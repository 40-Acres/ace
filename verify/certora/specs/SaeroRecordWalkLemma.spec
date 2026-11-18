// THE WALK'S ONE CONTRACT, the lemma `SaeroRecordWalkSplit.spec` summarizes `_walk` by: an answer the walk gives with no
// doubt carries a high at least the high it was handed. `_walk` starts from the latest answer and only raises it
// (`if (a > hi) hi = a`), so this is all the settle twin's implication needs of the 64-round history; the implication
// itself is proven over this contract in `confs/SaeroRecordWalkSplit.conf`, where no loop remains.
//
// THE SCENE IS `SaeroRecordWalk.conf`'s, through `RecordWalkHarness`, which adds one entry point onto the record's own
// `_walk` and no state. The feed is the LINKED `MockAggregator`, which answers every round id from storage, so the walk
// meets every history: a revert, a short or unfit round, a stamp out of order, and a window longer than 64 rounds.
// PESSIMISTIC AT 64: the walk reads at most MAX_HOLD_ROUNDS rounds, so unrolling it 64 times covers every walk.
methods {
    function walkOf(uint80, uint256, uint256, uint256, uint256) external returns (bool, uint256);
}

// A WALK THAT ANSWERS WITH NO DOUBT NEVER LOWERS THE HIGH IT WAS HANDED
rule aWalkNeverLowersTheHigh(env e, uint80 id, uint256 upd, uint256 hi, uint256 from, uint256 fresh) {
    bool ok;
    uint256 high;
    ok, high = walkOf(e, id, upd, hi, from, fresh);
    assert ok => high >= hi, "the walk answered a high under the high it was handed";
}

// and a walk can raise it: a past round above the latest answer is kept
rule witnessAWalkRaisesTheHigh(env e, uint80 id, uint256 upd, uint256 hi, uint256 from, uint256 fresh) {
    bool ok;
    uint256 high;
    ok, high = walkOf(e, id, upd, hi, from, fresh);
    satisfy ok && high > hi;
}
