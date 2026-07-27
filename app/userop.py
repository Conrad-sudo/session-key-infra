"""
Shared, submission-agnostic building blocks for the ERC-4337 session-key flow.

Both execution backends -- anvil.py (direct handleOps) and live_network.py (Alchemy
bundler RPC) -- use these identically; only the gas-estimation and submission strategy
differs per backend and stays in those modules. Keeping key management, op construction,
and signing here means there is exactly one place to fix a signing or nonce bug.
"""
import secrets
from dotenv import load_dotenv
from web3.contract import Contract
from network_config import load_network_config
from contracts import (
    load_session_handler,
    load_entry_point,
    load_spending_limit_module,
    pack_execution_calldata,
    encode_batch_execution_calldata,
    session_key_nonce_key,
    ERC7579_SINGLE_CALL_MODE,
    ERC7579_BATCH_CALL_MODE,
)
import db
from vault_signer import encrypt_key, decrypt_key

load_dotenv()


def get_or_create_session_key(chat_id: int, target_address: str) -> tuple[str, str]:
    """
    Returns the session key address and Vault ciphertext for a given user and target.

    On first call for a (chat_id, target_address) pair, generates a cryptographically
    random 32-byte private key, encrypts it via Vault Transit, stores the ciphertext in
    the DB, and wipes the raw key from memory. On subsequent calls, returns the stored
    (address, ciphertext) directly without touching Vault.

    @param chat_id         The Telegram chat ID of the user.
    @param target_address  The contract address the session key is scoped to.
    @return                A tuple of (session_key_address, vault_ciphertext).
    """
    row = db.get_session_key(chat_id, target_address)
    if row:
        return row

    w3, _, _ = load_network_config(chat_id)
    raw_key = secrets.token_bytes(32)
    account = w3.eth.account.from_key(raw_key)
    ciphertext = encrypt_key(raw_key)
    raw_key = b"\x00" * 32
    db.save_session_key(chat_id, target_address, account.address, ciphertext)
    return account.address, ciphertext


def prepare_execute_call(
    chat_id: int, target: str, value: int, data: bytes
) -> tuple[Contract, Contract, str, int]:
    """
    Builds the shared inputs for a session-key UserOp, identical across both backends:
    the bound SessionHandler and EntryPoint contracts, the ABI-encoded
    SessionHandler.execute(mode, executionCalldata) calldata, and a nonce keyed to the
    installed SpendingLimitModule (so the account routes validation to it). The caller
    layers its own gas estimation and submission on top.

    @param chat_id  The Telegram chat ID of the user.
    @param target   The contract address SessionHandler will call.
    @param value    ETH value in wei to forward with the inner call.
    @param data     ABI-encoded inner calldata to execute on the target.
    @return         (session_handler, entry_point, calldata_hex, nonce).
    """
    session_handler = load_session_handler(chat_id=chat_id)
    module = load_spending_limit_module(chat_id=chat_id)

    execution_calldata = pack_execution_calldata(target, value, data)
    calldata = session_handler.encode_abi(
        abi_element_identifier="execute",
        args=[ERC7579_SINGLE_CALL_MODE, execution_calldata],
    )

    entry_point = load_entry_point(chat_id=chat_id)
    nonce = entry_point.functions.getNonce(
        session_handler.address, session_key_nonce_key(module.address)
    ).call()

    return session_handler, entry_point, calldata, nonce


def prepare_execute_batch_call(
    chat_id: int, executions: list[tuple[str, int, bytes]]
) -> tuple[Contract, Contract, str, int]:
    """
    Batch variant of prepare_execute_call: builds SessionHandler.execute(batchMode,
    abi.encode(Execution[])) calldata for several sub-calls that must land atomically in ONE
    transaction — the only way an approval can be granted and consumed without tripping
    SpendingLimitModule's no-standing-approval rule.

    @param chat_id     The Telegram chat ID of the user.
    @param executions  List of (target_address, value_wei, calldata_bytes) triples, in order.
    @return            (session_handler, entry_point, calldata_hex, nonce).
    """
    session_handler = load_session_handler(chat_id=chat_id)
    module = load_spending_limit_module(chat_id=chat_id)

    execution_calldata = encode_batch_execution_calldata(executions)
    calldata = session_handler.encode_abi(
        abi_element_identifier="execute",
        args=[ERC7579_BATCH_CALL_MODE, execution_calldata],
    )

    entry_point = load_entry_point(chat_id=chat_id)
    nonce = entry_point.functions.getNonce(
        session_handler.address, session_key_nonce_key(module.address)
    ).call()

    return session_handler, entry_point, calldata, nonce


def create_signed_user_op(
    chat_id: int, user_op: tuple, entry_point: Contract, key_ciphertext: str
) -> tuple:
    """
    Signs a PackedUserOperation with a session key using EIP-191 message signing.

    Fetches the userOpHash from the EntryPoint, wraps it in the Ethereum signed
    message envelope via encode_defunct (matching toEthSignedMessageHash in
    SessionHandler._rawSignatureValidation, the account's own UserOp signature check —
    the module is not a validator), and returns the op with the signature attached.

    The raw private key is decrypted from Vault transiently and wiped from memory
    immediately after signing.

    @param chat_id        The Telegram chat ID of the user.
    @param user_op        An unsigned PackedUserOperation tuple (empty signature field).
    @param entry_point    Bound EntryPoint contract.
    @param key_ciphertext Vault Transit ciphertext for the session key ('vault:v1:...').
    @return               A signed PackedUserOperation tuple ready for submission.
    """
    from eth_account.messages import encode_defunct

    w3, _, _ = load_network_config(chat_id)
    user_op_hash = entry_point.functions.getUserOpHash(user_op).call()
    raw_key = decrypt_key(key_ciphertext)
    try:
        signed = w3.eth.account.sign_message(
            encode_defunct(user_op_hash), private_key=raw_key
        )
        return user_op[:-1] + (signed.signature,)
    finally:
        raw_key = b"\x00" * len(raw_key)
        del raw_key
