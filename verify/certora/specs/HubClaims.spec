// Ace hub -- O10: a loan's claim is its debt.
//
// One lender funds each loan, so the loan's claim in its market IS its debt: every write to one (the draw, a repay's
// melt, a deleverage melt, a migration's retire) writes the other by the same amount, an extension writes neither, and a
// close retires the claim. A live loan's debt is also positive: every loan's debt enters through `_preChecks`, which
// refuses a zero principal, a full repay closes the loan, and a deleverage restore leaves at least the debt floor, half
// `minPrincipal`, which genesis keeps positive: a crank whose restore would leave less sells the whole debt and closes. O51
// (`forceClose` must execute) rests on both halves: settlement credits the fee escrow over the claim and reverts NoClaims
// on a retired one. Dues mode, under which this read `debt == claim + dues` (O71), is deleted.
//
// DELEVERAGE IS PROVEN IN HubClaimsExact.spec, not here. Its positive-debt leg rests on the close decision, which compares
// the debt with the floor plus a ceiled bill, and this spec's `mulDiv` is uninterpreted: with it, the old `room` cap came
// back past 2^128 on a head of one.

import "HubLoans.spec";

methods {
    function loanDebtOf(uint256) external returns (uint256) envfree; // AceHarness
    function loanClaimOf(uint256) external returns (uint256) envfree; // AceHarness: read in the loan's own market
    function marketRailsOf(bytes32) external returns (uint256, uint256, uint256) envfree; // AceHarness
    function marketMinPrincipalOf(bytes32) external returns (uint256) envfree; // AceHarness
    function marketDebtFloorOf(bytes32) external returns (uint256) envfree; // AceHarness: `LoanMath.debtFloor`
    function principalOfLoan(uint256) external returns (uint256) envfree; // AceHarness
    function marketParamsHashOf(bytes32) external returns (bytes32) envfree; // AceHarness
}

// O56, identity: a created market's stored params hash to its id. `createMarket` derives the id from the params and
// genesis stores them verbatim, so it holds at birth, and it holds after only if no verb rewrites a field. Hashing is
// collision-free, so it says a created market's params never change -- its lender, quote and collateral included.
invariant aCreatedMarketIsItsParams(bytes32 m)
    marketQuoteOf(m) != 0 => marketParamsHashOf(m) == m
    filtered { f -> freshIdVerb(f) }
    { preserved with (env e) { require e.msg.sender != currentContract; } }

// O56, the rails the coverage line's arithmetic rests on: a created market's coverage factor sits in the genesis band,
// its unit scale is the one frame, its price is positive and under the ceiling, and its `minPrincipal` is at least two
// (a positive debt floor) and fits the cash cap. Genesis checks them, and params and scale are written once.
invariant aCreatedMarketKeepsItsRails(bytes32 m)
    marketQuoteOf(m) != 0 => railsHold(m)
    filtered { f -> freshIdVerb(f) }
    { preserved with (env e) { require e.msg.sender != currentContract; } }

function railsHold(bytes32 m) returns bool {
    uint256 cover; uint256 scale; uint256 price;
    cover, scale, price = marketRailsOf(m);
    return cover >= 105 * 10^16 && cover <= 20 * 10^18 && scale == 2^96 && price > 0 && price <= 2^224
        && marketMinPrincipalOf(m) >= 2 && marketMinPrincipalOf(m) <= max_uint128;
}

// a loan sits in a created market: every entry builds its config through `_cache`, which refuses an uncreated one,
// and nothing un-creates a market. With O56 it hands every loan its market's rails.
invariant aLoanSitsInACreatedMarket(uint256 id)
    loanMarket(id) != to_bytes32(0) => marketQuoteOf(loanMarket(id)) != 0
    filtered { f -> freshIdVerb(f) }
    {
        preserved with (env e) {
            require e.msg.sender != currentContract;
            requireInvariant aFreshIdHasNeverClosed(id);
        }
    }

definition notDeleverage(method f) returns bool = f.selector != sig:deleverage(uint256,uint256,bytes).selector;

// THE CHAIN'S CLOCK, stated: every close stamps `uint64(block.timestamp)` and liveness IS `closedAt == 0`, so a close
// at timestamp 0 (mod 2^64) would leave the loan live with its debt retired. No chain's timestamp is 0 or past 2^64.
definition aRealClock(env e) returns bool = e.block.timestamp > 0 && e.block.timestamp < 2^64;

// O10: an issued loan (above the counter none has a market: aFreshIdHasNeverClosed, HubLoans.spec), while live, carries its
// debt as its claim and owes something; once closed it carries no claim. Settlement keeps the stored debt word but owes
// nothing, so the closed leg says nothing of `debt`.
invariant aLoanCarriesItsDebtAsItsClaim(uint256 id)
    loanMarket(id) != to_bytes32(0) => (
        closedAtOf(id) == 0
            ? (loanClaimOf(id) == loanDebtOf(id) && loanDebtOf(id) > 0)
            : loanClaimOf(id) == 0
    )
    filtered { f -> freshIdVerb(f) && notDeleverage(f) }
    {
        preserved with (env e) {
            require e.msg.sender != currentContract;
            require aRealClock(e);
            requireInvariant marketZeroIsNeverCreated();
            requireInvariant aFreshIdHasNeverClosed(id);
            requireInvariant aFreshIdHasNeverClosed(require_uint256(idCount() + 1));
            requireInvariant aFreshIdHasNeverClosed(require_uint256(idCount() + 2));
        }
    }

// O71c (L): an issued loan, while live, carries at least its market's debt floor, half `minPrincipal`. A birth issues at
// least `minPrincipal`, a repay pays the loan off or leaves at least the floor whoever sends it, and `minPrincipal` is
// write-once (O56). The deleverage step is HubClaimsExact.spec's `aCrankLeavesTheDebtAtTheFloorOrClosesTheLoan`.
invariant aLiveLoanCarriesAtLeastTheDebtFloor(uint256 id)
    (loanMarket(id) != to_bytes32(0) && closedAtOf(id) == 0) => loanDebtOf(id) >= marketDebtFloorOf(loanMarket(id))
    filtered { f -> freshIdVerb(f) && notDeleverage(f) }
    {
        preserved with (env e) {
            require e.msg.sender != currentContract;
            require aRealClock(e);
            requireInvariant marketZeroIsNeverCreated();
            requireInvariant aFreshIdHasNeverClosed(id);
            requireInvariant aFreshIdHasNeverClosed(require_uint256(idCount() + 1));
            requireInvariant aFreshIdHasNeverClosed(require_uint256(idCount() + 2));
            requireInvariant aLoanSitsInACreatedMarket(id);
            requireInvariant aCreatedMarketIsItsParams(loanMarket(id));
        }
    }

// O71c (B): every issued loan, live or closed, was born with a principal of at least its market's `minPrincipal`.
// `_record` is the only writer of both the loan's market and its principal, behind `_preChecks`; the four births reach it
// (`open`, `openWithPermit2`, an order fill, a refinance successor), and no verb rewrites either word afterwards.
invariant aLoanIsBornAtMinPrincipal(uint256 id)
    loanMarket(id) != to_bytes32(0) => principalOfLoan(id) >= marketMinPrincipalOf(loanMarket(id))
    filtered { f -> freshIdVerb(f) }
    {
        preserved with (env e) {
            require e.msg.sender != currentContract;
            requireInvariant marketZeroIsNeverCreated();
            requireInvariant aFreshIdHasNeverClosed(id);
            requireInvariant aLoanSitsInACreatedMarket(id);
            requireInvariant aCreatedMarketIsItsParams(loanMarket(id));
        }
    }
