// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.36;

import {AceVaultFlows} from "../../../src/curator/libraries/AceVaultFlows.sol";
import {AceVaultRig} from "./AceVaultRig.sol";

/// @title Review_ExemptionOverVestingSale
/// @notice Krait review, an ACV-2 sibling, fixed: the guardian's dead-pot exemption clears the unsold leg while another pot's sale cash still vests.
/// @notice Two loans default; one pot sells and its cash vests while the other keeps entry shut; the exemption starts the trough hold like a sale.
contract Review_ExemptionOverVestingSale is AceVaultRig {
    uint256 internal constant ENTRY = 1_000_000e6;
    bytes4 internal constant RECOVERY_VESTING = bytes4(keccak256("RecoveryVesting()"));

    function _enterAs(address who, uint256 amt) internal returns (uint256 shares) {
        usdc.mint(who, amt);
        vm.startPrank(who);
        usdc.approve(address(vault), amt);
        shares = vault.deposit(amt, who);
        vm.stopPrank();
    }

    function _worth(address who) internal view returns (uint256) {
        return vault.previewRedeem(vault.balanceOf(who));
    }

    /// @dev The second entry reopens, from the vest word's bits 200-247.
    function _hold() internal view returns (uint256) {
        bytes32[] memory s = new bytes32[](1);
        s[0] = bytes32(uint256(AceVaultFlows.ROOT) + 2);
        return uint48(uint256(vault.extsload(s)[0]) >> 200);
    }

    /// @dev Two loans lapse and are force-closed; a crank marks the trough; after the hold a stranger buys the first pot only.
    function _stage() internal returns (uint256 paid) {
        uint256 sold = _borrowAs(borrower, 60_000e18, 40_000e6, MIN_TENOR);
        uint256 dead = _borrowAs(borrower, 2_000e18, 1_000e6, MIN_TENOR);
        _warpAtLeastTo(_expiry(dead) > _expiry(sold) ? _expiry(dead) : _expiry(sold));
        vm.startPrank(keeper);
        ace.forceClose(sold);
        ace.forceClose(dead);
        vm.stopPrank();
        vm.prank(bob);
        vault.crank();
        _warpBy(1 hours);
        uint256 budget = 10_000_000e6;
        usdc.mint(stranger, budget);
        vm.startPrank(stranger);
        usdc.approve(address(ace), budget);
        (, paid) = ace.buyInventory(sold, budget, 0, stranger);
        vm.stopPrank();
        vault.crank();
    }

    function test_Review_theExemptionHoldsEntryUntilASoldPotsCashVests() public {
        uint256 paid = _stage();
        (uint256 u, uint256 s) = ace.lenderUnresolved(address(vault), address(usdc));
        assertEq(u, 1, "premise: one pot is still unsold");
        assertEq(vault.maxDeposit(bob), 0, "premise: the unsold pot keeps entry shut");
        uint256 pile = vault.unvested();
        assertGt(pile, 0, "premise: the sold pot's cash is vesting");

        vm.prank(guardian);
        vault.exemptDeadPots(s);
        uint256 trough = vault.totalAssets();
        assertLe(pile * 10_000, trough * vault.GATE_BPS(), "premise: the vesting cash sits inside the band");
        assertEq(vault.maxDeposit(bob), 0, "the exemption reopened entry while the sale's cash vests");
        assertEq(vault.maxMint(bob), 0, "and so did maxMint");
        usdc.mint(bob, ENTRY);
        vm.startPrank(bob);
        usdc.approve(address(vault), ENTRY);
        vm.expectRevert(RECOVERY_VESTING);
        vault.deposit(ENTRY, bob);
        vm.stopPrank();
        vault.crank(); // the next sync, anyone's, stores the hold
        uint256 hold = _hold();
        _warpTo(hold);
        assertEq(vault.unvested(), 0, "premise: the sold pot's cash has vested at the hold");
        uint256 snap = vm.snapshotState();

        uint256 sb = _enterAs(bob, ENTRY);
        _warpBy(VEST_W);
        vault.crank();
        vm.prank(bob);
        uint256 out = vault.redeem(sb, bob, bob);
        uint256 aliceAttacked = _worth(alice);
        vm.revertToState(snap);

        _warpBy(VEST_W);
        vault.crank();
        uint256 aliceClean = _worth(alice);

        emit log_named_uint("R, the sold pot's price", paid);
        emit log_named_uint("pile at the exemption", pile);
        emit log_named_uint("T at the exemption", trough);
        emit log_named_uint("entrant's redemption after one window", out);

        assertLe(out, ENTRY, "the entrant took a share of the sold pot's recovery");
        assertApproxEqAbs(out, ENTRY, 2, "the entrant was not paid its entry back to two atoms");
        assertGe(aliceAttacked + 1, aliceClean, "the stayers lost more than an atom to the entrant");
    }
}
