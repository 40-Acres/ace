// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.36;

import {FullMath} from "@uniswap/v4-core/src/libraries/FullMath.sol";
import {WarpClock} from "../utils/WarpClock.sol";
import {Ace} from "../../src/ace/hub/Ace.sol";
import {InsufficientCash} from "../../src/ace/hub/Borrower.sol";
import {BelowMinLot, WouldLeaveDust} from "../../src/ace/hub/Lender.sol";
import {LoanMath} from "../../src/ace/hub/libraries/LoanMath.sol";
import {MarketParams, OpenBounds} from "../../src/ace/hub/Types.sol";
import {PositionManager} from "../../src/ace/positions/PositionManager.sol";
import {MockERC20} from "../mocks/MockERC20.sol";
import {MockPersistenceRecord} from "../mocks/MockPersistenceRecord.sol";
import {AceFixtures} from "../utils/AceFixtures.sol";
import {AceReader} from "../utils/AceReader.sol";

/// @title AceS12StaleReservation
/// @notice Phase 12 (sequences), run 2026-10-03-251533, finding F1.
/// @notice WRITER `setAutoRefinance` sizes a reservation at the ARM-TIME debt; WRITER `repay` then lowers the debt and leaves it.
/// @notice READER `cashAdmits` (every other fresh draw) cannot tell a reservation a live roll needs from one a repay left stale.
/// @notice So arm-then-repay kept `rollNeed(D, armTenor)` reserved behind a one-atom loan, where repay-then-arm reserves `minDebt - 1`.
/// @notice FIXED (Y-10): a partial repay shrinks the share to its roll's need at the new debt, so both orders hold `minDebt - 1`.
/// @dev ACCEPTED residual: a loan repaid to one atom and withdrawn to its line keeps that `minDebt - 1`, what repay-then-arm reserves.
/// @dev Each leg is proved alone first, then the ordered pair.
contract AceS12StaleReservation is WarpClock {
    Ace internal ace;
    AceReader internal read;
    PositionManager internal pm;
    MockERC20 internal usdc;
    MockERC20 internal coll;
    MockPersistenceRecord internal rec;
    bytes32 internal id; // the shipped launch shape: 7d to 30d terms
    bytes32 internal wide; // the same lender and pair at 7d to 364d, near the fee-share corner

    address internal alice = address(0xA11CE); // the market's one lender
    address internal griefer = address(0x6E1EF); // an ordinary borrower with no stake in alice's book
    address internal honest = address(0xB0B); // a later borrower the reservation stands in front of

    uint64 internal constant TEN7 = 7 days;
    uint64 internal constant TEN30 = 30 days;
    uint64 internal constant TEN364 = 364 days;
    uint256 internal constant C = 1_000_000e6; // alice's resting cash in each market
    uint256 internal constant D = 400_000e6; // the griefer's one-transaction draw
    uint256 internal constant UNITS = 800_000e18; // trigger at 0.7 of par

    function setUp() public {
        _warpTo(1_000_000);
        usdc = new MockERC20("USD Coin", "USDC", 6);
        coll = new MockERC20("Collateral", "COLL", 18);
        rec = new MockPersistenceRecord(address(usdc), address(coll));
        rec.setMinPrice(AceFixtures.px(1.1e18, address(usdc), address(coll)));
        AceFixtures.Deployment memory d = AceFixtures.deploy(_params(TEN30));
        (ace, pm, read, id) = (d.ace, d.positionManager, d.read, d.id);
        wide = ace.createMarket(_params(TEN364));

        usdc.mint(alice, 2 * C);
        vm.startPrank(alice);
        usdc.approve(address(ace), type(uint256).max);
        ace.deposit(id, C);
        ace.deposit(wide, C);
        vm.stopPrank();

        coll.mint(griefer, 4 * UNITS);
        usdc.mint(griefer, 50_000e6); // enough quote to cover the fee its repay owes on top of the payout
        vm.startPrank(griefer);
        coll.approve(address(pm), type(uint256).max);
        usdc.approve(address(ace), type(uint256).max);
        vm.stopPrank();

        coll.mint(honest, 10 * UNITS);
        vm.prank(honest);
        coll.approve(address(pm), type(uint256).max);
    }

    function _params(uint64 maxTenor) internal view returns (MarketParams memory p) {
        p = AceFixtures.marketParams(address(usdc), address(coll));
        p.record = address(rec);
        p.lender = alice;
        p.baseBps = 40;
        p.minTenor = TEN7;
        p.maxTenor = maxTenor;
        p.settleBountyBps = 50;
        p.minCoverageWad = 1.4e18;
        p.minDebt = 5_000e6; // the shipped floor, so the repay-then-arm bound reads at its real size
    }

    /// @dev The hub's own sizing rule, re-derived here from `LoanMath`: the fresh cash an expiry roll of `debt` draws.
    function _need(bytes32 m, uint256 debt, uint64 tenor) internal view returns (uint256) {
        MarketParams memory p = ace.idToMarketParams(m);
        uint256 succ = LoanMath.principalForOwed(debt, tenor, p.baseBps, p.minTenor);
        if (succ < p.minDebt) succ = p.minDebt;
        return succ > debt ? succ - debt : 0;
    }

    /// @dev The coverage line for `debt` at the market's price, as `Borrower.coverageLine` spells it (the record sits above par).
    function _line(bytes32 m, uint256 debt) internal view returns (uint256) {
        MarketParams memory p = ace.idToMarketParams(m);
        return FullMath.mulDivRoundingUp(p.minCoverageWad * debt, 1 << 96, p.price * 1e18) + 1;
    }

    function _open(bytes32 m, uint256 principal) internal returns (uint256 loanId) {
        vm.prank(griefer);
        loanId = ace.open(m, UNITS, principal, TEN7, griefer, OpenBounds(0, 0, 0));
    }

    function _arm(uint256 loanId, uint64 tenor) internal {
        vm.prank(griefer);
        ace.setAutoRefinance(loanId, tenor, 1000, 0);
    }

    /// @dev The borrower's own repay into `(0, minDebt)`, then its collateral back down to the one-atom line.
    function _shrink(bytes32 m, uint256 loanId) internal {
        vm.startPrank(griefer);
        ace.repay(loanId, read.debtOf(loanId) - 1);
        ace.withdrawCollateral(loanId, read.loan(loanId).collateralUnits - _line(m, 1), griefer);
        vm.stopPrank();
    }

    /// @notice LEG A ALONE: arming reserves exactly the expiry roll's need of the debt it arms at.
    function test_LegA_ArmingReservesTheNeedOfTheArmedDebt() public {
        uint256 loanId = _open(id, D);
        uint256 before = ace.drawableOf(id);
        _arm(loanId, TEN30);
        assertEq(read.reservedOf(loanId), _need(id, D, TEN30), "the reservation is rollNeed at the arm-time debt and arm tenor");
        assertEq(before - ace.drawableOf(id), read.reservedOf(loanId), "and it leaves every other draw's reach whole");
    }

    /// @notice LEG B ALONE: the borrower may repay its own loan into `(0, minDebt)` and take its collateral to the line; no reservation.
    function test_LegB_ARepayAndWithdrawAloneLandAndReserveNothing() public {
        uint256 loanId = _open(id, D);
        _shrink(id, loanId);
        assertEq(read.debtOf(loanId), 1, "the borrower repaid to one atom");
        assertEq(read.loan(loanId).collateralUnits, _line(id, 1), "and withdrew to the one-atom line");
        assertEq(read.reservedOf(loanId), 0, "an unarmed loan reserves nothing");
        assertEq(read.rollReserve(id), 0, "and the market holds nothing back");
    }

    /// @notice CONTROL, the other order: repay first, then arm, and the reservation is the floor's, `minDebt - 1`.
    /// @dev This is the bound phase 9's dismissal 1 recorded for the dust-loan arm; it holds in THIS order only.
    function test_Control_RepayThenArmReservesOnlyUpToTheFloor() public {
        uint256 loanId = _open(id, D);
        _shrink(id, loanId);
        _arm(loanId, TEN30);
        uint256 md = ace.idToMarketParams(id).minDebt;
        assertEq(read.reservedOf(loanId), md - 1, "repay then arm reserves minDebt - 1");
    }

    /// @notice The pair: arm then repay SHRINKS the reservation to the one-atom loan's own need, `minDebt - 1`.
    /// @notice The market's lender restores the drained cash, and a fresh draw sized to that correct share lands.
    function test_ArmThenRepayShrinksTheShareToTheLoansOwnNeed() public {
        uint256 bal0 = usdc.balanceOf(griefer);
        uint256 loanId = _open(id, D);
        _arm(loanId, TEN30);
        uint256 armed = read.reservedOf(loanId);
        _shrink(id, loanId);

        uint256 md = ace.idToMarketParams(id).minDebt;
        assertEq(_need(id, 1, TEN30), md - 1, "the loan's own expiry roll now needs the floor's remainder");
        assertGt(armed, md - 1, "PREMISE: the arm reserved more than that");
        assertEq(read.reservedOf(loanId), md - 1, "and the repay shrank the reservation to exactly it");
        assertEq(read.rollReserve(id), md - 1, "the market's reserve fell with it, to the atom");
        uint256 cost = bal0 - usdc.balanceOf(griefer);
        emit log_named_uint("reservation held behind a 1-atom loan (USDC atoms)", read.reservedOf(loanId));
        emit log_named_uint("collateral the griefer leaves in custody (atoms)", read.loan(loanId).collateralUnits);
        emit log_named_uint("griefer's whole quote cost (USDC atoms)", cost);

        // alice collects the drained principal and rests it again: the drain was hers to undo, and now so is the excess share
        vm.startPrank(alice);
        uint256 got = ace.collect(address(usdc), alice);
        ace.deposit(id, got);
        vm.stopPrank();
        uint256 resting = ace.restingOf(id);
        uint256 fair = resting - (md - 1); // what a reservation sized to this loan's own roll leaves drawable
        assertEq(ace.drawableOf(id), fair, "a fresh draw sees only the loan's own need held back");
        vm.prank(honest);
        ace.open(id, 10 * UNITS, fair, TEN7, honest, OpenBounds(0, 0, 0));
    }

    /// @notice ATOMIC: the four legs in ONE multicall; the griefer ends holding a one-atom loan, dust collateral, and the floor's share.
    function test_TheSequenceIsOneMulticall() public {
        uint256 next = read.loanCount() + 1; // the griefer's own batch; the id race is phase 9 F1's and not this row's
        bytes[] memory calls = new bytes[](4);
        calls[0] = abi.encodeCall(Ace.open, (id, UNITS, D, TEN7, griefer, OpenBounds(0, 0, 0)));
        calls[1] = abi.encodeCall(Ace.setAutoRefinance, (next, TEN30, 1000, 0));
        calls[2] = abi.encodeCall(Ace.repay, (next, D - 1));
        calls[3] = abi.encodeCall(Ace.withdrawCollateral, (next, UNITS - _line(id, 1), griefer));
        vm.prank(griefer);
        ace.multicall(calls);
        assertEq(read.debtOf(next), 1, "one atom of debt");
        assertEq(read.loan(next).collateralUnits, _line(id, 1), "on the one-atom line");
        assertEq(read.reservedOf(next), ace.idToMarketParams(id).minDebt - 1, "holding only the floor's share, not a 400k loan's");
    }

    /// @notice The fee corner: a 7d-364d market armed at the long tenor still keeps only the floor's share after the repay.
    /// @dev Was 67x the griefer's cost; the residual is now `minDebt - 1` whatever the arm tenor, about 2.8x the cost here.
    function test_AWideTenorMarketKeepsOnlyTheFloorsShare() public {
        uint256 bal0 = usdc.balanceOf(griefer);
        uint256 loanId = _open(wide, D);
        _arm(loanId, TEN364);
        uint256 armed = read.reservedOf(loanId);
        _shrink(wide, loanId);
        uint256 held = read.reservedOf(loanId);
        uint256 cost = bal0 - usdc.balanceOf(griefer);
        emit log_named_uint("wide market: reservation armed (USDC atoms)", armed);
        emit log_named_uint("wide market: reservation held after the repay (USDC atoms)", held);
        emit log_named_uint("wide market: griefer's quote cost (USDC atoms)", cost);
        emit log_named_uint("reservation per unit of cost (x100)", held * 100 / cost);
        assertEq(held, ace.idToMarketParams(wide).minDebt - 1, "the long tenor's share shrank to the floor's remainder");
        assertLt(held, 3 * cost, "so what is held stays within a few times what it cost");
    }

    /// @notice The floor's residual share outlives the loan's expiry, and no keeper is paid to end it.
    /// @notice The fold pays a sliver sized off DEBT, which is one atom, so the paid door pays nothing here.
    function test_TheResidualShareOutlivesExpiryAndNoKeeperIsPaidToEndIt() public {
        uint256 loanId = _open(id, D);
        _arm(loanId, TEN30);
        _shrink(id, loanId);
        uint256 held = read.reservedOf(loanId);
        assertEq(held, ace.idToMarketParams(id).minDebt - 1, "PREMISE: the repay shrank the share to the floor's remainder");
        _warpTo(uint256(read.loan(loanId).expiry) + 1 days);
        assertEq(read.reservedOf(loanId), held, "still held a day past expiry: nothing but a crank releases it");

        address keeper = address(0xCAFE);
        vm.prank(keeper);
        ace.forceClose(loanId);
        assertTrue(ace.isClosed(loanId), "the crank settles it: a floor-sized successor is inadmissible on dust collateral");
        uint256 sliver = read.unitsOwedOf(loanId, keeper);
        uint256 worth = FullMath.mulDiv(sliver, ace.idToMarketParams(id).price, 1 << 96);
        emit log_named_uint("keeper's sliver (collateral atoms)", sliver);
        assertEq(worth, 0, "and paid the keeper less than one quote atom for it");
        assertEq(read.rollReserve(id), 0, "only then is the reservation released");
    }
}

