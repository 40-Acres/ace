// Ace hub -- O4, the lent leg: a lender pool's `lent` is exactly the sum of the claims its markets hold, pooled and per
// collateral.
//
// A pool is one lender's in one quote, `pools[lender][quote]`, and every market naming that pair draws on it. The hub
// moves `lent` at three sites, each through `LoanAccounting.addLent` or `subLent` and paired with the same pool's claim
// by the same amount: the draw, the melt and settlement. The same three sites write
// `byCollateral[lender][quote][collateral].lent`, which must equal the sum of the claims of the markets naming that triple.
//
// THE BOOKS ARE `usum`s OVER ONE GHOST, `claimIn`, which files every claim under its market's lender, quote and
// collateral as mirrored from storage; `aClaimIsFiledUnderItsPool` ties each filed entry to the claim in storage. The
// prover knows a `usum` is at least every entry, so a book covers each claim filed under it. A hand-kept accumulator
// cannot show that, and the per-collateral `subLent` SATURATES rather than reverting: with one, the prover began a melt
// from a claim larger than its whole triple's book and floored `lent`, an unreachable start the pooled leg escapes only
// because its subtraction is checked.
//
// O4 PER LOAN, the form O51 and its liveness siblings require (`marketLentOf(m) >= loanClaimOf(id)`), is the state lemma
// `lentCoversEachClaim`: no induction, just the invariants in a state where they hold, which is every reachable one.
//
// LANE RULES: every `usum` sits inside a `forall`, since one at concrete keys crashes the prover; a rule leaning on a
// quantified fact names every key of the entry it needs; a sum's starting value is its own `init_state` axiom, never
// derived from its entries'.
//
// The hooks reach the hub's ERC-7201 roots through `AceStorageLink`. Three MIRROR WITNESSES below check that the claim
// hook and both `lent` hooks see every write each verb makes, as HubHookProbe.spec does for the revenue pot.

import "HubLoans.spec";

methods {
    function claimInMarket(bytes32, uint256) external returns (uint256) envfree; // AceHarness
    function marketLentOf(bytes32) external returns (uint256) envfree; // AceHarness
    function marketLentByCollateralOf(bytes32) external returns (uint256) envfree; // AceHarness
    function marketRestingPoolOf(bytes32) external returns (uint256) envfree; // AceHarness
    function restingOf(bytes32) external returns (uint256) envfree; // Ace: the market's own `cash`
}

// ---- each market's pool, mirrored from its write-once params ----

persistent ghost mapping(bytes32 => address) lenderOf {
    init_state axiom forall bytes32 m. lenderOf[m] == 0;
}
persistent ghost mapping(bytes32 => address) quoteOf {
    init_state axiom forall bytes32 m. quoteOf[m] == 0;
}
persistent ghost mapping(bytes32 => address) collOf {
    init_state axiom forall bytes32 m. collOf[m] == 0;
}

hook Sstore currentContract.markets.byId[KEY bytes32 m].p.lender address v {
    lenderOf[m] = v;
}
hook Sload address v currentContract.markets.byId[KEY bytes32 m].p.lender {
    require lenderOf[m] == v;
}
hook Sstore currentContract.markets.byId[KEY bytes32 m].p.quote address v {
    quoteOf[m] = v;
}
hook Sload address v currentContract.markets.byId[KEY bytes32 m].p.quote {
    require quoteOf[m] == v;
}
hook Sstore currentContract.markets.byId[KEY bytes32 m].p.collateral address v {
    collOf[m] = v;
}
hook Sload address v currentContract.markets.byId[KEY bytes32 m].p.collateral {
    require collOf[m] == v;
}

// ---- the claims, filed under their pool, and `lent` ----

persistent ghost mapping(bytes32 => mapping(uint256 => uint256)) claimOf {
    init_state axiom forall bytes32 m. forall uint256 i. claimOf[m][i] == 0;
}
// claimIn[lender][quote][collateral][market][loan]: the claim, filed under its market's triple and zero under any other.
// The sums start at zero by their own axioms, sound since every entry does.
persistent ghost mapping(address => mapping(address => mapping(address => mapping(bytes32 => mapping(uint256 => uint256))))) claimIn {
    init_state axiom forall address l. forall address q. forall address c. forall bytes32 m. forall uint256 i. claimIn[l][q][c][m][i] == 0;
    init_state axiom forall address l. forall address q. (usum address c, bytes32 m, uint256 i. claimIn[l][q][c][m][i]) == 0;
    init_state axiom forall address l. forall address q. forall address c. (usum bytes32 m, uint256 i. claimIn[l][q][c][m][i]) == 0;
}
persistent ghost mapping(address => mapping(address => uint256)) lentOf {
    init_state axiom forall address l. forall address q. lentOf[l][q] == 0;
}
persistent ghost mapping(address => mapping(address => mapping(address => uint256))) lentCOf {
    init_state axiom forall address l. forall address q. forall address c. lentCOf[l][q][c] == 0;
}

