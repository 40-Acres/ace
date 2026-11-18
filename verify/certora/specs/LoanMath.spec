// LoanMath: the fee chain's rounding, checked against what its own comments claim.
//
// `FullMath.mulDivRoundingUp` is modelled EXACTLY -- ceil(a*b/d) in unbounded integers, with the two cases where the
// real routine reverts (a zero divisor, a quotient past 256 bits) pruned. Uniswap's implementation of that
// definition is taken as correct; what is checked is that LoanMath's formulas, built on it, round the way they say.
//
// The constants are Constants.sol's: PROTOCOL_SHARE_BPS = 1000, REBATE_PHI_BPS = 5000, MAX_FEE_SHARE_BPS = 2500,
// SECONDS_PER_YEAR = 31536000 (the rate is bps a year) and MIN_LENDER_APR_BPS = 1.

methods {
    function FullMath.mulDivRoundingUp(uint256 a, uint256 b, uint256 d) internal returns (uint256) => ceilMulDiv(a, b, d);

    function triggerPrice(uint256, uint256, uint256, uint256) external returns (uint256) envfree;
    function originationFee(uint256, uint64, uint256) external returns (uint256) envfree;
    function protocolCut(uint256) external returns (uint256) envfree;
    function lenderCut(uint256) external returns (uint256) envfree;
    function escrowCut(uint256) external returns (uint256) envfree;
    function tickCut(uint256) external returns (uint256) envfree;
    function feeFundable(uint256, uint64) external returns (bool) envfree;
}

function ceilMulDiv(uint256 a, uint256 b, uint256 d) returns uint256 {
    require d != 0;
    mathint p = a * b;
    mathint q = p % d == 0 ? p / d : p / d + 1;
    return require_uint256(q);
}

definition SHARE() returns mathint = 1000;
definition MAX_FEE_SHARE() returns mathint = 2500;
definition YEAR() returns mathint = 31536000;

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
rule theFeeStaysWithinItsShareOfThePrincipal(uint256 principal, uint64 tenor, uint256 lenderAprBps) {
    require feeFundable(lenderAprBps, tenor);
    mathint fee = originationFee(principal, tenor, lenderAprBps);
    assert fee * 10000 <= principal * MAX_FEE_SHARE() + 10000, "the fee passed MAX_FEE_SHARE of the principal by more than a wei";
    assert fee <= to_mathint(principal) || principal == 0, "the fee exceeded the principal it prices";
}

// "At maxTenor it bounds every shorter term too, because the fee is monotone in tenor."
rule theFeeIsMonotoneInTenor(uint256 principal, uint64 t1, uint64 t2, uint256 lenderAprBps) {
    require t1 <= t2;
    assert originationFee(principal, t1, lenderAprBps) <= originationFee(principal, t2, lenderAprBps),
        "a longer term priced cheaper";
}

// "Division form, exact for integers: r <= floor(A / B) iff r * B <= A" -- for every rate, with no product of r taken
// Called @withrevert, so a mutant dropping the `tenor == 0` guard (a division by zero) fails here rather than being pruned.
rule feeFundableIsExact(uint256 lenderAprBps, uint64 tenor) {
    bool fundable = feeFundable@withrevert(lenderAprBps, tenor);
    assert !lastReverted, "the rail reverted instead of answering";
    assert fundable <=> (tenor != 0 && lenderAprBps * tenor * (10000 + SHARE()) <= MAX_FEE_SHARE() * 10000 * YEAR()),
        "the rail is not the exact share bound on rate times term";
}

// "With r, P and T all at least 1, the round-up keeps the fee at least 1 atom and the lender's immediate share at least 1."
rule theFeeAndTickCutAreNeverZero(uint256 principal, uint64 tenor, uint256 lenderAprBps) {
    require principal >= 1 && tenor >= 1 && lenderAprBps >= 1;
    mathint fee = originationFee(principal, tenor, lenderAprBps);
    assert fee >= 1, "a priced draw paid no fee";
    assert tickCut(require_uint256(fee)) >= 1, "the lender's immediate share rounded to zero";
}
