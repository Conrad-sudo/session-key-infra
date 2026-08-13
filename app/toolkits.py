"""
Per-user toolkit construction for langchain-erc20 and langchain-uniswap-v2.

These two packages own all ERC20 and Uniswap V2 calldata construction: balances, quotes,
slippage bounds, approval sequencing. They return an ordered *execution plan* -- a list of
account-agnostic (to, value, data) calls -- and never sign, submit, or hold a key. Turning a
plan into a UserOperation is app/tools.py's job (see _submit_plan there).

Two things force a wrapper layer rather than exposing the package tools to the agent directly:

  1. A toolkit instance is bound to ONE rpc/router/token set. The bot is multi-tenant by
     chat_id, so toolkits are built lazily and cached per chat_id, exactly like the Contract
     instances in contracts.py.
  2. langchain-uniswap-v2 takes raw addresses only. The agent speaks tickers and contact
     names, so app/tools.py resolves those before invoking a package tool.

Both toolkits are built in tx_mode="calls": they emit plan["calls"] and skip every
nonce/gas/fee RPC call. That is the correct mode for a smart account -- an ERC-4337 nonce is
EntryPoint.getNonce(sender, key), not an EOA transaction count, and eth_estimateGas with
`from` set to the account simulates it calling itself rather than the EntryPoint invoking it.
"""

from langchain_core.tools import BaseTool
from langchain_erc20 import ERC20Toolkit
from langchain_uniswap_v2 import UniswapV2Toolkit

from constants import ETH_SENTINEL, get_native_wrapped_ticker, get_router
from db import get_supported_tokens, get_token_address
from network_config import load_network_config

_erc20_tools_cache: dict[int, dict[str, BaseTool]] = {}
_uniswap_tools_cache: dict[int, dict[str, BaseTool]] = {}

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


def invalidate_toolkits(chat_id: int) -> None:
    """Drop both cached toolkits for chat_id after a redeploy, network switch, or token add.

    Called by contracts.invalidate_cache, which is the single invalidation entry point.
    """
    _erc20_tools_cache.pop(chat_id, None)
    _uniswap_tools_cache.pop(chat_id, None)
