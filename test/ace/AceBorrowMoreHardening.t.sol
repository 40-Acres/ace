// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.36;

import {stdError} from "forge-std/StdError.sol";
import {FullMath} from "@uniswap/v4-core/src/libraries/FullMath.sol";
import {
    BelowMinPrincipal,
    BufferBelowMin,
    CollateralOutOfRange,
    ExtensionAddsNoTime,
    ExtensionTooEarly,
    GateRefused,
    InsufficientCash,
    LoanClosed,
    LoanMatured,
    NoRecordPrice,
    NotBorrower,
    NothingAdded,
    OpenExpired,
    PayoutBelowMin,
    RecordUnreadable,
    TenorOutOfRange,
    TriggerAboveFloor
} from "../../src/ace/hub/Borrower.sol";
import {MarketParams, OpenBounds} from "../../src/ace/hub/Types.sol";
import {DrawMoreRig} from "../utils/DrawMoreRig.sol";

/// @title AceDrawMoreHardeningTest
/// @notice `drawMore` checked against figures written out by hand from the rule, not from the code.
/// @notice The rig: 10,000 USDC lent for 28 days at 2190 bps a year, so an open's fee is 6.6 USDC a day and a 2,500 top-up's 1.65 a day.
/// @notice The rule: `fee = ceil(amount * 2190 * term * 11000 / (1e8 * 365 days))`, a tenth of the lender's fee on top for the protocol.
/// @notice The lender's part splits half to `owed` now and half to an escrow that earns from the draw to the one expiry.
contract AceDrawMoreHardeningTest is DrawMoreRig {
    uint256 internal constant A = P / 4; // 2,500 USDC

    function setUp() public override {
        super.setUp();
        _deposit(id, alice, 8 * P);
    }

    /// @dev A loan of `P` for `LONG` at half the price, two days old: 26 days of its 28 left.
    function _loan() internal returns (uint256 loanId) {
        loanId = _openIn(id, borrower, P, LONG, 5000);
        _warpBy(2 days);
    }

    /* ============================== the figures, to the atom ============================== */

    /// @notice 2,500 USDC for 26 days costs 42.9 USDC: 3.9 to the protocol, 19.5 owed to the lender now, 19.5 into the escrow.
    /// @notice The open's 84 USDC escrow first earns its two served days, 6, and keeps 78 for the 26 left.
    function test_TheFeeAndItsSplitAreTheRulesFiguresToTheAtom() public {
        uint256 loanId = _loan();
        assertEq(read.feeEscrowOf(loanId), 84_000_000, "PREMISE: the open's escrow is half of 10/11 of 184.8 USDC");
        uint256 bal0 = usdc.balanceOf(borrower);
        uint256 hub0 = usdc.balanceOf(address(ace));
        uint256 rev0 = read.protocolRevenue(id);
        (uint256 resting0,, uint256 owed0) = read.poolOf(id);
        vm.prank(borrower);
        uint256 fee = hub.drawMore(loanId, A, _none());
        assertEq(fee, 42_900_000, "ceil(2,500e6 * 2190 * 26 days * 11000 / (1e8 * 365 days))");
        assertEq(usdc.balanceOf(borrower) - bal0, 2_457_100_000, "the holder took the amount less the fee");
        assertEq(hub0 - usdc.balanceOf(address(ace)), 2_457_100_000, "and the hub paid out exactly that");
        assertEq(read.protocolRevenue(id) - rev0, 3_900_000, "the protocol took an eleventh of the fee");
        (uint256 resting1,, uint256 owed1) = read.poolOf(id);
        assertEq(owed1 - owed0, 25_500_000, "owed took the open escrow's two served days and half the lender's cut");
        assertEq(read.feeEscrowOf(loanId), 97_500_000, "the escrow keeps 26/28 of the open's and the other half");
        assertEq(resting0 - resting1, A, "the lender's resting fell by the whole amount");
        _assertSolvent();
    }

    /// @notice A close 13 days on refunds each tranche over its own span: 39 of the open's 78, and 9.75 of the top-up's 19.5.
    /// @notice Over the whole tenor, or with the schedule never re-anchored, the refund would be 45.267857 instead.
    function test_ACloseAfterATopUpRefundsEachTrancheOverItsOwnSpan() public {
        uint256 loanId = _loan();
        _top(borrower, loanId, A);
        _warpBy(13 days);
        (,, uint256 owed0) = read.poolOf(id);
        uint256 alice0 = usdc.balanceOf(alice);
        uint256 debt = read.debtOf(loanId);
        assertEq(debt, P + A, "PREMISE: the debt is both tranches");
        _fund(borrower, debt);
        vm.prank(borrower);
        ace.repay(loanId, debt);
        assertEq(read.quoteOwedOf(loanId, borrower), 48_750_000, "13 of the 26 days left refund half of 97.5");
        assertEq(usdc.balanceOf(alice) - alice0, owed0 + debt + 48_750_000, "the closing push pays the lender the debt and the served half");
        _assertSolvent();
    }

    /// @notice A second top-up pays for the term left at its own draw, 19 days and 31.35 USDC, never for the schedule the first opened.
    function test_ASecondTopUpPaysForItsOwnTermLeft() public {
        uint256 loanId = _loan();
        assertEq(_top(borrower, loanId, A), 42_900_000, "PREMISE: the first top-up paid for 26 days");
        _warpBy(7 days);
        (bool ok,, uint256 quoted, uint64 term) = hub.tryDrawMore(loanId, A, _none(), borrower);
        assertTrue(ok, "PREMISE: the second top-up is admitted");
        assertEq(term, 19 days, "the term left at the second draw");
        assertEq(quoted, 31_350_000, "1.65 USDC a day for 19 days");
        assertEq(_top(borrower, loanId, A), 31_350_000, "and the verb charges it");
        assertEq(read.debtOf(loanId), P + 2 * A, "both tranches are owed");
    }

    /// @notice A loan repaid to its debt floor, 5 USDC, still tops up: the floor is per draw, so 9.999999 refuses and 10 lands, to 15 owed.
    function test_ALoanAtItsDebtFloorTopsUpByAtLeastMinPrincipal() public {
        uint256 loanId = _loan();
        uint256 pay = P - MIN_PRINCIPAL / 2;
        _fund(borrower, pay);
        vm.prank(borrower);
        ace.repay(loanId, pay);
        assertEq(read.debtOf(loanId), 5_000_000, "PREMISE: the loan sits at its debt floor, half of minPrincipal");
        _refusedTop(borrower, loanId, MIN_PRINCIPAL - 1, _none(), BelowMinPrincipal.selector);
        _top(borrower, loanId, MIN_PRINCIPAL);
        assertEq(read.debtOf(loanId), 15_000_000, "the floor's debt and one minPrincipal");
        _assertDebtIsClaim(loanId);
    }

    /* ============================== the cash leg, the record and the split ============================== */

    /// @notice A top-up of exactly the market's resting cash lands and empties it; one atom over refuses `InsufficientCash`.
    function test_ATopUpOfExactlyTheRestingCashLandsAndEmptiesIt() public {
        uint256 loanId = _loan();
        uint256 surplus = ace.restingOf(id) - A;
        vm.prank(alice);
        ace.withdraw(id, surplus, alice, 0);
        assertEq(ace.restingOf(id), A, "PREMISE: exactly the top-up rests");
        _refusedTop(borrower, loanId, A + 1, _none(), InsufficientCash.selector);
        _top(borrower, loanId, A);
        assertEq(ace.restingOf(id), 0, "the top-up drew the market's cash to zero");
        (uint256 resting,,) = read.poolOf(id);
        assertEq(resting, 0, "and the lender's pooled resting with it");
        _refusedTop(borrower, loanId, MIN_PRINCIPAL, _none(), InsufficientCash.selector);
    }

    /// @notice On a recordless market the record legs are vacuous: a top-up is judged at the price alone, and a trigger past it still refuses.
    function test_ARecordlessMarketTopsUpAtThePrice() public {
        MarketParams memory p = _params(alice);
        p.record = address(0);
        (p.deleverageFloorEpsBps, p.deleverageBandBps, p.deleverageTargetBps, p.deleverageStopBps, p.deleverageProtocolBps) = (0, 0, 0, 0, 0);
        bytes32 bare = ace.createMarket(p);
        _deposit(bare, alice, 4 * P);
        uint256 loanId = _openIn(bare, borrower, P, LONG, 5000);
        _warpBy(2 days);
        _refusedTop(borrower, loanId, 2 * P, _none(), TriggerAboveFloor.selector);
        assertEq(_top(borrower, loanId, A), 42_900_000, "the top-up lands for the same fee a recorded market charges");
        assertEq(read.debtOf(loanId), P + A, "and the debt rose by the amount");
    }

    /// @notice A top-up lends at par against the collateral as an open does: the lender's per-collateral `lent` rises by the amount.
    function test_ATopUpRaisesTheLendersPerCollateralLent() public {
        uint256 loanId = _loan();
        (uint256 lent0,) = ace.lenderByCollateral(alice, address(usdc), address(coll));
        _top(borrower, loanId, A);
        (uint256 lent1,) = ace.lenderByCollateral(alice, address(usdc), address(coll));
        assertEq(lent1, lent0 + A, "the per-collateral split rose by the amount");
        (, uint256 poolLent,) = read.poolOf(id);
        assertEq(lent1, poolLent, "summed over the lender's one collateral it is the pool's lent");
    }

    /* ============================== the order of the refusals ============================== */

    /// @notice THE ORDER, peeled one leg at a time from a state where every leg fails: each refusal names the first failing leg.
    /// @notice Closed, the caller, matured, the term left, the deadline, the amount, the borrower rule, the payout, the record, cash, admission.
    function test_TheRefusalsComeInTheirDeclaredOrder() public {
        MarketParams memory p = _params(alice);
        p.borrower = borrower;
        bytes32 named = ace.createMarket(p);
        _deposit(named, alice, 4 * P);
        uint256 loanId = _openIn(named, borrower, P, LONG, 5000);
        _warpBy(1 days);
        address buyer = address(0xB0E2);
        _moveTitle(loanId, borrower, buyer);
        rec.setSick(true);
        OpenBounds memory bad = OpenBounds(type(uint256).max, type(uint256).max, 1);
        uint256 small = MIN_PRINCIPAL - 1;

        uint256 snap = vm.snapshotState();
        uint256 debt = read.debtOf(loanId);
        _fund(buyer, debt);
        vm.prank(buyer);
        ace.repay(loanId, debt);
        _refusedTop(stranger, loanId, small, bad, LoanClosed.selector);
        vm.revertToState(snap);

        _refusedTop(stranger, loanId, small, bad, NotBorrower.selector);
        snap = vm.snapshotState();
        _warpTo(read.loan(loanId).expiry);
        _refusedTop(buyer, loanId, small, bad, LoanMatured.selector);
        vm.revertToState(snap);
        snap = vm.snapshotState();
        _warpTo(uint256(read.loan(loanId).expiry) - TEN7 + 1);
        _refusedTop(buyer, loanId, small, bad, TenorOutOfRange.selector);
        vm.revertToState(snap);

        _refusedTop(buyer, loanId, small, bad, OpenExpired.selector);
        bad.deadline = 0;
        _refusedTop(buyer, loanId, small, bad, BelowMinPrincipal.selector);
        _refusedTop(buyer, loanId, 2 * P, bad, GateRefused.selector);
        _moveTitle(loanId, buyer, borrower);

        _refusedTop(borrower, loanId, 2 * P, bad, PayoutBelowMin.selector);
        bad.minPayout = 0;
        _refusedTop(borrower, loanId, 2 * P, bad, RecordUnreadable.selector);
        rec.setSick(false);
        rec.setMinPrice(0);
        _refusedTop(borrower, loanId, 2 * P, bad, NoRecordPrice.selector);
        rec.setMinPrice(par - 1);
        _refusedTop(borrower, loanId, 2 * P, bad, InsufficientCash.selector);
        rec.setMinPrice(par);
        vm.prank(alice);
        ace.withdraw(named, 2 * P, alice, 0);
        _refusedTop(borrower, loanId, 2 * P, bad, InsufficientCash.selector);
        _deposit(named, alice, 2 * P);

        _refusedTop(borrower, loanId, 2 * P, bad, TriggerAboveFloor.selector);
        _refusedTop(borrower, loanId, A, bad, BufferBelowMin.selector);
        bad.minBufferWad = 0;
        vm.prank(borrower);
        hub.drawMore(loanId, A, bad);
        assertEq(read.debtOf(loanId), P + A, "with every leg cleared the top-up lands");
    }

    /* ============================== the schedule's start and the extension ============================== */

    /// @notice An extension in a top-up's own second lands: the no-time leg compares the two expiries, never the schedule's start.
    /// @notice It adds the two days served since the open, for 16.5 USDC on the 12,500 owed.
    function test_AnExtensionInATopUpsOwnSecondLands() public {
        uint256 loanId = _loan();
        _top(borrower, loanId, A);
        assertEq(read.loan(loanId).openTime, _now(), "PREMISE: the schedule opened in this second");
        uint256 fee = _extend(borrower, loanId);
        assertEq(read.loan(loanId).expiry, _now() + LONG, "the extension ran the tenor from the top-up's second");
        assertEq(fee, 16_500_000, "8.25 USDC a day on 12,500 for the two days it added");
    }

    /// @notice In the term's open second a top-up re-anchors nothing, and an extension there still adds no time.
    function test_InTheTermsOpenSecondATopUpLeavesAnExtensionAddingNoTime() public {
        uint256 loanId = _openIn(id, borrower, P, LONG, 5000);
        _top(borrower, loanId, A);
        (bool ok, bytes4 why,) = ace.tryExtend(loanId, 0, "", borrower);
        assertFalse(ok, "an extension in the open second was admitted after a top-up");
        assertEq(why, ExtensionAddsNoTime.selector, "refused by the no-time leg");
    }
}

