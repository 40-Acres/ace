// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.36;

import {IPoolManager} from "@uniswap/v4-core/src/interfaces/IPoolManager.sol";
import {StateLibrary} from "@uniswap/v4-core/src/libraries/StateLibrary.sol";
import {TickMath} from "@uniswap/v4-core/src/libraries/TickMath.sol";
import {PoolId} from "@uniswap/v4-core/src/types/PoolId.sol";
import {SwapParams} from "@uniswap/v4-core/src/types/PoolOperation.sol";
import {RunwayHook} from "../../src/entities/launch/RunwayHook.sol";
import {RunwayHookHarness} from "./RunwayHookHarness.sol";
import {RunwayHookWindowBase} from "./RunwayHookWindow.t.sol";

/// @title RunwayHookWindowHardeningTest
/// @notice The read's own slot index against the swap path's: a block's first swap after exactly 12, 24 and 36 hours of silence,
/// @notice the read before a block's first swap against the read after it, and how long one sample stays in the window.
/// @dev The read rolls the window with its own slot index; only the swap path's was pinned, so these rows tie the two together.
contract RunwayHookWindowHardeningTest is RunwayHookWindowBase {
    RunwayHookHarness internal harness;

    function setUp() public override {
        super.setUp();
        harness = new RunwayHookHarness(IPoolManager(address(manager)), address(strat));
    }

    // ---- silence, on the real pool ----

    /// @dev Three block-start samples: tick 0 at the open mid-slot, then a1 sampled exactly on the next slot's first second, at `t2`.
    /// @dev The price then stands at a2 < a1 < 0, so the slots read apart: the open's 0, a1, and a2.
    function _history() internal returns (int24 a1, int24 a2, uint256 t2, uint32 k) {
        _open(key, PRICE);
        _midSlot();
        _swap(key, true, NUDGE); // samples 0
        a1 = _tick(id);
        k = _slotNow() + 1;
        t2 = uint256(k) * SLOT;
        _warpTo(t2);
        vm.roll(vm.getBlockNumber() + 1);
        _swap(key, true, NUDGE); // samples a1, one slot on, on its first second
        a2 = _tick(id);
        assertTrue(a2 < a1 && a1 < 0, "fixture: three distinct block-start prices");
    }

    /// @dev After `silence` from t2, a new block reads the window, takes its first swap, and reads again: both reads must match.
    /// @dev Returns the read, the stored word after the swap, and the tick the swap left.
    function _afterSilence(uint256 t2, uint256 silence) internal returns (int24 lo, int24 hi, RunwayHook.Window memory w) {
        _warpTo(t2 + silence);
        vm.roll(vm.getBlockNumber() + 1);
        int24 start = _tick(id);
        int24 spot;
        (lo, hi, spot) = hook.windowOf(id);
        assertEq(spot, start, "fixture: spot is the block's start");
        _swap(key, false, 3 * NUDGE); // the block's first swap moves the price up
        w = _stored(address(hook), id);
        (int24 lo2, int24 hi2, int24 spot2) = hook.windowOf(id);
        assertEq(abi.encode(lo2, hi2), abi.encode(lo, hi), "the read after the block's first swap is not the read before it");
        assertGt(spot2, start, "fixture: the swap moved spot");
    }

    /// @notice A first swap 12 hours less a second after the last sample folds into its slot; at 12 hours exactly it shifts one slot.
    /// @notice Either way the open's 0 is still in the window, and the reads before and after the swap agree.
    function test_TheFirstSwapAfterTwelveHoursOfSilence() public {
        (int24 a1, int24 a2, uint256 t2, uint32 k) = _history();
        uint256 snap = vm.snapshotState();
        (int24 lo, int24 hi, RunwayHook.Window memory w) = _afterSilence(t2, 12 hours - 1);
        _eq(w, RunwayHook.Window(k, _block(), a2, a1, a1, 0, 0, 0, true), "a second short of 12 hours shifted a slot");
        assertEq(abi.encode(lo, hi), abi.encode(a2, int24(0)), "the read a second short of 12 hours");
        vm.revertToState(snap);
        (lo, hi, w) = _afterSilence(t2, 12 hours);
        _eq(w, RunwayHook.Window(k + 1, _block(), a2, a2, a2, a1, a1, 0, true), "12 hours did not shift one slot");
        assertEq(abi.encode(lo, hi), abi.encode(a2, int24(0)), "the read at 12 hours");
    }

    /// @notice At 24 hours less a second the open's 0 is still read; at 24 hours exactly its slot has gone, and a1 is the window's top.
    function test_TheFirstSwapAfterTwentyFourHoursOfSilence() public {
        (int24 a1, int24 a2, uint256 t2, uint32 k) = _history();
        uint256 snap = vm.snapshotState();
        (int24 lo, int24 hi, RunwayHook.Window memory w) = _afterSilence(t2, 24 hours - 1);
        _eq(w, RunwayHook.Window(k + 1, _block(), a2, a2, a2, a1, a1, 0, true), "a second short of 24 hours shifted two slots");
        assertEq(abi.encode(lo, hi), abi.encode(a2, int24(0)), "the read a second short of 24 hours");
        vm.revertToState(snap);
        (lo, hi, w) = _afterSilence(t2, 24 hours);
        _eq(w, RunwayHook.Window(k + 2, _block(), a2, a2, a2, a2, a2, a1, true), "24 hours did not shift two slots");
        assertEq(abi.encode(lo, hi), abi.encode(a2, a1), "the read at 24 hours still holds the open's 0");
    }

    /// @notice At 36 hours less a second a1 is still read; at 36 hours exactly every slot is the held price a2.
    function test_TheFirstSwapAfterThirtySixHoursOfSilence() public {
        (int24 a1, int24 a2, uint256 t2, uint32 k) = _history();
        uint256 snap = vm.snapshotState();
        (int24 lo, int24 hi, RunwayHook.Window memory w) = _afterSilence(t2, 36 hours - 1);
        _eq(w, RunwayHook.Window(k + 2, _block(), a2, a2, a2, a2, a2, a1, true), "a second short of 36 hours restarted the window");
        assertEq(abi.encode(lo, hi), abi.encode(a2, a1), "the read a second short of 36 hours");
        vm.revertToState(snap);
        (lo, hi, w) = _afterSilence(t2, 36 hours);
        _eq(w, _at(k + 3, _block(), a2), "36 hours did not restart every slot at the held price");
        assertEq(abi.encode(lo, hi), abi.encode(a2, a2), "the read at 36 hours still holds a1");
    }

    // ---- the read against the swap path, on the harness ----

    /// @notice In any block that has not sampled, for any stored word, tick and time, the read before the first swap is the read after it.
    /// @notice However far the swap then moves spot, lo and hi stand; spot is the new tick.
    function testFuzz_TheReadBeforeABlocksFirstSwapIsTheReadAfterIt(RunwayHook.Window memory w, int24 t, int24 moved, uint256 time, uint48 blk) public {
        blk = uint48(bound(blk, 1, type(uint48).max));
        if (w.seeded && w.lastBlock == blk) w.lastBlock = blk - 1; // this block has not sampled
        harness.setWindow(id, w);
        _setTick(id, t);
        _warpTo(bound(time, 0, type(uint64).max));
        vm.roll(blk);
        (int24 lo, int24 hi, int24 spot) = harness.windowOf(id);
        assertEq(spot, t, "fixture: spot is slot0's tick");
        vm.prank(address(manager));
        harness.beforeSwap(address(this), key, SwapParams(true, -1, 0), "");
        _setTick(id, moved);
        (int24 lo2, int24 hi2, int24 spot2) = harness.windowOf(id);
        assertEq(abi.encode(lo2, hi2, spot2), abi.encode(lo, hi, moved), "the block's first swap moved the window it read before it");
    }

    /// @notice A sample stays in the read window at least 24 hours and at most 36: it leaves exactly when its slot is three behind now.
    /// @dev Fuzzed over where in its slot the sample fell and how long the price then stood elsewhere.
    function testFuzz_ASampleStaysTwentyFourToThirtySixHours(uint32 k0, uint256 phase, uint256 silence) public {
        k0 = uint32(bound(k0, 1, 1_000_000));
        phase = bound(phase, 0, SLOT - 1);
        silence = bound(silence, 1, 40 hours);
        uint256 t0 = uint256(k0) * SLOT + phase;
        harness.setWindow(id, _at(k0, 5, 100)); // the old sample, tick 100, alone in every slot
        _setTick(id, -100); // the price that stood at every block start since
        _warpTo(t0 + silence);
        vm.roll(6);
        (int24 lo, int24 hi,) = harness.windowOf(id);
        bool kept = (t0 + silence) / SLOT - k0 <= 2;
        assertEq(abi.encode(lo, hi), abi.encode(int24(-100), kept ? int24(100) : int24(-100)), "the sample's stay is not its slot's three");
        if (silence < 24 hours) assertTrue(kept, "a sample left the window before 24 hours");
        if (silence >= 36 hours) assertFalse(kept, "a sample stayed in the window past 36 hours");
    }

    /// @notice The read turns a slot exactly on its boundary: a second before it, the oldest slot's extremes are read; at it, they are gone.
    function test_TheReadTurnsASlotExactlyOnTheBoundary() public {
        uint32 k = 1_000;
        harness.setWindow(id, RunwayHook.Window(k, 5, 0, 0, 0, 0, -500, 500, true)); // the oldest slot alone holds -500 and 500
        _setTick(id, 0);
        vm.roll(6);
        _warpTo((uint256(k) + 1) * SLOT - 1);
        (int24 lo, int24 hi,) = harness.windowOf(id);
        assertEq(abi.encode(lo, hi), abi.encode(int24(-500), int24(500)), "a second before the boundary dropped the oldest slot");
        _warpTo((uint256(k) + 1) * SLOT);
        (lo, hi,) = harness.windowOf(id);
        assertEq(abi.encode(lo, hi), abi.encode(int24(0), int24(0)), "the boundary did not drop the oldest slot");
    }

    /// @dev Write `t` as the tick in `pid`'s slot0 word in the PoolManager, so getSlot0 reads it back.
    function _setTick(PoolId pid, int24 t) internal {
        bytes32 s = keccak256(abi.encodePacked(PoolId.unwrap(pid), StateLibrary.POOLS_SLOT));
        vm.store(address(manager), s, bytes32(uint256(TickMath.MIN_SQRT_PRICE) | (uint256(uint24(t)) << 160)));
    }
}
