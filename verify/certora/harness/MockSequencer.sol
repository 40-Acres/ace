// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.36;

/// @title MockSequencer
/// @notice The L2 uptime feed, a DISTINCT contract from the price feed so the two answer from separate storage.
/// @notice One mock serving both would couple the sequencer's status to the price round, which no chain does.
/// @dev `SequencerUptime.status` reads up as "the call answered, answer == 0 and startedAt != 0", so both are free.
/// @dev The revert switch reaches that library's own catch leg, which answers DOWN rather than propagating.
contract MockSequencer {
    int256 internal answer; // zero means up, anything else means down
    uint256 internal startedAt; // when the status began; zero also means down
    bool internal reverts; // the call reverts instead of answering, which the library catches as down

    /// @notice The latest round, in Chainlink's shape; only `answer` and `startedAt` are read.
    /// @return The round id, always zero here.
    /// @return The signed answer, zero when up.
    /// @return When the status began.
    /// @return When the round last printed, always zero here.
    /// @return The round the answer came from, always zero here.
    function latestRoundData() external view returns (uint80, int256, uint256, uint256, uint80) {
        if (reverts) revert();
        return (0, answer, startedAt, 0, 0);
    }

    /// @notice Whether this feed reports the sequencer up, as the library reads it.
    /// @return True when the call answers, the answer is zero and the start is non-zero.
    function saysUp() external view returns (bool) {
        return !reverts && answer == 0 && startedAt != 0;
    }

    /// @notice When the current status began, for a spec reasoning about the grace.
    /// @return The stored start time.
    function startedAtView() external view returns (uint256) {
        return startedAt;
    }

    /// @notice Moves when the status began, for the rule that prices one state at two grace windows.
    /// @param s The start time to report.
    /// @dev The asymmetry's live half is a statement about TWO windows, so it needs two states to compare.
    function setStartedAt(uint256 s) external {
        startedAt = s;
    }
}
