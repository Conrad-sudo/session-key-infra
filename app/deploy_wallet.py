import os
import sys
from web3 import Web3
from web3.logs import DISCARD
from constants import (
    get_native_wrapped_ticker,
    get_router,
)
from network_config import load_network_config_by_name, load_network_config
from db import (
    save_wallet_address,
    save_user_network,
    save_contact
)
from userop import get_or_create_session_key
from contracts import (
    invalidate_cache,
    load_factory,
    load_session_handler,
    load_ierc20,
)

nonce: int

# Wallet-wide USD spending cap (18 decimals) configured at deployment: the max NET value that
# may leave the wallet per spending window, across every token and venue combined. Mirrors the
# $50k per-session limits the old per-target design used.
DEFAULT_DAILY_LIMIT_USD = 50_000 * 10**18
# Spending-window length in seconds (24h — the cap refills each window).
DEFAULT_WINDOW_SECS = 86_400

# ETH transferred into a freshly deployed wallet by prefund() so it can pay its own ERC-4337
# prefund (maxFeePerGas * total gas limit, drawn from balance since the wallet holds no EntryPoint
# deposit) and forward ETH into WETH wraps / Uniswap swaps. Live testnets get a modest amount
# (Sepolia/BSC ETH is faucet-scarce) sized to cover a UserOp prefund even when the base fee is
# elevated — at ~40 gwei base, a ~400k-gas op prefunds ~0.03 ETH, so 0.15 leaves room for the op
# plus the transfer. Local anvil + fork chains run on a richly-funded deployer, so they keep a
# larger cushion for multi-swap e2e runs. Strings (not floats) so to_wei converts them exactly.
WALLET_PREFUND_ETH_LIVE = "0.15"
WALLET_PREFUND_ETH_LOCAL = "1"

# Tokens the wallet's spending-limit module meters (net-value tracking), per network. Each MUST
# already be priced by the deployed SHOracle, or deployWallet reverts with TokenNotPriced.
# Native ETH/BNB is ALWAYS metered (it is not on this watched list); only unwatched ERC20s sit
# outside the meter.
DEFAULT_WATCHED_TICKERS = {
    "anvil": ["weth", "usdc", "dai"],
    "mainnet-fork": ["weth", "usdc", "dai"],
    "sepolia": ["weth", "usdc", "link"],
    "sepolia-fork": ["weth", "usdc", "link"],
    "bsc": ["wbnb", "usdc", "usdt"],
    "bsc-fork": ["wbnb", "usdc", "usdt"],
    # Celo intentionally omitted: HelperConfig.s.sol has no Celo NetworkConfig, so a Celo deploy
    # falls back to mainnet config anyway. Add a Celo watched list here only once Celo is wired up.
}

# Maps a chain_name to the env var holding its deployer private key. Fork networks of a
# real chain (mainnet-fork, sepolia-fork, bsc-fork, celo-fork) get a dedicated key too, not the
# Anvil default burner key — forking inherits that chain's real on-chain state, and the
# well-known Anvil/Hardhat accounts have been EIP-7702-delegated to drainer contracts on real
# Sepolia/BSC/mainnet (see HelperConfig.s.sol's MAINNET_DEPLOYER_PK comment for the same issue
# on the Foundry side). Plain "anvil" (no fork) has no real-world state to inherit, so the
# burner key is fine there — it's the only chain name allowed to fall through to the
# ANVIL_PRIVATE_KEY default in _private_key_env below.
LIVE_PRIVATE_KEY_ENV = {
    "sepolia": "SEPOLIA_PRIVATE_KEY",
    "bsc": "BSC_PRIVATE_KEY",
    "celo": "CELO_PRIVATE_KEY",
    "mainnet-fork": "FORK_DEPLOYER_PK",
    "sepolia-fork": "SEPOLIA_PRIVATE_KEY",
    "bsc-fork": "FORK_DEPLOYER_PK",
    "celo-fork": "FORK_DEPLOYER_PK",
}


def _private_key_env(chain_name: str) -> str:
    """Returns the env var name holding the deployer key for chain_name."""
    return LIVE_PRIVATE_KEY_ENV.get(chain_name, "ANVIL_PRIVATE_KEY")


