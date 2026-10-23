// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.36;

import {Test, console2} from "forge-std/Test.sol";
import {StdInvariant} from "forge-std/StdInvariant.sol";
import {AceLens} from "../../src/ace/lens/AceLens.sol";
import {AceInventoryLens} from "../../src/ace/lens/AceInventoryLens.sol";
import {BookedQuote} from "../utils/BookedQuote.sol";
import {AceUnsoldPotsHandler} from "./AceUnsoldPotsHandler.sol";

/// @title AceUnsoldPotsInvariants
/// @notice THE UNSOLD-POT COUNT, WALKED: every settle door, every emptying verb, a roll and an empty-pot buy between them.
/// @notice g. The pair's count EQUALS the loans whose pot holds units, counted by a ghost that reads each pot raw.
/// @notice h. Every action moves the count by exactly the pots it filled minus the pots it emptied (the step law).
/// @notice i. A buy at or over `AceInventoryLens.clearingBudget` always empties the pot.
/// @notice j-l. The settled word, on the same walk: every pot ever filled, never under the unsold word, one per settlement.
/// @notice m-o. The per-collateral split: each collateral's `lent` is its raw claims, its units its raw pots, and the `lent`s sum to the pool's.
/// @notice a-f of `AceAskDecimalsInvariants` hold under this walk too: solvency, and every buy check its handler latches.
/// @dev The count SATURATES at zero, so an under-count is invisible to the hub; g and h are its only detector.
/// @dev Weighted: a third of the walk settles and a third empties, so every run moves the count both ways.
/// @dev Config (foundry.toml [invariant]): runs = 256, depth = 32, fail_on_revert = false.
contract AceUnsoldPotsInvariantsTest is StdInvariant, Test {
    AceUnsoldPotsHandler internal handler;

    function setUp() public {
        handler = new AceUnsoldPotsHandler();
        AceLens lens = new AceLens(address(handler.ace()));
        handler.setInventoryLens(new AceInventoryLens(address(handler.ace()), address(lens)));
        bytes4[] memory sel = new bytes4[](27);
        sel[0] = AceUnsoldPotsHandler.tForceClose.selector;
        sel[1] = AceUnsoldPotsHandler.tForceClose.selector;
        sel[2] = AceUnsoldPotsHandler.tForceClose.selector;
        sel[3] = AceUnsoldPotsHandler.tFinalize.selector;
        sel[4] = AceUnsoldPotsHandler.tFinalize.selector;
        sel[5] = AceUnsoldPotsHandler.tFinalize.selector;
        sel[6] = AceUnsoldPotsHandler.tSettleExpired.selector;
        sel[7] = AceUnsoldPotsHandler.tSettleExpired.selector;
        sel[8] = AceUnsoldPotsHandler.tSettleExpired.selector;
        sel[9] = AceUnsoldPotsHandler.tEmptyWhole.selector;
        sel[10] = AceUnsoldPotsHandler.tEmptyWhole.selector;
        sel[11] = AceUnsoldPotsHandler.tEmptyWhole.selector;
        sel[12] = AceUnsoldPotsHandler.tEmptyWhole.selector;
        sel[13] = AceUnsoldPotsHandler.tEmptyWhole.selector;
        sel[14] = AceUnsoldPotsHandler.tRedeemInKind.selector;
        sel[15] = AceUnsoldPotsHandler.tRedeemInKind.selector;
        sel[16] = AceUnsoldPotsHandler.tRedeemInKind.selector;
        sel[17] = AceUnsoldPotsHandler.tBuy.selector;
        sel[18] = AceUnsoldPotsHandler.tOpen.selector;
        sel[19] = AceUnsoldPotsHandler.tOpen.selector;
        sel[20] = AceUnsoldPotsHandler.tBuyEmpty.selector;
        sel[21] = AceUnsoldPotsHandler.tBuyEmpty.selector;
        sel[22] = AceUnsoldPotsHandler.tRepay.selector;
        sel[23] = AceUnsoldPotsHandler.tArmRoll.selector;
        sel[24] = AceUnsoldPotsHandler.tWarp.selector;
        sel[25] = AceUnsoldPotsHandler.tRollAtExpiry.selector;
        sel[26] = AceUnsoldPotsHandler.tCollect.selector;
        targetSelector(FuzzSelector({addr: address(handler), selectors: sel}));
        targetContract(address(handler));
    }

    /// @notice Every property, on ONE walk.
    /// @dev Named apart from `invariant_all` and `invariant_askDecimalsAll`, so `--match-test` names this campaign alone.
    function invariant_unsoldPotsAll() public view {
        _invariant_gTheCountIsTheNonEmptyPots();
        _invariant_hTheStepLaw();
        _invariant_iTheClearingBudgetClears();
        _invariant_aSolvency();
        _invariant_bcdfTheBuyChecks();
        _invariant_jSettledIsEveryPotEverFilled();
        _invariant_kUnsoldNeverExceedsSettled();
        _invariant_lEverySettlementLeftAPot();
        _invariant_mEachCollateralsLentIsItsClaims();
        _invariant_nTheLentSplitSumsToThePool();
        _invariant_oEachCollateralsUnitsAreItsPots();
    }

    // ---- the per-collateral split: every market here is the one market of its collateral, so a raw market sum is the triple's ----

    /// @notice m. Each collateral's `lent` EQUALS its market's live claims, summed raw by the ghost.
    /// @dev The split saturates at zero, so an under-count is invisible to the hub; this equality is its detector.
    function _invariant_mEachCollateralsLentIsItsClaims() internal view {
        for (uint256 i; i < 3; i++) {
            (uint256 lent,) = handler.splitOf(i);
            assertEq(lent, handler.rawLentOf(i), "m: a collateral's lent != its market's raw claims");
        }
    }

    /// @notice n. The three collaterals' `lent` sum to the pool's `lent`, read off the pool's own word.
    function _invariant_nTheLentSplitSumsToThePool() internal view {
        uint256 sum;
        for (uint256 i; i < 3; i++) {
            (uint256 lent,) = handler.splitOf(i);
            sum += lent;
        }
        (, uint256 pooled,) = handler.read().lenderPools(handler.lender(), address(handler.usdc()));
        assertEq(sum, pooled, "n: the collaterals' lent do not sum to the pool's lent");
    }

    /// @notice o. Each collateral's unsold units EQUAL its market's settled pots, summed raw by the ghost.
    function _invariant_oEachCollateralsUnitsAreItsPots() internal view {
        for (uint256 i; i < 3; i++) {
            (, uint256 units) = handler.splitOf(i);
            assertEq(units, handler.rawUnitsOf(i), "o: a collateral's unsold units != its market's raw pots");
        }
    }

    function _invariant_gTheCountIsTheNonEmptyPots() internal view {
        assertEq(_count(), handler.nonEmptyPots(), "g: the pair's unsold count != the loans whose pot holds units");
    }

    function _invariant_hTheStepLaw() internal view {
        if (handler.stepLawBroken()) {
            console2.log("STEP BREACH verb", handler.stepBreachVerb());
            console2.log("  count before / after", handler.stepBreachBefore(), handler.stepBreachAfter());
            console2.log("  pots filled / emptied", handler.stepBreachFilled(), handler.stepBreachEmptied());
        }
        assertFalse(handler.stepLawBroken(), "h: an action moved the count by other than the pots it filled minus the pots it emptied");
    }

    function _invariant_iTheClearingBudgetClears() internal view {
        if (handler.clearingBudgetMissed()) console2.log("CLEARING MISS loan / budget", handler.missLoan(), handler.missBudget());
        assertFalse(handler.clearingBudgetMissed(), "i: a buy at or over the clearing budget left the pot nonempty");
    }

    /// @notice a. The same equality `AceAskDecimalsInvariants` asserts, under this walk's settles and in-kind exits.
    function _invariant_aSolvency() internal view {
        address[] memory lenders = new address[](1);
        lenders[0] = handler.lender();
        assertEq(
            handler.usdc().balanceOf(address(handler.ace())),
            BookedQuote.total(handler.ace(), handler.read(), handler.markets(), lenders, address(handler.usdc())),
            "a: hub balance != market pots + feeEscrows + pooled credit"
        );
    }

    function _invariant_bcdfTheBuyChecks() internal view {
        if (handler.anyBreach()) {
            console2.log("BREACH loan / budget", handler.breachLoan(), handler.breachBudget());
            console2.log("       units / charge", handler.breachUnits(), handler.breachCharge());
            console2.logBytes4(handler.unexpectedRefusalSelector());
        }
        assertFalse(handler.anyBreach(), "b-d, f: a buy broke a check the ask-decimals handler latches");
    }

    /// @notice A DETERMINISTIC coverage proof on the live fixture: every door and every exit moves the count by its own pots.
    /// @dev The latch below proves the walk moved the count both ways; this proves each VERB's direction, on no seed's luck.
    function test_Coverage_EachVerbMovesTheCountByItsOwnPots() public {
        uint256 c0 = _count();
        assertEq(c0, 3, "PREMISE: the baseline leaves one unsold pot per market");
        uint256 rolls = handler.rollsLanded();
        handler.tRollAtExpiry(0);
        assertEq(handler.rollsLanded(), rolls + 1, "PREMISE: the armed loan rolled into a successor rather than settling");
        assertEq(_count(), c0, "a roll at expiry writes no pot, so the count stands");

        handler.tFinalize(0);
        assertEq(handler.finalizesLanded(), 1, "PREMISE: finalize settled a live loan");
        assertEq(_count(), c0 + 1, "a distress settlement that leaves a pot counts one");
        handler.tSettleExpired(0);
        assertEq(handler.settleExpiredsLanded(), 1, "PREMISE: the backstop settled a live loan");
        assertEq(_count(), c0 + 2, "the unpaid backstop's pot counts one");
        uint256 settles = handler.settlesLanded();
        handler.tForceClose(0);
        assertEq(handler.settlesLanded(), settles + 1, "PREMISE: the paid expiry door settled a live loan");
        assertEq(_count(), c0 + 3, "the paid expiry door's pot counts one");

        handler.tEmptyWhole(0, 0);
        assertEq(_count(), c0 + 2, "a buy at the exact clearing budget empties its pot and takes one off");
        handler.tEmptyWhole(0, 1);
        assertEq(_count(), c0 + 1, "a buy over the clearing budget does the same");
        handler.tRedeemInKind(0);
        assertEq(_count(), c0, "the lender's in-kind redeem takes one off");
        handler.tBuyEmpty(0, 1e6);
        assertEq(handler.emptyPotBuys(), 1, "PREMISE: a buy on an empty pot landed while other pots were counted");
        assertEq(_count(), c0, "and it took no other pot's count");

        assertEq(handler.potsFilled(), 3, "the ghost saw three pots fill");
        assertEq(handler.potsEmptied(), 3, "and three empty");
        assertEq(_count(), handler.nonEmptyPots(), "g holds at the end");
        assertFalse(handler.stepLawBroken(), "h held on every step");
        assertFalse(handler.clearingBudgetMissed(), "i held on both clearing buys");
        assertFalse(handler.anyBreach(), "and every buy check held");
    }

    function _count() internal view returns (uint256 n) {
        (n,) = handler.ace().lenderUnresolved(handler.lender(), address(handler.usdc()));
    }

    // ---- the settled count: the second word, on the same walk ----

    /// @notice j. The settled word EQUALS every pot that ever held units: those holding units now, read raw, plus those the walk emptied.
    /// @dev Forge asserts it after EVERY call, so it is also the step law: each action moves the word by exactly the pots it filled.
    /// @dev An emptying door fills none, so it never moves the word; the birth premise is `test_Coverage_SettledStartsAtTheUnsoldBaseline`.
    function _invariant_jSettledIsEveryPotEverFilled() internal view {
        assertEq(_settled(), handler.nonEmptyPots() + handler.potsEmptied(), "j: the settled count != the pots holding units plus the pots emptied");
    }

    /// @notice k. A pot is settled before it can be unsold, so the unsold word never exceeds the settled one.
    function _invariant_kUnsoldNeverExceedsSettled() internal view {
        assertLe(_count(), _settled(), "k: the unsold count exceeds the settled count");
    }

    /// @notice l. Every settlement the walk lands leaves a pot: the raw settled loans equal the pots ever filled.
    /// @dev So the pot gate's false arm is never taken here, and a raise ungated on the pot reads identically on this walk.
    function _invariant_lEverySettlementLeftAPot() internal view {
        assertEq(handler.settledLoans(), handler.nonEmptyPots() + handler.potsEmptied(), "l: a settlement in the walk left no pot");
    }

    function _settled() internal view returns (uint256) {
        return handler.settledNow();
    }

    /// @notice The birth premise j reads off: before the walk no settled pot has emptied, so j needs no stored baseline.
    function test_Coverage_SettledStartsAtTheUnsoldBaseline() public view {
        assertEq(_settled(), 3, "PREMISE: the parent's baseline settled one pot per market");
        assertEq(_count(), _settled(), "and emptied none of them, so every pot ever settled still holds units");
        assertEq(handler.nonEmptyPots(), _settled(), "the raw pot ghost agrees");
        assertEq(handler.settledLoans(), _settled(), "and so does the raw settlement ghost");
        assertEq(handler.potsFilled() + handler.potsEmptied(), 0, "the transition ghosts start at zero");
    }

    /// @notice The STEP LAW on the second word, verb by verb on the live fixture: a settlement moves it by one, nothing else moves it.
    /// @dev Deterministic, so each verb's direction is pinned on no seed's luck; j asserts the same law after every fuzzed call.
    function test_Coverage_EachVerbMovesSettledByItsOwnFills() public {
        uint256 s0 = _settled();
        uint256 rolls = handler.rollsLanded();
        handler.tRollAtExpiry(0);
        assertEq(handler.rollsLanded(), rolls + 1, "PREMISE: the armed loan rolled into a successor rather than settling");
        assertEq(_settled(), s0, "a roll settles nothing");

        handler.tFinalize(0);
        assertEq(handler.finalizesLanded(), 1, "PREMISE: finalize settled a live loan");
        assertEq(_settled(), s0 + 1, "a distress settlement counts one");
        handler.tSettleExpired(0);
        assertEq(handler.settleExpiredsLanded(), 1, "PREMISE: the backstop settled a live loan");
        assertEq(_settled(), s0 + 2, "the unpaid backstop counts one");
        uint256 settles = handler.settlesLanded();
        handler.tForceClose(0);
        assertEq(handler.settlesLanded(), settles + 1, "PREMISE: the paid expiry door settled a live loan");
        assertEq(handler.rollsLanded(), rolls + 1, "PREMISE: and did not roll it");
        assertEq(_settled(), s0 + 3, "the paid expiry door counts one");

        uint256 emptied = handler.potsEmptied();
        handler.tEmptyWhole(0, 0);
        handler.tEmptyWhole(0, 1);
        handler.tRedeemInKind(0);
        assertEq(handler.potsEmptied(), emptied + 3, "PREMISE: two clearing buys and a redeem each emptied a pot");
        assertEq(_settled(), s0 + 3, "and no emptying door moved the settled count");
        handler.tBuyEmpty(0, 1e6);
        assertEq(handler.emptyPotBuys(), 1, "PREMISE: a buy on an empty pot landed while other pots were counted");
        assertEq(_settled(), s0 + 3, "nor did a buy on an empty pot");

        assertEq(handler.potsFilled(), 3, "the ghost saw three pots fill, one per settlement");
        _invariant_jSettledIsEveryPotEverFilled();
        _invariant_kUnsoldNeverExceedsSettled();
        _invariant_lEverySettlementLeftAPot();
    }

    /// @notice The campaign report, and the COVERAGE LATCH: the walk moved the count up and down by its own actions.
    /// @dev The counters exclude the parent's baseline and the handler's constructor, so the baseline cannot satisfy them.
    function afterInvariant() public view {
        console2.log("=== AceUnsoldPotsHandler verb hits ===");
        console2.log("pots filled / emptied ", handler.potsFilled(), handler.potsEmptied());
        console2.log("pair 0->n / n->0      ", handler.pairOpened(), handler.pairCleared());
        console2.log("count / ghost now     ", _count(), handler.nonEmptyPots());
        console2.log("forceClose calls      ", handler.callCount("forceClose"));
        console2.log("finalize calls/landed ", handler.callCount("finalize"), handler.finalizesLanded());
        console2.log("settleExpired c/landed", handler.callCount("settleExpired"), handler.settleExpiredsLanded());
        console2.log("  settles landed, all ", handler.settlesLanded());
        console2.log("emptyWhole calls/buys ", handler.callCount("emptyWhole"), handler.clearingBuys());
        console2.log("redeems landed        ", handler.redeemsLanded());
        console2.log("buy calls / fills     ", handler.callCount("buy"), handler.fillsLanded());
        console2.log("empty-pot buys counted", handler.emptyPotBuys());
        console2.log("rollAtExpiry calls    ", handler.callCount("rollAtExpiry"));
        console2.log("arms / rolls landed   ", handler.armsLanded(), handler.rollsLanded());
        console2.log("open calls / landed   ", handler.callCount("open"), handler.opensLanded());
        console2.log("repays landed         ", handler.repaysLanded());
        console2.log("isolated split moves  ", handler.isolatedMoves());
        assertGt(handler.potsFilled(), 0, "COVERAGE: no fuzzed action filled a pot, so the count's +1 never ran under the walk");
        assertGt(handler.potsEmptied(), 0, "COVERAGE: no fuzzed action emptied a pot, so the count's -1 never ran under the walk");
        assertGt(handler.isolatedMoves(), 0, "COVERAGE: no action moved one collateral's split while another stood, so m-o never saw a split");
    }
}
