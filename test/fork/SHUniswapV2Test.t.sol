// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {SHForkTestBase} from "./SHForkTestBase.sol";

/**
 * @title SHUniswapV2Test
 * @notice Mainnet-fork run of the shared spending-cap fork suite against the real Uniswap V2
 *         router, real Chainlink feeds, and the canonical EntryPoint.
 * @dev MAINNET FORK REQUIRED. Run with:
 *        make mainnet-uniswap-test
 *        (forge test --match-path test/fork/SHUniswapV2Test.t.sol --fork-url $MAINNET_RPC_URL)
 *
 *      Swap path: WETH -> DAI (deep pool, both priced by the deployed SHOracle).
 */
contract SHUniswapV2Test is SHForkTestBase {
    function _swapPath() internal view override returns (address[] memory path) {
        path = new address[](2);
        path[0] = config.weth;
        path[1] = config.dai;
    }

    function _swapAmount() internal pure override returns (uint256) {
        return 1e18; // 1 WETH
    }

    function _feedsToFreshen() internal view override returns (address[] memory feeds) {
        feeds = new address[](2);
        feeds[0] = config.ethUsdPriceFeed;
        feeds[1] = config.daiUsdPriceFeed;
    }
}
