// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.36;

import {IApi3ReaderProxy} from "../../src/interfaces/IApi3ReaderProxy.sol";

/// @notice Settable dAPI stand-in: value + timestamp, plus a revert mode.
contract MockApi3ReaderProxy is IApi3ReaderProxy {
    int224 public value;
    uint32 public timestamp;
    bool public reverting;

    function set(int224 v) external {
        value = v;
        timestamp = uint32(block.timestamp);
    }

    function setStamped(int224 v, uint32 ts) external {
        (value, timestamp) = (v, ts);
    }

    function setReverting(bool v) external {
        reverting = v;
    }

    function read() external view returns (int224, uint32) {
        if (reverting) revert("dapi down");
        return (value, timestamp);
    }

    /// @notice The Chainlink-shape surface a real API3 reader proxy also answers, at its 18 decimals.
    function decimals() external pure returns (uint8) {
        return 18;
    }

    /// @notice As a real API3 reader proxy answers it: both round ids zero, both stamps the dAPI's timestamp.
    function latestRoundData() external view returns (uint80, int256, uint256, uint256, uint80) {
        if (reverting) revert("dapi down");
        return (0, value, timestamp, timestamp, 0);
    }
}
