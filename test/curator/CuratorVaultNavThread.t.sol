// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.36;

import {CuratorVaultBase} from "./CuratorVaultBase.sol";
import {VaultConfig} from "../../src/curator/AceVault.sol";
import {CuratorVault, Listing} from "../../src/curator/CuratorVault.sol";

/// @notice A vault whose NAV can be nudged with no collection behind it, so a fee is genuinely pending.
/// @dev A local twin of the surface suite's `GrownNavVault`, so this file builds without that one.
contract ThreadGrownNavVault is CuratorVault {
    uint256 public extra;

    constructor(VaultConfig memory cfg, Listing[] memory l) CuratorVault(cfg, 10e6, 1.4e18, 1 days, l, "Grown", "cGROW") {}

    function grow(uint256 amount) external {
        extra += amount;
    }

    function totalAssets() public view override returns (uint256) {
        return super.totalAssets() + extra;
    }
}

/// @title CuratorVaultNavThread
/// @notice THE LAW OF THE THREADED NAV: a verb reads its NAV once, and it must read it at the SAME DOOR its previews do.
/// @notice That door is the `virtual` `totalAssets()`, never the gross under it: an override may lower NAV (the fixture raises it, to tell the two apart).
/// @notice A thread starting at the gross prices the verb off a number the preview never quoted, and misprices shares.
/// @dev The other rows pin what the thread carries THROUGH an exit and a claim: the claim's rounding direction.
/// @dev They also pin the fee mint's supply-only effect, and the hold a partial claim leaves the request.
contract CuratorVaultNavThreadTest is CuratorVaultBase {
    uint256 internal constant SEED = 10_000e6;
    uint256 internal constant SMALL = 1_000e6;
    uint256 internal constant DRAW = 6_000e6;
    uint256 internal constant THIN_DRAW = 10_000e6; // all but a tenth of the book, so bob's small order is cash-bound
    uint256 internal constant ENTRY = 1_000e6;
    uint256 internal constant WANT = 1_000e6 * 1e6; // the same size in shares, at the virtual offset
    uint256 internal constant GROWN = 1_000e6; // the NAV the subclass alone knows about
    uint16 internal constant FEE = 2000; // never zero on a fee row: at zero the pending term vanishes

    // ---- fixtures ----

    /// @dev A vault whose `totalAssets()` override sits ABOVE its gross, with a fee genuinely outstanding at the quote.
    /// @dev No loan is open: `grossNav` is then the balance alone, so every wei under assertion is the vault's own.
    function _grown() internal returns (ThreadGrownNavVault v) {
        v = new ThreadGrownNavVault(_cfg(FEE), _listing());
        _lpDeposit(v, alice, SEED);
        v.collectFee(); // the first mint prices against zero supply, so this is what stamps the fee mark
        v.grow(GROWN);
        assertEq(v.totalAssets(), v.grossNav() + GROWN, "fixture: the overridden NAV really is above the gross");
        assertGt(v.pendingFeeShares(), 0, "fixture: a fee is genuinely outstanding at the moment of the quote");
    }

    /// @dev Alice the whale and bob small, with most of the cash drawn out, and bob's whole position requested.
    /// @dev The draw's own gain is recognized first, so nothing vests under the request.
    function _railStood(CuratorVault v) internal returns (uint256 loanId) {
        _lpDeposit(v, alice, SEED);
        _lpDeposit(v, bob, SMALL);
        loanId = _open(THIN_DRAW);
        _crankAndRecognize(v);
        uint256 heldBob = v.balanceOf(bob); // BEFORE the prank: a read is a call, and a call would eat it
        vm.prank(bob);
        v.requestExit(heldBob);
    }

    /// @dev A NAV with an awkward remainder: a month of accrual banked, then matured, so nothing moves the price before the claim.
    function _awkwardNav(CuratorVault v) internal {
        _lpDeposit(v, alice, SEED);
        _lpDeposit(v, bob, SMALL);
        uint256 loanId = _open(DRAW);
        _crank(v, loanId, T2, 0);
        _warpBy(30 days);
        _repay(loanId, lens.loan(loanId).debt);
        _crankAll(v);
        _warpBy(VEST_W);
        assertEq(v.unvested(), 0, "fixture: nothing deferred, so nothing moves between the quote and the fill");
    }

    // ---- the headline: a NAV-overriding subclass ----

    /// @notice THE ROW THIS FILE EXISTS FOR, entry half: the verb prices off the OVERRIDDEN NAV, exactly as its preview did.
    /// @dev The plain vault leg is the LIVENESS: without it a broken thread and a working one could both go green here.
    function test_NavOverride_DepositMintsExactlyWhatPreviewDepositQuoted() public {
        ThreadGrownNavVault v = _grown();
        uint256 promised = v.previewDeposit(ENTRY);
        assertEq(_lpDeposit(v, bob, ENTRY), promised, "the deposit minted exactly what the preview quoted");

        CuratorVault plain = _deploy(_cfg(FEE), "Plain", "cPLN");
        _lpDeposit(plain, alice, SEED);
        plain.collectFee();
        assertGt(_lpDeposit(plain, bob, ENTRY), promised, "LIVENESS: the override is what makes the two quotes differ");
    }

    /// @notice The same law on `mint`, whose rounding runs the other way and whose error would be an over-pull.
    function test_NavOverride_MintPullsExactlyWhatPreviewMintQuoted() public {
        ThreadGrownNavVault v = _grown();
        uint256 promised = v.previewMint(WANT);
        usdc.mint(bob, 2 * promised);
        vm.startPrank(bob);
        usdc.approve(address(v), 2 * promised);
        uint256 pulled = v.mint(WANT, bob);
        vm.stopPrank();
        assertEq(pulled, promised, "the mint pulled exactly what the preview quoted");
        assertEq(v.balanceOf(bob), WANT, "and the share count asked for is what landed");
    }

    /// @notice The exit half: every exit door pays exactly what the overridden NAV prices, at the quote its preview gave.
    /// @dev A thread off the gross would miss the `GROWN` term, a tenth of NAV.
    function test_NavOverride_EveryExitAndTheClaimPayWhatTheOverriddenNavPrices() public {
        ThreadGrownNavVault v = _grown();
        uint256 sh = v.balanceOf(alice) / 8; // BEFORE the prank: a read is a call, and a call would eat it
        uint256 priced = v.previewRedeem(sh); // the overridden NAV, over the supply the verb's own fee leaves

        uint256 snap = vm.snapshotState();
        vm.prank(alice);
        assertEq(v.redeem(sh, alice, alice), priced, "redeem paid other than the overridden NAV's price");
        vm.revertToState(snap);
        uint256 burn = v.previewWithdraw(priced);
        vm.prank(alice);
        assertEq(v.withdraw(priced, alice, alice), burn, "withdraw spent other than its preview at the overridden NAV");
        vm.revertToState(snap);
        vm.prank(alice);
        v.requestExit(sh);
        vm.prank(alice);
        assertEq(v.claimExit(sh, alice, 0), priced, "and a claim of the same shares paid the same figure");
        assertEq(usdc.balanceOf(alice), priced, "to the holder");
    }

    // ---- the claim's rounding direction ----

    /// @notice A claim rounds the assets paid DOWN, as `redeem` does: the vault never overpays a leaver.
    function test_Rounding_AClaimFloorsTheAssetsPaidOut() public {
        CuratorVault v = _newVault(0);
        _awkwardNav(v);
        uint256 sh = v.balanceOf(alice) / 7;
        vm.prank(alice);
        v.requestExit(sh);
        uint256 floorAssets = v.convertToAssets(sh); // OZ's floor, at the price the claim is about to pay
        assertGt(v.previewMint(sh), floorAssets, "PREMISE: the division has a remainder, so the direction is observable");
        vm.prank(alice);
        assertEq(v.claimExit(sh, alice, 0), floorAssets, "the claim pays OZ's FLOOR of the ratio, never the ceil");
    }

    // ---- the fee mint, which a threaded verb holds its NAV across ----

    /// @notice A collection moves SUPPLY and never ASSETS, which is what makes a threaded NAV still correct after it.
    /// @dev Every verb calls `_collectFeeAt(a)` and then keeps using `a`; this is the property that licence rests on.
    function test_Fee_CollectionMovesSupplyAndNeverAssets() public {
        CuratorVault v = _newVault(FEE);
        _awkwardNav(v);
        uint256 pending = v.pendingFeeShares();
        assertGt(pending, 0, "PREMISE: a collection would mint shares right now");
        uint256 a = v.totalAssets();
        uint256 g = v.grossNav();
        uint256 s = v.totalSupply();

        v.collectFee();

        assertEq(v.grossNav(), g, "the mint moved nothing at the hub");
        assertEq(v.totalAssets(), a, "nor a wei of the NAV a threaded verb is holding across it");
        assertEq(v.totalSupply() - s, pending, "only the supply moved, and by exactly the pending fee");
    }

    // ---- a partial claim leaves a smaller request, and the hold reads it ----

    /// @notice A partial claim RE-PRICES what the request still holds: the same repayment then leaves strictly less held.
    /// @dev The hold is `min(exitable, worth(requestedShares))`, computed at read time, measured from one state before the claim and after it.
    /// @dev The repayment reaches the vault's balance at the crank, so each leg cranks it home before reading the hold.
    function test_Claim_APartialClaimPaysItsPriceAndRePricesWhatTheRequestHolds() public {
        CuratorVault v = _newVault(0);
        uint256 loanId = _railStood(v);
        (uint256 want,) = v.requestOf(bob);

        uint256 snap = vm.snapshotState();
        _repay(loanId, DRAW / 2);
        _crankAll(v);
        (, uint256 whole) = v.holds(); // the request's whole hold, as placed
        vm.revertToState(snap);

        uint256 can = want / 2;
        uint256 quote = v.previewRedeem(can);
        vm.prank(bob);
        uint256 paid = v.claimExit(can, bob, 0);
        assertEq(paid, quote, "the claim paid other than its own price");
        (uint256 left,) = v.requestOf(bob);
        assertEq(left, want - can, "the unclaimed remainder stands, to the share");
        assertEq(v.requestedShares(), want - can, "and the vault's own total request shrank with it");

        _repay(loanId, DRAW / 2);
        _crankAll(v);
        (, uint256 remainder) = v.holds();
        assertGt(remainder, 0, "the request still holds cash for what is left standing");
        assertLt(remainder, whole, "but strictly less than the request as placed: the claim re-priced the hold");
        assertApproxEqAbs(remainder, whole - paid, 2, "and re-priced it by exactly what the claim paid out");
    }
}
