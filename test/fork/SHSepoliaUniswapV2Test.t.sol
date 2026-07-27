// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {SHForkTestBase} from "./SHForkTestBase.sol";

/**
 * @title SHSepoliaUniswapV2Test
 * @notice Sepolia-fork run of the shared spending-cap fork suite against the official Sepolia
 *         Uniswap V2 router, live Sepolia Chainlink feeds, and the canonical EntryPoint.
 * @dev SEPOLIA FORK REQUIRED. Run with:
 *        make sepolia-uniswap-test
 *        (forge test --match-path test/fork/SHSepoliaUniswapV2Test.t.sol --fork-url $SEPOLIA_RPC_URL)
 *
 *      Swap path: WETH -> USDC (the deepest Sepolia V2 pool with both ends Chainlink-priced).
 *      NOTE: Sepolia pool ratios diverge wildly from real Chainlink prices (the pool has priced
 *      WETH ~11x above the feed). That is fine here: the base suite computes expected metering
 *      from actual balance diffs priced through the oracle, so a "profitable-looking" swap simply
 *      meters as net inflow => spend 0. Amounts stay small relative to pool depth.
 */
contract SHSepoliaUniswapV2Test is SHForkTestBase {
    function _swapPath() internal view override returns (address[] memory path) {
        path = new address[](2);
        path[0] = config.weth;
        path[1] = config.usdc;
    }

    function _swapAmount() internal pure override returns (uint256) {
        return 0.05e18; // 0.05 WETH — sized against real Sepolia pool depth
    }

    function _feedsToFreshen() internal view override returns (address[] memory feeds) {
        feeds = new address[](2);
        feeds[0] = config.ethUsdPriceFeed;
        feeds[1] = config.usdcUsdPriceFeed;
    }
}
