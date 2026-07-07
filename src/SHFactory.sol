// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Ownable} from "@openzeppelin/contracts/access/Ownable.sol";
import {Pausable} from "@openzeppelin/contracts/utils/Pausable.sol";
import {SessionHandler} from "./SessionHandler.sol";

contract SHFactory is Ownable, Pausable {
    error SHFactory_FundTransferFailed();
    /// @dev Thrown by deployWallet when no SessionHandlerModule has been configured yet.
    error SHFactory_SpendingLimitModuleNotSet();

    /// @notice The SHRegistry address that deployed SessionHandlers read protocol configuration from.
    address private immutable REGISTRY;
    /// @notice The canonical ERC-4337 EntryPoint baked into every deployed SessionHandler.
    address private immutable ENTRY_POINT;
    /// @notice The Reputation Registry baked into every deployed SessionHandler.
    address private immutable REPUTATION_REGISTRY;
    /// @notice The ERC-8004 Identity Registry baked into every deployed SessionHandler.
    address private immutable IDENTITY_REGISTRY;

    /// @notice Total number of wallets deployed. Doubles as the next walletId to assign.
    uint256 public totalWallets;
    /// @notice Maps each sequential walletId to its deployed wallet address.
    mapping(uint256 => address) public wallets;

    /// @notice SessionHandlerModule module address installed on every SessionHandler deployed here.
    /// @dev Settable rather than immutable, consistent with how SHRegistry's own dependent addresses
    ///      (priceOracle, callValueInterpreter, router) are owner-updatable without redeployment.
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
    constructor(address _entryPoint, address _feeRegistry, address _reputationRegistry, address _identityRegistry)
        Ownable(msg.sender)
    {
        ENTRY_POINT = _entryPoint;
        REGISTRY = _feeRegistry;
        REPUTATION_REGISTRY = _reputationRegistry;
        IDENTITY_REGISTRY = _identityRegistry;
    }

    /// @notice Pauses the contract, disabling execute(). Only callable by the owner.
    function pause() public onlyOwner {
        _pause();
    }

    /// @notice Unpauses the contract, re-enabling execute(). Only callable by the owner.
    function unpause() public onlyOwner {
        _unpause();
    }

    /// @notice Sets the SessionHandlerModule module installed on every wallet deployed from
    ///         this point on. Only callable by the owner.
    /// @param newModule The deployed SessionHandlerModule address. May be address(0) to pause
    ///                  deployWallet without pausing the whole factory.
    function setSpendingLimitModule(address newModule) external onlyOwner {
        address old = spendingLimitModule;
        spendingLimitModule = newModule;
        emit SpendingLimitModuleUpdated(old, newModule);
    }

    /// @notice Deploys a SessionHandler (ERC-7579 account) with spendingLimitModule installed as
    ///         both its validator and hook. Reverts if spendingLimitModule hasn't been set.
    function deployWallet() external payable whenNotPaused returns (address) {
        address module = spendingLimitModule;
        if (module == address(0)) revert SHFactory_SpendingLimitModuleNotSet();

        uint256 walletId = totalWallets;
        SessionHandler sessionHandler = new SessionHandler(
            msg.sender, ENTRY_POINT, REPUTATION_REGISTRY, IDENTITY_REGISTRY, REGISTRY, walletId, module
        );

        wallets[walletId] = address(sessionHandler);
        totalWallets = walletId + 1;

        (bool success,) = payable(address(sessionHandler)).call{value: msg.value}("");
        if (!success) {
            revert SHFactory_FundTransferFailed();
        }

        emit WalletDeployed(address(sessionHandler), msg.sender, walletId);
        return address(sessionHandler);
    }
}

