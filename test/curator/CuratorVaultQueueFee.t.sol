// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.36;

import {CuratorVaultBase} from "./CuratorVaultBase.sol";
import {CuratorVault, Listing} from "../../src/curator/CuratorVault.sol";
import {AceVault, VaultConfig} from "../../src/curator/AceVault.sol";
import {PocDeployConfig} from "../../src/config/Defaults.sol";
import {Math} from "@openzeppelin/contracts/utils/math/Math.sol";

/// @title CuratorVaultQueueFee
/// @notice The performance fee across exit claims: a transfer is not growth, so the curator's fee must not see it.
/// @notice A claim BELOW the high-water mark hands the claimer's share of any later recovery to the stayers; the fee must not charge it.
/// @dev The high-water is in assets: every burn takes the cash it pays out of it, so the fee-free gap stays put, either side of it.
contract CuratorVaultQueueFeeTest is CuratorVaultBase {
    uint16 internal constant BPS = 5000; // the ceiling, where the leak is largest; never a zero-fee vault for a fee row
    uint256 internal constant SEED = 10_000e6;
    uint256 internal constant DOOMED = 800e6; // about four percent of a 20,000 book
    uint256 internal constant RECOVERY_BPS = 8000; // eighty percent of the drop comes back
    uint256 internal constant DUST = 4; // asset-wei: one virtual share's worth plus a wei, per claim, at par
    uint256 internal constant V = 1e6; // the vault's virtual-share offset
    address internal carol = address(0xCA201);

    function _request(CuratorVault v, address who, uint256 shares) internal {
        vm.prank(who);
        v.requestExit(shares);
    }

    /// @dev Claim the whole of `who`'s request at the claim's own price; every row here leaves exitable cash able to cover it.
    function _claim(CuratorVault v, address who) internal returns (uint256) {
        uint256 esc = _escrow(v, who); // BEFORE the prank: a read is a call, and a call would eat it
        vm.prank(who);
        return v.claimExit(esc, who, 0);
    }

    /// @dev `who`'s escrowed shares still requested.
    function _escrow(CuratorVault v, address who) internal view returns (uint256 shares) {
        (shares,) = v.requestOf(who);
    }

    /// @dev Two LPs, one doomed loan, the open's gain recognized and the mark stamped at the peak.
    function _peak(uint256 doomed) internal returns (CuratorVault v, uint256 loanId) {
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
    function _claimBurn(CuratorVault v, address who) internal returns (uint256 h, uint256 cash) {
        h = v.feeHighWater();
        cash = _claim(v, who);
    }

    // ---- the burn rule, under the mark ----

    /// @notice A TROUGH CLAIM BELOW THE MARK CHARGES NO FEE ON THE LATE SALE: the burned shares' part of it went to the stayers.
    /// @dev Settle a four percent loss; bob, half the supply, requests and claims whole at the trough.
    /// @dev Then eighty percent of the drop sells, after the claim, and the fee is collected.
    /// @dev Unfixed, the stayers cross the old mark early and the curator is paid about 0.6% of NAV for a transfer.
    /// @dev With the burn taking only its cash out of the high-water, the stayers sit below it after the recovery and nothing is owed.
    function test_Fee_ATroughClaimBelowTheMarkChargesNoFeeOnTheLateSale() public {
        (CuratorVault v, uint256 loanId) = _peak(DOOMED);
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

        uint256 held = v.balanceOf(curator);
        v.collectFee();
        uint256 minted = v.balanceOf(curator) - held;
        uint256 feeValue = v.convertToAssets(minted);
        emit log_named_uint("NAV at the peak", peakNav);
        emit log_named_uint("the drop", drop);
        emit log_named_uint("the recovery", recovered);
        emit log_named_uint("fee shares minted on the recovery", minted);
        emit log_named_uint("their value (assets)", feeValue);
        emit log_named_uint("as bps of the peak NAV", (feeValue * 10_000) / peakNav);
        assertLe(feeValue, DUST, "the curator was paid a fee on the claimer's forfeited share of the recovery");
    }

    /// @notice A BURN LOWERS THE HIGH-WATER BY THE CASH IT PAID, across any loss, claim and recovery, whichever side of it the price sits.
    /// @dev The fee after the recovery is at most the fee on NAV past the lowered high-water, plus dust.
    function testFuzz_Fee_ABurnLowersTheHighWaterByTheCashPaid(uint256 lossSeed, uint256 fillSeed, uint256 backSeed) public {
        uint256 doomed = bound(lossSeed, 400e6, 3_000e6); // two to fifteen percent of the book
        (CuratorVault v, uint256 loanId) = _peak(doomed);
        _finalize(loanId);
        _crankAll(v);
        uint256 ask = Math.mulDiv(v.balanceOf(bob), bound(fillSeed, 1, 100), 100);
        if (v.convertToAssets(ask) == 0) return;
        _claimUnderTheMark(v, ask);
        _recoverAndCollect(v, loanId, Math.mulDiv(doomed, bound(backSeed, 1_000, 15_000), 10_000));
    }

    /// @dev Bob requests `ask` in the trough and claims it; the claim must lower the high-water by exactly the cash it paid.
    function _claimUnderTheMark(CuratorVault v, uint256 ask) internal {
        uint256 h0 = v.feeHighWater();
        _request(v, bob, ask);
        assertEq(v.feeHighWater(), h0, "PREMISE: under the high-water, the request moved nothing");
        (uint256 h, uint256 cash) = _claimBurn(v, bob);
        assertGt(cash, 0, "PREMISE: the claim paid");
        assertEq(v.feeHighWater(), Math.saturatingSub(h, cash), "the claim did not lower the high-water by exactly its cash");
    }

    /// @dev Sell some inventory back, let it vest, collect: the fee is at most the fee on NAV past the standing high-water.
    function _recoverAndCollect(CuratorVault v, uint256 loanId, uint256 sold) internal {
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

    /// @notice CLAIMS THAT TAKE THE WHOLE SUPPLY take their cash out of the high-water like any burn; the next collection stamps the residual NAV.
    /// @dev The empty vault holds a vested 1 USDC first, so the entry prices far off par and the last burn leaves a real residual, never a wei.
    function test_Fee_AWholeSupplyClaimTakesItsCashAndTheZeroSupplyStampsNav() public {
        CuratorVault v = _newVault(BPS);
        _giftPart(v, 100e6, 1e6); // NAV with no supply: the virtual shares own it
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
        uint256 h = v.feeHighWater();
        uint256 cash = _claim(v, alice) + _claim(v, curator); // the trough claims take the whole supply
        assertEq(v.totalSupply(), 0, "PREMISE: the claims took the whole supply");
        assertEq(v.feeHighWater(), Math.saturatingSub(h, cash), "burns of the whole supply did not take their cash out of the high-water");
        assertGt(v.totalAssets(), 1e5, "PREMISE: the last burn left a real residual at zero supply, not a wei");
        v.collectFee();
        assertEq(v.feeHighWater(), v.totalAssets(), "and the next collection did not stamp the residual NAV at zero supply");
    }

    /// @notice A ZERO-FEE VAULT NEVER WRITES THE HIGH-WATER: every write is gated on the fee, a burn's included.
    function test_Fee_NoMarkIsRaisedBeforeOneExists() public {
        CuratorVault v = _newVault(0);
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

    /// @notice A DONATION-ONLY REMAINDER CARRIES THE GAP: the burn takes its cash out of the high-water like any other, with no guard.
    /// @dev Nobody can recover anything for the donated share-wei, so the gap it carries waits for a later entrant, as a free holder's does.
    function test_Fee_ADonationOnlyRemainderCarriesTheGap() public {
        CuratorVault v = _newVault(BPS);
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
        uint256 h = v.feeHighWater();
        uint256 cash = _claim(v, alice) + _claim(v, curator); // the trough claims take the requested supply
        assertEq(v.totalSupply(), 1, "PREMISE: only the donated share-wei is left");
        assertEq(v.feeHighWater(), h - cash, "a donation-only remainder did not take the burns' cash out of the high-water");
        uint256 gap2 = Math.saturatingSub(v.feeHighWater(), v.totalAssets());
        assertApproxEqAbs(gap2, gap, 6, "or moved the gap by more than the claims' rounding"); // two claims
    }

    /// @notice A CLAIM AT THE HIGH-WATER KEEPS IT AT NAV: the claim's cash leaves both, so the gap stays at zero.
    function test_Fee_AClaimAtTheHighWaterKeepsItAtNav() public {
        CuratorVault v = _newVault(BPS);
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

    /// @notice MEASURE, residual 1: a near-total exit below the high-water lowers it by exactly its claims' cash.
    /// @notice An entrant then adds exactly its own cash, which leaves the fee-free gap in assets, and charges no fee on that cash.
    function test_Measure_ANearTotalExitLowersTheHighWaterByItsCash() public {
        (CuratorVault v, uint256 loanId) = _peak(2_000e6); // about ten percent of the book
        uint256 mark = v.feeHighWater();
        _finalize(loanId);
        _waivePots(v); // the loss stays standing under the high-water, and the entrant below may still come in
        _crankAll(v);
        uint256 ask = Math.mulDiv(v.totalSupply(), 9, 10) - 1; // nine tenths of the supply, from both LPs
        _request(v, bob, v.balanceOf(bob));
        _request(v, alice, ask - v.requestedShares());
        uint256 h = v.feeHighWater();
        uint256 cash = _claim(v, bob) + _claim(v, alice); // the claims in the ten percent trough pay at the trough
        uint256 lowered = v.feeHighWater();
        emit log_named_uint("high-water before", h);
        emit log_named_uint("cash the claims paid out", cash);
        emit log_named_uint("high-water after", lowered);
        emit log_named_uint("NAV after", v.totalAssets());
        assertEq(h, mark, "PREMISE: nothing before the claims moved the high-water");
        assertEq(lowered, h - cash, "the near-total exit did not lower the high-water by exactly its cash");
        _lpDeposit(v, carol, SEED);
        emit log_named_uint("high-water after the entrant", v.feeHighWater());
        assertEq(v.feeHighWater(), lowered + SEED, "an entrant moved the high-water by other than its own cash");
        uint256 held = v.balanceOf(curator);
        v.collectFee();
        assertEq(v.balanceOf(curator), held, "and the next collection charged a fee on the entrant's own cash");
    }

    // ---- the fee itself across exits ----

    /// @notice THE RAIL: `MAX_PERF_FEE_BPS` stays under 100%: at 100% a zero high-water makes the fee all of NAV, and the mint divides by zero.
    function test_Fee_TheRailIsUnderOneHundredPercent() public {
        CuratorVault v = _newVault(0);
        assertLt(v.MAX_PERF_FEE_BPS(), 10_000, "the fee rail is at or past one hundred percent");
        VaultConfig memory cfg = _cfg(v.MAX_PERF_FEE_BPS() + 1);
        Listing[] memory l = _listing(); // BEFORE the expectation: building the row's record is a call
        vm.expectRevert(AceVault.PerfFeeOutOfBounds.selector);
        new CuratorVault(cfg, RIG_MIN_DEBT, PocDeployConfig.MIN_COVERAGE_WAD, RIG_TIMELOCK, l, "Over", "cOVR");
    }

    /// @notice A COLLECTION NEVER LOWERS THE HIGH-WATER while anyone holds a share, across rises, losses, requests and claims.
    /// @dev Only the collection's own move is judged: a burn lowers it by its cash by design, and an empty vault stamps it at NAV.
    function testFuzz_Fee_ACollectionNeverLowersTheHighWater(uint256 seed) public {
        CuratorVault v = _newVault(BPS);
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
        CuratorVault v = _newVault(BPS);
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
        CuratorVault v = _newVault(BPS);
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
        CuratorVault v = _newVault(BPS);
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

    // ---- an entry under the mark: the fee-free gap is assets, and an entry neither grows nor clears it ----

    /// @dev Two LPs; a loan opened, then a gain collected, so the high-water stamps at the risen NAV; then the loan's `loss` written off.
    /// @dev The loss stays inside the gain net of its fee, so NAV sits under the high-water.
    function _underTheMark(uint256 loss) internal returns (CuratorVault v) {
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

    /// @notice AN ENTRY LEAVES THE FEE-FREE GAP IN ASSETS EXACTLY: `H - NAV` is what the curator must earn back, and a deposit adds to both.
    /// @notice The per-share mark this replaced let an entrant inherit it, growing that gap by the entrant's share, which compounded into an overflow.
    function testFuzz_Fee_AnEntryLeavesTheGapInAssets(uint256 lossSeed, uint256 depositSeed) public {
        CuratorVault v = _underTheMark(bound(lossSeed, 10e6, 300e6));
        uint256 gap = v.feeHighWater() - v.totalAssets();
        _lpDeposit(v, carol, bound(depositSeed, 1e6, 100_000e6));
        (uint256 h2, uint256 a2) = (v.feeHighWater(), v.totalAssets());
        assertGe(h2, a2, "an entry took the high-water under NAV");
        emit log_named_uint("the gap before the entry", gap);
        emit log_named_uint("the gap after it", h2 - a2);
        assertEq(h2 - a2, gap, "an entry moved the fee-free gap");
        assertEq(v.pendingFeeShares(), 0, "or made a fee owing");
    }

    /// @notice A MINT UNDER THE HIGH-WATER LEAVES THE GAP IN ASSETS TOO: `mint` rounds the assets it takes up, and the high-water takes exactly those.
    function testFuzz_Fee_AMintLeavesTheGapInAssets(uint256 lossSeed, uint256 sharesSeed) public {
        CuratorVault v = _underTheMark(bound(lossSeed, 10e6, 300e6));
        uint256 gap = v.feeHighWater() - v.totalAssets();
        uint256 want = bound(sharesSeed, 1e12, 1e20); // one to a hundred thousand USDC of shares near par
        uint256 cost = v.previewMint(want);
        usdc.mint(carol, cost);
        vm.startPrank(carol);
        usdc.approve(address(v), cost);
        v.mint(want, carol);
        vm.stopPrank();
        (uint256 h2, uint256 a2) = (v.feeHighWater(), v.totalAssets());
        assertGe(h2, a2, "a mint took the high-water under NAV");
        assertEq(h2 - a2, gap, "a mint moved the fee-free gap");
        assertEq(v.pendingFeeShares(), 0, "or made a fee owing");
    }

    /// @notice A DEPOSIT AND ITS WHOLE EXIT AT THE RATE KEEP THE GAP EXACTLY: the entry adds its cash to the high-water, the claim takes its cash out.
    function test_Fee_ADepositRoundTripKeepsTheGapExactly() public {
        CuratorVault v = _underTheMark(200e6);
        uint256 gap = v.feeHighWater() - v.totalAssets();
        uint256 shares = _lpDeposit(v, carol, 2 * SEED);
        _request(v, carol, shares);
        _claim(v, carol); // at the rate, under the high-water
        assertEq(_escrow(v, carol), 0, "PREMISE: carol left whole");
        emit log_named_uint("the gap before the round trip", gap);
        emit log_named_uint("the gap after it", v.feeHighWater() - v.totalAssets());
        assertEq(v.feeHighWater() - v.totalAssets(), gap, "a deposit and its exit at the rate moved the gap");
    }
}
