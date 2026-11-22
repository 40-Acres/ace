// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.36;

import {FullMath} from "@uniswap/v4-core/src/libraries/FullMath.sol";
import {NoMarket} from "../../src/ace/hub/Ace.sol";
import {
    BelowCoverageLine,
    BelowMinPrincipal,
    BufferBelowMin,
    GateRefused,
    InsufficientCash,
    LoanClosed,
    LoanMatured,
    NoRecordPrice,
    NotBorrower,
    OpenExpired,
    PayoutBelowMin,
    RecordUnreadable,
    TenorOutOfRange,
    TriggerAboveFloor
} from "../../src/ace/hub/Borrower.sol";
import {LoanMath} from "../../src/ace/hub/libraries/LoanMath.sol";
import {Loan, MarketParams, OpenBounds} from "../../src/ace/hub/Types.sol";
import {DrawMoreRig} from "../utils/DrawMoreRig.sol";

/// @title AceDrawMoreTest
/// @notice `drawMore` tops a live loan up from its own market's resting cash at the one price: debt and claim rise by the amount.
/// @notice The fee is the origination fee on the term left, netted from the payout; the schedule re-anchors at the draw.
/// @notice The holder or its title operator calls; the holder is paid, and every refusal names its leg in the verb and the preview alike.
contract AceDrawMoreTest is DrawMoreRig {
    uint256 internal constant A = P / 4; // the default top-up: the trigger moves from half the price to five eighths of it

    function setUp() public override {
        super.setUp();
        _deposit(id, alice, 8 * P);
    }

    /// @dev A loan of `P` for `LONG` at half the price, two days old, so a top-up has a term left and the escrow has earned.
    function _loan() internal returns (uint256 loanId) {
        loanId = _openIn(id, borrower, P, LONG, 5000);
        _warpBy(2 days);
    }

    /* ============================== what moves ============================== */

    /// @notice The debt and the claim rise by exactly the amount, and so do the lender's `lent`; resting cash falls by it.
    function test_ATopUpRaisesTheDebtAndTheClaimByExactlyTheAmount() public {
        uint256 loanId = _loan();
        uint256 debt0 = read.debtOf(loanId);
        uint256 claim0 = read.claimOf(id, loanId);
        (uint256 resting0, uint256 lent0,) = read.poolOf(id);
        uint256 cash0 = ace.restingOf(id);
        _top(borrower, loanId, A);
        assertEq(read.debtOf(loanId), debt0 + A, "the debt rose by the amount");
        assertEq(ace.debtOf(loanId), debt0 + A, "and the hub's guarded read agrees");
        assertEq(read.claimOf(id, loanId), claim0 + A, "the claim rose by the amount");
        _assertDebtIsClaim(loanId);
        (uint256 resting1, uint256 lent1,) = read.poolOf(id);
        assertEq(lent1, lent0 + A, "lent rose by the amount");
        assertEq(resting1, resting0 - A, "the lender's resting pool fell by it");
        assertEq(ace.restingOf(id), cash0 - A, "and so did the market's cash");
    }

    /// @notice The holder takes the amount less the fee on the term left; the fee splits as at open, the old escrow earned to now first.
    function test_TheHolderIsPaidTheAmountLessTheFeeOnTheTermLeft() public {
        uint256 loanId = _loan();
        uint256 fee = _topFee(loanId, A);
        uint256 e0 = read.feeEscrowOf(loanId);
        uint256 r0 = _unearned(loanId, e0); // exact here: no draw has re-anchored this loan yet
        uint256 bal0 = usdc.balanceOf(borrower);
        uint256 rev0 = read.revenuePot(address(usdc));
        (,, uint256 owed0) = read.poolOf(id);
        vm.prank(borrower);
        uint256 got = hub.drawMore(loanId, A, _none());
        assertEq(got, fee, "the verb returns the fee on the term left");
        assertEq(usdc.balanceOf(borrower), bal0 + A - fee, "the holder took the amount less the fee");
        assertEq(read.revenuePot(address(usdc)), rev0 + LoanMath.protocolCut(fee), "the protocol cut is revenue");
        (,, uint256 owed1) = read.poolOf(id);
        assertEq(owed1, owed0 + (e0 - r0) + LoanMath.tickCut(fee), "owed takes the earned old escrow and the tick cut");
        assertEq(read.feeEscrowOf(loanId), r0 + LoanMath.escrowCut(fee), "the escrow keeps the unearned old part and the new escrow cut");
        _assertSolvent();
    }

    /// @notice Expiry, tenor and funding floor never move; the schedule re-anchors at the draw, inside the restated term identity.
    function test_TheTermAndTheFloorNeverMoveAndTheScheduleOpensNow() public {
        uint256 loanId = _loan();
        Loan memory l0 = read.loan(loanId);
        uint256 floor0 = read.fundingFloor(id, loanId);
        _top(borrower, loanId, A);
        Loan memory l1 = read.loan(loanId);
        assertEq(l1.expiry, l0.expiry, "the expiry did not move");
        assertEq(l1.tenor, l0.tenor, "the tenor did not move");
        assertEq(read.fundingFloor(id, loanId), floor0, "the funding floor did not move");
        assertEq(l1.openTime, _now(), "the fee schedule re-anchored at the draw");
        assertEq(l1.collateralUnits, l0.collateralUnits, "the lot did not move");
        _assertTermBounds(loanId);
    }

    /// @notice The draw counter moves once per top-up; the born principal and the born fee stay the open's.
    function test_TheCounterBumpsAndTheBornFiguresStay() public {
        uint256 loanId = _loan();
        uint64 n0 = read.marketState(id).drawCount;
        uint256 born = read.principalOf(loanId);
        uint256 lastFee = read.loan(loanId).lastFee;
        _top(borrower, loanId, A);
        assertEq(read.marketState(id).drawCount, n0 + 1, "a top-up bumps the draw counter once");
        assertEq(read.principalOf(loanId), born, "principalOf keeps the born principal");
        assertEq(read.loan(loanId).lastFee, lastFee, "lastFee keeps the born fee");
    }

    /// @notice `Funded` fires on the top-up, naming the holder, and `DrewMore` carries the fee, the term charged and the new debt.
    function test_TheEventsNameTheHolderTheTermAndTheNewDebt() public {
        uint256 loanId = _loan();
        uint64 term = _termLeft(loanId);
        uint256 fee = _fee(A, term);
        vm.expectEmit(true, true, false, true, address(ace));
        emit Funded(loanId, A, borrower);
        vm.expectEmit(true, true, false, true, address(ace));
        emit DrewMore(loanId, A, fee, term, P + A, borrower);
        _top(borrower, loanId, A);
    }

    /// @notice A top-up and then a closing repay leave the hub's quote equal to its booked pots, and the close succeeds.
    function test_ATopUpThenAClosingRepayStaySolvent() public {
        uint256 loanId = _loan();
        _top(borrower, loanId, A);
        _assertSolvent();
        _warpBy(3 days);
        uint256 debt = read.debtOf(loanId);
        _fund(borrower, debt);
        vm.prank(borrower);
        ace.repay(loanId, debt);
        assertTrue(ace.isClosed(loanId), "the closing repay closed the topped-up loan");
        _assertSolvent();
    }

    /// @notice The preview agrees with the verb: its fee and term are what the verb charges and logs.
    function test_ThePreviewAgreesWithTheVerb() public {
        uint256 loanId = _loan();
        (bool ok, bytes4 why, uint256 fee, uint64 term) = hub.tryDrawMore(loanId, A, _none(), borrower);
        assertTrue(ok, "the preview admits the top-up");
        assertEq(why, bytes4(0), "with no reason");
        assertEq(term, _termLeft(loanId), "on the term left");
        assertEq(fee, _fee(A, term), "for the fee on it");
        assertEq(_top(borrower, loanId, A), fee, "and the verb charges what the preview quoted");
    }

    /* ============================== who may draw ============================== */

    /// @notice An operator the holder approved for this title draws, and the holder is paid, never the operator.
    function test_ATokenApprovedOperatorDrawsAndTheHolderIsPaid() public {
        uint256 loanId = _loan();
        address op = address(0x0FE4);
        vm.prank(borrower);
        titles.approve(op, loanId);
        uint256 fee = _topFee(loanId, A);
        uint256 holder0 = usdc.balanceOf(borrower);
        vm.expectEmit(true, true, false, true, address(ace));
        emit Funded(loanId, A, borrower);
        vm.expectEmit(true, true, false, true, address(ace));
        emit DrewMore(loanId, A, fee, _termLeft(loanId), P + A, op);
        _top(op, loanId, A);
        assertEq(usdc.balanceOf(borrower), holder0 + A - fee, "the holder took the payout");
        assertEq(usdc.balanceOf(op), 0, "the operator took nothing");
    }

    /// @notice An operator the holder approved for all its titles draws too, and again the holder is paid.
    function test_AnAllTitlesOperatorDrawsAndTheHolderIsPaid() public {
        uint256 loanId = _loan();
        address op = address(0x0FE5);
        vm.prank(borrower);
        titles.setApprovalForAll(op, true);
        uint256 fee = _topFee(loanId, A);
        uint256 holder0 = usdc.balanceOf(borrower);
        _top(op, loanId, A);
        assertEq(usdc.balanceOf(borrower), holder0 + A - fee, "the holder took the payout");
        assertEq(usdc.balanceOf(op), 0, "the operator took nothing");
    }

    /// @notice A title move clears the token approval and keys operators by the new holder: the old operator is refused, the buyer draws.
    function test_ATitleMoveTakesTheOldOperatorsPowerAway() public {
        uint256 loanId = _loan();
        address op = address(0x0FE4);
        address all = address(0x0FE5);
        vm.startPrank(borrower);
        titles.approve(op, loanId);
        titles.setApprovalForAll(all, true);
        vm.stopPrank();
        address buyer = address(0xB0E2);
        _moveTitle(loanId, borrower, buyer);
        _refusedTop(op, loanId, A, _none(), NotBorrower.selector);
        _refusedTop(all, loanId, A, _none(), NotBorrower.selector);
        uint256 fee = _topFee(loanId, A);
        _top(buyer, loanId, A);
        assertEq(usdc.balanceOf(buyer), A - fee, "the new holder draws and is paid");
    }

    /// @notice A credit grant is not title: the lender holding one, and any other granted operator, is refused like a stranger.
    function test_ACreditGrantAloneIsRefused() public {
        uint256 loanId = _loan();
        address router = address(0x2077E2);
        vm.startPrank(borrower);
        ace.setCreditOperator(alice, true);
        ace.setCreditOperator(router, true);
        vm.stopPrank();
        _refusedTop(alice, loanId, A, _none(), NotBorrower.selector);
        _refusedTop(router, loanId, A, _none(), NotBorrower.selector);
        _refusedTop(stranger, loanId, A, _none(), NotBorrower.selector);
        _refusedTop(keeper, loanId, A, _none(), NotBorrower.selector);
    }

    /// @notice The preview asks for a named caller: the zero address is no holder, the holder is, a stranger is not.
    function test_ThePreviewJudgesTheCallerItIsAsked() public {
        uint256 loanId = _loan();
        (bool okZero, bytes4 whyZero,,) = hub.tryDrawMore(loanId, A, _none(), address(0));
        assertFalse(okZero, "the zero address is never a holder");
        assertEq(whyZero, NotBorrower.selector, "refused by the caller leg");
        (bool okHolder,,,) = hub.tryDrawMore(loanId, A, _none(), borrower);
        assertTrue(okHolder, "the holder is admitted");
    }

    /* ============================== the refusals, leg by leg ============================== */

    /// @notice A closed loan refuses `LoanClosed`, before the caller is read.
    function test_AClosedLoanRefuses() public {
        uint256 loanId = _loan();
        uint256 debt = read.debtOf(loanId);
        _fund(borrower, debt);
        vm.prank(borrower);
        ace.repay(loanId, debt);
        _refusedTop(borrower, loanId, A, _none(), LoanClosed.selector);
        _refusedTop(stranger, loanId, A, _none(), LoanClosed.selector);
    }

    /// @notice From the expiry second a top-up refuses `LoanMatured`, at expiry and a day late; a stranger is refused by the caller first.
    function test_AMaturedLoanRefuses() public {
        uint256 loanId = _loan();
        _warpTo(read.loan(loanId).expiry);
        _refusedTop(borrower, loanId, A, _none(), LoanMatured.selector);
        _refusedTop(stranger, loanId, A, _none(), NotBorrower.selector);
        _warpBy(1 days);
        _refusedTop(borrower, loanId, A, _none(), LoanMatured.selector);
    }

    /// @notice B-2: a term left under `minTenor` refuses `TenorOutOfRange`; exactly `minTenor` left lands, for the fee on exactly that.
    function test_ATermLeftUnderMinTenorRefuses() public {
        uint256 loanId = _openIn(id, borrower, P, LONG, 5000);
        uint64 x = read.loan(loanId).expiry;
        _warpTo(uint256(x) - TEN7 + 1);
        _refusedTop(borrower, loanId, A, _none(), TenorOutOfRange.selector);
        _warpTo(uint256(x) - TEN7);
        uint256 fee = _top(borrower, loanId, A);
        assertEq(fee, _fee(A, TEN7), "a top-up with exactly minTenor left pays the fee on minTenor");
    }

    /// @notice B-2 on a single-term market: the open second already has under `minTenor` left a second later, so no top-up ever lands there.
    function test_ASingleTermMarketNeverTopsUpPastItsOpenSecond() public {
        MarketParams memory p = _params(alice);
        (p.minTenor, p.maxTenor) = (TEN7, TEN7);
        bytes32 one = ace.createMarket(p);
        _deposit(one, alice, 2 * P);
        uint256 loanId = _openIn(one, borrower, P, TEN7, 5000);
        uint256 fee = _top(borrower, loanId, A);
        assertEq(fee, _fee(A, TEN7), "in its open second the whole tenor is left");
        _warpBy(1);
        _refusedTop(borrower, loanId, A, _none(), TenorOutOfRange.selector);
    }

    /// @notice A deadline the clock has passed refuses `OpenExpired`; one equal to the clock still lands.
    function test_AStaleDeadlineRefuses() public {
        uint256 loanId = _loan();
        _refusedTop(borrower, loanId, A, OpenBounds(0, 0, uint64(_now()) - 1), OpenExpired.selector);
        vm.prank(borrower);
        hub.drawMore(loanId, A, OpenBounds(0, 0, uint64(_now())));
        assertEq(read.debtOf(loanId), P + A, "a deadline at the clock still lands");
    }

    /// @notice Each top-up is at least `minPrincipal`: one atom under refuses `BelowMinPrincipal`, as does zero, and the floor lands.
    function test_ATopUpUnderMinPrincipalRefuses() public {
        uint256 loanId = _loan();
        _refusedTop(borrower, loanId, MIN_PRINCIPAL - 1, _none(), BelowMinPrincipal.selector);
        _refusedTop(borrower, loanId, 0, _none(), BelowMinPrincipal.selector);
        _top(borrower, loanId, MIN_PRINCIPAL);
        assertEq(read.debtOf(loanId), P + MIN_PRINCIPAL, "a top-up of exactly minPrincipal lands");
    }

    /// @notice The borrower rule judges the current holder: in a market naming its borrower, a buyer of the title is refused `GateRefused`.
    function test_TheBorrowerRuleJudgesTheHolder() public {
        MarketParams memory p = _params(alice);
        p.borrower = borrower;
        bytes32 named = ace.createMarket(p);
        _deposit(named, alice, 2 * P);
        uint256 loanId = _openIn(named, borrower, P, LONG, 5000);
        _warpBy(1 days);
        _top(borrower, loanId, A);
        address buyer = address(0xB0E2);
        _moveTitle(loanId, borrower, buyer);
        _refusedTop(buyer, loanId, A, _none(), GateRefused.selector);
    }

    /// @notice A payout floor over the amount less the fee refuses `PayoutBelowMin`; a floor of exactly that lands.
    function test_APayoutFloorOverTheNetRefuses() public {
        uint256 loanId = _loan();
        uint256 net = A - _topFee(loanId, A);
        _refusedTop(borrower, loanId, A, OpenBounds(net + 1, 0, 0), PayoutBelowMin.selector);
        vm.prank(borrower);
        hub.drawMore(loanId, A, OpenBounds(net, 0, 0));
        assertEq(read.debtOf(loanId), P + A, "a floor of exactly the net lands");
    }

    /// @notice B-4: a record that reverts or answers short refuses `RecordUnreadable`, and the preview answers rather than reverting.
    function test_AnUnreadableRecordRefusesAndThePreviewAnswers() public {
        uint256 loanId = _loan();
        rec.setSick(true);
        _refusedTop(borrower, loanId, A, _none(), RecordUnreadable.selector);
        rec.setSick(false);
        rec.setShortAnswer(true);
        _refusedTop(borrower, loanId, A, _none(), RecordUnreadable.selector);
    }

    /// @notice B-4: a record answering zero refuses `NoRecordPrice`, by name in both.
    function test_ADarkRecordRefusesNoRecordPrice() public {
        uint256 loanId = _loan();
        rec.setMinPrice(0);
        _refusedTop(borrower, loanId, A, _none(), NoRecordPrice.selector);
    }

    /// @notice B-4: the draw cap refuses a top-up while the record's windowed minimum sits one atom under the price, `InsufficientCash`.
    function test_TheDrawCapRefusesUnderThePrice() public {
        uint256 loanId = _loan();
        rec.setMinPrice(par - 1);
        _refusedTop(borrower, loanId, A, _none(), InsufficientCash.selector);
        rec.setMinPrice(par);
        _top(borrower, loanId, A);
        assertEq(read.debtOf(loanId), P + A, "at the price exactly the top-up lands");
    }

    /// @notice B-4: a top-up one atom over the resting cash refuses `InsufficientCash`.
    function test_ATopUpOverTheRestingCashRefuses() public {
        uint256 loanId = _loan();
        uint256 cash = ace.restingOf(id);
        _refusedTop(borrower, loanId, cash + 1, _none(), InsufficientCash.selector);
    }

    /// @notice Admission runs on the new debt at the price: a top-up whose trigger tops the price refuses `TriggerAboveFloor`.
    function test_ATopUpOverThePriceRefusesTriggerAboveFloor() public {
        uint256 loanId = _loan();
        _refusedTop(borrower, loanId, 2 * P, _none(), TriggerAboveFloor.selector);
    }

    /// @notice A buffer the new debt cannot clear refuses `BufferBelowMin`: at five eighths of the price the buffer is three eighths.
    function test_ABufferBoundTheNewDebtMissesRefuses() public {
        uint256 loanId = _loan();
        _refusedTop(borrower, loanId, A, OpenBounds(0, 0.4e18, 0), BufferBelowMin.selector);
        vm.prank(borrower);
        hub.drawMore(loanId, A, OpenBounds(0, 0.37e18, 0));
        assertEq(read.debtOf(loanId), P + A, "a buffer the new debt clears lands");
    }

    /// @notice The coverage line runs on the new debt: a lot of exactly the new debt's need clears the trigger and refuses `BelowCoverageLine`.
    /// @notice One atom less of top-up lowers the need by more than an atom, and lands.
    /// @dev The need is `ceil(k * debt * S / (price * 1e18))`; a lot equal to it sits at the trigger, one atom under the line.
    function test_ATopUpToTheLineRefusesBelowCoverageLine() public {
        uint256 units = FullMath.mulDivRoundingUp(K * (P + A), S, par * 1e18); // the need of the topped-up debt
        coll.mint(borrower, units);
        vm.startPrank(borrower);
        coll.approve(address(pm), units);
        uint256 loanId = ace.open(id, units, P, LONG, borrower, _none());
        vm.stopPrank();
        _warpBy(2 days);
        _refusedTop(borrower, loanId, A, _none(), BelowCoverageLine.selector);
        _top(borrower, loanId, A - 1);
        assertEq(read.debtOf(loanId), P + A - 1, "a top-up one atom smaller clears the line and lands");
    }

    /// @notice An id that names no loan, an order's included, fails closed `NoMarket` at the verb and the preview.
    function test_AnUnknownIdFailsClosed() public {
        vm.expectRevert(NoMarket.selector);
        hub.tryDrawMore(999, A, _none(), borrower);
        vm.prank(borrower);
        vm.expectRevert(NoMarket.selector);
        hub.drawMore(999, A, _none());
    }

    /* ============================== B-5: the term an extension sets ============================== */

    /// @notice B-5: an extension landing first lengthens the term the next top-up pays for, and the holder's payout floor refuses the longer fee.
    function test_AnExtensionLandingFirstLengthensTheTermChargedAndMinPayoutBoundsIt() public {
        uint256 loanId = _openIn(id, borrower, P, LONG, 5000);
        _warpTo(uint256(read.loan(loanId).expiry) - TEN7);
        (bool ok0,, uint256 feeShort, uint64 termShort) = hub.tryDrawMore(loanId, A, _none(), borrower);
        assertTrue(ok0, "PREMISE: a top-up with minTenor left is admitted");
        assertEq(termShort, TEN7, "PREMISE: on minTenor");
        _extend(stranger, loanId);
        (,, uint256 feeLong, uint64 termLong) = hub.tryDrawMore(loanId, A, _none(), borrower);
        assertEq(termLong, LONG, "after the stranger's extension the next top-up pays for a whole tenor");
        assertGt(feeLong, feeShort, "so its fee is larger");
        _refusedTop(borrower, loanId, A, OpenBounds(A - feeShort, 0, 0), PayoutBelowMin.selector);
    }
}
