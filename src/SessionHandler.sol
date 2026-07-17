// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {IEntryPoint} from "@openzeppelin/contracts/interfaces/draft-IERC4337.sol";
import {AccountERC7579Hooked} from "@openzeppelin/contracts/account/extensions/draft-AccountERC7579Hooked.sol";
import {MODULE_TYPE_VALIDATOR, MODULE_TYPE_HOOK} from "@openzeppelin/contracts/interfaces/draft-IERC7579.sol";
import {Mode} from "@openzeppelin/contracts/account/utils/draft-ERC7579Utils.sol";
import {OwnableUpgradeable} from "@openzeppelin/contracts-upgradeable/access/OwnableUpgradeable.sol";
import {Pausable} from "@openzeppelin/contracts/utils/Pausable.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {SHOracle} from "./SHOracle.sol";
import {SHRegistry} from "./SHRegistry.sol";
import {SessionHandlerModule} from "./SessionHandlerModule.sol";
import {IReputationRegistry} from "./interfaces/IReputationRegistry.sol";
import {IIdentityRegistry} from "./interfaces/IIdentityRegistry.sol";
import {Context} from "@openzeppelin/contracts/utils/Context.sol";
import {ContextUpgradeable} from "@openzeppelin/contracts-upgradeable/utils/ContextUpgradeable.sol";

/**
 * @title SessionHandler
 * @author Conrad Japhet
 * @notice ERC-7579 smart account with delegated, spending-limited session-key permissions.
 *         Session-key state and USD-value enforcement live entirely in the installed
 *         SessionHandlerModule (installed as both validator and hook); this contract only keeps
 *         the account-level concerns that aren't session-key specific (ownership, ETH/ERC20
 *         withdrawal, pausing, protocol fee charging, and the ERC-8004 identity/reputation
 *         lookups).
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
    /// @dev Thrown when the protocol fee ETH transfer to the treasury fails.
    error SessionHandler_FeeTransferFailed();

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
    /// @dev Installed as both MODULE_TYPE_VALIDATOR and MODULE_TYPE_HOOK in initialize().
    SessionHandlerModule public SH_MODULE;

    
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
        address spendingLimitModule
    )  external initializer {
        __Ownable_init(owner);
        ENTRY_POINT = entryPointAddress;
        REPUTATION_REGISTRY = reputationRegistry;
        IDENTITY_REGISTRY = identityRegistry;
        REGISTRY = SHRegistry(registry);
        WALLET_ID = walletId;
        SH_MODULE = SessionHandlerModule(spendingLimitModule);

        _installModule(MODULE_TYPE_VALIDATOR, spendingLimitModule, "");
        _installModule(MODULE_TYPE_HOOK, spendingLimitModule, "");
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
     * @dev Charges a flat protocol fee when this call was driven by a session key through the
     *      EntryPoint. SessionHandlerModule.pendingSessionKey reflects whatever validateUserOp
     *      flagged for this account this transaction; it stays address(0) for owner-initiated
     *      calls, so no fee is charged for those.
     */
    function execute(bytes32 mode, bytes calldata executionCalldata)
        public
        payable
        override
        whenNotPaused
        onlyEntryPointOrSelfOrOwner
    {
        bool isSessionKeyExecution =
            msg.sender == address(entryPoint()) && SH_MODULE.pendingSessionKey(address(this), keccak256(msg.data)) != address(0);

        _execute(Mode.wrap(mode), executionCalldata);

        uint256 fee = REGISTRY.protocolFee();
        if (isSessionKeyExecution && fee > 0) {
            (bool feeSuccess,) = payable(REGISTRY.treasury()).call{value: fee}("");
            if (!feeSuccess) revert SessionHandler_FeeTransferFailed();
        }
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
              SESSION-KEY MANAGEMENT (passthrough to the module)
    //////////////////////////////////////////////////////////////*/

    /**
     * @notice Registers a new delegated session key. Forwards to SH_MODULE.addSessionKey,
     *         calling it as this account (so the module records the session under this account's address).
     * @dev See SessionHandlerModule for the actual validation and storage.
     */
    function addSessionKey(
        address sessionKey,
        address target,
        bytes4[] calldata selectors,
        uint48 validFrom,
        uint48 validUntil,
        uint256 spendingLimit
    ) external onlyOwner{

        SH_MODULE.addSessionKey(sessionKey, target, selectors, validFrom, validUntil, spendingLimit);
    }

    /**
     * @notice Registers a session key exempt from USD-value pricing (e.g. for calling contracts
     *         SHOracle has no price for). Forwards to SH_MODULE.addUnpricedSessionKey.
     */
    function addUnpricedSessionKey(
        address sessionKey,
        address target,
        bytes4[] calldata selectors,
        uint48 validFrom,
        uint48 validUntil
    ) external onlyOwner {
        SH_MODULE.addUnpricedSessionKey(sessionKey, target, selectors, validFrom, validUntil);
    }

    /// @notice Revokes a session key. Forwards to SH_MODULE.revokeSessionKey.
    function revokeSessionKey(address sessionKey) external onlyOwner {
        SH_MODULE.revokeSessionKey(sessionKey);
    }

    /// @notice Returns the full Session struct for a given session key on this account.
    function getSession(address sessionKey) external view returns (SessionHandlerModule.Session memory) {
        return SH_MODULE.getSession(address(this), sessionKey);
    }

    /// @notice Returns whether a session key is currently active on this account.
    function isSessionActive(address sessionKey) external view returns (bool) {
        return SH_MODULE.isSessionActive(address(this), sessionKey);
    }

    /// @notice Returns the remaining USD spending budget for a session key on this account.
    function getRemainingBudget(address sessionKey) external view returns (uint256) {
        return SH_MODULE.getRemainingBudget(address(this), sessionKey);
    }

    /// @notice Checks whether a proposed spend is within the session's remaining budget.
    function isSpendingWithinBudget(address sessionKey, address token, uint256 amount) external view returns (bool) {
        return SH_MODULE.isSpendingWithinBudget(address(this), sessionKey, token, amount);
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

    /// @notice Returns the current USD price of a token by querying the registered SHOracle.
    function getPrice(address token) public view returns (uint256 price, uint8 decimals) {
        return SHOracle(REGISTRY.priceOracle()).getPrice(token);
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
