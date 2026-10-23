// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.36;

import {WarpClock} from "./utils/WarpClock.sol";
import {TimeOracle} from "./mocks/TimeOracle.sol";

/// @title WarpClockTracks
/// @notice The property every time-dependent test in this tree now rests on: `_now()` IS chain time.
/// @dev The test may not read `block.timestamp` itself -- that is the read the via-IR optimizer hoists,
/// @dev and asserting with it would be asserting with the very thing under suspicion. So the chain is
/// @dev asked through an external call instead: a CALL's return value is not something the optimizer
/// @dev may cache across a later CALL, so this comparison is sound under both pipelines.
/// @dev Guards the whole WarpClock sweep. If this goes red, every timeline in the suite is suspect.
contract WarpClockTracksTest is WarpClock {
    TimeOracle internal oracle;

    function setUp() public {
        oracle = new TimeOracle();
        _warpTo(10 days);
    }

    /// @notice A chain of relative advances: the shape that silently compounded wrong under via-IR.
    function test_Clock_ChainedAdvancesTrackTheChain() public {
        uint256 base = _now();
        assertEq(oracle.currentTime(), base, "the clock starts on the chain");

        _warpBy(10 minutes);
        assertEq(_now(), base + 10 minutes, "clock advanced");
        assertEq(oracle.currentTime(), base + 10 minutes, "and the chain came with it");

        _warpBy(10 minutes);
        assertEq(_now(), base + 20 minutes, "clock advanced again");
        assertEq(oracle.currentTime(), base + 20 minutes, "still together, where the old pattern drifted");

        _warpBy(15 minutes);
        assertEq(_now(), base + 35 minutes, "and again");
        assertEq(oracle.currentTime(), base + 35 minutes, "no compounding error over the chain");
    }

    /// @notice Absolute warps keep the clock too, which is what a stale base would break.
    function test_Clock_AbsoluteWarpsKeepTheClock() public {
        _warpTo(20 days);
        assertEq(_now(), 20 days, "clock took the absolute time");
        assertEq(oracle.currentTime(), 20 days, "so did the chain");

        _warpBy(1 days);
        assertEq(oracle.currentTime(), 20 days + 1 days, "a relative advance off an absolute base");
    }

    /// @notice `_spanWindow` is the retired WarmRecord, and it must move the clock like everything else.
    function test_Clock_SpanWindowMovesTheClock() public {
        uint256 base = _now();
        _spanWindow(30 minutes);
        assertEq(_now(), base + 30 minutes + 1, "one second past the window, on the clock");
        assertEq(oracle.currentTime(), base + 30 minutes + 1, "and on the chain");
    }
}
