// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.36;

import {ERC4626} from "@openzeppelin/contracts/token/ERC20/extensions/ERC4626.sol";
import {AceVaultRig} from "./AceVaultRig.sol";

/// @notice The one hold: the requests' hold no placement may take. A live loan holds no idle back from an exit.
/// @dev exitable = idle; heldReq = draining ? 0 : min(exitable, requests' worth); lendable = draining ? 0 : exitable - heldReq.
contract AceVaultHoldsTest is AceVaultRig {
    /// @notice With nothing lent and nothing requested, the whole idle is exitable and lendable.
    function test_AnEmptyBookHoldsNothing() public view {
        assertEq(vault.lendable(), LP_CASH, "all idle is lendable");
        assertEq(vault.maxWithdraw(alice), LP_CASH, "and exitable by its holder");
    }

    /// @notice A redeem past the exit bound is refused as an over-redeem, naming the bound `maxRedeem` reads.
    function test_ARedeemPastTheHoldIsAnOverRedeem() public {
        _borrow(MAX_TENOR);
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

    /// @notice A claim takes exitable cash, held cash first.
    function test_AClaimTakesExitableButNotTheRollHold() public {
        _borrow(MAX_TENOR);
        uint256 shares = vault.balanceOf(alice);
        vm.prank(alice);
        vault.requestExit(shares);
        uint256 claimable = vault.maxClaim(alice);
        assertGt(claimable, 0, "premise: some of the request is claimable");
        vm.prank(alice);
        vault.claimExit(claimable, alice, 0);
    }

    /// @notice While draining, instant exits take all of exitable and nothing is lendable.
    function test_DrainingExitsTakeAllOfExitable() public {
        _borrow(MAX_TENOR);
        uint256 bobShares = _lp(bob, 100_000e6);
        vm.prank(bob);
        vault.requestExit(bobShares);
        _warpBy(VEST_W + 1);
        uint256 exitable = vault.idle();
        uint256 aliceWorth = vault.previewRedeem(vault.balanceOf(alice));
        assertLt(vault.maxWithdraw(alice), aliceWorth, "premise: undrained, bob's request holds alice under her worth");
        assertGt(exitable, aliceWorth, "premise: exitable alone would cover her");
        vm.prank(curator);
        vault.setDrain(true);
        assertEq(vault.lendable(), 0, "a drain lends nothing");
        assertEq(vault.maxWithdraw(alice), aliceWorth, "a drained instant exit reaches past the request hold, first come");
    }

    /// @notice Draining, the last holder's exit takes all of idle: with the roll hold deleted, nothing stands behind it.
    function test_DrainedExitsStillLeaveTheRollHold() public {
        _borrow(MAX_TENOR);
        _warpBy(VEST_W + 1);
        vm.prank(curator);
        vault.setDrain(true);
        uint256 m = vault.maxWithdraw(alice);
        vm.prank(alice);
        vault.withdraw(m, alice, alice);
        assertEq(vault.idle(), 0, "the drained exit took every idle unit");
    }
}
