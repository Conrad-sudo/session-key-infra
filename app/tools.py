from decimal import Decimal


from db import (
    get_supported_tokens as _get_supported_tokens,
    save_contact as _save_contact,
    get_contact as _get_contact,
    get_all_contacts as _get_all_contacts,
    delete_contact as _delete_contact,
)
from network_config import load_network_config
from anvil import (
    send_user_op_as_session as _send_user_op_as_session,
    send_batch_user_op_as_session as _send_batch_user_op_as_session,
)
from userop import get_or_create_session_key

from live_network import (
    send_live_user_op_as_session as _send_live_user_op_as_session,
    send_live_batch_user_op_as_session as _send_live_batch_user_op_as_session,
)

from constants import ETH_SENTINEL, WEI_PER_ETH, get_native_wrapped_ticker, get_native_asset_ticker
from langchain_erc20.amounts import to_base_units


def _to_base_units(amount: float | str, decimals: int) -> int:
    """Whole units -> base units, via langchain-erc20's converter.

    Thin wrapper rather than a direct call: the package returns (base_units, truncated) and
    this codebase only ever wants the integer. Worth delegating anyway — the package rejects
    negative, non-finite and >uint256 amounts as ToolException instead of letting them reach
    web3 as an unreadable encoding error, and truncates toward zero so an over-precise amount
    can never round UP past a balance or an allowance.
    """
    base_units, _truncated = to_base_units(amount, decimals)
    return base_units


def send_user_op_as_session(chat_id, key_ciphertext, target, value, data):
    """
    Central dispatch for all on-chain writes in the bot. Routes a UserOperation to
    either the local Anvil backend (for fork/test networks) or the live Alchemy bundler
    (for all other networks), based on the chain name stored in the user's network config.

    Every @tool function that submits an on-chain transaction calls this function. The full
    ERC-4337 flow — gas estimation, signing, submission, and receipt polling — is handled by
    the appropriate backend. RuntimeError from either backend is converted to ToolException
    so LangChain's tool error handler can surface it to the agent cleanly.

    @param chat_id        The Telegram chat ID of the user making the request.
    @param key_ciphertext Vault Transit ciphertext for the session key ('vault:v1:...').
    @param target         The contract address the SessionHandler will call.
    @param value          ETH value in wei to forward with the inner call (0 for ERC20 ops).
    @param data           ABI-encoded calldata for the inner call on target.
    @return               A tuple of (tx_hash_bytes, receipt_dict) where receipt_dict
                          contains at least {"status": 1} on success.
    @raises ToolException If the UserOperation fails or the bundler rejects the submission.
    """
    _,_,chain_name = load_network_config(chat_id)

    if "fork" in chain_name.lower() or "anvil" in chain_name.lower():
        try:
            return _send_user_op_as_session(chat_id, key_ciphertext, target, value, data)
        except RuntimeError as e:
            raise ToolException(str(e))
    else:
        try:
            return _send_live_user_op_as_session(chat_id, key_ciphertext, target, value, data)
        except RuntimeError as e:
            raise ToolException(str(e))


def send_batch_user_op_as_session(chat_id, key_ciphertext, executions):
    """
    Batch counterpart of send_user_op_as_session: routes an atomic multi-call UserOperation
    (ERC-7579 batch mode) to the right backend. Used by every flow that grants an approval,
    since SpendingLimitModule reverts any transaction that leaves an approval standing —
    [approve, spend(, approve 0)] must land together in one UserOp.

    @param chat_id        The Telegram chat ID of the user making the request.
    @param key_ciphertext Vault Transit ciphertext for the session key ('vault:v1:...').
    @param executions     List of (target_address, value_wei, calldata_bytes) triples, in order.
    @return               A tuple of (tx_hash_bytes, receipt_dict).
    @raises ToolException If the UserOperation fails or the bundler rejects the submission.
    """
    _, _, chain_name = load_network_config(chat_id)

    if "fork" in chain_name.lower() or "anvil" in chain_name.lower():
        try:
            return _send_batch_user_op_as_session(chat_id, key_ciphertext, executions)
        except RuntimeError as e:
            raise ToolException(str(e))
    else:
        try:
            return _send_live_batch_user_op_as_session(chat_id, key_ciphertext, executions)
        except RuntimeError as e:
            raise ToolException(str(e))





from contracts import (
    load_session_handler,
    load_ierc20,
    load_calldata,
    load_reputation_registry,
)
from toolkits import get_erc20_tools, get_uniswap_tools
from db import get_token_address
from network_config import load_network_config
from langchain.tools import tool
from langchain_core.tools import ToolException
from web3 import Web3

# Kept only as the default for the agent-facing slippage_bps arguments. The bounds themselves
# are derived inside langchain-uniswap-v2, in exact integer arithmetic -- the old float
# `int(base * (BPS - bps) / BPS)` here silently drifted at 18 decimals, in the wrong direction
# for amountInMax and the addLiquidity desired amounts.
DEFAULT_SLIPPAGE_BPS = 50  # 0.5%


def _resolve(chat_id: int, token: str) -> str:
    """Ticker -> checksummed address, for the address-only langchain-uniswap-v2 tools.

    "eth" maps to the chain's wrapped-native token: on a router, native ETH/BNB is always
    routed as its wrapped form, and the *ETH-suffixed router functions wrap/unwrap around
    that same address. A raw 0x address passes through, so LP/pair tokens work too.

    @param token  A ticker listed for the user's chain, "eth", or a raw 0x address.
    """
    if token.startswith("0x") and len(token) == 42:
        return Web3.to_checksum_address(token)
    _, chain_id, _ = load_network_config(chat_id)
    if token.lower() == "eth":
        token = get_native_wrapped_ticker(chain_id)
    return get_token_address(chain_id, token)


def _resolve_contact(chat_id: int, name: str, role: str = "recipient", hint: str = "") -> str:
    """Saved-contact name (or "me") -> address, failing usefully when it is neither.

    Every tool that takes a person's name routes through here. Two reasons it is not just a
    db lookup:

      - db.get_contact returns None for an unknown name rather than raising. Passing that None
        onward surfaces as an opaque "must be a string, got NoneType" from deep inside the
        calldata builder, which tells the agent nothing it can act on.
      - It is deliberately NOT address-accepting. The model may only name someone the user
        already saved, so an address injected into the conversation cannot become a
        destination for value (THREAT_MODEL 4.2). That makes save_contact the privileged step.

    "me" names the wallet itself, matching transferFrom_erc20's documented convention.

    @param role  What this name is being used as, for the error message ("sender", "spender", ...).
    @param hint  Optional extra sentence appended to the error, e.g. how to skip the argument.
    @raises ToolException If the name is not a saved contact.
    """
    if name.lower() == "me":
        return load_session_handler(chat_id).address

    address = _get_contact(chat_id, name)
    if address is None:
        raise ToolException(
            f"'{name}' is not a saved contact, so they cannot be used as the {role}. "
            f"Ask the user for their address and call save_contact first.{hint}"
        )
    return address


def _resolve_recipient(chat_id: int, recipient: str | None) -> str | None:
    """Resolve a swap's optional output recipient. None means "the wallet itself".

    This is the one place a swap can send value somewhere other than the wallet, so the
    contact-only rule in _resolve_contact is what bounds it.
    """
    if recipient is None:
        return None
    return _resolve_contact(
        chat_id,
        recipient,
        role="swap output recipient",
        hint=" Or omit recipient to receive the output in your own wallet.",
    )


def _destination_note(recipient: str | None) -> str:
    """Result-string suffix naming where a swap's output went, when it wasn't the wallet."""
    if recipient is None or recipient.lower() == "me":
        return ""
    return f", sent directly to: {recipient}"


def _submit_plan(chat_id: int, key_ciphertext: str, plan: dict):
    """Submit a package execution plan as ONE UserOperation.

    A single-call plan goes out as an ERC-7579 single execution; anything longer is batched.
    Batching is not an optimisation here -- SpendingLimitModule reverts any transaction that
    leaves an allowance standing, so [approve, spend, (reset)] must land atomically. The
    packages already order and size those calls; plan["calls"] is executed verbatim, in order.

    @param plan  A plan dict from a langchain-erc20 / langchain-uniswap-v2 write tool.
    @return      A tuple of (tx_hash_bytes, receipt_dict).
    @raises ToolException If the UserOperation did not succeed.
    """
    executions = [
        (Web3.to_checksum_address(call["to"]), call["value"], bytes.fromhex(call["data"][2:]))
        for call in plan["calls"]
    ]

    if len(executions) == 1:
        target, value, data = executions[0]
        tx_hash, receipt = send_user_op_as_session(
            chat_id=chat_id,
            key_ciphertext=key_ciphertext,
            target=target,
            value=value,
            data=data,
        )
    else:
        tx_hash, receipt = send_batch_user_op_as_session(
            chat_id=chat_id,
            key_ciphertext=key_ciphertext,
            executions=executions,
        )

    if receipt["status"] != 1:
        raise ToolException(f"UserOp failed! tx: {tx_hash.hex()}")
    return tx_hash, receipt


"""
 /*//////////////////////////////////////////////////////////////
                        DATABASE TOOLS
//////////////////////////////////////////////////////////////*/
"""


@tool
def get_supported_tokens(chat_id: int) -> list:
    """
    Retrieves a list of supported token tickers for the user's current network.

    Use this tool when you need to know which tokens the wallet is set up to handle,
    especially before any on-chain action or when the user asks about a specific token.
    The returned list reflects the network the user is connected to (anvil or mainnet).

    Args:
        chat_id: The Telegram chat ID of the user. Required to resolve the correct
                 network and token table.

    Returns:
        A list of supported token ticker symbols (e.g. ["usdc", "dai"]).
    """
    print("Running get_supported_tokens")
    return _get_supported_tokens(chat_id)


@tool
def get_native_asset(chat_id: int) -> str:
    """
    Retrieves the display name of the wallet's native gas asset for its current network.

    Use this before referring to the wallet's native balance in a response, and whenever the
    user mentions a native-asset ticker (ETH, BNB, CELO, etc.) that doesn't match what you'd
    expect on Ethereum. "eth" as a ticker/session argument (e.g. get_eth_balance,
    send_eth, get_session_keys("eth")) always means "the chain's native asset" internally —
    it is NOT Ethereum-specific and works identically on every supported network. Never refuse
    a native-balance or native-send request just because the network isn't Ethereum; call this
    tool to find out what to call the asset instead.

    Args:
        chat_id: The Telegram chat ID of the user. Required to resolve the correct network.

    Returns:
        The native asset's display ticker for the current network (e.g. "ETH", "BNB", "CELO").
    """
    print("Running get_native_asset")
    _, chain_id, _ = load_network_config(chat_id)
    return get_native_asset_ticker(chain_id)