def _eip1559_fees(w3: Web3) -> dict:
    """
    Returns EIP-1559 fee fields (maxFeePerGas / maxPriorityFeePerGas) giving a transaction a
    2x base-fee cushion. A legacy fixed `gasPrice` can never pay above its set value, so on
    Sepolia — where the base fee routinely several-x's within a few blocks — such a tx gets
    stranded and eventually dropped once the base fee climbs past it (the TimeExhausted this
    replaces). The 2x headroom mirrors how web3.py auto-populates fees for build_transaction,
    which is why deployWallet() below never hit this. Splat into a tx dict with **.
    """
    base = w3.eth.get_block("latest")["baseFeePerGas"]
    try:
        tip = w3.eth.max_priority_fee
    except Exception:
        # Some nodes don't implement eth_maxPriorityFeePerGas; a 2 gwei tip is a safe default.
        tip = w3.to_wei(2, "gwei")
    return {"maxFeePerGas": 2 * base + tip, "maxPriorityFeePerGas": tip}


def prefund(deployer, wallet_address: str, w3: Web3, network: str, chain_id: int):
    """
    Funds two accounts from the deployer after SessionHandler wallet deployment:
      1. SessionHandler wallet — ETH to cover its ERC-4337 prefund deposit and any forwarded
         ETH used for WETH wraps or Uniswap swaps initiated by session keys. Amount is
         WALLET_PREFUND_ETH_LIVE on live testnets, WALLET_PREFUND_ETH_LOCAL on anvil/forks.
      2. Bundler (FORK_DEPLOYER_PK, shared across every fork network) — 10 ETH to cover
         the gas cost of bundling ERC-4337 UserOperations on the fork. This is the same
         key anvil.py uses at runtime to sign the outer handleOps transaction, so the
         account that gets funded here is always the one that actually pays gas later.
         Skipped when the deployer is already that same key (e.g. sepolia-fork/bsc-fork/
         celo-fork, where _private_key_env also resolves to FORK_DEPLOYER_PK) — funding
         an account from itself would just burn gas on a no-op transfer.

    Args:
        deployer:       Signing account (web3.py LocalAccount) that pays for both transfers.
        wallet_address: Address of the deployed SessionHandler wallet.
        w3:             Web3 connection to the target network.
        network:        Network name (e.g. "anvil", "mainnet-fork", "sepolia-fork", "sepolia").
        chain_id:       EIP-155 chain ID used when building transactions.
    """
    nonce = w3.eth.get_transaction_count(deployer.address)
    is_live = "fork" not in network and network != "anvil"
    wallet_prefund = WALLET_PREFUND_ETH_LIVE if is_live else WALLET_PREFUND_ETH_LOCAL
    # 1. Fund the SessionHandler wallet (covers its ERC-4337 prefund deposit + forwarded ETH for wraps/swaps)
    tx = {
        "from": deployer.address,
        "to": wallet_address,
        "value": w3.to_wei(wallet_prefund, "ether"),
        "nonce": nonce,
        "chainId": chain_id,
        "gas": 50_000,
        **_eip1559_fees(w3),
    }
    w3.eth.wait_for_transaction_receipt(
        w3.eth.send_raw_transaction(
            w3.eth.account.sign_transaction(tx, deployer.key).raw_transaction
        )
    )
    print(f"SessionHandler wallet funded with {wallet_prefund} ETH for {network} deployments.")

    if "fork" in network:
        # 2. Fund the Bundler with 10 ETH to cover the gas costs of bundling UserOperations on
        #    this fork. FORK_DEPLOYER_PK is shared across every fork network — it's the same key
        #    anvil.py resolves at runtime for any non-Anvil chain, so funding and usage stay in sync.
        bundler = w3.eth.account.from_key(os.getenv("FORK_DEPLOYER_PK"))
        if bundler.address == deployer.address:
            print(f"Bundler {bundler.address} is the same as the deployer — already funded, skipping.")
            return
        nonce += 1
        tx = {
            "from": deployer.address,
            "to": bundler.address,
            "value": w3.to_wei(10, "ether"),
            "nonce": nonce,
            "chainId": chain_id,
            "gas": 50_000,
            **_eip1559_fees(w3),
        }
        w3.eth.wait_for_transaction_receipt(
            w3.eth.send_raw_transaction(
                w3.eth.account.sign_transaction(tx, deployer.key).raw_transaction
            )
        )
        print(f"Funded Bundler {bundler.address} with 10 ETH for {network} deployments.")


def _default_watched_tokens(chat_id: int, chain_name: str) -> list[str]:
    """
    Resolves the default watched-token ticker list for chain_name into checksummed addresses.
    Requires the DB token table to be seeded (`make db`) so tickers resolve on this network.

    @param chat_id     The Telegram chat ID (used to resolve the network's token addresses).
    @param chain_name  The network being deployed to.
    @return            List of token addresses to pass to deployWallet as watchedTokens.
    """
    tickers = DEFAULT_WATCHED_TICKERS.get(chain_name, [])
    return [load_ierc20(chat_id=chat_id, token=ticker).address for ticker in tickers]


