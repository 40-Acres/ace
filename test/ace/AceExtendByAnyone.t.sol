// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.36;

import {FullMath} from "@uniswap/v4-core/src/libraries/FullMath.sol";
import {BufferBelowMin, ExtensionTooEarly, LoanMatured, PolicyRefused, TriggerAboveFloor, UnderPrice} from "../../src/ace/hub/Borrower.sol";
import {Loan, MarketParams, MigrateArgs, OpenBounds} from "../../src/ace/hub/Types.sol";
import {DrawMoreRig} from "../utils/DrawMoreRig.sol";

/// @title AceExtendByAnyoneTest
/// @notice Anyone may extend a live loan and pays the fee in cash; the holder and its title operators extend as before.
/// @notice A non-holder needs all three legs: the record at or above the price, the trigger out of the band, and the term's last quarter.
/// @notice A credit grant is not title, so the lender holding one is a non-holder: #884's lever, flipped.
contract AceExtendByAnyoneTest is DrawMoreRig {
    uint64 internal constant QUARTER = TEN7 / 4; // the last quarter of the rig's seven-day term

    function setUp() public override {
        super.setUp();
        _deposit(id, alice, 4 * P);
    }

    /// @dev A loan of `P` for `TEN7` with its trigger at `thetaBps` of the price.
    function _loanAt(uint256 thetaBps) internal returns (uint256) {
        return _open(P, TEN7, thetaBps);
    }

    /// @dev The clock at the start of `loanId`'s last quarter, where a non-holder may first extend.
    function _toLastQuarter(uint256 loanId) internal {
        _warpTo(uint256(read.loan(loanId).expiry) - QUARTER);
    }

    /// @dev `who` is refused `err` by the preview and the verb alike, with no fee quoted.
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

    /// @dev The record sits at `cap` and its band question answers as a record at `cap` would, persisted.
    function _recordAt(uint256 cap) internal {
        rec.setMinPrice(cap);
        rec.setBandPrice(cap);
    }

    /* ============================== a stranger pays ============================== */

    /// @notice In the last quarter of a healthy loan a stranger's extension lands: it pays the fee, and debt, lot and claim hold.
    function test_AStrangerPaysInTheLastQuarterAndNothingElseMoves() public {
        uint256 loanId = _loanAt(5000);
        _toLastQuarter(loanId);
        Loan memory l0 = read.loan(loanId);
        uint256 claim0 = read.claimOf(id, loanId);
        uint256 fee = _feeNow(loanId);
        _fund(stranger, fee);
        uint256 holder0 = usdc.balanceOf(borrower);
        vm.expectEmit(true, true, false, true, address(ace));
        emit Extended(loanId, uint64(_now()) + TEN7 - l0.expiry, uint64(_now()) + TEN7, fee, stranger);
        vm.prank(stranger);
        uint256 paid = ace.extend(loanId, 0, "");
        assertEq(paid, fee, "the stranger paid the fee on the time added");
        assertEq(usdc.balanceOf(stranger), 0, "out of its own pocket");
        assertEq(usdc.balanceOf(borrower), holder0, "the holder paid nothing");
        Loan memory l1 = read.loan(loanId);
        assertEq(l1.expiry, _now() + TEN7, "the loan runs its tenor from now");
        assertEq(l1.debt, l0.debt, "the debt held");
        assertEq(l1.collateralUnits, l0.collateralUnits, "the lot held");
        assertEq(read.claimOf(id, loanId), claim0, "the claim held");
        assertEq(l1.borrower, borrower, "and the title stayed the holder's");
        _assertSolvent();
    }

    /// @notice The escrow a stranger funds is the holder's: a closing repay refunds the unearned part to the holder, never to the payer.
    function test_TheRefundAStrangerFundedGoesToTheHolderAtARepay() public {
        uint256 loanId = _loanAt(5000);
        _toLastQuarter(loanId);
        _extend(stranger, loanId);
        _warpBy(1 days);
        uint256 refund = _unearned(loanId, read.feeEscrowOf(loanId));
        assertGt(refund, 0, "PREMISE: an unearned escrow to refund");
        uint256 debt = read.debtOf(loanId);
        _fund(borrower, debt);
        vm.prank(borrower);
        ace.repay(loanId, debt);
        assertEq(read.quoteOwedOf(loanId, borrower), refund, "the holder takes the unearned escrow");
        assertEq(read.quoteOwedOf(loanId, stranger), 0, "and the stranger who paid takes none");
    }

    /// @notice In a refinance the unearned escrow a stranger funded nets into the holder's out, as the holder's own would.
    function test_TheRefundAStrangerFundedNetsToTheHolderInARefinance() public {
        uint256 loanId = _loanAt(5000);
        _toLastQuarter(loanId);
        _extend(stranger, loanId);
        _warpBy(1 days);
        uint256 refund = _unearned(loanId, read.feeEscrowOf(loanId));
        uint256 debt = read.debtOf(loanId);
        uint256 newP = P + P / 2;
        uint256 out = newP - _fee(newP, TEN7) + refund - debt;
        uint256 bal0 = usdc.balanceOf(borrower);
        vm.prank(borrower);
        ace.refinanceTo(MigrateArgs(loanId, id, newP, TEN7, OpenBounds(0, 0, 0), 0, address(0)));
        assertEq(usdc.balanceOf(borrower), bal0 + out, "the holder's net out carries the refund the stranger funded");
        assertEq(read.quoteOwedOf(loanId, stranger), 0, "the stranger is credited nothing");
    }

    /// @notice The lender's policy still decides a stranger's extension: no policy refuses `PolicyRefused`, in the last quarter too.
    function test_ThePolicyStillBindsAStranger() public {
        uint256 loanId = _loanAt(5000);
        _setPolicy(alice, address(0));
        _toLastQuarter(loanId);
        _refusedExt(stranger, loanId, PolicyRefused.selector);
    }

    /* ============================== the three non-holder legs ============================== */

    /// @notice Leg (i): a record one atom under the price refuses a stranger `UnderPrice`; at the price exactly it lands.
    function test_LegOne_UnderThePriceRefusesAStranger() public {
        uint256 loanId = _loanAt(5000);
        _toLastQuarter(loanId);
        _recordAt(par - 1);
        _refusedExt(stranger, loanId, UnderPrice.selector);
        _recordAt(par);
        _extend(stranger, loanId);
        assertEq(read.loan(loanId).expiry, _now() + TEN7, "at the price exactly a stranger extends");
    }

    /// @notice Leg (ii): a loan the band admits refuses a stranger `BufferBelowMin`, at or above the price; out of the band it lands.
    /// @dev At an eighty percent trigger the band opens under eight sevenths of the price, so a record at the price sits in it.
    function test_LegTwo_InTheBandRefusesAStranger() public {
        uint256 loanId = _loanAt(8000);
        _toLastQuarter(loanId);
        _refusedExt(stranger, loanId, BufferBelowMin.selector);
        uint256 trig = read.triggerPrice(loanId);
        uint256 bandLevel = FullMath.mulDivRoundingUp(trig, 1e18, 1e18 - 3000 * 1e14);
        _recordAt(bandLevel - 1);
        _refusedExt(stranger, loanId, BufferBelowMin.selector);
        _recordAt(bandLevel);
        _extend(stranger, loanId);
        assertEq(read.loan(loanId).expiry, _now() + TEN7, "at the band's edge a stranger extends");
    }

    /// @notice Leg (iii): before the last quarter a stranger is refused `ExtensionTooEarly`; from its first second it lands.
    function test_LegThree_BeforeTheLastQuarterRefusesAStranger() public {
        uint256 loanId = _loanAt(5000);
        _warpBy(1 days);
        _refusedExt(stranger, loanId, ExtensionTooEarly.selector);
        _warpTo(uint256(read.loan(loanId).expiry) - QUARTER - 1);
        _refusedExt(stranger, loanId, ExtensionTooEarly.selector);
        _warpBy(1);
        _extend(stranger, loanId);
        assertEq(read.loan(loanId).expiry, _now() + TEN7, "with exactly a quarter left a stranger extends");
    }

    /// @notice Leg (iii) re-arms at every extension: a stranger's roll resets the term, so the next stranger waits out three quarters again.
    function test_LegThree_AStrangerCannotRollALoanEarlyAndOften() public {
        uint256 loanId = _loanAt(5000);
        _toLastQuarter(loanId);
        _extend(stranger, loanId);
        _warpBy(1);
        _refusedExt(stranger, loanId, ExtensionTooEarly.selector);
        _refusedExt(keeper, loanId, ExtensionTooEarly.selector);
    }

    /* ============================== who is the holder ============================== */

    /// @notice The holder is untouched by the rule: it extends early, under the price and in the band, judged at `min(price, record)`.
    function test_TheHolderIsUntouchedByTheRule() public {
        uint256 loanId = _loanAt(5000);
        _warpBy(1 days);
        _recordAt(FullMath.mulDiv(par, 9, 10));
        _extend(borrower, loanId);
        assertEq(read.loan(loanId).expiry, _now() + TEN7, "the holder extends early and under the price");
    }

    /// @notice Under a record that sinks below the trigger the holder is refused by admission, `TriggerAboveFloor`; a stranger by the price leg first.
    function test_UnderTheTriggerTheHolderMeetsAdmissionAndAStrangerThePriceLeg() public {
        uint256 loanId = _loanAt(5000);
        _toLastQuarter(loanId);
        _recordAt(FullMath.mulDiv(par, 4, 10));
        _refusedExt(borrower, loanId, TriggerAboveFloor.selector);
        _refusedExt(stranger, loanId, UnderPrice.selector);
    }

    /// @notice D-4: an operator approved for this title, or for all the holder's titles, extends as the holder does, early and in the band.
    function test_ATitleOperatorExtendsAsTheHolder() public {
        uint256 loanId = _loanAt(8000);
        address one = address(0x0FE4);
        address all = address(0x0FE5);
        vm.startPrank(borrower);
        titles.approve(one, loanId);
        titles.setApprovalForAll(all, true);
        vm.stopPrank();
        _warpBy(1 days);
        uint256 holder0 = usdc.balanceOf(borrower);
        _extend(one, loanId);
        assertEq(read.loan(loanId).expiry, _now() + TEN7, "the token operator extends early and in the band");
        _warpBy(1 days);
        _extend(all, loanId);
        assertEq(read.loan(loanId).expiry, _now() + TEN7, "and so does the all-titles operator");
        assertEq(usdc.balanceOf(borrower), holder0, "each paid its own fee");
    }

    /// @notice A credit grant is not title: the market lender holding the holder's grant is a non-holder, refused early and in band.
    function test_ACreditGrantMakesNoHolder() public {
        uint256 loanId = _loanAt(5000);
        vm.prank(borrower);
        ace.setCreditOperator(alice, true);
        _warpBy(1 days);
        _refusedExt(alice, loanId, ExtensionTooEarly.selector);
        _toLastQuarter(loanId);
        _extend(alice, loanId);
        assertEq(read.loan(loanId).expiry, _now() + TEN7, "in fair weather it extends as anyone may");
    }

    /* ============================== #884, flipped ============================== */

    /// @notice #884 flipped: the granted lender cannot extend a loan past its expiry under the price, and the holder keeps book settlement.
    /// @notice A 70,000 loan at a seventy percent trigger, the record at ninety percent of the price, not distressed.
    /// @dev On a BAND-OFF market, where settlement at expiry is still the need: band on it takes the debt at the record.
    function test_884_TheGrantedLenderCannotTakeTheBookSettlementAway() public {
        MarketParams memory p = _params(alice);
        (p.deleverageFloorEpsBps, p.deleverageBandBps, p.deleverageTargetBps, p.deleverageStopBps, p.deleverageProtocolBps) = (0, 0, 0, 0, 0);
        bytes32 bandOff = ace.createMarket(p);
        _deposit(bandOff, alice, 7 * P);
        uint256 debt = 70_000e6;
        uint256 loanId = _openIn(bandOff, borrower, debt, TEN7, 7000);
        vm.prank(borrower);
        ace.setCreditOperator(alice, true);
        uint256 v = FullMath.mulDiv(par, 9, 10);
        _recordAt(v);
        assertFalse(read.inDistress(loanId), "PREMISE: not distressed");
        uint64 x = read.loan(loanId).expiry;
        _warpTo(uint256(x) - 1);
        _refusedExt(alice, loanId, UnderPrice.selector);
        _refusedExt(stranger, loanId, UnderPrice.selector);
        _warpTo(x);
        uint256 units = read.loan(loanId).collateralUnits;
        vm.prank(keeper);
        ace.forceClose(loanId);
        assertEq(read.loan(loanId).closedAt, x, "the loan settled at its own expiry");
        uint256 kept = read.unitsOwedOf(loanId, borrower);
        uint256 repayEq = FullMath.mulDiv(units, v, S) - debt;
        assertGt(FullMath.mulDiv(kept, v, S), repayEq, "PREMISE: under the price, settlement at book is the holder's best outcome");
        uint256 need = FullMath.mulDivRoundingUp(debt, S, par);
        assertEq(kept + read.invPotOf(bandOff, loanId) + read.unitsOwedOf(loanId, keeper), units, "the lot split three ways");
        assertEq(read.invPotOf(bandOff, loanId), need, "the lender took exactly the book need");
    }

    /// @notice #884 at or above the price: in the band the granted lender is refused `BufferBelowMin` in the loan's last second.
    function test_884_AtThePriceTheGrantedLenderIsRefusedInTheBand() public {
        uint256 loanId = _loanAt(8000);
        vm.prank(borrower);
        ace.setCreditOperator(alice, true);
        _warpTo(uint256(read.loan(loanId).expiry) - 1);
        _refusedExt(alice, loanId, BufferBelowMin.selector);
    }

    /* ============================== around the term ============================== */

    /// @notice From the expiry second a stranger is refused `LoanMatured`, and `forceClose` then settles.
    function test_AtExpiryAStrangerIsRefusedAndForceCloseLands() public {
        uint256 loanId = _loanAt(5000);
        _warpTo(read.loan(loanId).expiry);
        _refusedExt(stranger, loanId, LoanMatured.selector);
        vm.prank(keeper);
        ace.forceClose(loanId);
        assertTrue(ace.isClosed(loanId), "forceClose settles the loan the stranger could not extend");
    }

    /// @notice The preview answers a stranger as the verb does, and quotes the fee the verb charges.
    function test_ThePreviewAgreesForAStranger() public {
        uint256 loanId = _loanAt(5000);
        _toLastQuarter(loanId);
        (bool ok, bytes4 why, uint256 fee) = ace.tryExtend(loanId, 0, "", stranger);
        assertTrue(ok, "the preview admits the stranger in the last quarter");
        assertEq(why, bytes4(0), "with no reason");
        assertEq(_extend(stranger, loanId), fee, "and the verb charges what it quoted");
    }

    /// @notice A stranger's extension landing first never blocks the holder's closing repay, and the refund is still the holder's.
    function test_AFrontRunExtensionLeavesTheClosingRepayClosing() public {
        uint256 loanId = _loanAt(5000);
        _toLastQuarter(loanId);
        uint256 debt = read.debtOf(loanId);
        _fund(borrower, debt);
        _extend(stranger, loanId);
        vm.prank(borrower);
        ace.repay(loanId, debt);
        assertTrue(ace.isClosed(loanId), "the closing repay still closed the loan");
        assertGt(read.quoteOwedOf(loanId, borrower), 0, "and the holder took the escrow the stranger funded");
    }

    /// @notice On a recordless market the price and band legs are vacuous, and the time leg alone holds a stranger off.
    function test_ARecordlessMarketDefersAStrangerOnlyToTheLastQuarter() public {
        MarketParams memory p = _params(alice);
        p.record = address(0);
        (p.deleverageFloorEpsBps, p.deleverageBandBps, p.deleverageTargetBps, p.deleverageStopBps, p.deleverageProtocolBps) = (0, 0, 0, 0, 0);
        bytes32 bare = ace.createMarket(p);
        _deposit(bare, alice, 2 * P);
        uint256 loanId = _openIn(bare, borrower, P, TEN7, 9000);
        _warpBy(1 days);
        _refusedExt(stranger, loanId, ExtensionTooEarly.selector);
        _toLastQuarter(loanId);
        _extend(stranger, loanId);
        assertEq(read.loan(loanId).expiry, _now() + TEN7, "in the last quarter a stranger defers the settlement one tenor");
    }
}
