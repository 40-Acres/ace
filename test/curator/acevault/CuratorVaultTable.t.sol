// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.36;

import {MarketParams} from "../../../src/ace/hub/Types.sol";
import {AceVault} from "../../../src/curator/AceVault.sol";
import {AceVaultFlows} from "../../../src/curator/AceVaultFlows.sol";
import {CuratorVault, Listing, Row} from "../../../src/curator/CuratorVault.sol";
import {MockStakeVault} from "../../mocks/MockStakeVault.sol";
import {MockPersistenceRecord} from "../../mocks/MockPersistenceRecord.sol";
import {AceVaultRig} from "./AceVaultRig.sol";

/// @notice CuratorVault's collateral table: rows and cap raises wait a timelock, a cap cut lands at once, and the door prices off the row.
/// @dev The pending shape is MetaMorpho's `{value, validAt}`: submit, accept after the delay by anyone, revoke by the curator or the guardian.
contract CuratorVaultTableTest is AceVaultRig {
    bytes32 internal constant ROOT = 0xb7a4de03362d20465bcc8b45bb9625cb4abe76f109b674085f908e1bc61c7000; // erc7201:ace.curatorvault
    MockStakeVault internal other;
    MockPersistenceRecord internal otherRecord;

    function setUp() public override {
        super.setUp();
        other = new MockStakeVault(9);
        otherRecord = _record(address(other), 3e18);
    }

    /// @notice The timelock is railed to one to fourteen days at construction.
    function test_TheTimelockIsRailed() public {
        Listing[] memory none = new Listing[](0);
        vm.expectRevert(CuratorVault.TimelockOutOfBounds.selector);
        new CuratorVault(_cfg(), MIN_DEBT, COVERAGE, 1 days - 1, none, "C", "C");
        vm.expectRevert(CuratorVault.TimelockOutOfBounds.selector);
        new CuratorVault(_cfg(), MIN_DEBT, COVERAGE, 14 days + 1, none, "C", "C");
        assertEq(new CuratorVault(_cfg(), MIN_DEBT, COVERAGE, 14 days, none, "C", "C").TIMELOCK(), 14 days, "the ceiling itself is admitted");
    }

    /// @notice minDebt and coverage are checked against the hub's genesis rails at construction.
    function test_TheImmutablesMeetTheGenesisRails() public {
        Listing[] memory none = new Listing[](0);
        vm.expectRevert(CuratorVault.BadTerms.selector);
        new CuratorVault(_cfg(), 0, COVERAGE, TIMELOCK, none, "C", "C");
        vm.expectRevert(CuratorVault.BadTerms.selector);
        new CuratorVault(_cfg(), MIN_DEBT, 1e18, TIMELOCK, none, "C", "C");
        vm.expectRevert(CuratorVault.BadTerms.selector);
        new CuratorVault(_cfg(), MIN_DEBT, 21e18, TIMELOCK, none, "C", "C");
    }

    /// @notice A new collateral waits the timelock; anyone accepts it once it has run.
    function test_ANewCollateralWaitsTheTimelock() public {
        vm.prank(curator);
        vault.submitCollateral(address(other), _row(address(otherRecord), type(uint192).max));
        (, uint64 validAt) = vault.pendingRowOf(address(other));
        assertEq(validAt, uint64(_now()) + TIMELOCK, "pending until the delay runs");
        vm.expectRevert(CuratorVault.NothingDue.selector);
        vault.accept(address(other));
        _warpBy(TIMELOCK);
        vm.prank(stranger);
        vault.accept(address(other));
        assertEq(vault.rowOf(address(other)).record, address(otherRecord), "the row is live");
        (, validAt) = vault.pendingRowOf(address(other));
        assertEq(validAt, 0, "and no longer pending");
    }

    /// @notice Only the curator submits a row.
    function test_OnlyTheCuratorSubmitsARow() public {
        vm.prank(guardian);
        vm.expectRevert(AceVault.NotCurator.selector);
        vault.submitCollateral(address(other), _row(address(otherRecord), type(uint192).max));
    }

    /// @notice A row naming no record is refused: the door prices off it.
    function test_ARowNamesARecord() public {
        vm.prank(curator);
        vm.expectRevert(CuratorVault.BadRow.selector);
        vault.submitCollateral(address(other), _row(address(0), type(uint192).max));
    }

    /// @notice A row whose record does not affirm the vault's asset against the collateral is refused.
    function test_ARowsRecordAffirmsThePair() public {
        vm.prank(curator);
        vm.expectRevert(CuratorVault.BadRow.selector);
        vault.submitCollateral(address(other), _row(address(record), type(uint192).max));
    }

    /// @notice Every table verb leaves gross NAV, the pile, NAV and the mark untouched.
    function test_TableVerbsMoveNoValue() public {
        _borrow(MIN_TENOR, false);
        usdc.mint(address(vault), 1_000e6);
        vault.crank();
        uint256 gross = vault.grossNav();
        uint256 pile = vault.unvested();
        uint256 nav = vault.totalAssets();
        bytes32 mark = vm.load(address(vault), bytes32(uint256(ROOT) + 1));
        vm.startPrank(curator);
        vault.submitCollateral(address(other), _row(address(otherRecord), type(uint192).max));
        vault.submitCap(address(coll), 2_000e6);
        vault.submitCap(address(coll), 3_000e6);
        vm.stopPrank();
        vm.prank(guardian);
        vault.submitCap(address(coll), 0);
        vm.prank(guardian);
        vault.revokePending(address(other));
        vm.prank(curator);
        vault.submitCollateral(address(other), _row(address(otherRecord), type(uint192).max));
        _warpBy(TIMELOCK);
        pile = vault.unvested();
        nav = vault.totalAssets();
        vault.accept(address(other));
        assertEq(vault.grossNav(), gross, "gross NAV is untouched");
        assertEq(vault.unvested(), pile, "the pile is untouched");
        assertEq(vault.totalAssets(), nav, "NAV is untouched");
        assertEq(vm.load(address(vault), bytes32(uint256(ROOT) + 1)), mark, "the mark is untouched");
    }

    /// @notice A cap cut lands at once, by the guardian as well as the curator.
    function test_ACapCutLandsAtOnce() public {
        vm.prank(guardian);
        vault.submitCap(address(coll), 5_000e6);
        assertEq(vault.rowOf(address(coll)).cap, 5_000e6, "cut at once");
        vm.prank(curator);
        vault.submitCap(address(coll), 0);
        assertEq(vault.rowOf(address(coll)).cap, 0, "a cap of zero is removal, at once");
    }

    /// @notice A cap raise waits the timelock, and the guardian may not raise.
    function test_ACapRaiseWaitsTheTimelock() public {
        vm.prank(curator);
        vault.submitCap(address(coll), 5_000e6);
        vm.prank(guardian);
        vm.expectRevert(AceVault.NotCurator.selector);
        vault.submitCap(address(coll), 6_000e6);
        vm.prank(curator);
        vault.submitCap(address(coll), 6_000e6);
        assertEq(vault.rowOf(address(coll)).cap, 5_000e6, "the raise is pending");
        _warpBy(TIMELOCK);
        vault.accept(address(coll));
        assertEq(vault.rowOf(address(coll)).cap, 6_000e6, "accepted after the delay");
    }

    /// @notice A cut drops a raise submitted before it: once the timelock runs there is nothing to accept, and the cap stays cut.
    function test_ACutDropsAPendingRaise() public {
        vm.prank(curator);
        vault.submitCap(address(coll), 5_000e6);
        vm.prank(curator);
        vault.submitCap(address(coll), 6_000e6);
        (, uint64 validAt) = vault.pendingCapOf(address(coll));
        assertGt(validAt, 0, "premise: the raise is pending");
        vm.prank(guardian);
        vault.submitCap(address(coll), 1_000e6);
        (, validAt) = vault.pendingCapOf(address(coll));
        assertEq(validAt, 0, "the cut dropped the pending raise");
        _warpBy(TIMELOCK);
        vm.expectRevert(CuratorVault.NothingDue.selector);
        vault.accept(address(coll));
        assertEq(vault.rowOf(address(coll)).cap, 1_000e6, "and the cap stays cut");
    }

    /// @notice A cut drops a row submitted before it, so the row's own cap cannot lift the cut back after the timelock.
    function test_ACutDropsAPendingRow() public {
        vm.prank(curator);
        vault.submitCollateral(address(coll), _row(address(record), type(uint192).max));
        (, uint64 validAt) = vault.pendingRowOf(address(coll));
        assertGt(validAt, 0, "premise: the row is pending");
        vm.prank(guardian);
        vault.submitCap(address(coll), 1_000e6);
        (, validAt) = vault.pendingRowOf(address(coll));
        assertEq(validAt, 0, "the cut dropped the pending row");
        _warpBy(TIMELOCK);
        vm.expectRevert(CuratorVault.NothingDue.selector);
        vault.accept(address(coll));
        assertEq(vault.rowOf(address(coll)).cap, 1_000e6, "and the cap stays cut");
    }

    /// @notice The guardian revokes a pending row or raise.
    function test_TheGuardianRevokesPending() public {
        vm.prank(curator);
        vault.submitCollateral(address(other), _row(address(otherRecord), type(uint192).max));
        vm.prank(guardian);
        vault.revokePending(address(other));
        _warpBy(TIMELOCK);
        vm.expectRevert(CuratorVault.NothingDue.selector);
        vault.accept(address(other));
        vm.prank(stranger);
        vm.expectRevert(AceVault.NotCurator.selector);
        vault.revokePending(address(coll));
    }

    /// @notice The door's price is the buffered windowed minimum rounded down onto a 50-tick grid.
    function test_ThePriceIsTheGriddedBufferedMinimum() public {
        MarketParams memory mp = _mp(_borrow(MIN_TENOR, false));
        uint256 buffered = record.minPrice(address(usdc), address(coll)) * (10_000 - BUFFER_BPS) / 10_000;
        assertLe(mp.price, buffered, "never above the buffered minimum");
        assertGt(mp.price * 10_051, buffered * 10_000, "within one 50-tick step under it");
        assertEq(mp.record, address(record), "the row's record");
    }

    /// @notice Two borrows at nearby record prints share a market: the grid absorbs a move inside one step.
    function test_NearbyPricesShareAMarket() public {
        uint256 a = _borrow(MIN_TENOR, false);
        uint256 m = record.minPrice(address(usdc), address(coll));
        record.setMinPrice(m + m / 100_000);
        uint256 b = _borrowAs(bob, UNITS, PRINCIPAL, MIN_TENOR, false);
        assertEq(_mid(a), _mid(b), "one market across a sub-step move");
    }

    /// @notice The cap is a brake on exposure: lent plus unsold units at the minimum price; a draw past the room is refused.
    function test_TheCapRoomBrakesExposure() public {
        vm.prank(curator);
        vault.submitCap(address(coll), uint192(PRINCIPAL + PRINCIPAL / 2));
        _borrow(MIN_TENOR, false);
        coll.mint(bob, UNITS);
        vm.startPrank(bob);
        coll.approve(address(vault), UNITS);
        vm.expectRevert(AceVaultFlows.OverCap.selector);
        vault.borrow(_req(UNITS, PRINCIPAL, MIN_TENOR, false), "", "");
        vm.stopPrank();
        _borrowAs(bob, UNITS, PRINCIPAL / 2, MIN_TENOR, false);
    }

    /// @notice A collateral with no row is not listed; a removed one (cap zero) refuses every placement.
    function test_ARemovedCollateralRefusesPlacement() public {
        vm.prank(guardian);
        vault.submitCap(address(coll), 0);
        coll.mint(bob, UNITS);
        vm.startPrank(bob);
        coll.approve(address(vault), UNITS);
        vm.expectRevert(AceVaultFlows.OverCap.selector);
        vault.borrow(_req(UNITS, PRINCIPAL, MIN_TENOR, false), "", "");
        vm.stopPrank();
    }

    /// @notice The rows a deploy lists are live from the first block, with no timelock.
    function test_TheDeployListingIsLiveAtOnce() public view {
        Row memory r = vault.rowOf(address(coll));
        assertEq(r.record, address(record), "listed at deploy");
        assertEq(r.bufferBps, BUFFER_BPS, "with its buffer");
        assertEq(uint256(r.cap), type(uint192).max, "and its cap");
    }
}
