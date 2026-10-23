// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.36;

import {Test} from "forge-std/Test.sol";
import {WarpClock} from "./utils/WarpClock.sol";
import {PersistenceRecord} from "./utils/PersistenceRecord.sol";

// The windowed record fixture: truncation, silence, windowed persistence.
contract PersistenceRecordTest is WarpClock {
    PersistenceRecord internal rec;
    uint256 constant TRUNC_BPS = 500; // 5% per observation
    uint256 constant START = 1.0e18;
    // record-only suite: no market, so the declared frame is two distinct placeholders
    address constant FQ = address(0x9001);
    address constant FC = address(0xC011);

    function setUp() public {
        _warpTo(1_000_000); // non-zero base time
        // interval 1s, volRef at the test volumes: every observe is full-weight; depth window 0, and this suite reads none
        rec = new PersistenceRecord(
            PersistenceRecord.Config({
                writer: address(this),
                truncCapBps: TRUNC_BPS,
                initialPrice: START,
                obsInterval: 1,
                volRefFloor: 1e18,
                obsCap: 64,
                unitScale: 1e30,
                volRefBps: 5000,
                depthWindow: 0,
                quote: FQ,
                collateral: FC,
                persistenceWindow: 24,
                pendingWindow: 24
            })
        );
    }

    function test_Observe_OnlyWriter() public {
        vm.prank(address(0xBAD));
        vm.expectRevert(PersistenceRecord.NotWriter.selector);
        rec.observe(0.5e18, 1);
    }

    function test_Record_VolumeWeighted_TruncatedPerBlock() public {
        rec.observe(0.1e18, 1e18); // a one-tx dump: wants -90%, capped to -5%
        assertEq(rec.lastObserved(), (START * (10000 - TRUNC_BPS)) / 10000, "move capped to 5%");
    }

    function test_Record_SilencePersistsLastObservation() public {
        rec.observe(0.98e18, 1e18);
        uint256 p = rec.lastObserved();
        _warpBy(10 days); // silence
        assertEq(rec.lastObserved(), p, "stale price persists, not zeroed");
    }

    function test_PersistedBelow_NeedsFullWindow() public {
        // walk price down under 0.95 (5% steps) so _last < x
        rec.observe(0.95e18, 1e18); // -> 0.95
        rec.observe(0.9e18, 1e18); // -> 0.9025 (capped step)
        uint256 x = 0.96e18;
        // just dropped below: not yet persisted for 30 min
        assertFalse(rec.persistedBelow(FQ, FC, x, 30 minutes), "a fresh wick does not persist");
        _warpBy(30 minutes);
        assertTrue(rec.persistedBelow(FQ, FC, x, 30 minutes), "held below for the window");
    }

    /// @dev Targets the in-window break, not the `_last >= x` head shortcut: the head must be BELOW x
    /// @dev and the window-start bucket BELOW x too, so only a mid-window bucket above x can answer false.
    function test_PersistedBelow_FalseIfRecentlyAbove() public {
        rec.observe(0.9e18, 1e18); // anchor bucket, capped down to 0.95: the window-start state, below x
        _warpBy(30 minutes);
        rec.observe(1.0e18, 1e18); // capped up to 0.9975: the in-window bucket ABOVE x
        _warpBy(30 minutes);
        rec.observe(0.9e18, 1e18); // capped down to 0.947625, so the head clears the shortcut
        _warpBy(10 minutes);
        assertLt(rec.lastObserved(), 0.96e18, "head below x: the shortcut is not what answers");
        // boundary lands between the 0.95 anchor and the 0.9975 bucket, so window-start alone would be true
        assertFalse(rec.persistedBelow(FQ, FC, 0.96e18, 1 hours), "0.9975 inside the window broke below-ness");
    }

    function test_PersistedAbove_Symmetric() public {
        rec.observe(1.05e18, 1e18); // up 5% -> 1.05
        assertFalse(rec.persistedAbove(FQ, FC, 1.01e18, 30 minutes));
        _warpBy(30 minutes);
        assertTrue(rec.persistedAbove(FQ, FC, 1.01e18, 30 minutes), "held above for the window");
    }
}