def _addresses_to_tickers(chat_id: int, addresses: list) -> list:
    """Best-effort reverse map of token addresses to their supported tickers, falling back to the
    raw address for anything not in the network's token table."""
    reverse = {}
    for ticker in _get_supported_tokens(chat_id):
        try:
            reverse[load_ierc20(chat_id=chat_id, token=ticker).address.lower()] = ticker
        except Exception:
            pass
    return [reverse.get(a.lower(), a) for a in addresses]


@tool
def get_all_sessions(chat_id: int) -> dict:
    """
    Reports the wallet's session-key and USD spending-cap status — the modern replacement for
    per-token sessions.

    This wallet authorizes ONE session key for every action, bounded by a single wallet-wide USD
    spending cap per rolling window (there are no per-token limits, and the key does not expire).
    Use this whenever the user asks about their session, spending limit, remaining budget, or how
    much they can still spend.

    Args:
        chat_id: The Telegram chat ID of the user making the request.

    Returns:
        A dict with:
          - session_active (bool): whether the wallet's session key is currently authorized.
          - daily_limit_usd (float): the per-window spending cap, in whole USD.
          - spent_usd (float): net USD value spent so far in the current window.
          - remaining_usd (float): USD still spendable in the current window.
          - window_hours (float): length of the spending window, in hours.
          - watched_tokens (list): ERC20 tickers whose value movements count against the cap. The
            native asset (ETH/BNB) is ALWAYS metered and is not on this list; only unwatched ERC20s
            move freely and are not metered.
    """
    print("Running get_all_sessions")
    session_handler = load_session_handler(chat_id)
    session_key, _ = get_session_keys.func(chat_id, "wallet")
    # Config tuple: (installed, windowStart, windowDuration, dailyLimitUsd, spentInWindow,
    #                watchedTokens, trustedSpenders)
    cfg = session_handler.functions.getConfig().call()
    remaining = session_handler.functions.getRemainingBudget().call()

    return {
        "session_active": session_handler.functions.allowedSession(session_key).call(),
        "daily_limit_usd": cfg[3] / WEI_PER_ETH,
        "spent_usd": cfg[4] / WEI_PER_ETH,
        "remaining_usd": remaining / WEI_PER_ETH,
        "window_hours": cfg[2] / 3600,
        "watched_tokens": _addresses_to_tickers(chat_id, cfg[5]),
    }


@tool
def save_contact(chat_id: int, name: str, address: str):
    """
    Saves a new contact by associating a human-readable name with an Ethereum address.

    Use this tool when the user wants to add or update a contact so they can be
    referred to by name in future transactions instead of a raw address. If a contact
    with the same name already exists, their address will be updated. Name lookup is
    case-insensitive.

    Args:
        chat_id: The Telegram chat ID of the user making the request.
        name: A human-readable label for the contact (e.g. "Sandy"). Stored in lowercase.
        address: The Ethereum address to associate with the name (e.g. "0x70997970C51812dc3A010C7d01b50e0d17dc79C8").
    """
    print("Running save_contact")
    _save_contact(chat_id, name, address)


@tool
def get_contact(chat_id: int, name: str) -> str:
    """
    Looks up the Ethereum address of a saved contact by name.

    Use this tool when you need to resolve a contact's address before performing
    an operation that requires a raw address. If the contact is not found, ask the
    user to provide their Ethereum address and call save_contact before proceeding.

    Args:
        chat_id: The Telegram chat ID of the user making the request.
        name: The name of the contact to look up (e.g. "Sandy"). Case-insensitive.

    Returns:
        The Ethereum address associated with the name, or None if not found.
    """
    print("Running get_contact")
    return _get_contact(chat_id, name)


@tool
def get_all_contacts(chat_id: int) -> list:
    """
    Retrieves all saved contacts for a given user.

    Use this tool when the user wants to see their full contact list.

    Args:
        chat_id: The Telegram chat ID of the user making the request.

    Returns:
        A list of dicts with 'name' and 'address' keys, sorted alphabetically by name.
        Returns an empty list if no contacts are saved.
    """
    print("Running get_all_contacts")
    return _get_all_contacts(chat_id)


@tool
def delete_contact(chat_id: int, name: str):
    """
    Deletes a saved contact by name.

    Use this tool when the user wants to remove a contact from their list. If the
    contact does not exist, this function will do nothing.

    Args:
        chat_id: The Telegram chat ID of the user making the request.
        name: The name of the contact to delete (e.g. "Sandy"). Case-insensitive.
    """
    print("Running delete_contact")
    return _delete_contact(chat_id, name)


"""
 /*//////////////////////////////////////////////////////////////
                        BLOCKCHAIN TOOLS
//////////////////////////////////////////////////////////////*/
"""


def _get_native_balance(chat_id: int) -> float:
    """
    Raw native-asset balance fetch, in whole units. Not LLM-facing — internal helper shared by
    get_eth_balance and the balance-sufficiency tools (is_derived_input_sufficient,
    is_exact_input_sufficient, is_liquidity_sufficient), which need a plain float to do
    arithmetic against, not the self-describing dict get_eth_balance returns to the agent.
    """
    w3, _, _ = load_network_config(chat_id)
    address = load_session_handler(chat_id).address
    balance_wei = w3.eth.get_balance(address)
    return balance_wei / WEI_PER_ETH


@tool
def get_eth_balance(chat_id: int) -> dict:
    """
    Retrieves the smart wallet's native gas asset balance, together with what that asset is
    actually called on the current network. "eth" in the tool name is a generic internal
    label, not a claim that the network is Ethereum — this works identically on every
    supported network. Always report the `asset` value from the result, never assume "ETH".

    Use this tool when the user asks how much of their native asset (ETH, BNB, etc.) the
    wallet holds, or wants to check whether there is enough before wrapping or sending. If the
    ticker the user asked about (e.g. "ETH") does not match the returned `asset` (e.g. "BNB"),
    do not report the balance under the ticker they asked about and do not invent a balance for
    it either — tell them their wallet is on a network whose native asset is `asset`, and there
    is no separate balance for the ticker they named on this network.

    Args:
        chat_id: The Telegram chat ID of the user making the request.

    Returns:
        A dict with `balance` (float, whole units, e.g. 1.5) and `asset` (str, e.g. "ETH",
        "BNB", "CELO" — the actual name of the native asset on the wallet's current network).
    """
    print("Running get_eth_balance")
    _, chain_id, _ = load_network_config(chat_id)
    return {
        "balance": _get_native_balance(chat_id),
        "asset": get_native_asset_ticker(chain_id),
    }


@tool
def send_eth(
    chat_id: int, session_key_ciphertext: str, recipient: str, amount_eth: float
):
    """
    Sends the chain's native gas asset (ETH on Ethereum/Sepolia/Anvil, BNB on BSC, CELO on
    Celo) to a named contact using the native-asset session key. This works identically on
    every supported network — "eth" in the tool/parameter names is a generic internal label,
    not a claim that the network is Ethereum. Never refuse this request just because the
    network isn't Ethereum; call get_native_asset first if you need the correct name for
    your response.

    Use this tool when the user wants to send their native asset (ETH, BNB, etc.) to someone.
    The recipient must already be saved as a contact — if they are not, call save_contact first.
    Retrieve the session key by calling get_session_keys("eth").
    Specify the amount in whole native-asset units (e.g. 1.5), not in wei.

    Args:
        chat_id: The Telegram chat ID of the user making the request.
        session_key_ciphertext: Vault ciphertext for the native-asset session key.
                                Obtain by calling get_session_keys("eth").
        recipient: The name of the contact to send to (e.g. "Sandy"). Must be a saved contact.
        amount_eth: The amount of the native asset to send, in whole units (e.g. 1.5). The tool converts this to wei internally before sending the transaction.

    Returns:
        A string summarizing the transaction result, including the transaction hash and status.
    """
    print("Running send_eth")
    recipient_addr = _resolve_contact(chat_id, recipient)
    value = _to_base_units(amount_eth, 18)

    tx_hash, receipt = send_user_op_as_session(
        chat_id=chat_id,
        key_ciphertext=session_key_ciphertext,
        target=recipient_addr,
        value=value,
        data=b"",
    )

    if receipt["status"] != 1:
        raise ToolException(f"UserOp failed! tx: {tx_hash.hex()}")
    return f"Tx hash: `{tx_hash.hex()}`, Status: {receipt['status']}"


@tool
def get_session_keys(chat_id: int, token: str) -> tuple[str, str]:
    """
    Returns the session key address and Vault ciphertext for a given user and token.

    Use this tool before any on-chain write operation (transfer, approve, transferFrom)
    to retrieve the session credentials for the specified token. The returned ciphertext
    must be passed directly to the transaction tool — never expose it to the user in
    your response.

    Args:
        chat_id: The Telegram chat ID of the user making the request.
        token: The session target. A token ticker (e.g. "usdc") for ERC20 operations,
               "uniswapv2_router" for any swap or liquidity operation, "eth" for native
               ETH/BNB transfers, or "reputation_registry" for posting ERC-8004 feedback.

    Returns:
        A tuple of (session_key_address, session_key_ciphertext). Pass the ciphertext
        to the relevant transaction tool. Do not include it in any message to the user.
    """
    print("Running get_session_keys")

    # The account now authorizes ONE bare session key for the whole wallet (allowedSession
    # allowlist) rather than per-target scoped keys — every token/router/registry operation
    # signs with the same key, bounded by the wallet's global USD spending cap. The `token`
    # parameter is kept for tool-API compatibility but no longer selects a different key.
    wallet_address = load_session_handler(chat_id).address
    return get_or_create_session_key(chat_id, wallet_address)


