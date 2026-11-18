// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.36;

import {Math} from "@openzeppelin/contracts/utils/math/Math.sol";
import {AceVault} from "../../../src/curator/AceVault.sol";
import {AceVaultFlows} from "../../../src/curator/AceVaultFlows.sol";
import {IAceLenderOps} from "../../../src/interfaces/IAceLenderOps.sol";
import {AceVaultRig} from "./AceVaultRig.sol";

/// @title AceVaultTroughHold
/// @notice The hold after a cleared trough, in hub-ask mode: a sync that sees NAV fall over an unsold pot marks the vault.
/// @notice The first sync that sees no pot unsold while marked holds entry until the pile then standing has vested, or not at all under one unit.
/// @dev The hold is read from the vest word, bits 200-247: zero none, all ones marked, else the second entry reopens.
contract AceVaultTroughHoldTest is AceVaultRig {
    uint256 internal constant ENTRY = 1_000_000e6;
    uint48 internal constant MARKED = type(uint48).max;

    /// @dev The vest word, ROOT + 2: basis low, maturity at 128, the drain at 192, the hold at 200.
    function _vestWord() internal view returns (uint256) {
        bytes32[] memory s = new bytes32[](1);
        s[0] = bytes32(uint256(AceVaultFlows.ROOT) + 2);
        return uint256(vault.extsload(s)[0]);
    }

    function _hold() internal view returns (uint48) {
        return uint48(_vestWord() >> 200);
    }

    function _maturity() internal view returns (uint64) {
        return uint64(_vestWord() >> 128);
    }

    /// @dev A loan of `p` on `units` lapses and a keeper force-closes it; a crank by bob sees the fall; the pot then waits out the hub's hold.
    function _defaultToPot(uint256 units, uint256 p) internal returns (uint256 loanId) {
        loanId = _borrowAs(borrower, units, p, MIN_TENOR);
        _warpAtLeastTo(_expiry(loanId));
        vm.prank(keeper);
        ace.forceClose(loanId);
        vm.prank(bob);
        vault.crank();
        _warpBy(1 hours);
    }

    /// @dev `who` buys the whole settled pot at the hub's ask; returns what it paid.
    function _buyPot(address who, uint256 loanId) internal returns (uint256 units, uint256 paid) {
        uint256 budget = 10_000_000e6;
        usdc.mint(who, budget);
        vm.startPrank(who);
        usdc.approve(address(ace), budget);
        (units, paid) = ace.buyInventory(loanId, budget, 0, who);
        vm.stopPrank();
    }

    function _enterAs(address who, uint256 amt) internal returns (uint256 shares) {
        usdc.mint(who, amt);
        vm.startPrank(who);
        usdc.approve(address(vault), amt);
        shares = vault.deposit(amt, who);
        vm.stopPrank();
    }

    /// @dev Entry is held: both max views read zero, and a deposit and a mint both refuse `RecoveryVesting`.
    function _assertHeld(address who) internal {
        assertEq(vault.maxDeposit(who), 0, "maxDeposit advertised an entry the hold shuts");
        assertEq(vault.maxMint(who), 0, "and so did maxMint");
        usdc.mint(who, 2_000e6);
        vm.startPrank(who);
        usdc.approve(address(vault), 2_000e6);
        vm.expectRevert(AceVault.RecoveryVesting.selector);
        vault.deposit(1_000e6, who);
        vm.expectRevert(AceVault.RecoveryVesting.selector);
        vault.mint(1e9, who);
        vm.stopPrank();
    }

    /// @notice The hub sale clears the leg: the sale's sync stores the post-recovery maturity, and entry waits for that second.
    /// @dev The hold now lets go once the pile is at or under VEST_FLOOR, which can be seconds before the stored second.
    function test_Hold_TheHubSaleHoldsEntryUntilTheRecoveryVests() public {
        uint256 loanId = _defaultToPot(60_000e18, 40_000e6);
        assertEq(_hold(), MARKED, "the sync that saw the fall over the unsold pot did not mark the vault");
        _buyPot(stranger, loanId);
        vault.crank();
        uint256 pile = vault.unvested();
        assertGt(pile, vault.VEST_FLOOR(), "premise: the sale's cash vests");
        assertLe(pile * 10_000, vault.totalAssets() * vault.GATE_BPS(), "premise: inside the band, so the vest gate alone would open entry");
        assertEq(_hold(), _maturity(), "the hold is not the maturity the sale's own stamp left");
        assertGt(uint256(_hold()), _now(), "premise: the hold is in the future");
        _assertHeld(bob);
        _warpTo(uint256(_hold()) - 1 hours);
        _assertHeld(bob);
        _warpTo(_hold());
        assertEq(vault.unvested(), 0, "the recovery has vested by the hold's second");
        assertGt(vault.maxDeposit(bob), 0, "entry did not reopen at the hold's second");
        uint256 sb = _enterAs(bob, ENTRY);
        _warpBy(VEST_W);
        vault.crank();
        vm.prank(bob);
        uint256 out = vault.redeem(sb, bob, bob);
        assertLe(out, ENTRY, "an entrant after the hold took a share of a recovery it never funded");
        assertApproxEqAbs(out, ENTRY, 2, "an entrant after the hold was not paid its entry back to two atoms");
    }

    /// @notice A pot unsold for three windows stays marked, so the hold still starts at its sale and not at the fall.
    function test_Hold_APotUnsoldForLongerThanAWindowStillHoldsAtTheSale() public {
        uint256 loanId = _defaultToPot(60_000e18, 40_000e6);
        _warpBy(3 * VEST_W);
        vault.crank();
        assertEq(_hold(), MARKED, "the mark lapsed while the pot stood unsold");
        assertEq(vault.maxDeposit(bob), 0, "premise: the unsold pot shuts entry");
        _buyPot(stranger, loanId);
        vault.crank();
        assertEq(_hold(), _maturity(), "the hold is not the sale's maturity");
        assertEq(uint256(_hold()), _now() + VEST_W, "a fresh pile's maturity is one window from the sale");
        _assertHeld(bob);
    }

    /// @notice A donation after the hold is stored blends the maturity later but leaves the stored second where it was.
    function test_Hold_ADonationAfterTheHoldDoesNotExtendIt() public {
        uint256 loanId = _defaultToPot(60_000e18, 40_000e6);
        _buyPot(stranger, loanId);
        vault.crank();
        uint48 held = _hold();
        assertGt(uint256(held), _now(), "premise: a hold stands");
        _warpBy(VEST_W / 2);
        usdc.mint(address(vault), 10e6);
        vault.crank();
        assertGt(_maturity(), held, "premise: the donation blended the maturity later");
        assertEq(_hold(), held, "the donation moved the stored hold");
        _warpTo(held);
        assertGt(vault.unvested(), vault.VEST_FLOOR(), "premise: the donation still vests at the hold's second");
        assertGt(vault.maxDeposit(bob), 0, "entry stayed shut past the stored hold");
        assertGt(_enterAs(bob, 1_000e6), 0, "a deposit at the hold's second did not land");
    }

    /// @notice A settle and a sale with no sync between them net in one stamp: nothing is marked, and the borrower's raid nets nothing.
    function test_Hold_ASettleAndSaleWithNoSyncBetweenMarkNothing() public {
        uint256 units0 = 60_000e18;
        uint256 loanId = _borrowAs(borrower, units0, 40_000e6, MIN_TENOR);
        uint256 payout = usdc.balanceOf(borrower);
        _warpAtLeastTo(_expiry(loanId));
        vm.prank(keeper);
        ace.forceClose(loanId);
        _warpBy(1 hours);
        vm.prank(borrower);
        (uint256 residual,) = ace.claimOwed(loanId, borrower);
        (uint256 potUnits, uint256 paid) = _buyPot(borrower, loanId);
        uint256 sx = _enterAs(borrower, ENTRY);
        assertEq(_hold(), 0, "a sync that saw the net of a settle and its sale marked the vault");
        _warpBy(VEST_W);
        vault.crank();
        vm.prank(borrower);
        uint256 out = vault.redeem(sx, borrower, borrower);
        assertEq(residual + potUnits, units0, "premise: every unit the borrower pledged came home");
        int256 net = int256(payout) + int256(out) - int256(ENTRY) - int256(paid);
        emit log_named_uint("payout kept", payout);
        emit log_named_uint("paid for its own pot", paid);
        emit log_named_uint("redemption after one window", out);
        emit log_named_int("raider's cash net, all units home", net);
        assertLe(net, 0, "the raid paid the raider");
    }

    /// @notice The guardian's exemption clears the leg like a sale: the view shuts at once, and the next sync, a stranger's crank, stores the hold.
    function test_Hold_TheExemptionStartsTheHoldAndACrankStoresIt() public {
        uint256 sold = _borrowAs(borrower, 60_000e18, 40_000e6, MIN_TENOR);
        uint256 dead = _borrowAs(borrower, 2_000e18, 1_000e6, MIN_TENOR);
        _warpAtLeastTo(_expiry(dead) > _expiry(sold) ? _expiry(dead) : _expiry(sold));
        vm.startPrank(keeper);
        ace.forceClose(sold);
        ace.forceClose(dead);
        vm.stopPrank();
        vault.crank();
        _warpBy(1 hours);
        _buyPot(stranger, sold);
        vault.crank();
        assertEq(_hold(), MARKED, "premise: the other pot still stands unsold, so the vault stays marked");
        (, uint256 s) = ace.lenderUnresolved(address(vault), address(usdc));
        vm.prank(guardian);
        vault.exemptDeadPots(s);
        assertEq(_hold(), MARKED, "the exemption synced: it must write only its snapshot");
        assertEq(vault.maxDeposit(bob), 0, "the view opened over a marked vault whose pile still vests");
        assertEq(vault.maxMint(bob), 0, "and so did maxMint");
        vm.prank(stranger);
        vault.crank();
        assertEq(_hold(), _maturity(), "a stranger's crank did not store the hold at the pile's maturity");
        _assertHeld(bob);
        _warpTo(_hold());
        assertGt(_enterAs(bob, 1_000e6), 0, "entry did not reopen at the hold");
    }

    /// @notice A marked vault whose pot is exempted with no pile standing opens at once, in the view and in the verb, and clears the mark.
    function test_Hold_AMarkWithNoPileOpensInTheViewAndTheVerb() public {
        uint256 loanId = _borrowAs(borrower, 60_000e18, 40_000e6, MIN_TENOR);
        _warpAtLeastTo(_expiry(loanId));
        vm.prank(keeper);
        ace.forceClose(loanId);
        vault.crank();
        (, uint256 s) = ace.lenderUnresolved(address(vault), address(usdc));
        vm.prank(guardian);
        vault.exemptDeadPots(s);
        assertEq(_hold(), MARKED, "premise: the fall over the unsold pot marked the vault");
        assertLe(vault.unvested(), vault.VEST_FLOOR(), "premise: the fall burnt the pile");
        assertGt(vault.maxDeposit(bob), 0, "the view stayed shut over a mark with no pile");
        assertGt(vault.maxMint(bob), 0, "and so did maxMint");
        assertGt(_enterAs(bob, 1_000e6), 0, "the verb refused a mark with no pile");
        assertEq(_hold(), 0, "the entry's own sync did not clear the mark");
    }

    /// @notice Gas: an unmarked sync with no fall, flat or rising, never reads the hub's unsold count.
    function test_Hold_AnUnmarkedSyncWithNoFallMakesNoUnsoldRead() public {
        vm.expectCall(address(ace), abi.encodeWithSelector(IAceLenderOps.lenderUnresolved.selector), 0);
        vault.crank();
        usdc.mint(address(vault), 10e6);
        vault.crank();
        vault.collectFee();
    }

    /// @notice Gas: a sync that sees a fall reads the hub's unsold count exactly once, and marks the vault on an unsold pot.
    function test_Hold_AFallingSyncReadsTheUnsoldCountOnce() public {
        uint256 loanId = _borrowAs(borrower, 60_000e18, 40_000e6, MIN_TENOR);
        _warpAtLeastTo(_expiry(loanId));
        vm.prank(keeper);
        ace.forceClose(loanId);
        vm.expectCall(address(ace), abi.encodeWithSelector(IAceLenderOps.lenderUnresolved.selector), 1);
        vault.crank();
        assertEq(_hold(), MARKED, "the fall over an unsold pot did not mark the vault");
    }

    /// @notice Layout: the hold packs into the vest word at bits 200-247, above the drain's byte, and leaves the byte above it clear.
    function test_Hold_TheLayoutPacksTheHoldAboveTheDrain() public {
        uint256 loanId = _defaultToPot(60_000e18, 40_000e6);
        assertEq((_vestWord() >> 200) & type(uint48).max, uint256(MARKED), "the mark is not all ones at bits 200-247");
        _buyPot(stranger, loanId);
        vault.crank();
        vm.prank(curator);
        vault.setDrain(true);
        uint256 w = _vestWord();
        assertEq(uint64(w >> 128), _maturity(), "the maturity left bits 128-191");
        assertEq(uint8(w >> 192), 1, "the drain left the byte at 192");
        assertEq(uint48(w >> 200), _maturity(), "the hold is not the stored maturity at bits 200-247");
        assertEq(w >> 248, 0, "the hold spilled past bit 247");
        assertEq(vault.unvested(), Math.mulDiv(uint128(w), _maturity() - _now(), VEST_W, Math.Rounding.Ceil), "the basis left the low 128 bits");
    }

    // ---- the hold bites only while a pile over the floor stands ----

    /// @dev The view and the verb agree for `who`: both max views read zero exactly when a deposit, tried from a snapshot, refuses.
    function _agree(address who) internal returns (bool shut) {
        shut = vault.maxDeposit(who) == 0;
        assertEq(vault.maxMint(who) == 0, shut, "maxMint disagreed with maxDeposit");
        uint256 snap = vm.snapshotState();
        usdc.mint(who, 1_000e6);
        vm.startPrank(who);
        usdc.approve(address(vault), 1_000e6);
        (bool ok,) = address(vault).call(abi.encodeCall(vault.deposit, (1_000e6, who)));
        vm.stopPrank();
        vm.revertToState(snap);
        assertEq(ok, !shut, "the deposit disagreed with the max views");
    }

    /// @dev Loan A is sold after its default, storing a hold; loan B, opened a day later, lapses inside that hold and is settled and exempted unsynced.
    function _holdThenUnsyncedLoss() internal returns (uint256 held) {
        uint256 a = _borrowAs(borrower, 60_000e18, 40_000e6, MIN_TENOR);
        _warpBy(1 days);
        uint256 b = _borrowAs(borrower, 200_000e18, 100_000e6, MIN_TENOR);
        _warpAtLeastTo(_expiry(a));
        vm.prank(keeper);
        ace.forceClose(a);
        vault.crank();
        _warpBy(1 hours);
        _buyPot(stranger, a);
        vault.crank();
        held = _hold();
        assertGt(vault.unvested(), vault.VEST_FLOOR(), "PREMISE: the sale's cash vests under a stored hold");
        _warpAtLeastTo(_expiry(b));
        assertLt(_now(), uint256(held), "PREMISE: the second loan lapses inside the hold");
        vm.prank(keeper);
        ace.forceClose(b);
        (, uint256 s) = ace.lenderUnresolved(address(vault), address(usdc));
        vm.prank(guardian);
        vault.exemptDeadPots(s);
    }

    /// @notice A later loss that burns the pile lifts the hold: entry opens before the old second, in the view and the verb, and the clear stores none.
    function test_Hold_ALossThatBurnsThePileLiftsTheHold() public {
        uint256 held = _holdThenUnsyncedLoss();
        assertEq(_hold(), type(uint48).max, "PREMISE: the exemption marked the second loss no sync had seen");
        assertGt(vault.maxDeposit(bob), 0, "the view held entry over a pile the loss burnt");
        assertGt(vault.maxMint(bob), 0, "and so did maxMint");
        assertGt(_enterAs(bob, 1_000e6), 0, "the verb held entry over a pile the loss burnt");
        assertEq(vault.unvested(), 0, "PREMISE: the loss burnt the whole pile");
        assertEq(_hold(), 0, "the entry's clear over a burnt pile stored a hold");
        assertLt(_now(), uint256(held), "PREMISE: entry landed before the old stored second");
    }

    /// @notice A last requester's release vests the pile whole, which lifts the hold: the empty vault takes an entrant before the stored second.
    function test_Hold_ALastRequestersReleaseLiftsTheHold() public {
        uint256 loanId = _defaultToPot(60_000e18, 40_000e6);
        _buyPot(stranger, loanId);
        vault.crank();
        uint48 held = _hold();
        assertGt(vault.unvested(), vault.VEST_FLOOR(), "PREMISE: the sale's cash vests under a stored hold");
        uint256 all = vault.balanceOf(alice);
        vm.startPrank(alice);
        vault.requestExit(all);
        vault.claimExit(all, alice, 0);
        vm.stopPrank();
        assertEq(vault.totalSupply(), vault.SEED_SHARES(), "PREMISE: the last requester left whole, the genesis seed alone remaining");
        assertEq(vault.unvested(), 0, "PREMISE: her claim released the pile");
        assertLt(_now(), uint256(held), "PREMISE: before the stored second");
        assertGt(vault.maxDeposit(bob), 0, "the view held entry over a released pile");
        assertGt(_enterAs(bob, 1_000e6), 0, "the verb held entry over a released pile");
    }

    /// @notice The view and the verb agree in every hold state: none, marked over an unsold pot, marked as it clears, stored, and stored over a burnt pile.
    function test_Hold_TheViewMatchesTheVerbInEveryHoldState() public {
        assertFalse(_agree(bob), "no hold: entry is open");
        uint256 a = _borrowAs(borrower, 60_000e18, 40_000e6, MIN_TENOR);
        _warpBy(1 days);
        uint256 b = _borrowAs(borrower, 200_000e18, 100_000e6, MIN_TENOR);
        _warpAtLeastTo(_expiry(a));
        vm.prank(keeper);
        ace.forceClose(a);
        vault.crank();
        assertEq(_hold(), MARKED, "PREMISE: marked");
        assertTrue(_agree(bob), "marked over an unsold pot: entry is shut");
        _warpBy(1 hours);
        _buyPot(stranger, a);
        assertEq(_hold(), MARKED, "PREMISE: still marked, the sale unsynced");
        assertTrue(_agree(bob), "marked as the pot clears, with a pile over the floor: entry is shut");
        vault.crank();
        assertEq(_hold(), _maturity(), "PREMISE: the hold is stored");
        assertTrue(_agree(bob), "a stored hold over a pile: entry is shut");
        _warpAtLeastTo(_expiry(b));
        vm.prank(keeper);
        ace.forceClose(b);
        (, uint256 s) = ace.lenderUnresolved(address(vault), address(usdc));
        vm.prank(guardian);
        vault.exemptDeadPots(s);
        assertFalse(_agree(bob), "a stored hold over a pile the loss burnt: entry is open");
    }
}
