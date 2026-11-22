// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.36;

import {Vm} from "forge-std/Vm.sol";
import {AceVaultCaps} from "../../../src/curator/libraries/AceVaultCaps.sol";
import {CuratorTerms, Row} from "../../../src/entities/curated/CuratorTerms.sol";
import {MockPersistenceRecord} from "../../mocks/MockPersistenceRecord.sol";
import {AceVaultRig} from "./AceVaultRig.sol";

/// @notice Every dropped pending change says who dropped it, and nothing else does: on the vault's caps and on the terms' rows alike.
/// @dev A cut drops the change pending on its key and logs the revoke ahead of itself, so an indexer replaying events ends where storage does.
contract CuratorVaultPendingCapRowTest is AceVaultRig {
    MockPersistenceRecord internal newRecord;

    uint192 internal constant CUT = 1_000e6;
    uint192 internal constant RAISE = 9_000e6;

    function setUp() public override {
        super.setUp();
        newRecord = _record(address(coll), 1.5e18);
        vm.prank(guardian);
        vault.submitCap(address(coll), CUT); // a cut lands at once, so a later raise has room above it
    }

    /// @notice A cut that drops a pending raise says so, ahead of the cut itself.
    function test_ACutDroppingARaiseEmitsRevokePendingFirst() public {
        vm.prank(curator);
        vault.submitCap(address(coll), RAISE);
        vm.expectEmit(true, true, false, false, address(vault));
        emit AceVaultCaps.RevokePendingCap(guardian, address(coll));
        vm.expectEmit(true, true, false, true, address(vault));
        emit AceVaultCaps.SetCap(guardian, address(coll), CUT / 2, true);
        vm.prank(guardian);
        vault.submitCap(address(coll), CUT / 2);
    }

    // ---- the event log ends where storage does ----

    /// @dev How many logs `emitter` emitted under `topic0`.
    function _count(Vm.Log[] memory logs, address emitter, bytes32 topic0) internal pure returns (uint256 n) {
        for (uint256 i; i < logs.length; ++i) {
            if (logs[i].emitter == emitter && logs[i].topics[0] == topic0) ++n;
        }
    }

    /// @dev Both pending slots for `coll` read empty: the terms' row and the vault's cap.
    function _assertNothingPending(string memory what) internal view {
        (, uint64 rowAt) = _terms(vault).pendingRowOf(address(coll));
        (uint192 cap,, uint64 capAt) = vlens.pendingCapOf(address(vault), address(coll));
        assertEq(uint256(rowAt) + capAt + cap, 0, what);
    }

    /// @notice A new row over a pending ROW alone replaces it and revokes nothing, on the terms or on the vault.
    function test_ANewRowOverAPendingRowAloneEmitsNoRevoke() public {
        CuratorTerms t = _terms(vault);
        vm.prank(curator);
        t.submitCollateral(address(coll), _row(address(record)));
        (,, uint64 capAt) = vlens.pendingCapOf(address(vault), address(coll));
        assertEq(capAt, 0, "PREMISE: no raise is pending");
        vm.recordLogs();
        vm.prank(curator);
        t.submitCollateral(address(coll), _row(address(newRecord)));
        Vm.Log[] memory logs = vm.getRecordedLogs();
        assertEq(_count(logs, address(t), CuratorTerms.SubmitCollateral.selector), 1, "PREMISE: the submission logged");
        uint256 revokes = _count(logs, address(t), CuratorTerms.RevokePending.selector) + _count(logs, address(vault), AceVaultCaps.RevokePendingCap.selector);
        assertEq(revokes, 0, "replacing a pending row is no revoke");
        (Row memory pending,) = t.pendingRowOf(address(coll));
        assertEq(pending.record, address(newRecord), "the later row replaced the earlier");
    }

    /// @notice A cut with nothing pending drops nothing, so it emits its SetCap and no revoke.
    function test_ACutWithNothingPendingEmitsNoRevoke() public {
        _assertNothingPending("PREMISE: nothing is pending");
        vm.recordLogs();
        vm.prank(guardian);
        vault.submitCap(address(coll), CUT / 2);
        Vm.Log[] memory logs = vm.getRecordedLogs();
        assertEq(_count(logs, address(vault), AceVaultCaps.SetCap.selector), 1, "PREMISE: the cut logged");
        assertEq(_count(logs, address(vault), AceVaultCaps.RevokePendingCap.selector), 0, "nothing was pending, so nothing is revoked");
        (uint192 cap,) = vlens.capOf(address(vault), address(coll));
        assertEq(cap, CUT / 2, "and the cut landed");
    }

    /// @notice The revoke verbs themselves say who dropped what, the guardian and the curator alike: the vault's for a cap, the terms' for a row.
    function test_RevokePendingNamesWhoDroppedIt() public {
        vm.prank(curator);
        vault.submitCap(address(coll), RAISE);
        vm.expectEmit(true, true, false, false, address(vault));
        emit AceVaultCaps.RevokePendingCap(guardian, address(coll));
        vm.prank(guardian);
        vault.revokePendingCap(address(coll));
        _assertNothingPending("the guardian's revoke dropped the raise");

        CuratorTerms t = _terms(vault);
        vm.prank(curator);
        t.submitCollateral(address(coll), _row(address(newRecord)));
        vm.expectEmit(true, true, false, false, address(t));
        emit CuratorTerms.RevokePending(curator, address(coll));
        vm.prank(curator);
        t.revokePending(address(coll));
        _assertNothingPending("the curator's revoke dropped the row");
    }
}