@tool
def check_session_validity(chat_id: int, token: str) -> bool:
    """
    Checks if a session key for a given token is still valid.

    Use this tool to verify whether the session key associated with the specified
    token is active and can be used for transactions. This is useful for ensuring
    that the user has a valid session before attempting to send tokens.

    Args:
        chat_id: The Telegram chat ID of the user making the request.
        token: The token ticker symbol to check the session for (e.g. "usdc").

    Returns:
        True if the session key is valid and active, False otherwise.
    """
    print("Running check_session_validity")
    session_key, _ = get_session_keys.func(chat_id, token)
    session_handler = load_session_handler(chat_id)
    return session_handler.functions.allowedSession(session_key).call()


@tool
def check_remaining_budget(chat_id: int) -> float:
    """
    Returns the wallet's remaining USD spending budget for the current window.

    The wallet has a single USD spending cap per rolling window, shared across every token and
    venue (there is no per-token budget). Use this when the user asks how much they can still spend.

    Args:
        chat_id: The Telegram chat ID of the user making the request.

    Returns:
        The remaining budget in whole USD units (e.g. 500.0 for $500 remaining this window).
    """
    print("Running check_remaining_budget")
    session_handler = load_session_handler(chat_id)
    budget = session_handler.functions.getRemainingBudget().call()
    return budget / WEI_PER_ETH


@tool
def check_spending_within_budget(chat_id: int, token: str, amount: int) -> bool:
    """
    Checks whether spending `amount` of `token` fits within the wallet's remaining USD budget for
    the current window.

    The comparison is done in USD: the token amount is priced via the oracle and compared against
    the single wallet-wide remaining budget. Native value (ETH/BNB) is metered too — pass "eth"/"bnb"
    to check a native send. For a swap, pass the token being SOLD (the value leaving the wallet) —
    this is a conservative upper bound, since a swap is actually charged only its NET portfolio value
    change, not the gross input.

    Args:
        chat_id: The Telegram chat ID of the user making the request.
        token: The token ticker symbol used to price the amount (e.g. "usdc", or "eth"/"bnb" for native).
        amount: The proposed amount in whole token units (e.g. 100 for 100 USDC).

    Returns:
        True if the USD value of the amount is within the remaining budget, False otherwise.
    """
    print("Running check_spending_within_budget")
    session_handler = load_session_handler(chat_id)

    # The cap is wallet-wide net-value metering: convert the amount to USD via the oracle and
    # compare against the remaining window budget. Native value (ETH/BNB) is metered too, so it is
    # priced through the address(0) sentinel; watched ERC20s are priced by their token address.
    # (A swap's real charge is its NET value change, so pricing the gross amount here is a
    # conservative upper bound for the check.)
    if token.lower() in ("eth", "bnb"):
        token_address = ETH_SENTINEL
        base_units = _to_base_units(amount, 18)
    else:
        erc20 = load_ierc20(chat_id=chat_id, token=token)
        token_address = erc20.address
        base_units = _to_base_units(amount, erc20.functions.decimals().call())
    usd_value = session_handler.functions.getUsdValue(token_address, base_units).call()
    remaining = session_handler.functions.getRemainingBudget().call()
    return usd_value <= remaining


@tool
def get_price(chat_id: int, token: str) -> float:
    """
    Retrieves the current USD price of a token by querying the registered SHOracle.

    Use this tool when the user asks what a token is currently worth, or when you need
    to estimate the USD value of an amount before sending it. NEVER use this to estimate
    swap output quantities — use get_quote_in or get_quote_out, which query live pool reserves.

    Args:
        chat_id: The Telegram chat ID of the user making the request.
        token: The token ticker symbol to price (e.g. "usdc", "eth").

    Returns:
        The current USD price as a float (e.g. 2500.0 for ETH at $2500).
    """
    print("Running get_price")

    if token.lower() in ("eth", "bnb"):
        token_address = ETH_SENTINEL
        decimals = 18
    else:
        erc20 = load_ierc20(chat_id=chat_id, token=token)
        token_address = erc20.address
        decimals = erc20.functions.decimals().call()
    print(f"Getting price for token: {token}, address: {token_address}")
    session_handler = load_session_handler(chat_id)
    # getUsdValue(token, one whole token) returns the unit price with 18 decimals.
    usd_value = session_handler.functions.getUsdValue(token_address, 10**decimals).call()
    return usd_value / WEI_PER_ETH


@tool
def get_usd_value(chat_id: int, token: str, amount: float) -> float:
    """
    Converts a token amount to its current USD value using the registered SHOracle.

    Use this tool when confirming a transfer, approval, or transferFrom with the user or when the user asks for the USD value an amount of a token.
    Always call this before presenting the confirmation message so the user can see
    the USD equivalent of what they are about to send or approve.

    Args:
        chat_id: The Telegram chat ID of the user making the request.
        token: The token ticker symbol (e.g. "usdc", "dai").
        amount: The token amount in whole units (e.g. 100 for 100 USDC).

    Returns:
        The USD value of the amount as a float (e.g. 99.5 for 100 USDC at $0.995).
    """
    print("Running get_usd_value")
    price = get_price.func(chat_id, token)
    return price * amount


@tool
def preflight_check(chat_id: int, token: str, amount: float) -> dict:
    """
    Runs all pre-transaction checks in one call: session validity, budget check, and USD value.
    Call this instead of check_session_validity, check_spending_within_budget, and get_usd_value
    separately before any on-chain action. It applies to every operation — plain transfers and
    swaps alike — because the wallet has a single session key and a single USD spending cap.

    Args:
        chat_id: The Telegram chat ID of the user making the request.
        token: The token ticker to price for the budget check (e.g. "usdc"). For a swap, pass the
               token being SOLD (the value leaving the wallet). Pass "eth"/"bnb" for a native send —
               native value is metered against the cap too, so it is priced and budget-checked like
               any other spend.
        amount: The proposed amount in whole token units (e.g. 100 for 100 USDC).

    Returns:
        A dict with:
          - "session_active" (bool): True if the wallet's session key is authorized.
          - "within_budget" (bool): True if the amount fits the remaining USD budget.
          - "usd_value" (float): The USD equivalent of `amount` at the current price.
        If "session_active" is False, abort and notify the user. If "within_budget" is False,
        abort and notify the user. Only proceed if both are True.
    """
    print("Running preflight_check")
    session_key, _ = get_session_keys.func(chat_id, token)
    session_handler = load_session_handler(chat_id)

    session_active = session_handler.functions.allowedSession(session_key).call()

    usd_value = get_price.func(chat_id, token) * amount
    remaining = session_handler.functions.getRemainingBudget().call() / WEI_PER_ETH

    # Native value (ETH/BNB) is metered against the cap just like watched ERC20s — get_price prices
    # it through the address(0) sentinel — so every spend is compared in USD against the wallet-wide
    # remaining window budget. Gross value is a conservative bound: swaps are actually charged only
    # their NET portfolio value change on-chain.
    within_budget = usd_value <= remaining

    return {
        "session_active": session_active,
        "within_budget": within_budget,
        "usd_value": usd_value,
    }


@tool
def get_erc20_balance(chat_id: int, token: str) -> float:
    """
    Retrieves the ERC20 token balance of the smart wallet contract.

    Use this tool when the user asks about their own wallet's token balance
    (e.g. "my balance", "how much USDC do I have"). Do NOT use this to check
    a contact's balance — use get_contact_erc20_balance for that.

    Args:
        chat_id: The Telegram chat ID of the user making the request.
        token: The token ticker symbol to check (e.g. "usdc").

    Returns:
        The smart wallet's token balance in whole units (e.g. 100.0 for 100 USDC).
    """
    print("Running get_erc20_balance")
    address = load_session_handler(chat_id).address
    return get_erc20_tools(chat_id)["get_balance"].invoke(
        {"token": token, "owner": address}
    )["amount"]


@tool
def get_contact_erc20_balance(chat_id: int, contact_name: str, token: str) -> float:
    """
    Retrieves the ERC20 token balance of a saved contact's address.

    Use this tool when the user asks about a contact's token balance
    (e.g. "how much USDC does Sandy have?", "what is Alice's LINK balance?").
    Do NOT use this to check the smart wallet's own balance — use get_erc20_balance for that.

    Args:
        chat_id: The Telegram chat ID of the user making the request.
        contact_name: The name of the saved contact (e.g. "Sandy"). Case-insensitive.
        token: The token ticker symbol to check (e.g. "usdc").

    Returns:
        The contact's token balance in whole units (e.g. 100.0 for 100 USDC).
    """
    print("Running get_contact_erc20_balance")
    address = _resolve_contact(chat_id, contact_name, role="account to check")
    return get_erc20_tools(chat_id)["get_balance"].invoke(
        {"token": token, "owner": address}
    )["amount"]


@tool
def get_erc20_allowance(chat_id: int, token: str, spender: str) -> float:
    """
    Retrieves the smart wallet's ERC20 token allowance for a specified spender.

    Use this tool when the user wants to check how many tokens the wallet has approved for a
    particular spender. NOTE: this wallet almost always returns 0. Its spending-limit module
    forbids standing allowances — approvals are only ever granted and consumed within a single
    transaction (inside swaps/liquidity), so nothing remains approved afterwards. A non-zero
    result would be unusual.

    Args:
        token: The token ticker symbol to check (e.g. "usdc").
        spender: The name of the contact who is the spender (e.g. "Sandy"). Must be a saved contact.

    Returns:
        The token allowance approved for the spender in whole units (typically 0.0 by design).
    """
    print("Running get_erc20_allowance")
    address = load_session_handler(chat_id).address
    spender_addr = _resolve_contact(chat_id, spender, role="spender")
    return get_erc20_tools(chat_id)["get_allowance"].invoke(
        {"token": token, "owner": address, "spender": spender_addr}
    )["amount"]


@tool
def wrap_eth(chat_id: int, session_key_ciphertext: str, amount_eth: float):
    """
    Wraps native ETH/BNB into the chain's wrapped-native token (WETH on Ethereum, WBNB on
    BSC) by calling deposit() on that contract.

    Use this tool when the user wants to convert native ETH/BNB to its wrapped form. This
    does not go through the router — it is a direct 1:1 wrap. Retrieve the session key by
    calling get_session_keys() with the chain's wrapped-native ticker (e.g. "weth" on
    Ethereum, "wbnb" on BSC).

    Args:
        chat_id: The Telegram chat ID of the user making the request.
        session_key_ciphertext: The Vault ciphertext for the session key authorized
                                for the chain's wrapped-native contract. Obtain via
                                get_session_keys() with that chain's wrapped-native ticker.
        amount_eth: The amount of native ETH/BNB to wrap, in whole units (e.g. 1.5).
                    The tool converts this to wei internally before sending the transaction.

    Returns:
        A string summarizing the transaction result, including the transaction hash and status.
    """
    print("Running wrap_eth")
    plan = get_erc20_tools(chat_id)["wrap_native"].invoke(
        {
            "from_address": load_session_handler(chat_id).address,
            # str, not float: the package parses amounts as Decimal, and a float cannot
            # represent 18 decimal places exactly.
            "amount": str(amount_eth),
        }
    )
    tx_hash, receipt = _submit_plan(chat_id, session_key_ciphertext, plan)
    return f"Tx hash: `{tx_hash.hex()}`, Status: {receipt['status']}"


