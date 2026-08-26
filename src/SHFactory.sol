// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Ownable} from "@openzeppelin/contracts/access/Ownable.sol";
import {Pausable} from "@openzeppelin/contracts/utils/Pausable.sol";
import {SessionHandler} from "./SessionHandler.sol";
import {Clones} from "@openzeppelin/contracts/proxy/Clones.sol";
import {SHRegistry} from "./SHRegistry.sol";

contract SHFactory is Ownable, Pausable {
    error SHFactory_FundTransferFailed();
    /// @dev Thrown by deployWallet when no SpendingLimitModule has been configured yet.
    error SHFactory_SpendingLimitModuleNotSet();

    /// @notice The SHRegistry deployed SessionHandlers read all protocol configuration from —
    ///         EntryPoint, the two ERC-8004 registries, and the SpendingLimitModule to install.
    /// @dev Immutable: a factory is bound to one registry for life. Point wallets at a different
    ///      registry by deploying a new factory and recording it with SHRegistry.setFactory.
    SHRegistry public immutable REGISTRY;

    address public immutable IMPLEMENTATION;

    /// @notice Total number of wallets deployed. Doubles as the next walletId to assign.
    uint256 public totalWallets;
    /// @notice Maps each sequential walletId to its deployed wallet address.
    mapping(uint256 => address) public wallets;

    event WalletDeployed(address indexed walletAddress, address indexed owner, uint256 indexed walletId);

    /**
     * @notice Deploys the factory and the SessionHandler implementation it clones from.
     * @dev Every other address a wallet needs (EntryPoint, reputation/identity registries, the
     *      SpendingLimitModule) is read from the registry at deploy-wallet time rather than stored
     *      here, so those can be corrected in one place without redeploying this factory.
     * @param owner     Address that will own this factory — the SHTreasury, the protocol's single
     *                  admin root. Supplied rather than taken from msg.sender so no follow-up
     *                  transferOwnership is needed; the operator reaches {pause}/{unpause} through
     *                  SHTreasury's owner-only passthroughs.
     * @param _registry The SHRegistry this factory and its wallets read configuration from.
     */
    constructor(address owner, address _registry) Ownable(owner) {
        REGISTRY = SHRegistry(_registry);
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
        address module = REGISTRY.spendingLimitModule();
        if (module == address(0)) revert SHFactory_SpendingLimitModuleNotSet();

        uint256 walletId = totalWallets;
        address walletInstance = Clones.clone(IMPLEMENTATION);
        SessionHandler(payable(walletInstance))
            .initialize(
                msg.sender,
                REGISTRY.ENTRY_POINT(),
                REGISTRY.REPUTATION_REGISTRY(),
                REGISTRY.IDENTITY_REGISTRY(),
                address(REGISTRY),
                walletId,
                module,
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

