// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.36;

import {CuratorVaultBase} from "./CuratorVaultBase.sol";
import {AceVault, VaultConfig} from "../../src/curator/AceVault.sol";
import {CuratorTerms, Listing} from "../../src/entities/curated/CuratorTerms.sol";
import {CuratedVaults} from "../utils/CuratedVaults.sol";
import {PocDeployConfig} from "../../src/config/Defaults.sol";
import {Math} from "@openzeppelin/contracts/utils/math/Math.sol";

/// @title CuratorVaultQueueFee
/// @notice The performance fee across exit claims: a claim's own cash is never growth, so the curator's fee must not see it.
/// @notice A claim BELOW the high-water mark hands the claimer's share of any later recovery to the stayers, and the fee charges their part past the mark.
/// @dev The high-water is stored in assets and carried per virtual share: a burn scales it by the shares left, so the gap per share stays put.
contract CuratorVaultQueueFeeTest is CuratorVaultBase {
    uint16 internal constant BPS = 5000; // the ceiling, where the leak is largest; never a zero-fee vault for a fee row
    uint256 internal constant SEED = 10_000e6;
    uint256 internal constant DOOMED = 800e6; // about four percent of a 20,000 book
    uint256 internal constant RECOVERY_BPS = 8000; // eighty percent of the drop comes back
    uint256 internal constant DUST = 4; // asset-wei: one virtual share's worth plus a wei, per claim, at par
    uint256 internal constant V = 1e6; // the vault's virtual-share offset
    address internal carol = address(0xCA201);

    function _request(AceVault v, address who, uint256 shares) internal {
        vm.prank(who);
        v.requestExit(shares);
    }

    /// @dev Claim the whole of `who`'s request at the claim's own price; every row here leaves exitable cash able to cover it.
    function _claim(AceVault v, address who) internal returns (uint256) {
        uint256 esc = _escrow(v, who); // BEFORE the prank: a read is a call, and a call would eat it
        vm.prank(who);
        return v.claimExit(esc, who, 0);
    }

    /// @dev `who`'s escrowed shares still requested.
    function _escrow(AceVault v, address who) internal view returns (uint256 shares) {
        (shares,) = vlens.requestOf(address(v), who);
    }

    /// @dev Two LPs, one doomed loan, the open's gain recognized and the mark stamped at the peak.
    function _peak(uint256 doomed) internal returns (AceVault v, uint256 loanId) {
        v = _newVault(BPS);
        _lpDeposit(v, alice, SEED);
        _lpDeposit(v, bob, SEED);
        loanId = _open(doomed);
        _crankAllTicks(v, loanId, 0);
        _warpBy(VEST_W); // recognize whatever the open realized, so the mark stamps at the peak
        v.collectFee();
        assertGt(v.feeHighWater(), 0, "PREMISE: the mark is stamped before the loss");
    }

    /// @dev One claim by `who`: the high-water before it and the cash it paid out.
    function _claimBurn(AceVault v, address who) internal returns (uint256 h, uint256 cash) {
        h = v.feeHighWater();
        cash = _claim(v, who);
    }

    /// @dev `v`'s supply plus the virtual offset: the frame the high-water is carried in.
    function _sv(AceVault v) internal view returns (uint256) {
        return v.totalSupply() + V;
    }

    /// @dev The high-water `h` over virtual supply `sv0` carried through a burn to `v`'s supply now: scaled down, never under the NAV left.
    function _carried(AceVault v, uint256 h, uint256 sv0) internal view returns (uint256) {
        return Math.max(Math.mulDiv(h, _sv(v), sv0), v.totalAssets());
    }

    // ---- the burn rule, under the mark ----

    /// @notice MEASURE: A TROUGH CLAIM BELOW THE MARK FORFEITS THE CLAIMER'S SHARE OF A LATE SALE, AND THE FEE TAKES ITS PART PAST THE STAYERS' MARK.
    /// @dev Settle a four percent loss; bob, half the supply, requests and claims whole at the trough.
    /// @dev Then eighty percent of the drop sells, after the claim, and the fee is collected.
    /// @dev The accepted consequence of the per-share high-water: the forfeit lifts the stayers' NAV per share past their own mark, and that is fee.
    function test_Measure_ATroughClaimersForfeitedRecoveryIsFeedPerShare() public {
        (AceVault v, uint256 loanId) = _peak(DOOMED);
        uint256 mark = v.feeHighWater();
        uint256 peakNav = v.totalAssets();

        _finalize(loanId);
        _crankAll(v);
        uint256 troughNav = v.totalAssets();
        uint256 drop = peakNav - troughNav;
        assertGe(drop * 100, peakNav * 3, "PREMISE: the loss is at least three percent of NAV");
        assertLe(drop * 100, peakNav * 5, "PREMISE: and at most five");
        assertLt(troughNav, mark, "PREMISE: the trough sits under the mark");

        uint256 escrow = v.balanceOf(bob);
        assertApproxEqRel(escrow * 2, v.totalSupply(), 1e15, "PREMISE: bob is half the supply");
        _request(v, bob, escrow);
        uint256 paid = _claim(v, bob);
        assertEq(_escrow(v, bob), 0, "PREMISE: the trough claim burned half the supply whole");
        assertApproxEqRel(paid * 2, troughNav, 1e15, "PREMISE: and it was paid at the trough rate");

        uint256 sold = Math.mulDiv(drop, RECOVERY_BPS, 10_000);
        uint256 before = v.totalAssets();
        assertGt(_buyPot(keeper, loanId, sold), 0, "PREMISE: the pot really sold");
        _crankAll(v);
        _warpBy(VEST_W); // the recovery is a rise: let it vest
        uint256 recovered = v.totalAssets() - before;
        assertGe(recovered * 100, drop * 75, "PREMISE: about eighty percent of the drop came back");
        assertLe(recovered * 100, drop * 85, "PREMISE: and no more than that");

        assertLt(recovered, drop, "PREMISE: an asset high-water would still sit above NAV, owing nothing");
        emit log_named_uint("NAV at the peak", peakNav);
        emit log_named_uint("the drop", drop);
        emit log_named_uint("the recovery", recovered);
        _assertTheFeeIsThePerShareExcess(v, peakNav);
    }

    /// @dev Collect, and assert the fee minted is f of the stayers' NAV past their mark, per virtual share, over their virtual shares, within dust.
    function _assertTheFeeIsThePerShareExcess(AceVault v, uint256 peakNav) internal {
        (uint256 h, uint256 a, uint256 sv) = (v.feeHighWater(), v.totalAssets(), _sv(v));
        assertGt(a, h, "PREMISE: the forfeit lifted the stayers' NAV past their carried mark");
        uint256 pastPerShare = Math.mulDiv(a - h, 1e36, sv); // the stayers' NAV past their mark, per virtual share, at 1e36
        uint256 want = Math.mulDiv(Math.mulDiv(pastPerShare, sv, 1e36), BPS, 10_000); // f of it, over their virtual shares
        uint256 held = v.balanceOf(curator);
        v.collectFee();
        uint256 feeValue = v.convertToAssets(v.balanceOf(curator) - held);
        emit log_named_uint("the stayers' NAV past their mark", a - h);
        emit log_named_uint("the fee's value (assets)", feeValue);
        emit log_named_uint("f x the per-share excess x the virtual shares", want);
        emit log_named_uint("as bps of the peak NAV", (feeValue * 10_000) / peakNav);
        assertApproxEqAbs(feeValue, want, DUST, "the fee was not f of the stayers' per-share NAV past their mark, over their shares");
    }

    /// @notice A BURN CARRIES THE HIGH-WATER PER VIRTUAL SHARE, across any loss, claim and recovery, whichever side of it the price sits.
    /// @dev The fee after the recovery is at most the fee on NAV past the carried high-water, plus dust.
    function testFuzz_Fee_ABurnScalesTheHighWaterPerVirtualShare(uint256 lossSeed, uint256 fillSeed, uint256 backSeed) public {
        uint256 doomed = bound(lossSeed, 400e6, 3_000e6); // two to fifteen percent of the book
        (AceVault v, uint256 loanId) = _peak(doomed);
        _finalize(loanId);
        _crankAll(v);
        uint256 ask = Math.mulDiv(v.balanceOf(bob), bound(fillSeed, 1, 100), 100);
        if (v.convertToAssets(ask) == 0) return;
        _claimUnderTheMark(v, ask);
        _recoverAndCollect(v, loanId, Math.mulDiv(doomed, bound(backSeed, 1_000, 15_000), 10_000));
    }

    /// @dev Bob requests `ask` in the trough and claims it; the claim must carry the high-water down per virtual share, to an atom.
    function _claimUnderTheMark(AceVault v, uint256 ask) internal {
        uint256 h0 = v.feeHighWater();
        _request(v, bob, ask);
        assertEq(v.feeHighWater(), h0, "PREMISE: under the high-water, the request moved nothing");
        uint256 sv0 = _sv(v);
        (uint256 h, uint256 cash) = _claimBurn(v, bob);
        assertGt(cash, 0, "PREMISE: the claim paid");
        assertApproxEqAbs(v.feeHighWater(), _carried(v, h, sv0), 1, "the claim did not carry the high-water per virtual share");
    }

    /// @dev Sell some inventory back, let it vest, collect: the fee is at most the fee on NAV past the standing high-water.
    function _recoverAndCollect(AceVault v, uint256 loanId, uint256 sold) internal {
        try this.buyExternal(loanId, sold) {} catch {}
        _crankAll(v);
        _warpBy(VEST_W);
        uint256 h = v.feeHighWater();
        uint256 a = v.totalAssets();
        uint256 owed = a > h ? Math.mulDiv(a - h, BPS, 10_000) : 0;
        uint256 held = v.balanceOf(curator);
        v.collectFee();
        assertGe(v.feeHighWater(), h, "a collection lowered the high-water");
        uint256 feeValue = v.convertToAssets(v.balanceOf(curator) - held);
        assertLe(feeValue, owed + DUST, "the fee charged past the growth over the lowered high-water");
    }

    /// @dev Buy inventory behind an external call, so a refused sale skips instead of ending the row.
    function buyExternal(uint256 loanId, uint256 amt) external {
        require(msg.sender == address(this), "self only");
        _buyPot(keeper, loanId, amt);
    }

    /// @notice CLAIMS THAT TAKE THE WHOLE SUPPLY carry the high-water per virtual share like any burn; the next collection stamps the residual NAV.
    /// @dev The empty vault holds a vested 1 USDC first, so the entry prices far off par and the last burn leaves a real residual, never a wei.
    function test_Fee_AWholeSupplyClaimScalesTheMarkAndTheZeroSupplyStampsNav() public {
        AceVault v = _newVault(BPS);
        _giftPart(v, 100e6, 1e6); // NAV with no live supply: the seed and virtual shares own it
        v.crank();
        _warpBy(VEST_W);
        _lpDeposit(v, alice, SEED);
        uint256 loanId = _open(DOOMED);
        _crankAllTicks(v, loanId, 0);
        _warpBy(VEST_W);
        v.collectFee();
        assertGt(v.feeHighWater(), 0, "PREMISE: a high-water stands");
        _finalize(loanId);
        _crankAll(v);
        _request(v, alice, v.balanceOf(alice));
        _request(v, curator, v.balanceOf(curator)); // the open's recognized gain minted the curator in: it leaves too
        (uint256 h, uint256 sv0) = (v.feeHighWater(), _sv(v));
        _claim(v, alice);
        (uint256 h1, uint256 sv1) = (v.feeHighWater(), _sv(v));
        assertApproxEqAbs(h1, _carried(v, h, sv0), 1, "the first burn did not carry the high-water per virtual share");
        _claim(v, curator); // the trough claims take the whole supply
        assertEq(v.totalSupply(), v.SEED_SHARES(), "PREMISE: the claims took the whole live supply");
        assertApproxEqAbs(v.feeHighWater(), _carried(v, h1, sv1), 1, "the last burn did not carry it to the virtual shares' own");
        assertGt(v.totalAssets(), 1e5, "PREMISE: the last burn left a real residual at zero supply, not a wei");
        v.collectFee();
        assertEq(v.feeHighWater(), v.totalAssets(), "and the next collection did not stamp the residual NAV at zero supply");
    }

    /// @notice A ZERO-FEE VAULT NEVER WRITES THE HIGH-WATER: every write is gated on the fee, a burn's included.
    function test_Fee_NoMarkIsRaisedBeforeOneExists() public {
        AceVault v = _newVault(0);
        _lpDeposit(v, alice, SEED);
        _lpDeposit(v, bob, SEED);
        uint256 loanId = _open(DOOMED);
        _crankAllTicks(v, loanId, 0);
        _finalize(loanId);
        _crankAll(v);
        _request(v, bob, v.balanceOf(bob));
        assertGt(_claim(v, bob), 0, "PREMISE: the trough claim paid bob");
        assertEq(v.feeHighWater(), 0, "a claim wrote a high-water on a zero-fee vault");
    }

    /// @notice A DONATION-ONLY REMAINDER CARRIES THE GAP PER SHARE: each burn carries the high-water per virtual share like any other, with no guard.
    /// @dev On one share-wei over the virtual shares that carry is under an atom in assets, so a later entrant inherits none of it.
    function test_Fee_ADonationOnlyRemainderCarriesTheGapPerShare() public {
        AceVault v = _newVault(BPS);
        _lpDeposit(v, alice, SEED);
        uint256 loanId = _open(DOOMED);
        _crankAllTicks(v, loanId, 0);
        _warpBy(VEST_W);
        v.collectFee();
        vm.prank(alice);
        v.transfer(address(v), 1); // the one share-wei nobody can redeem
        _finalize(loanId);
        _crankAll(v);
        assertLt(v.totalAssets(), v.feeHighWater(), "PREMISE: the trough sits under the high-water");
        uint256 gap = v.feeHighWater() - v.totalAssets();
        _request(v, alice, v.balanceOf(alice));
        _request(v, curator, v.balanceOf(curator)); // the curator's fee shares leave too, so only the donation stays
        (uint256 h, uint256 sv0) = (v.feeHighWater(), _sv(v));
        _claim(v, alice);
        (uint256 h1, uint256 sv1) = (v.feeHighWater(), _sv(v));
        assertApproxEqAbs(h1, _carried(v, h, sv0), 1, "the first burn did not carry the high-water per virtual share");
        _claim(v, curator); // the trough claims take the requested supply
        assertEq(v.totalSupply(), v.SEED_SHARES() + 1, "PREMISE: only the seed and the donated share-wei are left");
        assertApproxEqAbs(v.feeHighWater(), _carried(v, h1, sv1), 1, "a donation-only remainder did not carry the high-water per virtual share");
        uint256 gap2 = Math.saturatingSub(v.feeHighWater(), v.totalAssets());
        assertApproxEqAbs(gap2, Math.mulDiv(gap, _sv(v), sv0), 2, "or moved the gap per virtual share by more than the claims' rounding"); // two claims
    }

    /// @notice A CLAIM AT THE HIGH-WATER KEEPS IT AT NAV: the claim's cash leaves both, so the gap stays at zero.
    function test_Fee_AClaimAtTheHighWaterKeepsItAtNav() public {
        AceVault v = _newVault(BPS);
        _lpDeposit(v, alice, SEED);
        _lpDeposit(v, bob, SEED);
        v.collectFee();
        _request(v, bob, v.balanceOf(bob) / 2);
        uint256 h = v.feeHighWater();
        assertEq(h, v.totalAssets(), "PREMISE: the vault sits at its high-water");
        uint256 cash = _claim(v, bob);
        assertGt(cash, 0, "PREMISE: the claim paid");
        assertEq(v.feeHighWater(), h - cash, "a claim at the high-water moved it by other than its cash");
        assertEq(v.feeHighWater(), v.totalAssets(), "or left it off NAV");
    }

    /// @notice MEASURE, residual 1: a near-total exit below the high-water carries it down per virtual share, burn by burn.
    /// @notice An entrant then raises it at its own per-share price, which leaves the gap per share, and charges no fee on that cash.
    function test_Measure_ANearTotalExitScalesTheHighWaterPerShare() public {
        (AceVault v, uint256 loanId) = _peak(2_000e6); // about ten percent of the book
        uint256 mark = v.feeHighWater();
        _finalize(loanId);
        _waivePots(v); // the loss stays standing under the high-water, and the entrant below may still come in
        _crankAll(v);
        uint256 ask = Math.mulDiv(v.totalSupply(), 9, 10) - 1; // nine tenths of the supply, from both LPs
        _request(v, bob, v.balanceOf(bob));
        _request(v, alice, ask - vlens.requestedShares(address(v)));
        (uint256 h, uint256 sv0) = (v.feeHighWater(), _sv(v));
        uint256 cash = _claim(v, bob); // the claims in the ten percent trough pay at the trough
        (uint256 h1, uint256 sv1) = (v.feeHighWater(), _sv(v));
        assertApproxEqAbs(h1, _carried(v, h, sv0), 1, "the first claim did not carry the high-water per virtual share");
        cash += _claim(v, alice);
        uint256 lowered = v.feeHighWater();
        emit log_named_uint("high-water before", h);
        emit log_named_uint("cash the claims paid out", cash);
        emit log_named_uint("high-water after", lowered);
        emit log_named_uint("NAV after", v.totalAssets());
        assertEq(h, mark, "PREMISE: nothing before the claims moved the high-water");
        assertApproxEqAbs(lowered, _carried(v, h1, sv1), 1, "the near-total exit did not carry the high-water per virtual share");
        assertLt(lowered, h - cash, "PREMISE: below the mark the per-share carry takes more than the claims' cash");
        uint256 sv2 = _sv(v);
        _lpDeposit(v, carol, SEED);
        emit log_named_uint("high-water after the entrant", v.feeHighWater());
        uint256 scaled = Math.mulDiv(lowered, _sv(v), sv2, Math.Rounding.Ceil);
        assertGt(scaled, lowered + SEED, "PREMISE: below the mark the entrant's per-share leg is the larger");
        assertEq(v.feeHighWater(), scaled, "an entrant moved the high-water by other than its own per-share price");
        uint256 held = v.balanceOf(curator);
        v.collectFee();
        assertEq(v.balanceOf(curator), held, "and the next collection charged a fee on the entrant's own cash");
    }

    // ---- the fee itself across exits ----

    /// @notice THE RAIL: `MAX_PERF_FEE_BPS` stays under 100%: at 100% a zero high-water makes the fee all of NAV, and the mint divides by zero.
    function test_Fee_TheRailIsUnderOneHundredPercent() public {
        AceVault v = _newVault(0);
        assertLt(v.MAX_PERF_FEE_BPS(), 10_000, "the fee rail is at or past one hundred percent");
        VaultConfig memory cfg = _cfg(v.MAX_PERF_FEE_BPS() + 1);
        Listing[] memory l = _listing(); // BEFORE the expectation: building the row's record is a call
        vm.expectRevert(AceVault.PerfFeeOutOfBounds.selector);
        this.makeCurated(cfg, l, "Over", "cOVR"); // one external call, so the expectation binds the vault's own refusal
    }

    /// @notice A COLLECTION NEVER LOWERS THE HIGH-WATER while anyone holds a share, across rises, losses, requests and claims.
    /// @dev Only the collection's own move is judged: a burn carries it down per share by design, and an empty vault stamps it at NAV.
    function testFuzz_Fee_ACollectionNeverLowersTheHighWater(uint256 seed) public {
        AceVault v = _newVault(BPS);
        _lpDeposit(v, alice, SEED);
        _lpDeposit(v, bob, SEED);
        uint256 loanId = _open(1_000e6);
        bool settled;
        for (uint256 k; k < 12; k++) {
            uint256 r = uint256(keccak256(abi.encode(seed, k)));
            uint256 act = r % 5;
            if (act == 0) {
                _gift(v, ((r >> 8) % 500 + 100) * 1e6);
            } else if (act == 1 && !settled) {
                _finalize(loanId);
                settled = true;
            } else if (act == 2) {
                address who = (r >> 8) % 2 == 0 ? alice : bob;
                uint256 ask = (v.balanceOf(who) * ((r >> 16) % 50 + 1)) / 100;
                if (ask != 0 && v.convertToAssets(ask) != 0) _request(v, who, ask);
            } else if (act == 3) {
                _warpBy((r >> 8) % 1 days + 1);
            } else {
                address who = (r >> 8) % 2 == 0 ? alice : bob;
                uint256 m = v.maxClaim(who);
                if (m != 0 && v.previewRedeem(m) != 0) {
                    vm.prank(who);
                    v.claimExit(m, who, 0);
                }
            }
            uint256 h = v.feeHighWater();
            bool held = v.totalSupply() != 0;
            v.crank();
            if (held) assertGe(v.feeHighWater(), h, "a crank lowered the high-water");
            h = v.feeHighWater();
            held = v.totalSupply() != 0;
            v.collectFee();
            if (held) assertGe(v.feeHighWater(), h, "a collection lowered the high-water");
        }
    }

    /// @notice A CLAIM CYCLE ON A FLAT NAV CHARGES AT MOST DUST: the claim's rounding is read as growth by under a virtual share.
    function testFuzz_Fee_AClaimCycleChargesAtMostDust(uint256 aliceSeed, uint256 askSeed) public {
        AceVault v = _newVault(BPS);
        _lpDeposit(v, alice, bound(aliceSeed, 1_000e6, 100_000e6));
        _lpDeposit(v, bob, SEED);
        v.collectFee();
        uint256 ask = Math.mulDiv(v.balanceOf(bob), bound(askSeed, 1, 100), 100);
        if (v.convertToAssets(ask) == 0) return;
        _request(v, bob, ask);
        _claim(v, bob);
        uint256 held = v.balanceOf(curator);
        uint256 a = v.totalAssets();
        uint256 s = v.totalSupply();
        v.collectFee();
        uint256 fee = Math.mulDiv(v.balanceOf(curator) - held, a + 1, s + V);
        uint256 bound_ = 2 * (Math.mulDiv(BPS, 1 + Math.mulDiv(V, a, s), 10_000) + 1); // a virtual share and a wei, twice over
        assertLe(fee, bound_, "a flat claim cycle charged more than the claim's rounding");
    }

    /// @notice THE NEAR-TOTAL EXIT on a flat NAV: 99.99% of the supply claimed, and the fee charged is still within the absolute bound.
    function test_Fee_ANearTotalExitChargesAtMostDust() public {
        AceVault v = _newVault(BPS);
        _lpDeposit(v, alice, SEED);
        _lpDeposit(v, bob, SEED);
        v.collectFee();
        uint256 keep = v.totalSupply() / 10_000; // one ten-thousandth stays
        _request(v, bob, v.balanceOf(bob));
        _request(v, alice, v.balanceOf(alice) - keep);
        _claim(v, bob);
        _claim(v, alice);
        uint256 held = v.balanceOf(curator);
        uint256 a = v.totalAssets();
        uint256 s = v.totalSupply();
        assertLt(s, keep * 2, "PREMISE: nearly the whole supply was claimed");
        v.collectFee();
        uint256 fee = Math.mulDiv(v.balanceOf(curator) - held, a + 1, s + V);
        uint256 bound_ = 2 * (Math.mulDiv(BPS, 1 + Math.mulDiv(V, a, s), 10_000) + 1);
        emit log_named_uint("fee on the near-total exit", fee);
        emit log_named_uint("its absolute bound", bound_);
        assertLe(fee, bound_, "a near-total exit charged past the absolute dust bound");
    }

    /// @notice REQUESTED SHARES BEAR THE FEE ON A RISE WHILE THEY WAIT: the claim collects the fee before it prices anything.
    /// @dev A supply read before the fee mint reads LOW, so the claim would be priced onto value the curator is about to take.
    function test_Fee_RequestersPayTheFeeOnARiseWhileTheyWait() public {
        AceVault v = _newVault(BPS);
        _lpDeposit(v, alice, SEED);
        _lpDeposit(v, bob, SEED);
        v.collectFee();
        uint256 escrow = v.balanceOf(bob);
        _request(v, bob, escrow);
        _gift(v, 2_000e6); // a rise while the request stands
        v.crank(); // stamps it into the vest
        _warpBy(VEST_W); // and the vest runs out, so a fee is genuinely pending
        uint256 held = v.balanceOf(curator);
        assertGt(v.pendingFeeShares(), 0, "PREMISE: a fee is due on the rise");
        uint256 aNoFee = v.totalAssets();
        uint256 paid = _claim(v, bob);
        assertGt(v.balanceOf(curator), held, "the claim collected the fee on the rise");
        uint256 sAfterFee = v.totalSupply() + escrow; // the supply the claim priced against: post-fee, pre-burn
        assertEq(paid, Math.mulDiv(escrow, aNoFee + 1, sAfterFee + V), "the claim priced net of the fee");
    }

    // ---- an entry under the mark: the fee-free gap per virtual share, which an entry neither grows nor clears ----

    /// @dev Two LPs; a loan opened, then a gain collected, so the high-water stamps at the risen NAV; then the loan's `loss` written off.
    /// @dev The loss stays inside the gain net of its fee, so NAV sits under the high-water.
    function _underTheMark(uint256 loss) internal returns (AceVault v) {
        v = _newVault(BPS);
        _lpDeposit(v, alice, SEED);
        _lpDeposit(v, bob, SEED);
        uint256 doomed = _open(loss);
        _crankAllTicks(v, doomed, 0);
        _gift(v, 1_000e6);
        v.crank();
        _warpBy(VEST_W);
        v.collectFee(); // the high-water stamps at the risen NAV
        _finalize(doomed);
        _waivePots(v); // the loss stays standing under the high-water, and the entrant may still come in
        _crankAll(v);
        assertLt(v.totalAssets(), v.feeHighWater(), "PREMISE: the loss put the vault under its high-water");
    }

    /// @dev Assert the gap now is `gap` over virtual supply `sv0` carried to the supply now, to its 4626 rounding: an atom a side, and one per `sv0` added.
    function _assertGapPerShare(AceVault v, uint256 gap, uint256 sv0, string memory why) internal {
        (uint256 h2, uint256 a2, uint256 sv1) = (v.feeHighWater(), v.totalAssets(), _sv(v));
        assertGe(h2, a2, "the flow took the high-water under NAV");
        emit log_named_uint("the gap before the flow", gap);
        emit log_named_uint("the gap after it", h2 - a2);
        assertApproxEqAbs(h2 - a2, Math.mulDiv(gap, sv1, sv0), 2 + (sv1 > sv0 ? sv1 - sv0 : sv0 - sv1) / sv0, why);
    }

    /// @notice AN ENTRY LEAVES THE FEE-FREE GAP PER VIRTUAL SHARE: it raises the high-water at the high-water's own price, so the entrant climbs back fee-free.
    function testFuzz_Fee_AnEntryLeavesTheGapPerShare(uint256 lossSeed, uint256 depositSeed) public {
        AceVault v = _underTheMark(bound(lossSeed, 10e6, 300e6));
        (uint256 gap, uint256 sv0) = (v.feeHighWater() - v.totalAssets(), _sv(v));
        _lpDeposit(v, carol, bound(depositSeed, 1e6, 100_000e6));
        _assertGapPerShare(v, gap, sv0, "an entry moved the fee-free gap per virtual share");
        assertEq(v.pendingFeeShares(), 0, "or made a fee owing");
    }

    /// @notice A MINT UNDER THE HIGH-WATER LEAVES THE GAP PER SHARE TOO: `mint` rounds the assets it takes up, and the high-water its own price.
    function testFuzz_Fee_AMintLeavesTheGapPerShare(uint256 lossSeed, uint256 sharesSeed) public {
        AceVault v = _underTheMark(bound(lossSeed, 10e6, 300e6));
        (uint256 gap, uint256 sv0) = (v.feeHighWater() - v.totalAssets(), _sv(v));
        uint256 want = bound(sharesSeed, 1e12, 1e20); // one to a hundred thousand USDC of shares near par
        uint256 cost = v.previewMint(want);
        usdc.mint(carol, cost);
        vm.startPrank(carol);
        usdc.approve(address(v), cost);
        v.mint(want, carol);
        vm.stopPrank();
        _assertGapPerShare(v, gap, sv0, "a mint moved the fee-free gap per virtual share");
        assertEq(v.pendingFeeShares(), 0, "or made a fee owing");
    }

    /// @notice A DEPOSIT AND ITS WHOLE EXIT AT THE RATE KEEP THE GAP TO AN ATOM: the entry raises the high-water per share, the claim carries it back.
    /// @dev The mark comes back to the atom, rounded up then down; the round trip's own rounding lands on NAV, at most an atom.
    function test_Fee_ADepositRoundTripKeepsTheGapToAnAtom() public {
        AceVault v = _underTheMark(200e6);
        uint256 gap = v.feeHighWater() - v.totalAssets();
        uint256 shares = _lpDeposit(v, carol, 2 * SEED);
        _request(v, carol, shares);
        _claim(v, carol); // at the rate, under the high-water
        assertEq(_escrow(v, carol), 0, "PREMISE: carol left whole");
        emit log_named_uint("the gap before the round trip", gap);
        emit log_named_uint("the gap after it", v.feeHighWater() - v.totalAssets());
        assertApproxEqAbs(v.feeHighWater() - v.totalAssets(), gap, 1, "a deposit and its exit at the rate moved the gap past an atom");
    }
}
