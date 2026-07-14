import os
import sys
import time
from web3 import Web3
from web3.logs import DISCARD
from constants import (
    ETH_SENTINEL,
    HEARTBEAT_24H,
    get_native_wrapped_ticker,
)
from network_config import load_network_config_by_name, load_network_config
from db import (
    get_reputation_registry_selectors,
    save_wallet_address,
    save_session,
    save_user_network,
    get_token_address,
    get_erc20_selectors,
    get_uniswapv2_selectors,
    save_contact
)
from anvil import get_or_create_session_key
from contracts import (
    invalidate_cache,
    load_factory,
    load_session_handler,
    load_session_handler_module,
    load_ierc20,
    load_calldata,
    pack_execution_calldata,
    ERC7579_SINGLE_CALL_MODE,
)

nonce: int

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
    "sepolia-fork": "FORK_DEPLOYER_PK",
    "bsc-fork": "FORK_DEPLOYER_PK",
    "celo-fork": "FORK_DEPLOYER_PK",
}


def _private_key_env(chain_name: str) -> str:
    """Returns the env var name holding the deployer key for chain_name."""
    return LIVE_PRIVATE_KEY_ENV.get(chain_name, "ANVIL_PRIVATE_KEY")


def _call(contract_fn, w3: Web3, deployer, chain_id: int, nonce: int):
    """
    Sends a non-deployment state-changing transaction and waits for the receipt.

    Builds, signs, and sends a transaction for a bound contract function call.
    Used for post-deployment setup steps such as minting tokens or calling execute().
    The caller is responsible for incrementing the nonce after each call.

    @param contract_fn  A bound ContractFunction ready to call build_transaction() on.
    @param w3           Web3 connection to the target network.
    @param deployer     Signing account (web3.py LocalAccount).
    @param chain_id     EIP-155 chain ID used when building the transaction.
    @param nonce        Sender nonce for this transaction.
    """
    tx = contract_fn.build_transaction(
        {"from": deployer.address, "nonce": nonce, "chainId": chain_id}
    )
    w3.eth.wait_for_transaction_receipt(
        w3.eth.send_raw_transaction(
            w3.eth.account.sign_transaction(tx, deployer.key).raw_transaction
        )
    )


def sync_anvil_time(w3):
    """
    Sets Anvil's next block timestamp to the current system time,
    preventing Chainlink staleness errors on a mainnet fork.
    """
    import time

    w3.provider.make_request("evm_setNextBlockTimestamp", [int(time.time())])
    w3.provider.make_request("evm_mine", [])


