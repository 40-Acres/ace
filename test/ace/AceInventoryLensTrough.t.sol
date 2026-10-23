// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.36;

import {FullMath} from "@uniswap/v4-core/src/libraries/FullMath.sol";
import {CuratorVaultBase} from "../curator/CuratorVaultBase.sol";
import {AceInventoryLens, TornRead} from "../../src/ace/lens/AceInventoryLens.sol";
import {NoMarket, ZeroLimit} from "../../src/ace/lens/AceLens.sol";
import {NoRecordPrice} from "../../src/ace/hub/Borrower.sol";
import {PriceFrame} from "../utils/PriceFrame.sol";
import {MarketParams, OpenBounds} from "../../src/ace/hub/Types.sol";
import {AceFixtures} from "../utils/AceFixtures.sol";
import {DeleverageCrank} from "../utils/DeleverageCrank.sol";

/// @title AceInventoryLensTrough
/// @notice The counterpart monitor: `unclaimableStrand` sizes the NAV overstatement, this sizes the trough.
/// @notice A settled loan's recovery rests in `classOf[].invPot`, which is in no term of `lenderAssets`.
/// @notice So NAV understates until that inventory sells, and until now nothing reported the gap at all.
/// @dev The vault's NAV stays COST-BASED and price-free by ruling; this view is the disclosure, never an input.
/// @dev It must therefore never become reachable from the vault's NAV path -- that is the whole boundary.
/// @dev THE SEAM: `quoted` must equal the sum of `AceLens.inventoryMark` over the same classes, to the wei.
/// @dev That seam now crosses a CONTRACT boundary, which is exactly where a duplicated price expression drifts.
/// @dev The lender is an EOA, `alice`, on a USDC market with the decline band open: the subject is the hub's lens, not a vault.
/// @dev `CuratorVaultBase` is inherited for its hub, record and market helpers only; no vault is built here.
contract AceInventoryLensTroughTest is CuratorVaultBase, DeleverageCrank {
    uint256 internal constant SEED = 10_000e6;
    uint256 internal constant DRAW = 6_000e6;
    uint256 internal constant BAND_BPS = 3000; // what `_gatedMarket` opens the decline channel at

    AceInventoryLens internal inv;

    bool internal probeArmed; // only the crank whose row set this reads the lens from inside the hub
    bool internal probeRan;
    bool internal hubEnteredDuringCallback;
    bytes4 internal probeSelector; // what the mid-flight read answered with, or 0 when it did not revert

    function setUp() public override {
        super.setUp();
        inv = new AceInventoryLens(address(ace), address(lens));
        mid = _gatedMarket(alice); // alice is the market's one lender, priced at par over the rig record
    }

    function _deleverageQuote() internal view override returns (address) {
        return address(usdc);
    }

    /// @dev The borrower draws `DRAW` from alice's resting cash.
    function _draw() internal returns (uint256 loanId) {
        return _openIn(mid, DRAW);
    }

    /// @dev One loan, opened and settled. The trough is open when this returns.
    function _settled() internal returns (uint256 loanId) {
        _lendDirectIn(alice, mid, SEED);
        loanId = _draw();
        _finalize(loanId);
    }

    /// @dev `n` settled loans in one market, so the pagination rows have something to page over.
    function _settledMany(uint256 n) internal returns (uint256[] memory ids) {
        _lendDirectIn(alice, mid, SEED * n);
        ids = new uint256[](n);
        for (uint256 i; i < n; i++) {
            ids[i] = _draw();
            _finalize(ids[i]);
        }
    }

    /// @dev The figure the aggregate must reproduce, off the SHIPPED singular view.
    /// @dev WAS a sum over the loan's funded ticks; a loan funds one price, so the sum is that one read.
    function _markSum(uint256 loanId) internal view returns (uint256) {
        return lens.inventoryMark(mid, loanId);
    }

    /// @dev The loan's raw pot off the shipped lens. The tick argument is gone with the per-tick pots.
    function _potOf(uint256 loanId) internal view returns (uint256) {
        return lens.invPotOf(mid, loanId);
    }

    /// @dev Put the record in this loan's decline band; that one number is also the disposal floor.
    function _enterBand(uint256 loanId) internal {
        uint256 trig = read.triggerPrice(loanId);
        uint256 ps = trig + trig / 20;
        record.setBelowBand(FullMath.mulDivRoundingUp(trig, 1e18, 1e18 - BAND_BPS * 1e14));
        record.setMinPrice(ps);
    }

    /// @dev An UNGATED market with NO record wired, which is the `RecordState.None` shape.
    /// @dev Genesis demands a record only on a live decline channel, so the band stays 0 here.
    function _recordlessMarket() internal returns (bytes32) {
        MarketParams memory p = AceFixtures.marketParams(address(usdc), address(collateral));
        p.minDebt = 11e6; // its own id, without disturbing the rig's default market
        return ace.createMarket(p);
    }

    /// @dev Reads the aggregate from INSIDE the hub's guarded body, recording what the call answered with.
    /// @dev A reverting staticcall has no state effect, so probing here cannot perturb the crank it rides.
    /// @dev The pay leg is inlined rather than `super`'s so the probe can ride it; the hub pulls the quote.
    function _deleverageCallback(uint256 unitsSold, uint256 quoteOwed, bytes calldata) internal override {
        lastUnitsSold = unitsSold;
        lastQuoteOwed = quoteOwed;
        usdc.mint(address(this), quoteOwed); // stands in for the route's proceeds
        usdc.approve(address(ace), quoteOwed);
        if (!probeArmed) return;
        probeRan = true;
        hubEnteredDuringCallback = !ace.notEntered();
        (bool ok, bytes memory ret) = address(inv).staticcall(abi.encodeCall(AceInventoryLens.settledInventory, (mid, 0, 64)));
        probeSelector = ok ? bytes4(0) : bytes4(ret);
    }

    // ---- THE SEAM ----

    /// @notice HEADLINE: the aggregate is the sum of the class marks, exactly.
    /// @dev A batch that disagrees with its singular form is unreconcilable, and no rounding flip repairs a seam.
    /// @dev MUTATION TARGET: change the ask to plain `Ladder.priceAt` and the record floor stops applying here.
    function test_Trough_TheAggregateIsTheSumOfTheClassMarksToTheWei() public {
        uint256 loanId = _settled();

        uint256 expect = _markSum(loanId);
        (uint256 quoted, uint256 units, bool priced,) = inv.settledInventory(mid, 0, 64);
        emit log_named_uint("settled inventory, quoted ", quoted); // the sized figure, greppable under -vv
        emit log_named_uint("settled inventory, units  ", units);

        assertTrue(priced, "the record prices, so the quoted figure means something");
        assertGt(expect, 0, "LIVENESS: the rig really did open a trough to measure");
        assertGt(units, 0, "and the pot really does hold collateral");
        assertEq(quoted, expect, "the aggregate is the sum of the class marks, to the wei");
    }

    /// @notice The #427 property: a monitor that reverts when the record is sick is useless when it matters.
    /// @dev `RecordBlind` is the state most likely to COINCIDE with a settlement, so this is the live case.
    /// @dev The singular view refuses by design; the aggregate must report SIZE instead, and say it is unpriced.
    function test_Trough_ABlindRecordReportsSizeInsteadOfReverting() public {
        uint256 loanId = _settled();
        (, uint256 unitsWhilePriced,,) = inv.settledInventory(mid, 0, 64);

        record.setSick(true);

        vm.expectRevert();
        lens.inventoryMark(mid, loanId);

        (uint256 quoted, uint256 units, bool priced,) = inv.settledInventory(mid, 0, 64);
        assertFalse(priced, "a record that cannot answer is reported, not guessed at");
        assertEq(quoted, 0, "and nothing is quoted against a price that does not exist");
        assertGt(units, 0, "but the SIZE survives, which is the only number left worth having");
        assertEq(units, unitsWhilePriced, "and it is the same size the priced read reported");
    }

    /// @notice A live loan carries no pot, so skipping it cannot silently under-report.
    /// @dev `invPot` is written at ONE site, inside settlement, and all three doors set `closedAt` in that call.
    /// @dev MUTATION TARGET: invert the liveness skip and this must fail rather than merely cost gas.
    function test_Trough_LiveLoansCarryNoPot() public {
        _lendDirectIn(alice, mid, SEED);
        uint256 loanId = _draw();

        (uint256 quoted, uint256 units,,) = inv.settledInventory(mid, 0, 64);
        assertEq(units, 0, "a market of live loans holds no settled inventory");
        assertEq(quoted, 0, "so there is nothing to quote either");
        assertEq(lens.loan(loanId).closedAt, 0, "LIVENESS: the loan really is still open");
    }

    /// @notice The monitor tracks the trough CLOSING, not only opening: a drained pot reads zero again.
    /// @dev Without this the view could be summing a stale field that no sale ever clears.
    function test_Trough_TheRecoveryClosesIt() public {
        uint256 loanId = _settled();
        (, uint256 before,,) = inv.settledInventory(mid, 0, 64);
        assertGt(before, 0, "LIVENESS: there is a pot to drain");

        _warpBy(30 days); // past the market's inventory hold, which gates the permissionless ask
        uint256 budget = 100_000e6;
        deal(address(usdc), bob, budget);
        vm.startPrank(bob);
        _approveCash(mid, budget); // the hub is the spender
        ace.buyInventory(loanId, budget, 0, bob);
        vm.stopPrank();

        (, uint256 units,,) = inv.settledInventory(mid, 0, 64);
        assertEq(units, 0, "the whole-pot sale emptied the pot, sub-quantum tail included, and the monitor says so");

        /// @dev A budget past the whole pot buys it whole, so no crumb survives; a second pass meets an empty pot.
        deal(address(usdc), bob, budget * 10);
        vm.startPrank(bob);
        _approveCash(mid, budget * 10);
        (uint256 again,) = ace.buyInventory(loanId, budget * 10, 0, bob);
        vm.stopPrank();
        assertEq(again, 0, "an emptied pot sells nothing");
    }

    // ---- PAGINATION ----

    /// @notice Paging is lossless: every page summed equals one full-window read.
    /// @dev `nextOffset == offset` is the ONLY done-signal, so a mid-market empty page must not read as the end.
    function test_Trough_EveryPageSummedEqualsTheWholeMarket() public {
        _settledMany(3);

        (uint256 whole, uint256 wholeUnits,,) = inv.settledInventory(mid, 0, 64);
        assertGt(whole, 0, "LIVENESS: the whole-market read found a trough");

        uint256 quoted;
        uint256 units;
        uint256 offset;
        for (uint256 i; i < 16; i++) {
            (uint256 q, uint256 u,, uint256 next) = inv.settledInventory(mid, offset, 1);
            if (next == offset) break;
            quoted += q;
            units += u;
            offset = next;
        }
        assertEq(quoted, whole, "the pages sum to the whole market");
        assertEq(units, wholeUnits, "and so do the units");
        assertGt(offset, 1, "LIVENESS: paging really did walk more than a single loan");
    }

    /// @notice A limit of zero is ambiguous, so it is refused rather than guessed at.
    function test_Trough_AZeroLimitIsRefused() public {
        _settled();
        vm.expectRevert(ZeroLimit.selector);
        inv.settledInventory(mid, 0, 0);
    }

    /// @notice A typo'd id REVERTS rather than reading zero: a monitor whose failure mode is "0" is not one.
    /// @dev Deliberately the selector the hub throws, so one catch covers the lens and the hub alike.
    function test_Trough_AnUnknownMarketRevertsRatherThanReadingZero() public {
        vm.expectRevert(NoMarket.selector);
        inv.settledInventory(keccak256("no such market"), 0, 64);
    }

    // ---- THE ASK, PINNED WITHOUT A SECOND IMPLEMENTATION ----

    /// @notice The ask is max(book, the record's windowed minimum), pinned against LITERALS rather than a twin.
    /// @dev Every other seam row checks this view against `AceLens.inventoryMark`, so a shared misreading
    /// @dev of the record would agree with itself. This row derives the number from the two inputs instead.
    /// @dev MUTATION TARGET: drop the floor lift and `quoted` falls to the book leg this row rejects.
    function test_Trough_TheRecordFloorLiftsTheAskAboveBook() public {
        _settled();

        uint256 book = T2;
        uint256 floorPrice = record.windowMin();
        assertGt(floorPrice, book, "LIVENESS: the rig's floor really does sit above the funding tick's book");

        uint256 scale = lens.marketState(mid).unitScale;
        (uint256 quoted, uint256 units,,) = inv.settledInventory(mid, 0, 64);
        assertGt(units, 0, "LIVENESS: there is a pot to price");
        assertEq(quoted, FullMath.mulDiv(units, floorPrice, scale), "the windowed minimum is the ask, because it is the higher leg");
        assertGt(quoted, FullMath.mulDiv(units, book, scale), "and it is strictly above what plain book would have quoted");
    }

    /// @notice A record that ANSWERS zero is unpriced exactly as one that REFUSES to answer is.
    /// @dev The two NoPrice shapes reach `recordStateOf` by different routes: a zero word, and a failed probe.
    /// @dev The sick row covers the second; this covers the first, and names the singular view's selector.
    function test_Trough_AZeroAnsweringRecordIsUnpricedJustLikeASickOne() public {
        uint256 loanId = _settled();
        (, uint256 unitsWhilePriced,,) = inv.settledInventory(mid, 0, 64);

        record.setMinPrice(0); // the record answers, and its answer is no price

        vm.expectRevert(NoRecordPrice.selector);
        lens.inventoryMark(mid, loanId);

        (uint256 quoted, uint256 units, bool priced,) = inv.settledInventory(mid, 0, 64);
        assertFalse(priced, "a zero answer is no price, and the view says so rather than quoting at zero");
        assertEq(quoted, 0, "nothing is quoted against a price the record disclaims");
        assertEq(units, unitsWhilePriced, "and the size is the same one the priced read reported");
    }

    /// @notice A market with NO record stays PRICED and marks at book: the max sentinel is no floor, not an infinite one.
    /// @dev `RecordState.None` is the third state, and it is the one a naive `state == Live` test gets wrong.
    /// @dev Reading the sentinel as a floor would not merely over-quote -- `mulDiv` by it would revert outright.
    /// @dev `finalize` refuses a record-less market by name, so the settled loan here comes through `forceClose`.
    function test_Trough_ARecordlessMarketPricesAtBookAndStaysPriced() public {
        bytes32 bare = _recordlessMarket();
        _lendDirectIn(alice, bare, SEED);
        uint256 loanId = _openIn(bare, DRAW);

        _warpBy(8 days); // past the 7-day tenor, so the permissionless close is admissible
        ace.forceClose(loanId);

        (uint256 quoted, uint256 units, bool priced,) = inv.settledInventory(bare, 0, 64);
        assertTrue(priced, "no record is not the same fact as no price, and the view must not conflate them");
        assertGt(units, 0, "LIVENESS: the close really did pool a pot");
        uint256 scale = lens.marketState(bare).unitScale;
        assertEq(quoted, FullMath.mulDiv(units, T2, scale), "with no record the ask is book, unlifted");
        assertEq(quoted, lens.inventoryMark(bare, loanId), "and the singular view agrees across the contract boundary");
    }

    // ---- THE WALKS ----

    /// @dev DELETED: "a loan funded at two ticks pools two pots, and the aggregate sums both". A draw walked
    /// @dev a ladder and could hold a claim per tick, so the aggregate carried an INNER walk over that list and
    /// @dev this was the only row that exercised it past length one. A market has one price: the inner walk is
    /// @dev gone with the list, and what is left -- the aggregate equals the loan's own pot and mark -- is
    /// @dev asserted by the settled rows below, which no longer have a summing body to be fooled by.

    /// @notice A live loan sitting BETWEEN two settled ones is skipped without stopping the walk.
    /// @dev The mixed market the liveness skip actually has to survive: an all-live market cannot show
    /// @dev that the skip continues rather than returning, because there is nothing after it to miss.
    /// @dev It is also the case the pagination contract names -- a mid-market empty page is NOT the end.
    function test_Trough_ALiveLoanBetweenTwoSettledOnesIsSkippedNotStopped() public {
        _lendDirectIn(alice, mid, SEED * 3);

        uint256 first = _draw();
        _finalize(first);
        uint256 live = _draw();
        uint256 last = _draw();
        _finalize(last);

        assertEq(lens.loan(live).closedAt, 0, "LIVENESS: the middle loan really is still open");
        assertEq(ace.marketLoansLength(mid), 3, "and the pager really does hold three entries to walk");

        (uint256 whole, uint256 wholeUnits,,) = inv.settledInventory(mid, 0, 64);
        assertEq(wholeUnits, _potOf(first) + _potOf(last), "the two settled pots, and nothing from the live loan");
        assertGt(whole, 0, "LIVENESS: the whole-market read found a trough");

        (uint256 q, uint256 u,, uint256 next) = inv.settledInventory(mid, 1, 1);
        assertEq(u, 0, "the live loan's own page carries no units");
        assertEq(q, 0, "and quotes nothing");
        assertEq(next, 2, "but it advances the cursor: an empty page mid-market is not the done-signal");

        (uint256 q0, uint256 u0,,) = inv.settledInventory(mid, 0, 1);
        (uint256 q2, uint256 u2,,) = inv.settledInventory(mid, 2, 1);
        assertEq(u0 + u + u2, wholeUnits, "the three single-loan pages sum to the whole market");
        assertEq(q0 + q + q2, whole, "and so do their values");
    }

    /// @notice An offset past the end reads empty and signals done rather than reverting.
    /// @dev A pager whose overrun reverts turns a monitor's normal terminating condition into an alert.
    /// @dev `priced` is still a live answer there: it is a property of the RECORD, never of the page.
    function test_Trough_AnOffsetPastTheEndIsTheDoneSignal() public {
        _settled();

        uint256 n = ace.marketLoansLength(mid);
        assertEq(n, 1, "LIVENESS: the rig opened exactly the loan this row pages past");

        (,,, uint256 firstNext) = inv.settledInventory(mid, 0, 64);
        assertEq(firstNext, n, "a page that consumed the list advances the cursor to its end");

        (uint256 quoted, uint256 units, bool priced, uint256 nextOffset) = inv.settledInventory(mid, n, 64);
        assertEq(nextOffset, n, "the cursor does not move, which is the whole done-signal");
        assertEq(units, 0, "nothing past the end holds inventory");
        assertEq(quoted, 0, "so nothing past the end is quoted");
        assertTrue(priced, "and the record still answers: pricing is not a property of the page");

        (,,, uint256 farNext) = inv.settledInventory(mid, n + 1000, 64);
        assertEq(farNext, n + 1000, "an offset far past the end signals done at its own cursor, not at the length");
    }

    /// @notice A PARTIAL sale lowers the pot and the quote together, without closing the trough.
    /// @dev The full-drain row cannot tell a monitor that tracks the pot from one that latches on empty.
    /// @dev Both legs must move: units by what was sold, and the quote by that size at the same ask.
    function test_Trough_APartialSaleLowersThePotWithoutClosingIt() public {
        uint256 loanId = _settled();
        (uint256 quotedBefore, uint256 unitsBefore,,) = inv.settledInventory(mid, 0, 64);
        assertGt(unitsBefore, 0, "LIVENESS: there is a pot to bite into");

        uint256 spend = quotedBefore / 4; // a quarter of the pot's own quoted value, so the fill is partial
        _warpAtLeastTo(read.inventoryAskOpensAt(loanId));
        usdc.mint(bob, spend);
        vm.startPrank(bob);
        _approveCash(mid, spend); // the hub is the spender
        (uint256 unitsSold,) = ace.buyInventory(loanId, spend, 0, bob);
        vm.stopPrank();
        assertGt(unitsSold, 0, "LIVENESS: the buy really did take units");
        assertLt(unitsSold, unitsBefore, "and it deliberately did NOT take the whole pot");

        (uint256 quoted, uint256 units, bool priced,) = inv.settledInventory(mid, 0, 64);
        assertTrue(priced, "the record still prices after a partial fill");
        assertEq(units, unitsBefore - unitsSold, "the pot fell by exactly what the buyer took");
        assertGt(units, 0, "and the trough is still open, which a latching monitor would deny");
        assertEq(quoted, _markSum(loanId), "the quote tracks the smaller pot, still to the wei of the singular view");
        assertLt(quoted, quotedBefore, "and it really did fall");
    }

    /// @notice The walked units total is the market's O(1) identity, reached by a completely different route.
    /// @dev `AceLens.headroom` is `cumulativeBackedBurns - netSyntheticOutflow`, and those two counters move
    /// @dev in lockstep with all three `invPot` writes, so the same quantity exists WITHOUT walking anything.
    /// @dev Two independent derivations agreeing is worth more than either alone: a walk can miss a class, and
    /// @dev the identity drifts silently the day a fourth site touches a pot without moving its counter.
    /// @dev The sale leg matters most -- it is the only one that moves the SUBTRAHEND rather than the sum.
    function test_Trough_TheWalkedUnitsAgreeWithTheMarketIdentity() public {
        uint256[] memory ids = _settledMany(3);

        (, uint256 units,,) = inv.settledInventory(mid, 0, 64);
        assertGt(units, 0, "LIVENESS: there is a pot to total");
        assertEq(units, lens.headroom(mid), "the walk and the O(1) identity are the same quantity");

        uint256 spend = 500e6;
        _warpAtLeastTo(read.inventoryAskOpensAt(ids[0]));
        usdc.mint(bob, spend);
        vm.startPrank(bob);
        _approveCash(mid, spend); // the hub is the spender
        (uint256 sold,) = ace.buyInventory(ids[0], spend, 0, bob);
        vm.stopPrank();
        assertGt(sold, 0, "LIVENESS: the sale really did take units out of custody");

        (, uint256 after_,,) = inv.settledInventory(mid, 0, 64);
        assertEq(after_, units - sold, "the walk fell by exactly what left custody");
        assertEq(after_, lens.headroom(mid), "and the identity tracked the outflow the same way");
    }

    // ---- THE TORN-READ GUARD ----

    /// @notice The aggregate REFUSES a read taken from inside a guarded hub body, and answers freely after it.
    /// @dev The hub's transient lock is per-address, so a lens at another address cannot check it directly
    /// @dev and must ASK. `notEntered()` is that ask, and only a re-entrant read shows the wire is live.
    /// @dev The re-entrant context is the deleverage callback, which the hub invokes still holding its lock.
    /// @dev Without this row the guard could be deleted and every other row here would stay green.
    function test_Trough_AMidFlightReadIsRefusedAsTorn() public {
        _lendDirectIn(alice, mid, SEED * 2); // depth for BOTH loans: the settled trough, and the one the keeper cranks
        uint256 settled = _draw();
        _finalize(settled);
        uint256 live = _draw();

        _enterBand(live);
        probeArmed = true;
        ace.deleverage(live, 0, "");
        probeArmed = false;

        assertTrue(probeRan, "LIVENESS: the callback never ran, so nothing was probed");
        assertTrue(hubEnteredDuringCallback, "the probe did not run inside the hub's guard, so it proves nothing");
        assertEq(probeSelector, TornRead.selector, "an aggregate read straddling a half-written hub state was answered");

        (uint256 quoted, uint256 units,,) = inv.settledInventory(mid, 0, 64);
        assertGt(units, 0, "and the same call answers freely once the hub body has returned");
        assertGt(quoted, 0, "with a real quote, so the refusal was the lock and not a broken read");
    }
}
