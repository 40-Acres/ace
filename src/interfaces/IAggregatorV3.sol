// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.36;

/// @title IAggregatorV3
/// @notice The minimal Chainlink-shape feed surface the price records consume: the latest round, and a past one by id.
interface IAggregatorV3 {
    function decimals() external view returns (uint8);

    function latestRoundData() external view returns (uint80 roundId, int256 answer, uint256 startedAt, uint256 updatedAt, uint80 answeredInRound);

    function getRoundData(uint80 roundId) external view returns (uint80, int256 answer, uint256 startedAt, uint256 updatedAt, uint80 answeredInRound);
}
