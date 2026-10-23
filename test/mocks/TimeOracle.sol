// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.36;

/// @title TimeOracle
/// @notice Reports the chain's own time from inside a CALL, so the reading cannot be hoisted.
/// @dev A test may not read `block.timestamp` -- that is the read the via-IR optimizer moves, and the
/// @dev read WarpClock exists to replace. Asserting the clock against it would beg the question.
/// @dev A CALL's return value is not something the optimizer may cache across a later CALL, so asking
/// @dev the chain through this contract is sound under both pipelines. Used by WarpClockTracks.
contract TimeOracle {
    function currentTime() external view returns (uint256) {
        return block.timestamp;
    }
}
