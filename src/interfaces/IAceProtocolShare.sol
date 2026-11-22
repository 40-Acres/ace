// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.36;

/// @title IAceProtocolShare
/// @notice The hub's origination share: the one value its treasury may set, at or under the 10% ceiling.
interface IAceProtocolShare {
    /// @notice Set the share every later fee is priced at; only the hub's treasury may call it.
    /// @param shareBps The new share, in bps of the lender fee.
    function setProtocolShareBps(uint256 shareBps) external;

    /// @notice The share every fee door now prices at, in bps of the lender fee.
    function protocolShareBps() external view returns (uint256);
}
