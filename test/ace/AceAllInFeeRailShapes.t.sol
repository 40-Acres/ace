// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.36;

import {Test} from "forge-std/Test.sol";
import {Ace} from "../../src/ace/hub/Ace.sol";
import {Constants} from "../../src/ace/hub/Constants.sol";
import {MarketParams} from "../../src/ace/hub/Types.sol";
import {MockERC20} from "../mocks/MockERC20.sol";
import {MockPersistenceRecord} from "../mocks/MockPersistenceRecord.sol";
import {MockStakeVault} from "../mocks/MockStakeVault.sol";
import {AceFixtures} from "../utils/AceFixtures.sol";
import {AllInFeeSpec} from "../utils/AllInFeeSpec.sol";

/// @notice The genesis share rail at market shapes other than the launch fixture's, and at its edge.
/// @notice The rail is INCLUSIVE, and with the rate in bps a year its edge is a single second wide.
/// @dev No rate times term lands exactly on the share: `2500 * 1e4 * 365 days` is not a multiple of 11000.
/// @dev So the edge is pinned as the last admitted second against the first refused one.
/// @dev Admission is judged against `AllInFeeSpec`, never against `LoanMath`: the rail must have an oracle.
contract AceAllInFeeRailShapesTest is Test {
    Ace internal ace;
    MockERC20 internal usdc;
    MockStakeVault internal vault;
    MockPersistenceRecord internal record;

    uint256 internal constant PS = Constants.MAX_PROTOCOL_SHARE_BPS;
    uint256 internal constant RAIL = 71_672_727_272; // floor(2500 * 1e4 * 365 days / 11000): a rate times a term past it takes over a quarter

    uint64 internal constant EDGE_MIN_TENOR = 11 days;
    uint64 internal constant EDGE_LAST = 143_345_454; // 500 * 143,345,454 = 71,672,727,000, the last term under RAIL at 500 bps
    uint256 internal constant EDGE_BASE_BPS = 500;
    uint256 internal constant YEAR_CEIL = 2272; // the top rate a market of at most a year carries: 2272 * 365 days * 11000 <= 2500 * 1e4 * 365 days

    function setUp() public {
        usdc = new MockERC20("USD Coin", "USDC", 6);
        vault = new MockStakeVault(42);
        record = new MockPersistenceRecord(address(usdc), address(vault));
        AceFixtures.Deployment memory d = AceFixtures.deploy(_params(40, 7 days, 30 days, 23 days));
        ace = d.ace;
    }

    /* ============================== the rail is INCLUSIVE, at its last second ============================== */

    /// @notice There is no exact share to land on, so the rail's edge is the last second a rate admits.
    /// @notice At 500 bps a year that is 143,345,454 seconds; one second more is refused.
    /// @dev The share bound `1e4 * b * T * 11000 <= 2500 * 1e8 * 365 days` has no integer equality, which the first assertion pins.
    /// @dev The launch grid cannot reach the bound; this shape can, which is why the rail is pinned here.
    function test_TheRailAdmitsItsLastSecondAndRefusesTheNext() public {
        assertTrue((2500 * 10000 * uint256(365 days)) % (10000 + PS) != 0, "fixture: no rate times term sits exactly on the share");
        assertTrue(AllInFeeSpec.fundable(EDGE_BASE_BPS, EDGE_LAST, PS), "the spec admits the last second");

        bytes32 id = ace.createMarket(_params(EDGE_BASE_BPS, EDGE_MIN_TENOR, EDGE_LAST, 13 days));
        assertTrue(id != bytes32(0), "and genesis must admit it");

        uint64 over = EDGE_LAST + 1;
        assertFalse(AllInFeeSpec.fundable(EDGE_BASE_BPS, over, PS), "one second over must breach the bound");
        /// @dev HOISTED: `_params` reads the pair's decimals to name par, and an armed expectation is spent
        /// @dev by the first call at this depth -- which would be that read rather than `createMarket`.
        MarketParams memory bad = _params(EDGE_BASE_BPS, EDGE_MIN_TENOR, over, over - EDGE_MIN_TENOR);
        vm.expectRevert(bytes("fee bps too high"));
        ace.createMarket(bad);
    }

    /// @notice The boundary is per-SECOND, not per-day: at 182,500 bps a year the last admitted term is 392,727s.
    /// @dev The whole-day pins elsewhere leave a gap in which the rail's behaviour is unstated.
    /// @dev The market's one-day `minTenor` plays no part: the rail reads `maxTenor` alone.
    function test_TheRailBoundaryIsPerSecondAtAOneDayRung() public {
        uint64 minTenor = 1 days;
        uint64 last = 392_727; // 182,500 * 392,727 = 71,672,677,500, under RAIL
        uint64 first = 392_728; // and one second more is 71,672,860,000, over it

        assertTrue(AllInFeeSpec.fundable(182_500, last, PS), "the last admitted second must be fundable");
        assertFalse(AllInFeeSpec.fundable(182_500, first, PS), "and the next one must not be");

        bytes32 id = ace.createMarket(_params(182_500, minTenor, last, last - minTenor));
        assertTrue(id != bytes32(0), "genesis admits the last second");

        MarketParams memory bad = _params(182_500, minTenor, first, first - minTenor); // hoisted: the builder reads decimals
        vm.expectRevert(bytes("fee bps too high"));
        ace.createMarket(bad);
    }

    /* ============================== the degenerate shape ============================== */

    /// @notice A market of at most a year is fundable at 2272 bps a year, whatever its terms.
    /// @notice The rail reads `maxTenor` alone, and a year's term is the longest this row asks it about.
    /// @dev The rail is checked from the type's low end; genesis is asked from `MIN_TENOR_FLOOR`, which refuses a shorter market first.
    function test_AFlatMarketIsFundableAtEveryTermTheTypeAdmits() public {
        uint64[3] memory terms = [uint64(1), uint64(1 hours), uint64(365 days)]; // 1 is the type's low end
        for (uint256 i; i < terms.length; i++) {
            assertTrue(AllInFeeSpec.fundable(YEAR_CEIL, terms[i], PS), "a market of at most a year must clear the rail at 2272");
            uint64 t = terms[i] < Constants.MIN_TENOR_FLOOR ? Constants.MIN_TENOR_FLOOR : terms[i];
            bytes32 id = ace.createMarket(_params(YEAR_CEIL, t, t, 0));
            assertTrue(id != bytes32(0), "and genesis must admit it at the steepest bps");
        }
    }

    /* ============================== admission IS the predicate ============================== */

    /// @notice Over every shape the envelope admits, genesis says yes exactly when the record's rail says fundable.
    /// @notice And when it says no, the refusal is the FEE rail's, never another require standing in for it.
    /// @dev The span is seeded up to twice `RAIL / lenderAprBps`, so the rail is crossed at every rate.
    function testFuzz_GenesisAdmitsExactlyWhenTheRailSaysFundable(uint64 minTenorSeed, uint256 baseBpsSeed, uint64 spanSeed) public {
        uint64 minTenor = uint64(bound(minTenorSeed, 1 hours, 365 days));
        uint256 lenderAprBps = bound(baseBpsSeed, Constants.MIN_LENDER_APR_BPS, (2 * RAIL) / minTenor);
        uint64 maxTenor = uint64(bound(spanSeed, minTenor, _max(minTenor, (2 * RAIL) / lenderAprBps)));
        uint64 spacing = maxTenor == minTenor ? 0 : maxTenor - minTenor;

        MarketParams memory p = _params(lenderAprBps, minTenor, maxTenor, spacing); // hoisted: the builder reads decimals
        if (AllInFeeSpec.fundable(lenderAprBps, maxTenor, PS)) {
            assertTrue(ace.createMarket(p) != bytes32(0), "the rail admits it, so genesis must");
        } else {
            vm.expectRevert(bytes("fee bps too high"));
            ace.createMarket(p);
        }
    }

    /// @notice The fee's slack is quantised on every admitted shape, so no market sits one wei inside the whole principal.
    /// @dev Pinned here as well as in the pure file because it is what makes the zero-payout fixture constructible.
    function testFuzz_EveryAdmittedShapeCarriesAtLeastTenThousandOfSlack(uint64 minTenorSeed, uint256 baseBpsSeed, uint64 spanSeed) public {
        uint64 minTenor = uint64(bound(minTenorSeed, 1 hours, 365 days));
        uint256 lenderAprBps = bound(baseBpsSeed, Constants.MIN_LENDER_APR_BPS, RAIL / minTenor);
        uint64 maxTenor = uint64(bound(spanSeed, minTenor, RAIL / lenderAprBps));
        vm.assume(AllInFeeSpec.fundable(lenderAprBps, maxTenor, PS));

        uint64 spacing = maxTenor == minTenor ? 0 : maxTenor - minTenor;
        assertTrue(ace.createMarket(_params(lenderAprBps, minTenor, maxTenor, spacing)) != bytes32(0), "fixture: the shape must be admitted");
        uint256 g = AllInFeeSpec.slack(lenderAprBps, maxTenor, PS);
        assertGe(g, 10_000, "an admitted market carried under ten thousand of slack, which the quantisation forbids");
    }

    /* ============================== helpers ============================== */

    function _max(uint256 a, uint256 b) private pure returns (uint256) {
        return a > b ? a : b;
    }

    /// @dev The launch fixture with only the fee shape overridden, so the rail is the one thing under test.
    function _params(uint256 lenderAprBps, uint64 minTenor, uint64 maxTenor, uint64 spacing) private view returns (MarketParams memory p) {
        p = AceFixtures.marketParams(address(usdc), address(vault));
        p.record = address(record);
        p.lenderAprBps = lenderAprBps;
        p.minTenor = minTenor;
        p.maxTenor = maxTenor;
    }
}
