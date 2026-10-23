// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.36;

import {CuratorVaultBase} from "./CuratorVaultBase.sol";
import {CuratorVault} from "../../src/curator/CuratorVault.sol";

/// @notice An exit request placed by an address holding NO shares: the phantom request through the front door, closed by escrow.
/// @dev A request moves real shares onto the vault, so a holder of none cannot request any and an escrow cannot leave.
/// @dev Unbounded, a stranger's request would hold exitable cash for value it does not hold and fence every repayment for it.
/// @dev These rows assert the closed property from both sides: the door refuses, and the real requester reaches the hold.
contract CuratorVaultPhantomOrderTest is CuratorVaultBase {
    uint256 internal constant EACH = 10_000e6;
    uint256 internal constant DRAWN = 18_000e6;
    uint256 internal constant BACK = 6_000e6;
    uint256 internal constant PHANTOM = 1e30; // far past the supply; sized so `_convertToAssets` still fits a word

    address internal mallory = address(0xBAD);

    CuratorVault internal v;
    uint256 internal loanId;

    function setUp() public override {
        super.setUp();
        v = _newVault(0);
        _lpDeposit(v, alice, EACH);
        _lpDeposit(v, bob, EACH);
        loanId = _open(DRAWN);
    }

    /// @dev The attack, which reverts at the door. Every row that used to describe its damage calls this.
    /// @dev Asserted as a bare revert on purpose: the property is that the state is UNREACHABLE, not which selector says so.
    function _phantomRefused() internal {
        vm.prank(mallory);
        vm.expectRevert();
        v.requestExit(PHANTOM);
    }

    function _escrow(address who) internal view returns (uint256 shares) {
        (shares,) = v.requestOf(who);
    }

    // ---- premise ----

    function test_Premise_TheStrangerHoldsNothingAndThePotIsDrained() public view {
        assertEq(v.balanceOf(mallory), 0, "PREMISE: mallory holds no shares");
        assertLt(v.idle(), EACH, "PREMISE: the draw left far less cash than either holder is owed");
    }

    // ---- the door refuses ----

    /// @dev A request is a claim on shares; one larger than the balance behind it is a claim on nothing.
    function test_AStrangerCannotStandAnOrderAtAll() public {
        _phantomRefused();
        assertEq(_escrow(mallory), 0, "nothing was stored for an address that holds nothing");
        assertEq(v.requestedShares(), 0, "and the request total never moved");
    }

    /// @dev The bound is on the BALANCE, not on the caller: a real holder is refused the same way past their own.
    /// @dev Escrow is what refuses it, so the revert is the share move's and carries no vault selector.
    function test_ARealHolderIsRefusedPastTheirOwnBalance() public {
        uint256 a0 = v.balanceOf(alice);
        vm.prank(alice);
        vm.expectRevert();
        v.requestExit(a0 + 1);
        assertEq(_escrow(alice), 0, "the over-request stored nothing");
    }

    /// @dev The boundary is INCLUSIVE: the whole balance is exactly what a full exit has to be able to ask for.
    function test_AHolderMayRequestTheirEntireBalance() public {
        uint256 a0 = v.balanceOf(alice);
        vm.prank(alice);
        v.requestExit(a0);
        assertEq(_escrow(alice), a0, "a full-balance request stands");
    }

    // ---- what the refusal buys everyone else ----

    /// @dev The whole point: with no phantom fencing exitable cash, the one real requester reaches all of it.
    /// @dev A request holds existing idle at once, up to its worth, and a repayment cranked home joins that hold.
    function test_ALegitimateRequesterReachesTheHoldHerRequestEarned() public {
        _phantomRefused();
        uint256 a0 = v.balanceOf(alice);
        vm.prank(alice);
        v.requestExit(a0);
        (uint256 ex0, uint256 held0) = v.holds();
        assertGt(held0, 0, "PREMISE: the request holds the cash already idle, at once");
        assertEq(held0, ex0, "PREMISE: all of it, her request being worth more than the cash left");
        _repay(loanId, BACK);
        v.crank(); // the repayment reaches the vault's balance at the crank
        (uint256 exitable, uint256 held) = v.holds();
        assertEq(held, exitable, "the repayment joined the hold her request earned");
        uint256 m = v.maxClaim(alice); // BEFORE the prank: a read is a call, and a call would eat it
        vm.prank(alice);
        uint256 got = v.claimExit(m, alice, 0);
        assertGe(got + 2, exitable, "the only real requester reaches all of exitable cash, the hold her request earned included");
    }

    /// @dev Lending is not frozen either: with nothing phantom requested, repaid cash is lendable again.
    /// @dev The refused stranger is present so this row fails if the refusal ever stops being a refusal.
    function test_RepaidCashCanBeDrawnAgain() public {
        _phantomRefused();
        _repay(loanId, BACK);
        v.crank(); // the repayment reaches the vault's balance at the crank
        assertGe(v.idle(), BACK, "PREMISE: the vault holds the repayment");
        assertGe(v.lendable(), BACK, "and none of it is held for a request nobody placed");
        uint256 before = v.idle();
        _open(BACK / 2);
        assertEq(before - v.idle(), BACK / 2, "a door borrow lent the repaid cash");
    }

    // ---- the other half of the invariant, still standing ----

    /// @dev An order could outlive its shares only while the shares could leave, and escrow is what stops them.
    function test_AnEscrowedOrdersSharesCannotLeaveAtAll() public {
        uint256 a0 = v.balanceOf(alice);
        vm.startPrank(alice);
        v.requestExit(a0);
        assertEq(v.balanceOf(alice), 0, "the shares went into escrow, so there is nothing left to send");
        vm.expectRevert();
        v.transfer(bob, a0 / 2);
        vm.stopPrank();
        assertEq(_escrow(alice), a0, "the request stands untouched");
        assertEq(v.balanceOf(address(v)), v.requestedShares(), "and every requested share is still escrowed behind it");
    }

    /// @dev A request is ADDITIVE: each call moves real shares in, so a second one adds to the first; a cancel is what hands shares back.
    function test_AHolderMayAddToTheirOrder() public {
        uint256 a0 = v.balanceOf(alice);
        vm.startPrank(alice);
        v.requestExit(a0 / 4);
        assertEq(_escrow(alice), a0 / 4, "the first request stands");
        v.requestExit(a0 / 4);
        vm.stopPrank();
        assertEq(_escrow(alice), a0 / 2, "and the second ADDS to it rather than replacing it");
        assertEq(v.requestedShares(), a0 / 2, "with the total accumulating in step");
        assertEq(v.balanceOf(alice), a0 - a0 / 2, "and the rest of her shares are still free");
    }
}
