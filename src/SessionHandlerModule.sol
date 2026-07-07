// SPDX-License-Identifier: MIT

pragma solidity ^0.8.24;

import {PackedUserOperation} from "@openzeppelin/contracts/interfaces/draft-IERC4337.sol";
import {
    IERC7579Validator,
    IERC7579Hook,
    IERC7579Execution,
    MODULE_TYPE_VALIDATOR,
    MODULE_TYPE_HOOK,
    VALIDATION_SUCCESS,
    VALIDATION_FAILED
} from "@openzeppelin/contracts/interfaces/draft-IERC7579.sol";
import {ERC7579Utils, Mode, CallType} from "@openzeppelin/contracts/account/utils/draft-ERC7579Utils.sol";
import {ECDSA} from "@openzeppelin/contracts/utils/cryptography/ECDSA.sol";
import {MessageHashUtils} from "@openzeppelin/contracts/utils/cryptography/MessageHashUtils.sol";
import {SHRegistry} from "./SHRegistry.sol";
import {SHValueInterpreter} from "./SHValueInterpreter.sol";
import {SHOracle} from "./SHOracle.sol";

/**
 * @title SessionHandlerModule
 * @author Conrad Japhet
 * @notice ERC-7579 module pair (Validator + Hook, installed as both) implementing session-key
 *         spending-limit logic as an installable module usable by any ERC-7579 account.
 * @dev A single deployed instance serves every account that installs it, so all session state is keyed
 *      by `account` (the installing smart account) rather than assumed to be "this contract's own wallet".
 *
 *      Why Validator + Hook are the SAME contract instead of two separate modules:
 *      EIP-1153 transient storage is scoped per contract address, not shared across different deployed
 *      contracts. A monolithic single-contract account could bridge validateUserOp -> execute via
 *      transient storage trivially, since both phases run as code of that same contract. Two separate
 *      modules could not share a bridge that way, and a validator cannot safely call out to a separate
 *      Hook contract during validateUserOp anyway (ERC-4337 validation-phase storage-access rules forbid
 *      calling arbitrary external contracts). Making this one contract installed as both a Validator
 *      (type 1) and a Hook (type 4) restores that same bridge trick, re-scoped per account.
 *
 *      Design boundaries worth knowing:
 *      - Owner-signed UserOps are out of scope: a separate default validator module would handle those;
 *        this module only ever sees session-key signers (the account dispatches to it by nonce key).
 *      - Protocol fee collection on execution is an account-level concern (moving ETH out of the account
 *        to a treasury), not something a Hook installed on arbitrary accounts should hardcode.
 *      - Batched executions are rejected outright for session-key UserOps (see _validateSession).
 *        Supporting batches would require per-item target/selector allowlist checks here, plus summing
 *        debit/credit per item in preCheck. Left out to avoid half-building a feature nothing exercises.
 *
 *      Sessions on contracts SHOracle has no price for (e.g. the ERC-8004 Reputation Registry) use
 *      addUnpricedSessionKey, which registers a session with Session.pricingExempt = true and skips the
 *      SHValueInterpreter/SHOracle call in preCheck entirely (see its dev comment for why a blanket
 *      try/catch around that call would be unsafe instead). Selector-checking is never skipped, even for
 *      exempt sessions -- callers must still register the exact selectors they want to allow.
 */
