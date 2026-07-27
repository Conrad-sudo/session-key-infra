// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {IEntryPoint} from "@openzeppelin/contracts/interfaces/draft-IERC4337.sol";
import {AccountERC7579Hooked} from "@openzeppelin/contracts/account/extensions/draft-AccountERC7579Hooked.sol";
import {MODULE_TYPE_HOOK, Execution} from "@openzeppelin/contracts/interfaces/draft-IERC7579.sol";
import {ERC7579Utils, Mode, CallType} from "@openzeppelin/contracts/account/utils/draft-ERC7579Utils.sol";
import {OwnableUpgradeable} from "@openzeppelin/contracts-upgradeable/access/OwnableUpgradeable.sol";
import {Pausable} from "@openzeppelin/contracts/utils/Pausable.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {ECDSA} from "@openzeppelin/contracts/utils/cryptography/ECDSA.sol";
import {MessageHashUtils} from "@openzeppelin/contracts/utils/cryptography/MessageHashUtils.sol";
import {SHOracle} from "./SHOracle.sol";
import {SHRegistry} from "./SHRegistry.sol";
import {SpendingLimitModule} from "./SpendingLimitModule.sol";
import {IReputationRegistry} from "./interfaces/IReputationRegistry.sol";
import {IIdentityRegistry} from "./interfaces/IIdentityRegistry.sol";
import {Context} from "@openzeppelin/contracts/utils/Context.sol";
import {ContextUpgradeable} from "@openzeppelin/contracts-upgradeable/utils/ContextUpgradeable.sol";

/**
 * @title SessionHandler
 * @author Conrad Japhet
 * @notice ERC-7579 smart account guarded by a USD-denominated spending cap. The cap and all
 *         USD-value enforcement live entirely in the installed SpendingLimitModule (installed as
 *         a hook); this contract keeps only the account-level concerns that aren't cap-specific
 *         (ownership, ETH/ERC20 withdrawal, pausing, spending-cap configuration passthroughs, and
 *         the ERC-8004 identity/reputation lookups).
 * @dev Session-key auth is built into the account itself: it validates its own UserOps via
 *      {_rawSignatureValidation}, accepting a UserOp signed by the owner OR by any address on the
 *      `allowedSession` allowlist (managed with {addSession}/{removeSession}). No separate validator
 *      module is installed -- SpendingLimitModule is a hook (module type 4) ONLY, enforcing the USD
 *      spending cap on every execution. A session key is a BARE signer with no per-key target/
 *      selector scope or expiry; the spending cap is its only on-chain guardrail (see {addSession}).
 * @dev Deliberate deviation from stock AccountERC7579Hooked: `execute`, `installModule`, and
 *      `uninstallModule` are normally `onlyEntryPointOrSelf` -- an EOA owner cannot call them
 *      directly. This contract reopens that direct-owner path (see the three overrides below) so
 *      the owner never has to submit a UserOp for their own admin actions -- they just call the
 *      account directly, without needing a second "owner validator" module.
 */
