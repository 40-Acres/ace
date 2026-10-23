// RunwayHook's block-start window: neither the roll, the read nor the swap callback can revert. A pool's hook is permanent, and a revert in
// beforeSwap would freeze every swap in a launch pool for good; the read is what the launch lending vault prices from.
//
// The PoolManager's extsload is summarized as an arbitrary word: any slot0 word comes back, so any int24 tick, a superset
// of the [MIN_TICK, MAX_TICK] a real pool holds. Storage starts arbitrary, so the stored window is any word at all.
// A bare NONDET is NOT used: it havocs the return SIZE as well, and a short return fails the caller's ABI decode, a
// revert no PoolManager can produce, since its extsload(bytes32) always returns exactly one word.

methods {
    function _.extsload(bytes32 slot) external => anyWord(slot) expect bytes32;
}

function anyWord(bytes32 slot) returns bytes32 {
    bytes32 word;
    return word;
}

// The roll, for any stored window, any slot index and any tick.
rule rollNeverReverts(RunwayHook.Window w, uint32 k, int24 t) {
    env e;
    require e.msg.value == 0;
    roll@withrevert(e, w, k, t);
    assert !lastReverted, "the roll reverted";
}

// The read, for any pool id, any stored window, any slot0 word, any time and any block. PoolId is a file-level value type
// CVL cannot name, so the id comes as calldataarg: its one bytes32 word has no value that fails to decode.
rule windowOfNeverReverts() {
    env e;
    calldataarg args;
    require e.msg.value == 0;
    windowOf@withrevert(e, args);
    assert !lastReverted, "the read reverted";
}

// The write: the swap callback every swap in a launch pool runs, for any key, any stored window, any slot0 word, any time
// and any block. PoolKey is file-level too, so the harness takes its fields and hands the hook the key as calldata through
// a self-call, as the PoolManager does; the one check it skips is BaseHook's onlyPoolManager, which the PoolManager passes.
rule beforeSwapNeverReverts(address currency0, address currency1, uint24 fee, int24 tickSpacing) {
    env e;
    require e.msg.value == 0;
    beforeSwapOn@withrevert(e, currency0, currency1, fee, tickSpacing);
    assert !lastReverted, "the swap callback reverted";
}
