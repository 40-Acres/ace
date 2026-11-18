// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.36;

/// @title MockReceiptClone
/// @notice The one read `SAeroStakeReceiptFactory.make` takes off a stake receipt: the prior receipt's `outstanding()`.
/// @dev DISPATCHED: the prior receipt is a runtime address no `link` reaches. The answer is free, so `make` meets spent and live receipts.
contract MockReceiptClone {
    uint256 internal units; // what outstanding answers

    /// @notice The units minted and not yet burned.
    /// @return The stored units.
    function outstanding() external view returns (uint256) {
        return units;
    }

    /// @notice The units a spec compares `make` against.
    /// @return The stored units.
    function outstandingView() external view returns (uint256) {
        return units;
    }
}
