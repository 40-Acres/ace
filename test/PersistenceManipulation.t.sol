// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.36;

import {Test} from "forge-std/Test.sol";
import {WarpClock} from "./utils/WarpClock.sol";
import {PersistenceRecord} from "./utils/PersistenceRecord.sol";

/// @notice Adversarial proofs for the price record the loan gates read, on the real record with deploy-like params.
/// @notice trigger() gates on persistedBelow, restore() on persistedAbove, and the draw cap reads minPriceOverWindow.
/// @dev Truncation rate-limits every walk, volume weighting mutes dust, and the windowed min is a true low watermark.
/// @dev So a wick cannot lift the draw cap, dust cannot grief a liquidation, and one dump cannot wrongfully trigger one.
/// @dev The honest path, walking down until it persists, lives in E2E; this suite covers only those read surfaces.
contract PersistenceManipulationTest is WarpClock {
    uint256 constant TRUNC = 500; // 5% full-volume cap per bucket
    uint256 constant START = 1e18;
    uint64 constant IVL = 60; // bucket width, seconds
    uint256 constant VREF = 100e18; // full-weight bucket volume
    uint256 constant OBS_CAP = 2048; // ring capacity, buckets
    uint256 constant WINDOW = 30 minutes; // persistence window: 1800s = 30 buckets
    uint256 constant DUMP_VOL = 10 * VREF; // over-full volume: a maximal flash dump earns the full cap
    // record-only suite: no market, so the declared frame is two distinct placeholders
    address constant FQ = address(0x9001);
    address constant FC = address(0xC011);

    PersistenceRecord internal rec;

    function setUp() public {
        _warpTo(1_000_000);
        rec = new PersistenceRecord(
            PersistenceRecord.Config({
                writer: address(this),
                truncCapBps: TRUNC,
                initialPrice: START,
                obsInterval: IVL,
                volRefFloor: VREF,
                obsCap: OBS_CAP,
                unitScale: 1e30,
                volRefBps: 5000,
                depthWindow: 1800,
                quote: FQ,
                collateral: FC,
                persistenceWindow: WINDOW,
                pendingWindow: 3600
            })
        );
    }

    // ---- helpers ----

    /// @dev Walks the record to a standing 0.90 and holds 40 buckets so the 1e18 anchor exits the 30-minute window.
    /// @dev Every in-window bucket then ends at or below 0.95, strictly below a 0.96 gate.
    function _holdAt90() internal {
        uint256 t = _now();
        for (uint256 i; i < 40; i++) {
            t += IVL;
            _warpTo(t);
            rec.observe(0.9e18, VREF);
        }
        assertEq(rec.lastObserved(), 0.9e18, "record settles to and holds 0.90");
        assertTrue(rec.persistedBelow(FQ, FC, 0.96e18, WINDOW), "0.90 is genuinely persisted below 0.96");
    }

    // ==== WRONGFUL-LIQUIDATION RESISTANCE: trigger() calls persistedBelow(triggerPrice, WINDOW) ====

    /// @notice One full-volume flash dump does not make persistedBelow true immediately.
    /// @dev Truncation caps the move to one 5% step and the window is still full of high buckets above the gate.
    function test_SingleFlashDump_DoesNotTriggerImmediately() public {
        // age the record so a 30-minute window is fully spanned by 1e18 buckets (window is real, not unproven)
        uint256 t = _now();
        for (uint256 i; i < 35; i++) {
            t += IVL;
            _warpTo(t);
            rec.observe(START, VREF);
        }
        // the maximal single-bucket flash dump: price 0.01, volume 10x reference
        t += IVL;
        _warpTo(t);
        rec.observe(0.01e18, DUMP_VOL);
        assertEq(rec.lastObserved(), 0.95e18, "one dump moves the record one capped 5% step, not to 0.01");
        // gate below the standing price: the rate-limit guard alone rejects it
        assertFalse(rec.persistedBelow(FQ, FC, 0.9e18, WINDOW), "one dump cannot drive the record below a 0.90 gate");
        // gate above the standing price: the window is still full of 1e18 buckets, so below-ness never held
        assertFalse(rec.persistedBelow(FQ, FC, 0.96e18, WINDOW), "one dump does not span the window below a 0.96 gate");
    }

    /// @notice Even once the dumped-low price stands, persistedBelow needs a FULL 30 minutes of buckets below the gate.
    /// @dev The boundary is probed both sides: false at 29 minutes, true at 30.
    function test_PersistedBelow_RequiresFullWindowBelow() public {
        uint256 x = 0.8e18;
        // walk the record down below x, capturing the first bucket that crosses below
        uint256 tCross;
        uint256 t = _now();
        for (uint256 i; i < 60; i++) {
            t += IVL;
            _warpTo(t);
            rec.observe(0.01e18, DUMP_VOL);
            if (rec.lastObserved() < x) {
                tCross = t;
                break;
            }
        }
        assertGt(tCross, 0, "the record crossed below the gate");
        // hold below x, filling buckets, and probe the boundary at 29 and 30 minutes past the cross
        uint256 t29 = tCross + WINDOW - IVL; // window start still lands on the last pre-cross bucket
        uint256 t30 = tCross + WINDOW; // window start lands exactly on the crossing bucket
        for (t = tCross + IVL; t <= t30; t += IVL) {
            _warpTo(t);
            rec.observe(0.01e18, DUMP_VOL);
            if (t == t29) {
                assertFalse(rec.persistedBelow(FQ, FC, x, WINDOW), "29 minutes below is not a full window below");
            }
            if (t == t30) {
                assertTrue(rec.persistedBelow(FQ, FC, x, WINDOW), "a full 30 minutes below the gate persists");
            }
        }
    }

    /// @notice N full-volume dumps across N buckets cannot push lastObserved below START*(0.95)^N.
    /// @dev Truncation bounds the walk rate, so a wrongful trigger needs sustained time and capital.
    function test_TruncationRateLimitsTheWalkDown() public {
        uint256 n = 10;
        uint256 t = _now();
        for (uint256 i; i < n; i++) {
            t += IVL;
            _warpTo(t);
            rec.observe(0.01e18, DUMP_VOL); // wants 0.01 every bucket; gets one capped step
        }
        // mirror the contract's step (base - base*bps/10000) exactly to avoid rounding drift
        uint256 floor = START;
        for (uint256 i; i < n; i++) {
            floor = floor - (floor * TRUNC) / 10000;
        }
        assertEq(rec.lastObserved(), floor, "N dumps equal exactly N capped 5% steps, never the raw 0.01 target");
        assertGt(rec.lastObserved(), 0.5e18, "after 10 full dumps the record is still above 0.5, not at 0.01");
    }

    // ==== LIQUIDATION-GRIEF RESISTANCE: an attacker faking recovery to block a legit liquidation ====

    /// @notice A DUST high-print in the newest bucket cannot lift a genuinely persisted price above the gate.
    /// @dev Volume weighting plus the cap keep the record below, so persistedBelow holds.
    function test_DustHighPrint_CannotGriefLiquidation() public {
        _holdAt90();
        // a dust wick: price 5.0 but only 1/1000 of reference volume, in a fresh bucket
        _warpBy(IVL);
        rec.observe(5e18, VREF / 1000);
        // full cap 0.045 scaled by volume/reference (1/1000) = 4.5e13: the record barely twitches
        assertEq(rec.lastObserved(), 0.9e18 + 4.5e13, "a dust high print moves the record by a whisker");
        assertLt(rec.lastObserved(), 0.96e18, "the dust wick stays below the gate");
        assertTrue(rec.persistedBelow(FQ, FC, 0.96e18, WINDOW), "dust cannot fake recovery to grief a liquidation");
    }

    /// @notice Contrast: FULL-volume high prints CAN break persistedBelow, but never inside one bucket.
    /// @dev The cap forces the cost across buckets as real sustained capital, so grief is priced rather than free.
    function test_FullVolumeHighPrint_BreaksPersistedBelowAtRealCost() public {
        _holdAt90();
        // one full-volume high print: 0.90 -> 0.945, still one cap step below the 0.96 gate
        _warpBy(IVL);
        rec.observe(5e18, VREF);
        assertEq(rec.lastObserved(), 0.945e18, "one full step is capped to +5%, still below the gate");
        assertTrue(rec.persistedBelow(FQ, FC, 0.96e18, WINDOW), "one full step does not yet clear the gate");
        // a second full-volume bucket clears it: 0.945 -> 0.99225, now above the gate
        _warpBy(IVL);
        rec.observe(5e18, VREF);
        assertGt(rec.lastObserved(), 0.96e18, "sustained full-volume prints lift the record above the gate");
        assertFalse(rec.persistedBelow(FQ, FC, 0.96e18, WINDOW), "breaking persistedBelow costs real capital over buckets");
    }

    // ==== DRAW-CAP RESISTANCE: minPriceOverWindow IS the draw cap, so a higher read funds a draw higher ====

    /// @notice A transient pump inside an otherwise-low window cannot raise the read above the lowest in-window bucket.
    /// @dev minPriceOverWindow is a LOW watermark, so a wick can never inflate the draw cap.
    function test_MinPrice_TransientPumpDoesNotInflateSkim() public {
        _holdAt90(); // window full of 0.90 buckets
        // pump one fresh bucket to 5.0 at full volume: capped to 0.945, the newest bucket
        _warpBy(IVL);
        rec.observe(5e18, VREF);
        assertEq(rec.lastObserved(), 0.945e18, "the pump bucket itself is capped to +5%");
        // the windowed min ignores the pump and reads the low buckets: the cap sits at 0.90, not the wick
        assertEq(rec.minPriceOverWindow(FQ, FC, WINDOW), 0.9e18, "windowed min is the low watermark, not the pumped head");
        assertLt(rec.minPriceOverWindow(FQ, FC, WINDOW), rec.lastObserved(), "the sizing read sits below the pumped head");
    }

    /// @notice One low bucket anywhere in the window collapses minPriceOverWindow to it.
    /// @dev Lifting the read means making EVERY bucket high, which is the sustained cost of lifting the cap.
    function test_MinPrice_OneLowBucketPinsTheRead() public {
        // hold high at 1.0 for 15 buckets
        uint256 t = _now();
        for (uint256 i; i < 15; i++) {
            t += IVL;
            _warpTo(t);
            rec.observe(1e18, VREF);
        }
        // one low bucket mid-window: capped to 0.95
        t += IVL;
        _warpTo(t);
        rec.observe(0.01e18, VREF);
        uint256 dip = rec.lastObserved();
        assertEq(dip, 0.95e18, "the single low bucket is one capped step down");
        // resume high for 15 more buckets
        for (uint256 i; i < 15; i++) {
            t += IVL;
            _warpTo(t);
            rec.observe(1e18, VREF);
        }
        // the read collapses to the one low bucket even though every other in-window bucket is high
        assertEq(rec.minPriceOverWindow(FQ, FC, WINDOW), dip, "one low bucket pins the windowed min, capping the skim size");
    }

    // fuzz: over any print sequence spanning the window the read exceeds neither lastObserved nor any in-window bucket
    /// forge-config: default.fuzz.runs = 5000
    function testFuzz_MinPriceNeverExceedsAnyConstituent(uint256 seed) public {
        uint256 n = 40; // 40 buckets = 40 minutes, spans the 30-minute window with room to spare
        uint256[] memory prices = new uint256[](n);
        uint64[] memory times = new uint64[](n);
        uint256 t = _now();
        for (uint256 i; i < n; i++) {
            t += IVL;
            _warpTo(t);
            uint256 p = bound(uint256(keccak256(abi.encode(seed, i))), 0.01e18, 100e18);
            uint256 v = bound(uint256(keccak256(abi.encode(seed, i, "v"))), 0, VREF * 3);
            rec.observe(p, v);
            prices[i] = rec.lastObserved();
            times[i] = uint64(_now());
        }
        uint256 read = rec.minPriceOverWindow(FQ, FC, WINDOW);
        assertGt(read, 0, "40 buckets span the window: the read is proven, never a stale answer");
        assertLe(read, rec.lastObserved(), "the windowed min never exceeds the standing price");
        uint64 boundary = uint64(_now() - WINDOW);
        for (uint256 i; i < n; i++) {
            if (times[i] > boundary) {
                assertLe(read, prices[i], "the windowed min never exceeds any in-window bucket price");
            }
        }
    }
}
