// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.36;

import {Test} from "forge-std/Test.sol";
import {Constants} from "../../src/ace/hub/Constants.sol";
import {LoanMath} from "../../src/ace/hub/libraries/LoanMath.sol";
import {AllInFeeSpec} from "../utils/AllInFeeSpec.sol";

/// @notice The origination fee is the borrower's ALL-IN cost, and the arithmetic that makes it safe.
/// @notice The protocol's share is charged ON TOP of the lender's rate, not carved out of it.
/// @dev T1, T3, T5 and the overflow corners. The hub-side seam is `AceAllInFeeSeam`.
/// @dev The expected values are re-spelled from the decision record, never called out of `src`:
/// @dev a test that asked `LoanMath` what `LoanMath` computes would compare the code to itself.
/// @dev THE RAIL IS `baseBps * maxTenor * (10000 + PS) < 10000 * 10000 * minTenor`, and it is STRICT.
contract AceAllInFeeArithmeticTest is Test {
    uint256 internal constant PS = Constants.PROTOCOL_SHARE_BPS;

    /// @dev The planner's minimum-slack market: `minTenor = 10, baseBps = 3, maxTenor = 30303`.
    /// @dev Its slack `D' - N'` is 1000, which is the SMALLEST a market can have (see the quantisation test).
    uint64 internal constant MIN_SLACK_MIN_TENOR = 10;
    uint64 internal constant MIN_SLACK_MAX_TENOR = 30_303;
    uint256 internal constant MIN_SLACK_BASE_BPS = 3;
    uint256 internal constant FLAT_CEIL = 2272; // the top rate ANY market can carry: b * 11000 <= 2500 * 10000 when maxTenor equals minTenor

    /* ============================== T1: the fee never exceeds the draw ============================== */

    /// @notice Over every market the widened rail admits, the all-in fee is bounded by the principal.
    /// @notice So `open`'s `principal - fee` cannot underflow and `_payoutCheck`'s over-fee leg (`trySub` failing) is dead.
    /// @dev THIS DOES NOT SAY `payout > 0`. `feeAllIn == principal` IS REACHABLE, and T5 constructs it.
    /// @dev A market at minimum rail slack pays out nothing for every principal under `D' / (D' - N')`.
    /// @dev Read this fuzz as bounding the fee's SIGN of slack, never its size; that question is issue #277.
    function testFuzz_T1_TheAllInFeeNeverExceedsThePrincipal(uint64 minTenorSeed, uint256 baseBpsSeed, uint64 tenorSeed, uint256 principalSeed) public pure {
        uint64 minTenor = uint64(bound(minTenorSeed, 1, 365 days));
        uint256 baseBps = bound(baseBpsSeed, Constants.MIN_BASE_BPS, FLAT_CEIL);
        uint64 tenor = _tenorWithinRail(minTenor, baseBps, tenorSeed);
        vm.assume(AllInFeeSpec.fundable(baseBps, tenor, minTenor, PS));
        uint256 principal = bound(principalSeed, 1, 1e15);

        uint256 shipped = LoanMath.originationFee(principal, tenor, baseBps, minTenor);
        assertEq(shipped, AllInFeeSpec.feeAllIn(principal, tenor, baseBps, minTenor, PS), "originationFee must be the borrower's ALL-IN cost");
        assertLe(shipped, principal, "the all-in fee ate more than the draw: the payout subtraction underflows");
    }

    /// @notice The named counterexample: the market that separates the single-ceil shape from the literal one.
    /// @dev Under the LITERAL split (`lenderFee` ceiled, then `protocolFee` floored on top) this overshoots
    /// @dev the principal by one wei, which is a permanent `Panic(0x11)` on the draw path of immutable bytecode.
    /// @dev Under the ruled single ceil it lands exactly ON the principal, and the payout is zero.
    function test_T1_TheCounterexampleMarket_LandsExactlyOnThePrincipal() public pure {
        uint256 principal = 99_989;
        uint256 shipped = LoanMath.originationFee(principal, MIN_SLACK_MAX_TENOR, MIN_SLACK_BASE_BPS, MIN_SLACK_MIN_TENOR);
        assertEq(
            shipped,
            AllInFeeSpec.feeAllIn(principal, MIN_SLACK_MAX_TENOR, MIN_SLACK_BASE_BPS, MIN_SLACK_MIN_TENOR, PS),
            "the counterexample must price through the ALL-IN spelling"
        );
        assertEq(shipped, principal, "the single ceil lands ON the principal here, never one wei past it");
    }

    /* ============================== T3: the inverse is EXACT ============================== */

    /// @notice The derivation's inverse is exact to the wei: the derived draw's payout IS the debt it owes.
    /// @notice Not merely sufficient. `p - feeAllIn(p) == owed`, in both directions, with one rounding.
    /// @dev That equality is what makes `_net`'s `DrawBelowDebt` unreachable on the armed path.
    /// @dev The forward leg is the SHIPPED function; only the inverse is re-spelled, so this is not circular.
    function testFuzz_T3_TheInverseIsExactToTheWei(uint64 minTenorSeed, uint256 baseBpsSeed, uint64 tenorSeed, uint256 owedSeed) public pure {
        uint64 minTenor = uint64(bound(minTenorSeed, 1 hours, 365 days));
        uint256 baseBps = bound(baseBpsSeed, Constants.MIN_BASE_BPS, FLAT_CEIL);
        uint64 tenor = _tenorWithinRail(minTenor, baseBps, tenorSeed);
        vm.assume(AllInFeeSpec.fundable(baseBps, tenor, minTenor, PS));
        uint256 owed = bound(owedSeed, 1, 1e15);

        uint256 p = AllInFeeSpec.principalForOwed(owed, tenor, baseBps, minTenor, PS);
        uint256 fee = LoanMath.originationFee(p, tenor, baseBps, minTenor);
        assertLe(fee, p, "the derived draw cannot even carry its own fee");
        assertEq(p - fee, owed, "the inverse is not exact: the derived draw's payout must BE the old debt");
    }

    /// @notice Raising the draw above the derived principal can never lower the payout below the debt.
    /// @dev Monotonicity is what lets `derivedPrincipal` floor at `minDebt` without re-checking the inequality.
    function testFuzz_T3_ThePayoutIsMonotoneAboveTheDerivedPrincipal(uint256 owedSeed, uint256 liftSeed) public pure {
        uint64 minTenor = 7 days;
        uint64 tenor = 30 days;
        uint256 baseBps = 40;
        uint256 owed = bound(owedSeed, 1, 1e15);

        uint256 p = AllInFeeSpec.principalForOwed(owed, tenor, baseBps, minTenor, PS);
        uint256 lifted = p + bound(liftSeed, 0, 1e15);
        uint256 fee = LoanMath.originationFee(lifted, tenor, baseBps, minTenor);
        assertGe(lifted - fee, owed, "a larger draw retired less debt: the floor branch would be unsafe");
    }

    /* ============================== T5: the zero-payout market ============================== */

    /// @notice The rail's slack is QUANTISED at 1000, so `D' - N' == 1` is unconstructible and 1000 is the floor.
    /// @dev `D' = 1e8 * minTenor` and `N' = baseBps * tenor * 11000` are both multiples of 1000.
    /// @dev This is why T5's fixture is built at 1000 rather than at 1: a market at 1 cannot be created.
    function testFuzz_T5_TheRailSlackIsQuantisedAtOneThousand(uint64 minTenorSeed, uint256 baseBpsSeed, uint64 tenorSeed) public pure {
        uint64 minTenor = uint64(bound(minTenorSeed, 1, 365 days));
        uint256 baseBps = bound(baseBpsSeed, Constants.MIN_BASE_BPS, FLAT_CEIL);
        uint64 tenor = _tenorWithinRail(minTenor, baseBps, tenorSeed);
        vm.assume(AllInFeeSpec.fundable(baseBps, tenor, minTenor, PS));

        uint256 g = AllInFeeSpec.slack(baseBps, tenor, minTenor, PS);
        assertEq(g % 1000, 0, "the slack is a multiple of 1000, so a market at slack 1 cannot exist");
        assertGe(g, 1000, "1000 is the smallest slack any admissible market can carry");
    }

    /// @notice At the true minimum slack the borrower receives NOTHING: the all-in fee IS the principal.
    /// @notice Every principal under `D' / (D' - N')` pays out zero; one wei of payout starts at that bound.
    /// @dev PRE-EXISTING and not introduced by the repricing: today's rail has the same shape and reach.
    /// @dev Pinned as KNOWN so T1's bound is never read as certifying `payout > 0`. See issue #277.
    /// @dev Slack 1000 needs `minTenor == 10 (mod 11)`, which is why a 7-day market cannot reach it.
    function test_T5_AtMinimumSlackThePayoutIsZero() public pure {
        assertEq(AllInFeeSpec.slack(MIN_SLACK_BASE_BPS, MIN_SLACK_MAX_TENOR, MIN_SLACK_MIN_TENOR, PS), 1000, "fixture: this market is at the floor");
        assertEq(uint256(MIN_SLACK_MIN_TENOR) % 11, 10, "fixture: slack 1000 requires minTenor == 10 (mod 11)");

        assertEq(_minSlackFee(1), 1, "one wei of principal buys one wei of fee and no payout at all");
        assertEq(_minSlackFee(500_000), 500_000, "and so does every principal under the bound");
        assertEq(_minSlackFee(999_999), 999_999, "including the last one below it");
        assertEq(_minSlackFee(1_000_000), 999_999, "at D' / (D' - N') exactly one wei of payout appears");
    }

    /// @notice The same market from the payout side, which is the number a borrower actually sees.
    function test_T5_AtMinimumSlackTheBorrowerReceivesNothing() public pure {
        assertEq(AllInFeeSpec.payout(999_999, MIN_SLACK_MAX_TENOR, MIN_SLACK_BASE_BPS, MIN_SLACK_MIN_TENOR, PS), 0, "spec: zero payout");
        assertEq(999_999 - _minSlackFee(999_999), 0, "the shipped fee must leave the borrower nothing here too");
        assertEq(1_000_000 - _minSlackFee(1_000_000), 1, "and exactly one wei one step up");
    }

    /* ============================== overflow headroom ============================== */

    /// @notice The widened products fit at both envelope corners, so no admissible market can overflow them.
    /// @dev The numerator's worst case is `2272 * (2^64 - 1) * 11000`, about 4.61e26.
    /// @dev The denominator's is `1e8 * (2^64 - 1)`, about 1.8e27. Both sit ~50 orders under 2^256.
    /// @dev 2272 IS THE RATE CEILING NOW, and it comes from the share rail rather than from a band of its own.
    /// @dev Genesis refuses anything over `MAX_FEE_SHARE_BPS` by name first, so the share rail is never reached unbounded.
    function test_OverflowHeadroom_TheWidenedProductsFitAtTheEnvelopeCorners() public pure {
        uint64 hugeTenor = type(uint64).max;
        uint256 corner = LoanMath.originationFee(1, hugeTenor, FLAT_CEIL, 1);
        assertEq(corner, AllInFeeSpec.feeAllIn(1, hugeTenor, FLAT_CEIL, 1, PS), "the tenor corner must not wrap or revert");
        assertLt(FLAT_CEIL * uint256(type(uint64).max) * 11000, type(uint256).max, "and the numerator's own corner fits outright");

        uint64 minTenor = 365 days;
        uint64 tenor = _railCeiling(minTenor, FLAT_CEIL);
        uint256 principal = type(uint128).max;
        uint256 big = LoanMath.originationFee(principal, tenor, FLAT_CEIL, minTenor);
        assertEq(big, AllInFeeSpec.feeAllIn(principal, tenor, FLAT_CEIL, minTenor, PS), "the principal corner must not wrap either");
        assertLe(big, principal, "and the bound still holds at the largest draw the type admits");
    }

    /* ============================== helpers ============================== */

    /// @dev The fee this file's minimum-slack market charges, spelled once so the cases read as numbers.
    function _minSlackFee(uint256 principal) private pure returns (uint256) {
        return LoanMath.originationFee(principal, MIN_SLACK_MAX_TENOR, MIN_SLACK_BASE_BPS, MIN_SLACK_MIN_TENOR);
    }

    /// @dev The longest term the WIDENED rail admits: strictly under `1e8 * minTenor / (baseBps * 11000)`.
    function _railCeiling(uint64 minTenor, uint256 baseBps) private pure returns (uint64) {
        uint256 ceiling = (10000 * 10000 * uint256(minTenor) - 1) / (baseBps * (10000 + PS));
        return uint64(ceiling < minTenor ? uint256(minTenor) : ceiling);
    }

    /// @dev A term inside the widened rail, and never under `minTenor`, which `_preChecks` also enforces.
    function _tenorWithinRail(uint64 minTenor, uint256 baseBps, uint64 seed) private pure returns (uint64) {
        return uint64(bound(seed, minTenor, _railCeiling(minTenor, baseBps)));
    }
}
