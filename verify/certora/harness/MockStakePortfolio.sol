// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.36;

/// @title MockStakePortfolio
/// @notice The one read `SAeroStakeReceiptFactory.make` takes off its caller, a 40 Acres portfolio: the stake's booked collateral.
/// @dev DISPATCHED: the caller is a runtime address no `link` reaches. The answer is free, so `make` meets booked and unbooked stakes.
contract MockStakePortfolio {
    mapping(uint256 => uint256) internal booked; // what getStakedCollateral answers

    /// @notice The collateral the portfolio books for `stakeId`.
    /// @param stakeId The stake.
    /// @return The stored booking.
    function getStakedCollateral(uint256 stakeId) external view returns (uint256) {
        return booked[stakeId];
    }

    /// @notice The booking a spec compares `make` against.
    /// @param stakeId The stake.
    /// @return The stored booking.
    function bookedView(uint256 stakeId) external view returns (uint256) {
        return booked[stakeId];
    }
}
