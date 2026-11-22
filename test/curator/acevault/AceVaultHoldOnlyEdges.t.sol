// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.36;

import {PolicyRefused} from "../../../src/ace/hub/Borrower.sol";
import {AceVault, VaultConfig} from "../../../src/curator/AceVault.sol";
import {AceVaultFlows} from "../../../src/curator/libraries/AceVaultFlows.sol";
import {Listing} from "../../../src/entities/curated/CuratorTerms.sol";
import {CuratedVaults} from "../../utils/CuratedVaults.sol";
import {AceVaultRig} from "./AceVaultRig.sol";

/// @dev The lens view these rows read beside the vault's own gates.
interface IHoldGateLens {
    function entryGate(address vault) external view returns (bytes4 reason, uint256 until);
}

/// @title AceVaultHoldOnlyEdges
/// @notice The exit gate relaxes only while a stored hold alone shuts entry: the mark, its second, an immaterial pile and the gain gate each keep it whole.
/// @notice The stored second is the hold's edge for entry, for the roll policy and for the lens alike, even over a pile still material there.
/// @notice A seed-only vault neither charges a fee on a gift nor reads it as a gain gate, in the vault or in the lens.
contract AceVaultHoldOnlyEdgesTest is AceVaultRig {
    uint48 internal constant MARKED = type(uint48).max;
    uint256 internal constant IN_BAND = 2_000e6; // a gift over one basis point of the rig's NAV and under the gain gate's band
    uint16 internal constant FEE = 2000;

    // ---- reads ----

    function _word(uint256 k) internal view returns (uint256) {
        bytes32[] memory s = new bytes32[](1);
        s[0] = bytes32(uint256(AceVaultFlows.ROOT) + k);
        return uint256(vault.extsload(s)[0]);
    }

    function _hold() internal view returns (uint48) {
        return uint48(_word(2) >> 200);
    }

    function _maturity() internal view returns (uint64) {
        return uint64(_word(2) >> 128);
    }

    function _gate() internal view returns (bytes4 reason, uint256 until) {
        return IHoldGateLens(address(vlens)).entryGate(address(vault));
    }

    /// @dev Material to the hold, derived here from its definition: over the atom floor and over one basis point of gross.
    function _material(uint256 x) internal view returns (bool) {
        return x > vault.MIN_SEED() && x * 10_000 > vault.grossNav();
    }

    /// @dev Whether the hub would admit the borrower's own roll of `loanId` now, and the refusal's selector.
    function _roll(uint256 loanId) internal view returns (bool ok, bytes4 reason) {
        (ok, reason,) = ace.tryExtend(loanId, 0, "", borrower);
    }

    // ---- moves ----

    function _buyPot(address who, uint256 loanId) internal {
        uint256 budget = 10_000_000e6;
        usdc.mint(who, budget);
        vm.startPrank(who);
        usdc.approve(address(ace), budget);
        ace.buyInventory(loanId, budget, 0, who);
        vm.stopPrank();
    }

    function _settleAndSync(uint256 loanId) internal {
        vm.prank(keeper);
        ace.forceClose(loanId);
        vm.prank(keeper);
        vault.crank();
    }

    /// @dev A gift to the vault, stamped by a crank.
    function _gift(uint256 amt) internal {
        usdc.mint(address(vault), amt);
        vault.crank();
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

    function _assertOpen(address who) internal {
        assertGt(vault.maxDeposit(who), 0, "the view held entry");
        assertGt(vault.maxMint(who), 0, "and so did maxMint");
        usdc.mint(who, 1_000e6);
        vm.startPrank(who);
        usdc.approve(address(vault), 1_000e6);
        assertGt(vault.deposit(1_000e6, who), 0, "the verb refused entry");
        vm.stopPrank();
    }

    /// @dev The roll refused by the vault's policy, and admitted once the request is withdrawn: so the exit gate is what refused it.
    function _assertTheGateRefuses(uint256 honest) internal {
        (bool ok, bytes4 reason) = _roll(honest);
        assertFalse(ok, "an uncovered request did not refuse the lengthening roll");
        assertEq(reason, PolicyRefused.selector, "the vault's policy is not what refused");
        uint256 snap = vm.snapshotState();
        uint256 escrow = vlens.requestedShares(address(vault));
        vm.prank(alice);
        vault.cancelExit(escrow);
        (ok,) = _roll(honest);
        assertTrue(ok, "CONTROL: with the request withdrawn the roll was still refused, so the exit gate was not what refused it");
        vm.revertToState(snap);
    }

    // ---- states ----

    /// @dev An honest month-long loan, a material default beside it and all of alice's shares requested; the default settles and marks the vault.
    function _markedUnderARequest() internal returns (uint256 honest, uint256 a) {
        honest = _borrowAs(borrower, 1_200_000e18, 600_000e6, MAX_TENOR);
        a = _borrowAs(borrower, 30_000e18, 20_000e6, MIN_TENOR);
        uint256 all = vault.balanceOf(alice);
        vm.prank(alice);
        vault.requestExit(all);
        _warpAtLeastTo(_expiry(a));
        _settleAndSync(a);
        assertEq(_hold(), MARKED, "PREMISE: the material fall marked the vault over its unsold pot");
        assertGt(vault.previewRedeem(all), vault.idle(), "PREMISE: the request outweighs idle");
    }

    /// @dev `_markedUnderARequest`, then the pot sells and a sync stores the hold's second.
    function _storedUnderARequest() internal returns (uint256 honest, uint48 held) {
        uint256 a;
        (honest, a) = _markedUnderARequest();
        _warpBy(1 hours);
        _buyPot(stranger, a);
        vault.crank();
        held = _hold();
        assertEq(held, _maturity(), "PREMISE: the sale's sync stored the pile's maturity");
        assertGt(uint256(held), _now(), "PREMISE: a second to come");
    }

    /// @dev A material default sells and stores a hold; the clock runs to a minute before the second, where the sale's pile has vested under the floor.
    function _storedOverAVestedDownPileUnderARequest() internal returns (uint256 honest, uint48 held) {
        honest = _borrowAs(borrower, 1_200_000e18, 600_000e6, MAX_TENOR);
        uint256 a = _borrowAs(borrower, 60_000e18, 40_000e6, MIN_TENOR);
        uint256 all = vault.balanceOf(alice);
        vm.prank(alice);
        vault.requestExit(all);
        _warpAtLeastTo(_expiry(a));
        _settleAndSync(a);
        assertEq(_hold(), MARKED, "PREMISE: the material fall marked the vault");
        _warpBy(1 hours);
        _buyPot(stranger, a);
        vault.crank();
        held = _hold();
        assertEq(held, _maturity(), "PREMISE: the sale's sync stored the hold");
        _warpTo(uint256(held) - 1 minutes);
        uint256 r = vault.unvested();
        assertGt(r, 0, "PREMISE: a residue of the sale's pile still vests");
        assertFalse(_material(r), "PREMISE: and it has vested under the floor");
        assertEq(_hold(), held, "PREMISE: the stored second still stands");
        assertGt(vault.previewRedeem(all), vault.idle(), "PREMISE: the request outweighs idle");
    }

    // ---- the policy's relaxation, leg by leg ----

    /// @notice While MARKED over an unsold pot, a material pile inside the band relaxes nothing: an uncovered request still refuses the roll.
    function test_HoldOnly_WhileMarkedAMaterialPileStillRefusesTheRoll() public {
        (uint256 honest,) = _markedUnderARequest();
        _gift(IN_BAND);
        assertEq(_hold(), MARKED, "PREMISE: still marked, the pot unsold");
        uint256 u = vault.unvested();
        assertTrue(_material(u), "PREMISE: the pile is material");
        assertLe(u * 10_000, vault.totalAssets() * vault.GATE_BPS(), "PREMISE: inside the gain band");
        _assertTheGateRefuses(honest);
    }

    /// @notice At the stored second the hold lifts for entry, the policy and the lens at once, though a later gift keeps the pile material past it.
    function test_HoldOnly_TheStoredSecondIsTheEdgeOverAMaterialPile() public {
        (uint256 honest, uint48 held) = _storedUnderARequest();
        _warpTo(uint256(held) - 1 hours);
        _gift(IN_BAND);
        assertEq(_hold(), held, "PREMISE: a later stamp never moves a stored second");
        assertGt(uint256(_maturity()), uint256(held), "PREMISE: the gift blended the pile's maturity past the stored second");
        _warpTo(uint256(held) - 1);
        assertTrue(_material(vault.unvested()), "PREMISE: a second before, the pile is material");
        (bytes4 reason, uint256 until) = _gate();
        assertEq(reason, AceVault.RecoveryVesting.selector, "a second before the stored one, the lens did not name the hold");
        assertEq(until, held, "and named another second than the stored one");
        _assertHeld(bob);
        (bool ok,) = _roll(honest);
        assertTrue(ok, "a second before the stored one, the hold did not relax the gate");
        _warpTo(held);
        uint256 u = vault.unvested();
        assertTrue(_material(u), "PREMISE: at the stored second the pile is still material");
        assertLe(u * 10_000, vault.totalAssets() * vault.GATE_BPS(), "PREMISE: inside the gain band");
        _assertTheGateRefuses(honest);
        (reason, until) = _gate();
        assertEq(reason, bytes4(0), "at the stored second the lens still named a gate");
        assertEq(until, 0, "and a second");
        _assertOpen(bob);
    }

    /// @notice A stored second over a pile vested under the floor shuts no entry, so it relaxes no gate: the lens reads open and the roll is refused.
    function test_HoldOnly_AStoredSecondOverAnImmaterialPileRelaxesNothing() public {
        (uint256 honest, uint48 held) = _storedOverAVestedDownPileUnderARequest();
        assertLt(_now(), uint256(held), "PREMISE: before the stored second");
        (bytes4 reason, uint256 until) = _gate();
        assertEq(reason, bytes4(0), "the lens named a hold over an immaterial pile");
        assertEq(until, 0, "and a second");
        _assertTheGateRefuses(honest);
        _assertOpen(bob);
    }

    /// @notice Under a stored second the gain gate keeps the exit gate whole: a gift over the band shuts entry, and the roll is still refused.
    function test_HoldOnly_UnderTheGainGateTheRollIsStillRefused() public {
        (uint256 honest, uint48 held) = _storedUnderARequest();
        _gift(100_000e6);
        assertEq(_hold(), held, "PREMISE: the stored second stands");
        assertGt(vault.unvested() * 10_000, vault.totalAssets() * vault.GATE_BPS(), "PREMISE: the pile is over the gain band");
        assertGt(vault.previewRedeem(vlens.requestedShares(address(vault))), vault.idle(), "PREMISE: the request still outweighs idle");
        usdc.mint(bob, 1_000e6);
        vm.startPrank(bob);
        usdc.approve(address(vault), 1_000e6);
        vm.expectRevert(AceVault.GainVesting.selector);
        vault.deposit(1_000e6, bob);
        vm.stopPrank();
        _assertTheGateRefuses(honest);
    }

    /// @notice The hold's gain-gate leg reads the band against NAV, as entry does: a pile over it against NAV still refuses the roll, under it against gross.
    /// @dev The band against NAV is `u > 5% of (gross - u)`; against gross it is `u > 5% of gross`. A pile of 4.9% of gross sits between, so only NAV sees it.
    function test_HoldOnly_InTheGainBandOnNavNotOnGrossTheRollIsStillRefused() public {
        (uint256 honest, uint48 held) = _storedUnderARequest();
        _warpTo(uint256(held) - 1 hours);
        uint256 gross = vault.grossNav();
        uint256 pile = gross - vault.totalAssets(); // the deferred gain a sync now would leave
        assertGt(49 * gross, 1_000 * pile, "PREMISE: the sale's pile has decayed under 4.9% of gross");
        _gift((49 * gross - 1_000 * pile) / 951);
        uint256 u = vault.unvested();
        assertEq(_hold(), held, "PREMISE: the stored second stands");
        assertTrue(_material(u), "PREMISE: the pile is material");
        assertGt(u * 10_000, vault.totalAssets() * vault.GATE_BPS(), "PREMISE: over the gain band against NAV");
        assertLe(u * 10_000, vault.grossNav() * vault.GATE_BPS(), "PREMISE: and under it against gross");
        assertGt(vault.previewRedeem(vlens.requestedShares(address(vault))), vault.idle(), "PREMISE: the request still outweighs idle");
        (bytes4 reason,) = _gate();
        assertEq(reason, AceVault.GainVesting.selector, "the lens did not name the gain gate");
        usdc.mint(bob, 1_000e6);
        vm.startPrank(bob);
        usdc.approve(address(vault), 1_000e6);
        vm.expectRevert(AceVault.GainVesting.selector);
        vault.deposit(1_000e6, bob);
        vm.stopPrank();
        _assertTheGateRefuses(honest);
    }

    // ---- live supply ----

    /// @notice A gift to a seed-only vault vests far over the band, yet the lens reads entry open, as `maxDeposit` and the verb do.
    function test_EntryGate_ASeedOnlyVaultReadsOpenOverAGift() public {
        vault = _newVault(_row(address(record)));
        usdc.mint(address(vault), 10e6);
        vault.crank();
        assertEq(vault.totalSupply(), vault.SEED_SHARES(), "PREMISE: no live share");
        assertGt(vault.unvested(), vault.VEST_FLOOR(), "PREMISE: the gift vests over one unit");
        assertGt(vault.unvested() * 10_000, vault.totalAssets() * vault.GATE_BPS(), "PREMISE: far over the gain band");
        (bytes4 reason, uint256 until) = _gate();
        assertEq(reason, bytes4(0), "the lens named a gain gate on a vault with no live share");
        assertEq(until, 0, "and a second");
        _assertOpen(bob);
    }

    /// @notice A seed-only fee vault charges no fee on a vested gift and re-stamps the high-water at NAV, so the curator is minted nothing.
    function test_Fee_ASeedOnlyVaultChargesNoFeeOnAGift() public {
        VaultConfig memory c = _cfg();
        c.perfFeeBps = FEE;
        Listing[] memory l = new Listing[](1);
        l[0] = Listing({collateral: address(coll), row: _row(address(record))});
        AceVault v = CuratedVaults.viaFactory(vaultFactory, bytes32(++vaultSalt), c, _curated(), l, "Fee", "fVLT");
        assertEq(v.totalSupply(), v.SEED_SHARES(), "PREMISE: no live share");
        usdc.mint(address(v), 10_000e6);
        v.crank();
        _warpBy(VEST_W + 1);
        assertEq(v.unvested(), 0, "PREMISE: the gift has vested");
        assertGt(v.totalAssets(), v.feeHighWater(), "PREMISE: the vested gift lifts NAV past the high-water");
        assertEq(v.pendingFeeShares(), 0, "a fee is pending on a vault with no live share");
        v.collectFee();
        assertEq(v.balanceOf(curator), 0, "the curator was minted a fee on the seed's gift");
        assertEq(v.totalSupply(), v.SEED_SHARES(), "a share was minted on a vault with no live share");
        assertEq(v.feeHighWater(), v.totalAssets(), "with no live share the high-water did not re-stamp at NAV");
    }
}
