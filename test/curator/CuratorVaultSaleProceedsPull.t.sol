// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.36;

import {CuratorVaultBase} from "./CuratorVaultBase.sol";
import {CuratorVault} from "../../src/curator/CuratorVault.sol";

/// @title CuratorVaultSaleProceedsPull
/// @notice A SALE CREDITS THE VAULT'S POOL, and the next terminal close in its (lender, quote) pair carries it home with NO crank.
/// @notice The push lands in the vault's own balance: the hub pays the pooled asset out, the sale's proceeds with it.
/// @dev Measured as a DIFFERENTIAL against the same close with no sale before it, so the sale's share is isolated exactly.
contract CuratorVaultSaleProceedsPullTest is CuratorVaultBase {
    uint256 internal constant SEED = 20_000e6;
    uint256 internal constant DRAW = 6_000e6;
    address internal stranger = address(0x57A11);

    /// @notice ANOTHER LOAN'S CLOSING REPAY BRINGS A SALE'S PROCEEDS HOME, and no crank runs between.
    /// @dev The balance and NAV differ from the no-sale run by the fill alone, so nothing was banked twice and nothing was lost.
    function test_Close_AnotherLoansCloseCarriesASalesProceedsHomeWithNoCrank() public {
        CuratorVault v = _newVault(0);
        _lpDeposit(v, alice, SEED);
        uint256 doomed = _open(DRAW);
        _crank(v, doomed, T2, 0);
        _finalize(doomed);
        _crankAll(v);
        uint256 live = _open(DRAW);
        _crankAll(v);
        _warpAtLeastTo(read.inventoryAskOpensAt(doomed));
        assertEq(lens.claimable(address(v), v.asset()), 0, "PREMISE: nothing is pooled for the vault before the sale");

        uint256 snap = vm.snapshotState();
        _repay(live, read.loan(live).debt);
        (uint256 gross0, uint256 idle0) = (v.grossNav(), v.idle());
        vm.revertToState(snap);

        uint256 filled = _buyPot(stranger, doomed, 40_000e6);
        assertGt(filled, 0, "PREMISE: a stranger really bought the pot");
        assertEq(lens.claimable(address(v), v.asset()), filled, "the proceeds wait in the vault's pool, unpushed");
        _repay(live, read.loan(live).debt);

        assertEq(lens.claimable(address(v), v.asset()), 0, "the close pushed the whole pool home, the sale's proceeds with it");
        assertEq(v.idle() - idle0, filled, "the vault's balance holds the buyer's cash on top, counted once");
        assertEq(v.grossNav() - gross0, filled, "and NAV differs from the no-sale run by the fill alone");
        assertEq(v.grossNav(), _hubTruthNav(v), "agreeing with hub truth");
    }
}
