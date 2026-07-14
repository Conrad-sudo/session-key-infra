// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

/**
 * @title SHSepoliaUniswapV2Test
 * @author Conrad Japhet
 * @notice Integration test suite for SessionHandler's Uniswap V2 session-key enforcement,
 *         against the officially deployed Uniswap V2 router/factory on Ethereum Sepolia.
 *
 * @dev SEPOLIA FORK REQUIRED — all tests use live Sepolia contract addresses (USDC, WETH,
 *      LINK, Uniswap V2 Router/Factory). Run with:
 *
 *        forge test --match-contract SHSepoliaUniswapV2Test --fork-url $SEPOLIA_RPC_URL
 *
 *      This is a near-identical copy of test/fork/SHUniswapV2Test.t.sol (the mainnet-fork
 *      suite), adapted for Sepolia:
 *        - DAI -> USDC as the primary pairing token for WETH (Sepolia's DAI/WETH pool is far
 *          shallower than its WETH/USDC pool; USDC + WETH + LINK are the three tokens with
 *          official Sepolia deployments and live Chainlink feeds per HelperConfig).
 *        - The confusingly-named `mkr` variable in the mainnet suite (actually bound to
 *          config.link there) is a real, correctly-named `link` here.
 *        - Absolute swap/liquidity amounts are sized against actual on-chain Sepolia pool
 *          reserves at the time this suite was written (WETH/USDC ~33 WETH / ~653k USDC,
 *          WETH/LINK ~4.16 WETH / ~1434 LINK, USDC/LINK ~608 USDC / ~13.4 LINK) rather than
 *          mainnet's much deeper liquidity — kept well under pool depth to avoid pathological
 *          slippage, and several assertions compare against a router-computed quote rather
 *          than a hardcoded expected amount, since testnet pool ratios can drift and are not
 *          expected to track real market prices (the Chainlink feeds used for USD budget
 *          accounting are real-market-priced independently of whatever ratio the test pool
 *          happens to hold).
 *
 *      execute() takes (mode, executionCalldata), the standard ERC-7579 shape. Session-key
 *      state/logic lives in SessionHandlerModule, not on the account. SendPackedUserOp builds
 *      the ERC-7579 calldata internally from (dest, value, data) rather than taking pre-built
 *      callData.
 *
 *      Tests are split into two categories:
 *
 *      1. Direct tests (no session key) — verify that the underlying Uniswap V2 router and
 *         pair mechanics work as expected on the fork. These never touch the wallet.
 *
 *      2. Session tests — submit UserOperations through the EntryPoint that call
 *         SessionHandler.execute(). These verify that SessionHandlerModule correctly
 *         parses calldata, prices the operation via SHOracle, and either enforces the
 *         session budget or credits it back (removeLiquidity).
 *
 *      setUp() provides each actor with 10 ETH, 100,000 USDC, and 5 WETH, and pre-approves
 *      the Uniswap V2 router for both tokens. Tests that need LP tokens use the
 *      liquidityAdded(address) modifier.
 */

import {PackedUserOperation} from "@account-abstraction/contracts/interfaces/PackedUserOperation.sol";
import {IEntryPoint} from "@account-abstraction/contracts/interfaces/IEntryPoint.sol";
import {Test, console2} from "forge-std/Test.sol";
import {IUniswapV2Router02} from "lib/v2-periphery/contracts/interfaces/IUniswapV2Router02.sol";
import {IUniswapV2Router01} from "lib/v2-periphery/contracts/interfaces/IUniswapV2Router01.sol";

import {SPO_UNISWAP_V2_FACTORY} from "../../script/Constants.s.sol";
import {IWETH} from "../../src/interfaces/IWETH.sol";
import {IERC20} from "@openzeppelin/contracts/interfaces/IERC20.sol";
import {SessionHandler} from "../../src/SessionHandler.sol";
import {SessionHandlerModule} from "../../src/SessionHandlerModule.sol";
import {HelperConfig} from "../../script/HelperConfig.s.sol";
import {SendPackedUserOp} from "../../script/SendPackedUserOp.s.sol";
import {DeploySHProtocol} from "../../script/DeploySHProtocol.s.sol";
import {ERC20Mock} from "../../src/mocks/ERC20Mock.sol";
import {SHOracle} from "../../src/SHOracle.sol";
import {SHRegistry} from "../../src/SHRegistry.sol";
import {SHFactory} from "../../src/SHFactory.sol";
import {SHTreasury} from "../../src/SHTreasury.sol";
import {IUniswapV2Factory} from "lib/v2-core/contracts/interfaces/IUniswapV2Factory.sol";
import {IUniswapV2Pair} from "lib/v2-core/contracts/interfaces/IUniswapV2Pair.sol";
import {AggregatorV3Interface} from "@chainlink/contracts/src/v0.8/shared/interfaces/AggregatorV3Interface.sol";

