// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.36;

import {ERC4626} from "@openzeppelin/contracts/token/ERC20/extensions/ERC4626.sol";
import {AceVault} from "../../src/curator/AceVault.sol";
import {CuratorVault} from "../../src/curator/CuratorVault.sol";
import {CuratorVaultExitsRig, ICuratorVaultExits} from "./CuratorVaultExitsRig.sol";

/// @title CuratorVaultDrain
/// @notice The drain stops lending: nothing is lendable, the door refuses, entry shuts, and exits and claims take all of exitable first come.
/// @notice The curator switches it on and off, the guardian on only; off takes effect at once.
contract CuratorVaultDrainTest is CuratorVaultExitsRig {
    function _drain(CuratorVault v, address by, bool on) internal {
        vm.prank(by);
        _x(v).setDrain(on);
    }

    // ---- the keys ----

    /// @notice THE CURATOR SWITCHES THE DRAIN ON AND OFF, each at once, and each by name.
    function test_Drain_TheCuratorSwitchesItOnAndOff() public {
        CuratorVault v = _vault(0);
        assertFalse(_x(v).draining(), "PREMISE: a new vault lends");
        vm.expectEmit(true, false, false, true, address(v));
        emit DrainSet(curator, true);
        _drain(v, curator, true);
        assertTrue(_x(v).draining(), "the curator's on did not drain");
        vm.expectEmit(true, false, false, true, address(v));
        emit DrainSet(curator, false);
        _drain(v, curator, false);
        assertFalse(_x(v).draining(), "the curator's off did not lend again");
    }

    /// @notice THE GUARDIAN SWITCHES IT ON AND NEVER OFF.
    function test_Drain_TheGuardianSwitchesItOnButNeverOff() public {
        CuratorVault v = _vault(0);
        _drain(v, guardian, true);
        assertTrue(_x(v).draining(), "the guardian's on did not drain");
        vm.prank(guardian);
        vm.expectRevert(AceVault.NotCurator.selector);
        _x(v).setDrain(false);
        assertTrue(_x(v).draining(), "the guardian lifted the drain");
    }

    /// @notice A STRANGER CANNOT SWITCH IT EITHER WAY.
    function test_Drain_AStrangerCannotSwitchIt() public {
        CuratorVault v = _vault(0);
        vm.prank(stranger);
        vm.expectRevert(AceVault.NotCurator.selector);
        _x(v).setDrain(true);
        _drain(v, curator, true);
        vm.prank(stranger);
        vm.expectRevert(AceVault.NotCurator.selector);
        _x(v).setDrain(false);
    }

    // ---- the hold ----

    /// @notice THE DRAIN LENDS NOTHING AND HOLDS NOTHING FOR REQUESTS: an instant exit reads all of exitable cash.
    function test_Drain_HoldsTheWholeFreePot() public {
        (CuratorVault v,) = _lent(15_000e6);
        _drain(v, curator, true);
        uint256 exitable = _exitable(v);
        assertGt(exitable, 0, "PREMISE: the vault holds exitable cash");
        assertEq(exitable, v.idle() - v.rollHoldNow(), "PREMISE: exitable is idle past the roll hold");
        assertEq(v.lendable(), 0, "the drain left cash lendable");
        assertEq(_heldReq(v), 0, "the drain held cash for requests");
        assertEq(v.maxWithdraw(alice), exitable, "an instant exit under the drain does not read all of exitable");
    }

    // ---- what it shuts ----

    /// @notice THE DRAIN SHUTS ENTRY by the standard error, and both max views read zero; off reopens it at once.
    function test_Drain_ShutsEntryAndOffReopensIt() public {
        CuratorVault v = _vault(0);
        _lpDeposit(v, alice, SEED);
        _drain(v, curator, true);
        assertEq(v.maxDeposit(carol), 0, "maxDeposit stayed open under the drain");
        assertEq(v.maxMint(carol), 0, "maxMint stayed open under the drain");
        usdc.mint(carol, 1_000e6);
        vm.startPrank(carol);
        usdc.approve(address(v), 1_000e6);
        vm.expectRevert(abi.encodeWithSelector(ERC4626.ERC4626ExceededMaxDeposit.selector, carol, 1_000e6, 0));
        v.deposit(1_000e6, carol);
        vm.stopPrank();
        _drain(v, curator, false);
        assertEq(v.maxDeposit(carol), type(uint256).max, "the switch-off did not reopen entry at once");
        _assertEntryAdmitted(v, carol);
    }

    /// @dev Pledge `COLL` and ask the door for `principal` as the rig borrower, expecting `err`.
    function _expectBorrowRefused(CuratorVault v, uint256 principal, bytes4 err) internal {
        collateral.mint(borrower, COLL);
        vm.startPrank(borrower);
        collateral.approve(address(v), COLL);
        vm.expectRevert(err);
        v.borrow(_request(address(collateral), COLL, principal), "", "");
        vm.stopPrank();
    }

    /// @notice THE DRAIN REFUSES A DRAW: the door is a lending verb, and it refuses by name while the drain stands.
    function test_Drain_ADrawIsRefused() public {
        CuratorVault v = _vault(0);
        _lpDeposit(v, alice, SEED);
        _drain(v, curator, true);
        _expectBorrowRefused(v, 1_000e6, ICuratorVaultExits.Draining.selector);
    }

    /// @notice WHILE IT STANDS THE DOOR IS SHUT by name, and the switch-off lets the next borrow land.
    function test_Drain_AnAllocateIsRefusedAndOffReopensIt() public {
        CuratorVault v = _vault(0);
        _lpDeposit(v, alice, SEED);
        _drain(v, curator, true);
        _expectBorrowRefused(v, 1_000e6, ICuratorVaultExits.Draining.selector);
        _drain(v, curator, false);
        uint256 loanId = _borrow(v, 1_000e6);
        assertEq(read.claimOf(mid, loanId), 1_000e6, "the switch-off did not let the door lend again");
        assertEq(ace.restingOf(mid), 0, "and nothing rests past the door");
    }

    // ---- what it opens ----

    /// @notice AN INSTANT EXIT UNDER THE DRAIN TAKES ALL OF EXITABLE, the cash held for a request included: first come.
    function test_Drain_AnInstantExitTakesTheWholePot() public {
        (CuratorVault v, uint256 loanId) = _lent(15_000e6);
        _request(v, bob, v.balanceOf(bob));
        _repay(loanId, 2_000e6);
        v.crank(); // the repayment reaches the vault's balance at the crank
        uint256 exitable = _exitable(v);
        assertGt(_heldReq(v), 0, "PREMISE: lending, bob's request holds cash");
        assertEq(v.maxWithdraw(alice), exitable - _heldReq(v), "PREMISE: lending, alice sees exitable less the requests' hold");
        _drain(v, guardian, true);
        assertEq(v.maxWithdraw(alice), exitable, "a drained vault did not open all of exitable to an instant exit");
        vm.prank(alice);
        v.withdraw(exitable, alice, alice);
        assertEq(_exitable(v), 0, "the exit did not take all of exitable");
        assertEq(_x(v).maxClaim(bob), 0, "the requester kept a claim on cash the exit took first");
    }

    /// @notice THE SWITCH-OFF RELEASES THE HOLD AT ONCE, down to what the requests are worth, and exits see what is left.
    function test_Drain_OffReleasesTheHoldButKeepsTheRequests() public {
        (CuratorVault v,) = _lent(15_000e6);
        uint256 sh = v.balanceOf(bob) / 10;
        _request(v, bob, sh);
        _drain(v, curator, true);
        assertEq(_heldReq(v), 0, "PREMISE: the drain holds nothing for requests");
        assertEq(v.lendable(), 0, "PREMISE: and lends nothing");
        _drain(v, curator, false);
        assertEq(_heldReq(v), _worth(v, sh), "the switch-off did not price the hold back to the request's worth");
        assertEq(_escrow(v, bob), sh, "and the request still stands");
        assertEq(v.maxWithdraw(alice), _exitable(v) - _heldReq(v), "an instant exit still reached held cash after the switch-off");
    }
}
