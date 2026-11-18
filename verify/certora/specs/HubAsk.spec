// Ace hub -- WHAT A BUY PAYS: a settled pot's units leave by a buy only for at least their ask value, credited to the lender.
//
// HubDoors.spec's `onlyTheLenderOrABuyLowersAPot` proves the door: a pot falls only by its lender's `redeemInKind` or by a
// `buyInventory` that raises the lender's `owed`. This rule proves the amount, on the one door a stranger has: across a
// buy, the pair's `owed` rises by at least the units that left the pot times the ask, `max(price, record floor)`, over the
// unit scale. The fill fee rides on top and is not claimed here.
//
// WHY ITS OWN SCENE: the bound is arithmetic. `_askLeg` ceils its charge off the units that LEAVE, so with `mulDiv`
// uninterpreted (HubDoors.spec) nothing ties the charge to the units; here every `FullMath.mulDiv` is EXACT, and
// `mulDivRoundingUp`'s body runs on it, so the ceiling is derived, never asserted. A call the real routine refuses (a zero
// divisor, a result past 2^256 - 1) prunes its path: this is a safety property, and a reverting path writes nothing.
//
// THE RECORD is recorded as in HubDoors.spec: `Borrower.persistedPrice` answers anything and writes the first answer down,
// so the rule reads the floor the buy priced at rather than re-deriving it. A codeless record reads max, as the real one.
// The custodian's release and the quote pull are unresolved calls that cannot write the hub.
//
// PREMISES: a real clock, a caller that is not the hub, and an issued loan at or under the id counter
// (HubAttribution.spec `aFreshIdHoldsNoLoan`), so the pot read before and after is one loan's in one market.

methods {
    function FullMath.mulDiv(uint256 a, uint256 b, uint256 d) internal returns (uint256) => mulDivDownExact(a, b, d);
    // NO SUMMARY for mulDivRoundingUp: via-IR inlines it, so one cannot bind and requesting it fails the run. Its body runs on the exact mulDiv above.
    function Borrower.persistedPrice(DoorsHarness.Cfg memory c) internal returns (uint256) => recordedPrice(c);

    function idCount() external returns (uint256) envfree;
    function loanMarket(uint256) external returns (bytes32) envfree;
    function loanPotOf(uint256) external returns (uint256) envfree;
    function marketOwedOf(bytes32) external returns (uint256) envfree;
    function marketRailsOf(bytes32) external returns (uint256, uint256, uint256) envfree;
    function marketGateOf(bytes32) external returns (uint256, uint256, address) envfree;
}

function mulDivDownExact(uint256 a, uint256 b, uint256 d) returns uint256 {
    require d != 0;
    mathint r = (a * b) / d;
    require r <= max_uint256;
    return require_uint256(r);
}

persistent ghost uint256 prices; // how many windowed minimums were read
persistent ghost uint256 price1; // the first one

// no record wired reads max, as the real one does; a wired one answers anything, never reverting where it might
function recordedPrice(DoorsHarness.Cfg c) returns uint256 {
    if (c.p.record == 0) {
        return max_uint256;
    }
    uint256 p;
    if (prices == 0) {
        price1 = p;
    }
    prices = require_uint256(prices + 1);
    return p;
}

definition aRealClock(env e) returns bool = e.block.timestamp > 0 && e.block.timestamp < 2^64;

function aStrangersBuy(env e, uint256 id) {
    require e.msg.sender != currentContract && aRealClock(e);
    require loanMarket(id) != to_bytes32(0);
    require id <= idCount(); // PROVEN: HubAttribution.spec `aFreshIdHoldsNoLoan`
    require prices == 0;
}

// the floor the buy priced at: zero with no record, or where the record read max (the hub's own sentinel), else its answer
function askOf(bytes32 m) returns mathint {
    uint256 cover;
    uint256 scale;
    uint256 price;
    cover, scale, price = marketRailsOf(m);
    uint256 band;
    uint256 stop;
    address record;
    band, stop, record = marketGateOf(m);
    mathint floor = (record == 0 || prices == 0 || price1 == max_uint256) ? 0 : price1;
    return price > floor ? price : floor;
}

rule aBuyCreditsTheLenderTheAskValue(env e, uint256 id, uint256 stableIn, uint256 minUnitsOut, address unitsTo) {
    aStrangersBuy(e, id);
    bytes32 m = loanMarket(id);
    uint256 cover;
    uint256 scale;
    uint256 price;
    cover, scale, price = marketRailsOf(m);
    mathint pot0 = loanPotOf(id);
    mathint owed0 = marketOwedOf(m);
    buyInventory(e, id, stableIn, minUnitsOut, unitsTo);
    mathint left = pot0 - loanPotOf(id);
    mathint ask = askOf(m);
    assert (marketOwedOf(m) - owed0) * scale >= left * ask, "a buy took a pot's units for less than their ask value";
}

// witnesses: a buy really takes units, both a part of a pot and a whole one, so the bound is not passing on nothing sold
rule aBuyCanTakePartOfAPot(env e, uint256 id, uint256 stableIn, uint256 minUnitsOut, address unitsTo) {
    aStrangersBuy(e, id);
    mathint pot0 = loanPotOf(id);
    buyInventory(e, id, stableIn, minUnitsOut, unitsTo);
    satisfy loanPotOf(id) < pot0 && loanPotOf(id) > 0;
}

rule aBuyCanEmptyAPot(env e, uint256 id, uint256 stableIn, uint256 minUnitsOut, address unitsTo) {
    aStrangersBuy(e, id);
    mathint pot0 = loanPotOf(id);
    buyInventory(e, id, stableIn, minUnitsOut, unitsTo);
    satisfy pot0 > 0 && loanPotOf(id) == 0;
}
