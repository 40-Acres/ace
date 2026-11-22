// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.36;

import {AceVault} from "../../../src/curator/AceVault.sol";
import {AceVaultFlows, Terms} from "../../../src/curator/libraries/AceVaultFlows.sol";
import {AceVaultDoorRig} from "../vault/AceVaultDoorRig.sol";

/// @title AceVaultTroughHoldDoor
/// @notice The hold after a cleared trough, in door mode: the collect's own sweep marks the vault, and a closing return or an accepted write-off clears it.
/// @notice A write-off lands with no sync, so the view reads the hold the next sync would store, and that sync stores it for anyone.
contract AceVaultTroughHoldDoorTest is AceVaultDoorRig {
    uint256 internal constant P = 40_000e6;
    uint256 internal constant BIG = 80_000e18;
    uint48 internal constant MARKED = type(uint48).max;

    function _vestWord() internal view returns (uint256) {
        bytes32[] memory s = new bytes32[](1);
        s[0] = bytes32(uint256(AceVaultFlows.ROOT) + 2);
        return uint256(vault.extsload(s)[0]);
    }

    function _hold() internal view returns (uint48) {
        return uint48(_vestWord() >> 200);
    }

    function _maturity() internal view returns (uint64) {
        return uint64(_vestWord() >> 128);
    }

    /// @dev A loan of `P` lapses and the door collects it: the key opens and the collect's sweep sees the fall.
    function _seizedLoan() internal returns (uint256 booked) {
        terms.setTerms(_doorMarket(address(coll), record), Terms({units: BIG, principal: P, tenor: 0, minBufferWad: 0}));
        uint256 loanId = _borrowAs(borrower, address(coll), BIG, P);
        _warpTo(read.loan(loanId).expiry + 1);
        _collect(loanId);
        bool open;
        (booked, open,) = _seized(address(coll));
        assertTrue(open, "premise: the collect opened the key");
        assertEq(_hold(), MARKED, "the collect's sweep saw the fall over the open key and did not mark the vault");
    }

    function _assertHeld(address who) internal {
        assertEq(vault.maxDeposit(who), 0, "maxDeposit advertised an entry the hold shuts");
        assertEq(vault.maxMint(who), 0, "and so did maxMint");
        usdc.mint(who, 1_000e6);
        vm.startPrank(who);
        usdc.approve(address(vault), 1_000e6);
        vm.expectRevert(AceVault.RecoveryVesting.selector);
        vault.deposit(1_000e6, who);
        vm.stopPrank();
    }

    /// @notice The door's closing return clears the leg in its own sweep, which stores the post-return maturity; entry waits for that second.
    function test_HoldDoor_TheClosingReturnHoldsEntryUntilItsCashVests() public {
        uint256 booked = _seizedLoan();
        _give(address(coll), booked, true);
        assertEq(_hold(), _maturity(), "the closing return's sweep did not store the hold at the return's maturity");
        assertEq(uint256(_hold()), _now() + VEST_W, "the hold is not one window from the return");
        _assertHeld(bob);
        _warpTo(_hold());
        assertGt(_lp(bob, 1_000e6), 0, "entry did not reopen at the hold");
    }

    /// @notice A return that leaves the key open keeps the vault marked; a write-off accepted later clears the leg with the cash still vesting.
    function test_HoldDoor_AnAcceptedWriteOffStartsTheHoldAtTheNextSync() public {
        uint256 booked = _seizedLoan();
        vm.prank(curator);
        dv.submitWriteOff(address(coll));
        _warpBy(CAP_LOCK - 2 hours);
        _give(address(coll), booked / 2, false);
        assertEq(_hold(), MARKED, "a return that left the key open cleared the mark");
        _warpBy(2 hours);
        dv.acceptWriteOff(address(coll));
        (, bool open,) = _seized(address(coll));
        assertFalse(open, "premise: the write-off closed the key");
        assertEq(_hold(), MARKED, "premise: the write-off lands with no sync");
        assertGt(vault.unvested(), vault.VEST_FLOOR(), "premise: the returned cash still vests");
        assertEq(vault.maxDeposit(bob), 0, "the view opened over a marked vault whose pile still vests");
        vm.prank(stranger);
        vault.crank();
        assertEq(_hold(), _maturity(), "a stranger's crank did not store the hold");
        _assertHeld(bob);
        _warpTo(_hold());
        assertGt(_lp(bob, 1_000e6), 0, "entry did not reopen at the hold");
    }

    /// @notice No hold when the pile at the clear is at or under one asset unit: a closing return of less opens entry in its own call.
    function test_HoldDoor_NoHoldWhenThePileIsAtTheFloor() public {
        _seizedLoan();
        _give(address(coll), vault.VEST_FLOOR(), true);
        assertEq(vault.unvested(), vault.VEST_FLOOR(), "premise: the pile is exactly at the floor");
        assertEq(_hold(), 0, "a pile at the floor stored a hold");
        assertGt(vault.maxDeposit(bob), 0, "entry stayed shut over a pile at the floor");
        assertGt(_lp(bob, 1_000e6), 0, "a deposit refused over a pile at the floor");
    }

    /// @notice A write-off with no cash returned leaves a stored mark and no pile: the view and the verb both open, and the entry clears the mark.
    function test_HoldDoor_AMarkWithNoPileOpensInTheViewAndTheVerb() public {
        _seizedLoan();
        vm.prank(curator);
        dv.submitWriteOff(address(coll));
        _warpBy(CAP_LOCK);
        dv.acceptWriteOff(address(coll));
        assertEq(_hold(), MARKED, "premise: the write-off lands with no sync, over a stored mark");
        assertLe(vault.unvested(), vault.VEST_FLOOR(), "premise: no pile stands");
        assertGt(vault.maxDeposit(bob), 0, "the view stayed shut over a mark with no pile");
        assertGt(vault.maxMint(bob), 0, "and so did maxMint");
        assertGt(_lp(bob, 1_000e6), 0, "the verb refused a mark with no pile");
        assertEq(_hold(), 0, "the entry's own sync did not clear the mark");
    }
}
