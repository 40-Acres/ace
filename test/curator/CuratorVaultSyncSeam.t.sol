// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.36;

import {Math} from "@openzeppelin/contracts/utils/math/Math.sol";
import {CuratorVaultBase} from "./CuratorVaultBase.sol";
import {AceVault, VaultConfig} from "../../src/curator/AceVault.sol";
import {CuratorVault, Listing} from "../../src/curator/CuratorVault.sol";
import {AceLens} from "../../src/ace/lens/AceLens.sol";
import {Ace} from "../../src/ace/hub/Ace.sol";
import {PriceFrame} from "../utils/PriceFrame.sol";

/// @notice THE NAIVE ITEM-4 OVERRIDE the lending review rejected, kept here purely to MEASURE F1.
/// @notice It mirrors the entry pair's shape: the pending fee added to the exit preview's denominator.
/// @dev The claim's `_release` runs BEFORE its `_collectFeeAt`, so a quote read ahead of the claim prices neither the pile nor the fee on it.
/// @dev Only `previewRedeem` is overridden: one path is enough to price the loss the last LP takes.
contract NaiveExitPreviewVault is CuratorVault {
    constructor(VaultConfig memory cfg, Listing[] memory l) CuratorVault(cfg, 10e6, 1.4e18, 1 days, l, "Naive", "cNAIV") {}

    function previewRedeem(uint256 shares) public view override returns (uint256) {
        uint256 s = totalSupply() + pendingFeeShares() + 1e6;
        return Math.mulDiv(shares, totalAssets() + 1, s, Math.Rounding.Floor);
    }
}