@tool
def transfer_erc20(
    chat_id: int, session_key_ciphertext: str, token: str, recipient: str, amount: float
):
    """
    Transfers ERC20 tokens to a named contact using a session key.

    Use this tool when the user wants to send tokens to someone. The recipient must
    already be saved as a contact — if they are not, call save_contact first. The
    session_key_ciphertext must match the token being sent — retrieve it by calling
    get_session_keys with the token ticker. Specify the amount in whole token units
    (e.g. 100 for 100 USDC), not in raw base units.

    Args:
        chat_id: The Telegram chat ID of the user making the request.
        session_key_ciphertext: The Vault ciphertext for the session key authorized
                                for this token. Obtain by calling get_session_keys(token).
        token: The token ticker symbol to transfer (e.g. "usdc").
        recipient: The name of the contact to send tokens to (e.g. "Sandy").
                   Must be a saved contact.
        amount: The amount of tokens to send in whole units (e.g. 100 for 100 USDC).

    Returns: A string summarizing the transaction result, including the transaction hash and status.
    """
    print("Running transfer_erc20")
    recipient_addr = _resolve_contact(chat_id, recipient)
    plan = get_erc20_tools(chat_id)["transfer"].invoke(
        {
            "token": token,
            "to": recipient_addr,
            "from_address": load_session_handler(chat_id).address,
            "amount": str(amount),
        }
    )
    tx_hash, receipt = _submit_plan(chat_id, session_key_ciphertext, plan)
    return f"Tx hash: `{tx_hash.hex()}`, Status: {receipt['status']}"


@tool
def transferFrom_erc20(
    chat_id: int,
    session_key_ciphertext: str,
    token: str,
    sender: str,
    recipient: str,
    amount: float,
):
    """
    Transfers ERC20 tokens from a sender to a recipient.

    Use this tool when the user wants to transfer tokens from another address (sender)
    to a recipient. The sender and recipient must already be saved as contacts — if they
    are not, call save_contact first. The session_key_ciphertext must match the token being
    transferred — retrieve it by calling get_session_keys with the token ticker. Specify the
    amount in whole token units (e.g. 100 for 100 USDC), not in raw base units.

    Args:
        chat_id: The Telegram chat ID of the user making the request.
        session_key_ciphertext: The Vault ciphertext for the session key authorized
                                for this token. Obtain by calling get_session_keys(token).
        token: The token ticker symbol to transfer (e.g. "usdc").
        sender: The name of the contact who is the sender of the tokens (e.g. "Sandy"). Must be a saved contact.
        recipient: The name of the contact who is the recipient of the tokens (e.g. "Alex"). Must be a
                   saved contact. Exception: if the user names themselves or the wallet as the
                   recipient (e.g. "to me", "to my wallet"), pass the literal string "me".
        amount: The amount of tokens to transfer in whole units (e.g. 100 for 100 USDC).

    Returns: A string summarizing the transaction result, including the transaction hash and status.
    """

    print("Running transferFrom_erc20")
    wallet = load_session_handler(chat_id).address
    sender_addr = _resolve_contact(chat_id, sender, role="sender")
    # _resolve_contact maps "me" to the wallet, which is this tool's documented convention
    # for the user naming themselves as the recipient.
    recipient_addr = _resolve_contact(chat_id, recipient)

    plan = get_erc20_tools(chat_id)["transfer_from"].invoke(
        {
            "token": token,
            "owner": sender_addr,
            "to": recipient_addr,
            "from_address": wallet,
            "amount": str(amount),
        }
    )
    tx_hash, receipt = _submit_plan(chat_id, session_key_ciphertext, plan)
    return f"Tx hash: `{tx_hash.hex()}`, Status: {receipt['status']}"


"""
 /*//////////////////////////////////////////////////////////////
                        UNISWAP_V2 TOOLS
//////////////////////////////////////////////////////////////*/
"""


@tool
def get_quote_in(
    chat_id: int, token_in: str, token_out: str, amount_out: float
) -> dict:
    """
    Returns how much of token_in is required to receive an exact amount of token_out,
    using the Uniswap V2 router's getAmountsIn. Routes through the chain's wrapped-native token
    (WETH on Ethereum, WBNB on BSC) when neither token is the wrapped-native token.

    Use this tool when the user wants to know the cost of acquiring a specific amount of a token
    (e.g. "How much USDC do I need to buy exactly 100 DAI?"). Call this before a swap to give
    the user a price preview. The returned dict can also be passed directly to Uniswap swap tools:
    use amount_in for the swap's amount argument and amount_in_base for slippage calculations.

    Args:
        chat_id: The Telegram chat ID of the user making the request.
        token_in: The ticker of the token being spent (e.g. "usdc").
        token_out: The ticker of the token being received (e.g. "dai").
        amount_out: The exact amount of token_out to receive, in whole units (e.g. 100 for 100 DAI).

    Returns:
        A dict with:
          - amount_in (float): required token_in in whole units (e.g. 101.5 for 101.5 USDC)
          - amount_out (float): the requested token_out amount in whole units
          - path (list[str]): the token address path used for the quote

        When presenting to the user, show only amount_in and amount_out. Never expose path.
    """
    print("Running get_quote_in")
    return get_uniswap_tools(chat_id)["get_quote_in"].invoke(
        {
            "token_in": _resolve(chat_id, token_in),
            "token_out": _resolve(chat_id, token_out),
            "amount_out": amount_out,
        }
    )


@tool
def get_quote_out(
    chat_id: int, token_in: str, token_out: str, amount_in: float
) -> dict:
    """
    Returns how much of token_out will be received when spending an exact amount of token_in,
    using the Uniswap V2 router's getAmountsOut. Routes through the chain's wrapped-native token
    (WETH on Ethereum, WBNB on BSC) when neither token is the wrapped-native token.

    Use this tool when the user wants to know how much they'll receive for a given spend
    (e.g. "How much DAI will I get for 100 USDC?"). Call this before a swap to give
    the user a price preview. The returned dict can also be passed directly to Uniswap swap tools:
    use amount_out for the swap's amount argument and amount_out_base for slippage calculations.

    Args:
        chat_id: The Telegram chat ID of the user making the request.
        token_in: The ticker of the token being spent (e.g. "usdc").
        token_out: The ticker of the token being received (e.g. "dai").
        amount_in: The exact amount of token_in to spend, in whole units (e.g. 100 for 100 USDC).

    Returns:
        A dict with:
          - amount_in (float): the token_in amount in whole units
          - amount_out (float): expected token_out in whole units (e.g. 99.2 for 99.2 DAI)
          - path (list[str]): the token address path used for the quote

        When presenting to the user, show only amount_in and amount_out. Never expose path.
    """
    print("Running get_quote_out")
    return get_uniswap_tools(chat_id)["get_quote_out"].invoke(
        {
            "token_in": _resolve(chat_id, token_in),
            "token_out": _resolve(chat_id, token_out),
            "amount_in": amount_in,
        }
    )


@tool
def get_liquidity_token_balance(
    chat_id: int, token_a: str, token_b: str | None = None
) -> float:
    """
    Retrieves the smart wallet's balance of Uniswap V2 liquidity tokens for a given pair.

    Use this tool when the user wants to check how much liquidity they have provided to a Uniswap V2 pool.
    The tool identifies the correct pair based on the two token tickers and returns the wallet's balance
    of that pair's liquidity tokens in whole units (not base units).

    Args:
        chat_id: The Telegram chat ID of the user making the request.
        token_a: The ticker symbol of the first token in the pair (e.g. "dai").
        token_b: The ticker symbol of the second token in the pair. Defaults to the chain's
                 wrapped-native token (WETH on Ethereum, WBNB on BSC).

    Returns:
        The wallet's balance of liquidity tokens for the specified pair, in whole units (e.g. 10.5).
    """
    print("Running get_liquidity_token_balance")
    if token_b is None:
        _, chain_id, _ = load_network_config(chat_id)
        token_b = get_native_wrapped_ticker(chain_id)
    return get_uniswap_tools(chat_id)["get_liquidity_token_balance"].invoke(
        {
            "owner_address": load_session_handler(chat_id).address,
            "token_a": _resolve(chat_id, token_a),
            "token_b": _resolve(chat_id, token_b),
        }
    )


@tool
def is_derived_input_sufficient(
    chat_id: int,
    token_in: str,
    token_out: str,
    amount_out: float,
    slippage_bps: int = DEFAULT_SLIPPAGE_BPS,
) -> dict[bool, float]:
    """
    Checks if the user has sufficient funds to execute a swap based on a quote and slippage tolerance.

    Use this function before attempting a swap to ensure that the user has enough of the input token
    to cover the required amount plus slippage. This is a helper function that can be called after
    get_quote_in or get_quote_out to validate that the swap can proceed.

    Args:
        chat_id: The Telegram chat ID of the user making the request.
        token_in: The ticker of the token being spent (e.g. "usdc").
        token_out: The ticker of the token being received (e.g. "dai").
        amount_out: The amount of token_out to receive, in whole units (e.g. 100 for 100 DAI).
        slippage_bps: The acceptable slippage in basis points (e.g. 50 for 0.5% slippage).
    Returns:
        A dict with:
          - is_sufficient (bool): True if the user has sufficient funds to cover the swap including slippage, False otherwise.
          - derived_input (float): The amount of the input token required to cover the swap including slippage.
    """
    print("Running is_derived_input_sufficient")
    wallet = load_session_handler(chat_id).address
    tools = get_uniswap_tools(chat_id)

    # Paying in the native asset is a different balance check (the wallet's ETH/BNB, not an
    # ERC20 holding), so it has its own tool in the package.
    if token_in.lower() == "eth":
        result = tools["is_derived_native_input_sufficient"].invoke(
            {
                "token_out": _resolve(chat_id, token_out),
                "amount_out": amount_out,
                "owner_address": wallet,
                "slippage_bps": slippage_bps,
            }
        )
    else:
        result = tools["is_derived_token_input_sufficient"].invoke(
            {
                "token_in": _resolve(chat_id, token_in),
                "token_out": _resolve(chat_id, token_out),
                "amount_out": amount_out,
                "owner_address": wallet,
                "slippage_bps": slippage_bps,
            }
        )

    return {
        "is_sufficient": result["is_sufficient"],
        "derived_input": result["required_input"],
    }


