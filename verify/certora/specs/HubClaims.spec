// Ace hub -- O10: a loan's claim is its debt.
//
// One lender funds each loan, so the loan's claim in its market IS its debt: every write to one (the draw, a repay's
// melt, a deleverage melt, a home migration's recycle) writes the other by the same amount, and a close retires the
// claim. A live loan's debt is also positive: every loan's debt enters through `_preChecks`, which refuses a zero
// principal, a full repay closes the loan, and a deleverage melt stops at `minDebt`, which genesis refuses at zero.
// O51 (the unpaid backstop) rests on both halves: settlement credits the fee escrow over the claim and reverts NoClaims
// on a retired one.
//
// DELEVERAGE IS PROVEN IN HubClaimsExact.spec, not here. Its positive-debt leg rests on the `room` cap, which is
// arithmetic, and this spec's `mulDiv` is uninterpreted: with it, `room` came back past 2^128 on a head of one.

import "HubLoans.spec";

methods {
    function loanDebtOf(uint256) external returns (uint256) envfree; // AceHarness
    function loanClaimOf(uint256) external returns (uint256) envfree; // AceHarness: read in the loan's own market
    function marketRailsOf(bytes32) external returns (uint256, uint256, uint256) envfree; // AceHarness
    function marketMinDebtOf(bytes32) external returns (uint256) envfree; // AceHarness
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
// its unit scale is the one frame, its price is positive and under the ceiling, and it issues no zero debt. Genesis
// checks them, and a market's params and scale are written once, so they hold for its whole life.
invariant aCreatedMarketKeepsItsRails(bytes32 m)
    marketQuoteOf(m) != 0 => railsHold(m)
    filtered { f -> freshIdVerb(f) }
    { preserved with (env e) { require e.msg.sender != currentContract; } }

function railsHold(bytes32 m) returns bool {
    uint256 cover; uint256 scale; uint256 price;
    cover, scale, price = marketRailsOf(m);
    return cover >= 105 * 10^16 && cover <= 20 * 10^18 && scale == 2^96 && price > 0 && price <= 2^224
        && marketMinDebtOf(m) > 0;
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

// an issued loan is one with a market: above the counter none has one (aFreshIdHasNeverClosed, HubLoans.spec)
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