/// @title AceAddCollateralHardeningTest
/// @notice `addCollateral`'s edges: the last second, the width bound to the atom, its refusal order, and payers who cannot pay.
contract AceAddCollateralHardeningTest is DrawMoreRig {
    uint256 internal constant U = 1_000e18;

    function setUp() public override {
        super.setUp();
        _deposit(id, alice, 4 * P);
    }

    function _loan() internal returns (uint256 loanId) {
        loanId = _openIn(id, borrower, P, LONG, 5000);
        _warpBy(1 days);
    }

    function _refusedAdd(address payer, uint256 loanId, uint256 units, bytes4 err) internal {
        vm.prank(payer);
        vm.expectRevert(err);
        hub.addCollateral(loanId, units, "");
    }

    /// @notice An add lands in the term's last second; from the expiry second it refuses.
    function test_AnAddLandsInTheTermsLastSecond() public {
        uint256 loanId = _openIn(id, borrower, P, LONG, 5000);
        _warpTo(uint256(read.loan(loanId).expiry) - 1);
        uint256 units0 = read.loan(loanId).collateralUnits;
        _add(stranger, loanId, U);
        assertEq(read.loan(loanId).collateralUnits, units0 + U, "the add in the last second landed");
    }

    /// @notice A sum of exactly the width bound lands: every lot is `<= max / 1e18`, the bound an open checks, and the add may reach it.
    function test_AnAddToExactlyTheWidthBoundLands() public {
        uint256 loanId = _loan();
        uint256 bound_ = type(uint256).max / 1e18;
        uint256 room = bound_ - read.loan(loanId).collateralUnits;
        _refusedAdd(stranger, loanId, room + 1, CollateralOutOfRange.selector);
        _add(stranger, loanId, room);
        assertEq(read.loan(loanId).collateralUnits, bound_, "the lot sits at the width bound");
        assertEq(pm.collateralOf(loanId), bound_, "and custody holds it");
        _refusedAdd(stranger, loanId, 1, CollateralOutOfRange.selector);
    }

    /// @notice THE ORDER: closed, nothing added, matured, the width; each leg yields to the one before it.
    function test_TheAddsRefusalsComeInTheirDeclaredOrder() public {
        uint256 loanId = _openIn(id, borrower, P, LONG, 5000);
        uint256 huge = type(uint256).max / 1e18;
        _warpTo(read.loan(loanId).expiry);
        uint256 snap = vm.snapshotState();
        uint256 debt = read.debtOf(loanId);
        _fund(borrower, debt);
        vm.prank(borrower);
        ace.repay(loanId, debt);
        _refusedAdd(stranger, loanId, 0, LoanClosed.selector);
        _refusedAdd(stranger, loanId, huge, LoanClosed.selector);
        vm.revertToState(snap);
        _refusedAdd(stranger, loanId, 0, NothingAdded.selector);
        _refusedAdd(stranger, loanId, huge, LoanMatured.selector);
    }

    /// @notice A payer that approved custody nothing, or holds nothing, is refused in the token, and the hub's credit unwinds with it.
    function test_APayerWhoCannotPayIsRefusedAndTheLotStands() public {
        uint256 loanId = _loan();
        uint256 units0 = read.loan(loanId).collateralUnits;
        uint256 custody0 = pm.collateralOf(loanId);
        coll.mint(stranger, U);
        vm.prank(stranger);
        vm.expectRevert(stdError.arithmeticError);
        hub.addCollateral(loanId, U, "");
        vm.prank(keeper);
        coll.approve(address(pm), U);
        vm.prank(keeper);
        vm.expectRevert(stdError.arithmeticError);
        hub.addCollateral(loanId, U, "");
        assertEq(read.loan(loanId).collateralUnits, units0, "neither refused add moved the lot");
        assertEq(pm.collateralOf(loanId), custody0, "nor custody");
        assertEq(coll.balanceOf(stranger), U, "and the unapproved payer kept its units");
    }

    /// @notice The borrower rule refuses new credit alone: a loan whose title left a market's named borrower still takes an add.
    function test_TheBorrowerRuleNeverBlocksAnAdd() public {
        MarketParams memory p = _params(alice);
        p.borrower = borrower;
        bytes32 named = ace.createMarket(p);
        _deposit(named, alice, 2 * P);
        uint256 loanId = _openIn(named, borrower, P, LONG, 5000);
        _warpBy(1 days);
        address buyer = address(0xB0E2);
        _moveTitle(loanId, borrower, buyer);
        _refusedTop(buyer, loanId, MIN_PRINCIPAL, _none(), GateRefused.selector);
        uint256 units0 = read.loan(loanId).collateralUnits;
        _add(buyer, loanId, U);
        _add(stranger, loanId, U);
        assertEq(read.loan(loanId).collateralUnits, units0 + 2 * U, "the holder the market does not name, and a stranger, each added");
    }

    /// @notice An add moves no lender figure, no cash, no revenue, no draw counter and no quote: only the lot.
    function test_AnAddMovesNoLenderFigure() public {
        uint256 loanId = _loan();
        bytes memory before = _lenderFigures();
        _add(stranger, loanId, U);
        assertEq(_lenderFigures(), before, "an add moved a lender figure");
    }

    /// @dev The market's pools, cash, counter and revenue, and the hub's quote, in one blob.
    function _lenderFigures() internal view returns (bytes memory) {
        (uint256 r, uint256 l, uint256 o) = read.poolOf(id);
        return abi.encode(r, l, o, ace.restingOf(id), read.marketState(id).drawCount, read.protocolRevenue(id), usdc.balanceOf(address(ace)));
    }
}

