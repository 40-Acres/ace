// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.36;

import {CuratorVaultBase} from "./CuratorVaultBase.sol";
import {CuratorVault} from "../../src/curator/CuratorVault.sol";
import {AceVaultFlows} from "../../src/curator/AceVaultFlows.sol";

/// @notice Audit V-Q1: a requesting holder MANUFACTURES the repayment their hold waits for.
/// @dev The hold a standing request takes is computed at read time from the requests' worth, so an inflow is held only up to that worth.
/// @dev A requester's own round trip through the door draws `lendable`, which the request has already carved its hold out of.
/// @dev A claim reaches all of exitable cash, held and free alike, so the round trip can move only its own fee gain into the requester's claim.
contract CuratorVaultV11ManufacturedReserveTest is CuratorVaultBase {
    uint256 internal constant EACH = 10_000e6;
    uint256 internal constant DRAWN = 14_000e6;

    CuratorVault internal v;
    uint256 internal loanId;

    function setUp() public override {
        super.setUp();
        v = _newVault(0);
        _lpDeposit(v, alice, EACH);
        _lpDeposit(v, bob, EACH);
        loanId = _open(DRAWN);
    }

    /// @dev `who` requests `num/den` of their balance.
    function _ask(address who, uint256 num, uint256 den) internal {
        uint256 sh = (v.balanceOf(who) * num) / den;
        vm.prank(who);
        v.requestExit(sh);
    }

    /// @dev `who` borrows `drawn` through the door and repays it at the hub in the same transaction, then anybody cranks the credit home.
    /// @return cost What the round trip cost them in cash, net of the payout and every refund they pulled.
    function _roundTrip(address who, uint256 drawn) internal returns (uint256 cost) {
        collateral.mint(who, COLL);
        uint256 cash0 = usdc.balanceOf(who);
        vm.startPrank(who);
        collateral.approve(address(v), COLL);
        uint256 id = v.borrow(_request(address(collateral), COLL, drawn), "", "");
        vm.stopPrank();
        uint256 debt = read.loan(id).debt;
        uint256 topUp = debt - (usdc.balanceOf(who) - cash0);
        usdc.mint(who, topUp);
        vm.startPrank(who);
        _approveCash(mid, debt);
        ace.repay(id, debt);
        ace.claimOwed(id, who);
        vm.stopPrank();
        v.crank();
        cost = cash0 + topUp - usdc.balanceOf(who);
    }

    /// @notice A GENUINE repayment is held for a standing request before the door may lend it, up to the request's worth and no further.
    /// @dev With the request worth more than idle, `lendable` reads zero before the collect and after it; under idle, it reads idle less the worth.
    function test_Control_AStandingRequestHoldsAGenuineRepaymentBeforeTheDoorLendsIt() public {
        _ask(alice, 1, 1); // worth about 10,000 against about 6,000 idle
        assertEq(v.lendable(), 0, "PREMISE: the whole request holds all of exitable");
        uint256 idle0 = v.idle();
        _repay(loanId, 1_000e6);
        v.crank();
        assertGt(v.idle(), idle0, "PREMISE: the repayment came home into idle");
        assertEq(v.lendable(), 0, "a real repayment is held for the request, as designed");

        (uint256 escrowed,) = v.requestOf(alice);
        vm.prank(alice);
        v.cancelExit(escrowed); // back to no request
        _ask(alice, 1, 4); // now worth under idle
        (uint256 exitable, uint256 held) = v.holds();
        assertEq(exitable, v.idle(), "PREMISE: no roll hold, so all of idle is exitable");
        assertLt(held, exitable, "PREMISE: the request is worth less than idle");
        assertEq(v.lendable(), exitable - held, "lendable is idle less the request's worth");

        uint256 room = v.lendable();
        _expectBorrowPastLendable(v, room + 1);
        uint256 id = _borrow(v, room);
        assertFalse(ace.isClosed(id), "and a borrow of exactly lendable lands");
        (, uint256 heldAfter) = v.holds();
        assertEq(heldAfter, v.idle(), "leaving idle exactly the request's hold");
    }

    /// @notice The safe property: a holder's own value-neutral open and repay never raise what they may take out.
    /// @dev A whole request leaves nothing lendable, so the door refuses her round trip outright.
    /// @dev A partial request leaves room, and the round trip through it moves her claim by at most its own fee gain.
    function test_ARequestersOwnRoundTripNeverRaisesTheirClaim() public {
        uint256 snap = vm.snapshotState();
        _ask(alice, 1, 1);
        assertEq(v.lendable(), 0, "PREMISE: her whole request holds all of exitable");
        collateral.mint(alice, COLL);
        vm.startPrank(alice);
        collateral.approve(address(v), COLL);
        vm.expectRevert(AceVaultFlows.OverLendable.selector);
        v.borrow(_request(address(collateral), COLL, RIG_MIN_DEBT), "", "");
        vm.stopPrank();
        vm.revertToState(snap);

        _ask(alice, 1, 4);
        uint256 room = v.lendable();
        assertGt(room, RIG_MIN_DEBT, "PREMISE: a partial request leaves room to lend");
        uint256 snap2 = vm.snapshotState();
        uint256 plain = _claimAll(alice);
        vm.revertToState(snap2);
        _roundTrip(alice, room);
        uint256 took = _claimAll(alice);
        assertGt(plain, 0, "LIVENESS: the plain claim takes something, or the row proves nothing");
        assertLe(took, plain + 100e6, "a requesting holder's own open-and-repay turned the stayers' idle into their claim");
    }

    /// @dev The claim the round trip is measured through: all of the request exitable cash covers now.
    function _claimAll(address who) internal returns (uint256) {
        uint256 m = v.maxClaim(who); // BEFORE the prank: a read is a call, and a call would eat it
        vm.prank(who);
        return v.claimExit(m, who, 0);
    }
}
