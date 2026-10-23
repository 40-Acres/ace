// Ace hub -- O4, the lent leg: a lender pool's `lent` is exactly the sum of the claims its markets hold.
//
// A pool is one lender's in one quote, `pools[lender][quote]`, and every market naming that pair draws on it. The hub
// moves `lent` at three sites, each through `LoanAccounting.addLent` or `subLent` and paired with the same pool's claim
// by the same amount: the draw, the melt and settlement. O51 (the unpaid backstop) rests on the per-loan form,
// `lent >= claim`, since settlement subtracts the claim from the pool's `lent` checked: a sum of unsigned claims is at
// least any one of them. The per-collateral `lent` saturates instead, so O51 needs no premise on it.
//
// THE SUM is a ghost per pool, kept by a store hook on every claim, keyed by the market's lender and quote as mirrored
// from storage. The hooks reach the hub's ERC-7201 roots through `AceStorageLink`. Three MIRROR WITNESSES below check
// that the claim hook and both `lent` hooks see every write each verb makes, as HubHookProbe.spec does for the revenue pot.
//
// O4, PER COLLATERAL: the same three sites write `byCollateral[lender][quote][collateral].lent`, the market's own
// collateral mirrored as its lender and quote are, so a second claim book keyed by the triple must equal it too.
// That the triples sum to the pool follows by composition: one claim hook moves both books by the same delta.

import "HubLoans.spec";

methods {
    function claimInMarket(bytes32, uint256) external returns (uint256) envfree; // AceHarness
    function marketLentOf(bytes32) external returns (uint256) envfree; // AceHarness
    function marketLentByCollateralOf(bytes32) external returns (uint256) envfree; // AceHarness
}

// ---- each market's pool, mirrored from its write-once params ----

persistent ghost mapping(bytes32 => address) lenderOf {
    init_state axiom forall bytes32 m. lenderOf[m] == 0;
}
persistent ghost mapping(bytes32 => address) quoteOf {
    init_state axiom forall bytes32 m. quoteOf[m] == 0;
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
persistent ghost mapping(bytes32 => address) collOf {
    init_state axiom forall bytes32 m. collOf[m] == 0;
}
hook Sstore currentContract.markets.byId[KEY bytes32 m].p.collateral address v {
    collOf[m] = v;
}
hook Sload address v currentContract.markets.byId[KEY bytes32 m].p.collateral {
    require collOf[m] == v;
}

// ---- the claims, their per-pool sum, and `lent` ----

persistent ghost mapping(bytes32 => mapping(uint256 => uint256)) claimOf {
    init_state axiom forall bytes32 m. forall uint256 i. claimOf[m][i] == 0;
}
persistent ghost mapping(address => mapping(address => mathint)) claimBook {
    init_state axiom forall address l. forall address q. claimBook[l][q] == 0;
}
persistent ghost mapping(address => mapping(address => uint256)) lentOf {
    init_state axiom forall address l. forall address q. lentOf[l][q] == 0;
}
persistent ghost mapping(address => mapping(address => mapping(address => mathint))) claimBookC {
    init_state axiom forall address l. forall address q. forall address c. claimBookC[l][q][c] == 0;
}
persistent ghost mapping(address => mapping(address => mapping(address => uint256))) lentCOf {
    init_state axiom forall address l. forall address q. forall address c. lentCOf[l][q][c] == 0;
}

// the witnesses' mirrors, `claimSeen` and `lentSeen`, are written by the store hooks ONLY: no load hook pins them to
// storage, so a write the hook missed shows as a mismatch rather than being assumed away
persistent ghost mapping(bytes32 => mapping(uint256 => uint256)) claimSeen;
persistent ghost mapping(address => mapping(address => uint256)) lentSeen;
persistent ghost mapping(address => mapping(address => mapping(address => uint256))) lentCSeen;

hook Sstore currentContract.markets.byId[KEY bytes32 m].claim[KEY uint256 i] uint256 v (uint256 oldV) {
    claimBook[lenderOf[m]][quoteOf[m]] = claimBook[lenderOf[m]][quoteOf[m]] + v - oldV;
    claimBookC[lenderOf[m]][quoteOf[m]][collOf[m]] = claimBookC[lenderOf[m]][quoteOf[m]][collOf[m]] + v - oldV;
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

// ---- O4, the lent leg ----

// an uncreated market holds no claim, so creating one moves nothing into its pool's sum
invariant anUncreatedMarketHoldsNoClaim()
    forall bytes32 m. forall uint256 i. quoteOf[m] == 0 => claimOf[m][i] == 0
    filtered { f -> freshIdVerb(f) }
    { preserved with (env e) { require e.msg.sender != currentContract; } }

invariant lentIsTheClaimBook()
    forall address l. forall address q. to_mathint(lentOf[l][q]) == claimBook[l][q]
    filtered { f -> freshIdVerb(f) }
    {
        preserved with (env e) {
            require e.msg.sender != currentContract;
            requireInvariant anUncreatedMarketHoldsNoClaim();
        }
    }

// O4 per collateral: the triple's `lent` is the triple's claim book
invariant lentByCollateralIsTheClaimBook()
    forall address l. forall address q. forall address c. to_mathint(lentCOf[l][q][c]) == claimBookC[l][q][c]
    filtered { f -> freshIdVerb(f) }
    {
        preserved with (env e) {
            require e.msg.sender != currentContract;
            requireInvariant anUncreatedMarketHoldsNoClaim();
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

// and the sum is not vacuous: a draw does write a claim and `lent`
rule anOpenWritesTheBook(env e, bytes32 id, uint256 units, uint256 principal, uint64 tenor, address borrower, AceHarness.OpenBounds bnd) {
    mathint before = claimBook[lenderOf[id]][quoteOf[id]];
    open(e, id, units, principal, tenor, borrower, bnd);
    satisfy claimBook[lenderOf[id]][quoteOf[id]] > before;
}

// and the triple's book is not vacuous either: a draw writes the collateral's claim book
rule anOpenWritesTheCollateralBook(env e, bytes32 id, uint256 units, uint256 principal, uint64 tenor, address borrower, AceHarness.OpenBounds bnd) {
    mathint before = claimBookC[lenderOf[id]][quoteOf[id]][collOf[id]];
    open(e, id, units, principal, tenor, borrower, bnd);
    satisfy claimBookC[lenderOf[id]][quoteOf[id]][collOf[id]] > before;
}
