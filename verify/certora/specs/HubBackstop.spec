// Ace hub -- O51: `forceClose` must execute. No dependency can leave a matured loan unsettleable.
//
// `forceClose` is the one settle verb at tenor. From a loan's expiry second it settles the loan whatever the record, the
// quote, the collateral, the lender or the treasury do, and only the caller's own gas limit can refuse it. It asks no roll
// policy (Extend.spec `forceCloseAsksNoPolicy`). BAND ON (#944, #945) it reads the record's price under the policy budget,
// and a DARK answer refuses until `SETTLE_DARK_GRACE` past expiry: that is the one refusal the rule admits, and a live
// answer inside the grace must still settle. The read is summarized as any answer, never reverting, recorded in persistent
// ghosts so the assert can see what a reverted call read; its gas floor is assumed met, as the push's is. Its other external calls are the custodian's
// `retireCustody` and the swallowed lender push; no revenue sweep rides it. Nothing else checks this: the fuzz handler
// swallows a refusal.
//
// A LIVENESS rule, so every premise is a refusal the property allows or a fact about reachable states, and NO summary
// may assume a call succeeds. That is why this spec is standalone rather than importing HubLoans.spec: an
// uninterpreted `mulDiv` both INVENTS reverts (it may return 2^256 - 1, which trips the real rounding guard) and HIDES
// them (a summary never reverts). Here each `mulDiv` is EXACT, and the two ways the real routine reverts -- a zero
// divisor and a result past 2^256 - 1 -- are ASSERTED at every call, so a `mulDiv` that would revert fails the rule.
//
// THE THREE STORAGE PREMISES the verb rests on (review R-4), each guarding a checked step on its path:
//   - O10, a live loan's claim is positive: settlement's earn credits the escrow over the claim, and reverts `NoClaims` on none;
//   - O4 per loan, the pool's `lent` covers the claim: `subLent` is a checked `-=`;
//   - O5, custody covers the loan's units: `retireCustody` is a checked `-=`.
// Each is required, not proven, in this scene: the specs proving them summarize `mulDiv`, which this one cannot import.

using PositionManagerHarness as pm;

methods {
    function FullMath.mulDiv(uint256 a, uint256 b, uint256 d) internal returns (uint256) => mulDivDownChecked(a, b, d);
    function FullMath.mulDivRoundingUp(uint256 a, uint256 b, uint256 d) internal returns (uint256) => mulDivUpChecked(a, b, d);

    function closedAtOf(uint256) external returns (uint64) envfree; // AceHarness
    function loanMarket(uint256) external returns (bytes32) envfree;
    function marketQuoteOf(bytes32) external returns (address) envfree; // AceHarness
    function loanExpiryOf(uint256) external returns (uint64) envfree; // AceHarness: forceClose's clock test
    function loanUnitsOf(uint256) external returns (uint256) envfree; // AceHarness
    function loanDebtOf(uint256) external returns (uint256) envfree; // AceHarness
    function loanClaimOf(uint256) external returns (uint256) envfree; // AceHarness
    function loanPotOf(uint256) external returns (uint256) envfree; // AceHarness
    function loanBorrowerOf(uint256) external returns (address) envfree; // AceHarness
    function unitsOwedOf(uint256, address) external returns (uint256) envfree; // AceHarness
    function feeEscrowOfLoan(uint256) external returns (uint256) envfree; // AceHarness
    function marketLentOf(bytes32) external returns (uint256) envfree; // AceHarness
    function marketOwedOf(bytes32) external returns (uint256) envfree; // AceHarness
    function marketTotalsOf(bytes32) external returns (uint256, uint256) envfree; // AceHarness
    function marketRailsOf(bytes32) external returns (uint256, uint256, uint256) envfree; // AceHarness
    function marketSettleBountyBpsOf(bytes32) external returns (uint256) envfree; // AceHarness
    function marketBandBpsOf(bytes32) external returns (uint256) envfree; // AceHarness

    function settleDarkGrace() external returns (uint256) envfree; // AceHarness: Constants.SETTLE_DARK_GRACE

    // the band-on settlement's record read: any answer, never reverting, RECORDED; the gas floor before it is assumed met
    function Borrower.cappedPrice(AceHarness.Cfg memory c) internal returns (bool, uint256) => readAsked();
    function marketUnsoldUnitsOf(bytes32) external returns (uint256) envfree; // AceHarness
    function marketPotCountsOf(bytes32) external returns (uint256, uint256) envfree; // AceHarness
    function notEntered() external returns (bool) envfree;
    function PUSH_FLOOR() external returns (uint256) envfree;
    function pm.collateralOf(uint256) external returns (uint256) envfree;
    function pm.retiredOf(uint256) external returns (uint256) envfree;
    function pm.notEntered() external returns (bool) envfree; // PositionManagerHarness

    // via-IR hides both the callee and the selector of the custodian call, so a signature summary never matches; the
    // dispatch runs the real custodian (its loan-manager and custody checks included) and the hub's own push self-call,
    // which the lender push makes. Any OTHER unresolved call takes the default, which assumes it
    // succeeds, so the call-resolution report is read for them: a liveness proof is only as good as that list.
    unresolved external in _._ => DISPATCH [
        pm.retireCustody(uint256,uint256),
        currentContract.pushToken(address,address,uint256)
    ] default NONDET;
}

