//SPDX-License-Identifier:MIT
pragma solidity ^0.8.24;

import {Test} from "forge-std/Test.sol";
//Openzeppelin Imports
import {Pausable} from "@openzeppelin/contracts/utils/Pausable.sol";
import {OwnableUpgradeable} from "@openzeppelin/contracts-upgradeable/access/OwnableUpgradeable.sol";
import {Initializable} from "@openzeppelin/contracts-upgradeable/proxy/utils/Initializable.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {
    IERC7579Execution,
    Execution,
    MODULE_TYPE_VALIDATOR,
    MODULE_TYPE_EXECUTOR,
    MODULE_TYPE_FALLBACK,
    MODULE_TYPE_HOOK
} from "@openzeppelin/contracts/interfaces/draft-IERC7579.sol";
import {ERC7579Utils} from "@openzeppelin/contracts/account/utils/draft-ERC7579Utils.sol";
//Local imports
import {SessionHandler} from "../../src/SessionHandler.sol";
import {SpendingLimitModule} from "../../src/SpendingLimitModule.sol";
import {HelperConfig} from "../../script/HelperConfig.s.sol";
import {DeploySHProtocol} from "../../script/DeploySHProtocol.s.sol";
import {ERC20Mock} from "../../src/mocks/ERC20Mock.sol";
import {MockWeth} from "../../src/mocks/MockWeth.sol";
import {MockV3Aggregator} from "../../src/mocks/MockV3Aggregator.sol";
import {SHOracle} from "../../src/SHOracle.sol";
import {SHRegistry} from "../../src/SHRegistry.sol";
import {SHFactory} from "../../src/SHFactory.sol";
import {SHTreasury} from "../../src/SHTreasury.sol";
import {SpendingLimitModuleHarness} from "./SpendingLimitModuleHarness.sol";

/**
 * @title SHProtocolTest
 * @author Conrad Japhet
 * @notice Unit suite for the SessionHandler protocol under the USD-spending-cap design:
 *         SessionHandler (ERC-7579 account, validates its own UserOps, session-key allowlist,
 *         admin-surface guard) + SpendingLimitModule (hook type 4 ONLY, net-value metering +
 *         no-standing-approvals) + SHOracle (Chainlink pricing with per-feed heartbeats).
 * @dev Shape notes worth knowing up front:
 *      - execute() takes (bytes32 mode, bytes executionCalldata), the standard ERC-7579 shape;
 *        single-call payloads are abi.encodePacked(target, value, data), batches are
 *        ERC7579Utils.encodeBatch(Execution[]).
 *      - The hook wraps _execute for EVERY caller, so owner-direct execute() calls are metered
 *        by the spending cap exactly like session-key UserOps -- most metering tests below drive
 *        execute() as the owner for brevity. (The EntryPoint flow is exercised end-to-end in
 *        SessionGuardTest.t.sol.)
 *      - onlyEntryPointOrSelfOrOwner reverts with OZAccount.AccountUnauthorized;
 *        onlyOwner passthroughs revert with Ownable.OwnableUnauthorizedAccount -- two different
 *        errors depending on which function you're testing.
 *      - Module errors carry the SpendingLimitModule_ prefix; oracle errors the PriceOracle_ prefix.
 */
