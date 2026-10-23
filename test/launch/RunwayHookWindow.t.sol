// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.36;

import {Vm, VmSafe} from "forge-std/Vm.sol";
import {console2} from "forge-std/console2.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {IHooks} from "@uniswap/v4-core/src/interfaces/IHooks.sol";
import {IPoolManager} from "@uniswap/v4-core/src/interfaces/IPoolManager.sol";
import {Hooks} from "@uniswap/v4-core/src/libraries/Hooks.sol";
import {StateLibrary} from "@uniswap/v4-core/src/libraries/StateLibrary.sol";
import {TickMath} from "@uniswap/v4-core/src/libraries/TickMath.sol";
import {PoolModifyLiquidityTest} from "@uniswap/v4-core/src/test/PoolModifyLiquidityTest.sol";
import {PoolSwapTest} from "@uniswap/v4-core/src/test/PoolSwapTest.sol";
import {BalanceDelta} from "@uniswap/v4-core/src/types/BalanceDelta.sol";
import {BeforeSwapDelta} from "@uniswap/v4-core/src/types/BeforeSwapDelta.sol";
import {PoolId, PoolIdLibrary} from "@uniswap/v4-core/src/types/PoolId.sol";
import {PoolKey} from "@uniswap/v4-core/src/types/PoolKey.sol";
import {ModifyLiquidityParams, SwapParams} from "@uniswap/v4-core/src/types/PoolOperation.sol";
import {RunwayHook} from "../../src/entities/launch/RunwayHook.sol";
import {RunwayFixture} from "./RunwayFixture.sol";
import {RunwayHookHarness} from "./RunwayHookHarness.sol";

