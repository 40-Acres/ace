// ExtendAskOrder: the rules of Extend.spec that read WHEN the hub writes against when it asks the lender's roll policy --
// obligation O72b's "before any write" leg, and the refusals O72 and the refinance gate state as "before any write or ask".
//
// WHY A SEPARATE CONF: "no write before the ask" is read off a RAW store hook, `ALL_SSTORE`, which sees every slot the hub
// writes, packed or not; the reentrancy guard is transient and never reaches it. The prover refuses that hook unless storage
// splitting is off, and with it off Extend.spec's frame rules (`aLoansTenorNeverMoves`, `theTermIdentityHolds`) were
// UNKNOWN at four hours. So the hook and every rule reading it live here, under splitting off, and Extend.conf keeps it on.
// `theStoreHookSeesAnExtensionsWrites` is the hook's witness.
//
// Everything else (the summaries, the token model, the scene, the policy-ask record) is Extend.spec's, imported, and its
// header says why each summary admits every real behaviour. This conf names its rules, so none of Extend.spec's runs here.

import "Extend.spec";

persistent ghost bool wroteBeforeAsk;
persistent ghost bool wroteAfterAsk;

// every persistent-storage write the hub's own code makes, split at the first ask
hook ALL_SSTORE(uint256 loc, uint256 v) {
    if (executingContract == currentContract) {
        if (asked) {
            wroteAfterAsk = true;
        } else {
            wroteBeforeAsk = true;
        }
    }
}

function nothingWrittenYet() {
    require !wroteBeforeAsk && !wroteAfterAsk;
}

// THE SAME SECOND: where the loan's own tenor from now ends where it already does, `now == expiry - tenor`, the extension
// adds no time and refuses before any write or policy ask; a top-up's re-anchor moves the open second, never the expiry
rule aSameSecondExtensionRefuses(env e, uint256 id, uint256 minBufferWad, bytes data) {
    sceneHolds(e, id);
    requireInvariant theTermIdentityHolds(id);
    require to_mathint(e.block.timestamp) == to_mathint(loanExpiry(id)) - to_mathint(loanTenor(id));
    nothingAskedYet();
    nothingWrittenYet();

    extend@withrevert(e, id, minBufferWad, data);

    assert lastReverted, "an extension adding no time landed";
    assert !asked && !wroteBeforeAsk, "an extension adding no time asked a policy or wrote";
}

// FROM EXPIRY: a matured loan's extension refuses, `LoanMatured`, before any write or policy ask; `forceClose` then settles it
rule anExtensionRefusesFromExpiry(env e, uint256 id, uint256 minBufferWad, bytes data) {
    sceneHolds(e, id);
    require to_mathint(e.block.timestamp) >= to_mathint(loanExpiry(id));
    nothingAskedYet();
    nothingWrittenYet();

    extend@withrevert(e, id, minBufferWad, data);

    assert lastReverted, "an extension landed from the loan's expiry";
    assert !asked && !wroteBeforeAsk, "a matured loan's extension asked a policy or wrote";
}

// NO WRITE BEFORE THE ANSWER: every leg before the ask only reads, so the policy sees the loan as it stands, and a refusal,
// which reverts there, leaves storage as it was
rule anExtensionWritesNothingBeforeItsPolicyAnswers(env e, uint256 id, uint256 minBufferWad, bytes data) {
    sceneHolds(e, id);
    nothingAskedYet();
    nothingWrittenYet();

    extend(e, id, minBufferWad, data);

    assert !wroteBeforeAsk, "an extension wrote storage before its lender's policy answered";
}

// ANTI-HOLLOW for the store hook: an extension's writes land after the ask, and the hook sees them
rule theStoreHookSeesAnExtensionsWrites(env e, uint256 id, uint256 minBufferWad, bytes data) {
    sceneHolds(e, id);
    nothingAskedYet();
    nothingWrittenYet();
    extend(e, id, minBufferWad, data);
    satisfy wroteAfterAsk;
}

// THE REFINANCE GATE: from the expiry second a refinance refuses `LoanMatured`, into any market, before any write and any
// policy ask, so a matured live loan leaves only by repay, forceClose, or finalize on persisted distress
rule aMaturedLoanNeverRefinances(env e, ExtendHarness.MigrateArgs a) {
    sceneHolds(e, a.id);
    require to_mathint(e.block.timestamp) >= to_mathint(loanExpiry(a.id));
    nothingAskedYet();
    nothingWrittenYet();

    refinanceTo@withrevert(e, a);

    assert lastReverted, "a matured loan refinanced";
    assert !asked && !wroteBeforeAsk, "a matured loan's refinance asked a policy or wrote";
}

// the policy is asked only when the refinance stays in the loan's own market, of its stored policy with POLICY_GAS and before
// any write; on its yes the successor draws only what the retiring claim does not recycle, and otherwise its whole
// principal. Anyone may create a market naming any lender, so another market, the same lender's included, draws it all
rule aRefinanceReusesTheClaimOnlyOnItsLendersYes(env e, ExtendHarness.MigrateArgs a) {
    sceneHolds(e, a.id);
    nothingAskedYet();
    nothingWrittenYet();
    bytes32 src = homeOf(a.id);
    mathint claim0 = claimOf(src, a.id);
    mathint cash0 = cashIn(a.dst);
    bool inPlace = a.dst == src;
    address policy = rollPolicyOf(lenderIn(src));

    refinanceTo(e, a);

    mathint p = a.newPrincipal;
    mathint recycle = claim0 < p ? claim0 : p;
    assert asked => inPlace && askedOf == policy && askedGas == POLICY_GAS(), "a refinance asked a policy outside the loan's own market";
    assert !inPlace => to_mathint(cashIn(a.dst)) == cash0 - p, "a refinance reused a claim outside the loan's own market";
    assert asked => !wroteBeforeAsk, "a refinance wrote storage before its lender's policy answered";
    assert (asked && said) => to_mathint(cashIn(a.dst)) == cash0 - (p - recycle), "a reusing refinance drew other than the fresh rest";
    assert !(asked && said) => to_mathint(cashIn(a.dst)) == cash0 - p, "a refinance reused a claim without its lender's yes";
}
