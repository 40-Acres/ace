// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.36;

/// @title MockApi3Proxy
/// @notice An API3 reader proxy whose value and timestamp are storage the prover sets, or a revert.
/// @notice Both fields are free, so a non-positive, future-stamped or stale value is reachable.
/// @dev It answers in full or reverts; a return too short to decode is the one proxy behaviour it cannot produce.
contract MockApi3Proxy {
    int224 internal value; // the signed dAPI value, 18-decimal by convention
    uint32 internal timestamp; // when the value was signed
    bool internal reverts; // the read reverts instead of answering

    /// @notice The dAPI read, or a revert while `reverts` is set.
    /// @return The stored value.
    /// @return The stored timestamp.
    function read() external view returns (int224, uint32) {
        require(!reverts, "dapi down");
        return (value, timestamp);
    }

    /// @notice The raw value a spec compares the record's reading against.
    /// @return The stored value.
    function valueView() external view returns (int224) {
        return value;
    }

    /// @notice When the value was signed.
    /// @return The stored timestamp.
    function timestampView() external view returns (uint32) {
        return timestamp;
    }

    /// @notice Whether the read reverts.
    /// @return The stored flag.
    function revertsView() external view returns (bool) {
        return reverts;
    }

    /// @notice Sets the value, for a rule that prices one state at two values.
    /// @param v The value to report.
    function setValue(int224 v) external {
        value = v;
    }
}
