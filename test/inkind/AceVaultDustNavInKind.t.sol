// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.36;

import {InKindRig} from "./InKindRig.sol";

/// @title AceVaultDustNavInKind
/// @notice The dust-NAV walk in kind, where `MAX_SUPPLY` binds: a stamp reads back exactly, so a stranger's dust cannot walk supply to the bound.
contract AceVaultDustNavInKindTest is InKindRig {
    function _stamp() internal {
        usdc.mint(stranger, 1);
        vm.prank(stranger);
        usdc.transfer(address(vault), 1);
        vault.collectFee();
    }

    function _tryDeposit(address who, uint256 amt) internal returns (bool ok, bytes memory reason) {
        usdc.mint(who, amt);
        vm.startPrank(who);
        usdc.approve(address(vault), amt);
        try vault.deposit(amt, who) returns (uint256) {
            ok = true;
        } catch (bytes memory err) {
            reason = err;
        }
        vm.stopPrank();
    }

    /// @notice One hundred and thirty-eight rounds of the walk leave NAV and supply at par; a one-USDC and the rig's LP deposit both land.
    function test_DustNavInKind_AStrangersStampsCannotWalkSupplyToTheBound() public {
        _lp(stranger, 3);
        _stamp();
        _warpBy(1);
        uint256 a0 = vault.totalAssets();
        uint256 s0 = vault.totalSupply();
        for (uint256 r; r < 138; ++r) {
            for (uint256 j; j < 10 && vault.totalAssets() > 1; ++j) {
                _stamp();
            }
            _lp(stranger, 2);
        }
        assertEq(vault.totalAssets(), a0 + 2 * 138, "the stamps moved NAV: only the deposits may");
        assertLe(vault.totalSupply(), s0 + 2 * 138 * 1e6 + 138, "the walk inflated the share count past par");
        (bool ok,) = _tryDeposit(alice, 1e6);
        assertTrue(ok, "a one-USDC deposit refused after the walk");
        _warpBy(VEST_W + 1);
        vault.collectFee();
        (ok,) = _tryDeposit(bob, LP_CASH);
        assertTrue(ok, "the rig's LP deposit refused after the walk vested");
    }
}
