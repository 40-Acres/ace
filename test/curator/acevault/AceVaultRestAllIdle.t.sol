// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.36;

import {BelowMinLot} from "../../../src/ace/hub/Lender.sol";
import {InsufficientCash} from "../../../src/ace/hub/Borrower.sol";
import {AceVaultRig} from "./AceVaultRig.sol";

/// @notice Rest all idle: every door and roll rests the vault's whole idle, acts, and withdraws every resting unit, skipping the withdraw at zero.
/// @dev The rows below pin the hub's deposit legs the plan accepted, with idle forced where the holds alone would never put it.
contract AceVaultRestAllIdleTest is AceVaultRig {
    /// @notice A cover that draws held cash returns every unit in the call: idle falls by the roll's fresh draw alone.
    function test_TheCoverReturnsEveryUnit() public {
        uint256 loanId = _borrow(MIN_TENOR, true);
        uint256 bobShares = _lp(bob, 50_000e6);
        vm.prank(bob);
        vault.requestExit(bobShares);
        _toWindow(loanId);
        uint256 idle0 = vault.idle();
        uint256 debt = ace.debtOf(loanId);
        uint256 newId = vault.roll(loanId, "");
        uint256 fresh = ace.debtOf(newId) - debt;
        assertEq(vault.idle(), idle0 - fresh, "the rested cover, held cash included, came back whole");
        _assertNothingRests(_mid(newId));
    }

    /// @notice Idle above the market's reservations by less than minDebt is the accepted dust band: the rest is refused.
    function test_TheMinLotBandIsPinned() public {
        uint256 loanId = _borrow(MIN_TENOR, true);
        _toWindow(loanId);
        uint256 rr = read.rollReserve(_mid(loanId));
        deal(address(usdc), address(vault), rr + MIN_DEBT / 2);
        vm.expectRevert(BelowMinLot.selector);
        vault.roll(loanId, "");
    }

    /// @notice With two armed loans, a refill under the other loan's reservation is admitted and the draw then fails.
    function test_ARefillUnderAnotherReservationThenFailsTheDraw() public {
        uint256 a = _borrow(MIN_TENOR, true);
        uint256 b = _borrowAs(bob, UNITS, PRINCIPAL, MIN_TENOR, true);
        _toWindow(a);
        uint256 ownB = read.reservedOf(b);
        deal(address(usdc), address(vault), ownB / 2);
        vm.expectRevert(InsufficientCash.selector);
        vault.roll(a, "");
    }

    /// @notice A roll whose draw spends the whole rested cash ends with nothing resting, and the skipped withdraw does not revert.
    function test_TheWithdrawIsSkippedAtZero() public {
        uint256 loanId = _borrow(MIN_TENOR, true);
        _toWindow(loanId);
        uint256 debt = ace.debtOf(loanId);
        (,, uint256 succ) = _quoteRoll(loanId);
        deal(address(usdc), address(vault), succ - debt);
        uint256 newId = vault.roll(loanId, "");
        assertTrue(ace.isLiveLoan(newId), "the roll ran on exactly its fresh draw");
        assertEq(vault.idle(), 0, "the draw took every rested unit");
        _assertNothingRests(_mid(newId));
    }

    /// @dev The hub's own continuation quote, read with the reservation's refill resting so its cash leg answers.
    function _quoteRoll(uint256 loanId) internal returns (bool ok, bytes4 why, uint256 principal) {
        uint256 snap = vm.snapshotState();
        uint256 own = read.reservedOf(loanId);
        usdc.mint(address(vault), own);
        vm.startPrank(address(vault));
        usdc.approve(address(ace), own);
        ace.deposit(_mid(loanId), own);
        vm.stopPrank();
        (ok, why, principal) = ace.tryContinue(loanId);
        vm.revertToState(snap);
    }
}
