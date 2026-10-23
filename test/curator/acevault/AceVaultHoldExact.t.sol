// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.36;

import {MarketParams, OpenBounds} from "../../../src/ace/hub/Types.sol";
import {AutoPolicyDisarmed} from "../../../src/ace/hub/Borrower.sol";
import {AceFixtures} from "../../utils/AceFixtures.sol";
import {AceVaultRig} from "./AceVaultRig.sol";

/// @notice The roll hold is exact: an entry leaves at the loan's vault roll, or when `crank` is handed an id the hub reports closed.
/// @dev Every closing path a vault never sees is pinned here: a repay, a settlement, a holder's re-term and a stranger's roll.
contract AceVaultHoldExactTest is AceVaultRig {
    function _prune(uint256 id) internal {
        uint256[] memory ids = new uint256[](1);
        ids[0] = id;
        vault.crank(ids);
    }

    /// @notice A loan repaid in full stays in the hold until a crank names it, then leaves it exactly.
    function test_ARepaidLoanLeavesTheHoldAtTheCrank() public {
        uint256 loanId = _borrow(MAX_TENOR, true);
        _repayAs(borrower, loanId, ace.debtOf(loanId));
        assertTrue(ace.isClosed(loanId), "premise: the repay closed it");
        assertGt(vault.rollHold(), 0, "the vault has not seen the close yet");
        _prune(loanId);
        assertEq(_need(loanId), 0, "the entry left");
        assertEq(vault.rollHold(), 0, "the hold is exact");
        assertEq(vault.rollHoldNow(), 0, "an empty book holds nothing, not minDebt");
    }

    /// @notice A crank never drops a live loan's entry.
    function test_ACrankIgnoresALiveLoan() public {
        uint256 loanId = _borrow(MAX_TENOR, true);
        uint256 hold = vault.rollHold();
        _prune(loanId);
        assertEq(vault.rollHold(), hold, "a live loan keeps its reservation");
        assertGt(_need(loanId), 0, "and its entry");
    }

    /// @notice A loan nobody rolled settles at the hub's backstop; the crank then drops it.
    function test_ASettledLoanLeavesTheHoldAtTheCrank() public {
        uint256 loanId = _borrow(MIN_TENOR, true);
        _warpAtLeastTo(_expiry(loanId) + 2 hours + 1);
        ace.settleExpired(loanId);
        _prune(loanId);
        assertEq(vault.rollHold(), 0, "the settled loan's reservation left");
    }

    /// @notice An unfunded successor is recorded, and leaves exactly when it closes and a crank names it.
    function test_AnUnfundedSuccessorLeavesTheHoldWhenItCloses() public {
        uint256 loanId = _borrow(MIN_TENOR, true);
        vm.prank(curator);
        vault.setDrain(true);
        _toWindow(loanId);
        uint256 newId = vault.roll(loanId, "");
        assertFalse(_funded(newId), "premise: the drain left it unfunded");
        assertEq(vault.rollHold(), _need(newId), "recorded all the same");
        _repayAs(borrower, newId, ace.debtOf(newId));
        _prune(newId);
        assertEq(vault.rollHold(), 0, "the hold returns to zero once the book is empty");
        vm.prank(curator);
        vault.setDrain(false);
        assertEq(vault.lendable(), vault.idle(), "and every unit of idle is lendable again");
    }

    /// @notice A holder may disarm and re-term zero-fresh; the old loan closes without the vault and the crank prunes it.
    function test_AHoldersZeroFreshRetermIsPrunable() public {
        uint256 loanId = _borrowAs(borrower, 20_000e18, 10_000e6, MIN_TENOR, true);
        _repayAs(borrower, loanId, 10_000e6 - 20e6);
        vm.startPrank(borrower);
        ace.setAutoRefinance(loanId, 0, 0, 0);
        uint256 newId = ace.refinance(loanId, 20e6, MIN_TENOR, OpenBounds(0, 0, 0));
        vm.stopPrank();
        assertTrue(ace.isClosed(loanId), "premise: the re-term closed the old loan");
        assertGt(_need(loanId), 0, "the vault never saw it");
        _prune(loanId);
        assertEq(vault.rollHold(), 0, "pruned exactly");
        assertEq(_need(newId), 0, "a re-term the vault did not fund is not recorded");
    }

    /// @notice A stranger's zero-fresh policy roll of a sole armed loan closes it without the vault; the crank prunes it.
    function test_AStrangersZeroFreshRollIsPrunable() public {
        uint256 loanId = _borrowAs(borrower, 20_000e18, 10_000e6, MIN_TENOR, true);
        _repayAs(borrower, loanId, 10_000e6 - 20e6);
        _toWindow(loanId);
        vm.prank(stranger);
        uint256 newId = ace.refinanceByPolicy(loanId);
        assertTrue(ace.isClosed(loanId), "premise: the stranger's roll closed it");
        (, bytes4 why,) = ace.tryContinue(newId);
        assertEq(why, bytes4(keccak256("AutoPolicyDisarmed()")), "premise: the stranger's successor lands disarmed");
        _prune(loanId);
        assertEq(vault.rollHold(), 0, "pruned exactly");
    }

    /// @notice A holder's disarm of a live loan leaves the record in the hold, the ruled over-hold, until the loan closes and a crank prunes it.
    function test_ADisarmKeepsTheRecordUntilTheLoanCloses() public {
        uint256 loanId = _borrow(MAX_TENOR, true);
        uint256 need = _need(loanId);
        vm.prank(borrower);
        ace.setAutoRefinance(loanId, 0, 0, 0);
        assertEq(read.reservedOf(loanId), 0, "premise: the hub released the reservation");
        assertEq(_need(loanId), need, "the record stands");
        assertEq(vault.rollHold(), need, "and so does the hold");
        _prune(loanId);
        assertEq(vault.rollHold(), need, "a crank leaves a live loan's record");
        _toWindow(loanId);
        vm.expectRevert(AutoPolicyDisarmed.selector);
        vault.roll(loanId, "");
        _repayAs(borrower, loanId, ace.debtOf(loanId));
        _prune(loanId);
        assertEq(vault.rollHold(), 0, "pruned once the loan closed");
        assertEq(vault.rollHoldNow(), 0, "and the hold is empty");
    }

    /// @notice A crank handed a stranger's loan, an id nobody opened, or a live loan of the vault's changes nothing.
    function test_ACrankOfForeignOrLiveIdsChangesNothing() public {
        uint256 ours = _borrow(MAX_TENOR, true);
        MarketParams memory p = AceFixtures.marketParams(address(usdc), address(coll));
        p.record = address(record);
        p.lender = stranger;
        bytes32 fm = ace.createMarket(p);
        usdc.mint(stranger, 10_000e6);
        vm.startPrank(stranger);
        usdc.approve(address(ace), 10_000e6);
        ace.deposit(fm, 10_000e6);
        vm.stopPrank();
        coll.mint(bob, UNITS);
        vm.startPrank(bob);
        coll.approve(address(pm), UNITS);
        uint256 foreign = ace.open(fm, UNITS, PRINCIPAL, 0, bob, OpenBounds(0, 0, 0));
        usdc.mint(bob, PRINCIPAL);
        usdc.approve(address(ace), PRINCIPAL);
        ace.repay(foreign, ace.debtOf(foreign));
        vm.stopPrank();
        assertTrue(ace.isClosed(foreign), "premise: the stranger's loan closed");
        uint256 hold = vault.rollHold();
        uint256 need = _need(ours);
        uint256 idle = vault.idle();
        uint256 gross = vault.grossNav();
        uint256[] memory ids = new uint256[](3);
        (ids[0], ids[1], ids[2]) = (foreign, 999_999, ours);
        vm.prank(stranger);
        vault.crank(ids);
        assertEq(vault.rollHold(), hold, "the hold is untouched");
        assertEq(_need(ours), need, "the live record stands");
        assertEq(vault.grossNav(), gross, "NAV is untouched");
        assertGe(vault.idle(), idle, "idle only gains the crank's own collection");
    }

    /// @notice The hold is the exact sum of every recorded entry across several loans and markets' worth of closes.
    function test_TheHoldIsTheSumOfTheRecords() public {
        uint256 a = _borrow(MAX_TENOR, true);
        uint256 b = _borrowAs(bob, UNITS, 2 * PRINCIPAL, MAX_TENOR, true);
        uint256 c = _borrow(MIN_TENOR, false);
        assertEq(vault.rollHold(), _need(a) + _need(b), "the hold is the sum");
        _repayAs(borrower, a, ace.debtOf(a));
        uint256[] memory ids = new uint256[](3);
        (ids[0], ids[1], ids[2]) = (a, b, c);
        vault.crank(ids);
        assertEq(vault.rollHold(), _need(b), "only the closed entry left");
        assertEq(vault.rollHoldNow(), _holdNowOf(_need(b)), "and the hold now follows");
    }
}
