// REC-5's implication, the settle twin implies the distress twin (O76), proven OVER THE WALK'S CONTRACT rather than over
// its 64-round unroll, which timed out. Settle answers true only with the latest round live and priced nonzero, and the
// window's high framed and priced under `x`; distress asks the same latest round live, priced nonzero and under `x`. The
// high is `_walk`'s answer, which starts at the latest answer and only rises, so the implication needs nothing else of the
// history. That one fact is the lemma `aWalkNeverLowersTheHigh` (`confs/SaeroRecordWalkLemma.conf`, at the full 64), and
// here `_walk` is summarized by it: an undoubted answer carries a high at least the high it was handed, and is otherwise
// free. Every other step runs as written: the pair check, the account reads, the sequencer, both feed reads, the framing,
// `_price`'s guard and its floor.
//
// THE SCENE IS `SaeroRecord.spec`'s, and its header argues it: the feed, the sequencer and the factory LINKED to mocks of
// storage, the account's three reads DISPATCHED to `MockStakeAccount`, and `FullMath.mulDiv` exact with its two reverts
// recorded in flags.
using MockStakeAccount as account;
using MockAccountFactory as factory;

methods {
    function FullMath.mulDiv(uint256 a, uint256 b, uint256 d) internal returns (uint256) => mulDivExact(a, b, d);
    function NftAccountRecord._walk(uint80 id, uint256 upd, uint256 hi, uint256 from, uint256 fresh) internal returns (bool, uint256)
        => walkContract(hi);

    function _.holdsStake() external => DISPATCHER(true);
    function _.totalSupply() external => DISPATCHER(true);
    function _.backing() external => DISPATCHER(true);

    function QUOTE() external returns (address) envfree;
    function MockAccountFactory.isAccount(address) external returns (bool) envfree;
}

ghost bool zeroDenSeen;
ghost bool overflowSeen;

// as in `SaeroRecord.spec`: exact, floored once, with the real library's two reverts recorded rather than pruned
function mulDivExact(uint256 a, uint256 b, uint256 d) returns uint256 {
    if (d == 0) {
        zeroDenSeen = true;
        return 0;
    }
    mathint r = (a * b) / d;
    if (r > to_mathint(max_uint256)) {
        overflowSeen = true;
        return 0;
    }
    return require_uint256(r);
}

// `_walk`'s contract, the lemma `aWalkNeverLowersTheHigh`: an undoubted answer's high is at least the high handed in
function walkContract(uint256 hi) returns (bool, uint256) {
    bool ok;
    uint256 high;
    require ok => high >= hi;
    return (ok, high);
}

function thePricedPair() returns address {
    require factory.isAccount(account);
    return account;
}

rule theSettleTwinImpliesTheDistressTwinOverTheWalksContract(env e, uint256 x) {
    address collateral = thePricedPair();
    bool distress = persistedBelowDistress(e, QUOTE(), collateral, x);
    bool settle = persistedBelowSettle(e, QUOTE(), collateral, x);
    assert settle => distress, "the settle twin answered below where the distress twin did not";
}

// and the implication is not satisfied by a settle twin that never answers true
rule theSettleTwinCanAnswerBelowOverTheWalksContract(env e, uint256 x) {
    address collateral = thePricedPair();
    satisfy persistedBelowSettle(e, QUOTE(), collateral, x);
}