contract SHProtocolTest is Test {
    ERC20Mock usdc;
    ERC20Mock dai;
    MockWeth weth;
    SHOracle oracle;
    SHRegistry feeRegistry;
    SHTreasury treasury;
    SHFactory factory;
    HelperConfig.NetworkConfig config;
    SessionHandler wallet;
    SpendingLimitModule module;
    SpendingLimitModuleHarness harness;
    MockSpender spender;

    /// @dev Per-window USD cap (18 decimals) configured at wallet deployment.
    int256 constant DAILY_LIMIT = 5000e18;
    uint256 constant WINDOW = 1 days;

    address owner;
    address kani = makeAddr("kani");
    address rando = makeAddr("rando");

    function setUp() public {
        DeploySHProtocol deployer = new DeploySHProtocol();
        (factory, treasury, config, oracle) = deployer.run();
        feeRegistry = SHRegistry(treasury.REGISTRY());
        module = SpendingLimitModule(factory.spendingLimitModule());
        owner = config.account;

        usdc = ERC20Mock(config.usdc);
        dai = ERC20Mock(config.dai);
        weth = MockWeth(payable(config.weth));

        address[] memory watched = new address[](2);
        watched[0] = address(usdc);
        watched[1] = address(dai);
        vm.prank(owner);
        wallet = SessionHandler(payable(factory.deployWallet(DAILY_LIMIT, WINDOW, watched)));

        harness = new SpendingLimitModuleHarness(address(oracle));
        spender = new MockSpender();

        vm.deal(address(wallet), 10 ether);
        usdc.mint(address(wallet), 10_000e6);
        dai.mint(address(wallet), 10_000e18);
        weth.mint(address(wallet), 1_000e18);
    }

    /*//////////////////////////////////////////////////////////////
                                HELPERS
    //////////////////////////////////////////////////////////////*/

    /// @dev Owner-direct single-call execute (hook applies; guard skipped since msg.sender == owner).
    function _ownerExecute(address dest, uint256 value, bytes memory data) internal {
        vm.prank(owner);
        wallet.execute(bytes32(0), abi.encodePacked(dest, value, data));
    }

    /// @dev Owner-direct batch execute.
    function _ownerExecuteBatch(Execution[] memory execs) internal {
        vm.prank(owner);
        wallet.execute(bytes32(uint256(0x01) << 248), ERC7579Utils.encodeBatch(execs));
    }

    function _spentInWindow() internal view returns (int256) {
        return wallet.getConfig().spentInWindow;
    }

    /*//////////////////////////////////////////////////////////////
                        DEPLOYMENT / FACTORY
    //////////////////////////////////////////////////////////////*/

    function test_deployWallet_initializesAccountAndCapConfig() public view {
        assertEq(wallet.owner(), owner);
        assertEq(address(wallet.SH_MODULE()), address(module));
        assertEq(wallet.ENTRY_POINT(), config.entryPoint);
        assertTrue(wallet.isModuleInstalled(MODULE_TYPE_HOOK, address(module), ""));

        SpendingLimitModule.Config memory cfg = wallet.getConfig();
        assertTrue(cfg.installed);
        assertEq(cfg.dailyLimitUsd, DAILY_LIMIT);
        assertEq(uint256(cfg.windowDuration), WINDOW);
        assertEq(cfg.watchedTokens.length, 2);
        assertTrue(wallet.isWatched(address(usdc)));
        assertTrue(wallet.isWatched(address(dai)));
        assertFalse(wallet.isWatched(address(weth)));
        assertEq(wallet.getRemainingBudget(), DAILY_LIMIT);
    }

    function test_deployWallet_revertsWhenModuleUnset() public {
        vm.prank(owner);
        factory.setSpendingLimitModule(address(0));

        address[] memory watched = new address[](0);
        vm.expectRevert(SHFactory.SHFactory_SpendingLimitModuleNotSet.selector);
        factory.deployWallet(DAILY_LIMIT, WINDOW, watched);
    }

    function test_deployWallet_revertsOnUnpricedWatchedToken() public {
        ERC20Mock unpriced = new ERC20Mock("Unpriced", "UNP", 18);
        address[] memory watched = new address[](1);
        watched[0] = address(unpriced);

        vm.expectRevert(
            abi.encodeWithSelector(
                SpendingLimitModule.SpendingLimitModule_TokenNotPriced.selector, address(unpriced)
            )
        );
        factory.deployWallet(DAILY_LIMIT, WINDOW, watched);
    }

    function test_deployWallet_revertsOnZeroWindow() public {
        address[] memory watched = new address[](0);
        vm.expectRevert(SpendingLimitModule.SpendingLimitModule_InvalidWindowDuration.selector);
        factory.deployWallet(DAILY_LIMIT, 0, watched);
    }

    function test_initialize_cannotRerun() public {
        address[] memory watched = new address[](0);
        vm.expectRevert(Initializable.InvalidInitialization.selector);
        wallet.initialize(rando, config.entryPoint, address(1), address(2), address(3), 9, address(module), 1, 1, watched);
    }

    function test_deployWallet_forwardsFunding() public {
        address[] memory watched = new address[](0);
        vm.deal(kani, 1 ether);
        vm.prank(kani);
        address funded = factory.deployWallet{value: 1 ether}(DAILY_LIMIT, WINDOW, watched);
        assertEq(funded.balance, 1 ether);
    }

    /*//////////////////////////////////////////////////////////////
                          MODULE LIFECYCLE
    //////////////////////////////////////////////////////////////*/

    function test_onInstall_revertsIfAlreadyInstalled() public {
        vm.prank(address(wallet));
        vm.expectRevert(SpendingLimitModule.SpendingLimitModule_AlreadyInstalled.selector);
        module.onInstall(abi.encode(DAILY_LIMIT, WINDOW, new address[](0)));
    }

    function test_uninstall_wipesStateAndReinstallStartsFresh() public {
        vm.prank(owner);
        wallet.uninstallModule(MODULE_TYPE_HOOK, address(module), "");

        assertFalse(module.getConfig(address(wallet)).installed);
        assertFalse(module.isWatched(address(wallet), address(usdc)));
        assertEq(module.getConfig(address(wallet)).watchedTokens.length, 0);

        // Re-install with a different config: starts from the fresh state, not leftovers.
        address[] memory watched = new address[](1);
        watched[0] = address(dai);
        vm.prank(owner);
        wallet.installModule(MODULE_TYPE_HOOK, address(module), abi.encode(int256(1e18), uint256(2 days), watched));

        SpendingLimitModule.Config memory cfg = module.getConfig(address(wallet));
        assertTrue(cfg.installed);
        assertEq(cfg.dailyLimitUsd, int256(1e18));
        assertEq(uint256(cfg.windowDuration), 2 days);
        assertEq(cfg.watchedTokens.length, 1);
        assertFalse(module.isWatched(address(wallet), address(usdc)));
    }

    function test_isModuleType_hookOnly() public view {
        assertTrue(module.isModuleType(MODULE_TYPE_HOOK));
        assertFalse(module.isModuleType(MODULE_TYPE_VALIDATOR));
        assertFalse(module.isModuleType(MODULE_TYPE_EXECUTOR));
        assertFalse(module.isModuleType(MODULE_TYPE_FALLBACK));
    }

    function test_preCheck_revertsWhenNotInstalled() public {
        vm.prank(rando);
        vm.expectRevert(SpendingLimitModule.SpendingLimitModule_NotInstalled.selector);
        module.preCheck(rando, 0, "");
    }

    function test_postCheck_silentWhenNotInstalled() public {
        bytes memory hookData =
            abi.encode(new address[](0), new uint256[](0), new address[](0), new address[](0));
        vm.prank(rando);
        module.postCheck(hookData); // must not revert
    }

    /*//////////////////////////////////////////////////////////////
                           CONFIG SETTERS
    //////////////////////////////////////////////////////////////*/

    function test_setDailyLimit_updatesAndZeroAllowed() public {
        vm.prank(owner);
        wallet.setDailyLimit(0);
        assertEq(wallet.getConfig().dailyLimitUsd, 0);
        assertEq(wallet.getRemainingBudget(), 0);
    }

    function test_setDailyLimit_negativeReverts() public {
        vm.prank(owner);
        vm.expectRevert(SpendingLimitModule.SpendingLimitModule_InvalidDailyLimit.selector);
        wallet.setDailyLimit(-1);
    }

    function test_setDailyLimit_nonOwnerReverts() public {
        vm.prank(rando);
        vm.expectRevert(abi.encodeWithSelector(OwnableUpgradeable.OwnableUnauthorizedAccount.selector, rando));
        wallet.setDailyLimit(1e18);
    }

    function test_setWindowDuration_boundsEnforced() public {
        vm.startPrank(owner);
        vm.expectRevert(SpendingLimitModule.SpendingLimitModule_InvalidWindowDuration.selector);
        wallet.setWindowDuration(0);

        vm.expectRevert(SpendingLimitModule.SpendingLimitModule_InvalidWindowDuration.selector);
        wallet.setWindowDuration(uint256(type(uint48).max) + 1);

        wallet.setWindowDuration(2 days);
        vm.stopPrank();
        assertEq(uint256(wallet.getConfig().windowDuration), 2 days);
    }

    function test_addWatchedToken_unpricedReverts() public {
        ERC20Mock unpriced = new ERC20Mock("Unpriced", "UNP", 18);
        vm.prank(owner);
        vm.expectRevert(
            abi.encodeWithSelector(
                SpendingLimitModule.SpendingLimitModule_TokenNotPriced.selector, address(unpriced)
            )
        );
        wallet.addWatchedToken(address(unpriced));
    }

    function test_addWatchedToken_duplicateIsNoOp() public {
        uint256 lengthBefore = wallet.getConfig().watchedTokens.length;
        vm.prank(owner);
        wallet.addWatchedToken(address(usdc));
        assertEq(wallet.getConfig().watchedTokens.length, lengthBefore);
    }

    function test_removeWatchedToken_removesAndAbsentIsNoOp() public {
        vm.prank(owner);
        wallet.removeWatchedToken(address(usdc));
        assertFalse(wallet.isWatched(address(usdc)));
        assertEq(wallet.getConfig().watchedTokens.length, 1);

        // absent token: no-op, no revert
        vm.prank(owner);
        wallet.removeWatchedToken(address(usdc));
        assertEq(wallet.getConfig().watchedTokens.length, 1);
    }

    function test_moduleSetters_revertForNonInstalledCaller() public {
        vm.startPrank(rando);
        vm.expectRevert(SpendingLimitModule.SpendingLimitModule_NotInstalled.selector);
        module.setDailyLimit(1e18);
        vm.expectRevert(SpendingLimitModule.SpendingLimitModule_NotInstalled.selector);
        module.addWatchedToken(address(usdc));
        vm.stopPrank();
    }

    function test_watchedTokenCap_enforcedAt32() public {
        // Self-contained fixture: 33 priced tokens against a dedicated oracle, with a plain EOA
        // acting as the installing account (the module only cares about msg.sender).
        uint256 n = 33;
        address[] memory tokens = new address[](n);
        address[] memory feeds = new address[](n);
        uint256[] memory beats = new uint256[](n);
        MockV3Aggregator sharedFeed = new MockV3Aggregator(8, 1e8);
        for (uint256 i = 0; i < n; i++) {
            tokens[i] = address(new ERC20Mock("T", "T", 18));
            feeds[i] = address(sharedFeed);
            beats[i] = 1 days;
        }
        SHOracle bigOracle = new SHOracle(tokens, feeds, beats);
        SpendingLimitModule freshModule = new SpendingLimitModule(address(bigOracle));

        address account = makeAddr("eoaAccount");
        address[] memory first32 = new address[](32);
        for (uint256 i = 0; i < 32; i++) {
            first32[i] = tokens[i];
        }
        vm.prank(account);
        freshModule.onInstall(abi.encode(int256(1e18), uint256(1 days), first32));

        vm.prank(account);
        vm.expectRevert(SpendingLimitModule.SpendingLimitModule_TooManyWatchedTokens.selector);
        freshModule.addWatchedToken(tokens[32]);
    }

    /*//////////////////////////////////////////////////////////////
                      SESSION-KEY AUTH (account-level)
    //////////////////////////////////////////////////////////////*/

    function test_addSession_zeroAddressReverts() public {
        vm.prank(owner);
        vm.expectRevert(SessionHandler.SessionHandler_InvalidSessionKey.selector);
        wallet.addSession(address(0));
    }

    function test_addRemoveSession_lifecycleAndEvents() public {
        vm.expectEmit(true, false, false, false, address(wallet));
        emit SessionHandler.SessionAdded(kani);
        vm.prank(owner);
        wallet.addSession(kani);
        assertTrue(wallet.allowedSession(kani));

        vm.expectEmit(true, false, false, false, address(wallet));
        emit SessionHandler.SessionRemoved(kani);
        vm.prank(owner);
        wallet.removeSession(kani);
        assertFalse(wallet.allowedSession(kani));
    }

    function test_sessionManagement_nonOwnerReverts() public {
        vm.startPrank(rando);
        vm.expectRevert(abi.encodeWithSelector(OwnableUpgradeable.OwnableUnauthorizedAccount.selector, rando));
        wallet.addSession(kani);
        vm.expectRevert(abi.encodeWithSelector(OwnableUpgradeable.OwnableUnauthorizedAccount.selector, rando));
        wallet.removeSession(kani);
        vm.stopPrank();
    }

    /*//////////////////////////////////////////////////////////////
                    NET-VALUE METERING (the spending cap)
    //////////////////////////////////////////////////////////////*/

    function test_transfer_isMeteredAtOraclePrice() public {
        uint256 amount = 1000e6;
        int256 expectedUsd = oracle.getPrice(address(usdc), amount);

        _ownerExecute(address(usdc), 0, abi.encodeCall(ERC20Mock.transfer, (kani, amount)));

        assertEq(usdc.balanceOf(kani), amount);
        assertEq(_spentInWindow(), expectedUsd);
        assertEq(wallet.getRemainingBudget(), DAILY_LIMIT - expectedUsd);
    }

    function test_transfers_accumulateAcrossTransactions() public {
        _ownerExecute(address(usdc), 0, abi.encodeCall(ERC20Mock.transfer, (kani, 1000e6)));
        _ownerExecute(address(dai), 0, abi.encodeCall(ERC20Mock.transfer, (kani, 500e18)));

        int256 expected = oracle.getPrice(address(usdc), 1000e6) + oracle.getPrice(address(dai), 500e18);
        assertEq(_spentInWindow(), expected);
    }

    function test_budgetExceeded_revertsWholeTransaction() public {
        vm.prank(owner);
        wallet.setDailyLimit(100e18); // tiny cap

        uint256 balanceBefore = usdc.balanceOf(address(wallet));
        int256 attemptedSpend = oracle.getPrice(address(usdc), 1000e6);
        vm.prank(owner);
        vm.expectRevert(
            abi.encodeWithSelector(
                SpendingLimitModule.SpendingLimitModule_BudgetExceeded.selector, attemptedSpend, int256(100e18)
            )
        );
        wallet.execute(
            bytes32(0), abi.encodePacked(address(usdc), uint256(0), abi.encodeCall(ERC20Mock.transfer, (kani, 1000e6)))
        );

        // whole tx reverted: nothing moved, nothing metered
        assertEq(usdc.balanceOf(address(wallet)), balanceBefore);
        assertEq(_spentInWindow(), 0);
    }

    function test_unwatchedToken_notMetered() public {
        _ownerExecute(address(weth), 0, abi.encodeCall(MockWeth.transfer, (kani, 100e18)));
        assertEq(weth.balanceOf(kani), 100e18);
        assertEq(_spentInWindow(), 0);
    }

    function test_nativeEth_isMetered() public {
        // Native value is metered: a plain 1-ETH send is priced through the address(0) sentinel and
        // charged to the window. This is the isolated native-decrease branch (no offsetting inflow).
        uint256 kaniBefore = kani.balance;
        int256 expectedUsd = oracle.getPrice(address(0), 1 ether);
        assertGt(expectedUsd, 0, "native price should be positive");

        _ownerExecute(kani, 1 ether, "");

        assertEq(kani.balance, kaniBefore + 1 ether);
        assertEq(_spentInWindow(), expectedUsd, "native send not metered");
        assertEq(wallet.getRemainingBudget(), DAILY_LIMIT - expectedUsd);
    }

    function test_nativeInflow_creditsAgainstWatchedOutflow() public {
        // A watched-token outflow plus a native INFLOW (unwrap) in one transaction: the native
        // inflow is priced through the address(0) sentinel and credited against the outflow,
        // exercising postCheck's native-INCREASE branch. Sized so the net stays positive, so the
        // credit is observable (without it, spend would be the full USDC value).
        vm.deal(address(weth), 10 ether); // back the mock so withdraw() can pay the wallet
        uint256 usdcOut = 3_000e6; // kept under the $5k window cap even after the native credit
        usdc.mint(address(wallet), usdcOut);

        Execution[] memory execs = new Execution[](2);
        execs[0] = Execution(address(usdc), 0, abi.encodeCall(ERC20Mock.transfer, (kani, usdcOut)));
        execs[1] = Execution(address(weth), 0, abi.encodeCall(MockWeth.withdraw, (1 ether)));
        _ownerExecuteBatch(execs);

        int256 netUsd = oracle.getPrice(address(usdc), usdcOut) - oracle.getPrice(address(0), 1 ether);
        assertGt(netUsd, 0, "test mis-sized: expected a positive net after the native credit");
        assertEq(_spentInWindow(), netUsd, "native inflow not credited against watched outflow");
    }

    function test_inflowOffsetsOutflow_withinSameTransaction() public {
        // Out 1000 USDC, in 400 USDC (minted mid-batch): net outflow 600 is what gets metered.
        Execution[] memory execs = new Execution[](2);
        execs[0] = Execution(address(usdc), 0, abi.encodeCall(ERC20Mock.transfer, (kani, 1000e6)));
        execs[1] = Execution(address(usdc), 0, abi.encodeCall(ERC20Mock.mint, (address(wallet), 400e6)));

        _ownerExecuteBatch(execs);

        assertEq(_spentInWindow(), oracle.getPrice(address(usdc), 600e6));
    }

    function test_crossTokenNetting_swapLikeBatchNetsOut() public {
        // Simulates a swap: 1000 USDC out, DAI of roughly equal USD value in. The net USD delta
        // is what's metered -- compute it exactly from the oracle rather than hardcoding.
        uint256 usdcOut = 1000e6;
        uint256 daiIn = 800e18;
        Execution[] memory execs = new Execution[](2);
        execs[0] = Execution(address(usdc), 0, abi.encodeCall(ERC20Mock.transfer, (kani, usdcOut)));
        execs[1] = Execution(address(dai), 0, abi.encodeCall(ERC20Mock.mint, (address(wallet), daiIn)));

        _ownerExecuteBatch(execs);

        int256 netUsd = oracle.getPrice(address(usdc), usdcOut) - oracle.getPrice(address(dai), daiIn);
        assertEq(_spentInWindow(), netUsd > 0 ? netUsd : int256(0));
    }

    function test_netInflow_neverBanksCreditForLaterTransactions() public {
        // Tx 1: net INFLOW (mint > out) => spent stays 0, no credit accrues.
        Execution[] memory execs = new Execution[](2);
        execs[0] = Execution(address(usdc), 0, abi.encodeCall(ERC20Mock.mint, (address(wallet), 5000e6)));
        execs[1] = Execution(address(usdc), 0, abi.encodeCall(ERC20Mock.transfer, (kani, 1000e6)));
        _ownerExecuteBatch(execs);
        assertEq(_spentInWindow(), 0, "net inflow must add nothing");

        // Tx 2: a plain outflow is charged in full -- the earlier inflow bought no headroom.
        _ownerExecute(address(usdc), 0, abi.encodeCall(ERC20Mock.transfer, (kani, 1000e6)));
        assertEq(_spentInWindow(), oracle.getPrice(address(usdc), 1000e6));
    }

    function test_windowRolls_restoringFullBudget() public {
        _ownerExecute(address(usdc), 0, abi.encodeCall(ERC20Mock.transfer, (kani, 4000e6)));
        int256 firstSpend = _spentInWindow();
        assertGt(firstSpend, 0);

        vm.warp(block.timestamp + WINDOW + 1);
        // Expired-but-unrolled window already reports a full budget.
        assertEq(wallet.getRemainingBudget(), DAILY_LIMIT);

        // Feeds went stale during the warp; refresh the one we're about to move.
        MockV3Aggregator(config.usdcUsdPriceFeed).updateAnswer(MockV3Aggregator(config.usdcUsdPriceFeed).latestAnswer());

        _ownerExecute(address(usdc), 0, abi.encodeCall(ERC20Mock.transfer, (kani, 1000e6)));
        assertEq(_spentInWindow(), oracle.getPrice(address(usdc), 1000e6), "window did not reset");
    }

    function test_staleFeed_blocksOnlyTheMovedToken() public {
        // Make every feed stale, then refresh ONLY usdc's.
        vm.warp(block.timestamp + 365 days);
        MockV3Aggregator(config.usdcUsdPriceFeed).updateAnswer(MockV3Aggregator(config.usdcUsdPriceFeed).latestAnswer());

        // Moving usdc works -- dai's stale feed is irrelevant because dai never moved.
        _ownerExecute(address(usdc), 0, abi.encodeCall(ERC20Mock.transfer, (kani, 100e6)));
        assertEq(usdc.balanceOf(kani), 100e6);

        // Moving dai now trips its stale feed.
        vm.prank(owner);
        vm.expectRevert(SHOracle.PriceOracle_StalePrice.selector);
        wallet.execute(
            bytes32(0), abi.encodePacked(address(dai), uint256(0), abi.encodeCall(ERC20Mock.transfer, (kani, 100e18)))
        );
    }

    /*//////////////////////////////////////////////////////////////
                      APPROVALS (no-standing rule)
    //////////////////////////////////////////////////////////////*/

    function test_unlimitedApprove_rejectedUpFront() public {
        vm.prank(owner);
        vm.expectRevert(SpendingLimitModule.SpendingLimitModule_UnlimitedApprovalRejected.selector);
        wallet.execute(
            bytes32(0),
            abi.encodePacked(
                address(usdc), uint256(0), abi.encodeCall(ERC20Mock.approve, (address(spender), type(uint256).max))
            )
        );
    }

    function test_approveOnUnpricedToken_rejected() public {
        ERC20Mock unpriced = new ERC20Mock("Unpriced", "UNP", 18);
        vm.prank(owner);
        vm.expectRevert(
            abi.encodeWithSelector(
                SpendingLimitModule.SpendingLimitModule_TokenNotPriced.selector, address(unpriced)
            )
        );
        wallet.execute(
            bytes32(0),
            abi.encodePacked(
                address(unpriced), uint256(0), abi.encodeCall(ERC20Mock.approve, (address(spender), 100e18))
            )
        );
    }

    function test_standingApproval_revertsWithResidual() public {
        vm.prank(owner);
        vm.expectRevert(
            abi.encodeWithSelector(
                SpendingLimitModule.SpendingLimitModule_StandingApprovalNotAllowed.selector,
                address(usdc),
                address(spender),
                uint256(100e6)
            )
        );
        wallet.execute(
            bytes32(0),
            abi.encodePacked(address(usdc), uint256(0), abi.encodeCall(ERC20Mock.approve, (address(spender), 100e6)))
        );
        assertEq(usdc.allowance(address(wallet), address(spender)), 0, "approval survived the revert");
    }

    function test_approveFullyConsumedInSameTx_passesAndMetersOutflow() public {
        Execution[] memory execs = new Execution[](2);
        execs[0] = Execution(address(usdc), 0, abi.encodeCall(ERC20Mock.approve, (address(spender), 100e6)));
        execs[1] =
            Execution(address(spender), 0, abi.encodeCall(MockSpender.pull, (address(usdc), address(wallet), 100e6)));

        _ownerExecuteBatch(execs);

        assertEq(usdc.allowance(address(wallet), address(spender)), 0);
        assertEq(usdc.balanceOf(address(spender)), 100e6);
        assertEq(_spentInWindow(), oracle.getPrice(address(usdc), 100e6), "consumed approval outflow not metered");
    }

    function test_partiallyConsumedApproval_reverts() public {
        Execution[] memory execs = new Execution[](2);
        execs[0] = Execution(address(usdc), 0, abi.encodeCall(ERC20Mock.approve, (address(spender), 100e6)));
        execs[1] =
            Execution(address(spender), 0, abi.encodeCall(MockSpender.pull, (address(usdc), address(wallet), 60e6)));

        vm.prank(owner);
        vm.expectRevert(
            abi.encodeWithSelector(
                SpendingLimitModule.SpendingLimitModule_StandingApprovalNotAllowed.selector,
                address(usdc),
                address(spender),
                uint256(40e6)
            )
        );
        wallet.execute(bytes32(uint256(0x01) << 248), ERC7579Utils.encodeBatch(execs));
    }

    function test_zeroApprove_notTrackedAndPasses() public {
        _ownerExecute(address(usdc), 0, abi.encodeCall(ERC20Mock.approve, (address(spender), 0)));
        assertEq(usdc.allowance(address(wallet), address(spender)), 0);
    }

    function test_approveThenRevokeInSameTx_passes() public {
        // Residual-based check: granting then zeroing within one tx leaves nothing standing.
        Execution[] memory execs = new Execution[](2);
        execs[0] = Execution(address(usdc), 0, abi.encodeCall(ERC20Mock.approve, (address(spender), 100e6)));
        execs[1] = Execution(address(usdc), 0, abi.encodeCall(ERC20Mock.approve, (address(spender), 0)));

        _ownerExecuteBatch(execs);
        assertEq(usdc.allowance(address(wallet), address(spender)), 0);
    }

    /*//////////////////////////////////////////////////////////////
             TRUSTED SPENDERS (unpriced-approval exemption, Option C)
    //////////////////////////////////////////////////////////////*/

    function test_addTrustedSpender_lifecycleAndEvents() public {
        address venue = makeAddr("venue");
        // Anvil config has router == address(0), so nothing is auto-trusted; the list starts empty.
        assertEq(wallet.getConfig().trustedSpenders.length, 0);

        vm.expectEmit(true, true, false, false, address(module));
        emit SpendingLimitModule.TrustedSpenderAdded(address(wallet), venue);
        vm.prank(owner);
        wallet.addTrustedSpender(venue);

        assertTrue(wallet.isTrustedSpender(venue));
        SpendingLimitModule.Config memory cfg = wallet.getConfig();
        assertEq(cfg.trustedSpenders.length, 1);
        assertEq(cfg.trustedSpenders[0], venue);

        // idempotent
        vm.prank(owner);
        wallet.addTrustedSpender(venue);
        assertEq(wallet.getConfig().trustedSpenders.length, 1);

        vm.expectEmit(true, true, false, false, address(module));
        emit SpendingLimitModule.TrustedSpenderRemoved(address(wallet), venue);
        vm.prank(owner);
        wallet.removeTrustedSpender(venue);
        assertFalse(wallet.isTrustedSpender(venue));
        assertEq(wallet.getConfig().trustedSpenders.length, 0);
    }

    function test_addTrustedSpender_zeroReverts() public {
        vm.prank(owner);
        vm.expectRevert(SpendingLimitModule.SpendingLimitModule_InvalidTrustedSpender.selector);
        wallet.addTrustedSpender(address(0));
    }

    function test_trustedSpender_management_nonOwnerReverts() public {
        vm.startPrank(rando);
        vm.expectRevert(abi.encodeWithSelector(OwnableUpgradeable.OwnableUnauthorizedAccount.selector, rando));
        wallet.addTrustedSpender(address(spender));
        vm.expectRevert(abi.encodeWithSelector(OwnableUpgradeable.OwnableUnauthorizedAccount.selector, rando));
        wallet.removeTrustedSpender(address(spender));
        vm.stopPrank();
    }

    function test_trustedSpender_capEnforced() public {
        vm.startPrank(owner);
        for (uint256 i = 1; i <= 16; i++) {
            wallet.addTrustedSpender(address(uint160(0x1000 + i)));
        }
        vm.expectRevert(SpendingLimitModule.SpendingLimitModule_TooManyTrustedSpenders.selector);
        wallet.addTrustedSpender(address(uint160(0x2000)));
        vm.stopPrank();
    }

    /// @notice The core Option-C behavior: an approval on an UNPRICED token (an LP-token stand-in)
    ///         to a TRUSTED spender is allowed as long as it's consumed to zero in the same tx.
    function test_trustedSpender_allowsUnpricedApprovalConsumedInSameTx() public {
        ERC20Mock lp = new ERC20Mock("LP", "LP", 18); // no oracle feed => unpriced
        lp.mint(address(wallet), 100e18);

        vm.prank(owner);
        wallet.addTrustedSpender(address(spender));

        Execution[] memory execs = new Execution[](2);
        execs[0] = Execution(address(lp), 0, abi.encodeCall(ERC20Mock.approve, (address(spender), 100e18)));
        execs[1] =
            Execution(address(spender), 0, abi.encodeCall(MockSpender.pull, (address(lp), address(wallet), 100e18)));

        _ownerExecuteBatch(execs);

        assertEq(lp.allowance(address(wallet), address(spender)), 0);
        assertEq(lp.balanceOf(address(spender)), 100e18);
        assertEq(_spentInWindow(), 0, "unpriced/unwatched token must not be metered");
    }

    /// @notice The same unpriced approval to an UNTRUSTED spender still reverts TokenNotPriced.
    function test_untrustedSpender_unpricedApprovalReverts() public {
        ERC20Mock lp = new ERC20Mock("LP", "LP", 18);
        vm.prank(owner);
        vm.expectRevert(
            abi.encodeWithSelector(SpendingLimitModule.SpendingLimitModule_TokenNotPriced.selector, address(lp))
        );
        wallet.execute(
            bytes32(0),
            abi.encodePacked(address(lp), uint256(0), abi.encodeCall(ERC20Mock.approve, (address(spender), 100e18)))
        );
    }

    /// @notice Trusting a spender does NOT relax the unlimited-approval ban.
    function test_trustedSpender_unlimitedStillRejected() public {
        ERC20Mock lp = new ERC20Mock("LP", "LP", 18);
        vm.prank(owner);
        wallet.addTrustedSpender(address(spender));

        vm.prank(owner);
        vm.expectRevert(SpendingLimitModule.SpendingLimitModule_UnlimitedApprovalRejected.selector);
        wallet.execute(
            bytes32(0),
            abi.encodePacked(
                address(lp), uint256(0), abi.encodeCall(ERC20Mock.approve, (address(spender), type(uint256).max))
            )
        );
    }

    /// @notice Trusting a spender does NOT relax the no-standing-approval rule: an unconsumed
    ///         allowance to a trusted spender still reverts the whole transaction.
    function test_trustedSpender_standingApprovalStillReverts() public {
        ERC20Mock lp = new ERC20Mock("LP", "LP", 18);
        vm.prank(owner);
        wallet.addTrustedSpender(address(spender));

        vm.prank(owner);
        vm.expectRevert(
            abi.encodeWithSelector(
                SpendingLimitModule.SpendingLimitModule_StandingApprovalNotAllowed.selector,
                address(lp),
                address(spender),
                uint256(100e18)
            )
        );
        wallet.execute(
            bytes32(0),
            abi.encodePacked(address(lp), uint256(0), abi.encodeCall(ERC20Mock.approve, (address(spender), 100e18)))
        );
    }

    function test_removeTrustedSpender_reinstatesPricedRequirement() public {
        ERC20Mock lp = new ERC20Mock("LP", "LP", 18);
        vm.startPrank(owner);
        wallet.addTrustedSpender(address(spender));
        wallet.removeTrustedSpender(address(spender));
        vm.stopPrank();

        vm.prank(owner);
        vm.expectRevert(
            abi.encodeWithSelector(SpendingLimitModule.SpendingLimitModule_TokenNotPriced.selector, address(lp))
        );
        wallet.execute(
            bytes32(0),
            abi.encodePacked(address(lp), uint256(0), abi.encodeCall(ERC20Mock.approve, (address(spender), 1e18)))
        );
    }

    function test_uninstall_clearsTrustedSpenders() public {
        vm.prank(owner);
        wallet.addTrustedSpender(address(spender));
        assertTrue(wallet.isTrustedSpender(address(spender)));

        vm.prank(owner);
        wallet.uninstallModule(MODULE_TYPE_HOOK, address(module), "");
        assertFalse(module.isTrustedSpender(address(wallet), address(spender)));

        address[] memory watched = new address[](0);
        vm.prank(owner);
        wallet.installModule(MODULE_TYPE_HOOK, address(module), abi.encode(DAILY_LIMIT, WINDOW, watched));
        assertFalse(wallet.isTrustedSpender(address(spender)));
        assertEq(wallet.getConfig().trustedSpenders.length, 0);
    }

    /*//////////////////////////////////////////////////////////////
                    HARNESS: CALLDATA DECODE / CLASSIFY
    //////////////////////////////////////////////////////////////*/

    function test_decodeExecuteCalldata_recognizesExecuteShapes() public view {
        bytes memory payload = abi.encodePacked(address(usdc), uint256(0), abi.encodeCall(ERC20Mock.transfer, (kani, 1e6)));

        (bool isExecute, bytes32 mode, bytes memory decoded) = harness.decodeExecuteCalldata(
            abi.encodeCall(IERC7579Execution.execute, (bytes32(0), payload))
        );
        assertTrue(isExecute);
        assertEq(mode, bytes32(0));
        assertEq(decoded, payload);

        // executeFromExecutor has the identical arg shape and must also be recognized.
        (isExecute,,) = harness.decodeExecuteCalldata(
            abi.encodeCall(IERC7579Execution.executeFromExecutor, (bytes32(0), payload))
        );
        assertTrue(isExecute);
    }

    function test_decodeExecuteCalldata_rejectsNonExecute() public view {
        (bool isExecute,,) = harness.decodeExecuteCalldata(hex"deadbeef");
        assertFalse(isExecute, "short calldata accepted");

        (isExecute,,) =
            harness.decodeExecuteCalldata(abi.encodeCall(ERC20Mock.transfer, (kani, uint256(1e18))));
        assertFalse(isExecute, "non-execute selector accepted");
    }

    function test_isApproveCandidate_classification() public view {
        assertFalse(harness.isApproveCandidate(hex"01"));
        assertFalse(harness.isApproveCandidate(abi.encodeCall(ERC20Mock.transfer, (kani, uint256(1)))));
        assertFalse(harness.isApproveCandidate(abi.encodeCall(ERC20Mock.approve, (kani, uint256(0)))));
        assertFalse(harness.isApproveCandidate(abi.encodeCall(ERC20Mock.approve, (kani, type(uint256).max))));
        assertTrue(harness.isApproveCandidate(abi.encodeCall(ERC20Mock.approve, (kani, uint256(5e6)))));
    }

    function test_validateApproval_pathsAndReverts() public {
        (bool isApproval, address approvedSpender) =
            harness.validateApproval(address(this), address(usdc), abi.encodeCall(ERC20Mock.approve, (kani, uint256(5e6))));
        assertTrue(isApproval);
        assertEq(approvedSpender, kani);

        (isApproval,) =
            harness.validateApproval(address(this), address(usdc), abi.encodeCall(ERC20Mock.transfer, (kani, uint256(1))));
        assertFalse(isApproval);

        vm.expectRevert(SpendingLimitModule.SpendingLimitModule_UnlimitedApprovalRejected.selector);
        harness.validateApproval(address(this), address(usdc), abi.encodeCall(ERC20Mock.approve, (kani, type(uint256).max)));

        ERC20Mock unpriced = new ERC20Mock("Unpriced", "UNP", 18);
        vm.expectRevert(
            abi.encodeWithSelector(
                SpendingLimitModule.SpendingLimitModule_TokenNotPriced.selector, address(unpriced)
            )
        );
        harness.validateApproval(address(this), address(unpriced), abi.encodeCall(ERC20Mock.approve, (kani, uint256(1e18))));
    }

    function test_collectApprovals_batchCollectsAllApprovePairs() public view {
        Execution[] memory execs = new Execution[](3);
        execs[0] = Execution(address(usdc), 0, abi.encodeCall(ERC20Mock.approve, (kani, uint256(1e6))));
        execs[1] = Execution(address(usdc), 0, abi.encodeCall(ERC20Mock.transfer, (kani, uint256(1e6))));
        execs[2] = Execution(address(dai), 0, abi.encodeCall(ERC20Mock.approve, (rando, uint256(2e18))));

        (address[] memory tokens, address[] memory spenders) =
            harness.collectApprovals(address(this), true, bytes32(uint256(0x01) << 248), ERC7579Utils.encodeBatch(execs));

        assertEq(tokens.length, 2);
        assertEq(tokens[0], address(usdc));
        assertEq(spenders[0], kani);
        assertEq(tokens[1], address(dai));
        assertEq(spenders[1], rando);
    }

    /*//////////////////////////////////////////////////////////////
                     ACCOUNT VIEWS / OWNER FUNCTIONS
    //////////////////////////////////////////////////////////////*/

    function test_getUsdValue_matchesOracle() public view {
        assertEq(wallet.getUsdValue(address(usdc), 1000e6), oracle.getPrice(address(usdc), 1000e6));
    }

    function test_registryViews() public view {
        assertEq(wallet.getRouter(), feeRegistry.router());
        assertEq(wallet.getAgentId(), feeRegistry.agentId());
    }

    function test_withdraw_erc20AndEth() public {
        vm.startPrank(owner);
        wallet.withdraw(address(usdc), 1000e6, kani);
        wallet.withdraw(address(0), 1 ether, kani);
        vm.stopPrank();

        assertEq(usdc.balanceOf(kani), 1000e6);
        assertEq(kani.balance, 1 ether);
    }

    function test_withdraw_reverts() public {
        vm.startPrank(owner);
        vm.expectRevert(SessionHandler.SessionHandler_InvalidRecipient.selector);
        wallet.withdraw(address(usdc), 1, address(0));

        vm.expectRevert(SessionHandler.SessionHandler_NotEnoughBalance.selector);
        wallet.withdraw(address(usdc), type(uint128).max, kani);

        vm.expectRevert(SessionHandler.SessionHandler_NotEnoughBalance.selector);
        wallet.withdraw(address(0), 1000 ether, kani);
        vm.stopPrank();

        vm.prank(rando);
        vm.expectRevert(abi.encodeWithSelector(OwnableUpgradeable.OwnableUnauthorizedAccount.selector, rando));
        wallet.withdraw(address(usdc), 1, kani);
    }

    function test_pause_blocksExecuteUntilUnpaused() public {
        vm.prank(owner);
        wallet.pause();

        vm.prank(owner);
        vm.expectRevert(Pausable.EnforcedPause.selector);
        wallet.execute(
            bytes32(0), abi.encodePacked(address(usdc), uint256(0), abi.encodeCall(ERC20Mock.transfer, (kani, 1e6)))
        );

        vm.prank(owner);
        wallet.unpause();
        _ownerExecute(address(usdc), 0, abi.encodeCall(ERC20Mock.transfer, (kani, 1e6)));
        assertEq(usdc.balanceOf(kani), 1e6);
    }
}

/**
 * @notice Minimal spender used to consume allowances mid-batch, exercising the module's
 *         "approval must be spent to exactly zero in the same transaction" rule.
 */
contract MockSpender {
    function pull(address token, address from, uint256 amount) external {
        IERC20(token).transferFrom(from, address(this), amount);
    }
}
