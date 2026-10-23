// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.36;

/// @title IApi3ReaderProxy
/// @notice The minimal API3 dAPI surface Api3OracleRecord consumes: an 18-decimal value + timestamp.
interface IApi3ReaderProxy {
    function read() external view returns (int224 value, uint32 timestamp);
}
