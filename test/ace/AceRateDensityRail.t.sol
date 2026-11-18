// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.36;

import {WarpClock} from "../utils/WarpClock.sol";
import {Ace} from "../../src/ace/hub/Ace.sol";
import {AceLens} from "../../src/ace/lens/AceLens.sol";
import {Borrower} from "../../src/ace/hub/Borrower.sol";
import {Constants} from "../../src/ace/hub/Constants.sol";
import {LoanMath} from "../../src/ace/hub/libraries/LoanMath.sol";
import {RefinanceMath} from "../utils/RefinanceMath.sol";
import {MarketParams, OpenBounds} from "../../src/ace/hub/Types.sol";
import {PositionManager} from "../../src/ace/positions/PositionManager.sol";
import {MockERC20} from "../mocks/MockERC20.sol";
import {MockPersistenceRecord} from "../mocks/MockPersistenceRecord.sol";
import {MockStakeVault} from "../mocks/MockStakeVault.sol";
import {AceFixtures} from "../utils/AceFixtures.sol";
import {AceReader} from "../utils/AceReader.sol";

/// @title AceRateDensityRail
/// @notice What bounds the PRICE OF CREDIT once the per-term band is gone, and what that costs per extension.
/// @notice The fee-share rail is the only ceiling left, and the rate is bps a year, so it reads `maxTenor` alone.
/// @dev `feeFundable` is `b * maxTenor * 11000 <= 2500 * 1e4 * 365 days`: at a one-year `maxTenor` that is 2272 against 2273.
/// @dev So 2272 admits and 2273 refuses at a one-year `maxTenor` whatever the `minTenor`; nothing here is the 7-day fixture's.
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

    uint256 internal constant CEILING_BPS = 2272; // the last rate a one-year maxTenor may carry
    uint256 internal constant OVER_BPS = 2273; // one step past it, refused by the fee-share rail
    uint256 internal constant OLD_CEILING_PLUS_ONE = 501; // what the deleted per-term band used to refuse
    uint256 internal constant DAY_CEILING_BPS = 829_545; // the last rate a one-day maxTenor may carry
    uint256 internal constant WIDE_BPS = 182_500; // the last rate a 392,727-second maxTenor may carry

    uint64 internal constant DAY = 1 days;
    /// @dev A 4.545-day maxTenor: the term at which 182,500 bps a year meets the fee-share rail's own edge.
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
    function _params(uint64 minTenor, uint64 maxTenor, uint256 lenderAprBps) internal view returns (MarketParams memory p) {
        p = AceFixtures.marketParams(address(usdc), address(vault));
        p.record = address(record);
        p.lenderAprBps = lenderAprBps;
        p.minTenor = minTenor;
        p.maxTenor = maxTenor;
    }

    function _create(uint64 minTenor, uint64 maxTenor, uint256 lenderAprBps) internal returns (bytes32) {
        return ace.createMarket(_params(minTenor, maxTenor, lenderAprBps));
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

    /// @notice An extension's cash fee, from the decision record's own closed form rather than from `src`.
    /// @notice `ceil(face * N / D)`, `N = lenderAprBps*tenor*11000`, `D = 1e8*365 days`: the fee on the debt, paid beside it.
    /// @param face The loan's debt at the extension.
    /// @param lenderAprBps The market's rate, bps a year.
    /// @param tenor The time the extension adds.
    /// @return The extension's fee.
    function _extensionFee(uint256 face, uint256 lenderAprBps, uint64 tenor) internal pure returns (uint256) {
        uint256 d = 10000 * 10000 * uint256(365 days);
        uint256 n = lenderAprBps * uint256(tenor) * 11000;
        return (face * n + d - 1) / d;
    }

    /// @dev Three extensions, each in the last second of the loan's term, so each adds the tenor less that second; the lender consents.
    /// @dev Each pays the closed form's fee on the time added in cash and leaves the face where it was; returns what the three cost.
    function _extendThrice(uint256 loanId, uint256 lenderAprBps, uint64 tenor) internal returns (uint256 paid) {
        AceFixtures.installYesPolicy(ace, lender);
        uint256 face = read.debtOf(loanId);
        for (uint256 i = 0; i < 3; i++) {
            _warpTo(uint256(read.loan(loanId).expiry) - 1);
            uint256 wallet = usdc.balanceOf(BORROWER);
            vm.prank(BORROWER);
            ace.extend(loanId, 0, "");
            uint256 fee = wallet - usdc.balanceOf(BORROWER);
            assertEq(fee, _extensionFee(face, lenderAprBps, tenor - 1), "each extension pays the closed form's fee on the time added, in cash");
            assertEq(read.debtOf(loanId), face, "and leaves the face where it was");
            paid += fee;
        }
    }

    /* ============================== the premise the rows below rest on ============================== */

    /// @notice WHERE THE SURVIVING RAIL ACTUALLY LANDS, proved in the pure library that no genesis band gates.
    /// @notice IT CREATES NO MARKET, and that is its job: it fixes the numbers before any genesis row reads them.
    /// @dev Every literal the market-level rows assert is derived here first, so a wrong one fails in one place.
    /// @dev The fee is checked against NATIVE arithmetic, which is an independent path from `FullMath`'s 512-bit one.
    function test_Premise_TheFeeShareRailLandsOn2272AndPricesItToTheWei() public pure {
        assertTrue(LoanMath.feeFundable(2272, 365 days), "2272 clears the fee-share rail at a one-year maxTenor");
        assertTrue(!LoanMath.feeFundable(2273, 365 days), "2273 does not");
        assertTrue(LoanMath.feeFundable(DAY_CEILING_BPS, DAY), "a one-day maxTenor carries 829,545");
        assertTrue(!LoanMath.feeFundable(DAY_CEILING_BPS + 1, DAY), "and not one more: the rail reads maxTenor alone");

        assertEq(LoanMath.originationFee(100_000e6, 365 days, 2272), 24_992e6, "24.992 percent of face, exact at this draw");
        assertEq(LoanMath.originationFee(100_000e6, 365 days, 2272), (100_000e6 * 24_992_000) / 100_000_000, "and native arithmetic agrees");
        assertEq(RefinanceMath.principalForOwed(DRAW, 365 days, 2272), 66_659_556_314, "a refinance retiring DRAW at the ceiling draws 1.3331911x of it");
        assertEq(LoanMath.originationFee(DRAW, 365 days, 2272), 12_496e6, "an extension at the ceiling costs 0.24992x of the face it extends");
        assertEq(_extensionFee(DRAW, 2272, 365 days), 12_496e6, "and this file's own closed form charges the same number");
    }

    /// @notice THE SECOND PREMISE: `AceLens.rateBps` reads the field itself, bps a year, whatever the market's `minTenor`.
    /// @notice The rate is quoted per year, so the same field reads the same at a ten-second, a seven-day and a one-year shortest term.
    /// @dev `lender = lenderAprBps`, `allIn = lenderAprBps * 11000 / 10000`, floored: 2086 reads (2086, 2294), the shipped rate and its all-in.
    function test_Premise_TheLensReadsTheSameYearlyRateAtEveryTermUnit() public {
        AceLens lens = new AceLens(address(ace));
        uint64[3] memory units = [Constants.MIN_TENOR_FLOOR, uint64(7 days), uint64(365 days)];
        uint64[3] memory longest = [uint64(30 days), uint64(30 days), uint64(365 days)];
        for (uint256 i = 0; i < units.length; i++) {
            bytes32 mid = _create(units[i], longest[i], 2086);
            assertEq(ace.idToMarketParams(mid).minTenor, units[i], "premise: genesis takes the shipped rate at this minTenor");
            (uint256 lenderApr, uint256 allInApr) = lens.rateBps(mid);
            assertEq(lenderApr, 2086, "the lender's leg is the field, at every minTenor");
            assertEq(allInApr, 2294, "the all-in leg is the field with ACE's share on top, floored");
        }
        (uint256 one, uint256 oneAllIn) = lens.rateBps(_create(730 days, 730 days, 1));
        assertEq(one, 1, "one bps a year, the floor, reads as itself");
        assertEq(oneAllIn, 1, "and its all-in floors to one, never to zero");
    }

    /* ============================== the ceiling, exactly ============================== */

    /// @notice A ONE-YEAR SINGLE-TENOR MARKET AT 2272: the share rail's edge at a one-year term, a fee just inside a quarter of the face.
    /// @notice The fee is a QUARTER of the face and a THIRD of the cash, and those are two different numbers.
    /// @dev The share is `2272 * 11000 / 1e8`, exact to the wei at this draw, so nothing here rounds.
    function test_TheFeeShareCeilingIsCreatableAtAOneYearTermUnit() public {
        bytes32 mid = _create(365 days, 365 days, CEILING_BPS);
        assertEq(ace.idToMarketParams(mid).lenderAprBps, CEILING_BPS, "genesis takes 2272 at a one-year term unit");
        _fund(mid, CASH);

        Borrower.Quote memory q = ace.previewOpen(mid, COLL, 100_000e6, 365 days, BORROWER, OFF);
        assertEq(q.fee, 24_992e6, "the all-in fee is 24.992 percent of face, just inside the quarter");
        assertEq(q.payout, 75_008e6, "so the borrower takes 75.008 percent of what they owe");
        assertEq(q.fee * 10000 / q.payout, 3331, "and 33.31 percent is the cost on the cash they actually receive");
    }

    /// @notice ONE STEP PAST IT THE REFUSAL IS THE FEE RAIL'S, BY NAME, and the name is the whole point of this row.
    function test_OneStepPastTheCeilingIsRefusedByTheFeeRail() public {
        MarketParams memory p = _params(365 days, 365 days, OVER_BPS); // hoisted: the builder reads decimals
        vm.expectRevert(bytes("fee bps too high"));
        ace.createMarket(p);
    }

    /// @notice THE BOUNDARY IS NOT THE FIXTURE'S: the rail reads `maxTenor` alone, so 2272/2273 holds at a one-year one whatever the `minTenor`.
    /// @dev Three `minTenor`s five orders of magnitude apart under one 365-day `maxTenor`, each admitting 2272 and refusing 2273.
    function test_TheCeilingSitsAtTheSameTwoNumbersAtEveryTermUnit() public {
        uint64[3] memory units = [Constants.MIN_TENOR_FLOOR, uint64(7 days), uint64(365 days)]; // the floor is the shortest unit genesis admits
        for (uint256 i = 0; i < units.length; i++) {
            bytes32 mid = _create(units[i], 365 days, CEILING_BPS);
            assertEq(ace.idToMarketParams(mid).minTenor, units[i], "2272 admits at this minTenor");
            MarketParams memory over = _params(units[i], 365 days, OVER_BPS); // hoisted: the builder reads decimals
            vm.expectRevert(bytes("fee bps too high"));
            ace.createMarket(over);
        }
    }

    /// @notice AN ABSURD RATE IS REFUSED BY NAME, never as an arithmetic panic: the share rail divides a constant and never multiplies the rate.
    /// @notice 2501 bps a year is an ordinary rate at a 7-day maxTenor, and `type(uint256).max` is refused as "fee bps too high".
    /// @dev The rate band this row used to pin is deleted; the division form of `feeFundable` is what keeps the refusal named.
    /// @dev A panic reports no reason at all, so a caller would learn nothing about which field they got wrong.
    function test_TheShareRailKeepsAnAbsurdRateNamedRatherThanPanicking() public {
        bytes32 mid = _create(7 days, 7 days, 2501);
        assertEq(ace.idToMarketParams(mid).lenderAprBps, 2501, "2501 a year is an ordinary rate at a 7-day maxTenor");

        MarketParams memory absurd = _params(7 days, 7 days, type(uint256).max); // hoisted: the builder reads decimals
        vm.expectRevert(bytes("fee bps too high"));
        ace.createMarket(absurd);
    }

    /* ============================== the floor stays, the band goes ============================== */

    /// @notice THE PAIR THAT PINS THE DELETE: zero is still refused, and 501 is now an ordinary rate.
    /// @dev Zero is refused deliberately: a market with no origination premium pays its lenders nothing.
    /// @dev 501 was the old band's first refusal.
    function test_TheFloorBitesAndTheOldPerTermCeilingDoesNot() public {
        MarketParams memory zero = _params(7 days, 7 days, 0); // hoisted: the builder reads decimals
        vm.expectRevert(bytes("rate below floor"));
        ace.createMarket(zero);

        bytes32 mid = _create(7 days, 7 days, OLD_CEILING_PLUS_ONE);
        assertEq(ace.idToMarketParams(mid).lenderAprBps, OLD_CEILING_PLUS_ONE, "501 is a rate like any other now");
    }

    /* ============================== the overflow corners, re-derived ============================== */

    /// @notice The widened products fit at the envelope's corner: the share rail caps `rate * maxTenor`, never the rate alone.
    /// @notice The extreme market is BUILT rather than reasoned about, so the arithmetic runs where the rail actually lands.
    /// @dev The two `assertLt`s bound a rate of 2272 at any term; the rail caps `rate * maxTenor` near 7.17e10, far inside both.
    function test_TheWidenedProductsFitAtTheNewEnvelopesCorners() public {
        assertLt(2272 * uint256(type(uint64).max) * 11000, type(uint256).max, "2272 a year over the widest tenor the type carries fits, past the rail's cap");
        assertLt(2272 * uint256(type(uint40).max), 1 << 128, "and so does 2272 a year over the longest term genesis names");

        uint64 unit = 365 days;
        bytes32 mid = _create(unit, unit, CEILING_BPS);
        assertEq(ace.idToMarketParams(mid).lenderAprBps, CEILING_BPS, "PREMISE: the corner is a market someone can really create");

        uint256 corner = LoanMath.originationFee(type(uint128).max, unit, CEILING_BPS);
        assertLe(corner, type(uint128).max, "the largest draw the cash cap admits still funds its own fee");
        assertEq(corner, (uint256(type(uint128).max) * 24_992_000 + 99_999_999) / 100_000_000, "and the fee is the share, ceiled once");
    }

    /* ============================== the extension, paid in cash every term ============================== */

    /// @notice THE CONTROL: a quarter of the face per extension on a 4.545-day market at its own ceiling rate.
    /// @notice A 182,500-bps-a-year market funds a 4.545-day term, and the borrower extends by it in each term's last second.
    /// @notice So the charge is a quarter of the face per maxTenor at any shape. The CADENCE is what the shape moves, which the next row measures.
    /// @dev An extension charges the fee on the debt for the time it adds, in cash; the face never compounds.
    function test_TheCeilingFeeShareIsAlreadyReachableOnAWideRangeMarket() public {
        bytes32 mid = _create(DAY, WIDE_ARM, WIDE_BPS);
        _fund(mid, CASH);
        uint256 loanId = _open(mid, DRAW, WIDE_ARM);

        uint256 paid = _extendThrice(loanId, WIDE_BPS, WIDE_ARM);

        assertEq(_extensionFee(DRAW, WIDE_BPS, WIDE_ARM) * 10000 / DRAW, 2499, "a whole term costs 0.2499999x of the face");
        assertEq(paid, 3 * _extensionFee(DRAW, WIDE_BPS, WIDE_ARM - 1), "three extensions of a term less a second, on a face that never moved");
        assertEq(_now() - t0, 3 * uint256(WIDE_ARM - 1), "BUT IT TOOK 13.6 DAYS: the longest term, never a term multiple, sets the charge's cadence");
    }

    /// @notice The same quarter-of-face charge on a ONE-DAY market at its own ceiling rate, once a day instead of once per 4.545.
    /// @notice Three extensions in three days where the control needed thirteen, each on the lender's policy's yes.
    /// @dev This is #644's subject. If the fee is not what the closed form says, the assertion below says so loudly.
    function test_ThreeExtensionsAtTheCeilingChargeTheFeeShareEveryTermUnit() public {
        bytes32 mid = _create(DAY, DAY, DAY_CEILING_BPS);
        _fund(mid, CASH);
        uint256 loanId = _open(mid, DRAW, DAY);

        uint256 paid = _extendThrice(loanId, DAY_CEILING_BPS, DAY);

        assertEq(paid, 37_499_545_425, "0.74999x of the face in cash over three extensions of a day less a second, the collateral never moved");
        assertEq(_now() - t0, 3 * uint256(DAY - 1), "AND IT TOOK THREE DAYS: the cadence is what the shape moves");
    }
}
