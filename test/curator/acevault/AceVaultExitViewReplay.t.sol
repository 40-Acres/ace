// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.36;

import {AceVaultRig} from "./AceVaultRig.sol";

/// @title AceVaultExitViewReplay
/// @notice The exit views read the pile the verb's own sync will leave, never the stored one, so their answers pay across an unsynced move.
/// @notice `maxClaim` replays the last requester's release at the gross the claim's sync reads; `maxRedeem` drops its last-out zero once a fall burns the pile.
/// @dev Fee-free on purpose: the property is which pile and which gross the views read, which a fee term would only scale.
contract AceVaultExitViewReplayTest is AceVaultRig {
    /// @dev Half of NAV is lent, so idle binds a whole-supply request; alice, the only holder, requests every share; no pile stands.
    function _soleRequestOverLentCash() internal returns (uint256 all) {
        _borrowAs(borrower, 1_000_000e18, 500_000e6, MIN_TENOR);
        _warpBy(VEST_W + 1);
        vault.crank();
        assertEq(vault.unvested(), 0, "PREMISE: no pile stands");
        all = vault.balanceOf(alice);
        assertEq(all + vault.SEED_SHARES(), vault.totalSupply(), "PREMISE: alice is the only holder, so her request is the last");
        vm.prank(alice);
        vault.requestExit(all);
    }

    /// @notice Over an unsynced rise, the sole requester's cash-bound `maxClaim` pays and takes idle to two wei: it priced the rise in.
    function test_MaxClaim_ACashBoundAnswerOverAnUnsyncedRisePaysAndTakesIdle() public {
        uint256 all = _soleRequestOverLentCash();
        usdc.mint(address(vault), 10_000e6);
        uint256 idle = vault.idle();
        assertGt(vault.grossNav() - vault.totalAssets(), 0, "PREMISE: the rise is unsynced, so the view must replay it");
        uint256 shares = vault.maxClaim(alice);
        assertLt(shares, all, "PREMISE: idle binds the answer, not the request");
        vm.prank(alice);
        uint256 paid = vault.claimExit(shares, alice, 0);
        assertLe(paid, idle, "the claim paid past idle");
        assertApproxEqAbs(paid, idle, 2, "maxClaim's answer left idle behind: it priced the release under the claim's gross");
    }

    /// @notice CONTROL: with the rise synced first, the same answer pays and takes idle to two wei.
    function test_MaxClaim_ACashBoundAnswerAfterASyncedRisePaysAndTakesIdle() public {
        uint256 all = _soleRequestOverLentCash();
        usdc.mint(address(vault), 10_000e6);
        vault.crank();
        uint256 idle = vault.idle();
        uint256 shares = vault.maxClaim(alice);
        assertLt(shares, all, "PREMISE: idle binds the answer, not the request");
        vm.prank(alice);
        uint256 paid = vault.claimExit(shares, alice, 0);
        assertLe(paid, idle, "the claim paid past idle");
        assertApproxEqAbs(paid, idle, 2, "maxClaim's answer left idle behind");
    }

    /// @notice A stored pile that an unsynced fall will burn does not zero the last holder's `maxRedeem`, and redeeming it pays the preview.
    function test_MaxRedeem_TheLastHolderOverAnUnsyncedFallThatBurnsThePileMayExit() public {
        uint256 loanId = _borrowAs(borrower, 60_000e18, 40_000e6, MIN_TENOR);
        _warpAtLeastTo(_expiry(loanId));
        usdc.mint(address(vault), 10e6);
        vault.crank();
        assertGt(vault.unvested(), 0, "PREMISE: a pile is stored");
        vm.prank(keeper);
        ace.forceClose(loanId);
        assertEq(vault.grossNav() - vault.totalAssets(), 0, "PREMISE: the unsynced fall will burn the whole stored pile");
        assertGt(vault.unvested(), 0, "PREMISE: and the stored pile still reads nonzero");
        assertEq(vault.balanceOf(alice) + vault.SEED_SHARES(), vault.totalSupply(), "PREMISE: alice is the only holder, so the last-out zero is in play");
        uint256 max = vault.maxRedeem(alice);
        assertGt(max, 0, "maxRedeem zeroed the last holder over a pile the verb's own sync burns");
        uint256 quoted = vault.previewRedeem(max);
        vm.prank(alice);
        assertEq(vault.redeem(max, alice, alice), quoted, "the redeem of maxRedeem did not pay its preview");
    }
}
