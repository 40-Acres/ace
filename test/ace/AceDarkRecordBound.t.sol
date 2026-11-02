// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.36;

import {WarpClock} from "../utils/WarpClock.sol";
import {Ace} from "../../src/ace/hub/Ace.sol";
import {AceLens} from "../../src/ace/lens/AceLens.sol";
import {NotSettleable} from "../../src/ace/hub/Settlement.sol";
import {NoRecordPrice} from "../../src/ace/hub/Borrower.sol";
import {MarketParams, OpenBounds} from "../../src/ace/hub/Types.sol";
import {PositionManager} from "../../src/ace/positions/PositionManager.sol";
import {MockERC20} from "../mocks/MockERC20.sol";
import {MockPersistenceRecord} from "../mocks/MockPersistenceRecord.sol";
import {AceFixtures} from "../utils/AceFixtures.sol";
import {AceReader} from "../utils/AceReader.sol";

/// @title AceDarkRecordBound
/// @notice THE PROPERTY: the settlement bound turns on whether a record was ever WIRED, never on whether it answers today.
/// @notice A wired record that has gone dark keeps the NARROW bound, so its borrower is still credited everything above need.
/// @notice Only the recordless class takes the whole coverage line, and the two differ by exactly that wedge.
/// @dev THE SUBJECT IS THE CLASS TEST, which is why this is not a row in `AceRecordlessForfeit`: that suite's
/// @dev subject is what the recordless class does, and its record-backed control holds a LIVE record throughout.
/// @dev The gap between them is the market this suite drives -- wired at genesis, dark by the time it settles.
/// @dev WHY THE CLASS AND NOT THE LIVENESS: darkness is transient, arrives on its own in a thin market, and the
/// @dev moment of exercise belongs to whoever calls the permissionless `forceClose`; a value transfer may not turn on it.
/// @dev The lender's compensation for having no seizure is priced when they rest, off a class genesis fixed.
/// @dev DARKNESS IS NOT ONE STATE, AND THE TWO SHIPPED CLASSES DIVERGE ON IT -- which is why the mock's
/// @dev below-answers are settable apart from `minPrice` rather than derived from it.
/// @dev ORACLE class: one fed price drives both, so a stale round takes the draw and the seizure doors together.
/// @dev VENUE class: silence persists below-ness off the last print while the price channel refuses, BY RULING,
/// @dev so that settlement cannot be stalled by a quiet venue -- title still moves there while no draw can.
/// @dev `_darken` models the ORACLE shape and `_darkenPriceOnly` the VENUE shape, and both are pinned below.
contract AceDarkRecordBoundTest is WarpClock {
    MockERC20 internal usdc; // quote, 6 decimals
    MockERC20 internal coll; // collateral, 18 decimals

    address internal alice = address(0xA11CE); // the lender, and the market's sole named tenant
    address internal borrower = address(0xB0B);
    address internal keeper = address(0xCA11E5);

    uint256 internal constant DEPOSIT = 20_000_000; // the whole resting balance; one tenant, one lot
    uint256 internal constant PRINCIPAL = 11_000_000; // over the fixture's 10e6 minPrincipal
    uint256 internal constant COLL = 10_000e18; // far enough above the line that the two rules differ
    uint64 internal constant TEN7 = 7 days;

    OpenBounds internal OFF = OpenBounds(0, 0, 0);

    /// @dev One hub per rig: the two classes differ in the market-id preimage, and a rig is the cheapest way to hold both.
    struct Rig {
        Ace ace;
        PositionManager pm;
        AceReader read;
        AceLens lens;
        bytes32 id;
        MockPersistenceRecord rec; // zero for the recordless twin
    }

    function setUp() public {
        _warpTo(1_000_000);
        usdc = new MockERC20("USD Coin", "USDC", 6);
        coll = new MockERC20("Collateral", "COLL", 18);
    }

    /* ================================ the ruled behaviour ================================ */

    /// @notice A WIRED RECORD THAT WENT DARK KEEPS THE NARROW BOUND: the borrower is credited everything above need, net of the sliver.
    /// @dev The issue's own repro: live at open, `setMinPrice(0)` thereafter, settled by `forceClose` at expiry.
    /// @dev RED under a liveness test, which would take the coverage line here and credit the wedge to the pot.
    /// @dev The sliver is taken before the bound is priced, so the borrower's credit is the lot less sliver less need.
    function test_DarkRecord_ForceClose_ReturnsTheResidual() public {
        Rig memory w = _wired();
        uint256 loanId = _open(w);
        (uint256 units, uint256 need,) = _unitsNeedLine(w, loanId); // the helper asserts the precondition for every row

        _darken(w);
        _settle(w, loanId);

        uint256 sliver = _sliver(w, loanId);
        assertGt(sliver, 0, "fixture: forceClose must actually credit a sliver");
        assertEq(w.read.unitsOwedOf(loanId, borrower), units - sliver - need, "a darkened record must not widen the bound");
    }

    /// @notice THE TWO CLASSES, SIDE BY SIDE: the same loan, the same numbers, differing by exactly the coverage wedge.
    /// @dev Asserted as a DIFFERENCE so neither arm can be satisfied alone: a rule that took the line everywhere,
    /// @dev and a rule that took need everywhere, each satisfy one equality and break the subtraction.
    function test_RecordlessTwin_TakesTheWholeCoverageLine() public {
        Rig memory w = _wired();
        Rig memory n = _recordless();
        uint256 darkLoan = _open(w);
        uint256 noneLoan = _open(n);

        (uint256 units, uint256 need, uint256 line) = _unitsNeedLine(w, darkLoan);
        (uint256 u2, uint256 n2, uint256 l2) = _unitsNeedLine(n, noneLoan);
        assertEq(u2, units, "fixture: the twin must be the same loan, or the difference below is not the class");
        assertEq(n2, need, "fixture: the twin's need must match");
        assertEq(l2, line, "fixture: the twin's line must match");

        _darken(w);
        _settle(w, darkLoan);
        _settle(n, noneLoan);

        uint256 keptDark = w.read.unitsOwedOf(darkLoan, borrower);
        uint256 keptNone = n.read.unitsOwedOf(noneLoan, borrower);
        assertEq(_sliver(w, darkLoan), _sliver(n, noneLoan), "fixture: the twins pay the same sliver, so it cancels in the difference");
        assertEq(keptDark, units - _sliver(w, darkLoan) - need, "the dark wired market returns the residual at need");
        assertEq(keptNone, units - _sliver(n, noneLoan) - line, "the recordless market forfeits up to the coverage line");
        assertEq(keptDark - keptNone, line - need, "the classes must differ by exactly the wedge, and by nothing else");
    }

    /* ======================= settlement survives a record that is worse ======================= */

    /// @notice A record that REVERTS settles anyway: `forceClose` consults nothing, so it cannot be bricked.
    /// @dev THE ROW THAT GOES RED IF ANYONE IMPLEMENTS THE LIVENESS TEST WITH A REVERTING READ.
    /// @dev A sick record is a different state from a dark one: that answers zero, this refuses to answer.
    function test_SickRecord_SettlesAnyway() public {
        Rig memory w = _wired();
        uint256 loanId = _open(w);
        (uint256 units, uint256 need,) = _unitsNeedLine(w, loanId);

        w.rec.setSick(true);
        _settle(w, loanId);

        assertEq(w.read.unitsOwedOf(loanId, borrower), units - _sliver(w, loanId) - need, "a sick record neither blocks the door nor widens it");
    }

    /// @notice A record that returns ZERO BYTES settles anyway: the call succeeds and the decode is what would fail.
    /// @dev The fourth record shape, and the one a try/catch cannot absorb, so it is pinned apart from the sick row.
    function test_ShortAnswerRecord_SettlesAnyway() public {
        Rig memory w = _wired();
        uint256 loanId = _open(w);
        (uint256 units, uint256 need,) = _unitsNeedLine(w, loanId);

        w.rec.setShortAnswer(true);
        _settle(w, loanId);

        assertEq(w.read.unitsOwedOf(loanId, borrower), units - _sliver(w, loanId) - need, "a short answer neither blocks the door nor widens it");
    }

    /* ============================== the ruling's own premise ============================== */

    /// @notice DARKNESS CLOSES DOORS: no new draw, no seizure, and no extension, so the loan settles at tenor.
    /// @notice The ruling rests on this, so it is pinned rather than argued: a change that reopens a door reopens the ruling.
    /// @dev Three doors in one row on purpose -- they are one fact, and a reader checking the ruling wants them together.
    function test_DarkRecord_ClosesTheOtherDoors() public {
        Rig memory w = _wired();
        uint256 loanId = _open(w);
        _darken(w);

        coll.mint(borrower, COLL);
        vm.startPrank(borrower);
        coll.approve(address(w.pm), COLL);
        vm.expectRevert(NoRecordPrice.selector);
        w.ace.open(w.id, COLL, PRINCIPAL, TEN7, borrower, OFF);
        vm.stopPrank();

        /// @dev WEAK ON ITS OWN, and said so rather than dressed up: a LIVE record answering not-below reverts
        /// @dev identically. The venue row below is the discriminator -- same door, below-ness true, and it OPENS.
        vm.expectRevert(NotSettleable.selector);
        w.ace.finalize(loanId);

        _warpTo(uint256(w.read.loan(loanId).expiry) - 1);
        (bool ok, bytes4 why,) = w.ace.tryExtend(loanId, 0, "", borrower);
        assertFalse(ok, "a dark record refuses the borrower's extension");
        assertEq(why, NoRecordPrice.selector, "by name, before the lender's policy is asked");
        _warpTo(w.read.loan(loanId).expiry);
        vm.prank(keeper);
        w.ace.forceClose(loanId);
        assertTrue(w.read.loan(loanId).closedAt != 0, "so forceClose ends the loan");
        assertGt(w.read.unitsOwedOf(loanId, borrower), 0, "and it SETTLES, crediting the borrower its residual");
    }

    /// @notice THE VENUE SHAPE: the price channel goes dark while below-ness survives the silence, and title still moves.
    /// @notice So a dark record does NOT deprive every lender of seizure -- and where it does not, nothing is owed in its place.
    /// @dev This is the class the finding's premise misses, and it is why the conceded loss is an ORACLE-class loss.
    /// @dev The bound is asserted too: seizure being OPEN here changes who may act, never what the settlement takes.
    function test_VenueShape_PriceDarkButBelowNessSurvives_TitleStillMoves() public {
        Rig memory w = _wired();
        uint256 loanId = _open(w);
        (uint256 units, uint256 need,) = _unitsNeedLine(w, loanId);

        _darkenPriceOnly(w);

        vm.prank(keeper);
        w.ace.finalize(loanId); // reverts NotSettleable if silence ever stops persisting below-ness
        assertEq(w.read.unitsOwedOf(loanId, borrower), units - need - w.read.unitsOwedOf(loanId, keeper), "the bound is the narrow one here too");
    }

    /// @notice EVERY RETIRED UNIT IS ACCOUNTED FOR under the dark class too: borrower plus keeper plus pot is the lot.
    /// @dev Formula-free, so it names no bound and cannot be satisfied by re-deriving the one under test.
    function test_ConservationHolds_DarkRecord() public {
        Rig memory w = _wired();
        uint256 loanId = _open(w);
        (uint256 units,,) = _unitsNeedLine(w, loanId);

        _darken(w);
        _settle(w, loanId);

        uint256 owned = w.read.unitsOwedOf(loanId, borrower) + w.read.unitsOwedOf(loanId, keeper) + w.read.invPotOf(w.id, loanId);
        assertEq(owned, units, "units left custody that no ledger entry names");
    }

    /* ===================================== the rigs ===================================== */

    /// @dev A market whose record is WIRED and LIVE at genesis; every row that needs it dark calls `_darken`.
    function _wired() internal returns (Rig memory r) {
        MockPersistenceRecord rec = new MockPersistenceRecord(address(usdc), address(coll));
        rec.setMinPrice(type(uint256).max); // no draw cap: the subject is the settlement bound, never admission
        r = _rig(address(rec));
        r.rec = rec;
    }

    /// @dev The twin: same tokens, same params, no record at all. The class the coverage line belongs to.
    function _recordless() internal returns (Rig memory r) {
        r = _rig(address(0));
    }

    function _rig(address record) internal returns (Rig memory r) {
        MarketParams memory p = AceFixtures.marketParams(address(usdc), address(coll));
        p.record = record;
        p.lender = alice;
        AceFixtures.Deployment memory d = AceFixtures.deploy(p);
        r.ace = d.ace;
        r.pm = d.positionManager;
        r.read = d.read;
        r.id = d.id;
        r.lens = new AceLens(address(d.ace));
    }

    /// @dev The ORACLE shape: one fed price answers everything, so a stale round takes the below-answers with it.
    function _darken(Rig memory r) internal {
        r.rec.setMinPrice(0);
        r.rec.setBelow(false);
        r.rec.setSettleBelow(false);
    }

    /// @dev The VENUE shape: the price channel refuses over the silence while below-ness stands on the last print.
    function _darkenPriceOnly(Rig memory r) internal {
        r.rec.setMinPrice(0);
        r.rec.setBelow(true);
        r.rec.setSettleBelow(true);
    }

    function _open(Rig memory r) internal returns (uint256 loanId) {
        usdc.mint(alice, DEPOSIT);
        vm.startPrank(alice);
        usdc.approve(address(r.ace), DEPOSIT);
        r.ace.deposit(r.id, DEPOSIT);
        vm.stopPrank();

        coll.mint(borrower, COLL);
        vm.startPrank(borrower);
        coll.approve(address(r.pm), COLL);
        loanId = r.ace.open(r.id, COLL, PRINCIPAL, TEN7, borrower, OFF);
        vm.stopPrank();
    }

    /// @dev The line comes from the shipped lens as a SUBTRACTION, never re-derived, so this cannot admit a wrong form.
    /// @dev CALL IT BEFORE DARKENING, and the assertion is what enforces that rather than a comment nobody reads.
    /// @dev Under a dark record the floor folds to zero, `requiredAt` returns its max sentinel, and `line` becomes
    /// @dev `units` silently -- every row would then assert against a bound it had already destroyed.
    function _unitsNeedLine(Rig memory r, uint256 loanId) internal returns (uint256 units, uint256 need, uint256 line) {
        units = r.read.loan(loanId).collateralUnits;
        need = r.lens.collateralNeeded(r.id, loanId);
        line = units - r.lens.withdrawableUnits(r.id, loanId);
        assertLt(line, units, "fixture: the line was read off a dark record, so it folded to the whole lot");
        assertGt(line, need, "fixture: coverage must exceed need, or every row here proves nothing");
    }

    /// @dev `forceClose` at expiry by the keeper, whose sliver comes off the lot before the bound.
    function _settle(Rig memory r, uint256 loanId) internal {
        _warpAtLeastTo(r.read.loan(loanId).expiry);
        vm.prank(keeper);
        r.ace.forceClose(loanId);
    }

    function _sliver(Rig memory r, uint256 loanId) internal view returns (uint256) {
        return r.read.unitsOwedOf(loanId, keeper);
    }
}
