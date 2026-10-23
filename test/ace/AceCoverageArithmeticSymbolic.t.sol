// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.36;

import {Test} from "forge-std/Test.sol";
import {Borrower} from "../../src/ace/hub/Borrower.sol";
import {Cfg} from "../../src/ace/hub/Types.sol";
import {FullMath} from "@uniswap/v4-core/src/libraries/FullMath.sol";

/// @title AceCoverageArithmeticSymbolic
/// @notice The gate-vs-execution question as PURE arithmetic: can settlement need more than the gate left?
/// @notice `check_` bodies are halmos entry points; the `testFuzz_` twins run the same properties under forge.
/// @dev The gate side calls the SHIPPED `Borrower.requiredAt`, so only the settlement sum is re-spelled here.
/// @dev That one line is `LoanAccounting.collateralNeeded`'s body, which is storage-bound and cannot be called pure.
/// @dev Its fidelity is anchored by the hub-level repro, not by this file: see the issue's named test.
/// @dev UNROLLED, never looped: halmos bounds loops explicitly, so a loop would not be solvable at all.
/// @dev ONE `check_` BODY RETURNS A VERDICT: the FullMath-free control passes. The rest time out.
/// @dev Run them with `make halmos`, never a bare `halmos` -- that builds where an ordinary build overwrites it.
/// @dev The default assertion budget is too short even for the one that lands: pass 600s to see it.
contract AceCoverageArithmeticSymbolicTest is Test {
    uint256 internal constant WAD = 1e18;

    /// @dev A Cfg carrying only the two fields `requiredAt` reads, so the gate is the real one.
    function _cfg(uint256 k, uint256 unitScale) internal pure returns (Cfg memory c) {
        c.p.minCoverageWad = k;
        c.unitScale = unitScale;
    }

    /// @dev One funded tick's contribution to settlement's need: CEIL, as `collateralNeeded` ceils.
    function _needAt(uint256 claim, uint256 unitScale, uint256 price) internal pure returns (uint256) {
        return (claim * unitScale + price - 1) / price;
    }

    /* ============ P1: the bound settlement's need can never exceed ============ */

    /// @notice Settlement's need is under the gate plus the number of funded ticks. THE bound, three ticks.
    /// @notice Each per-tick ceiling adds under one collateral wei, so `n` ticks add under `n`.
    /// @dev This is the property that SURVIVES whichever way the confirmed bug is fixed, so it is the one
    /// @dev worth pinning: a fix that lowers the divergence keeps it, a regression that widens it breaks it.
    function _assertBound(uint256 k, uint256 s, uint256 floor, uint256 d0, uint256 d1, uint256 d2, uint256 x1, uint256 x2) internal pure {
        uint256 gate = Borrower.requiredAt(_cfg(k, s), d0 + d1 + d2, floor);
        uint256 need = _needAt(d0, s, floor) + _needAt(d1, s, floor + x1) + _needAt(d2, s, floor + x2);
        assertLe(need, gate + 3, "settlement needed more than the gate plus one wei per funded tick");
    }

    /// @dev Bounds chosen to keep every product inside a uint256 while leaving the ceilings observable.
    function _bindInputs(uint256 kSeed, uint256 sSeed, uint256 floorSeed) internal pure returns (uint256 k, uint256 s, uint256 floor) {
        k = bound(kSeed, 1.05e18, 20e18); // MIN_COVERAGE_WAD .. MAX_COVERAGE_WAD
        s = bound(sSeed, 1e2, 1e34); // unitScale across the legal decimal gap
        floor = bound(floorSeed, 1e6, 1e24);
    }

    function testFuzz_P1_NeedNeverExceedsTheGatePlusTheTickCount(
        uint256 kSeed,
        uint256 sSeed,
        uint256 floorSeed,
        uint256 d0,
        uint256 d1,
        uint256 d2,
        uint256 x1,
        uint256 x2
    ) public pure {
        (uint256 k, uint256 s, uint256 floor) = _bindInputs(kSeed, sSeed, floorSeed);
        (d0, d1, d2) = (bound(d0, 0, 1e24), bound(d1, 0, 1e24), bound(d2, 0, 1e24));
        vm.assume(d0 + d1 + d2 > 0);
        /// @dev every funded tick prices at or above the loan's own funding floor, by definition of the floor
        (x1, x2) = (bound(x1, 0, 1e24), bound(x2, 0, 1e24));
        _assertBound(k, s, floor, d0, d1, d2, x1, x2);
    }

    /// @notice The halmos twin with coverage, scale and tick prices concrete and only the claims symbolic.
    /// @notice It does NOT land: TIMEOUT at 63 paths in 604.5s, on a 600s assertion budget.
    /// @dev Concrete divisors were the obvious fix and they are NOT the wall -- this run is what proved it.
    /// @dev `FullMath` IS the wall: the check below is this one without it, and it passes in 72s.
    /// @dev Same property, same parameters, same budget, one difference -- so the 512-bit path is the cost.
    function check_P1_AtConcreteScaleAndPrices(uint256 d0, uint256 d1, uint256 d2) public pure {
        vm.assume(d0 <= 1e12 && d1 <= 1e12 && d2 <= 1e12);
        vm.assume(d0 + d1 + d2 > 0);
        uint256 s = 1e8; // 8-dec collateral against an 18-dec quote
        uint256 floor = 1e18;
        uint256 gate = Borrower.requiredAt(_cfg(1.4e18, s), d0 + d1 + d2, floor);
        uint256 need = _needAt(d0, s, floor) + _needAt(d1, s, 1000100000000000000) + _needAt(d2, s, 1000200000000000000);
        assertLe(need, gate + 3, "settlement needed more than the gate plus one wei per funded tick");
    }

    /* ============ what a solver can and cannot do here, isolated ============ */

    /// @notice The SAME gate at the same concrete parameters, spelled without `FullMath`. Solver-only.
    /// @dev `requiredAt` at `k = 1.4e18`, `unitScale = 1e8`, `price = 1e18` reduces to `ceil(debt * 14 / 1e11)`.
    /// @dev `testFuzz_ThePlainGateIsTheRealGate` below proves that reduction against the shipped function.
    function _plainGate(uint256 debt) internal pure returns (uint256) {
        return (debt * 14 + 1e11 - 1) / 1e11;
    }

    /// @notice Anchors the reduction: the plain spelling IS `requiredAt` at these parameters, every debt.
    /// @dev Without this the solver-only check below would be verifying a formula nothing ties to the hub.
    function testFuzz_ThePlainGateIsTheRealGate(uint256 debt) public pure {
        debt = bound(debt, 0, 1e30);
        assertEq(_plainGate(debt), Borrower.requiredAt(_cfg(1.4e18, 1e8), debt, 1e18), "the reduction drifted from the shipped gate");
    }

    /// @notice P1 with the 512-bit path removed. THE control that says where the solver's cost actually is.
    /// @notice IT PASSES, at 19 paths in 72s. The only symbolic verdict this file has produced.
    /// @dev So a solver IS usable here, on a `FullMath`-free reduction anchored to the shipped gate.
    /// @dev It needs `--solver-timeout-assertion 600s`: the default budget times it out at 18 paths in 60s.
    /// @dev The check above is this one WITH `FullMath` and times out at that same budget: the 512-bit path is why.
    function check_P1_PlainArithmeticNoFullMath(uint256 d0, uint256 d1, uint256 d2) public pure {
        vm.assume(d0 <= 1e12 && d1 <= 1e12 && d2 <= 1e12);
        vm.assume(d0 + d1 + d2 > 0);
        uint256 need = _needAt(d0, 1e8, 1e18) + _needAt(d1, 1e8, 1000100000000000000) + _needAt(d2, 1e8, 1000200000000000000);
        assertLe(need, _plainGate(d0 + d1 + d2) + 3, "settlement needed more than the gate plus one wei per funded tick");
    }

    /// @dev The fully symbolic twin. KEPT so the limit stays visible, and it is not expected to return.
    function check_P1_NeedNeverExceedsTheGatePlusTheTickCount(uint256 k, uint256 s, uint256 floor, uint256 d0, uint256 d1, uint256 d2, uint256 x1, uint256 x2)
        public
        pure
    {
        vm.assume(k >= 1.05e18 && k <= 20e18);
        vm.assume(s >= 1e2 && s <= 1e34);
        vm.assume(floor >= 1e6 && floor <= 1e24);
        vm.assume(d0 <= 1e24 && d1 <= 1e24 && d2 <= 1e24 && d0 + d1 + d2 > 0);
        vm.assume(x1 <= 1e24 && x2 <= 1e24);
        _assertBound(k, s, floor, d0, d1, d2, x1, x2);
    }

    /* ============ P2: the coverage margin is what decides whether the bound bites ============ */

    /// @notice The gate strictly covers settlement WHENEVER the margin, in collateral wei, reaches the tick count.
    /// @notice `(k - 1) * debt * S / floor >= n` is the whole condition, and it is what dust debt destroys.
    /// @dev The contrapositive is the bug: shrink the margin under `n` and settlement can outrun the gate.
    /// @dev So this is not a restatement of P1 -- it names the reachable frontier rather than the bound.
    function testFuzz_P2_AMarginWiderThanTheTickCountAlwaysCovers(
        uint256 kSeed,
        uint256 sSeed,
        uint256 floorSeed,
        uint256 d0,
        uint256 d1,
        uint256 d2,
        uint256 x1,
        uint256 x2
    ) public pure {
        (uint256 k, uint256 s, uint256 floor) = _bindInputs(kSeed, sSeed, floorSeed);
        (d0, d1, d2) = (bound(d0, 0, 1e24), bound(d1, 0, 1e24), bound(d2, 0, 1e24));
        (x1, x2) = (bound(x1, 0, 1e24), bound(x2, 0, 1e24));
        uint256 debt = d0 + d1 + d2;
        vm.assume(debt > 0);

        uint256 margin = FullMath.mulDiv(k - WAD, debt * s, floor * WAD); // the coverage cushion, in collateral wei
        vm.assume(margin >= 3); // the frontier: a cushion at least as wide as the funded-tick count

        uint256 gate = Borrower.requiredAt(_cfg(k, s), debt, floor);
        uint256 need = _needAt(d0, s, floor) + _needAt(d1, s, floor + x1) + _needAt(d2, s, floor + x2);
        assertLe(need, gate, "a cushion wider than the tick count must still cover settlement");
    }

    /* ============ P3: the witness, so the frontier is known to be reachable ============ */

    /// @notice A concrete divergence: dust debt across three ticks makes settlement ask more than the gate left.
    /// @notice The same shape the hub-level repro reaches at 32 ticks; three is the smallest that shows it.
    /// @dev A PIN ON THE ARITHMETIC, not on hub behaviour -- it stays true whatever the hub fix does, because
    /// @dev it says only that these two formulas disagree on this input, which is why the fix was needed.
    function test_P3_TheDivergenceIsReachableAtDustDebt() public pure {
        uint256 k = 1.4e18;
        /// @dev 8-dec collateral against an 18-dec quote: `1e18 * 10 ** (8 - 18)`, so unitScale SHRINKS
        uint256 s = 1e8;
        uint256 floor = 1e18; // a price near parity, where the ladder's own ticks sit

        /// @dev each tick's claim is under `floor / s`, so its exact need is a FRACTION and its ceiling is 1
        uint256 claim = 1e9;
        uint256 gate = Borrower.requiredAt(_cfg(k, s), 3 * claim, floor);
        uint256 need = _needAt(claim, s, floor) + _needAt(claim, s, floor + 1) + _needAt(claim, s, floor + 2);

        assertEq(need, 3, "each of the three ticks must round its fraction up to one whole unit");
        assertGt(need, gate, "the witness must actually diverge, or this file proves nothing");
        assertLe(need, gate + 3, "and it must still obey P1's bound, or P1 is wrong");
    }

    /* ============ P4: how FEW funded ticks the divergence actually needs ============ */

    /// @notice TWO funded ticks are enough. The 32 in the hub-level repro is not what makes it happen.
    /// @dev Worth pinning because the precondition is much weaker than the reproduction suggests: 32 ticks
    /// @dev is what reaching dust debt THROUGH THE HUB took, not what the arithmetic divergence requires.
    function test_P4_TwoFundedTicksAlreadyDiverge() public pure {
        uint256 s = 1e8;
        uint256 floor = 1e18;
        uint256 claim = 1e9;

        uint256 gate = Borrower.requiredAt(_cfg(1.4e18, s), 2 * claim, floor);
        uint256 need = _needAt(claim, s, floor) + _needAt(claim, s, floor + 1);
        assertEq(need, 2, "both ticks round up to a whole unit");
        assertGt(need, gate, "two ticks are enough to outrun the gate");
    }

    /// @notice ONE funded tick can NEVER diverge, at any coverage, price or scale. The floor of the effect.
    /// @dev `k >= 1e18` makes the gate's single ceiling dominate settlement's single ceiling term for term,
    /// @dev so the divergence is created by AGGREGATING ceilings and by nothing else.
    function testFuzz_P4_ASingleFundedTickIsAlwaysCovered(uint256 kSeed, uint256 sSeed, uint256 floorSeed, uint256 debt) public pure {
        (uint256 k, uint256 s, uint256 floor) = _bindInputs(kSeed, sSeed, floorSeed);
        debt = bound(debt, 1, 1e24);
        uint256 gate = Borrower.requiredAt(_cfg(k, s), debt, floor);
        assertLe(_needAt(debt, s, floor), gate, "one tick outran the gate: the trap is not aggregation after all");
    }
}