def prefund(deployer, wallet_address: str, w3: Web3, network: str, chain_id: int):
    """
    Funds two accounts from the deployer after SessionHandler wallet deployment:
      1. SessionHandler wallet — 10 ETH to cover ERC-4337 prefund and any forwarded
         ETH used for WETH wraps or Uniswap swaps initiated by session keys.
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
    # 1. Send 10 ETH to the SessionHandler wallet (covers ERC-4337 prefund + forwarded ETH for wraps/swaps)
    tx = {
        "from": deployer.address,
        "to": wallet_address,
        "value": w3.to_wei(10, "ether"),
        "nonce": nonce,
        "chainId": chain_id,
        "gas": 50_000,
        "gasPrice": w3.eth.gas_price,
    }
    w3.eth.wait_for_transaction_receipt(
        w3.eth.send_raw_transaction(
            w3.eth.account.sign_transaction(tx, deployer.key).raw_transaction
        )
    )
    print(f"SessionHandler wallet funded with 10 ETH for {network} deployments.")

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
            "gasPrice": w3.eth.gas_price,
        }
        w3.eth.wait_for_transaction_receipt(
            w3.eth.send_raw_transaction(
                w3.eth.account.sign_transaction(tx, deployer.key).raw_transaction
            )
        )
        print(f"Funded Bundler {bundler.address} with 10 ETH for {network} deployments.")


def deploy_wallet(chat_id: int, chain_name: str):
    """
    Deploys a new SessionHandler wallet for chat_id by calling SHFactory.deployWallet()
    on the given chain, then persists the resulting address to wallet.db.

    This assumes the shared protocol infrastructure (EntryPoint, SHOracle,
    SHTreasury/SHRegistry, SHFactory, SessionHandlerModule) has already been deployed on
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
    tx = factory.functions.deployWallet().build_transaction(
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






def add_session(
    chat_id: int,
    targets: list[str],
    functions: list[list[str]],
    session_ends: list[int],
    limits: list[int],
):
    """
    Registers one session key per target on the SessionHandler contract by calling
    addSessionKey() as the owner. Each target gets its own session with independent
    function whitelists, duration, and spending limit.

    All four list parameters must have the same length — one entry per target.


    @param chat_id      The Telegram chat ID of the user for whom to create session keys.
                        Used to look up the deployed SessionHandler address from the database.
                         Passed to load_network_config() to obtain the Web3 instance, chain ID and Chain Name.
    @param targets      Token ticker symbols identifying the target contracts
                        (e.g. ["usdc", "dai"]). Each is resolved to a contract address
                        via get_anvil_token_address().
    @param functions    Per-target lists of function names to whitelist
                        (e.g. [["transfer", "approve"], ["transfer"]]).
                        Each name is looked up in erc20_selectors and keccak-hashed
                        to produce the 4-byte selector passed to addSessionKey().
    @param session_ends Per-target session durations in days from the current time.
                        (e.g. [1, 7] — 1 day for usdc, 7 days for dai).
    @param limits       Per-target maximum cumulative spending limits in whole USD units
                        (e.g. [1000, 500]). Converted to wei (18-decimal) internally.
    """
    w3, chain_id, chain_name = load_network_config(chat_id)
    if not (len(targets) == len(functions) == len(session_ends) == len(limits)):
        raise ValueError(
            "targets, functions, session_ends, and limits must all have the same length"
        )

    private_key_env = _private_key_env(chain_name)
    owner = w3.eth.account.from_key(os.getenv(private_key_env))
    session_handler = load_session_handler(chat_id=chat_id)
    module = load_session_handler_module(chat_id=chat_id)
    selector_map = {row["name"]: row["selector"] for row in get_erc20_selectors()}
    selector_map.update(
        {row["name"]: row["selector"] for row in get_uniswapv2_selectors()}
    )
    selector_map.update(
        {row["name"]: row["selector"] for row in get_reputation_registry_selectors()}
    )
    for target, funcs, session_end, limit in zip(
        targets, functions, session_ends, limits
    ):

        if target in ["eth","bnb"]:
            target_address = ETH_SENTINEL

        elif target == "uniswapv2_router":
            target_address = session_handler.functions.getRouter().call()

        elif chain_name == "anvil":
            target_address = load_ierc20(chat_id=chat_id, token=target).address

        elif target == "reputation_registry":
            target_address = session_handler.functions.REPUTATION_REGISTRY().call()
            

        else:
            target_address = get_token_address(chain_id, target)
        session_key, _ = get_or_create_session_key(chat_id, target_address)

        selectors = []
        valid_from = 0
        valid_until = int(time.time()) + HEARTBEAT_24H * session_end
        spending_limit = w3.to_wei(limit, "ether")  # scale USD to 18-decimal precision

        for func in funcs:
            if func not in selector_map:
                raise ValueError(
                    f"Function '{func}' has no selector in erc20_selectors"
                )
            selectors.append(bytes.fromhex(selector_map[func].removeprefix("0x")))

        # SessionHandlerModule rejects spendingLimit == 0 outright via addSessionKey.
        # reputation_registry sessions are registered with limit 0 (see add_default_session) —
        # that's not a priced target (SHOracle has no feed for it), so it goes through
        # addUnpricedSessionKey instead, which skips pricing/budget tracking entirely while
        # still enforcing target + selector allowlisting.
        if target == "reputation_registry":
            tx = session_handler.functions.addUnpricedSessionKey(
                session_key,
                target_address,
                selectors,
                valid_from,
                valid_until,
            ).build_transaction(
                {
                    "from": owner.address,
                    "nonce": w3.eth.get_transaction_count(owner.address),
                    "chainId": chain_id,
                }
            )
        else:
            tx = session_handler.functions.addSessionKey(
                session_key,
                target_address,
                selectors,
                valid_from,
                valid_until,
                spending_limit,
            ).build_transaction(
                {
                    "from": owner.address,
                    "nonce": w3.eth.get_transaction_count(owner.address),
                    "chainId": chain_id,
                }
            )

        signed_tx = w3.eth.account.sign_transaction(tx, owner.key)
        tx_hash = w3.eth.send_raw_transaction(signed_tx.raw_transaction)
        receipt = w3.eth.wait_for_transaction_receipt(tx_hash)
        save_session(chat_id, target, spending_limit, valid_until)

        # SessionAdded is emitted by SessionHandlerModule, not SessionHandler —
        # the wallet's own ABI no longer declares this event at all.
        logs = module.events.SessionAdded().process_receipt(receipt)
        print(f"Session added! tx: {tx_hash.hex()}, status: {receipt['status']}")
        if logs:
            log = logs[0]
            print("Session Key:", log["args"]["sessionKey"])
            print("Target:     ", log["args"]["target"])
            print("Valid Until:", log["args"]["validUntil"])
        else:
            print(
                "Warning: SessionAdded event could not be decoded (stale ABI — run forge build)"
            )
    if "mainnet" in chain_name or "sepolia" in chain_name or "bsc" in chain_name or "celo" in chain_name:
        for target in targets:
            if target not in ("uniswapv2_router", "eth"):
                approve(
                    chat_id, target
                )  # approve each token for the DEX router so it can be swapped within session limits


def approve(chat_id: int, token: str):
    """
    Approves the Uniswap V2 router to spend type(uint256).max of a given token
    from the SessionHandler wallet by calling execute() directly as the owner (deployer).

    This isn't a UserOp — no EntryPoint involved. It's the owner's direct-call escape hatch
    on execute() (onlyEntryPointOrSelfOrOwner), so the (mode, executionCalldata) packing
    still applies even though there's no session key or nonce involved here.

    This must be called before any swap that spends token_in, since the router
    uses transferFrom to pull tokens from the SessionHandler wallet.

    @param chat_id  The Telegram chat ID of the user.
    @param token    The ticker symbol of the ERC20 token to approve (e.g. "usdc").
    """
    if token == "reputation_registry":
        return

    w3, chain_id, chain_name = load_network_config(chat_id)
    private_key_env = _private_key_env(chain_name)
    deployer = w3.eth.account.from_key(os.getenv(private_key_env))
    session_handler = load_session_handler(chat_id)
    router_address=session_handler.functions.getRouter().call()

    erc20 = load_ierc20(chat_id=chat_id, token=token)

    approve_data = load_calldata(instance=erc20, fn_name="approve", args=[router_address, 2**256 - 1])
    execution_calldata = pack_execution_calldata(erc20.address, 0, approve_data)

    _call(
        session_handler.functions.execute(ERC7579_SINGLE_CALL_MODE, execution_calldata),
        w3,
        deployer,
        chain_id,
        w3.eth.get_transaction_count(deployer.address),
    )
    print(f"Approved Uniswap V2 router to spend {token.upper()} from SessionHandler wallet.")


def add_default_session(chat_id: int):
    """
    Registers a default set of session keys for a new user.

    Called automatically after deploy_wallet() to give the user
    immediate access to the four most common tokens with sensible defaults.
    Each token gets its own session key scoped to the standard ERC20 functions,
    a 1-day validity window, and a per-token spending limit.

    @param chat_id  The Telegram chat ID of the user.
    """
    _, chain_id, chain_name = load_network_config(chat_id)
    native_wrapped = get_native_wrapped_ticker(chain_id)
    erc20_functions = ["transfer", "balanceOf", "approve", "transferFrom", "allowance"]
    weth_functions = erc20_functions + ["deposit", "withdraw"]
    uniswapV2_functions = [
        "swapETHForExactTokens",
        "swapExactTokensForTokens",
        "swapTokensForExactTokens",
        "swapExactTokensForETH",
        "swapExactETHForTokens",
        "swapTokensForExactETH",
        "addLiquidity",
        "addLiquidityETH",
        "removeLiquidity",
        "removeLiquidityETH",
    ]
    reputation_registry_functions = ["giveFeedback"]

    if "mainnet" in chain_name:
        add_session(
            chat_id=chat_id,
            targets=["eth", native_wrapped, "usdc", "uniswapv2_router","reputation_registry"],
            functions=[
                [],  # empty selector array for native ETH sessions (address(0) target) since there are no function calls, just value transfers
                weth_functions,
                erc20_functions,
                uniswapV2_functions,
                reputation_registry_functions
            ],
            session_ends=[50, 50, 50, 50, 50],
            limits=[50000, 50000, 50000, 50000, 0],
        )
    if "sepolia" in chain_name:
        add_session(
            chat_id=chat_id,
            targets=["eth", native_wrapped, "link", "uniswapv2_router", "reputation_registry"],
            functions=[
                [],  # empty selector array for native ETH sessions (address(0) target) since there are no function calls, just value transfers
                weth_functions,
                erc20_functions,
                uniswapV2_functions,
                reputation_registry_functions

            ],
            session_ends=[50, 50, 50, 50, 50],
            limits=[50000, 50000, 50000, 50000, 0],
        )
    if "bsc" in chain_name:
        # "eth" remains the native-value sentinel target (resolves to ETH_SENTINEL/address(0)
        # in add_session) even though the asset moving is BNB — SHOracle prices address(0)
        # against BNB-USD on chain 56 regardless of the ticker name used to request the session.
        add_session(
            chat_id=chat_id,
            targets=["bnb", native_wrapped, "usdc", "uniswapv2_router", "reputation_registry"],
            functions=[
                [],  # empty selector array for native BNB sessions (address(0) target) since there are no function calls, just value transfers
                weth_functions,
                erc20_functions,
                uniswapV2_functions,
                reputation_registry_functions
            ],
            session_ends=[50, 50, 50, 50, 50],
            limits=[50000, 50000, 50000, 50000, 0],
        )
    if "celo" in chain_name:
        # Ubeswap V2 has no WETH() function — CELO is natively an ERC-20, so there is no
        # wrapping step and the *ETH*-payable router functions are unusable. Only token-to-token
        # Ubeswap functions are whitelisted. "celo" ERC-20 has no deposit()/withdraw() either.
        celo_uniswap_functions = [
            "swapExactTokensForTokens",
            "swapTokensForExactTokens",
            "addLiquidity",
            "removeLiquidity",
        ]
        add_session(
            chat_id=chat_id,
            targets=["eth", native_wrapped, "usdc", "uniswapv2_router", "reputation_registry"],
            functions=[
                [],  # empty selector array for native CELO sessions (address(0) target)
                erc20_functions,  # CELO ERC-20: no deposit/withdraw since it is natively ERC-20
                erc20_functions,
                celo_uniswap_functions,
                reputation_registry_functions,
            ],
            session_ends=[50, 50, 50, 50, 50],
            limits=[50000, 50000, 50000, 50000, 0],
        )


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
    approve(chat_id=chat_id, token="wbnb")