@tool
def is_exact_input_sufficient(chat_id: int, token_in: str, amount_in: float) -> bool:
    """
    Checks if the user has sufficient funds to execute a swap based on an exact input quote.

    Use this function before attempting a swap to ensure that the user has enough of the input token
    to cover the required amount without considering slippage.

    Args:
        chat_id: The Telegram chat ID of the user making the request.
        token_in: The ticker of the token being spent (e.g. "usdc").
        amount_in: The amount of token_in to spend, in whole units (e.g. 100 for 100 USDC).

    Returns:
        True if the user has sufficient funds to cover the swap without slippage, False otherwise.
    """
    print("Running is_exact_input_sufficient")
    wallet = load_session_handler(chat_id).address
    tools = get_uniswap_tools(chat_id)

    if token_in.lower() == "eth":
        return tools["is_native_balance_sufficient"].invoke(
            {"amount": amount_in, "owner_address": wallet}
        )
    return tools["is_token_balance_sufficient"].invoke(
        {
            "token_address": _resolve(chat_id, token_in),
            "amount": amount_in,
            "owner_address": wallet,
        }
    )


@tool
def is_liquidity_sufficient(
    chat_id: int, token_a: str, amount_a: float, token_b: str
) -> dict[bool, float]:
    """
    Checks whether the wallet holds enough of both tokens to add liquidity to a Uniswap V2 pool.

    Derives the required token_b amount from live pool reserves via get_pool_quote internally —
    no need to pre-compute it. Pass "eth" as token_b when the pool pairs an ERC20 with native
    ETH/BNB (i.e. for add_liquidity_eth); the function maps "eth" to the chain's wrapped-native
    ticker (WETH on Ethereum, WBNB on BSC) for the reserve lookup and checks the native balance
    accordingly.

    Args:
        chat_id: The Telegram chat ID of the user making the request.
        token_a: The ticker of the first token (e.g. "dai").
        amount_a: The desired token_a deposit amount in whole units.
        token_b: The ticker of the second token (e.g. "weth" on Ethereum, "wbnb" on BSC), or
                 "eth" for native ETH/BNB.

    Returns:
        A dict with:
          - is_sufficient (bool): True if the wallet holds enough of both tokens, False otherwise.
          - amount_b (float): The proportional token_b amount required, in whole units.
    """
    print("Running is_liquidity_sufficient")
    wallet = load_session_handler(chat_id).address
    tools = get_uniswap_tools(chat_id)

    # Pairing against the raw native asset checks the wallet's ETH/BNB balance rather than a
    # wrapped-native ERC20 holding, so the package splits it into a separate tool.
    if token_b.lower() == "eth":
        result = tools["is_liquidity_sufficient_eth"].invoke(
            {
                "token": _resolve(chat_id, token_a),
                "amount_token": amount_a,
                "owner_address": wallet,
            }
        )
        return {
            "is_sufficient": result["is_sufficient"],
            "amount_b": result["required_native"],
        }

    result = tools["is_liquidity_sufficient"].invoke(
        {
            "token_a": _resolve(chat_id, token_a),
            "amount_a": amount_a,
            "token_b": _resolve(chat_id, token_b),
            "owner_address": wallet,
        }
    )
    return {"is_sufficient": result["is_sufficient"], "amount_b": result["required_b"]}


@tool
def is_liquidity_removal_sufficient(
    chat_id: int, token_a: str, token_b: str, lp_amount: float
) -> bool:
    """
    Checks whether the wallet holds enough LP tokens to remove liquidity from a Uniswap V2 pool.


    Args:
        chat_id: The Telegram chat ID of the user making the request.
        token_a: The ticker of the first token in the pair (e.g. "dai").
        token_b: The ticker of the second token in the pair (e.g. "weth" on Ethereum, "wbnb" on BSC).
        lp_amount: The amount of LP tokens to burn, in whole units (e.g. 0.5).

    Returns:
        True if the wallet holds enough LP tokens to burn, False otherwise.
    """
    print("Running is_liquidity_removal_sufficient")
    return get_uniswap_tools(chat_id)["is_liquidity_removal_sufficient"].invoke(
        {
            "token_a": _resolve(chat_id, token_a),
            "token_b": _resolve(chat_id, token_b),
            "lp_amount": lp_amount,
            "owner_address": load_session_handler(chat_id).address,
        }
    )


@tool
def get_pool_quote(chat_id: int, token_a: str, token_b: str, amount_a: float) -> dict:
    """
    Returns the proportional token_b amount required to match a given token_a deposit in a
    Uniswap V2 pool, using live pool reserves and router.quote().

    Use this tool when the user wants to preview how much of the second token they need to
    provide before adding liquidity (e.g. "How much ETH do I need to pair with 2500 DAI?").
    For native-paired pools, pass token_b as the chain's wrapped-native ticker ("weth" on
    Ethereum, "wbnb" on BSC). add_liquidity derives this amount itself, so this tool is for
    previewing only.

    Args:
        chat_id: The Telegram chat ID of the user making the request.
        token_a: The ticker of the first token (e.g. "dai").
        token_b: The ticker of the second token (e.g. "weth" on Ethereum, "wbnb" on BSC).
        amount_a: The amount of token_a to deposit, in whole units (e.g. 2500 for 2500 DAI).

    Returns:
        A dict with:
          - amount_a (float): token_a deposit in whole units
          - amount_b_desired (float): required token_b in whole units
    """
    print("Running get_pool_quote")
    return get_uniswap_tools(chat_id)["get_pool_quote"].invoke(
        {
            "token_a": _resolve(chat_id, token_a),
            "token_b": _resolve(chat_id, token_b),
            "amount_a": amount_a,
        }
    )


@tool
def get_lp_amounts(chat_id: int, token_a: str, token_b: str, lp_amount: float) -> dict:
    """
    Returns the expected token amounts redeemable by burning a given amount of Uniswap V2 LP
    tokens, derived from live reserves using the proportional share formula
    (liquidity × reserve / totalSupply).

    Use this tool when the user wants to preview how much they'll receive before removing
    liquidity (e.g. "How much DAI and ETH will I get back for 0.5 LP tokens?"). For native-paired
    pools, pass token_b as the chain's wrapped-native ticker ("weth" on Ethereum, "wbnb" on BSC).
    remove_liquidity derives these amounts itself, so this tool is for previewing only.

    Args:
        chat_id: The Telegram chat ID of the user making the request.
        token_a: The ticker of the first token in the pair (e.g. "dai").
        token_b: The ticker of the second token in the pair (e.g. "weth" on Ethereum, "wbnb" on BSC).
        lp_amount: The amount of LP tokens to burn, in whole units (e.g. 0.5).

    Returns:
        A dict with:
          - expected_a (float): expected token_a return in whole units
          - expected_b (float): expected token_b return in whole units
    """
    print("Running get_lp_amounts")
    return get_uniswap_tools(chat_id)["get_lp_amounts"].invoke(
        {
            "token_a": _resolve(chat_id, token_a),
            "token_b": _resolve(chat_id, token_b),
            "lp_amount": lp_amount,
        }
    )


@tool
def swap_ETH_for_exact_tokens(
    chat_id: int,
    session_key_ciphertext: str,
    token_out: str,
    amount_out: float,
    slippage_bps: int = DEFAULT_SLIPPAGE_BPS,
    recipient: str | None = None,
):
    """
    Swaps the chain's native asset (ETH, BNB, etc.) for an exact amount of an ERC20 token via
    the Uniswap/PancakeSwap V2 router using swapETHForExactTokens. The user specifies how many
    tokens to receive; the router charges however much of the native asset is needed (plus a
    slippage buffer) and refunds any excess. "ETH" in the tool name is a generic internal
    label — this works identically on every supported network.

    Use this tool when the user wants to acquire a specific amount of an ERC20 token by
    spending their native asset. The session key must be authorized for the router. Always
    retrieve it by calling get_session_keys("uniswapv2_router") — the session is scoped
    to the router, not to the output token.

    Args:
        chat_id: The Telegram chat ID of the user making the request.
        session_key_ciphertext: The Vault ciphertext for the session key authorized
                                for the router. Obtain via get_session_keys("uniswapv2_router").
        token_out: The ticker symbol of the ERC20 token to acquire (e.g. "usdc").
        amount_out: The exact amount of token_out to receive, in whole units (e.g. 100 for 100 USDC).
                    The tool converts this to base units internally.
        slippage_bps: Maximum acceptable slippage in basis points (e.g. 50 = 0.5%). Applied as an
                      upward buffer on the native-asset value sent so the swap succeeds even if the
                      price moves slightly. Defaults to 50 bps. Use a higher value for volatile
                      tokens or low-liquidity pools.
        recipient: Optional. The name of a saved contact to receive token_out directly, when the
                   user asks to swap and send in one go. This is delivered by the swap itself —
                   do NOT follow up with transfer_erc20. Must be a saved contact; if they are not
                   saved, call save_contact first. Pass "me" or omit it to keep the output in the
                   wallet.
    Returns: A string summarizing the transaction result, including the transaction hash, status,
             native asset spent, and amount of token_out received.
    """
    print("Running swap_ETH_for_exact_tokens")
    _, chain_id, _ = load_network_config(chat_id)
    native_ticker = get_native_asset_ticker(chain_id)

    plan = get_uniswap_tools(chat_id)["swap_eth_for_exact_tokens"].invoke(
        {
            "token_out": _resolve(chat_id, token_out),
            "amount_out": amount_out,
            "from_address": load_session_handler(chat_id).address,
            "recipient": _resolve_recipient(chat_id, recipient),
            "slippage_bps": slippage_bps,
        }
    )
    tx_hash, receipt = _submit_plan(chat_id, session_key_ciphertext, plan)

    return (
        f"Tx hash: `{tx_hash.hex()}`, Status: {receipt['status']}, "
        f"Max {native_ticker} spent: {plan['summary']['amount_in_max']:.6f}, "
        f"{token_out.upper()} received: {amount_out}"
        f"{_destination_note(recipient)}"
    )


