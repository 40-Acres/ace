// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.36;

import {WarpClock} from "../utils/WarpClock.sol";
import {Ace} from "../../src/ace/hub/Ace.sol";
import {AceLens} from "../../src/ace/lens/AceLens.sol";
import {PriceFrame} from "../utils/PriceFrame.sol";
import {MarketInit} from "../../src/ace/hub/MarketInit.sol";
import {MarketParams, MarketState, OpenBounds} from "../../src/ace/hub/Types.sol";
import {PositionManager} from "../../src/ace/positions/PositionManager.sol";
import {MockERC20} from "../mocks/MockERC20.sol";
import {MockPersistenceRecord} from "../mocks/MockPersistenceRecord.sol";
import {AceFixtures} from "../utils/AceFixtures.sol";
import {AceReader} from "../utils/AceReader.sol";

error LoanClosed(); // the hub's own: a retired loan is refused by name, which is what makes the zero-need arm unreachable

/// @title AceRecordlessForfeit
/// @notice THE PROPERTY: a recordless market does not return the settlement residual up to the coverage line.
/// @notice The borrower keeps only what sits ABOVE that line; everything under it converts to the claims' pots.
/// @notice A record-backed market is untouched and still credits everything above the claims' own need.
/// @dev WHY THE CLASS SPLIT: with no record there is no early seizure, so the lender eats the whole drawdown; the coverage pays for that.
/// @dev The one act left to the lender is refusing an armed roll at its fold, which reaches this same bound.
/// @dev THE LINE IS TAKEN FROM THE SHIPPED LENS, never re-derived here: `withdrawableUnits` is
/// @dev `collateralUnits - coverageLine` on a live loan, so the line is a subtraction and not a second formula.
/// @dev That matters -- a test that re-implements the bound it checks admits the wrong form along with the right one.
/// @dev THE CONSERVATION ROW IS THE ONE THAT CATCHES THE NAIVE FIX. Raising the bound without giving the
/// @dev excess a destination retires units from custody that no ledger entry names; they simply vanish.
/// @dev It passes on today's rule too, by construction, and that is the point: it is the regression guard.
contract AceRecordlessForfeitTest is WarpClock {
    Ace internal ace;
    AceReader internal read;
    AceLens internal lens;
    PositionManager internal pm;

    MockERC20 internal usdc; // quote, 6 decimals
    MockERC20 internal coll; // collateral, 18 decimals
    bytes32 internal mid; // the recordless market under test

    address internal alice = address(0xA11CE); // the lender
    address internal borrower = address(0xB0B);
    address internal keeper = address(0xCA11E5);

    uint256 internal TOP;
    int24 internal constant SPACING = 60;
    uint256 internal constant TICKS = 4; // few enough that a pro-rata split reads by hand
    uint256 internal constant PER_TICK = 5_000_000; // the old per-rung lot; the rigs rest a multiple of it as one balance
    uint256 internal constant PRINCIPAL = 11_000_000; // over the fixture's 10e6 minDebt; two full ticks and part of a third
    uint256 internal constant COLL = 10_000e18;
    uint64 internal constant TEN7 = 7 days;
    uint256 internal constant WIDE_TICKS = 32; // the fixture's `maxClaimTicks`, which is the shipped ceiling too
    uint256 internal constant WIDE_PRINCIPAL = 159_000_000; // 31 whole ticks and part of a 32nd: the cap, unevenly

    OpenBounds internal OFF = OpenBounds(0, 0, 0);

    function _price(int24 offset) internal view returns (uint256) {
        return AceFixtures.priceAt(address(usdc), address(coll), offset);
    }

    function setUp() public {
        _warpTo(1_000_000);
        usdc = new MockERC20("USD Coin", "USDC", 6);
        coll = new MockERC20("Collateral", "COLL", 18);
        TOP = _price(0);

        MarketParams memory p = AceFixtures.marketParams(address(usdc), address(coll));
        p.record = address(0); // the class under test: no record, so no early seizure exists at all
        p.lender = alice; // this suite's own tenant; sole tenancy means the depositor and the named lender are one
        AceFixtures.Deployment memory d = AceFixtures.deploy(p);
        (ace, pm, read, mid) = (d.ace, d.positionManager, d.read, d.id);
        lens = new AceLens(address(ace));
    }

    /* ================================ the ruled behaviour ================================ */

    /// @notice The borrower is credited ONLY what sat above the coverage line, never the whole excess over `need`.
    /// @dev Red on the old rule by exactly the coverage: it credited `units - need` instead.
    function test_TheBorrowerKeepsOnlyWhatSitsAboveTheCoverageLine() public {
        uint256 loanId = _ladderLoan();
        (uint256 units, uint256 line) = _unitsAndLine(loanId);
        assertGt(units, line, "fixture: the loan must sit ABOVE its line for the two rules to differ");
        assertGt(line, lens.collateralNeeded(mid, loanId), "fixture: the line must exceed need, or there is no coverage");

        _settleUnpaid(loanId);

        assertEq(read.unitsOwedOf(loanId, borrower), units - line, "the borrower keeps exactly the units above the line");
    }

    /// @notice The claims receive the WHOLE coverage line, not merely what they needed at their own ticks.
    /// @dev The other half of the same move, asserted on the pots rather than on the borrower.
    function test_TheClaimsReceiveTheWholeCoverageLine() public {
        uint256 loanId = _ladderLoan();
        (uint256 units, uint256 line) = _unitsAndLine(loanId);
        /// @dev STRICTLY above the line, or this row weakens into "the pots hold everything", which a
        /// @dev TOTAL forfeit satisfies too -- the lens clamps `withdrawableUnits` to zero on the line.
        assertGt(units, line, "fixture: the loan must sit above its line for the bound to be the subject");

        _settleUnpaid(loanId);

        assertEq(_potOf(loanId), line, "the pots hold the whole line");
    }

    /// @notice EVERY RETIRED UNIT IS ACCOUNTED FOR: borrower credit plus keeper credit plus pots equals the lot.
    /// @notice This is the row that catches raising the bound without giving the excess a destination.
    /// @dev Formula-free on purpose -- it names no bound, so it cannot be satisfied by re-deriving one.
    function test_EveryRetiredUnitIsAccountedFor() public {
        uint256 loanId = _ladderLoan();
        (uint256 units,) = _unitsAndLine(loanId);

        _settleUnpaid(loanId);

        uint256 owned = read.unitsOwedOf(loanId, borrower) + read.unitsOwedOf(loanId, keeper) + _potOf(loanId);
        assertEq(owned, units, "units left custody that no ledger entry names");
    }

    /// @notice The same conservation on the PAID door, where the sliver takes its cut off the top first.
    function test_EveryRetiredUnitIsAccountedFor_PaidDoor() public {
        uint256 loanId = _ladderLoan();
        (uint256 units,) = _unitsAndLine(loanId);

        _warpTo(read.loan(loanId).expiry);
        vm.prank(keeper);
        ace.forceClose(loanId);

        uint256 owned = read.unitsOwedOf(loanId, borrower) + read.unitsOwedOf(loanId, keeper) + _potOf(loanId);
        assertEq(owned, units, "units left custody that no ledger entry names");
        assertGt(read.unitsOwedOf(loanId, keeper), 0, "fixture: the paid door must actually credit a sliver");
    }

    /// @notice The pot takes its own `need` PLUS the whole excess above it, with nothing left to apportion.
    /// @dev WAS `test_TheExcessSplitsProRataByClaim`, which pinned that the excess split PRO RATA BY CLAIM
    /// @dev across the loan's funded ticks rather than highest-tick-first -- an ordering-neutral choice made so
    /// @dev the row would not rule on an open seniority question. A loan holds ONE claim: there is nothing to
    /// @dev apportion and no order to choose, so what survives is the CONSERVATION the split was protecting.
    function test_TheExcessGoesWhollyToThePot() public {
        uint256 loanId = _ladderLoan();
        (, uint256 line) = _unitsAndLine(loanId);

        uint256 need = _need(loanId);
        uint256 excess = line - need;
        assertGt(excess, 0, "fixture: there must be a real excess over need for this row to mean anything");

        _settleUnpaid(loanId);

        assertEq(_potOf(loanId), need + excess, "the pot took its need and the whole excess, to the wei");
    }

    /// @notice Backed burns move by exactly what the pots gained, which is what LR-9 requires.
    /// @dev Crediting a pot without crediting the burn total breaks that identity by the excess.
    function test_BackedBurnsMoveWithThePots() public {
        uint256 loanId = _ladderLoan();
        uint256 burnsBefore = read.marketState(mid).cumulativeBackedBurns;

        _settleUnpaid(loanId);

        uint256 delta = read.marketState(mid).cumulativeBackedBurns - burnsBefore;
        assertEq(delta, _potOf(loanId), "backed burns and pots must move together");
    }

    /// @notice A covered settlement writes NO shortfall and NO realized loss, and that must survive the wider bound.
    /// @dev Recorded because bad debt becomes near-unreachable here: a zero means the coverage absorbed it, not health.
    function test_ACoveredForfeitWritesNoBadDebt() public {
        uint256 loanId = _ladderLoan();
        _settleUnpaid(loanId);

        (uint256 shortUnits, uint256 shortQuote) = read.shortfallOf(loanId);
        assertEq(shortUnits, 0, "a covered forfeit records no shortfall");
        assertEq(shortQuote, 0, "and no bad debt against it");
        assertEq(read.marketState(mid).realizedLossAtBook, 0, "nor any at the market level");
    }

    /* ======================= the forfeit arm's own rounding ======================= */

    /// @notice THE SPREAD'S RESIDUE IS SWEPT, NEVER DROPPED: the pots gain the whole excess to the wei.
    /// @notice The pro-rata split floors per tick, so a split that does not divide exactly leaves a remainder.
    /// @dev This arm's rounding was covered only incidentally by suites that took a recordless fixture for
    /// @dev convenience; those are record-backed now, so the coverage lives here or nowhere.
    function test_TheSpreadResidueIsSweptNotDropped() public {
        uint256 loanId = _ladderLoan();
        (, uint256 line) = _unitsAndLine(loanId);
        uint256 need = lens.collateralNeeded(mid, loanId);

        _settleUnpaid(loanId);

        assertEq(_potOf(loanId) - need, line - need, "the pots gained the whole excess, residue included");
    }

    /// @notice LOW-DECIMAL COLLATERAL: one atom is economically large, so a dropped atom is not dust.
    /// @dev The conservation identity must hold at the decimal where the spread's flooring bites hardest.
    function test_ZeroDecimalCollateral_TheSpreadStrandsNothing() public {
        _remake(0);
        uint256 loanId = _ladderLoan();
        (uint256 units,) = _unitsAndLine(loanId);

        _settleUnpaid(loanId);

        uint256 owned = read.unitsOwedOf(loanId, borrower) + read.unitsOwedOf(loanId, keeper) + _potOf(loanId);
        assertEq(owned, units, "an atom went missing where an atom is worth thousands of quote");
    }

    /// @notice A SMALL loan takes the whole excess too, with no residue to sweep.
    /// @dev WAS the degenerate arm of the split, where the pro-rata divisor was the only claim. Every loan is
    /// @dev that arm now; the row is kept because it drives a DIFFERENT fixture size through the same rule.
    function test_SmallLoan_TakesTheWholeExcessWithNoResidue() public {
        uint256 loanId = _singleTickLoan();
        (, uint256 line) = _unitsAndLine(loanId);
        assertEq(read.claimCount(mid, loanId), 1, "fixture: the loan really holds its claim");

        _settleUnpaid(loanId);

        assertEq(read.invPotOf(mid, loanId), line, "the pot holds the whole line");
    }

    /* ================================== the control ================================== */

    /// @notice A RECORD-BACKED market is untouched: it still credits everything above the claims' own need.
    /// @dev The class split is the whole design, so a suite that only pins the new arm would not show it.
    function test_RecordBackedSettlementStillReturnsTheResidual() public {
        MockERC20 q = new MockERC20("USD Coin", "USDC", 6);
        MockERC20 c = new MockERC20("Collateral", "COLL", 18);
        MockPersistenceRecord rec = new MockPersistenceRecord(address(q), address(c));
        MarketParams memory p = AceFixtures.marketParams(address(q), address(c));
        p.record = address(rec);
        p.lender = alice;
        AceFixtures.Deployment memory d = AceFixtures.deploy(p);

        uint256 top = AceFixtures.priceAt(address(q), address(c), 0);
        rec.setMinPrice(type(uint256).max); // no draw cap: the control is about the residual, not admission

        /// @dev THE TOTAL IS KEPT AND THE SHAPE IS GONE: it rested `PER_TICK` at each of `TICKS` rungs, and
        /// @dev `PER_TICK` sits UNDER the deposit floor now -- which is `minDebt` itself, not a fraction of it.
        uint256 total = PER_TICK * TICKS;
        q.mint(alice, total);
        vm.startPrank(alice);
        q.approve(address(d.ace), total);
        d.ace.deposit(d.id, total);
        vm.stopPrank();

        c.mint(borrower, COLL);
        vm.startPrank(borrower);
        c.approve(address(d.positionManager), COLL);
        uint256 loanId = d.ace.open(d.id, COLL, PRINCIPAL, TEN7, borrower, OFF);
        vm.stopPrank();

        AceLens l2 = new AceLens(address(d.ace));
        uint256 units = d.read.loan(loanId).collateralUnits;
        uint256 need = l2.collateralNeeded(d.id, loanId);

        _warpTo(d.read.loan(loanId).expiry + MarketInit.autoRefinanceWindow(d.read.loan(loanId).tenor));
        vm.prank(keeper);
        d.ace.settleExpired(loanId);

        assertEq(d.read.unitsOwedOf(loanId, borrower), units - need, "a record-backed borrower still keeps everything above need");
    }

    /* ===================== the arms the first pass did not reach ===================== */

    /// @notice THE BOUND READS THE LIVE DEBT, NOT THE PRINCIPAL: a partial repay shrinks it and the borrower keeps more.
    /// @notice Both terms move together, so the forfeited coverage falls with the debt rather than staying at the draw's size.
    /// @dev Without this row `debt` and `principal` are the same number everywhere and the two spellings are indistinguishable.
    function test_APartialRepayShrinksTheLineAndTheBorrowerKeepsMore() public {
        uint256 loanId = _ladderLoan();
        (uint256 units, uint256 lineBefore) = _unitsAndLine(loanId);
        uint256 pay = read.debtOf(loanId) / 2;

        usdc.mint(borrower, pay);
        vm.startPrank(borrower);
        usdc.approve(address(ace), pay);
        ace.repay(loanId, pay);
        vm.stopPrank();

        (, uint256 line) = _unitsAndLine(loanId);
        uint256 need = lens.collateralNeeded(mid, loanId);
        assertLt(line, lineBefore, "fixture: the repay must move the line, or the row distinguishes nothing");
        assertGt(line, need, "fixture: coverage must still exceed need after the repay");
        assertGt(lens.withdrawableUnits(mid, loanId), 0, "fixture: the loan must still sit above its line");

        _settleUnpaid(loanId);

        assertEq(read.unitsOwedOf(loanId, borrower), units - line, "the bound priced the PRINCIPAL, not the live debt");
        assertEq(_potOf(loanId), line, "the pots hold the POST-REPAY line");
        assertEq(read.unitsOwedOf(loanId, borrower) + _potOf(loanId), units, "units left custody that no ledger entry names");
    }

    /// @notice ON THE LINE, THE PAID DOOR'S SLIVER MAKES THE UNITS CAP BIND: the borrower is credited nothing at all.
    /// @notice The lot is already the whole coverage, so the keeper's cut comes out of what the claims would have taken.
    /// @dev The arm where `_marketBound` returns `units` rather than the line -- reachable only once a sliver is taken off the top.
    /// @dev Drop the cap and this row panics on the underflow, which is the only thing standing under that ternary.
    function test_OnTheLine_ThePaidDoorsSliverMakesTheUnitsCapBind() public {
        uint256 loanId = _ladderLoan();
        uint256 free = lens.withdrawableUnits(mid, loanId);
        assertGt(free, 0, "fixture: there must be slack to take out");
        vm.prank(borrower);
        ace.withdrawCollateral(loanId, free, borrower);

        uint256 units = read.loan(loanId).collateralUnits;
        assertEq(lens.withdrawableUnits(mid, loanId), 0, "fixture: the loan must now sit ON its line");
        uint256 need = lens.collateralNeeded(mid, loanId);

        _warpTo(read.loan(loanId).expiry);
        vm.prank(keeper);
        ace.forceClose(loanId);

        uint256 sliver = read.unitsOwedOf(loanId, keeper);
        assertGt(sliver, 0, "fixture: the paid door must actually credit a sliver");
        assertGt(units - sliver, need, "fixture: the capped lot must still clear every claim, or this is a shortfall row");
        assertEq(read.unitsOwedOf(loanId, borrower), 0, "a loan settled ON its line returns the borrower nothing");
        assertEq(_potOf(loanId), units - sliver, "the whole post-sliver lot converts: the cap bound on units");
        assertEq(sliver + _potOf(loanId), units, "units left custody that no ledger entry names");
        (uint256 shortUnits,) = read.shortfallOf(loanId);
        assertEq(shortUnits, 0, "the capped lot still covered every claim, so no shortfall may be written");
    }

    /// @notice A LARGE loan strands nothing either: the whole line reaches the pot however big the figures are.
    /// @dev WAS `test_MaxClaimTicksAtTheCeiling_TheSweepStrandsNothing`, at 32 funded ticks -- the cap, where the
    /// @dev pro-rata split floored once per tick and the sweep paid at most one wei back per tick, so those two
    /// @dev bounds were furthest apart and a dropped remainder would show first. There is ONE ceiling now, so the
    /// @dev residue has nowhere to hide; the fixture is kept for its SIZE, which is the only variable left.
    function test_ALargeLoan_StrandsNothing() public {
        uint256 loanId = _wideLadderLoan();
        (uint256 units, uint256 line) = _unitsAndLine(loanId);
        assertEq(read.claimCount(mid, loanId), 1, "fixture: the large draw holds its claim");

        uint256 need = _need(loanId);
        assertGt(line, need, "fixture: there is a real excess over need at this size");

        _settleUnpaid(loanId);

        assertEq(_potOf(loanId), line, "the pot holds the whole line, residue included");
        assertEq(read.unitsOwedOf(loanId, borrower) + _potOf(loanId), units, "units left custody that no ledger entry names");
    }

    /// @notice LR-9 OVER THE FORFEIT ARM: backed burns net of outflow equals the inventory, before AND after an exit.
    /// @notice The shared invariant campaign wires a record into every market it drives, so it never reaches this arm.
    /// @dev A pot credit that skipped the burn total passes every conservation row here and breaks only this one.
    /// @dev The in-kind leg matters on its own: it proves the forfeited coverage is REDEEMABLE, not merely booked.
    function test_LR9HoldsAcrossARecordlessForfeitAndItsInKindExit() public {
        uint256 loanId = _ladderLoan();
        uint256 claimAtTop = read.claimOf(mid, loanId);

        _settleUnpaid(loanId);

        uint256 inv = _potOf(loanId);
        assertGt(inv, 0, "fixture: the forfeit must leave inventory to reconcile");
        assertEq(read.poolLent(mid), 0, "the spread inflated retired principal: totalLent must fall by the claims alone");
        MarketState memory s = read.marketState(mid);
        assertEq(s.cumulativeBackedBurns - s.netSyntheticOutflow, inv, "LR-9: backed burns net of outflow != sum(inventoryOf)");
        assertEq(lens.headroom(mid), inv, "LR-9: AceLens.headroom() != sum(inventoryOf)");

        vm.prank(alice);
        uint256 out = ace.redeemInKind(loanId, alice); // no mint first: the pot is the lender's outright

        /// @dev VALUED AT THE MARKET'S PRICE, not at `fundingFloor`. The floor is DERIVED from the claim now
        /// @dev and the settlement retired it, so reading it here returns zero and prices the pot at nothing.
        /// @dev The market's own bid is the price that funded the claim and it never retires.
        uint256 price = ace.idToMarketParams(mid).price;
        assertGt((out * price) / read.marketState(mid).unitScale, claimAtTop, "the forfeited coverage never reached the lender");
        inv = _potOf(loanId);
        s = read.marketState(mid);
        assertGt(s.netSyntheticOutflow, 0, "fixture: the in-kind exit must move the outflow, or the second leg is the first");
        assertEq(s.cumulativeBackedBurns - s.netSyntheticOutflow, inv, "LR-9 broke once the forfeited coverage left in kind");
        assertEq(lens.headroom(mid), inv, "headroom drifted from inventory after the in-kind exit");
    }

    /// @notice WHY `_marketBound`'s ZERO-NEED ARM IS UNREACHABLE, pinned as a tripwire instead of argued in prose.
    /// @notice Paying the last atom CLOSES the loan, so no settlement verb ever meets one carrying no live claim.
    /// @dev Were that to stop holding, a recordless settle would price a claimless loan off the tick cap alone and
    /// @dev then spread it over nothing: units retired against no ledger entry, and no conservation row would see it.
    function test_AFullRepayClosesTheLoan_SoSettlementNeverMeetsAClaimlessLoan() public {
        uint256 loanId = _ladderLoan();
        uint256 debt = read.debtOf(loanId);
        usdc.mint(borrower, debt);
        vm.startPrank(borrower);
        usdc.approve(address(ace), debt);
        ace.repay(loanId, debt);
        vm.stopPrank();

        assertEq(read.debtOf(loanId), 0, "fixture: the debt must be gone for this to be the zero-need case");
        assertGt(read.loan(loanId).closedAt, 0, "A ZERO-DEBT LOAN STAYED OPEN: settlement can now meet a loan with no claims");
        assertEq(lens.collateralNeeded(mid, loanId), 0, "fixture: a retired claim set needs nothing");

        _warpTo(read.loan(loanId).expiry + MarketInit.autoRefinanceWindow(read.loan(loanId).tenor));
        vm.prank(keeper);
        vm.expectRevert(LoanClosed.selector);
        ace.settleExpired(loanId);
    }

    /* =================================== helpers =================================== */

    /// @dev The live loan's lot and its coverage line, the line read off the SHIPPED lens as a subtraction.
    function _unitsAndLine(uint256 loanId) internal view returns (uint256 units, uint256 line) {
        units = read.loan(loanId).collateralUnits;
        line = units - lens.withdrawableUnits(mid, loanId);
    }

    /// @dev What the live claim needs at its committed price, ceiled exactly as settlement ceils.
    /// @dev WAS a per-tick VECTOR, because a loan's coverage split across the ticks it funded and the shipped
    /// @dev whole-loan view could not supply the split. There is one claim at one price, so the vector is a
    /// @dev scalar -- and it is still checked against `lens.collateralNeeded`, so it cannot drift alone.
    function _need(uint256 loanId) internal view returns (uint256 n) {
        uint256 scale = read.marketState(mid).unitScale;
        uint256 amt = read.claimOf(mid, loanId);
        uint256 price = read.fundingFloor(mid, loanId);
        n = price == 0 || amt == 0 ? 0 : (amt * scale + price - 1) / price;
        assertEq(n, lens.collateralNeeded(mid, loanId), "the need must equal the shipped view");
    }

    /// @dev The loan's pot. WAS a sum over the funded ticks, whose list outlived the claims resting on it.
    function _potOf(uint256 loanId) internal view returns (uint256) {
        return read.invPotOf(mid, loanId);
    }

    /// @dev The unpaid backstop: no sliver, so the arithmetic is the bound and nothing else.
    function _settleUnpaid(uint256 loanId) internal {
        _warpTo(read.loan(loanId).expiry + MarketInit.autoRefinanceWindow(read.loan(loanId).tenor));
        vm.prank(keeper);
        ace.settleExpired(loanId);
    }

    /// @dev Rebuilds the market at a different collateral decimal, so the spread's flooring can be pressed.
    function _remake(uint8 collDecimals) internal {
        coll = new MockERC20("Collateral", "COLL", collDecimals);
        TOP = _price(0);
        MarketParams memory p = AceFixtures.marketParams(address(usdc), address(coll));
        p.record = address(0);
        p.lender = alice;
        AceFixtures.Deployment memory d = AceFixtures.deploy(p);
        (ace, pm, read, mid) = (d.ace, d.positionManager, d.read, d.id);
        lens = new AceLens(address(ace));
    }

    /// @dev One funded tick, for the degenerate arm of the pro-rata split.
    function _singleTickLoan() internal returns (uint256 loanId) {
        usdc.mint(alice, PER_TICK * TICKS);
        vm.startPrank(alice);
        usdc.approve(address(ace), PER_TICK * TICKS);
        ace.deposit(mid, PER_TICK * TICKS);
        vm.stopPrank();

        coll.mint(borrower, COLL);
        vm.startPrank(borrower);
        coll.approve(address(pm), COLL);
        loanId = ace.open(mid, COLL, PRINCIPAL, TEN7, borrower, OFF);
        vm.stopPrank();
    }

    /// @dev A loan funded out of the DEEPEST balance this file rests: what 34 rungs of `PER_TICK` held in total.
    /// @dev IT WAS THE WHOLE CLAIM CAP -- 32 legs, the last partial -- so a split had 32 shares to divide.
    /// @dev A loan holds ONE claim, so there is nothing to split and the depth is the only thing kept.
    function _wideLadderLoan() internal returns (uint256 loanId) {
        uint256 total = PER_TICK * (WIDE_TICKS + 2);
        usdc.mint(alice, total);
        vm.startPrank(alice);
        usdc.approve(address(ace), total);
        ace.deposit(mid, total);
        vm.stopPrank();

        coll.mint(borrower, COLL);
        vm.startPrank(borrower);
        coll.approve(address(pm), COLL);
        loanId = ace.open(mid, COLL, WIDE_PRINCIPAL, TEN7, borrower, OFF);
        vm.stopPrank();
    }

    /// @dev A loan drawn out of what the four-rung ladder held in total; `PER_TICK` alone is under the floor.
    function _ladderLoan() internal returns (uint256 loanId) {
        uint256 total = PER_TICK * TICKS;
        usdc.mint(alice, total);
        vm.startPrank(alice);
        usdc.approve(address(ace), total);
        ace.deposit(mid, total);
        vm.stopPrank();

        coll.mint(borrower, COLL);
        vm.startPrank(borrower);
        coll.approve(address(pm), COLL);
        loanId = ace.open(mid, COLL, PRINCIPAL, TEN7, borrower, OFF);
        vm.stopPrank();
    }
}
