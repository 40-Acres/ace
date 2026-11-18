// `SAeroTerms` as the vault's DOOR: what each verb returns to the vault, under which key, and whether it closes it (V-18,
// V-19 and X-1's per-verb halves in the internal record, owed under #876). The terms are upgradeable, so these
// rules state what the CODE AS DEPLOYED does; a later implementation needs them re-run.
//   D1  `creditCustodyRewards` sends every unit of cash here to the vault under the ASSET key, closing nothing;
//   D2  `collectSaleProceeds` returns exactly what the receipt's `settle` paid, against the receipt, and closes its key;
//   D3  `sweepLost` returns exactly what `sweep` paid, against the receipt, closing the key only once D is paid;
//   D4  `returnClaimed` passes a receipt's later cash on whole: against its key while a sweep left it open, else a transfer.
// In each the terms keep none of the cash they took, and only the receipt's own report is believed when it matches the cash.
//
// THE SCENE. The terms run as compiled, no harness (as `SaeroTerms.conf`). The asset is a LINKED `DummyERC20`; the vault
// is `MockDoorVault`, LINKED, whose `returnProceeds` pulls the cash named and records the call; the factory is
// `MockAccountFactory`, LINKED. The receipt is `MockDoorReceipt`: it pays a free amount and reports a free figure, and its
// claim and sweep flag are free, so the door meets a receipt that pays what it says, pays short, pays over, or refuses.
// It arrives as an argument, so every call to it is DISPATCHED, and each rule pins the receipt to the mock, the
// factory spec's pattern: the terms compare a receipt with nothing but the factory's answer, so one address stands for any.
// Every other unresolved call is dispatched by callee and selector, as in `SaeroReceipt.spec`, and any other callee is NONDET.
// The terms' namespaced storage starts arbitrary, as in `SaeroVault.spec`; none of these verbs reads a dial.
using DummyERC20 as asset;
using MockDoorVault as vault;
using MockDoorReceipt as rcpt;
using MockAccountFactory as factory;

methods {
    function ASSET() external returns (address) envfree;
    function VAULT() external returns (address) envfree;

    function DummyERC20.balanceOf(address) external returns (uint256) envfree;
    function MockDoorVault.callsView() external returns (uint256) envfree;
    function MockDoorVault.lastKeyView() external returns (address) envfree;
    function MockDoorVault.lastCashView() external returns (uint256) envfree;
    function MockDoorVault.lastClosesView() external returns (bool) envfree;
    function MockDoorVault.curatorView() external returns (address) envfree;
    function MockDoorReceipt.debtView() external returns (uint256) envfree;
    function MockDoorReceipt.sweptView() external returns (bool) envfree;
    function MockAccountFactory.isAccount(address) external returns (bool) envfree;

    // the receipt's four reads and verbs, which arrive through an argument: a typed call the catch-all below does not
    // reach (the first run took `settle()` as an AUTO havoc, which rewrote the asset's balances), so dispatched by name
    function _.settle() external => DISPATCHER(true);
    function _.sweep() external => DISPATCHER(true);
    function _.seniorDebt() external => DISPATCHER(true);
    function _.swept() external => DISPATCHER(true);

    unresolved external in _._ => DISPATCH [
        DummyERC20.transfer(address, uint256),
        DummyERC20.transferFrom(address, address, uint256),
        DummyERC20.approve(address, uint256),
        DummyERC20.balanceOf(address),
        MockDoorVault.returnProceeds(address, uint256, bool),
        MockDoorVault.CURATOR(),
        MockDoorReceipt.settle(),
        MockDoorReceipt.sweep(),
        MockDoorReceipt.seniorDebt(),
        MockDoorReceipt.swept(),
        MockAccountFactory.isAccount(address)
    ] default NONDET;
}

// the four parties are four different contracts, as deployed: the terms, the vault, the asset and the receipt
function apart() {
    require currentContract != vault && currentContract != rcpt && vault != rcpt;
    require asset != currentContract && asset != vault && asset != rcpt;
}

// ---- D1: custody rewards ----

// EVERY UNIT OF CASH HERE GOES TO THE VAULT UNDER THE ASSET KEY, CLOSING NOTHING, AND NONE STAYS
rule custodyRewardsPayTheVaultUnderTheAssetKey(env e) {
    apart();
    mathint b0 = asset.balanceOf(currentContract);
    mathint v0 = asset.balanceOf(vault);
    mathint c0 = vault.callsView();

    uint256 credited = creditCustodyRewards(e);

    assert to_mathint(credited) == b0, "the credit is not the whole of the cash here";
    assert asset.balanceOf(currentContract) == 0, "cash stayed with the terms";
    assert asset.balanceOf(vault) - v0 == b0, "the vault did not gain the whole of it";
    assert credited > 0 => (to_mathint(vault.callsView()) == c0 + 1 && vault.lastKeyView() == ASSET()), "the credit was returned under another key";
    assert credited > 0 => (vault.lastCashView() == credited && !vault.lastClosesView()), "the credit closed a key or named other cash";
    assert credited == 0 => to_mathint(vault.callsView()) == c0, "a credit of nothing called the vault";
}

