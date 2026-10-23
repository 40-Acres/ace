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

/// @notice The widened genesis rail at market shapes other than the launch fixture's, and at its edge.
/// @notice STRICT means the EQUALITY case is refused, and this file constructs one and reaches it.
/// @dev The existing pins are a bps edge (`AceOpenBounds`) and a whole-day edge (`AceAutoRefinance`).
/// @dev Neither sits on `baseBps * maxTenor * (10000 + PS) == 10000 * 10000 * minTenor` exactly, and it exists.
/// @dev Admission is judged against `AllInFeeSpec`, never against `LoanMath`: the rail must have an oracle.
contract AceAllInFeeRailShapesTest is Test {
    Ace internal ace;
    MockERC20 internal usdc;
    MockStakeVault internal vault;
    MockPersistenceRecord internal record;

    uint256 internal constant PS = Constants.PROTOCOL_SHARE_BPS;

    /// @dev The one constructible equality: `500 * 200d * 11000 == 1e8 * 11d`, both sides 9.504e13.
    uint64 internal constant EQ_MIN_TENOR = 11 days;
    /// @dev Sits EXACTLY on the share bound: 1e4*500*50d*11000 == 2500*1e8*11d, both 2.376e17.
    /// @dev It was 200 days against the old whole-principal bound, which the share ceiling moved.
    uint64 internal constant EQ_MAX_TENOR = 50 days;
    uint256 internal constant EQ_BASE_BPS = 500;
    uint256 internal constant FLAT_CEIL = 2272; // the top rate a flat market carries: b * 11000 <= 2500 * 10000 once the tenor cancels

    function setUp() public {
        usdc = new MockERC20("USD Coin", "USDC", 6);
        vault = new MockStakeVault(42);
        record = new MockPersistenceRecord(address(usdc), address(vault));
        AceFixtures.Deployment memory d = AceFixtures.deploy(_params(40, 7 days, 30 days, 23 days));
        ace = d.ace;
    }

    /* ============================== the rail is INCLUSIVE, at a reachable equality ============================== */

    /// @notice At exact equality the fee takes precisely the share ceiling, and genesis ADMITS the market.
    /// @notice One SECOND over it is refused, so the boundary really is the inclusive inequality.
    /// @dev This row INVERTED with the share ceiling. It used to pin equality as refused, because the
    /// @dev old bound existed only to keep the inverse's denominator off zero, where equality is fatal.
    /// @dev A share ceiling is a different claim: taking exactly a quarter of the draw is inside it.
    /// @dev The launch grid cannot reach the bound; this shape can, which is why the rail is pinned here.
    function test_TheRailAdmitsTheExactShareAndRefusesOneSecondOver() public {
        assertEq(
            10000 * EQ_BASE_BPS * uint256(EQ_MAX_TENOR) * (10000 + PS),
            AllInFeeSpec.FEE_SHARE_BPS * 10000 * 10000 * uint256(EQ_MIN_TENOR),
            "fixture: this market must sit exactly ON the bound, or it pins nothing"
        );
        assertTrue(AllInFeeSpec.fundable(EQ_BASE_BPS, EQ_MAX_TENOR, EQ_MIN_TENOR, PS), "the spec admits the exact share");

        bytes32 id = ace.createMarket(_params(EQ_BASE_BPS, EQ_MIN_TENOR, EQ_MAX_TENOR, 13 days));
        assertTrue(id != bytes32(0), "and genesis must admit it");

        uint64 over = EQ_MAX_TENOR + 1;
        assertFalse(AllInFeeSpec.fundable(EQ_BASE_BPS, over, EQ_MIN_TENOR, PS), "one second over must breach the bound");
        /// @dev HOISTED: `_params` reads the pair's decimals to name par, and an armed expectation is spent
        /// @dev by the first call at this depth -- which would be that read rather than `createMarket`.
        MarketParams memory bad = _params(EQ_BASE_BPS, EQ_MIN_TENOR, over, over - EQ_MIN_TENOR);
        vm.expectRevert(bytes("fee bps too high"));
        ace.createMarket(bad);
    }

    /// @notice The boundary is per-SECOND, not per-day: at a one-day rung the last admitted term is 392,727s.
    /// @dev The whole-day pins elsewhere leave a gap in which the rail's behaviour is unstated.
    /// @dev The pair moved with the share ceiling; it was 1,570,909/1,570,910 against the old bound.
    function test_TheRailBoundaryIsPerSecondAtAOneDayRung() public {
        uint64 minTenor = 1 days;
        uint64 last = 392_727; // 4 * 500 * 392_727 * 11000 == 8.639994e12, under 1e8 * 86400
        uint64 first = 392_728; // and one second more is 8.640016e12, over it

        assertTrue(AllInFeeSpec.fundable(500, last, minTenor, PS), "the last admitted second must be fundable");
        assertFalse(AllInFeeSpec.fundable(500, first, minTenor, PS), "and the next one must not be");

        bytes32 id = ace.createMarket(_params(500, minTenor, last, last - minTenor));
        assertTrue(id != bytes32(0), "genesis admits the last second");

        MarketParams memory bad = _params(500, minTenor, first, first - minTenor); // hoisted: the builder reads decimals
        vm.expectRevert(bytes("fee bps too high"));
        ace.createMarket(bad);
    }

    /* ============================== the degenerate shape ============================== */

    /// @notice A flat market (one rung, maxTenor == minTenor) is fundable at ANY admissible bps and any term.
    /// @notice The ratio collapses to `baseBps * (10000 + PS) / 1e8`, so the rail itself is what bounds it, at 2272.
    /// @dev So the rail can never refuse a single-rung market UNDER that rate, and the top of the band is where it stops.
    /// @dev The rail is checked from the type's low end; genesis is asked from `MIN_TENOR_FLOOR`, which refuses a shorter market first.
    function test_AFlatMarketIsFundableAtEveryTermTheTypeAdmits() public {
        uint64[3] memory terms = [uint64(1), uint64(1 hours), uint64(365 days)]; // 1 is the type's low end
        for (uint256 i; i < terms.length; i++) {
            assertTrue(AllInFeeSpec.fundable(FLAT_CEIL, terms[i], terms[i], PS), "a flat market must always clear the rail");
            uint64 t = terms[i] < Constants.MIN_TENOR_FLOOR ? Constants.MIN_TENOR_FLOOR : terms[i];
            bytes32 id = ace.createMarket(_params(FLAT_CEIL, t, t, 0));
            assertTrue(id != bytes32(0), "and genesis must admit it at the steepest bps");
        }
    }

    /* ============================== admission IS the predicate ============================== */

    /// @notice Over every shape the envelope admits, genesis says yes exactly when the record's rail says fundable.
    /// @notice And when it says no, the refusal is the FEE rail's, never another require standing in for it.
    /// @dev The span is seeded up to `20000 * minTenor / baseBps`, so the ratio crosses 1 at every bps.
    function testFuzz_GenesisAdmitsExactlyWhenTheRailSaysFundable(uint64 minTenorSeed, uint256 baseBpsSeed, uint64 spanSeed) public {
        uint64 minTenor = uint64(bound(minTenorSeed, 1 hours, 365 days));
        uint256 baseBps = bound(baseBpsSeed, Constants.MIN_BASE_BPS, Constants.MAX_FEE_SHARE_BPS);
        uint64 maxTenor = uint64(bound(spanSeed, minTenor, (20000 * uint256(minTenor)) / baseBps));
        uint64 spacing = maxTenor == minTenor ? 0 : maxTenor - minTenor;

        MarketParams memory p = _params(baseBps, minTenor, maxTenor, spacing); // hoisted: the builder reads decimals
        if (AllInFeeSpec.fundable(baseBps, maxTenor, minTenor, PS)) {
            assertTrue(ace.createMarket(p) != bytes32(0), "the rail admits it, so genesis must");
        } else {
            vm.expectRevert(bytes("fee bps too high"));
            ace.createMarket(p);
        }
    }

    /// @notice The rail's slack is quantised at 1000 on every admitted shape, so no market sits one wei inside it.
    /// @dev Pinned here as well as in the pure file because it is what makes the zero-payout fixture constructible.
    function testFuzz_EveryAdmittedShapeCarriesAtLeastAThousandOfSlack(uint64 minTenorSeed, uint256 baseBpsSeed, uint64 spanSeed) public {
        uint64 minTenor = uint64(bound(minTenorSeed, 1 hours, 365 days));
        uint256 baseBps = bound(baseBpsSeed, Constants.MIN_BASE_BPS, FLAT_CEIL);
        uint64 maxTenor = uint64(bound(spanSeed, minTenor, (20000 * uint256(minTenor)) / baseBps));
        vm.assume(AllInFeeSpec.fundable(baseBps, maxTenor, minTenor, PS));

        uint64 spacing = maxTenor == minTenor ? 0 : maxTenor - minTenor;
        assertTrue(ace.createMarket(_params(baseBps, minTenor, maxTenor, spacing)) != bytes32(0), "fixture: the shape must be admitted");
        uint256 g = AllInFeeSpec.slack(baseBps, maxTenor, minTenor, PS);
        assertGe(g, 1000, "an admitted market carried under a thousand of slack, which the quantisation forbids");
    }

    /* ============================== helpers ============================== */

    /// @dev The launch fixture with only the fee shape overridden, so the rail is the one thing under test.
    function _params(uint256 baseBps, uint64 minTenor, uint64 maxTenor, uint64 spacing) private view returns (MarketParams memory p) {
        p = AceFixtures.marketParams(address(usdc), address(vault));
        p.record = address(record);
        p.baseBps = baseBps;
        p.minTenor = minTenor;
        p.maxTenor = maxTenor;
    }
}
