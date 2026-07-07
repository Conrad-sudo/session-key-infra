//SPDX-License-Identifier:MIT
pragma solidity ^0.8.24;
import {Test} from "forge-std/Test.sol";
//Account abstraction Imports
import {PackedUserOperation} from "@account-abstraction/contracts/interfaces/PackedUserOperation.sol";
import {IEntryPoint} from "@account-abstraction/contracts/interfaces/IEntryPoint.sol";
//Openzeppelin Imports
import {ECDSA} from "@openzeppelin/contracts/utils/cryptography/ECDSA.sol";
import {Pausable} from "@openzeppelin/contracts/utils/Pausable.sol";
import {Ownable} from "@openzeppelin/contracts/access/Ownable.sol";
import {Errors} from "@openzeppelin/contracts/utils/Errors.sol";
import {Account as OZAccount} from "@openzeppelin/contracts/account/Account.sol";
import {PackedUserOperation as OZPackedUserOperation} from "@openzeppelin/contracts/interfaces/draft-IERC4337.sol";
//Local imports
import {SessionHandler} from "../../src/SessionHandler.sol";
import {SessionHandlerModule} from "../../src/SessionHandlerModule.sol";
import {HelperConfig} from "../../script/HelperConfig.s.sol";
import {SendPackedUserOp} from "../../script/SendPackedUserOp.s.sol";
import {DeploySHProtocol} from "../../script/DeploySHProtocol.s.sol";
import {ERC20Mock} from "../../src/mocks/ERC20Mock.sol";
import {MockWeth} from "../../src/mocks/MockWeth.sol";
import {SHOracle} from "../../src/SHOracle.sol";
import {SHRegistry} from "../../src/SHRegistry.sol";
import {SHFactory} from "../../src/SHFactory.sol";
import {SHTreasury} from "../../src/SHTreasury.sol";
import {SessionHandlerModuleHarness} from "./SessionHandlerModuleHarness.sol";
import {MockV3Aggregator} from "../../src/mocks/MockV3Aggregator.sol";

/**
 * @title SHProtocolTest
 * @author Conrad Japhet
 * @notice Test suite for SessionHandler, the ERC-7579 smart account with delegated,
 *         spending-limited session-key permissions.
 * @dev Tests cover access control, session validation, EntryPoint integration, spending limits,
 *      view functions, and event emissions. A few shape notes worth knowing up front:
 *      - execute() takes (bytes32 mode, bytes executionCalldata), the standard ERC-7579 shape --
 *        the target/value/inner-calldata are packed together into executionCalldata.
 *      - Session-key state/logic lives entirely in SessionHandlerModule (installed as both
 *        validator and hook), not on the account itself; SessionHandler only exposes passthroughs.
 *      - execute/installModule/uninstallModule are gated by onlyEntryPointOrSelfOrOwner, which
 *        reverts with OZAccount.AccountUnauthorized (inherited from OZ's Account.sol);
 *        addSessionKey/revokeSessionKey are gated by plain onlyOwner (Ownable), which reverts with
 *        Ownable.OwnableUnauthorizedAccount instead -- two different errors depending on which
 *        function you're testing.
 *      - There is no owner-mode UserOp path: SessionHandlerModule is the only installed validator
 *        and it rejects any signer that isn't a registered session key. SendPackedUserOp only
 *        signs session-key ops; tests that need an owner-signed UserOp (to prove it's rejected)
 *        build one manually with the same script, signing with the Anvil owner key.
 *      - execute() charges a flat protocol fee on session-key-driven calls, determined via
 *        SessionHandlerModule.pendingSessionKey rather than an internal transient variable, since
 *        session state lives in the module.
 *
 * NB Casting to 'uint160' is safe because we extract the lower 160 bits
 *      of the packed validation data which contains the aggregator/sig validation result
 */