/// @title RunwayHookWindowBase
/// @notice A launch pool behind the factory's hook on a local PoolManager, full-range liquidity, a swap router, and a reader for the hook's word.
abstract contract RunwayHookWindowBase is RunwayFixture {
    using PoolIdLibrary for PoolKey;
    using StateLibrary for IPoolManager;

    uint256 internal constant SLOT = 12 hours;
    uint160 internal constant PRICE = 1 << 96; // tick 0
    int256 internal constant LIQ = 1e21; // full-range liquidity: about 1,000e18 atoms of each side at PRICE
    uint256 internal constant NUDGE = 1e18; // an exact-input swap that moves the price about 20 ticks
    uint256 internal constant DUMP = 1e20; // one that moves it about 1,900 ticks
    bytes4 internal constant EXTSLOAD = bytes4(keccak256("extsload(bytes32)"));

    RunwayHook internal hook;
    PoolSwapTest internal swapper;
    PoolModifyLiquidityTest internal lp;
    PoolKey internal key;
    PoolId internal id;

    function setUp() public virtual override {
        super.setUp();
        hook = factory.HOOK();
        swapper = new PoolSwapTest(IPoolManager(address(manager)));
        lp = new PoolModifyLiquidityTest(IPoolManager(address(manager)));
        usdc.mint(address(this), 1e30);
        usdc.approve(address(swapper), type(uint256).max);
        usdc.approve(address(lp), type(uint256).max);
        (key, id) = _newLaunch();
    }

    /// @dev A fresh launch's pool key, its tokens in hand and approved; the pool is not open.
    function _newLaunch() internal returns (PoolKey memory k, PoolId pid) {
        Made memory m = _launch();
        strat.send(m.token, address(this), 100_000e18);
        IERC20(m.token).approve(address(swapper), type(uint256).max);
        IERC20(m.token).approve(address(lp), type(uint256).max);
        (k, pid) = (m.key, m.key.toId());
    }

    /// @dev The strategy opens `k` at `sqrtP`, as its migration does, then full-range liquidity goes in.
    function _open(PoolKey memory k, uint160 sqrtP) internal {
        strat.openPool(k, sqrtP);
        _fill(k);
    }

    function _fill(PoolKey memory k) internal {
        int24 edge = TickMath.maxUsableTick(SPACING);
        lp.modifyLiquidity(k, ModifyLiquidityParams(-edge, edge, LIQ, 0), "");
    }

    /// @dev The same pool with no hook, opened at `sqrtP` with the same liquidity.
    function _twin(PoolKey memory k, uint160 sqrtP) internal returns (PoolKey memory t) {
        t = PoolKey(k.currency0, k.currency1, k.fee, k.tickSpacing, IHooks(address(0)));
        manager.initialize(t, sqrtP);
        _fill(t);
    }

    /// @dev An exact-input swap of `amount` through `k`; `down` sells currency0, so the tick falls.
    function _swap(PoolKey memory k, bool down, uint256 amount) internal returns (BalanceDelta) {
        uint160 limit = down ? TickMath.MIN_SQRT_PRICE + 1 : TickMath.MAX_SQRT_PRICE - 1;
        return swapper.swap(k, SwapParams(down, -int256(amount), limit), PoolSwapTest.TestSettings(false, false), "");
    }

    function _tick(PoolId pid) internal view returns (int24 t) {
        (, t,,) = IPoolManager(address(manager)).getSlot0(pid);
    }

    /// @dev The hook's window for `pid`, decoded from the one word at `h`.
    function _stored(address h, PoolId pid) internal view returns (RunwayHook.Window memory w) {
        uint256 v = uint256(vm.load(h, _slotOf(pid)));
        (w.slot, w.lastBlock, w.seeded) = (uint32(v), uint48(v >> 32), ((v >> 224) & 0xff) != 0);
        (w.lo0, w.hi0) = (int24(uint24(v >> 80)), int24(uint24(v >> 104)));
        (w.lo1, w.hi1) = (int24(uint24(v >> 128)), int24(uint24(v >> 152)));
        (w.lo2, w.hi2) = (int24(uint24(v >> 176)), int24(uint24(v >> 200)));
    }

    /// @dev `_windows[pid]`: the mapping is the hook's first storage variable, everything before it immutable.
    function _slotOf(PoolId pid) internal pure returns (bytes32) {
        return keccak256(abi.encode(pid, uint256(0)));
    }

    /// @dev A seeded window with every tick at `t`.
    function _at(uint32 s, uint48 b, int24 t) internal pure returns (RunwayHook.Window memory) {
        return RunwayHook.Window(s, b, t, t, t, t, t, t, true);
    }

    function _eq(RunwayHook.Window memory a, RunwayHook.Window memory b, string memory what) internal pure {
        assertEq(abi.encode(a), abi.encode(b), what);
    }

    function _nextBlock() internal {
        vm.roll(vm.getBlockNumber() + 1);
        _warpBy(12);
    }

    /// @dev The middle of the next slot, so a row's few blocks cannot straddle a boundary.
    function _midSlot() internal {
        _warpTo((_now() / SLOT + 1) * SLOT + SLOT / 2);
        vm.roll(vm.getBlockNumber() + 1);
    }

    function _slotNow() internal view returns (uint32) {
        return uint32(_now() / SLOT);
    }

    function _block() internal view returns (uint48) {
        return uint48(vm.getBlockNumber());
    }
}

