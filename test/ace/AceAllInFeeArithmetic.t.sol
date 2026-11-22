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
/// @dev THE RAIL IS `1e4 * rate * maxTenor * (10000 + PS) <= 2500 * 1e8 * 365 days`; the rate is bps a year.
contract AceAllInFeeArithmeticTest is Test {
    uint256 internal constant PS = Constants.MAX_PROTOCOL_SHARE_BPS;

    /// @dev The minimum-slack pair: rate 10 bps a year over 28,669,090,909 seconds.
    /// @dev Its slack `D' - N'` is 10000, which is the SMALLEST a pair can have (see the quantisation test).
    uint64 internal constant MIN_SLACK_TENOR = 28_669_090_909;
    uint256 internal constant MIN_SLACK_BASE_BPS = 10;
    uint256 internal constant RATE_CEIL = 7_167_272_727; // the top rate any market can carry: the share rail at the hub's 10-second tenor floor
    uint256 internal constant YEAR_CEIL = 2272; // the share rail's top rate at a 365-day term

    /* ============================== T1: the fee never exceeds the draw ============================== */

    /// @notice Over every pair the rail admits, the all-in fee is bounded by the principal.
    /// @notice So `open`'s `principal - fee` cannot underflow and `_payoutCheck`'s over-fee leg (`trySub` failing) is dead.
    /// @dev THIS DOES NOT SAY `payout > 0` in general: `feeAllIn == principal` is reachable in arithmetic, and T5 constructs it.
    /// @dev Read this fuzz as bounding the fee's SIGN of slack, never its size; that question is issue #277.
    function testFuzz_T1_TheAllInFeeNeverExceedsThePrincipal(uint256 baseBpsSeed, uint64 tenorSeed, uint256 principalSeed) public pure {
        uint256 lenderAprBps = bound(baseBpsSeed, Constants.MIN_LENDER_APR_BPS, RATE_CEIL);
        uint64 tenor = _tenorWithinRail(lenderAprBps, tenorSeed);
        vm.assume(AllInFeeSpec.fundable(lenderAprBps, tenor, PS));
        uint256 principal = bound(principalSeed, 1, 1e15);

        uint256 shipped = LoanMath.originationFee(principal, tenor, lenderAprBps);
        assertEq(shipped, AllInFeeSpec.feeAllIn(principal, tenor, lenderAprBps, PS), "originationFee must be the borrower's ALL-IN cost");
        assertLe(shipped, principal, "the all-in fee ate more than the draw: the payout subtraction underflows");
    }

    /// @notice The named counterexample: the pair that separates the single-ceil shape from the literal one.
    /// @dev Under the LITERAL split (`lenderFee` ceiled, then `protocolFee` floored on top) this overshoots
    /// @dev the principal by one wei, which is a permanent `Panic(0x11)` on the draw path of immutable bytecode.
    /// @dev Under the ruled single ceil it lands exactly ON the principal, and the payout is zero.
    function test_T1_TheCounterexampleMarket_LandsExactlyOnThePrincipal() public pure {
        uint256 principal = 99_989;
        uint256 shipped = LoanMath.originationFee(principal, MIN_SLACK_TENOR, MIN_SLACK_BASE_BPS);
        assertEq(
            shipped, AllInFeeSpec.feeAllIn(principal, MIN_SLACK_TENOR, MIN_SLACK_BASE_BPS, PS), "the counterexample must price through the ALL-IN spelling"
        );
        assertEq(shipped, principal, "the single ceil lands ON the principal here, never one wei past it");
    }

    /* ============================== T3: the inverse is EXACT ============================== */

    /// @notice The derivation's inverse is exact to the wei: the derived draw's payout IS the debt it owes.
    /// @notice Not merely sufficient. `p - feeAllIn(p) == owed`, in both directions, with one rounding.
    /// @dev That equality is what makes `_net`'s `DrawBelowDebt` unreachable on the armed path.
    /// @dev The forward leg is the SHIPPED function; only the inverse is re-spelled, so this is not circular.
    function testFuzz_T3_TheInverseIsExactToTheWei(uint256 baseBpsSeed, uint64 tenorSeed, uint256 owedSeed) public pure {
        uint256 lenderAprBps = bound(baseBpsSeed, Constants.MIN_LENDER_APR_BPS, RATE_CEIL);
        uint64 tenor = _tenorWithinRail(lenderAprBps, tenorSeed);
        vm.assume(AllInFeeSpec.fundable(lenderAprBps, tenor, PS));
        uint256 owed = bound(owedSeed, 1, 1e15);

        uint256 p = AllInFeeSpec.principalForOwed(owed, tenor, lenderAprBps, PS);
        uint256 fee = LoanMath.originationFee(p, tenor, lenderAprBps);
        assertLe(fee, p, "the derived draw cannot even carry its own fee");
        assertEq(p - fee, owed, "the inverse is not exact: the derived draw's payout must BE the old debt");
    }

    /// @notice Raising the draw above the derived principal can never lower the payout below the debt.
    /// @dev Monotonicity is what lets `derivedPrincipal` floor at `minPrincipal` without re-checking the inequality.
    function testFuzz_T3_ThePayoutIsMonotoneAboveTheDerivedPrincipal(uint256 owedSeed, uint256 liftSeed) public pure {
        uint64 tenor = 30 days;
        uint256 lenderAprBps = 40;
        uint256 owed = bound(owedSeed, 1, 1e15);

        uint256 p = AllInFeeSpec.principalForOwed(owed, tenor, lenderAprBps, PS);
        uint256 lifted = p + bound(liftSeed, 0, 1e15);
        uint256 fee = LoanMath.originationFee(lifted, tenor, lenderAprBps);
        assertGe(lifted - fee, owed, "a larger draw retired less debt: the floor branch would be unsafe");
    }

    /* ============================== T5: the zero-payout pair ============================== */

    /// @notice The fee's slack is QUANTISED: it is always 10000 over a multiple of 11000, so 10000 is the floor.
    /// @dev `D' = 1e8 * 365 days` is 10000 mod 11000 and `N' = rate * tenor * 11000` is a multiple of 11000.
    /// @dev This is why T5's fixture is built at 10000 rather than at 1: a pair at 1 cannot be written.
    function testFuzz_T5_TheRailSlackIsQuantisedAtTenThousand(uint256 baseBpsSeed, uint64 tenorSeed) public pure {
        uint256 lenderAprBps = bound(baseBpsSeed, Constants.MIN_LENDER_APR_BPS, RATE_CEIL);
        uint64 tenor = _tenorWithinRail(lenderAprBps, tenorSeed);
        vm.assume(AllInFeeSpec.fundable(lenderAprBps, tenor, PS));

        uint256 g = AllInFeeSpec.slack(lenderAprBps, tenor, PS);
        assertEq(g % 11_000, 10_000, "the slack is 10000 over a multiple of 11000, so a pair at slack 1 cannot exist");
        assertGe(g, 10_000, "10000 is the smallest slack any pair can carry");
    }

    /// @notice At the true minimum slack the borrower receives NOTHING: the all-in fee IS the principal.
    /// @notice Every principal under `D' / (D' - N')` pays out zero; one wei of payout starts at that bound.
    /// @dev Pure arithmetic: genesis refuses this pair by the share rail, so no market can carry it (`AceAllInFeeSeam` T5).
    /// @dev Pinned as KNOWN so T1's bound is never read as certifying `payout > 0`. See issue #277.
    function test_T5_AtMinimumSlackThePayoutIsZero() public pure {
        assertEq(AllInFeeSpec.slack(MIN_SLACK_BASE_BPS, MIN_SLACK_TENOR, PS), 10_000, "fixture: this pair is at the floor");
        assertEq((10_000 * 10_000 * uint256(365 days)) % 11_000, 10_000, "fixture: a year of 1e8 sits 10000 over a multiple of 11000");

        assertEq(_minSlackFee(1), 1, "one wei of principal buys one wei of fee and no payout at all");
        assertEq(_minSlackFee(500_000), 500_000, "and so does every principal under the bound");
        assertEq(_minSlackFee(315_359_999_999), 315_359_999_999, "including the last one below it");
        assertEq(_minSlackFee(315_360_000_000), 315_359_999_999, "at D' / (D' - N') exactly one wei of payout appears");
    }

    /// @notice The same pair from the payout side, which is the number a borrower actually sees.
    function test_T5_AtMinimumSlackTheBorrowerReceivesNothing() public pure {
        assertEq(AllInFeeSpec.payout(315_359_999_999, MIN_SLACK_TENOR, MIN_SLACK_BASE_BPS, PS), 0, "spec: zero payout");
        assertEq(315_359_999_999 - _minSlackFee(315_359_999_999), 0, "the shipped fee must leave the borrower nothing here too");
        assertEq(315_360_000_000 - _minSlackFee(315_360_000_000), 1, "and exactly one wei one step up");
    }

    /* ============================== overflow headroom ============================== */

    /// @notice The widened products fit at both envelope corners, so no admissible market can overflow them.
    /// @dev The numerator's worst case is `7167272727 * (2^64 - 1) * 11000`, about 1.5e33, some 44 orders under 2^256.
    /// @dev The denominator is the constant `1e8 * 365 days`, about 3.2e15.
    /// @dev Genesis refuses an over-share rate by name before `originationFee` runs, so the product is never reached unbounded.
    function test_OverflowHeadroom_TheWidenedProductsFitAtTheEnvelopeCorners() public pure {
        uint64 hugeTenor = type(uint64).max;
        uint256 corner = LoanMath.originationFee(1, hugeTenor, RATE_CEIL);
        assertEq(corner, AllInFeeSpec.feeAllIn(1, hugeTenor, RATE_CEIL, PS), "the tenor corner must not wrap or revert");
        assertLt(RATE_CEIL * uint256(type(uint64).max) * 11000, type(uint256).max, "and the numerator's own corner fits outright");

        uint64 tenor = 365 days;
        uint256 principal = type(uint128).max;
        uint256 big = LoanMath.originationFee(principal, tenor, YEAR_CEIL);
        assertEq(big, AllInFeeSpec.feeAllIn(principal, tenor, YEAR_CEIL, PS), "the principal corner must not wrap either");
        assertLe(big, principal, "and the bound still holds at the largest draw the type admits");
    }

    /* ============================== helpers ============================== */

    /// @dev The fee this file's minimum-slack pair charges, spelled once so the cases read as numbers.
    function _minSlackFee(uint256 principal) private pure returns (uint256) {
        return LoanMath.originationFee(principal, MIN_SLACK_TENOR, MIN_SLACK_BASE_BPS);
    }

    /// @dev The longest term the share rail admits at `lenderAprBps`: `2500 * 1e4 * 365 days / (lenderAprBps * 11000)`.
    function _railCeiling(uint256 lenderAprBps) private pure returns (uint64) {
        return uint64((2500 * 10000 * uint256(365 days)) / (lenderAprBps * (10000 + PS)));
    }

    /// @dev A term inside the share rail, at least one second.
    function _tenorWithinRail(uint256 lenderAprBps, uint64 seed) private pure returns (uint64) {
        return uint64(bound(seed, 1, _railCeiling(lenderAprBps)));
    }
}
