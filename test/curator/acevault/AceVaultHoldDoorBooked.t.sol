// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.36;

import {IERC721} from "@openzeppelin/contracts/token/ERC721/IERC721.sol";
import {MockStakeVault} from "../../mocks/MockStakeVault.sol";
import {MockPersistenceRecord} from "../../mocks/MockPersistenceRecord.sol";
import {AceVault} from "../../../src/vault/AceVault.sol";
import {AceVaultFlows, Terms} from "../../../src/vault/libraries/AceVaultFlows.sol";
import {IAceVaultDoor} from "../../../src/interfaces/IAceVaultDoor.sol";
import {AceVaultDoorRig} from "../vault/AceVaultDoorRig.sol";

/// @title AceVaultHoldDoorBooked
/// @notice The trough hold in door mode, where the collect also weighs the value it booked: a netted fall still marks once that value is material.
/// @notice A default whose pot is immaterial against the mark leaves no hold, so a fully recovered smallest default opens entry at its return.
/// @notice The booked value lives one call: a later collect in the same transaction does not read an earlier one's.
/// @notice While a stored hold alone shuts entry, the vault's own `extendFor` admits a lengthening roll over an uncovered request.
contract AceVaultHoldDoorBookedTest is AceVaultDoorRig {
    uint256 internal constant ENTRY = 1_000_000e6;
    uint48 internal constant MARKED = type(uint48).max;
    uint256 internal constant SEIZED_SLOT_OFFSET = 9;

    MockStakeVault internal coll2; // a collateral on the uncapped wildcard, for the loans too large for the rig's row
    MockPersistenceRecord internal record2;

    function setUp() public virtual override {
        super.setUp();
        coll2 = new MockStakeVault(43);
        record2 = _record(address(coll2));
    }

    // ---- reads ----

    function _hold() internal view returns (uint48) {
        bytes32[] memory s = new bytes32[](1);
        s[0] = bytes32(uint256(AceVaultFlows.ROOT) + 2);
        return uint48(uint256(vault.extsload(s)[0]) >> 200);
    }

    function _navMark() internal view returns (uint256) {
        bytes32[] memory s = new bytes32[](1);
        s[0] = bytes32(uint256(AceVaultFlows.ROOT) + 1);
        return uint256(vault.extsload(s)[0]);
    }

    function _assertHeld(address who) internal {
        assertEq(vault.maxDeposit(who), 0, "maxDeposit advertised an entry the hold shuts");
        usdc.mint(who, 1_000e6);
        vm.startPrank(who);
        usdc.approve(address(vault), 1_000e6);
        vm.expectRevert(AceVault.RecoveryVesting.selector);
        vault.deposit(1_000e6, who);
        vm.stopPrank();
    }

    // ---- loans ----

    /// @dev A door-mode loan of `p` on `units` of `c`, priced off `r`, to `who`.
    function _loanOn(address who, MockStakeVault c, MockPersistenceRecord r, uint256 units, uint256 p) internal returns (uint256 id) {
        terms.setTerms(_doorMarket(address(c), r), Terms({units: units, principal: p, tenor: 0, minBufferWad: 0}));
        id = _borrowAs(who, address(c), units, p);
    }

    function _loan(address who, uint256 units, uint256 p) internal returns (uint256) {
        return _loanOn(who, coll, record, units, p);
    }

    // ---- T9: the netted fall marks through the booked value ----

    /// @notice A fall netted by a donation before any sync still marks at the collect, and the door's closing return is held.
    function test_DoorBooked_ANettedFallMarksThroughTheBookedValue() public {
        uint256 loanId = _loan(borrower, 80_000e18, 40_000e6);
        _warpTo(read.loan(loanId).expiry + VEST_W);
        vault.crank();
        uint256 gMark = vault.grossNav();
        usdc.mint(address(vault), 40_000e6);
        vm.prank(stranger);
        ace.forceClose(loanId);
        assertGe(vault.grossNav(), gMark, "PREMISE: gross never reads under the mark");
        _collect(loanId);
        assertEq(_hold(), MARKED, "the collect's booked value did not mark the vault over a netted fall");
        _warpBy(VEST_W);
        _give(address(coll), 30_000e6, true);
        assertGt(uint256(_hold()), _now(), "the closing return stored no hold");
        assertLe(vault.unvested() * 10_000, vault.totalAssets() * vault.GATE_BPS(), "PREMISE: inside the band, so only the hold shuts entry");
        _assertHeld(bob);
    }

    /// @notice A roll's fee paid at the hub, unseen, nets a stranger's 1,000 USDC settle; the collect still marks, and the sale is held.
    function test_DoorBooked_ARollsUnseenIncomeNetsAThousandUsdcDefaultAndItIsStillHeld() public {
        uint256 big = _loanOn(borrower, coll2, record2, 800_000e18, 400_000e6);
        uint256 small = _loan(stranger, 2_000e18, 1_000e6);
        _warpBy(6 days);
        vault.crank();
        uint256 mark = _navMark();
        _fundFee(borrower);
        vm.prank(borrower);
        uint256 fee = ace.extend(big, 0, "");
        assertGt(fee, 0, "PREMISE: the roll paid a fee at the hub");
        assertEq(_navMark(), mark, "PREMISE: the roll ran no vault sync");
        _warpTo(read.loan(small).expiry);
        vm.prank(stranger);
        ace.forceClose(small);
        assertGe(vault.grossNav(), mark, "PREMISE: the roll's income nets the default's fall");
        _collect(small);
        assertEq(_hold(), MARKED, "the collect did not mark over the netted 1,000 USDC default");
        (uint256 booked,,) = _seized(address(coll));
        _warpBy(1 hours);
        _give(address(coll), booked, true);
        _assertHeld(bob);
    }

    /// @notice BOUNDARY: a 100 USDC default on the same vault books under one basis point of the mark, so its netted fall is not held.
    function test_DoorBooked_AHundredUsdcNettedDefaultIsUnderTheFloor() public {
        uint256 big = _loanOn(borrower, coll2, record2, 800_000e18, 400_000e6);
        uint256 small = _loan(stranger, 200e18, 100e6);
        _warpBy(6 days);
        vault.crank();
        _fundFee(borrower);
        vm.prank(borrower);
        ace.extend(big, 0, "");
        _warpTo(read.loan(small).expiry);
        vm.prank(stranger);
        ace.forceClose(small);
        _collect(small);
        (uint256 booked,,) = _seized(address(coll));
        assertLe(booked * 10_000, _navMark(), "PREMISE: the pot books at or under one basis point of the mark");
        assertEq(_hold(), 0, "an immaterial booking marked the vault");
        _give(address(coll), booked, true);
        assertEq(_hold(), 0, "the closing return stored a hold");
        assertGt(vault.maxDeposit(bob), 0, "entry stayed shut over an immaterial recovery");
    }

    /// @notice Run A's door row: a closing repay lands unsynced, a stranger settles a material default under it, and the door's return is held.
    function test_DoorBooked_AClosingRepaysUnseenIncomeNetsADefaultAndItIsStillHeld() public {
        uint256 big = _loanOn(borrower, coll2, record2, 800_000e18, 400_000e6);
        _warpBy(1 days);
        uint256 small = _loan(stranger, 400e18, 200e6);
        _warpTo(read.loan(small).expiry);
        assertTrue(ace.isLiveLoan(big), "PREMISE: nobody has settled the big loan");
        uint256 gMark = vault.grossNav();
        uint256 debt = ace.debtOf(big);
        usdc.mint(borrower, debt);
        vm.startPrank(borrower);
        usdc.approve(address(ace), debt);
        ace.repay(big, debt);
        vm.stopPrank();
        vm.prank(stranger);
        ace.forceClose(small);
        assertGe(vault.grossNav(), gMark, "PREMISE: the income covers the fall, so gross never reads under the mark");
        assertGt(_collect(small), 0, "PREMISE: the door's collect took the pot");
        (uint256 booked,,) = _seized(address(coll));
        assertGt(booked * 10_000, _navMark(), "PREMISE: the pot books over one basis point of the mark");
        assertEq(_hold(), MARKED, "the collect did not mark over the netted default");
        _warpBy(1 hours);
        _give(address(coll), booked, true);
        _assertHeld(bob);
    }

    // ---- B7-F1: the smallest default, fully recovered ----

    /// @notice A smallest default the door collects and returns whole leaves entry open at its return.
    function test_DoorBooked_AFullyRecoveredSmallestDefaultDoesNotHoldEntry() public {
        uint256 loanId = _loan(borrower, 20e18, 10e6);
        _warpTo(read.loan(loanId).expiry + 1);
        _collect(loanId);
        assertEq(_hold(), 0, "a smallest default marked the vault");
        (uint256 booked,,) = _seized(address(coll));
        _give(address(coll), booked, true);
        assertEq(lens.openSeized(address(vault)), 0, "premise: no key is open");
        assertGt(vault.unvested(), vault.VEST_FLOOR(), "premise: the recovery vests over one asset unit");
        assertEq(_hold(), 0, "the closing return stored a hold over an immaterial pile");
        assertGt(vault.maxDeposit(bob), 0, "a recovery under a basis point of NAV held entry");
        assertGt(_lp(bob, 1_000e6), 0, "a deposit refused");
    }

    /// @notice CONTROL: the rig's 1,000 USDC default, collected and returned, holds entry.
    function test_DoorBooked_Control_AMaterialDefaultHolds() public {
        uint256 loanId = _defaulted();
        _collect(loanId);
        assertEq(_hold(), MARKED, "a material default did not mark the vault");
        (uint256 booked,,) = _seized(address(coll));
        _give(address(coll), booked, true);
        _assertHeld(bob);
    }

    // ---- LR-5: the booked value is one call's, and a saturated record still collects ----

    /// @notice In one transaction: a material collect and its closing return store a hold; a dust settle and a crank after them leave the stored second.
    /// @dev A booked value the collect left standing would read material at the crank's sync and mark the vault over the dust pot unsold at the hub.
    function test_DoorBooked_TheBookedValueDoesNotOutliveItsCollect() public {
        uint256 a = _loan(borrower, 80_000e18, 40_000e6);
        uint256 d = _loan(griefer(), 20e18, 10e6);
        _warpTo(read.loan(d).expiry + 1);
        assertGe(_now(), read.loan(a).expiry, "PREMISE: both loans have lapsed");
        _collect(a);
        assertEq(_hold(), MARKED, "PREMISE: the material collect marked the vault");
        (uint256 booked,,) = _seized(address(coll));
        _give(address(coll), booked, true);
        uint48 held = _hold();
        assertGt(uint256(held), _now(), "PREMISE: the closing return stored a hold");
        assertLt(held, MARKED, "PREMISE: a second, not the mark");
        assertEq(lens.drawdown(address(vault)), 0, "PREMISE: the return recovered the drawdown");
        vm.prank(stranger);
        ace.forceClose(d);
        (uint256 unsold,) = ace.lenderUnresolved(address(vault), address(usdc));
        assertEq(unsold, 1, "PREMISE: the dust pot stands unsold at the hub");
        vault.crank();
        assertEq(_hold(), held, "a later sync read the earlier collect's booked value");
    }

    function griefer() internal pure returns (address) {
        return address(0x6121EF);
    }

    /// @notice A record already saturated at its width still takes a material collect: it books, opens the key and marks the vault.
    function test_DoorBooked_ASaturatedRecordStillCollectsAndMarks() public {
        uint256 loanId = _defaulted();
        bytes32 s = keccak256(abi.encode(address(coll), uint256(AceVaultFlows.ROOT) + SEIZED_SLOT_OFFSET));
        vm.store(address(vault), s, bytes32(uint256(type(uint184).max - 1)));
        _collect(loanId);
        (uint256 v, bool open,) = _seized(address(coll));
        assertEq(v, type(uint184).max, "the value saturates at the record's width");
        assertTrue(open, "the key opens");
        assertEq(_hold(), MARKED, "the collect's fall did not mark the vault");
    }

    // ---- T11, door: the vault's own extension during a hold ----

    /// @dev A loan of most of the vault, on the wildcard collateral, whose holder approved the vault as title operator; a day old so a roll adds time.
    function _rollable() internal returns (uint256 loanId) {
        loanId = _loanOn(borrower, coll2, record2, 1_200_000e18, 600_000e6);
        address title = ace.POSITION_TITLE();
        vm.prank(borrower);
        IERC721(title).setApprovalForAll(address(vault), true);
        _warpBy(1 days);
    }

    function _extendFor(uint256 loanId) internal returns (bool ok, bytes memory err) {
        usdc.mint(borrower, 100_000e6);
        vm.prank(borrower);
        usdc.approve(address(vault), type(uint256).max);
        vm.prank(borrower);
        (ok, err) = address(dv).call(abi.encodeCall(IAceVaultDoor.extendFor, (loanId, type(uint256).max, 0, "", "")));
    }

    /// @notice While a stored hold alone shuts entry, `extendFor` admits a lengthening roll over an uncovered request; while marked it refuses.
    function test_DoorBooked_DuringAStoredHoldExtendForAdmitsARoll() public {
        uint256 a = _loan(stranger, 40_000e18, 20_000e6);
        _warpBy(3 days);
        uint256 honest = _rollable();
        uint256 all = vault.balanceOf(alice);
        vm.prank(alice);
        vault.requestExit(all);
        _warpTo(read.loan(a).expiry + 1);
        _collect(a);
        assertEq(_hold(), MARKED, "premise: marked over the open key");
        uint256 snap = vm.snapshotState();
        (bool ok, bytes memory err) = _extendFor(honest);
        assertFalse(ok, "while marked, the uncovered request did not refuse the roll");
        assertEq(bytes4(err), IAceVaultDoor.RequestsOutweighIdle.selector, "the exit gate is what refused");
        vm.revertToState(snap);
        (uint256 booked,,) = _seized(address(coll));
        _give(address(coll), booked, true);
        assertGt(uint256(_hold()), _now(), "premise: the closing return stored a hold");
        assertGt(vault.previewRedeem(all), vault.idle(), "premise: the request still outweighs idle");
        _assertHeld(bob);
        (ok,) = _extendFor(honest);
        assertTrue(ok, "during a stored hold the uncovered request refused the vault's own roll");
    }

    // ---- an exempted door key under a stored hold ----

    /// @dev Loan `a` defaults to the door, marked; the guardian exempts its key, and a recovery's sync stores a hold with the key still open.
    function _exemptedKeyUnderAHold() internal returns (uint256 honest, uint256 dust) {
        uint256 a = _loan(stranger, 40_000e18, 20_000e6);
        dust = _loan(griefer(), 20e18, 10e6);
        _warpBy(3 days);
        honest = _rollable();
        uint256 all = vault.balanceOf(alice);
        vm.prank(alice);
        vault.requestExit(all);
        _warpTo(read.loan(a).expiry + 1);
        _collect(a);
        assertEq(_hold(), MARKED, "premise: marked over the open key");
        (, uint256 settled) = ace.lenderUnresolved(address(vault), address(usdc));
        vm.prank(guardian);
        vault.exemptDeadPots(settled);
        usdc.mint(address(vault), 25_000e6);
        vault.crank();
        assertGt(uint256(_hold()), _now(), "premise: the clear stored a hold");
        assertLt(_hold(), MARKED, "premise: a second, not the mark");
        assertEq(lens.openSeized(address(vault)), 1, "premise: the exempted key is still open");
        assertEq(lens.drawdown(address(vault)), 0, "premise: the recovery closed the drawdown");
        assertGt(vault.previewRedeem(all), vault.idle(), "premise: the request still outweighs idle");
        _assertHeld(bob);
    }

    function _hubRoll(uint256 loanId) internal returns (bool ok) {
        _fundFee(borrower);
        vm.prank(borrower);
        (ok,) = address(ace).call(abi.encodeCall(ace.extend, (loanId, 0, "")));
    }

    /// @notice While an exempted key stands under a stored hold, a lengthening roll over an uncovered request is admitted, at the hub and by `extendFor`.
    function test_DoorBooked_AnExemptedKeyUnderAStoredHoldAdmitsARoll() public {
        (uint256 honest,) = _exemptedKeyUnderAHold();
        uint256 snap = vm.snapshotState();
        assertTrue(_hubRoll(honest), "the hub's roll was refused over an exempted key");
        vm.revertToState(snap);
        (bool ok,) = _extendFor(honest);
        assertTrue(ok, "the vault's own roll was refused over an exempted key");
    }

    /// @notice CONTROL: a settlement after the exemption voids it; once the door collects that pot, the uncovered request refuses the roll again.
    function test_DoorBooked_AStaleExemptionLeavesTheKeyUnexemptedAndTheRollRefused() public {
        (uint256 honest, uint256 dust) = _exemptedKeyUnderAHold();
        uint48 held = _hold();
        vm.prank(stranger);
        ace.forceClose(dust);
        _collect(dust);
        assertEq(_hold(), held, "premise: the dust collect left the stored hold");
        uint256 snap = vm.snapshotState();
        assertFalse(_hubRoll(honest), "the hub admitted a roll over an unexempted key");
        vm.revertToState(snap);
        (bool ok, bytes memory err) = _extendFor(honest);
        assertFalse(ok, "the vault's own roll was admitted over an unexempted key");
        assertEq(bytes4(err), IAceVaultDoor.RequestsOutweighIdle.selector, "the exit gate is what refused");
    }
}
