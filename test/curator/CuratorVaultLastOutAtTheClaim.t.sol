// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.36;

import {CuratorVaultBase} from "./CuratorVaultBase.sol";
import {CuratorVault, Listing} from "../../src/curator/CuratorVault.sol";
import {AceVault, VaultConfig} from "../../src/curator/AceVault.sol";

/// @notice A vault whose NAV a test can grow by a set amount, as a product's override may add NAV the base does not see.
contract LastOutGrownNavVault is CuratorVault {
    uint256 public extra;

    constructor(VaultConfig memory cfg, Listing[] memory l) CuratorVault(cfg, 10e6, 1.4e18, 1 days, l, "Grown", "cGROW") {}

    function grow(uint256 amount) external {
        extra += amount;
    }

    function totalAssets() public view override returns (uint256) {
        return super.totalAssets() + extra;
    }
}

/// @title CuratorVaultLastOutAtTheClaim
/// @notice A vault whose every holder requests is wound down by its claims: the requests are paid every wei of cash, up to their worth.
/// @notice A yield or a recovery standing in idle is held for the requests whenever it landed, so it still reaches them.
/// @dev The curator re-requesting its fee shares after every round keeps no free holder alive for long, so the release comes and nothing strands.
contract CuratorVaultLastOutWindDownTest is CuratorVaultBase {
    uint16 internal constant BPS = 2000; // a live fee, so the curator is a holder that has to leave too
    uint64 internal constant ROUND = 6 hours; // the wait between rounds of claims
    uint256 internal constant ALICE_IN = 10_000e6;
    uint256 internal constant BOB_IN = 5_000e6;
    uint256 internal constant GROWTH = 2_000e6; // repaid early: the charged cycle that gives the curator shares
    uint256 internal constant PREMIUM = 1_000e6; // repaid just before the requests: its premium is still vesting
    uint256 internal constant ARRIVAL = 3_000e6; // repaid between the first two rounds, as plain extra cash
    uint256 internal constant DOOMED = 2_000e6; // settled after the first claims: the fall
    uint256 internal constant RECOVERY_BPS = 12_500; // the sale beats the drop, so the vest lifts NAV past the high-water and mints fee shares
    uint256 internal constant DONATED = 1; // one share-wei sent to the vault: the only supply nobody can redeem
    uint256 internal constant DUST = 10; // asset-wei: the virtual and donated shares' slice of the last pot, plus rounding

    CuratorVault internal v;
    uint256 internal premiumLoan;
    uint256 internal arrivalLoan;
    uint256 internal doomedLoan;

    /// @dev Every requester claims its whole request, or what exitable covers of it. Low-level: a refusal must not end the wind-down early.
    function _claimAll() internal {
        address[3] memory who = [alice, bob, curator];
        for (uint256 i; i < who.length; i++) {
            (uint256 esc,) = v.requestOf(who[i]);
            if (esc == 0) continue;
            vm.prank(who[i]);
            (bool ok,) = address(v).call(abi.encodeCall(AceVault.claimExit, (esc, who[i], 0)));
            if (ok) continue;
            uint256 m = v.maxClaim(who[i]);
            if (m == 0) continue;
            vm.prank(who[i]);
            (ok,) = address(v).call(abi.encodeCall(AceVault.claimExit, (m, who[i], 0)));
        }
    }

    /// @dev The curator requests every fee share it was minted since it last asked.
    function _requeueFeeShares() internal {
        uint256 free = v.balanceOf(curator);
        if (free == 0) return;
        vm.prank(curator);
        (bool ok,) = address(v).call(abi.encodeCall(AceVault.requestExit, (free)));
        ok;
    }

    /// @dev One round of the wind-down: a crank, every claim, and the curator's re-request.
    function _round() internal {
        v.crank();
        _claimAll();
        _requeueFeeShares();
    }

    /// @dev Two LPs, four loans out, and a charged cycle behind them, so the curator holds fee shares.
    function _rig() internal {
        v = _newVault(BPS);
        _lpDeposit(v, alice, ALICE_IN);
        _lpDeposit(v, bob, BOB_IN);
        uint256 growth = _open(GROWTH);
        premiumLoan = _open(PREMIUM);
        arrivalLoan = _open(ARRIVAL);
        doomedLoan = _open(DOOMED);
        _crank(v, growth, T2, 0);
        _repay(growth, read.debtOf(growth));
        _crankAll(v);
        _warpBy(VEST_W);
        v.collectFee();
        assertGt(v.balanceOf(curator), 0, "PREMISE: the curator holds fee shares, so it is a holder that leaves too");
    }

    /// @dev A premium left vesting, one donated share-wei, then every LP and the curator ask for everything.
    function _everyoneRequests() internal {
        _repay(premiumLoan, read.debtOf(premiumLoan));
        _crankAll(v);
        assertGt(v.unvested(), 0, "PREMISE: a premium is still vesting as every holder requests");
        vm.prank(bob);
        v.transfer(address(v), DONATED);
        uint256 aliceAll = v.balanceOf(alice);
        uint256 bobAll = v.balanceOf(bob);
        vm.prank(alice);
        v.requestExit(aliceAll);
        vm.prank(bob);
        v.requestExit(bobAll);
        _requeueFeeShares();
        assertEq(v.balanceOf(alice) + v.balanceOf(bob), 0, "PREMISE: every LP share is requested");
    }

    /// @dev The first round, an arrival of extra cash while the premium keeps vesting, and a second round.
    function _arrivalBetweenRounds() internal {
        _round();
        _warpBy(ROUND / 2);
        _repay(arrivalLoan, read.debtOf(arrivalLoan));
        _crankAll(v);
        _round();
    }

    /// @dev A settlement, then the sale of its inventory, which beats the drop.
    /// @dev `troughRound` runs one round of claims at the sale's own second, BEFORE the sale: the fall is still the whole price there.
    function _fallThenRecovery(bool troughRound) internal returns (uint256 trough) {
        uint256 beforeFall = v.totalAssets();
        _finalize(doomedLoan);
        _crankAll(v);
        trough = v.totalAssets();
        uint256 drop = beforeFall - trough;
        assertGt(drop, DOOMED / 2, "PREMISE: the settlement opened a real fall");
        if (troughRound) {
            _warpAtLeastTo(read.inventoryAskOpensAt(doomedLoan));
            _round();
        }
        uint256 grossTrough = v.grossNav();
        assertGt(_buyPot(keeper, doomedLoan, (drop * RECOVERY_BPS) / 10_000), 0, "PREMISE: the recovery sold");
        _crankAll(v);
        assertGt(v.grossNav(), grossTrough + drop, "PREMISE: the recovery is counted, deferred, and beats the drop");
    }

    /// @dev The whole row: the wind-down, the rounds after the recovery, and the end state.
    /// @dev THE BOOK BOUND IS PRICE-SCALED: the virtual offset's slice of the last claim is unowned and grows with price over par.
    /// @dev So it is DUST plus the most the offset and the donated share-wei were ever worth across the rounds, read before each round.
    /// @dev The donated share counts too: a recovery landing after every holder left prices it far past par, so its slice is no longer dust.
    /// @dev The vault's balance IS its idle, so the same bound holds the cash left on it.
    function _windDown(bool troughRound) internal {
        _rig();
        _everyoneRequests();
        _arrivalBetweenRounds();
        uint256 trough = _fallThenRecovery(troughRound);

        uint256 n = (v.VEST_WINDOW() + ROUND - 1) / ROUND + 2;
        uint256 feeRounds; // rounds after the recovery in which the curator held fresh fee shares to re-request
        uint256 offsetWorth; // the most the virtual-share offset and the donated share-wei were worth before any of those rounds
        for (uint256 i; i < n; i++) {
            uint256 w = v.convertToAssets(1e6 + DONATED);
            if (w > offsetWorth) offsetWorth = w;
            _warpBy(ROUND);
            v.crank();
            _claimAll();
            if (v.balanceOf(curator) != 0) feeRounds++;
            _requeueFeeShares();
        }

        emit log_named_uint("NAV in the trough", trough);
        emit log_named_uint("rounds that minted the curator fresh fee shares", feeRounds);
        emit log_named_uint("rounds after the recovery", n);
        emit log_named_uint("supply left", v.totalSupply());
        emit log_named_uint("of it, still requested", v.requestedShares());
        emit log_named_uint("the vault's own book left", v.grossNav());
        emit log_named_uint("book bound", DUST + offsetWorth);
        emit log_named_uint("cash left on the vault", usdc.balanceOf(address(v)));
        emit log_named_uint("NAV left", v.totalAssets());
        assertEq(v.totalSupply(), DONATED, "the wind-down left redeemable supply behind: it is not donations only");
        assertLe(v.grossNav(), DUST + offsetWorth, "the wind-down stranded the vault's own book");
        assertLe(usdc.balanceOf(address(v)), DUST + offsetWorth, "the wind-down stranded cash on the vault, owed to nobody");
    }

    /// @notice THE WIND-DOWN: every LP and the curator request, and their claims alone pay out every wei of cash.
    /// @dev There is an unvested premium as they ask, an arrival between rounds, and a fall followed by a recovery.
    /// @dev After the recovery, `ceil(VEST_WINDOW / ROUND) + 2` rounds: the vest runs out, the last fee shares are requested and claimed.
    /// @dev The end state is the whole claim: supply is the donated share alone, and the vault holds no more than dust.
    function test_LastOut_AWindDownOfEveryHolderLeavesOnlyDonationsAndAnEmptyPot() public {
        _windDown(false);
    }

    /// @notice THE SAME WIND-DOWN WITH A ROUND OF CLAIMS IN THE TROUGH: the recovery that lands after it still leaves the vault.
    /// @dev Claims are each holder's own, so a round landing between a fall and its recovery is ordinary.
    /// @dev This row pins only the END STATE; who among the holders is paid the recovery is measured apart, not asserted here.
    function test_LastOut_AWindDownWithARoundInTheTroughStillEmptiesTheVault() public {
        _windDown(true);
    }
}

