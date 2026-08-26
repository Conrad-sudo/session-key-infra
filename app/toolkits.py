"""
Per-user toolkit construction for langchain-erc20, langchain-uniswap-v2 and langchain-erc8004.

These three packages own all ERC20, Uniswap V2 and ERC-8004 registry calldata construction:
balances, quotes, slippage bounds, approval sequencing, agent reads and registry writes. They
return an ordered *execution plan* -- a list of account-agnostic (to, value, data) calls -- and
never sign, submit, or hold a key. Turning a plan into a UserOperation is app/tools.py's job
(see _submit_plan there).

Two things force a wrapper layer rather than exposing the package tools to the agent directly:

  1. A toolkit instance is bound to ONE rpc/router/token set. The bot is multi-tenant by
     chat_id, so toolkits are built lazily and cached per chat_id, exactly like the Contract
     instances in contracts.py.
  2. langchain-uniswap-v2 takes raw addresses only. The agent speaks tickers and contact
     names, so app/tools.py resolves those before invoking a package tool.

All three toolkits are built in tx_mode="calls": they emit plan["calls"] and skip every
nonce/gas/fee RPC call. That is the correct mode for a smart account -- an ERC-4337 nonce is
EntryPoint.getNonce(sender, key), not an EOA transaction count, and eth_estimateGas with
`from` set to the account simulates it calling itself rather than the EntryPoint invoking it.
"""

from langchain_core.tools import BaseTool
from langchain_erc20 import ERC20Toolkit
from langchain_erc8004 import ERC8004Toolkit
from langchain_uniswap_v2 import UniswapV2Toolkit

from constants import ETH_SENTINEL, get_native_wrapped_ticker, get_router
from contracts import load_session_handler
from db import get_supported_tokens, get_token_address
from network_config import load_network_config

_erc20_tools_cache: dict[int, dict[str, BaseTool]] = {}
_uniswap_tools_cache: dict[int, dict[str, BaseTool]] = {}
_erc8004_tools_cache: dict[int, dict[str, BaseTool]] = {}

# Package tools that build valid ERC20 calldata but ALWAYS revert on this wallet, because
# SpendingLimitModule rejects any transaction that leaves an allowance standing (and rejects
# type(uint256).max outright). Approvals are only ever legal inside a batch that consumes
# them in the same transaction -- which every write tool below already emits. Withheld so the
# agent cannot reach for one and burn a UserOp on a guaranteed revert.
_BLOCKED_TOOLS = frozenset({"approve", "approve_token", "revoke_approval"})


def _token_map(chat_id: int) -> dict[str, str]:
    """Ticker -> checksummed address for every token listed on the user's current chain.

    Snapshotted into the toolkit at construction, so adding a token to the DB mid-session
    requires invalidate_toolkits(chat_id) before it resolves.
    """
    _, chain_id, _ = load_network_config(chat_id)
    return {
        ticker: get_token_address(chain_id, ticker)
        for ticker in get_supported_tokens(chat_id)
    }


def get_erc20_tools(chat_id: int) -> dict[str, BaseTool]:
    """Returns {tool_name: tool} for langchain-erc20, bound to this user's chain.

    @param chat_id  The Telegram chat ID of the user.
    """
    if chat_id not in _erc20_tools_cache:
        w3, chain_id, _ = load_network_config(chat_id)
        tokens = _token_map(chat_id)
        toolkit = ERC20Toolkit(
            rpc_url=w3.provider.endpoint_uri,
            tx_mode="calls",
            tokens=tokens,
            # deposit()/withdraw() target for wrap_native/unwrap_native. On Celo this
            # resolves to the CELO ERC20, which has no deposit() -- wrapping has never been
            # meaningful there (see NATIVE_WRAPPED_TICKER in constants.py).
            native_wrapped_address=tokens[get_native_wrapped_ticker(chain_id)],
            # Matches the address(0) sentinel the wallet and SHOracle already use for native.
            native_sentinel=ETH_SENTINEL,
        )
        _erc20_tools_cache[chat_id] = {
            t.name: t for t in toolkit.get_tools() if t.name not in _BLOCKED_TOOLS
        }
    return _erc20_tools_cache[chat_id]


