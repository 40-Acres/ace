// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.36;

import {CuratorVaultBase} from "./CuratorVaultBase.sol";
import {CuratorVault, Listing, Row} from "../../src/curator/CuratorVault.sol";
import {AceVault, VaultConfig} from "../../src/curator/AceVault.sol";
import {MarketState} from "../../src/ace/hub/Types.sol";
import {MockERC20} from "../mocks/MockERC20.sol";
import {MockPersistenceRecord} from "../mocks/MockPersistenceRecord.sol";
import {AceFixtures} from "../utils/AceFixtures.sol";
import {PocDeployConfig, ProtocolPolicy} from "../../src/config/Defaults.sol";

/// @title CuratorVaultVesting
/// @notice A pass's NAV INCREASE vests over an immutable window, so capturing it costs the window's risk.
/// @dev The quantity deferred is what the pass ADDED TO NAV. It is NOT "the premium": on an ordinary
/// @dev partial repayment the melt floors twice on the paid side and never on the release side, so the
/// @dev two differ by a wei per leg and the naive label is what leads a reader to delete the clamp.
/// @dev the design record (the ladder) and 2026-08-21 (its revival here).
contract CuratorVaultVestingTest is CuratorVaultBase {
    uint256 internal constant SEED = 20_000e6;
    uint256 internal constant PER_LOAN = 1_000e6;
    uint256 internal constant N = 9;

    function setUp() public override {
        super.setUp();
        record.setMinPrice(T2);
    }

    /// @dev N door loans, all synced, with the LAST loan still live and one clean close from paying.
    /// @dev Value arrives at the REPAY, in the hub's own aggregate, atomically.
    /// @dev The crank does not carry it -- it is NAV-neutral -- so the rig hands back the unpulled trigger.
    function _primedPremium(CuratorVault v) internal returns (uint256 loanId) {
        _lpDeposit(v, alice, SEED);
        uint256[] memory loans = new uint256[](N);
        for (uint256 i; i < N; i++) {
            loans[i] = _open(PER_LOAN);
            _crank(v, loans[i], T2, 0);
        }
        _warpBy(30 days);
        _crankAll(v); // syncs, so the repay below is the ONLY unobserved value in the vault
        loanId = loans[N - 1];
    }

    /// @dev The primed rig with the trigger already pulled: value standing, and no sync since it landed.
    /// @dev A clean close is what earns the fee escrow over the served term; a partial repay earns nothing.
    function _standingPremium(CuratorVault v) internal returns (uint256 loanId) {
        loanId = _primedPremium(v);
        _repay(loanId, lens.loan(loanId).debt);
    }

    /// @dev ONE loan, fully repaid and swept: every cent is idle CASH and a lump is standing on the ladder.
    /// @dev The shape the zero-shares transition has to be judged in, because a vault still carrying
    /// @dev lent principal cannot pay its last holder out in the first place.
    function _premiumThenAllCash(CuratorVault v) internal {
        _lpDeposit(v, alice, SEED);
        uint256 loanId = _open(6_000e6);
        _crank(v, loanId, T2, 0);
        _warpBy(30 days);
        _repay(loanId, lens.loan(loanId).debt);
        _crankAll(v);
        assertEq(v.idle(), v.grossNav(), "every cent of the vault's own book is back as cash");
        assertGt(v.unvested(), 0, "and a lump is standing on the ladder");
    }

    // ---- the attack ----

    /// @dev THE KEYSTONE. Deposit, have the value ARRIVE, redeem -- all in one block, no time passing.
    /// @dev The attacker must end at or below what they put in; a wei of exit rounding is theirs to lose.
    /// @dev WHAT IS MEASURED IS VALUE, NOT CASH TAKEN, and the distinction is load-bearing here.
    /// @dev The pro-rata exit rail bounds how much of a position one call can clear, so a cash-only
    /// @dev assertion would pass on a vault that merely refused to pay, and stop testing the ladder.
    /// @dev Cash out PLUS what the remaining shares are worth still exceeds the stake if the ladder is
    /// @dev broken, however illiquid the vault is, so this measure bites on the deferral and only on it.
    function test_Vest_TheAtomicSandwichCapturesNothing() public {
        CuratorVault v = _newVault(0);
        uint256 loanId = _primedPremium(v);

        uint256 stake = 5_000e6;
        usdc.mint(bob, stake);
        vm.startPrank(bob);
        usdc.approve(address(v), stake);
        v.deposit(stake, bob);
        vm.stopPrank();
        uint256 navMid = v.totalAssets();
        uint256 deferredMid = v.unvested();
        uint256 grossMid = v.grossNav();

        _repay(loanId, lens.loan(loanId).debt); // the arrival, inside the sandwich
        emit log_named_uint("the gap the sandwich reaches for", v.grossNav() - grossMid);
        assertGt(v.grossNav(), grossMid, "LIVENESS: with no arrival this run proves nothing");
        assertEq(v.totalAssets(), navMid, "and the price cannot see it: the mark still bounds the view");

        /// @dev THE EXIT IS INSTANT, in the same block, and its own sync is what stamps the arrival on the ladder.
        // HALVED for headroom, not to weaken it: the redeem's own `_sync` re-prices the rail under a
        uint256 sh = v.maxRedeem(bob) / 2; // quote taken before it, and the measure below is value, not size
        assertGt(sh, 0, "LIVENESS: the rail leaves a real exit open, so the LADDER is what has to defeat him");
        vm.prank(bob);
        v.redeem(sh, bob, bob);

        assertGt(v.unvested(), deferredMid, "the exit's own sync put the whole arrival on the ladder");
        uint256 captured = usdc.balanceOf(bob) + v.convertToAssets(v.balanceOf(bob));
        /// @dev NO TIME PASSED, so the ladder pays the round trip nothing: the arrival waits on the window for whoever holds.
        assertLe(captured, stake, "an atomic round trip captured part of the arrival");
    }

    /// @dev A flash-sized deposit is the same attack with a bigger numerator, and it captures the same zero.
    /// @dev Measured as value, not as cash taken, for the reason spelled out on the keystone row above.
    function test_Vest_AFlashLoanedSandwichCapturesNothing() public {
        CuratorVault v = _newVault(0);
        uint256 loanId = _standingPremium(v);

        uint256 stake = 40 * SEED; // D >> NAV, since the old profit scaled as delta * D/(V+D)
        usdc.mint(bob, stake);

        vm.startPrank(bob);
        usdc.approve(address(v), stake);
        v.deposit(stake, bob);
        _crank(v, loanId, T2, 0);
        uint256 sh = v.maxRedeem(bob); // the exit, in the same block
        v.redeem(sh, bob, bob);
        vm.stopPrank();

        assertGt(sh, 0, "LIVENESS: the rail left a real exit open at flash size too");
        uint256 captured = usdc.balanceOf(bob) + v.convertToAssets(v.balanceOf(bob));
        /// @dev SIZE BUYS NOTHING, the property here: a forty-times-NAV round trip in one block keeps no part of the arrival.
        assertLe(captured, stake, "size buys no part of value nobody has recognized");
    }

    /// @dev Vesting PRICES the hole, it does not close it: a one-block hold earns one block's share.
    function test_Vest_AOneBlockHoldCapturesOnlyItsShare() public {
        CuratorVault v = _newVault(0);
        uint256 loanId = _standingPremium(v);

        uint256 stake = 5_000e6;
        usdc.mint(bob, stake);
        vm.startPrank(bob);
        usdc.approve(address(v), stake);
        v.deposit(stake, bob);
        vm.stopPrank();
        _crank(v, loanId, T2, 0);
        uint256 lump = v.unvested();

        uint256 t0 = _now();
        _warpBy(12);
        uint256 sh = v.maxRedeem(bob);
        assertGt(sh, 0, "LIVENESS: the rail leaves a real exit open, so what he earns is the ladder's doing");
        vm.prank(bob);
        uint256 got = v.redeem(sh, bob, bob);

        uint256 captured = got + v.convertToAssets(v.balanceOf(bob));
        /// @dev What a brief holder earns is the window they actually bore: twelve seconds of it.
        assertLe(captured, stake + (lump * (_now() - t0)) / VEST_W, "a brief hold earns the window it bore");
    }

    /// @dev The honest claim: a holder who bears the window's risk receives their share in full.
    function test_Vest_AFullWindowHoldCapturesItAll() public {
        CuratorVault v = _newVault(0);
        uint256 loanId = _standingPremium(v);

        uint256 stake = 5_000e6;
        usdc.mint(bob, stake);

        vm.startPrank(bob);
        usdc.approve(address(v), stake);
        v.deposit(stake, bob);
        vm.stopPrank();
        _crank(v, loanId, T2, 0);

        _warpBy(7 days);
        _crankAll(v);
        uint256 sh = v.maxRedeem(bob);
        assertGt(sh, 0, "LIVENESS: the rail leaves a real exit open");
        vm.prank(bob);
        uint256 got = v.redeem(sh, bob, bob);

        uint256 captured = got + v.convertToAssets(v.balanceOf(bob));
        assertGt(captured, stake, "holding through the window earns the share the sandwich could not");
        assertEq(v.unvested(), 0, "and after the window nothing is deferred at all");
    }

    // ---- the quantity, and the clamp that makes it safe ----

    /// @dev A pass may LOWER nav (the hub's own melt flooring) but may never raise it: that is the invariant.
    function test_Vest_ASweepNeverRaisesNav() public {
        CuratorVault v = _newVault(0);
        _lpDeposit(v, alice, SEED);
        uint256 loanId = _open(6_000e6);
        _crank(v, loanId, T2, 0);
        _warpBy(3 days);

        for (uint256 i; i < 6; i++) {
            _repay(loanId, 500e6);
            uint256 before = v.totalAssets();
            _crankAll(v);
            assertLe(v.totalAssets(), before, "a pass never raises nav");
            assertGe(v.totalAssets(), before - 2, "and falls at most by the hub's own flooring dust");
        }
    }



    /// @dev A LOSS IS NEVER DEFERRED. `_sync` stamps only a RISE; a fall passes straight through.
    /// @dev The settlement moves the hub's own aggregate, so this needs no crank at all to land.
    function test_Vest_ASettlementDefersNothingAndLandsAtOnce() public {
        CuratorVault v = _newVault(0);
        _lpDeposit(v, alice, SEED);
        uint256 loanId = _open(6_000e6);
        _crank(v, loanId, T2, 0);
        _crankAll(v);

        uint256 deferred = v.unvested();
        uint256 grossBefore = v.grossNav();
        _finalize(loanId);

        assertLt(v.grossNav(), grossBefore, "the loss landed on the aggregate the instant it settled");
        assertLe(v.unvested(), deferred, "and the ladder took no part in it: a loss is never deferred");
    }

    /// @dev THE INVERSE of the old entry-basis invariant, and it IS the socialization.
    /// @dev NAV must FALL by the settled loan's whole unrecovered position, with the ladder staying out.
    /// @dev Replaces `test_Vest_EntryBasisIsStillInvariantAcrossAWriteOff`.
    function test_Vest_ASettlementLowersNavAndTheLadderStaysOut() public {
        CuratorVault v = _newVault(0);
        _lpDeposit(v, alice, SEED);
        uint256 loanId = _open(6_000e6);
        _crank(v, loanId, T2, 0);
        _crankAll(v);

        uint256 grossBefore = v.grossNav();
        uint256 deferred = v.unvested();
        _finalize(loanId);
        uint256 dropped = grossBefore - v.grossNav();
        v.collectFee(); // the sync that lets the fall through

        assertGt(dropped, 0, "the aggregate really did fall");
        assertEq(v.grossNav(), _hubTruthNav(v), "and the second read path agrees on where it landed");
        assertLe(v.unvested(), deferred, "the ladder never grew across a loss");
    }

    /// @dev A recovery is ordinary quote arriving: an observed RISE, so ALL of it defers.
    function test_Vest_ARecoveryDefersTheWholeArrival() public {
        CuratorVault v = _newVault(0);
        _lpDeposit(v, alice, SEED);
        uint256 loanId = _open(6_000e6);
        _crank(v, loanId, T2, 0);
        _finalize(loanId);
        _crankAll(v);
        uint256 deferred = v.unvested();
        uint256 grossBefore = v.grossNav();

        uint256 filled = _buyPot(keeper, loanId, 2_000e6);
        assertGt(filled, 0, "the pot really sold");
        _crankAll(v);
        uint256 rise = v.grossNav() - grossBefore;

        assertGt(rise, 0, "the sale lifted the aggregate");
        assertGt(v.unvested(), deferred, "and every wei of a rise defers");
        assertApproxEqAbs(v.unvested() - deferred, rise, 2, "the WHOLE arrival, not a slice of it");
    }


    /// @dev THE WHOLE `burned > 0` REGIME IS UNREACHABLE, and this is the test that says so out loud.
    /// @dev It needed a co-funder of the vault's own class to call `redeemInKind`. Only a lot owner is
    /// @dev ever minted units, the gate admits one lot owner, and the vault itself is forbidden to burn.
    /// @dev So `burned` is pinned at zero for every class the vault holds, forever, by construction.
    function test_Vest_NoClassOfThisVaultCanEverHaveBurnedUnits() public {
        CuratorVault v = _newVault(0);
        _lpDeposit(v, alice, SEED);
        uint256 loanId = _open(8_000e6);
        _crank(v, loanId, T2, 0);
        _finalize(loanId);
        _buyPot(keeper, loanId, 40_000e6);
        _crankAll(v);

        /// @dev The supply/minted/burned triple went with the receipt ledger, and its whole content was that
        /// @dev nothing could strand between them. Sole tenancy makes that unrepresentable rather than true:
        /// @dev the market names ONE lender, so whatever the settlement left is already wholly the vault's.
        assertEq(ace.idToMarketParams(mid).lender, address(v), "the market names this vault and nobody else");
        assertEq(lens.claimable(address(v), v.asset()), read.poolOwed(mid), "so the pot's proceeds are all its own");
    }

    /// @dev GAP-1 FROM THE DELTA REVIEW, and the ONE regime the whole `burned > 0` rule is really about:
    /// @dev a burn while the CLAIM IS STILL LIVE. `Token.burn` has no empty-pot guard and `redeemInKind`
    /// @dev raises `K.burned` unconditionally, so a holder can burn pre-settlement, receive nothing, and
    /// @dev move `supply - burned` under everyone else. Here alone the two denominators differ AND the
    /// @dev numerator is non-zero -- every other burn test in this tree runs after settlement, where
    /// @dev `claimAt` is zero and the denominator cannot be observed at all.

    // ---- the ladder's own edges ----


    /// @dev The span is ONE window flat, tightened from 1.5 when the epoch grid went: the accumulator's
    /// @dev maturity is a weighted average of values all at or below `now + W`, so it cannot exceed it.
    /// @dev The old bound was the three-rung span, where a credit took the first rung at or after now + W.
    function test_Vest_TheSpanIsBoundedByOneWindow() public {
        CuratorVault v = _newVault(0);
        uint256 loanId = _primedPremium(v);
        _repay(loanId, lens.loan(loanId).debt);
        v.collectFee(); // the sync that defers the arrival
        assertGt(v.unvested(), 0, "something is deferred");

        _warpBy(uint256(VEST_W) + 1);
        assertEq(v.unvested(), 0, "and it is fully vested one window later, with no grid to round out to");
    }


    /// @dev The read leg CEILS, so the deduction rounds against the entrant and never against the stayers.
    /// @dev The subject is now the OBSERVED RISE in gross, which is exactly what `_sync` hands the ladder.
    function test_Vest_TheDeductionRoundsUpNotDown() public {
        CuratorVault v = _newVault(0);
        uint256 loanId = _primedPremium(v);
        uint256 grossBefore = v.grossNav();
        uint256 deferredBefore = v.unvested();
        _repay(loanId, lens.loan(loanId).debt);

        uint256 rise = v.grossNav() - grossBefore;
        v.collectFee(); // any state-changing verb syncs, and the sync is what hands the ladder the rise
        uint256 banked = v.unvested() - deferredBefore;
        assertGt(rise, 0, "the arrival really did raise gross");
        assertGe(banked, rise, "the ladder never holds LESS than the rise it observed");
        assertLe(banked, rise + 2, "and never meaningfully more than it either");
    }

    /// @dev The window is fixed at deploy and railed at both ends. ZERO must revert: an LP cannot read
    /// @dev a disabled defence off the ABI, which is the whole reason the hub deleted its own off-switch.
    /// @dev The floor rails the PROPERTY rather than the symptom: a window too short to defer defeats
    /// @dev the deferral as completely as zero does, and reads as a deliberate config while doing it.
    /// @dev The short rows are LITERALS, never `MIN_VEST_WINDOW - 1`: a row written against the constant
    /// @dev tracks a mutated constant and would pin nothing.
    function test_Vest_TheWindowRailIsEnforced() public {
        VaultConfig memory cfg = _cfg(0);
        Listing[] memory l = _listing(); // BEFORE the expectations: building the row's record is a call
        cfg.vestWindow = 0;
        vm.expectRevert(AceVault.VestWindowOutOfBounds.selector);
        _make(cfg, l, "Zero");

        cfg.vestWindow = 1; // one second: defers nothing anyone must wait for
        vm.expectRevert(AceVault.VestWindowOutOfBounds.selector);
        _make(cfg, l, "Tick");

        cfg.vestWindow = 12; // one block: the capture this defends against needs two of them
        vm.expectRevert(AceVault.VestWindowOutOfBounds.selector);
        _make(cfg, l, "Block");

        cfg.vestWindow = 7 days + 1;
        vm.expectRevert(AceVault.VestWindowOutOfBounds.selector);
        _make(cfg, l, "Long");

        cfg.vestWindow = 1 hours;
        CuratorVault low = _make(cfg, l, "Min");
        assertEq(low.VEST_WINDOW(), 1 hours, "the bottom of the rail is admitted, not refused");

        cfg.vestWindow = 7 days;
        CuratorVault ok = _make(cfg, l, "Max");
        assertEq(ok.VEST_WINDOW(), 7 days, "the top of the rail is admitted");
    }

    /// @dev A vault from `cfg` listing `l`, at the rig's table inputs; the deploy is the one call, so an expectation binds it.
    function _make(VaultConfig memory cfg, Listing[] memory l, string memory name) internal returns (CuratorVault) {
        return new CuratorVault(cfg, RIG_MIN_DEBT, PocDeployConfig.MIN_COVERAGE_WAD, RIG_TIMELOCK, l, name, name);
    }

    /// @dev The floor's own EDGE: one second under, refused; the floor itself, admitted. The rail row
    /// @dev above tests 1s and 12s, which a `<=` written for `<` would also refuse, so neither pins the
    /// @dev comparator. This pair does, and it is the pair a lowered floor turns red.
    /// @dev LITERALS on purpose, exactly as the rail row argues: a bound spelled `MIN_VEST_WINDOW - 1`
    /// @dev follows a mutated constant and asserts nothing about where the edge actually is.
    function test_Vest_OneSecondBelowTheFloorIsRefusedAndTheFloorItselfIsNot() public {
        VaultConfig memory cfg = _cfg(0);
        Listing[] memory l = _listing(); // BEFORE the expectation: building the row's record is a call
        cfg.vestWindow = 3599; // one second under the hour
        vm.expectRevert(AceVault.VestWindowOutOfBounds.selector);
        _make(cfg, l, "Under");

        cfg.vestWindow = 3600;
        CuratorVault at = _make(cfg, l, "At");
        assertEq(at.VEST_WINDOW(), 3600, "the floor is inclusive: the rail refuses BELOW it, never AT it");
        assertEq(at.MIN_VEST_WINDOW(), 3600, "LIVENESS: the floor this row brackets really is one hour");
    }

    // ---- the brick: a loss must retire the deferral it wiped out, or the ladder outlives the value ----

    /// @dev THE BRICK PROBE. A settlement bigger than the pending vest must leave NOTHING deferred.
    /// @dev `totalAssets` is `min(gross, mark) - unvested`, so a ladder the loss did not clear is a
    /// @dev deduction against value that no longer exists: the view floors at zero, `_requireEntryOpen`
    /// @dev reads `EndOfLife`, and every exit prices to nothing while real cash sits in the vault.
    /// @dev MUTATION TARGET: delete the `_burnVest` call in `_sync` and this must fail, not merely drift.
    function test_Vest_ASettlementBiggerThanTheLadderClearsItRatherThanBricking() public {
        CuratorVault v = _newVault(0);
        uint256 loanId = _primedPremium(v);
        uint256 doomed = _open(PER_LOAN * 6); // the loss, sized to swamp whatever the repay defers
        _crankByLoan(v, doomed);
        _repay(loanId, lens.loan(loanId).debt);
        v.collectFee(); // the sync that puts the arrival on the ladder
        uint256 deferred = v.unvested();
        assertGt(deferred, 0, "LIVENESS: there is a real ladder for the loss to have to clear");

        uint256 grossBefore = v.grossNav();
        _finalize(doomed);
        uint256 loss = grossBefore - v.grossNav();
        assertGt(loss, deferred, "LIVENESS: and the settlement really is the bigger of the two");

        v.collectFee();
        assertEq(v.unvested(), 0, "a loss that swamps the ladder retires the whole of it");
        assertEq(v.totalAssets(), v.grossNav(), "so the view is the aggregate itself, with nothing deducted");
        assertGt(v.totalAssets(), 0, "and the vault is not bricked: there is still value to price against");

        uint256 sh = v.balanceOf(alice) / 10;
        assertGt(_requestAndClaim(v, alice, sh), 0, "the exit is servable, which is what bricking would deny");
        _waivePots(v); // the settled pot stays unsold, so only a bricking ladder could still refuse the entry below
        _lpDeposit(v, bob, 1_000e6); // and `_requireEntryOpen` still admits capital
    }

    // ---- liquidity: the ladder defers RECOGNITION, never availability ----

    /// @dev THE PROPERTY MOST LIKELY TO BE BROKEN BY A LATER EDITOR. Deferred value is still spendable cash.
    /// @dev No loan is armed, so exitable is all of idle.
    /// @dev MUTATION TARGET: make the claim's cash bound read `exitable - unvested()` and this must fail.
    function test_Vest_CashStaysAvailableForExitsWhileDeferred() public {
        CuratorVault v = _newVault(0);
        uint256 loanId = _standingPremium(v);
        _crank(v, loanId, T2, 0);
        uint256 lump = v.unvested();
        uint256 cash = v.idle();
        assertGt(lump, 1, "a real lump is deferred");
        assertGt(v.grossNav(), cash, "and real capital is still lent, so the liquidity bound can bind");
        uint256 heldA = v.balanceOf(alice); // BEFORE the prank: a read is a call, and a call would eat it
        vm.prank(alice);
        v.requestExit(heldA); // alice holds every share, so the claim releases the pile and is cash-bound
        uint256 m = v.maxClaim(alice);
        assertLt(m, heldA, "PREMISE: exitable covers less than alice's whole request");
        vm.prank(alice);
        uint256 got = v.claimExit(m, alice, 0);

        // strictly PAST `idle - unvested`, which is the figure a reserving exit would have refused
        assertGt(got, cash - lump, "the claim stopped short of the deferred slice");
        assertApproxEqAbs(got, cash, 1, "and the claim did not pay out the full idle counter");
    }

    /// @dev Lending is bounded by lendable ALONE: unvested value is nobody's in particular and reserves nothing.
    /// @dev No request and no armed loan stand, so lendable is all of idle, and a borrow of all of it lands while a pile vests.
    function test_Vest_LendingDoesNotReserveTheLadder() public {
        CuratorVault v = _newVault(0);
        uint256 loanId = _standingPremium(v);
        _crank(v, loanId, T2, 0);

        assertGt(v.unvested(), 0, "a lump is deferred");
        uint256 cash = v.idle();
        assertEq(v.lendable(), cash, "the ladder held some of idle back from lending");
        uint256 drawn = _open(cash);
        assertGt(v.unvested(), 0, "PREMISE: the pile still vests as the borrow lands");
        assertGt(read.debtOf(drawn), 0, "the borrow of all of lendable did not open");
        assertEq(v.idle(), 0, "the borrow did not take every cent of idle");
    }

    // ---- R1: the zero-shares transition ----

    /// @dev R1, ported from the hub. With no shares outstanding there is no share price to defend.
    /// @dev Without it the residue is ownerless cash and the next dust depositor takes it: the hub
    /// @dev measured a 10 USDC deposit withdrawing 25.2 before the release was added.
    /// @dev MUTATION TARGET: drop the `_release(g)` call in `claimExit` and this must fail.
    function test_Vest_AFullExitReleasesTheLadder() public {
        CuratorVault v = _newVault(0);
        _premiumThenAllCash(v);

        uint256 book = v.grossNav(); // idle IS the book: the vault holds its own cash and nobody else's
        uint256 got = _redeemAll(v, alice); // a request, then the claim that releases the pile

        assertEq(v.totalSupply(), 0, "the last holder really did leave");
        assertEq(v.unvested(), 0, "the ladder released, because there is no price left to defend");
        // the virtual offset always strands one wei; without R1 the residue would be the whole lump
        assertApproxEqAbs(got, book, 1, "so the last redeemer took the book in full, not a deferred fraction");
        assertLe(v.idle(), 1, "and nothing ownerless is left behind for a dust depositor to find");
    }

    /// @dev The BRICK branch of the same seam: a vault emptied that way must still take capital.
    function test_Vest_AFullExitDoesNotBrickEntry() public {
        CuratorVault v = _newVault(0);
        _premiumThenAllCash(v);
        _redeemAll(v, alice); // a request, then the claim that releases the pile

        assertEq(v.totalSupply(), 0, "the emptied-vault state the release exists for");
        assertEq(v.maxDeposit(bob), type(uint256).max, "and entry is still open on an empty vault");
        assertGt(_lpDeposit(v, bob, 1_000e6), 0, "which a depositor can prove");
    }

    /// @dev The LOOT branch: a dust deposit after a full exit must find nothing ownerless to capture.
    function test_Vest_ADustDepositAfterAFullExitCapturesNothing() public {
        CuratorVault v = _newVault(0);
        _premiumThenAllCash(v);
        _redeemAll(v, alice); // a request, then the claim that releases the pile

        uint256 dust = 10e6;
        _lpDeposit(v, bob, dust);
        _warpBy(7 days);
        uint256 out = _redeemAll(v, bob);
        assertLe(out, dust, "a ten-dollar deposit takes ten dollars out, not the whole residue");
    }

    // ---- the fee ----

    /// @dev The curator is paid exactly as the LPs are, over the same schedule: unvested is not in the rate.
    function test_Fee_CuratorEarnsOnlyAsPremiumVests() public {
        CuratorVault v = _newVault(2000);
        uint256 loanId = _standingPremium(v);
        v.collectFee();
        uint256 held = v.balanceOf(curator);
        _crank(v, loanId, T2, 0);
        v.collectFee();
        assertEq(v.balanceOf(curator), held, "no fee is struck on value nobody has recognized");

        _warpBy(7 days);
        v.collectFee();
        assertGt(v.balanceOf(curator), held, "and it is struck as the ladder releases, not before");
    }

    // ---- fuzz ----




    /// @dev THE LADDER BOUND over a random walk of repay / settle / recover: it never claims more than
    /// @dev gross holds, and a SETTLEMENT is the only step that may lower gross at all.
    /// @dev Replaces `..._APassThatMovedNothingIsNotAJudgement` and recovers `..._UnvestedNeverExceedsGross`.
    function testFuzz_Vest_OnlyASettlementShrinksGrossAndTheLadderStaysInside(uint256 seed) public {
        CuratorVault v = _newVault(0);
        _lpDeposit(v, alice, SEED);
        uint256 loanId = _open(6_000e6);
        _crank(v, loanId, T2, 0);
        uint256 moved;
        uint256 deferredSeen;

        for (uint256 i; i < 8; i++) {
            uint256 r = uint256(keccak256(abi.encode(seed, i, "rc")));
            uint256 grossBefore = v.grossNav();
            bool settled;
            if (i == 0) _repay(loanId, 500e6); // forced, so the guard below is never satisfied by luck
            else if (i == 7) _closeAFreshLoan(v); // FORCED: a clean round trip is the only guaranteed stamp
            else if (r % 5 == 0 && lens.loan(loanId).closedAt == 0) (settled) = (_finalizeAndFlag(loanId));
            /// @dev The settled guard is the ask's own precondition: a live loan has no pot and is refused by name
            else if (r % 5 == 1 && lens.loan(loanId).closedAt != 0) _buyPot(keeper, loanId, 1 + (r % 5_000e6));
            else if (lens.loan(loanId).closedAt == 0) _repay(loanId, 1 + (r % 500e6));
            _crankAll(v);

            if (!settled) assertGe(v.grossNav(), grossBefore, "only a settlement may ever shrink gross");
            assertLe(v.unvested(), v.grossNav(), "and the ladder never claims more than gross holds");
            if (v.grossNav() != grossBefore) moved++;
            if (v.unvested() != 0) deferredSeen++;
        }

        assertGt(moved, 0, "LIVENESS: gross never moved, so the walk judged nothing");
        assertGt(deferredSeen, 0, "LIVENESS: the ladder was empty throughout, so its bound judged nothing");
    }

    /// @dev `_finalize` plus the flag the loop needs to know a settlement was the step that ran.
    function _finalizeAndFlag(uint256 loanId) internal returns (bool) {
        _finalize(loanId);
        return true;
    }

    /// @dev R1 as the invariant it defends, over BOTH exit verbs and any mix of sizes. An emptied vault
    /// @dev carrying a live ladder is ownerless cash, and the next dust depositor mints against it.
    /// @dev The shipped R1 tests drive `redeem` alone; `withdraw` reaches the release too.
    function testFuzz_Vest_NoExitEverLeavesAnOwnerlessLadder(uint256 seed) public {
        CuratorVault v = _newVault(0);
        _premiumThenAllCash(v);
        uint256 banked = v.grossNav(); // idle IS the book: the vault holds its own cash and nobody else's
        uint256 took;
        uint256 exits;

        for (uint256 i; i < 5; i++) {
            uint256 r = uint256(keccak256(abi.encode(seed, i, "r1")));
            uint256 pct = 1 + (r % 60); // a slice, so the forced full exit below is always the last one
            if (r % 2 == 0) {
                took += _redeemFrac(v, alice, pct, 100);
            } else {
                /// @dev AN INSTANT WITHDRAW OF THE SLICE'S NET WORTH: the last free holder's max view reads zero over a pile,
                /// @dev but a partial exit is open, and it leaves the pile to whoever still holds.
                uint256 slice = (v.balanceOf(alice) * pct) / 100;
                if (slice == 0) continue;
                uint256 amt = v.previewRedeem(slice);
                if (amt == 0) continue;
                vm.prank(alice);
                v.withdraw(amt, alice, alice);
                took += amt;
            }
            exits++;
            assertTrue(v.totalSupply() != 0 || v.unvested() == 0, "a partial exit emptied the vault mid-run");
        }

        assertGt(exits, 0, "LIVENESS: nobody exited, so no seam was reached");
        took += _redeemAll(v, alice); // the forced last exit: every seed reaches the zero-supply seam
        assertEq(v.totalSupply(), 0, "the last holder really did leave");
        assertEq(v.unvested(), 0, "and the ladder released, because there is no share price left to defend");
        // each exit strands under two wei, the price's floor and the burn's ceiling; a stranded LADDER would be orders past that
        assertLe(banked - took, 2 * (exits + 1) + 2, "so the holders took the whole book, not a deferred fraction");
        assertLe(v.idle(), 2 * (exits + 1) + 2, "and nothing ownerless is left for a dust depositor to find");
    }

    // ---- the 18-decimal leg: REQUIRED, because AceFixtures defaults to 6 and hides the class ----

    uint256 internal constant BIG_SEED = 20_000e18; // the LP deposit, in the big asset's own wei
    uint256 internal constant BIG_DRAW = 3_000e18; // the take, so the class supply, so units/1e18 is 3000
    uint256 internal constant BIG_PART = 500e18; // (500e18*1e18) mod 3000e18 is 2000e18, so 2000 wei a leg
    uint256 internal constant BIG_PARTS = 4; // partial repays, each its own melt and its own pair of floors
    uint256 internal constant BIG_LEGS = 7; // the draw fee, BIG_PARTS melts, then the earn and the close

    /// @dev THE 18-DECIMAL STAND. Same shape as the 6dp rig on an asset whose wei are 1e12 times smaller.
    /// @dev Its own record on the BIG pair, because a `MockPersistenceRecord` is bound to one (quote, collateral) frame.
    /// @dev The row lends at half the record's 2x-par minimum, as the rig's own row does, so the door market sits at par gridded down.
    function _bigQuoteRig() internal returns (CuratorVault v) {
        big = new MockERC20("Big Quote", "BIG", 18);
        VaultConfig memory cfg = _cfg(0);
        cfg.asset = address(big);
        bigT = AceFixtures.priceAt(address(big), address(collateral), 0); // this rig's OWN par: `T2` is framed on the 6-decimal quote
        bigRec = new MockPersistenceRecord(address(big), address(collateral));
        bigRec.setObserved(AceFixtures.px(1e18, address(big), address(collateral)));
        bigRec.setMinPrice(AceFixtures.px(2e18, address(big), address(collateral)));
        Listing[] memory l = new Listing[](1);
        l[0] = Listing({
            collateral: address(collateral),
            row: Row({
                record: address(bigRec),
                bufferBps: RIG_BUFFER_BPS,
                baseBps: uint16(PocDeployConfig.BASE_BPS),
                minTenor: ProtocolPolicy.MIN_TENOR,
                maxTenor: ProtocolPolicy.MAX_TENOR,
                cap: type(uint192).max
            })
        });
        v = new CuratorVault(cfg, RIG_MIN_DEBT, PocDeployConfig.MIN_COVERAGE_WAD, RIG_TIMELOCK, l, "Curator 18", "cV18");
        bigMid = _doorMarket(v, address(collateral));
    }

    // DELETED with the second floor: `_meltStrand` predicted a residue, and credit reaches the pool unfloored

    function _bigDeposit(CuratorVault v, address who, uint256 amt) internal {
        big.mint(who, amt);
        vm.startPrank(who);
        big.approve(address(v), amt);
        v.deposit(amt, who);
        vm.stopPrank();
    }

    /// @dev `_finalize` against the BIG market's own record; the base one speaks for a different frame.
    function _finalizeBig(uint256 loanId) internal {
        bigRec.setBelow(true);
        vm.prank(keeper);
        ace.finalize(loanId);
        bigRec.setBelow(false);
    }

    /// @dev THE DRIFT IS GONE, AND THIS ROW IS THE WITNESS -- kept and INVERTED rather than deleted.
    /// @dev It WAS the melt's double floor: `LoanAccounting._retireAt` floored a credit into `K.qIndex` and
    /// @dev `Token.settle` floored it again per holder, while `unitOwed` took the whole amount either way.
    /// @dev The residue was `ceil(((give * 1e18) mod supply) / 1e18)` a leg -- a wei at 6dp, thousands at
    /// @dev 18dp -- and NAV the vault could never turn into cash. This 18-decimal rig exists to reach it.
    /// @dev The per-(loan, tick) index is deleted and a lender's credit lands in their POOL directly, so
    /// @dev there is no second floor left to round: the strand is zero at any decimals, and a non-zero here
    /// @dev means one came back through some other divisor.
    /// @dev SECOND HALF, UNCHANGED: the same rig driven DOWN, where a bare `g - m` in `_sync` panics 0x11.
    /// @dev MUTATION TARGET: `if (g > m)` -> `if (true)` in `_sync` is that bare subtraction, and it panics.
    function test_Vest_AnEighteenDecimalQuoteStrandsNotOneWei() public {
        CuratorVault v = _bigQuoteRig();
        _bigDeposit(v, alice, BIG_SEED);
        uint256 id = _borrow(v, BIG_DRAW);
        assertEq(ace.loanMarket(id), bigMid, "guard: the door lent in the big rig's own market");
        assertEq(read.claimCount(bigMid, id), 1, "guard: the loan holds its claim, so a leg is one _retireAt");
        assertEq(lens.claimOf(bigMid, id), BIG_DRAW, "guard: the claim IS the take, and the take is denominated in QUOTE");
        _crank(v, id, bigT, 0);

        // claim after EVERY leg: flooring is subadditive, so a lazy claim would deliver more and hide it
        for (uint256 i; i < BIG_PARTS; i++) {
            _repayBig(id, BIG_PART);
            _crank(v, id, bigT, 0);
        }
        _repayBig(id, lens.loan(id).debt);
        assertTrue(lens.loan(id).closedAt != 0, "guard: the loan closed, so the escrow-earn and closing legs both ran");
        _crank(v, id, bigT, 0);

        // the claim doors are EXHAUSTED: one more full pass moves nothing, so what is left never pays
        uint256 cash0 = v.idle();
        _crank(v, id, bigT, 0);
        assertEq(v.idle(), cash0, "guard: another whole pass paid nothing, so the classes are drained");
        assertEq(v.idle(), big.balanceOf(address(v)), "guard: idle and the token balance agree");
        MarketState memory st = lens.marketState(bigMid);
        assertEq(read.poolLent(bigMid), 0, "guard: nothing is lent, so the owed leg is the only unpaid word left in NAV");

        uint256 drift = read.poolOwed(bigMid);
        emit log_named_uint("drift at 18 decimals, in wei", drift);
        emit log_named_uint("the bound the two floors used to reach, N_legs * units/1e18", BIG_LEGS * (BIG_DRAW / 1e18));
        emit log_named_uint("resting dust the withdraw door floors separately", st.cash);
        /// @dev WAS `assertGt(drift, BIG_LEGS)` and a closed form beneath it. The credit reaches the pool
        /// @dev unfloored, so what a drained set of positions leaves behind is nothing at all.
        assertEq(drift, 0, "NOT A WEI, AT ANY DECIMALS: the second floor that stranded them is deleted");
        /// @dev The vault holds its cash, so its NAV is its balance plus the hub's pool for it, with nothing resting.
        assertEq(ace.restingOf(bigMid), 0, "nothing the vault funds rests between calls");
        assertEq(v.grossNav(), big.balanceOf(address(v)) + ace.lenderAssets(address(v), address(big)), "the vault's NAV is its cash plus the hub's pool");
        assertEq(v.grossNav(), v.idle(), "and with every claim drained, nothing uncashable stands beside the cash");

        // ---- the clamp: the same rig driven DOWN, which is where a bare subtraction underflows ----
        uint256 doomed = _borrow(v, BIG_DRAW);
        _crank(v, doomed, bigT, 0);
        uint256 deferred = v.unvested();
        uint256 grossBefore = v.grossNav();
        assertGt(deferred, 0, "LIVENESS: there is a real ladder for the fall to have to retire");
        _finalizeBig(doomed);
        uint256 loss = grossBefore - v.grossNav();
        assertGt(loss, deferred, "LIVENESS: the fall is the bigger of the two, so a bare `g - m` underflows");

        v.collectFee(); // the sync that takes the fall; a bare `g - m` panics 0x11 on this very line
        assertEq(v.unvested(), 0, "the fall retired the whole ladder instead of subtracting into a panic");
        assertEq(v.totalAssets(), v.grossNav(), "so the view is the aggregate itself, with nothing deducted");
        assertGt(v.totalAssets(), 0, "the vault survived the pass rather than bricking on it");
        uint256 sh = v.balanceOf(alice) / 10;
        assertGt(_requestAndClaim(v, alice, sh), 0, "and the exit is still servable");
    }

    // ---- helpers ----

    function _min(uint256 a, uint256 b) internal pure returns (uint256) {
        return a < b ? a : b;
    }

    /// @dev Draw a small loan off what still rests at T2, book it and repay it whole.
    /// @dev The next crank then collects past its cost, which is the ONE thing that stamps the ladder.
    function _closeAFreshLoan(CuratorVault v) internal {
        uint256 fresh = _open(500e6);
        _crank(v, fresh, T2, 0);
        _repay(fresh, lens.loan(fresh).debt);
    }

    /// @dev Take the lender's whole pot at this tick in kind, if the loan settled and left one.
    /// @dev Swallowed rather than guarded: an unsettled loan or an empty pot is a skipped op, not a failure.
    /// @dev NO MINT LEG ANY MORE: the pot is the one lender's outright, so there was never a balance to check.
    function _tryBurn(address who, uint256 loanId, int24 tick) internal {
        vm.prank(who);
        try ace.redeemInKind(loanId, who) {} catch {}
    }

    MockERC20 internal big; // the 18-decimal quote the drift leg runs on
    MockPersistenceRecord internal bigRec; // its own record: a mock speaks for ONE (quote, collateral) frame
    bytes32 internal bigMid;
    uint256 internal bigT; // par on the 18-decimal rig's own pair

    function _repayBig(uint256 loanId, uint256 amt) internal {
        big.mint(borrower, amt);
        vm.startPrank(borrower);
        big.approve(address(ace), amt); // the hub pulls the asset
        ace.repay(loanId, amt);
        vm.stopPrank();
    }
}
