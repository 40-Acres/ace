// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.36;

import {AceVault} from "../../src/curator/AceVault.sol";
import {VaultConfig} from "../../src/curator/AceVaultFlows.sol";
import {InKindRig} from "./InKindRig.sol";

/// @title InKindEmptyVaultEntry
/// @notice In kind, a batch with no tracked holder waits for the first one, and a stranger's tracker step cannot hold entry shut against it.
/// @notice The same-block shut binds only while a holder is tracked: with none, nobody carried the loss, so the first entrant takes the pot.
contract InKindEmptyVaultEntryTest is InKindRig {
    /// @dev alice, the only holder, exits whole after a stranger settles her vault's loan; the pot then comes home into the empty vault.
    function _potIntoAnEmptyVault() internal returns (uint256 pot) {
        _lp(alice, LP_CASH);
        uint256 loanId = _open(address(tokA));
        _toExpiry(loanId);
        pot = _expectedPot(loanId);
        vm.prank(stranger);
        ace.forceClose(loanId);
        vault.crank();
        uint256 all = vault.balanceOf(alice);
        vm.prank(alice);
        vault.redeem(all, alice, alice);
        assertEq(vault.totalSupply(), vault.SEED_SHARES(), "PREMISE: alice left whole, the genesis seed alone remaining");
        assertEq(_trackedSupply(), 0, "PREMISE: no tracked holder is left");
        assertEq(_collect(loanId), pot, "PREMISE: the pot came home into the empty vault");
    }

    /// @notice A stranger's empty claim at the top of a block re-stamps the waiting batch; the first entrant in that block still lands and takes the pot.
    function test_aStrangersClaimCannotHoldEntryShutOverAnEmptyVault() public {
        uint256 pot = _potIntoAnEmptyVault();
        _nextBlock();
        vm.prank(stranger);
        vault.claim(new address[](0), stranger);
        assertGt(vault.maxDeposit(bob), 0, "the view held entry shut over a batch no holder carried");
        assertGt(vault.maxMint(bob), 0, "and so did maxMint");
        assertGt(_lp(bob, LP_CASH), 0, "the first entrant was refused in the block a stranger's claim re-stamped");
        _expectEntryShut(carol, LP_CASH, "a second entrant in that block, now that a holder is tracked");
        _nextBlock();
        assertEq(_claim(bob, address(tokA)), pot, "the first holder did not take the whole pot");
    }

    /// @notice With a holder tracked the collect's own block still shuts entry, and the next block admits an entrant credited none of the pot.
    function test_withAHolderTrackedTheCollectsBlockStaysShut() public {
        _lp(alice, LP_CASH);
        uint256 pot = _defaultAndCollect(_open(address(tokA)));
        assertGt(_trackedSupply(), 0, "PREMISE: alice is tracked");
        _expectEntryShut(bob, LP_CASH, "a same-block entrant over a tracked holder");
        _nextBlock();
        _lp(bob, LP_CASH);
        _nextBlock();
        assertEq(_claimable(bob, address(tokA)), 0, "the next block's entrant was credited the pot");
        assertApproxEqAbs(_claimable(alice, address(tokA)), pot, 1, "the tracked holder did not take it all");
    }

    /// @notice An in-kind vault naming itself as guardian refuses at deploy, as one naming none does: it could never exempt a pot.
    function test_anInKindVaultRefusesItselfAsGuardian() public {
        VaultConfig memory c = _cfg(0);
        c.guardian = vm.computeCreateAddress(address(this), vm.getNonce(address(this)) + 1); // the vault's address, the terms being created first
        vm.expectRevert(AceVault.ZeroGuardian.selector);
        this.deployExternal(c, _ik(), _listings());
    }
}
