// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.36;

import {FullMath} from "@uniswap/v4-core/src/libraries/FullMath.sol";
import {Math} from "@openzeppelin/contracts/utils/math/Math.sol";
import {WarpClock} from "../utils/WarpClock.sol";
import {DeleverageCrank} from "../utils/DeleverageCrank.sol";
import {Ace} from "../../src/ace/hub/Ace.sol";
import {AceLens} from "../../src/ace/lens/AceLens.sol";
import {MarketParams, MarketState, OpenBounds} from "../../src/ace/hub/Types.sol";
import {PositionManager} from "../../src/ace/positions/PositionManager.sol";
import {BelowCoverageLine} from "../../src/ace/hub/Borrower.sol";
import {NotExpired} from "../../src/ace/hub/Settlement.sol";
import {Constants} from "../../src/ace/hub/Constants.sol";
import {HubLoanTerm} from "../../src/interfaces/HubLoanTerm.sol";
import {MockERC20} from "../mocks/MockERC20.sol";
import {MockPersistenceRecord} from "../mocks/MockPersistenceRecord.sol";
import {AceFixtures} from "../utils/AceFixtures.sol";
import {AceReader} from "../utils/AceReader.sol";

/// @title AceTakeFollowsTrigger
/// @notice THE RULE: a RECORDED market settling inside the term takes the claim at the loan's trigger, `ceil(lot * 1e18 / k)`, capped at the coverage line.
/// @notice Never less than the claim's need at the price; from the expiry second the take is that need alone, at either door.
/// @notice So the lender is whole at `max(trigger, price / k)`: at the trigger for a pledge up to `k` lines or a repay down to `1 / k` of the debt.
/// @dev `lot` is the units BEFORE the keeper sliver comes off: the trigger was priced on the whole lot, so the take must be too.
/// @dev Each in-term row pins the take AND the property it buys, the pot's worth at `max(trigger, price / k)` over the claim, which no formula restates.
/// @dev Rows named `Control` hold on the old rule as well; every other row stays red until the take follows the trigger.
contract AceTakeFollowsTriggerTest is WarpClock, DeleverageCrank {
    Ace internal ace;
    AceReader internal read;
    AceLens internal lens;
    PositionManager internal pm;
    MockERC20 internal usdc;
    MockERC20 internal coll;
    MockPersistenceRecord internal rec; // zero on a recordless market
    bytes32 internal mid;
    uint256 internal scale;

    address internal alice = address(0xA11CE); // the market's one lender
    address internal borrower = address(0xB0B);
    address internal keeper = address(0xCA11E5);

    uint256 internal constant SEED = 10_000e6; // the lender's resting cash
    uint256 internal constant PRINCIPAL = 1_000e6;
    uint256 internal constant K = 1.4e18; // the default fixture's coverage, so the cap binds past 1.4 lines
    uint16 internal constant BOUNTY = 50; // the default fixture's keeper bounty, so a real sliver comes off every row

    event Finalized(uint256 indexed id, uint256 collateralUnits, uint256 badDebt, address indexed executor);

    /// @dev What a row reads off the live loan the instant before it settles.
    struct Pre {
        uint256 lot; // collateral units, pre-sliver
        uint256 claim; // the live claim, which is the debt
        uint256 trig; // the trigger price on that lot and debt
        uint256 need; // the claim's need at the market's price
        uint256 line; // the coverage line on that debt at the market's price, the in-term take's cap
        uint256 sliver; // the keeper's debt-sized cut
    }

    function _deleverageQuote() internal view override returns (address) {
        return address(usdc);
    }

    function setUp() public {
        _warpTo(1_000_000);
        (ace, pm) = AceFixtures.newAceWithEscrow(AceFixtures.TREASURY);
        read = new AceReader(address(ace));
        lens = new AceLens(address(ace));
        _make(18, K, BOUNTY, true);
    }

    /* ================================ fixtures ================================ */

    /// @dev A fresh pair and market on the shared hub, at par.
    function _make(uint8 cd, uint256 k, uint16 bounty, bool recorded) internal {
        _makeAt(cd, 0, k, bounty, recorded);
    }

    /// @dev The same at a named human price, where `1e18` is one quote per whole collateral; zero keeps par.
    function _makeAt(uint8 cd, uint256 humanWad, uint256 k, uint16 bounty, bool recorded) internal {
        MarketParams memory p = _baseParams(cd, humanWad, recorded);
        p.minCoverageWad = k;
        p.settleBountyBps = bounty;
        _create(p);
    }

    /// @dev A recorded market with the decline channel live, at dials genesis admits.
    function _makeBand() internal {
        MarketParams memory p = _baseParams(18, 0, true);
        p.minCoverageWad = K;
        p.settleBountyBps = BOUNTY;
        p.deleverageFloorEpsBps = 100;
        p.deleverageProtocolBps = 0;
        p.deleverageBandBps = 3000;
        p.deleverageTargetBps = 4000;
        p.deleverageStopBps = 1000;
        _create(p);
    }

    function _baseParams(uint8 cd, uint256 humanWad, bool recorded) internal returns (MarketParams memory p) {
        usdc = new MockERC20("USD Coin", "USDC", 6);
        coll = new MockERC20("Collateral", "COLL", cd);
        p = AceFixtures.marketParams(address(usdc), address(coll));
        if (humanWad != 0) p.price = AceFixtures.px(humanWad, address(usdc), address(coll));
        if (recorded) {
            rec = new MockPersistenceRecord(address(usdc), address(coll));
            rec.setMinPrice(type(uint256).max); // no draw cap: the subject is the take, never admission
            p.record = address(rec);
        } else {
            rec = MockPersistenceRecord(address(0));
            p.record = address(0);
        }
        p.lender = alice;
    }

    function _create(MarketParams memory p) internal {
        mid = ace.createMarket(p);
        scale = read.marketState(mid).unitScale;
    }

    function _lend(uint256 amount) internal {
        usdc.mint(alice, amount);
        vm.startPrank(alice);
        usdc.approve(address(ace), amount);
        ace.deposit(mid, amount);
        vm.stopPrank();
    }

    function _open(uint256 units, uint256 principal) internal returns (uint256 loanId) {
        coll.mint(borrower, units);
        vm.startPrank(borrower);
        coll.approve(address(pm), units);
        loanId = ace.open(mid, units, principal, 0, borrower, OpenBounds(0, 0, 0));
        vm.stopPrank();
    }

    function _repay(uint256 loanId, uint256 amount) internal {
        usdc.mint(borrower, amount);
        vm.startPrank(borrower);
        usdc.approve(address(ace), amount);
        ace.repay(loanId, amount);
        vm.stopPrank();
    }

    /// @dev Flag mode, answering below at every level: the settle window has held, so `finalize` opens.
    function _armSettle() internal {
        rec.setBandPrice(0);
        rec.setBelow(true);
    }

    function _finalize(uint256 loanId) internal {
        _armSettle();
        vm.prank(keeper);
        ace.finalize(loanId);
    }

    function _forceClose(uint256 loanId) internal {
        vm.prank(keeper);
        ace.forceClose(loanId);
    }

    /* ================================ readers ================================ */

    function _price() internal view returns (uint256) {
        return ace.idToMarketParams(mid).price;
    }

    function _k() internal view returns (uint256) {
        return ace.idToMarketParams(mid).minCoverageWad;
    }

    /// @dev The coverage line at the market's price, spelled from the gate's definition: `requiredAt` plus one atom.
    function _line(uint256 debt) internal view returns (uint256) {
        return FullMath.mulDivRoundingUp(_k() * debt, scale, _price() * 1e18) + 1;
    }

    /// @dev The claim at the trigger: the lot over the coverage, ceiled toward the lender.
    function _atTrigger(uint256 lot) internal view returns (uint256) {
        return FullMath.mulDivRoundingUp(lot, 1e18, _k());
    }

    /// @dev The ruled in-term take: the claim at the trigger capped at the line, never under the need, never past the post-sliver lot.
    function _inTermTake(Pre memory s) internal view returns (uint256) {
        return Math.min(Math.max(s.need, Math.min(_atTrigger(s.lot), s.line)), s.lot - s.sliver);
    }

    function _pre(uint256 loanId) internal view returns (Pre memory s) {
        s = _snap(loanId);
        assertLe(s.trig, _price(), "PREMISE: a live recorded loan's trigger sits at or under the price");
    }

    /// @dev The same read with no premise on the trigger, for a STAGED lot no verb could reach.
    function _snap(uint256 loanId) internal view returns (Pre memory s) {
        s.lot = read.loan(loanId).collateralUnits;
        s.claim = read.claimOf(mid, loanId);
        s.trig = read.triggerPrice(loanId);
        s.need = FullMath.mulDivRoundingUp(s.claim, scale, _price());
        s.line = _line(s.claim);
        uint256 bty = FullMath.mulDiv(read.loan(loanId).debt * ace.idToMarketParams(mid).settleBountyBps, scale, 10000 * _price());
        s.sliver = Math.min(bty, s.lot);
        assertEq(s.claim, read.loan(loanId).debt, "PREMISE: a live loan's claim is its debt");
        assertEq(s.need, lens.collateralNeeded(mid, loanId), "PREMISE: the need spelled here is the shipped view's");
    }

    /* =============================== assertions =============================== */

    /// @dev Every in-term row's facts, the take FIRST so a red run names the pot and not a side effect.
    function _assertTakesTheInTermTake(uint256 loanId, Pre memory s) internal view {
        uint256 pot = read.invPotOf(mid, loanId);
        uint256 want = _inTermTake(s);
        assertEq(pot, want, "the pot is min(ceil(lot * 1e18 / k), line) on the PRE-sliver lot, never under the need");
        assertEq(read.unitsOwedOf(loanId, borrower), s.lot - s.sliver - want, "the borrower keeps the lot less the sliver and the take");
        _assertWholeAtTriggerOrPriceOverK(pot, s);
        _assertCoveredAndConserved(loanId, s);
    }

    /// @dev The cap's guarantee: the pot is worth the claim at `max(trigger, price / k)`, spelled without dividing.
    function _assertWholeAtTriggerOrPriceOverK(uint256 pot, Pre memory s) internal view {
        bool atTrigger = pot * s.trig >= s.claim * scale;
        bool atPriceOverK = pot * _price() * 1e18 >= s.claim * scale * _k();
        assertTrue(atTrigger || atPriceOverK, "the lender is whole at max(trigger, price / k)");
    }

    /// @dev Where the cap does not bind: the pot is worth the claim at the trigger itself.
    function _assertWholeAtTheTrigger(uint256 pot, Pre memory s) internal view {
        assertGe(pot * s.trig, s.claim * scale, "the lender is whole at the trigger: pot * trigger >= claim * unitScale");
    }

    /// @dev No shortfall of either half, the keeper took its sliver, and every retired unit has a ledger entry.
    function _assertCoveredAndConserved(uint256 loanId, Pre memory s) internal view {
        (uint256 shortUnits, uint256 shortQuote) = read.shortfallOf(loanId);
        assertEq(shortUnits, 0, "a covered settlement records no unit shortfall");
        assertEq(shortQuote, 0, "and no bad debt");
        assertEq(read.marketState(mid).realizedLossAtBook, 0, "nor any at the market level");
        assertEq(read.unitsOwedOf(loanId, keeper), s.sliver, "the keeper took exactly the debt-sized sliver");
        uint256 owned = read.invPotOf(mid, loanId) + read.unitsOwedOf(loanId, borrower) + read.unitsOwedOf(loanId, keeper);
        assertEq(owned, s.lot, "pot + borrower credit + keeper sliver == lot: no unit left custody unnamed");
    }

    /// @dev The forfeit-free tenor take: the need alone, the rest credited to the borrower.
    function _assertTakesTheNeed(uint256 loanId, Pre memory s) internal view {
        assertEq(read.invPotOf(mid, loanId), s.need, "from the expiry second the take is the claim's need at the price");
        assertEq(read.unitsOwedOf(loanId, borrower), s.lot - s.sliver - s.need, "and the borrower keeps everything above it, less the sliver");
        _assertCoveredAndConserved(loanId, s);
    }

    /// @dev The two rules must differ on the fixture, or a row cannot tell them apart.
    function _assertRulesDiffer(Pre memory s) internal view {
        assertGt(Math.min(_atTrigger(s.lot), s.line), s.need, "PREMISE: the capped claim at the trigger exceeds the need, so the old and new takes differ");
        assertLe(_atTrigger(s.lot) + s.sliver, s.lot, "PREMISE: the fit proof, the claim at the trigger and the sliver fit the lot");
    }

    /* ======================= 1. what lowers the trigger ======================= */

    /// @notice A 2x over-pledge then `finalize` inside the term: past `k` lines, so the take is the coverage line, not the need.
    function test_OverPledgedTwiceTheLine_FinalizeInsideTheTerm_TakesTheCoverageLine() public {
        _lend(SEED);
        uint256 loanId = _open(2 * _line(PRINCIPAL), PRINCIPAL);
        Pre memory s = _pre(loanId);
        assertLt(s.trig, (_price() * 51) / 100, "PREMISE: twice the line pulls the trigger to about half the price");
        assertGt(_atTrigger(s.lot), s.line, "PREMISE: twice the line is past k lines, so the cap binds");
        _assertRulesDiffer(s);

        _armSettle();
        vm.expectEmit(true, true, false, true, address(ace));
        emit Finalized(loanId, s.lot - s.sliver, 0, keeper);
        vm.prank(keeper);
        ace.finalize(loanId);

        _assertTakesTheInTermTake(loanId, s);
        assertEq(read.invPotOf(mid, loanId), s.line, "the take is the coverage line on the debt");
    }

    /// @notice A partial repay to 80% of the debt, units untouched, then `finalize`: above `1 / k`, so the take is the claim at the NEW trigger.
    /// @dev Repay is permissionless, so no product clamp can close this leg: only the hub's take can.
    function test_PartialRepayAboveOneOverK_FinalizeInsideTheTerm_TakesTheClaimAtTheNewTrigger() public {
        _lend(SEED);
        uint256 lot = _line(PRINCIPAL);
        uint256 loanId = _open(lot, PRINCIPAL);
        _repay(loanId, (PRINCIPAL * 2) / 10);
        assertEq(read.loan(loanId).collateralUnits, lot, "PREMISE: a repay moves no units");
        assertEq(read.loan(loanId).debt, (PRINCIPAL * 8) / 10, "PREMISE: the debt is the fraction left");
        Pre memory s = _pre(loanId);
        assertLt(s.trig, (_price() * 81) / 100, "PREMISE: the repay pulled the trigger to about four fifths of the price");
        assertLt(_atTrigger(s.lot), s.line, "PREMISE: four fifths of the debt is over 1 / k, so the cap does not bind");
        _assertRulesDiffer(s);

        _finalize(loanId);

        _assertTakesTheInTermTake(loanId, s);
        assertEq(read.invPotOf(mid, loanId), _atTrigger(s.lot), "the take is the claim at the trigger");
        _assertWholeAtTheTrigger(read.invPotOf(mid, loanId), s);
    }

    /// @notice A partial repay to 40% of the debt, under `1 / k`: the claim at the trigger passes the line, so the take is the line at the current debt.
    function test_PartialRepayBelowOneOverK_FinalizeInsideTheTerm_TakesTheLineAtTheCurrentDebt() public {
        _lend(SEED);
        uint256 lot = _line(PRINCIPAL);
        uint256 loanId = _open(lot, PRINCIPAL);
        _repay(loanId, (PRINCIPAL * 6) / 10);
        assertEq(read.loan(loanId).debt, (PRINCIPAL * 4) / 10, "PREMISE: the debt is the fraction left");
        Pre memory s = _pre(loanId);
        assertLt(s.trig, _price() / 2, "PREMISE: the repay pulled the trigger under half the price");
        assertGt(_atTrigger(s.lot), s.line, "PREMISE: two fifths of the debt is under 1 / k, so the cap binds");
        assertEq(s.line, _line((PRINCIPAL * 4) / 10), "PREMISE: the cap is the line on the debt left, not on the debt drawn");
        _assertRulesDiffer(s);

        _finalize(loanId);

        _assertTakesTheInTermTake(loanId, s);
        assertEq(read.invPotOf(mid, loanId), s.line, "the take is the coverage line at the current debt");
    }

    /// @notice A deleverage restore sells units and melts debt to the target margin; a later `finalize` takes the capped claim at the restored trigger.
    function test_DeleverageRestore_FinalizeInsideTheTerm_TakesTheCappedClaimAtTheRestoredTrigger() public {
        _makeBand();
        _lend(SEED);
        uint256 loanId = _open(_line(PRINCIPAL), PRINCIPAL);
        uint256 lotBefore = read.loan(loanId).collateralUnits;
        uint256 debtBefore = read.loan(loanId).debt;
        _armBand(loanId);

        (uint256 sold,) = ace.deleverage(loanId, 0, "");

        assertGt(sold, 0, "PREMISE: the crank sold");
        assertEq(read.loan(loanId).closedAt, 0, "PREMISE: a restore, not a close");
        assertEq(read.loan(loanId).collateralUnits, lotBefore - sold, "PREMISE: the sold units left the lot");
        assertLt(read.loan(loanId).debt, debtBefore, "PREMISE: the proceeds melted debt");
        Pre memory s = _pre(loanId);
        assertLt(s.trig, _price(), "PREMISE: the restore left the trigger under the price");
        _assertRulesDiffer(s);

        _finalize(loanId);

        _assertTakesTheInTermTake(loanId, s);
    }

    /// @notice A withdrawal down to a record line priced UNDER the market's price, then `finalize`: the take is the claim at the trigger.
    /// @dev The withdraw gate folds `min(price, record)`, so a fallen record lets the lot sit on a line whose trigger is under the price.
    /// @dev A record at 80% of the price leaves 1.25 lines, under `k` lines, so the cap does not bind.
    function test_WithdrawToARecordLineUnderThePrice_FinalizeInsideTheTerm_TakesTheClaimAtTheTrigger() public {
        _lend(SEED);
        uint256 loanId = _open(2 * _line(PRINCIPAL), PRINCIPAL);
        uint256 cap = (_price() * 8) / 10;
        rec.setMinPrice(cap);
        uint256 free = lens.withdrawableUnits(mid, loanId);
        assertGt(free, 0, "PREMISE: there is slack above the record line");
        vm.prank(borrower);
        ace.withdrawCollateral(loanId, free, borrower);
        assertEq(lens.withdrawableUnits(mid, loanId), 0, "PREMISE: the lot now sits on its record line");
        Pre memory s = _pre(loanId);
        assertLe(s.trig, cap, "PREMISE: the trigger sits at or under the record line's price");
        _assertRulesDiffer(s);

        _finalize(loanId);

        _assertTakesTheInTermTake(loanId, s);
        _assertWholeAtTheTrigger(read.invPotOf(mid, loanId), s);
    }

    /// @dev Park the record between the loan's stop and band levels: in band, not in distress, above the stop.
    function _armBand(uint256 loanId) internal {
        MarketParams memory p = ace.idToMarketParams(mid);
        uint256 trig = read.triggerPrice(loanId);
        uint256 bandLevel = FullMath.mulDivRoundingUp(trig, 1e18, 1e18 - p.deleverageBandBps * 1e14);
        uint256 stopLevel = FullMath.mulDivRoundingUp(trig, 1e18, 1e18 - p.deleverageStopBps * 1e14);
        uint256 ps = (bandLevel + stopLevel) / 2;
        rec.setBandPrice(ps);
        rec.setMinPrice(ps);
    }

    /* ======================= 2. the cap, under and past k lines ======================= */

    /// @notice A pledge of 1.2 lines at k = 1.4, between the line and `k` lines: the take is the claim at the trigger, uncapped, and whole there.
    function test_PledgeBetweenTheLineAndKLines_IsWholeAtTheTriggerExactly() public {
        _lend(SEED);
        uint256 loanId = _open((_line(PRINCIPAL) * 6) / 5, PRINCIPAL);
        Pre memory s = _pre(loanId);
        assertLt(s.lot * 1e18, s.line * _k(), "PREMISE: the lot sits under k lines");
        assertLt(_atTrigger(s.lot), s.line, "PREMISE: so the claim at the trigger sits under the line");
        _assertRulesDiffer(s);

        _finalize(loanId);

        uint256 pot = read.invPotOf(mid, loanId);
        assertEq(pot, _atTrigger(s.lot), "the take is the claim at the trigger, the cap not binding");
        _assertWholeAtTheTrigger(pot, s);
        _assertTakesTheInTermTake(loanId, s);
    }

    /// @notice A pledge of 1.7 lines at k = 1.4, past `k` lines but under `k^2`: the take is exactly the coverage line, whole at `price / k`.
    /// @dev Between `k` and `k^2` lines is where a cap misplaced at `k^2` lines would still take the uncapped claim at the trigger.
    function test_PledgePastKLines_TakesExactlyTheLine() public {
        _lend(SEED);
        uint256 loanId = _open((_line(PRINCIPAL) * 17) / 10, PRINCIPAL);
        Pre memory s = _pre(loanId);
        assertGt(s.lot * 1e18, s.line * _k(), "PREMISE: the lot sits past k lines");
        assertLt(s.lot * 1e36, s.line * _k() * _k(), "PREMISE: and under k^2 lines");
        assertGt(_atTrigger(s.lot), s.line, "PREMISE: so the claim at the trigger passes the line");
        _assertRulesDiffer(s);

        _finalize(loanId);

        uint256 pot = read.invPotOf(mid, loanId);
        assertEq(pot, s.line, "the take is exactly the coverage line on the debt");
        assertGe(pot * _price() * 1e18, s.claim * scale * _k(), "the lender is whole at price / k");
        assertLt(pot * s.trig, s.claim * scale, "and short at the trigger: the cap is what binds");
        _assertTakesTheInTermTake(loanId, s);
    }

    /* =========================== 3. at the line, rounding =========================== */

    /// @notice ON the coverage line, inside the term, the ceil takes the claim at the trigger: at most two atoms over the need.
    function test_AtTheLine_TheTakeOvershootsTheNeedByAtMostTwoAtoms() public {
        _lend(SEED);
        uint256 line = _line(PRINCIPAL);
        coll.mint(borrower, line);
        vm.startPrank(borrower);
        coll.approve(address(pm), line);
        vm.expectRevert(BelowCoverageLine.selector);
        ace.open(mid, line - 1, PRINCIPAL, 0, borrower, OpenBounds(0, 0, 0));
        uint256 loanId = ace.open(mid, line, PRINCIPAL, 0, borrower, OpenBounds(0, 0, 0));
        vm.stopPrank();
        Pre memory s = _pre(loanId);
        _assertRulesDiffer(s);

        _finalize(loanId);

        uint256 pot = read.invPotOf(mid, loanId);
        assertEq(pot, _atTrigger(s.lot), "on the line the take is still the claim at the trigger");
        assertLe(pot - s.need, 2, "and the ceil overshoots the need by at most two atoms there");
        _assertWholeAtTheTrigger(pot, s);
        _assertCoveredAndConserved(loanId, s);
    }

    /// @notice The same at any coverage in band, any bounty up to its ceiling, any ticket: ceil(line / k) - need is in {0, 1, 2}.
    function testFuzz_AtTheLine_TheTakeIsTheClaimAtTheTriggerAndOvershootsByAtMostTwo(uint256 kSeed, uint256 bountySeed, uint256 principalSeed) public {
        uint256 k = bound(kSeed, Constants.MIN_COVERAGE_WAD, Constants.MAX_COVERAGE_WAD);
        uint16 b = uint16(bound(bountySeed, 0, Constants.MAX_SETTLE_BOUNTY_BPS));
        _make(18, k, b, true);
        uint256 principal = bound(principalSeed, 10e6, SEED);
        _lend(principal);
        uint256 loanId = _open(_line(principal), principal);
        Pre memory s = _pre(loanId);

        _finalize(loanId);

        uint256 pot = read.invPotOf(mid, loanId);
        assertEq(pot, _inTermTake(s), "on the line the take is the claim at the trigger");
        assertLe(pot - s.need, 2, "and overshoots the need by at most two atoms");
        _assertWholeAtTheTrigger(pot, s);
        _assertCoveredAndConserved(loanId, s);
    }

    /// @notice KNOWN ROW, the ceil ruling's cost: zero-decimal collateral, need 3, line 5, k = 1.05 -- the take is the whole lot.
    /// @dev The claim is 2.9 atoms at the price, so `requiredAt` is ceil(3.045) = 4 and the line is 5; ceil(5 / 1.05) = 5, which the cap at 5 leaves.
    function test_LowAtomLot_NeedThreeLineFive_TakesTheWholeLot() public {
        _makeAt(0, 10e18, Constants.MIN_COVERAGE_WAD, BOUNTY, true);
        _lend(100e6);
        uint256 draw = 29e6;
        uint256 line = _line(draw);
        assertEq(line, 5, "PREMISE: the coverage line is five atoms");
        uint256 loanId = _open(line, draw);
        Pre memory s = _pre(loanId);
        assertEq(s.need, 3, "PREMISE: the claim needs three atoms at the price");
        assertEq(s.sliver, 0, "PREMISE: the sliver floors to nothing at this size");
        assertEq(_atTrigger(s.lot), 5, "PREMISE: ceil(5 * 1e18 / 1.05e18) is the whole lot");

        _finalize(loanId);

        assertEq(read.invPotOf(mid, loanId), 5, "the ceil takes all five atoms");
        assertEq(read.unitsOwedOf(loanId, borrower), 0, "so the borrower keeps nothing on the line");
        _assertWholeAtTheTrigger(read.invPotOf(mid, loanId), s);
        _assertCoveredAndConserved(loanId, s);
    }

    /// @notice The take ROUNDS UP: with `lot * 1e18 % k != 0` it is the floor plus one, never the floor.
    /// @dev 1.2 lines, so the cap at the line cannot mask the rounding.
    function test_TheTakeRoundsUp_WhenTheLotDoesNotDivideByTheCoverage() public {
        _lend(SEED);
        uint256 lot = (_line(PRINCIPAL) * 6) / 5;
        if ((lot * 1e18) % _k() == 0) lot += 1;
        assertGt((lot * 1e18) % _k(), 0, "PREMISE: lot * 1e18 is not a multiple of k, so the floor and the ceil differ");
        uint256 loanId = _open(lot, PRINCIPAL);
        Pre memory s = _pre(loanId);
        assertLt(_atTrigger(s.lot), s.line, "PREMISE: under the cap");
        _assertRulesDiffer(s);

        _finalize(loanId);

        assertEq(read.invPotOf(mid, loanId), (lot * 1e18) / _k() + 1, "the take is floor(lot * 1e18 / k) + 1: the residue goes to the lender");
        _assertWholeAtTheTrigger(read.invPotOf(mid, loanId), s);
        _assertCoveredAndConserved(loanId, s);
    }

    /* ======================= 4. the clock, not the door ======================= */

    /// @notice CONTROL: an over-pledged `forceClose` at the expiry second takes the need, as it always has.
    function test_Control_OverPledgedForceCloseAtExpiry_TakesTheNeed() public {
        _lend(SEED);
        uint256 loanId = _open(2 * _line(PRINCIPAL), PRINCIPAL);
        Pre memory s = _pre(loanId);
        _assertRulesDiffer(s);
        _warpTo(read.loan(loanId).expiry);

        _forceClose(loanId);

        _assertTakesTheNeed(loanId, s);
    }

    /// @notice CONTROL: a `finalize` landing AT the expiry second takes the need, exactly as `forceClose` would.
    function test_Control_OverPledgedFinalizeAtTheExpirySecond_TakesTheNeed() public {
        _lend(SEED);
        uint256 loanId = _open(2 * _line(PRINCIPAL), PRINCIPAL);
        Pre memory s = _pre(loanId);
        _assertRulesDiffer(s);
        _warpTo(read.loan(loanId).expiry);

        _finalize(loanId);

        _assertTakesTheNeed(loanId, s);
    }

    /// @notice CONTROL: a `finalize` a day past expiry takes the need too.
    function test_Control_OverPledgedFinalizeADayAfterExpiry_TakesTheNeed() public {
        _lend(SEED);
        uint256 loanId = _open(2 * _line(PRINCIPAL), PRINCIPAL);
        Pre memory s = _pre(loanId);
        _warpTo(uint256(read.loan(loanId).expiry) + 1 days);

        _finalize(loanId);

        _assertTakesTheNeed(loanId, s);
    }

    /// @notice CONTROL: after expiry the two doors take the same, so no first caller picks the take.
    function test_Control_AfterExpiry_BothDoorsTakeTheSame() public {
        _lend(SEED);
        uint256 loanId = _open(2 * _line(PRINCIPAL), PRINCIPAL);
        Pre memory s = _pre(loanId);
        _warpTo(uint256(read.loan(loanId).expiry) + 1);
        uint256 snap = vm.snapshotState();

        _finalize(loanId);
        uint256 viaFinalize = read.invPotOf(mid, loanId);
        uint256 creditViaFinalize = read.unitsOwedOf(loanId, borrower);
        vm.revertToState(snap);
        _forceClose(loanId);

        assertEq(read.invPotOf(mid, loanId), viaFinalize, "the two doors take the same pot after expiry");
        assertEq(read.unitsOwedOf(loanId, borrower), creditViaFinalize, "and credit the borrower the same");
        _assertTakesTheNeed(loanId, s);
    }

    /// @notice One second BEFORE expiry the loan is still inside its term: `finalize` takes the in-term take, here the line.
    function test_OverPledgedFinalizeOneSecondBeforeExpiry_TakesTheInTermTake() public {
        _lend(SEED);
        uint256 loanId = _open(2 * _line(PRINCIPAL), PRINCIPAL);
        Pre memory s = _pre(loanId);
        _assertRulesDiffer(s);
        _warpTo(uint256(read.loan(loanId).expiry) - 1);

        _finalize(loanId);

        _assertTakesTheInTermTake(loanId, s);
    }

    /* ======================= 5. the fit-proof corner and LR-9 ======================= */

    /// @notice At k = 1.05 and the 200 bps bounty ceiling the claim at the trigger and the sliver still fit the lot.
    /// @dev The corner where `floor(lot (k - 1) / k) >= b * need >= sliver` has the least slack, so the min-clamp is likeliest to bind.
    function test_FitProofCorner_TheTakeAndTheSliverFitTheLotAndEveryUnitIsAccountedFor() public {
        _make(18, Constants.MIN_COVERAGE_WAD, uint16(Constants.MAX_SETTLE_BOUNTY_BPS), true);
        _lend(SEED);
        uint256 loanId = _open(_line(PRINCIPAL), PRINCIPAL);
        Pre memory s = _pre(loanId);
        assertGt(s.sliver, 0, "PREMISE: the corner pays a real sliver");
        _assertRulesDiffer(s);

        _finalize(loanId);

        _assertTakesTheInTermTake(loanId, s);
    }

    /// @notice The fit corner over every lot from the line to three times it, at every decimal shape the suite uses.
    function testFuzz_FitProofCorner_TheClampNeverBindsInsideTheTerm(uint256 principalSeed, uint256 lotSeed, uint256 decSeed) public {
        uint8 cd = decSeed % 3 == 0 ? 0 : (decSeed % 3 == 1 ? 6 : 18);
        _make(cd, Constants.MIN_COVERAGE_WAD, uint16(Constants.MAX_SETTLE_BOUNTY_BPS), true);
        uint256 principal = bound(principalSeed, 10e6, SEED);
        _lend(principal);
        uint256 line = _line(principal);
        uint256 loanId = _open(bound(lotSeed, line, 3 * line), principal);
        Pre memory s = _pre(loanId);

        _finalize(loanId);

        uint256 want = Math.max(s.need, Math.min(_atTrigger(s.lot), s.line));
        assertEq(read.invPotOf(mid, loanId), want, "the post-sliver clamp never binds: the take is the capped claim at the trigger");
        _assertTakesTheInTermTake(loanId, s);
    }

    /// @notice LR-9 after a RECORDED spread: backed burns net of outflow equal the inventory, before and after the in-kind exit.
    /// @dev The excess over need reaches the pot through the coverage spread, which must move the backed-burn total with it.
    function test_LR9_HoldsAcrossARecordedSpreadAndItsInKindExit() public {
        _lend(SEED);
        uint256 loanId = _open(2 * _line(PRINCIPAL), PRINCIPAL);
        Pre memory s = _pre(loanId);
        _assertRulesDiffer(s);
        uint256 burnsBefore = read.marketState(mid).cumulativeBackedBurns;

        _finalize(loanId);

        uint256 pot = read.invPotOf(mid, loanId);
        assertEq(pot, _inTermTake(s), "the recorded spread landed: the pot is the in-term take");
        MarketState memory st = read.marketState(mid);
        assertEq(st.cumulativeBackedBurns - burnsBefore, pot, "backed burns moved by the whole pot, spread included");
        assertEq(st.cumulativeBackedBurns - st.netSyntheticOutflow, pot, "LR-9: backed burns net of outflow != the inventory");
        assertEq(lens.headroom(mid), pot, "LR-9: AceLens.headroom() != the inventory");
        assertEq(read.poolLent(mid), 0, "the spread inflated retired principal: lent must fall by the claim alone");

        vm.prank(alice);
        uint256 out = ace.redeemInKind(loanId, alice);

        assertEq(out, pot, "the lender redeems the whole pot in kind");
        assertEq(coll.balanceOf(alice), pot, "and holds every unit of it");
        st = read.marketState(mid);
        assertEq(st.cumulativeBackedBurns - st.netSyntheticOutflow, read.invPotOf(mid, loanId), "LR-9 broke once the spread left in kind");
        assertEq(lens.headroom(mid), 0, "headroom drifted from the emptied inventory");
    }

    /* =============================== 6. the fuzz =============================== */

    /// @notice Any lot from the line to four times it, any partial repay that leaves a live loan: inside the term the lender is whole at max(T, P / k).
    function testFuzz_LotAboveTheLineAndAPartialRepay_TheLenderIsWholeAtTriggerOrPriceOverK(uint256 principalSeed, uint256 lotSeed, uint256 repaySeed) public {
        uint256 principal = bound(principalSeed, 10e6, SEED);
        _lend(principal);
        uint256 line = _line(principal);
        uint256 loanId = _open(bound(lotSeed, line, 4 * line), principal);
        uint256 debtFloor = ace.idToMarketParams(mid).minPrincipal / 2;
        uint256 pay = (principal * bound(repaySeed, 0, 9_999)) / 10_000;
        if (principal - pay < debtFloor) pay = principal - debtFloor;
        if (pay > 0) _repay(loanId, pay);
        Pre memory s = _pre(loanId);

        _finalize(loanId);

        uint256 pot = read.invPotOf(mid, loanId);
        _assertWholeAtTriggerOrPriceOverK(pot, s);
        assertEq(pot, _inTermTake(s), "the take is the capped claim at the trigger, never under the need");
        _assertCoveredAndConserved(loanId, s);
    }

    /* ============================ 7. the recordless control ============================ */

    /// @notice CONTROL: a RECORDLESS twin is untouched and still takes `min(units - sliver, coverage line)` at tenor.
    function test_Control_RecordlessTwin_StillTakesTheCoverageLineAtTenor() public {
        _make(18, K, BOUNTY, false);
        _lend(SEED);
        uint256 loanId = _open(2 * _line(PRINCIPAL), PRINCIPAL);
        Pre memory s = _pre(loanId);
        uint256 line = s.lot - lens.withdrawableUnits(mid, loanId);
        assertEq(line, _line(PRINCIPAL), "PREMISE: the line spelled here is the shipped lens's");
        assertGt(line, s.need, "PREMISE: the line exceeds the need, so the class split is visible");
        _warpTo(read.loan(loanId).expiry);

        _forceClose(loanId);

        uint256 pot = read.invPotOf(mid, loanId);
        assertEq(pot, Math.min(s.lot - s.sliver, line), "a recordless settlement still takes the coverage line");
        assertEq(read.unitsOwedOf(loanId, borrower), s.lot - s.sliver - pot, "and credits the borrower only what sits above it");
        _assertCoveredAndConserved(loanId, s);
    }

    /* ==================== 8. the boundaries, from both sides ==================== */

    /// @dev The coverage line as the shipped withdraw gate reads it, the lot less what it frees, at a record that never caps.
    function _assertLineIsTheGates(uint256 loanId, Pre memory s) internal view {
        assertEq(s.lot - lens.withdrawableUnits(mid, loanId), s.line, "PREMISE: the line spelled here is the shipped withdraw gate's");
    }

    /// @dev The in-term take's two bounds as properties: never past the line, never past the claim at the trigger unless it is the need.
    function _assertTakeBounds(uint256 pot, Pre memory s) internal view {
        assertLe(pot, s.line, "an in-term take never passes the coverage line");
        assertTrue(pot <= _atTrigger(s.lot) || pot == s.need, "nor the claim at the trigger, unless the need is the larger");
        assertGe(pot, s.need, "nor falls under the need on a covered lot");
    }

    /// @notice At EXACTLY k lines the claim at the trigger IS the line; one atom more and the cap takes that atom back; two fewer and the trigger rules.
    /// @dev The largest lot whose claim at the trigger fits the line is `floor(line * k / 1e18)`; a cap misplaced by an atom either way reddens a leg.
    function test_CapBoundary_AtExactlyKLines_TheTakeMeetsTheLineAndNeverPassesIt() public {
        _lend(SEED);
        uint256 line = _line(PRINCIPAL);
        uint256 kLines = (line * _k()) / 1e18;
        assertEq(_atTrigger(kLines), line, "PREMISE: at k lines the claim at the trigger is exactly the line");
        assertEq(_atTrigger(kLines + 1), line + 1, "PREMISE: one atom past k lines it passes the line by one");
        assertLt(_atTrigger(kLines - 2), line, "PREMISE: two atoms under k lines it sits under the line");
        uint256 snap = vm.snapshotState();

        uint256 at = _open(kLines, PRINCIPAL);
        Pre memory s = _pre(at);
        _assertLineIsTheGates(at, s);
        _finalize(at);
        assertEq(read.invPotOf(mid, at), line, "at k lines the take is the line, which is also the claim at the trigger");
        _assertWholeAtTheTrigger(line, s);
        _assertTakesTheInTermTake(at, s);

        vm.revertToState(snap);
        uint256 past = _open(kLines + 1, PRINCIPAL);
        s = _pre(past);
        _assertLineIsTheGates(past, s);
        _finalize(past);
        assertEq(read.invPotOf(mid, past), line, "one atom past k lines the cap holds the take at the line");
        assertEq(read.unitsOwedOf(past, borrower), kLines + 1 - s.sliver - line, "and the atom the cap refused is the borrower's");
        _assertCoveredAndConserved(past, s);

        vm.revertToState(snap);
        uint256 under = _open(kLines - 2, PRINCIPAL);
        s = _pre(under);
        _finalize(under);
        uint256 pot = read.invPotOf(mid, under);
        assertEq(pot, _atTrigger(kLines - 2), "under k lines the take is the claim at the trigger");
        assertLt(pot, line, "which sits under the line");
        _assertWholeAtTheTrigger(pot, s);
        _assertCoveredAndConserved(under, s);
    }

    /// @notice The repay boundary at `1 / k` of the debt: down to it the cap rules, the take the line on the debt left; one atom more and the trigger rules.
    /// @dev The largest debt whose line still fits under the claim at the trigger comes off the line's definition, then is pinned both ways as premises.
    function test_RepayBoundary_AtOneOverKOfTheDebt_TheCapHandsTheTakeToTheTrigger() public {
        _lend(SEED);
        uint256 lot = _line(PRINCIPAL);
        uint256 a = _atTrigger(lot);
        uint256 dStar = FullMath.mulDiv((a - 1) * 1e18, _price(), _k() * scale);
        assertLe(_line(dStar), a, "PREMISE: at this debt the line fits under the claim at the trigger");
        assertGt(_line(dStar + 1), a, "PREMISE: one atom more debt and the line passes it");
        assertApproxEqRel(dStar * _k(), PRINCIPAL * 1e18, 1e15, "PREMISE: the boundary debt is the debt drawn over k");
        uint256 snap = vm.snapshotState();

        uint256 id = _open(lot, PRINCIPAL);
        _repay(id, PRINCIPAL - dStar);
        Pre memory s = _pre(id);
        _assertLineIsTheGates(id, s);
        _finalize(id);
        assertEq(read.invPotOf(mid, id), s.line, "at 1 / k of the debt the take is the line on the debt left");
        _assertTakeBounds(s.line, s);
        _assertTakesTheInTermTake(id, s);

        vm.revertToState(snap);
        id = _open(lot, PRINCIPAL);
        _repay(id, PRINCIPAL - dStar - 1);
        s = _pre(id);
        _assertLineIsTheGates(id, s);
        _finalize(id);
        assertEq(read.invPotOf(mid, id), a, "one atom of debt over 1 / k the take is the claim at the trigger");
        _assertWholeAtTheTrigger(a, s);
        _assertTakeBounds(a, s);
        _assertTakesTheInTermTake(id, s);
    }

    /// @notice The clock on the TRIGGER arm: in the last second `finalize` takes the claim at the trigger and `forceClose` refuses; from expiry, the need.
    function test_ClockBoundary_OnTheTriggerArm_TheTakeStepsAtTheExpirySecondAtBothDoors() public {
        _lend(SEED);
        uint256 id = _open((_line(PRINCIPAL) * 6) / 5, PRINCIPAL);
        Pre memory s = _pre(id);
        assertLt(_atTrigger(s.lot), s.line, "PREMISE: under k lines, so the in-term take is the claim at the trigger");
        _assertRulesDiffer(s);
        uint256 expiry = read.loan(id).expiry;
        _warpTo(expiry - 1);
        uint256 snap = vm.snapshotState();

        vm.prank(keeper);
        vm.expectRevert(NotExpired.selector);
        ace.forceClose(id);
        _finalize(id);
        assertEq(read.invPotOf(mid, id), _atTrigger(s.lot), "in the term's last second finalize takes the claim at the trigger");
        _assertTakesTheInTermTake(id, s);

        vm.revertToState(snap);
        _warpTo(expiry);
        _finalize(id);
        _assertTakesTheNeed(id, s);

        vm.revertToState(snap);
        _warpTo(expiry);
        _forceClose(id);
        _assertTakesTheNeed(id, s);
    }

    /// @notice The clock reads the loan's OWN stored expiry: an extension moves it, so a `finalize` past the first expiry is still inside the term.
    function test_ExtendedLoan_FinalizePastItsFirstExpiry_IsStillInsideTheTerm() public {
        AceFixtures.installYesPolicy(ace, alice);
        _lend(SEED);
        uint256 id = _open(2 * _line(PRINCIPAL), PRINCIPAL);
        uint256 first = read.loan(id).expiry;
        _warpTo(first - 1 hours);
        usdc.mint(borrower, PRINCIPAL);
        vm.startPrank(borrower);
        usdc.approve(address(ace), PRINCIPAL);
        ace.extend(id, 0, "");
        vm.stopPrank();
        assertGt(read.loan(id).expiry, first + 1 hours, "PREMISE: the extension moved the stored expiry past the first");
        _warpTo(first + 1 hours);
        Pre memory s = _pre(id);
        _assertRulesDiffer(s);

        _finalize(id);

        _assertTakesTheInTermTake(id, s);
        assertEq(read.invPotOf(mid, id), s.line, "past the first expiry but inside the extended term, the take is the capped claim at the trigger");
    }

    /// @notice DARKNESS MOVES NO VALUE: a record dark at zero shuts the withdrawal, yet the take leaves the borrower all a live record would have freed.
    /// @dev The cap at `coverageLine(debt, P)` is what holds it: a withdrawal must leave `coverageLine(debt, min(P, record))`, never less.
    function test_DarkRecord_TheInTermTakeTakesNothingALiveRecordWouldHaveFreed() public {
        _lend(SEED);
        uint256 id = _open(2 * _line(PRINCIPAL), PRINCIPAL);
        Pre memory s = _pre(id);
        uint256 freeLive = lens.withdrawableUnits(mid, id);
        assertEq(freeLive, s.lot - s.line, "PREMISE: a live record at or over the price frees the lot down to the line");
        rec.setMinPrice(0);
        assertEq(lens.withdrawableUnits(mid, id), 0, "PREMISE: a dark record frees nothing");

        _finalize(id);

        assertEq(read.invPotOf(mid, id), s.line, "the take stops at the line");
        assertEq(read.unitsOwedOf(id, borrower), freeLive - s.sliver, "so the borrower keeps every unit a live record would have freed, less the sliver");
        _assertCoveredAndConserved(id, s);
    }

    /* ======================= 9. staged: the floor and the clamp ======================= */

    /// @dev QUARANTINED, `withdrawCollateral` with its coverage refusal removed: the custodian releases and the hub's units word is rewritten.
    function _stage(uint256 loanId, uint256 target) internal {
        uint256 units = read.loan(loanId).collateralUnits;
        vm.prank(address(ace));
        pm.release(loanId, address(0x5111C), units - target);
        vm.store(address(ace), bytes32(uint256(keccak256(abi.encode(loanId, HubLoanTerm.LOANS))) + 2), bytes32(target));
        assertEq(read.loan(loanId).collateralUnits, target, "PREMISE: the staged lot reads back as written");
        assertEq(pm.collateralOf(loanId), target, "PREMISE: and the custodian moved with it");
    }

    /// @notice BELT-AND-BRACES, staged: a trigger ABOVE the price, which no verb reaches, puts the claim at the trigger under the need; the floor holds.
    /// @dev Without the need floor the take would be `ceil(lot / k)`, short of the claim on a lot that covers it, and the lender would book a loss.
    function test_Staged_TriggerAboveThePrice_TheNeedFloorHoldsTheTakeAtTheNeed() public {
        _lend(SEED);
        uint256 id = _open(_line(PRINCIPAL), PRINCIPAL);
        _stage(id, (lens.collateralNeeded(mid, id) * 6) / 5);
        Pre memory s = _snap(id);
        assertGt(s.trig, _price(), "PREMISE: the staged trigger sits above the price");
        assertLt(_atTrigger(s.lot), s.need, "PREMISE: so the claim at the trigger is under the need");
        assertGe(s.lot - s.sliver, s.need, "PREMISE: while the lot less the sliver still covers the need");

        _finalize(id);

        assertEq(read.invPotOf(mid, id), s.need, "the need floor holds the take at the claim's need");
        _assertTakesTheNeed(id, s);
    }

    /// @notice The post-sliver clamp, staged: a lot one atom short of the need plus the sliver yields the lot less the sliver, the sliver still off the top.
    function test_Staged_LotUnderTheNeedPlusTheSliver_TheClampTakesTheLotLessTheSliverAndRecordsTheShort() public {
        _lend(SEED);
        uint256 id = _open(_line(PRINCIPAL), PRINCIPAL);
        Pre memory s0 = _snap(id);
        _stage(id, s0.need + s0.sliver - 1);
        Pre memory s = _snap(id);
        assertGt(s.sliver, 0, "PREMISE: a real sliver comes off");
        assertEq(s.sliver, s0.sliver, "PREMISE: the sliver is sized off the debt, so the staging left it");

        _finalize(id);

        assertEq(read.invPotOf(mid, id), s.need - 1, "the clamp takes the lot less the sliver, one atom short of the need");
        assertEq(read.unitsOwedOf(id, keeper), s.sliver, "the sliver still comes off the top");
        assertEq(read.unitsOwedOf(id, borrower), 0, "a short settlement credits the defaulted borrower nothing");
        (uint256 su, uint256 sq) = read.shortfallOf(id);
        assertEq(su, 1, "the shortfall record names the one atom the claim did not get");
        assertGt(sq, 0, "and books its value as a loss");
        assertEq(read.marketState(mid).realizedLossAtBook, sq, "the market's loss total moved with the record");
    }

    /// @notice CONTROL: a RECORDLESS loan on its line at tenor, where the clamp binds: the take is the lot less the sliver, the borrower keeps nothing.
    function test_Control_RecordlessOnTheLine_TheClampTakesTheLotLessTheSliver() public {
        _make(18, K, BOUNTY, false);
        _lend(SEED);
        uint256 id = _open(_line(PRINCIPAL), PRINCIPAL);
        Pre memory s = _pre(id);
        assertGt(s.sliver, 0, "PREMISE: a real sliver comes off");
        assertGt(s.line, s.lot - s.sliver, "PREMISE: the line passes the lot less the sliver, so the clamp binds");
        _warpTo(read.loan(id).expiry);

        _forceClose(id);

        assertEq(read.invPotOf(mid, id), s.lot - s.sliver, "the clamp takes the lot less the sliver");
        assertEq(read.unitsOwedOf(id, borrower), 0, "and leaves the borrower nothing");
        _assertCoveredAndConserved(id, s);
    }

    /* ==================== 10. the stored debt word and LR-9 with a buy ==================== */

    /// @notice A stranger's settlement leaves the debt word as it stood while `debtOf` reads zero; `HubLoanTerm.debtSlot` names that word.
    function test_StoredDebtWord_AStrangerSettlesAndTheWordKeepsTheDebtItSettled() public {
        _lend(SEED);
        uint256 id = _open(2 * _line(PRINCIPAL), PRINCIPAL);
        _repay(id, 300e6);
        uint256 debt = PRINCIPAL - 300e6;
        assertEq(ace.debtOf(id), debt, "PREMISE: the live debt is what the repay left");
        _armSettle();
        vm.prank(address(0x57A2A6E2));
        ace.finalize(id);

        assertEq(ace.debtOf(id), 0, "PREMISE: a settled loan owes nothing through debtOf");
        bytes32 slot = HubLoanTerm.debtSlot(id);
        assertEq(uint256(ace.extsload(slot)), debt, "the debt slot still holds the debt the settlement retired");
        assertEq(lens.loan(id).debt, debt, "and the lens decodes the same word");
        assertEq(uint256(ace.extsload(bytes32(uint256(slot) - 1))), 0, "the word under it is the units word, which settlement zeroed");
        assertEq(bytes32(uint256(slot) + 1), HubLoanTerm.slot(id), "and the word over it is the term word");
    }

    /// @notice LR-9 across a recorded spread, a stranger's partial buy at the ask, and the lender's in-kind exit of the rest.
    function test_LR9_HoldsAcrossARecordedSpreadThenABuyThenTheInKindExit() public {
        _lend(SEED);
        uint256 id = _open(2 * _line(PRINCIPAL), PRINCIPAL);
        Pre memory s = _pre(id);
        _finalize(id);
        uint256 pot = read.invPotOf(mid, id);
        assertGt(pot, s.need, "PREMISE: the recorded spread landed over the need");
        rec.setBelow(false);
        _warpAtLeastTo(read.inventoryAskOpensAt(id));

        address buyer = address(0xB1B1);
        uint256 spend = 100e6;
        usdc.mint(buyer, spend);
        vm.startPrank(buyer);
        usdc.approve(address(ace), spend);
        (uint256 bought, uint256 paid) = ace.buyInventory(id, spend, 0, buyer);
        vm.stopPrank();

        assertGt(bought, 0, "PREMISE: the buy filled");
        assertLt(bought, pot - s.need, "PREMISE: a partial fill, smaller even than the spread");
        assertGe(paid * scale, bought * _price(), "at no less than the market's price");
        assertEq(coll.balanceOf(buyer), bought, "the buyer holds what it bought");
        assertEq(read.invPotOf(mid, id), pot - bought, "and the pot fell by exactly that");
        MarketState memory st = read.marketState(mid);
        assertEq(st.cumulativeBackedBurns - st.netSyntheticOutflow, pot - bought, "LR-9 after the buy");
        assertEq(lens.headroom(mid), pot - bought, "headroom after the buy");

        vm.prank(alice);
        uint256 out = ace.redeemInKind(id, alice);

        assertEq(out, pot - bought, "the lender redeems the rest in kind");
        assertEq(read.invPotOf(mid, id), 0, "which empties the pot");
        st = read.marketState(mid);
        assertEq(st.cumulativeBackedBurns - st.netSyntheticOutflow, 0, "LR-9 once the spread left by trade and in kind");
        assertEq(lens.headroom(mid), 0, "headroom once the pot is empty");
    }

    /* ======================= 11. decimals and coverage, fuzzed ======================= */

    /// @notice Zero- and low-decimal collateral, up to a unit worth more than a quote atom, any lot and any repay: whole at max(T, P / k), the take bounded.
    function testFuzz_LowDecimals_LotAndRepay_WholeAtTriggerOrPriceOverK(uint256 decSeed, uint256 principalSeed, uint256 lotSeed, uint256 repaySeed) public {
        uint8[4] memory decs = [uint8(0), 2, 6, 8];
        uint256[4] memory human = [uint256(10e18), 50e18, 2e18, 60_000e18];
        uint256 i = decSeed % 4;
        _makeAt(decs[i], human[i], K, BOUNTY, true);
        uint256 principal = bound(principalSeed, 10e6, SEED);
        _lend(principal);
        uint256 line = _line(principal);
        uint256 id = _open(bound(lotSeed, line, 3 * line), principal);
        uint256 debtFloor = ace.idToMarketParams(mid).minPrincipal / 2;
        uint256 pay = (principal * bound(repaySeed, 0, 9_999)) / 10_000;
        if (principal - pay < debtFloor) pay = principal - debtFloor;
        if (pay > 0) _repay(id, pay);
        Pre memory s = _pre(id);

        _finalize(id);

        uint256 pot = read.invPotOf(mid, id);
        _assertWholeAtTriggerOrPriceOverK(pot, s);
        _assertTakeBounds(pot, s);
        assertEq(pot, _inTermTake(s), "the take is the capped claim at the trigger, never under the need");
        _assertCoveredAndConserved(id, s);
    }

    /// @notice The fit corner, k = 1.05 and the 200 bps bounty, with a partial repay: the post-sliver clamp never binds, whatever lowered the trigger.
    function testFuzz_FitProofCorner_WithARepay_TheClampNeverBinds(uint256 decSeed, uint256 lotSeed, uint256 repaySeed) public {
        uint8 cd = decSeed % 3 == 0 ? 0 : (decSeed % 3 == 1 ? 6 : 18);
        _make(cd, Constants.MIN_COVERAGE_WAD, uint16(Constants.MAX_SETTLE_BOUNTY_BPS), true); // at par, so a 90% repay still leaves a whole-atom sliver
        _lend(SEED);
        uint256 line = _line(PRINCIPAL);
        uint256 id = _open(bound(lotSeed, line, 3 * line), PRINCIPAL);
        _repay(id, (PRINCIPAL * bound(repaySeed, 1, 9_000)) / 10_000);
        Pre memory s = _pre(id);
        assertGt(s.sliver, 0, "PREMISE: the corner pays a real sliver");

        _finalize(id);

        uint256 pot = read.invPotOf(mid, id);
        assertEq(pot, Math.max(s.need, Math.min(_atTrigger(s.lot), s.line)), "the clamp at the lot less the sliver never binds");
        assertLe(pot + s.sliver, s.lot, "the take and the sliver fit the lot");
        _assertTakeBounds(pot, s);
        _assertCoveredAndConserved(id, s);
    }

    /// @notice Any coverage and bounty genesis admits, any lot to four lines and any repay: the take is bounded by the line and the trigger, and whole.
    function testFuzz_AnyCoverageAndBounty_LotAndRepay_TheTakeIsBoundedAndWhole(uint256 kSeed, uint256 bountySeed, uint256 lotSeed, uint256 repaySeed) public {
        uint256 k = bound(kSeed, Constants.MIN_COVERAGE_WAD, Constants.MAX_COVERAGE_WAD);
        _make(18, k, uint16(bound(bountySeed, 0, Constants.MAX_SETTLE_BOUNTY_BPS)), true);
        _lend(SEED);
        uint256 line = _line(PRINCIPAL);
        uint256 id = _open(bound(lotSeed, line, 4 * line), PRINCIPAL);
        uint256 pay = (PRINCIPAL * bound(repaySeed, 0, 9_000)) / 10_000;
        if (pay > 0) _repay(id, pay);
        Pre memory s = _pre(id);

        _finalize(id);

        uint256 pot = read.invPotOf(mid, id);
        _assertWholeAtTriggerOrPriceOverK(pot, s);
        _assertTakeBounds(pot, s);
        assertEq(pot, _inTermTake(s), "the take is the capped claim at the trigger, never under the need");
        _assertCoveredAndConserved(id, s);
    }
}
