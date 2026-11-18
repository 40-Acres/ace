// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.36;

import {AceVault} from "../../src/curator/AceVault.sol";
import {InKindRig} from "./InKindRig.sol";

/// @dev The lens view these rows read beside the vault's own gates.
interface IInKindGateLens {
    function entryGate(address vault) external view returns (bytes4 reason, uint256 until);
}

/// @title AceVaultEntryGateInKind
/// @notice `AceVaultLens.entryGate` in kind: the collect's open batch reads `InventoryUnsold` for its block alone, and the supply bound reads `OverSupply`.
/// @notice Each row checks the lens against the vault's own `maxDeposit`, which the lens must agree with.
contract AceVaultEntryGateInKindTest is InKindRig {
    uint256 internal constant BOUND = 1 << 160; // the in-kind supply bound

    function _gate() internal view returns (bytes4 reason) {
        (reason,) = IInKindGateLens(address(lens)).entryGate(address(vault));
    }

    /// @notice In the collect's block the lens reads the open batch, as the vault does; a block on, both read open.
    function test_EntryGateInKind_TheCollectsBlockReadsInventoryUnsold() public {
        _lp(alice, LP_CASH);
        uint256 loanId = _open(address(tokA));
        _defaultAndCollect(loanId);
        (uint256 unsold,) = ace.lenderUnresolved(address(vault), address(usdc));
        assertEq(unsold, 0, "PREMISE: the pot came home, so nothing is unsold at the hub");
        assertGt(_trackedSupply(), 0, "PREMISE: a holder is tracked");
        assertEq(vault.maxDeposit(bob), 0, "PREMISE: the vault's own gate shuts entry in the collect's block");
        assertEq(_gate(), AceVault.InventoryUnsold.selector, "in the collect's block the lens did not read the open batch");
        _nextBlock();
        assertGt(vault.maxDeposit(bob), 0, "PREMISE: a block on, the vault reads open");
        assertEq(_gate(), bytes4(0), "a block on, the lens still read the batch");
    }

    /// @notice Under the bound the lens reads open; with the supply on the bound it names `OverSupply`, where `maxDeposit` reads zero.
    function test_EntryGateInKind_TheSupplyBoundReadsOverSupply() public {
        uint256 big = (BOUND - vault.SEED_SHARES()) / 1e6 - 10; // ten units of cash short of the bound
        _lp(alice, big);
        assertGt(vault.maxDeposit(bob), 0, "PREMISE: cash is left under the bound");
        assertEq(_gate(), bytes4(0), "under the bound the lens named a gate");
        uint256 room = BOUND - vault.totalSupply();
        usdc.mint(bob, room);
        vm.startPrank(bob);
        usdc.approve(address(vault), room);
        vault.mint(room, bob);
        vm.stopPrank();
        assertEq(vault.totalSupply(), BOUND, "PREMISE: the supply sits on the bound");
        assertEq(vault.maxDeposit(carol), 0, "PREMISE: maxDeposit reads zero at the bound");
        assertEq(_gate(), AceVault.OverSupply.selector, "at the bound the lens did not name OverSupply");
    }
}
