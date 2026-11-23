// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.36;

import {AceVault} from "../../src/vault/AceVault.sol";
import {CapListing, ProductConfig} from "../../src/vault/libraries/AceVaultCaps.sol";
import {AceVaultFlows, VaultConfig, VaultLayout} from "../../src/vault/libraries/AceVaultFlows.sol";
import {InKindVaults} from "../utils/InKindVaults.sol";
import {IInKindTerms, IInKindVault} from "./InKindSurface.sol";
import {InKindRig} from "./InKindRig.sol";

/// @notice A test-only leaf adding the one base path the share hook does not foresee: a third party burning a holder's escrow.
/// @dev It adds a function and overrides nothing; nothing in `AceVault` does this, so the leaf shows what the tracker does if a base path ever did.
contract InKindKeeperBurnHarness is AceVault {
    constructor(VaultConfig memory cfg, ProductConfig memory pc, CapListing[] memory caps) AceVault(cfg, pc, caps, "Harness", "H") {}

    /// @notice Burn `shares` of `holder`'s request on their behalf, the request ledger debited as `claimExit` debits it.
    function burnEscrowFor(address holder, uint256 shares) external {
        VaultLayout storage $ = AceVaultFlows.vaultLayout();
        $.requests[holder].shares -= shares;
        $.requestedShares -= shares;
        _burn(address(this), shares);
    }
}