// the witnesses' mirrors, `claimSeen` and `lentSeen`, are written by the store hooks ONLY: no load hook pins them to
// storage, so a write the hook missed shows as a mismatch rather than being assumed away
persistent ghost mapping(bytes32 => mapping(uint256 => uint256)) claimSeen;
persistent ghost mapping(address => mapping(address => uint256)) lentSeen;
persistent ghost mapping(address => mapping(address => mapping(address => uint256))) lentCSeen;

hook Sstore currentContract.markets.byId[KEY bytes32 m].claim[KEY uint256 i] uint256 v {
    claimIn[lenderOf[m]][quoteOf[m]][collOf[m]][m][i] = v;
    claimOf[m][i] = v;
    claimSeen[m][i] = v;
}
hook Sload uint256 v currentContract.markets.byId[KEY bytes32 m].claim[KEY uint256 i] {
    require claimOf[m][i] == v;
}
hook Sstore currentContract.lenders.pools[KEY address l][KEY address q].lent uint256 v {
    lentOf[l][q] = v;
    lentSeen[l][q] = v;
}
hook Sload uint256 v currentContract.lenders.pools[KEY address l][KEY address q].lent {
    require lentOf[l][q] == v;
}
hook Sstore currentContract.lenders.byCollateral[KEY address l][KEY address q][KEY address c].lent uint256 v {
    lentCOf[l][q][c] = v;
    lentCSeen[l][q][c] = v;
}
hook Sload uint256 v currentContract.lenders.byCollateral[KEY address l][KEY address q][KEY address c].lent {
    require lentCOf[l][q][c] == v;
}

// ---- the books: read ONLY with their keys bound by a `forall` ----

// the pool's book: every claim filed under its lender and quote, across collaterals
definition poolBook(address l, address q) returns mathint = usum address c, bytes32 m, uint256 i. claimIn[l][q][c][m][i];

// the triple's book
definition tripleBook(address l, address q, address c) returns mathint = usum bytes32 m, uint256 i. claimIn[l][q][c][m][i];

// ---- O4, the lent leg ----

// an uncreated market holds no claim, so creating one moves nothing into its pool's sum
invariant anUncreatedMarketHoldsNoClaim()
    forall bytes32 m. forall uint256 i. quoteOf[m] == 0 => claimOf[m][i] == 0
    filtered { f -> freshIdVerb(f) }
    { preserved with (env e) { require e.msg.sender != currentContract; } }

// every claim sits under its market's own triple and nowhere else; a market's triple is written once, at creation, when
// it holds no claim, so no filed claim is ever left under a stale key
invariant aClaimIsFiledUnderItsPool()
    forall address l. forall address q. forall address c. forall bytes32 m. forall uint256 i.
        claimIn[l][q][c][m][i] == ((l == lenderOf[m] && q == quoteOf[m] && c == collOf[m]) ? claimOf[m][i] : 0)
    filtered { f -> freshIdVerb(f) }
    {
        preserved with (env e) {
            require e.msg.sender != currentContract;
            requireInvariant anUncreatedMarketHoldsNoClaim();
        }
    }

// O4 pooled: the pool's `lent` is the pool's claim book
invariant lentIsTheClaimBook()
    forall address l. forall address q. to_mathint(lentOf[l][q]) == poolBook(l, q)
    filtered { f -> freshIdVerb(f) }
    {
        preserved with (env e) {
            require e.msg.sender != currentContract;
            requireInvariant anUncreatedMarketHoldsNoClaim();
            requireInvariant aClaimIsFiledUnderItsPool();
        }
    }

// O4 per collateral: the triple's `lent` is the triple's claim book
invariant lentByCollateralIsTheClaimBook()
    forall address l. forall address q. forall address c. to_mathint(lentCOf[l][q][c]) == tripleBook(l, q, c)
    filtered { f -> freshIdVerb(f) }
    {
        preserved with (env e) {
            require e.msg.sender != currentContract;
            requireInvariant anUncreatedMarketHoldsNoClaim();
            requireInvariant aClaimIsFiledUnderItsPool();
        }
    }

