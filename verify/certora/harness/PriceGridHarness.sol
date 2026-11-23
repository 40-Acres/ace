// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.36;

import {PriceGrid} from "../../../src/vault/libraries/PriceGrid.sol";

/// @title PriceGridHarness
/// @notice The vault doors' price grid, `PriceGrid.down`, reached as the doors reach it: a call into the linked library.
/// @dev Adds no storage and no logic: one entry point per library function a spec reads.
contract PriceGridHarness {
    /// @notice The highest grid price at or under `p`, as the library answers it.
    /// @param p The price, Q96.
    /// @return The gridded price.
    function down(uint256 p) external pure returns (uint256) {
        return PriceGrid.down(p);
    }
}
