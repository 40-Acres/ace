// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.36;

import {Test} from "forge-std/Test.sol";
import {Ace} from "../../src/ace/hub/Ace.sol";
import {BelowCoverageLine, Borrower} from "../../src/ace/hub/Borrower.sol";
import {Constants} from "../../src/ace/hub/Constants.sol";
import {PriceFrame} from "../utils/PriceFrame.sol";
import {AceLens} from "../../src/ace/lens/AceLens.sol";
import {MarketParams, OpenBounds} from "../../src/ace/hub/Types.sol";
import {PocDeployConfig} from "../../src/config/Defaults.sol";
import {PositionManager} from "../../src/ace/positions/PositionManager.sol";
import {MockERC20} from "../mocks/MockERC20.sol";
import {MockPersistenceRecord} from "../mocks/MockPersistenceRecord.sol";
import {AceFixtures} from "../utils/AceFixtures.sol";
import {AceReader} from "../utils/AceReader.sol";
import {PriceFrame} from "../utils/PriceFrame.sol";

/// @title AceAdmissionCoverageDust
/// @notice Issue #305 is FIXED, and this suite is the standing proof: it certifies the property outright.
/// @notice Its five blessing tests INVERTED when `_gate` began reading the coverage line, and now assert coverage.
/// @notice THE QUESTION: does the ADMISSION gate cover settlement, with no withdrawal and no sale?
/// @notice The admission-side twin of `AceWithdrawCoverageDust`, and the same two functions disagree.
/// @notice `Borrower._gate` takes ONE ceiling over the whole debt: `trig <= floor` IS `units >= requiredAt`.
/// @notice `LoanAccounting.collateralNeeded` takes ONE ceiling too, so the two now differ by a single atom.
/// @dev THE EXPOSURE THIS FILE WAS WRITTEN FOR IS STRUCTURALLY GONE, and the rows are kept as its witness.
/// @dev Settlement used to ceil PER FUNDED TICK while admission ceiled the whole debt once, and a sum of
/// @dev ceilings is not the ceiling of a sum: the gap grew with the tick count `n`, so a draw spanning the
/// @dev whole claim cap on a principal worth a few collateral wei could be admitted and still come up short.
/// @dev Write `W = principal * unitScale / fundingFloor` and `R` for the claim-weighted mean of
/// @dev `fundingFloor / price_t`. The violation bound was `W < n / (k - 1)`, which needed `R` near one AND a
/// @dev large `n`. BOTH TERMS COLLAPSED: `R` is exactly one, because every claim funds at the market's single
/// @dev price, and `n` is one, because a loan holds one claim. The residue cannot exceed a single atom, which
/// @dev is precisely the epsilon `coverageLine` carries.
/// @dev Reasoning: `the design record`, and `the design record` one-market-one-price.
/// @dev NO WITHDRAWAL, NO SALE AND NO REPAY HERE: every loan settles exactly as the draw left it.
contract AceAdmissionCoverageDustTest is Test {
    /// @dev One deployed market, plus the views the assertions read it through.
    struct Fx {
        Ace ace;
        PositionManager pm;
        AceReader read;
        AceLens lens;
        bytes32 id;
        MockERC20 quote;
        MockERC20 coll;
        MockPersistenceRecord record;
        uint256 unitScale;
        uint256 minLot;
    }

    address internal alice = address(0xA11CE);
    address internal borrower = address(0xB0B);

    uint256 internal constant TICKS = 32; // == maxClaimTicks: the count that maximizes the ceiling slack
    int24 internal constant SPACING = 60; // the suite-wide default grid; the threshold scans vary it
    uint256 internal constant DUST_MIN_DEBT = 32; // the smallest floor that still legalizes a one-wei lot at 32 ticks

    int24 internal spacing = SPACING; // the grid the live fixture was seeded on
    uint256 internal topTick; // the market price the fixture creates at; it was the highest seeded tick
    /// @dev WHERE THE MARKET BIDS, as an offset from par, set BEFORE `_deploy` by a row that wants one.
    /// @dev It used to be a tick a row picked when it seeded; the price is a creation param now, so a row
    /// @dev that writes `topTick` after the market exists is writing to nothing.
    int24 internal priceOffset;

    function setUp() public {
        vm.warp(1_000_000);
    }

    /* ============================ the fixture ============================ */

    /// @dev A market at the caller's decimals, coverage multiple and dust floor; nothing is seeded yet.
    /// @dev `settleBountyBps` is ZEROED so the measurement isolates the ceiling gap from the keeper sliver.
    /// @dev The sliver is railed separately at `b <= k - 1`, which is the same margin this file is about.
    function _deploy(uint8 collDec, uint8 quoteDec, uint256 minDebt, uint256 k) internal returns (Fx memory f) {
        return _deploy(collDec, quoteDec, minDebt, k, SPACING, 0);
    }

    /// @dev The same, on a caller-chosen tick grid: the span of the funded band moves the coverage margin.
    /// @dev A tighter grid pushes every funded tick toward the floor, which is what drives `R` toward one.
    function _deploy(uint8 collDec, uint8 quoteDec, uint256 minDebt, uint256 k, int24 gridSpacing) internal returns (Fx memory f) {
        return _deploy(collDec, quoteDec, minDebt, k, gridSpacing, 0);
    }

    /// @dev The same, with a LIVE keeper sliver: the expiry fold spends it before judging the successor.
    /// @dev Only the roll test wants one; every coverage measurement zeroes it so the ceiling stands alone.
    function _deploy(uint8 collDec, uint8 quoteDec, uint256 minDebt, uint256 k, int24 gridSpacing, uint16 bountyBps) internal returns (Fx memory f) {
        spacing = gridSpacing;
        f.quote = new MockERC20("Quote", "Q", quoteDec);
        f.coll = new MockERC20("Collateral", "C", collDec);
        topTick = PriceFrame.priceAt(address(f.quote), address(f.coll), priceOffset);
        MockPersistenceRecord record = new MockPersistenceRecord(address(f.quote), address(f.coll));
        f.record = record;

        MarketParams memory p = AceFixtures.marketParams(address(f.quote), address(f.coll));
        p.record = address(record);
        p.price = topTick; // the market bids where the row asked, and every claim funds there
        p.minDebt = minDebt;
        p.minCoverageWad = k;
        p.settleBountyBps = bountyBps;

        AceFixtures.Deployment memory d = AceFixtures.deploy(p);
        (f.ace, f.pm, f.read, f.id) = (d.ace, d.positionManager, d.read, d.id);
        f.lens = new AceLens(address(d.ace)); // the shipped views are the oracle; the test keeps no mirror
        f.unitScale = f.read.marketState(f.id).unitScale;
        f.minLot = minDebt; // the deposit floor IS `minDebt` now: one price, so there is no claim cap to divide by
    }

    /// @dev Rest `perTick * TICKS` in the market: what the uniform 32-tick seed held in total.
    /// @dev THE SHAPE IS GONE AND THE TOTAL IS KEPT. It seeded one equal lot at each of 32 ticks so a draw of
    /// @dev the whole seed funded all 32 evenly, which is what maximised the per-tick ceiling slack this file
    /// @dev measures. A draw funds ONE claim now, so there is no shape to choose and the slack is one atom.
    function _seedUniform(Fx memory f, uint256 perTick) internal {
        uint256 total = perTick * TICKS;
        f.quote.mint(alice, total);
        vm.startPrank(alice);
        f.quote.approve(address(f.ace), total);
        f.ace.deposit(f.id, total);
        vm.stopPrank();
    }

    /// @dev The same total the ADVERSARIAL shape rested: dust on the 31 high ticks, the balance on the floor tick.
    /// @dev THAT SHAPE DROVE `R` TOWARD ONE -- the claim-weighted mean of `fundingFloor / price_t` -- which was
    /// @dev the regime the derived `n / (k - 1)` violation bound assumed. `R` IS EXACTLY ONE now, by construction:
    /// @dev every claim funds at the market's single price, so the funding floor and the claim's price are one
    /// @dev number. There is no adversarial arrangement left, which is why this and `_seedUniform` now agree.
    /// @dev IT TOOK THE FLOOR LOT and derived the total as `minLot * 31 + floorLot`. It takes the TOTAL now:
    /// @dev the split was the shape, the shape is gone, and the derivation UNDERFLOWED once `minLot` stopped
    /// @dev being `ceil(minDebt / maxClaimTicks)` and became `minDebt` itself.
    function _seedDustThenFloor(Fx memory f, uint256 total) internal {
        f.quote.mint(alice, total);
        vm.startPrank(alice);
        f.quote.approve(address(f.ace), total);
        f.ace.deposit(f.id, total);
        vm.stopPrank();
    }

    /* ==================== the gate's own line, probed ==================== */

    /// @dev Whether the hub's own quote admits this draw at this unit count. Reads nothing else.
    function _admits(Fx memory f, uint256 units, uint256 principal) internal view returns (bool) {
        try f.ace.previewOpen(f.id, units, principal, 0, borrower, OpenBounds(0, 0, 0)) returns (Borrower.Quote memory) {
            return true;
        } catch {
            return false;
        }
    }

    /// @notice The fewest units `_gate` will admit for this draw, bisected on the hub's own quote.
    /// @dev Admission is monotone in units -- `triggerPrice` falls as they rise -- so the bisection is exact.
    function _minAdmissibleUnits(Fx memory f, uint256 principal) internal view returns (uint256 hi) {
        hi = 1;
        for (uint256 i; i < 128 && !_admits(f, hi, principal); i++) {
            hi <<= 1;
        }
        require(_admits(f, hi, principal), "fixture: no unit count clears the gate for this draw");
        uint256 lo = hi >> 1; // refused, or zero when one wei was already admitted
        while (hi - lo > 1) {
            uint256 mid = lo + (hi - lo) / 2;
            if (_admits(f, mid, principal)) hi = mid;
            else lo = mid;
        }
    }

    /// @notice Opens at exactly the gate's minimum, having proved one wei less is refused by the HUB.
    /// @notice That minimum IS the coverage line now: `requiredAt` plus the market's tick cap.
    /// @dev BY SELECTOR: a bare expectRevert would accept any refusal and leave the line unpinned.
    /// @dev The probe also pins `previewOpen` to `open`, so the bisection above is the verb's own boundary.
    /// @dev `BelowCoverageLine` and not `TriggerAboveFloor`: one wei under the line still clears the trigger leg.
    function _openAtTheLine(Fx memory f, uint256 principal) internal returns (uint256 loanId, uint256 units) {
        units = _minAdmissibleUnits(f, principal);
        f.coll.mint(borrower, units);
        vm.prank(borrower);
        f.coll.approve(address(f.pm), units);

        if (units > 1) {
            vm.prank(borrower);
            vm.expectRevert(BelowCoverageLine.selector);
            f.ace.open(f.id, units - 1, principal, 0, borrower, OpenBounds(0, 0, 0));
        }
        vm.prank(borrower);
        loanId = f.ace.open(f.id, units, principal, 0, borrower, OpenBounds(0, 0, 0));
        assertEq(f.read.loan(loanId).collateralUnits, units, "fixture: the loan holds exactly the gate's minimum");
    }

    /// @dev What settlement needs, read off the SHIPPED lens rather than recomputed here.
    /// @dev The suite deliberately keeps no arithmetic of its own: a mirror that drifts proves nothing.
    function _need(Fx memory f, uint256 loanId) internal view returns (uint256) {
        return f.lens.collateralNeeded(f.id, loanId);
    }

    /// @dev Claims carrying a live balance: `n_eff`, the count `collateralNeeded` pays a ceiling for.
    /// @dev IT IS ONE OR ZERO NOW. `n_eff` was the whole variable this file measured against: settlement ceiled
    /// @dev PER FUNDED TICK, so its requirement floored at one atom per live claim tick and the gap grew with
    /// @dev the count. A loan holds one claim, so `n_eff` is a fact rather than a dial, and the gap is one atom.
    function _liveTicks(Fx memory f, uint256 loanId) internal view returns (uint256) {
        return f.read.claimCount(f.id, loanId);
    }

    /* ========== the sequence that answers the admission question ========== */

    /// @notice THE PROPERTY, on the shape that used to break it: a loan the gate admits covers settlement.
    /// @notice The gate now asks 73 units where it once asked 41, and settlement needs 63.
    /// @dev The regime is an 18/18 pair, so `unitScale` is 1e18 and one collateral wei buys about one quote wei.
    /// @dev A one-wei claim then ceils to two units at every tick under the floor, which was the whole exposure.
    /// @dev THE EXACT LINE IS PINNED, not just the inequality, so a change in the SLACK trips this too.
    /// @dev This is issue #305 inverted: it asserted 41 against a need of 63 while the defect stood.
    function test_DustMinDebt_TheAdmittedLoanCoversSettlement() public {
        Fx memory f = _deploy(18, 18, DUST_MIN_DEBT, Constants.MIN_COVERAGE_WAD);
        _seedUniform(f, f.minLot);
        (uint256 loanId, uint256 units) = _openAtTheLine(f, DUST_MIN_DEBT);
        assertEq(f.read.claimCount(f.id, loanId), 1, "fixture: the draw funded, and a draw funds exactly one claim");
        assertEq(_liveTicks(f, loanId), 1, "fixture: that one claim is live");

        uint256 need = _need(f, loanId);
        emit log_named_uint("n_eff", TICKS);
        emit log_named_uint("debt", f.read.loan(loanId).debt);
        emit log_named_uint("unitScale", f.unitScale);
        emit log_named_uint("fundingFloor", f.read.fundingFloor(f.id, loanId));
        emit log_named_uint("units at the gate's line", units);
        emit log_named_uint("_collateralNeeded", need);

        assertEq(units, 35, "the gate's line on this draw: requiredAt 41 plus the 32-tick cap");
        assertEq(need, 32, "what settlement asks of it, and the line now clears it"); // WAS 63: settlement ceiled PER TICK
        assertLe(need, units, "a loan the admission gate admitted covers settlement");
    }

    /// @notice The same loan settled at tenor leaves its lenders whole: no shortfall, no bad debt.
    /// @dev The lens is only a MIRROR of the hub's own sum, so this asserts on `shortfallOf`, which `_settle` writes.
    /// @dev It is the ground truth for the sibling above: if the lens were wrong, this would still be right.
    /// @dev This is issue #305 inverted: it asserted a 22-unit shortfall while the defect stood.
    function test_DustMinDebt_ForceCloseLeavesTheLendersWhole() public {
        Fx memory f = _deploy(18, 18, DUST_MIN_DEBT, Constants.MIN_COVERAGE_WAD);
        _seedUniform(f, f.minLot);
        (uint256 loanId,) = _openAtTheLine(f, DUST_MIN_DEBT);

        vm.warp(f.read.loan(loanId).expiry + 1);
        f.ace.forceClose(loanId);
        assertTrue(f.read.loan(loanId).closedAt != 0, "fixture: the expiry fold must actually settle the loan");

        (uint256 short, uint256 quoteAtBook) = f.read.shortfallOf(loanId);
        emit log_named_uint("shortfall units", short);
        emit log_named_uint("shortfall at book (quote)", quoteAtBook);
        assertEq(short, 0, "a loan settled straight off the admission gate leaves its lenders whole");
        assertEq(quoteAtBook, 0, "so nothing is booked against the funding ticks");
    }

    /// @notice The SHIPPED coverage multiple gets the same line, one derived off `maxClaimTicks` and not off k.
    /// @dev It separates the property from `MIN_COVERAGE_WAD`: the slack is a tick count, so k does not move it.
    /// @dev This is issue #305 inverted: it asserted 54 against a need of 63 while the defect stood.
    function test_DustMinDebt_AtTheShippedK_TheAdmittedLoanCoversSettlement() public {
        Fx memory f = _deploy(18, 18, DUST_MIN_DEBT, 1.4e18);
        _seedUniform(f, f.minLot);
        (uint256 loanId, uint256 units) = _openAtTheLine(f, DUST_MIN_DEBT);
        emit log_named_uint("units at the gate's line", units);
        emit log_named_uint("_collateralNeeded", _need(f, loanId));
        assertEq(units, 46, "the gate's line at the shipped k: requiredAt 54 plus the 32-tick cap");
        assertEq(_need(f, loanId), 32, "what settlement asks of it, and the line now clears it"); // WAS 63
        assertLe(_need(f, loanId), units, "the shipped coverage multiple covers a dust-floor market too");
    }

    /* ============================ the control ============================ */

    /// @notice THE CONTROL, and it must PASS: the identical shape on the suite's baseline `minDebt`.
    /// @dev Its job is to show the failures above are the DUST FLOOR and not the fixture's plumbing.
    /// @dev At `minDebt` 10e6 on an 18-dec quote the position is ~1.2e7 collateral units, so 32 ceilings vanish.
    function test_Control_OnTheBaselineMinDebt_StaysCoveredAtTheGatesOwnLine() public {
        Fx memory f = _deploy(18, 18, 10e6, Constants.MIN_COVERAGE_WAD);
        _seedUniform(f, f.minLot);
        (uint256 loanId, uint256 units) = _openAtTheLine(f, f.minLot * TICKS);
        assertEq(_liveTicks(f, loanId), 1, "fixture: the draw funds ONE claim, whatever the seed was spread over");
        assertLe(_need(f, loanId), units, "a market whose dust floor clears the bound is covered at the line");
    }

    /* ========== the corner with NO dust floor at all: coarse collateral ========== */

    /// @notice THE REACHABILITY CASE, now closed: the gate asks 33 whole units where settlement needs 32.
    /// @notice It needed no dust floor: this is the SHIPPED `minDebt` and the SHIPPED `k`.
    /// @notice W is `minDebt / omega`, and `omega` is the quote that ONE collateral WEI buys.
    /// @notice A whole-unit collateral at a few thousand dollars puts W under one, not under 640.
    /// @dev So the corner does not need an absurd `minDebt`: it needs collateral COARSE beside the loan.
    /// @dev Tokenized whole units -- shares, bars, wrapped singles -- are exactly that shape, and legal.
    /// @dev Each funded tick then ceils its own claim to a WHOLE unit, so 32 ticks ask 32 units of a 1-unit lot.
    /// @dev The band sits near tick 92100, where one whole unit is worth about 10,000 of a 6-dec quote.
    /// @dev This is issue #305 inverted: it asserted a 1-unit line against a need of 32 while the defect stood.
    /// @dev THE PRICE OF THE FIX IS VISIBLE HERE: a 5,000-quote loan now demands 33 whole units, not one.
    function test_CoarseCollateral_TheAdmittedLoanCoversSettlement() public {
        priceOffset = 92_100; // ~1e4 above par: one whole unit is ~10,000 quote tokens. SET BEFORE the deploy
        Fx memory f = _deploy(0, 6, PocDeployConfig.MIN_DEBT, PocDeployConfig.MIN_COVERAGE_WAD);
        f.record.setMinPrice(PriceFrame.px(1e23, address(f.quote), address(f.coll))); // ten times the band, so the cap never gates
        _seedUniform(f, f.minLot);

        (uint256 loanId, uint256 units) = _openAtTheLine(f, f.minLot * TICKS);
        assertEq(_liveTicks(f, loanId), 1, "fixture: the draw funds ONE claim, whatever the seed was spread over");
        uint256 floor = f.read.fundingFloor(f.id, loanId);

        emit log_named_uint("omega (quote wei one collateral wei buys)", floor / f.unitScale);
        emit log_named_uint("W (collateral units at coverage one)", (f.read.loan(loanId).debt * f.unitScale) / floor);
        emit log_named_uint("units at the gate's line", units);
        emit log_named_uint("_collateralNeeded", _need(f, loanId));

        assertEq(units, 24, "the gate's line on a whole-unit collateral: requiredAt 1 plus the 32-tick cap");
        assertEq(_need(f, loanId), 17, "what settlement asks: ONE ceiling over the whole debt, not one per rung"); // WAS TICKS
        assertLe(_need(f, loanId), units, "a coarse-collateral market covers settlement at the gate's line");
    }

    /// @notice The same coarse market settled: every class is paid its atom, and nothing is booked as bad debt.
    /// @notice The loan is never in distress and is never touched after the draw: it simply expires.
    /// @dev Each of the 32 classes takes the whole unit its own claim ceils to, which is what the line funds.
    /// @dev This is issue #305 inverted: it asserted 4,843.75 quote of bad debt while the defect stood.
    function test_CoarseCollateral_ForceCloseLeavesTheLendersWhole() public {
        priceOffset = 92_100; // SET BEFORE the deploy: the price is a creation param, not a rung a seed picks
        Fx memory f = _deploy(0, 6, PocDeployConfig.MIN_DEBT, PocDeployConfig.MIN_COVERAGE_WAD);
        f.record.setMinPrice(PriceFrame.px(1e23, address(f.quote), address(f.coll)));
        _seedUniform(f, f.minLot);
        (uint256 loanId, uint256 units) = _openAtTheLine(f, f.minLot * TICKS);

        uint256 debt = f.read.loan(loanId).debt;
        uint256 atBook = (units * f.read.fundingFloor(f.id, loanId)) / f.unitScale;
        assertGt(atBook, debt, "fixture: the posted collateral is worth more than the debt at the funding floor");

        vm.warp(f.read.loan(loanId).expiry + 1);
        f.ace.forceClose(loanId);
        (uint256 short, uint256 quoteAtBook) = f.read.shortfallOf(loanId);
        emit log_named_uint("debt", debt);
        emit log_named_uint("collateral at book", atBook);
        emit log_named_uint("shortfall units", short);
        emit log_named_uint("bad debt at book (quote)", quoteAtBook);
        assertEq(short, 0, "every class is handed the unit its claim ceils to");
        assertEq(quoteAtBook, 0, "so nothing is booked against an overcollateralized loan");
    }

    /* ============ the line leaves no headroom for the next roll ============ */

    /// @notice A loan opened EXACTLY at the line cannot roll: the expiry fold force-closes it instead.
    /// @notice Two things take from it and nothing gives back, so the successor is judged short by construction.
    /// @dev The fold credits the keeper sliver FIRST and judges `units - sliver` against the successor's line.
    /// @dev `derivedPrincipal` floors at `minDebt` and must also cover the new fee, so the successor cannot shrink.
    /// @dev Force-close is the SAFE branch, so this is headroom the borrower has to leave, not a hole.
    /// @dev A borrower who wants the roll posts above the line; nothing in `src` obliges them to discover that.
    function test_OpenedAtTheLine_TheExpiryFoldForceClosesRatherThanRolling() public {
        Fx memory f = _deploy(18, 18, DUST_MIN_DEBT, Constants.MIN_COVERAGE_WAD, SPACING, 50);
        /// @dev Deep enough that the TOP TICK alone funds the draw, so a drained ladder cannot refuse the
        /// @dev successor `InsufficientCash` and mask the leg under test.
        /// @dev The dust scale is what puts the gap INSIDE the band: the successor's fee costs one unit,
        /// @dev not thousands, so the trigger leg still clears and only the coverage line can refuse.
        uint256 principal = DUST_MIN_DEBT;
        _seedUniform(f, 2 * principal);
        (uint256 loanId, uint256 units) = _openAtTheLine(f, principal);
        assertEq(f.read.fundingFloor(f.id, loanId), topTick, "fixture: the draw floored at the market price");

        uint64 tenor = f.ace.idToMarketParams(f.id).minTenor;
        vm.prank(borrower);
        f.ace.setAutoRefinance(loanId, tenor, 0, 0);
        vm.warp(f.read.loan(loanId).expiry + 1);

        (bool ok, bytes4 reason,) = f.ace.tryContinue(loanId);
        assertFalse(ok, "the successor cannot be admitted off a position sitting on the line");
        assertEq(reason, BelowCoverageLine.selector, "and the coverage line is what refuses it, by name");

        uint256 countBefore = f.read.loanCount();
        f.ace.forceClose(loanId);
        assertEq(f.read.loanCount(), countBefore, "the fold opened no successor");
        assertTrue(f.read.loan(loanId).closedAt != 0, "it took the settle branch instead");

        (uint256 short,) = f.read.shortfallOf(loanId);
        emit log_named_uint("units at the line", units);
        emit log_named_uint("shortfall units", short);
        assertEq(short, 0, "and the settle branch is safe: the line still covers every claim");
    }

    /* ============= the window the coverage line closes, swept ============= */

    /// @dev One measurement: a fresh market, the adversarial shape, an open at the gate's own line.
    /// @dev Returns whether settlement is short, and W, the position in collateral units at coverage one.
    function _probe(uint256 principal, int24 gridSpacing) internal returns (bool short, uint256 w) {
        Fx memory f = _deploy(18, 18, DUST_MIN_DEBT, Constants.MIN_COVERAGE_WAD, gridSpacing);
        _seedDustThenFloor(f, principal);
        (uint256 loanId, uint256 units) = _openAtTheLine(f, principal);
        assertEq(_liveTicks(f, loanId), 1, "fixture: the probe funds ONE claim; there is no cap left to span");
        short = _need(f, loanId) > units;
        w = (principal * f.unitScale) / f.read.fundingFloor(f.id, loanId);
    }

    /// @dev The sweep itself: every principal is opened at the gate's line and must settle covered.
    /// @dev The points are the window the defect used to occupy, so a sweep that finds nothing is the result.
    /// @dev It returns the widest W it reached, which is what says the sweep actually entered that window.
    function _scan(uint256[6] memory principals, int24 gridSpacing) internal returns (uint256 widestW) {
        for (uint256 i; i < principals.length; i++) {
            (bool short, uint256 w) = _probe(principals[i], gridSpacing);
            emit log_named_uint("principal", principals[i]);
            emit log_named_uint("  W (collateral units at coverage one)", w);
            assertFalse(short, "no position admitted at the coverage line may be short at settlement");
            if (w > widestW) widestW = w;
        }
        emit log_named_uint("widest W swept", widestW);
    }

    /// @dev `n / (k - 1)`, in collateral units, at the market's own coverage multiple.
    function _derivedBound(uint256 k) internal pure returns (uint256) {
        return (TICKS * 1e18) / (k - 1e18);
    }

    /// @notice SWEEPS the window the defect used to occupy, on the default grid, and finds it empty.
    /// @notice Every point once measured short at the line; each is now opened at the line and settles covered.
    /// @dev The sweep must REACH that window or it proves nothing, so the widest W it touched is asserted into it.
    function test_CoverageLine_ClosesTheWholeWindow_OnTheDefaultGrid() public {
        uint256 derived = _derivedBound(Constants.MIN_COVERAGE_WAD);
        emit log_named_uint("derived bound n/(k-1)", derived);
        uint256 widestW = _scan([uint256(32), 256, 320, 384, 448, 512], SPACING);
        assertGt(widestW, derived / 2, "the sweep must reach deep into the window, or it is not testing it");
    }

    /// @notice The SAME sweep at deeper W, where the window once reached furthest.
    /// @dev IT RAN AT THE TIGHTEST GRID GENESIS ALLOWED, because a tighter grid narrowed the funded band, drove
    /// @dev `R` toward one and pushed the window further out. There is no grid and no band: `R` is one outright,
    /// @dev so what is left to vary is W itself, and the deeper points are what this row now sweeps.
    function test_CoverageLine_ClosesTheWholeWindow_AtDeeperW() public {
        uint256 derived = _derivedBound(Constants.MIN_COVERAGE_WAD);
        emit log_named_uint("derived bound n/(k-1)", derived);
        uint256 widestW = _scan([uint256(32), 448, 512, 544, 576, 608], SPACING);
        assertGt(widestW, derived / 2, "the sweep must reach deep into the window, or it is not testing it");
    }
}
