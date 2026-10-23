// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.36;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {WarpClock} from "../utils/WarpClock.sol";
import {Ace} from "../../src/ace/hub/Ace.sol";
import {Borrower} from "../../src/ace/hub/Borrower.sol";
import {AceLens} from "../../src/ace/lens/AceLens.sol";
import {MarketParams, MigrateArgs, OpenBounds} from "../../src/ace/hub/Types.sol";
import {PositionManager} from "../../src/ace/positions/PositionManager.sol";
import {PriceFrame} from "../utils/PriceFrame.sol";
import {MockERC20} from "../mocks/MockERC20.sol";
import {MockPersistenceRecord} from "../mocks/MockPersistenceRecord.sol";
import {IPersistenceRecord} from "../../src/interfaces/IPersistenceRecord.sol";
import {AceFixtures} from "../utils/AceFixtures.sol";
import {AceReader} from "../utils/AceReader.sol";

/// @notice The continuation predicate, declared test-side exactly as AceContinuePredicate declares it.
interface IAceTryContinue {
    function tryContinue(uint256 id) external view returns (bool ok, bytes4 reason, uint256 principal);
}

interface IAceAuto {
    function setAutoRefinance(uint256 id, uint64 tenor, uint16 minBufferBps, uint16 maxFeeBps) external;
}