/// @title AceS12ReserveFloorRace
/// @notice Phase 12 (sequences), run 2026-10-03-251533, seed pair S18, VERIFIED.
/// @notice WRITER `setAutoRefinance` (arm, disarm) moves `rollReserve`; READER the lender doors' unreserved-dust tests.
/// @notice Both directions exist: an arm or disarm refuses a pending lender withdraw or refill, and an arm admits a withdraw the floor refuses.
/// @dev Every outcome is a REVERT the lender retries, or unreserved dust a close's release already produces with no lender act.
/// @dev GREEN rows. Two actors, so this is a race (units 7 and 9), recorded here because the seed table asked for it.
contract AceS12ReserveFloorRace is WarpClock {
    Ace internal ace;
    AceReader internal read;
    PositionManager internal pm;
    MockERC20 internal usdc;
    MockERC20 internal coll;
    MockPersistenceRecord internal rec;
    bytes32 internal id;

    address internal alice = address(0xA11CE);
    address internal borrower = address(0xB0B);

    uint64 internal constant TEN7 = 7 days;
    uint256 internal constant P = 50_000e6;
    uint256 internal constant UNITS = 100_000e18;

    uint256 internal loanId;
    uint256 internal md;
    uint256 internal r; // the reservation an arm of `loanId` takes

    function setUp() public {
        _warpTo(1_000_000);
        usdc = new MockERC20("USD Coin", "USDC", 6);
        coll = new MockERC20("Collateral", "COLL", 18);
        rec = new MockPersistenceRecord(address(usdc), address(coll));
        rec.setMinPrice(AceFixtures.px(1.1e18, address(usdc), address(coll)));
        MarketParams memory p = AceFixtures.marketParams(address(usdc), address(coll));
        p.record = address(rec);
        p.lender = alice;
        p.baseBps = 40;
        p.minTenor = TEN7;
        p.maxTenor = TEN7;
        p.settleBountyBps = 50;
        p.minCoverageWad = 1.4e18;
        p.minDebt = 5_000e6;
        AceFixtures.Deployment memory d = AceFixtures.deploy(p);
        (ace, pm, read, id) = (d.ace, d.positionManager, d.read, d.id);
        md = p.minDebt;

        usdc.mint(alice, 10 * P);
        vm.startPrank(alice);
        usdc.approve(address(ace), type(uint256).max);
        ace.deposit(id, 4 * P);
        vm.stopPrank();

        coll.mint(borrower, UNITS);
        vm.startPrank(borrower);
        coll.approve(address(pm), UNITS);
        loanId = ace.open(id, UNITS, P, TEN7, borrower, OpenBounds(0, 0, 0));
        vm.stopPrank();

        uint256 snap = vm.snapshotState();
        _arm();
        uint256 share = read.reservedOf(loanId); // a local: reverting the state reverts this contract's storage too
        vm.revertToState(snap);
        r = share;
        assertGt(r, 0, "PREMISE: an arm reserves");
        assertLt(r, md, "PREMISE: the reservation sits under the floor, as it does at shipped dials");
    }

    function _arm() internal {
        vm.prank(borrower);
        ace.setAutoRefinance(loanId, TEN7, 0, 0);
    }

    function _disarm() internal {
        vm.prank(borrower);
        ace.setAutoRefinance(loanId, 0, 0, 0);
    }

    /// @dev Alice's pending withdraw, pre-encoded to leave `left` resting.
    function _withdrawLeaving(uint256 left) internal returns (bool ok, bytes4 why) {
        uint256 a = ace.restingOf(id) - left;
        vm.prank(alice);
        try ace.withdraw(id, a, alice, 0) returns (uint256) {
            ok = true;
        } catch (bytes memory err) {
            why = bytes4(err);
        }
    }

    /// @notice An ARM refuses a pending partial withdraw: alone it leaves a whole floor unreserved, after the arm a sub-floor slice.
    function test_Race_AnArmTurnsAPendingWithdrawIntoWouldLeaveDust() public {
        uint256 left = md + r / 2;
        uint256 snap = vm.snapshotState();
        (bool alone,) = _withdrawLeaving(left);
        assertTrue(alone, "LEG A: alone, the withdraw leaves a whole floor and lands");
        vm.revertToState(snap);
        _arm();
        assertEq(read.reservedOf(loanId), r, "LEG B: alone, the arm lands");
        uint256 a = ace.restingOf(id) - left;
        vm.prank(alice);
        vm.expectRevert(WouldLeaveDust.selector);
        ace.withdraw(id, a, alice, 0);
    }

    /// @notice A DISARM refuses a pending withdraw down to the reserve: the released share becomes sub-floor unreserved cash.
    function test_Race_ADisarmTurnsAWithdrawDownToTheReserveIntoWouldLeaveDust() public {
        _arm();
        uint256 snap = vm.snapshotState();
        (bool alone,) = _withdrawLeaving(r);
        assertTrue(alone, "LEG A: alone, withdrawing down to exactly the reserve lands");
        vm.revertToState(snap);
        _disarm();
        assertEq(read.rollReserve(id), 0, "LEG B: alone, the disarm lands");
        uint256 a = ace.restingOf(id) - r;
        vm.prank(alice);
        vm.expectRevert(WouldLeaveDust.selector);
        ace.withdraw(id, a, alice, 0);
    }

    /// @notice A DISARM refuses a pending refill: the deficit it was sized to fill is gone, and a sub-floor lot is dust again.
    function test_Race_ADisarmTurnsAPendingRefillIntoBelowMinLot() public {
        _arm();
        vm.prank(alice);
        ace.withdraw(id, type(uint256).max, alice, 0);
        assertEq(ace.restingOf(id), 0, "PREMISE: the lender emptied the market, so the deficit is the whole reservation");
        uint256 snap = vm.snapshotState();
        vm.prank(alice);
        ace.deposit(id, r);
        assertEq(ace.restingOf(id), r, "LEG A: alone, the sub-floor refill lands");
        vm.revertToState(snap);
        _disarm();
        vm.prank(alice);
        vm.expectRevert(BelowMinLot.selector);
        ace.deposit(id, r);
    }

    /// @notice An ARM ADMITS a withdraw the floor refuses, and a DISARM then leaves the sub-floor slice resting unreserved.
    function test_Race_AnArmAdmitsAWithdrawTheFloorRefusesAndTheDisarmLeavesTheDust() public {
        (bool alone, bytes4 why) = _withdrawLeaving(r / 2);
        assertFalse(alone, "LEG A: alone, a withdraw leaving a sub-floor slice is refused");
        assertEq(why, WouldLeaveDust.selector, "by the dust wall");
        _arm();
        (bool after_,) = _withdrawLeaving(r / 2);
        assertTrue(after_, "behind the reservation the same slice is reserved, so the withdraw lands");
        _disarm();
        assertEq(read.rollReserve(id), 0, "the disarm releases it");
        assertEq(ace.restingOf(id), r / 2, "leaving a sub-floor slice unreserved, which the wall exists to refuse");
    }

    /// @notice CONTROL: the same dust arises with NO lender act at all, from a borrower's close releasing a reservation.
    /// @notice So the floor is a DOOR rule, not a state invariant, and the admit direction above adds no reachable state.
    function test_Control_AClosingRepayLeavesTheSameDustWithNoLenderAct() public {
        _arm();
        (bool ok,) = _withdrawLeaving(r);
        assertTrue(ok, "PREMISE: the lender keeps exactly the reserve");
        usdc.mint(borrower, P);
        vm.startPrank(borrower);
        usdc.approve(address(ace), P);
        ace.repay(loanId, P);
        vm.stopPrank();
        assertTrue(ace.isClosed(loanId), "the borrower's repay closed the loan");
        assertEq(read.rollReserve(id), 0, "and released the reservation");
        assertEq(ace.restingOf(id), r, "leaving the released share as sub-floor unreserved cash");
        assertLt(ace.restingOf(id), md, "under the floor");
    }
}
