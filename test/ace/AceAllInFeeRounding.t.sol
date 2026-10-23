// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.36;

import {Test} from "forge-std/Test.sol";
import {Constants} from "../../src/ace/hub/Constants.sol";
import {LoanMath} from "../../src/ace/hub/libraries/LoanMath.sol";

/// @notice Every rounding in the origination chain, stated as a direction rather than as a value.
/// @notice The ceil is against the BORROWER; each floor below it lands its residue on the LENDER.
/// @dev The seam files pin the numbers; this file pins which way the wei goes when they do not divide.
/// @dev Characterised as floors and ceilings, never re-spelled as expressions, so it survives a rewrite.
/// @dev `AceAllInFeeSeam` asserts the take rail on live draws; here it is unconditional over the domain.
contract AceAllInFeeRoundingTest is Test {
    uint256 internal constant PS = Constants.PROTOCOL_SHARE_BPS;
    uint256 internal constant PHI = Constants.REBATE_PHI_BPS;

    /// @dev Every product this file forms stays under 2^256 at or below it, so no fuzz needs FullMath.
    uint256 internal constant MAX_FEE = type(uint256).max / 100_000;
    uint256 internal constant FLAT_CEIL = 2272; // the top rate ANY market can carry: b * 11000 <= 2500 * 10000 when maxTenor equals minTenor

    /* ============================== the split closes, at every fee ============================== */

    /// @notice The four cuts account for the whole all-in to the wei, at any fee the arithmetic admits.
    /// @dev No dust escapes: `open` books exactly these three pots and transfers the rest.
    function testFuzz_TheSplitAccountsForEveryWeiOfTheAllIn(uint256 feeSeed) public pure {
        uint256 fee = bound(feeSeed, 0, MAX_FEE);
        uint256 p = LoanMath.protocolCut(fee);
        uint256 l = LoanMath.lenderCut(fee);

        assertEq(p + l, fee, "the protocol cut and the lender cut must be the whole all-in");
        assertEq(LoanMath.escrowCut(fee) + LoanMath.tickCut(fee), l, "and the escrow and tick halves must be the whole lender cut");
        assertEq(p + LoanMath.escrowCut(fee) + LoanMath.tickCut(fee), fee, "so the three booked pots close on the all-in");
    }

    /// @notice A zero fee splits into nothing, with no branch and no dust.
    function test_TheZeroFeeSplitsIntoNothing() public pure {
        assertEq(LoanMath.protocolCut(0), 0, "no fee, no take");
        assertEq(LoanMath.lenderCut(0), 0, "no fee, no lender cut");
        assertEq(LoanMath.escrowCut(0), 0, "no fee, no escrow");
        assertEq(LoanMath.tickCut(0), 0, "no fee, no tick credit");
    }

    /// @notice The split still closes at the largest fee the widened products admit.
    /// @dev The extreme is asserted as a named case because a fuzz bound is a choice, not a proof.
    function test_TheSplitClosesAtTheLargestFeeTheArithmeticAdmits() public pure {
        uint256 fee = MAX_FEE;
        assertEq(LoanMath.protocolCut(fee) + LoanMath.escrowCut(fee) + LoanMath.tickCut(fee), fee, "the split closes at the envelope corner too");
    }

    /* ============================== the take: floored, and bounded ============================== */

    /// @notice The take is the LARGEST integer under the inverse ratio: a floor, characterised as one.
    /// @dev Rounding it up would take a wei the lender's stated rate says is the lender's.
    function testFuzz_TheTakeIsTheFlooredInverseRatio(uint256 feeSeed) public pure {
        uint256 fee = bound(feeSeed, 0, MAX_FEE);
        uint256 p = LoanMath.protocolCut(fee);

        assertLe(p * (10000 + PS), fee * PS, "the take rounded UP: it took a wei of the lender's rate");
        assertGt((p + 1) * (10000 + PS), fee * PS, "and it must be the largest integer that fits, never less");
    }

    /// @notice The adopted rail, unconditionally: the protocol never out-takes its share of the lender fee.
    /// @notice And the wei-level tightening: the slack is under ONE step of the ratio, so no fee is over-kept.
    /// @dev The lower bound kills a ceiling mutant; the upper bound kills a cut that under-takes by design.
    function testFuzz_TheRoundingDustIsOneRatioStepAndLandsOnTheLender(uint256 feeSeed) public pure {
        uint256 fee = bound(feeSeed, 0, MAX_FEE);
        uint256 p = LoanMath.protocolCut(fee);
        uint256 l = LoanMath.lenderCut(fee);

        assertGe(l * PS, p * 10000, "the protocol out-took its share: the dust went the wrong way");
        assertLt(l * PS - p * 10000, 10000 + PS, "and the lender kept more than one ratio step of dust");
    }

    /// @notice Below eleven wei of all-in the protocol takes NOTHING and the borrower's whole fee is lender money.
    /// @dev The smallest fees are where an inverse-ratio floor differs most from a carve, so they are named.
    function test_TheTakeIsZeroUntilTheAllInReachesElevenWei() public pure {
        for (uint256 fee = 0; fee <= 12; fee++) {
            assertEq(LoanMath.protocolCut(fee), fee / 11, "the take at PS 1000 is the eleventh part, floored");
            assertEq(LoanMath.lenderCut(fee), fee - fee / 11, "and the lender keeps the rest exactly");
        }
        assertEq(LoanMath.protocolCut(10), 0, "ten wei of all-in is entirely the lender's");
        assertEq(LoanMath.protocolCut(11), 1, "eleven is the first that pays the protocol anything");
        assertEq(LoanMath.tickCut(1), 1, "one wei of fee reaches the ticks whole, earned immediately");
        assertEq(LoanMath.escrowCut(1), 0, "and none of it is withheld as a refundable half");
    }

    /* ============================== the escrow: floored, residue to the tick ============================== */

    /// @notice The escrow is the floored share of the LENDER cut, so its residue is earned immediately.
    /// @dev Characterised as a floor rather than re-spelled, so the property outlives a change to phi.
    function testFuzz_TheEscrowIsTheFlooredShareOfTheLenderCut(uint256 feeSeed) public pure {
        uint256 fee = bound(feeSeed, 0, MAX_FEE);
        uint256 l = LoanMath.lenderCut(fee);
        uint256 e = LoanMath.escrowCut(fee);

        assertLe(e * 10000, l * PHI, "the escrow rounded UP: it withheld a wei the tick had already earned");
        assertGt((e + 1) * 10000, l * PHI, "and it must be the largest share that fits");
        assertEq(LoanMath.tickCut(fee), l - e, "the tick cut is the exact residue, never a second product");
    }

    /// @notice At the shipped phi the odd wei of a lender cut goes to the TICK, never to the refundable half.
    /// @dev A borrower who closes in the opening block cannot claw that wei back, which is the safe direction.
    function testFuzz_TheOddWeiOfTheLenderCutGoesToTheTick(uint256 feeSeed) public pure {
        assertEq(PHI, 5000, "fixture: this direction is stated for the shipped half-and-half phi");
        uint256 fee = bound(feeSeed, 0, MAX_FEE);
        uint256 e = LoanMath.escrowCut(fee);
        uint256 t = LoanMath.tickCut(fee);

        assertGe(t, e, "the refundable half must never exceed the half earned at the draw");
        assertLe(t - e, 1, "and the two halves differ by at most the odd wei");
    }

    /* ============================== monotonicity ============================== */

    /// @notice Every cut is monotone in the fee, so no fee increase makes any party worse off.
    /// @dev A non-monotone floor would let a borrower pick a larger draw that pays the lenders less.
    function testFuzz_EveryCutIsMonotoneInTheFee(uint256 feeSeed) public pure {
        uint256 fee = bound(feeSeed, 0, MAX_FEE - 1);

        assertGe(LoanMath.protocolCut(fee + 1), LoanMath.protocolCut(fee), "the take fell as the fee rose");
        assertGe(LoanMath.lenderCut(fee + 1), LoanMath.lenderCut(fee), "the lender cut fell as the fee rose");
        assertGe(LoanMath.escrowCut(fee + 1), LoanMath.escrowCut(fee), "the escrow fell as the fee rose");
        assertGe(LoanMath.tickCut(fee + 1), LoanMath.tickCut(fee), "the tick credit fell as the fee rose");
    }

    /* ============================== the all-in: the ceil, and what rests on it ============================== */

    /// @notice The all-in rounds UP and by strictly less than a wei: the ceil is against the borrower.
    /// @dev Pinned against the ratio itself, not against a second spelling of the same formula.
    function testFuzz_TheAllInRoundsUpAndNeverDown(uint64 minTenorSeed, uint256 baseBpsSeed, uint64 tenorSeed, uint256 principalSeed) public pure {
        (uint64 minTenor, uint256 baseBps, uint64 tenor) = _admissibleShape(minTenorSeed, baseBpsSeed, tenorSeed);
        uint256 principal = bound(principalSeed, 1, 1e15);

        uint256 fee = LoanMath.originationFee(principal, tenor, baseBps, minTenor);
        uint256 num = principal * baseBps * uint256(tenor) * (10000 + PS);
        uint256 den = 10000 * 10000 * uint256(minTenor);

        assertGe(fee * den, num, "the all-in rounded DOWN: the borrower kept a wei of the lenders' premium");
        if (fee != 0) assertLt((fee - 1) * den, num, "and it overshot: a smaller integer already cleared the ratio");
    }

    /// @notice The all-in is monotone in the PRINCIPAL, which is what lets the minDebt floor raise a draw safely.
    /// @dev `derivedPrincipal` floors at `minDebt` without re-checking the inequality, and this is why it may.
    function testFuzz_TheAllInIsMonotoneInThePrincipal(uint64 minTenorSeed, uint256 baseBpsSeed, uint64 tenorSeed, uint256 pSeed, uint256 liftSeed)
        public
        pure
    {
        (uint64 minTenor, uint256 baseBps, uint64 tenor) = _admissibleShape(minTenorSeed, baseBpsSeed, tenorSeed);
        uint256 principal = bound(pSeed, 1, 1e15);
        uint256 lifted = principal + bound(liftSeed, 0, 1e15);

        assertGe(
            LoanMath.originationFee(lifted, tenor, baseBps, minTenor),
            LoanMath.originationFee(principal, tenor, baseBps, minTenor),
            "a larger draw priced cheaper: the floor branch could then under-fund the debt"
        );
    }

    /// @notice The all-in is monotone in the TENOR, which is the whole reason genesis checks the rail at maxTenor.
    /// @notice So a market the rail admits at its longest rung is fundable at every shorter one, with no per-draw check.
    /// @dev `MarketInit` states this as its justification; nothing else in the suite makes it fail if it stops holding.
    function testFuzz_TheRailAtMaxTenorBoundsEveryRungUnderIt(uint64 minTenorSeed, uint256 baseBpsSeed, uint64 longSeed, uint64 shortSeed) public pure {
        uint64 minTenor = uint64(bound(minTenorSeed, 1, 365 days));
        uint256 baseBps = bound(baseBpsSeed, Constants.MIN_BASE_BPS, FLAT_CEIL);
        uint64 long_ = uint64(bound(longSeed, minTenor, 40 * uint256(minTenor)));
        uint64 short_ = uint64(bound(shortSeed, minTenor, long_));

        assertGe(
            LoanMath.originationFee(1e15, long_, baseBps, minTenor),
            LoanMath.originationFee(1e15, short_, baseBps, minTenor),
            "the fee is not monotone in tenor: bounding at maxTenor would not bound the rungs under it"
        );
        if (LoanMath.feeFundable(baseBps, long_, minTenor)) {
            assertTrue(LoanMath.feeFundable(baseBps, short_, minTenor), "a rung under an admitted maxTenor was itself unfundable");
        }
    }

    /* ============================== helpers ============================== */

    /// @dev A market shape the widened rail admits, with the tenor never under `minTenor`.
    function _admissibleShape(uint64 minTenorSeed, uint256 baseBpsSeed, uint64 tenorSeed)
        private
        pure
        returns (uint64 minTenor, uint256 baseBps, uint64 tenor)
    {
        minTenor = uint64(bound(minTenorSeed, 1 hours, 365 days));
        baseBps = bound(baseBpsSeed, Constants.MIN_BASE_BPS, FLAT_CEIL);
        uint256 ceiling = (10000 * 10000 * uint256(minTenor) - 1) / (baseBps * (10000 + PS));
        tenor = uint64(bound(tenorSeed, minTenor, ceiling < minTenor ? uint256(minTenor) : ceiling));
    }
}
