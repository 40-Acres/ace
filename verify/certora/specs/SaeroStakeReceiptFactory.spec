// V-3's FACTORY half of the internal record, over `SAeroStakeReceiptFactory.make`: `isAccount` is true for
// exactly the receipts the factory made, and `latest` names the last one per portfolio and stake (O82). Then H-2 (at
// most one receipt per portfolio and stake has units out) and L-D (an unbooked stake is refused), with the cheap
// sibling refusals beside it.
//
// WHY THIS LANE EXISTS SEPARATELY, and why it is worth its own conf rather than a footnote. The terms'
// `theBidNeverPanics` and `theBidReachesNoZeroDenominator` lean on it as a PREMISE: the bid divides by a receipt's
// supply, and a registry that blessed an address which was not a real receipt would divide by zero. That premise was
// not chosen -- it was found by getting the vault's rule wrong, on a counterexample where the factory blessed `0x401`.
// So this is the lane that discharges a dependency another proof already rests on.
//
// WHAT IS PROVEN HERE IS THE WRITE SET, NOT THE CLONE. `make` reads the escrow, the 40 Acres factory, the caller's
// booking and the prior receipt, creates a clone and mints into it. The registry rules state that NOTHING BUT `make`
// ever touches `isAccount` or `latest`, that `isAccount` only ever adds, and that `make` writes only the entries of the
// receipt it returns -- which is what a reader of `isAccount` depends on, whatever the clone does.
//
// EVERY CALL `make` MAKES IS UNRESOLVED, AND THAT IS FORCED, NOT CHOSEN. OZ `Clones` builds the clone's bytecode with
// `abi.encodePacked`, which under via-IR does not match the prover's packed allocation pattern; the failure discards
// the pointer analysis for the WHOLE of `make`, so no call in it resolves, the conf's links never bind, and a
// per-selector summary reports itself unused. Unhandled, each call is a havoc, and the refusal rules fail on answers no
// mock gave. `Clones` cannot be summarized instead: the prover cannot locate its functions, in either finder mode.
//
// SO EACH UNRESOLVED CALL IS DISPATCHED, and here is why none of it weakens a rule. The dispatch matches the CALLEE as
// well as the selector: a call reaches a mock only when its target is that mock's address, and any other is `NONDET`.
// (1) THE FIVE READS -- `isPortfolio`, the escrow's `ownerOf` and `staked`, the caller's `getStakedCollateral`, the
// prior receipt's `outstanding` -- each reach a mock whose storage the prover sets freely, so every answer is reachable.
// The escrow and the 40 Acres factory are immutables the conf links to their mocks, so those three always reach them. All
// five are `view` in the interfaces `make` calls them through, so solc issues a STATICCALL and the real callee can write
// nothing anywhere: a mock, or a `NONDET` answer, loses no effect.
// (2) THE CALLER AND THE PRIOR RECEIPT ARE PINNED TO THEIR MOCKS in the rules that need their answer -- L-D, both
// halves of H-2 -- because only then does the dispatch reach the mock the rule reads. THE PIN IS A NAME, NOT A CASE:
// `make` compares the caller only with CUSTODY and the answers it reads, and the prior receipt only with zero, and
// CUSTODY stays free of the pin, so one address stands for any. Every other rule leaves both free, and there the booking
// and `outstanding` arrive as `NONDET` answers: arbitrary, which a registry rule must survive anyway.
// (3) THE CLONE'S `mint()` is the one CALL `make` makes, into the receipt it has just created, at an address no mock
// holds, so it is `NONDET`: no effect and no revert. The real one writes only that clone's storage and calls nothing,
// so it cannot reach `isAccount` or `latest`; and on a fresh clone of this factory's implementation it cannot revert
// (the factory is its FACTORY, its state is None, the receiver is the caller), so the landing rule loses nothing real.
// (4) THE CLONE'S CREATION is the prover's own CREATE model, a fresh non-zero address; only the run of its init code
// takes the `NONDET` default, which havocs no state. That init code is the minimal proxy's, which returns the runtime
// code and writes no storage, and no rule reads the clone's code.
// What the mocks drop is a callee that REVERTS or has no code. That only removes reverts, so a rule asserting a refusal
// must find it in the factory's own check, and a rule about a landed `make` covers every answer; the one rule it
// touches is the landing half of H-2, whose premise "every other precondition holds" includes that each callee answers.
//
// AN EXTERNAL CALL DOES NOT RE-ENTER: the five reads are STATICCALLs, and the mint is `NONDET`.
using MockStakeEscrow as escrow;
using MockFortyAcresFactory as portfolios;
using MockStakePortfolio as portfolio;
using MockReceiptClone as clone;

methods {
    function isAccount(address) external returns (bool) envfree;
    function latest(address, uint256) external returns (address) envfree;
    function CUSTODY() external returns (address) envfree;

    function MockStakeEscrow.ownerOf(uint256) external returns (address) envfree;
    function MockStakeEscrow.amountView(uint256) external returns (uint128) envfree;
    function MockStakeEscrow.permanentView(uint256) external returns (bool) envfree;
    function MockFortyAcresFactory.isPortfolio(address) external returns (bool) envfree;
    function MockStakePortfolio.bookedView(uint256) external returns (uint256) envfree;
    function MockReceiptClone.outstandingView() external returns (uint256) envfree;

    // every call in `make` arrives unresolved (see the header), so each is dispatched to the mock at its callee
    unresolved external in SAeroStakeReceiptFactory.make(uint256) => DISPATCH [
        MockFortyAcresFactory.isPortfolio(address),
        MockStakeEscrow.ownerOf(uint256),
        MockStakeEscrow.staked(uint256),
        MockStakePortfolio.getStakedCollateral(uint256),
        MockReceiptClone.outstanding()
    ] default NONDET;
}

