// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.36;

import {MockStakeVault} from "../../mocks/MockStakeVault.sol";
import {MockPersistenceRecord} from "../../mocks/MockPersistenceRecord.sol";
import {AceVault} from "../../../src/vault/AceVault.sol";
import {AceVaultFlows, Terms} from "../../../src/vault/libraries/AceVaultFlows.sol";
import {AceVaultDoorRig} from "../vault/AceVaultDoorRig.sol";

/// @dev The lens views these rows read beside the vault's own gates.
interface IDoorGateLens {
    function entryGate(address vault) external view returns (bytes4 reason, uint256 until);
    function troughHoldOf(address vault) external view returns (uint48);
}

/// @title AceVaultDoorEntryGate
/// @notice Door mode at the entry gate: the lens names an open key and its hold as the vault does, and an exempted key as open.
/// @notice A collect keeps an exemption no settlement has voided, and its booked value is the batch's sum, so pots split under the floor still mark.
contract AceVaultDoorEntryGateTest is AceVaultDoorRig {
    uint48 internal constant MARKED = type(uint48).max;
    uint256 internal constant EXEMPT_SETTLED = 5; // the exemption's word, at its offset from `ace.curatorvault`

    MockStakeVault internal coll2; // a collateral on the uncapped wildcard, for a loan too large for the rig's row
    MockPersistenceRecord internal record2;

    function setUp() public virtual override {
        super.setUp();
        coll2 = new MockStakeVault(43);
        record2 = _record(address(coll2));
    }

    // ---- reads ----

    function _word(uint256 k) internal view returns (uint256) {
        bytes32[] memory s = new bytes32[](1);
        s[0] = bytes32(uint256(AceVaultFlows.ROOT) + k);
        return uint256(vault.extsload(s)[0]);
    }

    function _hold() internal view returns (uint48) {
        return uint48(_word(2) >> 200);
    }

    function _navMark() internal view returns (uint256) {
        return _word(1);
    }

    function _gl() internal view returns (IDoorGateLens) {
        return IDoorGateLens(address(lens));
    }

    /// @dev The lens's reason, checked against `maxDeposit` and against the verb's own refusal.
    function _parity(bytes4 want) internal returns (uint256 until) {
        bytes4 reason;
        (reason, until) = _gl().entryGate(address(vault));
        assertEq(reason, want, "the lens named another reason");
        assertEq(reason == bytes4(0), vault.maxDeposit(bob) > 0, "the lens's OPEN disagreed with maxDeposit");
        assertEq(_gl().troughHoldOf(address(vault)), _hold(), "troughHoldOf is not the stored hold");
        uint256 snap = vm.snapshotState();
        usdc.mint(bob, 1_000e6);
        vm.startPrank(bob);
        usdc.approve(address(vault), 1_000e6);
        (bool ok, bytes memory err) = address(vault).call(abi.encodeCall(vault.deposit, (1_000e6, bob)));
        vm.stopPrank();
        vm.revertToState(snap);
        assertEq(ok, reason == bytes4(0), "the verb disagreed with the lens");
        if (!ok) assertEq(bytes4(err), reason, "the verb refused with another reason");
    }

    function _loanOn(address who, MockStakeVault c, MockPersistenceRecord r, uint256 units, uint256 p) internal returns (uint256 id) {
        terms.setTerms(_doorMarket(address(c), r), Terms({units: units, principal: p, tenor: 0, minBufferWad: 0}));
        id = _borrowAs(who, address(c), units, p);
    }

    // ---- the lens reads the door's key ----

    /// @notice An open door key with nothing unsold at the hub reads `InventoryUnsold`; its closing return then reads the hold, to the stored second.
    function test_DoorEntryGate_AnOpenKeyReadsInventoryUnsoldThenItsHold() public {
        uint256 loanId = _defaulted();
        _collect(loanId);
        (uint256 hubUnsold,) = ace.lenderUnresolved(address(vault), address(usdc));
        assertEq(hubUnsold, 0, "PREMISE: the pot left the hub for the door");
        assertEq(lens.openSeized(address(vault)), 1, "PREMISE: the door's key is open");
        assertEq(_hold(), MARKED, "PREMISE: the collect marked the vault");
        assertEq(_parity(AceVault.InventoryUnsold.selector), 0, "an open key named a second");
        (uint256 booked,,) = _seized(address(coll));
        _give(address(coll), booked, true);
        uint48 held = _hold();
        assertGt(uint256(held), _now(), "PREMISE: the closing return stored a hold");
        assertEq(_parity(AceVault.RecoveryVesting.selector), held, "the lens named another second than the stored hold");
    }

    // ---- an exemption the collect does not void ----

    /// @notice The guardian exempts a pot standing at the hub; the door's collect of that same pot keeps the exemption, so entry stays open over its key.
    function test_DoorExemption_ACollectOfTheExemptedPotKeepsTheExemption() public {
        uint256 loanId = _defaulted();
        vm.prank(stranger);
        ace.forceClose(loanId);
        vault.crank();
        assertEq(_hold(), MARKED, "PREMISE: the fall marked the vault over the hub's unsold pot");
        (, uint256 s) = ace.lenderUnresolved(address(vault), address(usdc));
        vm.prank(guardian);
        vault.exemptDeadPots(s);
        _collect(loanId);
        (, uint256 s2) = ace.lenderUnresolved(address(vault), address(usdc));
        assertEq(s2, s, "PREMISE: no settlement since the exemption");
        assertEq(lens.openSeized(address(vault)), 1, "PREMISE: the collect opened the door's key");
        assertEq(_word(EXEMPT_SETTLED), s, "the collect of the very pot the exemption covers voided it");
        assertEq(_hold(), 0, "PREMISE: the exemption's clear over no pile stored no hold");
        _parity(bytes4(0));
    }

    // ---- the booked value is the batch's sum ----

    /// @notice Two pots each booked under one basis point of the mark, collected in one batch under a netted fall, mark on their sum.
    function test_DoorBooked_TwoSubFloorPotsInOneBatchMarkOnTheirSum() public {
        uint256 big = _loanOn(borrower, coll2, record2, 800_000e18, 400_000e6);
        uint256 s1 = _loanOn(stranger, coll, record, 200e18, 100e6);
        uint256 s2 = _loanOn(stranger, coll, record, 200e18, 100e6);
        assertEq(read.loan(s2).expiry, read.loan(s1).expiry, "PREMISE: the two small loans lapse together");
        _warpBy(6 days);
        vault.crank();
        _fundFee(borrower);
        vm.prank(borrower);
        assertGt(ace.extend(big, 0, ""), 0, "PREMISE: the roll paid a fee at the hub, unseen");
        _warpTo(read.loan(s1).expiry);
        uint256 mark = _navMark();
        vm.startPrank(stranger);
        ace.forceClose(s1);
        ace.forceClose(s2);
        vm.stopPrank();
        assertGe(vault.grossNav(), mark, "PREMISE: the roll's income nets both falls");
        uint256[] memory ids = new uint256[](2);
        (ids[0], ids[1]) = (s1, s2);
        uint256[] memory out = door.collect(ids);
        assertEq(out[0], out[1], "PREMISE: the two pots are alike");
        (uint256 booked,,) = _seized(address(coll));
        uint256 each = booked / 2;
        assertEq(booked, 2 * each, "PREMISE: each pot booked the same value");
        assertLe(each * 10_000, _navMark(), "PREMISE: each pot books at or under one basis point of the mark");
        assertGt(booked * 10_000, _navMark(), "PREMISE: the two together book over one basis point");
        assertLe(lens.drawdown(address(vault)) * 10_000, _navMark(), "PREMISE: the drawdown is immaterial, so only the booked sum can mark");
        assertEq(_hold(), MARKED, "two sub-floor pots collected in one batch did not mark on their sum");
    }
}
