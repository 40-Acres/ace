// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.36;

import {WarpClock} from "../utils/WarpClock.sol";
import {PersistenceRecord} from "../utils/PersistenceRecord.sol";
import {PriceFrame} from "../utils/PriceFrame.sol";

/// @title PersistenceRecordWindowsTest
/// @notice The record owns its windows: both are constructor immutables, and every ex-genesis rail is now a ctor rail.
/// @notice It also pins the two-window surface, where one wrong wiring makes distress and settlement the same question.
/// @dev Deterministic steps: volRefBps 0 floors the denominator, so an observe at the floor volume takes the full cap.
/// @dev A full 100% cap then lets one bucket carry a price anywhere, so a fixture states the price it wants.
contract PersistenceRecordWindowsTest is WarpClock {
    PersistenceRecord internal rec;

    uint256 internal constant TRUNC_BPS = 10000; // full cap: one bucket may carry the price to its target
    uint64 internal constant INTERVAL = 60;
    uint256 internal constant CAP = 64; // (64-1)*60 = 3780s of reach, comfortably over the settle window
    uint256 internal constant VOL = 1e18; // == VOL_REF_FLOOR, so every observe earns the full cap
    address internal constant FQ = address(0x9001); // record-only suite: the declared pair is two placeholders
    address internal constant FC = address(0xC011);

    uint256 internal constant P = 600; // 10 buckets
    uint64 internal constant PENDING = 600; // settle window is 1200: 20 buckets
    uint256 internal constant DEPTH_W = 300; // under P, as R4 requires

    uint256 internal START;

    function setUp() public {
        _warpTo(1_000_000);
        START = PriceFrame.px(1e18, FQ, FC);
        rec = _record(P, PENDING, INTERVAL, CAP, DEPTH_W);
    }

    function _record(uint256 p, uint64 pending, uint64 interval, uint256 cap, uint256 depthWindow) internal returns (PersistenceRecord) {
        return new PersistenceRecord(
            PersistenceRecord.Config({
                writer: address(this),
                truncCapBps: TRUNC_BPS,
                initialPrice: START,
                obsInterval: interval,
                volRefFloor: VOL,
                obsCap: cap,
                unitScale: 1 << 96,
                volRefBps: 0,
                depthWindow: depthWindow,
                quote: FQ,
                collateral: FC,
                persistenceWindow: p,
                pendingWindow: pending
            })
        );
    }

    /// @dev One bucket roll carrying `price`: the boundary rolls, then the observe lands in the fresh bucket.
    function _rollTo(uint256 price) internal {
        _warpBy(INTERVAL);
        rec.observe(price, VOL);
    }

    function _rollMany(uint256 n, uint256 price) internal {
        for (uint256 i; i < n; i++) {
            _rollTo(price);
        }
    }

    // --- the windows are the record's own ---

    /// @notice Both windows read back verbatim, and the settle window is their sum computed once.
    function test_Windows_ReadBackAndSettleIsTheSum() public view {
        assertEq(rec.PERSISTENCE_WINDOW(), P, "persistence window");
        assertEq(rec.PENDING_WINDOW(), PENDING, "pending window");
        assertEq(rec.SETTLE_WINDOW(), P + PENDING, "settle window is persistence + pending");
    }

    // --- THE test: the two below-questions must not be wired to one window ---

    /// @notice A break newer than the settle window but older than the distress window: distress TRUE, settle FALSE.
    /// @dev THE straddle. It is the only test that fails when both members are wired to the same window.
    /// @dev Every other test in the tree passes under that bug, because no other fixture sits between the two windows.
    function test_Straddle_DistressHoldsWhileSettleDoesNot() public {
        uint256 x = START; // the level: the drop below is what starts both clocks
        _rollMany(25, START); // a warm ring, well above the level
        _rollMany(11, START - 1); // 11 buckets below x: past P (10 buckets), short of settle (20)
        assertTrue(rec.persistedBelowDistress(FQ, FC, x), "11 buckets below covers the 10-bucket distress window");
        assertFalse(rec.persistedBelowSettle(FQ, FC, x), "11 buckets below cannot cover the 20-bucket settle window");
    }

    /// @notice Past the settle window the same break answers TRUE on both.
    /// @dev The other side of the straddle, so the first test cannot pass by a member that is always false.
    function test_Straddle_PastTheSettleWindowBothHold() public {
        uint256 x = START;
        _rollMany(25, START);
        _rollMany(21, START - 1); // past the 20-bucket settle window
        assertTrue(rec.persistedBelowDistress(FQ, FC, x), "distress holds");
        assertTrue(rec.persistedBelowSettle(FQ, FC, x), "settle holds once the break covers the longer window");
    }

    /// @notice `minPrice` answers over the record's own persistence window, with no argument to disagree about.
    function test_MinPrice_IsTakenOverThePersistenceWindow() public {
        _rollMany(25, START);
        _rollTo(START - 5); // one dip, inside the distress window
        assertEq(rec.minPrice(FQ, FC), START - 5, "the windowed minimum includes the dip");
        _rollMany(11, START); // roll the dip out of the 10-bucket window
        assertEq(rec.minPrice(FQ, FC), START, "past the window the dip no longer counts");
    }

    // --- the ctor rails, at their boundaries ---

    /// @notice R5: a window under the block-time floor is refused, whatever the bucket width.
    /// @dev The case R1 alone admits: at a one-second bucket R1's floor is two seconds, under one block.
    function test_R5_RefusesAWindowUnderTheBlockTimeFloor() public {
        uint256 floorW = rec.MIN_PERSISTENCE_WINDOW();
        vm.expectRevert(PersistenceRecord.BadParams.selector);
        _record(floorW - 1, PENDING, 1, 100000, 0);
        rec = _record(floorW, 1, 1, 100000, 0); // the floor itself admits
        assertEq(rec.PERSISTENCE_WINDOW(), floorW, "the floor itself is a legal window");
    }

    /// @notice R1: the window must cover two bucket widths, so a live pool is not refused for most of each bucket.
    function test_R1_RefusesAWindowUnderTwoBucketWidths() public {
        uint64 wide = 400; // 2*400 = 800 > MIN_PERSISTENCE_WINDOW, so R1 is the binding rail here
        vm.expectRevert(PersistenceRecord.BadParams.selector);
        _record(2 * uint256(wide) - 1, PENDING, wide, CAP, 0);
        rec = _record(2 * uint256(wide), PENDING, wide, CAP, 0);
        assertEq(rec.PERSISTENCE_WINDOW(), 2 * uint256(wide), "exactly two bucket widths is legal");
    }

    /// @notice R2: zero grace is refused, as the hub's `grace zero` rail refused it.
    function test_R2_RefusesZeroPendingWindow() public {
        vm.expectRevert(PersistenceRecord.BadParams.selector);
        _record(P, 0, INTERVAL, CAP, DEPTH_W);
    }

    /// @notice R3: the ring must reach the SETTLE window, the sum, because the settle read walks it.
    /// @dev Was the genesis span interview; both operands are now this constructor's own arguments.
    function test_R3_RefusesASettleWindowPastTheRingReach() public {
        uint256 span = (CAP - 1) * INTERVAL;
        vm.expectRevert(PersistenceRecord.BadParams.selector);
        _record(span, uint64(1), INTERVAL, CAP, 0); // span + 1 in total
        rec = _record(span - 1, uint64(1), INTERVAL, CAP, 0); // exactly the span admits
        assertEq(rec.SETTLE_WINDOW(), span, "a settle window exactly at the ring reach is legal");
    }

    /// @notice R4: the depth window must sit inside the blackout, else borrowing stays live past the feed's maturity.
    function test_R4_RefusesADepthWindowPastThePersistenceWindow() public {
        vm.expectRevert(PersistenceRecord.BadParams.selector);
        _record(P, PENDING, INTERVAL, CAP, P + 1);
        rec = _record(P, PENDING, INTERVAL, CAP, P); // equality admits
        assertEq(rec.DEPTH_WINDOW(), P, "a depth window exactly at the blackout is legal");
    }

    // --- what the hub no longer bounds ---

    /// @notice A window past the deleted hub ceiling is constructible: the bound is the ring's reach now.
    /// @dev The accepted consequence of the offboarding, pinned so its removal is deliberate rather than noticed later.
    function test_NoHubCeiling_AWindowPastTheOldMaximumIsLegal() public {
        uint256 wide = 2 days; // over the deleted MAX_PERSISTENCE_WINDOW of 1 day
        rec = _record(wide, 1 hours, 1 hours, 100, 0);
        assertEq(rec.PERSISTENCE_WINDOW(), wide, "nothing bounds the window but the record's own reach");
    }
}
