// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.36;

import {CuratorVaultBase} from "./CuratorVaultBase.sol";
import {CuratorVault} from "../../src/curator/CuratorVault.sol";
import {Math} from "@openzeppelin/contracts/utils/math/Math.sol";

/// @title CuratorVaultQueueHardening
/// @notice The exit request's hardening rows: each pins a property a named mutant used to survive.
/// @dev Expected values are derived from the vault's public reads and the rule the row names, never from the function under test.
contract CuratorVaultQueueHardeningTest is CuratorVaultBase {
    address internal carol = address(0xCA501);

    function _request(CuratorVault v, address who, uint256 shares) internal {
        vm.prank(who);
        v.requestExit(shares);
    }

    /// @dev The fee-free gap in assets, `feeHighWater - totalAssets()`: what the stayers must earn back before a fee.
    function _gapNow(CuratorVault v) internal view returns (uint256) {
        return Math.saturatingSub(v.feeHighWater(), v.totalAssets());
    }

    /// @dev Settle `loanId` and sweep, returning the fall in gross NAV.
    function _drop(CuratorVault v, uint256 loanId) internal returns (uint256 drop) {
        uint256 g = v.grossNav();
        _finalize(loanId);
        _crankAll(v);
        drop = g - v.grossNav();
    }

    // ---- the fee mark: a claim at a dip moves the gap by nothing ----

    /// @notice ACROSS A CLAIM AT A DIP, G MOVES BY THE REAL LOSS: both write-offs, and nothing for the claim itself.
    /// @notice alice requests, the first loss lands, she claims whole at the dip, a second loss follows, and an entrant may come in after it.
    /// @dev Fuzzes both losses and the entry; the claim takes its cash out of the high-water and NAV alike, so only the losses move G.
    function testFuzz_Fee_ADipClaimThenASecondLossMovesGByTheRealLoss(uint256 firstSeed, uint256 secondSeed, uint256 entrySeed) public {
        CuratorVault v = _newVault(1000);
        _lpDeposit(v, alice, 5_000e6);
        _lpDeposit(v, bob, 5_000e6);
        uint256 l1 = bound(firstSeed, 20e6, 150e6);
        uint256 l2 = bound(secondSeed, 50e6, 300e6);
        uint256 first = _open(l1);
        uint256 second = _open(l2);
        v.crank();
        _warpBy(VEST_W);
        v.crank();
        v.collectFee(); // the mark, at the price
        _request(v, alice, v.balanceOf(alice));
        uint256 g0 = _gapNow(v);
        uint256 lost = _drop(v, first);
        uint256 m = v.maxClaim(alice); // BEFORE the prank: a read is a call, and a call would eat it
        vm.prank(alice);
        assertGt(v.claimExit(m, alice, 0), 0, "PREMISE: the dip claim paid alice");
        lost += _drop(v, second);
        _waivePots(v); // both losses stay standing, and the entrant may still come in
        uint256 x = bound(entrySeed, 0, 30_000e6);
        if (x >= 1e6) _lpDeposit(v, carol, x);
        assertApproxEqAbs(_gapNow(v), g0 + lost, 10 + 4 * (v.totalSupply() / 1e18 + 1), "G moved by other than the real loss across the dip claim");
    }

    // ---- an entry keeps the gap exactly ----

    /// @notice AN ENTRY NEVER MOVES THE FEE-FREE GAP: it adds exactly its cash to the high-water and to NAV, so the curator earns back every atom.
    /// @dev Entries reach 100M USDC, so the supply is past 1e18 share-wei, where a per-share frame's rounding was worth whole atoms.
    function testFuzz_Fee_AnEntryNeverShrinksTheGap(uint256 lossSeed, uint256 depositSeed) public {
        CuratorVault v = _newVault(1000);
        _lpDeposit(v, alice, 10_000e6);
        uint256 doomed = _open(bound(lossSeed, 10e6, 300e6));
        v.crank();
        _warpBy(VEST_W);
        v.crank();
        v.collectFee(); // the mark, at the price
        _finalize(doomed);
        _waivePots(v); // the loss stays standing under the mark, and the entrant may still come in
        _crankAll(v);
        uint256 gap = _gapNow(v);
        assertGt(gap, 0, "PREMISE: the loss put the vault under its mark");
        _lpDeposit(v, carol, bound(depositSeed, 1e6, 100_000_000e6));
        assertEq(_gapNow(v), gap, "an entry moved the fee-free gap");
    }

    // ---- requestExit syncs: its sync stamps a gain that landed unsynced ----

    /// @notice A REQUEST SYNCS, SO A GAIN THAT LANDED UNSYNCED STARTS VESTING AT THE REQUEST.
    /// @notice The request's own sync is the first verb to observe the gift; half a window later half of it has vested.
    /// @dev Without that sync the next reader re-stamps the whole gain at its own time, and requests are priced at the deferred NAV for longer.
    function test_Sync_ARequestStampsAnUnsyncedGainSoItVestsFromTheRequest() public {
        CuratorVault v = _newVault(0);
        _lpDeposit(v, alice, 10_000e6);
        _lpDeposit(v, bob, 10_000e6);
        uint256 nav0 = v.totalAssets();
        uint256 gain = 400e6;
        _gift(v, gain);
        assertEq(v.totalAssets(), nav0, "PREMISE: an unsynced gain reads as wholly deferred");
        _request(v, bob, v.balanceOf(bob) / 2);
        _warpBy(uint256(VEST_W) / 2);
        assertApproxEqAbs(v.totalAssets(), nav0 + gain / 2, 2, "half a vest window after the request, half the gain had not vested");
    }
}