def get_uniswap_tools(chat_id: int) -> dict[str, BaseTool]:
    """Returns {tool_name: tool} for langchain-uniswap-v2, bound to this user's router.

    @param chat_id  The Telegram chat ID of the user.
    """
    if chat_id not in _uniswap_tools_cache:
        w3, chain_id, _ = load_network_config(chat_id)
        tokens = _token_map(chat_id)
        toolkit = UniswapV2Toolkit(
            rpc_url=w3.provider.endpoint_uri,
            # Read the router from app constants, never from the package's chain registry
            # (which has no Anvil entry and points BSC elsewhere). This is the same address
            # deploy_wallet.py passes to addTrustedSpender, so the router the toolkit builds
            # calldata for is always the one the wallet actually trusts.
            router_address=get_router(chain_id),
            # Omitted on purpose -- the toolkit reads router.factory(), so the pair lookups
            # can never drift from the router the wallet actually uses, and Anvil works
            # without a hardcoded address.
            factory_address=None,
            native_wrapped_address=tokens[get_native_wrapped_ticker(chain_id)],
            tx_mode="calls",
            # Already the default in calls mode; explicit because SpendingLimitModule depends
            # on it. Appends approve(router, 0) to any plan where the router may pull less
            # than it was approved for (exact-output swaps, addLiquidity), so no residual
            # allowance survives the transaction.
            reset_residual_approvals=True,
        )
        _uniswap_tools_cache[chat_id] = {
            t.name: t for t in toolkit.get_tools() if t.name not in _BLOCKED_TOOLS
        }
    return _uniswap_tools_cache[chat_id]


def get_erc8004_tools(chat_id: int) -> dict[str, BaseTool]:
    """Returns {tool_name: tool} for langchain-erc8004, bound to this user's registries.

    @param chat_id  The Telegram chat ID of the user.
    """
    if chat_id not in _erc8004_tools_cache:
        w3, _, _ = load_network_config(chat_id)
        wallet = load_session_handler(chat_id)
        toolkit = ERC8004Toolkit(
            rpc_url=w3.provider.endpoint_uri,
            # Both addresses come off the WALLET, never from the package's chain table. The
            # canonical 0x8004... pair is right on Sepolia/BSC, but on Anvil the protocol
            # deploys MockIdentityRegistry/MockReputationRegistry -- and chain 31337 is not in
            # KNOWN_NETWORKS at all. Reading them from the account the UserOp executes from is
            # the only way the toolkit's calldata and the wallet's view cannot disagree.
            identity_registry=wallet.functions.IDENTITY_REGISTRY().call(),
            reputation_registry=wallet.functions.REPUTATION_REGISTRY().call(),
            # Omitted deliberately: ERC-8004's Validation Registry has no canonical deployment
            # on any chain, and this protocol deploys none. Leaving it unset makes the toolkit
            # withhold its seven tools rather than offer ones that can only fail.
            validation_registry=None,
            tx_mode="calls",
            # The sender every plan is built FOR: registry writes go out as UserOps executed by
            # the account, so msg.sender at the registry is the wallet, not the session key.
            # It is also what the package preflights against -- the self-feedback guard and the
            # owner/operator checks on the identity writes all test this address.
            from_address=wallet.address,
            # In calls mode this is a single eth_call preflight rather than a gas estimate, so
            # a write that would revert (self-feedback, not the owner, nonexistent agent) is
            # caught here instead of burning a UserOp.
            estimate_gas=True,
            # No default reviewer allowlist: filtered reputation reads must name their
            # reviewers explicitly. Sybil inflation is the expected attack on this registry
            # (anyone can register an agent and review it from addresses they control), and
            # there is no set of reviewers this project has an independent reason to trust.
            client_allowlist=None,
        )
        _erc8004_tools_cache[chat_id] = {t.name: t for t in toolkit.get_tools()}
    return _erc8004_tools_cache[chat_id]


def invalidate_toolkits(chat_id: int) -> None:
    """Drop every cached toolkit for chat_id after a redeploy, network switch, or token add.

    Called by contracts.invalidate_cache, which is the single invalidation entry point.
    """
    _erc20_tools_cache.pop(chat_id, None)
    _uniswap_tools_cache.pop(chat_id, None)
    _erc8004_tools_cache.pop(chat_id, None)
