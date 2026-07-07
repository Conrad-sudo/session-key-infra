//SPDX-License Identifier: MIT
pragma solidity ^0.8.24;

import {Script} from "forge-std/Script.sol";
import {HelperConfig} from "./HelperConfig.s.sol";
import {IEntryPoint} from "@account-abstraction/contracts/interfaces/IEntryPoint.sol";
import {PackedUserOperation} from "@account-abstraction/contracts/interfaces/PackedUserOperation.sol";
import {MessageHashUtils} from "@openzeppelin/contracts/utils/cryptography/MessageHashUtils.sol";
import {IERC7579Execution} from "@openzeppelin/contracts/interfaces/draft-IERC7579.sol";

/**
 * @title SendPackedUserOp
 * @notice Helper script for generating and signing ERC-4337 PackedUserOperations targeting
 *         SessionHandler, an ERC-7579 account whose only installed validator is
 *         SessionHandlerModule.
 * @dev This script has no "owner mode" -- SessionHandler deliberately never routes owner actions
 *      through the EntryPoint at all. The only installed validator (SessionHandlerModule) rejects
 *      any signer that isn't a registered session key, and there is no separate owner-validator
 *      module. Owners call the account directly instead (see
 *      SessionHandler.onlyEntryPointOrSelfOrOwner). Every UserOp this script builds is therefore a
 *      session-key-signed call to `execute(...)`.
 *
 *      Signing flow:
 *      1. Fetch nonce from EntryPoint using a key whose top 20 bytes equal the spending-limit
 *         module's address -- SessionHandler dispatches UserOp validation to whichever validator
 *         module address is embedded in the nonce key (see AccountERC7579._extractUserOpValidator).
 *      2. Pack (dest, value, data) into ERC-7579's single-execution calldata and wrap it in an
 *         execute(mode, executionCalldata) call.
 *      3. Get userOpHash from EntryPoint (EIP-712 typed structured data hash).
 *      4. Wrap in EIP-191 envelope via toEthSignedMessageHash.
 *      5. Sign the digest with vm.sign.
 *      6. Attach (r, s, v) signature to the UserOp.
 */
contract SendPackedUserOp is Script {
    using MessageHashUtils for bytes32;

    /**
     * @notice Generates a signed ERC-4337 PackedUserOperation for a session-key call on a
     *         SessionHandler account.
     * @param sender              The SessionHandler account address that will send the UserOp.
     * @param config              Network configuration containing the entryPoint address.
     * @param spendingLimitModule Address of the SessionHandlerModule installed on `sender`. Its
     *                            address is embedded in the nonce key so the account routes
     *                            validation to it; it is also the module that will enforce the
     *                            session's target/selector/time-window/budget rules.
     * @param dest                Target contract for the inner call.
     * @param value               Native ETH value (wei) to forward with the inner call.
     * @param data                Calldata for the inner call.
     * @param sessionSigner       Address of the session key signer.
     * @param sessionSignerKey    Private key of the session key signer.
     * @return userOp     The fully constructed and signed PackedUserOperation.
     * @return userOpHash The raw EIP-712 hash of the UserOp as returned by the EntryPoint.
     * @return digest     The EIP-191 wrapped digest that was actually signed.
     */
    function generateSignedUserOp(
        address sender,
        HelperConfig.NetworkConfig memory config,
        address spendingLimitModule,
        address dest,
        uint256 value,
        bytes memory data,
        address sessionSigner,
        uint256 sessionSignerKey
    ) external view returns (PackedUserOperation memory, bytes32, bytes32) {
        // Nonce key convention (AccountERC7579._extractUserOpValidator): top 20 bytes of the
        // 192-bit key select the validator module; the low 32 bits are free sub-key space.
        uint192 nonceKey = uint192(uint160(spendingLimitModule)) << 32;
        uint256 nonce = IEntryPoint(config.entryPoint).getNonce(sender, nonceKey);

        bytes memory callData = _encodeExecuteCalldata(dest, value, data);

        // 1. Build the unsigned UserOp with hardcoded gas parameters
        PackedUserOperation memory userOp = _generateUnsignedUserOp(sender, nonce, callData);

        // 2. Get the EIP-712 typed structured data hash from the EntryPoint
        bytes32 userOpHash = IEntryPoint(config.entryPoint).getUserOpHash(userOp);

        // 3. Wrap in EIP-191 envelope to produce the signable digest
        bytes32 digest = userOpHash.toEthSignedMessageHash();

        // 4. Sign the digest — vm.sign returns v as 0 or 1 on Anvil, adjusted to 27/28
        (uint8 v, bytes32 r, bytes32 s) = vm.sign(sessionSignerKey, digest);
        require(ecrecover(digest, v, r, s) == sessionSigner, "sessionSigner does not match sessionSignerKey");

        // 5. Attach the packed (r, s, v) signature to the UserOp
        userOp.signature = abi.encodePacked(r, s, v);

        return (userOp, userOpHash, digest);
    }

    /**
     * @notice Packs (dest, value, data) into an ERC-7579 execute(mode, executionCalldata) call.
     * @dev Single-call mode only (CALLTYPE_SINGLE = 0x00, EXECTYPE_DEFAULT = 0x00, no selector or
     *      payload), so `mode` is simply bytes32(0). SessionHandlerModule's validator rejects batch
     *      and delegatecall modes for session keys, so this script never needs to build those.
     *      The inner (target, value, data) triple is packed with abi.encodePacked, not abi.encode,
     *      matching ERC7579Utils.encodeSingle/decodeSingle's fixed-offset layout.
     */
    function _encodeExecuteCalldata(address dest, uint256 value, bytes memory data)
        internal
        pure
        returns (bytes memory)
    {
        bytes memory executionCalldata = abi.encodePacked(dest, value, data);
        bytes32 mode = bytes32(0);
        return abi.encodeCall(IERC7579Execution.execute, (mode, executionCalldata));
    }

    /**
     * @notice Constructs an unsigned PackedUserOperation with hardcoded gas parameters
     * @dev Gas values are intentionally set high for testing purposes and should not
     *      be used in production. Fields are packed according to ERC-4337 v0.7 spec:
     *      - accountGasLimits: verificationGasLimit (upper 128 bits) | callGasLimit (lower 128 bits)
     *      - gasFees: maxFeePerGas (upper 128 bits) | maxPriorityFeePerGas (lower 128 bits)
     *      initCode and paymasterAndData are empty as this account is already deployed
     *      and self-funded. signature is empty as it is attached after hashing.
     */
    function _generateUnsignedUserOp(address sender, uint256 nonce, bytes memory callData)
        internal
        pure
        returns (PackedUserOperation memory)
    {
        uint128 verificationGasLimit = 17e6;
        uint128 callGasLimit = 17e6;
        uint128 maxFeePerGas = 256;
        uint128 maxPriorityFeePerGas = 256;

        return PackedUserOperation({
            sender: sender,
            nonce: nonce,
            initCode: hex"",
            callData: callData,
            accountGasLimits: bytes32(uint256(uint256(verificationGasLimit) << 128 | uint256(callGasLimit))),
            preVerificationGas: verificationGasLimit,
            gasFees: bytes32(uint256(maxFeePerGas) << 128 | uint256(maxPriorityFeePerGas)),
            paymasterAndData: hex"",
            signature: hex""
        });
    }
}
