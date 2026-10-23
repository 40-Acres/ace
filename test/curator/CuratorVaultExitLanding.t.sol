// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.36;

import {CuratorVaultBase} from "./CuratorVaultBase.sol";
import {CuratorVault} from "../../src/curator/CuratorVault.sol";
import {Lender} from "../../src/ace/hub/Lender.sol";

/// @title CuratorVaultExitLanding
/// @notice #381 hardening of the vault's hub exit, judged by OUTCOME where the calldata pins judge the call.
/// @notice `crank` pays the vault's own pool to the vault: the vault's cash rises by exactly the payout and neither NAV figure moves.
/// @dev The hub's event is pinned with every topic, so the vault is named as both the ledger key and the recipient.
contract CuratorVaultExitLandingTest is CuratorVaultBase {
    uint256 internal constant SEED = 10_000e6;

    /// @dev Everything a landing must leave unchanged or move by exactly the payout, read at one instant.
    struct Snap {
        uint256 gross;
        uint256 total;
        uint256 position; // the vault's `lenderAssets` at the hub
        uint256 vaultCash;
        uint256 callerCash;
    }

    function _snap(CuratorVault v, address caller) internal view returns (Snap memory s) {
        s.gross = v.grossNav();
        s.total = v.totalAssets();
        s.position = ace.lenderAssets(address(v), address(usdc));
        s.vaultCash = usdc.balanceOf(address(v));
        s.callerCash = usdc.balanceOf(caller);
    }

    /// @notice `crank` brings the vault's whole pool home into its own balance: the pool empties, the cash rises by it, NAV-neutral.
    function test_Crank_BringsThePoolHomeInPlaceAndMovesNoNav() public {
        CuratorVault v = _newVault(0);
        _lpDeposit(v, alice, SEED);
        _repay(_open(1_000e6), 300e6); // partial: the credit pools for the vault and nothing closes, so nothing pushes it
        uint256 owed = ace.lenderOwed(address(v), address(usdc));
        assertGt(owed, 0, "premise: the vault's pool holds credit");
        Snap memory s = _snap(v, keeper);

        vm.expectEmit(true, true, true, true, address(ace));
        emit Lender.Collected(address(v), address(usdc), address(v), owed);
        vm.prank(keeper);
        v.crank();

        assertEq(ace.lenderOwed(address(v), address(usdc)), 0, "the vault's whole pool came home");
        assertEq(s.position - ace.lenderAssets(address(v), address(usdc)), owed, "the vault's hub position fell by exactly the payout");
        assertEq(usdc.balanceOf(address(v)) - s.vaultCash, owed, "and the vault's own cash rose by it");
        assertEq(usdc.balanceOf(keeper), s.callerCash, "the caller was paid nothing");
        assertEq(v.grossNav(), s.gross, "so the vault's gross did not move");
        assertEq(v.totalAssets(), s.total, "and neither did totalAssets");
    }
}
