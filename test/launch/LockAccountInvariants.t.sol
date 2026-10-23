// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.36;

import {Test, console2} from "forge-std/Test.sol";
import {StdInvariant} from "forge-std/StdInvariant.sol";
import {LockAccount} from "../../src/entities/launch/LockAccount.sol";
import {AceReader} from "../utils/AceReader.sol";
import {LockAccountHandler} from "./LockAccountHandler.sol";

/// @title LockAccountChecks
/// @notice B1's property, as the INDUCTION the proof runs on rather than only its conclusion.
/// @notice For every future tau: spent + (units of live pledges expiring by tau) <= V(tau). `out(t) <= V(t)` follows, and is checked too.
/// @dev The grid is the next 40 days daily plus every live pledge's own expiry, the points where the left side steps.
abstract contract LockAccountChecks is Test {
    LockAccountHandler internal handler;
    LockAccount internal acct;
    AceReader internal read;

    function _build(uint256 scheduleId) internal {
        handler = new LockAccountHandler(scheduleId);
        acct = handler.acct();
        read = handler.read();
    }

    /// @notice All four properties on one walk; the first failure names the break.
    function _checkAll() internal view {
        assertFalse(handler.breached(), "an over-capacity pledge or an over-release landed");
        assertEq(acct.totalAllocation(), handler.totalIn(), "the account's books disagree with what landed");
        _inductive();
        _outBoundedByVested();
        _ledgerMatchesHub();
    }

    /// @dev The inductive form, over the grid.
    function _inductive() internal view {
        uint256 nowT = handler.now_();
        for (uint256 k; k <= 40; ++k) {
            _checkAt(nowT + k * 1 days);
        }
        uint256 n = handler.loanCount();
        for (uint256 i; i < n; ++i) {
            (uint256 units, uint64 e) = acct.pledgeOf(handler.loanAt(i));
            if (units != 0 && e >= nowT) _checkAt(e);
        }
    }

    function _checkAt(uint256 tau) internal view {
        uint256 lhs = acct.spent();
        uint256 n = handler.loanCount();
        for (uint256 i; i < n; ++i) {
            (uint256 units, uint64 e) = acct.pledgeOf(handler.loanAt(i));
            if (units != 0 && e <= tau) lhs += units;
        }
        uint256 v = _vOracle(tau);
        assertEq(acct.vestedAmount(uint64(tau)), v, "the account's V(tau) disagrees with the curve");
        assertLe(lhs, v, "spent + pledges expiring by tau exceed V(tau)");
    }

    /// @dev The conclusion: what has left the account's reach is at most what has vested now.
    function _outBoundedByVested() internal view {
        uint256 out = handler.totalIn() - handler.claimable();
        assertLe(out, _vOracle(handler.now_()), "more left the account than has vested");
    }

    /// @dev V(t) computed HERE, from the lock's schedule and the ghost total, so a defect in the account's own curve cannot hide.
    function _vOracle(uint256 t) internal view returns (uint256) {
        (uint64 start, uint64 cliff, uint64 duration) = handler.lock().schedules(handler.scheduleId());
        uint256 total = handler.totalIn();
        if (t < uint256(start) + cliff) return 0;
        if (t >= uint256(start) + duration) return total;
        return total * (t - start) / duration;
    }

    /// @dev Every live ledger entry is the hub's own loan, at the hub's own units and expiry.
    function _ledgerMatchesHub() internal view {
        uint256 n = handler.loanCount();
        for (uint256 i; i < n; ++i) {
            uint256 loanId = handler.loanAt(i);
            (uint256 units, uint64 e) = acct.pledgeOf(loanId);
            if (units == 0 || handler.ace().isClosed(loanId)) continue;
            assertEq(read.loan(loanId).collateralUnits, units, "a live pledge's units drifted from the hub's");
            assertEq(read.loan(loanId).expiry, e, "a live pledge's expiry drifted from the hub's");
            assertEq(handler.ace().borrowerOf(loanId), address(acct), "a live pledge's title left the account");
        }
    }
}

