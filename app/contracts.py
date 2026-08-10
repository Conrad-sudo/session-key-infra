from web3.contract import Contract
from network_config import load_network_config
from db import (
    get_json,
    get_wallet_address,
    get_token_address,
    get_factory_address,
)
from abi import (
    ientry_point,
    ierc20_extended,
    ireputation_registry,
)

_session_handler_cache: dict[int, Contract] = {}
_entry_point_cache: dict[int, Contract] = {}
_erc20_cache: dict[tuple[int, str], Contract] = {}
_sh_factory_cache: dict[int, Contract] = {}
_reputation_registry_cache: dict[int, Contract] = {}
_spending_limit_module_cache: dict[int, Contract] = {}

# ERC-7579 single-call, default-execution-type mode (CALLTYPE_SINGLE = 0x00 in the top byte).
ERC7579_SINGLE_CALL_MODE = b"\x00" * 32

# ERC-7579 batch, default-execution-type mode (CALLTYPE_BATCH = 0x01 in the top byte).
# Batches are how approvals stay legal under SpendingLimitModule's no-standing-approval rule:
# [approve, spend(, approve 0)] must all land in ONE transaction so nothing is left standing.
ERC7579_BATCH_CALL_MODE = b"\x01" + b"\x00" * 31


def invalidate_cache(chat_id: int) -> None:
    """Drop all cached contract instances for chat_id after a redeploy."""
    # Imported here, not at module scope: toolkits.py imports load_session_handler from this
    # module, so a top-level import would be circular.
    from toolkits import invalidate_toolkits

    invalidate_toolkits(chat_id)
    _session_handler_cache.pop(chat_id, None)
    _entry_point_cache.pop(chat_id, None)
    _sh_factory_cache.pop(chat_id, None)
    _reputation_registry_cache.pop(chat_id, None)
    _spending_limit_module_cache.pop(chat_id, None)
    for key in [k for k in _erc20_cache if k[0] == chat_id]:
        del _erc20_cache[key]


def load_session_handler(chat_id: int) -> Contract:
    """
    Loads the SessionHandler contract ABI and binds it to the address stored in the DB
    for the given chat ID.

    @param chat_id  The Telegram chat ID of the user.
    @return         A web3.py Contract instance pointing to the deployed SessionHandler.
    """
    if chat_id not in _session_handler_cache:
        w3, _, _ = load_network_config(chat_id)
        abi = get_json("./out/SessionHandler.sol/SessionHandler.json")["abi"]
        address = get_wallet_address(chat_id)
        _session_handler_cache[chat_id] = w3.eth.contract(address=address, abi=abi)
    return _session_handler_cache[chat_id]


def load_spending_limit_module(chat_id: int) -> Contract:
    """
    Loads the SpendingLimitModule contract ABI, bound to the address the wallet reports
    via its public SH_MODULE getter.

    The module is the ERC-7579 HOOK that enforces the wallet's global USD spending cap
    (net-value metering + no-standing-approvals). It is NOT a validator and holds no session-key
    state — session keys are an allowlist on the SessionHandler account itself
    (allowedSession/addSession), and SessionAdded/SessionRemoved are emitted there. This loader
    is used mainly to read the module's cap config/events.

    @param chat_id  The Telegram chat ID of the user.
    @return         A web3.py Contract instance pointing to the installed SpendingLimitModule.
    """
    if chat_id not in _spending_limit_module_cache:
        w3, _, _ = load_network_config(chat_id)
        abi = get_json("./out/SpendingLimitModule.sol/SpendingLimitModule.json")["abi"]
        address = load_session_handler(chat_id).functions.SH_MODULE().call()
        _spending_limit_module_cache[chat_id] = w3.eth.contract(address=address, abi=abi)
    return _spending_limit_module_cache[chat_id]


def load_entry_point(chat_id: int) -> Contract:
    """
    Loads the EntryPoint contract ABI and binds it to the address stored in the DB.

    @return  A web3.py Contract instance pointing to the deployed EntryPoint.
    """
    if chat_id not in _entry_point_cache:
        w3, _, _ = load_network_config(chat_id)
        abi = ientry_point
        # entryPoint() (lowercase, a function) — SessionHandler inherits this from OZ's
        # Account.sol.
        address = load_session_handler(chat_id).functions.ENTRY_POINT().call()
        _entry_point_cache[chat_id] = w3.eth.contract(address=address, abi=abi)
    return _entry_point_cache[chat_id]


