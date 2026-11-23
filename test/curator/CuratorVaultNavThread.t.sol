// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.36;

import {CuratorVaultBase} from "./CuratorVaultBase.sol";
import {AceVault} from "../../src/vault/AceVault.sol";

/// @title CuratorVaultNavThread
/// @notice What a verb's NAV, read once, carries THROUGH an exit and a claim: the claim's rounding direction.
/// @notice Also the fee mint's supply-only effect, and the hold a partial claim leaves the request.
/// @dev The rows that pinned a NAV-overriding subclass went with the virtual `totalAssets`: the vault's NAV is no product's to override.
contract CuratorVaultNavThreadTest is CuratorVaultBase {
    uint256 internal constant SEED = 10_000e6;
    uint256 internal constant SMALL = 1_000e6;
    uint256 internal constant DRAW = 6_000e6;
    uint256 internal constant THIN_DRAW = 10_000e6; // all but a tenth of the book, so bob's small order is cash-bound
    uint16 internal constant FEE = 2000; // never zero on a fee row: at zero the pending term vanishes

    // ---- fixtures ----

    /// @dev Alice the whale and bob small, with most of the cash drawn out, and bob's whole position requested.
    /// @dev The draw's own gain is recognized first, so nothing vests under the request.
    function _railStood(AceVault v) internal returns (uint256 loanId) {
        _lpDeposit(v, alice, SEED);
        _lpDeposit(v, bob, SMALL);
        loanId = _open(THIN_DRAW);
        _crankAndRecognize(v);
        uint256 heldBob = v.balanceOf(bob); // BEFORE the prank: a read is a call, and a call would eat it
        vm.prank(bob);
        v.requestExit(heldBob);
    }

    /// @dev A NAV with an awkward remainder: a month of accrual banked, then matured, so nothing moves the price before the claim.
    function _awkwardNav(AceVault v) internal {
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

    // ---- the claim's rounding direction ----

    /// @notice A claim rounds the assets paid DOWN, as `redeem` does: the vault never overpays a leaver.
    function test_Rounding_AClaimFloorsTheAssetsPaidOut() public {
        AceVault v = _newVault(0);
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
        AceVault v = _newVault(FEE);
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
        AceVault v = _newVault(0);
        uint256 loanId = _railStood(v);
        (uint256 want,) = vlens.requestOf(address(v), bob);

        uint256 snap = vm.snapshotState();
        _repay(loanId, DRAW / 2);
        _crankAll(v);
        (, uint256 whole) = vlens.holds(address(v)); // the request's whole hold, as placed
        vm.revertToState(snap);

        uint256 can = want / 2;
        uint256 quote = v.previewRedeem(can);
        vm.prank(bob);
        uint256 paid = v.claimExit(can, bob, 0);
        assertEq(paid, quote, "the claim paid other than its own price");
        (uint256 left,) = vlens.requestOf(address(v), bob);
        assertEq(left, want - can, "the unclaimed remainder stands, to the share");
        assertEq(vlens.requestedShares(address(v)), want - can, "and the vault's own total request shrank with it");

        _repay(loanId, DRAW / 2);
        _crankAll(v);
        (, uint256 remainder) = vlens.holds(address(v));
        assertGt(remainder, 0, "the request still holds cash for what is left standing");
        assertLt(remainder, whole, "but strictly less than the request as placed: the claim re-priced the hold");
        assertApproxEqAbs(remainder, whole - paid, 2, "and re-priced it by exactly what the claim paid out");
    }
}
