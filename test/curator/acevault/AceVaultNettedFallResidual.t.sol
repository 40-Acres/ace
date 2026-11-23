// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.36;

import {AceVault} from "../../../src/vault/AceVault.sol";
import {AceVaultFlows} from "../../../src/vault/libraries/AceVaultFlows.sol";
import {AceVaultRig} from "./AceVaultRig.sol";

/// @title AceVaultNettedFallResidual
/// @notice MEASURE rows of the accepted hub-ask residual: a loss netted by income no sync has seen leaves no mark, so its recovery vests unheld.
/// @notice The bound: it needs unseen income at least the size of the loss, an entrant takes at most that income, and any crank between defeats it.
contract AceVaultNettedFallResidualTest is AceVaultRig {
    uint256 internal constant ENTRY = 1_000_000e6;
    uint256 internal constant UNITS_PER_ATOM = 1.5e12;
    uint48 internal constant MARKED = type(uint48).max;

    function _hold() internal view returns (uint48) {
        bytes32[] memory s = new bytes32[](1);
        s[0] = bytes32(uint256(AceVaultFlows.ROOT) + 2);
        return uint48(uint256(vault.extsload(s)[0]) >> 200);
    }

    function _buyPot(address who, uint256 loanId) internal returns (uint256 paid) {
        uint256 budget = 10_000_000e6;
        usdc.mint(who, budget);
        vm.startPrank(who);
        usdc.approve(address(ace), budget);
        (, paid) = ace.buyInventory(loanId, budget, 0, who);
        vm.stopPrank();
    }

    /// @dev A big loan runs a month; a small one, sized under a quarter of the big loan's fee, lapses while it is live.
    function _twoLoans() internal returns (uint256 big, uint256 small) {
        uint256 bigP = 500_000e6;
        big = _borrowAs(borrower, bigP * UNITS_PER_ATOM, bigP, MAX_TENOR);
        uint256 p = (bigP - usdc.balanceOf(borrower)) / 4;
        p = p - (p % 1e6);
        if (p > 5_000e6) p = 5_000e6;
        _warpBy(22 days);
        small = _borrowAs(stranger, p * UNITS_PER_ATOM, p, MIN_TENOR);
        _warpAtLeastTo(_expiry(small));
        assertLt(_now(), _expiry(big), "PREMISE: the big loan is still live when the small one lapses");
    }

    /// @notice MEASURE: a closing repay lands unsynced and nets a material default; no mark, and the entrant's take stays under the unseen income.
    function test_Measure_ANettedFallLeavesNoMarkAndTheTakeIsBoundedByTheUnseenIncome() public {
        (uint256 big, uint256 small) = _twoLoans();
        uint256 gMark = vault.grossNav();
        _repayAs(borrower, big, ace.debtOf(big));
        uint256 income = vault.grossNav() - gMark;
        vm.prank(keeper);
        ace.forceClose(small);
        assertGe(vault.grossNav(), gMark, "PREMISE: the income covers the fall");
        vault.crank();
        assertEq(_hold(), 0, "MEASURE: the netted fall was marked after all");
        _warpBy(1 hours);
        uint256 paid = _buyPot(stranger, small);
        uint256 sb = _lp(bob, ENTRY);
        assertEq(_hold(), 0, "MEASURE: the entry's sync stored a hold");
        _warpBy(VEST_W);
        vault.crank();
        vm.prank(bob);
        uint256 take = vault.redeem(sb, bob, bob) - ENTRY;
        emit log_named_uint("unseen income", income);
        emit log_named_uint("recovery paid for the pot", paid);
        emit log_named_uint("entrant's take", take);
        assertGt(take, 0, "MEASURE: the residual took nothing");
        assertLe(take, income, "the entrant took more than the unseen income");
    }

    /// @notice CONTROL: one crank between the income and the settle, and the same sale is held.
    function test_Measure_Control_ACrankBetweenDefeatsIt() public {
        (uint256 big, uint256 small) = _twoLoans();
        _repayAs(borrower, big, ace.debtOf(big));
        vault.crank();
        vm.prank(keeper);
        ace.forceClose(small);
        vault.crank();
        assertEq(_hold(), MARKED, "CONTROL: the fall over the unsold pot marks the vault");
        _warpBy(1 hours);
        _buyPot(stranger, small);
        assertEq(vault.maxDeposit(bob), 0, "CONTROL: the view holds entry over the recovery");
        usdc.mint(bob, ENTRY);
        vm.startPrank(bob);
        usdc.approve(address(vault), ENTRY);
        vm.expectRevert(AceVault.RecoveryVesting.selector);
        vault.deposit(ENTRY, bob);
        vm.stopPrank();
    }

    /// @notice MEASURE: one borrower's own extension fee nets its own default; the unheld recovery it takes back is bounded by the fee it paid.
    function test_Measure_ASelfNettedDefaultIsBoundedByTheAttackersOwnFee() public {
        uint256 small = _borrowAs(borrower, 300e6 * UNITS_PER_ATOM, 300e6, MIN_TENOR);
        _warpBy(1 days);
        uint256 big = _borrowAs(borrower, 500_000e6 * UNITS_PER_ATOM, 500_000e6, MIN_TENOR);
        _warpAtLeastTo(_expiry(small));
        uint256 gMark = vault.grossNav();
        usdc.mint(borrower, 10_000e6);
        vm.startPrank(borrower);
        usdc.approve(address(ace), 10_000e6);
        uint256 fee = ace.extend(big, 0, "");
        ace.forceClose(small);
        vm.stopPrank();
        assertGe(vault.grossNav(), gMark, "PREMISE: the fee covers the fall");
        vault.crank();
        assertEq(_hold(), 0, "MEASURE: the self-netted fall was marked");
        _warpBy(1 hours);
        uint256 paid = _buyPot(borrower, small);
        uint256 s = _lp(borrower, 4 * ENTRY);
        _warpBy(VEST_W);
        vault.crank();
        vm.prank(borrower);
        uint256 take = vault.redeem(s, borrower, borrower) - 4 * ENTRY;
        emit log_named_uint("extension fee the attacker paid", fee);
        emit log_named_uint("price the attacker paid for its own pot", paid);
        emit log_named_uint("attacker's take over its entry", take);
        assertLe(take, fee + paid, "the attacker took back more than it paid in");
    }
}
