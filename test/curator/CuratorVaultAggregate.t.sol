// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.36;

import {CuratorVaultBase} from "./CuratorVaultBase.sol";
import {CuratorVault} from "../../src/curator/CuratorVault.sol";

/// @title CuratorVaultAggregate
/// @notice THE AGGREGATE IDENTITY over the hub flow `CuratorVaultNav.t.sol` never drives: the inventory FILL.
/// @notice A fill moves the vault's owed credit with the vault not in the transaction at all.
/// @notice That is exactly when a NAV that keeps no book of its own can be wrong.
/// @dev The oracle throughout is `_hubTruthNav`, which sums the lens's pools by a different call path than the vault's own
/// @dev `Ace.lenderAssets` read, and reads CASH off the token balance.
/// @dev A CuratorVault market runs no deleverage band, so the keeper crank this file once drove has no subject here.
contract CuratorVaultAggregateTest is CuratorVaultBase {
    uint256 internal constant SEED = 40_000e6;
    uint256 internal constant DRAW = 12_000e6;
    address internal stranger = address(0x57A11);

    function setUp() public override {
        super.setUp();
        record.setMinPrice(T2);
    }

    /// @dev The identity itself, by the second read path, plus the balance the exit actually pays from.
    function _assertIdentity(CuratorVault v, string memory where) internal view {
        assertEq(v.grossNav(), _hubTruthNav(v), where);
        assertEq(usdc.balanceOf(address(v)), v.idle(), where);
        assertLe(v.totalAssets(), v.grossNav(), where);
    }

    /// @dev One live door loan, and the class booked.
    function _lentAndBooked(CuratorVault v) internal returns (uint256 loanId) {
        _lpDeposit(v, alice, SEED);
        loanId = _open(DRAW);
        _crank(v, loanId, T2, 0);
    }

    // ---- the inventory fill ----

    /// @dev A fill is quote arriving at a settled class from a party the vault never named. It raises
    /// @dev `unitOwed` and lowers nothing, so gross must rise by the credit and the identity must survive.
    /// @dev The crank then MOVES the credit: the owed cash comes home into idle, and NAV does not move.
    function test_BuyInventory_TheAggregateIdentityHoldsAcrossAFill() public {
        CuratorVault v = _newVault(0);
        uint256 loanId = _lentAndBooked(v);
        _finalize(loanId);
        _crankAll(v);
        _assertIdentity(v, "after the settlement");
        uint256 grossBefore = v.grossNav();

        uint256 filled = _buyPot(stranger, loanId, 40_000e6);
        assertGt(filled, 0, "LIVENESS: the pot really sold");
        assertGt(v.grossNav(), grossBefore, "and the proceeds are in the aggregate before anyone cranks");
        _assertIdentity(v, "after the fill");

        uint256 owed = lens.claimable(address(v), v.asset()); // the credit pools per (lender, quote)
        assertGt(owed, 0, "PREMISE: the fill credited the vault's pool at the hub");
        uint256 idleBefore = v.idle();
        uint256 grossAfterFill = v.grossNav();
        _crankAll(v);

        assertEq(v.idle() - idleBefore, owed, "the crank brings the proceeds home into idle, to the wei");
        assertEq(lens.claimable(address(v), v.asset()), 0, "and leaves nothing owed behind");
        assertEq(v.grossNav(), grossAfterFill, "and collecting them valued nothing: the crank is NAV-neutral");
        _assertIdentity(v, "after banking the fill");
    }

    /// @dev A PARTIAL fill leaves the pot live, and the identity must hold at every step of a drip.
    function testFuzz_BuyInventory_TheIdentityHoldsAcrossADripOfFills(uint96 bite) public {
        CuratorVault v = _newVault(0);
        uint256 loanId = _lentAndBooked(v);
        _finalize(loanId);
        _crankAll(v);
        uint256 amt = bound(uint256(bite), 100e6, 5_000e6);
        uint256 fills;

        for (uint256 i; i < 5; i++) {
            uint256 pot = lens.invPotOf(mid, loanId);
            if (pot == 0) break;
            if (_buyPot(stranger, loanId, amt) != 0) fills++;
            _assertIdentity(v, "mid-drip");
            _crankAll(v);
            _assertIdentity(v, "mid-drip, banked");
        }
        assertGt(fills, 0, "LIVENESS: not one fill landed, so this run judged nothing");
    }
}
