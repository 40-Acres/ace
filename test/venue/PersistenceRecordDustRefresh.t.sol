// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.36;

import {WarpClock} from "../utils/WarpClock.sol";
import {PersistenceRecord} from "../utils/PersistenceRecord.sol";
import {PriceFrame} from "../utils/PriceFrame.sol";

/// @title PersistenceRecordDustRefreshTest
/// @notice PoC, phase 6 of audit run 2026-09-05-05351c. RED ON PURPOSE where a claim is under test.
/// @notice The freshness rail in `_minPriceOverWindow` is a TIMESTAMP test, and any observation refreshes it.
/// @notice Truncation guarantees a dust observation cannot move the price, so a dust print carries no information.
/// @notice Together: one dust print per window revives the stale-high draw cap the freshness rail was built to refuse.
/// @dev The record alone, writer = this test: any writer calls `observe` per swap, and a dust swap is one of its inputs.
/// @dev Depth ring never fed, so `_denom` sits at `VOL_REF_FLOOR`; a deep live pool makes the denominator larger, never smaller.
contract PersistenceRecordDustRefreshTest is WarpClock {
    PersistenceRecord internal rec;

    uint256 internal constant TRUNC_BPS = 500;
    uint64 internal constant INTERVAL = 60;
    uint256 internal constant CAP = 64;
    uint256 internal constant WINDOW = 600;
    uint256 internal constant VOL_REF_FLOOR = 1e18; // one whole collateral token at full weight
    address internal constant FQ = address(0x9001);
    address internal constant FC = address(0xC011);

    uint256 internal START;

    function setUp() public {
        _warpTo(1_000_000);
        START = PriceFrame.px(1e18, FQ, FC);
        rec = new PersistenceRecord(
            PersistenceRecord.Config({
                writer: address(this),
                truncCapBps: TRUNC_BPS,
                initialPrice: START,
                obsInterval: INTERVAL,
                volRefFloor: VOL_REF_FLOOR,
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

    /// @dev Honest trading: full-weight volume at START, one bucket per interval, so the ring is warm and real.
    function _warmRing(uint256 n) internal {
        for (uint256 i; i < n; i++) {
            _warpBy(INTERVAL);
            rec.observe(START, VOL_REF_FLOOR);
        }
    }

    /// @notice PREMISE, green: after the warm ring goes silent past the window the cap refuses. This is the #451 fix.
    function test_Premise_SilencePastTheWindowRefuses() public {
        _warmRing(20);
        _warpBy(WINDOW + 1);
        assertEq(rec.minPrice(FQ, FC), 0, "silence past the window refuses: the fix holds when nothing prints");
    }

    /// @notice MEASUREMENT, green: what the dust print actually did. Head moved a whole window; price moved by zero.
    /// @dev The two numbers the finding rests on, pinned so the mechanism is legible without reading the walk.
    function test_Measure_DustPrintMovesTheHeadNotThePrice() public {
        _warmRing(20);
        _warpBy(WINDOW + 1);
        assertEq(rec.minPrice(FQ, FC), 0, "premise: silent, refused");
        rec.observe(START / 2, 1);
        uint256 cap = rec.minPrice(FQ, FC);
        uint256 maxStep = (START * TRUNC_BPS) / 10000 / VOL_REF_FLOOR; // the cap, prorated by vol / denom = 1 / 1e18
        assertGt(cap, 0, "the cap is revived");
        assertLe(START - cap, maxStep + 1, "the half-price dust print moved it by at most the prorated cap, which is ~5e-20 of START");
        assertEq(rec.lastObserved(), cap, "and the head price is the same number");
    }

    /// @notice MEASUREMENT, green: the revival holds for a full window, then one more dust print holds it again.
    /// @dev One dust observe per window is the standing cost of a stale-high cap for as long as the pool stays quiet.
    function test_Measure_OneDustPrintPerWindowHoldsTheCapIndefinitely() public {
        _warmRing(20);
        uint256 maxStep = (START * TRUNC_BPS) / 10000 / VOL_REF_FLOOR;
        for (uint256 i; i < 5; i++) {
            _warpBy(WINDOW + 1);
            assertEq(rec.minPrice(FQ, FC), 0, "each silence refuses");
            rec.observe(START / 2, 1);
            uint256 cap = rec.minPrice(FQ, FC);
            assertLe(START - cap, (i + 1) * (maxStep + 1), "and each dust print revives the stale cap, less one prorated step");
        }
    }
}
