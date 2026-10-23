// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.36;

import {WarpClock} from "../utils/WarpClock.sol";
import {PersistenceRecord} from "../utils/PersistenceRecord.sol";
import {PriceFrame} from "../utils/PriceFrame.sol";

/// @title PersistenceRecordFreshnessTest
/// @notice The draw cap must refuse under silence instead of answering the last printed price.
/// @notice The defect: a silent head sits at or before the boundary, so the walk returns `_last` on step one.
/// @dev STRICT, not `>=`: at `head.time == boundary` the walk terminates on the head, and a cold record would answer its ctor anchor.
/// @dev Prices are held FLAT via zero-volume observes, which still roll a bucket -- TIME tests, not truncation tests.
contract PersistenceRecordFreshnessTest is WarpClock {
    PersistenceRecord internal rec;

    uint256 internal constant TRUNC_BPS = 500;
    uint64 internal constant INTERVAL = 60;
    uint256 internal constant CAP = 64;
    address internal constant FQ = address(0x9001); // record-only suite: the declared pair is two placeholders
    address internal constant FC = address(0xC011);

    uint256 internal constant WINDOW = 600; // 10 intervals: comfortably clear of the false-refusal floor
    uint256 internal constant TIGHT = 2 * INTERVAL; // the guidance floor itself, where a live pool must still answer

    uint256 internal START;
    uint256 internal T0;

    function setUp() public {
        _warpTo(1_000_000);
        T0 = _now();
        START = PriceFrame.px(1e18, FQ, FC);
        rec = new PersistenceRecord(
            PersistenceRecord.Config({
                writer: address(this),
                truncCapBps: TRUNC_BPS,
                initialPrice: START,
                obsInterval: INTERVAL,
                volRefFloor: 1e18,
                obsCap: CAP,
                unitScale: 1 << 96,
                volRefBps: 5000,
                depthWindow: WINDOW,
                quote: FQ,
                collateral: FC,
                persistenceWindow: WINDOW,
                pendingWindow: 600
            })
        );
    }

    /// @dev One bucket roll at the same price: zero volume never moves it, but the boundary still rolls.
    function _roll() internal {
        _warpBy(INTERVAL);
        rec.observe(START, 0);
    }

    /// @dev Roll `n` buckets, so the ring carries real print timestamps spanning `n * INTERVAL`.
    function _rollMany(uint256 n) internal {
        for (uint256 i; i < n; i++) {
            _roll();
        }
    }

    // --- the defect: silence answers a price nobody printed ---

    /// @notice Silence longer than the window must answer 0, not the last print.
    function test_Silence_PastTheWindow_AnswersZero() public {
        _rollMany(20); // a warm ring, so this is about SILENCE and not about spanning
        _warpBy(WINDOW + 1);
        assertEq(rec.minPriceOverWindow(FQ, FC, WINDOW), 0, "silence past the window must refuse, not answer _last");
    }

    /// @notice The boundary itself refuses: `head.time == boundary` is where the walk returns on step one.
    /// @dev This is the `>` in the predicate. At `>=` the fabricated-anchor draw survives the whole fix.
    function test_Boundary_HeadExactlyAtTheBoundary_Refuses() public {
        _rollMany(20);
        uint256 head = _now(); // the roll we just took IS the head observation's time
        _warpTo(head + WINDOW); // boundary == head, exactly
        assertEq(rec.minPriceOverWindow(FQ, FC, WINDOW), 0, "head sitting ON the boundary must refuse");
    }

    /// @notice One second inside the boundary still admits, and answers the true windowed minimum.
    /// @dev The guard against over-correcting: a bound that refuses here would close a live market.
    function test_Boundary_HeadOneSecondInside_Admits() public {
        _rollMany(20);
        uint256 head = _now();
        _warpTo(head + WINDOW - 1);
        assertEq(rec.minPriceOverWindow(FQ, FC, WINDOW), START, "one second inside the boundary must still answer");
    }

    // --- the cold record: the case the young rail was supposed to catch and does not ---

    /// @notice A never-observed record aged exactly the window must refuse its own constructor anchor.
    /// @dev Genesis admits this market, so without the bound the creator-chosen anchor would BE its draw cap.
    function test_ColdRecord_AtTheBoundary_RefusesTheFabricatedAnchor() public {
        _warpTo(T0 + WINDOW); // boundary == T0 == the anchor's time
        assertEq(rec.minPriceOverWindow(FQ, FC, WINDOW), 0, "the ctor anchor must never serve as a draw cap");
    }

    /// @notice And past the boundary likewise, which is the same fabricated price one second later.
    function test_ColdRecord_PastTheBoundary_Refuses() public {
        _warpTo(T0 + WINDOW + 1);
        assertEq(rec.minPriceOverWindow(FQ, FC, WINDOW), 0, "a cold record stays refused as it ages");
    }

    /// @notice Before the window it already answered 0 -- the ring genuinely does not span yet.
    /// @dev Pinned so the fix is not credited with a refusal that predates it.
    function test_ColdRecord_BeforeTheWindow_AlreadyRefused() public {
        _warpTo(T0 + WINDOW - 1);
        assertEq(rec.minPriceOverWindow(FQ, FC, WINDOW), 0, "a young ring does not span, and never did");
    }

    // --- no false refusal on a live pool ---

    /// @notice A pool printing once per bucket must never be refused at the guidance floor of 2 intervals.
    /// @dev The honest cost of the strict bound is a market whose window sits at or under one interval.
    /// @dev At two intervals the gap `now - head.time` never reaches the window, so a live pool always answers.
    function test_LivePool_AtTwiceTheInterval_NeverFalseRefuses() public {
        _rollMany(20);
        for (uint256 i; i < 10; i++) {
            _roll();
            assertEq(rec.minPriceOverWindow(FQ, FC, TIGHT), START, "a live pool must answer at the guidance floor");
            _warpBy(INTERVAL - 1); // the far edge of the bucket, just before the next roll is due
            assertEq(rec.minPriceOverWindow(FQ, FC, TIGHT), START, "and still answer at the far edge of its bucket");
        }
    }

    // --- the per-direction asymmetry, pinned so the fix does not quietly widen ---

    /// @notice `persistedBelow` is DELIBERATELY unchanged: silence persists below-ness by ruling.
    /// @dev The price channel fails closed and the settlement channel does not, so settlement cannot be
    /// @dev stalled by a quiet venue. That asymmetry is intentional and this pins it against drift.
    function test_PersistedBelow_IsUnchangedUnderTheSameSilence() public {
        _rollMany(20);
        uint256 above = START + 1; // _last sits strictly below this, so below-ness is true at the head
        assertTrue(rec.persistedBelow(FQ, FC, above, WINDOW), "below-ness holds while the venue is printing");
        _warpBy(WINDOW + 1);
        assertTrue(rec.persistedBelow(FQ, FC, above, WINDOW), "and silence must NOT dissolve it");
        assertEq(rec.minPriceOverWindow(FQ, FC, WINDOW), 0, "while the price channel refuses over the same silence");
    }
}
