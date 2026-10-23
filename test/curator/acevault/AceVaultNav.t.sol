// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.36;

import {AceVault} from "../../../src/curator/AceVault.sol";
import {AceVaultRig} from "./AceVaultRig.sol";

/// @notice NAV when the vault holds the cash: the asset balance plus the hub's (lender, asset) pool, nothing else.
/// @dev The NAV oracle here is the hub and the token, read directly; the vault's own figure is checked against them.
contract AceVaultNavTest is AceVaultRig {
    /// @notice An idle vault's gross is exactly its asset balance: the cash sits on the vault, not in a market.
    function test_IdleGrossIsTheBalance() public view {
        assertEq(vault.grossNav(), usdc.balanceOf(address(vault)), "gross is the balance before any loan");
        assertEq(vault.idle(), LP_CASH, "idle is the LP's cash");
        assertEq(ace.lenderAssets(address(vault), address(usdc)), 0, "nothing at the hub yet");
    }

    /// @notice After a borrow, gross is the balance plus the hub's pool, and it rose by exactly the lender's credited fee share.
    function test_GrossIsBalancePlusLenderAssets() public {
        uint256 g0 = vault.grossNav();
        uint256 owed0 = ace.lenderOwed(address(vault), address(usdc));
        uint256 loanId = _borrow(MIN_TENOR, false);
        uint256 bal = usdc.balanceOf(address(vault));
        uint256 pool = ace.lenderAssets(address(vault), address(usdc));
        assertEq(vault.grossNav(), bal + pool, "gross = balance + lenderAssets");
        assertEq(vault.grossNav() - g0, ace.lenderOwed(address(vault), address(usdc)) - owed0, "a draw moves gross by the credited fee alone");
        assertEq(bal, LP_CASH - PRINCIPAL, "the principal left idle and the payout passed through");
        _assertNothingRests(_mid(loanId));
    }

    /// @notice An armed borrow's hold moves no NAV: it only fences idle from exits and placements.
    /// @dev The same draw, armed and unarmed from one state, leaves gross, totalAssets and idle equal; lending loses exactly the hold.
    /// @dev Then the vault's roll re-books the hold and moves gross by the roll's fee credit alone, and totalAssets not at all.
    function test_TheRollHoldMovesNoNav() public {
        uint256 root = vm.snapshotState();
        _borrow(MAX_TENOR, false);
        (uint256 g0, uint256 t0, uint256 i0, uint256 l0) = (vault.grossNav(), vault.totalAssets(), vault.idle(), vault.lendable());
        assertEq(vault.rollHoldNow(), 0, "premise: the unarmed draw holds nothing");
        vm.revertToState(root);
        uint256 loanId = _borrow(MAX_TENOR, true);
        uint256 hold = vault.rollHoldNow();
        assertGt(hold, 0, "premise: the arm recorded a hold");
        assertEq(vault.grossNav(), g0, "the hold moves no gross");
        assertEq(vault.totalAssets(), t0, "nor totalAssets");
        assertEq(vault.idle(), i0, "nor idle: the arm rests nothing");
        assertEq(vault.lendable(), l0 - hold, "it fences exactly itself out of lending");

        _toWindow(loanId);
        uint256 owed = ace.lenderOwed(address(vault), address(usdc));
        (uint256 g1, uint256 t1, uint256 need1) = (vault.grossNav(), vault.totalAssets(), vault.rollHold());
        uint256 newId = vault.roll(loanId, "");
        assertTrue(vault.rollHold() != need1 && _need(newId) == vault.rollHold(), "premise: the roll re-booked the hold on the successor");
        assertEq(vault.grossNav() - g1, ace.lenderOwed(address(vault), address(usdc)) - owed, "a roll moves gross by its fee credit alone");
        assertEq(vault.totalAssets(), t1, "and totalAssets not at all, the hold re-booked or not");
    }

    /// @notice A raw landing of the asset is counted: gross rises at once and the rise vests.
    function test_ARawLandingIsACountedDonation() public {
        uint256 g0 = vault.grossNav();
        uint256 t0 = vault.totalAssets();
        usdc.mint(address(vault), 500e6);
        assertEq(vault.grossNav(), g0 + 500e6, "the landing is in gross");
        assertEq(vault.totalAssets(), t0, "and it vests rather than pricing at once");
    }

    /// @notice One wei landed on a single-holder vault refuses that holder's whole instant exit: the pile vests.
    function test_OneWeiRefusesTheLastFreeHoldersInstantExit() public {
        usdc.mint(address(vault), 1);
        uint256 all = vault.balanceOf(alice);
        vm.prank(alice);
        vm.expectRevert(AceVault.LastOutVesting.selector);
        vault.redeem(all, alice, alice);
    }

    /// @notice A crank turns the hub's credit into idle and leaves gross where it was.
    function test_CrankCollectsTheCreditIntoIdle() public {
        _borrow(MIN_TENOR, false);
        uint256 owed = ace.lenderOwed(address(vault), address(usdc));
        assertGt(owed, 0, "premise: the draw credited a fee share");
        uint256 g0 = vault.grossNav();
        uint256 idle0 = vault.idle();
        vault.crank();
        assertEq(ace.lenderOwed(address(vault), address(usdc)), 0, "the credit came home");
        assertEq(vault.idle(), idle0 + owed, "as idle");
        assertEq(vault.grossNav(), g0, "a crank moves no NAV");
    }

    /// @notice The vault names no credit line: its asset is the market quote and there is nothing else to read.
    function test_TheVaultHasNoLine() public {
        (bool ok,) = address(vault).staticcall(abi.encodeWithSignature("LINE()"));
        assertFalse(ok, "no LINE getter survives");
        assertEq(vault.asset(), address(usdc), "the asset is the cash");
    }
}
