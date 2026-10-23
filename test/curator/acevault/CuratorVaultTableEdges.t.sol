// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.36;

import {Constants} from "../../../src/ace/hub/Constants.sol";
import {AceVault} from "../../../src/curator/AceVault.sol";
import {AceVaultFlows} from "../../../src/curator/AceVaultFlows.sol";
import {CuratorVault, Listing, Row} from "../../../src/curator/CuratorVault.sol";
import {MockStakeVault} from "../../mocks/MockStakeVault.sol";
import {MockPersistenceRecord} from "../../mocks/MockPersistenceRecord.sol";
import {AceVaultRig} from "./AceVaultRig.sol";

/// @notice CuratorVault's table at its edges: the timelock's second, a cap equal to the current one, the row rails, the deploy rails, and the parked pot.
/// @dev Each rail is driven at the last value it admits and the first it refuses, with every other leg held admissible, so one leg answers.
contract CuratorVaultTableEdgesTest is AceVaultRig {
    MockStakeVault internal other;
    MockPersistenceRecord internal otherRecord;
    uint256 internal constant Q96 = 1 << 96;

    function setUp() public override {
        super.setUp();
        other = new MockStakeVault(9);
        otherRecord = _record(address(other), 3e18);
    }

    /// @dev The rig's row on `other`, with the given terms.
    function _otherRow(uint16 bufferBps, uint16 baseBps, uint64 minTenor, uint64 maxTenor) internal view returns (Row memory) {
        return Row({record: address(otherRecord), bufferBps: bufferBps, baseBps: baseBps, minTenor: minTenor, maxTenor: maxTenor, cap: 1_000e6});
    }

    /// @dev Submit `row` for `other` as the curator: refused `BadRow` where `ok` is false, else pending.
    function _submit(Row memory row, bool ok, string memory what) internal {
        vm.prank(curator);
        if (!ok) vm.expectRevert(CuratorVault.BadRow.selector);
        vault.submitCollateral(address(other), row);
        (, uint64 validAt) = vault.pendingRowOf(address(other));
        assertEq(validAt != 0, ok, what);
        vm.prank(curator);
        vault.revokePending(address(other));
    }

    function _listing(address c, Row memory row) internal pure returns (Listing[] memory l) {
        l = new Listing[](1);
        l[0] = Listing({collateral: c, row: row});
    }

    // ---- the timelock's edge ----

    /// @notice A row is not acceptable one second before it is valid, and is at that second.
    function test_ARowIsAcceptableFromItsValidSecondAndNotBefore() public {
        vm.prank(curator);
        vault.submitCollateral(address(other), _row(address(otherRecord), type(uint192).max));
        (, uint64 validAt) = vault.pendingRowOf(address(other));
        _warpTo(validAt - 1);
        vm.expectRevert(CuratorVault.NothingDue.selector);
        vault.accept(address(other));
        _warpTo(validAt);
        vm.prank(stranger);
        vault.accept(address(other));
        assertEq(vault.rowOf(address(other)).record, address(otherRecord), "accepted at the valid second");
    }

    /// @notice A cap raise likewise: not one second early, and at its valid second.
    function test_ACapRaiseIsAcceptableFromItsValidSecondAndNotBefore() public {
        vm.prank(guardian);
        vault.submitCap(address(coll), 5_000e6);
        vm.prank(curator);
        vault.submitCap(address(coll), 6_000e6);
        (, uint64 validAt) = vault.pendingCapOf(address(coll));
        _warpTo(validAt - 1);
        vm.expectRevert(CuratorVault.NothingDue.selector);
        vault.accept(address(coll));
        assertEq(vault.rowOf(address(coll)).cap, 5_000e6, "still the cut cap");
        _warpTo(validAt);
        vault.accept(address(coll));
        assertEq(vault.rowOf(address(coll)).cap, 6_000e6, "raised at the valid second");
    }

    // ---- what counts as a cut ----

    /// @notice A cap equal to the current one is not a cut: the guardian may not land it, and the curator's waits the timelock.
    function test_AnEqualCapIsARaiseNotACut() public {
        vm.prank(guardian);
        vault.submitCap(address(coll), 5_000e6);
        vm.prank(curator);
        vault.submitCollateral(address(coll), _row(address(record), 4_000e6));
        vm.prank(guardian);
        vm.expectRevert(AceVault.NotCurator.selector);
        vault.submitCap(address(coll), 5_000e6);
        vm.prank(curator);
        vault.submitCap(address(coll), 5_000e6);
        (uint192 cap, uint64 validAt) = vault.pendingCapOf(address(coll));
        assertEq(cap, 5_000e6, "the equal cap is pending, a raise's shape");
        assertGt(validAt, 0, "behind the timelock");
        (, uint64 rowAt) = vault.pendingRowOf(address(coll));
        assertGt(rowAt, 0, "and, not being a cut, it dropped no pending row");
    }

    /// @notice A cap names a listed collateral: an unlisted one is refused by name, whoever asks and whichever way.
    function test_ACapOnAnUnlistedCollateralIsRefused() public {
        address[2] memory who = [curator, guardian];
        for (uint256 i; i < 2; i++) {
            vm.prank(who[i]);
            vm.expectRevert(CuratorVault.NotListed.selector);
            vault.submitCap(address(other), 0);
            vm.prank(who[i]);
            vm.expectRevert(CuratorVault.NotListed.selector);
            vault.submitCap(address(other), 1_000e6);
        }
    }

    /// @notice A due row and a due raise land in one accept: the row, then the raise over the row's own cap.
    function test_OneAcceptLandsADueRowAndADueRaise() public {
        MockPersistenceRecord next = _record(address(coll), 2e18);
        vm.prank(guardian);
        vault.submitCap(address(coll), 5_000e6);
        vm.startPrank(curator);
        vault.submitCollateral(address(coll), _row(address(next), 7_000e6));
        vault.submitCap(address(coll), 9_000e6);
        vm.stopPrank();
        _warpBy(TIMELOCK);
        vm.expectEmit(true, false, false, true, address(vault));
        emit CuratorVault.SetCollateral(address(coll), _row(address(next), 7_000e6));
        vm.expectEmit(true, true, false, true, address(vault));
        emit CuratorVault.SetCap(stranger, address(coll), 9_000e6);
        vm.prank(stranger);
        vault.accept(address(coll));
        Row memory r = vault.rowOf(address(coll));
        assertEq(r.record, address(next), "the row landed");
        assertEq(r.cap, 9_000e6, "and the raise over its cap");
        (, uint64 rowAt) = vault.pendingRowOf(address(coll));
        (, uint64 capAt) = vault.pendingCapOf(address(coll));
        assertEq(rowAt + capAt, 0, "both pendings are spent");
    }

    // ---- the row rails, each at its edge ----

    /// @notice The buffer: under the whole price is admitted, the whole price is refused.
    function test_RowRail_Buffer() public {
        _submit(_otherRow(9_999, RATE_BPS, MIN_TENOR, MAX_TENOR), true, "a buffer under 100% is admitted");
        _submit(_otherRow(10_000, RATE_BPS, MIN_TENOR, MAX_TENOR), false, "a buffer of 100% is refused");
    }

    /// @notice The rate's floor: one bps is admitted, zero is refused.
    function test_RowRail_RateFloor() public {
        _submit(_otherRow(BUFFER_BPS, uint16(Constants.MIN_BASE_BPS), MIN_TENOR, MAX_TENOR), true, "the least rate is admitted");
        _submit(_otherRow(BUFFER_BPS, uint16(Constants.MIN_BASE_BPS - 1), MIN_TENOR, MAX_TENOR), false, "a zero rate is refused");
    }

    /// @notice The fee's fundability at the longest term: 530 bps over a week-to-month span is admitted, 531 refused.
    function test_RowRail_FeeFundableAtTheLongestTerm() public {
        _submit(_otherRow(BUFFER_BPS, 530, 7 days, 30 days), true, "the last fundable rate is admitted");
        _submit(_otherRow(BUFFER_BPS, 531, 7 days, 30 days), false, "one bps past it is refused");
    }

    /// @notice The term floor: the hub's least minTenor is admitted, one second under it refused; and maxTenor never under minTenor.
    function test_RowRail_TermFloorAndOrder() public {
        uint64 f = Constants.MIN_TENOR_FLOOR;
        _submit(_otherRow(BUFFER_BPS, RATE_BPS, f, f), true, "the least term is admitted");
        _submit(_otherRow(BUFFER_BPS, RATE_BPS, f - 1, f), false, "a term under the hub's floor is refused");
        _submit(_otherRow(BUFFER_BPS, RATE_BPS, MAX_TENOR, MAX_TENOR - 1), false, "a ceiling under the floor is refused");
    }

    /// @notice The term ceiling: the widest the hub stores is admitted, one second past it refused.
    function test_RowRail_TermCeiling() public {
        uint64 top = uint64(type(uint40).max);
        _submit(_otherRow(BUFFER_BPS, 1, top, top), true, "a term at the hub's width is admitted");
        _submit(_otherRow(BUFFER_BPS, 1, top + 1, top + 1), false, "one second past it is refused");
    }

    /// @notice A row names a real collateral.
    function test_RowRail_ZeroCollateral() public {
        vm.prank(curator);
        vm.expectRevert(CuratorVault.BadRow.selector);
        vault.submitCollateral(address(0), _row(address(otherRecord), type(uint192).max));
    }

    // ---- the deploy rails ----

    /// @notice The coverage multiple is admitted at both of genesis's ends, and refused one atom past either.
    function test_DeployRail_CoverageEnds() public {
        Listing[] memory none = new Listing[](0);
        new CuratorVault(_cfg(), MIN_DEBT, Constants.MIN_COVERAGE_WAD, TIMELOCK, none, "C", "C");
        new CuratorVault(_cfg(), MIN_DEBT, Constants.MAX_COVERAGE_WAD, TIMELOCK, none, "C", "C");
        vm.expectRevert(CuratorVault.BadTerms.selector);
        new CuratorVault(_cfg(), MIN_DEBT, Constants.MIN_COVERAGE_WAD - 1, TIMELOCK, none, "C", "C");
        vm.expectRevert(CuratorVault.BadTerms.selector);
        new CuratorVault(_cfg(), MIN_DEBT, Constants.MAX_COVERAGE_WAD + 1, TIMELOCK, none, "C", "C");
    }

    /// @notice The minDebt fits a uint128, the width the roll record stores a need in.
    function test_DeployRail_MinDebtWidth() public {
        Listing[] memory none = new Listing[](0);
        assertEq(new CuratorVault(_cfg(), type(uint128).max, COVERAGE, TIMELOCK, none, "C", "C").MIN_DEBT(), type(uint128).max, "the widest is admitted");
        vm.expectRevert(CuratorVault.BadTerms.selector);
        new CuratorVault(_cfg(), uint256(type(uint128).max) + 1, COVERAGE, TIMELOCK, none, "C", "C");
    }

    /// @notice A deploy listing is checked as a submitted row is: a bad one refuses the deploy.
    function test_DeployRail_AListedRowMeetsTheRails() public {
        vm.expectRevert(CuratorVault.BadRow.selector);
        new CuratorVault(_cfg(), MIN_DEBT, COVERAGE, TIMELOCK, _listing(address(coll), _row(address(0), 1)), "C", "C");
        vm.expectRevert(CuratorVault.BadRow.selector);
        new CuratorVault(_cfg(), MIN_DEBT, COVERAGE, TIMELOCK, _listing(address(other), _row(address(record), 1)), "C", "C");
    }

    /// @notice A minDebt so small the fee rounds up to all of it is refused with its row: a one-atom floor never lends.
    function test_DeployRail_AFeeThatRoundsToTheWholeFloorIsRefused() public {
        Row memory row = _row(address(record), type(uint192).max);
        vm.expectRevert(CuratorVault.BadRow.selector);
        new CuratorVault(_cfg(), 1, COVERAGE, TIMELOCK, _listing(address(coll), row), "C", "C");
        CuratorVault v = new CuratorVault(_cfg(), 2, COVERAGE, TIMELOCK, _listing(address(coll), row), "C", "C");
        assertEq(v.rowOf(address(coll)).record, address(record), "two atoms leave the fee under the floor");
    }

    // ---- the cap room's parked leg ----

    /// @notice An unsold pot counts against the cap at the record's minimum: a draw an empty cap admits is refused while the pot sits, and admitted after.
    function test_AnUnsoldPotTakesCapRoomUntilItSells() public {
        vm.prank(guardian);
        vault.submitCap(address(coll), 2_000e6);
        uint256 loanId = _borrow(MIN_TENOR, false);
        _warpAtLeastTo(_expiry(loanId));
        vm.prank(stranger);
        ace.forceClose(loanId);
        (uint256 lent, uint256 unsold) = ace.lenderByCollateral(address(vault), address(usdc), address(coll));
        assertEq(lent, 0, "premise: nothing is lent against the collateral");
        uint256 parked = unsold * record.minPrice(address(usdc), address(coll)) / Q96;
        assertGt(parked + PRINCIPAL, 2_000e6, "premise: the pot at the minimum leaves no room for the draw");
        assertLt(PRINCIPAL, 2_000e6, "premise: an empty cap would admit it");
        coll.mint(bob, UNITS);
        vm.startPrank(bob);
        coll.approve(address(vault), UNITS);
        vm.expectRevert(AceVaultFlows.OverCap.selector);
        vault.borrow(_req(UNITS, PRINCIPAL, MIN_TENOR, false), "", "");
        vm.stopPrank();
        _warpBy(1 hours);
        usdc.mint(stranger, 10_000e6);
        vm.startPrank(stranger);
        usdc.approve(address(ace), 10_000e6);
        ace.buyInventory(loanId, 10_000e6, 0, stranger);
        vm.stopPrank();
        (, unsold) = ace.lenderByCollateral(address(vault), address(usdc), address(coll));
        assertEq(unsold, 0, "premise: the pot sold whole");
        uint256 id2 = _borrowAs(bob, UNITS, PRINCIPAL, MIN_TENOR, false);
        assertTrue(ace.isLiveLoan(id2), "the sold pot gave its room back");
    }
}
