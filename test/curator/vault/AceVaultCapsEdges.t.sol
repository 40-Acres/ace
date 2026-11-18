// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.36;

import {AceVault} from "../../../src/curator/AceVault.sol";
import {Vm} from "forge-std/Vm.sol";
import {AceVaultCaps, CapListing, ProductConfig} from "../../../src/curator/AceVaultCaps.sol";
import {MockStakeVault} from "../../mocks/MockStakeVault.sol";
import {AceVaultBaseRig} from "./AceVaultBaseRig.sol";
import {VaultSeed} from "../../utils/VaultSeed.sol";
import {MockTerms} from "./MockTerms.sol";

/// @title AceVaultCapsEdgesTest
/// @notice F4 hardening: the timelock's two edges, an equal cap on every kind of key, who may queue, cut, delist and revoke, and the events.
/// @notice An UNLISTED TOTAL is zero, never the wildcard: a vault that names no total lends nothing, and listing one is a raise that waits.
contract AceVaultCapsEdgesTest is AceVaultBaseRig {
    uint192 internal constant WILD = 1_000e6;
    address internal c;

    event SubmitCap(address indexed key, uint256 cap, bool listed, uint64 validAt);
    event SetCap(address indexed by, address indexed key, uint256 cap, bool listed);
    event RevokePendingCap(address indexed by, address indexed key);

    function setUp() public override {
        super.setUp();
        (vault, terms) = _deploy(_cfg(), _pc(), _caps(UNCAPPED, WILD, UNCAPPED));
        _setTerms(address(coll), record);
        _lp(alice, LP_CASH);
        c = address(new MockStakeVault(42));
    }

    function _cap(address key) internal view returns (uint192 cap, bool listed) {
        return vlens.capOf(address(vault), key);
    }

    function _validAt(address key) internal view returns (uint64 validAt) {
        (,, validAt) = vlens.pendingCapOf(address(vault), key);
    }

    /// @dev A vault whose deploy lists exactly `l`, its terms first at the address the vault's create takes.
    function _deployListing(CapListing[] memory l) internal returns (AceVault v) {
        address predicted = vm.computeCreateAddress(address(this), vm.getNonce(address(this)) + 1);
        MockTerms t = new MockTerms(predicted, address(ace));
        ProductConfig memory pc = _pc();
        pc.terms = address(t);
        VaultSeed.fund(_cfg(), predicted);
        v = new AceVault(_cfg(), pc, l, "Edge", "eVLT");
        assertEq(address(v), predicted, "rig: the vault landed off its predicted address");
        (vault, terms) = (v, t);
        _setTerms(address(coll), record);
    }

    // ---- the timelock's two edges ----

    /// @notice A raise is refused one second before `validAt` and lands at it, by anyone.
    function test_AcceptCapRefusesOneSecondEarlyAndLandsAtValidAt() public {
        vm.prank(curator);
        vault.submitCap(address(0), 2 * WILD);
        uint64 validAt = _validAt(address(0));
        assertEq(validAt, _now() + CAP_LOCK, "premise: the raise waits the timelock");
        _warpTo(validAt - 1);
        vm.prank(stranger);
        vm.expectRevert(AceVaultCaps.NothingDue.selector);
        vault.acceptCap(address(0));
        _warpTo(validAt);
        vm.prank(stranger);
        vault.acceptCap(address(0));
        assertEq(vault.effectiveCap(c), 2 * WILD, "the raise did not land at its validAt");
        assertEq(_validAt(address(0)), 0, "the accepted raise is still pending");
        vm.expectRevert(AceVaultCaps.NothingDue.selector);
        vault.acceptCap(address(0));
    }

    /// @notice A raise resubmitted mid-wait restarts its timelock: the first `validAt` admits nothing, and only the second value lands.
    function test_AResubmittedRaiseRestartsItsTimelock() public {
        vm.prank(curator);
        vault.submitCap(address(0), 2 * WILD);
        uint64 first = _validAt(address(0));
        _warpBy(2 days);
        vm.prank(curator);
        vault.submitCap(address(0), 3 * WILD);
        uint64 second = _validAt(address(0));
        assertEq(second, _now() + CAP_LOCK, "the resubmission did not restart the timelock");
        _warpTo(first);
        vm.expectRevert(AceVaultCaps.NothingDue.selector);
        vault.acceptCap(address(0));
        _warpTo(second);
        vault.acceptCap(address(0));
        assertEq(vault.effectiveCap(c), 3 * WILD, "the resubmitted value did not land");
    }

    // ---- an equal cap is no raise, on every kind of key ----

    /// @notice An equal cap lands at once on a listed row, the wildcard and the total, by the guardian too, and leaves nothing pending.
    function test_AnEqualCapLandsAtOnceOnEveryKindOfKey() public {
        vm.prank(curator);
        vault.submitCap(c, 400e6);
        vm.startPrank(guardian);
        vault.submitCap(c, 400e6);
        vault.submitCap(address(0), WILD);
        vault.submitCap(address(vault), UNCAPPED);
        vm.stopPrank();
        (uint192 row, bool listed) = _cap(c);
        assertTrue(listed && row == 400e6, "an equal row did not stand");
        assertEq(vault.effectiveCap(address(0)), WILD, "an equal wildcard moved");
        assertEq(vault.effectiveCap(address(vault)), UNCAPPED, "an equal total moved");
        assertEq(_validAt(c) + _validAt(address(0)) + _validAt(address(vault)), 0, "an equal cap was queued");
    }

    /// @notice One unit over the effective cap is a raise on every kind of key: it waits, and the guardian may not queue it.
    function test_OneUnitOverIsARaiseOnEveryKindOfKey() public {
        vm.prank(curator);
        vault.submitCap(c, 400e6);
        vm.startPrank(guardian);
        vm.expectRevert(AceVaultCaps.NotCurator.selector);
        vault.submitCap(c, 400e6 + 1);
        vm.expectRevert(AceVaultCaps.NotCurator.selector);
        vault.submitCap(address(0), WILD + 1);
        vm.stopPrank();
        vm.startPrank(curator);
        vault.submitCap(c, 400e6 + 1);
        vault.submitCap(address(0), WILD + 1);
        vm.stopPrank();
        assertEq(vault.effectiveCap(c), 400e6, "a one-unit raise of a row landed at once");
        assertEq(vault.effectiveCap(address(0)), WILD, "a one-unit raise of the wildcard landed at once");
        assertGt(_validAt(c) * _validAt(address(0)), 0, "a one-unit raise was not queued");
    }

    // ---- cuts drop what was pending, on a row too ----

    /// @notice A cut on a collateral's row drops its pending raise, so the raise can never land over the cut.
    function test_ACutOnARowDropsItsPendingRaise() public {
        vm.startPrank(curator);
        vault.submitCap(c, 100e6);
        vault.submitCap(c, 900e6);
        vm.stopPrank();
        assertGt(_validAt(c), 0, "premise: the row's raise waits");
        vm.prank(guardian);
        vault.submitCap(c, 50e6);
        assertEq(_validAt(c), 0, "the cut left the row's raise pending");
        assertEq(vault.effectiveCap(c), 50e6, "the cut did not land");
        _warpBy(CAP_LOCK);
        vm.expectRevert(AceVaultCaps.NothingDue.selector);
        vault.acceptCap(c);
    }

    /// @notice The curator may revoke its own pending raise as well as the guardian, and a stranger may not.
    function test_TheCuratorRevokesAPendingRaise() public {
        vm.prank(curator);
        vault.submitCap(c, 2 * WILD);
        vm.prank(stranger);
        vm.expectRevert(AceVaultCaps.NotCurator.selector);
        vault.revokePendingCap(c);
        vm.expectEmit(true, true, false, false, address(vault));
        emit RevokePendingCap(curator, c);
        vm.prank(curator);
        vault.revokePendingCap(c);
        assertEq(_validAt(c), 0, "the curator's revoke left the raise pending");
        _warpBy(CAP_LOCK);
        vm.expectRevert(AceVaultCaps.NothingDue.selector);
        vault.acceptCap(c);
        assertEq(vault.effectiveCap(c), WILD, "a revoked raise moved the cap");
    }

    // ---- the delist's permissions ----

    /// @notice A delist that would land is refused to a stranger; one that waits is refused to the guardian; an unlisted key has nothing to delist.
    function test_TheDelistsPermissions() public {
        vm.prank(curator);
        vault.submitCap(c, WILD);
        vm.prank(stranger);
        vm.expectRevert(AceVaultCaps.NotCurator.selector);
        vault.submitDelist(c);
        address d = address(new MockStakeVault(42));
        vm.prank(curator);
        vault.submitCap(d, WILD / 2);
        vm.prank(guardian);
        vm.expectRevert(AceVaultCaps.NotCurator.selector);
        vault.submitDelist(d);
        address e = address(new MockStakeVault(42));
        vm.prank(curator);
        vm.expectRevert(AceVaultCaps.NotListed.selector);
        vault.submitDelist(e);
    }

    /// @notice Under a zero wildcard a delist is a cut to zero: it lands at once, by the guardian, and refuses the next borrow.
    function test_UnderAZeroWildcardADelistIsACut() public {
        vm.prank(guardian);
        vault.submitCap(address(0), 0);
        vm.prank(guardian);
        vault.submitDelist(address(coll));
        (, bool listed) = _cap(address(coll));
        assertFalse(listed, "a delist under a zero wildcard did not land at once");
        assertEq(vault.effectiveCap(address(coll)), 0, "the delisted row does not read the zero wildcard");
        assertEq(vlens.roomOf(address(vault), address(coll)), 0, "the delisted row kept room");
    }

    /// @notice An unlisted collateral follows the wildcard as it moves; a listed one keeps its own row.
    function test_AnUnlistedCollateralFollowsTheWildcard() public {
        address d = address(new MockStakeVault(42));
        vm.prank(curator);
        vault.submitCap(d, 300e6);
        vm.prank(guardian);
        vault.submitCap(address(0), 200e6);
        assertEq(vault.effectiveCap(c), 200e6, "an unlisted collateral did not follow the wildcard's cut");
        assertEq(vault.effectiveCap(d), 300e6, "a listed row followed the wildcard");
    }

    // ---- an unlisted total is zero, never the wildcard ----

    /// @notice A VAULT THAT NAMES NO TOTAL lends nothing, under any wildcard; listing a total is a raise from zero, curator only, after the timelock.
    /// @dev A total that fell back to the wildcard would land a total up to the wildcard at once, by the guardian: that mutant dies here.
    function test_AnUnlistedTotalIsZeroNeverTheWildcard() public {
        CapListing[] memory l = new CapListing[](2);
        l[0] = CapListing(address(coll), UNCAPPED);
        l[1] = CapListing(address(0), WILD);
        vault = _deployListing(l);
        _lp(alice, LP_CASH);
        assertEq(vault.effectiveCap(address(vault)), 0, "an unlisted total read the wildcard");
        assertEq(vlens.roomOf(address(vault), address(coll)), 0, "a vault naming no total has room");
        _expectBorrowRevert(address(coll), AceVaultCaps.OverTotal.selector);
        vm.prank(guardian);
        vm.expectRevert(AceVaultCaps.NotCurator.selector);
        vault.submitCap(address(vault), WILD / 2);
        vm.prank(curator);
        vault.submitCap(address(vault), WILD / 2);
        assertEq(vault.effectiveCap(address(vault)), 0, "listing a total landed at once");
        _warpBy(CAP_LOCK);
        vault.acceptCap(address(vault));
        assertEq(vault.effectiveCap(address(vault)), WILD / 2, "the accepted total did not land");
        assertEq(vlens.roomOf(address(vault), address(coll)), WILD / 2, "the accepted total gave other room");
    }

    // ---- the events ----

    /// @notice A landing emits `SetCap` naming who; a queue emits `SubmitCap` with its `validAt`; a cut over a pending change emits the revoke first.
    function test_TheCapVerbsEmitWhatTheyDid() public {
        vm.expectEmit(true, true, false, true, address(vault));
        emit SetCap(guardian, c, 100e6, true);
        vm.prank(guardian);
        vault.submitCap(c, 100e6);
        vm.expectEmit(true, false, false, true, address(vault));
        emit SubmitCap(c, 500e6, true, uint64(_now()) + CAP_LOCK);
        vm.prank(curator);
        vault.submitCap(c, 500e6);
        vm.expectEmit(true, true, false, false, address(vault));
        emit RevokePendingCap(guardian, c);
        vm.expectEmit(true, true, false, true, address(vault));
        emit SetCap(guardian, c, 10e6, true);
        vm.prank(guardian);
        vault.submitCap(c, 10e6);
        vm.prank(curator);
        vault.submitCap(address(0), 2 * WILD);
        _warpBy(CAP_LOCK);
        vm.expectEmit(true, true, false, true, address(vault));
        emit SetCap(stranger, address(0), 2 * WILD, true);
        vm.prank(stranger);
        vault.acceptCap(address(0));
    }

    /// @notice The deploy's caps each emit `SetCap`, listed, naming the deployer.
    function test_TheDeployEmitsEachCap() public {
        CapListing[] memory l = new CapListing[](2);
        l[0] = CapListing(address(coll), 7e6);
        address predicted = vm.computeCreateAddress(address(this), vm.getNonce(address(this)) + 1);
        l[1] = CapListing(predicted, 9e6);
        vm.recordLogs();
        AceVault v = _deployListing(l);
        Vm.Log[] memory logs = vm.getRecordedLogs();
        bytes32 sig = keccak256("SetCap(address,address,uint256,bool)");
        uint256 seen;
        for (uint256 i; i < logs.length; i++) {
            if (logs[i].emitter != address(v) || logs[i].topics[0] != sig) continue;
            assertEq(logs[i].topics[1], bytes32(uint256(uint160(address(this)))), "a deploy cap names another setter");
            (uint256 cap, bool listed) = abi.decode(logs[i].data, (uint256, bool));
            assertTrue(listed, "a deploy cap emitted unlisted");
            assertEq(cap, seen == 0 ? 7e6 : 9e6, "a deploy cap emitted another figure");
            assertEq(logs[i].topics[2], bytes32(uint256(uint160(seen == 0 ? address(coll) : predicted))), "a deploy cap emitted another key");
            seen++;
        }
        assertEq(seen, 2, "the deploy did not emit one SetCap per listing");
        assertEq(v.effectiveCap(address(v)), 9e6, "the deploy's total did not stand");
    }
}
