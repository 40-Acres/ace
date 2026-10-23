// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.36;

import {Test, console2} from "forge-std/Test.sol";
import {StdInvariant} from "forge-std/StdInvariant.sol";
import {CuratorVault} from "../../src/curator/CuratorVault.sol";
import {CuratorVaultHandler} from "./CuratorVaultHandler.sol";
import {CuratorVaultRollHandler} from "./CuratorVaultRollHandler.sol";

/// @title CuratorVaultRollReserveInvariants
/// @notice THE VAULT CAMPAIGN WITH ROLLS IN IT: armed door borrows, the vault's roll, the holder's retune and disarm, strangers' rolls and folds.
/// @notice L1. Nothing the vault funds rests in its market between calls; the hub's roll reserve stands on paper only.
/// @notice b. `Ace.drawableOf` equals `AceLens.drawableOf` for the vault's market and for an id nobody created.
/// @notice c. The roll reserve is the sum of the live armed loans' shares, and no closed or disarmed loan holds one.
/// @notice L2. The vault's roll hold is exactly the sum of its records, funded and unfunded successors alike.
/// @notice L3. Every live armed reservation in the vault's market sits inside the roll hold.
/// @notice e. No promised roll inside its window is refused for cash or the dust gap, wherever idle stands against the roll hold.
/// @notice And: a prune of an empty book leaves no hold; L4, no exit or claim leaving idle under the hold, is latched by the base handler.
/// @dev Every inherited selector is driven at the base campaign's weights; the new actions are appended with their own weights.
/// @dev The base campaign's properties are NOT re-asserted here: `CuratorVaultInvariants` owns them, on its own walk.
/// @dev Config (foundry.toml [invariant]): runs = 256, depth = 32, fail_on_revert = false.
contract CuratorVaultRollReserveInvariantsTest is StdInvariant, Test {
    CuratorVaultRollHandler internal handler;
    CuratorVault internal vault;

    function setUp() public {
        handler = new CuratorVaultRollHandler();
        handler.baselineExits();
        handler.baselineArm(); // pre-snapshot: one armed loan stands, so every run starts with a roll hold recorded
        vault = handler.vault();

        bytes4[] memory sel = new bytes4[](51);
        sel[0] = CuratorVaultHandler.depositLp.selector;
        sel[1] = CuratorVaultHandler.mintLp.selector;
        sel[2] = CuratorVaultHandler.request.selector;
        sel[3] = CuratorVaultHandler.requestZero.selector;
        sel[4] = CuratorVaultHandler.claimAll.selector;
        sel[5] = CuratorVaultHandler.exitAtQuote.selector;
        sel[6] = CuratorVaultHandler.redeemAtQuote.selector;
        sel[7] = CuratorVaultHandler.claimZero.selector;
        sel[8] = CuratorVaultHandler.cancel.selector;
        sel[9] = CuratorVaultHandler.shuttleShares.selector;
        sel[10] = CuratorVaultHandler.donateShares.selector;
        sel[11] = CuratorVaultHandler.donateOneShare.selector;
        sel[12] = CuratorVaultHandler.donateAssets.selector;
        sel[13] = CuratorVaultHandler.settleLoan.selector;
        sel[14] = CuratorVaultHandler.sellInventory.selector;
        sel[15] = CuratorVaultHandler.collectFee.selector;
        sel[16] = CuratorVaultHandler.openLoan.selector;
        sel[17] = CuratorVaultHandler.repayLoan.selector;
        sel[18] = CuratorVaultHandler.crank.selector;
        sel[19] = CuratorVaultHandler.warpShort.selector;
        sel[20] = CuratorVaultHandler.warpLong.selector;
        sel[21] = CuratorVaultHandler.collectFee.selector;
        sel[22] = CuratorVaultHandler.vaultDoors.selector;
        sel[23] = CuratorVaultHandler.requestAndClaim.selector;
        sel[24] = CuratorVaultHandler.requestAndClaim.selector;
        sel[25] = CuratorVaultHandler.claimMax.selector;
        sel[26] = CuratorVaultHandler.claimMax.selector;
        sel[27] = CuratorVaultHandler.request.selector;
        sel[28] = CuratorVaultHandler.lapseDue.selector;
        sel[29] = CuratorVaultHandler.drainOn.selector;
        sel[30] = CuratorVaultHandler.repayLoan.selector;
        sel[31] = CuratorVaultHandler.windDown.selector;
        sel[32] = CuratorVaultHandler.drainOff.selector;
        sel[33] = CuratorVaultHandler.redeemPart.selector;
        sel[34] = CuratorVaultHandler.claimWithMin.selector;
        sel[35] = CuratorVaultHandler.repayAndClaim.selector;
        sel[36] = CuratorVaultHandler.repayAndClaim.selector;
        /// @dev THE NEW ACTIONS, weighted so each lands a few times per depth-32 run among 51 entries.
        sel[37] = CuratorVaultRollHandler.rollArmed.selector;
        sel[38] = CuratorVaultRollHandler.rollArmed.selector;
        sel[39] = CuratorVaultRollHandler.rollArmed.selector;
        sel[40] = CuratorVaultRollHandler.openAndArm.selector;
        sel[41] = CuratorVaultRollHandler.openAndArm.selector;
        sel[42] = CuratorVaultRollHandler.retuneOrDisarm.selector;
        sel[43] = CuratorVaultRollHandler.retuneOrDisarm.selector;
        sel[44] = CuratorVaultRollHandler.crankClosed.selector;
        sel[45] = CuratorVaultRollHandler.crankClosed.selector;
        sel[46] = CuratorVaultRollHandler.strangerRoll.selector;
        sel[47] = CuratorVaultRollHandler.forceCloseAtExpiry.selector;
        sel[48] = CuratorVaultRollHandler.capCut.selector;
        sel[49] = CuratorVaultRollHandler.capRestore.selector;
        sel[50] = CuratorVaultRollHandler.capRestore.selector;
        targetSelector(FuzzSelector({addr: address(handler), selectors: sel}));
        targetContract(address(handler));
    }

    /// @notice Every property, on ONE walk.
    /// @dev Named apart from `invariant_vaultAll` and `invariant_all`, so `--match-test` names this campaign alone.
    function invariant_rollReserveAll() public view {
        _invariant_L1_nothingRests();
        _invariant_bHubAndLensDrawableAgree();
        _invariant_cTheReserveIsTheSumOfItsShares();
        _invariant_L2_theHoldIsTheSumOfTheRecords();
        _invariant_L3_everyReservationSitsInsideTheHold();
        _invariant_eNoPromisedRollIsStarved();
        _invariant_anEmptyBookHoldsNothing();
        _invariant_L4_noPayLeavesIdleUnderTheHold();
    }

    /// @notice L1. The door and the roll rest all idle and withdraw every resting unit before they return.
    function _invariant_L1_nothingRests() internal view {
        assertEq(handler.restingNow(), 0, "L1: vault cash rests in its market between calls");
    }

    /// @notice b. The hub's view and the lens's view are one number, in the vault's market and at an id nobody created.
    function _invariant_bHubAndLensDrawableAgree() internal view {
        (uint256 hub, uint256 viaLens) = handler.drawablePair(handler.market());
        assertEq(hub, viaLens, "b: Ace.drawableOf and AceLens.drawableOf disagree on the vault's market");
        (uint256 cash, uint256 rr) = handler.restingAndReserve();
        assertEq(hub, cash > rr ? cash - rr : 0, "b: drawableOf is not resting cash less the roll reserve, floored at zero");
        (uint256 hubU, uint256 lensU) = handler.drawablePair(keccak256("no market was ever created at this id"));
        assertEq(hubU, 0, "b: an unknown id reads nonzero on the hub");
        assertEq(lensU, 0, "b: an unknown id reads nonzero on the lens");
    }

    /// @notice c. The reserve is the sum of its loans' shares, held only by live armed loans.
    function _invariant_cTheReserveIsTheSumOfItsShares() internal view {
        (uint256 sum, uint256 rr, bool stray) = handler.reserveLedger();
        assertEq(sum, rr, "c: the roll reserve is not the sum of its loans' shares");
        assertFalse(stray, "c: a closed or disarmed loan still holds a roll reservation");
    }

    /// @notice L2. The hold moves only with its records: a borrow or a roll books one, a prune or a roll drops one.
    function _invariant_L2_theHoldIsTheSumOfTheRecords() internal view {
        assertEq(vault.rollHold(), handler.recordSum(), "L2: the roll hold is not the sum of the vault's records");
    }

    /// @notice L3. The hub's paper reservation for the vault's market never outruns what the vault holds back for it.
    function _invariant_L3_everyReservationSitsInsideTheHold() internal view {
        (, uint256 rr) = handler.restingAndReserve();
        assertLe(rr, vault.rollHold(), "L3: a live armed reservation sits outside the vault's roll hold");
    }

    /// @notice e. A promised roll is never refused for want of cash: the hold backs every promise, even once a roll spent idle under it.
    /// @dev `RollNotLendable` is outside it: a draw past the record is new lending, which the legs, lendable or the room may refuse.
    function _invariant_eNoPromisedRollIsStarved() internal view {
        if (handler.rollStarved()) {
            console2.log("STARVED loan / why", handler.starvedLoan(), vm.toString(abi.encodePacked(handler.starvedWhy())));
            console2.log("STARVED idle / hold", handler.starvedIdle(), handler.starvedHold());
        }
        assertFalse(handler.rollStarved(), "e: a promised roll inside its window was refused for cash");
    }

    /// @notice The hold returns to zero once `crank(closed)` prunes a book with no live recorded loan.
    function _invariant_anEmptyBookHoldsNothing() internal view {
        assertFalse(handler.holdStuck(), "prune: an empty book kept a roll hold");
    }

    /// @notice L4. Latched per pay by the base handler, asserted here too because only this walk stands a hold.
    /// @dev Idle MAY sit under the hold between pays: a roll spends its cover out of it, and lending and exits then wait for repayments.
    function _invariant_L4_noPayLeavesIdleUnderTheHold() internal view {
        assertFalse(handler.payUnderRollHold(), "L4: an exit or a claim left idle under the roll hold");
        assertFalse(handler.holdsBroke(), "L4: an action left the holds unnested");
    }

    /// @notice THE NEW CHANNELS, driven once in order, so "never chosen" and "cannot land" stay distinguishable.
    /// @notice A second loan opens armed at the door, nothing rests after either, and the first armed loan rolls by the vault inside its window.
    /// @dev Every property is then asserted on the state that sequence built, which a depth-32 walk reaches only sometimes.
    function test_TheRollChannelsLand() public {
        uint256[] memory before = handler.loanIds();
        uint256 armed = before[before.length - 1]; // the baseline's armed loan
        handler.openAndArm(20e6); // `bound` keeps an in-range seed as it is
        assertEq(handler.armedOpens(), 2, "PREMISE: a second armed loan opened beside the baseline's");
        (uint256 cash,) = handler.restingAndReserve();
        assertEq(cash, 0, "and the door left nothing resting");
        uint256[] memory ids = handler.loanIds();
        (uint128 need2, bool funded2) = vault.rollOf(ids[ids.length - 1]);
        assertTrue(need2 != 0 && funded2, "the second armed loan recorded a promised roll");

        uint256 seed;
        for (uint256 i; i < ids.length; i++) {
            if (ids[i] == armed) seed = i;
        }
        handler.rollArmed(seed, 1); // mode 1 rolls inside the window
        assertEq(handler.rollsLanded(), 1, "the vault rolled the baseline's armed loan inside its window");
        assertEq(handler.successorsFunded(), 1, "and recorded its successor with a promise");
        (cash,) = handler.restingAndReserve();
        assertEq(cash, 0, "and the roll left nothing resting");
        invariant_rollReserveAll();
    }

    /// @notice A promised chain rolled from idle drained to the hold: three rolls in their windows, and property e on the state they leave.
    /// @dev The walk reaches idle exactly at the hold only sometimes, so this drives it there: a promise the hold cannot back starves here.
    function test_APromisedChainRolledFromTheHoldNeverStarves() public {
        uint256[] memory before = handler.loanIds();
        uint256 seed = before.length - 1; // the baseline's armed loan; each successor is tracked after it
        for (uint256 i; i <= handler.actorCount(); i++) {
            handler.exitAtQuote(i);
        }
        for (uint256 i; i <= handler.actorCount(); i++) {
            handler.claimMax(i);
        }
        assertEq(vault.idle(), vault.rollHoldNow(), "PREMISE: idle sits exactly at the hold");
        assertEq(vault.lendable(), 0, "PREMISE: and nothing is lendable");
        for (uint256 k; k < 3; k++) {
            handler.rollArmed(seed, 1); // mode 1 rolls inside the window
        }
        assertEq(handler.rollTries(), 3, "PREMISE: every roll found a recorded live loan");
        assertGt(handler.rollsLanded(), 0, "PREMISE: the promised roll ran from the hold");
        invariant_rollReserveAll();
    }

    /// @notice The campaign report, and coverage: a run that tried a promised roll in its window landed one, unless each such try was ruled out.
    /// @dev Read the SUCCESS ghosts: a selector hit says nothing about whether its channel landed.
    function afterInvariant() public view {
        console2.log("=== CuratorVaultRollHandler verb hits ===");
        console2.log("armed opens           ", handler.armedOpens());
        console2.log("retunes / disarms     ", handler.retunesLanded(), handler.disarmsLanded());
        console2.log("  arms refused unbacked", handler.armsUnbacked());
        console2.log("  arms refused other  ", handler.armsRefusedOther());
        console2.log("hold peak             ", handler.holdPeak());
        console2.log("rolls tried / in window", handler.rollTries(), handler.rollsInWindow());
        console2.log("  in window, ruled out", handler.rollsRuledOut());
        console2.log("  landed / late       ", handler.rollsLanded(), handler.lateRollsLanded());
        console2.log("  successors funded   ", handler.successorsFunded());
        console2.log("  successors unfunded ", handler.successorsUnfunded());
        console2.log("  never recorded      ", handler.successorsUnrecorded());
        console2.log("  refused             ", handler.rollsRefused());
        console2.log("  last refusal        ", vm.toString(abi.encodePacked(handler.lastRollRefusal())));
        console2.log("stranger rolls landed / refused", handler.strangerRollsLanded(), handler.strangerRollsRefused());
        console2.log("stranger folds landed ", handler.forceClosesLanded());
        console2.log("prunes / empty book   ", handler.cranksClosed(), handler.emptyBookPrunes());
        console2.log("cap cuts / restores   ", handler.capCuts(), handler.capRestores());
        console2.log("hold now              ", vault.rollHold());
        bool owed = handler.rollsInWindow() > handler.rollsRuledOut(); // a `RollNotLendable` try is new lending the legs may refuse
        if (owed) assertGt(handler.rollsLanded(), 0, "a run tried promised rolls in their window and none landed");
    }
}