contract SessionHandler is AccountERC7579Hooked, OwnableUpgradeable, Pausable {
    using SafeERC20 for IERC20;

    /*//////////////////////////////////////////////////////////////
                                    ERRORS
    //////////////////////////////////////////////////////////////*/
    error SessionHandler_InvalidRecipient();
    error SessionHandler_NotEnoughBalance();
    error SessionHandler_ExecutionFailed();
    /// @dev Thrown when address(0) is passed as a session key to addSession.
    error SessionHandler_InvalidSessionKey();
    /// @dev Thrown when a session-key (non-owner) execution targets the account's own admin surface
    ///      (address(this) or the spending-limit module), which would let a key escape the cap.
    error SessionHandler_SessionRestrictedTarget(address target);
    /// @dev Thrown when a session-key (non-owner) execution uses delegatecall, which runs arbitrary
    ///      code in the account's context and so could reach the admin surface regardless of target.
    error SessionHandler_SessionDelegateCallForbidden();

    /*//////////////////////////////////////////////////////////////
                                    EVENTS
    //////////////////////////////////////////////////////////////*/
    /// @notice Emitted when the owner authorizes a session key.
    event SessionAdded(address indexed sessionKey);
    /// @notice Emitted when the owner revokes a session key.
    event SessionRemoved(address indexed sessionKey);

    /*//////////////////////////////////////////////////////////////
                             STATE VARIABLES
    //////////////////////////////////////////////////////////////*/

    /// @dev Overrides Account's default (OZ's canonical v0.8 singleton) with this deployment's own
    ///      EntryPoint, since this project actually uses a v0.7 EntryPoint (see HelperConfig.s.sol).
    /// @dev Set once in initialize() rather than the constructor: this account is deployed behind an
    ///      EIP-1167 minimal proxy by SHFactory, so per-wallet state cannot live in immutables (those
    ///      are baked into the shared implementation bytecode). initialize() is one-time (initializer).
    address public ENTRY_POINT;
    address public REPUTATION_REGISTRY;
    address public IDENTITY_REGISTRY;
    SHRegistry public REGISTRY;
    uint256 public WALLET_ID;
    /// @dev Installed as MODULE_TYPE_HOOK in initialize(); enforces the account's USD spending cap.
    SpendingLimitModule public SH_MODULE;

    /// @notice Session keys authorized to sign UserOps for this account (the owner is always
    ///         authorized separately, in {_rawSignatureValidation}). A bare allowlist: an allowed
    ///         key may drive ANY execute() call, bounded only by the SpendingLimitModule spending
    ///         cap. Managed via {addSession}/{removeSession}.
    mapping(address sessionKey => bool allowed) public allowedSession;


    /*//////////////////////////////////////////////////////////////
                                Constructor
    //////////////////////////////////////////////////////////////*/

    constructor() {
        _disableInitializers();
    }
    /*//////////////////////////////////////////////////////////////
                                Initialization
    //////////////////////////////////////////////////////////////*/
    function initialize(
        address owner,
        address entryPointAddress,
        address reputationRegistry,
        address identityRegistry,
        address registry,
        uint256 walletId,
        address spendingLimitModule,
        int256 dailyLimitUsd,
        uint256 windowDuration,
        address[] calldata watchedTokens
    )  external initializer {
        __Ownable_init(owner);
        ENTRY_POINT = entryPointAddress;
        REPUTATION_REGISTRY = reputationRegistry;
        IDENTITY_REGISTRY = identityRegistry;
        REGISTRY = SHRegistry(registry);
        WALLET_ID = walletId;
        SH_MODULE = SpendingLimitModule(spendingLimitModule);

        // Install the spending-limit module as a HOOK only (it is not a validator). Its onInstall
        // decodes exactly this (dailyLimitUsd, windowDuration, watchedTokens) tuple, so the config
        // must be non-empty and valid: windowDuration > 0, dailyLimitUsd >= 0, and every watched
        // token already priced by the oracle.
        _installModule(
            MODULE_TYPE_HOOK, spendingLimitModule, abi.encode(dailyLimitUsd, windowDuration, watchedTokens)
        );

        // Trust the registry's canonical DEX router by default so unpriced-token approvals to it
        // (e.g. an LP token in removeLiquidity) are permitted -- the no-standing-approval rule still
        // forces every such approval to zero within its own transaction. Skipped when no router is
        // configured for this chain. The owner can add/remove trusted spenders later.
        address router = REGISTRY.router();
        if (router != address(0)) SH_MODULE.addTrustedSpender(router);
    }

    function entryPoint() public view override returns (IEntryPoint) {
        return IEntryPoint(ENTRY_POINT);
    }

    /*//////////////////////////////////////////////////////////////
                     OWNER DIRECT-CALL ESCAPE HATCH
    //////////////////////////////////////////////////////////////*/

    /// @dev Allows the EntryPoint, the account itself (self-call), or the owner directly.
    modifier onlyEntryPointOrSelfOrOwner() {
        _onlyEntryPointOrSelfOrOwner();
        _;
    }

    function _onlyEntryPointOrSelfOrOwner() internal view {
        if (msg.sender != owner()) _checkEntryPointOrSelf();
    }

    /**
     * @notice Executes on behalf of the account. Callable by the EntryPoint, the account itself
     *         (via an installed executor), or directly by the owner without a UserOp.
     * @dev The installed SpendingLimitModule hook wraps this call: its preCheck/postCheck enforce
     *      the account's USD spending cap around whatever runs here. For non-owner (session-key)
     *      executions, {_guardSessionExecution} additionally blocks any sub-call to the account's own
     *      admin surface, so a session key cannot uninstall the hook or raise the cap to escape it.
     */
    function execute(bytes32 mode, bytes calldata executionCalldata)
        public
        payable
        override
        whenNotPaused
        onlyEntryPointOrSelfOrOwner
    {
        Mode execMode = Mode.wrap(mode);
        // Owner-initiated calls are unrestricted; any other path (a session-key UserOp via the
        // EntryPoint, or a self-call) must not be able to reach the account's own admin surface.
        if (msg.sender != owner()) _guardSessionExecution(execMode, executionCalldata);
        _execute(execMode, executionCalldata);
    }

    /// @notice Installs an ERC-7579 module. Callable by the EntryPoint, the account itself, or the owner.
    function installModule(uint256 moduleTypeId, address module, bytes calldata initData)
        public
        override
        onlyEntryPointOrSelfOrOwner
    {
        _installModule(moduleTypeId, module, initData);
    }

    /// @notice Uninstalls an ERC-7579 module. Callable by the EntryPoint, the account itself, or the owner.
    function uninstallModule(uint256 moduleTypeId, address module, bytes calldata deInitData)
        public
        override
        onlyEntryPointOrSelfOrOwner
    {
        _uninstallModule(moduleTypeId, module, deInitData);
    }

    /*//////////////////////////////////////////////////////////////
           SPENDING-LIMIT CONFIG (owner-only passthrough to module)
    //////////////////////////////////////////////////////////////*/

    /// @dev Each setter below calls the module AS this account, so the module keys the config under
    ///      this account's address. Kept owner-only on purpose: a session key must never be able to
    ///      raise its own cap or reshape the watched list (see SpendingLimitModule's NatSpec).

    /// @notice Sets the account's max USD spend per window (18 decimals). Forwards to SH_MODULE.setDailyLimit.
    function setDailyLimit(int256 dailyLimitUsd) external onlyOwner {
        SH_MODULE.setDailyLimit(dailyLimitUsd);
    }

    /// @notice Sets the account's spending-window length in seconds. Forwards to SH_MODULE.setWindowDuration.
    function setWindowDuration(uint256 windowDuration) external onlyOwner {
        SH_MODULE.setWindowDuration(windowDuration);
    }

    /// @notice Adds a token to the account's watched (value-metered) list. Forwards to SH_MODULE.addWatchedToken.
    function addWatchedToken(address token) external onlyOwner {
        SH_MODULE.addWatchedToken(token);
    }

    /// @notice Removes a token from the account's watched list. Forwards to SH_MODULE.removeWatchedToken.
    function removeWatchedToken(address token) external onlyOwner {
        SH_MODULE.removeWatchedToken(token);
    }

    /// @notice Returns the account's full spending-limit config from the module.
    function getConfig() external view returns (SpendingLimitModule.Config memory) {
        return SH_MODULE.getConfig(address(this));
    }

    /// @notice Returns whether a token is on the account's watched list.
    function isWatched(address token) external view returns (bool) {
        return SH_MODULE.isWatched(address(this), token);
    }

    /// @notice Returns the account's remaining USD budget for the current window (18 decimals).
    function getRemainingBudget() external view returns (int256) {
        return SH_MODULE.getRemainingBudget(address(this));
    }

    /// @notice Trusts a spender so it may be approved even for unpriced tokens (e.g. the DEX router,
    ///         for removeLiquidity's LP-token approval). Forwards to SH_MODULE.addTrustedSpender.
    /// @dev Owner-only: a trusted spender can pull an unpriced token within a single transaction, so
    ///      only grant it to contracts you trust (the canonical router is auto-trusted at deploy).
    function addTrustedSpender(address spender) external onlyOwner {
        SH_MODULE.addTrustedSpender(spender);
    }

    /// @notice Stops trusting a spender. Forwards to SH_MODULE.removeTrustedSpender.
    function removeTrustedSpender(address spender) external onlyOwner {
        SH_MODULE.removeTrustedSpender(spender);
    }

    /// @notice Returns whether a spender is trusted for this account.
    function isTrustedSpender(address spender) external view returns (bool) {
        return SH_MODULE.isTrustedSpender(address(this), spender);
    }

    /*//////////////////////////////////////////////////////////////
                       SESSION-KEY AUTH (owner-managed)
    //////////////////////////////////////////////////////////////*/

    /**
     * @notice Authorizes `sessionKey` to sign UserOps for this account.
     * @dev SECURITY: a session key is a BARE signer -- once authorized it can drive ANY execute()
     *      call to external targets, gated by the SpendingLimitModule USD spending cap and by
     *      {_guardSessionExecution} (which blocks it from the account's own admin surface). It is
     *      NOT scoped to particular external targets or selectors, and has no expiry; grant keys
     *      only to agents trusted to stay within the cap. Scoped keys (target/selector/expiry) are
     *      a deliberate future step.
     * @param sessionKey The signer address to authorize. Must not be address(0).
     */
    function addSession(address sessionKey) external onlyOwner {
        if (sessionKey == address(0)) revert SessionHandler_InvalidSessionKey();
        allowedSession[sessionKey] = true;
        emit SessionAdded(sessionKey);
    }

    /**
     * @notice Revokes a previously authorized session key. No-op if it was not authorized.
     * @param sessionKey The signer address to revoke.
     */
    function removeSession(address sessionKey) external onlyOwner {
        allowedSession[sessionKey] = false;
        emit SessionRemoved(sessionKey);
    }

    /**
     * @dev UserOp signature validation for this account. Reached via {Account-_validateUserOp}, the
     *      fallback path AccountERC7579 takes whenever the nonce's validator module isn't installed
     *      -- which is always here, since this account installs no validator module. Returns true iff
     *      the op is signed by the owner or by an authorized session key.
     *
     *      `hash` is {Account-_signableUserOpHash} (the raw userOpHash by default). The bot and the
     *      Foundry helper sign the EIP-191 envelope of it (toEthSignedMessageHash /
     *      eth_account.encode_defunct), so it is re-wrapped here before recovery. Uses tryRecover so
     *      a malformed signature returns SIG_VALIDATION_FAILED instead of reverting validation.
     */
    function _rawSignatureValidation(bytes32 hash, bytes calldata signature)
        internal
        view
        override
        returns (bool)
    {
        bytes32 digest = MessageHashUtils.toEthSignedMessageHash(hash);
        (address signer, ECDSA.RecoverError err,) = ECDSA.tryRecoverCalldata(digest, signature);
        if (err != ECDSA.RecoverError.NoError) return false;
        return signer == owner() || allowedSession[signer];
    }

    /**
     * @dev Blocks a non-owner (session-key or self) execution from reaching the account's own admin
     *      surface. Session keys may act on external protocols under the USD cap, but must never be
     *      able to reconfigure or remove the cap itself:
     *        - single / batch: reverts if any sub-call targets address(this) or address(SH_MODULE);
     *        - delegatecall: reverts outright, since delegated code runs in this account's context
     *          and could reach the admin surface regardless of the encoded target.
     *      address(this) is restricted because execute(address(this), ...) self-calls installModule/
     *      uninstallModule/addSession/withdraw/the cap setters with msg.sender == the account, which
     *      those functions accept; SH_MODULE is restricted because its cap setters key by msg.sender.
     */
    function _guardSessionExecution(Mode mode, bytes calldata executionCalldata) internal view {
        (CallType callType,,,) = ERC7579Utils.decodeMode(mode);

        if (callType == ERC7579Utils.CALLTYPE_SINGLE) {
            (address target,,) = ERC7579Utils.decodeSingle(executionCalldata);
            _requireUnrestrictedTarget(target);
        } else if (callType == ERC7579Utils.CALLTYPE_BATCH) {
            Execution[] calldata batch = ERC7579Utils.decodeBatch(executionCalldata);
            for (uint256 i = 0; i < batch.length; i++) {
                _requireUnrestrictedTarget(batch[i].target);
            }
        } else if (callType == ERC7579Utils.CALLTYPE_DELEGATECALL) {
            revert SessionHandler_SessionDelegateCallForbidden();
        }
    }

    /// @dev Reverts if `target` is the account itself or its spending-limit module. See {_guardSessionExecution}.
    function _requireUnrestrictedTarget(address target) internal view {
        if (target == address(this) || target == address(SH_MODULE)) {
            revert SessionHandler_SessionRestrictedTarget(target);
        }
    }

    /*//////////////////////////////////////////////////////////////
                           OWNER-ONLY FUNCTIONS
    //////////////////////////////////////////////////////////////*/

    function pause() external onlyOwner {
        _pause();
    }

    function unpause() external onlyOwner {
        _unpause();
    }

    /**
     * @notice Withdraws ERC20 tokens or native ETH from the wallet to a recipient chosen by the owner.
     * @param token  ERC20 token address to withdraw, or address(0) for native ETH.
     * @param amount Amount to withdraw in the token's base units.
     * @param to     Recipient address for the withdrawn funds.
     */
    function withdraw(address token, uint256 amount, address to) external onlyOwner {
        if (to == address(0)) revert SessionHandler_InvalidRecipient();
        if (token != address(0)) {
            if (IERC20(token).balanceOf(address(this)) < amount) revert SessionHandler_NotEnoughBalance();
            SafeERC20.safeTransfer(IERC20(token), to, amount);
        } else {
            if (address(this).balance < amount) revert SessionHandler_NotEnoughBalance();
            (bool success,) = payable(to).call{value: amount}("");
            if (!success) revert SessionHandler_ExecutionFailed();
        }
    }

    /*//////////////////////////////////////////////////////////////
                             VIEW FUNCTIONS
    //////////////////////////////////////////////////////////////*/

    /// @notice Returns the USD value (18 decimals) of `amount` of `token`, via the registered SHOracle.
    function getUsdValue(address token, uint256 amount) public view returns (int256) {
        return SHOracle(REGISTRY.priceOracle()).getPrice(token, amount);
    }

    function getAgentId() public view returns (uint256) {
        return REGISTRY.agentId();
    }

    /// @notice Returns the agent's ERC-8004 on-chain identity.
    function getAgentIdentity() public view returns (bool registered, uint256 agentId, string memory agentUri) {
        agentId = getAgentId();
        try IIdentityRegistry(IDENTITY_REGISTRY).ownerOf(agentId) returns (address) {
            agentUri = IIdentityRegistry(IDENTITY_REGISTRY).tokenURI(agentId);
            registered = true;
        } catch {
            registered = false;
        }
    }

    /// @notice Returns the agent's on-chain reputation from the Reputation Registry, scoped to this wallet.
    function getAgentReputation()
        public
        view
        returns (uint256 agentId, uint64 feedbackCount, int128 summaryValue, uint8 summaryValueDecimals)
    {
        agentId = getAgentId();
        address[] memory clients = new address[](1);
        clients[0] = address(this);
        (feedbackCount, summaryValue, summaryValueDecimals) =
            IReputationRegistry(REPUTATION_REGISTRY).getSummary(agentId, clients, "", "");
    }

    /// @notice Returns the Uniswap V2 Router address from the registry.
    function getRouter() public view returns (address) {
        return REGISTRY.router();
    }

    /*//////////////////////////////////////////////////////////////
                      CONTEXT OVERRIDE RESOLUTION
    //////////////////////////////////////////////////////////////*/

    /// @dev Resolves the diamond between the non-upgradeable Context (pulled in by the ERC-7579
    ///      account stack) and ContextUpgradeable (pulled in by OwnableUpgradeable). Both are
    ///      stateless and identical for a non-ERC-2771 account, so these return the plain msg.* values.
    function _msgSender() internal view override(Context, ContextUpgradeable) returns (address) {
        return msg.sender;
    }

    function _msgData() internal view override(Context, ContextUpgradeable) returns (bytes calldata) {
        return msg.data;
    }

    function _contextSuffixLength() internal view override(Context, ContextUpgradeable) returns (uint256) {
        return 0;
    }
}