def deploy_wallet(chat_id: int, chain_name: str):
    """
    Deploys a new SessionHandler wallet for chat_id by calling SHFactory.deployWallet(
    dailyLimitUsd, windowDuration, watchedTokens) on the given chain, then persists the
    resulting address to wallet.db. The three arguments seed the wallet's spending-cap
    config: SpendingLimitModule is installed as a hook with a DEFAULT_DAILY_LIMIT_USD cap
    per DEFAULT_WINDOW_SECS window, metering the DEFAULT_WATCHED_TICKERS for this network.

    This assumes the shared protocol infrastructure (EntryPoint, SHOracle,
    SHTreasury/SHRegistry, SHFactory, SpendingLimitModule) has already been deployed on
    chain_name via `forge script script/DeploySHProtocol.s.sol` and synced into the DB via
    `make db` — including SHFactory.setSpendingLimitModule(...), without which
    deployWallet() reverts. This function only deploys the per-user SessionHandler
    wallet, then calls prefund() to fund the new wallet (and the bundler, on fork networks)
    with 10 ETH each.

    @param chat_id     The Telegram chat ID of the user who will own the new wallet.
    @param chain_name  The network to deploy on (e.g. "anvil", "mainnet-fork", "sepolia-fork", "sepolia").
    @return             The checksummed address of the newly deployed SessionHandler.
    """
    save_user_network(
        chat_id, chain_name
    )  # set network in DB before deployment so load_factory can resolve the right address
    w3, chain_id = load_network_config_by_name(chain_name)

    private_key_env = _private_key_env(chain_name)
    deployer = w3.eth.account.from_key(os.getenv(private_key_env))

    factory = load_factory(chat_id)
    watched_tokens = _default_watched_tokens(chat_id, chain_name)
    tx = factory.functions.deployWallet(
        DEFAULT_DAILY_LIMIT_USD, DEFAULT_WINDOW_SECS, watched_tokens
    ).build_transaction(
        {
            "from": deployer.address,
            "nonce": w3.eth.get_transaction_count(deployer.address),
            "chainId": chain_id,
        }
    )
    receipt = w3.eth.wait_for_transaction_receipt(
        w3.eth.send_raw_transaction(
            w3.eth.account.sign_transaction(tx, deployer.key).raw_transaction
        )
    )

    logs = factory.events.WalletDeployed().process_receipt(receipt,errors=DISCARD)
    if not logs:
        raise RuntimeError(
            "WalletDeployed event not found in receipt — deployWallet() may have reverted silently"
        )
    wallet_address = logs[0]["args"]["walletAddress"]

    prefund(deployer, wallet_address, w3, chain_name, chain_id)
    save_wallet_address(chat_id, wallet_address)
    invalidate_cache(chat_id)

    print(f"SessionHandler wallet deployed: {wallet_address}")
    print("Deployment complete — Database updated.")

    return wallet_address






def add_default_session(chat_id: int):
    """
    Registers the user's single session key on the SessionHandler wallet.

    The wallet authorizes ONE bare session key for the whole account (an allowedSession
    allowlist entry) rather than per-target scoped keys: the key may sign UserOps for any
    external call, bounded on-chain by two guardrails that replace the old per-target
    scoping entirely:
      1. the wallet-wide USD spending cap (net-value metering per window) configured at
         deployWallet time, and
      2. the account's execution guard, which blocks session-key calls to the wallet itself
         or its SpendingLimitModule (so a key can never raise its own cap), and its
         no-standing-approval rule (approvals must be consumed in the same transaction).

    Called automatically after deploy_wallet(). The key is generated (or fetched) via
    get_or_create_session_key keyed to the wallet address, encrypted in Vault, and
    registered on-chain with SessionHandler.addSession() as the owner.

    @param chat_id  The Telegram chat ID of the user.
    """
    w3, chain_id, chain_name = load_network_config(chat_id)
    private_key_env = _private_key_env(chain_name)
    owner = w3.eth.account.from_key(os.getenv(private_key_env))
    session_handler = load_session_handler(chat_id=chat_id)

    # One key per wallet: keyed to the wallet address (tools.get_session_keys resolves the
    # same way, so every tool signs with this exact key).
    session_key, _ = get_or_create_session_key(chat_id, session_handler.address)

    tx = session_handler.functions.addSession(session_key).build_transaction(
        {
            "from": owner.address,
            "nonce": w3.eth.get_transaction_count(owner.address),
            "chainId": chain_id,
        }
    )
    signed_tx = w3.eth.account.sign_transaction(tx, owner.key)
    tx_hash = w3.eth.send_raw_transaction(signed_tx.raw_transaction)
    receipt = w3.eth.wait_for_transaction_receipt(tx_hash)
    if receipt["status"] != 1:
        raise RuntimeError(f"addSession reverted (tx: {tx_hash.hex()})")

    logs = session_handler.events.SessionAdded().process_receipt(receipt, errors=DISCARD)
    print(f"Session added! tx: {tx_hash.hex()}, status: {receipt['status']}")
    if logs:
        print("Session Key:", logs[0]["args"]["sessionKey"])
    else:
        print("Warning: SessionAdded event could not be decoded (stale ABI — run forge build)")


