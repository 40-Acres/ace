// LoanMath: the fee chain's rounding, checked against what its own comments claim.
//
// `FullMath.mulDivRoundingUp` is modelled EXACTLY -- ceil(a*b/d) in unbounded integers, with the two cases where the
// real routine reverts (a zero divisor, a quotient past 256 bits) pruned. Uniswap's implementation of that
// definition is taken as correct; what is checked is that LoanMath's formulas, built on it, round the way they say.
//
// The constants are Constants.sol's: PROTOCOL_SHARE_BPS = 1000, REBATE_PHI_BPS = 5000, MAX_FEE_SHARE_BPS = 2500.

methods {
    function FullMath.mulDivRoundingUp(uint256 a, uint256 b, uint256 d) internal returns (uint256) => ceilMulDiv(a, b, d);

    function triggerPrice(uint256, uint256, uint256, uint256) external returns (uint256) envfree;
    function originationFee(uint256, uint64, uint256, uint64) external returns (uint256) envfree;
    function protocolCut(uint256) external returns (uint256) envfree;
    function lenderCut(uint256) external returns (uint256) envfree;
    function escrowCut(uint256) external returns (uint256) envfree;
    function tickCut(uint256) external returns (uint256) envfree;
    function principalForOwed(uint256, uint64, uint256, uint64) external returns (uint256) envfree;
    function feeFundable(uint256, uint64, uint64) external returns (bool) envfree;
}

function ceilMulDiv(uint256 a, uint256 b, uint256 d) returns uint256 {
    require d != 0;
    mathint p = a * b;
    mathint q = p % d == 0 ? p / d : p / d + 1;
    return require_uint256(q);
}

definition SHARE() returns mathint = 1000;
definition MAX_FEE_SHARE() returns mathint = 2500;

// ---- the split ----

// "Subtraction, so the two floors cancel and the split closes to the wei."
rule theFeeSplitClosesToTheWei(uint256 fee) {
    assert protocolCut(fee) + lenderCut(fee) == to_mathint(fee), "the protocol and lender cuts do not sum to the fee";
    assert escrowCut(fee) + tickCut(fee) == to_mathint(lenderCut(fee)), "the escrow and tick cuts do not sum to the lender cut";
}

// "Floors, so the rounding residue lands on the LENDER and the protocol never over-takes."
rule theProtocolNeverOverTakes(uint256 fee) {
    mathint cut = protocolCut(fee);
    assert cut * (10000 + SHARE()) <= fee * SHARE(), "the protocol cut exceeds its exact share";
    assert (cut + 1) * (10000 + SHARE()) > fee * SHARE(), "the protocol cut fell more than a wei short";
}

// ---- the trigger ----

// "Rounds UP: a higher trigger arms earlier, so rounding favours lenders." -- and by less than one tick
rule theTriggerRoundsUpByUnderOne(uint256 debt, uint256 units, uint256 minCoverageWad, uint256 unitScale) {
    require units > 0;
    mathint t = triggerPrice(debt, units, minCoverageWad, unitScale);
    mathint exact = minCoverageWad * debt * unitScale;
    mathint den = units * 1000000000000000000;
    assert t * den >= exact, "the trigger rounded down, arming later than the debt requires";
    assert (t - 1) * den < exact, "the trigger rounded up by a whole tick or more";
}

// ---- the fee and its bound ----

// "that single rounding is what bounds the fee by the principal" -- under the genesis rail feeFundable
rule theFeeStaysWithinItsShareOfThePrincipal(uint256 principal, uint64 tenor, uint256 baseBps, uint64 minTenor) {
    require minTenor > 0;
    require feeFundable(baseBps, tenor, minTenor);
    mathint fee = originationFee(principal, tenor, baseBps, minTenor);
    assert fee * 10000 <= principal * MAX_FEE_SHARE() + 10000, "the fee passed MAX_FEE_SHARE of the principal by more than a wei";
    assert fee <= to_mathint(principal) || principal == 0, "the fee exceeded the principal it prices";
}

// "At maxTenor it bounds every shorter term too, because the fee is monotone in tenor."
rule theFeeIsMonotoneInTenor(uint256 principal, uint64 t1, uint64 t2, uint256 baseBps, uint64 minTenor) {
    require minTenor > 0 && t1 <= t2;
    assert originationFee(principal, t1, baseBps, minTenor) <= originationFee(principal, t2, baseBps, minTenor),
        "a longer term priced cheaper";
}

// ---- the inverse ----

// "EXACT against originationFee: the derived draw's payout IS owed, never a wei over."
rule theInverseIsExact(uint256 owed, uint64 tenor, uint256 baseBps, uint64 minTenor) {
    require minTenor > 0;
    require feeFundable(baseBps, tenor, minTenor);
    uint256 p = principalForOwed(owed, tenor, baseBps, minTenor);
    assert p - originationFee(p, tenor, baseBps, minTenor) == to_mathint(owed), "the derived draw's payout is not exactly owed";
}

// "The smallest draw whose payout still clears owed": one less and the payout falls short
rule theInverseIsTheSmallestDraw(uint256 owed, uint64 tenor, uint256 baseBps, uint64 minTenor) {
    require minTenor > 0 && owed > 0;
    require feeFundable(baseBps, tenor, minTenor);
    uint256 p = principalForOwed(owed, tenor, baseBps, minTenor);
    require p > 0;
    assert (p - 1) - originationFee(require_uint256(p - 1), tenor, baseBps, minTenor) < to_mathint(owed),
        "a smaller draw would also have cleared owed";
}

// "It implies d - n > 0" -- asserted on the arithmetic itself, because the ceilMulDiv summary PRUNES a zero divisor,
// so the no-revert rule below cannot see the one revert this claim exists to rule out
rule fundableMeansTheInverseDenominatorIsPositive(uint256 baseBps, uint64 tenor, uint64 minTenor) {
    require minTenor > 0;
    require feeFundable(baseBps, tenor, minTenor);
    mathint d = 10000 * 10000 * minTenor;
    mathint n = baseBps * tenor * (10000 + SHARE());
    assert d - n > 0, "a fundable term left the inverse a zero or negative denominator";
}

// and the subtraction itself never underflows on a fundable term (the divisor's positivity is the rule above)
rule fundableMeansTheInverseNeverUnderflows(uint256 owed, uint64 tenor, uint256 baseBps, uint64 minTenor) {
    require minTenor > 0;
    require owed < 2^200; // the quotient owed*d/(d-n) stays far inside 256 bits
    require feeFundable(baseBps, tenor, minTenor);
    principalForOwed@withrevert(owed, tenor, baseBps, minTenor);
    assert !lastReverted, "a fundable term still reverted the inverse";
}