/// @title CuratorVaultSyncSeam
/// @notice THE SEAM THIS CLOSES: `totalAssets()` used to report a number the next `_sync()` would not produce.
/// @notice The old form was `min(g, m) - u`; what a sync leaves is `min(g, m - u)`, and a FALL splits them.
/// @notice A fall past the standing pile must leave the vault exitable and enterable: impaired, never frozen.
/// @dev THE HEADLINE LAW is `test_Sync_IsANoOp...`: a sync must not move `totalAssets()` by a wei.
/// @dev It is exact and unconditional, and it alone kills the `min(g,m)-u` mutant.
contract CuratorVaultSyncSeamTest is CuratorVaultBase {
    uint256 internal constant SEED = 10_000e6;
    uint256 internal constant DRAW = 6_000e6;
    uint256 internal constant ENTRY = 1_000e6;
    uint256 internal constant WANT = 1_000e6 * 1e6; // the same size in shares, at the virtual offset
    uint16 internal constant FEE = 2000; // never _newVault(0) on a fee row: that habit hid the exit gap

    function setUp() public override {
        super.setUp();
        record.setMinPrice(T2);
    }

    // ---- fixtures ----

    /// @dev A clean close nobody has synced yet: gross is above the mark and the pile has not seen it.
    /// @dev Lifted from `CuratorVaultSurface.t.sol` so this suite reads on its own.
    function _pendingRise(CuratorVault v) internal returns (uint256 loanId) {
        _lpDeposit(v, alice, 2 * SEED);
        loanId = _open(DRAW);
        _crank(v, loanId, T2, 0);
        _warpBy(30 days);
        _repay(loanId, lens.loan(loanId).debt);
    }

    /// @dev A deferred pile from an earlier arrival, then an unsynced settlement big enough to burn it.
    function _pendingFallUnderAPile(CuratorVault v) internal {
        _pendingFallOf(v, DRAW);
    }

    /// @dev The same fall at a chosen size, so an entry row can take a shallow fall that still burns past the pile.
    function _pendingFallOf(CuratorVault v, uint256 draw) internal {
        _pendingRise(v);
        _crankAll(v);
        assertGt(v.unvested(), 0, "fixture: a pile is standing");
        assertGt(draw, v.unvested(), "fixture: the fall burns past the pile");
        uint256 doomed = _open(draw);
        _crankByLoan(v, doomed);
        _finalize(doomed);
    }

    uint256 internal constant SHALLOW_DRAW = 800e6; // about four percent of the book

    /// @dev A pile standing, a fee genuinely PENDING, and an unsynced fall, all at once.
    /// @dev The fee is pending because half the pile matured with no verb in between to collect it.
    /// @dev DRIVEN OFF THE MOCKED HUB because a real settlement is far too big to hold this state: a
    /// @dev write-off drops NAV under the fee mark, the fee term goes to zero, and the row tests half.
    function _feePendingUnderAFall(uint16 feeBps) internal returns (CuratorVault v) {
        v = _mockedVault(feeBps);
        _lpDeposit(v, alice, SEED);
        _setHubQuote(2_000e6);
        v.collectFee(); // stamps the pile and the fee mark together, at a NAV of exactly SEED
        _warpBy(VEST_W / 2); // half the pile matures, which is what leaves a fee owing
        _setHubQuote(1_800e6); // a 200e6 fall, well under the 1_000e6 of pile still standing
        assertGt(v.unvested(), 0, "fixture: a pile is still standing under the fall");
        assertGt(v.pendingFeeShares(), 0, "fixture: a fee is genuinely outstanding at the quote");
    }

    /// @dev A fee pending with NO unsynced move at all, so a red row here is the FEE gap and nothing else.
    function _feePendingAtRest(CuratorVault v) internal {
        _pendingRise(v);
        _crankAll(v);
        _warpBy(VEST_W); // the pile matures, which is a NAV rise no verb has collected
        assertEq(v.unvested(), 0, "fixture: nothing deferred, so the sync has nothing left to do");
        assertEq(v.totalAssets(), v.grossNav(), "fixture: the mark is at gross, so the seam is shut here");
        assertGt(v.pendingFeeShares(), 0, "fixture: a fee is genuinely outstanding at the quote");
    }

    /// @dev A pile standing, then a NAV fall PAST it, driven off the mocked hub read.
    /// @dev An ordinary write-off reaches this state, so the freeze the next two rows guard is live and still reachable.
    function _fallPastThePile(CuratorVault v) internal {
        _lpDeposit(v, alice, SEED);
        _setHubQuote(2 * SEED);
        v.collectFee(); // stamps a pile larger than everything the vault still holds after the fall
        _warpBy(VEST_W / 4);
        assertGt(v.unvested(), v.idle(), "fixture: the pile stands above what survives the fall");
        _setHubQuote(0); // the write-off: the market's whole value is gone at once
    }

    /// @dev A SOLE holder, a deferral standing, everything in idle, the curator holding no share.
    /// @dev Built off a LOSS then a RECOVERY: net NAV sits under the fee mark and gross above it, so no fee mints before the exit.
    /// @dev The releasing claim's own collection then charges the rise past the mark, which its rows assert.
    function _lastOutWithADeferralStanding(CuratorVault v) internal {
        _lpDeposit(v, alice, SEED);
        uint256 loanId = _open(DRAW);
        _crank(v, loanId, T2, 0);
        _finalize(loanId);
        _crankAll(v); // the write-off lands and burns the origination pile with it
        _warpBy(3 * uint256(VEST_W));
        _buyPot(bob, loanId, 40_000e6); // a recovery, which is a rise nobody has recognized
        _crankAll(v); // banks it into idle AND defers it in one sync

        assertEq(v.balanceOf(curator), 0, "fixture: the ratchet held, so alice really is the whole supply");
        assertEq(v.totalSupply(), v.balanceOf(alice), "fixture: one holder, so the exit below is the last");
        /// @dev The crank brought every unit the hub owed home, so the balance is the whole book and can serve a FULL exit.
        assertGe(v.idle(), v.grossNav(), "fixture: the balance covers the whole book, so a full exit can be served");
    }

    /// @dev A vault whose hub read is MOCKED, so a row drives gross NAV to any figure.
    /// @dev `grossNav` reads the hub's `lenderAssets` for the asset with no market list, so the mock fires on every vault.
    /// @dev Mocks are CLEARED first: `vm.mockCall` matches on selector alone, so a quote left standing
    /// @dev from an earlier vault would answer this build's own reads.
    function _mockedVault(uint16 feeBps) internal returns (CuratorVault v) {
        vm.clearMockedCalls();
        v = _deploy(_cfg(feeBps), "Seam", "cSEAM");
    }

    /// @dev Point the hub read at a fixed answer; gross becomes idle plus this, at any sign and magnitude.
    /// @dev The mocked figure IS the whole non-idle half of NAV.
    function _setHubQuote(uint256 q) internal {
        vm.mockCall(address(ace), abi.encodeWithSelector(Ace.lenderAssets.selector), abi.encode(q));
    }

    /// @dev A mocked vault holding a deferral, then moved to `to` with NOBODY having synced it.
    /// @dev `to` is free: below `up` it is a fall, above it a rise, and idle keeps NAV off zero either way.
    function _mockedSeam(uint16 feeBps, uint256 up, uint256 to) internal returns (CuratorVault v) {
        v = _mockedVault(feeBps);
        _lpDeposit(v, alice, SEED);
        _setHubQuote(up);
        v.collectFee(); // stamps `up` as deferral; NAV is still the deposit, which the fee high-water already holds
        _warpBy(VEST_W / 4); // partial maturity, so a fee is genuinely pending
        _setHubQuote(to);
    }

    // ---- rows 1-2: the freeze a fall past the pile must not cause, sequenced first because it is the severe one ----

    /// @dev The freeze as an LP meets it. BROKEN: `_exit` reverts `ZeroAssets()` for a whole vest window.
    /// @dev A write-off is the doorway: the pile it was struck against must not outlive the value and read NAV as zero.
    function test_Fall_AnLpCanStillExitAfterAFallPastThePile() public {
        CuratorVault v = _mockedVault(0);
        _fallPastThePile(v);

        uint256 sh = v.balanceOf(alice) / 8;
        uint256 before = usdc.balanceOf(alice);
        uint256 paid = _requestAndClaim(v, alice, sh); // a request, then the claim
        assertGt(paid, 0, "an LP is still paid for their shares after a fall past the standing pile");
        assertEq(usdc.balanceOf(alice) - before, paid, "and the cash really moved");
    }

    /// @dev The other half of the freeze. BROKEN: `_requireEntryOpen` reverts `EndOfLife()`.
    /// @dev It guards the same regression as the row above.
    function test_Fall_TheVaultStillTakesCapitalAfterAFallPastThePile() public {
        CuratorVault v = _mockedVault(0);
        _fallPastThePile(v);

        uint256 minted = _lpDeposit(v, bob, ENTRY);
        assertGt(minted, 0, "the vault still admits capital: it is impaired, not spent");
    }

    // ---- the headline law: a sync must not move `totalAssets()` ----

    /// @dev THE ONE INVARIANT THE WHOLE CHANGE IS. `collectFee()` is the cheapest permissionless sync.
    /// @dev BROKEN ON A FALL by the size of the fall: the view reads `g - u`, the sync leaves `m - u`.
    function test_Sync_IsANoOpOnTotalAssetsOnAnUnsyncedFall() public {
        CuratorVault v = _newVault(0);
        _pendingFallUnderAPile(v);
        uint256 a = v.totalAssets();
        v.collectFee();
        assertEq(v.totalAssets(), a, "a sync must leave the number the view already reported");
    }

    /// @dev The same law on a rise, where the closed form agrees to within the stamp's CEIL wei.
    /// @dev It is EQUALITY here too: the fix replays the write, so there is no wei to lose.
    function test_Sync_IsANoOpOnTotalAssetsOnAnUnsyncedRise() public {
        CuratorVault v = _newVault(0);
        _pendingRise(v);
        uint256 a = v.totalAssets();
        v.collectFee();
        assertEq(v.totalAssets(), a, "a sync must leave the number the view already reported");
    }

    /// @dev The same law over any move of either sign, driven off a mocked hub read.
    /// @dev Unconditional: `grossNav()` is untouched by `_sync`, so nothing external can excuse a delta.
    function testFuzz_Sync_IsANoOpOnTotalAssetsAtAnyMoveAndSign(uint256 up, uint256 to, uint16 feeBps) public {
        up = bound(up, 1e6, 100_000e6);
        to = bound(to, 0, 2 * (SEED + up));
        CuratorVault v = _mockedSeam(uint16(bound(feeBps, 0, 5000)), up, to);

        uint256 a = v.totalAssets();
        v.collectFee();
        assertEq(v.totalAssets(), a, "a sync must leave the number the view already reported");
    }

    // ---- rows 6-9: the four preview directions across the seam ----

    /// @dev THE PROMOTED REPRO. `previewDeposit` over-quoted by ~0.16% on a fall with a pile standing.
    /// @dev EIP-4626: the deposit quote is an UPPER bound on the mint and the mint quote a LOWER bound.
    /// @dev A shallow fall, which still burns past the pile.
    function test_Preview_TheEntryPairHoldsAcrossAnUnsyncedFall() public {
        CuratorVault a = _newVault(0);
        _pendingFallOf(a, SHALLOW_DRAW);
        _waivePots(a); // the pot stays unsold and the fall unsynced, and the entrant may still come in
        uint256 promised = a.previewDeposit(ENTRY);
        assertGe(_lpDeposit(a, bob, ENTRY), promised, "previewDeposit is an upper bound on the mint");

        CuratorVault b = _newVault(0);
        _pendingFallOf(b, SHALLOW_DRAW);
        _waivePots(b);
        uint256 quoted = b.previewMint(WANT);
        usdc.mint(bob, 2 * quoted);
        vm.startPrank(bob);
        usdc.approve(address(b), 2 * quoted);
        assertLe(b.mint(WANT, bob), quoted, "previewMint is a lower bound on the pull");
        vm.stopPrank();
    }

    /// @dev The entry pair on a rise. GUARD: already conformant, and it must stay that way.
    function test_Preview_TheEntryPairHoldsAcrossAnUnsyncedRise() public {
        CuratorVault a = _newVault(0);
        _pendingRise(a);
        uint256 promised = a.previewDeposit(ENTRY);
        assertGe(_lpDeposit(a, bob, ENTRY), promised, "previewDeposit is an upper bound on the mint");

        CuratorVault b = _newVault(0);
        _pendingRise(b);
        uint256 quoted = b.previewMint(WANT);
        usdc.mint(bob, 2 * quoted);
        vm.startPrank(bob);
        usdc.approve(address(b), 2 * quoted);
        assertLe(b.mint(WANT, bob), quoted, "previewMint is a lower bound on the pull");
        vm.stopPrank();
    }

    // ---- rows 10-11: the quote IS the fill, on a fee-bearing vault ----

    /// @dev The strongest pin available, and it needs BOTH halves of the change to hold.
    /// @dev BROKEN TWICE OVER: the fee term is priced off the pre-sync NAV and so is the entry itself.
    /// @dev The pile vests under the entry gate's line first: a fee still pending and the fall still under the pile, but entry open.
    function test_Preview_TheQuoteIsTheFillToTheWeiOnAFeeBearingVault() public {
        CuratorVault v = _feePendingUnderAFall(FEE);
        _warpBy((VEST_W * 3) / 10);
        uint256 promised = v.previewDeposit(ENTRY);
        assertEq(_lpDeposit(v, bob, ENTRY), promised, "the deposit quote is the mint, to the wei");
    }

    /// @dev THE LAW, and it is EXACT: an inequality here admits the very mutant the row exists to catch.
    /// @dev `block.timestamp` is FIXED across quote and fill, deliberately: `unvested()` decays, which
    /// @dev would invert the entry pair for a reason EIP-4626 puts out of scope ("the same transaction").
    /// @dev THE LAST OUT IS DRIVEN TOO: `_release` raises NAV mid-claim, and the views quote it released, so it is no exception.
    /// @dev DO NOT SOFTEN THIS TO A TOLERANCE. If exact equality cannot hold, the plan is wrong.
    /// @dev An entry the pile gate shuts is judged by the seam instead: both max views read zero and the verb refuses with `GainVesting`.
    function testFuzz_Preview_TheQuoteEqualsTheFillAcrossAnyUnsyncedMove(uint256 up, uint256 to, uint16 feeBps) public {
        up = bound(up, 1e6, 100_000e6);
        to = bound(to, 0, 2 * (SEED + up));
        uint16 f = uint16(bound(feeBps, 0, 5000));
        _assertEntryLegs(f, up, to);

        _assertExitLegs(f, up, to, false); // HALF, instantly: supply stands after the exit
        _assertExitLegs(f, up, to, true); // the WHOLE balance: the last out, whose claim releases
    }

    /// @notice THE SAME LAW WHERE ENTRY IS OPEN: the deferral and the move sized so the pile stays under the entry gate's line.
    /// @dev Both entry legs then assert the exact equality on every draw, which the open-ended row above reaches only on some.
    function testFuzz_Preview_TheQuoteEqualsTheFillUnderThePileLine(uint256 up, uint256 to, uint16 feeBps) public {
        up = bound(up, 1e6, 500e6); // a pile at most 5% of the seed, three quarters of it standing at the quote
        to = bound(to, 0, up + 100e6); // a fall of any depth, or a rise that keeps the pile under the line
        uint16 f = uint16(bound(feeBps, 0, 5000));
        CuratorVault a = _mockedSeam(f, up, to);
        assertGt(a.maxDeposit(bob), 0, "PREMISE: the pile sits under the entry gate's line");
        _assertEntryLegs(f, up, to);
    }

    /// @dev The law's two entry legs: `previewDeposit` is the mint and `previewMint` the pull, each to the wei, where entry is open.
    /// @dev Where the pile gate shuts it, the max views read zero and the verbs refuse with `GainVesting`, which is the seam's own agreement.
    function _assertEntryLegs(uint16 f, uint256 up, uint256 to) internal {
        CuratorVault a = _mockedSeam(f, up, to);
        uint256 promised = a.previewDeposit(ENTRY);
        if (a.maxDeposit(bob) == 0) {
            usdc.mint(bob, ENTRY);
            vm.startPrank(bob);
            usdc.approve(address(a), ENTRY);
            vm.expectRevert(AceVault.GainVesting.selector);
            a.deposit(ENTRY, bob);
            vm.stopPrank();
        } else {
            assertEq(_lpDeposit(a, bob, ENTRY), promised, "previewDeposit is the mint, to the wei");
        }

        CuratorVault b = _mockedSeam(f, up, to);
        uint256 quoted = b.previewMint(WANT);
        usdc.mint(bob, 2 * quoted);
        vm.startPrank(bob);
        usdc.approve(address(b), 2 * quoted);
        if (b.maxMint(bob) == 0) {
            vm.expectRevert(AceVault.GainVesting.selector);
            b.mint(WANT, bob);
        } else {
            assertEq(b.mint(WANT, bob), quoted, "previewMint is the pull, to the wei");
        }
        vm.stopPrank();
    }

    /// @dev The law's exit legs. HALF: `previewRedeem` is the payout and `previewWithdraw` the burn, each to the wei, on the instant exit.
    /// @dev WHOLE: the claim is the LAST OUT and releases, and `maxClaim` replays that, so claiming it never reverts and takes the cash it is bound by.
    function _assertExitLegs(uint16 f, uint256 up, uint256 to, bool whole) internal {
        CuratorVault c = _mockedSeam(f, up, to);
        if (whole) {
            uint256 all = c.balanceOf(alice);
            vm.prank(alice);
            c.requestExit(all);
            uint256 m = c.maxClaim(alice);
            vm.assume(m > 0);
            (uint256 exitable,) = c.holds();
            vm.prank(alice);
            uint256 paid = c.claimExit(m, alice, 0);
            assertLe(paid, exitable, "the claim of maxClaim paid past exitable cash");
            if (m < all) assertGe(paid + 1, exitable, "a claim bound by exitable cash left more than a wei of it");
            return;
        }
        uint256 sh = c.balanceOf(alice) / 2;
        uint256 quote = c.previewRedeem(sh);
        (uint256 ex, uint256 held) = c.holds();
        vm.assume(quote > 0 && quote <= ex - held);
        vm.prank(alice);
        assertEq(c.redeem(sh, alice, alice), quote, "previewRedeem is the payout, to the wei");

        CuratorVault d = _mockedSeam(f, up, to);
        uint256 burn = d.previewWithdraw(quote);
        vm.prank(alice);
        assertEq(d.withdraw(quote, alice, alice), burn, "previewWithdraw is the burn, to the share");
    }

    // ---- row 12 and F1: the fee views, and what the LAST LP out is owed ----

    /// @dev The public view must equal what collection actually mints, or the previews price a fiction.
    /// @dev BROKEN ON A FALL: the view reads the pre-sync NAV and `_collectFeeAt` mints against the post.
    function test_Fee_ThePendingViewEqualsWhatCollectionMints() public {
        CuratorVault a = _newVault(FEE);
        _feePendingAtRest(a);
        uint256 quotedRise = a.pendingFeeShares();
        uint256 heldRise = a.balanceOf(curator);
        a.collectFee();
        assertEq(a.balanceOf(curator) - heldRise, quotedRise, "the view is the mint on a plain rise");

        CuratorVault b = _feePendingUnderAFall(FEE);
        uint256 quotedFall = b.pendingFeeShares();
        uint256 heldFall = b.balanceOf(curator);
        b.collectFee();
        assertEq(b.balanceOf(curator) - heldFall, quotedFall, "and the mint on an unsynced fall too");
    }

    /// @dev The guard the preview change must not soften: the fee is a RATCHET.
    /// @dev A vault under its high-water mark owes nothing and the mark does not move down to meet it.
    function test_Fee_TheRatchetDoesNotMoveUnderTheMark() public {
        CuratorVault v = _newVault(FEE);
        _pendingRise(v);
        _crankAll(v);
        _warpBy(VEST_W);
        v.collectFee();
        uint256 mark = v.feeHighWater();
        uint256 held = v.balanceOf(curator);
        assertGt(mark, 0, "fixture: a mark really was stamped before the loss");

        uint256 doomed = _open(DRAW);
        _crankByLoan(v, doomed);
        _finalize(doomed);
        _crankAll(v);
        _warpBy(VEST_W);
        v.collectFee();

        assertLt(v.totalAssets(), mark, "LIVENESS: the vault really is under it");
        assertEq(v.feeHighWater(), mark, "the mark does not follow a loss down");
        assertEq(v.balanceOf(curator), held, "and not a share is minted while it is unearned");
        assertEq(v.pendingFeeShares(), 0, "the view says the same thing");
    }

    /// @dev F1, THE ROW THE REVIEW DEMANDS: the claim's `_release` raises NAV before that claim's `_collectFeeAt`.
    /// @dev WHAT IT GUARDS -- the release is not stranded, and the fee on the released rise is taken once, on the way out.
    /// @dev The fixture's net NAV sits under the fee mark and its gross above it, so only the release's own collection charges.
    /// @dev The leaver is the whole supply, so the claim releases and the deferral goes to them, less that fee.
    function test_Fee_TheLastLpOutIsPaidTheReleasedDeferralLessTheFeeOnIt() public {
        CuratorVault v = _newVault(FEE);
        _lastOutWithADeferralStanding(v);
        assertGt(v.unvested(), 0, "fixture: a deferral is standing when the last holder leaves");
        assertGt(v.feeHighWater(), 0, "fixture: the deposit stamped a fee high-water");

        uint256 sh = v.totalSupply();
        assertEq(v.balanceOf(alice), sh, "fixture: alice really is the whole supply");
        vm.prank(alice);
        v.requestExit(sh);
        /// @dev READ BEFORE THE CLAIM, at the net price the standing deferral leaves.
        uint256 preRelease = v.convertToAssets(sh);
        uint256 g = v.grossNav();
        uint256 fee = Math.mulDiv(g - v.feeHighWater(), FEE, 10_000); // the fee on the released rise past the mark
        uint256 curatorHeld = v.balanceOf(curator);
        vm.prank(alice);
        uint256 filled = v.claimExit(sh, alice, 0); // the claim, which releases before it prices

        uint256 owed = Math.mulDiv(sh, g + 1, sh + 1e6, Math.Rounding.Floor);
        uint256 charged = v.convertToAssets(v.balanceOf(curator) - curatorHeld);
        assertGt(filled, preRelease, "LIVENESS: the release really did lift what the exit is worth");
        assertLe(filled, owed, "the exit was paid past the whole of it");
        assertApproxEqAbs(filled + charged, g, 3, "the release goes WHOLLY to the leaver and the fee on it, short only the floors");
        assertApproxEqAbs(charged, fee, 2, "and the fee taken on the way out is not the fee on the rise past the mark");
    }

    /// @dev THE MEASUREMENT BEHIND F1, so the guard above is not taken on trust: the same exit, quoted
    /// @dev by the rejected override, short-pays the last holder and nobody can collect the difference.
    /// @dev This row asserts the DEFECT of a test-only contract on purpose; it never touches `src`.
    function test_Fee_ANaiveExitPreviewOverrideCannotReachTheVerb() public {
        NaiveExitPreviewVault v = new NaiveExitPreviewVault(_cfg(FEE), _listing());
        mid = _doorMarket(v, address(collateral));
        _lastOutWithADeferralStanding(v);

        uint256 sh = v.totalSupply();
        /// @dev THE REQUEST COMES FIRST, so the naive quote below is read at the claim's own instant, before it moves anything.
        vm.prank(alice);
        v.requestExit(sh);
        uint256 g = v.grossNav();
        uint256 fee = Math.mulDiv(g - v.feeHighWater(), FEE, 10_000); // the fee on the released rise past the mark
        uint256 curatorHeld = v.balanceOf(curator);
        uint256 naive = v.previewRedeem(sh); // what the fee-bearing quote says, before anything moves
        vm.prank(alice);
        uint256 paid = v.claimExit(sh, alice, 0); // the claim, which releases before it prices

        uint256 owed = Math.mulDiv(sh, g + 1, sh + 1e6, Math.Rounding.Floor);
        uint256 charged = v.convertToAssets(v.balanceOf(curator) - curatorHeld);
        emit log_named_uint("what the naive quote would have cost the last LP", owed - naive);
        assertLt(naive, owed, "LIVENESS: the naive quote really does take a cut of the released pile");
        assertLe(paid, owed, "the exit was paid past the whole of it");
        assertApproxEqAbs(paid + charged, g, 3, "but the verb prices after the release, so the last LP out is paid the book less the fee on it");
        assertApproxEqAbs(charged, fee, 2, "the curator is paid the fee on the released rise and not the naive quote's difference");
        assertEq(v.totalSupply(), v.balanceOf(curator), "and nothing but the fee shares is left for the next depositor to capture");
    }
}
