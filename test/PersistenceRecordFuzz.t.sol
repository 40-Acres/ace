// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.36;

import {Test} from "forge-std/Test.sol";
import {WarpClock} from "./utils/WarpClock.sol";
import {PersistenceRecord} from "./utils/PersistenceRecord.sol";

/// @notice Property tests for the observation record, over any price/volume sequence.
/// @dev The per-bucket truncation bound holds and volume weighting stays monotonic.
/// @dev The windowed min is a true low watermark, and a lower depth observation never raises the windowed depth min.
contract PersistenceRecordFuzzTest is WarpClock {
    uint256 constant TRUNC = 500; // 5% full-volume cap
    uint256 constant START = 1e18;
    uint64 constant IVL = 60;
    uint256 constant VREF = 1000e18;
    uint256 constant CAP = 16;
    // record-only suite: no market, so the declared frame is two distinct placeholders
    address constant FQ = address(0x9001);
    address constant FC = address(0xC011);

    function _fresh() internal returns (PersistenceRecord) {
        // depth window 120, inside the 900s ring: the record's own rail keeps it under the blackout
        return new PersistenceRecord(
            PersistenceRecord.Config({
                writer: address(this),
                truncCapBps: TRUNC,
                initialPrice: START,
                obsInterval: IVL,
                volRefFloor: VREF,
                obsCap: CAP,
                unitScale: 1e30,
                volRefBps: 5000,
                depthWindow: 120,
                quote: FQ,
                collateral: FC,
                persistenceWindow: 120,
                pendingWindow: 60
            })
        );
    }

    // (a) within a single bucket, the record never leaves [base - fullCap, base + fullCap]
    function testFuzz_PerBucketMoveBounded(uint256 p1, uint256 v1, uint256 p2, uint256 v2) public {
        _warpTo(1_000_000);
        PersistenceRecord r = _fresh();
        p1 = bound(p1, 0, 100e18);
        p2 = bound(p2, 0, 100e18);
        v1 = bound(v1, 0, VREF * 5);
        v2 = bound(v2, 0, VREF * 5);
        r.observe(p1, v1); // same bucket (no warp between)
        r.observe(p2, v2);
        uint256 fullDelta = (START * TRUNC) / 10000;
        uint256 last = r.lastObserved();
        uint256 dist = last > START ? last - START : START - last;
        assertLe(dist, fullDelta, "a single bucket never moves beyond the full cap");
    }

    // (b) for the same target, a larger bucket volume never moves the record less than a smaller one
    function testFuzz_VolumeWeightingMonotonic(uint256 target, uint256 volA, uint256 volB) public {
        _warpTo(1_000_000);
        target = bound(target, 0, 100e18);
        volA = bound(volA, 0, VREF * 3);
        volB = bound(volB, 0, VREF * 3);
        if (volA > volB) (volA, volB) = (volB, volA); // volA <= volB
        PersistenceRecord rA = _fresh();
        PersistenceRecord rB = _fresh();
        rA.observe(target, volA);
        rB.observe(target, volB);
        uint256 la = rA.lastObserved();
        uint256 lb = rB.lastObserved();
        uint256 distA = la > START ? la - START : START - la;
        uint256 distB = lb > START ? lb - START : START - lb;
        assertLe(distA, distB, "smaller volume never moves the record more than larger volume");
    }

    // (c) a nonzero windowed min equals the lowest standing bucket price in the window
    function testFuzz_MinPriceIsLowWatermark(uint256 s0, uint256 s1, uint256 s2, uint256 s3) public {
        _warpTo(1_000_000);
        PersistenceRecord r = _fresh();
        uint256 t0 = _now();
        uint256[4] memory seeds = [s0, s1, s2, s3];
        uint256 runningMin = START; // the anchor sits in the window
        for (uint256 i; i < 4; i++) {
            _warpTo(t0 + (i + 1) * IVL);
            uint256 p = bound(seeds[i], 0.01e18, 100e18);
            r.observe(p, VREF); // full weight, one bucket per step
            uint256 lastNow = r.lastObserved();
            if (lastNow < runningMin) runningMin = lastNow;
        }
        uint256 win = 4 * IVL; // spans back to the anchor at t0
        uint256 got = r.minPriceOverWindow(FQ, FC, win);
        assertGt(got, 0, "the window spans, so the read is proven");
        assertEq(got, runningMin, "the windowed min is the lowest standing bucket over the window");
    }

    // (d) observing a lower depth in-window never raises the windowed depth min
    function testFuzz_MinDepthNeverIncreasesOnLowerObs(uint256 d0, uint256 d1) public {
        _warpTo(1_000_000);
        PersistenceRecord r = _fresh();
        uint256 t0 = _now();
        d0 = bound(d0, 0, 1e24);
        r.observeDepth(d0);
        _warpTo(t0 + 30 minutes); // the baseline now spans the window
        uint256 m0 = r.minDepthOverWindow(30 minutes);
        assertEq(m0, d0, "the standing depth spans the window");
        d1 = bound(d1, 0, d0); // a lower (or equal) depth
        r.observeDepth(d1); // a new in-window bucket
        uint256 m1 = r.minDepthOverWindow(30 minutes);
        assertLe(m1, m0, "a lower in-window depth never raises the min");
    }
}
