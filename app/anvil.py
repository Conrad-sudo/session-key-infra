import os
from dotenv import load_dotenv
from web3.contract import Contract
from web3.logs import DISCARD
from network_config import load_network_config
from constants import CHAIN_ID_ANVIL
from userop import create_signed_user_op, prepare_execute_call, prepare_execute_batch_call

load_dotenv()

# Gas estimation constants for the dummy UserOp used in eth_estimateGas simulation.
# These are placeholder limits — large enough that the EntryPoint prefund check passes,
# but not so large they cause issues. The real limits are set after estimation.
DUMMY_INNER_GAS = 500_000
DUMMY_PRE_VERIFICATION_GAS = 50_000
_DUMMY_GAS_PRICE_WEI = 256  # minimal non-zero value; real price applied post-estimation

GAS_BUFFER_MULTIPLIER = 1.2  # 20% headroom added to estimated gas
PRE_VERIFICATION_GAS = 50_000


def create_unsigned_user_op(
    chat_id: int,
    session_handler: Contract,
    key_ciphertext: str,
    entry_point: Contract,
    nonce: int,
    calldata: str,
    beneficiary: str,
) -> tuple[tuple, int, int]:
    """
    Constructs an unsigned ERC-4337 PackedUserOperation tuple.

    Builds a dummy op with placeholder gas limits, signs it to estimate actual gas
    via eth_estimateGas, then constructs the final op with a 20% gas buffer and the
    live gas price from the node.

    @param chat_id        The Telegram chat ID of the user.
    @param session_handler Bound SessionHandler contract (the UserOp sender).
    @param key_ciphertext  Vault Transit ciphertext for the session key ('vault:v1:...').
    @param entry_point     Bound EntryPoint contract.
    @param nonce           The sender's current nonce from the EntryPoint.
    @param calldata        Hex-encoded SessionHandler.execute() calldata (0x-prefixed).
    @param beneficiary     Address the dummy handleOps probe credits gas compensation to.
                           Must be the same address the real handleOps call will use — the
                           EntryPoint's final _compensate() step does a plain ETH send to it,
                           which reverts (AA91) against any address with code that lacks a
                           payable receive/fallback (e.g. an EIP-7702-delegated EOA).
    @return                A tuple of (unsigned PackedUserOperation, outer_gas, gas_price) where
                           outer_gas is 2x the estimated inner gas so the EntryPoint AA95 check
                           passes, and gas_price is the snapshot used to build gas_fees — must be
                           reused on the outer tx so the EntryPoint prefund check is consistent.
    """
    w3, _, _ = load_network_config(chat_id)

    # Use modest placeholder limits for the dummy op so the EntryPoint's prefund
    # calculation (verificationGasLimit + callGasLimit + preVerificationGas) * gasPrice
    # stays within the SessionHandler's ETH balance during eth_estimateGas simulation.
    dummy_op = (
        session_handler.address,
        nonce,
        b"",
        bytes.fromhex(calldata[2:]),
        (DUMMY_INNER_GAS << 128 | DUMMY_INNER_GAS).to_bytes(32, "big"),
        DUMMY_PRE_VERIFICATION_GAS,
        (_DUMMY_GAS_PRICE_WEI << 128 | _DUMMY_GAS_PRICE_WEI).to_bytes(32, "big"),
        b"",
        b"",
    )

    signed_dummy_op = create_signed_user_op(
        chat_id=chat_id,
        user_op=dummy_op,
        entry_point=entry_point,
        key_ciphertext=key_ciphertext,
    )

    estimated = w3.eth.estimate_gas(
        {
            "to": entry_point.address,
            "data": entry_point.encode_abi(
                abi_element_identifier="handleOps",
                args=[[signed_dummy_op], beneficiary],
            ),
        }
    )

    # outer_gas: total gas for the handleOps transaction — must comfortably exceed
    # verificationGasLimit + callGasLimit so the EntryPoint's AA95 check passes.
    # inner_gas: per-component limit packed into the UserOp. Set to estimated so each
    # component has enough headroom; outer_gas = 2x covers the sum.
    gas_price = w3.eth.gas_price
    inner_gas = int(estimated * GAS_BUFFER_MULTIPLIER)
    outer_gas = inner_gas * 2
    pre_verification_gas = PRE_VERIFICATION_GAS

    account_gas_limits = (inner_gas << 128 | inner_gas).to_bytes(32, "big")
    gas_fees = (gas_price << 128 | gas_price).to_bytes(32, "big")

    return (
        (
            session_handler.address,
            nonce,
            b"",
            bytes.fromhex(calldata[2:]),
            account_gas_limits,
            pre_verification_gas,
            gas_fees,
            b"",
            b"",
        ),
        outer_gas,
        gas_price,
    )


