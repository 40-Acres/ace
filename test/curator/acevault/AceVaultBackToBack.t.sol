// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.36;

import {AceVaultRig} from "./AceVaultRig.sol";

/// @notice Back-to-back promised rolls in one market, from a vault drained to the hold, never land in the hub's dust gap.
/// @dev Three times the record covers the fresh draws, any one market's reservations, and the carry's growth across the run.
contract AceVaultBackToBackTest is AceVaultRig {
    uint256 internal constant N = 6;

    /// @notice Every promised roll in the window runs, each from idle sitting at the hold, and nothing rests after any of them.
    function test_PromisedRollsAtTheHoldNeverRevert() public {
        uint256[] memory ids = new uint256[](N);
        for (uint256 i; i < N; i++) {
            ids[i] = _borrowAs(address(uint160(0xB000 + i)), UNITS, PRINCIPAL, MIN_TENOR, true);
        }
        bytes32 m = _mid(ids[0]);
        for (uint256 i = 1; i < N; i++) {
            assertEq(_mid(ids[i]), m, "premise: one market");
        }
        _warpBy(VEST_W + 1);
        uint256 out = vault.maxWithdraw(alice);
        vm.prank(alice);
        vault.withdraw(out, alice, alice);
        assertEq(vault.idle(), vault.rollHoldNow(), "premise: the vault sits exactly at the hold");
        _toWindow(ids[0]);
        for (uint256 i; i < N; i++) {
            uint256 newId = vault.roll(ids[i], "");
            assertTrue(ace.isLiveLoan(newId), "each promised roll ran");
            _assertNothingRests(m);
        }
    }

    /// @notice The same run promises no successor: from the hold, every successor's growth finds nothing lendable, so none is booked funded.
    function test_RollsAtTheHoldPromiseNoSuccessor() public {
        uint256[] memory ids = new uint256[](N);
        for (uint256 i; i < N; i++) {
            ids[i] = _borrowAs(address(uint160(0xD000 + i)), UNITS, PRINCIPAL, MIN_TENOR, true);
        }
        _warpBy(VEST_W + 1);
        uint256 out = vault.maxWithdraw(alice);
        vm.prank(alice);
        vault.withdraw(out, alice, alice);
        assertEq(vault.idle(), vault.rollHoldNow(), "premise: the vault sits exactly at the hold");
        _toWindow(ids[0]);
        for (uint256 i; i < N; i++) {
            uint256 newId = vault.roll(ids[i], "");
            assertTrue(ace.isLiveLoan(newId), "each promised roll ran");
            assertFalse(_funded(newId), "and promised its successor nothing");
        }
    }

    /// @notice The same run with mixed sizes, so the market's reservations are uneven when each roll's cover is rested.
    function test_UnevenPromisedRollsAtTheHoldNeverRevert() public {
        uint256[] memory ids = new uint256[](N);
        for (uint256 i; i < N; i++) {
            uint256 p = PRINCIPAL * (i + 1);
            ids[i] = _borrowAs(address(uint160(0xC000 + i)), UNITS * (i + 1), p, MIN_TENOR, true);
        }
        _warpBy(VEST_W + 1);
        uint256 out = vault.maxWithdraw(alice);
        vm.prank(alice);
        vault.withdraw(out, alice, alice);
        _toWindow(ids[0]);
        for (uint256 i = N; i > 0; i--) {
            uint256 newId = vault.roll(ids[i - 1], "");
            assertTrue(ace.isLiveLoan(newId), "each promised roll ran, largest first");
        }
    }
}