@tool
def swap_exact_tokens_for_tokens(
    chat_id: int,
    session_key_ciphertext: str,
    token_in: str,
    token_out: str,
    amount_in: float,
    slippage_bps: int = DEFAULT_SLIPPAGE_BPS,
    recipient: str | None = None,
):
    """
    Swaps an exact amount of one ERC20 token (including WETH) for another using the Uniswap router.

    Use this tool when the user wants to swap a specific amount of one token for another.
    The session key must be authorized for the Uniswap router. Retrieve it by calling
    get_session_keys("uniswapv2_router") before calling this tool.

    Args:
        chat_id: The Telegram chat ID of the user making the request.
        session_key_ciphertext: The Vault ciphertext for the session key authorized
                                for the Uniswap router. Obtain by calling get_session_keys("uniswapv2_router").
        token_in: The ticker symbol of the ERC20 token to swap from (e.g. "usdc").
        token_out: The ticker symbol of the ERC20 token to acquire (e.g. "dai").
        amount_in: The amount of token_in to swap, in whole units (e.g. 100 for 100 USDC).
                   The tool converts this to base units internally before sending the transaction.
        slippage_bps: Maximum acceptable slippage in basis points (e.g. 50 = 0.5%). The tool
                      queries getAmountsOut to find the expected output and sets amountOutMin
                      accordingly. Defaults to 50 bps. Use a higher value (e.g. 100–300) for
                      volatile tokens or low-liquidity pools.
        recipient: Optional. The name of a saved contact to receive token_out directly, when the
                   user asks to swap and send in one go (e.g. "swap 1 ETH for USDC and send it to
                   Sandy"). This is delivered by the swap itself — do NOT follow up with
                   transfer_erc20. Must be a saved contact; if they are not saved, call
                   save_contact first. Pass "me" or omit it to keep the output in the wallet.
    Returns: A string summarizing the transaction result, including the transaction hash, status,
             amount of token_in spent, and amount of token_out received.
    """
    print("Running swap_exact_tokens_for_tokens")
    plan = get_uniswap_tools(chat_id)["swap_exact_tokens_for_tokens"].invoke(
        {
            "token_in": _resolve(chat_id, token_in),
            "token_out": _resolve(chat_id, token_out),
            "amount_in": amount_in,
            "from_address": load_session_handler(chat_id).address,
            "recipient": _resolve_recipient(chat_id, recipient),
            "slippage_bps": slippage_bps,
        }
    )
    tx_hash, receipt = _submit_plan(chat_id, session_key_ciphertext, plan)

    return (
        f"Tx hash: `{tx_hash.hex()}`, Status: {receipt['status']}, "
        f"{token_in.upper()} spent: {amount_in}, "
        f"Min {token_out.upper()} received: {plan['summary']['amount_out_min']:.6f}"
        f"{_destination_note(recipient)}"
    )


@tool
def swap_tokens_for_exact_tokens(
    chat_id: int,
    session_key_ciphertext: str,
    token_in: str,
    token_out: str,
    amount_out: float,
    slippage_bps: int = DEFAULT_SLIPPAGE_BPS,
    recipient: str | None = None,
):
    """
    Swaps an amount of one ERC20 token (including WETH) for an exact amount of another using the Uniswap router.

    Use this tool when the user wants to acquire a specific amount of one token by swapping another.
    The session key must be authorized for the Uniswap router. Retrieve it by calling
    get_session_keys("uniswapv2_router") before calling this tool.

    Args:
        chat_id: The Telegram chat ID of the user making the request.
        session_key_ciphertext: The Vault ciphertext for the session key authorized
                                for the Uniswap router. Obtain by calling get_session_keys("uniswapv2_router").
        token_in: The ticker symbol of the ERC20 token to swap from (e.g. "usdc").
        token_out: The ticker symbol of the ERC20 token to acquire (e.g. "dai").
        amount_out: The exact amount of token_out to acquire, in whole units (e.g. 100 for 100 DAI).
                    The tool converts this to base units internally before sending the transaction.
        slippage_bps: Maximum acceptable slippage in basis points (e.g. 50 = 0.5%). The tool
                      queries getAmountsIn to find the expected input cost and sets amountInMax
                      accordingly. Defaults to 50 bps. Use a higher value (e.g. 100–300) for
                      volatile tokens or low-liquidity pools.
        recipient: Optional. The name of a saved contact to receive token_out directly, when the
                   user asks to swap and send in one go. This is delivered by the swap itself —
                   do NOT follow up with transfer_erc20. Must be a saved contact; if they are not
                   saved, call save_contact first. Pass "me" or omit it to keep the output in the
                   wallet.
    Returns: A string summarizing the transaction result, including the transaction hash, status,
             amount of token_in spent, and amount of token_out received.
    """
    print("Running swap_tokens_for_exact_tokens")
    plan = get_uniswap_tools(chat_id)["swap_tokens_for_exact_tokens"].invoke(
        {
            "token_in": _resolve(chat_id, token_in),
            "token_out": _resolve(chat_id, token_out),
            "amount_out": amount_out,
            "from_address": load_session_handler(chat_id).address,
            "recipient": _resolve_recipient(chat_id, recipient),
            "slippage_bps": slippage_bps,
        }
    )
    tx_hash, receipt = _submit_plan(chat_id, session_key_ciphertext, plan)

    return (
        f"Tx hash: `{tx_hash.hex()}`, Status: {receipt['status']}, "
        f"Max {token_in.upper()} spent: {plan['summary']['amount_in_max']:.6f}, "
        f"{token_out.upper()} received: {amount_out}"
        f"{_destination_note(recipient)}"
    )


@tool
def swap_exact_tokens_for_ETH(
    chat_id: int,
    session_key_ciphertext: str,
    token_in: str,
    amount_in: float,
    slippage_bps: int = DEFAULT_SLIPPAGE_BPS,
    recipient: str | None = None,
):
    """
    Swaps an exact amount of an ERC20 token for the chain's native asset (ETH, BNB, etc.) via
    the Uniswap/PancakeSwap V2 router using swapExactTokensForETH. The user specifies how much
    of token_in to sell; they receive however much of the native asset the pool gives back
    (minus slippage). "ETH" in the tool name is a generic internal label — this works
    identically on every supported network.

    Use this tool when the user wants to sell a specific amount of an ERC20 token
    and receive their native asset in return. The session key must be authorized for the
    router. Always retrieve it by calling get_session_keys("uniswapv2_router")
    before calling this tool.

    Args:
        chat_id: The Telegram chat ID of the user making the request.
        session_key_ciphertext: The Vault ciphertext for the session key authorized
                                for the router. Obtain via get_session_keys("uniswapv2_router").
        token_in: The ticker symbol of the ERC20 token to sell (e.g. "usdc", "dai").
        amount_in: The exact amount of token_in to sell, in whole units (e.g. 100 for 100 USDC).
                   The tool converts this to base units internally.
        slippage_bps: Maximum acceptable slippage in basis points (e.g. 50 = 0.5%). The tool
                      queries getAmountsOut to find the expected native-asset output and sets
                      amountOutMin accordingly. Defaults to 50 bps. Use a higher value for
                      volatile tokens or low-liquidity pools.
        recipient: Optional. The name of a saved contact to receive the native asset directly,
                   when the user asks to swap and send in one go. This is delivered by the swap
                   itself — do NOT follow up with send_eth. Must be a saved contact; if they are
                   not saved, call save_contact first. Pass "me" or omit it to keep the output in
                   the wallet.
    Returns: A string summarizing the transaction result, including the transaction hash, status,
             amount of token_in spent, and native asset received.
    """
    print("Running swap_exact_tokens_for_ETH")
    _, chain_id, _ = load_network_config(chat_id)
    native_ticker = get_native_asset_ticker(chain_id)

    plan = get_uniswap_tools(chat_id)["swap_exact_tokens_for_eth"].invoke(
        {
            "token_in": _resolve(chat_id, token_in),
            "amount_in": amount_in,
            "from_address": load_session_handler(chat_id).address,
            "recipient": _resolve_recipient(chat_id, recipient),
            "slippage_bps": slippage_bps,
        }
    )
    tx_hash, receipt = _submit_plan(chat_id, session_key_ciphertext, plan)

    return (
        f"Tx hash: `{tx_hash.hex()}`, Status: {receipt['status']}, "
        f"{token_in.upper()} spent: {amount_in}, "
        f"Min {native_ticker} received: {plan['summary']['amount_out_min']:.6f}"
        f"{_destination_note(recipient)}"
    )


