//SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;
import {SessionHandlerModule} from "../../src/SessionHandlerModule.sol";

/**
 * @title SessionHandlerModuleHarness
 * @notice Test harness that exposes SessionHandlerModule internal functions for unit testing.
 * @dev Inherits SessionHandlerModule and re-exports internal functions as external so they can
 *      be called directly in tests without modifying the production contract.
 */
contract SessionHandlerModuleHarness is SessionHandlerModule {
    constructor(address registry) SessionHandlerModule(registry) {}

    /**
     * @notice Exposes _packValidationData for round-trip testing.
     * @dev Delegates directly to the internal function with no additional logic,
     *      so any discrepancy between this and the production path is a test bug, not a contract bug.
     */
    function packValidationData(bool sigFailed, uint48 validFrom, uint48 validUntil) external pure returns (uint256) {
        return _packValidationData(sigFailed, validFrom, validUntil);
    }
}
