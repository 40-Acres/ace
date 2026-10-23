// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.36;

import {CuratorVaultBase} from "./CuratorVaultBase.sol";
import {AceVault} from "../../src/curator/AceVault.sol";
import {CuratorVault} from "../../src/curator/CuratorVault.sol";
import {PriceFrame} from "../utils/PriceFrame.sol";
import {Math} from "@openzeppelin/contracts/utils/math/Math.sol";

/// @title CuratorVaultWorkout
/// @notice Workout mode: entry and new lending close on an unresolved impairment, exits never do.
contract CuratorVaultWorkoutTest is CuratorVaultBase {
    uint256 internal constant SEED = 10_000e6;
    uint256 internal constant DRAW = 6_000e6;
    uint256 internal constant BIG_COLL = 4_000_000e18;

    function setUp() public override {
        super.setUp();
        record.setMinPrice(T2);
    }

    /// @dev A settled but un-cranked class: the write-off has not been recognized yet.
    function _settled(CuratorVault v) internal returns (uint256 loanId) {
        _lpDeposit(v, alice, SEED);
        loanId = _open(DRAW);
        _crank(v, loanId, T2, 0);
        _finalize(loanId);
    }

    function _impaired(CuratorVault v) internal returns (uint256 loanId) {
        loanId = _settled(v);
        _crankAll(v);
    }

    function _tryDeposit(CuratorVault v, address who, uint256 amt) internal {
        usdc.mint(who, amt);
        vm.startPrank(who);
        usdc.approve(address(v), amt);
        v.deposit(amt, who);
        vm.stopPrank();
    }



    /// @dev T27 restated: the class stops giving when its POT empties, and the recovery reaches NAV.
    /// @dev There is no workout flag left to clear, so what a later entrant meets is the price, and the pile gate.
    /// @dev While the recovery vests it sits over GATE_BPS of NAV and entry is refused `GainVesting`; once vested, the same depositor enters.
    function test_Recovery_LeavesTheClassSpentAndEntryOpen() public {
        CuratorVault v = _newVault(0);
        uint256 loanId = _impaired(v);
        uint256 navAfterLoss = v.totalAssets();

        _buyPot(keeper, loanId, 40_000e6);
        _crankAll(v);
        _crankAll(v);

        assertGt(v.totalAssets() + v.unvested(), navAfterLoss, "the sale reached NAV through the crank");
        assertEq(lens.claimable(address(v), v.asset()), 0, "and the spent pool has nothing left to give");
        assertGt(v.unvested() * 10_000, v.totalAssets() * v.GATE_BPS(), "PREMISE: the recovery vests as a pile over GATE_BPS");
        assertEq(v.maxDeposit(bob), 0, "the max view advertised an entry the pile gate refuses");
        usdc.mint(bob, 1_000e6);
        vm.startPrank(bob);
        usdc.approve(address(v), 1_000e6);
        vm.expectRevert(AceVault.GainVesting.selector);
        v.deposit(1_000e6, bob);
        vm.stopPrank();
        _warpBy(VEST_W);
        assertEq(v.unvested(), 0, "PREMISE: the recovery has vested whole");
        _tryDeposit(v, bob, 1_000e6);
        assertGt(v.balanceOf(bob), 0, "and a depositor can enter");
    }

    /// @dev T28: the trough gate is deleted, but a JIT depositor into a deep impairment is refused until its settled pot sells.
    /// @dev So it captures none of the later recovery: the unsold pot refuses it `InventoryUnsold`, with no share minted.
    function test_Skim_AJitDepositIntoADeepImpairmentIsRefusedUntilTheSale() public {
        CuratorVault v = _newVault(0);
        uint256 doomed = _impaired(v);
        assertTrue(ace.isClosed(doomed), "PREMISE: the impairment landed");
        uint256 live = Math.mulDiv(v.totalAssets() + 1, 1e18, v.totalSupply() + 1e6);
        assertLt(live * 10_000, uint256(1e12) * (10_000 - v.GATE_BPS()), "PREMISE: the impairment sits deeper than GATE_BPS under par");
        _assertEntryWaitsForTheSale(v, bob);
    }

    /// @dev T38 INVERTED: a realized loss reserves NOTHING. Every cent of the vault's balance stays lendable.
    /// @dev Bob's cash lands BEFORE the loss, so the balance holds his deposit as well as alice's leftover.
    /// @dev With no request and no armed loan, `lendable` is the whole balance: one wei past it is refused, and all of it lends.
    function test_Lend_ReservesNothingAgainstARealizedLoss() public {
        CuratorVault v = _newVault(0);
        _lpDeposit(v, bob, SEED);
        _impaired(v);
        uint256 cash = v.idle();
        assertGt(cash, 0, "there is cash on hand after the loss");
        assertEq(v.lendable(), cash, "the WHOLE balance is lendable: the loss holds nothing back from it");

        _expectBorrowPastLendable(v, cash + 1);
        assertEq(v.idle(), cash, "and the refused borrow left the balance exactly where it was");

        uint256 loanId = _open(cash);
        assertEq(read.claimOf(mid, loanId), cash, "a borrow of all of it lands");
        assertEq(v.idle(), 0, "and takes every wei of the balance");
    }

    /// @dev T39: the class brake is deleted, so a large set is an accepted consequence, not a refusal.
    function test_Lend_IsUncappedInPositions() public {
        uint256 target = 130;
        CuratorVault v = _newVault(0);
        _lpDeposit(v, alice, target * 100e6 + 5_000e6);
        _buildClasses(v, target);

        assertGe(_carriedClasses(v), target, "the set runs past what the old brake allowed");
        assertEq(v.grossNav(), _hubTruthNav(v), "nothing is impaired: this is the cap alone talking");

        uint256 idleBefore = v.idle();
        uint256 loanId = _borrow(v, 1_000e6);
        assertEq(read.claimOf(mid, loanId), 1_000e6, "and the door still lends at any position count");
        assertEq(idleBefore - v.idle(), 1_000e6, "out of the vault's own balance");
    }

    /// @dev Withdrawal and the exit stay open right through an impairment; nothing about a loss gates them.
    function test_Workout_ExitsStayOpen() public {
        CuratorVault v = _newVault(0);
        uint256 loanId = _impaired(v);
        assertTrue(ace.isClosed(loanId), "impaired: the loan really did settle");
        uint256 first = v.balanceOf(alice) / 10; // BEFORE the prank: a read is a call, and a call would eat it
        vm.prank(alice);
        v.requestExit(first); // the claim below prices at the impaired NAV
        uint256 m = v.maxClaim(alice);
        assertGt(m, 0, "recall still works in a workout, and the cash exit is quoted");

        vm.prank(alice);
        uint256 got = v.claimExit(m, alice, 0);
        assertGt(got, 0, "and it pays");
        assertGt(_redeemFrac(v, alice, 1, 10), 0, "as many times as an LP asks");
    }
}
