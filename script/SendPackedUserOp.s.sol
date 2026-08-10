//SPDX-License Identifier: MIT
pragma solidity ^0.8.24;

import {Script} from "forge-std/Script.sol";
import {HelperConfig} from "./HelperConfig.s.sol";
import {IEntryPoint} from "@account-abstraction/contracts/interfaces/IEntryPoint.sol";
import {PackedUserOperation} from "@account-abstraction/contracts/interfaces/PackedUserOperation.sol";
import {MessageHashUtils} from "@openzeppelin/contracts/utils/cryptography/MessageHashUtils.sol";
import {IERC7579Execution, Execution} from "@openzeppelin/contracts/interfaces/draft-IERC7579.sol";
import {ERC7579Utils} from "@openzeppelin/contracts/account/utils/draft-ERC7579Utils.sol";

/**
 * @title SendPackedUserOp
 * @notice Helper script for generating and signing ERC-4337 PackedUserOperations targeting
 *         SessionHandler, an ERC-7579 account that validates its own UserOps.
 * @dev SessionHandler installs NO validator module (SpendingLimitModule is a hook only). UserOp
 *      validation therefore always falls through AccountERC7579's module lookup to the account's
 *      own {_rawSignatureValidation}, which accepts a signature from the owner OR from any address
 *      the owner registered via addSession. This script signs with whatever key it is given -- the
 *      same flow covers owner-signed and session-key-signed ops.
 *
 *      Signing flow:
 *      1. Fetch nonce from EntryPoint using key 0. The nonce key's top 20 bytes select a validator
 *         module (AccountERC7579._extractUserOpValidator); address(0) is never installed, so the
 *         account always falls back to its own signature validation. Any other key value would
 *         behave identically -- key 0 is just the canonical choice.
 *      2. Pack the execution into ERC-7579 execute(mode, executionCalldata) calldata
 *         (single-call or batch).
 *      3. Get userOpHash from EntryPoint (EIP-712 typed structured data hash).
 *      4. Wrap in EIP-191 envelope via toEthSignedMessageHash (matches what
 *         SessionHandler._rawSignatureValidation re-wraps before recovery).
 *      5. Sign the digest with vm.sign and attach (r, s, v) to the UserOp.
 *
 *      NOTE: session-key ops are subject to SessionHandler's execution guard -- a non-owner op
 *      whose target is the account itself or its SpendingLimitModule reverts at execution time
 *      (SessionHandler_SessionRestrictedTarget), and delegatecall mode is rejected outright.
 *      This script builds single and batch modes only, which is all the account supports for
 *      session keys anyway.
 */
contract SendPackedUserOp is Script {
    using MessageHashUtils for bytes32;

    /**
     * @notice Generates a signed PackedUserOperation for a single-call execute() on a
     *         SessionHandler account.
     * @param sender     The SessionHandler account address that will send the UserOp.
     * @param config     Network configuration containing the entryPoint address.
     * @param dest       Target contract for the inner call.
     * @param value      Native ETH value (wei) to forward with the inner call.
     * @param data       Calldata for the inner call.
     * @param signer     Address whose key signs the op (the owner or an allowed session key).
     * @param signerKey  Private key matching `signer`.
     * @return userOp     The fully constructed and signed PackedUserOperation.
     * @return userOpHash The raw EIP-712 hash of the UserOp as returned by the EntryPoint.
     * @return digest     The EIP-191 wrapped digest that was actually signed.
     */
    function generateSignedUserOp(
        address sender,
        HelperConfig.NetworkConfig memory config,
        address dest,
        uint256 value,
        bytes memory data,
        address signer,
        uint256 signerKey
    ) external view returns (PackedUserOperation memory, bytes32, bytes32) {
        // Single-call mode: CALLTYPE_SINGLE (0x00) | EXECTYPE_DEFAULT (0x00) => bytes32(0).
        // The inner (target, value, data) triple is packed with abi.encodePacked, not abi.encode,
        // matching ERC7579Utils.encodeSingle/decodeSingle's fixed-offset layout.
        bytes memory executionCalldata = abi.encodePacked(dest, value, data);
        bytes memory callData = abi.encodeCall(IERC7579Execution.execute, (bytes32(0), executionCalldata));
        return _signUserOp(sender, config, callData, signer, signerKey);
    }

    /**
     * @notice Generates a signed PackedUserOperation for a batch execute() on a SessionHandler
     *         account -- e.g. [approve router, swap] so the approval is consumed atomically in the
     *         same transaction (SpendingLimitModule reverts any approval left standing).
     * @param sender     The SessionHandler account address that will send the UserOp.
     * @param config     Network configuration containing the entryPoint address.
     * @param executions The (target, value, callData) triples to execute in order.
     * @param signer     Address whose key signs the op (the owner or an allowed session key).
     * @param signerKey  Private key matching `signer`.
     * @return userOp     The fully constructed and signed PackedUserOperation.
     * @return userOpHash The raw EIP-712 hash of the UserOp as returned by the EntryPoint.
     * @return digest     The EIP-191 wrapped digest that was actually signed.
     */
    function generateSignedBatchUserOp(
        address sender,
        HelperConfig.NetworkConfig memory config,
        Execution[] memory executions,
        address signer,
        uint256 signerKey
    ) external view returns (PackedUserOperation memory, bytes32, bytes32) {
        // Batch mode word: CALLTYPE_BATCH (0x01) in the top byte, EXECTYPE_DEFAULT (0x00) next,
        // everything else zero -- matches ERC7579Utils.decodeMode's byte layout.
        bytes32 mode = bytes32(uint256(0x01) << 248);
        bytes memory callData = abi.encodeCall(IERC7579Execution.execute, (mode, ERC7579Utils.encodeBatch(executions)));
        return _signUserOp(sender, config, callData, signer, signerKey);
    }

    /// @dev Shared tail: nonce lookup (key 0), unsigned op construction, hashing, EIP-191 signing.
    function _signUserOp(
        address sender,
        HelperConfig.NetworkConfig memory config,
        bytes memory callData,
        address signer,
        uint256 signerKey
    ) internal view returns (PackedUserOperation memory, bytes32, bytes32) {
        uint256 nonce = IEntryPoint(config.entryPoint).getNonce(sender, 0);

        // 1. Build the unsigned UserOp with hardcoded gas parameters
        PackedUserOperation memory userOp = _generateUnsignedUserOp(sender, nonce, callData);

        // 2. Get the EIP-712 typed structured data hash from the EntryPoint
        bytes32 userOpHash = IEntryPoint(config.entryPoint).getUserOpHash(userOp);

        // 3. Wrap in EIP-191 envelope to produce the signable digest
        bytes32 digest = userOpHash.toEthSignedMessageHash();

        // 4. Sign the digest — vm.sign returns v as 27/28 already adjusted
        (uint8 v, bytes32 r, bytes32 s) = vm.sign(signerKey, digest);
        require(ecrecover(digest, v, r, s) == signer, "signer does not match signerKey");

        // 5. Attach the packed (r, s, v) signature to the UserOp
        userOp.signature = abi.encodePacked(r, s, v);

        return (userOp, userOpHash, digest);
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