contract SHSepoliaUniswapV2Test is Test {
    SHOracle oracle;
    SHRegistry feeRegistry;
    HelperConfig.NetworkConfig config;
    SessionHandler sessionHandler;
    SessionHandlerModule spendingLimitModule;
    SendPackedUserOp sendPackedUserOp;

    /// @dev Starting USDC balance given to both `user` and `sessionHandler` in setUp.
    ///      Sepolia's official USDC deployment uses 6 decimals (same as mainnet USDC).
    uint256 private constant INITIAL_USDC_BALANCE = 100_000e6;

    IERC20 private usdc;
    IWETH private weth;
    IERC20 private link;

    address user;
    uint256 privateKey;

    /// @dev Simulated bundler; set as both tx.origin and msg.sender when calling handleOps.
    address bundler = makeAddr("bundler");

    IUniswapV2Factory private constant FACTORY = IUniswapV2Factory(SPO_UNISWAP_V2_FACTORY);
    IUniswapV2Router02 private router;

    /// @dev Session spending limit used across tests — $50,000 USD with 18 decimals of precision.
    uint256 constant BUDGET = 50000e18;

    /// @dev Unused constant kept for reference; 5 ETH in base units.
    uint256 constant ETH_VALUE = 5e18;

    /*//////////////////////////////////////////////////////////////
                               MODIFIERS
    //////////////////////////////////////////////////////////////*/

    /**
     * @dev Registers a session key for `user` scoped to the WETH contract.
     *      Permits transfer, transferFrom, approve, deposit (wrap), and withdraw (unwrap).
     *      Valid for 1 day from the current block timestamp.
     */
    modifier wethSessionAdded() {
        address sessionKey = user;
        address target = config.weth;
        bytes4[] memory sel = new bytes4[](5);
        sel[0] = IERC20.transfer.selector;
        sel[1] = IERC20.transferFrom.selector;
        sel[2] = IERC20.approve.selector;
        sel[3] = IWETH.deposit.selector;
        sel[4] = IWETH.withdraw.selector;
        uint48 validFrom = uint48(block.timestamp);
        uint48 validUntil = uint48(block.timestamp + 1 days);
        uint256 spendingLimit = BUDGET;

        vm.prank(sessionHandler.owner());
        sessionHandler.addSessionKey(sessionKey, target, sel, validFrom, validUntil, spendingLimit);

        _;
    }

    /**
     * @dev Registers a session key for `user` scoped to the Uniswap V2 router.
     *      Covers all 6 swap selectors plus addLiquidity, addLiquidityETH,
     *      removeLiquidity, and removeLiquidityETH.
     *      Valid between +1 h and +3 h from the current block. Tests that use this modifier
     *      must call vm.warp(block.timestamp + 1.1 hours) before submitting the UserOperation.
     */
    modifier routerSessionAdded() {
        address sessionKey = user;
        bytes4[] memory uniswapSelectors = new bytes4[](10);
        address target = config.router;
        uniswapSelectors[0] = IUniswapV2Router01.swapExactTokensForTokens.selector;
        uniswapSelectors[1] = IUniswapV2Router01.swapTokensForExactTokens.selector;
        uniswapSelectors[2] = IUniswapV2Router01.swapExactETHForTokens.selector;
        uniswapSelectors[3] = IUniswapV2Router01.swapTokensForExactETH.selector;
        uniswapSelectors[4] = IUniswapV2Router01.swapExactTokensForETH.selector;
        uniswapSelectors[5] = IUniswapV2Router01.swapETHForExactTokens.selector;
        uniswapSelectors[6] = IUniswapV2Router01.addLiquidity.selector;
        uniswapSelectors[7] = IUniswapV2Router01.addLiquidityETH.selector;
        uniswapSelectors[8] = IUniswapV2Router01.removeLiquidity.selector;
        uniswapSelectors[9] = IUniswapV2Router01.removeLiquidityETH.selector;

        uint48 validFrom = uint48(block.timestamp + 1 hours);
        uint48 validUntil = uint48(block.timestamp + 3 hours);
        uint256 spendingLimit = BUDGET;

        vm.prank(sessionHandler.owner());
        sessionHandler.addSessionKey(sessionKey, target, uniswapSelectors, validFrom, validUntil, spendingLimit);

        _;
    }

    /**
     * @dev Adds 1,000 USDC + proportional WETH liquidity to the USDC/WETH Uniswap V2 pool on
     *      behalf of `user`. The WETH amount is derived from live pool reserves via router.quote()
     *      so the deposit is always at the current pool ratio. Kept modest (well under 1% of the
     *      pool's live USDC reserve) since this is real Sepolia testnet liquidity, not a deep
     *      mainnet pool.
     *
     *      After adding, the LP token allowance for the router is set to max so subsequent
     *      removeLiquidity calls do not need a separate approval step.
     *
     * @param _user The address that provides the tokens, receives the LP tokens, and whose
     *              prank context is used for the router call.
     */
    modifier liquidityAdded(address _user) {
        address tokenA = config.usdc;
        address tokenB = config.weth;
        uint256 amountADesired = 1000e6;
        uint256 amountBDesired;
        uint256 amountAMin = 1;
        uint256 amountBMin = 1;
        address to = _user;
        uint256 deadline = block.timestamp + 30 minutes;
        address pair = FACTORY.getPair(tokenA, tokenB);
        // Get reserves in token0/token1 order and map to tokenA/tokenB order.
        (uint112 r0, uint112 r1,) = IUniswapV2Pair(pair).getReserves();
        address token0 = IUniswapV2Pair(pair).token0();
        (uint256 reserveA, uint256 reserveB) =
            token0 == tokenA ? (uint256(r0), uint256(r1)) : (uint256(r1), uint256(r0));

        amountBDesired = router.quote(amountADesired, reserveA, reserveB);

        vm.startPrank(_user);
        router.addLiquidity(tokenA, tokenB, amountADesired, amountBDesired, amountAMin, amountBMin, to, deadline);
        IERC20(pair).approve(address(router), type(uint256).max);
        vm.stopPrank();

        _;
    }

    /*//////////////////////////////////////////////////////////////
                                 SETUP
    //////////////////////////////////////////////////////////////*/

    /**
     * @dev Deploys a fresh SessionHandler + EntryPoint + SHOracle via DeploySHProtocol,
     *      then funds both `user` and `sessionHandler` with:
     *        - 10 ETH (raw, for gas and ETH-value calls)
     *        - 100,000 USDC (via vm.deal storage override)
     *        - 5 WETH (wrapped from the ETH balance)
     *      All router approvals (USDC and WETH) are set to max for both actors so individual
     *      tests do not need to manage allowances.
     */
    function setUp() public {
        (user, privateKey) = makeAddrAndKey("user");

        DeploySHProtocol deployer = new DeploySHProtocol();
        SHFactory factory;
        SHTreasury treasury;
        (factory, treasury, config, oracle) = deployer.run();
        feeRegistry = SHRegistry(treasury.REGISTRY());
        spendingLimitModule = SessionHandlerModule(factory.spendingLimitModule());
        vm.prank(config.account);
        sessionHandler = SessionHandler(payable(factory.deployWallet()));
        sendPackedUserOp = new SendPackedUserOp();

        usdc = IERC20(config.usdc);
        weth = IWETH(config.weth);
        link = IERC20(config.link);
        router = IUniswapV2Router02(config.router);

        vm.deal(address(sessionHandler), 10 ether);
        vm.deal(user, 10 ether);

        deal(config.usdc, user, INITIAL_USDC_BALANCE);
        deal(config.usdc, address(sessionHandler), INITIAL_USDC_BALANCE);

        vm.startPrank(user);
        weth.deposit{value: 5 ether}();
        weth.approve(address(router), type(uint256).max);
        usdc.approve(address(router), type(uint256).max);
        vm.stopPrank();

        vm.startPrank(address(sessionHandler));
        weth.deposit{value: 5 ether}();
        weth.approve(config.router, type(uint256).max);
        usdc.approve(config.router, type(uint256).max);
        vm.stopPrank();
    }

    /*//////////////////////////////////////////////////////////////
                     CALLDATA / ORACLE REFRESH HELPERS
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
     * @dev Mocks every configured Chainlink feed to return updatedAt = block.timestamp after a vm.warp.
     *      Required because real Sepolia feeds cannot have updateAnswer called on them — their updatedAt
     *      stays at the fork-block value while block.timestamp advances, eventually exceeding the per-feed
     *      heartbeat and triggering SHOracle_StalePrice. Sepolia heartbeats are conservatively set to
     *      1 hour across the board in HelperConfig, so this matters even for modest warps.
     */
    function _refreshForkFeeds() internal {
        _mockFeedFresh(config.ethUsdPriceFeed);
        _mockFeedFresh(config.usdcUsdPriceFeed);
        _mockFeedFresh(config.daiUsdPriceFeed);
        _mockFeedFresh(config.usdtUsdPriceFeed);
        _mockFeedFresh(config.aaveUsdPriceFeed);
        _mockFeedFresh(config.linkUsdPriceFeed);
        _mockFeedFresh(config.oneinchUsdPriceFeed);
        _mockFeedFresh(config.apeUsdPriceFeed);
        _mockFeedFresh(config.arbUsdPriceFeed);
        _mockFeedFresh(config.bnbUsdPriceFeed);
        _mockFeedFresh(config.btcUsdPriceFeed);
        _mockFeedFresh(config.compUsdPriceFeed);
        _mockFeedFresh(config.crvUsdPriceFeed);
        _mockFeedFresh(config.ensUsdPriceFeed);
        _mockFeedFresh(config.sandUsdPriceFeed);
        _mockFeedFresh(config.sushiUsdPriceFeed);
        _mockFeedFresh(config.wtaoUsdPriceFeed);
        _mockFeedFresh(config.uniUsdPriceFeed);
        _mockFeedFresh(config.yfiUsdPriceFeed);
    }

    function _mockFeedFresh(address feed) private {
        if (feed == address(0)) return;
        (uint80 roundId, int256 answer, uint256 startedAt,, uint80 answeredInRound) =
            AggregatorV3Interface(feed).latestRoundData();
        vm.mockCall(
            feed,
            abi.encodeWithSelector(AggregatorV3Interface.latestRoundData.selector),
            abi.encode(roundId, answer, startedAt, block.timestamp, answeredInRound)
        );
    }

    /*//////////////////////////////////////////////////////////////
                           DIRECT ROUTER TESTS
    //////////////////////////////////////////////////////////////*/

    /**
     * @notice Queries the router for the output amounts of a multi-hop WETH->USDC->LINK swap.
     * @dev Sanity check that getAmountsOut works on the fork and pool reserves are readable.
     *      amountIn kept small (0.001 WETH) since the USDC/LINK bridge pool is comparatively
     *      shallow (~608 USDC / ~13.4 LINK at the time this suite was written).
     */
    function testGetAmountsOut() public view {
        address[] memory path = new address[](3);
        path[0] = config.weth;
        path[1] = config.usdc;
        path[2] = config.link;

        uint256 amountIn = 0.001 ether;
        uint256[] memory amounts = router.getAmountsOut(amountIn, path);

        console2.log("WETH: ", amounts[0]);
        console2.log("USDC: ", amounts[1]);
        console2.log("LINK: ", amounts[2]);
    }

    /**
     * @notice Queries the router for the input amounts required for a multi-hop WETH->USDC->LINK swap.
     * @dev amountOut is set to 0.01 LINK, well below the USDC/LINK pool's LINK reserve (~13.4 LINK).
     */
    function testGetAmountsIn() public view {
        address[] memory path = new address[](3);
        path[0] = config.weth;
        path[1] = config.usdc;
        path[2] = config.link;

        uint256 amountOut = 0.01e18; // 0.01 LINK — must be less than the USDC/LINK pool's LINK reserve
        uint256[] memory amounts = router.getAmountsIn(amountOut, path);

        console2.log("WETH: ", amounts[0]);
        console2.log("USDC: ", amounts[1]);
        console2.log("LINK: ", amounts[2]);
    }

    /**
     * @notice Wraps ETH to WETH directly via the WETH contract.
     * @dev Verifies the 1:1 conversion and that balanceOf reflects the deposit immediately.
     */
    function testSwapEthForWeth() public {
        uint256 amount = 1 ether;

        vm.startPrank(user);
        uint256 wethBefore = weth.balanceOf(user);
        IWETH(config.weth).deposit{value: amount}();
        uint256 wethAfter = weth.balanceOf(user);
        vm.stopPrank();

        assertEq(wethAfter - wethBefore, amount);
        console2.log("WETH received: ", wethAfter - wethBefore);
    }

    /**
     * @notice Swaps an exact amount of WETH for USDC directly through the router.
     * @dev Confirms that the received USDC is at least amountOutMin and the user balance updates.
     */
    function testSwapExactTokensForTokens() public {
        address[] memory path = new address[](2);
        path[0] = config.weth;
        path[1] = config.usdc;

        uint256 amountIn = 1 ether;
        uint256 amountOutMin = router.getAmountsOut(amountIn, path)[1];
        uint256 deadline = block.timestamp;
        address to = user;

        vm.prank(user);
        uint256[] memory amounts = router.swapExactTokensForTokens(amountIn, amountOutMin, path, to, deadline);

        console2.log("WETH: ", amounts[0]);
        console2.log("USDC: ", amounts[1]);

        assertGe(usdc.balanceOf(user), amounts[1]);
    }

    /**
     * @notice Swaps WETH for an exact amount of USDC directly through the router.
     * @dev Confirms that the user receives exactly the requested USDC and that the WETH spent
     *      does not exceed amountInMax (computed live from the router).
     */
    function testSwapTokensForExactTokens() public {
        address[] memory path = new address[](2);
        path[0] = config.weth;
        path[1] = config.usdc;

        uint256 amountOut = 1000e6;
        uint256 amountInMax = router.getAmountsIn(amountOut, path)[0];

        vm.prank(user);
        uint256[] memory amounts = router.swapTokensForExactTokens({
            amountOut: amountOut, amountInMax: amountInMax, path: path, to: user, deadline: block.timestamp
        });

        console2.log("WETH: ", amounts[0]);
        console2.log("USDC: ", amounts[1]);

        assertGe(usdc.balanceOf(user), amounts[1]);
    }

    /**
     * @notice The SessionHandler owner can wrap ETH to WETH by calling execute directly.
     * @dev Verifies that the WETH balance of sessionHandler increases by exactly `value`.
     *      setUp pre-funds sessionHandler with 5 WETH, so the assertion uses a delta.
     */
    function testOwnerCanSwapEthForWeth() public {
        address dest = config.weth;
        uint256 value = 1 ether;
        bytes memory data = abi.encodeWithSelector(IWETH.deposit.selector);
        uint256 wethBefore = weth.balanceOf(address(sessionHandler));

        vm.startPrank(sessionHandler.owner());
        sessionHandler.execute(bytes32(0), _encodeExecutionCalldata(dest, value, data));
        vm.stopPrank();

        assertEq(weth.balanceOf(address(sessionHandler)) - wethBefore, value);
        console2.log("WETH received: ", weth.balanceOf(address(sessionHandler)));
    }

    /**
     * @notice Adds 1,000 USDC + proportional WETH to the USDC/WETH pool directly as `user`.
     * @dev amountBDesired is computed from live reserves via router.quote() so the deposit
     *      always matches the current pool ratio. Verifies user receives the minted LP tokens.
     */
    function testAddLiquidityOnly() public {
        address tokenA = config.usdc;
        address tokenB = config.weth;
        uint256 amountADesired = 1000e6;
        uint256 amountBDesired;
        uint256 amountAMin = 1;
        uint256 amountBMin = 1;
        address to = user;
        uint256 deadline = block.timestamp + 30 minutes;
        address pair = FACTORY.getPair(tokenA, tokenB);
        // Get reserves in token0/token1 order and map to tokenA/tokenB order.
        (uint112 r0, uint112 r1,) = IUniswapV2Pair(pair).getReserves();
        address token0 = IUniswapV2Pair(pair).token0();
        (uint256 reserveA, uint256 reserveB) =
            token0 == tokenA ? (uint256(r0), uint256(r1)) : (uint256(r1), uint256(r0));

        amountBDesired = router.quote(amountADesired, reserveA, reserveB);

        console2.log("AMOUNT DESIRED: ", amountBDesired);

        vm.startPrank(user);
        (uint256 amountA, uint256 amountB, uint256 liquidity) =
            router.addLiquidity(tokenA, tokenB, amountADesired, amountBDesired, amountAMin, amountBMin, to, deadline);
        vm.stopPrank();

        console2.log("USDC :  ", amountA);
        console2.log("WETH:   ", amountB);
        console2.log("LIQUIDITY:  ", liquidity);

        assertEq(IERC20(pair).balanceOf(user), liquidity);
    }

    /**
     * @notice Adds 300 USDC + proportional ETH to the USDC/WETH pool directly as `user`.
     * @dev Uses addLiquidityETH which accepts raw ETH and wraps it internally. The ETH amount
     *      is derived from reserves via router.quote(). Verifies user receives LP tokens.
     */
    function testAddLiquidityETHOnly() public {
        address token = config.usdc;
        uint256 amountEthDesired;
        uint256 amountTokenDesired = 300e6;
        uint256 amountTokenMin = 1;
        uint256 amountEthMin = 1;
        address to = user;
        uint256 deadline = block.timestamp + 30 minutes;

        address pair = FACTORY.getPair(token, config.weth);
        // Get reserves in token0/token1 order and map to token/WETH order.
        (uint112 r0, uint112 r1,) = IUniswapV2Pair(pair).getReserves();
        address token0 = IUniswapV2Pair(pair).token0();
        (uint256 reserveA, uint256 reserveB) = token0 == token ? (uint256(r0), uint256(r1)) : (uint256(r1), uint256(r0));

        amountEthDesired = router.quote(amountTokenDesired, reserveA, reserveB);

        vm.startPrank(user);
        (uint256 amountToken, uint256 amountEth, uint256 liquidity) = router.addLiquidityETH{value: amountEthDesired}(
            token, amountTokenDesired, amountTokenMin, amountEthMin, to, deadline
        );
        vm.stopPrank();

        console2.log("USDC :  ", amountToken);
        console2.log("ETH:   ", amountEth);
        console2.log("LIQUIDITY:  ", liquidity);

        assertEq(IERC20(pair).balanceOf(user), liquidity);
    }

    /**
     * @notice Removes all of `user`'s USDC/WETH LP directly through the router.
     * @dev Uses the proportional share formula (liquidity * reserve / totalSupply) to derive
     *      expected token amounts. Verifies the LP balance is zeroed and both token balances
     *      increase by the expected amounts.
     */
    function testRemoveLiquidityOnly() public liquidityAdded(user) {
        address tokenA = config.usdc;
        address tokenB = config.weth;
        address pair = FACTORY.getPair(tokenA, tokenB);
        uint256 liquidity = IERC20(pair).balanceOf(user);
        console2.log("LIQUIDITY TO REMOVE: ", liquidity);
        address to = user;
        uint256 deadline = block.timestamp + 30 minutes;

        (uint112 r0, uint112 r1,) = IUniswapV2Pair(pair).getReserves();
        uint256 totalSupply = IERC20(pair).totalSupply();

        uint256 expectedAmount0 = (liquidity * uint256(r0)) / totalSupply;
        uint256 expectedAmount1 = (liquidity * uint256(r1)) / totalSupply;

        address token0 = IUniswapV2Pair(pair).token0();
        (uint256 expectedA, uint256 expectedB) =
            token0 == tokenA ? (expectedAmount0, expectedAmount1) : (expectedAmount1, expectedAmount0);

        uint256 balanceBeforeA = IERC20(tokenA).balanceOf(user);
        uint256 balanceBeforeB = IERC20(tokenB).balanceOf(user);
        vm.startPrank(user);
        (uint256 amountA, uint256 amountB) =
            router.removeLiquidity(tokenA, tokenB, liquidity, expectedA, expectedB, to, deadline);
        vm.stopPrank();
        uint256 balanceAfterA = IERC20(tokenA).balanceOf(user);
        uint256 balanceAfterB = IERC20(tokenB).balanceOf(user);

        console2.log("USDC :  ", amountA);
        console2.log("WETH:   ", amountB);

        assertEq(IERC20(pair).balanceOf(user), 0);
        assertEq(expectedA, amountA);
        assertEq(expectedB, amountB);
        assertEq(balanceAfterA - balanceBeforeA, amountA);
        assertEq(balanceAfterB - balanceBeforeB, amountB);
    }

    /**
     * @notice Removes all of `user`'s USDC/WETH LP directly through removeLiquidityETH.
     * @dev removeLiquidityETH unwraps the WETH share to raw ETH before transferring to `to`.
     *      Verifies the LP balance is zeroed and that both the USDC and ETH balances of `user`
     *      increase by the expected amounts.
     */
    function testRemoveLiquidityETH() public liquidityAdded(user) {
        address token = config.usdc;
        address pair = FACTORY.getPair(token, config.weth);
        uint256 liquidity = IERC20(pair).balanceOf(user);

        uint256 amountTokenMin = 1;
        uint256 amountEthMin = 1;
        address to = user;
        uint256 deadline = block.timestamp + 30 minutes;

        uint256 balanceBeforeToken = IERC20(token).balanceOf(user);
        uint256 balanceBeforeEth = address(user).balance;

        vm.startPrank(user);
        (uint256 amountToken, uint256 amountEth) =
            router.removeLiquidityETH(token, liquidity, amountTokenMin, amountEthMin, to, deadline);
        vm.stopPrank();
        uint256 balanceAfterToken = IERC20(token).balanceOf(user);
        uint256 balanceAfterEth = user.balance;

        console2.log("USDC :  ", amountToken);
        console2.log("ETH:   ", amountEth);

        assertEq(IERC20(pair).balanceOf(user), 0);
        assertEq(balanceAfterToken - balanceBeforeToken, amountToken);
        assertEq(balanceAfterEth - balanceBeforeEth, amountEth);
    }

    /**
     * @notice Creates a new Uniswap V2 pair for an ERC20Mock token paired with WETH.
     * @dev Verifies that the factory stores token0 and token1 in ascending address order.
     */
    function testCreatePair() public {
        ERC20Mock token = new ERC20Mock("TestCoin", "TC", 18);

        address pair = FACTORY.createPair(config.weth, address(token));

        address token0 = IUniswapV2Pair(pair).token0();
        address token1 = IUniswapV2Pair(pair).token1();

        if (address(token) < config.weth) {
            assertEq(token0, address(token));
            assertEq(token1, config.weth);
        } else {
            assertEq(token0, config.weth);
            assertEq(token1, address(token));
        }
    }

    /*//////////////////////////////////////////////////////////////
                           SESSION KEY TESTS
    //////////////////////////////////////////////////////////////*/

    /**
     * @notice Session key can wrap ETH to WETH through SessionHandler via a UserOperation.
     * @dev The WETH session (wethSessionAdded) permits the deposit selector on the WETH contract.
     *      Budget is charged against the USD value of 1 ETH as priced by the oracle.
     *      setUp already provides sessionHandler with 5 WETH, so the assertion uses a delta.
     */
    function testSwapEthForWethWithSession() public wethSessionAdded {
        address dest = config.weth;
        uint256 value = 1 ether;
        uint256 wethBefore = weth.balanceOf(address(sessionHandler));

        PackedUserOperation[] memory packedUserOp = new PackedUserOperation[](1);
        bytes memory data = abi.encodeWithSelector(IWETH.deposit.selector);

        (PackedUserOperation memory userOp,,) = sendPackedUserOp.generateSignedUserOp(
            address(sessionHandler), config, address(spendingLimitModule), dest, value, data, user, privateKey
        );
        packedUserOp[0] = userOp;

        vm.warp(block.timestamp + 1.1 hours);
        _refreshForkFeeds();
        vm.startPrank(bundler, bundler);
        IEntryPoint(config.entryPoint).handleOps(packedUserOp, payable(user));
        vm.stopPrank();

        assertEq(weth.balanceOf(address(sessionHandler)) - wethBefore, value);
    }

    /**
     * @notice Session key can execute swapTokensForExactTokens through SessionHandler.
     * @dev Buys exactly 1,000 USDC by spending up to a router-computed amount of WETH. setUp
     *      provides sessionHandler with 5 WETH and max router approval, so no extra setup is
     *      needed. Budget is charged against the USD value of the WETH spent (tokenIn amount),
     *      not the USDC received.
     */
    function testSwapTokensForExactTokensWithSession() public routerSessionAdded {
        address dest = config.router;
        address[] memory path = new address[](2);
        path[0] = config.weth;
        path[1] = config.usdc;

        uint256 amountOut = 1000e6;
        uint256 amountInMax = router.getAmountsIn(amountOut, path)[0];
        uint256 deadline = block.timestamp + 2 hours;
        address to = address(sessionHandler);

        bytes memory data = abi.encodeWithSelector(
            IUniswapV2Router01.swapTokensForExactTokens.selector, amountOut, amountInMax, path, to, deadline
        );

        PackedUserOperation[] memory packedUserOp = new PackedUserOperation[](1);
        (PackedUserOperation memory userOp,,) = sendPackedUserOp.generateSignedUserOp(
            address(sessionHandler), config, address(spendingLimitModule), dest, 0, data, user, privateKey
        );
        packedUserOp[0] = userOp;

        vm.warp(block.timestamp + 1.1 hours);
        _refreshForkFeeds();
        vm.startPrank(bundler, bundler);
        IEntryPoint(config.entryPoint).handleOps(packedUserOp, payable(user));
        vm.stopPrank();

        assertEq(usdc.balanceOf(address(sessionHandler)), INITIAL_USDC_BALANCE + amountOut);
        assertLt(sessionHandler.getRemainingBudget(user), BUDGET);
    }

    /**
     * @notice Session key can execute swapExactTokensForTokens through SessionHandler.
     * @dev Sells exactly 1 WETH for at least a router-computed minimum of USDC. setUp provides
     *      sessionHandler with 5 WETH and max router approval. Budget is charged against the
     *      USD value of the 1 WETH sold (tokenIn), as extracted by SessionHandlerModule.
     *      deadline must be set beyond the vm.warp(+1.1 hours) applied before handleOps.
     */
    function testSwapExactTokensForTokensWithSession() public routerSessionAdded {
        address dest = config.router;
        address[] memory path = new address[](2);
        path[0] = config.weth;
        path[1] = config.usdc;

        uint256 amountIn = 1 ether;
        uint256 amountOutMin = router.getAmountsOut(amountIn, path)[1];
        uint256 deadline = block.timestamp + 2 hours;
        address to = address(sessionHandler);

        bytes memory data = abi.encodeWithSelector(
            IUniswapV2Router01.swapExactTokensForTokens.selector, amountIn, amountOutMin, path, to, deadline
        );

        PackedUserOperation[] memory packedUserOp = new PackedUserOperation[](1);
        (PackedUserOperation memory userOp,,) = sendPackedUserOp.generateSignedUserOp(
            address(sessionHandler), config, address(spendingLimitModule), dest, 0, data, user, privateKey
        );
        packedUserOp[0] = userOp;

        vm.warp(block.timestamp + 1.1 hours);
        _refreshForkFeeds();
        vm.startPrank(bundler, bundler);
        IEntryPoint(config.entryPoint).handleOps(packedUserOp, payable(user));
        vm.stopPrank();

        assertGe(usdc.balanceOf(address(sessionHandler)), INITIAL_USDC_BALANCE + amountOutMin);
        assert(sessionHandler.getRemainingBudget(user) < BUDGET);
    }

    /**
     * @notice Session key can execute swapExactETHForTokens through SessionHandler.
     * @dev Forwards 1 ETH as `value` directly to the router. The router wraps it internally,
     *      so no prior WETH deposit or ERC20 approval is needed. The ETH value is priced via the
     *      oracle and charged against the session budget.
     */
    function testSwapExactETHForTokensWithSession() public routerSessionAdded {
        address dest = config.router;
        uint256 value = 1 ether;
        address[] memory path = new address[](2);
        path[0] = config.weth;
        path[1] = config.usdc;

        uint256 amountOutMin = router.getAmountsOut(value, path)[1];
        uint256 deadline = block.timestamp + 2 hours;
        address to = address(sessionHandler);

        bytes memory data =
            abi.encodeWithSelector(IUniswapV2Router01.swapExactETHForTokens.selector, amountOutMin, path, to, deadline);

        PackedUserOperation[] memory packedUserOp = new PackedUserOperation[](1);
        (PackedUserOperation memory userOp,,) = sendPackedUserOp.generateSignedUserOp(
            address(sessionHandler), config, address(spendingLimitModule), dest, value, data, user, privateKey
        );
        packedUserOp[0] = userOp;

        vm.warp(block.timestamp + 1.1 hours);
        _refreshForkFeeds();
        vm.startPrank(bundler, bundler);
        IEntryPoint(config.entryPoint).handleOps(packedUserOp, payable(user));
        vm.stopPrank();

        assertGe(usdc.balanceOf(address(sessionHandler)), INITIAL_USDC_BALANCE + amountOutMin);
        assertEq(sessionHandler.getRemainingBudget(user), BUDGET - oracle.getUsdValue(address(0), value));
    }

    /**
     * @notice Session key can execute swapETHForExactTokens through SessionHandler.
     * @dev Buys exactly 1,000 USDC with ETH. The required ETH input is computed via
     *      router.getAmountsIn() so the forwarded value is tight. SessionHandlerModule
     *      charges the full `value` forwarded (not the actual WETH spent by Uniswap), since
     *      the ETH refund comes back after execution but the budget is already decremented
     *      during preCheck.
     */
    function testSwapEthForExactTokensWithSession() public routerSessionAdded {
        address dest = config.router;

        address[] memory path = new address[](2);
        path[0] = config.weth;
        path[1] = config.usdc;
        uint256 amountOut = 1000e6;
        uint256[] memory amounts = router.getAmountsIn(amountOut, path);
        console2.log("WETH AMOUNT IN  ******************: ", amounts[0]);
        uint256 value = amounts[0];

        uint256 deadline = block.timestamp + 2 hours;
        address to = address(sessionHandler);

        bytes memory data =
            abi.encodeWithSelector(IUniswapV2Router01.swapETHForExactTokens.selector, amountOut, path, to, deadline);

        PackedUserOperation[] memory packedUserOp = new PackedUserOperation[](1);
        (PackedUserOperation memory userOp,,) = sendPackedUserOp.generateSignedUserOp(
            address(sessionHandler), config, address(spendingLimitModule), dest, value, data, user, privateKey
        );
        packedUserOp[0] = userOp;

        vm.prank(address(sessionHandler));
        weth.approve(address(router), type(uint256).max);

        vm.warp(block.timestamp + 1.1 hours);
        _refreshForkFeeds();
        vm.startPrank(bundler, bundler);
        IEntryPoint(config.entryPoint).handleOps(packedUserOp, payable(user));
        vm.stopPrank();

        assertGe(usdc.balanceOf(address(sessionHandler)), INITIAL_USDC_BALANCE + amountOut);
        assertEq(sessionHandler.getRemainingBudget(user), BUDGET - oracle.getUsdValue(address(0), value));
    }

    /**
     * @notice Session key can execute swapTokensForExactETH through SessionHandler.
     * @dev Sells USDC to receive exactly 0.05 ETH. The owner first acquires USDC for
     *      sessionHandler by swapping 0.1 WETH->USDC and approving the router to spend USDC,
     *      both via direct execute() calls (no UserOp) — demonstrating the owner escape hatch,
     *      though sessionHandler already holds plenty of USDC from setUp regardless. Budget is
     *      charged against the USD value of the ETH output (amountOut), as extracted by
     *      SessionHandlerModule. Assertion uses a small tolerance because Uniswap may return
     *      slightly more ETH than requested before unwrapping.
     */
    function testSwapTokensForExactETHWithSession() public routerSessionAdded {
        // Owner pre-funds sessionHandler with USDC by swapping WETH -> USDC.
        address[] memory buyPath = new address[](2);
        buyPath[0] = config.weth;
        buyPath[1] = config.usdc;

        vm.startPrank(sessionHandler.owner());
        sessionHandler.execute(
            bytes32(0),
            _encodeExecutionCalldata(
                config.router,
                0,
                abi.encodeWithSelector(
                    IUniswapV2Router01.swapExactTokensForTokens.selector,
                    0.1 ether,
                    1,
                    buyPath,
                    address(sessionHandler),
                    block.timestamp + 2 hours
                )
            )
        );
        sessionHandler.execute(
            bytes32(0),
            _encodeExecutionCalldata(
                config.usdc, 0, abi.encodeWithSelector(IERC20.approve.selector, config.router, type(uint256).max)
            )
        );
        vm.stopPrank();

        address dest = config.router;
        address[] memory path = new address[](2);
        path[0] = config.usdc;
        path[1] = config.weth;

        uint256 amountOut = 0.05 ether;
        uint256 spentAMount = oracle.getUsdValue(address(0), amountOut);
        uint256 amountInMax = router.getAmountsIn(amountOut, path)[0];
        uint256 deadline = block.timestamp + 2 hours;
        address to = address(sessionHandler);

        bytes memory data = abi.encodeWithSelector(
            IUniswapV2Router01.swapTokensForExactETH.selector, amountOut, amountInMax, path, to, deadline
        );

        PackedUserOperation[] memory packedUserOp = new PackedUserOperation[](1);
        (PackedUserOperation memory userOp,,) = sendPackedUserOp.generateSignedUserOp(
            address(sessionHandler), config, address(spendingLimitModule), dest, 0, data, user, privateKey
        );
        packedUserOp[0] = userOp;

        uint256 ethBefore = address(sessionHandler).balance;

        vm.warp(block.timestamp + 1.1 hours);
        _refreshForkFeeds();
        vm.startPrank(bundler, bundler);
        IEntryPoint(config.entryPoint).handleOps(packedUserOp, payable(user));
        vm.stopPrank();

        assertGe(address(sessionHandler).balance, ethBefore + amountOut - 0.001 ether);
        assertEq(sessionHandler.getRemainingBudget(user), BUDGET - spentAMount);
    }

    /**
     * @notice Session key can execute swapExactTokensForETH through SessionHandler.
     * @dev Sells exactly 1,000 USDC for at least a router-computed minimum of ETH. The owner
     *      first swaps 0.1 WETH->USDC to add headroom (sessionHandler already holds plenty of
     *      USDC from setUp), then approves the router for USDC. Budget is charged against the
     *      USD value of the USDC sold (tokenIn), as extracted by SessionHandlerModule.
     */
    function testSwapExactTokensForETHWithSession() public routerSessionAdded {
        // Owner pre-funds sessionHandler with USDC by swapping WETH -> USDC.
        address[] memory buyPath = new address[](2);
        buyPath[0] = config.weth;
        buyPath[1] = config.usdc;

        vm.startPrank(sessionHandler.owner());
        sessionHandler.execute(
            bytes32(0),
            _encodeExecutionCalldata(
                config.router,
                0,
                abi.encodeWithSelector(
                    IUniswapV2Router01.swapExactTokensForTokens.selector,
                    0.1 ether,
                    1,
                    buyPath,
                    address(sessionHandler),
                    block.timestamp
                )
            )
        );
        sessionHandler.execute(
            bytes32(0),
            _encodeExecutionCalldata(
                config.usdc, 0, abi.encodeWithSelector(IERC20.approve.selector, config.router, type(uint256).max)
            )
        );
        vm.stopPrank();

        address dest = config.router;
        address[] memory path = new address[](2);
        path[0] = config.usdc;
        path[1] = config.weth;

        uint256 amountIn = 1000e6;
        uint256 amountOutMin = router.getAmountsOut(amountIn, path)[1];
        uint256 deadline = block.timestamp + 2 hours;
        address to = address(sessionHandler);

        bytes memory data = abi.encodeWithSelector(
            IUniswapV2Router01.swapExactTokensForETH.selector, amountIn, amountOutMin, path, to, deadline
        );

        PackedUserOperation[] memory packedUserOp = new PackedUserOperation[](1);
        (PackedUserOperation memory userOp,,) = sendPackedUserOp.generateSignedUserOp(
            address(sessionHandler), config, address(spendingLimitModule), dest, 0, data, user, privateKey
        );
        packedUserOp[0] = userOp;

        uint256 ethBefore = address(sessionHandler).balance;

        vm.warp(block.timestamp + 1.1 hours);
        _refreshForkFeeds();
        vm.startPrank(bundler, bundler);
        IEntryPoint(config.entryPoint).handleOps(packedUserOp, payable(user));
        vm.stopPrank();

        assertGe(address(sessionHandler).balance, ethBefore + amountOutMin - 0.001 ether);
        assertEq(sessionHandler.getRemainingBudget(user), BUDGET - oracle.getUsdValue(config.usdc, amountIn));
    }

    /**
     * @notice Session key is rejected when the USD value of an addLiquidity call exceeds BUDGET.
     * @dev Attempts to add 86,500 USDC + proportional WETH (well over $50,000 at real Chainlink
     *      prices, regardless of this testnet pool's internal ratio) against a session with
     *      BUDGET = $50,000. preCheck reverts with SessionHandlerModule_SpendingLimitExceeded,
     *      which the EntryPoint catches as a failed execution (handleOps does not revert overall).
     *      addLiquidity is not bounded by existing pool reserves (adding liquidity only ever
     *      increases them), so this is safe to attempt regardless of the pool's live depth —
     *      sessionHandler just needs to actually hold the tokens, which setUp already provides.
     */
    function testAddLiquidityFailsWhenSessionOverBudget() public routerSessionAdded {
        address tokenA = config.usdc;
        address tokenB = config.weth;
        uint256 amountADesired = 86500e6;
        uint256 amountBDesired;
        uint256 amountAMin = 1;
        uint256 amountBMin = 1;
        address to = address(sessionHandler);
        uint256 deadline = block.timestamp + 1.2 hours;
        address dest = config.router;
        address pair = FACTORY.getPair(tokenA, tokenB);
        (uint112 r0, uint112 r1,) = IUniswapV2Pair(pair).getReserves();
        address token0 = IUniswapV2Pair(pair).token0();
        (uint256 reserveA, uint256 reserveB) =
            token0 == tokenA ? (uint256(r0), uint256(r1)) : (uint256(r1), uint256(r0));

        amountBDesired = router.quote(amountADesired, reserveA, reserveB);

        PackedUserOperation[] memory packedUserOp = new PackedUserOperation[](1);

        bytes memory data = abi.encodeWithSelector(
            IUniswapV2Router01.addLiquidity.selector,
            tokenA,
            tokenB,
            amountADesired,
            amountBDesired,
            amountAMin,
            amountBMin,
            to,
            deadline
        );
        (PackedUserOperation memory userOp,,) = sendPackedUserOp.generateSignedUserOp(
            address(sessionHandler), config, address(spendingLimitModule), dest, 0, data, user, privateKey
        );
        packedUserOp[0] = userOp;

        vm.warp(block.timestamp + 1.1 hours);
        _refreshForkFeeds();
        vm.startPrank(bundler, bundler);
        IEntryPoint(config.entryPoint).handleOps(packedUserOp, payable(user));
        vm.stopPrank();

        // handleOps does not revert on failed UserOps — the EntryPoint catches the execution
        // revert and emits UserOperationEvent(success=false). Verify the budget is intact,
        // proving the spending-limit check fired and no tokens were moved.
        assertEq(sessionHandler.getRemainingBudget(user), BUDGET);
    }

    /**
     * @notice Session key can execute addLiquidity through SessionHandler.
     * @dev Adds 2,500 USDC + proportional WETH (comfortably within BUDGET = $50,000 at real
     *      Chainlink prices). amountBDesired is computed from live reserves via router.quote().
     *      Budget is charged against the combined USD value of both tokens deposited.
     */
    function testAddLiquidityWithSession() public routerSessionAdded {
        address tokenA = config.usdc;
        address tokenB = config.weth;
        uint256 valueInUsd;
        uint256 amountADesired = 2500e6;
        uint256 amountBDesired;
        uint256 amountAMin = 1;
        uint256 amountBMin = 1;
        address to = address(sessionHandler);
        uint256 deadline = block.timestamp + 1.2 hours;
        address dest = config.router;
        address pair = FACTORY.getPair(tokenA, tokenB);
        (uint112 r0, uint112 r1,) = IUniswapV2Pair(pair).getReserves();
        address token0 = IUniswapV2Pair(pair).token0();
        (uint256 reserveA, uint256 reserveB) =
            token0 == tokenA ? (uint256(r0), uint256(r1)) : (uint256(r1), uint256(r0));

        amountBDesired = router.quote(amountADesired, reserveA, reserveB);

        valueInUsd += oracle.getUsdValue(tokenA, amountADesired);
        valueInUsd += oracle.getUsdValue(tokenB, amountBDesired);

        PackedUserOperation[] memory packedUserOp = new PackedUserOperation[](1);

        bytes memory data = abi.encodeWithSelector(
            IUniswapV2Router01.addLiquidity.selector,
            tokenA,
            tokenB,
            amountADesired,
            amountBDesired,
            amountAMin,
            amountBMin,
            to,
            deadline
        );
        (PackedUserOperation memory userOp,,) = sendPackedUserOp.generateSignedUserOp(
            address(sessionHandler), config, address(spendingLimitModule), dest, 0, data, user, privateKey
        );
        packedUserOp[0] = userOp;

        vm.warp(block.timestamp + 1.1 hours);
        _refreshForkFeeds();
        vm.startPrank(bundler, bundler);
        IEntryPoint(config.entryPoint).handleOps(packedUserOp, payable(user));
        vm.stopPrank();

        assertEq(sessionHandler.getRemainingBudget(user), BUDGET - valueInUsd);
    }

    /**
     * @notice Session key can execute addLiquidityETH through SessionHandler.
     * @dev Adds 2,500 USDC + proportional raw ETH via addLiquidityETH. The ETH amount is derived
     *      from live reserves via router.quote() and forwarded as the UserOp's value field.
     *      Budget is charged against the combined USD value of the USDC and the ETH forwarded,
     *      as extracted by SessionHandlerModule (ETH leg from the UserOp value field, token
     *      leg from calldata).
     */
    function testAddLiquidityETHWithSession() public routerSessionAdded {
        uint256 valueInUsd;
        address token = config.usdc;
        uint256 amountEthDesired;
        uint256 amountTokenDesired = 2500e6;
        uint256 amountTokenMin = 1;
        uint256 amountEthMin = 1;

        address to = address(sessionHandler);
        uint256 deadline = block.timestamp + 1.2 hours;
        address dest = config.router;

        address pair = FACTORY.getPair(token, config.weth);
        // Get reserves in token0/token1 order and map to token/WETH order.
        (uint112 r0, uint112 r1,) = IUniswapV2Pair(pair).getReserves();
        address token0 = IUniswapV2Pair(pair).token0();
        (uint256 reserveA, uint256 reserveB) = token0 == token ? (uint256(r0), uint256(r1)) : (uint256(r1), uint256(r0));
        amountEthDesired = router.quote(amountTokenDesired, reserveA, reserveB);

        valueInUsd += oracle.getUsdValue(token, amountTokenDesired);
        valueInUsd += oracle.getUsdValue(config.weth, amountEthDesired);

        PackedUserOperation[] memory packedUserOp = new PackedUserOperation[](1);

        bytes memory data = abi.encodeWithSelector(
            IUniswapV2Router01.addLiquidityETH.selector,
            token,
            amountTokenDesired,
            amountTokenMin,
            amountEthMin,
            to,
            deadline
        );
        (PackedUserOperation memory userOp,,) = sendPackedUserOp.generateSignedUserOp(
            address(sessionHandler),
            config,
            address(spendingLimitModule),
            dest,
            amountEthDesired,
            data,
            user,
            privateKey
        );
        packedUserOp[0] = userOp;

        vm.warp(block.timestamp + 1.1 hours);
        _refreshForkFeeds();
        vm.startPrank(bundler, bundler);
        IEntryPoint(config.entryPoint).handleOps(packedUserOp, payable(user));
        vm.stopPrank();

        assertEq(sessionHandler.getRemainingBudget(user), BUDGET - valueInUsd);
    }

    /**
     * @notice Session key can execute removeLiquidity through SessionHandler.
     * @dev The liquidityAdded(sessionHandler) modifier seeds the pool with 1,000 USDC + WETH on
     *      behalf of sessionHandler. Expected return amounts are calculated from live reserves
     *      using the proportional share formula: amount = liquidity * reserve / totalSupply.
     *      removeLiquidity credits back the session budget rather than charging it — spentAmount
     *      is decremented by the USD value of the minimum amounts (amountAMin, amountBMin).
     *      The final budget assertion expects BUDGET (i.e. spentAmount returns to 0) because
     *      this session has no prior spend and the credit floors at 0.
     */
    function testRemoveLiquidityWithSession() public routerSessionAdded liquidityAdded(address(sessionHandler)) {
        address tokenA = config.usdc;
        address tokenB = config.weth;
        address pair = FACTORY.getPair(tokenA, tokenB);
        uint256 liquidity = IERC20(pair).balanceOf(address(sessionHandler));
        console2.log("LIQUIDITY TO REMOVE: ", liquidity);
        address to = address(sessionHandler);
        uint256 deadline = block.timestamp + 1.2 hours;
        address dest = config.router;

        (uint112 r0, uint112 r1,) = IUniswapV2Pair(pair).getReserves();
        uint256 totalSupply = IERC20(pair).totalSupply();

        uint256 expectedAmount0 = (liquidity * uint256(r0)) / totalSupply;
        uint256 expectedAmount1 = (liquidity * uint256(r1)) / totalSupply;

        address token0 = IUniswapV2Pair(pair).token0();
        (uint256 expectedA, uint256 expectedB) =
            token0 == tokenA ? (expectedAmount0, expectedAmount1) : (expectedAmount1, expectedAmount0);

        uint256 balanceBeforeA = IERC20(tokenA).balanceOf(to);
        uint256 balanceBeforeB = IERC20(tokenB).balanceOf(to);

        PackedUserOperation[] memory packedUserOp = new PackedUserOperation[](1);

        bytes memory data = abi.encodeWithSelector(
            IUniswapV2Router01.removeLiquidity.selector, tokenA, tokenB, liquidity, expectedA, expectedB, to, deadline
        );
        (PackedUserOperation memory userOp,,) = sendPackedUserOp.generateSignedUserOp(
            address(sessionHandler), config, address(spendingLimitModule), dest, 0, data, user, privateKey
        );
        packedUserOp[0] = userOp;

        vm.warp(block.timestamp + 1.1 hours);
        _refreshForkFeeds();
        vm.startPrank(bundler, bundler);
        IEntryPoint(config.entryPoint).handleOps(packedUserOp, payable(user));
        vm.stopPrank();

        uint256 balanceAfterA = IERC20(tokenA).balanceOf(to);
        uint256 balanceAfterB = IERC20(tokenB).balanceOf(to);
        console2.log("USDC :  ", balanceAfterA);
        console2.log("WETH:   ", balanceAfterB);

        assertEq(IERC20(pair).balanceOf(to), 0);
        assertEq(balanceAfterA, balanceBeforeA + expectedA);
        assertEq(balanceAfterB, balanceBeforeB + expectedB);
        assertEq(sessionHandler.getRemainingBudget(user), BUDGET);
    }

    /**
     * @notice Session key can execute removeLiquidityETH through SessionHandler.
     * @dev The liquidityAdded(sessionHandler) modifier seeds the pool with 1,000 USDC + WETH on
     *      behalf of sessionHandler. removeLiquidityETH burns the LP tokens, returns the USDC
     *      share as an ERC20 transfer, and unwraps the WETH share to raw ETH sent to `to`.
     *      The ETH balance assertion is omitted because the EntryPoint deducts the full prefund
     *      from sessionHandler's raw ETH balance upfront; any unused gas is refunded to the
     *      EntryPoint deposit ledger (not to the ETH balance), making a clean delta assertion
     *      impractical without mocking the EntryPoint gas accounting.
     */
    function testRemoveLiquidityETHWithSession()
        public
        routerSessionAdded
        liquidityAdded(address(sessionHandler))
    {
        address token = config.usdc;
        address pair = FACTORY.getPair(token, config.weth);
        uint256 liquidity = IERC20(pair).balanceOf(address(sessionHandler));

        address to = address(sessionHandler);
        uint256 deadline = block.timestamp + 1.2 hours;

        address dest = config.router;

        (uint112 r0, uint112 r1,) = IUniswapV2Pair(pair).getReserves();
        uint256 totalSupply = IERC20(pair).totalSupply();

        uint256 expectedAmount0 = (liquidity * uint256(r0)) / totalSupply;
        uint256 expectedAmount1 = (liquidity * uint256(r1)) / totalSupply;

        address token0 = IUniswapV2Pair(pair).token0();
        (uint256 amountToken, uint256 amountEth) =
            token0 == token ? (expectedAmount0, expectedAmount1) : (expectedAmount1, expectedAmount0);

        bytes memory data = abi.encodeWithSelector(
            IUniswapV2Router01.removeLiquidityETH.selector, token, liquidity, amountToken, amountEth, to, deadline
        );
        PackedUserOperation[] memory packedUserOp = new PackedUserOperation[](1);
        (PackedUserOperation memory userOp,,) = sendPackedUserOp.generateSignedUserOp(
            address(sessionHandler), config, address(spendingLimitModule), dest, 0, data, user, privateKey
        );
        packedUserOp[0] = userOp;
        uint256 balanceBeforeToken = IERC20(token).balanceOf(to);
        vm.warp(block.timestamp + 1.1 hours);
        _refreshForkFeeds();
        vm.startPrank(bundler, bundler);
        IEntryPoint(config.entryPoint).handleOps(packedUserOp, payable(user));
        vm.stopPrank();
        uint256 balanceAfterToken = IERC20(token).balanceOf(to);

        console2.log("USDC :  ", amountToken);
        console2.log("ETH:   ", amountEth);

        assertEq(IERC20(pair).balanceOf(address(sessionHandler)), 0);
        assertEq(balanceAfterToken - balanceBeforeToken, amountToken);
    }
}