@tool
def swap_tokens_for_exact_ETH(
    chat_id: int,
    session_key_ciphertext: str,
    token_in: str,
    amount_out_eth: float,
    slippage_bps: int = DEFAULT_SLIPPAGE_BPS,
    recipient: str | None = None,
):
    """
    Swaps however much of an ERC20 token is needed to receive an exact amount of the chain's
    native asset (ETH, BNB, etc.) via the Uniswap/PancakeSwap V2 router using
    swapTokensForExactETH. The user specifies how much of the native asset they want to
    receive; the router spends as much token_in as required (up to amountInMax). "ETH" in the
    tool/parameter names is a generic internal label — this works identically on every
    supported network.

    Use this tool when the user wants to receive a specific amount of their native asset by
    selling an ERC20 token. The session key must be authorized for the router. Always retrieve
    it by calling get_session_keys("uniswapv2_router") before calling this tool.

    Args:
        chat_id: The Telegram chat ID of the user making the request.
        session_key_ciphertext: The Vault ciphertext for the session key authorized
                                for the router. Obtain via get_session_keys("uniswapv2_router").
        token_in: The ticker symbol of the ERC20 token to sell (e.g. "usdc", "dai").
        amount_out_eth: The exact amount of the native asset to receive, in whole units (e.g. 1.5).
                        The tool converts this to wei internally.
        slippage_bps: Maximum acceptable slippage in basis points (e.g. 50 = 0.5%). Applied as an
                      upward buffer on amountInMax so the swap succeeds even if the price moves
                      slightly. Defaults to 50 bps. Use a higher value for volatile tokens or
                      low-liquidity pools.
        recipient: Optional. The name of a saved contact to receive the native asset directly,
                   when the user asks to swap and send in one go. This is delivered by the swap
                   itself — do NOT follow up with send_eth. Must be a saved contact; if they are
                   not saved, call save_contact first. Pass "me" or omit it to keep the output in
                   the wallet.
    Returns: A string summarizing the transaction result, including the transaction hash, status,
             amount of token_in spent, and native asset received.
    """
    print("Running swap_tokens_for_exact_ETH")
    _, chain_id, _ = load_network_config(chat_id)
    native_ticker = get_native_asset_ticker(chain_id)

    plan = get_uniswap_tools(chat_id)["swap_tokens_for_exact_eth"].invoke(
        {
            "token_in": _resolve(chat_id, token_in),
            "amount_out": amount_out_eth,
            "from_address": load_session_handler(chat_id).address,
            "recipient": _resolve_recipient(chat_id, recipient),
            "slippage_bps": slippage_bps,
        }
    )
    tx_hash, receipt = _submit_plan(chat_id, session_key_ciphertext, plan)

    return (
        f"Tx hash: `{tx_hash.hex()}`, Status: {receipt['status']}, "
        f"Max {token_in.upper()} spent: {plan['summary']['amount_in_max']:.6f}, "
        f"{native_ticker} received: {amount_out_eth}"
        f"{_destination_note(recipient)}"
    )


@tool
def swap_exact_ETH_for_tokens(
    chat_id: int,
    session_key_ciphertext: str,
    token_out: str,
    eth_amount_in: float,
    slippage_bps: int = DEFAULT_SLIPPAGE_BPS,
    recipient: str | None = None,
):
    """
    Swaps an exact amount of the chain's native asset (ETH, BNB, etc.) for an ERC20 token via
    the Uniswap/PancakeSwap V2 router using swapExactETHForTokens. The user specifies how much
    of the native asset to spend; they receive however many tokens the pool gives back (minus
    slippage). "ETH" in the tool/parameter names is a generic internal label — this works
    identically on every supported network.

    Use this tool when the user wants to spend a specific amount of their native asset and
    receive as many tokens as possible in return. The session key must be authorized for the
    router. Always retrieve it by calling get_session_keys("uniswapv2_router") — the
    session is scoped to the router, not to the output token.

    Args:
        chat_id: The Telegram chat ID of the user making the request.
        session_key_ciphertext: The Vault ciphertext for the session key authorized
                                for the router. Obtain via get_session_keys("uniswapv2_router").
        token_out: The ticker symbol of the ERC20 token to receive (e.g. "usdc", "dai").
        eth_amount_in: The exact amount of the native asset to spend, in whole units (e.g. 1.5).
                       The tool converts this to wei internally and forwards it as msg.value.
        slippage_bps: Maximum acceptable slippage in basis points (e.g. 50 = 0.5%). The tool
                      queries getAmountsOut to find the expected token output and sets amountOutMin
                      accordingly. Defaults to 50 bps. Use a higher value for volatile tokens
                      or low-liquidity pools.
        recipient: Optional. The name of a saved contact to receive token_out directly, when the
                   user asks to swap and send in one go (e.g. "swap 1 ETH for USDC and send it to
                   Sandy"). This is delivered by the swap itself — do NOT follow up with
                   transfer_erc20. Must be a saved contact; if they are not saved, call
                   save_contact first. Pass "me" or omit it to keep the output in the wallet.
    Returns: A string summarizing the transaction result, including the transaction hash, status,
             native asset spent, and amount of token_out received.
    """
    print("Running swap_exact_ETH_for_tokens")
    _, chain_id, _ = load_network_config(chat_id)
    native_ticker = get_native_asset_ticker(chain_id)

    plan = get_uniswap_tools(chat_id)["swap_exact_eth_for_tokens"].invoke(
        {
            "token_out": _resolve(chat_id, token_out),
            "amount_in": eth_amount_in,
            "from_address": load_session_handler(chat_id).address,
            "recipient": _resolve_recipient(chat_id, recipient),
            "slippage_bps": slippage_bps,
        }
    )
    tx_hash, receipt = _submit_plan(chat_id, session_key_ciphertext, plan)

    return (
        f"Tx hash: `{tx_hash.hex()}`, Status: {receipt['status']}, "
        f"{native_ticker} spent: {eth_amount_in}, "
        f"Min {token_out.upper()} received: {plan['summary']['amount_out_min']:.6f}"
        f"{_destination_note(recipient)}"
    )


@tool
def add_liquidity(
    chat_id: int,
    session_key_ciphertext: str,
    token_a: str,
    amount_a: float,
    token_b: str | None = None,
    slippage_bps: int = DEFAULT_SLIPPAGE_BPS,
):
    """
    Adds liquidity to a Uniswap V2 pool via addLiquidity. The user specifies token_a and an
    amount; the proportional token_b amount is derived from live pool reserves via router.quote()
    so the deposit always matches the current pool ratio.

    Use this tool when the user wants to provide liquidity to a Uniswap V2 pool. The session
    key must be authorized for the Uniswap router. Retrieve it by calling
    get_session_keys("uniswapv2_router") before calling this tool. Both tokens must already
    have their ERC20 allowance set for the router so it can pull both amounts.

    Args:
        chat_id: The Telegram chat ID of the user making the request.
        session_key_ciphertext: The Vault ciphertext for the session key authorized for the
                                Uniswap router. Obtain via get_session_keys("uniswapv2_router").
        token_a: The ticker symbol of the first token to deposit (e.g. "dai").
        amount_a: The desired amount of token_a to deposit, in whole units (e.g. 2500 for 2500 DAI).
                  The proportional token_b amount is computed from pool reserves automatically.
        token_b: The ticker symbol of the second token to deposit. Defaults to the chain's
                 wrapped-native token (WETH on Ethereum, WBNB on BSC), the standard pairing.
                 Only override if depositing into a non-wrapped-native pair.
        slippage_bps: Maximum acceptable slippage in basis points (e.g. 50 = 0.5%). Applied to
                      both amountAMin and amountBMin. Defaults to 50 bps.

    Returns:
        A string summarizing the transaction result, including the transaction hash and status.
    """
    print("Running add_liquidity")
    if token_b is None:
        _, chain_id, _ = load_network_config(chat_id)
        token_b = get_native_wrapped_ticker(chain_id)

    plan = get_uniswap_tools(chat_id)["add_liquidity"].invoke(
        {
            "token_a": _resolve(chat_id, token_a),
            "token_b": _resolve(chat_id, token_b),
            "amount_a": amount_a,
            "from_address": load_session_handler(chat_id).address,
            "slippage_bps": slippage_bps,
        }
    )
    tx_hash, receipt = _submit_plan(chat_id, session_key_ciphertext, plan)

    summary = plan["summary"]
    return (
        f"Tx hash: `{tx_hash.hex()}`, Status: {receipt['status']}, "
        f"{token_a.upper()} min deposited: {summary['amount_a_min']:.6f}, "
        f"{token_b.upper()} min deposited: {summary['amount_b_min']:.6f}"
    )


@tool
def add_liquidity_eth(
    chat_id: int,
    session_key_ciphertext: str,
    token: str,
    amount_token: float,
    slippage_bps: int = DEFAULT_SLIPPAGE_BPS,
):
    """
    Adds liquidity to a Uniswap/PancakeSwap V2 token/native-asset pool via addLiquidityETH.
    The user specifies the ERC20 token and an amount; the proportional amount of the chain's
    native asset (ETH, BNB, etc.) is derived from live pool reserves via router.quote() so the
    deposit always matches the current pool ratio. The native asset is forwarded directly as
    msg.value — no prior wrapping is required. "ETH" in the tool name is a generic internal
    label — this works identically on every supported network.

    Use this tool when the user wants to add liquidity to a pool using their raw native asset
    (as opposed to the chain's wrapped-native token). The session key must be authorized for
    the router. Retrieve
    it by calling get_session_keys("uniswapv2_router") before calling this tool. The token
    must already have its ERC20 allowance set for the router so it can pull the token amount.

    Args:
        chat_id: The Telegram chat ID of the user making the request.
        session_key_ciphertext: The Vault ciphertext for the session key authorized for the
                                router. Obtain via get_session_keys("uniswapv2_router").
        token: The ticker symbol of the ERC20 token to deposit alongside the native asset (e.g. "dai").
        amount_token: The desired amount of the ERC20 token to deposit, in whole units
                      (e.g. 2500 for 2500 DAI). The proportional native-asset amount is computed
                      from pool reserves automatically.
        slippage_bps: Maximum acceptable slippage in basis points (e.g. 50 = 0.5%). Applied
                      to both amountTokenMin and amountETHMin. Defaults to 50 bps.

    Returns:
        A string summarizing the transaction result, including the transaction hash, status,
        token min deposited, and native asset min deposited.
    """
    print("Running add_liquidity_eth")
    _, chain_id, _ = load_network_config(chat_id)
    native_ticker = get_native_asset_ticker(chain_id)

    plan = get_uniswap_tools(chat_id)["add_liquidity_eth"].invoke(
        {
            "token": _resolve(chat_id, token),
            "amount_token": amount_token,
            "from_address": load_session_handler(chat_id).address,
            "slippage_bps": slippage_bps,
        }
    )
    tx_hash, receipt = _submit_plan(chat_id, session_key_ciphertext, plan)

    summary = plan["summary"]
    return (
        f"Tx hash: `{tx_hash.hex()}`, Status: {receipt['status']}, "
        f"{token.upper()} min deposited: {summary['amount_token_min']:.6f}, "
        f"{native_ticker} min deposited: {summary['amount_eth_min']:.6f}"
    )


