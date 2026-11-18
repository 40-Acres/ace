// V-3's other factory half: the CLONE `make` builds is pinned to its caller and its stake. `SaeroStakeReceiptFactory.spec`
// proves which registry entries `make` writes; this proves what it bakes into the receipt it makes: PORTFOLIO is the
// caller, STAKE_ID the stake named, UNITS the stake's amount as the escrow reads it now, the code the factory's own
// IMPLEMENTATION, and one clone per `make`.
//
// THE FACTORY IS MUNGED, ONE LINE AND ONE HOOK: `scripts/certora-munge-factory.sh` routes `make`'s Clones call through an
// internal virtual `_cloneWithArgs`, and `SAeroStakeReceiptFactoryHarness` overrides it to decode and store the args as
// the receipt's `_args()` decodes them. OZ `Clones.fetchCloneArgs` returns exactly the bytes a clone was made with, so the
// stored args are the ones the receipt reads back. The script's header carries the argument.
//
// THE REST OF THE SCENE IS `SaeroStakeReceiptFactory.spec`'s: the escrow and the 40 Acres factory are LINKED mocks of free
// storage, and every call `make` makes is DISPATCHED to the mock at its callee, any other being NONDET; that spec's header
// argues why that weakens no rule about a landed `make`. The clone's `mint` reaches the free address the hook answers,
// which no mock holds, so it is NONDET: the real one writes only the clone's storage.
using MockStakeEscrow as escrow;

methods {
    function IMPLEMENTATION() external returns (address) envfree;
    function madeView() external returns (address, address, uint256, uint256) envfree;
    function clonesView() external returns (uint256) envfree;
    function cloneAtView() external returns (address) envfree;
    function MockStakeEscrow.amountView(uint256) external returns (uint128) envfree;

    unresolved external in SAeroStakeReceiptFactoryHarness.make(uint256) => DISPATCH [
        MockFortyAcresFactory.isPortfolio(address),
        MockStakeEscrow.ownerOf(uint256),
        MockStakeEscrow.staked(uint256),
        MockStakePortfolio.getStakedCollateral(uint256),
        MockReceiptClone.outstanding()
    ] default NONDET;
}

// A LANDED `make` CLONES THE FACTORY'S OWN CODE ONCE, WITH ITS CALLER, THE STAKE NAMED AND THAT STAKE'S AMOUNT NOW
rule makePinsTheCloneToTheCallerAndTheStakeAmount(env e, uint256 stakeId) {
    mathint amount = escrow.amountView(stakeId);
    mathint c0 = clonesView();

    address receipt = make(e, stakeId);

    address impl;
    address p;
    uint256 id;
    uint256 units;
    impl, p, id, units = madeView();
    assert to_mathint(clonesView()) == c0 + 1, "make did not clone exactly once";
    assert receipt == cloneAtView(), "make returned an address other than the clone it made";
    assert impl == IMPLEMENTATION(), "make cloned code other than its own receipt implementation";
    assert p == e.msg.sender, "the clone's PORTFOLIO is not the caller";
    assert id == stakeId, "the clone's STAKE_ID is not the stake named";
    assert to_mathint(units) == amount, "the clone's UNITS is not the stake's amount";
}

rule witnessAMakeLands(env e, uint256 stakeId) {
    make(e, stakeId);
    satisfy clonesView() > 0;
}
