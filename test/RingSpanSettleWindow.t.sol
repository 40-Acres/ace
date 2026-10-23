// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.36;

import {Test} from "forge-std/Test.sol";
import {WarpClock} from "./utils/WarpClock.sol";
import {PersistenceRecord} from "./utils/PersistenceRecord.sol";

/// @notice Proves the harm behind a settle window wider than the record's guaranteed ring span.
/// @notice `Loans.settleable(id)` is `RECORD.persistedBelow(trigger, SETTLE_WINDOW)`, which fails safe to false.
/// @dev No retained bucket old enough to prove the window disables price settlement silently: only forceClose closes.
/// @dev Wired at the record level, below the genesis span rail, so it stays valid while that rail stands.
/// @dev Small ring (obsCap 4, interval 60 => span 180s) held at 1e18, strictly below x = 2e18, across rolled buckets.
/// @dev Same ring, same price, same x: only the window differs, isolating the span coupling as the cause.
/// @dev minPriceOverWindow, the draw cap, shares the identical fail-safe and is asserted alongside.
contract RingSpanSettleWindowTest is WarpClock {
    uint64 constant INTERVAL = 60;
    uint256 constant CAP = 4; // deliberately tiny: ring span = 180s
    uint256 constant RING_SPAN = (CAP - 1) * INTERVAL; // 180s: head to oldest crosses CAP-1 gaps, not CAP
    uint256 constant PRICE = 1e18; // held here, strictly below X the whole time
    uint256 constant X = 2e18; // the "trigger" the price stays below
    // record-only suite: no market, so the declared frame is two distinct placeholders
    address constant FQ = address(0x9001);
    address constant FC = address(0xC011);

    PersistenceRecord internal rec;
    uint256 internal t0;

    function setUp() public {
        t0 = 1_000_000; // large base so _now() - window never underflows
        _warpTo(t0);
        // writer == this test so observe() is callable directly; windows sized to the ring, 120 + 60 IS its 180s span
        rec = new PersistenceRecord(
            PersistenceRecord.Config({
                writer: address(this),
                truncCapBps: 500,
                initialPrice: PRICE,
                obsInterval: INTERVAL,
                volRefFloor: 1,
                obsCap: CAP,
                unitScale: 1e18,
                volRefBps: 5000,
                depthWindow: 60,
                quote: FQ,
                collateral: FC,
                persistenceWindow: 120,
                pendingWindow: 60
            })
        );
    }

    /// @dev Rolls n fresh INTERVAL buckets at PRICE, so _last stays below X; the ring retains only the last CAP.
    function _rollBuckets(uint256 n) internal {
        for (uint256 i = 1; i <= n; i++) {
            _warpTo(t0 + i * INTERVAL);
            rec.observe(PRICE, 1e18);
        }
    }

    /// @notice With the whole ring below X, a window beyond the ring span reads false and one inside it reads true.
    /// @dev That false is settleable() wedged shut when SETTLE_WINDOW exceeds the span: finalize can never fire.
    function test_persistedBelow_WindowBeyondRingSpan_FailsSafeFalse() public {
        _rollBuckets(12); // wrap the 4-slot ring; _now() == t0 + 720

        // every retained bucket is below X, and the live price is below X
        assertEq(rec.lastObserved(), PRICE, "price held below X the whole time");
        assertLt(PRICE, X, "sanity: PRICE < X");
        assertLt(RING_SPAN, 600, "sanity: queried big window exceeds the ring span");
        assertLt(120, RING_SPAN, "sanity: queried small window fits inside the ring span");

        // window 600s > 180s span: no bucket proves the window start, so false DESPITE the whole ring below X
        assertFalse(rec.persistedBelow(FQ, FC, X, 600), "window beyond ring span: fail-safe false silently disables settle");

        // control: window 120s fits the 180s span and proves below-ness on the same price, isolating the coupling
        assertTrue(rec.persistedBelow(FQ, FC, X, 120), "in-span window on the same below-X ring: true");

        // the same fail-safe hits the draw cap: 0 (proves nothing) over the span, the real min inside it
        assertEq(rec.minPriceOverWindow(FQ, FC, 600), 0, "minPriceOverWindow beyond span: fail-safe 0");
        assertEq(rec.minPriceOverWindow(FQ, FC, 120), PRICE, "minPriceOverWindow within span: the real min");
    }
}
