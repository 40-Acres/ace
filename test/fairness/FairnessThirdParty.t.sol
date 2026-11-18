// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.36;

import {IERC721} from "@openzeppelin/contracts/token/ERC721/IERC721.sol";
import {FullMath} from "@uniswap/v4-core/src/libraries/FullMath.sol";
import {FairnessHarness} from "./FairnessHarness.sol";
import {YesPolicy} from "../utils/RollPolicyMocks.sol";
import {BufferBelowMin, ExtensionTooEarly, InsufficientCash, UnderPrice} from "../../src/ace/hub/Borrower.sol";
import {LoanMath} from "../../src/ace/hub/libraries/LoanMath.sol";
import {OpenBounds} from "../../src/ace/hub/Types.sol";

/// @title FairnessThirdParty
/// @notice Family F2, a third party's action never hurts the party it acts on: a stranger's repay or add, an extension by anyone, a crank, a buy.
/// @notice An operator's top-up, and the draw cap that guards the lender's cash. Settlement by a stranger is family F4's caller-identity row.
/// @dev #884 is fixed: a non-holder extends only at or above the price, out of the band and in the term's last quarter, so its property row runs.
/// @dev The #933 seizure row clamps each trigger to `price / k`: past `k` coverage lines the in-term take is capped there, and that residual is ruled.
contract FairnessThirdPartyTest is FairnessHarness {
    function _repayCase(uint256 i) internal pure returns (uint256 thetaBps, uint256 repayBps) {
        if (i == 0) return (9000, 2000);
        if (i == 1) return (9000, 4000);
        if (i == 2) return (8000, 2000);
        return (8000, 4000);
    }

    function _strangerPair(Kind k, uint256 thetaBps, uint256 repayBps) internal returns (Outcome memory a, Outcome memory b) {
        Run memory ra = _baseRun(k, thetaBps, _glide(10000, 3000, GRID));
        Run memory rb = _baseRun(k, thetaBps, _glide(10000, 3000, GRID));
        (rb.act, rb.actAt, rb.actAmount) = (Act.StrangerRepay, 0, D * repayBps / 10000);
        (a, b) = _pairOf(ra, rb);
    }

    /// @dev A band-on loan at 65% of par, the print at 64%: distress for the baseline, which settles at book; `act` lands first in the other run.
    function _intoTheBand(Act act, uint256 repayBps) internal returns (Outcome memory a, Outcome memory b) {
        Run memory ra = _baseRun(Kind.BandOn, 6500, _dropTo(6400, 4));
        Run memory rb = _baseRun(Kind.BandOn, 6500, _dropTo(6400, 4));
        (rb.act, rb.actAt, rb.actAmount) = (act, 1, D * repayBps / 10000);
        (a, b) = _pairOf(ra, rb);
    }

    /* ================================ F2.1 a stranger's repay ================================ */

    /// @notice F2.1: a stranger's partial repay never leaves the borrower worse off, band off or recordless.
    function test_F2_1_StrangerRepay_BorrowerNeverWorse() public {
        for (uint256 k; k < 2; ++k) {
            Kind kind = k == 0 ? Kind.BandOff : Kind.Recordless;
            for (uint256 i; i < 4; ++i) {
                (uint256 theta, uint256 repay) = _repayCase(i);
                (Outcome memory a, Outcome memory b) = _strangerPair(kind, theta, repay);
                assertGe(_wealth(b), _wealth(a), "F2.1: the stranger's repay left the borrower worse off");
            }
        }
    }

    /// forge-config: default.fuzz.runs = 64
    /// @notice F2.1 band off, over any trigger, repay and two prints.
    function testFuzz_F2_1_StrangerRepay_BandOff_BorrowerNeverWorse(uint256 thetaBps, uint256 repayBps, uint256 p1, uint256 p2) public {
        thetaBps = bound(thetaBps, 3000, 9500);
        repayBps = bound(repayBps, 100, 8000);
        uint256[] memory path = new uint256[](2);
        (path[0], path[1]) = (bound(p1, 500, 20000), bound(p2, 500, 20000));
        Run memory ra = _baseRun(Kind.BandOff, thetaBps, path);
        Run memory rb = _baseRun(Kind.BandOff, thetaBps, path);
        (rb.act, rb.actAt, rb.actAmount) = (Act.StrangerRepay, 0, D * repayBps / 10000);
        (Outcome memory a, Outcome memory b) = _pairOf(ra, rb);
        assertGe(_wealth(b), _wealth(a), "F2.1: the stranger's repay left the borrower worse off");
    }

    /// @notice F2.1 at seizure: a stranger's repay never raises the selling lender's shortfall, triggers clamped to `max(trigger, price / k)`, the ruled cap.
    function test_F2_1_StrangerRepay_Recorded_LenderShortfallAtSeizure() public {
        if (!FIXED_933) return;
        for (uint256 i; i < 4; ++i) {
            (uint256 theta, uint256 repay) = _repayCase(i);
            (Outcome memory a, Outcome memory b) = _strangerPair(Kind.BandOff, theta, repay);
            uint256 tol = _gridTol(D, GRID, theta * (10000 - repay) / 10000);
            assertLe(_clampedShortfall(b), _clampedShortfall(a) + tol, "F2.1: the stranger's repay left the selling lender shorter");
        }
    }

    /// @notice F2.1 band on: a stranger's partial repay never leaves the borrower worse off, here on a loan the print has put in distress.
    function test_F2_1_StrangerRepay_BandOn_BorrowerNeverWorse() public {
        if (!FIXED_933) return;
        for (uint256 i; i < 3; ++i) {
            (Outcome memory a, Outcome memory b) = _intoTheBand(Act.StrangerRepay, 1500 + 500 * i);
            assertGe(_wealth(b), _wealth(a), "F2.1: the stranger's repay left the borrower worse off");
        }
    }

    /// @notice F2.1 band on: repaying its own distressed loan gains the lender nothing at the 65% fixture on the capped take; under ~0.55 P it does.
    function test_F2_1_LenderRepay_BandOn_LenderGainsNothing() public {
        if (!FIXED_933) return;
        for (uint256 i; i < 3; ++i) {
            (Outcome memory a, Outcome memory b) = _intoTheBand(Act.LenderRepay, 1200 + 400 * i);
            assertTrue(a.finalized && a.sold == 0 && !b.finalized && b.sold > 0, "fixture: the baseline settles at book and the repaid loan is cranked");
            assertLe(_lenderWealth(b), _lenderWealth(a), "F2.1: the lender profited from repaying its own distressed loan");
            assertGe(_wealth(b), _wealth(a), "F2.1: the lender's repay left the borrower worse off");
        }
    }

    /* ================================ F2.2 the granted lender's extension ================================ */

    /// @notice F2.2: the market lender's extension under the borrower's grant never costs the borrower the settlement it had earned.
    function test_F2_2_GrantedLenderExtension_NeverCostsTheBorrower() public {
        if (!FIXED_884) return;
        uint256 snap = vm.snapshotState();
        (uint256 a,) = _lastSecond(false);
        vm.revertToState(snap);
        (uint256 b,) = _lastSecond(true);
        assertGe(b, a, "F2.2: the lender's extension cost the borrower");
    }

    /// @dev A band-on loan at 70% of par, granted to its lender; the record falls to 90% in the last second, inside the band and above distress.
    /// @dev The mock answers persistence at once, so the baseline's crank second is withheld: the band opens there only after the original expiry.
    function _lastSecond(bool lenderExtends) internal returns (uint256 wealth, bool landed) {
        _deposit(id, alice, 2 * D);
        _budget();
        uint256 loanId = _openRun(id, _baseRun(Kind.BandOn, 7000, _flatAt(10000, 1)));
        vm.prank(borrower);
        ace.setCreditOperator(alice, true);
        _setPolicy(alice, address(new YesPolicy()));
        _warpTo(read.loan(loanId).expiry - 1);
        _printBps(9000);
        if (lenderExtends) {
            _fund(alice, _ceiling(loanId));
            vm.prank(alice);
            try ace.extend(loanId, 0, "") {
                landed = true;
            } catch {}
            if (landed) ace.deleverage(loanId, 0, "");
        }
        _warpAtLeastTo(read.loan(loanId).expiry);
        vm.prank(keeper);
        ace.forceClose(loanId);
        Outcome memory o;
        (o.mid, o.loanId, o.endPx) = (id, loanId, _pxOf(9000));
        _tallyOf(o);
        wealth = _wealth(o);
    }

    /* ================================ F2.2b-f a stranger's extension ================================ */

    /// @dev A loan of `D` for `TEN7` in class `k` at `thetaBps`, its lender's yes installed, the clock at the start of the term's last quarter.
    function _inTheLastQuarter(Kind k, uint256 thetaBps) internal returns (uint256 loanId) {
        bytes32 mid = _mid(k);
        _deposit(mid, alice, 2 * D);
        _budget();
        _setPolicy(alice, address(new YesPolicy()));
        loanId = _openRun(mid, _baseRun(k, thetaBps, _flatAt(10000, 1)));
        _warpTo(read.loan(loanId).expiry - TEN7 / 4);
    }

    /// @notice F2.2b: a stranger's extension never moves the holder's quote, and the escrow it funds refunds to the holder at close, never to the payer.
    function test_F2_2b_StrangerExtension_TheHolderPaysNothingAndTakesTheRefund() public {
        uint256 loanId = _inTheLastQuarter(Kind.BandOff, 7000);
        uint256 holder0 = usdc.balanceOf(borrower);
        uint256 fee = _feeNow(loanId);
        _fund(stranger, fee);
        vm.prank(stranger);
        assertEq(ace.extend(loanId, 0, ""), fee, "fixture: the stranger's extension lands for the fee on the time added");
        assertEq(usdc.balanceOf(borrower), holder0, "F2.2b: the stranger's extension moved the holder's quote");
        assertEq(read.debtOf(loanId), D, "F2.2b: the stranger's extension moved the debt");
        _warpBy(1 days);
        uint256 refund = _unearned(loanId, read.feeEscrowOf(loanId));
        assertGt(refund, 0, "fixture: an unearned escrow to refund");
        vm.prank(borrower);
        ace.repay(loanId, D);
        assertEq(read.quoteOwedOf(loanId, borrower), refund, "F2.2b: the holder did not take the unearned escrow the stranger funded");
        assertEq(read.quoteOwedOf(loanId, stranger), 0, "F2.2b: the stranger who paid was refunded");
    }

    /// @notice F2.2c: a stranger can never take the holder's expiry settlement away, so its attempt leaves the borrower exactly as no attempt does.
    /// @notice Refused `UnderPrice` while the holder's put is in the money, the record under the price; `BufferBelowMin` while a crank could open.
    function test_F2_2c_StrangerExtension_RefusedWhileThePutIsInTheMoneyOrInTheBand() public {
        for (uint256 i; i < 2; ++i) {
            (uint256 theta, uint256 bps, bytes4 err) = i == 0 ? (7000, 9000, UnderPrice.selector) : (8000, 10000, BufferBelowMin.selector);
            uint256 snap = vm.snapshotState();
            uint256 a = _strangerInTheLastSecond(theta, bps, bytes4(0));
            vm.revertToState(snap);
            uint256 b = _strangerInTheLastSecond(theta, bps, err);
            vm.revertToState(snap);
            assertEq(b, a, "F2.2c: the stranger's refused attempt moved the borrower");
        }
    }

    /// @dev A band-on loan at `thetaBps`, the record at `bps` in its last second; with `err` set a stranger tries to extend and is refused by name.
    function _strangerInTheLastSecond(uint256 thetaBps, uint256 bps, bytes4 err) internal returns (uint256 wealth) {
        uint256 loanId = _inTheLastQuarter(Kind.BandOn, thetaBps);
        _warpTo(read.loan(loanId).expiry - 1);
        _printBps(bps);
        if (err != bytes4(0)) {
            (bool ok, bytes4 why,) = ace.tryExtend(loanId, 0, "", stranger);
            assertTrue(!ok && why == err, "F2.2c: the preview admitted the stranger, or named another leg");
            _fund(stranger, _ceiling(loanId));
            vm.prank(stranger);
            vm.expectRevert(err);
            ace.extend(loanId, 0, "");
        }
        _warpAtLeastTo(read.loan(loanId).expiry);
        vm.prank(keeper);
        ace.forceClose(loanId);
        Outcome memory o;
        (o.mid, o.loanId, o.endPx) = (id, loanId, _pxOf(bps));
        _tallyOf(o);
        wealth = _wealth(o);
    }

    /// forge-config: default.fuzz.runs = 64
    /// @notice F2.2d, D-1: a stranger extends only in the term's last quarter, so it can never roll a loan early, and each landing restarts the wait.
    function testFuzz_F2_2d_AStrangerNeverRollsALoanEarly(uint256 at) public {
        _deposit(bandOff, alice, 2 * D);
        _budget();
        _setPolicy(alice, address(new YesPolicy()));
        uint256 loanId = _openRun(bandOff, _baseRun(Kind.BandOff, 5000, _flatAt(10000, 1)));
        uint64 x = read.loan(loanId).expiry;
        _warpTo(bound(at, uint256(x) - TEN7 + 1, uint256(x) - 1));
        _fund(stranger, 2 * _ceiling(loanId));
        vm.startPrank(stranger);
        if (x - _now() > TEN7 / 4) {
            vm.expectRevert(ExtensionTooEarly.selector);
            ace.extend(loanId, 0, "");
            vm.stopPrank();
            assertEq(read.loan(loanId).expiry, x, "D-1: a refused early extension moved the expiry");
            return;
        }
        ace.extend(loanId, 0, "");
        assertEq(read.loan(loanId).expiry, _now() + TEN7, "D-1: the stranger's extension runs one tenor from now");
        assertLe(read.loan(loanId).expiry - x, TEN7, "D-1: one stranger's extension deferred the expiry by more than a tenor");
        _warpBy(1);
        vm.expectRevert(ExtensionTooEarly.selector);
        ace.extend(loanId, 0, "");
        vm.stopPrank();
    }

    /// @notice F2.2e, accepted: recordless, the clock alone bounds a stranger, who defers the settlement by at most a tenor and pays the lender for it.
    /// @notice On a flat print the holder ends where it would have and pays nothing; the lender keeps the stranger's fee.
    function test_F2_2e_StrangerExtension_Recordless_DefersTheSettlementAtMostOneTenor() public {
        uint256 snap = vm.snapshotState();
        (Outcome memory a, uint256 feeA) = _recordlessStranger(false);
        vm.revertToState(snap);
        (Outcome memory b, uint256 feeB) = _recordlessStranger(true);
        vm.revertToState(snap);
        assertEq(feeA, 0, "fixture: no extension in the baseline");
        assertGt(feeB, 0, "fixture: the stranger's extension lands, paying a fee");
        assertEq(_wealth(b), _wealth(a), "F2.2e: the stranger's deferral moved the holder");
        assertEq(b.pot, a.pot, "F2.2e: the deferral moved the take at the settlement it deferred");
        uint256 paid = feeB - LoanMath.protocolCut(feeB);
        assertEq(_lenderWealth(b), _lenderWealth(a) + paid, "F2.2e: the lender was not paid the stranger's fee, less the protocol's cut");
    }

    /// @dev A recordless loan at 90% of par to expiry, a stranger extending at the start of its last quarter when `defer`; returns the tally and the fee.
    function _recordlessStranger(bool defer) internal returns (Outcome memory o, uint256 fee) {
        uint256 loanId = _inTheLastQuarter(Kind.Recordless, 9000);
        uint64 x = read.loan(loanId).expiry;
        if (defer) {
            _fund(stranger, _ceiling(loanId));
            vm.prank(stranger);
            fee = ace.extend(loanId, 0, "");
            assertLe(read.loan(loanId).expiry - x, TEN7, "F2.2e: one stranger's extension deferred the settlement by more than a tenor");
            _warpBy(1);
            vm.prank(stranger);
            vm.expectRevert(ExtensionTooEarly.selector);
            ace.extend(loanId, 0, "");
        }
        _warpAtLeastTo(read.loan(loanId).expiry);
        vm.prank(keeper);
        ace.forceClose(loanId);
        (o.mid, o.loanId, o.endPx) = (recordless, loanId, par);
        _tallyOf(o);
    }

    /// @notice D-2, the accepted residual: the rule reads the record, so a record lagging a fall lets a last-block stranger extend under the true price.
    /// @notice In the loan's last second the record still reads par while the true price is 90%; once it catches up, the loan sits in the band a tenor longer.
    function test_Residual_D2_ALaggingRecordLetsALastBlockStrangerExtendUnderTheTruePrice() public {
        uint256 snap = vm.snapshotState();
        (uint256 a,) = _laggingRecord(false);
        vm.revertToState(snap);
        (uint256 b, bool landed) = _laggingRecord(true);
        vm.revertToState(snap);
        assertTrue(landed, "residual: the stranger's extension lands on the lagging record");
        assertLt(b, a, "residual: the lagging record's extension costs the borrower its book settlement");
        emit log_named_decimal_uint("D-2 residual: the borrower's loss to a stranger's extension on a lagging record", a - b, 6);
    }

    /// @dev A band-on loan at 65% of par, out of the band at par; in its last second the record still reads par, the true price 90%, in the band.
    function _laggingRecord(bool strangerExtends) internal returns (uint256 wealth, bool landed) {
        uint256 loanId = _inTheLastQuarter(Kind.BandOn, 6500);
        _warpTo(read.loan(loanId).expiry - 1);
        if (strangerExtends) {
            _fund(stranger, _ceiling(loanId));
            vm.prank(stranger);
            try ace.extend(loanId, 0, "") {
                landed = true;
            } catch {}
        }
        _printBps(9000);
        if (landed) ace.deleverage(loanId, 0, "");
        _warpAtLeastTo(read.loan(loanId).expiry);
        vm.prank(keeper);
        ace.forceClose(loanId);
        Outcome memory o;
        (o.mid, o.loanId, o.endPx) = (id, loanId, _pxOf(9000));
        _tallyOf(o);
        wealth = _wealth(o);
    }

    /* ================================ F2.13 a stranger's add ================================ */

    /// @dev The add grid: (the trigger at open, the stranger's add in bps of the lot).
    function _addCase(uint256 i) internal pure returns (uint256 thetaBps, uint256 addBps) {
        if (i == 0) return (9000, 2500);
        if (i == 1) return (8000, 5000);
        return (7000, 10000);
    }

    function _strangerAddRun(Kind k, uint256 thetaBps, uint256 addBps) internal view returns (Run memory r) {
        r = _baseRun(k, thetaBps, _glide(10000, 3000, GRID));
        (r.act, r.actAt, r.actAmount) = (Act.StrangerAdd, 0, FullMath.mulDiv(_units(D, thetaBps), addBps, 10000));
    }

    /// @notice F2.13: a stranger's add only ever benefits the holder: band off or recordless the borrower is never worse off, and the payer is owed nothing.
    function test_F2_13_StrangerAdd_OnlyEverBenefitsTheHolder() public {
        for (uint256 k; k < 2; ++k) {
            Kind kind = k == 0 ? Kind.BandOff : Kind.Recordless;
            for (uint256 i; i < 3; ++i) {
                (uint256 theta, uint256 add) = _addCase(i);
                (Outcome memory a, Outcome memory b) = _pairOf(_baseRun(kind, theta, _glide(10000, 3000, GRID)), _strangerAddRun(kind, theta, add));
                assertGt(_wealth(b), _wealth(a), "F2.13: the stranger's add did not benefit the borrower");
                uint256 snap = vm.snapshotState();
                Outcome memory o = _runFor(_strangerAddRun(kind, theta, add));
                assertEq(coll.balanceOf(stranger), 0, "fixture: the stranger paid the units");
                assertEq(read.unitsOwedOf(o.loanId, stranger), 0, "F2.13: the stranger is owed units for its add");
                assertEq(read.quoteOwedOf(o.loanId, stranger), 0, "F2.13: the stranger is owed quote for its add");
                vm.revertToState(snap);
            }
        }
    }

    /// forge-config: default.fuzz.runs = 64
    /// @notice F2.13 band off, over any trigger, any add and two prints: the stranger's add never leaves the borrower worse off.
    function testFuzz_F2_13_StrangerAdd_BandOff_BorrowerNeverWorse(uint256 thetaBps, uint256 addBps, uint256 p1, uint256 p2) public {
        thetaBps = bound(thetaBps, 3000, 9500);
        addBps = bound(addBps, 1, 20000);
        uint256[] memory path = new uint256[](2);
        (path[0], path[1]) = (bound(p1, 500, 20000), bound(p2, 500, 20000));
        Run memory ra = _baseRun(Kind.BandOff, thetaBps, path);
        Run memory rb = _baseRun(Kind.BandOff, thetaBps, path);
        uint256 units = FullMath.mulDiv(_units(D, thetaBps), addBps, 10000);
        (rb.act, rb.actAt, rb.actAmount) = (Act.StrangerAdd, 0, units == 0 ? 1 : units);
        (Outcome memory a, Outcome memory b) = _pairOf(ra, rb);
        assertGe(_wealth(b), _wealth(a), "F2.13: the stranger's add left the borrower worse off");
    }

    /* ================================ F2.14-15 a top-up ================================ */

    /// @notice F2.14: an operator's top-up pays the holder alone, the amount less the fee on the term left; the operator takes nothing and is owed nothing.
    function test_F2_14_OperatorTopUp_PaysOnlyTheHolder() public {
        _deposit(bandOff, alice, 4 * D);
        _budget();
        uint256 loanId = _openLong(bandOff, D, 5000);
        (address one, address all) = (address(0x0FE4), address(0x0FE5));
        vm.startPrank(borrower);
        IERC721(ace.POSITION_TITLE()).approve(one, loanId);
        IERC721(ace.POSITION_TITLE()).setApprovalForAll(all, true);
        vm.stopPrank();
        for (uint256 i; i < 2; ++i) {
            _warpBy(2 days);
            address op = i == 0 ? one : all;
            uint256 amount = D / 8;
            uint256 fee = LoanMath.originationFee(amount, uint64(read.loan(loanId).expiry - _now()), BASE);
            (uint256 holder0, uint256 debt0) = (usdc.balanceOf(borrower), read.debtOf(loanId));
            vm.prank(op);
            assertEq(ace.drawMore(loanId, amount, OpenBounds(0, 0, 0)), fee, "fixture: the top-up charges the fee on the term left");
            assertEq(usdc.balanceOf(borrower), holder0 + amount - fee, "F2.14: the holder was not paid the amount less the fee");
            assertEq(usdc.balanceOf(op), 0, "F2.14: the operator was paid");
            assertEq(read.quoteOwedOf(loanId, op), 0, "F2.14: the operator is owed quote");
            assertEq(read.debtOf(loanId), debt0 + amount, "F2.14: the debt did not rise by the amount");
        }
    }

    /// forge-config: default.fuzz.runs = 64
    /// @notice F2.15: a top-up never draws the lender's cash while the record's windowed minimum sits under the price: refused, the pools untouched.
    function testFuzz_F2_15_TheDrawCapRefusesATopUpUnderThePrice(uint256 recordPx, uint256 amount) public {
        _deposit(bandOff, alice, 4 * D);
        _budget();
        uint256 loanId = _openLong(bandOff, D, 5000);
        _warpBy(2 days);
        amount = bound(amount, MIN_PRINCIPAL, D / 4);
        rec.setMinPrice(bound(recordPx, 1, par - 1));
        (uint256 resting0, uint256 lent0, uint256 owed0) = read.lenderPools(alice, address(usdc));
        uint256 cash0 = ace.restingOf(bandOff);
        vm.prank(borrower);
        vm.expectRevert(InsufficientCash.selector);
        ace.drawMore(loanId, amount, OpenBounds(0, 0, 0));
        (uint256 resting1, uint256 lent1, uint256 owed1) = read.lenderPools(alice, address(usdc));
        bytes memory after_ = abi.encode(resting1, lent1, owed1, ace.restingOf(bandOff));
        assertEq(after_, abi.encode(resting0, lent0, owed0, cash0), "F2.15: a refused top-up moved the lender");
        rec.setMinPrice(par);
        vm.prank(borrower);
        ace.drawMore(loanId, amount, OpenBounds(0, 0, 0));
        assertEq(read.debtOf(loanId), D + amount, "fixture: at the price the top-up lands");
    }

    /* ================================ F2.3 a crank ================================ */

    /// @dev A band-on loan at 65% of par under a flat print at `bps`, in the band and above the stop, with and without a keeper.
    function _crankPair(uint256 bps) internal returns (Outcome memory a, Outcome memory b) {
        Run memory ra = _baseRun(Kind.BandOn, 6500, _flatAt(bps, 4));
        Run memory rb = _baseRun(Kind.BandOn, 6500, _flatAt(bps, 4));
        ra.noCranks = true;
        (a, b) = _pairOf(ra, rb);
    }

    /// @notice F2.3 for the party a crank protects: a crank never raises the lender's shortfall.
    function test_F2_3_Crank_NeverRaisesTheLenderShortfall() public {
        for (uint256 i; i < 3; ++i) {
            (Outcome memory a, Outcome memory b) = _crankPair(7600 + 600 * i);
            assertGt(b.sold, 0, "fixture: the keeper's crank lands");
            assertLe(_shortfall(b, Mark.End), _shortfall(a, Mark.End), "F2.3: the crank left the lender shorter");
        }
    }

    /// @notice F2.3 for the party a crank sells: it costs the borrower its haircut on the melt and the book premium, never more.
    /// @notice Ruled: deleverage is the keepers' safety verb, and settling at book is cheaper for the borrower than a sale below it.
    function test_F2_3_Crank_CostsTheBorrowerNoMoreThanTheRuledHaircutAndBookPremium() public {
        for (uint256 i; i < 3; ++i) {
            uint256 bps = 7600 + 600 * i;
            (Outcome memory a, Outcome memory b) = _crankPair(bps);
            uint256 melt = a.debtAtClose - b.debtAtClose;
            assertGt(melt, 0, "fixture: the crank melts debt");
            uint256 haircut = melt * 1e8 / ((10000 - 100) * (10000 - 500));
            uint256 bound = haircut - melt * bps / 10000 + D / 1e4;
            assertLt(_wealth(b), _wealth(a), "ruled: the crank costs the borrower against book settlement");
            assertLe(_wealth(a) - _wealth(b), bound, "F2.3: the crank cost the borrower more than its haircut and the book premium");
        }
    }

    /* ================================ F2.5 a stranger's buy of the settled pot ================================ */

    /// @notice F2.5: a stranger's buy out of a settled pot never lowers the lender's wealth at the record, above or below the price.
    function test_F2_5_StrangerBuy_NeverLowersTheLenderAtTheRecord() public {
        for (uint256 i; i < 2; ++i) {
            uint256 snap = vm.snapshotState();
            uint256 recordBps = i == 0 ? 6000 : 13000;
            Outcome memory o = _runFor(_baseRun(Kind.BandOff, 9000, _dropTo(6000, 1)));
            assertTrue(o.finalized, "fixture: the loan settles");
            _warpBy(TEN7);
            _printBps(recordBps);
            uint256 px = _pxOf(recordBps);
            uint256 before = _lenderAt(o, px);
            uint256 borrowerUnits = read.unitsOwedOf(o.loanId, borrower);
            usdc.mint(stranger, D);
            vm.startPrank(stranger);
            usdc.approve(address(ace), D);
            (uint256 out,) = ace.buyInventory(o.loanId, D / 2, 0, stranger);
            vm.stopPrank();
            assertGt(out, 0, "fixture: the buy fills");
            assertGe(_lenderAt(o, px), before, "F2.5: the stranger's buy lowered the lender at the record");
            assertEq(read.unitsOwedOf(o.loanId, borrower), borrowerUnits, "F2.5: the buy moved the borrower's residual");
            vm.revertToState(snap);
        }
    }

    function _lenderAt(Outcome memory o, uint256 px) internal view returns (uint256) {
        (uint256 resting, uint256 lent, uint256 owed) = read.lenderPools(alice, address(usdc));
        return usdc.balanceOf(alice) + resting + lent + owed + _valueAt(read.invPotOf(o.mid, o.loanId), px);
    }
}
