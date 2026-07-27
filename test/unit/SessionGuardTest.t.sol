//SPDX-License-Identifier:MIT
pragma solidity ^0.8.24;

import {Test} from "forge-std/Test.sol";
import {PackedUserOperation} from "@account-abstraction/contracts/interfaces/PackedUserOperation.sol";
import {IEntryPoint} from "@account-abstraction/contracts/interfaces/IEntryPoint.sol";
import {MODULE_TYPE_HOOK, Execution} from "@openzeppelin/contracts/interfaces/draft-IERC7579.sol";
import {SessionHandler} from "../../src/SessionHandler.sol";
import {SpendingLimitModule} from "../../src/SpendingLimitModule.sol";
import {SHFactory} from "../../src/SHFactory.sol";
import {SHTreasury} from "../../src/SHTreasury.sol";
import {SHOracle} from "../../src/SHOracle.sol";
import {ERC20Mock} from "../../src/mocks/ERC20Mock.sol";
import {HelperConfig} from "../../script/HelperConfig.s.sol";
import {DeploySHProtocol} from "../../script/DeploySHProtocol.s.sol";
import {SendPackedUserOp} from "../../script/SendPackedUserOp.s.sol";

/**
 * @title SessionGuardTest
 * @notice End-to-end proof of SessionHandler's session-execution guard: a session-key UserOp that
 *         tries to reach the account's own admin surface (uninstall the hook, raise the cap, mint
 *         more session keys) fails at execution, while a legitimate external call sails through the
 *         EntryPoint and is metered by the spending-cap hook.
 * @dev Two layers of coverage:
 *      - Full ERC-4337 flow (EntryPoint.handleOps): the inner execution revert does NOT bubble out
 *        of handleOps (the EntryPoint absorbs it and emits UserOperationRevertReason), so those
 *        tests assert the admin state is UNCHANGED afterwards — which is the property that matters.
 *      - Direct EntryPoint-pranked execute() calls: prove the exact custom error the guard raises.
 */