/// @title InKindRequests
/// @notice Moves to and from the vault's own address are ignored by the tracker, so escrowed shares keep earning until claimed.
/// @notice The `claimExit` burn is charged to the requester the base names in its context word, never to the vault's own address.
contract InKindRequestsTest is InKindRig {
    /// @dev Alice holds `v` shares from one entry and `p` from a later one, and bob a stake of his own.
    function _setUpHolders() internal returns (uint256 v, uint256 p) {
        v = _lp(alice, 500_000e6);
        _lp(bob, 100_000e6);
        _warpBy(MIN_TENOR);
        p = _lp(alice, 200_000e6);
    }

    /// @notice An exit request escrows shares on the vault and moves nothing in the tracker.
    function test_requestExitLeavesTheTrackerUnchanged() public {
        (uint256 v, uint256 p) = _setUpHolders();
        uint256 before = _tracked(alice);
        uint256 ts = _trackedSupply();
        vm.prank(alice);
        vault.requestExit((v + p) / 2);
        assertEq(_tracked(alice), before, "request: alice's tracked balance is unmoved");
        assertEq(_trackedSupply(), ts, "the tracked supply is unmoved");
        assertEq(_tracked(address(vault)), 0, "the vault's own address tracks nothing");
        assertGe(_tracked(alice), vault.balanceOf(alice) + (v + p) / 2, "the tracker covers the balance plus the request");
    }

    /// @notice A cancel hands the escrow back and moves nothing in the tracker.
    function test_cancelExitLeavesTheTrackerUnchanged() public {
        (uint256 v,) = _setUpHolders();
        vm.prank(alice);
        vault.requestExit(v);
        uint256 before = _tracked(alice);
        vm.prank(alice);
        vault.cancelExit(v / 2);
        assertEq(_tracked(alice), before, "cancel: alice's tracked balance is unmoved");
    }

    /// @notice A lapse, by a stranger, hands the escrow back and moves nothing in the tracker.
    function test_lapseExitLeavesTheTrackerUnchanged() public {
        (uint256 v,) = _setUpHolders();
        vm.prank(alice);
        vault.requestExit(v);
        _warpBy(30 days);
        _lp(alice, 1_000e6);
        uint256 before = _tracked(alice);
        vm.prank(stranger);
        vault.lapseExit(alice);
        assertEq(_tracked(alice), before, "lapse: alice's tracked balance is unmoved");
    }

    /// @notice Requested shares keep earning: a holder who asked to leave is still credited until the claim burns them.
    function test_requestedSharesKeepEarningUntilClaimed() public {
        uint256 v = _lp(alice, LP_CASH);
        _warpBy(MIN_TENOR);
        uint256 loanId = _open(address(tokA));
        vm.prank(alice);
        vault.requestExit(v);
        assertEq(vault.balanceOf(alice), 0, "premise: every share is escrowed");
        uint256 pot = _defaultAndCollect(loanId);
        _nextBlock();
        assertApproxEqAbs(_claimable(alice, address(tokA)), pot, 1, "the requester was credited the whole pot");
    }

    /// @notice The claim's burn is charged to the requester: their tracked shares fall by exactly what was burned, and nobody else's move.
    function test_claimExitIsChargedToTheRequester() public {
        uint256 v = _lp(alice, 500_000e6);
        uint256 b = _lp(bob, 100_000e6);
        _warpBy(MIN_TENOR);
        vm.prank(alice);
        vault.requestExit(v / 2);
        uint256 ts = _trackedSupply();
        vm.prank(alice);
        vault.claimExit(v / 2, alice, 0);
        assertEq(_tracked(alice), v - v / 2, "the requester's tracked shares fell by the claim");
        assertEq(_trackedSupply(), ts - v / 2, "the tracked supply fell with it");
        assertEq(_tracked(bob), b, "a bystander's tracked shares did not move");
        assertEq(_tracked(address(vault)), 0, "and the vault's own address was never charged");
    }

    // ---- whose tracker an escrow burn debits ----

    /// @dev EXACT, not `>=`: no row below gifts shares to the vault, so every tracked share is a balance or a request.
    function _assertExact(address h, string memory who) internal view {
        (uint256 r,) = lens.requestOf(address(vault), h);
        assertEq(_tracked(h), vault.balanceOf(h) + r, string.concat(who, ": tracked is exactly the balance plus the request"));
    }

    /// @dev The tracked supply is the holders' tracked balances, and they sum to the supply less the seed when nothing was gifted to the vault.
    function _assertTotals() internal view {
        address[4] memory hs = [alice, bob, carol, curator];
        uint256 tracked;
        for (uint256 i; i < hs.length; i++) {
            tracked += _tracked(hs[i]);
        }
        assertEq(_trackedSupply(), tracked, "the tracked supply is exactly the holders' tracked balances");
        assertEq(tracked, vault.totalSupply() - vault.SEED_SHARES(), "the tracked shares sum to the supply less the genesis seed");
    }

    /// @notice Two requesters each burn only their own escrow: a claim leaves the other requester's tracked balance and request whole.
    /// @dev Bob holds shares from three entries, one a gift by another payer, so a burn charged to him moves his tracked balance.
    function test_claimExit_eachRequestersBurnIsChargedToThemAlone() public {
        uint256 av = _lp(alice, 300_000e6);
        uint256 bv = _lp(bob, 200_000e6);
        _warpBy(MIN_TENOR);
        uint256 ap = _lp(alice, 50_000e6);
        _warpBy(1 days);
        uint256 bg = _lpFor(carol, bob, 40_000e6);
        _warpBy(1 days);
        _lp(bob, 30_000e6);
        vm.prank(alice);
        vault.requestExit(ap + av / 2);
        vm.prank(bob);
        vault.requestExit(bg + bv / 2);

        uint256 b0 = _tracked(bob);
        (uint256 br0,) = lens.requestOf(address(vault), bob);
        uint256 ts0 = _trackedSupply();
        vm.prank(alice);
        vault.claimExit(ap + av / 4, alice, 0);
        assertEq(_tracked(bob), b0, "bob, after alice's claim: his tracked balance is whole");
        (uint256 br1,) = lens.requestOf(address(vault), bob);
        assertEq(br1, br0, "bob's request is whole");
        uint256 a1 = _tracked(alice);
        assertEq(a1, av + ap - (ap + av / 4), "alice's tracked balance fell by exactly her claim");
        assertEq(_trackedSupply(), ts0 - (ap + av / 4), "the tracked supply fell by her claim alone");
        _assertExact(alice, "alice");
        _assertExact(bob, "bob");
        _assertExact(carol, "carol");
        _assertTotals();

        vm.prank(bob);
        vault.claimExit(bg + bv / 4, bob, 0);
        assertEq(_tracked(alice), a1, "alice, after bob's claim: her tracked balance is whole");
        _assertExact(alice, "alice");
        _assertExact(bob, "bob");
        _assertTotals();
    }

    /// @notice Only the requester's own claim burns its escrow: a stranger's claim, the cranks, a collect, the drain and a lapse burn none of it.
    /// @dev With no fee the supply only falls by a burn, so any of these verbs turning into a keeper claim or a drain sweep reads here as a fall.
    function test_escrow_noVerbButTheRequestersOwnClaimBurnsIt() public {
        uint256 av = _lp(alice, 500_000e6);
        _lp(bob, 300_000e6);
        _warpBy(MIN_TENOR);
        uint256 loanId = _open(address(tokA));
        vm.prank(alice);
        vault.requestExit(av / 2);
        uint256 supply = vault.totalSupply();
        uint256 escrow = vault.balanceOf(address(vault));
        assertEq(escrow, av / 2 + vault.SEED_SHARES(), "premise: the vault holds alice's request and the genesis seed");

        vm.prank(stranger);
        vm.expectRevert(AceVault.OverRequest.selector);
        vault.claimExit(1, stranger, 0);
        vm.startPrank(stranger);
        vault.crank();
        vault.collectFee();
        vm.stopPrank();
        _defaultAndCollect(loanId);
        _nextBlock();
        _claim(bob, address(tokA));
        vm.prank(guardian);
        vault.setDrain(true);
        vm.prank(stranger);
        vault.crank();
        assertEq(vault.totalSupply(), supply, "no verb but a claim burned a share");
        assertEq(vault.balanceOf(address(vault)), escrow, "the escrow is whole");
        _assertExact(alice, "alice, escrow standing");

        _warpBy(30 days);
        vm.prank(stranger);
        vault.lapseExit(alice);
        assertEq(vault.totalSupply(), supply, "a lapse hands the escrow back, it burns none of it");
        assertEq(vault.balanceOf(alice), av, "every share is alice's again");
        _assertExact(alice, "alice, after the lapse");
        _assertTotals();
    }

    /// @notice DETECTION CONTROL: a burn of alice's escrow that no base verb names leaves her phantom tracked shares, which only an EXACT bound sees.
    /// @dev The hook charges an escrow burn to the holder the base's context word names; this leaf's path sets none, so nobody is charged.
    function test_escrow_aBurnByAnotherCallerIsCaughtOnlyByTheExactBound() public {
        (address t, address predicted) = InKindVaults.prepare(_cfg(0), _ik(), _listings(), NAME);
        InKindKeeperBurnHarness h = new InKindKeeperBurnHarness(_cfg(0), InKindVaults.product(t, _ik()), InKindVaults.caps(predicted, _listings(), total));
        assertEq(address(h), predicted, "premise: the leaf landed where its terms name");
        (vault, terms) = (IInKindVault(address(h)), IInKindTerms(t));
        uint256 av = _lp(alice, 500_000e6);
        _lp(bob, 300_000e6);
        _warpBy(MIN_TENOR);
        vm.prank(alice);
        vault.requestExit(av / 2);
        uint256 ts = _trackedSupply();
        vm.prank(keeper);
        h.burnEscrowFor(alice, av / 4);

        (uint256 r,) = lens.requestOf(address(vault), alice);
        assertEq(r, av / 2 - av / 4, "premise: the base debited alice's request");
        assertGe(_tracked(alice), vault.balanceOf(alice) + r, "the `>=` bound still passes");
        assertEq(_tracked(alice) - (vault.balanceOf(alice) + r), av / 4, "but alice keeps exactly the burned shares as phantoms");
        assertEq(_trackedSupply(), ts, "which still count in the tracked supply and earn every later pot");
        assertEq(_tracked(keeper), 0, "and with no context set, no other holder was charged");
    }
}
