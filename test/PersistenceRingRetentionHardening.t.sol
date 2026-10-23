// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.36;

import {Test} from "forge-std/Test.sol";
import {WarpClock} from "./utils/WarpClock.sol";
import {PersistenceRecord} from "./utils/PersistenceRecord.sol";

/// @notice Ring-retention hardening for minDepthOverWindow, the read the G1 capacity amplifier depends on.
/// @notice The shape here is an 86400s window against OBS_CAP 2048 / OBS_INTERVAL 60, so ~34h of retention.
/// @dev Adversarial cases past the plain window-fits-retention check, on a ring WRAPPED beyond 2048 depth buckets.
/// @dev It must return the true min over a window inside retention, respecting the boundary across the wrap.
/// @dev It must also fail SAFE to 0 for a window older than retention, which it cannot prove.
/// @dev A wrong wrap-index or a missing fail-safe would over-report depth and lift the amplifier past what the pool held.
contract PersistenceRingRetentionHardeningTest is WarpClock {
    // this suite's shape, NOT production-pinned: retired MarketFactory chose 60/2048, now ctor args
    uint64 constant INTERVAL = 60;
    uint256 constant CAP = 2048;
    uint256 constant WINDOW = 86_400; // the record's own depth window (1 day)
    uint256 constant RETENTION = CAP * INTERVAL; // 122_880s (~34h): full-ring time span

    PersistenceRecord internal rec;
    uint256 internal t0;

    function setUp() public {
        t0 = 1_000_000; // large base so _now() - window never underflows
        _warpTo(t0);
        // writer == this test so observeDepth is callable directly; record-only, so the frame is two placeholders
        rec = new PersistenceRecord(
            PersistenceRecord.Config({
                writer: address(this),
                truncCapBps: 500,
                initialPrice: 1e18,
                obsInterval: INTERVAL,
                volRefFloor: 1,
                obsCap: CAP,
                unitScale: 1e18,
                volRefBps: 5000,
                depthWindow: WINDOW,
                quote: address(0x9001),
                collateral: address(0xC011),
                persistenceWindow: WINDOW,
                pendingWindow: 3600
            })
        );
    }

    /// @dev Fills n distinct INTERVAL depth buckets, one observeDepth each: `low` at `lowIter`, `high` everywhere else.
    /// @return last The final block.timestamp.
    function _fillRing(uint256 n, uint256 high, uint256 low, uint256 lowIter) internal returns (uint256 last) {
        for (uint256 i; i < n; i++) {
            _warpTo(t0 + i * INTERVAL);
            rec.observeDepth(i == lowIter ? low : high);
        }
        last = t0 + (n - 1) * INTERVAL;
    }

    /// @notice A WRAPPED ring of 2100 buckets still returns the correct in-window min.
    /// @dev A lower value planted outside the window but inside the 34h retention is EXCLUDED: the boundary survives the wrap.
    function test_WrappedRing_InWindowMinCorrect_OutOfWindowExcluded() public {
        uint256 n = 2100;
        // in-window low: 1000 buckets before the end => age 60_000s < 86_400 (inside the window)
        uint256 inWindowIter = n - 1 - 1000;
        // out-of-window low: 1800 buckets before the end => age 108_000s (> window, < retention)
        uint256 outWindowIter = n - 1 - 1800;

        // fill everything high, then overwrite the two planted buckets on their own iterations
        for (uint256 i; i < n; i++) {
            _warpTo(t0 + i * INTERVAL);
            uint256 v = 10_000e6;
            if (i == inWindowIter) v = 500e6; // the true in-window min
            if (i == outWindowIter) v = 100e6; // lower, but older than the window: must be ignored
            rec.observeDepth(v);
        }

        // the ring has wrapped: more buckets written than capacity
        assertGt(n, CAP, "precondition: ring wrapped");
        // window fits retention, so the read returns the in-window min, not the older-but-lower one
        assertEq(rec.minDepthOverWindow(WINDOW), 500e6, "wrapped ring: in-window min, boundary respected");
        assertLt(RETENTION, 200_000, "sanity: 200k window exceeds ring retention");
    }

    /// @notice Same wrapped ring: a window LARGER than the ~34h retention cannot be proven, so the read fails safe to 0.
    /// @dev The record never extrapolates depth it did not observe.
    function test_WrappedRing_WindowBeyondRetention_ReadsZeroFailSafe() public {
        _fillRing(2100, 10_000e6, 5_000e6, 1050); // a full, wrapped ring of real depth
        // 200_000s > 122_880s retention: every retained bucket is newer than the boundary, so nothing proves it
        assertEq(rec.minDepthOverWindow(200_000), 0, "window beyond retention proves nothing: 0");
        // control: a window WITHIN retention on the same ring does span and returns the real min
        assertEq(rec.minDepthOverWindow(WINDOW), 5_000e6, "in-retention window still reads the true min");
    }

    /// @notice The bucket exactly at `blockTs - window` carries into the read, since silence persists; a strictly older one does not.
    /// @dev Pins that the wrap-aware walk stops AT the boundary bucket rather than one either side of it.
    function test_WrappedRing_BoundaryBucketCarriesIn_OlderDoesNot() public {
        uint256 n = 2100;
        // boundary bucket sits exactly WINDOW/INTERVAL = 1440 buckets before the end
        uint256 boundaryIter = n - 1 - 1440;
        uint256 justOlderIter = boundaryIter - 1; // one bucket older than the boundary

        for (uint256 i; i < n; i++) {
            _warpTo(t0 + i * INTERVAL);
            uint256 v = 10_000e6;
            if (i == boundaryIter) v = 300e6; // exactly at the window start: must be included
            if (i == justOlderIter) v = 50e6; // one step older: must be excluded
            rec.observeDepth(v);
        }
        // min over the window includes the boundary bucket (300e6) but not the older 50e6
        assertEq(rec.minDepthOverWindow(WINDOW), 300e6, "boundary bucket included, strictly-older excluded");
    }
}
