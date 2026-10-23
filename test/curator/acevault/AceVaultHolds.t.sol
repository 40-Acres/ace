// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.36;

import {ERC4626} from "@openzeppelin/contracts/token/ERC20/extensions/ERC4626.sol";
import {AceVaultRig} from "./AceVaultRig.sol";

/// @notice The two holds: the roll hold no exit may take, and the requests' hold no placement may take.
/// @dev exitable = idle - rollHoldNow; heldReq = draining ? 0 : min(exitable, requests' worth); lendable = draining ? 0 : exitable - heldReq.
contract AceVaultHoldsTest is AceVaultRig {
    /// @notice With nothing armed and nothing requested, the whole idle is exitable and lendable.
    function test_AnEmptyBookHoldsNothing() public view {
        assertEq(vault.rollHoldNow(), 0, "no hold on an empty book");
        assertEq(vault.lendable(), LP_CASH, "all idle is lendable");
        assertEq(vault.maxWithdraw(alice), LP_CASH, "and exitable by its holder");
    }

    /// @notice An instant exit takes idle less the roll hold, and asking past it is refused by ERC-4626's own max refusal.
    function test_InstantExitsLeaveTheRollHold() public {
        _borrow(MAX_TENOR, true);
        _warpBy(VEST_W + 1); // the fee credit vests first, so the sole holder is not refused as the last one out
        uint256 hold = vault.rollHoldNow();
        assertGt(hold, 0, "premise: an armed loan holds");
        uint256 free = vault.idle() - hold;
        assertEq(vault.maxWithdraw(alice), free, "the instant exit stops at the hold");
        vm.prank(alice);
        vm.expectRevert(abi.encodeWithSelector(ERC4626.ERC4626ExceededMaxWithdraw.selector, alice, free + 1, free));
        vault.withdraw(free + 1, alice, alice);
        vm.prank(alice);
        vault.withdraw(free, alice, alice);
        assertEq(vault.idle(), hold, "law: the exit left idle at the roll hold, never under it");
    }

    /// @notice A redeem past the hold is refused as an over-redeem, naming the bound `maxRedeem` reads.
    function test_ARedeemPastTheHoldIsAnOverRedeem() public {
        _borrow(MAX_TENOR, true);
        _warpBy(VEST_W + 1);
        uint256 max = vault.maxRedeem(alice);
        uint256 ask = max + 1e12;
        vm.prank(alice);
        vm.expectRevert(abi.encodeWithSelector(ERC4626.ERC4626ExceededMaxRedeem.selector, alice, ask, max));
        vault.redeem(ask, alice, alice);
    }

    /// @notice A standing request holds exitable cash from placements and from other holders' instant exits.
    function test_ARequestHoldsCashFromPlacements() public {
        uint256 bobShares = _lp(bob, 100_000e6);
        vm.prank(bob);
        vault.requestExit(bobShares);
        uint256 worth = vault.previewRedeem(bobShares);
        assertApproxEqAbs(vault.lendable(), vault.idle() - worth, 2, "lendable is exitable less the requests' worth");
        assertApproxEqAbs(vault.maxWithdraw(alice), vault.idle() - worth, 2, "alice's instant exit leaves bob's held cash");
    }

    /// @notice A claim takes exitable cash, held cash first; it never takes the roll hold.
    function test_AClaimTakesExitableButNotTheRollHold() public {
        _borrow(MAX_TENOR, true);
        uint256 hold = vault.rollHoldNow();
        uint256 shares = vault.balanceOf(alice);
        vm.prank(alice);
        vault.requestExit(shares);
        uint256 claimable = vault.maxClaim(alice);
        assertGt(claimable, 0, "premise: some of the request is claimable");
        vm.prank(alice);
        vault.claimExit(claimable, alice, 0);
        assertGe(vault.idle(), hold, "law: a claim never leaves idle under the roll hold");
    }

    /// @notice While draining, instant exits take all of exitable and nothing is lendable.
    function test_DrainingExitsTakeAllOfExitable() public {
        _borrow(MAX_TENOR, true);
        uint256 bobShares = _lp(bob, 100_000e6);
        vm.prank(bob);
        vault.requestExit(bobShares);
        _warpBy(VEST_W + 1);
        uint256 exitable = vault.idle() - vault.rollHoldNow();
        uint256 aliceWorth = vault.previewRedeem(vault.balanceOf(alice));
        assertLt(vault.maxWithdraw(alice), aliceWorth, "premise: undrained, bob's request holds alice under her worth");
        assertGt(exitable, aliceWorth, "premise: exitable alone would cover her");
        vm.prank(curator);
        vault.setDrain(true);
        assertEq(vault.lendable(), 0, "a drain lends nothing");
        assertEq(vault.maxWithdraw(alice), aliceWorth, "a drained instant exit reaches past the request hold, first come");
    }

    /// @notice Exits never take the roll hold, even draining, even the last holder.
    function test_DrainedExitsStillLeaveTheRollHold() public {
        _borrow(MAX_TENOR, true);
        _warpBy(VEST_W + 1);
        vm.prank(curator);
        vault.setDrain(true);
        uint256 hold = vault.rollHoldNow();
        uint256 m = vault.maxWithdraw(alice);
        vm.prank(alice);
        vault.withdraw(m, alice, alice);
        assertEq(vault.idle(), hold, "law: the drain does not release the roll hold");
    }
}
