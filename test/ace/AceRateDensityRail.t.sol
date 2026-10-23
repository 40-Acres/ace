// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.36;

import {WarpClock} from "../utils/WarpClock.sol";
import {Ace} from "../../src/ace/hub/Ace.sol";
import {Borrower} from "../../src/ace/hub/Borrower.sol";
import {Constants} from "../../src/ace/hub/Constants.sol";
import {LoanMath} from "../../src/ace/hub/libraries/LoanMath.sol";
import {MarketParams, OpenBounds} from "../../src/ace/hub/Types.sol";
import {PositionManager} from "../../src/ace/positions/PositionManager.sol";
import {MockERC20} from "../mocks/MockERC20.sol";
import {MockPersistenceRecord} from "../mocks/MockPersistenceRecord.sol";
import {MockStakeVault} from "../mocks/MockStakeVault.sol";
import {AceFixtures} from "../utils/AceFixtures.sol";
import {AceReader} from "../utils/AceReader.sol";

/// @title AceRateDensityRail
/// @notice What bounds the PRICE OF CREDIT once the per-term band is gone, and what that costs at the roll.
/// @notice The fee-share rail is the only ceiling left, and at a single-tenor market it lands on an exact integer.
/// @dev `minTenor == maxTenor` cancels the tenor on both sides of `feeFundable`, leaving `b * 11000 <= 2500 * 10000`.
/// @dev So 2272 admits and 2273 refuses at EVERY term unit; nothing here is a property of the 7-day fixture.
/// @dev 2272 and 2273 are spelled as LITERALS on purpose: a mirror of the implementation cannot disagree with it.
/// @dev That makes this file the tripwire if `MAX_FEE_SHARE_BPS` or `PROTOCOL_SHARE_BPS` ever moves.
contract AceRateDensityRailTest is WarpClock {
    Ace internal ace;
    PositionManager internal pm;
    AceReader internal read;
    MockERC20 internal usdc;
    MockStakeVault internal vault;
    MockPersistenceRecord internal record;

    address internal constant BORROWER = address(0xB0110);
    address internal constant KEEPER = address(0x9EE9E2);
    address internal lender;

    uint256 internal constant CEILING_BPS = 2272; // the last rate a single-tenor market may carry
    uint256 internal constant OVER_BPS = 2273; // one step past it, refused by the fee-share rail
    uint256 internal constant OLD_CEILING_PLUS_ONE = 501; // what the deleted per-term band used to refuse

    uint64 internal constant DAY = 1 days;
    /// @dev The longest term a 500-bps market may fund off a one-day unit: 4.545 days, the fee-share rail's own edge.
    uint64 internal constant WIDE_ARM = 392_727;

    uint256 internal constant COLL = 1_000_000e18; // worth 1,000,000 quote at par, so no row here is gated on margin
    uint256 internal constant CASH = 2_000_000e6;
    uint256 internal constant DRAW = 50_000e6;

    OpenBounds internal OFF = OpenBounds(0, 0, 0);
    uint256 internal t0;

    function setUp() public {
        _warpTo(1_000_000);
        t0 = _now();
        usdc = new MockERC20("USD Coin", "USDC", 6);
        vault = new MockStakeVault(42);
        record = new MockPersistenceRecord(address(usdc), address(vault));
        lender = AceFixtures.LENDER;

        AceFixtures.Deployment memory d = AceFixtures.deploy(_params(7 days, 7 days, 40));
        (ace, pm, read) = (d.ace, d.positionManager, d.read);
        usdc.mint(BORROWER, CASH);
    }

    /* ============================== fixture ============================== */

    /// @dev One market shape, with only the three fields every row here varies spelled out.
    function _params(uint64 minTenor, uint64 maxTenor, uint256 baseBps) internal view returns (MarketParams memory p) {
        p = AceFixtures.marketParams(address(usdc), address(vault));
        p.record = address(record);
        p.baseBps = baseBps;
        p.minTenor = minTenor;
        p.maxTenor = maxTenor;
    }

    function _create(uint64 minTenor, uint64 maxTenor, uint256 baseBps) internal returns (bytes32) {
        return ace.createMarket(_params(minTenor, maxTenor, baseBps));
    }

    function _fund(bytes32 mid, uint256 amount) internal {
        usdc.mint(lender, amount);
        vm.startPrank(lender);
        usdc.approve(address(ace), amount);
        ace.deposit(mid, amount);
        vm.stopPrank();
    }

    function _open(bytes32 mid, uint256 principal, uint64 tenor) internal returns (uint256 loanId) {
        vault.mint(BORROWER, COLL);
        vm.startPrank(BORROWER);
        vault.approve(address(pm), COLL);
        usdc.approve(address(ace), type(uint256).max);
        loanId = ace.open(mid, COLL, principal, tenor, BORROWER, OFF);
        vm.stopPrank();
    }

    /// @notice The face a home roll writes, from the decision record's own closed form rather than from `src`.
    /// @notice `P = ceil(owed * D / (D - N))`, `N = baseBps*tenor*11000`, `D = 1e8*minTenor`, with no refund at expiry.
    /// @param face The retiring loan's debt.
    /// @param baseBps The market's rate.
    /// @param tenor The armed term.
    /// @param minTenor The market's term unit.
    /// @return The successor's face.
    function _rolledFace(uint256 face, uint256 baseBps, uint64 tenor, uint64 minTenor) internal pure returns (uint256) {
        uint256 d = 10000 * 10000 * uint256(minTenor);
        uint256 den = d - baseBps * uint256(tenor) * 11000;
        return (face * d + den - 1) / den;
    }

    /// @dev Three armed home rolls, each taken at the retiring loan's own expiry so no early-exit refund muddies the face.
    function _rollThrice(uint256 loanId, uint256 baseBps, uint64 tenor, uint64 minTenor, uint256 wantPerRollBps) internal returns (uint256) {
        for (uint256 i = 0; i < 3; i++) {
            uint256 before = read.debtOf(loanId);
            _warpTo(uint256(read.loan(loanId).expiry));
            vm.prank(KEEPER);
            loanId = ace.refinanceByPolicy(loanId);
            assertEq(read.debtOf(loanId), _rolledFace(before, baseBps, tenor, minTenor), "the successor carries the closed form's face");
            assertEq(read.debtOf(loanId) * 10000 / before, wantPerRollBps, "and that face is the measured multiple of the one it retired");
        }
        return loanId;
    }

    /* ============================== the premise the rows below rest on ============================== */

    /// @notice WHERE THE SURVIVING RAIL ACTUALLY LANDS, proved in the pure library that no genesis band gates.
    /// @notice GREEN ON BOTH TREES BY CONSTRUCTION, and that is its job: it fixes the numbers before the rail moves.
    /// @dev Every literal the market-level rows assert is derived here first, so a wrong one fails in one place.
    /// @dev The fee is checked against NATIVE arithmetic, which is an independent path from `FullMath`'s 512-bit one.
    function test_Premise_TheFeeShareRailLandsOn2272AndPricesItToTheWei() public pure {
        assertTrue(LoanMath.feeFundable(2272, 7 days, 7 days), "2272 clears the fee-share rail on a flat market");
        assertTrue(!LoanMath.feeFundable(2273, 7 days, 7 days), "2273 does not");
        assertTrue(LoanMath.feeFundable(2272, 1, 1), "the same two numbers at a one-second term unit");
        assertTrue(!LoanMath.feeFundable(2273, 1, 1), "because the tenor cancels wherever minTenor equals maxTenor");

        assertEq(LoanMath.originationFee(100_000e6, 365 days, 2272, 365 days), 24_992e6, "24.992 percent of face, exact at this draw");
        assertEq(LoanMath.originationFee(100_000e6, 365 days, 2272, 365 days), (100_000e6 * 24_992_000) / 100_000_000, "and native arithmetic agrees");
        assertEq(LoanMath.principalForOwed(DRAW, DAY, 2272, DAY), 66_659_556_314, "a roll writes 1.3331911x of the face it retires");
        assertEq(_rolledFace(DRAW, 2272, DAY, DAY), 66_659_556_314, "and this file's own closed form writes the same number");
    }

    /// @notice THE SECOND PREMISE: the annualization `AceLens.rateBps` owes, hand-computed before the view exists.
    /// @notice It also proves the markets those rows read are ones genesis takes TODAY, so only the wiring is owed.
    /// @dev `lender = baseBps * 365 days / minTenor`, `allIn = baseBps * 11000 * 365 days / (10000 * minTenor)`.
    /// @dev `worstRollFaceMulWad = 1e18 * D / (D - baseBps*maxTenor*11000)`, `D = 1e8 * minTenor`; flat markets here.
    function test_Premise_TheAnnualizedRateIsTheSameNumberAtEveryTermUnit() public {
        uint64 floor = Constants.MIN_TENOR_FLOOR;
        assertEq(ace.idToMarketParams(_create(floor, floor, 500)).minTenor, floor, "#380's repro, at the tenor floor, is creatable today");
        assertEq(ace.idToMarketParams(_create(730 days, 730 days, 1)).baseBps, 1, "and so is the market under the view's resolution");
        assertEq(ace.idToMarketParams(_create(14 days, 14 days, 80)).baseBps, 80, "the fortnightly twin of the shipped rate");
        assertEq(ace.idToMarketParams(_create(28 days, 28 days, 160)).baseBps, 160, "and the four-weekly one");

        assertEq(500 * uint256(365 days) / floor, 1_576_800_000, "500 bps per MIN_TENOR_FLOOR is 1.5768 billion bps a year");
        assertEq(500 * 11000 * uint256(365 days) / (10000 * uint256(floor)), 1_734_480_000, "17 million percent all-in");
        assertEq(40 * uint256(365 days) / uint256(7 days), 2085, "the shipped market's lender leg");
        assertEq(80 * uint256(365 days) / uint256(14 days), 2085, "its fortnightly twin returns the same number");
        assertEq(160 * uint256(365 days) / uint256(28 days), 2085, "and so does its four-weekly one");
        assertEq(40 * 11000 * uint256(365 days) / (10000 * uint256(7 days)), 2294, "2294 is the ALL-IN figure, not the lender's");
        assertEq(1 * uint256(365 days) / uint256(365 days), 1, "one bps a year is the smallest rate the view can state");
        assertEq(1 * uint256(365 days) / uint256(730 days), 0, "and half a bps truncates to zero rather than reverting");

        assertEq(uint256(1e18) * 1e8 / (1e8 - 500 * 11000), 1_058_201_058_201_058_201, "the MIN_TENOR_FLOOR market rolls its face 1.0582x");
        assertEq(uint256(1e18) * 1e8 / (1e8 - 2272 * 11000) / 1e14, 13331, "the ceiling rolls it 1.3331x, the most the hub can write");
        assertEq(uint256(1e18) * 1e8 / (1e8 - 40 * 11000) / 1e14, 10044, "the shipped market, 1.0044x per weekly roll");
        assertEq(uint256(1e18) * 1e8 / (1e8 - 160 * 11000) / 1e14, 10179, "and 1.0179x per four-weekly roll at the SAME annual rate");
    }

    /* ============================== the ceiling, exactly ============================== */

    /// @notice A ONE-YEAR SINGLE-TENOR MARKET AT 2272: the most expensive credit the hub can ever issue on one term.
    /// @notice The fee is a QUARTER of the face and a THIRD of the cash, and those are two different numbers.
    /// @dev The share is `2272 * 11000 / 1e8`, exact to the wei at this draw, so nothing here rounds.
    function test_TheFeeShareCeilingIsCreatableAtAOneYearTermUnit() public {
        bytes32 mid = _create(365 days, 365 days, CEILING_BPS);
        assertEq(ace.idToMarketParams(mid).baseBps, CEILING_BPS, "genesis takes 2272 at a one-year term unit");
        _fund(mid, CASH);

        Borrower.Quote memory q = ace.previewOpen(mid, COLL, 100_000e6, 365 days, BORROWER, OFF);
        assertEq(q.fee, 24_992e6, "the all-in fee is 24.992 percent of face, just inside the quarter");
        assertEq(q.payout, 75_008e6, "so the borrower takes 75.008 percent of what they owe");
        assertEq(q.fee * 10000 / q.payout, 3331, "and 33.31 percent is the cost on the cash they actually receive");
    }

    /// @notice ONE STEP PAST IT THE REFUSAL IS THE FEE RAIL'S, BY NAME, and the name is the whole point of this row.
    /// @dev It reds on today's tree with "base bps out of band": the per-term band still shadows the rail here.
    function test_OneStepPastTheCeilingIsRefusedByTheFeeRail() public {
        MarketParams memory p = _params(365 days, 365 days, OVER_BPS); // hoisted: the builder reads decimals
        vm.expectRevert(bytes("fee bps too high"));
        ace.createMarket(p);
    }

    /// @notice THE BOUNDARY IS NOT THE FIXTURE'S: the tenor cancels at `minTenor == maxTenor`, so 2272/2273 holds everywhere.
    /// @dev Three term units three orders of magnitude apart, each admitting 2272 and refusing 2273.
    function test_TheCeilingSitsAtTheSameTwoNumbersAtEveryTermUnit() public {
        uint64[3] memory units = [Constants.MIN_TENOR_FLOOR, uint64(7 days), uint64(type(uint40).max)]; // the floor is the shortest unit genesis admits
        for (uint256 i = 0; i < units.length; i++) {
            bytes32 mid = _create(units[i], units[i], CEILING_BPS);
            assertEq(ace.idToMarketParams(mid).minTenor, units[i], "2272 admits at this unit");
            MarketParams memory over = _params(units[i], units[i], OVER_BPS); // hoisted: the builder reads decimals
            vm.expectRevert(bytes("fee bps too high"));
            ace.createMarket(over);
        }
    }

    /// @notice THE MITIGATION ITSELF: the derived upper leg, whose only job is to keep an absurd rate NAMED.
    /// @notice It decides nothing a market can reach -- `feeFundable` binds at 2272, well under it -- so only these two rows see it.
    /// @notice WITHOUT IT BOTH LEGS STILL REFUSE, one under a different name and one as an arithmetic panic. That is the point.
    /// @dev At 2501 the share rail would refuse too, saying `fee bps too high`; this leg gets there first and says what is wrong.
    /// @dev At `type(uint256).max` the share rail cannot even be evaluated: `10000 * baseBps` panics before the comparison.
    /// @dev A panic reports no reason at all, so a caller learns nothing about which field they got wrong.
    function test_TheDerivedUpperLegKeepsAnAbsurdRateNamedRatherThanPanicking() public {
        MarketParams memory justOver = _params(7 days, 7 days, 2501); // hoisted: the builder reads decimals
        vm.expectRevert(bytes("base bps out of band"));
        ace.createMarket(justOver);

        MarketParams memory absurd = _params(7 days, 7 days, type(uint256).max);
        vm.expectRevert(bytes("base bps out of band"));
        ace.createMarket(absurd);
    }

    /* ============================== the floor stays, the band goes ============================== */

    /// @notice THE PAIR THAT PINS THE DELETE: zero is still refused, and 501 is now an ordinary rate.
    /// @dev Zero is refused deliberately: a market with no origination premium pays its lenders nothing.
    /// @dev 501 was the old band's first refusal; it reds today for exactly that reason.
    function test_TheFloorBitesAndTheOldPerTermCeilingDoesNot() public {
        MarketParams memory zero = _params(7 days, 7 days, 0); // hoisted: the builder reads decimals
        vm.expectRevert(bytes("base bps out of band"));
        ace.createMarket(zero);

        bytes32 mid = _create(7 days, 7 days, OLD_CEILING_PLUS_ONE);
        assertEq(ace.idToMarketParams(mid).baseBps, OLD_CEILING_PLUS_ONE, "501 is a rate like any other now");
    }

    /* ============================== the overflow corners, re-derived ============================== */

    /// @notice The widened products fit at the corners of the NEW envelope, whose rate ceiling is 2272 and not 500.
    /// @notice The extreme market is BUILT rather than reasoned about, so the arithmetic runs where the rail actually lands.
    /// @dev The two `assertLt`s are re-derivations and pass on either tree; the CREATION at 2272 is what reds today.
    function test_TheWidenedProductsFitAtTheNewEnvelopesCorners() public {
        assertLt(2272 * uint256(type(uint64).max) * 11000, type(uint256).max, "the fee numerator's worst case");
        assertLt(2272 * uint256(type(uint40).max), 1 << 128, "and the widest density a created market can carry");

        uint64 unit = uint64(type(uint40).max);
        bytes32 mid = _create(unit, unit, CEILING_BPS);
        assertEq(ace.idToMarketParams(mid).baseBps, CEILING_BPS, "PREMISE: the corner is a market someone can really create");

        uint256 corner = LoanMath.originationFee(type(uint128).max, unit, CEILING_BPS, unit);
        assertLe(corner, type(uint128).max, "the largest draw the cash cap admits still funds its own fee");
        assertEq(corner, (uint256(type(uint128).max) * 24_992_000 + 99_999_999) / 100_000_000, "and the fee is the share, ceiled once");
    }

    /* ============================== the roll, which is what actually changes ============================== */

    /// @notice THE CONTROL, AND IT IS GREEN TODAY: 1.3333x per roll is ALREADY reachable, on a wide-range market.
    /// @notice A 500-bps market with a one-day unit funds a 4.545-day term, and an armed policy rolls at that face.
    /// @notice So the delete does not create the compounding. It changes the CADENCE, which the next row measures.
    /// @dev The home roll carries no fee ceiling by design, so `AutoPolicy.maxFeeBps` never binds on this path.
    function test_TheCeilingFaceMultipleIsAlreadyReachableOnAWideRangeMarket() public {
        bytes32 mid = _create(DAY, WIDE_ARM, 500);
        _fund(mid, CASH);
        uint256 loanId = _open(mid, DRAW, WIDE_ARM);
        vm.prank(BORROWER);
        ace.setAutoRefinance(loanId, WIDE_ARM, 0, 0);

        loanId = _rollThrice(loanId, 500, WIDE_ARM, DAY, 13333);

        assertEq(read.debtOf(loanId) * 10000 / DRAW, 23703, "2.3703x over three rolls");
        assertEq(_now() - t0, 3 * uint256(WIDE_ARM), "BUT IT COST 13.6 DAYS: the term multiple is the price of the multiple");
    }

    /// @notice NEWLY REACHABLE: the same 1.333x face, on a SINGLE-TENOR market, once per term unit instead of once per 4.545.
    /// @notice Three rolls in three days where the control needed thirteen, and no per-roll consent is asked on the home leg.
    /// @dev This is #644's subject. If the face multiple is not what the closed form says, the assertion below says so loudly.
    function test_ThreeHomeRollsAtTheCeilingCompoundTheFaceEveryTermUnit() public {
        bytes32 mid = _create(DAY, DAY, CEILING_BPS);
        _fund(mid, CASH);
        uint256 loanId = _open(mid, DRAW, DAY);
        vm.prank(BORROWER);
        ace.setAutoRefinance(loanId, DAY, 0, 0);

        loanId = _rollThrice(loanId, CEILING_BPS, DAY, DAY, 13331);

        assertEq(read.debtOf(loanId) * 10000 / DRAW, 23696, "2.3696x over three rolls, against 1.0 of collateral that never moved");
        assertEq(_now() - t0, 3 * uint256(DAY), "AND IT COST THREE DAYS: the cadence is what the delete moves");
    }

    /// @notice THE BORROWER IS NOT ASKED, because a fee ceiling on the home leg would make any refusal terminal at expiry.
    /// @dev A policy armed with the tightest possible ceiling still rolls at 1.333x, so `maxFeeBps` is decoration here.
    /// @dev It binds only on a ROUTED destination, which is the seam this row exists to keep honest.
    /// @dev The buffer is 1 bps because a nonzero fee ceiling is venue consent, and consent with no risk distance is refused.
    function test_TheHomeRollIgnoresTheBorrowersOwnFeeCeiling() public {
        bytes32 mid = _create(DAY, DAY, CEILING_BPS);
        _fund(mid, CASH);
        uint256 loanId = _open(mid, DRAW, DAY);
        vm.prank(BORROWER);
        ace.setAutoRefinance(loanId, DAY, 1, 1); // one bps of ceiling: the tightest the field can express

        uint256 before = read.debtOf(loanId);
        _warpTo(uint256(read.loan(loanId).expiry));
        vm.prank(KEEPER);
        uint256 newId = ace.refinanceByPolicy(loanId);

        assertEq(read.debtOf(newId), _rolledFace(before, CEILING_BPS, DAY, DAY), "a 1-bps ceiling did not stop a 2499-bps roll");
    }
}
