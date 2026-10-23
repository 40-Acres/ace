// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.36;

import {Test, console2} from "forge-std/Test.sol";
import {StdInvariant} from "forge-std/StdInvariant.sol";
import {CuratorVault} from "../../src/curator/CuratorVault.sol";
import {CuratorVaultHandler} from "./CuratorVaultHandler.sol";

/// @title CuratorVaultInvariants
/// @notice THE STATEFUL CAMPAIGN OVER THE CURATOR VAULT'S EXIT REQUEST AND DRAIN, beside its instant exit.
/// @notice R1. The vault's request book is each holder's request as the handler moved it, and sums to `requestedShares`.
/// @notice R2. The vault holds exactly the requests' escrow plus the donated shares.
/// @notice L1. Nothing the vault funds rests in its market between calls.
/// @notice L4. The holds nest: heldReq within exitable within idle, heldReq within the requests' worth, lendable the rest and none draining.
/// @notice R4. An instant exit while lending never pays into what the requests hold, and no exit or claim leaves idle under the roll hold.
/// @notice R5. A claim never pays past exitable or under its minimum; under the drain nothing is lendable.
/// @notice R6. The drain answers its keys, and a lapse lands past the lease and nowhere else.
/// @notice And: the last holders leave nothing behind, the pile gate holds, the fee-free gap moves only by loss, and no verb panics.
/// @dev Config (foundry.toml [invariant]): runs = 256, depth = 32, fail_on_revert = false.
/// @dev THE QUOTE PROPERTY IS ITS OWN CAMPAIGN: folded into the walk, a revert there would abort every other verdict.
/// @dev Properties that cannot be views latch into HANDLER ghosts: forge reverts the state an `invariant_` function writes.
contract CuratorVaultInvariantsTest is StdInvariant, Test {
    uint256 internal constant VAULT_ROOT = 0xb7a4de03362d20465bcc8b45bb9625cb4abe76f109b674085f908e1bc61c7000; // erc7201:ace.curatorvault
    uint256 internal constant MARK_SLOT = VAULT_ROOT + 1; // `navMark`, the namespace's second word after `feeHighWater`

    CuratorVaultHandler internal handler;
    CuratorVault internal vault;

    function setUp() public {
        handler = new CuratorVaultHandler();
        handler.baselineExits(); // pre-snapshot, and it needs the handler's own code deployed to prank from
        vault = handler.vault();
        /// @dev DUPLICATES ARE WEIGHTS: forge draws uniformly from this array, and the request verbs are the subject.
        bytes4[] memory sel = new bytes4[](45);
        sel[0] = CuratorVaultHandler.depositLp.selector;
        sel[1] = CuratorVaultHandler.mintLp.selector;
        sel[2] = CuratorVaultHandler.request.selector;
        sel[3] = CuratorVaultHandler.requestZero.selector;
        sel[4] = CuratorVaultHandler.requestFee.selector;
        sel[5] = CuratorVaultHandler.claimAll.selector;
        sel[6] = CuratorVaultHandler.claimMax.selector;
        sel[7] = CuratorVaultHandler.redeemAtQuote.selector;
        sel[8] = CuratorVaultHandler.claimZero.selector;
        sel[9] = CuratorVaultHandler.cancel.selector;
        sel[10] = CuratorVaultHandler.shuttleShares.selector;
        sel[11] = CuratorVaultHandler.donateShares.selector;
        sel[12] = CuratorVaultHandler.donateOneShare.selector;
        sel[13] = CuratorVaultHandler.donateAssets.selector;
        sel[14] = CuratorVaultHandler.openLoan.selector; // the door is the only way cash leaves for a market, so it takes the recall's weight
        sel[15] = CuratorVaultHandler.openLoan.selector;
        sel[16] = CuratorVaultHandler.collectFee.selector;
        sel[17] = CuratorVaultHandler.openLoan.selector;
        sel[18] = CuratorVaultHandler.repayLoan.selector;
        sel[19] = CuratorVaultHandler.crank.selector;
        sel[20] = CuratorVaultHandler.warpShort.selector;
        sel[21] = CuratorVaultHandler.warpLong.selector;
        sel[22] = CuratorVaultHandler.collectFee.selector;
        sel[23] = CuratorVaultHandler.vaultDoors.selector;
        sel[24] = CuratorVaultHandler.requestAndClaim.selector;
        sel[25] = CuratorVaultHandler.requestAndClaim.selector;
        sel[26] = CuratorVaultHandler.exitAtQuote.selector;
        sel[27] = CuratorVaultHandler.request.selector;
        sel[28] = CuratorVaultHandler.claimMax.selector;
        sel[29] = CuratorVaultHandler.claimWithMin.selector;
        sel[30] = CuratorVaultHandler.repayLoan.selector;
        /// @dev THE ONLY ROUTE TO AN EMPTIED VAULT, which is the whole state the strand property is about.
        sel[31] = CuratorVaultHandler.windDown.selector;
        sel[32] = CuratorVaultHandler.lapseDue.selector;
        sel[33] = CuratorVaultHandler.lapseEarly.selector;
        sel[34] = CuratorVaultHandler.redeemPart.selector;
        sel[35] = CuratorVaultHandler.repayAndClaim.selector;
        sel[36] = CuratorVaultHandler.repayAndClaim.selector;
        /// @dev THE TROUGH'S DRIVERS: a settlement is the only fall, a sale the only recovery.
        sel[37] = CuratorVaultHandler.settleLoan.selector;
        sel[38] = CuratorVaultHandler.sellInventory.selector;
        sel[39] = CuratorVaultHandler.sellInventory.selector;
        /// @dev THE DRAIN, on and off, by each key and by none.
        sel[40] = CuratorVaultHandler.drainOn.selector;
        sel[41] = CuratorVaultHandler.drainOn.selector;
        sel[42] = CuratorVaultHandler.drainOff.selector;
        sel[43] = CuratorVaultHandler.drainOff.selector;
        /// @dev THE WHOLE RECOVERY, the one path on which entry reopens after a settlement.
        sel[44] = CuratorVaultHandler.sellOutAndEnter.selector;
        targetSelector(FuzzSelector({addr: address(handler), selectors: sel}));
        targetContract(address(handler));
    }

    /// @notice Every property below, checked on ONE walk instead of one campaign each.
    /// @dev NAMED APART FROM `AceInvariants.invariant_all`, so `--match-test` and a mutation proof can name this suite.
    function invariant_vaultAll() public view {
        _invariant_R1_theBookIsTheHandlersAndSums();
        _invariant_R2_theEscrowIsHeldExactly();
        _invariant_L1_nothingRests();
        _invariant_L4_theHoldsNest();
        _invariant_theLastHoldersLeaveNothingBehind();
        _invariant_latches();
        _invariant_theEntryAndFeeLatches();
    }

    /// @notice R1: a request moves only by its own verbs, so the book is the handler's ghost and the aggregate is its sum.
    /// @dev The vault is in the walk to pin a zero: no request ever stands for it.
    function _invariant_R1_theBookIsTheHandlersAndSums() internal view {
        uint256 n = handler.participantCount();
        uint256 sum;
        for (uint256 i; i < n; i++) {
            address p = handler.participantAt(i);
            (uint256 s,) = vault.requestOf(p);
            assertEq(s, handler.ghostEscrow(p), "R1: a request moved other than by its own verbs");
            sum += s;
        }
        (uint256 own,) = vault.requestOf(address(vault));
        assertEq(own, 0, "R1: a request stands for the vault itself");
        assertEq(vault.requestedShares(), sum, "R1: the aggregate is not the sum of the requests");
    }

    /// @notice R2: a request moves in exactly what it adds, a cancel or lapse moves it out, and a claim burns exactly its escrow.
    function _invariant_R2_theEscrowIsHeldExactly() internal view {
        assertEq(
            vault.balanceOf(address(vault)), vault.requestedShares() + handler.donatedShares(), "R2: the vault holds other than the escrow and the donations"
        );
    }

    /// @notice L1: the door rests all idle and withdraws every resting unit before it returns, so the vault's market holds no cash between calls.
    function _invariant_L1_nothingRests() internal view {
        assertEq(handler.restingNow(), 0, "L1: vault cash rests in its market between calls");
    }

    /// @notice L4: the holds nest at the walk's end, and no action left them unnested on the way (latched per action).
    function _invariant_L4_theHoldsNest() internal view {
        (uint256 exitable, uint256 held) = vault.holds();
        assertLe(held, exitable, "L4: the requests hold past exitable cash");
        assertLe(exitable, vault.idle(), "L4: exitable cash past idle");
        assertLe(held, vault.convertToAssets(vault.requestedShares()) + 1, "L4: the requests hold past their worth");
        assertEq(vault.lendable(), vault.draining() ? 0 : exitable - held, "L4: lendable is not exitable less the requests' hold");
        if (handler.holdsBroke()) console2.log("HOLDS broke in", handler.holdsTag());
        assertFalse(handler.holdsBroke(), "L4: an action left the holds unnested");
    }

    /// @notice When every exit-capable share has left, what is left is at most the virtual offset's and the donations' slice.
    function _invariant_theLastHoldersLeaveNothingBehind() internal view {
        assertFalse(handler.strandBroken(), "strand: the last holders out left value behind");
    }

    /// @notice R4, R5 and R6, and the zero-valued and vault-owned doors.
    function _invariant_latches() internal view {
        assertFalse(handler.heldTakenByAnExit(), "R4: an instant exit while lending took cash held for requests");
        assertFalse(handler.payUnderRollHold(), "R4: an exit or a claim left idle under the roll hold");
        assertFalse(handler.claimPastExitable(), "R5: a claim paid past exitable cash");
        assertFalse(handler.claimUnderMin(), "R5: a claim paid under its own minimum");
        assertFalse(handler.drainLeftLendable(), "R5: a drain switched on left cash lendable");
        assertFalse(handler.keyBroke(), "R6: the drain answered a key wrong");
        assertFalse(handler.lapsedEarly(), "R6: a lapse landed inside the lease");
        assertFalse(handler.emptyLapseLanded(), "R6: a lapse of an empty record landed");
        assertFalse(handler.dueLapseRefused(), "R6: a lapse past the lease was refused");
        assertFalse(handler.renewMissed(), "R6: a request left the lease other than a full lease from now");
        assertFalse(handler.zeroMovedAnOrder(), "zero: a zero-valued verb moved a request, a balance or the vault's cash");
        assertFalse(handler.vaultDoorOpened(), "vault: a door paid out or lapsed the vault's own balance");
        assertFalse(handler.vaultMovedEscrow(), "vault: the escrow moved across a door on the vault's own balance");
    }

    function _invariant_theEntryAndFeeLatches() internal view {
        if (handler.verbPanicked()) console2.log("PANIC", vm.toString(handler.panicData()));
        assertFalse(handler.verbPanicked(), "panic: a vault verb panicked");
        if (handler.entryUnderAPile()) console2.log("ENTRY pile / nav", handler.entryPile(), handler.entryNav());
        assertFalse(handler.entryUnderAPile(), "entry: a deposit or mint landed while a pile over the entry line vested");
        assertFalse(handler.entrySeamSplit(), "entry: maxDeposit or maxMint disagreed with the verb");
        if (handler.gapGrew()) console2.log("GAP rose / allowed / in", handler.gapRise(), handler.gapAllowed(), handler.gapTag());
        assertFalse(handler.gapGrew(), "fee: the fee-free gap in assets rose past the action's real loss and its rounding");
    }

    /// @notice NO VAULT VERB PANICS, whatever the walk: a refusal is a custom error, and an arithmetic panic is a defect.
    /// @dev ITS OWN CAMPAIGN, so a property broken earlier in `invariant_vaultAll` cannot mask it; printed before it asserts.
    function invariant_aVaultVerbNeverPanics() public view {
        if (handler.verbPanicked()) console2.log("PANIC", vm.toString(handler.panicData()));
        assertFalse(handler.verbPanicked(), "a vault verb panicked");
    }

    /// @notice THE PILE NEVER READS PAST THE MARK: a sync caps its stamp at the gross it observed, and between syncs the pile only decays.
    /// @dev The mark has no getter, so it is read at its slot; `test_theMarkSlotIsTheGrossAfterACrank` pins that slot.
    function invariant_thePileNeverReadsPastTheMark() public view {
        assertLe(vault.unvested(), _navMark(), "vest: the pile read past the gross the last sync observed");
    }

    /// @notice The slot the pile law reads is the mark: a crank syncs, and a sync leaves the mark at the gross it read.
    function test_theMarkSlotIsTheGrossAfterACrank() public {
        handler.crank();
        assertGt(vault.grossNav(), 0, "PREMISE: the seeded vault has a gross");
        assertEq(_navMark(), vault.grossNav(), "the slot read is not the mark");
        invariant_thePileNeverReadsPastTheMark();
    }

    /// @dev The vault's `navMark`, read at its ERC-7201 slot.
    function _navMark() internal view returns (uint256) {
        return uint256(vm.load(address(vault), bytes32(MARK_SLOT)));
    }

    /// @notice THE PROPERTY: `withdraw(maxWithdraw)`, `redeem(maxRedeem)` and `claimExit(maxClaim)` neither revert nor pay anything but the figure.
    /// @dev LATCHED, because `fail_on_revert = false` discards the revert this is about; printed before it asserts.
    function invariant_theQuoteIsServable() public view {
        if (handler.quoteReverted()) {
            console2.log("QUOTE BROKE for / asked", handler.quoteWho(), handler.quoteAsked());
            console2.log("  revert               ", vm.toString(handler.quoteRevertData()));
        }
        assertFalse(handler.quoteReverted(), "quote: a max ask reverted on the figure its own view had just given");
        assertFalse(handler.quoteShort(), "quote: an exit paid something other than what the view quoted");
    }

    /// @notice The wind-down channel, driven once deterministically, because the campaign rarely builds it.
    /// @dev It asserts rather than tallies, so "not chosen" and "cannot run" stay distinguishable.
    function test_windDownReachesTheLastHolderOut() public {
        handler.windDown();
        assertEq(vault.requestedShares(), 0, "wind-down: a request was left standing");
        assertGt(handler.lastOuts(), 0, "wind-down: the vault never paid its last exit-capable share");
        assertFalse(handler.strandBroken(), "wind-down: the last holders out left value behind");
        invariant_vaultAll();
    }

    /// @notice The handler reaches a claim of held cash on a fixed path: two requests hold exitable cash at once, lending stops short of it, and a claim lands.
    function test_theHandlerReachesAHeldClaim() public {
        handler.request(1, type(uint256).max);
        handler.request(2, type(uint256).max);
        (uint256 exitable, uint256 held) = vault.holds();
        assertGt(held, 0, "the requests held none of the exitable cash they found");
        assertEq(vault.lendable(), exitable - held, "lending reaches the cash the requests hold");
        handler.repayAndClaim(0, type(uint256).max, 1);
        assertGt(handler.claimsPaid(), 0, "the first claimer's maxClaim did not land");
        invariant_vaultAll();
    }

    /// @notice A settlement and the claim that sees it, driven once, so the claim latches are judged on a claim in a trough.
    function test_theHandlerReachesADipClaim() public {
        handler.request(1, type(uint256).max);
        handler.settleLoan(0);
        assertGt(handler.loanSettles(), 0, "PREMISE: the loan settled");
        handler.claimMax(1);
        assertGt(handler.dipClaims(), 0, "no claim landed after the settlement");
        invariant_vaultAll();
    }

    /// @notice A whole recovery on a fixed path: a settlement, its pot sold out, an entry judged at the sale, and one landing a vest window on.
    function test_theHandlerReachesAnEntryAfterAWholeRecovery() public {
        handler.settleLoan(0);
        assertGt(handler.loanSettles(), 0, "PREMISE: the loan settled");
        handler.sellOutAndEnter(0, 1);
        assertEq(handler.recoveryEntriesJudged(), 1, "no entry was judged at the whole sale's own second");
        assertEq(handler.cleanRecoveries(), 1, "the whole sale did not leave the run clean");
        assertEq(handler.cleanRecoveriesEntered(), 1, "no judged entry landed a vest window after the whole recovery");
        invariant_vaultAll();
    }

    /// @notice The drain on a fixed path: the guardian's on, an instant exit and a claim under it, the guardian's off refused, the curator's off.
    function test_theHandlerReachesTheDrain() public {
        handler.request(2, type(uint256).max);
        handler.drainOn(2); // the guardian
        assertTrue(vault.draining(), "the guardian's drain did not land");
        handler.exitAtQuote(1);
        handler.claimMax(2);
        assertGt(handler.drainedExits() + handler.drainedClaims(), 1, "an exit and a claim did not both land under the drain");
        handler.drainOff(2); // the guardian, who must be refused
        assertTrue(vault.draining(), "the guardian lifted the drain");
        handler.drainOff(0); // the curator
        assertFalse(vault.draining(), "the curator's switch-off did not land");
        assertEq(handler.drainsOff(), 1, "the switch-off was not counted");
        invariant_vaultAll();
    }

    /// @notice The lapse on a fixed path: refused inside the lease and on an empty record, landed at the lease's end.
    function test_theHandlerReachesALapse() public {
        handler.request(3, type(uint256).max);
        handler.lapseEarly(3);
        handler.lapseEarly(4); // actor 4 holds no request
        assertEq(handler.earlyLapsesRefused(), 1, "a lapse inside the lease was not refused");
        assertEq(handler.emptyLapsesRefused(), 1, "a lapse of an empty record was not refused");
        handler.lapseDue(3);
        assertEq(handler.lapses(), 1, "the lapse at the lease's end did not land");
        invariant_vaultAll();
    }

    /// @notice THE SAME DUST WALK that once panicked the close: dust entries and wind-downs under the fee mark, a donated and a dust share staying.
    function test_theDustExitCyclesNeverPanicAVerb() public {
        handler.donateOneShare(45531248931759264260532641);
        handler.windDown();
        handler.depositLp(14168644756, 12836);
        handler.depositLp(89927269033, 3);
        handler.request(2465989443, type(uint256).max - 3);
        handler.windDown();
        handler.depositLp(272471829066320946114742, 16560);
        handler.windDown();
        handler.mintLp(361032362676008138270541395867763961981942917715112118818178, 327460300085464974464389143985129556732647034290380013084454);
        handler.mintLp(94307574404990638714853480776721298905237640822351887827534, 455);
        handler.windDown();
        handler.depositLp(40311712283, 244996116152242488);
        handler.windDown();
        handler.depositLp(747129474413102336069303354810841379014625313880404262, 67409193386510869264687260139243273911874);
        handler.windDown();
        invariant_aVaultVerbNeverPanics();
    }

    /// @notice THE SAME through mints, dust entries and share shuttles: the deeper walk that once panicked the close.
    function test_theDustMintCyclesNeverPanicAVerb() public {
        handler.windDown();
        handler.mintLp(1038644501826451630060280235992147, 3);
        handler.mintLp(600, 19123);
        handler.depositLp(838, 11748);
        handler.windDown();
        handler.depositLp(421453602762426298132479700090712850178395100778386983476198898, 3630221);
        handler.windDown();
        handler.depositLp(type(uint256).max - 3, 708975759287417113404905624386325035953725202984979242487563);
        handler.windDown();
        handler.shuttleShares(
            18900, 504788114708950406279887359887721550294466783, 53545110726350130136968644664244291917039145576833170621735129739690067886101
        );
        handler.mintLp(5000, 2022917740);
        handler.shuttleShares(
            162562943188789828650644150391752595599557248508701378, 54925112841636657837707793354204855152198016171446748143747427966980458506, 1587848
        );
        handler.windDown();
        handler.depositLp(10084557281884642601314445455960368872833208, 357819528158020);
        handler.windDown();
        handler.mintLp(1800, 1349215147114084691550316547759869276000585007563009);
        handler.mintLp(2564, 6549);
        handler.windDown();
        handler.depositLp(6, 6899);
        handler.windDown();
        invariant_aVaultVerbNeverPanics();
    }

    /// @notice THE ALL-ESCROW RELEASE STRANDS NOTHING ON DONATED SHARES: seed 7's walk, replayed.
    /// @dev A donation, a settlement, a wind-down and a sale: the release at an all-escrow claim prices the pile in, and the strand latch judges it.
    function test_theReleaseEndStrandsNothingOnDonatedShares() public {
        handler.donateShares(775282300840359949055759600025, 9720583473804255409105253);
        handler.settleLoan(21790210469543258161386872598258680450327249339);
        handler.windDown();
        handler.sellInventory(107477464, 255);
        handler.sellInventory(6110060, 55591619685021697909056792707197303036220558103331889927498291960984057197650);
        handler.windDown();
        invariant_vaultAll();
    }

    /// @notice The campaign report, and the coverage guards: a run that tried a verb with a live premise landed it.
    /// @dev Conditional on the run's own tries: forge reverts handler ghosts between runs, so an unconditional guard measures one sequence.
    function afterInvariant() public view {
        console2.log("=== CuratorVaultHandler verb hits ===");
        console2.log("requests stood        ", handler.requestsStood());
        console2.log("  of those, top-ups   ", handler.topUps());
        console2.log("renewals              ", handler.renewals());
        console2.log("cancels               ", handler.cancels());
        console2.log("lapses tried / landed ", handler.lapseTries(), handler.lapses());
        console2.log("  refused early/empty ", handler.earlyLapsesRefused(), handler.emptyLapsesRefused());
        console2.log("claims tried / paid   ", handler.claimTries(), handler.claimsPaid());
        console2.log("  refused, cash short ", handler.claimsRefused());
        console2.log("  in a trough         ", handler.dipClaims());
        console2.log("instant exits paid    ", handler.exitsPaid());
        console2.log("drain tries / on / off", handler.drainTries(), handler.drainsOn(), handler.drainsOff());
        console2.log("  exits / claims under", handler.drainedExits(), handler.drainedClaims());
        console2.log("actions ending held   ", handler.heldReads());
        console2.log("door borrows tried    ", handler.loanTries());
        console2.log("  landed              ", handler.loansOpened());
        console2.log("settles / sales       ", handler.loanSettles(), handler.salesLanded());
        console2.log("whole recoveries      ", handler.callCount("sellOutAndEnter"));
        console2.log("  judged at the sale  ", handler.recoveryEntriesJudged());
        console2.log("  clean / entered     ", handler.cleanRecoveries(), handler.cleanRecoveriesEntered());
        console2.log("quotes served         ", handler.quotesServed());
        console2.log("last holders out      ", handler.lastOuts());
        console2.log("  strand / ceiling    ", handler.lastOutStrand(), handler.lastOutCeiling());
        console2.log("share donations       ", handler.shareDonations());
        console2.log("asset donations       ", handler.assetDonations());
        console2.log("share shuttles        ", handler.shuttles());
        console2.log("zero-valued calls     ", handler.zeroCalls());
        console2.log("vault doors refused   ", handler.vaultDoorsRefused());
        console2.log("wind-downs driven     ", handler.callCount("windDown"));
        if (handler.claimTries() != 0) assertGt(handler.claimsPaid(), 0, "a run tried claims of maxClaim and none landed");
        if (handler.drainTries() != 0) assertGt(handler.drainsOn(), 0, "a run tried the drain by its keys and none landed");
        if (handler.lapseTries() != 0) assertGt(handler.lapses(), 0, "a run tried lapses past the lease and none landed");
        if (handler.loanTries() != 0) assertGt(handler.loansOpened(), 0, "a run tried door borrows inside lendable and none landed");
        uint256 clean = handler.cleanRecoveries();
        if (clean != 0) assertEq(handler.cleanRecoveriesEntered(), clean, "a clean whole recovery saw no judged entry land a vest window on");
    }
}
