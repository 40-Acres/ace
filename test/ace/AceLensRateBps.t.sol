// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.36;

import {Test} from "forge-std/Test.sol";
import {Ace} from "../../src/ace/hub/Ace.sol";
import {AceLens} from "../../src/ace/lens/AceLens.sol";
import {Constants} from "../../src/ace/hub/Constants.sol";
import {MarketParams} from "../../src/ace/hub/Types.sol";
import {MockERC20} from "../mocks/MockERC20.sol";
import {MockStakeVault} from "../mocks/MockStakeVault.sol";
import {MockPersistenceRecord} from "../mocks/MockPersistenceRecord.sol";
import {MockMonthlyHub, MockPerTermHub} from "../mocks/MockRatePeriodHubs.sol";
import {HubHasNoCode, HubRateNotPerYear} from "../../src/interfaces/HubRatePeriod.sol";
import {AceFixtures} from "../utils/AceFixtures.sol";

/// @title AceLensRateBps
/// @notice The view that composes the PRICE OF CREDIT, which #380 records as the thing no view composed.
/// @notice `lenderAprBps` is the lender's rate in bps a year, so the lender leg is the field and the all-in leg adds the protocol share.
/// @dev Every figure here is hand-computed from the closed form and spelled as a literal, never read off `src`.
/// @dev The two APR legs are tenor-INVARIANT, so two markets quoting the same rate at any terms must return the SAME number.
/// @dev The extension-face leg is gone with dues: a cash extension moves no face, so the view returns the two APR legs alone.
contract AceLensRateBpsTest is Test {
    Ace internal ace;
    AceLens internal lens;
    MockERC20 internal usdc;
    MockStakeVault internal vault;
    MockPersistenceRecord internal rec; // every market here but the recordless row's is record-backed
    bytes32 internal shipped; // the PoC shape, created once in setUp: a duplicate id reverts MarketExists

    function setUp() public {
        usdc = new MockERC20("USD Coin", "USDC", 6);
        vault = new MockStakeVault(42);
        rec = new MockPersistenceRecord(address(usdc), address(vault));
        AceFixtures.Deployment memory d = AceFixtures.deploy(_params(7 days, 7 days, 2086));
        (ace, shipped) = (d.ace, d.id);
        lens = new AceLens(address(ace));
    }

    function _params(uint64 minTenor, uint64 maxTenor, uint256 lenderAprBps) internal view returns (MarketParams memory p) {
        p = AceFixtures.marketParams(address(usdc), address(vault));
        p.record = address(rec);
        p.lenderAprBps = lenderAprBps;
        p.minTenor = minTenor;
        p.maxTenor = maxTenor;
    }

    function _create(uint64 minTenor, uint64 maxTenor, uint256 lenderAprBps) internal returns (bytes32) {
        return ace.createMarket(_params(minTenor, maxTenor, lenderAprBps));
    }

    /* ============================== the shipped market, and the unit it is quoted in ============================== */

    /// @notice THE SHIPPED POC MARKET: 2086 bps a year is 20.86 percent to the lender and 22.94 percent all-in.
    /// @notice 2,294 IS THE ALL-IN FIGURE and 2,086 is the lender's; #380 quotes the first, which reads like the second.
    /// @dev The all-in leg carries the protocol share on top: `2086 * 11000 / 10000 = 2294.6`, truncated.
    function test_RateBps_TheShippedMarketReadsAsTwentyThreePercent() public view {
        (uint256 lenderApr, uint256 allInApr) = lens.rateBps(shipped);
        assertEq(lenderApr, 2086, "the lender's own rate, bps a year");
        assertEq(allInApr, 2294, "and the borrower's, with the protocol share riding on top");
    }

    /// @notice #380'S OWN REPRO, NOW A PLAIN RATE: a floor-tenor market at 500 is 5 percent a year, whatever its term.
    /// @notice Under the per-term unit this read as 15,768,000 percent a year; the unit is what changed, not the view.
    /// @dev Genesis floors `minTenor` at `MIN_TENOR_FLOOR`, which bounds no rate; the all-in leg is the field times 1.1, truncated.
    function test_RateBps_TheFloorTenorMarketIsStillCreatableAndNowReadable() public {
        uint64 floor = Constants.MIN_TENOR_FLOOR;
        bytes32 mid = _create(floor, floor, 500);
        assertEq(ace.idToMarketParams(mid).lenderAprBps, 500, "PREMISE: genesis takes it, at the rate #380 measured");

        (uint256 lenderApr, uint256 allInApr) = lens.rateBps(mid);
        assertEq(lenderApr, 500, "500 bps a year is 5 percent to the lender at a ten-second term");
        assertEq(allInApr, 550, "and 5.5 percent all-in");
    }

    /* ============================== the unit-invariance that is the whole deliverable ============================== */

    /// @notice THE SAME RATE AT THREE TERM UNITS RETURNS ONE NUMBER: a year is the unit, so the term never enters the read.
    /// @notice 2086 a year at a week, a fortnight and four weeks is the SAME price of credit, and the view says so.
    function test_RateBps_ThreeTermUnitsAtOneRealRateReturnTheSameNumber() public {
        bytes32 fortnightly = _create(14 days, 14 days, 2086);
        bytes32 monthly = _create(28 days, 28 days, 2086);

        (uint256 lw, uint256 aw) = lens.rateBps(shipped);
        (uint256 lf, uint256 af) = lens.rateBps(fortnightly);
        (uint256 lm, uint256 am) = lens.rateBps(monthly);

        assertEq(lw, 2086, "the weekly market's lender APR, hand-computed");
        assertEq(lf, lw, "the fortnightly market quotes the same price of credit");
        assertEq(lm, lw, "and so does the four-weekly one");
        assertEq(aw, 2294, "the all-in leg, hand-computed");
        assertEq(af, aw, "invariant in the same way");
        assertEq(am, aw, "at every unit");
    }

    /// @notice THE APR LEGS READ THE FIELD ALONE: two markets at 500 bps a year, one single-tenor and one spanning four, quote one rate.
    function test_RateBps_TheAprLegsReadTheFieldAlone() public {
        bytes32 flat = _create(7 days, 7 days, 500);
        bytes32 wide = _create(7 days, 28 days, 500);

        (uint256 lFlat, uint256 aFlat) = lens.rateBps(flat);
        (uint256 lWide, uint256 aWide) = lens.rateBps(wide);

        assertEq(lFlat, 500, "500 bps a year is 5 percent to the lender");
        assertEq(aFlat, 550, "and 5.5 percent all-in");
        assertEq(lWide, lFlat, "the span does not move the lender APR: that leg reads the field alone");
        assertEq(aWide, aFlat, "nor the all-in one");
    }

    /// @notice THE CEILING, READ OFF THE VIEW: a one-year market at 2272 a year quotes 22.72 percent, 24.99 all-in.
    /// @dev 2272 is a LITERAL, never imported: a mirror of the implementation cannot disagree with it.
    function test_RateBps_TheFeeShareCeilingMarketReadsJustInsideAQuarter() public {
        (uint256 lenderApr, uint256 allInApr) = lens.rateBps(_create(365 days, 365 days, 2272));
        assertEq(lenderApr, 2272, "a one-year market reads its own rate");
        assertEq(allInApr, 2499, "and 24.99 percent all-in, just inside the quarter");
    }

    /// @notice A RECORDLESS MARKET QUOTES THE SAME RATE as its record-backed twin: the record never decides what credit costs.
    function test_RateBps_ARecordlessMarketQuotesTheSameRate() public {
        MarketParams memory p = _params(7 days, 7 days, 2086);
        p.record = address(0);
        bytes32 bare = ace.createMarket(p);

        (uint256 lenderApr, uint256 allInApr) = lens.rateBps(bare);
        (uint256 lenderTwin, uint256 allInTwin) = lens.rateBps(shipped);
        assertEq(lenderApr, lenderTwin, "the lender APR does not read the record");
        assertEq(allInApr, allInTwin, "nor does the all-in one");
    }

    /* ============================== the floor, which no term truncates ============================== */

    /// @notice THE FLOOR RATE READS AS ONE AT EVERY TERM: the view reads the field, so no term pushes it under a bps a year.
    /// @notice Under the per-term unit a two-year market at 1 read as zero; that truncation is gone with the unit.
    /// @dev The all-in leg is `1 * 11000 / 10000`, which truncates to 1, never to 0.
    function test_RateBps_TheFloorRateReadsAsOneAtEveryTerm() public {
        (uint256 atAYear,) = lens.rateBps(_create(365 days, 365 days, 1));
        assertEq(atAYear, 1, "one bps a year is the smallest rate this view can state");

        (uint256 atTwoYears, uint256 allIn) = lens.rateBps(_create(730 days, 730 days, 1));
        assertEq(atTwoYears, 1, "and a two-year market at the floor reads the same one, never zero");
        assertEq(allIn, 1, "the all-in leg truncates to the floor, not under it");
    }

    /* ============================== the unknown id, which must not be the one view that panics ============================== */

    /// @notice AN UNKNOWN ID ANSWERS ZERO, matching `fundingFloor`, `claimOf` and `marketState`.
    /// @notice A market that does not exist has a zero rate field, and the view reads it rather than reverting.
    /// @dev A revert here would make `rateBps` the one lens view a caller must pre-check an id for.
    function test_RateBps_AnUnknownIdAnswersZeroRatherThanPanicking() public view {
        bytes32 ghost = keccak256("no market was ever created at this id");
        (uint256 lenderApr, uint256 allInApr) = lens.rateBps(ghost);
        assertEq(lenderApr, 0, "no market, no rate");
        assertEq(allInApr, 0, "on both legs");

        assertEq(lens.claimOf(ghost, 1), 0, "the neighbours this row is matched against answer the same way");
        assertEq(lens.fundingFloor(ghost, 1), 0, "a derived read over an absent market is zero, not a fault");
        assertEq(lens.marketState(ghost).unitScale, 0, "and the scalar state reads empty rather than reverting");
    }

    /// @notice A LENS REFUSES A HUB THAT DOES NOT QUOTE A YEAR: `rateBps` reads the field as bps a year, so a per-`minTenor` hub would read 52x low.
    /// @dev A hub naming no `RATE_PERIOD()`, one naming a month and an address with no code each refuse the constructor; this tree's hub binds.
    function test_TheLensRefusesAHubThatDoesNotQuoteAYear() public {
        address perTerm = address(new MockPerTermHub());
        address monthly = address(new MockMonthlyHub());
        vm.expectRevert(HubRateNotPerYear.selector);
        new AceLens(perTerm);
        vm.expectRevert(HubRateNotPerYear.selector);
        new AceLens(monthly);
        vm.expectRevert(HubHasNoCode.selector);
        new AceLens(address(0xDEAD));
        assertEq(address(new AceLens(address(ace)).ACE()), address(ace), "control: this tree's hub, answering a year, binds");
    }
}
