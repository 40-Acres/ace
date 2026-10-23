// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.36;

import {Test} from "forge-std/Test.sol";
import {WarpClock} from "../utils/WarpClock.sol";
import {Ace} from "../../src/ace/hub/Ace.sol";
import {MarketParams, OpenBounds} from "../../src/ace/hub/Types.sol";
import {NotSettleable} from "../../src/ace/hub/Settlement.sol";
import {PositionManager} from "../../src/ace/positions/PositionManager.sol";
import {OracleRecord} from "../../src/oracle/OracleRecord.sol";
import {MockAggregatorV3} from "../mocks/MockAggregatorV3.sol";
import {MockShortReturnFeed} from "../mocks/MockShortReturnFeed.sol";
import {MockERC20} from "../mocks/MockERC20.sol";
import {MockStakeVault} from "../mocks/MockStakeVault.sol";
import {AceFixtures} from "../utils/AceFixtures.sol";
import {ProtocolPolicy} from "../../src/config/Defaults.sol";
import {AceReader} from "../utils/AceReader.sol";
import {DeleverageCrank} from "../utils/DeleverageCrank.sol";

/// @title OracleRecordTest
/// @notice The ORACLE class: the feed is the truth, there is no persistence window, and every failure answers closed.
/// @dev Pins the zero-singleton-diff property, the borrowing-only health gate, and the termed-loan terminal state.
/// @dev Also pins that a recovered feed is live at once: this class carries no outage grace on any path.
contract OracleRecordTest is WarpClock, DeleverageCrank {
    Ace internal ace;
    PositionManager internal positionManager;
    AceReader internal read;
    MockERC20 internal usdc;
    MockStakeVault internal vault;
    MockAggregatorV3 internal feed;
    OracleRecord internal record;
    bytes32 internal id;
    // the ordered pair the record is constructed with; every record read is parameterized by it
    address internal recQ;
    address internal recC;

    address internal alice = address(0xA11CE);
    address internal borrower = address(0xB0B);

    uint256 internal constant COLL = 10_000e18;
    uint256 internal constant PRINCIPAL = 4_500e6;
    int256 internal constant ANSWER = 2e8; // 2.0 quote per token on an 8-dec feed
    uint8 internal constant FEED_DECIMALS = 8;
    uint256 internal P; // the same price in the hub's atom frame, which needs the pair to state
    uint256 internal constant BAND_BPS = 3000;
    uint256 internal constant STALENESS = 1 hours;

    function setUp() public {
        _warpTo(365 days); // clear of genesis so staleness arithmetic never underflows
        usdc = new MockERC20("USD Coin", "USDC", 6);
        vault = new MockStakeVault(42);
        feed = new MockAggregatorV3(FEED_DECIMALS);
        feed.push(ANSWER);
        record = new OracleRecord(address(feed), address(usdc), address(vault), STALENESS);
        (recQ, recC) = (address(usdc), address(vault));
        P = AceFixtures.px(2e18, address(usdc), address(vault));

        MarketParams memory p = AceFixtures.marketParams(address(usdc), address(vault));
        p.record = address(record);
        p.deleverageFloorEpsBps = ProtocolPolicy.DELEVERAGE_FLOOR_EPS_BPS;
        p.deleverageBandBps = BAND_BPS; // the one crank that prices off the feed
        p.deleverageTargetBps = 4000;
        p.deleverageStopBps = 1;
        AceFixtures.Deployment memory d = AceFixtures.deploy(p);
        (ace, positionManager, read, id) = (d.ace, d.positionManager, d.read, d.id);

        usdc.mint(alice, 15_000e6);
        vm.startPrank(alice);
        usdc.approve(address(ace), 15_000e6);
        ace.deposit(id, 15_000e6);
        vm.stopPrank();
    }

    function _deleverageQuote() internal view override returns (address) {
        return address(usdc);
    }

    function _open() internal returns (uint256 loanId) {
        vault.mint(borrower, COLL);
        vm.startPrank(borrower);
        vault.approve(address(positionManager), COLL);
        loanId = ace.open(id, COLL, PRINCIPAL, 0, borrower, OpenBounds(0, 0, 0));
        vm.stopPrank();
    }

    // ============ the class, in units ============

    /// @dev E2 pinned: this class HAS no window, so the two below-questions are one answer under two names.
    /// @dev It used to be pinned by passing two window arguments; there is no argument to vary any more.
    /// @dev The twins must stay DISTINCT FUNCTIONS: a future oracle-class record can carry real settle patience.
    function test_OracleRecord_TheTwinsAnswerIdentically() public view {
        assertEq(record.minPrice(recQ, recC), P, "the min is the answer, in the hub's atom frame");
        assertEq(record.persistedBelowDistress(recQ, recC, P * 2), record.persistedBelowSettle(recQ, recC, P * 2), "below-ness has no window");
        assertTrue(record.persistedBelowSettle(recQ, recC, P * 2), "and it is the live answer, not a constant false");
        assertTrue(record.persistedAbove(recQ, recC, P / 2), "above-ness likewise reads the feed");
    }

    function test_OracleRecord_StaleFeed_FailsClosedEverywhere() public {
        _warpBy(STALENESS + 1);
        assertEq(record.minPrice(recQ, recC), 0, "min answers closed");
        assertEq(record.lastObserved(recQ, recC), 0, "last answers closed");
        assertFalse(record.persistedBelowDistress(recQ, recC, type(uint256).max), "below answers closed");
        assertFalse(record.persistedAbove(recQ, recC, 0), "above answers closed");
    }

    function test_OracleRecord_IncompleteRound_FailsClosed() public {
        feed.setRound(2, ANSWER, _now(), 1); // answeredInRound < roundId
        assertEq(record.minPrice(recQ, recC), 0, "incomplete round answers closed");
    }

    function test_OracleRecord_NonPositiveAnswer_FailsClosed() public {
        feed.push(0);
        assertEq(record.minPrice(recQ, recC), 0, "zero answers closed");
        feed.push(-1);
        assertEq(record.minPrice(recQ, recC), 0, "negative answers closed");
    }

    /// @dev A REVERTING feed must answer closed, never bubble: `open` reads the record on the draw path.
    /// @dev A bubbled revert there would be indistinguishable from a bug.
    function test_OracleRecord_RevertingFeed_AnswersClosedNotBubbled() public {
        feed.setReverting(true);
        assertEq(record.minPrice(recQ, recC), 0, "caught, answered closed");
        assertFalse(record.persistedBelowDistress(recQ, recC, type(uint256).max), "below caught");
        assertFalse(record.persistedAbove(recQ, recC, 0), "above caught");
        assertEq(record.lastObserved(recQ, recC), 0, "last caught");
    }

    /// @dev The reason the class exists: the property the venue-fed record structurally lacks.
    function test_OracleRecord_TracksACrashImmediately() public {
        feed.push(ANSWER / 2);
        assertEq(record.minPrice(recQ, recC), P / 2, "the crash is visible in the same block");
        assertTrue(record.persistedBelowDistress(recQ, recC, P), "below-ness immediate");
    }

    function test_OracleRecord_CtorRails() public {
        vm.expectRevert(OracleRecord.BadParams.selector);
        new OracleRecord(address(0), address(usdc), address(vault), STALENESS);
        vm.expectRevert(OracleRecord.BadParams.selector);
        new OracleRecord(address(feed), address(usdc), address(vault), 0);
        vm.expectRevert(OracleRecord.BadParams.selector);
        new OracleRecord(address(feed), address(usdc), address(usdc), STALENESS);
    }

    /// @dev Pure trust-the-oracle: feed uptime and recovery are the ORACLE'S own infrastructure concern.
    /// @dev ACE adds no outage machinery, so a recovery round is live at once for every predicate, seizure included.
    function test_OracleRecord_OutageRecovery_IsImmediatelyLive() public {
        _warpBy(STALENESS + 2 hours); // the feed gapped
        feed.push(ANSWER / 4); // and recovered far below any trigger

        assertEq(record.minPrice(recQ, recC), P / 4, "the price reads live at once");
        assertTrue(record.persistedBelowDistress(recQ, recC, P), "and so does below-ness: no grace, no delay");
    }

    // ============ the class, wired into a market ============

    /// @dev Invariant 8: an ORACLE market goes through the untouched createMarket, zero singleton and genesis-rail diff.
    /// @dev Its setUp IS this assertion; this row pins the frame checks alongside it.
    function test_MarketGenesis_PassesUnmodified() public view {
        assertEq(ace.idToMarketParams(id).record, address(record), "the record seam holds the oracle");
    }

    function test_MarketGenesis_WrongFrame_Refused() public {
        OracleRecord inverse = new OracleRecord(address(feed), address(vault), address(usdc), STALENESS);
        MarketParams memory p = AceFixtures.marketParams(address(usdc), address(vault));
        p.record = address(inverse);
        Ace hub = AceFixtures.newAce();
        vm.expectRevert("record orientation");
        hub.createMarket(p);
    }

    /// @dev Invariant 9, both halves: a stale feed gates BORROWING only, and the lender's exit is never hostage to the oracle.
    function test_StaleFeed_GatesBorrowingOnly_WithdrawalsUnaffected() public {
        _warpBy(STALENESS + 1);

        vault.mint(borrower, COLL);
        vm.startPrank(borrower);
        vault.approve(address(positionManager), COLL);
        vm.expectRevert();
        ace.open(id, COLL, PRINCIPAL, 0, borrower, OpenBounds(0, 0, 0));
        vm.stopPrank();

        uint256 half = ace.restingOf(id) / 2; // resolved BEFORE the prank; an arg call eats it
        vm.prank(alice);
        uint256 out = ace.withdraw(id, half, alice, 0);
        assertGt(out, 0, "the lender leaves whenever they like");
    }

    /// @dev "Tenor bounds every trust": a loan admitted under a healthy feed rides out its term after the feed degrades.
    /// @dev No mid-loan confiscation path exists.
    function test_AdmittedLoanRidesOutItsTenor_AfterFeedDegrades() public {
        uint256 loanId = _open();
        _warpBy(STALENESS + 1); // the feed dies mid-term

        vm.expectRevert(NotSettleable.selector);
        ace.finalize(loanId); // a dead feed proves nothing, so it seizes nothing

        uint256 debt = read.debtOf(loanId);
        usdc.mint(borrower, debt);
        vm.startPrank(borrower);
        usdc.approve(address(ace), debt);
        ace.repay(loanId, debt); // and the borrower's own exit still works
        vm.stopPrank();
        assertEq(read.debtOf(loanId), 0, "cure never needs the oracle");
    }

    /// @dev Invariant 10: with the trust object fully dead the market degrades to termed loans.
    /// @dev forceClose reads no price and still settles at expiry, the same terminal state as depth-zero.
    function test_DeadFeed_MarketDegradesToTermedLoans() public {
        uint256 loanId = _open();
        feed.setReverting(true); // the feed dies outright
        _warpBy(uint256(read.loan(loanId).tenor) + 1);

        ace.forceClose(loanId); // reverts on failure

        assertTrue(read.loan(loanId).closedAt != 0, "settled at maturity with no price at all");
    }

    /// @dev The disposal floor prices off the oracle: a keeper crank clears at the live answer.
    /// @dev `out == lastQuoteOwed` alone proves nothing, since the callback itself wrote that value.
    /// @dev So the floor is also derived from the FEED answer and the units sold, and pinned.
    function test_Deleverage_FloorsOnTheOracleAnswer() public {
        uint256 loanId = _open();
        uint256 ps = _pushIntoBand(loanId, 105);

        (uint256 sold, uint256 out) = ace.deleverage(loanId, 0, "");

        assertGt(sold, 0, "the crank runs");
        assertEq(out, lastQuoteOwed, "and books the floor the oracle set");
        assertEq(out, _floorFor(sold, ps), "the floor is priced off the feed answer");
    }

    /// @dev A DIFFERENT in-band answer gives a different floor: one not read off the feed cannot pass.
    function test_Deleverage_FloorMovesWithTheOracleAnswer() public {
        uint256 loanId = _open();
        uint256 ps = _pushIntoBand(loanId, 125);

        (uint256 sold, uint256 out) = ace.deleverage(loanId, 0, "");

        assertGt(sold, 0, "the crank runs");
        assertEq(out, _floorFor(sold, ps), "the floor tracked the answer, not the callback");
    }

    /// @dev Push the feed to `pct`% of the loan's trigger, inside the band and above the stop.
    /// @dev Returns the atom price the record now reports, which is what the floor must be derived from.
    /// @dev It round-trips through the feed's own scale first, so `ps` is exactly representable there.
    function _pushIntoBand(uint256 loanId, uint256 pct) internal returns (uint256 ps) {
        uint256 answer = _toFeed((read.triggerPrice(loanId) * pct) / 100);
        feed.push(int256(answer));
        ps = _fromFeed(answer);
    }

    /// @dev The record's own normalization, restated: a human answer at the feed's scale becomes quote atoms per collateral atom.
    function _fromFeed(uint256 answer) internal view returns (uint256) {
        return (answer * ((uint256(1) << 96) * 10 ** usdc.decimals())) / (10 ** FEED_DECIMALS * 10 ** vault.decimals());
    }

    /// @dev Its inverse, floored: the largest feed answer the record maps at or below `atomPrice`.
    function _toFeed(uint256 atomPrice) internal view returns (uint256) {
        return (atomPrice * (10 ** FEED_DECIMALS * 10 ** vault.decimals())) / ((uint256(1) << 96) * 10 ** usdc.decimals());
    }

    /// @dev The hub's floor arithmetic restated from the market's stored dials: ceil, keeper eps off.
    function _floorFor(uint256 units, uint256 price) internal view returns (uint256) {
        uint256 den = 10000 * read.marketState(id).unitScale;
        return (units * price * (10000 - ace.idToMarketParams(id).deleverageFloorEpsBps) + den - 1) / den;
    }

    // ============ decimal normalization, off the 8-dec happy case ============

    /// @dev A feed whose decimals match the collateral's still needs the frame divided out, so this is no identity.
    function test_OracleRecord_Decimals18_NormalizationIsIdentity() public {
        MockAggregatorV3 f = new MockAggregatorV3(18);
        f.push(2e18);
        OracleRecord r = new OracleRecord(address(f), address(usdc), address(vault), STALENESS);
        assertEq(r.lastObserved(recQ, recC), P, "an 18-dec answer names the same two quote per token");
    }

    function test_OracleRecord_Decimals6_ScalesUpIntoThe1e18Frame() public {
        MockAggregatorV3 f = new MockAggregatorV3(6);
        f.push(2e6);
        OracleRecord r = new OracleRecord(address(f), address(usdc), address(vault), STALENESS);
        assertEq(r.lastObserved(recQ, recC), P, "a 6-dec answer lands on the same atom price");
    }

    /// @dev Zero decimals is the degenerate integer feed; SCALE == 1 must not divide the answer away.
    function test_OracleRecord_DecimalsZero_ScalesWholeUnits() public {
        MockAggregatorV3 f = new MockAggregatorV3(0);
        f.push(3);
        OracleRecord r = new OracleRecord(address(f), address(usdc), address(vault), STALENESS);
        assertEq(r.lastObserved(recQ, recC), AceFixtures.px(3e18, address(usdc), address(vault)), "whole units become atom-frame prices");
    }

    /// @dev A feed finer than the frame can carry loses the tail, so it must truncate DOWN and never panic.
    /// @dev Down leaves the record leg of the disposal floor conservative; up would invent value the feed never printed.
    function test_OracleRecord_Decimals20_TruncatesDownNeverUp() public {
        MockAggregatorV3 f = new MockAggregatorV3(20);
        f.push(2e20 + 99); // a sub-atom tail in the hub's frame
        OracleRecord r = new OracleRecord(address(f), address(usdc), address(vault), STALENESS);
        assertEq(r.lastObserved(recQ, recC), P, "the unrepresentable tail truncates");
    }

    /// @dev The absurd-answer guard is a `>` on `max / PRICE_NUM`, so the largest representable answer must still READ.
    /// @dev Only one past it answers closed; a `>=` there would blind the record for free.
    /// @dev `PRICE_NUM` is the hub's Q96 frame times the quote's atoms per whole token, restated here from the pair.
    function test_OracleRecord_AbsurdAnswer_ClosedOnlyPastTheBoundary() public {
        int256 edge = int256(type(uint256).max / ((uint256(1) << 96) * 10 ** usdc.decimals()));
        feed.push(edge);
        assertGt(record.lastObserved(recQ, recC), 0, "the largest representable answer still prices");
        feed.push(edge + 1);
        assertEq(record.lastObserved(recQ, recC), 0, "one past it answers closed instead of panicking");
    }

    // ============ the read's own boundaries ============

    /// @dev Staleness is `block.timestamp > upd + MAX_STALENESS`: at exactly the limit the feed is fit.
    function test_OracleRecord_StalenessBoundary_LiveAtExactlyTheLimit() public {
        _warpBy(STALENESS);
        assertEq(record.minPrice(recQ, recC), P, "at exactly MAX_STALENESS the round still reads");
        _warpBy(1);
        assertEq(record.minPrice(recQ, recC), 0, "one second past it answers closed");
    }

    /// @dev Both predicates are STRICT, and they must be: an inclusive `persistedBelow` puts a loan exactly on its trigger into distress.
    /// @dev An inclusive `persistedAbove` would call that same loan healthy enough to roll.
    function test_OracleRecord_BelowAndAbove_AreStrictAtEquality() public {
        feed.push(ANSWER); // a fresh round, so a stale feed answering closed is not what is under test here
        assertFalse(record.persistedBelowDistress(recQ, recC, P), "p == x is not below x");
        assertTrue(record.persistedBelowDistress(recQ, recC, P + 1), "one wei above x is");
        assertFalse(record.persistedAbove(recQ, recC, P), "p == x is not above x");
        assertTrue(record.persistedAbove(recQ, recC, P - 1), "one wei under x is");
    }

    // ============ the stamp itself ============

    /// @notice A feed stamping `updatedAt` at the word's ceiling reads CLOSED: the old `upd + MAX_STALENESS` panicked 0x11.
    function test_OracleRecord_UpdatedAtCeiling_ReadsClosedNotAPanic() public {
        feed.setRound(2, ANSWER, type(uint256).max, 2);
        assertEq(record.lastObserved(recQ, recC), 0, "closed, not an overflow");
        assertEq(record.minPrice(recQ, recC), 0, "the floor read with it");
        assertFalse(record.persistedBelowDistress(recQ, recC, type(uint256).max), "and it proves no below-ness");
    }

    /// @notice A round stamped ONE second ahead of the chain reads closed; the same round stamped now reads.
    function test_OracleRecord_FutureStamp_ReadsClosed() public {
        feed.setRound(2, ANSWER, _now() + 1, 2);
        assertEq(record.lastObserved(recQ, recC), 0, "a future stamp is closed");
        feed.setRound(3, ANSWER, _now(), 3);
        assertEq(record.lastObserved(recQ, recC), P, "and the same answer stamped now reads");
    }

    /// @notice A return too short to decode REVERTS the read: `try` catches the callee's revert, not the caller's decode.
    /// @dev The hub reads every record through a staticcall probe: its strict reads name it `RecordUnreadable`, its try reads answer not-ok.
    function testRevert_OracleRecord_ShortReturn_RevertsTheRead() public {
        OracleRecord r = new OracleRecord(address(new MockShortReturnFeed()), address(usdc), address(vault), STALENESS);
        vm.expectRevert();
        r.lastObserved(recQ, recC);
    }
}
