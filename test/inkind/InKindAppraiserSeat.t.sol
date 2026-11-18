// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.36;

import {PolicyRefused} from "../../src/ace/hub/Borrower.sol";
import {Loan} from "../../src/ace/hub/Types.sol";
import {Extension, IRollPolicy} from "../../src/interfaces/IRollPolicy.sol";
import {IInKindTerms, Quote, RollQuote} from "./InKindSurface.sol";
import {InKindRig} from "./InKindRig.sol";

/// @title InKindAppraiserSeat
/// @notice Who prices: an appointment pends the timelock as an appointee and a `validAt`, and the instant lever is a halt to zero.
/// @notice The curator submits; anyone accepts once `validAt` has passed; the curator or the guardian revokes a pending one or halts.
/// @notice A halted seat validates no signature, so no borrow or extension is priced until an appointment lands.
contract InKindAppraiserSeatTest is InKindRig {
    function setUp() public override {
        super.setUp();
        _lp(alice, LP_CASH);
    }

    function _borrowExpecting(bytes4 err, bytes memory data) internal {
        _fund(address(tokA), borrower, UNITS);
        vm.prank(borrower);
        vm.expectRevert(err);
        vault.borrow(_req(address(tokA), UNITS, PRINCIPAL, MIN_TENOR), data, "");
    }

    /// @dev The extension the hub hands the vault when the holder extends `id` now: its own tenor from now, `dst` a copy of `src`.
    function _ext(uint256 id) internal view returns (Extension memory e) {
        Loan memory l = read.loan(id);
        (e.caller, e.loanId, e.borrower, e.units, e.debt, e.newDebt) = (l.borrower, id, l.borrower, l.collateralUnits, l.debt, l.debt);
        (e.expiry, e.newExpiry, e.src, e.dst) = (l.expiry, uint64(_now()) + l.tenor, _mp(id), _mp(id));
    }

    /// @dev The roll quote for `id` issued now, at the market's own price.
    function _rq(uint256 id) internal view returns (RollQuote memory) {
        return RollQuote({loanId: id, expiry: uint64(_expiry(id)), price: _mp(id).price, issuedAt: uint64(_now())});
    }

    /// @dev Nothing is pending: the view reads zero, and an accept has nothing due.
    function _assertNothingPending() internal {
        (address p, uint64 validAt) = terms.pendingAppraiser();
        assertEq(p, address(0), "no appointment pending");
        assertEq(validAt, 0, "and no clock running");
        vm.prank(stranger);
        vm.expectRevert(IInKindTerms.NothingDue.selector);
        terms.acceptAppraiser();
    }

    // ---- an appointment pends the timelock ----

    /// @notice A pending appointment prices nothing: the appointee's quote refuses `BadSignature`, and the incumbent's still prices.
    function test_submitAppraiser_aPendingAppraisersQuoteIsRefused() public {
        address next = vm.addr(ROGUE_KEY);
        vm.expectEmit(true, false, false, true, address(terms));
        emit IInKindTerms.SubmitAppraiser(next, uint64(_now() + TIMELOCK));
        vm.prank(curator);
        terms.submitAppraiser(next);
        (address p, uint64 validAt) = terms.pendingAppraiser();
        assertEq(p, next, "the appointment is pending");
        assertEq(validAt, _now() + TIMELOCK, "until the timelock has run");
        assertEq(terms.APPRAISER(), appraiser, "and the incumbent holds the seat");
        Quote memory q = _quote(address(tokA), PRICE);
        _borrowExpecting(IInKindTerms.BadSignature.selector, _dataBy(q, ROGUE_KEY));
        Quote memory honest = _quote(address(tokA), PRICE);
        assertGt(_borrowWith(honest, _data(honest), UNITS, PRINCIPAL, MIN_TENOR), 0, "the incumbent's quote still prices");
    }

    /// @notice A pending appointment consents to no extension either: the appointee's roll gets no answer, and the incumbent's still extends.
    function test_submitAppraiser_aPendingAppraisersRollIsRefused() public {
        uint256 loanId = _open(address(tokA));
        vm.prank(curator);
        terms.submitAppraiser(vm.addr(ROGUE_KEY));
        _warpAtLeastTo(_expiry(loanId) - 1 hours);
        bytes memory rogue = _rollData(_rq(loanId), ROGUE_KEY);
        assertEq(vault.admitsExtension(_ext(loanId), rogue), bytes4(0), "the appointee's roll gets no consent while pending");
        _armFee(loanId, MIN_TENOR);
        vm.prank(borrower);
        vm.expectRevert(PolicyRefused.selector);
        ace.extend(loanId, 0, rogue);
        bytes memory honest = _rollData(_rq(loanId), APPRAISER_KEY);
        _armFee(loanId, MIN_TENOR);
        vm.prank(borrower);
        ace.extend(loanId, 0, honest);
        assertEq(_expiry(loanId), _now() + MIN_TENOR, "the incumbent's roll still extends");
    }

    /// @notice The appointment lands only once the timelock has run: a second early refuses `NothingDue`, and at `validAt` anyone seats it.
    function test_acceptAppraiser_landsOnlyAfterTheTimelock() public {
        address next = vm.addr(ROGUE_KEY);
        vm.prank(curator);
        terms.submitAppraiser(next);
        (, uint64 validAt) = terms.pendingAppraiser();
        _warpTo(validAt - 1);
        vm.prank(stranger);
        vm.expectRevert(IInKindTerms.NothingDue.selector);
        terms.acceptAppraiser();
        assertEq(terms.APPRAISER(), appraiser, "a second early, the incumbent stays");
        _warpTo(validAt);
        vm.expectEmit(true, true, false, false, address(terms));
        emit IInKindTerms.AppraiserSet(appraiser, next);
        vm.prank(stranger);
        terms.acceptAppraiser();
        assertEq(terms.APPRAISER(), next, "at validAt a stranger seats the appointee");
        _assertNothingPending();
        Quote memory q = _quote(address(tokA), PRICE);
        assertGt(_borrowWith(q, _dataBy(q, ROGUE_KEY), UNITS, PRINCIPAL, MIN_TENOR), 0, "and its quote prices");
    }

    /// @notice With nothing ever submitted there is nothing to accept.
    function testRevert_acceptAppraiser_nothingPending() public {
        _assertNothingPending();
    }

    /// @notice A new submit replaces the pending appointment AND restarts the clock: the first appointee never lands, the second waits its own timelock.
    function test_submitAppraiser_aNewSubmitReplacesThePendingOneAndRestartsItsClock() public {
        address first = vm.addr(ROGUE_KEY);
        uint256 nextKey = 0xA99A15E5;
        address second = vm.addr(nextKey);
        vm.prank(curator);
        terms.submitAppraiser(first);
        (, uint64 firstValidAt) = terms.pendingAppraiser();
        _warpBy(TIMELOCK - 1 hours);
        uint64 secondValidAt = uint64(_now() + TIMELOCK);
        vm.expectEmit(true, false, false, true, address(terms));
        emit IInKindTerms.SubmitAppraiser(second, secondValidAt);
        vm.prank(curator);
        terms.submitAppraiser(second);
        (address p, uint64 validAt) = terms.pendingAppraiser();
        assertEq(p, second, "the second appointment replaced the first");
        assertEq(validAt, secondValidAt, "and its clock runs from its own submit");

        _warpTo(firstValidAt);
        vm.prank(stranger);
        vm.expectRevert(IInKindTerms.NothingDue.selector);
        terms.acceptAppraiser();
        _warpTo(secondValidAt - 1);
        vm.prank(stranger);
        vm.expectRevert(IInKindTerms.NothingDue.selector);
        terms.acceptAppraiser();
        assertEq(terms.APPRAISER(), appraiser, "the incumbent holds the seat until the second clock has run");

        _warpTo(secondValidAt);
        vm.expectEmit(true, true, false, false, address(terms));
        emit IInKindTerms.AppraiserSet(appraiser, second);
        vm.prank(stranger);
        terms.acceptAppraiser();
        assertEq(terms.APPRAISER(), second, "the second appointee is seated");
        Quote memory q = _quote(address(tokA), PRICE);
        _borrowExpecting(IInKindTerms.BadSignature.selector, _dataBy(q, ROGUE_KEY));
        Quote memory ok = _quote(address(tokA), PRICE);
        assertGt(_borrowWith(ok, _dataBy(ok, nextKey), UNITS, PRINCIPAL, MIN_TENOR), 0, "and only its quote prices");
    }

    /// @notice An accept seats the stored appointee, never the caller and never the incumbent, and anyone may run it.
    function test_acceptAppraiser_seatsTheAppointeeWhoeverCalls() public {
        address next = vm.addr(ROGUE_KEY);
        _submitAppraiser(next);
        vm.prank(curator);
        terms.acceptAppraiser();
        assertEq(terms.APPRAISER(), next, "the curator's accept seats the appointee, as a stranger's would");
        _assertNothingPending();
    }

    // ---- revoking a pending appointment ----

    /// @dev `who` revokes a pending appointment: it is gone, nothing lands after the timelock, and the incumbent keeps the seat.
    function _assertRevokes(address who) internal {
        vm.prank(curator);
        terms.submitAppraiser(vm.addr(ROGUE_KEY));
        vm.expectEmit(true, false, false, false, address(terms));
        emit IInKindTerms.RevokePendingAppraiser(who);
        vm.prank(who);
        terms.revokePendingAppraiser();
        _warpBy(TIMELOCK);
        _assertNothingPending();
        assertEq(terms.APPRAISER(), appraiser, "the incumbent keeps the seat");
    }

    function test_revokePendingAppraiser_byTheCurator() public {
        _assertRevokes(curator);
    }

    function test_revokePendingAppraiser_byTheGuardian() public {
        _assertRevokes(guardian);
    }

    function testRevert_revokePendingAppraiser_byAStranger() public {
        vm.prank(curator);
        terms.submitAppraiser(vm.addr(ROGUE_KEY));
        vm.prank(stranger);
        vm.expectRevert(IInKindTerms.NotCurator.selector);
        terms.revokePendingAppraiser();
    }

    // ---- the halt ----

    /// @dev `who` halts: the incumbent's own quote and roll, and garbage bytes the zero account might recover to, all go unpriced.
    function _assertHaltRefusesBorrowsAndRolls(address who) internal {
        uint256 loanId = _open(address(tokA));
        _warpAtLeastTo(_expiry(loanId) - 1 hours);
        Quote memory q = _quote(address(tokA), PRICE);
        bytes memory data = _data(q);
        bytes memory roll = _rollData(_rq(loanId), APPRAISER_KEY);
        assertEq(vault.admitsExtension(_ext(loanId), roll), IRollPolicy.admitsExtension.selector, "premise: the roll admits before the halt");

        vm.expectEmit(true, true, false, false, address(terms));
        emit IInKindTerms.AppraiserSet(appraiser, address(0));
        vm.prank(who);
        terms.haltAppraiser();
        assertEq(terms.APPRAISER(), address(0), "the seat is empty at once");

        _borrowExpecting(IInKindTerms.BadSignature.selector, data);
        _borrowExpecting(IInKindTerms.BadSignature.selector, abi.encode(q, hex"deadbeef"));
        assertFalse(terms.spent(q.nonce), "a refused borrow burns no nonce");
        assertEq(vault.admitsExtension(_ext(loanId), roll), bytes4(0), "the roll gets no consent");
        assertEq(vault.admitsExtension(_ext(loanId), abi.encode(_rq(loanId), bytes(""))), bytes4(0), "nor does an empty signature");
        _armFee(loanId, MIN_TENOR);
        vm.prank(borrower);
        vm.expectRevert(PolicyRefused.selector);
        ace.extend(loanId, 0, roll);
    }

    function test_haltAppraiser_byTheCuratorRefusesBorrowsAndRollQuotes() public {
        _assertHaltRefusesBorrowsAndRolls(curator);
    }

    function test_haltAppraiser_byTheGuardianRefusesBorrowsAndRollQuotes() public {
        _assertHaltRefusesBorrowsAndRolls(guardian);
    }

    function testRevert_haltAppraiser_byAStranger() public {
        vm.prank(stranger);
        vm.expectRevert(IInKindTerms.NotCurator.selector);
        terms.haltAppraiser();
        assertEq(terms.APPRAISER(), appraiser, "the seat stands");
    }

    /// @notice After a halt only an appointment reopens lending: the halt leaves a pending one in place, and it lands after the timelock.
    function test_haltAppraiser_anAppointmentReopensLending() public {
        address next = vm.addr(ROGUE_KEY);
        vm.prank(curator);
        terms.submitAppraiser(next);
        vm.prank(guardian);
        terms.haltAppraiser();
        (address p,) = terms.pendingAppraiser();
        assertEq(p, next, "the halt left the pending appointment in place");
        _warpBy(TIMELOCK);
        _acceptAppraiser();
        Quote memory q = _quote(address(tokA), PRICE);
        assertGt(_borrowWith(q, _dataBy(q, ROGUE_KEY), UNITS, PRINCIPAL, MIN_TENOR), 0, "the appointee's quote reopens lending");
    }

    /// @notice A halt mid-timelock moves neither the appointee nor its clock: the rotation lands at the validAt it was submitted with, from zero.
    function test_haltAppraiser_midTimelockKeepsThePendingClock() public {
        address next = vm.addr(ROGUE_KEY);
        vm.prank(curator);
        terms.submitAppraiser(next);
        (, uint64 validAt) = terms.pendingAppraiser();
        _warpBy(1 days);
        vm.prank(guardian);
        terms.haltAppraiser();
        (address p, uint64 v) = terms.pendingAppraiser();
        assertEq(p, next, "the appointee is still pending");
        assertEq(v, validAt, "on the clock it was submitted with");
        _warpTo(validAt);
        vm.expectEmit(true, true, false, false, address(terms));
        emit IInKindTerms.AppraiserSet(address(0), next);
        vm.prank(stranger);
        terms.acceptAppraiser();
        assertEq(terms.APPRAISER(), next, "the rotation lands on time, onto the halted seat");
    }

    /// @notice A halted seat with nothing pending stays halted: an accept has nothing due, and only a fresh appointment, a timelock on, reopens it.
    function test_haltAppraiser_withNothingPendingStaysHaltedUntilAnAppointmentLands() public {
        vm.prank(curator);
        terms.haltAppraiser();
        vm.prank(stranger);
        vm.expectRevert(IInKindTerms.NothingDue.selector);
        terms.acceptAppraiser();
        assertEq(terms.APPRAISER(), address(0), "nothing reseats a halted seat but an appointment");
        vm.prank(curator);
        terms.haltAppraiser();
        assertEq(terms.APPRAISER(), address(0), "a second halt is a no-op, not a refusal");
        _appoint(appraiser);
        assertEq(terms.APPRAISER(), appraiser, "the incumbent's own key returns only through the timelock");
    }

    // ---- the production rotation ----

    /// @notice The beta's EOA hands the seat to a Safe: the appointment waits the timelock, and once it lands every live EOA quote and roll dies.
    function test_acceptAppraiser_fromTheBetaEoaToASafeKillsTheEoasQuotes() public {
        uint256 loanId = _open(address(tokA));
        (address safe, uint256[] memory keys) = _safe(2, 3);
        _submitAppraiser(safe);
        _warpAtLeastTo(_expiry(loanId) - 1 hours);
        Quote memory eoaQuote = _quote(address(tokA), PRICE);
        bytes memory eoaData = _data(eoaQuote);
        bytes memory eoaRoll = _rollData(_rq(loanId), APPRAISER_KEY);
        assertEq(vault.admitsExtension(_ext(loanId), eoaRoll), IRollPolicy.admitsExtension.selector, "premise: the EOA still signs while pending");
        _acceptAppraiser();
        assertEq(terms.APPRAISER(), safe, "the Safe holds the seat");

        _borrowExpecting(IInKindTerms.BadSignature.selector, eoaData);
        assertEq(vault.admitsExtension(_ext(loanId), eoaRoll), bytes4(0), "the EOA's live roll died with the rotation");
        Quote memory q = _quote(address(tokA), PRICE);
        bytes memory safeData = abi.encode(q, _safeSigs(safe, keys, 2, terms.hashQuote(q)));
        assertGt(_borrowWith(q, safeData, UNITS, PRINCIPAL, MIN_TENOR), 0, "two of the Safe's three owners price a loan");
        RollQuote memory rq = _rq(loanId);
        bytes memory safeRoll = abi.encode(rq, _safeSigs(safe, keys, 2, terms.hashRollQuote(rq)));
        _armFee(loanId, MIN_TENOR);
        vm.prank(borrower);
        ace.extend(loanId, 0, safeRoll);
        assertEq(_expiry(loanId), _now() + MIN_TENOR, "and extend one");
    }
}
