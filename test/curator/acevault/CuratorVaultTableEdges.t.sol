// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.36;

import {Constants} from "../../../src/ace/hub/Constants.sol";
import {AceVault} from "../../../src/vault/AceVault.sol";
import {AceVaultFlows} from "../../../src/vault/libraries/AceVaultFlows.sol";
import {CuratorTerms, Listing, Row} from "../../../src/vault/curated/CuratorTerms.sol";
import {AceVaultCaps} from "../../../src/vault/libraries/AceVaultCaps.sol";
import {CuratedVaults} from "../../utils/CuratedVaults.sol";
import {MockStakeVault} from "../../mocks/MockStakeVault.sol";
import {MockPersistenceRecord} from "../../mocks/MockPersistenceRecord.sol";
import {AceVaultRig} from "./AceVaultRig.sol";

/// @notice The curated table at its edges: the timelock's second, a cap equal to the current one, the row rails, the deploy rails, and the parked pot.
/// @dev Each rail is driven at the last value it admits and the first it refuses, with every other leg held admissible, so one leg answers.
/// @dev Rows and the deploy rails live on CuratorTerms; caps live on the vault.
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
    function _otherRow(uint16 bufferBps, uint16 lenderAprBps, uint64 minTenor, uint64 maxTenor) internal view returns (Row memory) {
        return Row({record: address(otherRecord), bufferBps: bufferBps, lenderAprBps: lenderAprBps, minTenor: minTenor, maxTenor: maxTenor});
    }

    /// @dev Submit `row` for `other` as the curator: refused `BadRow` where `ok` is false, else pending.
    function _submit(Row memory row, bool ok, string memory what) internal {
        CuratorTerms t = _terms(vault);
        vm.prank(curator);
        if (!ok) vm.expectRevert(CuratorTerms.BadRow.selector);
        t.submitCollateral(address(other), row);
        (, uint64 validAt) = t.pendingRowOf(address(other));
        assertEq(validAt != 0, ok, what);
        vm.prank(curator);
        t.revokePending(address(other));
    }

    function _listing(address c, Row memory row) internal pure returns (Listing[] memory l) {
        l = new Listing[](1);
        l[0] = Listing({collateral: c, row: row});
    }

    /// @dev Terms for the rig vault at the given floor ticket and coverage, listing `l`; the deploy's own call, so an expectation binds it.
    function _termsWith(uint256 minPrincipal, uint256 coverage, Listing[] memory l) internal returns (CuratorTerms) {
        return new CuratorTerms(CuratedVaults.termsConfig(address(vault), _cfg(), CuratedVaults.Terms(minPrincipal, coverage, TIMELOCK, 0)), l);
    }

    /// @dev The rig collateral's stored cap on the vault.
    function _cap() internal view returns (uint192 c) {
        (c,) = vlens.capOf(address(vault), address(coll));
    }

    // ---- the timelock's edge ----

    /// @notice A row is not acceptable one second before it is valid, and is at that second.
    function test_ARowIsAcceptableFromItsValidSecondAndNotBefore() public {
        CuratorTerms t = _terms(vault);
        vm.prank(curator);
        t.submitCollateral(address(other), _row(address(otherRecord)));
        (, uint64 validAt) = t.pendingRowOf(address(other));
        _warpTo(validAt - 1);
        vm.expectRevert(CuratorTerms.NothingDue.selector);
        t.accept(address(other));
        _warpTo(validAt);
        vm.prank(stranger);
        t.accept(address(other));
        assertEq(t.rowOf(address(other)).record, address(otherRecord), "accepted at the valid second");
    }

    /// @notice A cap raise likewise: not one second early, and at its valid second.
    function test_ACapRaiseIsAcceptableFromItsValidSecondAndNotBefore() public {
        vm.prank(guardian);
        vault.submitCap(address(coll), 5_000e6);
        vm.prank(curator);
        vault.submitCap(address(coll), 6_000e6);
        (,, uint64 validAt) = vlens.pendingCapOf(address(vault), address(coll));
        _warpTo(validAt - 1);
        vm.expectRevert(AceVaultCaps.NothingDue.selector);
        vault.acceptCap(address(coll));
        assertEq(_cap(), 5_000e6, "still the cut cap");
        _warpTo(validAt);
        vault.acceptCap(address(coll));
        assertEq(_cap(), 6_000e6, "raised at the valid second");
    }

    // ---- what counts as a cut ----

    /// @notice A cap equal to the current one lands at once, as a cut does: the guardian may land it, and nothing waits the timelock.
    function test_AnEqualCapLandsAtOnceAsACut() public {
        vm.prank(guardian);
        vault.submitCap(address(coll), 5_000e6);
        vm.prank(guardian);
        vault.submitCap(address(coll), 5_000e6);
        vm.prank(curator);
        vault.submitCap(address(coll), 5_000e6);
        assertEq(_cap(), 5_000e6, "the equal cap is live at once, by either key");
        (,, uint64 validAt) = vlens.pendingCapOf(address(vault), address(coll));
        assertEq(validAt, 0, "and nothing is behind the timelock");
    }

    // ---- the row rails, each at its edge ----

    /// @notice The buffer: under the whole price is admitted, the whole price is refused.
    function test_RowRail_Buffer() public {
        _submit(_otherRow(9_999, RATE_BPS, MIN_TENOR, MAX_TENOR), true, "a buffer under 100% is admitted");
        _submit(_otherRow(10_000, RATE_BPS, MIN_TENOR, MAX_TENOR), false, "a buffer of 100% is refused");
    }

    /// @notice The rate's floor: one bps is admitted, zero is refused.
    function test_RowRail_RateFloor() public {
        _submit(_otherRow(BUFFER_BPS, uint16(Constants.MIN_LENDER_APR_BPS), MIN_TENOR, MAX_TENOR), true, "the least rate is admitted");
        _submit(_otherRow(BUFFER_BPS, uint16(Constants.MIN_LENDER_APR_BPS - 1), MIN_TENOR, MAX_TENOR), false, "a zero rate is refused");
    }

    /// @notice The fee's fundability at the longest term: 27651 bps a year over a week-to-month span is admitted, 27652 refused.
    function test_RowRail_FeeFundableAtTheLongestTerm() public {
        _submit(_otherRow(BUFFER_BPS, 27_651, 7 days, 30 days), true, "the last fundable rate is admitted");
        _submit(_otherRow(BUFFER_BPS, 27_652, 7 days, 30 days), false, "one bps past it is refused");
    }

    /// @notice The term floor: the vault's rail floor is admitted, one second under it refused; and maxTenor never under minTenor.
    function test_RowRail_TermFloorAndOrder() public {
        uint64 f = vault.MIN_TENOR();
        _submit(_otherRow(BUFFER_BPS, RATE_BPS, f, f), true, "the least term is admitted");
        _submit(_otherRow(BUFFER_BPS, RATE_BPS, f - 1, f), false, "a term under the vault's floor is refused");
        _submit(_otherRow(BUFFER_BPS, RATE_BPS, MAX_TENOR, MAX_TENOR - 1), false, "a ceiling under the floor is refused");
    }

    /// @notice The term ceiling: the vault's rail ceiling is admitted, one second past it refused.
    function test_RowRail_TermCeiling() public {
        uint64 top = vault.MAX_TENOR();
        _submit(_otherRow(BUFFER_BPS, 1, top, top), true, "a term at the vault's ceiling is admitted");
        _submit(_otherRow(BUFFER_BPS, 1, top + 1, top + 1), false, "one second past it is refused");
    }

    /// @notice A row names a real collateral.
    function test_RowRail_ZeroCollateral() public {
        CuratorTerms t = _terms(vault);
        vm.prank(curator);
        vm.expectRevert(CuratorTerms.BadRow.selector);
        t.submitCollateral(address(0), _row(address(otherRecord)));
    }

    // ---- the deploy rails ----

    /// @notice The coverage multiple is admitted at both of genesis's ends, and refused one atom past either.
    function test_DeployRail_CoverageEnds() public {
        Listing[] memory none = new Listing[](0);
        _termsWith(MIN_PRINCIPAL, Constants.MIN_COVERAGE_WAD, none);
        _termsWith(MIN_PRINCIPAL, Constants.MAX_COVERAGE_WAD, none);
        vm.expectRevert(CuratorTerms.BadTerms.selector);
        _termsWith(MIN_PRINCIPAL, Constants.MIN_COVERAGE_WAD - 1, none);
        vm.expectRevert(CuratorTerms.BadTerms.selector);
        _termsWith(MIN_PRINCIPAL, Constants.MAX_COVERAGE_WAD + 1, none);
    }

    /// @notice The minPrincipal fits a uint128, the width the roll record stores a need in.
    function test_DeployRail_MinDebtWidth() public {
        Listing[] memory none = new Listing[](0);
        assertEq(_termsWith(type(uint128).max, COVERAGE, none).MIN_PRINCIPAL(), type(uint128).max, "the widest is admitted");
        vm.expectRevert(CuratorTerms.BadTerms.selector);
        _termsWith(uint256(type(uint128).max) + 1, COVERAGE, none);
    }

    /// @notice A deploy listing is checked as a submitted row is: a bad one refuses the deploy.
    function test_DeployRail_AListedRowMeetsTheRails() public {
        Listing[] memory bad = _listing(address(coll), _row(address(0)));
        vm.expectRevert(CuratorTerms.BadRow.selector);
        _termsWith(MIN_PRINCIPAL, COVERAGE, bad);
        bad = _listing(address(other), _row(address(record)));
        vm.expectRevert(CuratorTerms.BadRow.selector);
        _termsWith(MIN_PRINCIPAL, COVERAGE, bad);
    }

    /// @notice A one-atom minPrincipal, whose fee would round up to all of it, is refused at the terms: its debt floor, half of it, is zero.
    /// @dev The `< 2` terms mirror fires before the row's fee mirror, which `feeFundable` leaves unreachable from two atoms up.
    function test_DeployRail_AFeeThatRoundsToTheWholeFloorIsRefused() public {
        Listing[] memory l = _listing(address(coll), _row(address(record)));
        vm.expectRevert(CuratorTerms.BadTerms.selector);
        _termsWith(1, COVERAGE, l);
        CuratorTerms t = _termsWith(2, COVERAGE, l);
        assertEq(t.rowOf(address(coll)).record, address(record), "two atoms leave the fee under the floor");
    }

    // ---- the cap room's parked leg ----

    /// @notice An unsold pot counts against the cap at the record's minimum: a draw an empty cap admits is refused while the pot sits, and admitted after.
    /// @dev The vault's row room counts only what is lent; the parked leg is the terms' room, which the vault's room never exceeds.
    function test_AnUnsoldPotTakesCapRoomUntilItSells() public {
        vm.prank(guardian);
        vault.submitCap(address(coll), 2_000e6);
        uint256 loanId = _borrow(MIN_TENOR);
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
        vault.borrow(_req(UNITS, PRINCIPAL, MIN_TENOR), "", "");
        vm.stopPrank();
        _warpBy(1 hours);
        usdc.mint(stranger, 10_000e6);
        vm.startPrank(stranger);
        usdc.approve(address(ace), 10_000e6);
        ace.buyInventory(loanId, 10_000e6, 0, stranger);
        vm.stopPrank();
        (, unsold) = ace.lenderByCollateral(address(vault), address(usdc), address(coll));
        assertEq(unsold, 0, "premise: the pot sold whole");
        uint256 id2 = _borrowAs(bob, UNITS, PRINCIPAL, MIN_TENOR);
        assertTrue(ace.isLiveLoan(id2), "the sold pot gave its room back");
    }
}