// ---- O82: the registry only ever grows, and only `make` writes it or `latest` ----

// A PARAMETRIC RULE, over every external method the factory has. Today `make` is the only mutator, so this is cheap to
// prove and that is the point: it is a PIN against a future function -- a migration, an admin repair, a second make
// shape -- that writes the registry, or the map H-2 reads, without anyone noticing the vault's panic-freedom now
// depends on it.
rule onlyMakeEverChangesTheRegistry(method f, env e, calldataarg args, address a, address p, uint256 s) {
    bool was = isAccount(a);
    address latestWas = latest(p, s);
    f(e, args);
    bool now_ = isAccount(a);

    assert now_ != was => now_, "a receipt was UN-blessed: the registry shrank, and every reader treats it as final";
    assert now_ != was => f.selector == sig:make(uint256).selector, "something other than make changed the receipt registry";
    assert latest(p, s) != latestWas => f.selector == sig:make(uint256).selector, "something other than make wrote latest";
}

// `make` blesses the receipt it returns and NO OTHER ADDRESS, records it as the caller's latest for that stake and moves
// no other entry. The second assert is the one with teeth: a make that blessed a second address would hand the vault
// collateral the factory never built.
rule makeBlessesOnlyTheReceiptItMade(env e, uint256 stakeId, address other, address p, uint256 s) {
    bool otherWas = isAccount(other);
    address latestWas = latest(p, s);

    address receipt = make(e, stakeId);

    assert isAccount(receipt), "make did not bless the receipt it made";
    assert other != receipt => isAccount(other) == otherWas, "make changed the registry for an address it did not make";
    assert latest(e.msg.sender, stakeId) == receipt, "make did not record the receipt it made as the caller's latest";
    assert (p != e.msg.sender || s != stakeId) => latest(p, s) == latestWas, "make moved latest for another portfolio or stake";
}

// ---- H-2: at most one receipt per portfolio and stake has units outstanding ----

// While the caller's last receipt for the stake still has units out, `make` refuses: a second receipt would price the
// same stake twice. The prior receipt is pinned to its mock, so its `outstanding` is the one read: see (2).
rule aMakeRefusesWhileTheLastReceiptHasUnitsOut(env e, uint256 stakeId) {
    require latest(e.msg.sender, stakeId) == clone && clone.outstandingView() != 0;

    make@withrevert(e, stakeId);
    assert lastReverted, "make made a second receipt while the last one for the stake still had units out";
}

// And the refusal is no wider than that: with no prior receipt, or one with every unit burned, `make` lands whenever
// every other precondition holds. Without this half, a `make` that always reverted would satisfy the rule above.
// The caller and any prior receipt are pinned to their mocks, so the booking and `outstanding` are the ones read: see (2).
rule aMakeLandsOnceTheLastReceiptIsSpent(env e, uint256 stakeId) {
    address p = e.msg.sender;
    require p == portfolio;
    require e.msg.value == 0;
    require p != CUSTODY() && portfolios.isPortfolio(p);
    require escrow.ownerOf(stakeId) == p;
    require escrow.permanentView(stakeId) && escrow.amountView(stakeId) != 0;
    require portfolio.bookedView(stakeId) != 0;
    require latest(p, stakeId) == 0 || (latest(p, stakeId) == clone && clone.outstandingView() == 0);

    make@withrevert(e, stakeId);
    assert !lastReverted, "make refused a fit stake whose last receipt had no units out";
}

// ---- L-D and the sibling refusals: who may make, and on what stake ----

// the caller is pinned to its mock, so its booking is the one read: see (2)
rule aMakeRefusesAnUnbookedStake(env e, uint256 stakeId) {
    require e.msg.sender == portfolio && portfolio.bookedView(stakeId) == 0;
    make@withrevert(e, stakeId);
    assert lastReverted, "make took a stake the caller's portfolio does not book";
}

rule aMakeRefusesCustody(env e, uint256 stakeId) {
    require e.msg.sender == CUSTODY();
    make@withrevert(e, stakeId);
    assert lastReverted, "custody made a receipt";
}

rule aMakeRefusesANonPortfolio(env e, uint256 stakeId) {
    require !portfolios.isPortfolio(e.msg.sender);
    make@withrevert(e, stakeId);
    assert lastReverted, "an address the 40 Acres factory does not name made a receipt";
}

rule aMakeRefusesAStakeTheCallerDoesNotHold(env e, uint256 stakeId) {
    require escrow.ownerOf(stakeId) != e.msg.sender;
    make@withrevert(e, stakeId);
    assert lastReverted, "make took a stake the escrow does not name the caller's";
}

rule aMakeRefusesADecayingStake(env e, uint256 stakeId) {
    require !escrow.permanentView(stakeId);
    make@withrevert(e, stakeId);
    assert lastReverted, "make took a stake that decays";
}

rule aMakeRefusesAnEmptyStake(env e, uint256 stakeId) {
    require escrow.amountView(stakeId) == 0;
    make@withrevert(e, stakeId);
    assert lastReverted, "make took an empty stake";
}
