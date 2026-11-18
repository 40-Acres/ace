// RunwayHook's window CORRECTNESS and its registration GATE. `RunwayHookWindow.spec` proves the window code never
// reverts; this spec proves what it keeps, and who may open a launch pool.
//   W1  the roll keeps each slot's low and high: the tick folds into the current slot, a slot crossed carries its low
//       and high one place back, and nothing ages out before it has crossed three slots;
//   W2  the read (`windowOf`) never drops a stored low or high its window still covers, and holds spot while no swap
//       has run this block: a read one slot ahead, or one second early, would drop the oldest slot 12 hours early;
//   W3  the swap callback writes the same window: a block's first swap folds its tick in, and a later swap writes nothing;
//   R1  only the strategy initializes a pool naming this hook, and only at or before the factory's launchBy for that key;
//   R2  `authorized()` names the strategy exactly while the factory is launching, and no one otherwise.
//
// THE SCENE. `RunwayHookProof` is the hook with key-field entry points, since CVL cannot name the file-level PoolKey or
// PoolId; it adds no storage, and each entry builds the key the hook would see and reaches its internal through a
// calldata self-call, as the PoolManager's call arrives. The one check skipped is BaseHook's onlyPoolManager.
// The factory is `MockLaunchPools`, LINKED to FACTORY: free storage, so every launchBy and launching flag is met.
// The PoolManager's extsload is an arbitrary word, as in `RunwayHookWindow.spec`: any slot0 word, so any tick.
// Storage starts arbitrary, so the stored window is any word; a rule that needs a seeded window says so.
using MockLaunchPools as pools;

methods {
    function _.extsload(bytes32 slot) external => anyWord(slot) expect bytes32;

    function STRATEGY() external returns (address) envfree;
    function MockLaunchPools.launchByView(bytes32) external returns (uint64) envfree;
    function MockLaunchPools.launchingView() external returns (bool) envfree;
}

function anyWord(bytes32 slot) returns bytes32 {
    bytes32 word;
    return word;
}

definition SLOT_SECONDS() returns mathint = 43200; // the hook's SLOT, 12 hours, written out so the spec does not read it back

// the hook's clock reads: the slot index and the block fit their casts, as they do for the next eight thousand years
function clockFits(env e) {
    require e.block.timestamp / SLOT_SECONDS() <= max_uint32;
    require e.block.number <= max_uint48;
}

// ---- W1: the roll ----

// THE ROLL KEEPS EACH SLOT'S LOW AND HIGH. `j` is the slots crossed since the newest sample: none while the stored slot
// is at or ahead of `k`, all three for an unseeded window. The tick always joins the current slot; with nothing crossed
// the older two are untouched; one slot crossed moves the current slot, tick included, one place back and the one before
// it to the oldest; two moves it to the oldest; three or more leave the tick alone, since only a swap moves the price.
rule theRollKeepsEachSlotsLowAndHigh(RunwayHook.Window w, uint32 k, int24 t) {
    env e;
    RunwayHook.Window r = roll(e, w, k, t);
    mathint j = !w.seeded ? 3 : (k > w.slot ? k - w.slot : 0);

    assert r.seeded && r.lo0 <= t && r.hi0 >= t, "the tick did not join the current slot";
    assert j == 0 => (r.slot == w.slot && r.lo0 <= w.lo0 && r.hi0 >= w.hi0), "a roll within the slot lost its low or high";
    assert j == 0 => (r.lo1 == w.lo1 && r.hi1 == w.hi1 && r.lo2 == w.lo2 && r.hi2 == w.hi2), "a roll within the slot moved an older slot";
    assert j > 0 => r.slot == k, "a roll that crossed a slot did not move to it";
    assert j == 1 => (r.lo1 <= w.lo0 && r.lo1 <= t && r.hi1 >= w.hi0 && r.hi1 >= t), "one slot on, the slot before lost the current slot's low or high";
    assert j == 1 => (r.lo2 <= w.lo1 && r.hi2 >= w.hi1), "one slot on, the oldest slot lost the slot before's low or high";
    assert j == 2 => (r.lo1 <= t && r.hi1 >= t && r.lo2 <= w.lo0 && r.lo2 <= t && r.hi2 >= w.hi0 && r.hi2 >= t),
        "two slots on, a slot lost the tick or the current slot's low or high";
    assert j >= 3 => (r.lo1 <= t && r.hi1 >= t && r.lo2 <= t && r.hi2 >= t), "three slots on, a slot lost the tick";
}

// ---- W2: the read ----

// THE READ NEVER DROPS A LOW OR A HIGH ITS WINDOW STILL COVERS. At or behind the stored slot it covers all three
// stored slots; one slot on, the current and the one before; two on, the current. Spot joins whenever no swap has
// sampled this block. A read one slot ahead, or turning a second early, fails the first line at the slot's end.
rule theReadNeverDropsALowItsWindowCovers(env e, address c0, address c1, uint24 fee, int24 ts) {
    clockFits(e);
    RunwayHook.Window w = windowOfKey(e, c0, c1, fee, ts);
    mathint k = e.block.timestamp / SLOT_SECONDS();
    int24 lo;
    int24 hi;
    int24 spot;
    lo, hi, spot = readOfKey(e, c0, c1, fee, ts);
    bool fresh = !w.seeded || to_mathint(w.lastBlock) != to_mathint(e.block.number);

    assert (w.seeded && k <= to_mathint(w.slot)) => (lo <= w.lo0 && lo <= w.lo1 && lo <= w.lo2 && hi >= w.hi0 && hi >= w.hi1 && hi >= w.hi2),
        "the read dropped a stored slot inside its window";
    assert (w.seeded && k == w.slot + 1) => (lo <= w.lo0 && lo <= w.lo1 && hi >= w.hi0 && hi >= w.hi1),
        "one slot on, the read dropped the current slot or the one before";
    assert (w.seeded && k == w.slot + 2) => (lo <= w.lo0 && hi >= w.hi0), "two slots on, the read dropped the current slot";
    assert fresh => (lo <= spot && hi >= spot), "the read left spot out while no swap had sampled this block";
}