def send_user_op_as_session(
    chat_id: int, key_ciphertext: str, target: str, value: int, data: bytes
):
    """
    Orchestrates the full ERC-4337 UserOperation flow for a session key holder.

    Packs (target, value, data) into ERC-7579 executionCalldata and encodes
    SessionHandler.execute(mode, executionCalldata) as the UserOp calldata, fetches a
    nonce keyed to the installed SpendingLimitModule (so the account routes validation to
    it), builds an unsigned PackedUserOperation, signs it with the session key via EIP-191,
    and submits it to the EntryPoint via handleOps(). The bundler key from the environment
    signs and sends the outer transaction.

    @param chat_id        The Telegram chat ID of the user.
    @param key_ciphertext Vault Transit ciphertext for the session key ('vault:v1:...').
    @param target         The contract address SessionHandler will call (e.g. USDC).
    @param value          The ETH value in wei to forward with the inner call.
    @param data           ABI-encoded inner calldata to execute on the target.
    @return               A tuple of (tx_hash, receipt).
    """
    session_handler, entry_point, calldata, nonce = prepare_execute_call(
        chat_id, target, value, data
    )
    return _submit_user_op(chat_id, key_ciphertext, session_handler, entry_point, calldata, nonce)


def send_batch_user_op_as_session(
    chat_id: int, key_ciphertext: str, executions: list[tuple[str, int, bytes]]
):
    """
    Batch variant of send_user_op_as_session: submits several sub-calls as ONE atomic
    execute(batchMode, ...) UserOp. Required for any flow that grants an approval —
    SpendingLimitModule reverts the whole transaction if an approval survives it, so
    [approve, spend(, approve 0)] must land together.

    @param chat_id        The Telegram chat ID of the user.
    @param key_ciphertext Vault Transit ciphertext for the session key ('vault:v1:...').
    @param executions     List of (target_address, value_wei, calldata_bytes) triples, in order.
    @return               A tuple of (tx_hash, receipt).
    """
    session_handler, entry_point, calldata, nonce = prepare_execute_batch_call(
        chat_id, executions
    )
    return _submit_user_op(chat_id, key_ciphertext, session_handler, entry_point, calldata, nonce)


def _submit_user_op(
    chat_id: int,
    key_ciphertext: str,
    session_handler,
    entry_point,
    calldata: str,
    nonce: int,
):
    """
    Shared tail of the Anvil/fork UserOp flow: estimates gas, signs the op with the session key,
    and submits it to the EntryPoint via handleOps() signed by the local bundler key. Everything
    after calldata construction is identical for single-call and batch ops.
    """
    # FORK_DEPLOYER_PK is shared across every fork network (mainnet-fork/sepolia-fork/bsc-fork/
    # celo-fork) — deploy_wallet.py's prefund() funds this same key, so it always has gas here.
    w3, chain_id, _ = load_network_config(chat_id)
    if chain_id == CHAIN_ID_ANVIL:
        bundler = w3.eth.account.from_key(os.getenv("ANVIL_BUNDLER"))
    else:
        bundler = w3.eth.account.from_key(os.getenv("FORK_DEPLOYER_PK"))

    print("\n[1/3] Creating transaction  ...")
    user_op, gas_limit, gas_price = create_unsigned_user_op(
        chat_id=chat_id,
        session_handler=session_handler,
        key_ciphertext=key_ciphertext,
        entry_point=entry_point,
        nonce=nonce,
        calldata=calldata,
        beneficiary=bundler.address,
    )
    print("[2/3] Signing transaction   ...")
    user_op_signed = create_signed_user_op(
        chat_id=chat_id,
        user_op=user_op,
        entry_point=entry_point,
        key_ciphertext=key_ciphertext,
    )

    print("[3/3] Sending transaction   ...")
    tx = entry_point.functions.handleOps(
        [user_op_signed], bundler.address
    ).build_transaction(
        {
            "from": bundler.address,
            "nonce": w3.eth.get_transaction_count(bundler.address),
            "chainId": chain_id,
            "gas": gas_limit,
            "gasPrice": gas_price,
        }
    )
    signed_tx = w3.eth.account.sign_transaction(tx, bundler.key)
    tx_hash = w3.eth.send_raw_transaction(signed_tx.raw_transaction)
    receipt = w3.eth.wait_for_transaction_receipt(tx_hash)

    if receipt["status"] == 0:
        try:
            w3.eth.call(
                {
                    "from": bundler.address,
                    "to": entry_point.address,
                    "data": tx["data"],
                    "gas": tx["gas"],
                    "gasPrice": gas_price,
                },
                block_identifier=receipt["blockNumber"] - 1,
            )
        except Exception as revert_err:
            print(f"[revert reason] {revert_err}")
        raise RuntimeError("handleOps outer transaction reverted")

    # In ERC-4337, the EntryPoint catches inner call reverts and still mines the outer
    # transaction successfully (status 1). The actual inner result is in UserOperationEvent.
    events = entry_point.events.UserOperationEvent().process_receipt(
        receipt, errors=DISCARD
    )
    for evt in events:
        if not evt["args"]["success"]:
            raise RuntimeError(
                f"UserOperation inner call failed "
                f"(nonce={evt['args']['nonce']}, gas_cost={evt['args']['actualGasCost']} wei). "
                f"The transaction was mined but the inner call reverted — check token balances and allowances."
            )

    return tx_hash, receipt