// ---- D2, D3: the sale and the sweep ----

// A SALE RETURNS EXACTLY WHAT `settle` PAID, AGAINST THE RECEIPT, AND CLOSES ITS KEY; the terms keep none of it
rule aSaleReturnsItsCashAndClosesTheKey(env e, address receipt) {
    apart();
    require receipt == rcpt && factory.isAccount(rcpt);
    mathint b0 = asset.balanceOf(currentContract);
    mathint r0 = asset.balanceOf(rcpt);
    mathint c0 = vault.callsView();

    uint256 got = collectSaleProceeds(e, receipt);

    assert r0 - asset.balanceOf(rcpt) == to_mathint(got), "the return is not what the receipt paid";
    assert to_mathint(asset.balanceOf(currentContract)) == b0, "the terms kept or spent cash of their own";
    assert to_mathint(vault.callsView()) == c0 + 1 && vault.lastKeyView() == receipt, "the sale was not returned against its receipt";
    assert vault.lastCashView() == got && vault.lastClosesView(), "the sale's return named other cash or left the key open";
}

// A SWEEP RETURNS EXACTLY WHAT `sweep` PAID, AGAINST THE RECEIPT, CLOSING THE KEY EXACTLY WHEN D IS PAID; nothing to
// return on an open key calls the vault not at all
rule aSweepClosesTheKeyOnlyOnceTheClaimIsPaid(env e, address receipt) {
    apart();
    require receipt == rcpt && factory.isAccount(rcpt);
    mathint b0 = asset.balanceOf(currentContract);
    mathint r0 = asset.balanceOf(rcpt);
    mathint c0 = vault.callsView();

    uint256 got = sweepLost(e, receipt);
    bool closes = rcpt.debtView() == 0;

    assert e.msg.sender == vault.curatorView(), "a caller other than the curator swept";
    assert r0 - asset.balanceOf(rcpt) == to_mathint(got), "the return is not what the receipt paid";
    assert to_mathint(asset.balanceOf(currentContract)) == b0, "the terms kept or spent cash of their own";
    assert (got != 0 || closes) => (to_mathint(vault.callsView()) == c0 + 1 && vault.lastKeyView() == receipt),
        "the sweep was not returned against its receipt";
    assert (got != 0 || closes) => (vault.lastCashView() == got && vault.lastClosesView() == closes),
        "the sweep's return named other cash, or closed the key other than once D was paid";
    assert (got == 0 && !closes) => to_mathint(vault.callsView()) == c0, "an empty sweep on an open key called the vault";
}

// ---- D4: a receipt's later cash ----

// A RECEIPT'S LATER CASH PASSES ON WHOLE: against its key while a sweep left it open, closing it once the cash covers D;
// otherwise a plain transfer to the vault, no key named
rule laterCashPassesToTheVaultWhole(env e, uint256 amount) {
    apart();
    require e.msg.sender == rcpt && factory.isAccount(rcpt);
    bool sweptBefore = rcpt.sweptView();
    mathint debt = rcpt.debtView();
    mathint b0 = asset.balanceOf(currentContract);
    mathint v0 = asset.balanceOf(vault);
    mathint c0 = vault.callsView();

    returnClaimed(e, amount);

    assert to_mathint(asset.balanceOf(currentContract)) == b0, "the terms kept or spent cash of their own";
    assert asset.balanceOf(vault) - v0 == to_mathint(amount), "the vault did not gain the whole of the later cash";
    assert !sweptBefore => to_mathint(vault.callsView()) == c0, "later cash of a receipt sold by a sale was returned against a key";
    assert (sweptBefore && (amount != 0 || amount >= debt)) => (to_mathint(vault.callsView()) == c0 + 1 && vault.lastKeyView() == rcpt),
        "later cash of a swept receipt was not returned against its key";
    assert (sweptBefore && (amount != 0 || amount >= debt)) => (vault.lastCashView() == amount && vault.lastClosesView() == (amount >= debt)),
        "later cash of a swept receipt named other cash, or closed the key other than once it covered D";
}

rule witnessASaleReturnsCash(env e, address receipt) {
    require receipt == rcpt;
    uint256 got = collectSaleProceeds(e, receipt);
    satisfy got > 0;
}

rule witnessASweepClosesTheKey(env e, address receipt) {
    require receipt == rcpt;
    sweepLost(e, receipt);
    satisfy vault.lastClosesView() && vault.lastKeyView() == receipt;
}
