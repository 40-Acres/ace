// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.36;

import {InKindRig} from "./InKindRig.sol";

/// @title InKindFeeMintEntryView
/// @notice In kind, every share gifted to the vault, a batch waiting on no tracked holder, a fee pending: the entry views and the deposit agree.
/// @notice The deposit runs its gates before it collects the fee, so the fee mint cannot re-stamp the batch the gates read, and entry is open.
/// @notice The fee mint then tracks the curator in the entry's block, and the waiting batch closes the next block on both.
contract InKindFeeMintEntryViewTest is InKindRig {
    /// @dev A fee vault; alice's loan defaults with every share gifted to the vault, so the pot waits; a vested gain then puts NAV over the high-water.
    function _waitingBatchUnderAPendingFee() internal returns (uint256 pot) {
        vault = _deploy(_cfg(2_000), _ik(), _listings());
        uint256 sa = _lp(alice, LP_CASH);
        uint256 loanId = _open(address(tokA));
        vm.prank(alice);
        vault.transfer(address(vault), sa);
        assertEq(_trackedSupply(), 0, "PREMISE: every share is gifted to the vault, so none is tracked");
        pot = _defaultAndCollect(loanId);
        usdc.mint(address(vault), 5_000e6);
        vault.crank();
        _warpBy(VEST_W + 1);
        _nextBlock();
        assertGt(vault.totalSupply(), 0, "PREMISE: the gifted shares are still supply, so a fee prices");
        assertEq(_trackedSupply(), 0, "PREMISE: the batch still waits on no tracked holder");
        assertGt(vault.pendingFeeShares(), 0, "PREMISE: the vested gain owes a fee the entry collects after its gates");
    }

    /// @notice The entry views and the deposit agree: both views read zero exactly when the deposit refuses.
    function test_repro_aPendingFeeOverAWaitingBatchKeepsTheViewsAndTheVerbInStep() public {
        _waitingBatchUnderAPendingFee();
        bool viewShut = vault.maxDeposit(bob) == 0;
        assertEq(vault.maxMint(bob) == 0, viewShut, "maxMint disagreed with maxDeposit");
        uint256 snap = vm.snapshotState();
        _armDeposit(bob, 1_000e6);
        vm.prank(bob);
        (bool ok, bytes memory err) = address(vault).call(abi.encodeCall(vault.deposit, (1_000e6, bob)));
        vm.revertToState(snap);
        emit log_named_uint("maxDeposit", vault.maxDeposit(bob));
        emit log_named_uint("deposit landed", ok ? 1 : 0);
        if (!ok) emit log_named_bytes("deposit's refusal", err);
        assertEq(ok, !viewShut, "the entry views and the deposit disagree");
    }

    /// @notice The gates run before the fee: entry opens in both views and the deposit lands, its fee mint tracking the curator in the same block.
    /// @notice The waiting batch then closes the next block on the curator's fee shares plus the entrant's, the block's end supply; the gift earns nothing.
    function test_aPendingFeeOverAWaitingBatchAdmitsTheEntrantAndSharesThePotWithTheFee() public {
        uint256 pot = _waitingBatchUnderAPendingFee();
        assertEq(vault.balanceOf(curator), 0, "PREMISE: the curator holds no share before the entry");
        assertGt(vault.maxDeposit(bob), 0, "maxDeposit shut the entry the verb admits");
        assertGt(vault.maxMint(bob), 0, "and so did maxMint");
        uint256 sb = _lp(bob, 1_000e6);
        uint256 fee = vault.balanceOf(curator);
        assertGt(sb, 0, "the deposit minted nothing");
        assertGt(fee, 0, "the entry did not collect the pending fee");
        assertEq(_tracked(curator), fee, "the fee shares are not tracked to the curator");
        assertEq(_tracked(bob), sb, "the entrant's shares are not tracked to it");
        assertEq(_trackedSupply(), fee + sb, "the block's end supply is not the fee shares plus the entrant's");
        _nextBlock();
        uint256 toBob = _claim(bob, address(tokA));
        uint256 toCurator = _claim(curator, address(tokA));
        assertEq(toBob, pot * sb / (fee + sb), "the entrant's credit is not its share of the block's end supply");
        assertEq(toCurator, pot * fee / (fee + sb), "the curator's credit is not its fee shares' share of the block's end supply");
        assertEq(_claim(alice, address(tokA)), 0, "the gifted shares were credited");
        assertLe(toBob + toCurator, pot, "the credits sum past the pot");
        assertGe(toBob + toCurator + 2, pot, "the credits leave more than a unit each of rounding");
    }
}
