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
import {AceFixtures} from "../utils/AceFixtures.sol";

/// @title AceLensRateBps
/// @notice The view that composes the PRICE OF CREDIT, which #380 records as the thing no view composed.
/// @notice `baseBps` is per the market's OWN term unit, so the bare number says nothing until it is annualized.
/// @dev Every figure here is hand-computed from the closed form and spelled as a literal, never read off `src`.
/// @dev The two APR legs are tenor-INVARIANT, so two markets quoting the same real rate must return the SAME number.
/// @dev THE ROLL LEG IS AT `maxTenor`: the worst term the market admits, and the one the fee-share rail is checked at.
/// @dev That keeps the view a MARKET characterisation; a borrower's own roll uses `ap.tenor` and is derivable per draw.
contract AceLensRateBpsTest is Test {
    Ace internal ace;
    AceLens internal lens;
    MockERC20 internal usdc;
    MockStakeVault internal vault;
    MockPersistenceRecord internal rec; // every market here is record-backed: a recordless market reports no roll leg
    bytes32 internal shipped; // the PoC shape, created once in setUp: a duplicate id reverts MarketExists

    function setUp() public {
        usdc = new MockERC20("USD Coin", "USDC", 6);
        vault = new MockStakeVault(42);
        rec = new MockPersistenceRecord(address(usdc), address(vault));
        AceFixtures.Deployment memory d = AceFixtures.deploy(_params(7 days, 7 days, 40));
        (ace, shipped) = (d.ace, d.id);
        lens = new AceLens(address(ace));
    }

    function _params(uint64 minTenor, uint64 maxTenor, uint256 baseBps) internal view returns (MarketParams memory p) {
        p = AceFixtures.marketParams(address(usdc), address(vault));
        p.record = address(rec);
        p.baseBps = baseBps;
        p.minTenor = minTenor;
        p.maxTenor = maxTenor;
    }

    function _create(uint64 minTenor, uint64 maxTenor, uint256 baseBps) internal returns (bytes32) {
        return ace.createMarket(_params(minTenor, maxTenor, baseBps));
    }

    /* ============================== the shipped market, and the unit it is quoted in ============================== */

    /// @notice THE SHIPPED POC MARKET: 40 bps per 7 days is 20.85 percent to the lender and 22.94 percent all-in.
    /// @notice 2,294 IS THE ALL-IN FIGURE and 2,086 is the lender's; #380 quotes the first, which reads like the second.
    /// @dev `40 * 365/7 = 2085.71`, truncated; the all-in leg carries the protocol share on top and truncates to 2294.
    function test_RateBps_TheShippedMarketReadsAsTwentyThreePercent() public view {
        (uint256 lenderApr, uint256 allInApr,) = lens.rateBps(shipped);
        assertEq(lenderApr, 2085, "the lender's own annualized rate");
        assertEq(allInApr, 2294, "and the borrower's, with the protocol share riding on top");
    }

    /// @notice #380'S OWN REPRO, MADE LEGIBLE RATHER THAN CLOSED: a floor-tenor term unit at 500 bps is still creatable.
    /// @notice The bare field says "500". The rate is 15,768,000 percent a year, and the view is what says so.
    /// @dev #380 measured it at one second; genesis now floors `minTenor` at `MIN_TENOR_FLOOR`, which bounds no rate.
    /// @dev `500 * 31,536,000 / MIN_TENOR_FLOOR` exactly, at its value of 10; the all-in leg is that times 1.1, multiply-before-divide.
    /// @dev The roll multiple is `1e18 * 1e8 / (1e8 - 500*11000)` = `1e21/945`, floored: a flat market's is unit-free.
    function test_RateBps_TheFloorTenorMarketIsStillCreatableAndNowReadable() public {
        uint64 floor = Constants.MIN_TENOR_FLOOR;
        bytes32 mid = _create(floor, floor, 500);
        assertEq(ace.idToMarketParams(mid).baseBps, 500, "PREMISE: genesis takes it, at the rate #380 measured");

        (uint256 lenderApr, uint256 allInApr, uint256 rollMul) = lens.rateBps(mid);
        assertEq(lenderApr, 1_576_800_000, "500 bps per MIN_TENOR_FLOOR is 1.5768 billion bps a year");
        assertEq(allInApr, 1_734_480_000, "and 1.73 billion all-in, which is 17 million percent");
        assertEq(rollMul, 1_058_201_058_201_058_201, "one roll inflates the face 1.0582x, once per MIN_TENOR_FLOOR");
    }

    /* ============================== the unit-invariance that is the whole deliverable ============================== */

    /// @notice THE SAME REAL RATE IN THREE TERM UNITS RETURNS ONE NUMBER, which is what "no view composes it" asked for.
    /// @notice 40 per week, 80 per fortnight and 160 per four weeks are the SAME price of credit, and the bare field hides that.
    /// @dev Truncation is identical across the three because the quotient is, so the invariance is exact and not approximate.
    function test_RateBps_ThreeTermUnitsAtOneRealRateReturnTheSameNumber() public {
        bytes32 fortnightly = _create(14 days, 14 days, 80);
        bytes32 monthly = _create(28 days, 28 days, 160);

        (uint256 lw, uint256 aw,) = lens.rateBps(shipped);
        (uint256 lf, uint256 af,) = lens.rateBps(fortnightly);
        (uint256 lm, uint256 am,) = lens.rateBps(monthly);

        assertEq(lw, 2085, "the weekly market's lender APR, hand-computed");
        assertEq(lf, lw, "the fortnightly market quotes the same price of credit");
        assertEq(lm, lw, "and so does the four-weekly one");
        assertEq(aw, 2294, "the all-in leg, hand-computed");
        assertEq(af, aw, "invariant in the same way");
        assertEq(am, aw, "at every unit");
    }

    /// @notice THE ROLL MULTIPLE IS NOT INVARIANT, AND THAT IS THE POINT: it is per ROLL, where the APR legs are per YEAR.
    /// @notice A fortnightly market inflates the face more per roll and rolls half as often, so the year-cost is the same.
    /// @dev `1e18 * 1e8 / (1e8 - baseBps*11000)` at a single-tenor market: 2500/2489, 1250/1239 and 625/614.
    /// @dev Asserted at 1e14 resolution so the figure reads as a multiple rather than as an opaque WAD.
    /// @dev Every market here is single-tenor, so the `maxTenor` the view reads is also its `minTenor`.
    function test_RateBps_TheRollMultipleIsPerRollAndNotPerYear() public {
        (,, uint256 rw) = lens.rateBps(shipped);
        (,, uint256 rf) = lens.rateBps(_create(14 days, 14 days, 80));
        (,, uint256 rm) = lens.rateBps(_create(28 days, 28 days, 160));

        assertEq(rw / 1e14, 10044, "1.0044x per weekly roll");
        assertEq(rf / 1e14, 10088, "1.0088x per fortnightly roll, on a market with the SAME annual rate");
        assertEq(rm / 1e14, 10179, "1.0179x per four-weekly roll");
    }

    /// @notice THE ROLL LEG READS `maxTenor` AND THE APR LEGS DO NOT, which is the whole of the tenor ruling.
    /// @notice Two markets at 500 bps per week: one single-tenor, one spanning to four. SAME rate, DIFFERENT worst roll.
    /// @notice 28,678 bps all-in is the ratified pawn band's own published figure, so this leg is checked against the record.
    /// @dev `n` uses `maxTenor`: at 7d/28d the share is `500*28*11000 / (1e8*7)` = 0.22, so the multiple is `1/0.78`.
    /// @dev Swap it to `minTenor` and the wide market returns 10582 with the flat one, which is what this row refuses.
    /// @dev EVERY OTHER ROW HERE IS SINGLE-TENOR, where the two agree, so without this one the ruling is untested.
    function test_RateBps_TheRollLegReadsMaxTenorWhereTheAprLegsReadMinTenor() public {
        bytes32 flat = _create(7 days, 7 days, 500);
        bytes32 wide = _create(7 days, 28 days, 500);

        (uint256 lFlat, uint256 aFlat, uint256 rFlat) = lens.rateBps(flat);
        (uint256 lWide, uint256 aWide, uint256 rWide) = lens.rateBps(wide);

        assertEq(lFlat, 26_071, "500 bps a week is 260.71 percent to the lender");
        assertEq(aFlat, 28_678, "and 286.78 percent all-in, which is the pawn band's published number");
        assertEq(lWide, lFlat, "the span does not move the lender APR: that leg reads minTenor alone");
        assertEq(aWide, aFlat, "nor the all-in one");

        assertEq(rFlat / 1e14, 10582, "a flat market's worst roll is 1.0582x");
        assertEq(rWide / 1e14, 12820, "the SAME rate over a 4x span is 1.2820x, because the worst term is four times as long");
    }

    /// @notice NO CREATABLE MARKET CAN ROLL A FACE BY MORE THAN 4/3, which is the fee-share rail read from the other side.
    /// @notice It is also why the view needs no guard on its subtraction: `d > n` is that rail restated, with 4x of margin.
    /// @dev The rate is drawn UNDER the share rail at the shape's own term multiple, so every market here is really created.
    /// @dev `s <= 1/4` gives `1/(1-s) <= 4/3`, and `mulDiv` floors, so the bound is exact at the literal below.
    function testFuzz_RateBps_TheRollMultipleCannotExceedFourThirds(uint64 minTenorSeed, uint256 multipleSeed, uint256 bpsSeed) public {
        uint64 minTenor = uint64(bound(minTenorSeed, 1 hours, 365 days));
        uint64 maxTenor = minTenor * uint64(bound(multipleSeed, 1, 8));
        uint256 cap = (2500 * 10000 * 10000 * uint256(minTenor)) / (10000 * uint256(maxTenor) * 11000);
        uint256 baseBps = bound(bpsSeed, 1, cap);

        (,, uint256 rollMul) = lens.rateBps(_create(minTenor, maxTenor, baseBps));
        assertGe(rollMul, 1e18, "a roll never shrinks a face: the fee is charged, not refunded");
        assertLe(rollMul, 1_333_333_333_333_333_333, "and it never inflates it past 4/3, whatever shape the market takes");
    }

    /// @notice THE CEILING, READ OFF THE VIEW: a single-tenor market at 2272 rolls its face 1.3331x every term unit.
    /// @dev 2272 is a LITERAL, never imported: a mirror of the implementation cannot disagree with it.
    /// @dev `1e18 * 1e8 / (1e8 - 2272*11000)` = `1e18 * 3125/2344`, the reciprocal of `principalForOwed`'s denominator.
    function test_RateBps_TheFeeShareCeilingReadsAsAThirdPerRoll() public {
        (uint256 lenderApr, uint256 allInApr, uint256 rollMul) = lens.rateBps(_create(365 days, 365 days, 2272));
        assertEq(lenderApr, 2272, "a one-year term unit annualizes to itself");
        assertEq(allInApr, 2499, "and 24.99 percent all-in, just inside the quarter");
        assertEq(rollMul / 1e14, 13331, "1.3331x of face per roll, which is the most the hub can ever write");
    }

    /// @notice A RECORDLESS MARKET REPORTS NO ROLL LEG: it cannot arm (`ArmNeedsRecord`), so no loan there ever takes that roll.
    /// @notice Its APR legs are the record-backed twin's, unchanged: the record decides whether a roll exists, never what credit costs.
    function test_RateBps_ARecordlessMarketReportsNoRollMultiple() public {
        MarketParams memory p = _params(7 days, 7 days, 40);
        p.record = address(0);
        bytes32 bare = ace.createMarket(p);

        (uint256 lenderApr, uint256 allInApr, uint256 rollMul) = lens.rateBps(bare);
        (uint256 lenderTwin, uint256 allInTwin, uint256 rollTwin) = lens.rateBps(shipped);
        assertEq(rollMul, 0, "no roll leg where no loan can arm");
        assertEq(rollTwin / 1e14, 10044, "CONTROL: the record-backed twin still reports its 1.0044x roll");
        assertEq(lenderApr, lenderTwin, "the lender APR does not read the record");
        assertEq(allInApr, allInTwin, "nor does the all-in one");
    }

    /* ============================== truncation, bounded and documented ============================== */

    /// @notice THE TRUNCATION FLOOR, PINNED RATHER THAN GUARDED: under one bps of APR the view reads zero.
    /// @notice It bites only above a one-year term unit, where one unit of `baseBps` is already under a bps of APR.
    /// @dev At `minTenor == 1 year` and `baseBps == 1` the quotient is exactly 1; at two years it is 0.
    function test_RateBps_TruncatesToZeroBelowItsOwnResolution() public {
        (uint256 atAYear,,) = lens.rateBps(_create(365 days, 365 days, 1));
        assertEq(atAYear, 1, "one bps a year is the smallest rate this view can state");

        (uint256 atTwoYears, uint256 allIn,) = lens.rateBps(_create(730 days, 730 days, 1));
        assertEq(atTwoYears, 0, "half a bps a year reads as zero, and nothing reverts");
        assertEq(allIn, 0, "the all-in leg truncates with it");
    }

    /* ============================== the unknown id, which must not be the one view that panics ============================== */

    /// @notice AN UNKNOWN ID ANSWERS ZERO, matching `fundingFloor`, `claimOf` and `marketState` rather than dividing by it.
    /// @notice `minTenor` is zero on a market that does not exist, and every leg of this view divides by it.
    /// @dev A `Panic(0x11)` here would make `rateBps` the one lens view a caller must pre-check an id for.
    function test_RateBps_AnUnknownIdAnswersZeroRatherThanPanicking() public view {
        bytes32 ghost = keccak256("no market was ever created at this id");
        (uint256 lenderApr, uint256 allInApr, uint256 rollMul) = lens.rateBps(ghost);
        assertEq(lenderApr, 0, "no market, no rate");
        assertEq(allInApr, 0, "on both legs");
        assertEq(rollMul, 0, "and no roll multiple either");

        assertEq(lens.claimOf(ghost, 1), 0, "the neighbours this row is matched against answer the same way");
        assertEq(lens.fundingFloor(ghost, 1), 0, "a derived read over an absent market is zero, not a fault");
        assertEq(lens.marketState(ghost).unitScale, 0, "and the scalar state reads empty rather than reverting");
    }
}