contract SHProtocolTest is Test {
    ERC20Mock usdc;
    ERC20Mock dai;
    MockWeth weth;
    SHOracle oracle;
    SHRegistry feeRegistry;
    SHTreasury treasury;
    HelperConfig.NetworkConfig config;
    SessionHandler sessionHandler;
    SessionHandlerModule spendingLimitModule;
    SendPackedUserOp sendPackedUserOp;
    bytes4[] selectors;

    /// @dev Amount minted to SessionHandler for ERC20 tests
    uint256 constant AMOUNT_TO_MINT = 1000 ether;

    /// @dev Initial ETH balance given to SessionHandler
    uint256 constant INTITIAL_ACCOUNT_BALANCE = 10 ether;

    /// @dev Spending limit in USD with 18 decimals (e.g., 5000 USDC = 5000 * 10^18 for precision in the oracle)
    uint256 constant BUDGET = 5000e18;
    /// @dev Example ETH value used in tests that verify USD value tracking through the oracle
    uint256 constant ETH_VALUE = 5e18;

    uint256 constant AMOUNT_TO_TRANSFER = 1000e6;

    /// @dev Anvil's default private key for config.account (0xf39Fd6e51aad88F6F4ce6aB8827279cffFb9226),
    ///      used only by the two tests that must prove an owner-signed UserOp is rejected.
    uint256 constant ANVIL_OWNER_KEY = 0xac0974bec39a17e36ba4a6b4d238ff944bacb478cbed5efcae784d7bf4f2ff80;

    /// @dev Session key holder — generated with a known private key for signature tests
    address user;
    uint256 privateKey;
    address kani = makeAddr("kani");

    /// @dev Simulates a bundler submitting ops to the EntryPoint
    address bundler = makeAddr("bundler");

    /*//////////////////////////////////////////////////////////////
                                MODIFIERS
    //////////////////////////////////////////////////////////////*/

    /**
     * @dev Adds a standard ERC20 transfer session for `user` on the `usdc` mock token.
     *      Grants access to ERC20Mock.transfer only, within a 1-day window, with BUDGET spending limit.
     */
    modifier sessionAdded() {
        address sessionKey = user;
        address target = address(usdc);
        bytes4[] memory sel = new bytes4[](3);
        sel[0] = ERC20Mock.transfer.selector;
        sel[1] = ERC20Mock.transferFrom.selector;
        sel[2] = ERC20Mock.approve.selector;

        uint48 validFrom = uint48(block.timestamp + 1 hours);
        uint48 validUntil = uint48(block.timestamp + 3 hours);
        uint256 spendingLimit = BUDGET;

        vm.prank(sessionHandler.owner());
        sessionHandler.addSessionKey(sessionKey, target, sel, validFrom, validUntil, spendingLimit);

        _;
    }

    /**
     * @dev Adds a session for `user` scoped to the WETH contract (transfer/transferFrom/approve/deposit/withdraw).
     */
    modifier wethSessionAdded() {
        address sessionKey = user;
        address target = config.weth;
        bytes4[] memory sel = new bytes4[](5);
        sel[0] = MockWeth.transfer.selector;
        sel[1] = MockWeth.transferFrom.selector;
        sel[2] = MockWeth.approve.selector;
        sel[3] = MockWeth.deposit.selector;
        sel[4] = MockWeth.withdraw.selector;
        uint48 validFrom = uint48(block.timestamp);
        uint48 validUntil = uint48(block.timestamp + 1 days);
        uint256 spendingLimit = BUDGET;

        vm.prank(sessionHandler.owner());
        sessionHandler.addSessionKey(sessionKey, target, sel, validFrom, validUntil, spendingLimit);

        _;
    }

    modifier ethSessionAdded() {
        address sessionKey = user;
        address target = address(0); // Sentinel for native ETH-send session
        bytes4[] memory sel = new bytes4[](0); // No selectors for native ETH session
        uint48 validFrom = uint48(block.timestamp);
        uint48 validUntil = uint48(block.timestamp + 1 days);
        uint256 spendingLimit = BUDGET;

        vm.prank(sessionHandler.owner());
        sessionHandler.addSessionKey(sessionKey, target, sel, validFrom, validUntil, spendingLimit);

        _;
    }

    /*//////////////////////////////////////////////////////////////
                                 SETUP
    //////////////////////////////////////////////////////////////*/

    /**
     * @dev Deploys all required contracts and funds the SessionHandler.
     *      - Generates a named user address and private key for session signing
     *      - Deploys SessionHandler via DeploySHProtocol + SHFactory.deployWallet()
     *      - Deploys SendPackedUserOp helper and reads the mock tokens from config
     *      - Funds SessionHandler with 1 ETH and mints mock tokens to it
     */
    function setUp() public {
        (user, privateKey) = makeAddrAndKey("user");
        DeploySHProtocol deployer = new DeploySHProtocol();
        SHFactory factory;
        (factory, treasury, config, oracle) = deployer.run();
        feeRegistry = SHRegistry(treasury.REGISTRY());
        spendingLimitModule = SessionHandlerModule(factory.spendingLimitModule());
        vm.prank(config.account);
        sessionHandler = SessionHandler(payable(factory.deployWallet()));
        sendPackedUserOp = new SendPackedUserOp();
        usdc = ERC20Mock(config.usdc);
        dai = ERC20Mock(config.dai);
        weth = MockWeth(payable(config.weth));
        vm.deal(address(sessionHandler), INTITIAL_ACCOUNT_BALANCE);
        usdc.mint(address(sessionHandler), 10000e6);
        dai.mint(address(sessionHandler), 10000e18);
        weth.mint(address(sessionHandler), 1000e18);
    }

    /*//////////////////////////////////////////////////////////////
                          CALLDATA / ORACLE HELPERS
    //////////////////////////////////////////////////////////////*/

    /// @dev Packs (dest, value, data) into the ERC-7579 single-execution calldata expected by
    ///      SessionHandler.execute(bytes32 mode, bytes executionCalldata) when called directly
    ///      (owner path) rather than through a signed UserOp.
    function _encodeExecutionCalldata(address dest, uint256 value, bytes memory data)
        internal
        pure
        returns (bytes memory)
    {
        return abi.encodePacked(dest, value, data);
    }

    /**
     * @dev SendPackedUserOp returns account-abstraction's PackedUserOperation (needed for
     *      IEntryPoint.handleOps, which is typed against that same package). SessionHandler's
     *      validateUserOp is typed against OZ's own PackedUserOperation (via OZ's Account.sol) --
     *      structurally identical (same field order/types) but a distinct Solidity type, so a direct
     *      call (bypassing the real EntryPoint's raw calldata dispatch) needs an explicit field-by-field
     *      copy rather than an implicit conversion.
     */
    function _toOzUserOp(PackedUserOperation memory userOp) internal pure returns (OZPackedUserOperation memory) {
        return OZPackedUserOperation({
            sender: userOp.sender,
            nonce: userOp.nonce,
            initCode: userOp.initCode,
            callData: userOp.callData,
            accountGasLimits: userOp.accountGasLimits,
            preVerificationGas: userOp.preVerificationGas,
            gasFees: userOp.gasFees,
            paymasterAndData: userOp.paymasterAndData,
            signature: userOp.signature
        });
    }

    /**
     * @dev Refreshes every mock price feed's updatedAt to block.timestamp after a vm.warp.
     *      Required whenever warping more than the per-feed heartbeat (1 hour on Anvil) in
     *      tests where the session is still active and the oracle will be queried.
     */
    function _refreshMockFeeds() internal {
        _refreshMockFeed(config.ethUsdPriceFeed);
        _refreshMockFeed(config.usdcUsdPriceFeed);
        _refreshMockFeed(config.daiUsdPriceFeed);
        _refreshMockFeed(config.usdtUsdPriceFeed);
        _refreshMockFeed(config.aaveUsdPriceFeed);
        _refreshMockFeed(config.linkUsdPriceFeed);
        _refreshMockFeed(config.oneinchUsdPriceFeed);
        _refreshMockFeed(config.apeUsdPriceFeed);
        _refreshMockFeed(config.arbUsdPriceFeed);
        _refreshMockFeed(config.bnbUsdPriceFeed);
        _refreshMockFeed(config.btcUsdPriceFeed);
        _refreshMockFeed(config.compUsdPriceFeed);
        _refreshMockFeed(config.crvUsdPriceFeed);
        _refreshMockFeed(config.ensUsdPriceFeed);
        _refreshMockFeed(config.sandUsdPriceFeed);
        _refreshMockFeed(config.sushiUsdPriceFeed);
        _refreshMockFeed(config.wtaoUsdPriceFeed);
        _refreshMockFeed(config.uniUsdPriceFeed);
        _refreshMockFeed(config.yfiUsdPriceFeed);
    }

    function _refreshMockFeed(address feed) private {
        if (feed == address(0)) return;
        MockV3Aggregator mock = MockV3Aggregator(feed);
        mock.updateAnswer(mock.latestAnswer());
    }

    /*//////////////////////////////////////////////////////////////
                            ACCESS CONTROL TESTS
    //////////////////////////////////////////////////////////////*/

    /// @notice validateUserOp must revert when called by any address other than the EntryPoint
    function testValidateUserOpRevertsForNonEntryPoint() public {
        (PackedUserOperation memory userOp, bytes32 userOpHash,) = sendPackedUserOp.generateSignedUserOp(
            address(sessionHandler), config, address(spendingLimitModule), address(usdc), 0, "", user, privateKey
        );

        vm.expectRevert(abi.encodeWithSelector(OZAccount.AccountUnauthorized.selector, user));
        vm.prank(user); // not the EntryPoint
        sessionHandler.validateUserOp(_toOzUserOp(userOp), userOpHash, 0);
    }

    /// @notice Non-owners must not be able to call execute directly
    function testNonOwnerCannotExecuteCommand() public {
        bytes memory data = abi.encodeWithSelector(ERC20Mock.mint.selector, user, AMOUNT_TO_MINT);

        vm.expectRevert(abi.encodeWithSelector(OZAccount.AccountUnauthorized.selector, user));
        vm.prank(user);
        sessionHandler.execute(bytes32(0), _encodeExecutionCalldata(address(usdc), 0, data));
    }

    /// @notice Owner must be able to execute arbitrary calls on behalf of the account directly (no UserOp)
    function testOwnerCanExecuteCommand() public {
        bytes memory data = abi.encodeWithSelector(ERC20Mock.mint.selector, user, AMOUNT_TO_MINT);

        vm.prank(sessionHandler.owner());
        sessionHandler.execute(bytes32(0), _encodeExecutionCalldata(address(usdc), 0, data));
        assertEq(usdc.balanceOf(user), AMOUNT_TO_MINT);
    }

    /// @notice Owner must be able to pause the contract, blocking execute calls
    function testOwnerCanPauseExecution() public {
        bytes memory data = abi.encodeWithSelector(ERC20Mock.mint.selector, user, AMOUNT_TO_MINT);

        vm.startPrank(sessionHandler.owner());
        sessionHandler.pause();
        vm.expectRevert(Pausable.EnforcedPause.selector);
        sessionHandler.execute(bytes32(0), _encodeExecutionCalldata(address(usdc), 0, data));
        vm.stopPrank();
    }

    /// @notice Owner must be able to unpause and resume normal execution
    function testOwnerCanUpauseExecution() public {
        bytes memory data = abi.encodeWithSelector(ERC20Mock.mint.selector, user, AMOUNT_TO_MINT);

        vm.startPrank(sessionHandler.owner());
        sessionHandler.pause();
        sessionHandler.unpause();
        sessionHandler.execute(bytes32(0), _encodeExecutionCalldata(address(usdc), 0, data));
        vm.stopPrank();

        assertEq(usdc.balanceOf(user), AMOUNT_TO_MINT);
    }

    /// @notice Owner must be able to register a new session key with valid parameters
    function testOwnerCanAddSessionKey() public {
        address sessionKey = user;
        address target = address(usdc);
        selectors.push(ERC20Mock.transfer.selector);
        uint48 validFrom = uint48(block.timestamp);
        uint48 validUntil = uint48(block.timestamp + 1 days);
        uint256 spendingLimit = 0.005e18;

        vm.prank(sessionHandler.owner());
        sessionHandler.addSessionKey(sessionKey, target, selectors, validFrom, validUntil, spendingLimit);

        assertEq(sessionHandler.isSessionActive(sessionKey), true);
    }

    /// @notice Non-owners must not be able to revoke session keys
    function testNonOwnerCannotRevokeSession() public sessionAdded {
        vm.startPrank(user);
        vm.expectRevert(abi.encodeWithSelector(Ownable.OwnableUnauthorizedAccount.selector, user));
        sessionHandler.revokeSessionKey(user);
        vm.stopPrank();
    }

    /// @notice Owner must be able to revoke an active session key, deactivating it immediately
    function testOwnerCanRevokeSession() public sessionAdded {
        vm.startPrank(sessionHandler.owner());
        sessionHandler.revokeSessionKey(user);
        vm.stopPrank();

        assertEq(sessionHandler.isSessionActive(user), false);
    }

    /// @notice Non-owners must not be able to register session keys
    function testNonOwnerCannotAddSessionKey() public {
        address sessionKey = user;
        address target = address(usdc);
        selectors.push(ERC20Mock.transfer.selector);
        uint48 validFrom = uint48(block.timestamp);
        uint48 validUntil = uint48(block.timestamp + 1 days);
        uint256 spendingLimit = BUDGET;

        vm.startPrank(user);
        vm.expectRevert(abi.encodeWithSelector(Ownable.OwnableUnauthorizedAccount.selector, user));
        sessionHandler.addSessionKey(sessionKey, target, selectors, validFrom, validUntil, spendingLimit);
        vm.stopPrank();
    }

    /// @notice Non-owners must not be able to pause the contract
    function testNonOwnerCannotPause() public {
        vm.startPrank(user);
        vm.expectRevert(abi.encodeWithSelector(Ownable.OwnableUnauthorizedAccount.selector, user));
        sessionHandler.pause();
        vm.stopPrank();
    }

    /**
     * @notice Session keys must not be able to call execute directly
     * @dev Session keys are only valid as signers on UserOps submitted through the EntryPoint.
     *      Direct calls to execute must be rejected even for registered session keys.
     */
    function testSessionKeyCannotCallExecuteDirectly() public sessionAdded {
        bytes memory data = abi.encodeWithSelector(ERC20Mock.transfer.selector, user, 1000e18);

        vm.expectRevert(abi.encodeWithSelector(OZAccount.AccountUnauthorized.selector, user));
        vm.prank(user);
        sessionHandler.execute(bytes32(0), _encodeExecutionCalldata(address(usdc), 0, data));
    }

    /*//////////////////////////////////////////////////////////////
                               VALIDATION TESTS
    //////////////////////////////////////////////////////////////*/

    /// @notice validateUserOp must return SIG_VALIDATION_FAILED when the signer is neither the owner nor a registered session key
    function testValidateUserOpFailsWithUnknownSigner() public {
        (address random, uint256 randomKey) = makeAddrAndKey("random");

        (PackedUserOperation memory userOp, bytes32 userOpHash,) = sendPackedUserOp.generateSignedUserOp(
            address(sessionHandler), config, address(spendingLimitModule), address(usdc), 0, "", random, randomKey
        );

        vm.prank(config.entryPoint);
        uint256 validationData = sessionHandler.validateUserOp(_toOzUserOp(userOp), userOpHash, 0);

        // forge-lint: disable-next-line(unsafe-typecast)
        assertEq(uint160(validationData), 1); // SIG_VALIDATION_FAILED
    }

    /// @notice execute must revert (OZ's Errors.FailedCall) when the underlying call reverts
    function testExecuteRevertsWhenCallFails() public {
        // Call a non-existent function on a contract that doesn't accept it
        bytes memory badCallData = abi.encodeWithSignature("nonExistentFunction()");

        vm.prank(sessionHandler.owner());
        vm.expectRevert(Errors.FailedCall.selector);
        sessionHandler.execute(bytes32(0), _encodeExecutionCalldata(address(usdc), 0, badCallData));
    }

    /**
     * @notice An owner-signed UserOp must fail validation on SessionHandler
     * @dev SessionHandler has no owner validator module installed — SessionHandlerModule is the
     *      only validator and it explicitly rejects any signer that isn't a registered session
     *      key. Owner actions go through the direct-call escape hatch instead (see execute()),
     *      never through the EntryPoint. Signs with the Anvil default key backing config.account,
     *      routed (via the nonce key) to SessionHandlerModule exactly like a real session-key op
     *      would be, to prove that path is rejected rather than just untested.
     */
    function testValidateUserOpFailsForOwnerSignedUserOp() public {
        uint256 missingAccountFunds = 1 ether;
        bytes memory data = abi.encodeWithSelector(ERC20Mock.mint.selector, user, AMOUNT_TO_MINT);

        (PackedUserOperation memory userOp, bytes32 userOpHash,) = sendPackedUserOp.generateSignedUserOp(
            address(sessionHandler),
            config,
            address(spendingLimitModule),
            address(usdc),
            0,
            data,
            config.account,
            ANVIL_OWNER_KEY
        );

        vm.prank(config.entryPoint);
        uint256 validationData = sessionHandler.validateUserOp(_toOzUserOp(userOp), userOpHash, missingAccountFunds);

        // forge-lint: disable-next-line(unsafe-typecast)
        assertEq(uint160(validationData), 1); // SIG_VALIDATION_FAILED — owner is not a registered session key
    }

    /**
     * @notice Session-key-signed UserOps must pass validation when all session constraints are met
     */
    function testValidateUserOpWithSession() public sessionAdded {
        uint256 missingAccountFunds = 1 ether;
        uint256 amountToTransfer = AMOUNT_TO_TRANSFER;

        bytes memory data = abi.encodeWithSelector(ERC20Mock.transfer.selector, user, amountToTransfer);
        (PackedUserOperation memory userOp, bytes32 userOpHash,) = sendPackedUserOp.generateSignedUserOp(
            address(sessionHandler), config, address(spendingLimitModule), address(usdc), 0, data, user, privateKey
        );

        vm.warp(block.timestamp + 1 hours);
        vm.startPrank(config.entryPoint);
        uint256 validationData = sessionHandler.validateUserOp(_toOzUserOp(userOp), userOpHash, missingAccountFunds);
        vm.stopPrank();

        // forge-lint: disable-next-line(unsafe-typecast)
        uint160 aggregator = uint160(validationData);
        assertEq(aggregator, 0);
    }

    /**
     * @notice Session-key-signed UserOps must fail validation when targeting a non-whitelisted contract
     */
    function testValidateUserOpFailsWithWrongTarget() public sessionAdded {
        address wrongDest = makeAddr("wrongTarget");
        uint256 missingAccountFunds = 1 ether;
        uint256 amountToTransfer = AMOUNT_TO_TRANSFER;

        bytes memory data = abi.encodeWithSelector(ERC20Mock.transfer.selector, user, amountToTransfer);
        (PackedUserOperation memory userOp, bytes32 userOpHash,) = sendPackedUserOp.generateSignedUserOp(
            address(sessionHandler), config, address(spendingLimitModule), wrongDest, 0, data, user, privateKey
        );

        vm.prank(config.entryPoint);
        uint256 validationData = sessionHandler.validateUserOp(_toOzUserOp(userOp), userOpHash, missingAccountFunds);

        // forge-lint: disable-next-line(unsafe-typecast)
        uint160 aggregator = uint160(validationData);
        assertEq(aggregator, 1);
    }

    /**
     * @notice Session-key-signed UserOps must fail validation when using a non-whitelisted function selector
     */
    function testValidateUserOpFailsWithUnauthorisedSelector() public sessionAdded {
        uint256 missingAccountFunds = 1 ether;
        uint256 amountToTransfer = AMOUNT_TO_TRANSFER;

        bytes memory data = abi.encodeWithSelector(ERC20Mock.mint.selector, user, amountToTransfer);
        (PackedUserOperation memory userOp, bytes32 userOpHash,) = sendPackedUserOp.generateSignedUserOp(
            address(sessionHandler), config, address(spendingLimitModule), address(usdc), 0, data, user, privateKey
        );

        vm.prank(config.entryPoint);
        uint256 validationData = sessionHandler.validateUserOp(_toOzUserOp(userOp), userOpHash, missingAccountFunds);

        // forge-lint: disable-next-line(unsafe-typecast)
        uint160 aggregator = uint160(validationData);
        assertEq(aggregator, 1);
    }

    /**
     * @notice Session-key-signed UserOps must fail validation after the session has been revoked
     */
    function testValidateUserOpFailsWithRevokedSession() public sessionAdded {
        uint256 missingAccountFunds = 1 ether;
        uint256 amountToTransfer = AMOUNT_TO_TRANSFER;

        bytes memory data = abi.encodeWithSelector(ERC20Mock.transfer.selector, user, amountToTransfer);
        (PackedUserOperation memory userOp, bytes32 userOpHash,) = sendPackedUserOp.generateSignedUserOp(
            address(sessionHandler), config, address(spendingLimitModule), address(usdc), 0, data, user, privateKey
        );

        vm.prank(sessionHandler.owner());
        sessionHandler.revokeSessionKey(user);

        vm.prank(config.entryPoint);
        uint256 validationData = sessionHandler.validateUserOp(_toOzUserOp(userOp), userOpHash, missingAccountFunds);

        // forge-lint: disable-next-line(unsafe-typecast)
        uint160 aggregator = uint160(validationData);
        assertEq(aggregator, 1);
    }

    /*//////////////////////////////////////////////////////////////
                       RECOVER SIGNED USEROP TESTS
    //////////////////////////////////////////////////////////////*/

    /**
     * @notice The Anvil owner key's signature must be correctly recoverable from a signed UserOp
     * @dev Pure signature-math check on SendPackedUserOp's own signing flow — does not imply
     *      the UserOp would validate on-chain (it wouldn't; see testValidateUserOpFailsForOwnerSignedUserOp).
     */
    function testRecoverSignedUserOpForOwner() public view {
        bytes memory data = abi.encodeWithSelector(ERC20Mock.mint.selector, user, AMOUNT_TO_MINT);
        (PackedUserOperation memory userOp,, bytes32 digest) = sendPackedUserOp.generateSignedUserOp(
            address(sessionHandler),
            config,
            address(spendingLimitModule),
            address(usdc),
            0,
            data,
            config.account,
            ANVIL_OWNER_KEY
        );
        address actualSigner = ECDSA.recover(digest, userOp.signature);

        assertEq(actualSigner, config.account);
    }

    /**
     * @notice The session key's signature must be correctly recoverable from a signed UserOp
     */
    function testRecoverSignedUserOpWithSession() public view {
        uint256 amountToTransfer = AMOUNT_TO_TRANSFER;
        bytes memory data = abi.encodeWithSelector(ERC20Mock.transfer.selector, user, amountToTransfer);

        (PackedUserOperation memory userOp,, bytes32 digest) = sendPackedUserOp.generateSignedUserOp(
            address(sessionHandler), config, address(spendingLimitModule), address(usdc), 0, data, user, privateKey
        );
        address actualSigner = ECDSA.recover(digest, userOp.signature);

        assertEq(actualSigner, user);
    }

    /*//////////////////////////////////////////////////////////////
                             ENTRY POINT TESTS
    //////////////////////////////////////////////////////////////*/

    /**
     * @notice EntryPoint must be able to execute a session-key-signed UserOp end-to-end
     * @dev SessionHandler has no owner-mode-via-EntryPoint path (see contract-level note), so
     *      unlike SHProtocolTest's testEntryPointCanExecuteCommand, this is the only "EntryPoint
     *      executes a command" happy path that exists for V2.
     */
    function testEntryPointCanExecuteCommandWithSession() public sessionAdded {
        uint256 amountToTransfer = AMOUNT_TO_TRANSFER;

        PackedUserOperation[] memory packedUserOp = new PackedUserOperation[](1);
        bytes memory data = abi.encodeWithSelector(ERC20Mock.transfer.selector, user, amountToTransfer);
        (PackedUserOperation memory userOp,,) = sendPackedUserOp.generateSignedUserOp(
            address(sessionHandler), config, address(spendingLimitModule), address(usdc), 0, data, user, privateKey
        );
        packedUserOp[0] = userOp;

        vm.warp(block.timestamp + 1.1 hours);
        _refreshMockFeeds();
        vm.startPrank(bundler, bundler);
        IEntryPoint(config.entryPoint).handleOps(packedUserOp, payable(user));
        vm.stopPrank();

        assertEq(usdc.balanceOf(user), AMOUNT_TO_TRANSFER);
    }

    /*//////////////////////////////////////////////////////////////
                              SESSION TESTS
    //////////////////////////////////////////////////////////////*/

    /**
     * @notice address(0) is the ETH-send sentinel and must be registered with an empty selector array
     */
    function testCannotAddSessionWithZeroAddressTargetAndSelector() public {
        address sessionKey = user;
        address target = address(0);
        bytes4[] memory sel = new bytes4[](1);
        sel[0] = ERC20Mock.transfer.selector;
        uint48 validFrom = uint48(block.timestamp);
        uint48 validUntil = uint48(block.timestamp + 1 days);
        uint256 spendingLimit = BUDGET;

        vm.prank(sessionHandler.owner());
        vm.expectRevert(SessionHandlerModule.SessionHandlerModule_InvalidTarget.selector);
        sessionHandler.addSessionKey(sessionKey, target, sel, validFrom, validUntil, spendingLimit);
    }

    /**
     * @notice Sending native ETH via a session key deducts the correct USD value from the session budget
     */
    function testSpendingLimitUpdatesForSendingEthWithSession() public ethSessionAdded {
        address dest = kani;
        uint256 value = 1 ether;
        uint256 valueInUsd = oracle.getUsdValue(address(0), value);

        PackedUserOperation[] memory packedUserOp = new PackedUserOperation[](1);
        (PackedUserOperation memory userOp,,) = sendPackedUserOp.generateSignedUserOp(
            address(sessionHandler), config, address(spendingLimitModule), dest, value, "", user, privateKey
        );

        packedUserOp[0] = userOp;

        vm.warp(block.timestamp + 1.1 hours);
        _refreshMockFeeds();
        vm.prank(bundler, bundler);
        IEntryPoint(config.entryPoint).handleOps(packedUserOp, payable(user));

        uint256 remainingBudget = sessionHandler.getRemainingBudget(user);
        uint256 expectedRemainingBudget = BUDGET - valueInUsd;
        assertEq(remainingBudget, expectedRemainingBudget);
        assertEq(kani.balance, value);
    }

    /**
     * @notice Overwriting a session must clear the previous selector whitelist
     */
    function testOverwritingSessionClearsOldSelectors() public {
        bytes4[] memory first = new bytes4[](1);
        first[0] = ERC20Mock.approve.selector;
        vm.prank(sessionHandler.owner());
        sessionHandler.addSessionKey(
            user, address(usdc), first, uint48(block.timestamp), uint48(block.timestamp + 1 days), BUDGET
        );

        // Overwrite with a different selector
        bytes4[] memory second = new bytes4[](1);
        second[0] = ERC20Mock.transfer.selector;
        vm.prank(sessionHandler.owner());
        sessionHandler.addSessionKey(
            user, address(usdc), second, uint48(block.timestamp), uint48(block.timestamp + 1 days), BUDGET
        );

        // `approve` should no longer be allowed — if it is, the old mapping was never cleared
        bytes memory data = abi.encodeWithSelector(ERC20Mock.approve.selector, makeAddr("s"), 1e6);
        (PackedUserOperation memory userOp, bytes32 hash,) = sendPackedUserOp.generateSignedUserOp(
            address(sessionHandler), config, address(spendingLimitModule), address(usdc), 0, data, user, privateKey
        );

        vm.prank(config.entryPoint);
        uint256 validationData = sessionHandler.validateUserOp(_toOzUserOp(userOp), hash, 0);
        // forge-lint: disable-next-line(unsafe-typecast)
        assertEq(uint160(validationData), 1); // should fail — approve was only in the first session
    }

    /// @notice addSessionKey must revert when the session key address is the zero address
    function testAddSessionKeyRevertsInvalidSessionKey() public {
        address sessionKey = address(0);
        address target = address(usdc);
        selectors.push(ERC20Mock.transfer.selector);
        uint48 validFrom = uint48(block.timestamp);
        uint48 validUntil = uint48(block.timestamp + 1 days);
        uint256 spendingLimit = 2e18;

        vm.startPrank(sessionHandler.owner());
        vm.expectRevert(SessionHandlerModule.SessionHandlerModule_InvalidSessionKey.selector);
        sessionHandler.addSessionKey(sessionKey, target, selectors, validFrom, validUntil, spendingLimit);
        vm.stopPrank();
    }

    /// @notice addSessionKey must revert when the target contract address is the zero address
    function testAddSessionKeyRevertsInvalidTarget() public {
        address sessionKey = user;
        address target = address(0);
        selectors.push(ERC20Mock.transfer.selector);
        uint48 validFrom = uint48(block.timestamp);
        uint48 validUntil = uint48(block.timestamp + 1 days);
        uint256 spendingLimit = 2e18;

        vm.startPrank(sessionHandler.owner());
        vm.expectRevert(SessionHandlerModule.SessionHandlerModule_InvalidTarget.selector);
        sessionHandler.addSessionKey(sessionKey, target, selectors, validFrom, validUntil, spendingLimit);
        vm.stopPrank();
    }

    /// @notice addSessionKey must revert when validFrom is greater than or equal to validUntil
    function testAddSessionKeyRevertsInvalidTimeRange() public {
        address sessionKey = user;
        address target = address(usdc);
        selectors.push(ERC20Mock.transfer.selector);
        uint48 validFrom = uint48(block.timestamp);
        uint48 validUntil = uint48(block.timestamp);
        uint256 spendingLimit = 2e18;

        vm.startPrank(sessionHandler.owner());
        vm.expectRevert(SessionHandlerModule.SessionHandlerModule_InvalidTimeRange.selector);
        sessionHandler.addSessionKey(sessionKey, target, selectors, validFrom, validUntil, spendingLimit);
        vm.stopPrank();
    }

    /// @notice revokeSessionKey must revert when the session key has no active session
    function testCannotRevokeNonExistantSession() public sessionAdded {
        address ben = makeAddr("ben");
        vm.startPrank(sessionHandler.owner());
        vm.expectRevert(SessionHandlerModule.SessionHandlerModule_SessionIsNotActive.selector);
        sessionHandler.revokeSessionKey(ben);
        vm.stopPrank();
    }

    /**
     * @notice Spending limit must accumulate correctly across multiple sequential UserOps
     */
    function testBudgetAccumulatesAcrossMultipleOps() public wethSessionAdded {
        uint256 singleSpend = 0.1 ether;
        address dest = address(weth);
        uint256 singleSpendUsd = oracle.getUsdValue(dest, singleSpend);
        address reciever = kani;

        for (uint256 i = 0; i < 3; i++) {
            PackedUserOperation[] memory ops = new PackedUserOperation[](1);
            bytes memory data = abi.encodeWithSelector(MockWeth.transfer.selector, reciever, singleSpend);
            (PackedUserOperation memory userOp,,) = sendPackedUserOp.generateSignedUserOp(
                address(sessionHandler), config, address(spendingLimitModule), dest, 0, data, user, privateKey
            );
            ops[0] = userOp;

            vm.warp(block.timestamp + 1.1 hours);
            _refreshMockFeeds(); // reset updatedAt after each warp to avoid cumulative staleness
            vm.prank(bundler, bundler);
            IEntryPoint(config.entryPoint).handleOps(ops, payable(user));
        }

        assertEq(sessionHandler.getRemainingBudget(user), BUDGET - singleSpendUsd * 3);
    }

    /**
     * @notice Sessions with multiple selectors must allow all listed selectors and reject unlisted ones
     */
    function testMultipleSelectorsAllowedInSession() public {
        selectors.push(ERC20Mock.transfer.selector);
        selectors.push(ERC20Mock.approve.selector);
        vm.prank(sessionHandler.owner());
        sessionHandler.addSessionKey(
            user, address(usdc), selectors, uint48(block.timestamp), uint48(block.timestamp + 1 days), BUDGET
        );

        // approve selector should pass
        bytes memory data = abi.encodeWithSelector(ERC20Mock.approve.selector, makeAddr("spender"), 1e6);
        (PackedUserOperation memory userOp, bytes32 hash,) = sendPackedUserOp.generateSignedUserOp(
            address(sessionHandler), config, address(spendingLimitModule), address(usdc), 0, data, user, privateKey
        );

        vm.prank(config.entryPoint);
        uint256 validationData = sessionHandler.validateUserOp(_toOzUserOp(userOp), hash, 0);
        // forge-lint: disable-next-line(unsafe-typecast)
        assertEq(uint160(validationData), 0); // success

        // mint (unlisted) should still fail
        data = abi.encodeWithSelector(ERC20Mock.mint.selector, user, 1e6);
        (userOp, hash,) = sendPackedUserOp.generateSignedUserOp(
            address(sessionHandler), config, address(spendingLimitModule), address(usdc), 0, data, user, privateKey
        );

        vm.prank(config.entryPoint);
        validationData = sessionHandler.validateUserOp(_toOzUserOp(userOp), hash, 0);
        // forge-lint: disable-next-line(unsafe-typecast)
        assertEq(uint160(validationData), 1); // failure
    }

    /**
     * @notice Owner must be able to register a new session for a key that was previously revoked
     */
    function testOwnerCanReAddSessionAfterRevoke() public sessionAdded {
        vm.prank(sessionHandler.owner());
        sessionHandler.revokeSessionKey(user);

        bytes4[] memory newSelectors = new bytes4[](1);
        newSelectors[0] = ERC20Mock.approve.selector;

        vm.prank(sessionHandler.owner());
        sessionHandler.addSessionKey(
            user, address(dai), newSelectors, uint48(block.timestamp), uint48(block.timestamp + 1 days), BUDGET
        );

        SessionHandlerModule.Session memory s = sessionHandler.getSession(user);
        assertEq(s.active, true);
        assertEq(s.target, address(dai));
        assertEq(sessionHandler.isSessionActive(user), true);
    }

    /*//////////////////////////////////////////////////////////////
                           VIEW FUNCTION TESTS
    //////////////////////////////////////////////////////////////*/

    /// @notice getRemainingBudget must return the full spending limit when no ETH has been spent
    function testSpendingLimitTracksCorrectly() public sessionAdded {
        assertEq(sessionHandler.getRemainingBudget(user), BUDGET);
    }

    /**
     * @notice getRemainingBudget must decrease by the ETH value spent in a successful session UserOp
     */
    function testRemainingBudgetDecreasesAfterSpend() public wethSessionAdded {
        address dest = address(weth);
        address receiver = kani;
        uint256 amountToTransfer = 0.1 ether;

        PackedUserOperation[] memory packedUserOp = new PackedUserOperation[](1);
        bytes memory data = abi.encodeWithSelector(MockWeth.transfer.selector, receiver, amountToTransfer);
        (PackedUserOperation memory userOp,,) = sendPackedUserOp.generateSignedUserOp(
            address(sessionHandler), config, address(spendingLimitModule), dest, 0, data, user, privateKey
        );
        packedUserOp[0] = userOp;

        vm.warp(block.timestamp + 5);
        vm.startPrank(bundler, bundler);
        IEntryPoint(config.entryPoint).handleOps(packedUserOp, payable(user));
        vm.stopPrank();

        assertEq(
            sessionHandler.getRemainingBudget(user), oracle.getUsdValue(address(weth), ETH_VALUE - amountToTransfer)
        );
    }

    /// @notice isSessionActive must return false for an address that has never had a session
    function testIsSessionActiveReturnsFalseForNonExistentSession() public {
        address randomAddress = makeAddr("randomAddress");
        assertEq(sessionHandler.isSessionActive(randomAddress), false);
    }

    /// @notice isSessionActive must return false after the session's validUntil timestamp has passed
    function testIsSessionActiveReturnsFalseAfterExpiry() public sessionAdded {
        vm.warp(block.timestamp + 2 days);
        assertEq(sessionHandler.isSessionActive(user), false);
    }

    /// @notice isSessionActive must return false immediately after the session is revoked
    function testIsSessionActiveReturnsFalseAfterRevocation() public sessionAdded {
        vm.prank(sessionHandler.owner());
        sessionHandler.revokeSessionKey(user);
        assertEq(sessionHandler.isSessionActive(user), false);
    }

    /// @notice getSession must return a Session struct that accurately reflects all registered parameters
    function testGetSessionReturnsCorrectData() public {
        address sessionKey = user;
        address target = address(usdc);
        selectors.push(ERC20Mock.transfer.selector);
        uint48 validFrom = uint48(block.timestamp);
        uint48 validUntil = uint48(block.timestamp + 1 days);
        uint256 spendingLimit = BUDGET;

        vm.prank(sessionHandler.owner());
        sessionHandler.addSessionKey(sessionKey, target, selectors, validFrom, validUntil, spendingLimit);

        SessionHandlerModule.Session memory session = sessionHandler.getSession(sessionKey);
        assertEq(session.target, target);
        assertEq(session.validFrom, validFrom);
        assertEq(session.validUntil, validUntil);
        assertEq(session.spendingLimit, spendingLimit);
        assertEq(session.spentAmount, 0);
        assertEq(session.active, true);
    }

    /**
     * @notice getRemainingBudget must return 0 when the full spending limit has been consumed
     */
    function testGetRemainingBudgetReturnsZeroWhenFullySpent() public wethSessionAdded {
        address dest = address(weth);
        uint256 amountToTransfer = ETH_VALUE;
        address receiver = kani;

        PackedUserOperation[] memory packedUserOp = new PackedUserOperation[](1);
        bytes memory data = abi.encodeWithSelector(MockWeth.transfer.selector, receiver, amountToTransfer);
        (PackedUserOperation memory userOp,,) = sendPackedUserOp.generateSignedUserOp(
            address(sessionHandler), config, address(spendingLimitModule), dest, 0, data, user, privateKey
        );
        packedUserOp[0] = userOp;

        vm.warp(block.timestamp + 1.1 hours);
        _refreshMockFeeds();
        vm.startPrank(bundler, bundler);
        IEntryPoint(config.entryPoint).handleOps(packedUserOp, payable(user));
        vm.stopPrank();

        assertEq(sessionHandler.getRemainingBudget(user), 0);
    }

    /**
     * @notice getRemainingBudget must be unaffected when the session key deposits ETH into WETH
     */
    function testDespositWethDoesntAffectBudget() public wethSessionAdded {
        address dest = address(weth);
        uint256 value = ETH_VALUE;

        PackedUserOperation[] memory packedUserOp = new PackedUserOperation[](1);
        bytes memory data = abi.encodeWithSelector(MockWeth.deposit.selector);
        (PackedUserOperation memory userOp,,) = sendPackedUserOp.generateSignedUserOp(
            address(sessionHandler), config, address(spendingLimitModule), dest, value, data, user, privateKey
        );
        packedUserOp[0] = userOp;

        vm.warp(block.timestamp + 1.1 hours);
        _refreshMockFeeds();
        vm.startPrank(bundler, bundler);
        IEntryPoint(config.entryPoint).handleOps(packedUserOp, payable(user));
        vm.stopPrank();

        assertEq(sessionHandler.getRemainingBudget(user), BUDGET);
    }

    /**
     * @notice getRemainingBudget must return the full budget after an approve() call
     */
    function testApproveDoesNotAffectBudget() public wethSessionAdded {
        address dest = address(weth);

        PackedUserOperation[] memory packedUserOp = new PackedUserOperation[](1);
        bytes memory data = abi.encodeWithSelector(MockWeth.approve.selector, kani, type(uint256).max);
        (PackedUserOperation memory userOp,,) = sendPackedUserOp.generateSignedUserOp(
            address(sessionHandler), config, address(spendingLimitModule), dest, 0, data, user, privateKey
        );
        packedUserOp[0] = userOp;

        vm.warp(block.timestamp + 1.1 hours);
        _refreshMockFeeds();
        vm.startPrank(bundler, bundler);
        IEntryPoint(config.entryPoint).handleOps(packedUserOp, payable(user));
        vm.stopPrank();

        assertEq(sessionHandler.getRemainingBudget(user), BUDGET);
    }

    /**
     * @notice transferFrom must decrement the remaining budget by the USD value of the transferred amount
     */
    function testTransferFromAffectsBudget() public wethSessionAdded {
        uint256 amountToTransfer = 1e18;

        weth.mint(kani, amountToTransfer);
        vm.prank(kani);
        weth.approve(address(sessionHandler), amountToTransfer);

        address dest = address(weth);

        PackedUserOperation[] memory packedUserOp = new PackedUserOperation[](1);
        bytes memory data = abi.encodeWithSelector(MockWeth.transferFrom.selector, kani, user, amountToTransfer);
        (PackedUserOperation memory userOp,,) = sendPackedUserOp.generateSignedUserOp(
            address(sessionHandler), config, address(spendingLimitModule), dest, 0, data, user, privateKey
        );
        packedUserOp[0] = userOp;

        vm.warp(block.timestamp + 1.1 hours);
        _refreshMockFeeds();
        vm.startPrank(bundler, bundler);
        IEntryPoint(config.entryPoint).handleOps(packedUserOp, payable(user));
        vm.stopPrank();

        assertLt(sessionHandler.getRemainingBudget(user), BUDGET);
    }

    /*//////////////////////////////////////////////////////////////
                               EMIT TESTS
    //////////////////////////////////////////////////////////////*/

    /**
     * @notice revokeSessionKey must emit SessionHandlerModule.SessionRevoked with the correct
     *         indexed account and session key
     * @dev The event now originates from SessionHandlerModule (addSessionKey/revokeSessionKey are
     *      forwarded there), not SessionHandler, and carries an extra leading indexed `account`
     *      field since one module instance serves many accounts.
     */
    function testRevokeSessionEmitsEvent() public sessionAdded {
        vm.expectEmit(true, true, false, false);
        emit SessionHandlerModule.SessionRevoked(address(sessionHandler), user);

        vm.prank(sessionHandler.owner());
        sessionHandler.revokeSessionKey(user);
    }

    /// @notice addSessionKey must emit SessionHandlerModule.SessionAdded with the correct account, session key, target, and validUntil
    function testAddSessionEmitsEvent() public {
        address sessionKey = user;
        address target = address(usdc);
        selectors.push(ERC20Mock.transfer.selector);
        uint48 validFrom = uint48(block.timestamp);
        uint48 validUntil = uint48(block.timestamp + 1 days);
        uint256 spendingLimit = 0.005e18;

        vm.expectEmit(true, true, true, true);
        emit SessionHandlerModule.SessionAdded(address(sessionHandler), sessionKey, target, validUntil);
        vm.prank(sessionHandler.owner());
        sessionHandler.addSessionKey(sessionKey, target, selectors, validFrom, validUntil, spendingLimit);
    }

    /*//////////////////////////////////////////////////////////////
                                  FUZZ TESTS
       //////////////////////////////////////////////////////////////*/

    /**
     * @notice addSessionKey must revert with InvalidTimeRange for any input where validFrom >= validUntil.
     */
    function testAddSessionKeyRevertsWithInvalidTimeRange(uint48 validFrom, uint48 validUntil) public {
        vm.assume(validFrom >= validUntil); // ensure we have a invalid time range to start with
        vm.assume(validUntil > block.timestamp); // isolate from SessionHandlerModule_InvalidEndTime
        address sessionKey = user;
        address target = address(usdc);
        selectors.push(ERC20Mock.transfer.selector);
        uint256 spendingLimit = BUDGET;

        vm.startPrank(sessionHandler.owner());
        vm.expectRevert(SessionHandlerModule.SessionHandlerModule_InvalidTimeRange.selector);
        sessionHandler.addSessionKey(sessionKey, target, selectors, validFrom, validUntil, spendingLimit);
        vm.stopPrank();
    }

    /**
     * @notice addSessionKey must revert with InvalidEndTime for any validUntil already in the past.
     */
    function testAddSessionKeyRevertsWithEndTimeInThePast(uint48 validFrom, uint48 validUntil) public {
        vm.warp(block.timestamp + 150 days); // warp far into the future to ensure validUntil is in the past
        vm.assume(validFrom < validUntil);
        vm.assume(validUntil < block.timestamp); // ensure validUntil is in the past
        address sessionKey = user;
        address target = address(usdc);
        selectors.push(ERC20Mock.transfer.selector);
        uint256 spendingLimit = BUDGET;

        vm.startPrank(sessionHandler.owner());
        vm.expectRevert(SessionHandlerModule.SessionHandlerModule_InvalidEndTime.selector);
        sessionHandler.addSessionKey(sessionKey, target, selectors, validFrom, validUntil, spendingLimit);
        vm.stopPrank();
    }

    /**
     * @notice Selector whitelists must be isolated per (account, session key) pair — granting a
     *         selector to keyA must not affect keyB's session storage on the same account.
     */
    function testSelectorIsolationBetweenSessions(address keyA, address keyB, bytes4 selector) public {
        vm.assume(keyA != keyB && keyA != address(0) && keyB != address(0));
        selectors.push(selector);
        address target = address(usdc);
        uint48 validFrom = uint48(block.timestamp + 1 hours);
        uint48 validUntil = uint48(block.timestamp + 3 hours);
        uint256 spendingLimit = BUDGET;

        vm.startPrank(sessionHandler.owner());
        sessionHandler.addSessionKey(keyA, target, selectors, validFrom, validUntil, spendingLimit);
        vm.stopPrank();

        SessionHandlerModule.Session memory sessionB = sessionHandler.getSession(keyB);
        assertEq(sessionB.active, false); // keyB should have no session
        assertEq(sessionB.selectors.length, 0); // keyB should have no selectors
    }

    /**
     * @notice isSessionActive must return true at any timestamp within [validFrom, validUntil].
     */
    function testIsSessionActiveAtTimeBoundaries(uint48 validFrom, uint48 validUntil) public sessionAdded {
        vm.assume(validFrom < validUntil && validUntil > block.timestamp);

        address sessionKey = user;
        address target = address(usdc);
        selectors.push(ERC20Mock.transfer.selector);
        uint256 spendingLimit = BUDGET;
        vm.startPrank(sessionHandler.owner());
        sessionHandler.addSessionKey(sessionKey, target, selectors, validFrom, validUntil, spendingLimit);
        vm.stopPrank();
        vm.warp(validUntil);
        assertEq(sessionHandler.isSessionActive(user), true);
    }

    /**
     * @notice SessionHandlerModule._packValidationData must produce a lossless round-trip for all input combinations.
     * @dev Uses SessionHandlerModuleHarness to call the internal _packValidationData without modifying
     *      the production contract.
     */
    function testPackValidationDataRoundTrip(bool sigFailed, uint48 validAfter, uint48 validUntil) public {
        SessionHandlerModuleHarness harness = new SessionHandlerModuleHarness(address(feeRegistry));
        uint256 packed = harness.packValidationData(sigFailed, validAfter, validUntil);
        // forge-lint: disable-next-line(unsafe-typecast)
        assertEq(uint160(packed), sigFailed ? 1 : 0);
        // forge-lint: disable-next-line(unsafe-typecast)
        assertEq(uint48(packed >> 160), validUntil);
        // forge-lint: disable-next-line(unsafe-typecast)
        assertEq(uint48(packed >> 208), validAfter);
    }

    /**
     * @notice The treasury registered in SHRegistry must receive the flat protocol fee when a
     *         session-key-signed UserOp is executed through the EntryPoint.
     * @dev Fee collection lives in SessionHandler.execute() itself (not SessionHandlerModule) —
     *      see the account-level fee-charging note on execute() — using
     *      SessionHandlerModule.pendingSessionKey to tell whether this particular call was
     *      session-key-driven.
     */
    function testTreasuryRecievesProtocolFeeWithSession() public sessionAdded {
        uint256 amountToTransfer = AMOUNT_TO_TRANSFER;
        address treasuryAddr = feeRegistry.treasury();
        uint256 treasuryBalanceBefore = treasuryAddr.balance;

        PackedUserOperation[] memory packedUserOp = new PackedUserOperation[](1);
        bytes memory data = abi.encodeWithSelector(ERC20Mock.transfer.selector, user, amountToTransfer);
        (PackedUserOperation memory userOp,,) = sendPackedUserOp.generateSignedUserOp(
            address(sessionHandler), config, address(spendingLimitModule), address(usdc), 0, data, user, privateKey
        );
        packedUserOp[0] = userOp;

        vm.warp(block.timestamp + 1.1 hours);
        _refreshMockFeeds();
        vm.startPrank(bundler, bundler);
        IEntryPoint(config.entryPoint).handleOps(packedUserOp, payable(user));
        vm.stopPrank();

        assertEq(treasuryAddr.balance, treasuryBalanceBefore + feeRegistry.protocolFee());
    }

    /*//////////////////////////////////////////////////////////////
                       TREASURY ADMIN TESTS
    //////////////////////////////////////////////////////////////*/

    /// @notice Treasury owner must be able to update the protocol fee, and the change must propagate to SHRegistry
    function testTreasuryOwnerCanSetProtocolFee() public {
        uint256 newFee = 0.0005 ether;

        vm.prank(treasury.owner());
        treasury.setProtocolFee(newFee);

        assertEq(feeRegistry.protocolFee(), newFee);
    }

    /// @notice Non-owners must not be able to update the protocol fee through the treasury
    function testNonOwnerCannotSetProtocolFee() public {
        uint256 newFee = 0.0005 ether;

        vm.expectRevert(abi.encodeWithSelector(Ownable.OwnableUnauthorizedAccount.selector, user));
        vm.prank(user);
        treasury.setProtocolFee(newFee);
    }

    /// @notice Setting a protocol fee above SHRegistry.MAX_PROTOCOL_FEE must revert, even when called by the treasury owner
    function testTreasurySetProtocolFeeRevertsWhenTooHigh() public {
        uint256 tooHighFee = SHRegistry(address(feeRegistry)).MAX_PROTOCOL_FEE() + 1;

        vm.prank(treasury.owner());
        vm.expectRevert(SHRegistry.SHRegistry_FeeTooHigh.selector);
        treasury.setProtocolFee(tooHighFee);
    }

    /// @notice Treasury owner must be able to update the canonical SHOracle, and the change must propagate to SHRegistry
    function testTreasuryOwnerCanSetPriceOracle() public {
        address newOracle = makeAddr("newOracle");

        vm.prank(treasury.owner());
        treasury.setPriceOracle(newOracle);

        assertEq(feeRegistry.priceOracle(), newOracle);
    }

    /// @notice Non-owners must not be able to update the SHOracle through the treasury
    function testNonOwnerCannotSetPriceOracle() public {
        address newOracle = makeAddr("newOracle");

        vm.expectRevert(abi.encodeWithSelector(Ownable.OwnableUnauthorizedAccount.selector, user));
        vm.prank(user);
        treasury.setPriceOracle(newOracle);
    }

    /// @notice Setting the SHOracle to address(0) must revert, even when called by the treasury owner
    function testTreasurySetPriceOracleRevertsWithZeroAddress() public {
        vm.prank(treasury.owner());
        vm.expectRevert(SHRegistry.SHRegistry_InvalidPriceOracle.selector);
        treasury.setPriceOracle(address(0));
    }

    /// @notice Treasury owner must be able to redirect future fees to a new treasury address
    function testTreasuryOwnerCanSetTreasury() public {
        address newTreasury = makeAddr("newTreasury");

        vm.prank(treasury.owner());
        treasury.setTreasury(newTreasury);

        assertEq(feeRegistry.treasury(), newTreasury);
    }

    /// @notice Non-owners must not be able to redirect fees to a new treasury address
    function testNonOwnerCannotSetTreasury() public {
        address newTreasury = makeAddr("newTreasury");

        vm.expectRevert(abi.encodeWithSelector(Ownable.OwnableUnauthorizedAccount.selector, user));
        vm.prank(user);
        treasury.setTreasury(newTreasury);
    }

    /// @notice Redirecting fees to address(0) must revert, even when called by the treasury owner
    function testTreasurySetTreasuryRevertsWithZeroAddress() public {
        vm.prank(treasury.owner());
        vm.expectRevert(SHRegistry.SHRegistry_InvalidTreasury.selector);
        treasury.setTreasury(address(0));
    }
}
