// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.36;

import {LockAccountChecks} from "./LockAccountInvariants.t.sol";

/// @title LockAccountCliffScripted
/// @notice The induction on the one curve the campaigns never run: the single-tranche team schedule, whose V steps from zero to the whole.
/// @notice The campaigns cannot reach it either: its tranche sits 90 days out and a 32-call run warps about nine.
contract LockAccountCliffScriptedTest is LockAccountChecks {
    /// @notice Refused before the tranche at every tenor, the whole allocation pledged against an expiry past it, a default, a reclaim,
    /// @notice a release at the tranche net of the forfeit, then a donation released at once: every property checked after every step.
    function test_CliffTrancheChainHoldsTheInduction() public {
        _build(1);
        handler.pledge(0, 0); // the shortest tenor, at the anchor: V(E) is zero
        _checkAll();
        handler.pledgeAtCapacity(type(uint256).max); // the longest tenor still expires 60 days before the tranche: capacity zero, nothing tried
        _checkAll();
        handler.release(0); // probes one atom past a zero releasable
        _checkAll();
        assertEq(handler.hits("pledgeRefused"), 1, "the pledge before the tranche was not refused");
        assertEq(handler.hits("pledge"), 0, "a pledge landed before the tranche");

        for (uint256 i; i < 13; ++i) {
            handler.warp(type(uint256).max); // five days a step: 65 days in, the tranche 25 days out
        }
        handler.pledge(0, 0); // a week's tenor still expires before the tranche
        _checkAll();
        assertEq(handler.hits("pledgeRefused"), 2, "a pledge expiring before the tranche was not refused");
        handler.pledgeAtCapacity(type(uint256).max); // 30 days: expires past the tranche, where V is the whole allocation
        _checkAll();
        assertEq(handler.hits("pledge"), 1, "the pledge past the tranche did not land");
        assertEq(acct.pledged(), acct.totalAllocation(), "the pledge past the tranche did not take the whole allocation");
        handler.release(0); // the tranche has not come: nothing releases, the whole allocation is pledged anyway
        _checkAll();

        handler.defaultLoan(0, false);
        _checkAll();
        handler.reclaim(0);
        _checkAll();
        assertGt(acct.spent(), 0, "fixture: the default forfeited the coverage line");
        assertEq(handler.hits("reclaim"), 1, "the reclaim did not land");

        handler.release(type(uint256).max); // past the tranche: everything the default left
        _checkAll();
        assertEq(acct.spent(), acct.totalAllocation(), "past the tranche, not everything left was releasable");
        handler.donate(123e18);
        _checkAll();
        assertEq(acct.releasable(), 123e18, "a donation past the tranche is not releasable at once");
        handler.release(type(uint256).max);
        _checkAll();
        assertFalse(handler.breached(), "an over-capacity pledge or an over-release landed");
    }
}