// O4 PER LOAN, a STATE LEMMA: a market's pool's `lent` covers each claim the market holds. Sum-free, so a spec that
// cannot carry a `usum` at concrete keys can require it; `marketLentOf(m) >= loanClaimOf(id)` is its instance at the
// loan's own market and id, since `loanClaimOf(id)` reads `claimInMarket(loanMarket(id), id)`
rule lentCoversEachClaim(bytes32 m, uint256 i) {
    requireInvariant aClaimIsFiledUnderItsPool();
    requireInvariant lentIsTheClaimBook();
    // NAME the claim's filed entry, an instance of the invariant above: nothing else here names the market's collateral
    require claimIn[lenderOf[m]][quoteOf[m]][collOf[m]][m][i] == claimOf[m][i];
    assert marketLentOf(m) >= claimInMarket(m, i), "a pool's lent fell under a claim filed under it";
}

// and per collateral: the triple's `lent` covers each of its claims, so `subLent`'s saturating step, which retires at
// most a claim, never floors on a reachable state and the split retires exactly what the pool does
rule lentByCollateralCoversEachClaim(bytes32 m, uint256 i) {
    requireInvariant aClaimIsFiledUnderItsPool();
    requireInvariant lentByCollateralIsTheClaimBook();
    // NAME the claim's filed entry, as above
    require claimIn[lenderOf[m]][quoteOf[m]][collOf[m]][m][i] == claimOf[m][i];
    assert marketLentByCollateralOf(m) >= claimInMarket(m, i), "a triple's lent fell under a claim filed under it";
}

// ---- O4, the cash leg: a pool's `resting` is the sum of its markets' `cash` ----
//
// The same money is booked twice: each market's `cash`, and its lender's pooled `resting` in that quote. The three sites
// that move them (`Lender.creditCash`, `Lender.debitCash`, and `Borrower`'s draw, which inlines the debit) move both by
// the same amount. `HubSolvency.spec` books `cash` and leaves `resting` out as the same money; this is the sentence that
// makes that sound. Built as the lent leg is: `cashIn` files each market's cash under its lender and quote, and the pool's
// book is a `usum` over it (#759: a mutant over-crediting `resting` survived every prover rule until this one).

persistent ghost mapping(bytes32 => uint256) cashOf {
    init_state axiom forall bytes32 m. cashOf[m] == 0;
}
// cashIn[lender][quote][market]: the market's cash, filed under its pool and zero under any other
persistent ghost mapping(address => mapping(address => mapping(bytes32 => uint256))) cashIn {
    init_state axiom forall address l. forall address q. forall bytes32 m. cashIn[l][q][m] == 0;
    init_state axiom forall address l. forall address q. (usum bytes32 m. cashIn[l][q][m]) == 0;
}
persistent ghost mapping(address => mapping(address => uint256)) restingPool {
    init_state axiom forall address l. forall address q. restingPool[l][q] == 0;
}
// store-only mirrors for the witnesses, as `claimSeen` and `lentSeen` above
persistent ghost mapping(bytes32 => uint256) cashSeen;
persistent ghost mapping(address => mapping(address => uint256)) restingSeen;

hook Sstore currentContract.markets.byId[KEY bytes32 m].s.cash uint256 v {
    cashIn[lenderOf[m]][quoteOf[m]][m] = v;
    cashOf[m] = v;
    cashSeen[m] = v;
}
hook Sload uint256 v currentContract.markets.byId[KEY bytes32 m].s.cash {
    require cashOf[m] == v;
}
hook Sstore currentContract.lenders.pools[KEY address l][KEY address q].resting uint256 v {
    restingPool[l][q] = v;
    restingSeen[l][q] = v;
}
hook Sload uint256 v currentContract.lenders.pools[KEY address l][KEY address q].resting {
    require restingPool[l][q] == v;
}

// the pool's cash book, read ONLY with its keys bound by a `forall`
definition cashBook(address l, address q) returns mathint = usum bytes32 m. cashIn[l][q][m];

// an uncreated market holds no cash, so creating one moves nothing into its pool's book
invariant anUncreatedMarketHoldsNoCash()
    forall bytes32 m. quoteOf[m] == 0 => cashOf[m] == 0
    filtered { f -> freshIdVerb(f) }
    { preserved with (env e) { require e.msg.sender != currentContract; } }

