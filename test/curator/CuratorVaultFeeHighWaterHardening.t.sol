// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.36;

import {Vm} from "forge-std/Vm.sol";
import {CuratorVaultBase} from "./CuratorVaultBase.sol";
import {CuratorVault} from "../../src/curator/CuratorVault.sol";
import {AceVault} from "../../src/curator/AceVault.sol";
import {AceInventoryLens} from "../../src/ace/lens/AceInventoryLens.sol";

/// @title CuratorVaultFeeHighWaterHardening
/// @notice The fee high-water's audit rows: each closes a gap where no existing row could fail.
/// @dev Expected values are read off the vault's own state after the verb, never recomputed from the fee formula.
contract CuratorVaultFeeHighWaterHardeningTest is CuratorVaultBase {
    /// @dev Request `who`'s whole holding and claim all of it.
    function _exitWhole(CuratorVault v, address who) internal {
        uint256 shares = v.balanceOf(who);
        vm.startPrank(who);
        v.requestExit(shares);
        v.claimExit(shares, who, 0);
        vm.stopPrank();
    }

    /// @dev The `FeeCharged` events the vault emitted since `vm.recordLogs()`, as (shares, high-water) pairs.
    function _charges(CuratorVault v) internal returns (uint256 n, uint256 shares, uint256 highWater) {
        Vm.Log[] memory logs = vm.getRecordedLogs();
        for (uint256 i; i < logs.length; i++) {
            if (logs[i].emitter != address(v) || logs[i].topics[0] != AceVault.FeeCharged.selector) continue;
            n++;
            (shares, highWater) = abi.decode(logs[i].data, (uint256, uint256));
        }
    }

    /// @notice A CHARGE REPORTS WHAT HAPPENED: `FeeCharged` names the shares the curator was minted and the high-water it left at NAV.
    /// @notice And the charge LIFTS the high-water: a second collection with no growth since emits nothing and mints nothing.
    /// @dev No row asserted the event, and only an exit or a claim lowers the high-water, so a collection that left it standing re-billed one gain.
    function test_Fee_AChargeReportsItsMintAndLiftsTheHighWaterToNav() public {
        CuratorVault v = _newVault(1000);
        _lpDeposit(v, alice, 10_000e6);
        _gift(v, 1_000e6);
        v.crank(); // syncs the gain into the vest; the fee it collects reads only the vested part, which has not moved
        _warpBy(VEST_W);
        uint256 held = v.balanceOf(curator);
        vm.recordLogs();
        v.collectFee();
        (uint256 n, uint256 shares, uint256 highWater) = _charges(v);
        uint256 minted = v.balanceOf(curator) - held;
        assertGt(minted, 0, "PREMISE: the gain past the high-water was charged");
        assertEq(n, 1, "the charge emitted other than one FeeCharged");
        assertEq(shares, minted, "FeeCharged named other than the shares the curator was minted");
        assertEq(highWater, v.feeHighWater(), "FeeCharged named other than the high-water the charge left");
        assertEq(v.feeHighWater(), v.totalAssets(), "and the charge did not lift the high-water to NAV");
        vm.recordLogs();
        v.collectFee(); // nothing has grown since
        (n,,) = _charges(v);
        assertEq(n, 0, "a collection with no growth since the last charge emitted a charge");
        assertEq(v.balanceOf(curator) - held, minted, "and billed the same gain a second time");
    }

    /// @notice A RECOVERY THAT LANDS AFTER THE LAST HOLDER LEFT IS NOT BILLED TO THE NEXT DEPOSITOR.
    /// @notice Every holder exits by a claim at the trough; the settled loan's inventory then sells into the empty vault.
    /// @notice The collection at zero supply stamps the high-water at that NAV, which is nobody's growth, and the next entrant pays no fee on it.
    /// @dev The other zero-supply rows leave a residual of a wei or none, where a stamp of zero and a stamp of NAV read alike.
    function test_Fee_ARecoveryIntoTheEmptyVaultIsNotBilledToTheNextDepositor() public {
        CuratorVault v = _newVault(5000);
        _lpDeposit(v, alice, 10_000e6);
        uint256 loanId = _open(1_000e6);
        v.crank();
        _warpBy(VEST_W);
        v.collectFee(); // the open's recognized gain charged, so the curator holds shares and leaves too
        _finalize(loanId);
        _crankAll(v);
        if (v.balanceOf(curator) != 0) _exitWhole(v, curator);
        _exitWhole(v, alice);
        assertEq(v.totalSupply(), 0, "PREMISE: every holder left");
        AceInventoryLens inv = new AceInventoryLens(address(ace), address(lens));
        _warpAtLeastTo(read.inventoryAskOpensAt(loanId));
        assertGt(_buyPot(keeper, loanId, inv.clearingBudget(mid, loanId)), 0, "PREMISE: the inventory sold into the empty vault");
        assertEq(read.invPotOf(mid, loanId), 0, "PREMISE: sold whole, so the unsold-pot gate admits the next entrant");
        v.crank();
        _warpBy(VEST_W);
        v.collectFee(); // at zero supply: the stamp
        uint256 nav = v.totalAssets();
        assertGt(nav, 100e6, "PREMISE: the recovery left real NAV with nobody holding a share");
        assertEq(v.feeHighWater(), nav, "the zero-supply collection did not stamp the high-water at the NAV left");
        _lpDeposit(v, bob, 10_000e6);
        assertEq(v.pendingFeeShares(), 0, "the next entrant was billed for a recovery nobody earned");
        uint256 held = v.balanceOf(curator);
        v.collectFee();
        assertEq(v.balanceOf(curator), held, "and a collection charged it");
    }
}