/// @title CuratorVaultLastOutReleaseAtTheClaim
/// @notice The last holders out release the deferral AT THE CLAIM that pays them, so one NAV prices them and the book is theirs.
/// @dev The predicate is "every share is escrow, donation or, for an LP, the curator's", read at the claim before its fee; `maxClaim` replays it.
contract CuratorVaultLastOutReleaseAtTheClaimTest is CuratorVaultBase {
    uint256 internal constant SEED = 20_000e6;
    uint256 internal constant STAKE = 5_000e6;
    uint256 internal constant EXTRA = 1e6; // NAV a subclass adds; under idle's surplus, so idle still covers the escrow
    address internal mallory = address(0xBAD);

    /// @dev Alice the sole holder, every cent idle, a lump standing on the ladder.
    function _premiumThenAllCash(CuratorVault v) internal {
        _lpDeposit(v, alice, SEED);
        uint256 loanId = _open(6_000e6);
        _crank(v, loanId, T2, 0);
        _warpBy(30 days);
        _repay(loanId, lens.loan(loanId).debt);
        _crankAll(v);
        assertGt(v.unvested(), 0, "LIVENESS: a lump is standing on the ladder");
    }

    /// @dev Escrow alice's whole balance as one request.
    function _stand(CuratorVault v) internal returns (uint256 escrow) {
        escrow = v.balanceOf(alice);
        vm.prank(alice);
        v.requestExit(escrow);
    }

    /// @dev Alice claims `shares` of her request, paid to herself.
    function _claim(CuratorVault v, uint256 shares) internal returns (uint256) {
        vm.prank(alice);
        return v.claimExit(shares, alice, 0);
    }

    function _left(CuratorVault v) internal view returns (uint256 shares) {
        (shares,) = v.requestOf(alice);
    }

    /// @dev A fee-charging vault: alice its only holder, a loan out, the fee high-water at NAV, the curator holding nothing, no pile.
    function _feeRigNoPile(CuratorVault v) internal returns (uint256 loanId) {
        _lpDeposit(v, alice, SEED);
        loanId = _open(6_000e6);
        v.crank(); // a sync that charges nothing: the open's own rise is on the ladder, unvested, and the fee reads only the vested part
        _warpBy(2 days); // and vests in full
        v.collectFee(); // the first collection charges the open's premium
        uint256 fee = v.balanceOf(curator); // BEFORE the prank: a read is a call, and a call would eat it
        vm.prank(curator);
        v.transfer(alice, fee); // and the curator hands those shares to alice, so it holds none
        assertEq(v.balanceOf(curator), 0, "LIVENESS: the curator holds no share");
        assertEq(v.unvested(), 0, "LIVENESS: nothing is deferred yet");
    }

    /// @notice THE LAST HOLDER IS PAID THE BOOK: the claim releases before it prices, and one claim takes it all.
    function test_LastOut_AClaimOfTheWholeRequestPaysTheBookAndEmptiesTheVault() public {
        CuratorVault v = _newVault(0);
        _premiumThenAllCash(v);
        uint256 book = v.grossNav();
        uint256 escrow = _stand(v);

        assertEq(v.maxClaim(alice), escrow, "maxClaim did not offer the last holder her whole request");
        uint256 paid = _claim(v, escrow);
        assertApproxEqAbs(paid, book, 1, "the last holder was paid the gross");
        assertEq(v.totalSupply(), 0, "so no share is outstanding after the claim's burn");
        assertEq(v.unvested(), 0, "and the deferral released");
        assertEq(usdc.balanceOf(alice), paid, "the book, paid in one call");
    }

    /// @notice ANY PART CLAIMED BY THE LAST HOLDER RELEASES, AND THE REST PAYS THE BOOK: the request is claimable in parts.
    function testFuzz_LastOut_AnyAskByTheLastHolderReleasesAndTheRestPaysTheBook(uint256 want) public {
        CuratorVault v = _newVault(0);
        _premiumThenAllCash(v);
        uint256 book = v.grossNav();
        uint256 escrow = _stand(v);
        want = bound(want, 1e6, escrow);

        _claim(v, want);
        assertEq(v.unvested(), 0, "the claim released the deferral");
        uint256 left = _left(v);
        if (left != 0 && v.previewRedeem(left) != 0) _claim(v, left);
        assertApproxEqAbs(usdc.balanceOf(alice), book, 3, "the part plus the later claim pay the book");
        assertLe(usdc.balanceOf(alice), book, "and never more");
    }

    /// @notice AN ENTRANT AFTER A PARTIAL LAST-HOLDER CLAIM PAYS FULL NAV AND TAKES NOTHING: the pile left with the release.
    function test_LastOut_AnEntrantAfterAPartialLastHolderClaimPaysFullNavAndTakesNothing() public {
        CuratorVault v = _newVault(0);
        _premiumThenAllCash(v);
        uint256 escrow = _stand(v);
        _claim(v, escrow / 2);
        assertEq(v.unvested(), 0, "the claim released");

        uint256 left = _left(v);
        uint256 residual = v.previewRedeem(left);
        uint256 bobShares = _lpDeposit(v, bob, STAKE);
        assertApproxEqAbs(v.convertToAssets(bobShares), STAKE, 1, "the entrant pays full NAV");
        _warpBy(VEST_W);
        uint256 bobLater = v.convertToAssets(bobShares);
        assertLe(bobLater, STAKE, "a window later the entrant has taken nothing");
        assertGe(bobLater + 1, STAKE, "and lost nothing");
        assertApproxEqAbs(v.previewRedeem(left), residual, 1, "the leftover request keeps its value at the price");
        assertLe(_redeemAll(v, bob), STAKE, "the entrant's whole exit is at most the stake");
    }

    /// @notice UNDER A FEE, THE FEE SHARES A VERB MINTS FIRST DO NOT SHIELD THE LAST LP: her whole instant exit is refused, and her claim releases.
    function test_LastOut_UnderAFeeTheLastLpIsRefusedAtOnceAndHerClaimReleasesThePile() public {
        CuratorVault v = _newVault(2000);
        uint256 loanId = _feeRigNoPile(v);
        _repay(loanId, lens.loan(loanId).debt);
        _crankAll(v); // stamped now, so the wait below vests part of it; every cent is idle, so cash is not what stops the release
        _warpBy(2 hours); // part of the rise vests, so a fee is owed at alice's exit
        uint256 all = v.balanceOf(alice);
        vm.prank(alice);
        vm.expectRevert(AceVault.LastOutVesting.selector);
        v.redeem(all, alice, alice);
        _stand(v);
        uint256 book = v.grossNav();
        assertEq(v.maxClaim(alice), all, "maxClaim did not offer the last LP her whole request");
        uint256 paid = _claim(v, all);

        assertGt(v.balanceOf(curator), 0, "the claim's own collection minted the curator in");
        assertEq(v.unvested(), 0, "and the release ran beside its fee shares");
        assertEq(_left(v), 0, "alice is fully paid");
        assertApproxEqAbs(paid + v.convertToAssets(v.balanceOf(curator)), book, 3, "and the book went to alice and the fee shares alone");
    }

    /// @notice A DONATED SHARE DOES NOT BLOCK THE RELEASE: a share on the vault backs no request and can never claim.
    function test_LastOut_ADonatedShareDoesNotBlockTheRelease() public {
        CuratorVault v = _newVault(0);
        _premiumThenAllCash(v);
        vm.prank(alice);
        v.transfer(address(v), 1);
        uint256 book = v.grossNav();
        uint256 escrow = _stand(v);

        assertEq(v.maxClaim(alice), escrow, "maxClaim did not replay the release past the donation");
        uint256 paid = _claim(v, escrow);
        assertEq(v.unvested(), 0, "the claim released despite the donation");
        assertEq(v.totalSupply(), v.balanceOf(address(v)), "leaving only the donated share");
        assertApproxEqAbs(paid, book, 2, "and paying the book");
    }

    /// @notice WHAT A SUBCLASS ADDS TO NAV IS PAID TO THE LAST HOLDER AT ITS SHARE: the claim prices off the `virtual` door after the release.
    /// @dev Idle is exactly the gross book, so NAV the subclass adds is not cash: the last holder claims half, which idle covers.
    function test_LastOut_ASubclassesAddedNavIsPaidToTheLastHolderInFull() public {
        LastOutGrownNavVault v = new LastOutGrownNavVault(_cfg(0), _listing());
        mid = _doorMarket(v, address(collateral));
        _premiumThenAllCash(v);
        v.grow(EXTRA);
        uint256 g = v.grossNav();
        uint256 escrow = _stand(v);

        uint256 paid = _claim(v, escrow / 2);
        assertEq(v.unvested(), 0, "the last holder's claim did not release");
        assertApproxEqAbs(paid, (g + EXTRA) / 2, 1, "the claim did not pay its half of the gross plus what the subclass adds");
        assertEq(v.totalSupply(), escrow - escrow / 2, "and the claim burned other than its half");
    }

    /// @dev A SOLE holder, a deferral standing, and every wei of it banked into idle.
    function _lastOutWithADeferral(CuratorVault v) internal {
        _lpDeposit(v, alice, SEED);
        uint256 loanId = _open(6_000e6);
        _crank(v, loanId, T2, 0);
        _warpBy(30 days);
        _repay(loanId, lens.loan(loanId).debt);
        _crankAll(v); // banks the premium into idle AND defers the rise, in one sync
        assertGt(v.unvested(), 0, "fixture: a deferral is standing when the last holder leaves");
        assertEq(v.totalSupply(), v.balanceOf(alice), "fixture: one holder, so the exit below is the last");
        assertGe(v.idle(), v.grossNav(), "fixture: idle covers the book, so the claim can pay a full exit");
    }

    /// @notice THE CLAIM RE-PRICES AFTER THE RELEASE: the deferral it retires lifts the payout, so the last holder takes the gross.
    /// @dev MUTATION TARGET: `claimExit` releases, then reads NAV once and collects the fee; read NAV before `_release(g)` and this must fail.
    function test_LastOut_AClaimRePricesAfterTheReleaseAndPaysTheWholeBook() public {
        CuratorVault v = _newVault(0);
        _lastOutWithADeferral(v);
        uint256 sh = v.totalSupply();
        vm.prank(alice);
        v.requestExit(sh);
        uint256 g = v.grossNav();
        uint256 preRelease = v.convertToAssets(sh);
        assertLt(preRelease, g, "PREMISE: the standing deferral is still deducted from the price");

        uint256 paid = _claim(v, sh);
        assertEq(v.totalSupply(), 0, "the last holder really did leave");
        assertEq(v.unvested(), 0, "and the release retired the whole deferral");
        assertGt(paid, preRelease, "LIVENESS: the read after the release really did lift the payout");
        assertApproxEqAbs(paid, g, 2, "so the last holder out took the whole gross book, not a deferred fraction");
    }

    /// @notice A SOLE HOLDER'S REQUEST IS CLAIMABLE WHOLE AT ONCE AND ONE CLAIM TAKES IT, with no residue behind.
    function test_LastOut_ASoleHoldersClaimLeavesNoResidueAtAll() public {
        CuratorVault v = _newVault(0);
        _lastOutWithADeferral(v);
        uint256 held = v.balanceOf(alice); // BEFORE the prank: a read is a call, and a call would eat it
        vm.prank(alice);
        v.requestExit(held);
        assertEq(v.maxClaim(alice), held, "the whole request is claimable at once");

        assertGt(_claim(v, held), 0, "and one claim takes it");
        assertEq(v.totalSupply(), 0, "with no residue behind it: this really was the last out");
        assertEq(v.unvested(), 0, "so the release fired, and nothing is left ownerless");
        assertEq(_left(v) + v.maxClaim(alice), 0, "and the request is spent");
    }

    /// @notice THE OCTANE LIVENESS HALF: a share donated to the vault does not delay the release, so the book is paid whole.
    /// @dev A FREE dust holder does delay it, and that is the ACCEPTED residual: alice is paid at the net price and leaves the pile behind.
    /// @dev So the dust holder collects alice's share of the pile as it vests, at most the pile, and alice is paid the book less it.
    function test_LastOut_ADonationDoesNotDelayTheReleaseAndLosesNoValue() public {
        CuratorVault v = _newVault(0);
        _premiumThenAllCash(v);
        uint256 snap = vm.snapshotState();

        vm.prank(alice);
        v.transfer(address(v), 1);
        uint256 book = v.grossNav();
        uint256 paid = _claim(v, _stand(v));
        assertEq(v.unvested(), 0, "a donated share delayed the release");
        assertApproxEqAbs(paid, book, 2, "and the book was not paid whole");

        vm.revertToState(snap);
        uint256 dust = _lpDeposit(v, mallory, 1); // one asset-wei of free shares: a holder the predicate must count
        uint256 pile = v.unvested();
        book = v.grossNav();
        paid = _claim(v, _stand(v));
        _warpBy(VEST_W); // the pile alice's claim left behind vests to the dust holder
        uint256 dustAfter = v.convertToAssets(dust);
        emit log_named_uint("pile standing at the request", pile);
        emit log_named_uint("book", book);
        emit log_named_uint("alice paid", paid);
        emit log_named_uint("the dust holder's worth once the pile vests", dustAfter);
        assertGt(v.balanceOf(mallory), 0, "PREMISE: the dust holder stayed in");
        assertEq(_left(v), 0, "PREMISE: alice was paid whole");
        assertLe(dustAfter, 1 + pile + 2, "the dust holder took more than the pile");
        assertGe(paid + pile + 2, book, "and alice was paid less than the book less the pile");
    }

    /// @notice A DUST HOLDER BLOCKING THE RELEASE COLLECTS THE CLAIM'S PILE: the accepted residual of a claim at the net price. ACCEPTANCE.
    /// @dev Alice claims whole at once at the net price; the pile her shares would have shared vests to the one free holder.
    function test_LastOut_ADustHolderBlockingTheReleaseCollectsTheClaimsPile() public {
        CuratorVault v = _newVault(0);
        _premiumThenAllCash(v);
        uint256 dust = _lpDeposit(v, mallory, 1);
        _gift(v, 4_000e6); // a fifth of the book, deferred
        v.crank();
        uint256 book = v.grossNav();
        uint256 pile = v.unvested();
        uint256 paid = _claim(v, _stand(v));
        assertEq(_left(v), 0, "alice was not paid whole at once");
        _warpBy(VEST_W);
        uint256 dustAfter = v.convertToAssets(dust);
        emit log_named_uint("the pile at the request", pile);
        emit log_named_uint("the pile handed on: the dust holder's worth once it vests", dustAfter);
        assertLe(dustAfter, 1 + pile + 2, "the dust holder took more than the pile");
        assertGe(paid + pile + 2, book, "and alice was paid less than the book less the pile");
    }
}