def trust_router(chat_id: int):
    """
    Trusts the chain's canonical V2 router on the user's wallet, as the owner.

    A wallet deploys with an EMPTY trusted-spender list. SpendingLimitModule refuses any
    approval on a token the oracle cannot price unless its spender is trusted, so without
    this the LP-token approval inside remove_liquidity would revert (LP tokens have no
    Chainlink feed). Priced-token approvals never needed the exemption and are unaffected.

    The router used to be protocol configuration (SHRegistry.router) and was auto-trusted
    inside initialize(). It is now a wallet-level choice, granted here from the same
    constants.ROUTER entry toolkits.py binds the Uniswap toolkit to, so the trusted router
    and the router the bot builds calldata for cannot drift apart.

    Trusting a spender is a real grant: it may pull an unpriced token within a single
    transaction. The no-standing-approval rule still forces every such approval to exactly
    zero before the transaction ends.

    @param chat_id  The Telegram chat ID of the user.
    """
    w3, chain_id, chain_name = load_network_config(chat_id)
    try:
        router = get_router(chain_id)
    except ValueError:
        # Bare Anvil has no Uniswap deployment; nothing to trust and nothing to do.
        print(f"No router configured for chain {chain_id}; skipping trust_router")
        return

    private_key_env = _private_key_env(chain_name)
    owner = w3.eth.account.from_key(os.getenv(private_key_env))
    session_handler = load_session_handler(chat_id=chat_id)

    tx = session_handler.functions.addTrustedSpender(router).build_transaction(
        {
            "from": owner.address,
            "nonce": w3.eth.get_transaction_count(owner.address),
            "chainId": chain_id,
        }
    )
    signed_tx = w3.eth.account.sign_transaction(tx, owner.key)
    tx_hash = w3.eth.send_raw_transaction(signed_tx.raw_transaction)
    receipt = w3.eth.wait_for_transaction_receipt(tx_hash)
    if receipt["status"] != 1:
        raise RuntimeError(f"addTrustedSpender reverted (tx: {tx_hash.hex()})")
    print(f"Router trusted: {router} (tx: {tx_hash.hex()})")


def deploy(chat_id: int, network: str):
    """
    Top-level deployment dispatcher. Deploys a SessionHandler wallet for chat_id via
    SHFactory.deployWallet() on the given network.

    Supported networks: "anvil", "mainnet-fork", "sepolia-fork", "bsc-fork", "sepolia", "bsc".
    Each one must already have the shared protocol infrastructure deployed (see
    deploy_wallet()). "sepolia" and "bsc" are live networks — SEPOLIA_PRIVATE_KEY /
    BSC_PRIVATE_KEY must be set and funded with real ETH/BNB before deploying (see
    LIVE_PRIVATE_KEY_ENV).

    To target a different network, pass it as the first CLI argument (e.g.
    `python3 app/deploy_wallet.py bsc-fork`, or `make deploy-wallet ARGS=bsc-fork`).
    Defaults to "anvil" when no argument is given, matching `make deploy`'s own
    no-ARGS default (plain local Anvil) — see the Makefile's `NETWORK_ARGS`.

    @param chat_id  Telegram chat ID — used to key all database records for this user.
    @param network  Target network name (see supported values above).
    @raises ValueError  If network is not one of the supported values.
    """
    if network in ("anvil", "mainnet-fork", "sepolia-fork", "bsc-fork", "celo-fork", "sepolia", "bsc", "celo"):
        deploy_wallet(chat_id, network)
    else:
        raise ValueError(f"Unsupported network '{network}'")


if __name__ == "__main__":
    chat_id = int(os.getenv("TELEGRAM_CHAT_ID"))
    save_contact(chat_id=chat_id,name="tim",address="0x9f4d8D3f66C47c75b95325f01861d1643825Bffc")
    network = sys.argv[1] if len(sys.argv) > 1 else "anvil"
    deploy(chat_id=chat_id, network=network)
    add_default_session(chat_id=chat_id)
    trust_router(chat_id=chat_id)
