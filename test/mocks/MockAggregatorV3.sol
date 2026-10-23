// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.36;

import {IAggregatorV3} from "../../src/interfaces/IAggregatorV3.sol";

/// @notice Settable Chainlink-shape feed: per-round history, staleness by clock, revert mode.
contract MockAggregatorV3 is IAggregatorV3 {
    struct Round {
        int256 answer;
        uint256 updatedAt;
        uint80 answeredInRound;
    }

    uint8 public immutable DECIMALS;
    uint80 public latestRound;
    bool public reverting;
    mapping(uint80 => Round) public rounds;

    constructor(uint8 dec) {
        DECIMALS = dec;
    }

    function decimals() external view returns (uint8) {
        return DECIMALS;
    }

    function setReverting(bool v) external {
        reverting = v;
    }

    /// @notice Push a new round at the current timestamp; answeredInRound follows unless overridden.
    function push(int256 answer) external {
        latestRound += 1;
        rounds[latestRound] = Round(answer, block.timestamp, latestRound);
    }

    /// @notice Overwrite one round wholesale, for incomplete-round and gap shapes.
    function setRound(uint80 rid, int256 answer, uint256 updatedAt, uint80 answeredInRound) external {
        if (rid > latestRound) latestRound = rid;
        rounds[rid] = Round(answer, updatedAt, answeredInRound);
    }

    function latestRoundData() external view returns (uint80, int256, uint256, uint256, uint80) {
        if (reverting) revert("feed down");
        Round memory r = rounds[latestRound];
        return (latestRound, r.answer, r.updatedAt, r.updatedAt, r.answeredInRound);
    }

    function getRoundData(uint80 rid) external view returns (uint80, int256, uint256, uint256, uint80) {
        if (reverting) revert("feed down");
        Round memory r = rounds[rid];
        if (r.updatedAt == 0) revert("no round");
        return (rid, r.answer, r.updatedAt, r.updatedAt, r.answeredInRound);
    }
}
