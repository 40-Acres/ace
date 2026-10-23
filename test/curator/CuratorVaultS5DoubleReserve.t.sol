// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.36;

import {CuratorVaultBase} from "./CuratorVaultBase.sol";
import {CuratorVault} from "../../src/curator/CuratorVault.sol";
import {BorrowRequest} from "../../src/curator/AceVaultFlows.sol";

/// @title CuratorVaultS5DoubleReserve
/// @notice No need is held twice: a request claimed whole leaves nothing held behind, and no unit of idle is held for both a roll and a request.
/// @dev The fixture is the one the double-reserve finding was measured on: three LPs, four fifths lent, NAV flat, two repayments.
/// @dev Plus one small ARMED loan, so the roll hold is standing beside the request's hold the whole time.
/// @dev RESTATED ON THE READ-TIME HOLDS: the request's hold is carved out of exitable, which is already net of the roll hold.
contract CuratorVaultS5DoubleReserveTest is CuratorVaultBase {
    uint256 internal constant ALICE_IN = 8_000e6;
    uint256 internal constant BOB_IN = 1_000e6;
    uint256 internal constant CAROL_IN = 10_000e6;
    uint256 internal constant LENT = 15_200e6; // four fifths of the book
    uint256 internal constant ARMED = 100e6; // a small armed loan, so a roll hold stands beside the request
    uint256 internal constant ARRIVAL = 3_000e6; // one repayment, then another
    uint256 internal constant DUST = 2;
    address internal carol = address(0xCA201);

    CuratorVault internal v;
    uint256 internal loanId;

    function setUp() public override {
        super.setUp();
        v = _newVault(0);
        _lpDeposit(v, alice, ALICE_IN);
        _lpDeposit(v, bob, BOB_IN);
        _lpDeposit(v, carol, CAROL_IN);
        loanId = _open(LENT);
        _crank(v, loanId, T2, 0);
        collateral.mint(borrower, COLL);
        vm.startPrank(borrower);
        collateral.approve(address(v), COLL);
        BorrowRequest memory r = _request(address(collateral), COLL, ARMED);
        r.arm = true;
        v.borrow(r, "", "");
        vm.stopPrank();
        _warpBy(VEST_W); // the opens' own gain vests before anyone asks, so NAV is flat from here
        v.crank();
        assertGt(v.rollHoldNow(), 0, "PREMISE: a roll hold stands");
    }

    /// @dev Bob requests his whole stake, two repayments land behind it and are cranked home, and he claims the whole request.
    /// @dev While the request stands, its hold is carved out of exitable, which is idle less the roll hold.
    function _serveBob() internal returns (uint256 paid, uint256 worth) {
        uint256 escrow = v.balanceOf(bob);
        worth = v.convertToAssets(escrow);
        vm.prank(bob);
        v.requestExit(escrow);
        _repay(loanId, ARRIVAL);
        _repay(loanId, ARRIVAL);
        v.crank(); // a repayment reaches idle only at a crank
        (uint256 exitable, uint256 held) = v.holds();
        assertEq(exitable, v.idle() - v.rollHoldNow(), "exitable is idle less the roll hold");
        assertLe(held, exitable, "the request's hold sits inside exitable, never on top of the roll hold");
        assertLe(held, worth + DUST, "and never past the request's worth");
        assertEq(v.lendable(), exitable - held, "lendable is what neither hold takes");
        vm.prank(bob);
        paid = v.claimExit(escrow, bob, 0);
    }

    /// @notice The safe property: a request claimed whole and ended leaves no held cash behind it, and the roll hold is untouched.
    /// @dev Its surplus would sit in the request's hold, owed to no request, and keep the door from lending it.
    function test_AServedRequestLeavesNoCashHeldBehind() public {
        uint256 rollHold0 = v.rollHold();
        (uint256 paid, uint256 worth) = _serveBob();
        (uint256 left,) = v.requestOf(bob);
        assertEq(v.requestedShares(), 0, "PREMISE: no request stands");
        assertEq(left, 0, "PREMISE: bob's request ended");
        assertApproxEqAbs(paid, worth, DUST, "PREMISE: bob was paid his whole stake, so the request was served whole");
        (uint256 exitable, uint256 held) = v.holds();
        emit log_named_uint("request hold after the served request", held);
        assertEq(held, 0, "a request that is gone holds nothing back");
        assertEq(v.lendable(), exitable, "so all of exitable is lendable again");
        assertEq(v.rollHold(), rollHold0, "and the claim took nothing out of the roll hold's record");
    }
}
