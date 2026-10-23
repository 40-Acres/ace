// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.36;

import {Test} from "forge-std/Test.sol";
import {PersistenceRecord} from "./PersistenceRecord.sol";

/// @title WarpClock
/// @notice The test clock. Inherit this instead of `Test` and never read `block.timestamp` in a test.
/// @dev `block.timestamp` is invariant inside a transaction, so the via-IR Yul optimizer reads TIMESTAMP
/// @dev once and moves that read freely. `vm.warp` breaks the premise: it mutates block context mid-call,
/// @dev which no on-chain execution can do. A timeline derived from `block.timestamp` therefore compounds
/// @dev wrongly under via_ir, and the test silently exercises a different timeline than it reads like.
/// @dev The clock lives in STORAGE because an SLOAD cannot be hoisted across an external call -- the
/// @dev optimizer must assume `vm.warp` may reenter and write -- so the timeline survives both pipelines.
abstract contract WarpClock is Test {
    uint256 internal _clock; // absolute test time; the ONLY timeline source a test may read

    constructor() {
        _clock = block.timestamp; // the anchor, taken at construction, before any warp exists
    }

    /// @notice Re-anchor the clock to the current block. The ONE caller is a fork selected in `setUp`.
    /// @dev The constructor runs BEFORE `setUp`, so its read predates `vm.createSelectFork` and a fork
    /// @dev test would carry a clock sitting at the local default while the chain sits at the fork block.
    /// @dev A deadline signed against `_now()` is then already long expired to the contracts being forked.
    function _anchorClock() internal {
        _clock = block.timestamp;
    }

    /// @notice Warp to an absolute time and keep the clock with it.
    function _warpTo(uint256 t) internal {
        _clock = t;
        vm.warp(t);
    }

    /// @notice Advance the clock by `d` seconds. The relative-warp replacement.
    /// @dev RE-ANCHORS FIRST, because an INVARIANT run moves `block.timestamp` between calls and this clock
    /// @dev does not see it. Left lagging, `_clock + d` can land BEHIND the chain and the warp runs time
    /// @dev BACKWARDS -- a matured notice stops being matured, and it reads exactly like a contract bug.
    /// @dev Measured on the curator campaign: `maturesAt` 1,699,160 against `block.timestamp` 1,697,961
    /// @dev after a FORWARD warp, which showed up as `maxWithdraw` falling to zero across a verb-free step.
    /// @dev A no-op under unit tests, where nothing but this clock ever moves the chain.
    function _warpBy(uint256 d) internal {
        if (block.timestamp > _clock) _clock = block.timestamp;
        _clock += d;
        vm.warp(_clock);
    }

    /// @notice Warp forward to `t`, or stand still when the clock is already past it.
    /// @dev Never backwards: a rewind breaks every checkpoint the hub keeps, so a late clock stays late.
    /// @dev RE-ANCHORS FIRST, for the reason `_warpBy` does: an INVARIANT run moves `block.timestamp`
    /// @dev between calls, so a lagging clock would let this warp the CHAIN backwards to reach a `t` the
    /// @dev chain had already passed. Comparing against the later of the two is what keeps it monotone.
    function _warpAtLeastTo(uint256 t) internal {
        if (block.timestamp > _clock) _clock = block.timestamp;
        if (t > _clock) _warpTo(t);
    }

    /// @notice Current test time. Use instead of `block.timestamp` everywhere in a test.
    function _now() internal view returns (uint256) {
        return _clock;
    }

    /// @notice Move the clock one second past `window`. CLOCK ONLY -- it does not make any record span.
    /// @dev Was `WarmRecord.spanWindow`, which warped off `block.timestamp` and desynced this clock.
    /// @dev A warp alone no longer spans a record: use `_spanWindowOn` against a real one, or draws refuse.
    function _spanWindow(uint256 window) internal {
        _warpBy(window + 1);
    }

    /// @notice Age a record past `window` AND print, so it genuinely spans and is fresh at the head.
    /// @dev TWO facts are needed: an observation at or before the boundary, and one strictly inside it.
    /// @dev Zero volume never moves the price -- this rolls a bucket and stamps the head, nothing more.
    /// @dev Requires `window + 1 >= OBS_INTERVAL` so the write actually rolls; every caller clears it.
    /// @param rec The record to age; the caller must be its WRITER, which every fixture here is.
    /// @param window The window the record must span, in seconds.
    function _spanWindowOn(PersistenceRecord rec, uint256 window) internal {
        _warpBy(window + 1);
        rec.observe(0, 0);
    }
}