function mulDivDownChecked(uint256 a, uint256 b, uint256 d) returns uint256 {
    assert d != 0, "a mulDiv on the settle path divides by zero";
    mathint r = (a * b) / d;
    assert r <= max_uint256, "a mulDiv on the settle path overflows";
    return require_uint256(r);
}

function mulDivUpChecked(uint256 a, uint256 b, uint256 d) returns uint256 {
    assert d != 0, "a mulDivRoundingUp on the settle path divides by zero";
    mathint r = (a * b + d - 1) / d;
    assert r <= max_uint256, "a mulDivRoundingUp on the settle path overflows";
    return require_uint256(r);
}

// the band-on read, RECORDED in persistent ghosts so a reverted call still says what it read
persistent ghost bool readSeen;
persistent ghost bool readOk;
persistent ghost uint256 readWord;

function readAsked() returns (bool, uint256) {
    bool ok; uint256 w;
    readSeen = true;
    readOk = ok;
    readWord = w;
    return (ok, w);
}

// THE ONE ALLOWED REFUSAL is a caller whose gas limit leaves less than the push's floor (`PushGasShort`). The prover
// reads `gasleft()` as arbitrary, so every read is held at or above that floor: a caller who sends enough gas.
persistent ghost uint256 pushFloor;
hook GAS uint256 g {
    require g >= pushFloor;
}

// O51: an issued live loan, from its expiry second, settles: the call completes, and it closes the loan
rule forceCloseMustExecute(env e, uint256 id) {
    require pushFloor == PUSH_FLOOR();
    require e.msg.value == 0 && notEntered() && pm.notEntered(); // not payable; a transaction starts both guards clear
    require loanMarket(id) != to_bytes32(0) && closedAtOf(id) == 0; // an issued loan, live
    require marketQuoteOf(loanMarket(id)) != 0;                     // in a created market
    require to_mathint(e.block.timestamp) >= to_mathint(loanExpiryOf(id));
    require e.block.timestamp > 0 && e.block.timestamp < 2^64;     // the chain's clock: a close stamps a nonzero uint64
    bytes32 m = loanMarket(id);
    require !readSeen; // no read yet in this transaction
    // SCAFFOLDING, each to be replaced by a proven fact before this rule counts:
    require loanClaimOf(id) == loanDebtOf(id) && loanDebtOf(id) > 0; // O10: the claim is the debt, and positive
    require marketLentOf(m) >= loanClaimOf(id);                      // O4 per loan: the pool's lent covers the claim
    require pm.collateralOf(id) >= loanUnitsOf(id);                  // O5: custody covers the loan's units
    uint256 cover; uint256 scale; uint256 price;
    cover, scale, price = marketRailsOf(m);
    require cover >= 105 * 10^16 && cover <= 20 * 10^18 && scale == 2^96 && price > 0 && price <= 2^224; // O56: the rails hold
    require marketSettleBountyBpsOf(m) <= 200; // O56: genesis caps the sliver at MAX_SETTLE_BOUNTY_BPS, and params never change
    // THE DOMAIN, stated: a loan's amounts fit in 128 bits (the hub narrows cash into a uint128), and a running total
    // sits under 2^255, so no one addition below can overflow. The prover's arbitrary state starts a total anywhere.
    uint256 burns; uint256 loss;
    burns, loss = marketTotalsOf(m);
    require loanDebtOf(id) < 2^128 && loanUnitsOf(id) < 2^128 && feeEscrowOfLoan(id) < 2^128;
    require marketOwedOf(m) < 2^255 && burns < 2^255 && loss < 2^255;
    require unitsOwedOf(id, loanBorrowerOf(id)) < 2^255 && unitsOwedOf(id, e.msg.sender) < 2^255 && pm.retiredOf(id) < 2^255;
    // the pot grows twice (the spread, then the give) before the unsold units take it whole, hence 2^254 for both
    uint256 unsoldPots; uint256 settledPots;
    unsoldPots, settledPots = marketPotCountsOf(m);
    require loanPotOf(id) < 2^254 && marketUnsoldUnitsOf(m) < 2^254 && unsoldPots < 2^127 && settledPots < 2^127;
    bool bandOn = marketBandBpsOf(m) != 0; // read BEFORE the call: a later call resets lastReverted
    mathint graceEnd = to_mathint(loanExpiryOf(id)) + to_mathint(settleDarkGrace());
    forceClose@withrevert(e, id);
    bool refused = lastReverted;
    // THE ONE ALLOWED WAIT: a band-on market whose record read DARK holds the door until SETTLE_DARK_GRACE past expiry; a
    // live read inside the grace must still settle
    bool darkWait = bandOn && readSeen && (!readOk || readWord == 0) && to_mathint(e.block.timestamp) < graceEnd;
    assert !refused || darkWait, "forceClose refused a matured loan";
    assert !refused => closedAtOf(id) != 0, "forceClose returned without closing the loan";
}