// and the oldest slot really is the low a read can land on: the bound above is met with equality
rule witnessTheReadLandsOnTheOldestSlot(env e, address c0, address c1, uint24 fee, int24 ts) {
    clockFits(e);
    RunwayHook.Window w = windowOfKey(e, c0, c1, fee, ts);
    int24 lo;
    int24 hi;
    int24 spot;
    lo, hi, spot = readOfKey(e, c0, c1, fee, ts);
    satisfy w.seeded && to_mathint(w.slot) == e.block.timestamp / SLOT_SECONDS() && lo == w.lo2 && w.lo2 < w.lo0 && w.lo2 < w.lo1 && w.lo2 < spot;
}

// ---- W3: the swap callback ----

// A BLOCK'S FIRST SWAP FOLDS ITS TICK IN AND KEEPS EVERY LOW AND HIGH THE WINDOW STILL COVERS; A LATER SWAP WRITES NOTHING
rule aSwapKeepsEachSlotsLowAndHigh(env e, address c0, address c1, uint24 fee, int24 ts) {
    clockFits(e);
    RunwayHook.Window w = windowOfKey(e, c0, c1, fee, ts);
    mathint k = e.block.timestamp / SLOT_SECONDS();
    bool fresh = !w.seeded || to_mathint(w.lastBlock) != to_mathint(e.block.number);

    swapOn(e, c0, c1, fee, ts);
    RunwayHook.Window r = windowOfKey(e, c0, c1, fee, ts);

    assert !fresh => (r.slot == w.slot && r.lastBlock == w.lastBlock && r.seeded == w.seeded), "a later swap in the block moved the sample";
    assert !fresh => (r.lo0 == w.lo0 && r.hi0 == w.hi0 && r.lo1 == w.lo1 && r.hi1 == w.hi1 && r.lo2 == w.lo2 && r.hi2 == w.hi2),
        "a later swap in the block wrote the window";
    assert fresh => (r.seeded && to_mathint(r.lastBlock) == to_mathint(e.block.number)), "a block's first swap did not stamp the block";
    assert (fresh && w.seeded && k <= to_mathint(w.slot)) => (r.lo0 <= w.lo0 && r.hi0 >= w.hi0 && r.lo1 == w.lo1 && r.hi1 == w.hi1 && r.lo2 == w.lo2 && r.hi2 == w.hi2),
        "a swap within the slot lost a low or a high";
    assert (fresh && w.seeded && k == w.slot + 1) => (r.lo1 <= w.lo0 && r.hi1 >= w.hi0 && r.lo2 <= w.lo1 && r.hi2 >= w.hi1),
        "one slot on, a swap lost a low or a high it still covers";
    assert (fresh && w.seeded && k == w.slot + 2) => (r.lo2 <= w.lo0 && r.hi2 >= w.hi0), "two slots on, a swap lost the current slot's low or high";
}

// ---- R1: the registration gate ----

// ONLY THE STRATEGY INITIALIZES A POOL NAMING THIS HOOK, AND ONLY AT OR BEFORE THE FACTORY'S launchBy FOR THAT KEY: a
// key no launch recorded reads zero, so it is refused at every real second.
rule onlyTheStrategyOpensALaunchPoolByItsLaunchBy(env e, address sender, address c0, address c1, uint24 fee, int24 ts, uint160 sqrtPriceX96) {
    bytes32 id = keyId(e, c0, c1, fee, ts);
    mathint by = pools.launchByView(id);
    initializeOn@withrevert(e, sender, c0, c1, fee, ts, sqrtPriceX96);
    bool ok = !lastReverted;
    assert ok => sender == STRATEGY(), "a sender other than the strategy initialized a pool naming the hook";
    assert ok => to_mathint(e.block.timestamp) <= by, "a pool was initialized after its launch's launchBy";
}

// and the gate opens: the strategy initializes a recorded key by its launchBy
rule witnessTheStrategyOpensALaunchPool(env e, address sender, address c0, address c1, uint24 fee, int24 ts, uint160 sqrtPriceX96) {
    bytes32 id = keyId(e, c0, c1, fee, ts);
    initializeOn(e, sender, c0, c1, fee, ts, sqrtPriceX96);
    satisfy pools.launchByView(id) > 0;
}

// ---- R2: who the hook authorizes ----

// `authorized()` IS THE STRATEGY EXACTLY WHILE THE FACTORY IS LAUNCHING, AND ZERO OTHERWISE
rule theStrategyIsAuthorizedOnlyWhileALaunchRuns(env e) {
    bool launching = pools.launchingView();
    address a = authorized(e);
    assert a != 0 => launching, "the hook authorized someone while no launch ran";
    assert launching => a == STRATEGY(), "the hook did not authorize the strategy while a launch ran";
    assert !launching => a == 0, "the hook authorized someone while no launch ran";
}
