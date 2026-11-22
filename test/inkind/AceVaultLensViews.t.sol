// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.36;

import {Checkpoints} from "@openzeppelin/contracts/utils/structs/Checkpoints.sol";
import {AceVault} from "../../src/curator/AceVault.sol";
import {CapListing, ProductConfig} from "../../src/curator/libraries/AceVaultCaps.sol";
import {VaultConfig} from "../../src/curator/libraries/AceVaultFlows.sol";
import {AceVaultInKind} from "../../src/curator/libraries/AceVaultInKind.sol";
import {InKindVaults} from "../utils/InKindVaults.sol";
import {IInKindTerms, IInKindVault} from "./InKindSurface.sol";
import {InKindRig} from "./InKindRig.sol";

/// @dev An AceVault that reads its tracker through the library's own layout, the figures the lens must reproduce from raw words.
contract TrackerReadVault is AceVault {
    constructor(VaultConfig memory c, ProductConfig memory p, CapListing[] memory caps, string memory n, string memory s) AceVault(c, p, caps, n, s) {}

    function trackedOfLayout(address h) external view returns (uint256) {
        return Checkpoints.latest(AceVaultInKind.inKindLayout().bal[h]);
    }

    function trackedSupplyOf() external view returns (uint256) {
        return AceVaultInKind.inKindLayout().trackedSupply;
    }

    function tokensOf() external view returns (address[] memory) {
        return AceVaultInKind.inKindLayout().paidTokens;
    }
}

/// @title AceVaultLensViews
/// @notice A REGRESSION PIN on the lens's raw offsets: each tracker view equals what the library's own layout holds, and `claimable` equals what `claim` pays.
/// @notice `claimable` is pinned in the three states a claim meets: a fold landed, a fold waiting from an earlier block, and the collect's own block.
contract AceVaultLensViewsTest is InKindRig {
    TrackerReadVault internal tv;

    function setUp() public override {
        super.setUp();
        (address t, address predicted) = InKindVaults.prepare(_cfg(0), _ik(), _listings(), NAME);
        tv = new TrackerReadVault(_cfg(0), InKindVaults.product(t, _ik()), InKindVaults.caps(predicted, _listings(), total), NAME, SYMBOL);
        (vault, terms) = (IInKindVault(address(tv)), IInKindTerms(t));
        _lp(alice, LP_CASH);
    }

    function _assertHolder(address h, string memory who) internal view {
        assertEq(_tracked(h), tv.trackedOfLayout(h), string.concat(who, ": the tracked balance"));
    }

    function _assertSupplyAndTokens() internal view {
        assertEq(_trackedSupply(), tv.trackedSupplyOf(), "trackedSupply");
        address[] memory a = lens.rewardTokens(address(vault));
        address[] memory b = tv.tokensOf();
        assertEq(a.length, b.length, "rewardTokens: the count");
        for (uint256 i; i < a.length; i++) {
            assertEq(a[i], b[i], "rewardTokens: each slot");
        }
    }

    /// @notice Every holder's tracked balance and the tracked supply match the library's layout, with an escrow and a gift to the vault standing.
    function test_theTrackerViewsMatchTheLayout() public {
        _warpBy(MIN_TENOR);
        uint256 sb = _lp(bob, 1_000e6);
        vm.prank(alice);
        vault.transfer(bob, sb / 3);
        _warpBy(1 days);
        _lpFor(carol, bob, 500e6);
        vm.prank(bob);
        vault.transfer(dave, sb / 5);
        vm.prank(alice);
        vault.requestExit(sb / 7);
        vm.prank(dave);
        vault.transfer(address(vault), sb / 11);
        _assertHolder(alice, "alice");
        _assertHolder(bob, "bob");
        _assertHolder(dave, "dave");
        _assertSupplyAndTokens();
        assertEq(_tracked(alice), vault.balanceOf(alice) + sb / 7, "premise: alice's escrow is tracked as hers");
        assertGt(_tracked(dave), 0, "premise: dave holds tracked shares");
        assertEq(
            _trackedSupply(), vault.totalSupply() - sb / 11 - vault.SEED_SHARES(), "premise: the gift to the vault left the tracked supply, as the seed is"
        );
    }

    /// @notice A fold already landed: `claimable` is what `claim` pays, for a holder whose checkpoint is behind it.
    function test_claimableIsWhatClaimPaysAfterAFold() public {
        _warpBy(MIN_TENOR);
        _defaultAndCollect(_open(address(tokA)));
        _nextBlock();
        _lp(bob, 1_000e6); // a later block's share move closes the batch
        uint256 view_ = _claimable(alice, address(tokA));
        assertGt(view_, 0, "premise: alice is owed a credit her checkpoint has not settled");
        assertEq(_claim(alice, address(tokA)), view_, "the claim pays exactly the view");
        assertEq(_claimable(alice, address(tokA)), 0, "and the view reads zero after it");
    }

    /// @notice A fold waiting from an earlier block: the view projects it, and the claim, folding first, pays the same.
    function test_claimableIsWhatClaimPaysWithAFoldWaiting() public {
        _warpBy(MIN_TENOR);
        _defaultAndCollect(_open(address(tokA)));
        _nextBlock();
        uint256 view_ = _claimable(alice, address(tokA));
        assertGt(view_, 0, "premise: the view projects the waiting fold");
        assertEq(_claim(alice, address(tokA)), view_, "the claim folds and pays exactly the view");
    }

    /// @notice The collect's own block: the view shows none of the pot, and a claim in that block pays none.
    function test_claimableIsWhatClaimPaysInTheCollectsBlock() public {
        _warpBy(MIN_TENOR);
        _defaultAndCollect(_open(address(tokA)));
        assertEq(_claimable(alice, address(tokA)), 0, "the collect's block shows none of it");
        assertEq(_claim(alice, address(tokA)), 0, "and pays none of it");
        _nextBlock();
        assertGt(_claimable(alice, address(tokA)), 0, "CONTROL: from the next block it is owed");
    }
}