// every market's cash sits under its own lender and quote and nowhere else
invariant aCashIsFiledUnderItsPool()
    forall address l. forall address q. forall bytes32 m.
        cashIn[l][q][m] == ((l == lenderOf[m] && q == quoteOf[m]) ? cashOf[m] : 0)
    filtered { f -> freshIdVerb(f) }
    {
        preserved with (env e) {
            require e.msg.sender != currentContract;
            requireInvariant anUncreatedMarketHoldsNoCash();
        }
    }

// O4's cash leg: a lender's pooled `resting` in a quote is the sum of its markets' `cash` in it
invariant restingIsTheCashBook()
    forall address l. forall address q. to_mathint(restingPool[l][q]) == cashBook(l, q)
    filtered { f -> freshIdVerb(f) }
    {
        preserved with (env e) {
            require e.msg.sender != currentContract;
            requireInvariant anUncreatedMarketHoldsNoCash();
            requireInvariant aCashIsFiledUnderItsPool();
        }
    }

// ---- ANTI-HOLLOW: the hooks see every claim and `lent` write a verb makes ----

rule theClaimHookSeesEveryWrite(env e, method f, calldataarg args, bytes32 m, uint256 i) filtered { f -> freshIdVerb(f) } {
    require claimSeen[m][i] == claimInMarket(m, i);
    f(e, args);
    assert claimSeen[m][i] == claimInMarket(m, i), "a claim write slipped past the hook";
}

rule theLentHookSeesEveryWrite(env e, method f, calldataarg args, bytes32 m) filtered { f -> freshIdVerb(f) } {
    address l = lenderOf[m];
    address q = quoteOf[m];
    require marketQuoteOf(m) != 0; // a created market: its pool is fixed, where `createMarket` would re-point it
    require lentSeen[l][q] == marketLentOf(m); // the read loads the market's lender and quote, pinning `l` and `q`
    f(e, args);
    assert lentSeen[l][q] == marketLentOf(m), "a lent write slipped past the hook";
}

rule theCollateralLentHookSeesEveryWrite(env e, method f, calldataarg args, bytes32 m) filtered { f -> freshIdVerb(f) } {
    address l = lenderOf[m];
    address q = quoteOf[m];
    address c = collOf[m];
    require marketQuoteOf(m) != 0; // a created market: its triple is fixed, where `createMarket` would re-point it
    require lentCSeen[l][q][c] == marketLentByCollateralOf(m); // the read loads the market's lender, quote and collateral
    f(e, args);
    assert lentCSeen[l][q][c] == marketLentByCollateralOf(m), "a per-collateral lent write slipped past the hook";
}

rule theCashHookSeesEveryWrite(env e, method f, calldataarg args, bytes32 m) filtered { f -> freshIdVerb(f) } {
    require cashSeen[m] == restingOf(m);
    f(e, args);
    assert cashSeen[m] == restingOf(m), "a cash write slipped past the hook";
}

rule theRestingHookSeesEveryWrite(env e, method f, calldataarg args, bytes32 m) filtered { f -> freshIdVerb(f) } {
    address l = lenderOf[m];
    address q = quoteOf[m];
    require marketQuoteOf(m) != 0; // a created market: its pool is fixed, where `createMarket` would re-point it
    require restingSeen[l][q] == marketRestingPoolOf(m); // the read loads the market's lender and quote, pinning `l` and `q`
    f(e, args);
    assert restingSeen[l][q] == marketRestingPoolOf(m), "a resting write slipped past the hook";
}

// the cash book is not vacuous: a deposit raises its market's cash, the entry the book sums over
rule aDepositFilesItsCash(env e, bytes32 id, uint256 assets) {
    require cashIn[lenderOf[id]][quoteOf[id]][id] == cashOf[id];
    uint256 before = cashOf[id];
    deposit(e, id, assets);
    satisfy cashIn[lenderOf[id]][quoteOf[id]][id] > before;
}

// and the books are not vacuous: a draw files its claim under its market's triple, the entry BOTH books sum over. Read
// as an entry, not a sum: a `usum` at concrete keys crashes the prover.
rule anOpenFilesItsClaim(env e, bytes32 id, uint256 units, uint256 principal, uint64 tenor, address borrower, AceHarness.OpenBounds bnd) {
    uint256 fresh = require_uint256(idCount() + 1);
    require claimIn[lenderOf[id]][quoteOf[id]][collOf[id]][id][fresh] == 0;
    open(e, id, units, principal, tenor, borrower, bnd);
    satisfy claimIn[lenderOf[id]][quoteOf[id]][collOf[id]][id][fresh] > 0;
}