/// @title LockAccountInvariants
/// @notice The campaign: every verb in random order, the properties after every call.
/// @dev Config (foundry.toml [invariant]): runs = 256, depth = 32, fail_on_revert = false.
abstract contract LockAccountInvariantsBase is StdInvariant, LockAccountChecks {
    function _schedule() internal pure virtual returns (uint256);

    function setUp() public {
        _build(_schedule());
        bytes4[] memory sel = new bytes4[](8);
        sel[0] = LockAccountHandler.pledge.selector;
        sel[1] = LockAccountHandler.release.selector;
        sel[2] = LockAccountHandler.repay.selector;
        sel[3] = LockAccountHandler.defaultLoan.selector;
        sel[4] = LockAccountHandler.reclaim.selector;
        sel[5] = LockAccountHandler.warp.selector;
        sel[6] = LockAccountHandler.donate.selector;
        sel[7] = LockAccountHandler.pledgeAtCapacity.selector;
        targetSelector(FuzzSelector({addr: address(handler), selectors: sel}));
        targetContract(address(handler));
    }

    function invariant_all() public view {
        _checkAll();
    }

    /// @notice The reach tallies, LAST sequence only: a campaign that never pledged, defaulted or reclaimed proved nothing.
    /// @dev Logged rather than asserted: each run restarts from setUp, and a cold 32-call run can miss a three-verb chain.
    /// @dev The chain is pinned deterministically by `LockAccountScripted`, so reach is never left to the fuzzer alone.
    function afterInvariant() external view {
        console2.log("=== LockAccountHandler verb hits (LAST sequence only) ===");
        console2.log("pledge            ", handler.hits("pledge"));
        console2.log("pledge refused    ", handler.hits("pledgeRefused"));
        console2.log("release           ", handler.hits("release"));
        console2.log("repay             ", handler.hits("repay"));
        console2.log("forceClose        ", handler.hits("forceClose"));
        console2.log("settleExpired     ", handler.hits("settleExpired"));
        console2.log("reclaim           ", handler.hits("reclaim"));
        console2.log("donate            ", handler.hits("donate"));
    }
}

/// @notice The buyer schedule: linear over 30 days.
contract LockAccountBuyerInvariants is LockAccountInvariantsBase {
    function _schedule() internal pure override returns (uint256) {
        return 0;
    }
}

/// @notice The team's year-long linear vest behind a 30-day cliff.
contract LockAccountTeamLinearInvariants is LockAccountInvariantsBase {
    function _schedule() internal pure override returns (uint256) {
        return 2;
    }
}

/// @title LockAccountScripted
/// @notice The chains the campaign can miss, driven in order with every property checked after each step.
contract LockAccountScripted is LockAccountChecks {
    /// @notice Pledge to capacity, default at expiry, reclaim, release what vested: the bypass, step by step.
    function test_B1_ScriptedDefaultChainHoldsTheInduction() public {
        _build(0);
        handler.pledge(type(uint256).max, 0); // over capacity at the shortest tenor: refused
        _checkAll();
        handler.pledgeAtCapacity(0); // exactly capacity at the shortest tenor
        _checkAll();
        handler.pledgeAtCapacity(type(uint256).max); // and again at the longest
        _checkAll();
        handler.defaultLoan(0, false);
        _checkAll();
        handler.reclaim(0);
        _checkAll();
        handler.donate(5_000e18);
        _checkAll();
        handler.release(type(uint256).max);
        _checkAll();
        handler.defaultLoan(1, true);
        _checkAll();
        handler.reclaim(1);
        _checkAll();
        handler.warp(type(uint256).max);
        handler.release(type(uint256).max);
        _checkAll();
        assertEq(handler.hits("pledgeRefused"), 1, "the over-capacity pledge was refused");
        assertGt(handler.hits("pledge"), 1, "both pledges landed");
        assertGt(handler.hits("reclaim"), 1, "both reclaims landed");
        assertFalse(handler.breached(), "nothing breached");
    }

    /// @notice Pledge, repay, reclaim, and the probe one atom past every release, on the team's linear vest.
    function test_C1_ScriptedRepayChainHoldsTheInduction() public {
        _build(2);
        handler.warp(type(uint256).max);
        handler.warp(type(uint256).max);
        handler.warp(type(uint256).max);
        handler.warp(type(uint256).max);
        handler.warp(type(uint256).max);
        handler.warp(type(uint256).max);
        handler.warp(type(uint256).max); // 35 days: past the 30-day cliff
        handler.pledgeAtCapacity(type(uint256).max);
        _checkAll();
        handler.repay(0);
        _checkAll();
        handler.reclaim(0);
        _checkAll();
        handler.release(type(uint256).max);
        _checkAll();
        assertGt(handler.hits("repay"), 0, "the repay landed");
        assertGt(handler.hits("reclaim"), 0, "the reclaim landed");
    }
}
