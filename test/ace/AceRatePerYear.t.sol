// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.36;

import {WarpClock} from "../utils/WarpClock.sol";
import {Ace} from "../../src/ace/hub/Ace.sol";
import {Borrower} from "../../src/ace/hub/Borrower.sol";
import {LoanMath} from "../../src/ace/hub/libraries/LoanMath.sol";
import {MarketParams, MigrateArgs, OpenBounds} from "../../src/ace/hub/Types.sol";
import {AceLens} from "../../src/ace/lens/AceLens.sol";
import {PositionManager} from "../../src/ace/positions/PositionManager.sol";
import {MockERC20} from "../mocks/MockERC20.sol";
import {MockPersistenceRecord} from "../mocks/MockPersistenceRecord.sol";
import {RatePeriodProbe} from "../mocks/MockRatePeriodHubs.sol";
import {MockStakeVault} from "../mocks/MockStakeVault.sol";
import {AceFixtures} from "../utils/AceFixtures.sol";
import {AceReader} from "../utils/AceReader.sol";

/// @title AceRatePerYear
/// @notice The origination rate is bps per 365 days: `fee = ceil(P * r * tenor * 11000 / (1e8 * 365 days))`, and `minTenor` plays no part.
/// @notice The fee-share rail binds the rate at `maxTenor` alone: `r <= 2500 * 1e4 * 365 days / (maxTenor * 11000)`, exact for integers.
/// @dev Every figure is hand-computed from that closed form and spelled as a literal, never read off `src`.
/// @dev The field was renamed from `baseBps`; only its unit is the subject here.
/// @dev `RATE_PERIOD()` is probed by a raw staticcall, so the file compiles against a hub that has no such getter.
contract AceRatePerYearTest is WarpClock {
    Ace internal ace;
    PositionManager internal pm;
    AceReader internal read;
    MockERC20 internal usdc;
    MockStakeVault internal vault;
    MockPersistenceRecord internal record;

    address internal constant BORROWER = address(0xB0110);
    address internal constant SECOND = address(0xB0220);
    address internal lender;

    uint256 internal constant YEAR = 31_536_000; // 365 days, the rate's period
    uint256 internal constant COLL = 1_000_000e18; // worth 1,000,000 quote at par, so no row here is gated on margin
    uint256 internal constant CASH = 10_000_000e6;
    uint256 internal constant DRAW = 1_000e6; // 1e9 atoms
    uint256 internal constant RATE = 73; // a fifth of 365, so a whole number of days prices to the atom
    uint256 internal constant CEIL_30D = 27_651; // floor(2500 * 1e4 * YEAR / (30 days * 11000)), the last rate a 30-day maxTenor takes
    uint256 internal constant CEIL_1Y = 2272; // the same bound at a one-year maxTenor
    uint256 internal constant CEIL_10S = 7_167_272_727; // the same bound at the tenor floor, ten seconds
    uint64 internal constant LONGEST_AT_ONE = 71_672_727_272; // floor(2500 * 1e4 * YEAR / 11000): the longest maxTenor a rate of 1 takes
    uint256 internal constant SHARE_YEAR = 788_400_000_000_000; // 2500 * 1e4 * YEAR: the share rail is `r * maxTenor * 11000 <= SHARE_YEAR`

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
        usdc.mint(SECOND, CASH);
    }

    /* ============================== fixture ============================== */

    function _params(uint64 minTenor, uint64 maxTenor, uint256 rate) internal view returns (MarketParams memory p) {
        p = AceFixtures.marketParams(address(usdc), address(vault));
        p.record = address(record);
        p.lenderAprBps = rate;
        p.minTenor = minTenor;
        p.maxTenor = maxTenor;
    }

    function _create(uint64 minTenor, uint64 maxTenor, uint256 rate) internal returns (bytes32) {
        return ace.createMarket(_params(minTenor, maxTenor, rate));
    }

    /// @dev A market of this shape refused at genesis with `reason`.
    function _refused(uint64 minTenor, uint64 maxTenor, uint256 rate, string memory reason) internal {
        MarketParams memory p = _params(minTenor, maxTenor, rate); // hoisted: the builder reads decimals
        vm.expectRevert(bytes(reason));
        ace.createMarket(p);
    }

    function _fund(bytes32 mid, uint256 amount) internal {
        usdc.mint(lender, amount);
        vm.startPrank(lender);
        usdc.approve(address(ace), amount);
        ace.deposit(mid, amount);
        vm.stopPrank();
    }

    function _quote(bytes32 mid, uint256 principal, uint64 tenor) internal view returns (Borrower.Quote memory) {
        return ace.previewOpen(mid, COLL, principal, tenor, BORROWER, OFF);
    }

    function _openAs(address who, bytes32 mid, uint256 principal, uint64 tenor) internal returns (uint256 loanId) {
        vault.mint(who, COLL);
        vm.startPrank(who);
        vault.approve(address(pm), COLL);
        usdc.approve(address(ace), type(uint256).max);
        loanId = ace.open(mid, COLL, principal, tenor, who, OFF);
        vm.stopPrank();
    }

    /* ============================== the period, on chain ============================== */

    /// @notice THE HUB NAMES ITS RATE PERIOD: a pure `RATE_PERIOD()` answering one 365-day year, the word every product probes.
    function test_RatePeriodGetterAnswersAYear() public view {
        (bool ok, uint256 period) = RatePeriodProbe.ask(address(ace));
        assertTrue(ok, "the hub answers RATE_PERIOD() with one word");
        assertEq(period, YEAR, "and the word is 365 days, leap years ignored");
    }

    /* ============================== the fee ============================== */

    /// @notice THE FEE IGNORES `minTenor`: three markets differing only in it charge one fee for one draw over one term.
    /// @dev `ceil(1e9 * 73 * 7 days * 11000 / (1e8 * 365 days)) = 154,000` exactly, 0.0154 percent of face.
    function test_FeeIgnoresMinTenor() public {
        bytes32 weekly = _create(7 days, 7 days, RATE);
        bytes32 daily = _create(1 days, 7 days, RATE);
        _fund(weekly, CASH);
        _fund(daily, CASH);
        assertEq(_quote(weekly, DRAW, 7 days).fee, 154_000, "a week at 73 bps a year on 1,000 USDC");
        assertEq(_quote(daily, DRAW, 7 days).fee, 154_000, "the same week on a market whose shortest term is a day");

        bytes32 floor = _create(10, 7 days, RATE);
        _fund(floor, CASH);
        assertEq(_quote(floor, DRAW, 7 days).fee, 154_000, "and on one whose shortest term is the ten-second floor");
    }

    /// @notice THE FEE AT THE ATOM: one ceil on the fused product, never a per-second pre-truncation.
    /// @notice A 10-minute loan of 1e6 at 500 a year costs 2 atoms; a 10-second loan of 2 atoms at 1 a year costs 1.
    /// @dev `1e6 * 500 * 600 * 11000 / 3.1536e15 = 1.046`, so 2; `2 * 1 * 10 * 11000 / 3.1536e15` is a sliver, so 1.
    /// @dev The single atom splits as nothing to the protocol, one to the lender at once, and nothing to escrow.
    function test_FeeClosedFormAtTheAtom() public {
        MarketParams memory p = _params(600, 600, 500);
        p.minPrincipal = 1e6;
        bytes32 tenMinutes = ace.createMarket(p);
        _fund(tenMinutes, CASH);
        Borrower.Quote memory q = _quote(tenMinutes, 1e6, 600);
        assertEq(q.fee, 2, "ten minutes of 1e6 at 500 bps a year is two atoms");
        assertEq(q.payout, 999_998, "paid out of the draw");

        p = _params(10, 10, 1);
        p.minPrincipal = 2;
        bytes32 atom = ace.createMarket(p);
        _fund(atom, CASH);
        q = _quote(atom, 2, 10);
        assertEq(q.fee, 1, "ten seconds of two atoms at the floor rate is one atom");
        assertEq(q.protocolFee, 0, "the protocol's floored eleventh of it is nothing");
        assertEq(LoanMath.tickCut(1), 1, "so the lender takes the atom at the draw");
        assertEq(LoanMath.escrowCut(1), 0, "and none of it waits in escrow");
        uint256 loanId = _openAs(BORROWER, atom, 2, 10);
        assertEq(read.feeEscrowOf(loanId), 0, "the opened loan escrows nothing");
    }

    /// @notice A TEN-MINUTE MARKET AT FIVE PERCENT A YEAR IS CREATABLE with a 30-day longest term; per `minTenor` it was 500 per ten minutes.
    /// @dev `maxTenor` is pinned to 30 days: 500 per ten minutes passes the old rail at a ten-minute `maxTenor`, so a shorter one proves nothing.
    /// @dev Ten minutes of 10e6 is `ceil(10.46) = 11` atoms; the whole 30 days is `ceil(45,205.48) = 45,206`.
    function test_TenMinuteMarketAtFivePercentIsCreatable() public {
        bytes32 mid = _create(600, 30 days, 500);
        assertEq(ace.idToMarketParams(mid).maxTenor, 30 days, "genesis takes 500 a year on a 10-minute to 30-day market");
        _fund(mid, CASH);
        assertEq(_quote(mid, 10e6, 600).fee, 11, "ten minutes of the floor ticket");
        assertEq(_quote(mid, 10e6, 30 days).fee, 45_206, "and its longest term");
    }

    /// @notice AN EXTENSION CHARGES THE TIME IT ADDS AT THE ANNUAL RATE: six days added on 1,000 USDC at 73 a year is 132,000 atoms.
    /// @dev Opened for a week, extended a day before expiry: the new expiry is now plus the tenor, so six days are added.
    function test_ExtensionChargesTimeAddedAtTheAnnualRate() public {
        bytes32 mid = _create(7 days, 7 days, RATE);
        _fund(mid, CASH);
        uint256 loanId = _openAs(BORROWER, mid, DRAW, 7 days);
        AceFixtures.installYesPolicy(ace, lender);
        _warpTo(t0 + 6 days);
        uint256 wallet = usdc.balanceOf(BORROWER);
        vm.prank(BORROWER);
        uint256 fee = ace.extend(loanId, 0, "");
        assertEq(fee, 132_000, "six days of 1e9 at 73 bps a year");
        assertEq(wallet - usdc.balanceOf(BORROWER), 132_000, "paid in cash");
        assertEq(read.debtOf(loanId), DRAW, "and the face did not move");
    }

    /// @notice A REFINANCE PRICES THE SUCCESSOR ON THE DESTINATION'S RATE AND TERM, never its `minTenor`: two destinations, one fee.
    /// @dev Two loans opened together and refinanced together, so their debts and refunds match; only the destinations' shortest terms differ.
    function test_RefinanceFeeIgnoresDestinationMinTenor() public {
        bytes32 src = _create(7 days, 7 days, RATE);
        _fund(src, CASH);
        MarketParams memory p = _params(7 days, 7 days, RATE);
        p.record = address(new MockPersistenceRecord(address(usdc), address(vault))); // a twin of the source, distinct by its record
        bytes32 weekly = ace.createMarket(p);
        bytes32 daily = _create(1 days, 7 days, RATE);
        _fund(weekly, CASH);
        _fund(daily, CASH);
        uint256 a = _openAs(BORROWER, src, 500e6, 7 days);
        uint256 b = _openAs(SECOND, src, 500e6, 7 days);
        _warpTo(t0 + 3 days);

        uint256 want = DRAW - 154_000 + read.earlyExitRefund(a) - read.debtOf(a);
        assertEq(read.earlyExitRefund(b), read.earlyExitRefund(a), "PREMISE: the two loans carry one refund");
        uint256 outA = _refi(BORROWER, a, weekly);
        uint256 outB = _refi(SECOND, b, daily);
        assertEq(outA, want, "into the weekly market: the new principal less 154,000, plus the refund, less the debt");
        assertEq(outB, want, "into the daily one: the same fee, because its shortest term never priced it");
    }

    /// @dev Refinance `id` into `dst` for DRAW over a week, as its holder; returns the cash the holder received.
    function _refi(address who, uint256 id, bytes32 dst) internal returns (uint256 out) {
        MigrateArgs memory m = MigrateArgs(id, dst, DRAW, 7 days, OFF, 0, address(0));
        uint256 wallet = usdc.balanceOf(who);
        vm.prank(who);
        ace.refinanceTo(m);
        out = usdc.balanceOf(who) - wallet;
    }

    /* ============================== the rails ============================== */

    /// @notice THE CEILING DEPENDS ON `maxTenor` ALONE: 27,651 admits and 27,652 refuses at 30 days, whatever the shortest term.
    /// @notice At a one-year `maxTenor` the same edge is 2,272 and 2,273, so one-year credit stays at 24.99 percent of face.
    function test_FeeShareCeilingDependsOnMaxTenorOnly() public {
        uint64[3] memory shortest = [uint64(10), uint64(1 days), uint64(30 days)];
        for (uint256 i; i < shortest.length; ++i) {
            bytes32 mid = _create(shortest[i], 30 days, CEIL_30D);
            assertEq(ace.idToMarketParams(mid).lenderAprBps, CEIL_30D, "27,651 a year admits at a 30-day maxTenor");
            _refused(shortest[i], 30 days, CEIL_30D + 1, "fee bps too high");
        }
        uint64[2] memory yearly = [uint64(1 days), uint64(365 days)];
        for (uint256 i; i < yearly.length; ++i) {
            bytes32 mid = _create(yearly[i], 365 days, CEIL_1Y);
            assertEq(ace.idToMarketParams(mid).lenderAprBps, CEIL_1Y, "2,272 a year admits at a one-year maxTenor");
            _refused(yearly[i], 365 days, CEIL_1Y + 1, "fee bps too high");
        }
    }

    /// @notice THE CORNER AT THE TENOR FLOOR: a ten-second market takes 7,167,272,727 bps a year and refuses one more.
    /// @dev Its whole fee is `ceil(2,499,999.99999) = 2,500,000` atoms on the 10e6 floor ticket, a quarter to the atom.
    function test_FeeShareBoundAtTheTenorFloor() public {
        bytes32 mid = _create(10, 10, CEIL_10S);
        assertEq(ace.idToMarketParams(mid).lenderAprBps, CEIL_10S, "the bound at ten seconds admits");
        _fund(mid, CASH);
        assertEq(_quote(mid, 10e6, 10).fee, 2_500_000, "and its ticket pays a quarter of face");
        _refused(10, 10, CEIL_10S + 1, "fee bps too high");
    }

    /// @notice THE LONGEST TERM AT THE FLOOR RATE: 1 bp a year funds a maxTenor up to about 2,272.7 years, and `type(uint40).max` never.
    function test_LongestMaxTenorAtTheFloorRate() public {
        bytes32 mid = _create(1 days, LONGEST_AT_ONE, 1);
        assertEq(ace.idToMarketParams(mid).maxTenor, LONGEST_AT_ONE, "the longest maxTenor a rate of one takes");
        _refused(1 days, LONGEST_AT_ONE + 1, 1, "fee bps too high");
        _refused(1 days, uint64(type(uint40).max), 1, "fee bps too high");
    }

    /// @notice AN ABSURD RATE IS REFUSED BY NAME: the division form never multiplies the rate, so no rate reaches a Panic.
    function test_AbsurdRateRefusedByName() public {
        _refused(7 days, 7 days, type(uint256).max, "fee bps too high");
        _refused(10, 10, type(uint256).max, "fee bps too high");
        _refused(1 days, 365 days, 1 << 255, "fee bps too high");
    }

    /// @notice A ZERO TENOR FUNDS NO FEE: the rail answers false rather than dividing by zero, at any rate, the floor's included.
    /// @dev Killed: dropping `tenor == 0`'s early return, which Panics on the division instead of answering.
    function test_FeeFundableAtAZeroTenorIsFalse() public pure {
        assertFalse(LoanMath.feeFundable(1, 0), "the floor rate at a zero tenor is not fundable");
        assertFalse(LoanMath.feeFundable(0, 0), "nor is a zero rate");
        assertFalse(LoanMath.feeFundable(type(uint256).max, 0), "nor the widest one");
    }

    /// @notice THE RAIL IS EXACT AT EVERY TENOR: it admits its own edge rate and refuses one bp more, and at any rate it is the product form.
    /// @dev The edge is found by division and then CHECKED in product form, `r * T * 11000 <= SHARE_YEAR`, so the oracle is not the code's spelling.
    /// @dev Killed: `<` for `<=` and an edge one bp wide, at every tenor rather than at the four the literal rows name.
    function testFuzz_FeeFundableIsExactAtEveryTenor(uint64 tenorSeed, uint256 rateSeed) public pure {
        uint64 t = uint64(bound(tenorSeed, 1, type(uint64).max));
        uint256 edge = SHARE_YEAR / (uint256(t) * 11_000);
        assertLe(edge * t * 11_000, SHARE_YEAR, "premise: the edge rate funds this tenor in product form");
        assertGt((edge + 1) * t * 11_000, SHARE_YEAR, "premise: and one bp more does not");
        assertTrue(LoanMath.feeFundable(edge, t), "the rail admits its edge");
        assertFalse(LoanMath.feeFundable(edge + 1, t), "and refuses one bp past it");
        uint256 r = bound(rateSeed, 0, type(uint128).max);
        assertEq(LoanMath.feeFundable(r, t), r * t * 11_000 <= SHARE_YEAR, "at any rate the rail is the product form");
    }

    /// @notice THE HUB QUOTES THE CLOSED FORM AT ANY SHAPE: a fuzzed rate, shortest term, term and draw, priced by native arithmetic.
    /// @dev Killed: the fee priced per `minTenor` at any shortest term under a year, and a floored fee wherever the quotient is not whole.
    function testFuzz_TheHubQuotesTheClosedFormAtAnyShortestTerm(uint256 rateSeed, uint64 minSeed, uint64 tenorSeed, uint256 drawSeed) public {
        uint256 r = bound(rateSeed, 1, CEIL_30D);
        uint64 minTenor = uint64(bound(minSeed, 10, 30 days));
        uint64 tenor = uint64(bound(tenorSeed, minTenor, 30 days));
        uint256 draw = bound(drawSeed, 10e6, DRAW);
        bytes32 mid = _create(minTenor, 30 days, r);
        _fund(mid, CASH);
        uint256 d = 10_000 * 10_000 * YEAR;
        assertEq(_quote(mid, draw, tenor).fee, (draw * r * tenor * 11_000 + d - 1) / d, "ceil(P * r * tenor * 11000 / (1e8 * 365 days))");
    }

    /// @notice A PRICED DRAW ALWAYS PAYS THE LENDER AT ONCE: with the draw, the term and the rate each at least one, fee and tick cut are at least an atom.
    /// @dev The executable form of the prover's `theFeeAndTickCutAreNeverZero`, whose run is owed.
    /// @dev Killed: a floored fee, which prices the smallest products at zero, and phi = 1, which escrows the whole lender cut.
    function testFuzz_TheFeeAndTickCutAreNeverZero(uint256 pSeed, uint64 tenorSeed, uint256 rateSeed) public pure {
        uint256 principal = bound(pSeed, 1, type(uint128).max);
        uint64 tenor = uint64(bound(tenorSeed, 1, type(uint64).max));
        uint256 r = bound(rateSeed, 1, type(uint64).max);
        uint256 fee = LoanMath.originationFee(principal, tenor, r);
        assertGe(fee, 1, "a priced draw paid no fee");
        assertGe(LoanMath.tickCut(fee), 1, "the lender's immediate share rounded to zero");
    }

    /// @notice ZERO IS REFUSED BY THE FLOOR'S OWN NAME, and the floor itself, 1 bp a year, admits.
    function test_ZeroRateRefused() public {
        _refused(7 days, 7 days, 0, "rate below floor");
        assertEq(ace.idToMarketParams(_create(7 days, 7 days, 1)).lenderAprBps, 1, "one bp a year is a rate");
    }

    /* ============================== the view ============================== */

    /// @notice THE LENS READS THE FIELD: the lender leg is the rate itself, and the all-in leg carries the protocol share on top.
    /// @dev `2086 * 11000 / 10000 = 2294.6`, truncated; the same rate on a 30-day market reads the same pair.
    function test_LensReadsTheField() public {
        AceLens lens = new AceLens(address(ace));
        (uint256 lenderApr, uint256 allInApr) = lens.rateBps(_create(7 days, 7 days, 2086));
        assertEq(lenderApr, 2086, "the lender's rate is the field");
        assertEq(allInApr, 2294, "and the borrower's adds the protocol share");
        (lenderApr, allInApr) = lens.rateBps(_create(30 days, 30 days, 2086));
        assertEq(lenderApr, 2086, "a 30-day market at the same rate reads the same");
        assertEq(allInApr, 2294, "on both legs");
        (lenderApr, allInApr) = lens.rateBps(keccak256("no market was ever created at this id"));
        assertEq(lenderApr + allInApr, 0, "and an unknown id reads zero");
    }
}