/// @title RunwayHookWindowTest
/// @notice The Runway hook's block-start window: what a swap samples, how its slots roll, what windowOf reads, and that neither path reverts.
/// @dev The fork suite runs the same hook through the deployed strategy's migration and a real launch pool.
contract RunwayHookWindowTest is RunwayHookWindowBase {
    using PoolIdLibrary for PoolKey;

    RunwayHookHarness internal harness;

    function setUp() public override {
        super.setUp();
        harness = new RunwayHookHarness(IPoolManager(address(manager)), address(strat));
    }

    // ---- the shape ----

    /// @notice The permissions are exactly before-initialize and before-swap, the address carries exactly those bits, and a slot is twelve hours.
    function test_TheShapeIsInitializeAndSwapAlone() public view {
        Hooks.Permissions memory want;
        (want.beforeInitialize, want.beforeSwap) = (true, true);
        assertEq(abi.encode(hook.getHookPermissions()), abi.encode(want), "the permissions are not the two");
        assertEq(uint160(address(hook)) & Hooks.ALL_HOOK_MASK, Hooks.BEFORE_INITIALIZE_FLAG | Hooks.BEFORE_SWAP_FLAG, "the address bits");
        assertEq(hook.SLOT(), 12 hours, "a slot is not twelve hours");
    }

    /// @notice The swap callback hands back its selector, a zero delta and no fee override, on the call that samples and the one that does not.
    function test_TheCallbackReturnsAZeroDeltaAndNoFee() public {
        _open(key, PRICE);
        SwapParams memory p = SwapParams(true, -1e18, TickMath.MIN_SQRT_PRICE + 1);
        for (uint256 i; i < 2; ++i) {
            vm.prank(address(manager));
            (bytes4 sel, BeforeSwapDelta delta, uint24 fee) = hook.beforeSwap(address(this), key, p, "");
            assertEq(sel, IHooks.beforeSwap.selector, "the selector");
            assertEq(BeforeSwapDelta.unwrap(delta), 0, "a nonzero delta");
            assertEq(fee, 0, "a fee override");
        }
        assertTrue(_stored(address(hook), id).seeded, "fixture: the first call sampled");
    }

    /// @notice A swap through the hook pays and receives exactly what the same swap does on a hookless twin, sampling or not.
    function test_ASwapMovesWhatAHooklessPoolMoves() public {
        _open(key, PRICE);
        PoolKey memory twin = _twin(key, PRICE);
        _nextBlock();
        for (uint256 i; i < 3; ++i) {
            bool down = i != 1;
            BalanceDelta a = _swap(key, down, DUMP);
            BalanceDelta b = _swap(twin, down, DUMP);
            assertEq(BalanceDelta.unwrap(a), BalanceDelta.unwrap(b), "the hook moved a swap's amounts");
        }
        assertEq(_tick(id), _tick(twin.toId()), "the two pools ended at different prices");
        assertTrue(_stored(address(hook), id).seeded, "fixture: the hook pool sampled");
    }

    // ---- sampling ----

    /// @notice A block's first swap writes the hook's one word: this block, this slot, and the tick the price stood at before the swap.
    function test_TheFirstSwapOfABlockSamplesItsPreSwapTick() public {
        _open(key, PRICE);
        _midSlot();
        _swap(key, true, NUDGE); // the pool's first sample, at tick 0
        _nextBlock();
        int24 start = _tick(id);
        assertLt(start, 0, "fixture: the first swap moved the price down");
        vm.record();
        _swap(key, true, DUMP);
        (, bytes32[] memory writes) = vm.accesses(address(hook));
        assertGt(writes.length, 0, "the block's first swap wrote nothing");
        for (uint256 i; i < writes.length; ++i) {
            assertEq(writes[i], _slotOf(id), "the swap wrote outside the pool's one word");
        }
        _eq(_stored(address(hook), id), RunwayHook.Window(_slotNow(), _block(), start, 0, 0, 0, 0, 0, true), "the stored word");
        assertLt(_tick(id), start, "fixture: the swap moved the price on");
    }

    /// @notice A later swap in the same block writes nothing: the word is byte-identical after it, whatever the swap moves.
    function test_ALaterSwapInTheBlockWritesNothing() public {
        _open(key, PRICE);
        _midSlot();
        _swap(key, true, NUDGE);
        bytes32 word = vm.load(address(hook), _slotOf(id));
        vm.record();
        _swap(key, false, DUMP);
        _swap(key, true, DUMP);
        (, bytes32[] memory writes) = vm.accesses(address(hook));
        assertEq(writes.length, 0, "a later swap in the block wrote");
        assertEq(vm.load(address(hook), _slotOf(id)), word, "the stored word moved");
    }

    /// @notice A dump and buy-back inside one block leaves no trace: the window holds the block's start, during the round trip and after it.
    function test_ASameBlockRoundTripLeavesNoSample() public {
        _open(key, PRICE);
        _midSlot();
        _swap(key, true, NUDGE); // the history: tick 0, then a price just under it
        _nextBlock();
        int24 start = _tick(id);
        BalanceDelta d = _swap(key, true, DUMP);
        int24 low = _tick(id);
        _swap(key, false, uint256(int256(d.amount1())));
        int24 back = _tick(id);
        (int24 lo, int24 hi, int24 spot) = hook.windowOf(id);
        assertEq(abi.encode(lo, hi, spot), abi.encode(start, int24(0), back), "in the block: the window is its start, spot apart");
        _nextBlock();
        (lo,,) = hook.windowOf(id);
        assertGt(lo, low, "the dump's low reached the window a block later");
        assertEq(lo, back < start ? back : start, "the next block's window is not the prices that stood at block starts");
    }

    /// @notice The first swap in the block the pool opened samples the opening price.
    function test_TheFirstSwapInTheOpeningBlockSamplesTheOpeningPrice() public {
        _open(key, TickMath.getSqrtPriceAtTick(777));
        _swap(key, true, DUMP);
        _eq(_stored(address(hook), id), _at(_slotNow(), _block(), 777), "the opening block's sample is not the opening price");
    }

    // ---- one call ----

    /// @notice Each block's first swap makes one call from the hook, an extsload of the pool's slot0 word, and a later swap makes none.
    function test_TheFirstSwapMakesOneExtsloadAndNothingElse() public {
        _open(key, PRICE);
        _nextBlock();
        bytes memory read = abi.encodeWithSelector(EXTSLOAD, keccak256(abi.encodePacked(PoolId.unwrap(id), StateLibrary.POOLS_SLOT)));
        vm.expectCall(address(manager), read, 2);
        vm.startStateDiffRecording();
        _swap(key, true, NUDGE);
        _swap(key, false, NUDGE);
        _nextBlock();
        _swap(key, true, NUDGE);
        Vm.AccountAccess[] memory a = vm.stopAndReturnStateDiff();
        assertEq(_callsBy(a, address(hook), read), 2, "the hook did not call once per block's first swap");
    }

    /// @notice The read makes the same one call and nothing else.
    function test_TheReadMakesOneExtsloadAndNothingElse() public {
        _open(key, PRICE);
        bytes memory read = abi.encodeWithSelector(EXTSLOAD, keccak256(abi.encodePacked(PoolId.unwrap(id), StateLibrary.POOLS_SLOT)));
        vm.startStateDiffRecording();
        hook.windowOf(id);
        Vm.AccountAccess[] memory a = vm.stopAndReturnStateDiff();
        assertEq(_callsBy(a, address(hook), read), 1, "the read did not call once");
    }

    /// @dev How many accesses `from` made to another account, each checked to be a staticcall of `want` on the PoolManager.
    function _callsBy(Vm.AccountAccess[] memory a, address from, bytes memory want) internal view returns (uint256 n) {
        for (uint256 i; i < a.length; ++i) {
            if (a[i].accessor != from || a[i].kind == VmSafe.AccountAccessKind.Resume) continue;
            assertEq(uint8(a[i].kind), uint8(VmSafe.AccountAccessKind.StaticCall), "an access that is not a staticcall");
            assertEq(abi.encode(a[i].account, a[i].data), abi.encode(address(manager), want), "a call that is not the extsload");
            ++n;
        }
    }

    // ---- rolling: the slot roll, row by row ----

    /// @dev A seeded window at slot 100 whose three slots are [-10, 10], [-20, 20] and [-30, 30].
    function _base() internal pure returns (RunwayHook.Window memory) {
        return RunwayHook.Window(100, 7, -10, 10, -20, 20, -30, 30, true);
    }

    function _w(uint32 s, int24 lo0, int24 hi0, int24 lo1, int24 hi1, int24 lo2, int24 hi2) internal pure returns (RunwayHook.Window memory) {
        return RunwayHook.Window(s, 7, lo0, hi0, lo1, hi1, lo2, hi2, true);
    }

    /// @notice The same slot: the tick widens the current slot's range and nothing else moves.
    function test_Roll_TheSameSlotFoldsIntoTheCurrentSlot() public view {
        _eq(harness.roll(_base(), 100, 15), _w(100, -10, 15, -20, 20, -30, 30), "a high tick in the same slot");
        _eq(harness.roll(_base(), 100, -15), _w(100, -15, 10, -20, 20, -30, 30), "a low tick in the same slot");
        _eq(harness.roll(_base(), 100, 3), _base(), "a tick inside the range");
    }

    /// @notice One slot on: the slots shift once, the tick folds into the slot it closes, and it opens the new one.
    function test_Roll_OneSlotOnShiftsOnce() public view {
        _eq(harness.roll(_base(), 101, 15), _w(101, 15, 15, -10, 15, -20, 20), "a high tick one slot on");
        _eq(harness.roll(_base(), 101, -50), _w(101, -50, -50, -50, 10, -20, 20), "a low tick one slot on");
    }

    /// @notice Two slots on: the silent slot between stood at the tick throughout, and the closed one takes the tick too.
    function test_Roll_TwoSlotsOnFillsTheSilentSlot() public view {
        _eq(harness.roll(_base(), 102, -50), _w(102, -50, -50, -50, -50, -50, 10), "a low tick two slots on");
        _eq(harness.roll(_base(), 102, 3), _w(102, 3, 3, 3, 3, -10, 10), "a tick inside the closed slot's range");
    }

    /// @notice Three or more slots on, up to the widest gap a slot index holds: every slot is the tick.
    function test_Roll_ThreeOrMoreSlotsOnRestartAtTheTick() public view {
        _eq(harness.roll(_base(), 103, 7), _w(103, 7, 7, 7, 7, 7, 7), "three slots on");
        _eq(harness.roll(_base(), type(uint32).max, 7), _w(type(uint32).max, 7, 7, 7, 7, 7, 7), "the widest gap");
    }

    /// @notice A stored slot ahead of now reads as no gap: the tick folds into the current slot, and the slot stays where it was.
    function test_Roll_AStoredSlotAheadOfNowIsNoGap() public view {
        _eq(harness.roll(_base(), 99, 15), _w(100, -10, 15, -20, 20, -30, 30), "one slot behind");
        _eq(harness.roll(_base(), 0, -15), _w(100, -15, 10, -20, 20, -30, 30), "slot zero");
    }

    /// @notice An unseeded window starts at the tick, whatever its word held, and the roll never moves the block.
    function test_Roll_AnUnseededWindowStartsAtTheTick() public view {
        RunwayHook.Window memory junk = RunwayHook.Window(4_000_000_000, 7, 1, 2, 3, 4, 5, 6, false);
        _eq(harness.roll(junk, 12, -9), _w(12, -9, -9, -9, -9, -9, -9), "an unseeded window");
    }

    /// @notice A slot turns exactly on a twelve-hour boundary: a second before it is the old slot, the boundary itself the new one.
    function test_TheSlotTurnsExactlyOnTheTwelveHourBoundary() public {
        _open(key, PRICE);
        uint256 k = _now() / SLOT + 3;
        if (k % 2 == 0) ++k; // odd, so its start is no whole-day boundary
        _warpTo(k * SLOT - 1);
        vm.roll(vm.getBlockNumber() + 1);
        _swap(key, true, NUDGE); // the pool's first sample, at tick 0
        assertEq(_stored(address(hook), id).slot, k - 1, "a second before the boundary is not the old slot");
        int24 held = _tick(id);
        _warpTo(k * SLOT);
        vm.roll(vm.getBlockNumber() + 1);
        _swap(key, true, NUDGE);
        _eq(_stored(address(hook), id), RunwayHook.Window(uint32(k), _block(), held, held, held, 0, 0, 0, true), "the boundary did not roll one slot");
    }

    // ---- carry-forward ----

    /// @notice A pool silent for years reads as its held price: every slot it crossed stood at that price at every block start.
    function test_APoolSilentForYearsReadsAsItsHeldPrice() public {
        _open(key, PRICE);
        _midSlot();
        _swap(key, true, DUMP);
        int24 held = _tick(id);
        _warpBy(3 * 365 days);
        vm.roll(vm.getBlockNumber() + 8_000_000);
        (int24 lo, int24 hi, int24 spot) = hook.windowOf(id);
        assertEq(abi.encode(lo, hi, spot), abi.encode(held, held, held), "the read is not the held price");
        _swap(key, false, NUDGE);
        _eq(_stored(address(hook), id), _at(_slotNow(), _block(), held), "the sample after the silence is not the held price");
        (lo, hi, spot) = hook.windowOf(id);
        assertEq(abi.encode(lo, hi), abi.encode(held, held), "the in-block swap reached the window");
        assertGt(spot, held, "fixture: the swap moved spot");
    }

    /// @notice After a silent slot, a pump in the current block cannot lift the window: its high stays the held price, the pump is spot alone.
    /// @notice A pump held to the next block's start does enter it: the window is what stood at block starts.
    function test_APumpAfterASilentSlotCannotLiftTheWindow() public {
        _open(key, PRICE);
        _midSlot();
        _swap(key, false, NUDGE); // samples 0, then holds just above it
        int24 held = _tick(id);
        _warpBy(2 * SLOT);
        _nextBlock();
        _swap(key, false, DUMP); // the pump, this block's first swap
        int24 pumped = _tick(id);
        assertGt(pumped, held, "fixture: the pump moved the price up");
        (int24 lo, int24 hi, int24 spot) = hook.windowOf(id);
        assertEq(abi.encode(lo, hi, spot), abi.encode(int24(0), held, pumped), "the pump lifted the window");
        _nextBlock();
        (, hi,) = hook.windowOf(id);
        assertEq(hi, pumped, "a pump held to the next block start is not in the window");
    }

    // ---- the read ----

    /// @notice The read is the block-start window: a swap earlier in the block moves spot, never lo or hi.
    function test_TheReadIgnoresAnInBlockSwapAndReturnsSpotApart() public {
        _open(key, PRICE);
        _midSlot();
        _swap(key, true, NUDGE); // samples 0
        _nextBlock();
        int24 start = _tick(id);
        (int24 lo, int24 hi, int24 spot) = hook.windowOf(id);
        assertEq(abi.encode(lo, hi, spot), abi.encode(start, int24(0), start), "before a swap, the block's start is spot");
        _swap(key, true, DUMP);
        (int24 lo2, int24 hi2, int24 spot2) = hook.windowOf(id);
        assertEq(abi.encode(lo2, hi2), abi.encode(lo, hi), "an in-block swap moved the window");
        assertEq(spot2, _tick(id), "spot is not the pool's tick");
        assertLt(spot2, lo, "fixture: the swap took spot under the window");
    }

    /// @notice A window this block sampled reads as its three slots' lowest low and highest high, and spot apart, whatever spot is.
    function testFuzz_TheReadIsTheThreeSlotsExtremes(RunwayHook.Window memory w, int24 t) public {
        (w.seeded, w.lastBlock) = (true, _block());
        harness.setWindow(id, w);
        _setTick(id, t);
        (int24 lo, int24 hi, int24 spot) = harness.windowOf(id);
        int24 low = w.lo0 < w.lo1 ? w.lo0 : w.lo1;
        int24 high = w.hi0 > w.hi1 ? w.hi0 : w.hi1;
        (low, high) = (low < w.lo2 ? low : w.lo2, high > w.hi2 ? high : w.hi2);
        assertEq(abi.encode(lo, hi, spot), abi.encode(low, high, t), "the read is not the three slots' extremes");
    }

    /// @notice A pool that never swapped reads as its opening price throughout.
    function test_AnUnseededPoolReadsAsSpot() public {
        _open(key, TickMath.getSqrtPriceAtTick(-4321));
        (int24 lo, int24 hi, int24 spot) = hook.windowOf(id);
        assertEq(abi.encode(lo, hi, spot), abi.encode(int24(-4321), int24(-4321), int24(-4321)), "an unseeded pool read other than spot");
    }

    /// @notice A key never opened reads zero throughout, so a reader must check the pool's liveness itself.
    function test_AnUnopenedKeyReadsZero() public view {
        (int24 lo, int24 hi, int24 spot) = hook.windowOf(id);
        assertEq(abi.encode(lo, hi, spot), abi.encode(int24(0), int24(0), int24(0)), "an unopened key read other than zero");
    }

    // ---- never revert ----

    /// @notice The roll never reverts, for any stored word, slot and int24 tick, and always leaves the tick inside the current slot.
    function testFuzz_RollNeverReverts(RunwayHook.Window memory w, uint32 k, int24 t) public view {
        RunwayHook.Window memory r = harness.roll(w, k, t);
        assertTrue(r.seeded, "the roll left the window unseeded");
        assertTrue(r.lo0 <= t && t <= r.hi0, "the tick is outside the current slot");
        assertEq(r.lastBlock, w.lastBlock, "the roll moved the block");
    }

    /// @notice The roll is the ruled cases exactly: unseeded, one slot on, two, three or more, and the same slot or one ahead.
    function testFuzz_RollIsTheRuledCases(RunwayHook.Window memory w, uint8 gap, uint32 other, int24 t) public view {
        uint32 k;
        unchecked {
            k = gap < 5 ? w.slot + gap : gap < 8 ? w.slot - (gap - 4) : other;
        }
        _eq(harness.roll(w, k, t), _ruled(w, k, t), "the roll is not the ruled case");
    }

    /// @dev The roll as ruled, case by case: the reference the hook's roll is checked against.
    function _ruled(RunwayHook.Window memory w, uint32 k, int24 t) internal pure returns (RunwayHook.Window memory) {
        if (!w.seeded) return RunwayHook.Window(k, w.lastBlock, t, t, t, t, t, t, true);
        (int24 lo, int24 hi) = (w.lo0 < t ? w.lo0 : t, w.hi0 > t ? w.hi0 : t);
        if (k <= w.slot) return RunwayHook.Window(w.slot, w.lastBlock, lo, hi, w.lo1, w.hi1, w.lo2, w.hi2, true);
        if (k - w.slot == 1) return RunwayHook.Window(k, w.lastBlock, t, t, lo, hi, w.lo1, w.hi1, true);
        if (k - w.slot == 2) return RunwayHook.Window(k, w.lastBlock, t, t, t, t, lo, hi, true);
        return RunwayHook.Window(k, w.lastBlock, t, t, t, t, t, t, true);
    }

    /// @notice The read never reverts, for any stored word, slot0 tick, time and block, and folds spot in whenever this block has not sampled.
    function testFuzz_WindowOfNeverReverts(RunwayHook.Window memory w, int24 t, uint256 time, uint256 blk) public {
        harness.setWindow(id, w);
        _setTick(id, t);
        _warpTo(time);
        vm.roll(blk);
        (int24 lo, int24 hi, int24 spot) = harness.windowOf(id);
        assertEq(spot, t, "spot is not slot0's tick");
        if (!w.seeded || w.lastBlock != uint48(blk)) assertTrue(lo <= t && t <= hi, "a stale window left spot out");
    }

    /// @notice The write never reverts either: for any stored word, slot0 tick, time and block it returns zeroes and leaves this block sampled.
    function testFuzz_BeforeSwapNeverReverts(RunwayHook.Window memory w, int24 t, uint256 time, uint256 blk) public {
        harness.setWindow(id, w);
        _setTick(id, t);
        _warpTo(time);
        vm.roll(blk);
        vm.prank(address(manager));
        (bytes4 sel, BeforeSwapDelta delta, uint24 fee) = harness.beforeSwap(address(this), key, SwapParams(true, -1, 0), "");
        assertEq(abi.encode(sel, BeforeSwapDelta.unwrap(delta), fee), abi.encode(IHooks.beforeSwap.selector, int256(0), uint24(0)), "the returns");
        RunwayHook.Window memory s = harness.windowAt(id);
        assertTrue(s.seeded && s.lastBlock == uint48(blk), "the block did not sample");
        if (w.seeded && w.lastBlock == uint48(blk)) _eq(s, w, "a block that had sampled wrote again");
        else assertTrue(s.lo0 <= t && t <= s.hi0, "the sample is not slot0's tick");
    }

    /// @dev Write `t` as the tick in `pid`'s slot0 word in the PoolManager, so getSlot0 reads it back.
    function _setTick(PoolId pid, int24 t) internal {
        bytes32 s = keccak256(abi.encodePacked(PoolId.unwrap(pid), StateLibrary.POOLS_SLOT));
        vm.store(address(manager), s, bytes32(uint256(TickMath.MIN_SQRT_PRICE) | (uint256(uint24(t)) << 160)));
    }

    /// @notice Fixture: the decoder this suite reads the hook's word with is the hook's own layout.
    function testFuzz_TheDecoderReadsTheStoredWindow(RunwayHook.Window memory w) public {
        harness.setWindow(id, w);
        _eq(_stored(address(harness), id), w, "the decoder disagrees with the hook's layout");
        _eq(harness.windowAt(id), w, "the window did not store whole");
    }

    // ---- gas ----

    /// @notice What the hook adds to a swap, each swap its own transaction, against a hookless twin taking the same swap.
    /// @notice A pool's first swap writes a fresh word, a block's first rewrites it, and a later swap only reads it.
    /// @dev forge-config: default.isolate = true
    /// @dev forge-config: deploy.isolate = true
    function test_Gas_TheHookOnASwap() public {
        _open(key, PRICE);
        PoolKey memory twin = _twin(key, PRICE);
        (PoolKey memory fresh,) = _newLaunch();
        _open(fresh, PRICE);
        PoolKey memory freshTwin = _twin(fresh, PRICE);
        _nextBlock();
        uint256 poolFirst = _overhead(fresh, freshTwin);
        _overhead(key, twin); // the pool's first sample, not measured
        _nextBlock();
        uint256 blockFirst = _overhead(key, twin);
        uint256 later = _overhead(key, twin);
        console2.log("hook gas on a pool's first swap", poolFirst);
        console2.log("hook gas on a block's first swap", blockFirst);
        console2.log("hook gas on a later swap in the block", later);
        assertLe(poolFirst, 32_000, "a pool's first swap pays more than one fresh word");
        assertLe(blockFirst, 15_000, "a block's first swap pays more than one rewrite");
        assertLe(later, 9_000, "a later swap pays more than one cold read");
        assertGt(blockFirst, later, "the sample cost nothing");
    }

    /// @dev The hooked swap's gas over the twin's, the same swap on both so the two pools stay in step.
    function _overhead(PoolKey memory k, PoolKey memory twin) internal returns (uint256) {
        _swap(k, true, NUDGE);
        uint256 hooked = vm.lastCallGas().gasTotalUsed;
        _swap(twin, true, NUDGE);
        return hooked - vm.lastCallGas().gasTotalUsed;
    }
}
