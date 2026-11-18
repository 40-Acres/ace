// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.36;

import {AceVaultFlows, Terms} from "../../../src/curator/AceVaultFlows.sol";
import {AceVaultDoorRig} from "../vault/AceVaultDoorRig.sol";

/// @title Suite_DoorReturnEntry
/// @notice RS-2 PoC, door form, fixed: a door's closing `returnProceeds(c, cash, true)` lifts the unsold-pot gate, and the trough hold keeps entry shut.
/// @notice An honest door returning the whole booked value in one call leaves NAV at the trough for a window; entry waits that window out.
/// @dev Beside RK-70 (phase 5 F-1), which measured the door's bare early close with no cash; here the close carries the cash, as an honest sale does.
contract Suite_DoorReturnEntry is AceVaultDoorRig {
    uint256 internal constant P = 40_000e6; // a loan of 4% of NAV, inside the row
    uint256 internal constant BIG = 80_000e18; // twice the principal's units at the record's 2 USDC
    uint256 internal constant ENTRY = 1_000_000e6;
    bytes4 internal constant RECOVERY_VESTING = bytes4(keccak256("RecoveryVesting()"));

    function _worth(address who) internal view returns (uint256) {
        return vault.previewRedeem(vault.balanceOf(who));
    }

    /// @dev The second entry reopens, from the vest word's bits 200-247.
    function _hold() internal view returns (uint256) {
        bytes32[] memory s = new bytes32[](1);
        s[0] = bytes32(uint256(AceVaultFlows.ROOT) + 2);
        return uint48(uint256(vault.extsload(s)[0]) >> 200);
    }

    /// @notice (c) The door collects, sells, and returns the whole booked value with `closes`: entry is held until the cash has vested.
    function test_RS2c_theDoorsClosingReturnHoldsEntryWhileItsCashVests() public {
        terms.setTerms(_doorMarket(address(coll), record), Terms({units: BIG, principal: P, tenor: 0, minBufferWad: 0}));
        uint256 loanId = _borrowAs(borrower, address(coll), BIG, P);
        _warpTo(read.loan(loanId).expiry + 1);
        _collect(loanId);
        (uint256 booked, bool open,) = _seized(address(coll));
        assertTrue(open, "premise: the collect opened the key");
        assertEq(vault.maxDeposit(bob), 0, "premise: the open key shuts entry");

        _give(address(coll), booked, true); // the sale's whole cash and the close, in one call
        uint256 trough = vault.totalAssets();
        (, bool stillOpen,) = _seized(address(coll));
        assertFalse(stillOpen, "the key closed");
        assertApproxEqAbs(vault.unvested(), booked, 1, "the returned cash vests");
        assertEq(vault.maxDeposit(bob), 0, "entry reopened in the return's own call, with NAV at the trough");
        assertEq(vault.maxMint(bob), 0, "and so did maxMint");
        usdc.mint(bob, ENTRY);
        vm.startPrank(bob);
        usdc.approve(address(vault), ENTRY);
        vm.expectRevert(RECOVERY_VESTING);
        vault.deposit(ENTRY, bob);
        vm.stopPrank();

        uint256 hold = _hold();
        uint256 heldFor = hold - _now();
        _warpTo(hold);
        assertEq(vault.unvested(), 0, "premise: the returned cash has vested at the hold");
        uint256 snap = vm.snapshotState();
        _lp(bob, ENTRY);
        _warpBy(VEST_W);
        vault.crank();
        uint256 bobOut = _worth(bob);
        uint256 aliceAttacked = _worth(alice);
        vm.revertToState(snap);
        _warpBy(VEST_W);
        vault.crank();
        uint256 aliceClean = _worth(alice);

        emit log_named_uint("booked value the door returned with closes", booked);
        emit log_named_uint("NAV right after the return", trough);
        emit log_named_uint("seconds entry was held after the return", heldFor);
        emit log_named_uint("entrant's worth after the window", bobOut);

        assertLe(bobOut, ENTRY, "the entrant at the hold took a share of a recovery it never funded");
        assertApproxEqAbs(bobOut, ENTRY, 2, "the entrant at the hold is not worth its entry to two atoms");
        assertGe(aliceAttacked + 1, aliceClean, "the stayers, who bore the loss, lost more than an atom");
    }
}
