// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.36;

import {Test} from "forge-std/Test.sol";
import {WarpClock} from "./utils/WarpClock.sol";
import {PersistenceRecord} from "./utils/PersistenceRecord.sol";

/// @notice Production hardening of the observation record, across its storage, its weighting and its window reads.
/// @dev Fixed-ring storage with interval bucketing, so write spam can never evict a window.
/// @dev Volume-weighted truncation, so dust prints barely count, over the minPriceOverWindow read the draw cap comes from.
/// @dev Fail-safe span semantics on every window read: an unproven window reads 0/false, never a stale answer.
/// @dev Record-only suite, so no market exists; the genesis rail reading the declared frame is exercised in AceRecordOrientation.
contract PersistenceRecordHardeningTest is WarpClock {
    uint256 constant TRUNC = 500; // 5% full-volume cap
    uint256 constant START = 1e18;
    uint64 constant IVL = 60; // bucket width
    uint256 constant VREF = 1000e18; // full-weight volume
    address constant FQ = address(0x9001); // the declared frame: two distinct placeholders, no market behind them
    address constant FC = address(0xC011);
    /// @dev The record owns its windows now, and its own rails bind them to this ring: the 8-slot ring
    /// @dev reaches 420s, so the settle window must fit inside that and the depth window under the blackout.
    uint256 constant P_W = 120; // two bucket widths, the record's own floor
    uint64 constant PEND_W = 60;
    uint256 constant DEPTH_W = 60;

    PersistenceRecord internal rec;

    function setUp() public {
        _warpTo(1_000_000);
        rec = _rec(TRUNC, IVL, VREF, 8);
    }

    // ---- ctor guards ----

    function test_Ctor_BadParams_Revert() public {
        vm.expectRevert(PersistenceRecord.BadParams.selector);
        // interval 0 re-opens spam eviction
        _rec(TRUNC, 0, VREF, 8);
        vm.expectRevert(PersistenceRecord.BadParams.selector);
        _rec(TRUNC, 1 days + 1, VREF, 8); // typo cap
        vm.expectRevert(PersistenceRecord.BadParams.selector);
        _rec(TRUNC, IVL, 0, 8); // volRef 0 divides
        vm.expectRevert(PersistenceRecord.BadParams.selector);
        // 1-slot ring spans nothing
        _rec(TRUNC, IVL, VREF, 1);
    }

    /// @dev The suite's one record shape: only the knob under test varies, and every field is NAMED.
    function _rec(uint256 trunc, uint64 interval, uint256 volRef, uint256 cap) internal returns (PersistenceRecord) {
        return new PersistenceRecord(
            PersistenceRecord.Config({
                writer: address(this),
                truncCapBps: trunc,
                initialPrice: START,
                obsInterval: interval,
                volRefFloor: volRef,
                obsCap: cap,
                unitScale: 1e30,
                volRefBps: 5000,
                depthWindow: DEPTH_W,
                quote: FQ,
                collateral: FC,
                persistenceWindow: P_W,
                pendingWindow: PEND_W
            })
        );
    }

    // ---- fail-safe span (LR-1) ----

    function test_MinPrice_UnspannedWindow_ReadsZero() public view {
        // record is seconds old; a 30-minute window reaches past the deploy anchor: nothing proven
        assertEq(rec.minPriceOverWindow(FQ, FC, 30 minutes), 0, "unproven window reads zero, never a stale answer");
    }

    /// @notice The ctor anchor NEVER serves as a windowed minimum, however old it gets.
    /// @dev Ageing is not printing: what the record owes is a price the VENUE produced inside the window.
    function test_MinPrice_AgedAnchorAloneStillReadsZero() public {
        _warpBy(30 minutes);
        assertEq(rec.minPriceOverWindow(FQ, FC, 30 minutes), 0, "an aged anchor is still a price nobody printed");
    }

    function test_MinPrice_WrappedOutRing_ReadsZero() public {
        // 9 buckets through an 8-slot ring evicts the anchor, so a window past the oldest SURVIVOR proves nothing
        for (uint256 i; i < 9; i++) {
            _warpBy(IVL);
            rec.observe(START, VREF);
        }
        assertEq(rec.minPriceOverWindow(FQ, FC, 30 minutes), 0, "evicted history is never silently vouched for");
        // a window the surviving ring does span still reads fine
        assertEq(rec.minPriceOverWindow(FQ, FC, 5 * IVL), START, "spanned window reads normally");
    }

    function test_PersistedAbove_FailSafeOnWrap() public {
        for (uint256 i; i < 9; i++) {
            _warpBy(IVL);
            rec.observe(2e18, VREF); // walk up, full weight
        }
        // _last is well above 1.5e18 by now, but a wrapped-out window proves nothing
        assertGt(rec.lastObserved(), 1.5e18);
        assertFalse(rec.persistedAbove(FQ, FC, 1.01e18, 30 minutes), "unspanned window: false, not a guess");
    }

    // ---- interval bucketing (anti-spam) ----

    function test_SameIntervalWritesCoalesce_OneCappedStep() public {
        // 50 spam dumps in one interval: ONE 5% step from the bucket base, not 50 compounding steps
        for (uint256 i; i < 50; i++) {
            rec.observe(0.1e18, VREF);
        }
        assertEq(rec.lastObserved(), (START * (10000 - TRUNC)) / 10000, "write spam cannot walk the record");
    }

    function test_NewIntervalStepsAgain() public {
        rec.observe(0.1e18, VREF);
        assertEq(rec.lastObserved(), 0.95e18);
        _warpBy(IVL);
        rec.observe(0.1e18, VREF);
        assertEq(rec.lastObserved(), (0.95e18 * (10000 - TRUNC)) / 10000, "one capped step per interval");
    }

    function test_MinPrice_SeesInWindowBucketsAndBoundary() public {
        uint256 t0 = _now();
        rec.observe(0.9e18, VREF); // -> 0.95 (capped)
        _warpTo(t0 + IVL);
        rec.observe(0.9e18, VREF); // -> 0.9025
        _warpTo(t0 + 2 * IVL);
        rec.observe(2e18, VREF); // -> 0.947625 (capped up)
        _warpTo(t0 + IVL + 30 minutes); // window start lands on the 0.9025 bucket
        assertEq(rec.minPriceOverWindow(FQ, FC, 30 minutes), 0.9025e18, "low watermark over the window");
    }

    // ---- volume weighting ----

    function test_DustPrint_BarelyMovesTheRecord() public {
        rec.observe(0.1e18, VREF / 100); // 1% of full weight: cap scales to 0.05%
        uint256 fullDelta = (START * TRUNC) / 10000;
        uint256 expected = START - fullDelta / 100;
        assertEq(rec.lastObserved(), expected, "dust prints barely count");
    }

    function test_ZeroVolume_NeverMoves() public {
        rec.observe(0.1e18, 0);
        assertEq(rec.lastObserved(), START, "a volumeless print is not evidence");
    }

    function test_VolumeAccumulatesWithinBucket_ToFullCap() public {
        // two half-weight prints in one bucket reach the full cap together
        rec.observe(0.1e18, VREF / 2);
        uint256 half = START - (START * TRUNC) / 10000 / 2;
        assertEq(rec.lastObserved(), half, "half weight, half step");
        rec.observe(0.1e18, VREF / 2);
        assertEq(rec.lastObserved(), (START * (10000 - TRUNC)) / 10000, "bucket volume accumulates to full");
    }

    function test_FullVolume_ByteIdenticalToUnweighted() public {
        rec.observe(0.98e18, VREF); // within the cap and fully weighted: lands exactly
        assertEq(rec.lastObserved(), 0.98e18, "at or above volRef the old truncation semantics hold");
    }

    function test_BucketPriceIsVwap() public {
        // same bucket, equal volumes at 0.98 and 1.00 -> vwap 0.99, within the cap: lands exactly
        rec.observe(0.98e18, VREF);
        rec.observe(1.0e18, VREF);
        assertEq(rec.lastObserved(), 0.99e18, "bucket represents its volume-weighted price");
    }

    // ---- silence persists the HEAD, and refuses the WINDOW: the two channels diverge on purpose ----

    /// @notice Silence keeps the standing price readable, and stops it counting as a windowed minimum.
    /// @dev The pairing IS the point: `lastObserved` still persists, so the two channels genuinely diverge.
    function test_SilencePersists_TheHeadButNotTheWindow() public {
        rec.observe(0.95e18, VREF);
        _warpBy(10 days); // silence
        assertEq(rec.lastObserved(), 0.95e18, "silence persists the standing head");
        assertEq(rec.minPriceOverWindow(FQ, FC, 30 minutes), 0, "but it never carries into a windowed minimum");
    }

    /// @notice The boundary is STRICT: a head sitting exactly on it refuses.
    /// @dev `head.time == boundary` is where the walk returns on step one, so equality leaves the defect reachable.
    function test_BoundaryExactTimestampRefuses() public {
        uint256 t0 = _now();
        _warpTo(t0 + 30 minutes - 1);
        assertEq(rec.minPriceOverWindow(FQ, FC, 30 minutes), 0, "one second short proves nothing");
        _warpTo(t0 + 30 minutes);
        assertEq(rec.minPriceOverWindow(FQ, FC, 30 minutes), 0, "and the boundary itself proves nothing either");
    }

    // ---- depth ring keeps its semantics under bucketing ----

    function test_DepthBucket_KeepsTheMin() public {
        rec.observeDepth(1_000e6);
        rec.observeDepth(10_000e6); // JIT spike in the same bucket: never raises
        rec.observeDepth(400e6); // a pull in the same bucket: marks instantly
        _warpBy(30 minutes);
        assertEq(rec.minDepthOverWindow(30 minutes), 400e6, "bucket keeps its low watermark");
    }

    function test_DepthRing_WrapFailSafe() public {
        for (uint256 i; i < 9; i++) {
            _warpBy(IVL);
            rec.observeDepth(1_000e6);
        }
        assertEq(rec.minDepthOverWindow(30 minutes), 0, "wrapped-out depth window proves nothing");
        assertEq(rec.minDepthOverWindow(5 * IVL), 1_000e6, "spanned depth window reads normally");
    }

    // ---- strict-inequality edges (equal is never strictly below/above) ----

    function test_Persisted_LastEqualsX_BothFalse() public view {
        // at deploy _last == START; the head shortcut treats equal as neither below nor above
        assertFalse(rec.persistedBelow(FQ, FC, START, 30 minutes), "last equal to x is not strictly below");
        assertFalse(rec.persistedAbove(FQ, FC, START, 30 minutes), "last equal to x is not strictly above");
    }

    function test_PersistedBelow_WindowStartBucketEqualsX_ReturnsFalse() public {
        uint256 t0 = _now();
        rec.observe(0.9e18, VREF); // anchor capped to 0.95
        _warpTo(t0 + IVL);
        rec.observe(0.1e18, VREF); // head capped to 0.9025 (< 0.95)
        // window start lands exactly on the anchor bucket (price 0.95)
        assertFalse(rec.persistedBelow(FQ, FC, 0.95e18, IVL), "boundary bucket equal to x is not strictly below");
        assertTrue(rec.persistedBelow(FQ, FC, 0.951e18, IVL), "boundary bucket strictly below x holds");
    }

    function test_PersistedBelow_InWindowBucketEqualsX_ReturnsFalse() public {
        uint256 t0 = _now(); // anchor stays START = 1e18
        _warpTo(t0 + IVL);
        rec.observe(1.06e18, VREF); // base 1e18 capped up to 1.05
        _warpTo(t0 + 2 * IVL);
        rec.observe(1.06e18, VREF); // base 1.05 -> 1.06 exactly (within cap)
        _warpTo(t0 + 3 * IVL);
        rec.observe(1.0e18, VREF); // base 1.06 -> 1.007 (head, < 1.06)
        // window start on the anchor (1e18 < x); an in-window bucket sits at exactly x = 1.06
        assertFalse(rec.persistedBelow(FQ, FC, 1.06e18, 3 * IVL), "in-window bucket equal to x breaks below-ness");
        // same buckets, x just above the peak: every in-window bucket is strictly below
        assertTrue(rec.persistedBelow(FQ, FC, 1.061e18, 3 * IVL), "all in-window buckets strictly below x holds");
    }

    function test_PersistedAbove_WindowStartBucketEqualsX_ReturnsFalse() public {
        uint256 t0 = _now();
        rec.observe(0.9e18, VREF); // anchor capped to 0.95
        _warpTo(t0 + IVL);
        rec.observe(0.96e18, VREF); // base 0.95 -> 0.96 (head, > x)
        // window start lands exactly on the anchor bucket (price 0.95)
        assertFalse(rec.persistedAbove(FQ, FC, 0.95e18, IVL), "boundary bucket equal to x is not strictly above");
        assertTrue(rec.persistedAbove(FQ, FC, 0.949e18, IVL), "boundary bucket strictly above x holds");
    }

    function test_PersistedAbove_InWindowBucketEqualsX_ReturnsFalse() public {
        uint256 t0 = _now();
        rec.observe(0.9e18, VREF); // anchor capped to 0.95 (> x)
        _warpTo(t0 + IVL);
        rec.observe(0.94e18, VREF); // base 0.95 -> 0.94 (in-window)
        _warpTo(t0 + 2 * IVL);
        rec.observe(0.96e18, VREF); // base 0.94 -> 0.96 (head, > x)
        // window start on the anchor (0.95 > x); an in-window bucket sits at exactly x = 0.94
        assertFalse(rec.persistedAbove(FQ, FC, 0.94e18, 2 * IVL), "in-window bucket equal to x breaks above-ness");
        assertTrue(rec.persistedAbove(FQ, FC, 0.939e18, 2 * IVL), "all in-window buckets strictly above x holds");
    }

    // ---- window == 0: the PRICE channel refuses it; depth and persistence still read standing state ----

    /// @notice A zero window proves nothing about price, so the price channel refuses it outright.
    /// @dev At `window == 0` the boundary IS `block.timestamp`, so even a same-block print sits on it.
    /// @dev Unreachable from the hub: genesis requires a strictly positive persistence window.
    /// @dev The other two channels are deliberately untouched, which is what the rest of this test pins.
    function test_WindowZero_PriceRefuses_OtherChannelsReadStandingState() public {
        uint256 t0 = _now();
        rec.observe(0.9e18, VREF); // -> 0.95
        _warpTo(t0 + IVL);
        rec.observe(0.9e18, VREF); // -> 0.9025 (_last)
        rec.observeDepth(700e6);
        uint256 last = rec.lastObserved(); // 0.9025
        assertEq(rec.minPriceOverWindow(FQ, FC, 0), 0, "a zero window proves no price, even on a same-block print");
        assertEq(rec.minDepthOverWindow(0), 700e6, "the depth walk is unchanged and still reads standing depth");
        assertTrue(rec.persistedBelow(FQ, FC, last + 1, 0), "zero window: strictly below a higher x");
        assertFalse(rec.persistedBelow(FQ, FC, last, 0), "zero window: equal is not below");
        assertFalse(rec.persistedBelow(FQ, FC, last - 1, 0), "zero window: not below a lower x");
        assertTrue(rec.persistedAbove(FQ, FC, last - 1, 0), "zero window: strictly above a lower x");
        assertFalse(rec.persistedAbove(FQ, FC, last, 0), "zero window: equal is not above");
    }

    // ---- huge window (boundary clamps to 0): fail-safe even though an anchor exists ----

    function test_HugeWindow_FailSafeZeroFalse() public {
        uint256 t0 = _now();
        rec.observe(0.9e18, VREF); // -> 0.95, a real standing state exists
        rec.observeDepth(700e6);
        _warpTo(t0 + 1 hours); // age the record; the anchor is genuine
        uint256 huge = _now() + 1; // window start would predate genesis -> boundary clamps to 0
        assertEq(rec.minPriceOverWindow(FQ, FC, huge), 0, "window past genesis proves nothing");
        assertEq(rec.minDepthOverWindow(huge), 0, "window past genesis proves nothing");
        assertFalse(rec.persistedBelow(FQ, FC, 0.96e18, huge), "window past genesis is false");
        assertFalse(rec.persistedAbove(FQ, FC, 0.9e18, huge), "window past genesis is false");
    }

    // ---- truncation cap extremes ----

    function test_TruncCapZero_RecordFrozenAtInitialPrice() public {
        // ctor accepts a zero cap; the record can never move off its initial price
        PersistenceRecord frozen = _rec(0, IVL, VREF, 8);
        uint256 t0 = _now();
        frozen.observe(0.1e18, VREF); // wants -90%, cap is 0
        assertEq(frozen.lastObserved(), START, "zero cap admits no movement");
        _warpTo(t0 + IVL);
        frozen.observe(5e18, VREF); // wants +400%, still frozen
        assertEq(frozen.lastObserved(), START, "zero cap stays frozen across buckets");
        _warpTo(t0 + 30 minutes);
        assertEq(frozen.minPriceOverWindow(FQ, FC, 30 minutes), START, "frozen record spans at the initial price");
    }

    function test_LargeCap_MovesSanely() public {
        // a full 100% cap: the step is base +/- base, still bounded per bucket
        PersistenceRecord wide = _rec(10000, IVL, VREF, 8);
        uint256 t0 = _now();
        wide.observe(0.1e18, VREF); // 0.1 within [0, 2e18] -> lands exactly
        assertEq(wide.lastObserved(), 0.1e18, "a wide cap admits the full move within range");
        _warpTo(t0 + IVL);
        wide.observe(5e18, VREF); // base 0.1, cap 0.1 -> max 0.2; capped up
        assertEq(wide.lastObserved(), 0.2e18, "a wide cap still caps the step at base plus full delta");
    }

    // ---- bucket roll after long silence caps from the standing price ----

    function test_BucketRollAfterSilence_CapsFromStandingPrice() public {
        uint256 t0 = _now();
        rec.observe(0.9e18, VREF); // -> 0.95 standing
        _warpTo(t0 + 10 days); // long silence
        rec.observe(0.1e18, VREF); // fresh bucket seeded from 0.95, capped one 5% step
        assertEq(rec.lastObserved(), (0.95e18 * (10000 - TRUNC)) / 10000, "post-silence step caps from the standing price");
    }

    // ---- ring exactly full vs wrapped by exactly one ----

    function test_RingExactlyFull_ThenWrappedByOne() public {
        uint256 t0 = _now();
        // 7 rolls fill the 8-slot ring exactly (anchor + 7); the anchor still resides in slot 0
        for (uint256 i; i < 7; i++) {
            _warpTo(t0 + (i + 1) * IVL);
            rec.observe(START, VREF);
        }
        // window reaching the anchor (t0) still spans while the ring is exactly full
        assertEq(rec.minPriceOverWindow(FQ, FC, 7 * IVL), START, "exactly-full ring still spans to the anchor");
        // one more roll evicts the anchor (wrap by one)
        _warpTo(t0 + 8 * IVL);
        rec.observe(START, VREF);
        assertEq(rec.minPriceOverWindow(FQ, FC, 8 * IVL), 0, "wrapped-by-one: the anchor age no longer spans");
        assertEq(rec.minPriceOverWindow(FQ, FC, 7 * IVL), START, "the surviving oldest bucket still spans its own age");
    }

    /// @dev Roll `n` buckets of the same price and depth, one per interval.
    function _rollBuckets(uint256 n) internal {
        for (uint256 i; i < n; i++) {
            _warpBy(IVL);
            rec.observe(START, VREF);
            rec.observeDepth(700e6);
        }
    }

    /// @dev The four ring walks over a window no wrapped 8-slot ring can span, so each walks its whole bound.
    function _nonSpanningWalksCost() internal view returns (uint256 used) {
        uint256 g = gasleft();
        uint256 p = rec.minPriceOverWindow(FQ, FC, 1 days);
        uint256 d = rec.minDepthOverWindow(1 days);
        bool below = rec.persistedBelow(FQ, FC, 2e18, 1 days);
        bool above = rec.persistedAbove(FQ, FC, 0.5e18, 1 days);
        used = g - gasleft();
        require(p == 0 && d == 0 && !below && !above, "fixture: a walk spanned the window, so it did not walk the whole ring");
    }

    /// @notice A WALK THAT CANNOT SPAN COSTS THE RING, NEVER THE HISTORY: its gas does not grow with the buckets ever written.
    /// @dev Every walk is bounded by `OBS_CAP`, so a record wrapped eighteen times reads no dearer than one wrapped twice.
    /// @dev The slack is a few opcodes of noise; an unbounded walk adds 128 extra slot reads to each of the four.
    function test_ANonSpanningWalkCostsTheRingNotItsHistory() public {
        _rollBuckets(16);
        uint256 early = _nonSpanningWalksCost();
        _rollBuckets(128);
        uint256 late = _nonSpanningWalksCost();
        assertApproxEqAbs(late, early, 500, "a walk's cost is the ring's size, not the record's age");
    }

    // ---- depth edge cases ----

    function test_Depth_ZeroObservationReadsAsUnspanned() public {
        uint256 t0 = _now();
        rec.observeDepth(0); // a legitimate zero depth
        _warpTo(t0 + 30 minutes);
        // a spanned zero-depth read is indistinguishable from an unproven window: both read 0
        assertEq(rec.minDepthOverWindow(30 minutes), 0, "zero depth reads zero, same as an unspanned window");
    }

    function test_Depth_PerBucketMinAcrossRolls() public {
        uint256 t0 = _now();
        rec.observeDepth(900e6); // bucket 0
        rec.observeDepth(600e6); // same bucket: min 600
        _warpTo(t0 + IVL);
        rec.observeDepth(800e6); // bucket 1
        rec.observeDepth(500e6); // same bucket: min 500
        _warpTo(t0 + 2 * IVL);
        rec.observeDepth(700e6); // bucket 2 (head)
        // window start lands on the anchor bucket (t0); min is the lowest per-bucket watermark
        assertEq(rec.minDepthOverWindow(2 * IVL), 500e6, "window min is the lowest per-bucket watermark");
    }

    // ---- depth-relative truncation denominator (fork 1) ----

    // the full-cap volume is a VOL_REF_BPS fraction of live min-over-window depth, floored at VOL_REF_FLOOR

    /// @dev The denominator converts quote depth into UNITS at the record's own frame, so these rows start AT it.
    /// @dev At `DEPTH_BASE` one quote atom buys one collateral atom, so with volRefBps 10000 the denom IS the fed depth.
    uint256 constant DEPTH_BASE = 1 << 96;

    /// @dev The whole cap this step can spend, so every expectation below is the cap and not a restated product.
    function _capStep() internal pure returns (uint256) {
        return (DEPTH_BASE * TRUNC) / 10000;
    }

    /// @dev One capped step on a fresh record, seeded at the frame's own one-to-one price.
    /// @dev `depth` is the min-over-window depth cached at the bucket roll, and 0 means the floor is used instead.
    function _depthStep(uint256 floor, uint256 depth, uint256 vol) internal returns (uint256) {
        PersistenceRecord r = new PersistenceRecord(
            PersistenceRecord.Config({
                writer: address(this),
                truncCapBps: TRUNC,
                initialPrice: DEPTH_BASE,
                obsInterval: 60,
                volRefFloor: floor,
                obsCap: 8,
                unitScale: DEPTH_BASE,
                volRefBps: 10000,
                depthWindow: 60,
                quote: FQ,
                collateral: FC,
                persistenceWindow: P_W,
                pendingWindow: PEND_W
            })
        );
        uint256 t0 = _now();
        if (depth > 0) r.observeDepth(depth);
        r.observe(DEPTH_BASE, floor > vol ? floor : vol); // full-weight first bucket
        _warpTo(t0 + 120); // roll (>60) and span the 60s depth window
        r.observe(DEPTH_BASE / 2, vol); // far under the cap, so the step is the cap and not the target
        return r.lastObserved();
    }

    function test_Trunc_DenominatorTracksLiveDepth() public {
        // depth 1000e18 => denom 1000e18: full cap at/above it, pro-rata below
        assertEq(_depthStep(1, 1000e18, 1000e18), DEPTH_BASE - _capStep(), "vol >= depth-derived denom earns the full cap");
        assertEq(_depthStep(1, 1000e18, 500e18), DEPTH_BASE - _capStep() / 2, "vol below the denom scales pro-rata");
    }

    function test_Trunc_DepthlessBootstrapUsesFloor() public {
        // no depth fed => denom is the floor (2000e18): a below-floor bucket only nudges the record
        assertEq(_depthStep(2000e18, 0, 2000e18), DEPTH_BASE - _capStep(), "empty ring: the floor is the denom, full cap");
        assertEq(_depthStep(2000e18, 0, 1000e18), DEPTH_BASE - _capStep() / 2, "empty ring: below the floor is pro-rata");
    }

    /// @notice Deeper live depth RAISES the denominator, so the SAME dump volume moves the record LESS.
    /// @dev A disposal dump into a deeper pool is therefore more self-defeating.
    function test_Trunc_DeeperDepthStiffensTheCap() public {
        uint256 shallow = _depthStep(1, 1000e18, 1000e18); // vol == denom: full step
        uint256 deep = _depthStep(1, 4000e18, 1000e18); // denom 4x: vol is 1/4 of it, quarter step
        assertGt(deep, shallow, "the same volume moves a deeper-pool record less");
        assertEq(deep, DEPTH_BASE - _capStep() / 4, "quarter of the cap at a quarter of the denom");
    }
}