@tool
def remove_liquidity(
    chat_id: int,
    session_key_ciphertext: str,
    token_a: str,
    lp_amount: float,
    token_b: str | None = None,
    slippage_bps: int = DEFAULT_SLIPPAGE_BPS,
):
    """
    Removes liquidity from a Uniswap V2 pool via removeLiquidity. The user specifies the
    LP token amount to burn; the expected return amounts for both tokens are derived from
    live pool reserves using the proportional share formula (liquidity * reserve / totalSupply).
    Slippage is applied downward to compute amountAMin and amountBMin.

    Use this tool when the user wants to withdraw liquidity from a Uniswap V2 pool and
    receive both tokens back. Retrieve the session key with get_session_keys (any argument
    resolves to the wallet's single session key). The router approval for the pool's LP token
    is granted and consumed automatically inside this call — no separate approval is needed.

    Note: removing liquidity returns value to the wallet, so it registers as a net inflow and
    costs nothing against the spending cap — no budget check is required, only session validity.

    Args:
        chat_id: The Telegram chat ID of the user making the request.
        session_key_ciphertext: The Vault ciphertext for the wallet's session key.
        token_a: The ticker symbol of the first token in the pair (e.g. "dai").
        lp_amount: The amount of LP tokens to burn, in whole units (e.g. 0.5 for 0.5 LP tokens).
                   The tool converts this to base units using the pair's decimals internally.
        token_b: The ticker symbol of the second token in the pair. Defaults to the chain's
                 wrapped-native token (WETH on Ethereum, WBNB on BSC).
        slippage_bps: Maximum acceptable slippage in basis points (e.g. 50 = 0.5%). Applied
                      as a downward buffer on amountAMin and amountBMin. Defaults to 50 bps.

    Returns:
        A string summarizing the transaction result, including the transaction hash and status.
    """
    print("Running remove_liquidity")
    if token_b is None:
        _, chain_id, _ = load_network_config(chat_id)
        token_b = get_native_wrapped_ticker(chain_id)

    # The plan's approval is on the pair's own LP token, which the oracle does not price. It
    # clears SpendingLimitModule only because the router is a trusted spender (auto-trusted at
    # wallet deploy), and removeLiquidity pulls exactly the approved amount.
    plan = get_uniswap_tools(chat_id)["remove_liquidity"].invoke(
        {
            "token_a": _resolve(chat_id, token_a),
            "token_b": _resolve(chat_id, token_b),
            "lp_amount": lp_amount,
            "from_address": load_session_handler(chat_id).address,
            "slippage_bps": slippage_bps,
        }
    )
    tx_hash, receipt = _submit_plan(chat_id, session_key_ciphertext, plan)

    summary = plan["summary"]
    return (
        f"Tx hash: `{tx_hash.hex()}`, Status: {receipt['status']}, "
        f"Min {token_a.upper()} returned: {summary['amount_a_min']:.6f}, "
        f"Min {token_b.upper()} returned: {summary['amount_b_min']:.6f}"
    )


@tool
def remove_liquidity_eth(
    chat_id: int,
    session_key_ciphertext: str,
    token: str,
    lp_amount: float,
    slippage_bps: int = DEFAULT_SLIPPAGE_BPS,
):
    """
    Removes liquidity from a Uniswap/PancakeSwap V2 token/native-asset pool via
    removeLiquidityETH. The user specifies the ERC20 token and the LP amount to burn; expected
    return amounts for the token and the chain's native asset (ETH, BNB, etc.) are derived
    from live reserves using the proportional share formula (liquidity * reserve /
    totalSupply). Slippage is applied downward to compute amountTokenMin and amountETHMin.
    The router unwraps the wrapped-native share to the raw native asset before sending it back
    to the wallet. "ETH" in the tool/parameter names is a generic internal label — this works
    identically on every supported network.

    Use this tool when the user wants to remove liquidity from a token/native-asset pool and
    receive the ERC20 token and the raw native asset back. Retrieve the session key with
    get_session_keys (any argument resolves to the wallet's single session key). The router
    approval for the pool's LP token is granted and consumed automatically — no separate
    approval is needed.

    Note: removing liquidity returns value to the wallet, so it registers as a net inflow and
    costs nothing against the spending cap — no budget check is required, only session validity.

    Args:
        chat_id: The Telegram chat ID of the user making the request.
        session_key_ciphertext: The Vault ciphertext for the wallet's session key.
        token: The ticker symbol of the ERC20 token in the pair (e.g. "dai"). The other
               side of the pair is always the chain's native asset.
        lp_amount: The amount of LP tokens to burn, in whole units (e.g. 0.5 for 0.5 LP
                   tokens). The tool converts this to base units internally.
        slippage_bps: Maximum acceptable slippage in basis points (e.g. 50 = 0.5%). Applied
                      as a downward buffer on amountTokenMin and amountETHMin. Defaults to 50 bps.

    Returns:
        A string summarizing the transaction result, including the transaction hash and status.
    """
    print("Running remove_liquidity_eth")
    _, chain_id, _ = load_network_config(chat_id)
    native_ticker = get_native_asset_ticker(chain_id)

    plan = get_uniswap_tools(chat_id)["remove_liquidity_eth"].invoke(
        {
            "token": _resolve(chat_id, token),
            "lp_amount": lp_amount,
            "from_address": load_session_handler(chat_id).address,
            "slippage_bps": slippage_bps,
        }
    )
    tx_hash, receipt = _submit_plan(chat_id, session_key_ciphertext, plan)

    summary = plan["summary"]
    return (
        f"Tx hash: `{tx_hash.hex()}`, Status: {receipt['status']}, "
        f"Min {token.upper()} returned: {summary['amount_token_min']:.6f}, "
        f"Min {native_ticker} returned: {summary['amount_eth_min']:.6f}"
    )


"""
 /*//////////////////////////////////////////////////////////////
                       ERC-8004 TOOLS
//////////////////////////////////////////////////////////////*/
"""


def get_agent_id(chat_id: int) -> int:
    """Retrieves the agent's ERC-8004 tokenId directly from the SessionHandler contract."""
    return load_session_handler(chat_id).functions.getAgentId().call()


@tool
def get_agent_identity(chat_id: int) -> dict:
    """
    Looks up this agent's ERC-8004 on-chain identity.

    Returns the token ID and agent card URI if registered, or indicates that the
    agent is not registered. Call this when the user asks about the agent's identity
    or wants to verify on-chain registration.

    Args:
        chat_id: The Telegram chat ID of the user.

    Returns:
        A dict with 'registered' (bool), and if True: 'token_id' (int) and 'card_uri' (str).
    """
    print("Running get_agent_identity")
    registered, agent_id, card_uri = load_session_handler(chat_id).functions.getAgentIdentity().call()
    if registered:
        return {"registered": True, "token_id": agent_id, "card_uri": card_uri}
    return {"registered": False}


@tool
def get_agent_reputation(chat_id: int) -> dict:
    """
    Returns the on-chain reputation score and feedback count for this agent.

    Call this when the user wants to check how the agent is rated.

    Args:
        chat_id: The Telegram chat ID of the user.

    Returns:
        A dict with 'token_id' (int), 'average_score' (float, 0–100), and 'feedback_count' (int).
    """
    print("Running get_agent_reputation")
    agent_id, count, summary_value, summary_value_decimals = load_session_handler(chat_id).functions.getAgentReputation().call()
    average_score = round(summary_value / (10 ** summary_value_decimals), 2) if count > 0 else 0
    return {
        "token_id": agent_id,
        "average_score": average_score,
        "feedback_count": count,
    }


@tool
def post_reputation_feedback(
    chat_id: int, session_key_ciphertext: str, score: int, tags: str
) -> dict:
    """
    Posts on-chain feedback for this agent in the ERC-8004 Reputation Registry.

    Call this when the user wants to rate the agent after an interaction. The score must
    be between 0 and 100. Tags are comma-separated descriptors (e.g. "reliable,fast").
    This is an irreversible on-chain write — always confirm the score and tags with the user
    before calling. Always retrieve the session key by calling
    get_session_keys("reputation_registry") before calling this tool.

    Args:
        chat_id: The Telegram chat ID of the user.
        session_key_ciphertext: Vault ciphertext for the reputation_registry session key.
                                Obtain by calling get_session_keys("reputation_registry").
        score: Rating from 0 (worst) to 100 (best).
        tags: Comma-separated tags describing the interaction (e.g. "reliable,fast").

    Returns:
        A dict with 'tx_hash' (str) and 'status' (int, 1 = success).
    """
    print("Running post_reputation_feedback")

    if score < 0 or score > 100:
        raise ToolException("Score must be between 0 and 100.")

    agent_id = get_agent_id(chat_id)
    reputation_registry = load_reputation_registry(chat_id)

    # score 0-100 → int128 value with valueDecimals=0; tag goes into tag1, tag2 empty
    data = load_calldata(
        instance=reputation_registry,
        fn_name="giveFeedback",
        args=[agent_id, score, 0, tags, "", "", "", b"\x00" * 32],
    )
    tx_hash, receipt = send_user_op_as_session(
        chat_id=chat_id,
        key_ciphertext=session_key_ciphertext,
        target=reputation_registry.address,
        value=int(0),
        data=data,
    )
    if receipt["status"] != 1:
        raise ToolException(f"UserOp failed! tx: {tx_hash.hex()}")
    return {"tx_hash": tx_hash.hex(), "status": receipt["status"]}


def get_tools():
    tools_list = [
        # Database tools
        get_supported_tokens,
        get_all_sessions,
        save_contact,
        get_contact,
        get_all_contacts,
        delete_contact,
        # Blockchain tools
        get_eth_balance,
        get_native_asset,
        send_eth,
        get_session_keys,
        check_session_validity,
        check_remaining_budget,
        check_spending_within_budget,
        preflight_check,
        swap_exact_tokens_for_tokens,
        swap_tokens_for_exact_tokens,
        get_price,
        get_usd_value,
        get_erc20_balance,
        get_contact_erc20_balance,
        get_erc20_allowance,
        wrap_eth,
        is_derived_input_sufficient,
        is_exact_input_sufficient,
        is_liquidity_sufficient,
        is_liquidity_removal_sufficient,
        get_quote_in,
        get_quote_out,
        get_pool_quote,
        get_lp_amounts,
        swap_ETH_for_exact_tokens,
        swap_exact_tokens_for_ETH,
        swap_tokens_for_exact_ETH,
        swap_exact_ETH_for_tokens,
        add_liquidity,
        add_liquidity_eth,
        remove_liquidity,
        remove_liquidity_eth,
        get_liquidity_token_balance,
        transfer_erc20,
        transferFrom_erc20,
        # ERC-8004 tools
        get_agent_identity,
        get_agent_reputation,
        post_reputation_feedback,
    ]

    for t in tools_list:
        t.handle_tool_error = True
    return tools_list
