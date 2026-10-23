// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.36;

import {CuratorVaultBase} from "./CuratorVaultBase.sol";
import {CuratorVault} from "../../src/curator/CuratorVault.sol";
import {Math} from "@openzeppelin/contracts/utils/math/Math.sol";
import {MarketParams} from "../../src/ace/hub/Types.sol";
import {AceFixtures} from "../utils/AceFixtures.sol";

/// @title CuratorVaultFee
/// @notice The performance fee: one high-water in assets, one NAV, and a loss earned back before any fee.
contract CuratorVaultFeeTest is CuratorVaultBase {
    uint256 internal constant DOOMED = 10e6;
    uint256 internal constant GROWTH_DRAW = 6_000e6;
    uint256 internal constant SEED = 12_020e6; // a doomed loan and two earning cycles, with twenty units over

    /// @dev One vault holding the LP's cash; every draw is a door borrow on its one gridded market.
    function _rig(uint16 bps) internal returns (CuratorVault v) {
        v = _newVault(bps);
        _lpDeposit(v, alice, SEED);
    }

    /// @dev A small loan taken to settlement: the impairment every diversion test is struck against.
    function _impair(CuratorVault v) internal returns (uint256 loanId) {
        loanId = _open(DOOMED);
        _crankAllTicks(v, loanId, 0);
        _finalize(loanId);
        _crankAll(v);
    }

    /// @dev One earning cycle: draw a lot, crank it, repay it with its fee, bank AND recognize the result.
    /// @dev The wait is load-bearing: the ladder defers recognition, and these tests are about the AMOUNT.
    function _growth(CuratorVault v) internal {
        uint256 loanId = _open(GROWTH_DRAW);
        _crankAllTicks(v, loanId, 0);
        _repay(loanId, GROWTH_DRAW * 2);
        _crankAndRecognize(v);
        v.collectFee(); // the pass that banked it could not yet see it; this is the one that charges
    }

    /// @dev The fee the next collection would strike, from the high-water standing before the call.
    function _feeValue(uint256 h, uint256 a, uint256 bps) internal pure returns (uint256) {
        if (a <= h) return 0;
        return Math.mulDiv(a - h, bps, 10_000);
    }

    /// @dev What the shares minted in this window are worth now, which is what the fee actually paid.
    function _mintedValue(CuratorVault v, uint256 sharesBefore) internal view returns (uint256) {
        uint256 fresh = v.balanceOf(curator) - sharesBefore;
        return (v.totalAssets() * fresh) / v.totalSupply();
    }

    // ---- the dilution denominator ----

    /// @dev T16: one NAV, so what the curator's new shares are worth equals the fee struck, to the wei.
    function test_Fee_DilutionDenominatorIsTotalAssets() public {
        CuratorVault v = _rig(2000);
        _growth(v); // the fee is struck on the second cycle, against the high-water the first left
        uint256 base = v.feeHighWater();
        uint256 held = v.balanceOf(curator);
        _growth(v);

        uint256 feeValue = _feeValue(base, v.totalAssets(), 2000);
        assertGt(feeValue, 0, "there was a fee to strike");
        assertApproxEqAbs(_mintedValue(v, held), feeValue, 2, "the shares minted are worth the fee, not more");
    }

    // ---- the high-water mark, which REPLACED the diversion as the loss alignment ----

    /// @dev THE RATCHET, the exact inverse of what this suite used to assert: a loss may not lower the high-water.
    /// @dev So the curator earns nothing at all until the LPs are whole again.
    /// @dev Replaces `test_Fee_BaselineRatchetsWithTheRate`, which pinned "there is no high-water mark".
    /// @dev It costs the curator strictly MORE than the diversion did: that is the point of the swap.
    function test_Fee_TheHighWaterHoldsThroughALoss() public {
        CuratorVault v = _rig(2000);
        _growth(v);
        uint256 peak = v.feeHighWater();
        assertGt(peak, 0, "PREMISE: a high-water stands before the loss");

        _impair(v);

        assertEq(v.feeHighWater(), peak, "a write-off leaves the mark EXACTLY where it was");
        assertLt(v.totalAssets(), peak, "though NAV is now under it");
        uint256 held = v.balanceOf(curator);
        v.collectFee();
        assertEq(v.balanceOf(curator), held, "so a collection under the mark mints nothing at all");
    }

    /// @dev T21 INVERTED: a recovery IS ordinary growth now, but under the mark it still pays nothing.
    /// @dev The old design routed it to the memo; the ratchet gets to the same place with no memo at all.
    /// @dev BANKS WITHOUT WAITING OUT THE WINDOW, changed when the ladder collapsed to a single rung.
    /// @dev It used to wait, and a 1.5-window span left enough deferred at +1W to keep the vault under
    /// @dev its mark; one flat window releases the lot and carries it back OVER, so the wait now stages
    /// @dev the opposite state. The premise is asserted rather than assumed so it cannot rot again.
    function test_Fee_ARecoveryUnderTheOldMarkPaysTheCuratorNothing() public {
        CuratorVault v = _rig(2000);
        uint256 loanId = _impair(v);
        uint256 mark = v.feeHighWater();
        assertGt(mark, 0, "the pre-loss mark stands, and the write-off did not move it");
        assertLt(v.totalAssets(), mark, "the vault is under water");
        uint256 held = v.balanceOf(curator);

        uint256 filled = _buyPot(keeper, loanId, 5_000e6);
        assertGt(filled, 0, "the pot really sold");
        _crankAll(v);
        assertLt(v.totalAssets(), mark, "PREMISE: still under the mark it must clear");
        v.collectFee();

        assertEq(v.balanceOf(curator), held, "a recovery under the old mark earns the curator nothing");
        assertEq(v.feeHighWater(), mark, "and the mark never moved down to meet it");
    }


    /// @dev THE PROPORTIONALITY PROPERTY, restated for the ratchet: over a whole impairment the curator
    /// @dev forgoes at least the loss, because no fee is struck until NAV clears the old high-water.
    /// @dev Replaces the four diverted-fee rows, which measured the same alignment through the memo.
    function testFuzz_Fee_NothingIsEarnedUntilTheLossIsClawedBack(uint8 cycles) public {
        CuratorVault v = _rig(5000);
        _impair(v); // its own booking crank stamps the mark, and the settling pass may not lower it
        uint256 peak = v.feeHighWater();
        assertGt(peak, 0, "the pre-loss mark stands");
        uint256 held = v.balanceOf(curator);
        assertLt(v.totalAssets(), peak, "the loss put the vault under its mark");

        uint256 rounds = 1 + (uint256(cycles) % 2); // the rig funds two earning cycles, no more
        for (uint256 i; i < rounds; i++) {
            _growth(v);
            if (v.totalAssets() <= peak) {
                assertEq(v.balanceOf(curator), held, "under the mark the curator is paid nothing, every cycle");
            }
            assertGe(v.feeHighWater(), peak, "and the mark never once ratchets down");
        }
    }

    // ---- the surviving fee surface ----

    /// @dev The fee must actually mint on REALIZED growth, else the whole mechanism is inert.
    /// @dev The second cycle's growth is measured from the high-water the first cycle's collection left.
    function test_Fee_MintsOnRealizedGrowth() public {
        CuratorVault v = _rig(2000);
        _growth(v);
        uint256 navBefore = v.totalAssets();
        uint256 held = v.balanceOf(curator);
        _growth(v);

        uint256 growth = v.totalAssets() - navBefore;
        assertGt(growth, 0, "the origination fee is realized to idle");
        assertGt(v.balanceOf(curator), held, "the curator was paid");
        assertApproxEqRel(_mintedValue(v, held), (growth * 2000) / 10000, 0.02e18, "20% of the growth");
    }

    /// @dev A zero-fee vault never mints and never stamps a mark, through a loss and a recovery alike.
    function test_Fee_ZeroBps_IsInert() public {
        CuratorVault v = _rig(0);
        _impair(v);
        uint256 supplyBefore = v.totalSupply();
        _growth(v);

        v.collectFee();
        assertEq(v.totalSupply(), supplyBefore, "nothing minted");
        assertEq(v.balanceOf(curator), 0, "the curator holds nothing");
        assertEq(v.feeHighWater(), 0, "no high-water was ever stamped");
    }


    /// @dev The first deposit stamps the high-water at its own cash, and the next collection CHARGES NOTHING.
    /// @dev MUTATION TARGET: an `H` the first deposit left at zero would bill the whole NAV at the next collection.
    /// @dev The zero-charge assertions below are the whole point: stamping alone would survive without them.
    /// @dev Replaces `test_Fee_BaselineStampedByFirstMint`, which pinned the deleted per-entry restamp.
    function test_Fee_TheFirstDepositStampsTheHighWaterAndChargesNothing() public {
        CuratorVault v = _newVault(2000);
        v.collectFee();
        assertEq(v.feeHighWater(), 0, "an empty vault stamps nothing");

        _lpDeposit(v, alice, 1_000e6);
        assertEq(v.feeHighWater(), 1_000e6, "the first deposit stamps the high-water at its cash");
        uint256 supplyAfterEntry = v.totalSupply();

        v.collectFee();
        assertEq(v.feeHighWater(), v.totalAssets(), "and the first collection leaves it at NAV");
        assertEq(v.balanceOf(curator), 0, "and charges nothing: NAV has not grown past the deposit that stamped it");
        assertEq(v.totalSupply(), supplyAfterEntry, "so not one share was minted to pay a fee on the whole NAV");

        _lpDeposit(v, bob, 1_000e6);
        assertEq(v.balanceOf(curator), 0, "and a pro-rata entry mints the curator nothing either");
    }

    // ---- a full wind-down restamps the high-water at the NAV left (code review on the forfeit fix) ----

    uint256 internal constant NEXT_IN = 10_000e6; // the first money into a vault every holder has left
    address internal donor = address(0xD0D0);

    /// @dev Every holder out through a claim after two charged cycles, the curator's fee shares included.
    /// @dev The last claim is the sole holder's, which floors through the virtual shares and leaves a residual.
    function _windDown(CuratorVault v) internal {
        _growth(v);
        _growth(v);
        uint256 lp = v.balanceOf(alice);
        uint256 fee = v.balanceOf(curator);
        assertGt(fee, 0, "PREMISE: the curator holds fee shares, so it is a holder that leaves too");
        _requestThenClaim(v, lp, fee);
        assertEq(v.totalSupply(), 0, "PREMISE: every share left through a claim");
    }

    /// @dev Alice and the curator each request, then each claims the whole request: every share they held leaves by a claim.
    function _requestThenClaim(CuratorVault v, uint256 lp, uint256 fee) internal {
        vm.prank(alice);
        v.requestExit(lp);
        vm.prank(curator);
        v.requestExit(fee);
        vm.prank(alice);
        v.claimExit(lp, alice, 0);
        vm.prank(curator);
        v.claimExit(fee, curator, 0);
    }

    /// @dev Pay `amount` into the vault's counted NAV from a market the donor runs on the vault's asset, then let it vest.
    function _donate(CuratorVault v, uint256 amount) internal {
        MarketParams memory p = AceFixtures.marketParams(v.asset(), address(collateral));
        p.lender = donor;
        bytes32 gift = ace.createMarket(p);
        _lendDirectIn(donor, gift, 1_000e6);
        vm.prank(donor);
        ace.withdraw(gift, amount, address(v), 0);
        v.crank(); // the sync that stamps the rise into the vest
        _warpBy(VEST_W);
    }

    /// @dev A fresh entrant into a vault with no supply, then the fee the next collection would charge it.
    function _assertTheNextDepositorIsNotCharged(CuratorVault v) internal {
        uint256 residual = v.totalAssets();
        uint256 stale = v.feeHighWater();
        uint256 shares = _lpDeposit(v, bob, NEXT_IN);
        uint256 a = v.totalAssets();
        uint256 s = v.totalSupply();
        uint256 pend = v.pendingFeeShares();
        emit log_named_uint("residual NAV the entrant met (assets)", residual);
        emit log_named_uint("high-water it met", stale);
        emit log_named_uint("rate after the entry", (a * 1e18) / s);
        emit log_named_uint("entrant worth net of the pending fee", Math.mulDiv(shares, a + 1, s + pend + 1e6));
        emit log_named_uint("pending fee shares", pend);
        assertEq(pend, 0, "the entrant's own principal is charged against the high-water of a vault that emptied");
    }

    /// @notice A full wind-down leaves a residual; the next depositor must not pay the fee on its own cash.
    /// @dev Zero supply stamps the high-water at the NAV left, so nothing at zero supply is ever billed as growth.
    function test_WindDown_TheNextDepositorPaysNoFeeOnOwnPrincipal() public {
        CuratorVault v = _rig(2000);
        _windDown(v);
        assertGt(v.totalAssets(), 0, "PREMISE: the last exit floored through the virtual shares and left a residual");
        _assertTheNextDepositorIsNotCharged(v);
    }

    /// @notice The same with the residual DONATED: a few atoms into an emptied vault must not set a fee on the next principal.
    function test_WindDown_ADonationIntoTheEmptyVaultIsNotChargedToTheNextDepositor() public {
        CuratorVault v = _newVault(2000);
        _lpDeposit(v, alice, NEXT_IN);
        _requestAndClaim(v, alice, v.balanceOf(alice));
        assertEq(v.totalSupply(), 0, "PREMISE: the only holder left through a claim");
        _donate(v, 5);
        assertGt(v.totalAssets(), 0, "PREMISE: the donation is counted and vested");
        _assertTheNextDepositorIsNotCharged(v);
    }

    /// @notice A DONATED SHARE-WEI DOES NOT KILL THE NEXT COHORT'S FEE: the supply never reaches zero, so the high-water is never restamped.
    /// @notice A per-share mark restamped at the dust remainder's rate sat far past par, and the next cohort inherited it.
    /// @dev In assets the high-water carries the dust's value only, and the next cohort adds its cash to it, so its growth is charged.
    function test_WindDown_ADonatedShareDoesNotKillTheNextCohortsFee() public {
        CuratorVault v = _rig(2000);
        _growth(v);
        _growth(v);
        vm.prank(alice);
        v.transfer(address(v), 1); // one share-wei nobody can redeem: the supply can never reach zero again
        _requestThenClaim(v, v.balanceOf(alice), v.balanceOf(curator));
        assertEq(v.totalSupply(), 1, "PREMISE: only the donated share-wei is left");
        _warpBy(VEST_W);
        v.collectFee(); // the restamp at the dust remainder's rate
        emit log_named_uint("the high-water the dust left", v.feeHighWater());
        _lpDeposit(v, bob, NEXT_IN);
        uint256 held = v.balanceOf(curator);
        _gift(v, NEXT_IN / 100); // the next cohort's book grows one percent
        v.crank();
        _warpBy(VEST_W);
        v.collectFee();
        emit log_named_uint("the fee paid on the growth", _mintedValue(v, held));
        assertApproxEqRel(_mintedValue(v, held), (NEXT_IN / 100) * 2000 / 10_000, 0.05e18, "the next cohort's growth paid no fee");
    }

    /// @dev I7: the fee and the crank are flat in the position set, because neither walks it.
    function test_I7_CollectFeeAndCrankAreFlatAcrossHoldings() public {
        (uint256 feeFew, uint256 crankFew) = _measureFlat(9);
        (uint256 feeMany, uint256 crankMany) = _measureFlat(120);
        emit log_named_uint("collectFee gas at 9 positions", feeFew);
        emit log_named_uint("collectFee gas at 120 positions", feeMany);
        emit log_named_uint("crank gas at 9 positions", crankFew);
        emit log_named_uint("crank gas at 120 positions", crankMany);
        assertApproxEqRel(feeMany, feeFew, 0.1e18, "the fee path walks NO position at all, so holdings are free");
        assertApproxEqRel(crankMany, crankFew, 0.1e18, "and the crank never walks a position at all");
    }

    /// @dev Build exactly `n` positions, one door borrow each, then time a collection and a crank.
    function _measureFlat(uint256 n) internal returns (uint256 feeGas, uint256 crankGas) {
        CuratorVault v = _newVault(2000);
        _lpDeposit(v, alice, (n + 2) * 100e6);
        for (uint256 i; i < n; i++) {
            _crank(v, _open(100e6), T2, 0);
        }
        assertEq(_carriedClasses(v), n, "every draw is its own position");

        uint256 g0 = gasleft();
        v.collectFee();
        feeGas = g0 - gasleft();

        uint256 g1 = gasleft();
        v.crank();
        crankGas = g1 - gasleft();
    }
}
