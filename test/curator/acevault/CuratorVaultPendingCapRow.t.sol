// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.36;

import {Vm} from "forge-std/Vm.sol";
import {CuratorVault, Row} from "../../../src/curator/CuratorVault.sol";
import {MockPersistenceRecord} from "../../mocks/MockPersistenceRecord.sol";
import {MockStakeVault} from "../../mocks/MockStakeVault.sol";
import {AceVaultRig} from "./AceVaultRig.sol";

/// @notice A new row is the curator's whole word on a collateral: a cap raise submitted before it never lands over the row's own cap.
/// @dev The defect it pins: a `submitCollateral` that left `_pendingCaps` standing let one `accept` write an earlier raise over the row.
contract CuratorVaultPendingCapRowTest is AceVaultRig {
    MockPersistenceRecord internal newRecord;

    uint192 internal constant CUT = 1_000e6;
    uint192 internal constant RAISE = 9_000e6;
    uint192 internal constant ROW_CAP = 2_000e6;

    function setUp() public override {
        super.setUp();
        newRecord = _record(address(coll), 1.5e18);
        vm.prank(guardian);
        vault.submitCap(address(coll), CUT); // a cut lands at once, so a later raise has room above it
    }

    /// @notice A raise submitted before a new row is dropped by it, so no accept, in any order, lifts the row's cap.
    function test_ANewRowDropsAnEarlierPendingCapRaise() public {
        vm.prank(curator);
        vault.submitCap(address(coll), RAISE);
        (, uint64 raiseAt) = vault.pendingCapOf(address(coll));
        assertGt(raiseAt, 0, "PREMISE: the raise is pending");

        _warpBy(1 days);
        vm.prank(curator);
        vault.submitCollateral(address(coll), _row(address(newRecord), ROW_CAP));
        (, uint64 validAt) = vault.pendingCapOf(address(coll));
        assertEq(validAt, 0, "the new row dropped the earlier raise");
        (Row memory pend, uint64 rowAt) = vault.pendingRowOf(address(coll));
        assertEq(pend.record, address(newRecord), "and the new row itself is pending");
        assertGt(rowAt, 0, "on its own timelock");

        _warpAtLeastTo(raiseAt);
        vm.prank(stranger);
        vm.expectRevert(CuratorVault.NothingDue.selector);
        vault.accept(address(coll));
        assertEq(vault.rowOf(address(coll)).cap, CUT, "the raise's due time lifts nothing");

        _warpBy(TIMELOCK);
        vm.prank(stranger);
        vault.accept(address(coll));
        assertEq(vault.rowOf(address(coll)).record, address(newRecord), "the new row is live");
        assertEq(vault.rowOf(address(coll)).cap, ROW_CAP, "at its own cap, not the earlier raise");
    }

    /// @notice A new row that drops a pending raise says so, ahead of its own submission, so an indexer replaying events ends right.
    function test_ANewRowDroppingARaiseEmitsRevokePendingFirst() public {
        vm.prank(curator);
        vault.submitCap(address(coll), RAISE);
        vm.expectEmit(true, true, false, false, address(vault));
        emit CuratorVault.RevokePending(curator, address(coll));
        vm.expectEmit(true, false, false, false, address(vault));
        emit CuratorVault.SubmitCollateral(address(coll), _row(address(newRecord), ROW_CAP), 0);
        vm.prank(curator);
        vault.submitCollateral(address(coll), _row(address(newRecord), ROW_CAP));
    }

    /// @notice A new row with nothing pending drops nothing, so it emits no revoke.
    function test_ANewRowWithNothingPendingEmitsNoRevoke() public {
        (, uint64 rowAt) = vault.pendingRowOf(address(coll));
        (, uint64 capAt) = vault.pendingCapOf(address(coll));
        assertEq(rowAt + capAt, 0, "PREMISE: nothing is pending for the collateral");
        vm.recordLogs();
        vm.prank(curator);
        vault.submitCollateral(address(coll), _row(address(newRecord), ROW_CAP));
        Vm.Log[] memory logs = vm.getRecordedLogs();
        assertEq(_count(logs, CuratorVault.SubmitCollateral.selector), 1, "PREMISE: the submission logged");
        for (uint256 i; i < logs.length; ++i) {
            assertTrue(logs[i].topics[0] != CuratorVault.RevokePending.selector, "nothing was pending, so nothing is revoked");
        }
    }

    /// @notice A cut that drops a pending raise says so too, ahead of the cut itself.
    function test_ACutDroppingARaiseEmitsRevokePendingFirst() public {
        vm.prank(curator);
        vault.submitCap(address(coll), RAISE);
        vm.expectEmit(true, true, false, false, address(vault));
        emit CuratorVault.RevokePending(guardian, address(coll));
        vm.expectEmit(true, true, false, true, address(vault));
        emit CuratorVault.SetCap(guardian, address(coll), CUT / 2);
        vm.prank(guardian);
        vault.submitCap(address(coll), CUT / 2);
    }

    /// @notice CONTROL: a raise submitted AFTER the row is the curator's later word, and lands on its own timelock.
    function test_ARaiseSubmittedAfterTheRowStillLands() public {
        vm.prank(curator);
        vault.submitCollateral(address(coll), _row(address(newRecord), ROW_CAP));
        _warpBy(1 days);
        vm.prank(curator);
        vault.submitCap(address(coll), RAISE);

        _warpBy(TIMELOCK);
        vault.accept(address(coll));
        assertEq(vault.rowOf(address(coll)).record, address(newRecord), "the row landed");
        assertEq(vault.rowOf(address(coll)).cap, RAISE, "and the later raise over it");
    }

    // ---- the event log ends where storage does ----

    /// @dev How many logs the vault emitted under `topic0`.
    function _count(Vm.Log[] memory logs, bytes32 topic0) internal view returns (uint256 n) {
        for (uint256 i; i < logs.length; ++i) {
            if (logs[i].emitter == address(vault) && logs[i].topics[0] == topic0) ++n;
        }
    }

    /// @dev Both pending slots for `coll` read empty.
    function _assertNothingPending(string memory what) internal view {
        (, uint64 rowAt) = vault.pendingRowOf(address(coll));
        (uint192 cap, uint64 capAt) = vault.pendingCapOf(address(coll));
        assertEq(uint256(rowAt) + capAt + cap, 0, what);
    }

    /// @notice The revoke a new row makes drops the raise and never the row it is writing.
    function test_ANewRowDroppingARaiseLeavesItsOwnRowPending() public {
        vm.prank(curator);
        vault.submitCap(address(coll), RAISE);
        vm.prank(curator);
        vault.submitCollateral(address(coll), _row(address(newRecord), ROW_CAP));
        (Row memory pending, uint64 rowAt) = vault.pendingRowOf(address(coll));
        assertEq(pending.record, address(newRecord), "the new row is the one pending");
        assertEq(pending.cap, ROW_CAP, "at its own cap");
        assertEq(rowAt, uint64(_now()) + TIMELOCK, "on a fresh timelock");
        (uint192 cap, uint64 capAt) = vault.pendingCapOf(address(coll));
        assertEq(uint256(cap) + capAt, 0, "and the raise is gone, value and all");
    }

    /// @notice A new row over a pending ROW alone replaces it and revokes nothing: only a pending raise is dropped.
    function test_ANewRowOverAPendingRowAloneEmitsNoRevoke() public {
        vm.prank(curator);
        vault.submitCollateral(address(coll), _row(address(record), ROW_CAP));
        (, uint64 capAt) = vault.pendingCapOf(address(coll));
        assertEq(capAt, 0, "PREMISE: no raise is pending");
        vm.recordLogs();
        vm.prank(curator);
        vault.submitCollateral(address(coll), _row(address(newRecord), ROW_CAP));
        Vm.Log[] memory logs = vm.getRecordedLogs();
        assertEq(_count(logs, CuratorVault.SubmitCollateral.selector), 1, "PREMISE: the submission logged");
        assertEq(_count(logs, CuratorVault.RevokePending.selector), 0, "replacing a pending row is no revoke");
        (Row memory pending,) = vault.pendingRowOf(address(coll));
        assertEq(pending.record, address(newRecord), "the later row replaced the earlier");
    }

    /// @notice A cut with nothing pending drops nothing, so it emits its SetCap and no revoke.
    function test_ACutWithNothingPendingEmitsNoRevoke() public {
        _assertNothingPending("PREMISE: nothing is pending");
        vm.recordLogs();
        vm.prank(guardian);
        vault.submitCap(address(coll), CUT / 2);
        Vm.Log[] memory logs = vm.getRecordedLogs();
        assertEq(_count(logs, CuratorVault.SetCap.selector), 1, "PREMISE: the cut logged");
        assertEq(_count(logs, CuratorVault.RevokePending.selector), 0, "nothing was pending, so nothing is revoked");
        assertEq(vault.rowOf(address(coll)).cap, CUT / 2, "and the cut landed");
    }

    /// @notice A cut that drops a pending ROW, with no raise beside it, says so ahead of the cut.
    function test_ACutDroppingAPendingRowEmitsRevokePendingFirst() public {
        vm.prank(curator);
        vault.submitCollateral(address(coll), _row(address(newRecord), ROW_CAP));
        (, uint64 rowAt) = vault.pendingRowOf(address(coll));
        (, uint64 capAt) = vault.pendingCapOf(address(coll));
        assertGt(rowAt, 0, "PREMISE: the row is pending");
        assertEq(capAt, 0, "PREMISE: and no raise beside it");
        vm.expectEmit(true, true, false, false, address(vault));
        emit CuratorVault.RevokePending(guardian, address(coll));
        vm.expectEmit(true, true, false, true, address(vault));
        emit CuratorVault.SetCap(guardian, address(coll), CUT / 2);
        vm.prank(guardian);
        vault.submitCap(address(coll), CUT / 2);
        _assertNothingPending("the cut dropped the row");
    }

    /// @notice The revoke verb itself says who dropped what, the guardian and the curator alike.
    function test_RevokePendingNamesWhoDroppedIt() public {
        vm.prank(curator);
        vault.submitCap(address(coll), RAISE);
        vm.expectEmit(true, true, false, false, address(vault));
        emit CuratorVault.RevokePending(guardian, address(coll));
        vm.prank(guardian);
        vault.revokePending(address(coll));
        _assertNothingPending("the guardian's revoke dropped the raise");

        vm.prank(curator);
        vault.submitCollateral(address(coll), _row(address(newRecord), ROW_CAP));
        vm.expectEmit(true, true, false, false, address(vault));
        emit CuratorVault.RevokePending(curator, address(coll));
        vm.prank(curator);
        vault.revokePending(address(coll));
        _assertNothingPending("the curator's revoke dropped the row");
    }

    /// @notice A new row is keyed to its own collateral: it leaves another collateral's raise standing.
    function test_ANewRowElsewhereLeavesThisRaiseStanding() public {
        MockStakeVault other = new MockStakeVault(9);
        MockPersistenceRecord otherRecord = _record(address(other), 3e18);
        vm.prank(curator);
        vault.submitCap(address(coll), RAISE);
        vm.prank(curator);
        vault.submitCollateral(address(other), _row(address(otherRecord), ROW_CAP));
        (uint192 cap, uint64 capAt) = vault.pendingCapOf(address(coll));
        assertEq(cap, RAISE, "the raise on this collateral still stands");
        _warpAtLeastTo(capAt);
        vault.accept(address(coll));
        assertEq(vault.rowOf(address(coll)).cap, RAISE, "and lands");
    }
}
