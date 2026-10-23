// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.36;

import {Math} from "@openzeppelin/contracts/utils/math/Math.sol";
import {CuratorVaultBase} from "./CuratorVaultBase.sol";
import {CuratorVault} from "../../src/curator/CuratorVault.sol";
import {PriceFrame} from "../utils/PriceFrame.sol";

/// @title CuratorVaultBare
/// @notice The bare 4626: entry is PRICED at plain NAV with no surcharge and waits while a settled pot is unsold; the exit pays cash alone.
/// @dev Written against the pre-teardown contract, so every assertion here is a statement of the target shape.
contract CuratorVaultBareTest is CuratorVaultBase {
    uint256 internal constant SEED = 10_000e6;
    uint256 internal constant DRAW = 6_000e6;
    uint256 internal constant VIRTUAL = 1e6; // MUST agree with CuratorVault._decimalsOffset()

    function setUp() public override {
        super.setUp();
        record.setMinPrice(T2);
    }

    /// @dev One settled class marked down, with idle cash left to redeem against.
    function _impaired(CuratorVault v, uint256 seedA, uint256 seedB) internal returns (uint256 loanId) {
        _lpDeposit(v, alice, seedA);
        _lpDeposit(v, bob, seedB);
        loanId = _open(DRAW);
        _crank(v, loanId, T2, 0);
        _finalize(loanId);
        _crankAll(v);
    }

    function _tryDeposit(CuratorVault v, address who, uint256 amt) internal returns (uint256 shares) {
        usdc.mint(who, amt);
        vm.startPrank(who);
        usdc.approve(address(v), amt);
        shares = v.deposit(amt, who);
        vm.stopPrank();
    }

    /// @dev THE CLIFF IS GONE: there is no surcharge, and entry into a deep write-off is priced at plain pro-rata NAV once the pot is exempted or sold.
    /// @dev Replaces `test_Entry_IsPricedUpInWorkoutMode`, which priced this same mint at a surcharge.
    /// @dev The trough gate that once shut this entry is deleted; the unsold-pot gate shuts it until the pot is exempted.
    /// @dev The pot is exempted, so the loss stands and only the price is under test.
    function test_Entry_IsPricedAfterADeepWriteOff() public {
        CuratorVault v = _newVault(0);
        uint256 loanId = _impaired(v, 9_000e6, 1_000e6);
        assertTrue(ace.isClosed(loanId), "LIVENESS: the class really did settle, so a loss really landed");
        _waivePots(v);
        _assertEntryAdmitted(v, bob);
    }

    /// @dev The exit pays cash and moves no title: there is no in-kind fraction left to take.
    function test_Exit_PaysCashOnlyAndTransfersNoUnits() public {
        CuratorVault v = _newVault(0);
        uint256 loanId = _impaired(v, 9_000e6, 1_000e6);

        uint256 unitsHeld = read.invPotOf(mid, loanId);
        assertGt(unitsHeld, 0, "the vault holds real title booked at zero");

        uint256 got = _redeemAll(v, bob);

        assertGt(got, 0, "the cash leg paid");
        assertEq(read.invPotOf(mid, loanId), unitsHeld, "the stayers keep every unit");
    }

    /// @dev A vault a write-off nearly emptied takes no new capital until the settled pot sells: there is no trough gate, but the pot is unsold.
    /// @dev Replaces `test_EndOfLife_EntryStaysOpenPricedAtBadDebt`, whose open entry the unsold-pot gate reverses.
    function test_Entry_WaitsForTheSaleAfterAWriteOffEmptiesNav() public {
        CuratorVault v = _newVault(0);
        _lpDeposit(v, alice, DRAW);
        uint256 loanId = _open(DRAW);
        _crank(v, loanId, T2, 0);
        _finalize(loanId);
        _crankAll(v);

        assertLt(v.grossNav(), DRAW, "every cent of the position left the aggregates");
        assertLt(v.totalAssets(), DRAW, "and the loss fell straight through to NAV");
        assertGt(v.totalAssets(), 0, "PREMISE: the open's lender fee is left, so the vault is not spent");
        _assertEntryWaitsForTheSale(v, bob);
    }

    /// @dev New lending is bounded by `lendable` alone; a realized loss reserves nothing against it.
    /// @dev With no armed loan and no request standing, `lendable` is all of idle: a borrow of it lands and one wei past it is refused.
    function test_Borrow_IsBoundedByLendableAloneAfterALoss() public {
        CuratorVault v = _newVault(0);
        _impaired(v, 9_000e6, 8_000e6);
        uint256 cash = v.idle();
        assertGt(cash, 0, "there is cash on hand after the impairment");
        assertEq(v.lendable(), cash, "the loss reserved none of idle");

        _expectBorrowPastLendable(v, cash + 1);
        assertEq(v.idle(), cash, "the refused borrow left idle exactly where it was");

        uint256 loanId = _open(cash);
        assertFalse(ace.isClosed(loanId), "a borrow of all of lendable lands");
        assertEq(v.idle(), 0, "and the principal left idle whole");
        assertEq(ace.restingOf(mid), 0, "with nothing resting after the door");
    }

    /// @dev RULE BD: a loss is never accrued per pass. Fifty ordinary partial repays socialize nothing.
    /// @dev The memo is gone, so the observable is the share price: an ordinary repay may never lower it.
    function test_Nav_PerShareNeverFallsOnAnOrdinaryRepayment() public {
        CuratorVault v = _newVault(0);
        _lpDeposit(v, alice, SEED);
        uint256 loanId = _open(DRAW);
        _crank(v, loanId, T2, 0);

        uint256 last = v.convertToAssets(1e6);
        for (uint256 i; i < 50; i++) {
            _warpBy(1 hours);
            _repay(loanId, 20e6);
            _crankAll(v);
            assertGe(v.convertToAssets(1e6), last, "an ordinary repayment never costs a share, on any pass");
            last = v.convertToAssets(1e6);
        }
        assertFalse(ace.isClosed(loanId), "LIVENESS: the loan is still open, so no pass silently settled it");
    }
}