contract SessionHandlerModule is IERC7579Validator, IERC7579Hook {
    /*//////////////////////////////////////////////////////////////
                                    ERRORS
    //////////////////////////////////////////////////////////////*/
    error SessionHandlerModule_InvalidSessionKey();
    error SessionHandlerModule_InvalidTarget();
    error SessionHandlerModule_InvalidTimeRange();
    error SessionHandlerModule_InvalidEndTime();
    error SessionHandlerModule_SpendingLimitCannotBeZero();
    error SessionHandlerModule_SessionIsNotActive();
    error SessionHandlerModule_SpendingLimitExceeded();

    /*//////////////////////////////////////////////////////////////
                             STATE VARIABLES
    //////////////////////////////////////////////////////////////*/

    /// @dev SHRegistry supplying the callValueInterpreter address at runtime.
    SHRegistry public immutable REGISTRY;

    /// @dev Full configuration and runtime state for a single delegated session on a given account.
    struct Session {
        bool active;
        address target;
        uint48 validFrom;
        uint48 validUntil;
        uint256 spendingLimit;
        uint256 spentAmount;
        bytes4[] selectors;
        /// @dev When true, preCheck skips SHValueInterpreter/SHOracle pricing entirely and
        ///      getRemainingBudget always reports unlimited -- see addUnpricedSessionKey.
        bool pricingExempt;
    }

    mapping(address account => mapping(address sessionKey => Session)) private _sessions;
    mapping(address account => mapping(address sessionKey => mapping(bytes4 => bool))) private _isSelectorAllowed;
    mapping(address account => mapping(address sessionKey => bool)) private _sessionExists;
    /// @dev Tracked only so onUninstall can loop and clear every session for the account -- addSessionKey
    ///      and revokeSessionKey only ever need to clean up the one key being revoked/replaced.
    mapping(address account => address[]) private _sessionKeyList;
    mapping(address account => bool) private _installed;

    /*//////////////////////////////////////////////////////////////
                                   EVENTS
    //////////////////////////////////////////////////////////////*/
    event SessionAdded(address indexed account, address indexed sessionKey, address indexed target, uint48 validUntil);
    event SessionRevoked(address indexed account, address indexed sessionKey);

    constructor(address registry) {
        REGISTRY = SHRegistry(registry);
    }

    /*//////////////////////////////////////////////////////////////
                          IERC7579Module (shared)
    //////////////////////////////////////////////////////////////*/

    /// @dev Idempotent: an account installs this module twice (as MODULE_TYPE_VALIDATOR and again as
    ///      MODULE_TYPE_HOOK), triggering two onInstall calls, so this must not revert on the second one.
    function onInstall(bytes calldata) external {
        _installed[msg.sender] = true;
    }

    /// @dev Clears every session the account ever registered so a later re-install starts from zero state.
    function onUninstall(bytes calldata) external {
        address account = msg.sender;
        address[] storage keys = _sessionKeyList[account];
        uint256 length = keys.length;
        for (uint256 i = 0; i < length; i++) {
            _clearSession(account, keys[i]);
        }
        delete _sessionKeyList[account];
        delete _installed[account];
    }

    function isModuleType(uint256 moduleTypeId) external pure returns (bool) {
        return moduleTypeId == MODULE_TYPE_VALIDATOR || moduleTypeId == MODULE_TYPE_HOOK;
    }

    /*//////////////////////////////////////////////////////////////
              SESSION MANAGEMENT (called by the account on itself)
    //////////////////////////////////////////////////////////////*/

    /**
     * @notice Registers a session key's scoped permissions for the calling account.
     * @dev Guarded by `msg.sender == account` rather than an owner check: the account's own primary
     *      validator already decided who is authorized to make this call before routing it here.
     */
    function addSessionKey(
        address sessionKey,
        address target,
        bytes4[] calldata selectors,
        uint48 validFrom,
        uint48 validUntil,
        uint256 spendingLimit
    ) external {
        if (spendingLimit == 0) revert SessionHandlerModule_SpendingLimitCannotBeZero();
        _addSessionKey(sessionKey, target, selectors, validFrom, validUntil, spendingLimit, false);
    }

    /**
     * @notice Registers a session key that is exempt from USD-value pricing and budget tracking.
     * @dev For sessions that call contracts SHOracle has no price for (governance, reputation,
     *      NFTs, etc.) -- target + selector allowlisting still applies in full, only the pricing
     *      step is skipped. There's no meaningful spendingLimit for a session that's never priced,
     *      so this omits the parameter entirely rather than accept a value that would be inert.
     */
    function addUnpricedSessionKey(
        address sessionKey,
        address target,
        bytes4[] calldata selectors,
        uint48 validFrom,
        uint48 validUntil
    ) external {
        _addSessionKey(sessionKey, target, selectors, validFrom, validUntil, 0, true);
    }

    function _addSessionKey(
        address sessionKey,
        address target,
        bytes4[] calldata selectors,
        uint48 validFrom,
        uint48 validUntil,
        uint256 spendingLimit,
        bool pricingExempt
    ) internal {
        address account = msg.sender;
        if (sessionKey == address(0)) revert SessionHandlerModule_InvalidSessionKey();
        if (target == address(0) && selectors.length != 0) revert SessionHandlerModule_InvalidTarget();
        if (validFrom >= validUntil) revert SessionHandlerModule_InvalidTimeRange();
        if (validUntil <= block.timestamp) revert SessionHandlerModule_InvalidEndTime();

        if (_sessionExists[account][sessionKey]) {
            _clearSelectorMappings(account, sessionKey);
        } else {
            _sessionKeyList[account].push(sessionKey);
            _sessionExists[account][sessionKey] = true;
        }

        Session storage session = _sessions[account][sessionKey];
        session.active = validFrom <= block.timestamp;
        session.target = target;
        session.validFrom = validFrom;
        session.validUntil = validUntil;
        session.spendingLimit = spendingLimit;
        session.spentAmount = 0;
        session.selectors = selectors;
        session.pricingExempt = pricingExempt;

        uint256 length = selectors.length;
        for (uint256 i = 0; i < length; i++) {
            _isSelectorAllowed[account][sessionKey][selectors[i]] = true;
        }

        emit SessionAdded(account, sessionKey, target, validUntil);
    }

    function revokeSessionKey(address sessionKey) external {
        address account = msg.sender;
        if (!_sessionExists[account][sessionKey]) revert SessionHandlerModule_SessionIsNotActive();
        _clearSession(account, sessionKey);
        emit SessionRevoked(account, sessionKey);
    }

    function _clearSession(address account, address sessionKey) internal {
        _clearSelectorMappings(account, sessionKey);
        delete _sessions[account][sessionKey];
        delete _sessionExists[account][sessionKey];
    }

    function _clearSelectorMappings(address account, address sessionKey) internal {
        Session storage session = _sessions[account][sessionKey];
        uint256 length = session.selectors.length;
        for (uint256 i = 0; i < length; i++) {
            delete _isSelectorAllowed[account][sessionKey][session.selectors[i]];
        }
    }

    /*//////////////////////////////////////////////////////////////
                    IERC7579Validator (module type 1)
    //////////////////////////////////////////////////////////////*/

    /**
     * @notice Validates a session-key-signed UserOperation for `msg.sender` (the account dispatching to us).
     * @dev Only own-storage reads here -- no oracle calls -- since ERC-4337 mempool rules ban calling
     *      out to arbitrary external contracts during validation. Spending-limit enforcement happens
     *      later, in preCheck, where external calls are unrestricted.
     */
    function validateUserOp(PackedUserOperation calldata userOp, bytes32 userOpHash) external returns (uint256) {
        address account = msg.sender;
        bytes32 digest = MessageHashUtils.toEthSignedMessageHash(userOpHash);
        address signer = ECDSA.recover(digest, userOp.signature);

        if (!_sessionExists[account][signer]) {
            return VALIDATION_FAILED;
        }
        return _validateSession(account, signer, userOp);
    }

    /// @dev Session keys don't support ERC-1271; the account's primary validator should handle that.
    function isValidSignatureWithSender(address, bytes32, bytes calldata) external pure returns (bytes4) {
        return 0xffffffff;
    }

    function _validateSession(address account, address signer, PackedUserOperation calldata userOp)
        internal
        returns (uint256)
    {
        Session storage session = _sessions[account][signer];

        (bool isExecute, Mode mode, bytes calldata executionCalldata) = _decodeExecuteCalldata(userOp.callData);
        if (!isExecute) {
            return _packValidationData(true, session.validFrom, session.validUntil);
        }
        (CallType callType,,,) = ERC7579Utils.decodeMode(mode);
        if (!(callType == ERC7579Utils.CALLTYPE_SINGLE)) {
            return _packValidationData(true, session.validFrom, session.validUntil);
        }

        (address dest, uint256 value, bytes calldata callData) = ERC7579Utils.decodeSingle(executionCalldata);

        // Native ETH send: address(0) target is the sentinel for ETH sends to any recipient.
        if (callData.length == 0 && value > 0) {
            if (session.target != address(0) || !_isSessionUsable(account, signer)) {
                return _packValidationData(true, session.validFrom, session.validUntil);
            }
            _setPendingSession(account, signer);
            return _packValidationData(false, session.validFrom, session.validUntil);
        }

        if (session.target != dest) {
            return _packValidationData(true, session.validFrom, session.validUntil);
        }

        bytes4 selector = callData.length >= 4 ? bytes4(callData[:4]) : bytes4(0);

        if (!_isSessionUsable(account, signer) || !_isSelectorAllowed[account][signer][selector]) {
            return _packValidationData(true, session.validFrom, session.validUntil);
        }

        _setPendingSession(account, signer);
        return _packValidationData(false, session.validFrom, session.validUntil);
    }

    /*//////////////////////////////////////////////////////////////
                       IERC7579Hook (module type 4)
    //////////////////////////////////////////////////////////////*/

    /**
     * @notice Prices the pending session-key execution and applies the spend debit/credit before it runs.
     * @dev `msg.sender` here is the account itself (it calls its installed hook directly), so it doubles
     *      as the same per-account key used for storage above. If no session was flagged by validateUserOp
     *      this transaction (e.g. an owner-authorized call, or a UserOp validated by a different validator
     *      module), sessionKey is address(0) and this is a no-op -- non-session-key calls are not limited.
     */
    function preCheck(address, uint256, bytes calldata msgData) external returns (bytes memory) {
        address account = msg.sender;
        address sessionKey = _consumePendingSession(account);
        if (sessionKey == address(0)) return "";

        // Pricing-exempt sessions never touch SHValueInterpreter/SHOracle -- target and selector
        // were already enforced in _validateSession, so there's nothing left to check here beyond
        // auto-expiry. See addUnpricedSessionKey.
        if (_sessions[account][sessionKey].pricingExempt) {
            if (!isSessionActive(account, sessionKey)) {
                _clearSession(account, sessionKey);
            }
            return "";
        }

        (bool isExecute, Mode mode, bytes calldata executionCalldata) = _decodeExecuteCalldata(msgData);
        if (!isExecute) return "";
        (CallType callType,,,) = ERC7579Utils.decodeMode(mode);
        if (!(callType == ERC7579Utils.CALLTYPE_SINGLE)) return "";

        (address dest, uint256 value, bytes calldata callData) = ERC7579Utils.decodeSingle(executionCalldata);
        bytes4 selector = callData.length >= 4 ? bytes4(callData[:4]) : bytes4(0);

        bytes memory dataMem = callData;
        (uint256 debitValueInUsd, uint256 creditValueInUsd) = SHValueInterpreter(REGISTRY.callValueInterpreter())
            .computeUsdValue(dest, value, dataMem, selector);

        Session storage session = _sessions[account][sessionKey];
        if (creditValueInUsd > 0) {
            session.spentAmount =
                creditValueInUsd >= session.spentAmount ? 0 : session.spentAmount - creditValueInUsd;
        } else {
            if (session.spentAmount + debitValueInUsd > session.spendingLimit) {
                revert SessionHandlerModule_SpendingLimitExceeded();
            }
            session.spentAmount += debitValueInUsd;
        }

        if (!isSessionActive(account, sessionKey)) {
            _clearSession(account, sessionKey);
        }

        return "";
    }

    /// @dev Nothing to reconcile post-execution: unlike a swap's actual output, every value used above
    ///      (transfer amounts, removeLiquidity minimums) is already final calldata, not an estimate.
    function postCheck(bytes calldata) external {}

    /*//////////////////////////////////////////////////////////////
                             INTERNAL HELPERS
    //////////////////////////////////////////////////////////////*/

    /**
     * @dev Recovers (mode, executionCalldata) from the raw calldata of a call to
     *      IERC7579Execution.execute(bytes32 mode, bytes executionCalldata), without copying to memory,
     *      by walking the standard ABI offset/length encoding directly on the calldata slice. Used from
     *      both validateUserOp (on userOp.callData) and preCheck (on msgData) since both receive that same
     *      shape whenever the account is executing on behalf of a session key.
     */
    function _decodeExecuteCalldata(bytes calldata fullCalldata)
        internal
        pure
        returns (bool isExecute, Mode mode, bytes calldata executionCalldata)
    {
        if (fullCalldata.length < 68 || bytes4(fullCalldata[:4]) != IERC7579Execution.execute.selector) {
            return (false, Mode.wrap(0), fullCalldata[0:0]);
        }
        bytes calldata args = fullCalldata[4:];
        mode = Mode.wrap(bytes32(args[0:32]));
        uint256 dataOffset = uint256(bytes32(args[32:64]));
        uint256 dataLen = uint256(bytes32(args[dataOffset:dataOffset + 32]));
        executionCalldata = args[dataOffset + 32:dataOffset + 32 + dataLen];
        isExecute = true;
    }

    /// @dev Transient storage is scoped per contract address, so keying by `account` (this contract's own
    ///      msg.sender in both validateUserOp and preCheck) keeps concurrent UserOps from different
    ///      accounts in the same bundled transaction from clobbering each other. Auto-clears at tx end.
    function _setPendingSession(address account, address sessionKey) internal {
        bytes32 slot = keccak256(abi.encode("SessionHandlerModule.pendingSession", account));
        assembly {
            tstore(slot, sessionKey)
        }
    }

    function _consumePendingSession(address account) internal view returns (address sessionKey) {
        bytes32 slot = keccak256(abi.encode("SessionHandlerModule.pendingSession", account));
        assembly {
            sessionKey := tload(slot)
        }
    }

    /**
     * @notice Returns the session key flagged as pending for `account` during this transaction's
     *         validateUserOp, or address(0) if the in-flight execution wasn't authorized by a
     *         session key (e.g. an owner-initiated call).
     * @dev Read-only wrapper around the same transient slot preCheck reads. Lets an account (e.g.
     *      SessionHandler) tell, from inside its own execute(), whether this particular call was
     *      driven by a session key -- useful for session-key-only behavior like fee charging that
     *      doesn't belong inside a reusable spending-limit module.
     */
    function pendingSessionKey(address account) external view returns (address) {
        return _consumePendingSession(account);
    }

    function _packValidationData(bool sigFailed, uint48 validFrom, uint48 validUntil)
        internal
        pure
        returns (uint256 validationData)
    {
        validationData = (sigFailed ? VALIDATION_FAILED : VALIDATION_SUCCESS) | (uint256(validUntil) << 160)
            | (uint256(validFrom) << (160 + 48));
    }

    /*//////////////////////////////////////////////////////////////
                              VIEW FUNCTIONS
    //////////////////////////////////////////////////////////////*/

    function getSession(address account, address sessionKey) public view returns (Session memory) {
        return _sessions[account][sessionKey];
    }

    function isSessionActive(address account, address sessionKey) public view returns (bool) {
        Session storage session = _sessions[account][sessionKey];
        if (session.active) {
            if (block.timestamp > session.validUntil || getRemainingBudget(account, sessionKey) == 0) {
                return false;
            }
        } else if (
            _sessionExists[account][sessionKey] && block.timestamp >= session.validFrom
                && block.timestamp <= session.validUntil && getRemainingBudget(account, sessionKey) > 0
        ) {
            return true;
        }
        return session.active;
    }

    function getRemainingBudget(address account, address sessionKey) public view returns (uint256) {
        Session storage session = _sessions[account][sessionKey];
        // Pricing-exempt sessions have no real budget; reporting "unlimited" here (rather than 0)
        // is what makes _isSessionUsable/isSessionActive treat them as usable without a separate
        // special case in each of those functions -- both are built directly on this one.
        if (session.pricingExempt) return type(uint256).max;
        if (session.spentAmount >= session.spendingLimit) return 0;
        return session.spendingLimit - session.spentAmount;
    }

    /// @notice Checks whether a proposed spend is within the session's remaining budget.
    /// @dev Not used internally by preCheck/validateUserOp -- a convenience view for callers
    ///      deciding whether to submit a UserOp.
    function isSpendingWithinBudget(address account, address sessionKey, address token, uint256 amount)
        public
        view
        returns (bool)
    {
        if (!isSessionActive(account, sessionKey)) return false;
        Session storage session = _sessions[account][sessionKey];
        uint256 valueInUsd = SHOracle(REGISTRY.priceOracle()).getUsdValue(token, amount);
        return session.spentAmount + valueInUsd <= session.spendingLimit;
    }

    function _isSessionUsable(address account, address sessionKey) internal view returns (bool) {
        return _sessionExists[account][sessionKey] && getRemainingBudget(account, sessionKey) > 0;
    }
}