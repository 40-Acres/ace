// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.36;

import {CuratorVaultBase} from "./CuratorVaultBase.sol";
import {AceVault} from "../../src/vault/AceVault.sol";
import {Math} from "@openzeppelin/contracts/utils/math/Math.sol";

/// @title CuratorVaultQueueHardening
/// @notice The exit request's hardening rows: each pins a property a named mutant used to survive.
/// @dev Expected values are derived from the vault's public reads and the rule the row names, never from the function under test.
contract CuratorVaultQueueHardeningTest is CuratorVaultBase {
    address internal carol = address(0xCA501);

    function _request(AceVault v, address who, uint256 shares) internal {
        vm.prank(who);
        v.requestExit(shares);
    }

    /// @dev The fee-free gap in assets, `feeHighWater - totalAssets()`: per virtual share, what the stayers must earn back before a fee.
    function _gapNow(AceVault v) internal view returns (uint256) {
        return Math.saturatingSub(v.feeHighWater(), v.totalAssets());
    }

    /// @dev `v`'s supply plus the virtual offset: the frame the high-water is carried in.
    function _sv(AceVault v) internal view returns (uint256) {
        return v.totalSupply() + 1e6;
    }

    /// @dev Settle `loanId` and sweep, returning the fall in gross NAV.
    function _drop(AceVault v, uint256 loanId) internal returns (uint256 drop) {
        uint256 g = v.grossNav();
        _finalize(loanId);
        _crankAll(v);
        drop = g - v.grossNav();
    }

    // ---- the fee mark: a claim at a dip moves the gap per share by nothing ----

    /// @notice ACROSS A CLAIM AT A DIP, G PER SHARE MOVES BY THE REAL LOSS: both write-offs, each over the supply it landed on, and nothing for the claim.
    /// @notice alice requests, the first loss lands, she claims whole at the dip, a second loss follows, and an entrant may come in after it.
    /// @dev Fuzzes both losses and the entry; the claim and the entry carry G per virtual share, so only the losses move G per share.
    function testFuzz_Fee_ADipClaimThenASecondLossMovesGByTheRealLoss(uint256 firstSeed, uint256 secondSeed, uint256 entrySeed) public {
        AceVault v = _newVault(1000);
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
        uint256 g = _gapNow(v);
        g += _drop(v, first); // the first loss lands on the whole supply
        uint256 sv0 = _sv(v);
        uint256 m = v.maxClaim(alice); // BEFORE the prank: a read is a call, and a call would eat it
        vm.prank(alice);
        assertGt(v.claimExit(m, alice, 0), 0, "PREMISE: the dip claim paid alice");
        uint256 sv1 = _sv(v);
        g = Math.mulDiv(g, sv1, sv0); // the claim carries G per share
        g += _drop(v, second); // the second loss lands on the supply left
        _waivePots(v); // both losses stay standing, and the entrant may still come in
        uint256 x = bound(entrySeed, 0, 30_000e6);
        if (x >= 1e6) _lpDeposit(v, carol, x);
        g = Math.mulDiv(g, _sv(v), sv1); // and the entry carries it per share
        assertApproxEqAbs(_gapNow(v), g, 10 + 4 * (_sv(v) / sv1 + 1), "G per share moved by other than the real loss across the dip claim");
    }

    // ---- an entry never shrinks the gap ----

    /// @notice AN ENTRY NEVER SHRINKS THE FEE-FREE GAP: it raises the high-water at its own per-share price, rounded up, so the gap per share holds.
    /// @notice So the curator earns back every atom of it, at the entrant's cost as well as the incumbents'.
    /// @dev Entries reach 100M USDC, so the supply is past 1e18 share-wei, where the entry's round-up is what keeps the gap from shrinking.
    function testFuzz_Fee_AnEntryNeverShrinksTheGap(uint256 lossSeed, uint256 depositSeed) public {
        AceVault v = _newVault(1000);
        _lpDeposit(v, alice, 10_000e6);
        uint256 doomed = _open(bound(lossSeed, 10e6, 300e6));
        v.crank();
        _warpBy(VEST_W);
        v.crank();
        v.collectFee(); // the mark, at the price
        _finalize(doomed);
        _waivePots(v); // the loss stays standing under the mark, and the entrant may still come in
        _crankAll(v);
        (uint256 gap, uint256 sv0) = (_gapNow(v), _sv(v));
        assertGt(gap, 0, "PREMISE: the loss put the vault under its mark");
        _lpDeposit(v, carol, bound(depositSeed, 1e6, 100_000_000e6));
        uint256 sv1 = _sv(v);
        assertGe(_gapNow(v), gap, "an entry shrank the fee-free gap");
        assertApproxEqAbs(_gapNow(v), Math.mulDiv(gap, sv1, sv0), 2 + (sv1 - sv0) / sv0, "an entry moved the fee-free gap per virtual share");
    }

    // ---- requestExit syncs: its sync stamps a gain that landed unsynced ----

    /// @notice A REQUEST SYNCS, SO A GAIN THAT LANDED UNSYNCED STARTS VESTING AT THE REQUEST.
    /// @notice The request's own sync is the first verb to observe the gift; half a window later half of it has vested.
    /// @dev Without that sync the next reader re-stamps the whole gain at its own time, and requests are priced at the deferred NAV for longer.
    function test_Sync_ARequestStampsAnUnsyncedGainSoItVestsFromTheRequest() public {
        AceVault v = _newVault(0);
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