contract SessionGuardTest is Test {
    SessionHandler wallet;
    SpendingLimitModule module;
    SHOracle oracle;
    SHTreasury treasury;
    SHFactory factory;
    HelperConfig.NetworkConfig config;
    SendPackedUserOp sendPackedUserOp;
    ERC20Mock usdc;
    ERC20Mock dai;

    /// @dev Per-window USD cap (18 decimals) configured at wallet deployment.
    int256 constant DAILY_LIMIT = 5000e18;
    uint256 constant WINDOW = 1 days;

    /// @dev Anvil's default private key for config.account (the wallet owner on the local chain).
    uint256 constant ANVIL_OWNER_KEY = 0xac0974bec39a17e36ba4a6b4d238ff944bacb478cbed5efcae784d7bf4f2ff80;

    address owner;
    address sessionKey;
    uint256 sessionKeyPk;
    address kani = makeAddr("kani");
    address attacker = makeAddr("attacker");
    address bundler = makeAddr("bundler");

    function setUp() public {
        (sessionKey, sessionKeyPk) = makeAddrAndKey("sessionKey");

        DeploySHProtocol deployer = new DeploySHProtocol();
        (factory, treasury, config, oracle) = deployer.run();
        module = SpendingLimitModule(factory.spendingLimitModule());
        owner = config.account;

        usdc = ERC20Mock(config.usdc);
        dai = ERC20Mock(config.dai);

        address[] memory watched = new address[](2);
        watched[0] = address(usdc);
        watched[1] = address(dai);
        vm.prank(owner);
        wallet = SessionHandler(payable(factory.deployWallet(DAILY_LIMIT, WINDOW, watched)));

        sendPackedUserOp = new SendPackedUserOp();

        vm.deal(address(wallet), 10 ether);
        usdc.mint(address(wallet), 10_000e6);
        dai.mint(address(wallet), 10_000e18);

        vm.prank(owner);
        wallet.addSession(sessionKey);
    }

    /*//////////////////////////////////////////////////////////////
                                HELPERS
    //////////////////////////////////////////////////////////////*/

    /// @dev Signs a single-call UserOp with the session key and submits it through the EntryPoint.
   
    function _sendSessionOp(address dest, bytes memory data) internal {
        (PackedUserOperation memory userOp,,) =
            sendPackedUserOp.generateSignedUserOp(address(wallet), config, dest, 0, data, sessionKey, sessionKeyPk);
        _handleOps(userOp);
    }
    

    /*
    function _sendSessionOp(address dest, bytes memory data) internal {
        PackedUserOperation[] memory ops = new PackedUserOperation[](1);
        (PackedUserOperation memory userOp,,)= sendPackedUserOp.generateSignedUserOp(address(wallet), config, dest, 0, data, sessionKey, signerKeyPk);
        ops[0]=userOp;

        vm.prank(bundler,bundler);
        IEntryPoint(config.entryPoint).handleOps(ops, payable(bundler));

    }
    */

    function _handleOps(PackedUserOperation memory userOp) internal {
        PackedUserOperation[] memory ops = new PackedUserOperation[](1);
        ops[0] = userOp;
        // Two-arg prank: EntryPoint v0.9's nonReentrant requires tx.origin == msg.sender (EOA bundler).
        vm.prank(bundler, bundler);
        IEntryPoint(config.entryPoint).handleOps(ops, payable(bundler));
    }

    /// @dev Packs (dest, value, data) into ERC-7579 single-call executionCalldata.
    function _encodeSingle(address dest, uint256 value, bytes memory data) internal pure returns (bytes memory) {
        return abi.encodePacked(dest, value, data);
    }

    /*//////////////////////////////////////////////////////////////
              LEGIT SESSION FLOW (the guard must NOT interfere)
    //////////////////////////////////////////////////////////////*/

    /// @notice A session-key UserOp making a legitimate external call succeeds end-to-end through
    ///         the EntryPoint, and the spending-cap hook meters it.
    function test_sessionOp_legitTransfer_succeedsAndIsMetered() public {
        uint256 amount = 1000e6;
        int256 expectedUsd = oracle.getPrice(address(usdc), amount);

        _sendSessionOp(address(usdc), abi.encodeCall(ERC20Mock.transfer, (kani, amount)));

        assertEq(usdc.balanceOf(kani), amount, "transfer did not execute");
        assertEq(wallet.getConfig().spentInWindow, expectedUsd, "outflow not metered");
        assertEq(wallet.getRemainingBudget(), DAILY_LIMIT - expectedUsd, "remaining budget wrong");
    }

    /// @notice An owner-signed UserOp through the EntryPoint also validates (owner is always an
    ///         authorized signer) and executes external calls fine.
    function test_ownerSignedOp_legitTransfer_succeeds() public {
        (PackedUserOperation memory userOp,,) = sendPackedUserOp.generateSignedUserOp(
            address(wallet), config, address(usdc), 0, abi.encodeCall(ERC20Mock.transfer, (kani, 500e6)), owner, ANVIL_OWNER_KEY
        );
        _handleOps(userOp);
        assertEq(usdc.balanceOf(kani), 500e6, "owner-signed transfer did not execute");
    }

    /*//////////////////////////////////////////////////////////////
        ADMIN-SURFACE ESCALATION ATTEMPTS (must fail, state intact)
    //////////////////////////////////////////////////////////////*/

    /// @notice A session key must not be able to uninstall the spending-cap hook via a self-call.
    ///         The inner execution reverts inside the EntryPoint; the hook stays installed.
    function test_sessionOp_cannotUninstallHook() public {
        bytes memory data =
            abi.encodeCall(SessionHandler.uninstallModule, (MODULE_TYPE_HOOK, address(module), ""));

        _sendSessionOp(address(wallet), data);

        assertTrue(
            wallet.isModuleInstalled(MODULE_TYPE_HOOK, address(module), ""), "hook was uninstalled by a session key"
        );
        assertTrue(module.getConfig(address(wallet)).installed, "module config was wiped");
    }

    /// @notice A session key must not be able to raise its own cap by calling the module directly.
    function test_sessionOp_cannotRaiseOwnCap() public {
        bytes memory data = abi.encodeCall(SpendingLimitModule.setDailyLimit, (int256(1_000_000_000e18)));

        _sendSessionOp(address(module), data);

        assertEq(wallet.getConfig().dailyLimitUsd, DAILY_LIMIT, "session key raised its own cap");
    }

    /// @notice A session key must not be able to authorize more session keys via a self-call.
    function test_sessionOp_cannotMintMoreSessionKeys() public {
        _sendSessionOp(address(wallet), abi.encodeCall(SessionHandler.addSession, (attacker)));

        assertFalse(wallet.allowedSession(attacker), "session key minted another session key");
    }

    /// @notice A batch hiding one restricted sub-call among legit ones must revert ATOMICALLY:
    ///         neither the transfer nor the cap change may land.
    function test_sessionOp_batchWithRestrictedTarget_revertsAtomically() public {
        Execution[] memory execs = new Execution[](2);
        execs[0] = Execution({target: address(usdc), value: 0, callData: abi.encodeCall(ERC20Mock.transfer, (kani, 100e6))});
        execs[1] =
            Execution({target: address(module), value: 0, callData: abi.encodeCall(SpendingLimitModule.setDailyLimit, (int256(1_000_000_000e18)))});

        (PackedUserOperation memory userOp,,) =
            sendPackedUserOp.generateSignedBatchUserOp(address(wallet), config, execs, sessionKey, sessionKeyPk);
        _handleOps(userOp);

        assertEq(usdc.balanceOf(kani), 0, "batch partially executed despite restricted target");
        assertEq(wallet.getConfig().dailyLimitUsd, DAILY_LIMIT, "cap changed through batch smuggling");
    }

    /*//////////////////////////////////////////////////////////////
              EXACT GUARD ERRORS (direct EntryPoint-pranked calls)
    //////////////////////////////////////////////////////////////*/

    /// @notice The guard reverts with SessionRestrictedTarget(module) when a non-owner execution
    ///         targets the spending-limit module.
    function test_guard_revertsOnModuleTarget() public {
        bytes memory executionCalldata = _encodeSingle(
            address(module), 0, abi.encodeCall(SpendingLimitModule.setDailyLimit, (int256(1e18)))
        );

        vm.prank(config.entryPoint);
        vm.expectRevert(
            abi.encodeWithSelector(SessionHandler.SessionHandler_SessionRestrictedTarget.selector, address(module))
        );
        wallet.execute(bytes32(0), executionCalldata);
    }

    /// @notice The guard reverts with SessionRestrictedTarget(account) when a non-owner execution
    ///         targets the account itself.
    function test_guard_revertsOnSelfTarget() public {
        bytes memory executionCalldata = _encodeSingle(
            address(wallet), 0, abi.encodeCall(SessionHandler.addSession, (attacker))
        );

        vm.prank(config.entryPoint);
        vm.expectRevert(
            abi.encodeWithSelector(SessionHandler.SessionHandler_SessionRestrictedTarget.selector, address(wallet))
        );
        wallet.execute(bytes32(0), executionCalldata);
    }

    /// @notice The guard rejects delegatecall mode outright for non-owner executions.
    function test_guard_revertsOnDelegatecall() public {
        // Delegate executionCalldata layout: target ++ data (no value field).
        bytes memory executionCalldata = abi.encodePacked(address(usdc), abi.encodeCall(ERC20Mock.transfer, (kani, 1e6)));
        bytes32 delegatecallMode = bytes32(uint256(0xff) << 248); // CALLTYPE_DELEGATECALL in top byte

        vm.prank(config.entryPoint);
        vm.expectRevert(SessionHandler.SessionHandler_SessionDelegateCallForbidden.selector);
        wallet.execute(delegatecallMode, executionCalldata);
    }

    /*//////////////////////////////////////////////////////////////
                  OWNER PATH (the guard must NOT apply)
    //////////////////////////////////////////////////////////////*/

    /// @notice The owner calling execute() DIRECTLY may still reach the module (guard skipped),
    ///         because msg.sender == owner.
    function test_ownerDirectExecute_mayTargetModule() public {
        bytes memory executionCalldata = _encodeSingle(
            address(module), 0, abi.encodeCall(SpendingLimitModule.setDailyLimit, (int256(7000e18)))
        );

        vm.prank(owner);
        wallet.execute(bytes32(0), executionCalldata);

        assertEq(wallet.getConfig().dailyLimitUsd, int256(7000e18), "owner direct call was wrongly guarded");
    }

    /// @notice The owner's passthroughs remain the normal admin path and are untouched by the guard.
    function test_ownerPassthroughs_unaffected() public {
        vm.startPrank(owner);
        wallet.setDailyLimit(1234e18);
        wallet.removeSession(sessionKey);
        vm.stopPrank();

        assertEq(wallet.getConfig().dailyLimitUsd, int256(1234e18));
        assertFalse(wallet.allowedSession(sessionKey));
    }

    /*//////////////////////////////////////////////////////////////
                         SIGNER AUTHORIZATION
    //////////////////////////////////////////////////////////////*/

    /// @notice A UserOp signed by a never-authorized key fails validation (AA24) before execution.
    function test_unknownSigner_failsValidation() public {
        (address rando, uint256 randoPk) = makeAddrAndKey("rando");
        (PackedUserOperation memory userOp,,) = sendPackedUserOp.generateSignedUserOp(
            address(wallet), config, address(usdc), 0, abi.encodeCall(ERC20Mock.transfer, (kani, 1e6)), rando, randoPk
        );

        PackedUserOperation[] memory ops = new PackedUserOperation[](1);
        ops[0] = userOp;
        vm.prank(bundler, bundler);
        vm.expectRevert(abi.encodeWithSelector(IEntryPoint.FailedOp.selector, 0, "AA24 signature error"));
        IEntryPoint(config.entryPoint).handleOps(ops, payable(bundler));
    }

    /// @notice After removeSession, a previously working session key fails validation (AA24).
    function test_removedSessionKey_failsValidation() public {
        vm.prank(owner);
        wallet.removeSession(sessionKey);

        (PackedUserOperation memory userOp,,) = sendPackedUserOp.generateSignedUserOp(
            address(wallet), config, address(usdc), 0, abi.encodeCall(ERC20Mock.transfer, (kani, 1e6)), sessionKey, sessionKeyPk
        );

        PackedUserOperation[] memory ops = new PackedUserOperation[](1);
        ops[0] = userOp;
        vm.prank(bundler, bundler);
        vm.expectRevert(abi.encodeWithSelector(IEntryPoint.FailedOp.selector, 0, "AA24 signature error"));
        IEntryPoint(config.entryPoint).handleOps(ops, payable(bundler));
    }
}
