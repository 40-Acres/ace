// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.36;

import {CuratorVaultBase} from "./CuratorVaultBase.sol";
import {CuratorVault} from "../../src/curator/CuratorVault.sol";
import {Math} from "@openzeppelin/contracts/utils/math/Math.sol";

/// @title CuratorVaultFeeHighWater
/// @notice The fee threshold held in ASSETS: an entry adds its cash, an exit or a claim takes the cash paid, a collection lifts it to NAV.
/// @notice So every flow keeps the fee-free gap `H - NAV` exactly, with no per-share frame to round in or concentrate.
/// @dev WRITTEN RED against the per-share mark it replaced, each row naming the reason it failed there.
contract CuratorVaultFeeHighWaterTest is CuratorVaultBase {
    uint16 internal constant BPS = 1000;
    uint256 internal constant V_OFF = 1e6; // the vault's virtual-share offset
    address internal carol = address(0xCA601);

    /// @dev The fee high-water in assets.
    function _hw(CuratorVault v) internal view returns (uint256) {
        return v.feeHighWater();
    }

    /// @dev The fee-free gap in assets.
    function _gap(CuratorVault v) internal view returns (uint256) {
        return Math.saturatingSub(_hw(v), v.totalAssets());
    }

    function _request(CuratorVault v, address who, uint256 shares) internal {
        vm.prank(who);
        v.requestExit(shares);
    }

    /// @dev Claim `who`'s whole request, returning the cash paid.
    function _claimAll(CuratorVault v, address who) internal returns (uint256) {
        (uint256 esc,) = v.requestOf(who);
        vm.prank(who);
        return v.claimExit(esc, who, 0);
    }

    /// @notice AN ENTRY MOVES THE HIGH-WATER BY EXACTLY ITS CASH, on `deposit` and on `mint`, at a supply past 1e19 share-wei.
    /// @dev RED on the per-share mark: the blend's two ceilings add up to `2 * s / 1e18` atoms.
    function testFuzz_Fee_AnEntryMovesTheHighWaterByExactlyItsCash(uint256 xSeed, uint256 sharesSeed) public {
        CuratorVault v = _newVault(BPS);
        _lpDeposit(v, alice, 12_000_000e6);
        v.collectFee(); // at NAV, a no-op: the first deposit already set the high-water to its cash
        uint256 h = _hw(v);
        uint256 x = bound(xSeed, 1e6, 1_000_000e6);
        _lpDeposit(v, carol, x);
        assertEq(_hw(v), h + x, "a deposit moved the high-water by other than its cash");
        h = _hw(v);
        uint256 want = bound(sharesSeed, 1e12, 1e20);
        uint256 cost = v.previewMint(want);
        usdc.mint(carol, cost);
        vm.startPrank(carol);
        usdc.approve(address(v), cost);
        uint256 paid = v.mint(want, carol);
        vm.stopPrank();
        assertEq(_hw(v), h + paid, "a mint moved the high-water by other than the assets it took");
    }

    /// @notice A CLAIM ABOVE PAR LOWERS THE HIGH-WATER BY EXACTLY ITS CASH: a 1 USDC book gifted to about 100x par, then a claim.
    /// @dev RED on the per-share mark: it falls by the true-frame rate times the shares, about `paid * V / s` past the cash.
    function test_Fee_AClaimAboveParLowersTheHighWaterByExactlyItsCash() public {
        CuratorVault v = _newVault(BPS);
        _lpDeposit(v, alice, 1e6);
        _gift(v, 99e6);
        v.crank();
        _warpBy(VEST_W);
        v.collectFee(); // the high-water at NAV, about 100x par
        _request(v, alice, v.balanceOf(alice) / 2);
        uint256 h = _hw(v);
        uint256 paid = _claimAll(v, alice);
        assertGt(paid, 0, "PREMISE: the claim paid");
        assertEq(_hw(v), h - paid, "a claim moved the high-water by other than its cash");
    }

    /// @notice THE FIRST DEPOSIT STAMPS THE HIGH-WATER: a gain after it is charged at the first collection.
    /// @dev The gain is synced by a crank while it is all unvested, so that crank charges nothing and it has vested when the first collection reads it.
    /// @dev RED on the per-share mark: its first collection only stamps, so the gain since the first deposit is never charged.
    function test_Fee_TheFirstDepositStampsTheHighWater() public {
        CuratorVault v = _newVault(BPS);
        _lpDeposit(v, alice, 10_000e6);
        _gift(v, 1_000e6);
        v.crank(); // syncs the gain into the vest; the fee it collects reads only the vested part, which has not moved
        _warpBy(VEST_W);
        uint256 held = v.balanceOf(curator);
        v.collectFee();
        uint256 minted = v.convertToAssets(v.balanceOf(curator) - held);
        emit log_named_uint("the fee on a 1,000 gain since the first deposit", minted);
        assertApproxEqAbs(minted, Math.mulDiv(1_000e6, BPS, 10_000), 2, "the gain since the first deposit was not charged");
    }

    /// @notice A STAY OF ONLY DONATED SHARES CARRIES THE GAP: an exit leaving one donated share-wei keeps G where it was.
    /// @dev RED on the per-share mark: with only donations staying it skips the raise, so the gap collapses with the supply.
    function test_Fee_ADonatedOnlyStayCarriesTheGap() public {
        CuratorVault v = _newVault(5000);
        _lpDeposit(v, alice, 10_000e6);
        uint256 loanId = _open(800e6);
        _crankAllTicks(v, loanId, 0);
        _warpBy(VEST_W);
        v.collectFee();
        vm.prank(alice);
        v.transfer(address(v), 1); // the one share-wei nobody can redeem
        _finalize(loanId);
        _crankAll(v);
        uint256 g0 = _gap(v);
        assertGt(g0, 0, "PREMISE: the loss opened a gap");
        _request(v, alice, v.balanceOf(alice));
        _request(v, curator, v.balanceOf(curator)); // the open's recognized gain minted the curator in: it leaves too
        _claimAll(v, alice); // each claim at the trough, the requested supply leaving whole
        _claimAll(v, curator);
        assertEq(v.totalSupply(), 1, "PREMISE: only the donated share-wei is left");
        emit log_named_uint("the gap before the exit", g0);
        emit log_named_uint("the gap after it", _gap(v));
        assertApproxEqAbs(_gap(v), g0, 10, "an exit leaving only donated shares moved the gap");
    }

    /// @notice A LAST-OUT RELEASE WITH A DONATED REMAINDER charges the fee on the pile at that claim, and only once: the next collection mints nothing.
    /// @dev The release runs before the claim's collection, so the pile it frees is growth there, charged past the high-water.
    /// @dev The burn then takes the claim's cash out of the high-water, so the next collection finds NAV at it.
    function test_Fee_AReleaseToTheLastOutChargesTheFeeOnThePileOnce() public {
        CuratorVault v = _newVault(BPS);
        _lpDeposit(v, alice, 10_000e6);
        uint256 loanId = _open(800e6);
        _crankAllTicks(v, loanId, 0);
        _finalize(loanId);
        _crankAll(v); // the write-off: NAV under the first deposit's high-water
        _gift(v, 2_000e6); // a recovery past the loss, deferred
        v.crank();
        assertGt(v.unvested(), 0, "PREMISE: a pile is standing");
        assertGt(v.grossNav(), v.feeHighWater(), "PREMISE: released, the pile lifts NAV past the high-water");
        assertEq(v.balanceOf(curator), 0, "PREMISE: the curator holds nothing, so the request is every free share");
        vm.prank(alice);
        v.transfer(address(v), 1); // the one share-wei nobody can redeem
        _request(v, alice, v.balanceOf(alice));
        assertGt(v.unvested(), 0, "PREMISE: the request released nothing");
        uint256 fee = Math.mulDiv(v.grossNav() - v.feeHighWater(), BPS, 10_000); // the fee on the rise past the high-water, the pile included
        _claimAll(v, alice); // every share escrow or donation: the release, then the claim
        assertEq(v.unvested(), 0, "PREMISE: the claim released the pile");
        uint256 feeShares = v.balanceOf(curator);
        assertEq(v.totalSupply(), 1 + feeShares, "PREMISE: the releasing claim paid alice out whole, leaving the donated share-wei and the fee");
        uint256 charged = v.convertToAssets(feeShares);
        emit log_named_uint("the fee on the rise past the high-water", fee);
        emit log_named_uint("what the releasing claim's fee shares are worth", charged);
        assertApproxEqAbs(charged, fee, 2, "the releasing claim did not charge the fee on the pile");
        v.collectFee();
        assertEq(v.balanceOf(curator), feeShares, "the next collection charged the pile's fee a second time");
    }

    /// @notice A DEPOSIT AND ITS WHOLE EXIT LEAVE THE HIGH-WATER AT THE RESIDUAL NAV: the entry added its cash and the burn took its pay.
    /// @notice The empty vault holds a vested 1 USDC first, so the entry prices far off par and the exit leaves the virtual shares' slice.
    /// @dev So the zero-supply stamp finds it already at a real NAV, never a wei, and the next entrant is billed for nothing.
    function test_Fee_ADepositAndItsWholeExitLeaveTheHighWaterAtTheResidualNav() public {
        CuratorVault v = _newVault(BPS);
        _giftPart(v, 100e6, 1e6); // NAV with no supply: the virtual shares own it
        v.crank();
        _warpBy(VEST_W);
        uint256 nav0 = v.totalAssets();
        assertGt(nav0, 0, "PREMISE: the empty vault holds a vested NAV");
        uint256 x = 10_000e6;
        _lpDeposit(v, alice, x);
        assertEq(_hw(v), nav0 + x, "the entry's zero-supply stamp did not set the high-water at the NAV it found, before its cash");
        _request(v, alice, v.balanceOf(alice));
        uint256 paid = _claimAll(v, alice); // the cash the claim moved, floored by a wei off par
        assertEq(v.totalSupply(), 0, "PREMISE: the exit took the whole supply");
        assertGt(v.totalAssets(), 1e5, "PREMISE: the exit left a real residual at zero supply, not a wei");
        assertEq(_hw(v), nav0 + x - paid, "the whole exit did not take its pay out of the high-water");
        assertEq(_hw(v), v.totalAssets(), "and left it off the residual NAV");
        v.collectFee();
        assertEq(_hw(v), v.totalAssets(), "the zero-supply stamp moved a high-water already at NAV");
        _lpDeposit(v, carol, x);
        assertEq(v.pendingFeeShares(), 0, "the next entrant was billed for the residual");
    }
}
