// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.36;

import {AceVaultFlows} from "../../../src/curator/AceVaultFlows.sol";
import {AceVaultRig} from "./AceVaultRig.sol";

/// @title BlindSca_TroughEntryAfterSale
/// @notice RSCA-2 PoC, fixed: the unsold-pot gate lifts the moment a hub pot sells, and the sale's proceeds then VEST, so NAV still reads the trough.
/// @notice The trough hold keeps entry shut until those proceeds have vested: a depositor after the hold buys at the recovered price and takes nothing.
/// @dev Non-atomic on purpose: the attacker holds across the window, so only a hold that outlasts the vest defends it.
contract BlindSca_TroughEntryAfterSale is AceVaultRig {
    uint256 internal constant P = 40_000e6; // 4% of the rig's 1,000,000 NAV
    uint256 internal constant BIG_UNITS = 60_000e18; // the line is about 31,000 units at the buffered 1.8 price
    bytes4 internal constant RECOVERY_VESTING = bytes4(keccak256("RecoveryVesting()"));

    /// @dev A loan of `P` runs to expiry unpaid and is force-closed; its pot then waits out the hub's inventory hold.
    function _defaultToPot() internal returns (uint256 loanId) {
        loanId = _borrowAs(borrower, BIG_UNITS, P, MIN_TENOR);
        _warpAtLeastTo(_expiry(loanId));
        vm.prank(keeper);
        ace.forceClose(loanId);
        vm.prank(bob);
        vault.crank(); // any sync now, an LP's exit or this permissionless crank, marks the trough
        _warpBy(1 hours); // the hub's inventory hold for a week-long minTenor
    }

    /// @dev `who` buys the whole settled pot at the hub's ask.
    function _buyPot(address who, uint256 loanId) internal returns (uint256 paid) {
        uint256 budget = 1_000_000e6;
        usdc.mint(who, budget);
        vm.startPrank(who);
        usdc.approve(address(ace), budget);
        (, paid) = ace.buyInventory(loanId, budget, 0, who);
        vm.stopPrank();
    }

    function _enterAs(address who, uint256 amt) internal returns (uint256 shares) {
        usdc.mint(who, amt);
        vm.startPrank(who);
        usdc.approve(address(vault), amt);
        shares = vault.deposit(amt, who);
        vm.stopPrank();
    }

    /// @dev The second entry reopens, from the vest word's bits 200-247.
    function _hold() internal view returns (uint256) {
        bytes32[] memory s = new bytes32[](1);
        s[0] = bytes32(uint256(AceVaultFlows.ROOT) + 2);
        return uint48(uint256(vault.extsload(s)[0]) >> 200);
    }

    function test_RSCA2_entryRightAfterTheSaleIsHeldUntilTheRecoveryVests() public {
        uint256 loanId = _defaultToPot();
        (uint256 unsold,) = ace.lenderUnresolved(address(vault), address(usdc));
        assertEq(unsold, 1, "premise: the pot stands unsold, so entry is shut");
        assertEq(vault.maxDeposit(bob), 0, "premise: the unsold-pot gate holds entry shut");

        uint256 recovery = _buyPot(stranger, loanId);
        vault.crank(); // the sale's own block: the recovery is observed and starts to vest, in both branches alike
        (unsold,) = ace.lenderUnresolved(address(vault), address(usdc));
        assertEq(unsold, 0, "the pot sold whole");
        uint256 trough = vault.totalAssets();
        emit log_named_uint("recovery paid into the vault's pool", recovery);
        emit log_named_uint("totalAssets right after the sale (trough)", trough);
        emit log_named_uint("unvested right after the sale", vault.unvested() + 0);
        assertEq(vault.maxDeposit(bob), 0, "entry reopened the same block the pot sold");
        usdc.mint(bob, LP_CASH);
        vm.startPrank(bob);
        usdc.approve(address(vault), LP_CASH);
        vm.expectRevert(RECOVERY_VESTING);
        vault.deposit(LP_CASH, bob);
        vm.stopPrank();

        _warpTo(_hold());
        assertEq(vault.unvested(), 0, "premise: the recovery has vested at the hold");
        uint256 aliceBefore = vault.previewRedeem(vault.balanceOf(alice));
        uint256 snap = vm.snapshotState();

        // ---- the attack, now: bob enters at the hold's second and holds one vest window ----
        uint256 sb = _enterAs(bob, LP_CASH);
        _warpBy(VEST_W);
        vault.crank();
        uint256 aliceAttacked = vault.previewRedeem(vault.balanceOf(alice));
        vm.prank(bob);
        uint256 got = vault.redeem(sb, bob, bob);
        vm.revertToState(snap);

        // ---- the counterfactual: nobody enters ----
        _warpBy(VEST_W);
        vault.crank();
        uint256 aliceClean = vault.previewRedeem(vault.balanceOf(alice));

        emit log_named_uint("bob deposited", LP_CASH);
        emit log_named_uint("bob redeemed after one vest window", got);
        emit log_named_uint("alice at the hold", aliceBefore);
        emit log_named_uint("alice after the vest, bob in", aliceAttacked);
        emit log_named_uint("alice after the vest, nobody in", aliceClean);

        assertLe(got, LP_CASH, "bob took a share of a recovery he never funded");
        assertApproxEqAbs(got, LP_CASH, 2, "bob was not paid his deposit back to two atoms");
        assertGe(aliceAttacked + 1, aliceClean, "alice, who bore the loss, lost more than an atom");
    }
}
