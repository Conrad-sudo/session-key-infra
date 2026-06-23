// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Script} from "forge-std/Script.sol";
import {SHOracle} from "../src/SHOracle.sol";

/**
 * @title PriceUpdate
 * @notice Test helper that pushes real, pre-fetched Pyth price updates onto a forked
 *         network's Pyth contract via SHOracle.updatePrices().
 * @dev PriceUpdate.json is generated off-chain by app/price_update.py, which fetches live
 *      Hermes update data for the tokens used by the fork tests — Foundry scripts can't make
 *      HTTP calls themselves, so the data has to be pre-fetched and read from a fixture file.
 *      Calling updatePrices() with this data writes a genuinely fresh price into the forked
 *      Pyth contract's storage for each feed ID, so SHOracle's staleness check passes without
 *      needing to mock getPriceUnsafe.
 */
contract PriceUpdate is Script {
    string constant PRICE_UPDATE_PATH = "./script/PriceUpdate.json";

    /**
     * @notice Reads the pre-fetched Pyth update payload(s) from PriceUpdate.json.
     */
    function getPriceUpdateData() public view returns (bytes[] memory) {
        string memory json = vm.readFile(PRICE_UPDATE_PATH);
        return vm.parseJsonBytesArray(json, ".updateData");
    }

    /**
     * @notice Funds `oracle` with enough ETH to cover Pyth's update fee, then calls
     *         updatePrices() with the data from PriceUpdate.json.
     * @dev For use from within a forge test/script VM (e.g. a fork test's setUp()) —
     *      vm.deal is a cheatcode and is a no-op against a real network.
     * @param oracle The SHOracle instance to refresh (must point at the same Pyth
     *               contract the update data was fetched for).
     */
    function updateOracle(address oracle) public {
        bytes[] memory updateData = getPriceUpdateData();
        vm.deal(oracle, oracle.balance + 1 ether);
        SHOracle(payable(oracle)).updatePrices(updateData);
    }

    /**
     * @notice Standalone CLI entrypoint for broadcasting a real update transaction.
     * @dev Unlike updateOracle(), this does not vm.deal the oracle — on a real network
     *      the oracle must already hold enough ETH to cover Pyth's fee itself.
     *      Usage: forge script script/PriceUpdate.s.sol --sig "run(address)" <oracle> \
     *             --rpc-url <network> --private-key <key> --broadcast
     */
    function run(address oracle) external {
        bytes[] memory updateData = getPriceUpdateData();
        vm.startBroadcast();
        SHOracle(payable(oracle)).updatePrices(updateData);
        vm.stopBroadcast();
    }
}