/// @title AceExtendNonHolderHardeningTest
/// @notice The non-holder rule's order and edges: the band before the clock, the quarter floored, and who stops being an operator.
contract AceExtendNonHolderHardeningTest is DrawMoreRig {
    function setUp() public override {
        super.setUp();
        _deposit(id, alice, 4 * P);
    }

    function _refusedExt(address who, uint256 loanId, bytes4 err) internal {
        (bool ok, bytes4 why, uint256 fee) = ace.tryExtend(loanId, 0, "", who);
        assertFalse(ok, "the preview admitted an extension the verb refuses");
        assertEq(why, err, "the preview named another leg");
        assertEq(fee, 0, "a refused preview quotes no fee");
        _fund(who, _ceiling(loanId));
        vm.prank(who);
        vm.expectRevert(err);
        ace.extend(loanId, 0, "");
    }

    /// @notice The band leg runs before the clock: early in an in-band loan's term a stranger is refused `BufferBelowMin`.
    /// @notice With the record lifted to the band's level the clock is what refuses it, `ExtensionTooEarly`.
    function test_TheBandLegRunsBeforeTheClock() public {
        uint256 loanId = _open(P, TEN7, 8000);
        _warpBy(1 days);
        _refusedExt(stranger, loanId, BufferBelowMin.selector);
        uint256 level = FullMath.mulDivRoundingUp(read.triggerPrice(loanId), 1e18, 1e18 - 3000 * 1e14);
        rec.setMinPrice(level);
        rec.setBandPrice(level);
        _refusedExt(stranger, loanId, ExtensionTooEarly.selector);
    }

    /// @notice The quarter is the tenor's floored fourth: on seven days and three seconds a stranger lands with 151,200 seconds left, not 151,201.
    function test_TheQuarterIsTheTenorsFlooredFourth() public {
        uint64 odd = TEN7 + 3;
        uint256 loanId = _open(P, odd, 5000);
        uint64 x = read.loan(loanId).expiry;
        _warpTo(uint256(x) - 151_201);
        _refusedExt(stranger, loanId, ExtensionTooEarly.selector);
        _warpTo(uint256(x) - 151_200);
        _extend(stranger, loanId);
        assertEq(read.loan(loanId).expiry, _now() + odd, "with the floored quarter left a stranger extends");
    }

    /// @notice A title move takes an operator's seat away: the old token and all-titles operators become non-holders, the buyer extends early.
    function test_ATitleMoveMakesTheOldOperatorsNonHoldersToExtend() public {
        uint256 loanId = _open(P, TEN7, 5000);
        address one = address(0x0FE4);
        address all = address(0x0FE5);
        vm.startPrank(borrower);
        titles.approve(one, loanId);
        titles.setApprovalForAll(all, true);
        vm.stopPrank();
        _warpBy(1 days);
        (bool okOne,,) = ace.tryExtend(loanId, 0, "", one);
        (bool okAll,,) = ace.tryExtend(loanId, 0, "", all);
        assertTrue(okOne && okAll, "PREMISE: a day in both operators extend as the holder");
        address buyer = address(0xB0E2);
        _moveTitle(loanId, borrower, buyer);
        _refusedExt(one, loanId, ExtensionTooEarly.selector);
        _refusedExt(all, loanId, ExtensionTooEarly.selector);
        _extend(buyer, loanId);
        assertEq(read.loan(loanId).expiry, _now() + TEN7, "the buyer extends early as the holder");
    }

    /// @notice The zero address is never the holder's operator, even with no token approval standing, where the getter answers zero.
    function test_TheZeroCallerIsANonHolderWithNoApprovalStanding() public {
        uint256 loanId = _open(P, TEN7, 5000);
        assertEq(titles.getApproved(loanId), address(0), "PREMISE: no token approval, so the getter answers the zero address");
        _warpBy(1 days);
        (bool ok, bytes4 why,) = ace.tryExtend(loanId, 0, "", address(0));
        assertFalse(ok, "the zero caller was seated as the holder");
        assertEq(why, ExtensionTooEarly.selector, "refused as the non-holder it is");
    }
}
