// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.36;

import {AceVault} from "../../../src/curator/AceVault.sol";
import {LoanMath} from "../../../src/ace/hub/libraries/LoanMath.sol";
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
        uint256 loanId = _borrow(MIN_TENOR);
        uint256 bal = usdc.balanceOf(address(vault));
        uint256 pool = ace.lenderAssets(address(vault), address(usdc));
        assertEq(vault.grossNav(), bal + pool, "gross = balance + lenderAssets");
        assertEq(vault.grossNav() - g0, ace.lenderOwed(address(vault), address(usdc)) - owed0, "a draw moves gross by the credited fee alone");
        assertEq(bal, LP_CASH - PRINCIPAL, "the principal left idle and the payout passed through");
        _assertNothingRests(_mid(loanId));
    }

    /// @notice A cash extension moves gross by the lender's credit alone, the claim unmoved, and totalAssets not at all.
    /// @dev The borrower pays the fee in, so the lender's share lands as credit; the debt and the claim never move.
    /// @dev totalAssets standing still is the sandwich guard: a deposit before an extension and a redeem after it gain nothing.
    function test_TheExtensionMovesNoTotalAssets() public {
        uint256 loanId = _borrow(MAX_TENOR);
        bytes32 mid = _mid(loanId);
        _toWindow(loanId);
        (uint256 g1, uint256 t1) = (vault.grossNav(), vault.totalAssets());
        uint256 owed1 = ace.lenderOwed(address(vault), address(usdc));
        uint256 claim1 = read.claimOf(mid, loanId);
        uint64 added = uint64(_now()) + MAX_TENOR - read.loan(loanId).expiry; // re-anchored at now plus the loan's own tenor
        uint256 fee = LoanMath.originationFee(ace.debtOf(loanId), added, RATE_BPS, MIN_TENOR);
        usdc.mint(borrower, fee);
        vm.startPrank(borrower);
        usdc.approve(address(ace), fee);
        ace.extend(loanId, 0, "");
        vm.stopPrank();
        int256 grossMoved = int256(vault.grossNav()) - int256(g1);
        int256 owedMoved = int256(ace.lenderOwed(address(vault), address(usdc))) - int256(owed1);
        assertEq(read.claimOf(mid, loanId), claim1, "the claim does not move");
        assertEq(grossMoved, owedMoved, "an extension moves gross by the lender's credit alone");
        assertGt(owedMoved, 0, "PREMISE: the extension credited the lender a share");
        assertEq(vault.totalAssets(), t1, "and totalAssets not at all");
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
        _borrow(MIN_TENOR);
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
