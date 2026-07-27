// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Ownable} from "@openzeppelin/contracts/access/Ownable.sol";
import {Pausable} from "@openzeppelin/contracts/utils/Pausable.sol";
import {SessionHandler} from "./SessionHandler.sol";
import {Clones} from "@openzeppelin/contracts/proxy/Clones.sol";

contract SHFactory is Ownable, Pausable {
    error SHFactory_FundTransferFailed();
    /// @dev Thrown by deployWallet when no SpendingLimitModule has been configured yet.
    error SHFactory_SpendingLimitModuleNotSet();

    /// @notice The SHRegistry address that deployed SessionHandlers read protocol configuration from.
    address private immutable REGISTRY;
    /// @notice The canonical ERC-4337 EntryPoint baked into every deployed SessionHandler.
    address private immutable ENTRY_POINT;
    /// @notice The Reputation Registry baked into every deployed SessionHandler.
    address private immutable REPUTATION_REGISTRY;
    /// @notice The ERC-8004 Identity Registry baked into every deployed SessionHandler.
    address private immutable IDENTITY_REGISTRY;

    address public immutable IMPLEMENTATION;

    /// @notice Total number of wallets deployed. Doubles as the next walletId to assign.
    uint256 public totalWallets=1;
    /// @notice Maps each sequential walletId to its deployed wallet address.
    mapping(uint256 => address) public wallets;

    /// @notice SpendingLimitModule module address installed on every SessionHandler deployed here.
    /// @dev Settable rather than immutable, consistent with how SHRegistry's own dependent addresses
    ///      (priceOracle, router) are owner-updatable without redeployment.
    ///      deployWallet reverts while this is unset.
    address public spendingLimitModule;

    event WalletDeployed(address indexed walletAddress, address indexed owner, uint256 indexed walletId);
    event SpendingLimitModuleUpdated(address indexed oldModule, address indexed newModule);

    /**
     * @param _entryPoint         The canonical ERC-4337 EntryPoint address.
     * @param _feeRegistry        The SHRegistry address that deployed Session Handlers read
     *                            protocol configuration (fee, treasury, oracle, etc.) from.
     * @param _reputationRegistry The Reputation Registry address.
     * @param _identityRegistry   The ERC-8004 Identity Registry address.
     */
    constructor(address _entryPoint, address _feeRegistry, address _reputationRegistry, address _identityRegistry,address _module)
        Ownable(msg.sender)
    {
        ENTRY_POINT = _entryPoint;
        REGISTRY = _feeRegistry;
        REPUTATION_REGISTRY = _reputationRegistry;
        IDENTITY_REGISTRY = _identityRegistry;
        spendingLimitModule = _module;
        IMPLEMENTATION = address(new SessionHandler());


    }

    /// @notice Pauses the contract, disabling execute(). Only callable by the owner.
    function pause() public onlyOwner {
        _pause();
    }

    /// @notice Unpauses the contract, re-enabling execute(). Only callable by the owner.
    function unpause() public onlyOwner {
        _unpause();
    }

    /// @notice Sets the SpendingLimitModule module installed on every wallet deployed from
    ///         this point on. Only callable by the owner.
    /// @param newModule The deployed SpendingLimitModule address. May be address(0) to pause
    ///                  deployWallet without pausing the whole factory.
    function setSpendingLimitModule(address newModule) external onlyOwner {
        address old = spendingLimitModule;
        spendingLimitModule = newModule;
        emit SpendingLimitModuleUpdated(old, newModule);
    }

    /// @notice Deploys a SessionHandler (ERC-7579 account) with spendingLimitModule installed as a
    ///         hook, seeded with the caller's spending-cap config. Reverts if the module isn't set.
    /// @param dailyLimitUsd  Max USD (18 decimals) the wallet may spend per window. Must be >= 0.
    /// @param windowDuration Spending-window length in seconds. Must be > 0.
    /// @param watchedTokens  Tokens to meter; each must already be priced by the oracle.
    function deployWallet(int256 dailyLimitUsd, uint256 windowDuration, address[] calldata watchedTokens)
        external
        payable
        whenNotPaused
        returns (address)
    {
        if (spendingLimitModule == address(0)) revert SHFactory_SpendingLimitModuleNotSet();

        uint256 walletId = totalWallets;
        address walletInstance = Clones.clone(IMPLEMENTATION);
        SessionHandler(payable(walletInstance)).initialize(
            msg.sender,
            ENTRY_POINT,
            REPUTATION_REGISTRY,
            IDENTITY_REGISTRY,
            REGISTRY,
            walletId,
            spendingLimitModule,
            dailyLimitUsd,
            windowDuration,
            watchedTokens
        );

        wallets[walletId] = walletInstance;
        totalWallets = walletId + 1;

        (bool success,) = payable(walletInstance).call{value: msg.value}("");
        if (!success) {
            revert SHFactory_FundTransferFailed();
        }

        emit WalletDeployed(walletInstance, msg.sender, walletId);
        return walletInstance;
    }
}