/// @title AceFoldSingleRead
/// @notice The armed expiry roll asks the creator-chosen RECORD once, and funds at the answer it got.
/// @notice THE GATE HALF IS GONE: admission is an address comparison now, so there is no call left to count.
/// @notice A3 went with it -- a gate that changed its answer mid-roll was the hazard, and it cannot exist.
/// @notice N1/N2 count the reads from the VM side, which is the only side that can count a staticcall.
/// @notice N3 pins the manual doors at the whole gauntlet: a caller that asked nothing gets asked everything.
/// @notice N4 pins that a carried open moves no quote at all, because the hub would be paying itself.
/// @notice N6 probes TOTALITY at the tightest admissible fold: what the predicate admits, the commit completes.
/// @notice N6b pins that the view previews the unpaid verb, never the paid fold, one unit past that edge.
contract AceFoldSingleReadTest is WarpClock {
    Ace internal ace;
    AceReader internal read;
    AceLens internal lens;
    PositionManager internal pm;

    MockERC20 internal usdc; // quote, 6 decimals
    MockERC20 internal coll; // collateral, 18 decimals
    MockPersistenceRecord internal record;

    bytes32 internal mid; // the counting market: a plain record, live, and no borrower named

    address internal alice = address(0xA11CE); // the lender
    address internal borrower = address(0xB0B);
    address internal keeper = address(0xCA11E5); // any third party running the crank

    uint256 internal TICK; // ~1.1007x par; assigned in setUp, since par is not a compile-time value
    uint256 internal CAP; // the windowed minimum the record answers, in the hub's frame
    uint256 internal constant DEPOSIT = 5_000e6;
    uint256 internal constant PRINCIPAL = 4_500e6;
    uint256 internal constant COLL = 10_000e18;
    uint64 internal constant TEN7 = 7 days;

    OpenBounds internal OFF = OpenBounds(0, 0, 0);

    /// @dev This suite's pair, so a tick reads as its distance from par rather than as a grid coordinate.
    /// @param offset Ticks above par.
    /// @return The absolute grid tick.
    function _price(int24 offset) internal view returns (uint256) {
        return AceFixtures.priceAt(address(usdc), address(coll), offset);
    }

    function setUp() public {
        _warpTo(1_000_000);
        usdc = new MockERC20("USD Coin", "USDC", 6);
        coll = new MockERC20("Collateral", "COLL", 18);
        TICK = _price(960);
        CAP = AceFixtures.px(2e18, address(usdc), address(coll));
        record = new MockPersistenceRecord(address(usdc), address(coll));
        record.setObserved(AceFixtures.px(1e18, address(usdc), address(coll)));
        record.setMinPrice(CAP);

        MarketParams memory p = AceFixtures.marketParams(address(usdc), address(coll));
        p.record = address(record);
        p.lender = alice; // sole tenancy: the depositor and the market's named lender are one
        p.price = TICK; // WAS the rung the lender rested at; it is the market's own bid now
        AceFixtures.Deployment memory d = AceFixtures.deploy(p);
        (ace, pm, read, mid) = (d.ace, d.positionManager, d.read, d.id);
        lens = new AceLens(address(ace));
        assertGt(CAP, TICK, "fixture: the answered minimum sits ABOVE the market's bid, so the cap admits");
    }

    /* ============ N1: one record call across a whole armed roll ============ */

    /// @notice The headline count. A record cannot tally its own staticcalls, so the VM tallies them instead.
    /// @notice Both a SELECTOR count and an exact-calldata count run: the first is total, the second pins the args.
    /// @dev The probe below the warp is spent BEFORE the expectations are armed, so it is not one of the counted reads.
    function test_N1_ArmedRoll_AsksTheRecordOnce() public {
        uint256 loanId = _armedLoanOn(mid);
        _warpTo(read.loan(loanId).expiry + 1);
        (bool ok,, uint256 principal) = IAceTryContinue(address(ace)).tryContinue(loanId);
        assertTrue(ok, "fixture: the roll must be admissible, or the counted path is the settle branch");

        uint256 before = read.loanCount();
        _expectOneRecordCall();
        vm.prank(keeper);
        ace.forceClose(loanId);

        assertEq(read.loanCount(), before + 1, "the counts are of a ROLL: a settle would have counted a different path");
        assertTrue(ace.isClosed(loanId), "and the predecessor really did retire inside that call");
    }

    /* ============ N2: the same counts on the permissionless verb, and across its batch ============ */

    /// @notice `refinanceByPolicy` reaches the same fold body, so it inherits the same single reads.
    function test_N2_RefinanceByPolicy_AsksTheRecordOnce() public {
        uint256 loanId = _armedLoanOn(mid);
        _warpTo(read.loan(loanId).expiry + 1);
        (bool ok,, uint256 principal) = IAceTryContinue(address(ace)).tryContinue(loanId);
        assertTrue(ok, "fixture: the roll must be admissible");

        _expectOneRecordCall();
        vm.prank(keeper);
        uint256 newId = ace.refinanceByPolicy(loanId);
        assertGt(newId, loanId, "the verb produced a successor");
    }

    /// @notice The batch builds a `PreAdmitted` per iteration, so two loans cost two reads and never four.
    /// @dev The leak this refuses is a cached answer surviving into the next id: it would show up as 2, not 4.
    function test_N2b_RefinanceByPolicies_TwoLoansCostTwoReadsEach() public {
        _lend(mid, DEPOSIT * 8);
        uint256 a = _openArmed(mid);
        uint256 b = _openArmed(mid);
        _warpTo(read.loan(a).expiry + 1);

        (bool okA,,) = IAceTryContinue(address(ace)).tryContinue(a);
        (bool okB,,) = IAceTryContinue(address(ace)).tryContinue(b);
        assertTrue(okA && okB, "fixture: both loans must be admissible, or the batch is not a two-roll batch");

        uint256[] memory ids = new uint256[](2);
        (ids[0], ids[1]) = (a, b);
        vm.expectCall(address(record), abi.encodeWithSelector(IPersistenceRecord.minPrice.selector), 2);
        vm.prank(keeper);
        uint256[] memory newIds = ace.refinanceByPolicies(ids);
        assertGt(newIds[0] * newIds[1], 0, "both legs of the batch produced a successor");
    }

    /* ============ N3: a caller that asked nothing gets asked everything ============ */

    /// @notice A borrower's own refinance establishes nothing before it calls, so its open runs the whole gauntlet.
    /// @dev ONE read, not zero: an over-applied thread would show up here as a skipped record on a caller's request.
    function test_N3_ManualRefinance_StillAsksTheRecordOnceInsideMigrate() public {
        uint256 loanId = _armedLoanOn(mid);
        uint256 fresh = (read.debtOf(loanId) * 105) / 100;

        vm.expectCall(address(record), abi.encodeWithSelector(IPersistenceRecord.minPrice.selector), 1);
        vm.prank(borrower);
        uint256 newId = ace.refinance(loanId, fresh, TEN7, OFF);
        assertGt(newId, loanId, "the manual refinance produced a successor");
    }

    /// @notice `refinanceTo` is the same body reached through the args struct, and it asks the same once.
    function test_N3b_RefinanceTo_StillAsksTheRecordOnceInsideMigrate() public {
        uint256 loanId = _armedLoanOn(mid);
        uint256 fresh = (read.debtOf(loanId) * 105) / 100;
        MigrateArgs memory m = MigrateArgs(loanId, mid, fresh, TEN7, OFF, 0, address(0));

        vm.expectCall(address(record), abi.encodeWithSelector(IPersistenceRecord.minPrice.selector), 1);
        vm.prank(borrower);
        uint256 newId = ace.refinanceTo(m);
        assertGt(newId, loanId, "the args-struct door produced a successor");
    }

    /// @notice The open door is untouched at one record read.
    /// @dev A counted expectation may be set once per test, so the two doors are counted in two tests.
    function test_N3c_Open_UnchangedAtOneReadEach() public {
        _lend(mid, DEPOSIT * 4);
        coll.mint(borrower, COLL);
        vm.prank(borrower);
        coll.approve(address(pm), COLL);

        vm.expectCall(address(record), abi.encodeWithSelector(IPersistenceRecord.minPrice.selector), 1);
        vm.prank(borrower);
        uint256 loanId = ace.open(mid, COLL, PRINCIPAL, TEN7, borrower, OFF);
        assertEq(read.loan(loanId).debt, PRINCIPAL, "the open really did draw");
    }

    /// @notice The quote door reads the record exactly as the open door does: one read, never two and never none.
    function test_N3d_PreviewOpen_UnchangedAtOneReadEach() public {
        _lend(mid, DEPOSIT * 4);
        vm.expectCall(address(record), abi.encodeWithSelector(IPersistenceRecord.minPrice.selector), 1);
        Borrower.Quote memory q = ace.previewOpen(mid, COLL, PRINCIPAL, TEN7, borrower, OFF);
        assertGt(q.postDrawFloor, 0, "the quote is a real one, so the walk actually ran");
    }

    /* ============ N4: a carried open moves no quote at all ============ */

    /// @notice The migration payee is the hub, so the payout leg is skipped rather than paid to itself.
    /// @dev The piggyback sweep is drained first: it is a real quote transfer, and it is not the migration's.
    function test_N4_TheArmedRollMovesNoQuote() public {
        uint256 rollId = _armedLoanOn(mid);
        _warpTo(read.loan(rollId).expiry + 1);
        ace.sweepRevenue(mid); // stamps the period, so `_sweepIfDue` inside forceClose is structurally inert

        uint256 before = read.loanCount();
        vm.expectCall(address(usdc), abi.encodeWithSelector(IERC20.transfer.selector), 0);
        vm.prank(keeper);
        ace.forceClose(rollId);
        assertEq(read.loanCount(), before + 1, "the roll ran, and it moved no quote");
    }

    /// @notice The manual door nets the same way, then PAYS the net out: one quote transfer, and the draw never goes out and back.
    function test_N4b_TheManualRefinanceMovesOnlyItsNetOut() public {
        uint256 loanId = _armedLoanOn(mid);
        uint256 fresh = (read.debtOf(loanId) * 105) / 100;
        uint256 hub = usdc.balanceOf(address(ace));
        uint256 wallet = usdc.balanceOf(borrower);

        vm.expectCall(address(usdc), abi.encodeWithSelector(IERC20.transfer.selector), 1);
        vm.prank(borrower);
        uint256 newId = ace.refinance(loanId, fresh, TEN7, OFF);

        assertGt(newId, loanId, "the manual refinance ran");
        uint256 paid = usdc.balanceOf(borrower) - wallet;
        assertGt(paid, 0, "fixture: a successor over the debt has a net out to pay");
        assertEq(hub - usdc.balanceOf(address(ace)), paid, "and the one transfer is that net out, from the hub to the borrower");
        (, uint256 owed) = ace.owedOf(loanId, borrower);
        assertEq(owed, 0, "with nothing booked behind it for a later claim");
    }

    /* ============ N6: totality at the tightest fold the predicate will admit ============ */

    /// @notice The successor lands EXACTLY on the market's minDebt floor and on the last unit the fold will carry.
    /// @notice At that boundary the post-commit gauntlet must not refuse: what the predicate admits, the roll completes.
    /// @dev The counts above prove the reads are single. This proves the SECOND half: the single answer is admissible.
    /// @dev The boundary is found by bisection rather than asserted, so the case sits on the real edge, not near it.
    function test_N6_TheTightestAdmissibleFold_Completes() public {
        uint256 loanId = _armedLoanOn(mid);
        _repayDownToTheFloorRegion(loanId);
        uint256 expiry = read.loan(loanId).expiry;
        _warpTo(expiry - 1); // the withdrawal door shuts AT maturity, so the shed happens inside the term

        /// @dev Whole-lot first, so a refusal here names the leg rather than surfacing as an empty bisection.
        (bool wide, bytes4 wideReason,) = IAceTryContinue(address(ace)).tryContinue(loanId);
        assertEq(bytes32(wideReason), bytes32(0), "fixture: the whole-lot fold must admit before a single unit is shed");
        assertTrue(wide, "fixture: without an admitted starting point there is no boundary to bisect toward");

        uint256 edge = _largestWithdrawalTheFoldStillCarries(loanId, expiry);
        assertGt(edge, 0, "fixture: the fold carries no withdrawal at all, so there is no boundary to sit on");
        _assertOneUnitPastTheEdgeSettles(loanId, edge, expiry);

        _withdraw(loanId, edge);
        _warpTo(expiry + 1);
        (bool ok, bytes4 reason, uint256 principal) = IAceTryContinue(address(ace)).tryContinue(loanId);
        assertEq(bytes32(reason), bytes32(0), "the predicate refused at the boundary, and it names the leg it refused on");
        assertTrue(ok, "the predicate must admit, or the post-commit gauntlet is never reached");
        assertEq(principal, ace.idToMarketParams(mid).minDebt, "the successor lands exactly on the market's minDebt floor");

        uint256 before = read.loanCount();
        vm.prank(keeper);
        ace.forceClose(loanId);
        assertEq(read.loanCount(), before + 1, "TOTALITY: the tightest admitted fold committed and then refused its own draw");
        assertEq(read.loan(before + 1).debt, principal, "and the successor carries exactly the principal the predicate named");
        emit log_named_uint("units shed before the fold still carried it", edge);
    }

    /// @notice One unit past N6's edge the view and `refinanceByPolicy` still ROLL while the paid fold SETTLES.
    /// @notice INTENDED: the view previews the unpaid verb on the whole lot; the fold judges the lot less its keeper sliver.
    /// @dev A view "fixed" to subtract the sliver goes red on the first assert, refusing a roll its own verb executes.
    function test_N6b_OnePastTheEdge_ViewAndVerbRollWhileThePaidFoldSettles() public {
        uint256 loanId = _armedLoanOn(mid);
        _repayDownToTheFloorRegion(loanId);
        uint256 expiry = read.loan(loanId).expiry;
        _warpTo(expiry - 1);
        uint256 edge = _largestWithdrawalTheFoldStillCarries(loanId, expiry);
        assertGt(edge, 0, "fixture: no boundary to step past");
        _withdraw(loanId, edge + 1);
        _warpTo(expiry + 1); // both doors are live here

        (bool ok, bytes4 reason, uint256 principal) = IAceTryContinue(address(ace)).tryContinue(loanId);
        assertEq(bytes32(reason), bytes32(0), "the whole-lot view admits one unit past the fold's edge");
        assertTrue(ok, "the whole-lot view admits one unit past the fold's edge");
        _assertEveryPreviewQuotes(loanId, principal);

        uint256 snap = vm.snapshotState();
        assertFalse(_foldRolls(loanId), "the paid fold settles here, or this state is not in the sliver gap");
        (uint256 paidSliver,) = ace.owedOf(loanId, keeper);
        assertGt(paidSliver, 0, "the paid fold credited the sliver that put the lot under its edge");
        vm.revertToState(snap);

        vm.prank(keeper);
        uint256 newId = ace.refinanceByPolicy(loanId);
        assertEq(read.loan(newId).debt, principal, "the unpaid verb rolls at exactly the debt the view quoted");
        (uint256 freeSliver,) = ace.owedOf(loanId, keeper);
        assertEq(freeSliver, 0, "the unpaid verb credits no sliver, which is why it judges the whole lot");
    }

    /// @dev The home `tryContinueTo` and both lens forwards quote what the hub view quotes: none of them previews the fold.
    function _assertEveryPreviewQuotes(uint256 loanId, uint256 principal) internal view {
        (bool ok, bytes4 reason, uint256 debt) = ace.tryContinueTo(loanId, mid);
        assertTrue(ok && reason == bytes4(0) && debt == principal, "tryContinueTo(home) quotes the whole-lot roll");
        (ok, reason, debt) = lens.tryContinue(loanId);
        assertTrue(ok && reason == bytes4(0) && debt == principal, "AceLens.tryContinue quotes the whole-lot roll");
        uint256[] memory ids = new uint256[](1);
        ids[0] = loanId;
        (bool[] memory oks, bytes4[] memory reasons, uint256[] memory debts) = lens.tryContinueMany(ids);
        assertTrue(oks[0] && reasons[0] == bytes4(0) && debts[0] == principal, "AceLens.tryContinueMany quotes the whole-lot roll");
    }

    /// @dev The non-vacuous half: one unit further and the crank SETTLES, so `edge` is the real edge.
    function _assertOneUnitPastTheEdgeSettles(uint256 loanId, uint256 edge, uint256 expiry) internal {
        uint256 snap = vm.snapshotState();
        _withdraw(loanId, edge + 1);
        _warpTo(expiry + 1);
        assertFalse(_foldRolls(loanId), "one unit past the edge must SETTLE, or the boundary is not a boundary");
        vm.revertToState(snap);
        _warpTo(expiry - 1);
    }

    /* ================================= fixture ================================= */

    function _expectOneRecordCall() internal {
        MarketParams memory p = ace.idToMarketParams(mid);
        vm.expectCall(address(record), abi.encodeWithSelector(IPersistenceRecord.minPrice.selector), 1);
        vm.expectCall(address(record), abi.encodeCall(IPersistenceRecord.minPrice, (p.quote, p.collateral)), 1);
    }

    function _lend(bytes32 m, uint256 amt) internal {
        usdc.mint(alice, amt);
        vm.startPrank(alice);
        usdc.approve(address(ace), amt);
        ace.deposit(m, amt);
        vm.stopPrank();
    }

    /// @dev Four times the deposit: the successor draws afresh, so the tick must still fund it after the first loan.
    function _armedLoanOn(bytes32 m) internal returns (uint256 loanId) {
        _lend(m, DEPOSIT * 4);
        loanId = _openArmed(m);
    }

    /// @dev An armed loan against cash already seeded, so a caller can put two of them on one lend.
    function _openArmed(bytes32 m) internal returns (uint256 loanId) {
        coll.mint(borrower, COLL);
        vm.startPrank(borrower);
        coll.approve(address(pm), COLL);
        loanId = ace.open(m, COLL, PRINCIPAL, TEN7, borrower, OFF);
        IAceAuto(address(ace)).setAutoRefinance(loanId, TEN7, 0, 0);
        vm.stopPrank();
    }

    /// @dev Repays until the debt is far enough under `minDebt` that `derivedPrincipal`'s ceil still lands beneath it.
    /// @dev That is what puts the successor exactly ON the floor rather than a rounding step above it.
    function _repayDownToTheFloorRegion(uint256 loanId) internal {
        uint256 debt = read.debtOf(loanId);
        uint256 target = ace.idToMarketParams(mid).minDebt / 10;
        usdc.mint(borrower, debt);
        vm.startPrank(borrower);
        usdc.approve(address(ace), type(uint256).max);
        ace.repay(loanId, debt - target);
        vm.stopPrank();
    }

    function _withdraw(uint256 loanId, uint256 units) internal {
        vm.prank(borrower);
        ace.withdrawCollateral(loanId, units, borrower);
    }

    /// @dev Whether the crank ROLLS rather than settles; snapshot-free, so the caller owns the state it leaves.
    function _foldRolls(uint256 loanId) internal returns (bool) {
        uint256 before = read.loanCount();
        vm.prank(keeper);
        ace.forceClose(loanId);
        return read.loanCount() == before + 1;
    }

    /// @dev Bisects the withdrawal the fold still carries. Each probe runs on a snapshot, so none of them survives.
    /// @dev Monotone by construction: shedding units only tightens coverage, so a carried amount stays carried below it.
    function _largestWithdrawalTheFoldStillCarries(uint256 loanId, uint256 expiry) internal returns (uint256 lo) {
        uint256 hi = read.loan(loanId).collateralUnits;
        while (lo + 1 < hi) {
            uint256 wMid = lo + (hi - lo) / 2;
            uint256 snap = vm.snapshotState();
            bool rolled = _probeWithdrawThenFold(loanId, wMid, expiry);
            vm.revertToState(snap);
            _warpTo(expiry - 1); // the revert restores storage, not the block clock the probe moved
            if (rolled) lo = wMid;
            else hi = wMid;
        }
    }

    /// @dev One probe: shed `units` inside the term, mature, then crank. A refused shed is itself a "not carried".
    function _probeWithdrawThenFold(uint256 loanId, uint256 units, uint256 expiry) internal returns (bool) {
        vm.prank(borrower);
        (bool ok,) = address(ace).call(abi.encodeCall(Ace.withdrawCollateral, (loanId, units, borrower)));
        if (!ok) return false;
        _warpTo(expiry + 1);
        return _foldRolls(loanId);
    }
}