def pack_execution_calldata(target: str, value: int, data: bytes) -> bytes:
    """
    Packs (target, value, data) into the ERC-7579 single-execution calldata expected by
    SessionHandler.execute(bytes32 mode, bytes executionCalldata).

    Mirrors Solidity's abi.encodePacked(target, value, data): a raw 20-byte address,
    followed by a raw 32-byte big-endian value, followed by the inner calldata — no ABI
    offset/length words, unlike a normal abi.encode.

    @param target  Checksummed hex address string (e.g. "0xAbC...").
    @param value   Native ETH value in wei to forward with the inner call.
    @param data    ABI-encoded calldata for the inner call.
    @return        The packed executionCalldata bytes.
    """
    return bytes.fromhex(target[2:]) + value.to_bytes(32, "big") + data


def session_key_nonce_key(module_address: str) -> int:
    """
    Builds the ERC-4337 nonce key used for session-key UserOps.

    SessionHandler (via OZ's AccountERC7579) reads the top 20 bytes of the nonce's 192-bit key
    as a validator-module address. SpendingLimitModule is now a HOOK only — it is never
    installed as a validator — so whatever address the key encodes, the account falls through to
    its own _rawSignatureValidation (owner OR allowedSession signer). Keeping the module-derived
    key preserves nonce continuity for wallets that already submitted ops under it; any key
    value (including 0) validates identically.

    @param module_address  Checksummed hex address of the installed SpendingLimitModule.
    @return                The nonce key to pass as EntryPoint.getNonce's second argument.
    """
    return int(module_address, 16) << 32


def encode_batch_execution_calldata(executions: list[tuple[str, int, bytes]]) -> bytes:
    """
    ABI-encodes an ERC-7579 batch: Execution[] where Execution = (address target, uint256 value,
    bytes callData). This is a normal abi.encode of the struct array (matching OZ's
    ERC7579Utils.encodeBatch/decodeBatch), unlike the single-call packed form.

    @param executions  List of (target_address, value_wei, calldata_bytes) triples.
    @return            The ABI-encoded executionCalldata for ERC7579_BATCH_CALL_MODE.
    """
    from eth_abi import encode

    return encode(["(address,uint256,bytes)[]"], [executions])


def load_ierc20(chat_id: int, token: str) -> Contract:
    """
    Loads an IERC20 Contract instance for the given ticker symbol.

    Only used now for address lookups and decimals() by the oracle-pricing tools; all ERC20
    reads and calldata construction moved to langchain-erc20 (see app/toolkits.py). The
    wrapped-native token needs no special ABI here either -- deposit()/withdraw() are the
    package's wrap_native/unwrap_native.

    @param token  The token ticker symbol to look up (e.g. "usdc", "dai").
    @return       A web3.py Contract instance for the matching token.
    """
    key = (chat_id, token)
    if key not in _erc20_cache:
        w3, chain_id, _ = load_network_config(chat_id)
        address = get_token_address(chain_id, token)
        _erc20_cache[key] = w3.eth.contract(address=address, abi=ierc20_extended)
    return _erc20_cache[key]


def load_factory(chat_id: int) -> Contract:
    """
    Loads the SHFactory contract ABI and binds it to the address stored in the DB
    for the chain the user is connected to.

    @param chat_id  The Telegram chat ID of the user.
    @return         A web3.py Contract instance pointing to the deployed SHFactory.
    """
    if chat_id not in _sh_factory_cache:
        w3, chain_id, _ = load_network_config(chat_id)
        abi = get_json("./out/SHFactory.sol/SHFactory.json")["abi"]
        address = get_factory_address(chain_id)
        _sh_factory_cache[chat_id] = w3.eth.contract(address=address, abi=abi)
    return _sh_factory_cache[chat_id]


def load_calldata(instance: Contract, fn_name: str, args: list) -> bytes:
    """
    ABI-encodes a call to a function and returns the raw calldata bytes.

    @param instance       A bound web3.py  Contract instance.
    @param fn_name         The function name to encode (e.g. "transfer").
    @param args            The positional arguments for the function.
    @return                The ABI-encoded calldata as bytes (without 0x prefix).
    """
    return bytes.fromhex(
        instance.encode_abi(abi_element_identifier=fn_name, args=args)[2:]
    )


def load_reputation_registry(chat_id: int) -> Contract:
    """Loads the ERC-8004 Reputation Registry bound to the correct address for this chain.
    Anvil uses the locally compiled ABI; Sepolia/Mainnet use the canonical artifact."""
    if chat_id not in _reputation_registry_cache:
        w3, _, _ = load_network_config(chat_id)
       
        abi = ireputation_registry
        address = load_session_handler(chat_id).functions.REPUTATION_REGISTRY().call()
        _reputation_registry_cache[chat_id] = w3.eth.contract(address=address, abi=abi)
    return _reputation_registry_cache[chat_id]


