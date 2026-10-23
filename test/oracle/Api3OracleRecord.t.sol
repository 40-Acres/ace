// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.36;

import {Test} from "forge-std/Test.sol";
import {WarpClock} from "../utils/WarpClock.sol";
import {Ace} from "../../src/ace/hub/Ace.sol";
import {NotInBand} from "../../src/ace/hub/Deleverage.sol";
import {MarketParams, OpenBounds} from "../../src/ace/hub/Types.sol";
import {PositionManager} from "../../src/ace/positions/PositionManager.sol";
import {Api3OracleRecord} from "../../src/oracle/Api3OracleRecord.sol";
import {MockApi3ReaderProxy} from "../mocks/MockApi3ReaderProxy.sol";
import {MockShortReturnFeed} from "../mocks/MockShortReturnFeed.sol";
import {MockERC20} from "../mocks/MockERC20.sol";
import {MockStakeVault} from "../mocks/MockStakeVault.sol";
import {AceFixtures} from "../utils/AceFixtures.sol";
import {ProtocolPolicy} from "../../src/config/Defaults.sol";
import {AceReader} from "../utils/AceReader.sol";
import {DeleverageCrank} from "../utils/DeleverageCrank.sol";

/// @title Api3OracleRecordTest
/// @notice The API3 flavour of the ORACLE class: the aggregator-shape record's posture over the dAPI value+timestamp surface.
/// @dev The dAPI's 18-dec value IS the frame, so there is no scaling step.
contract Api3OracleRecordTest is WarpClock, DeleverageCrank {
    Ace internal ace;
    PositionManager internal positionManager;
    AceReader internal read;
    MockERC20 internal usdc;
    MockStakeVault internal vault;
    MockApi3ReaderProxy internal dapi;
    Api3OracleRecord internal record;
    bytes32 internal id;
    // the ordered pair the record is constructed with; every record read is parameterized by it
    address internal recQ;
    address internal recC;

    address internal alice = address(0xA11CE);
    address internal borrower = address(0xB0B);

    uint256 internal constant COLL = 10_000e18;
    uint256 internal constant PRINCIPAL = 4_500e6;
    int224 internal constant VALUE = 2e18; // the dAPI convention is 18-dec: two quote per whole token
    uint256 internal constant BAND_BPS = 3000;
    uint256 internal P; // the same two quote per token in the hub's atom frame, which needs the pair to state
    uint256 internal constant STALENESS = 1 hours;

    function setUp() public {
        _warpTo(365 days); // clear of genesis so staleness arithmetic never underflows
        usdc = new MockERC20("USD Coin", "USDC", 6);
        vault = new MockStakeVault(42);
        dapi = new MockApi3ReaderProxy();
        dapi.set(VALUE);
        record = new Api3OracleRecord(address(dapi), address(usdc), address(vault), STALENESS);
        (recQ, recC) = (address(usdc), address(vault));
        P = AceFixtures.px(2e18, address(usdc), address(vault));

        MarketParams memory p = AceFixtures.marketParams(address(usdc), address(vault));
        p.record = address(record);
        p.deleverageFloorEpsBps = ProtocolPolicy.DELEVERAGE_FLOOR_EPS_BPS;
        p.deleverageBandBps = BAND_BPS; // the one crank that prices off the dAPI
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

    /// @dev The class carries no window at all now, so the two below-questions are one answer under two names.
    function test_Api3Record_ValueIsTheFrame_NoWindowInThisClass() public view {
        assertEq(record.minPrice(recQ, recC), P, "the 18-dec dAPI value lands on the pair's atom price");
        assertEq(record.persistedBelowDistress(recQ, recC, P + 1), record.persistedBelowSettle(recQ, recC, P + 1), "no window in this class");
        assertEq(record.lastObserved(recQ, recC), P, "last is the same read");
    }

    function test_Api3Record_StaleFeed_FailsClosedEverywhere() public {
        _warpBy(STALENESS + 1);
        assertEq(record.minPrice(recQ, recC), 0, "min answers closed");
        assertEq(record.lastObserved(recQ, recC), 0, "last answers closed");
        assertFalse(record.persistedBelowDistress(recQ, recC, type(uint256).max), "below answers closed");
        assertFalse(record.persistedAbove(recQ, recC, 0), "above answers closed");
    }

    function test_Api3Record_NonPositiveValue_FailsClosed() public {
        dapi.set(0);
        assertEq(record.minPrice(recQ, recC), 0, "zero answers closed");
        dapi.set(-1);
        assertEq(record.minPrice(recQ, recC), 0, "negative answers closed");
    }

    function test_Api3Record_RevertingFeed_AnswersClosedNotBubbled() public {
        dapi.setReverting(true);
        assertEq(record.minPrice(recQ, recC), 0, "caught, answered closed");
        assertFalse(record.persistedBelowDistress(recQ, recC, type(uint256).max), "below caught");
        assertFalse(record.persistedAbove(recQ, recC, 0), "above caught");
    }

    function test_Api3Record_TracksACrashImmediately_RecoveryLiveAtOnce() public {
        _warpBy(STALENESS + 2 hours); // the feed gapped
        dapi.set(VALUE / 4); // and recovered far below any trigger
        assertEq(record.minPrice(recQ, recC), P / 4, "live at once");
        assertTrue(record.persistedBelowSettle(recQ, recC, P), "for every predicate, seizure included: no grace");
    }

    function test_Api3Record_StalenessBoundary_LiveAtExactlyTheLimit() public {
        _warpBy(STALENESS); // now == ts + MAX exactly
        assertEq(record.minPrice(recQ, recC), P, "live at the boundary");
        _warpBy(1);
        assertEq(record.minPrice(recQ, recC), 0, "closed one second past it");
    }

    /// @notice A dAPI value stamped ahead of the chain reads CLOSED, one second ahead and at the furthest stamp it carries.
    function test_Api3Record_FutureStamp_ReadsClosed() public {
        dapi.setStamped(VALUE, uint32(_now() + 1));
        assertEq(record.lastObserved(recQ, recC), 0, "one second ahead is closed");
        dapi.setStamped(VALUE, type(uint32).max);
        assertEq(record.lastObserved(recQ, recC), 0, "and so is the stamp's ceiling");
        assertFalse(record.persistedBelowDistress(recQ, recC, type(uint256).max), "and it proves no below-ness");
        dapi.setStamped(VALUE, uint32(_now()));
        assertEq(record.lastObserved(recQ, recC), P, "the same value stamped now reads");
    }

    /// @notice A return too short to decode REVERTS the read rather than answering closed; the hub's strict reads name it `RecordUnreadable`.
    function testRevert_Api3Record_ShortReturn_RevertsTheRead() public {
        Api3OracleRecord r = new Api3OracleRecord(address(new MockShortReturnFeed()), address(usdc), address(vault), STALENESS);
        vm.expectRevert();
        r.lastObserved(recQ, recC);
    }

    function test_Api3Record_CtorRails() public {
        vm.expectRevert(Api3OracleRecord.BadParams.selector);
        new Api3OracleRecord(address(0), address(usdc), address(vault), STALENESS);
        vm.expectRevert(Api3OracleRecord.BadParams.selector);
        new Api3OracleRecord(address(dapi), address(usdc), address(vault), 0);
        vm.expectRevert(Api3OracleRecord.BadParams.selector);
        new Api3OracleRecord(address(dapi), address(usdc), address(usdc), STALENESS);
    }

    function test_MarketGenesis_PassesUnmodified_WrongFrameRefused() public {
        assertEq(ace.idToMarketParams(id).record, address(record), "the record seam holds the dAPI");

        Api3OracleRecord inverse = new Api3OracleRecord(address(dapi), address(vault), address(usdc), STALENESS);
        MarketParams memory p = AceFixtures.marketParams(address(usdc), address(vault));
        p.record = address(inverse);
        Ace hub = AceFixtures.newAce();
        vm.expectRevert("record orientation");
        hub.createMarket(p);
    }

    /// @dev The disposal floor prices off the dAPI: a keeper crank clears at the live value.
    /// @dev `out == lastQuoteOwed` alone proves nothing, since the callback itself wrote that value.
    /// @dev So the floor is also derived from the dAPI VALUE and the units sold, and pinned.
    function test_Deleverage_FloorsOnTheDapiValue() public {
        uint256 loanId = _open();
        uint256 ps = _pushIntoBand(loanId, 105);

        (uint256 sold, uint256 out) = ace.deleverage(loanId, 0, "");

        assertGt(sold, 0, "the crank runs");
        assertEq(out, lastQuoteOwed, "and books the floor the dAPI set");
        assertEq(out, _floorFor(sold, ps), "the floor is priced off the dAPI value");
    }

    /// @dev A DIFFERENT in-band value gives a different floor: one not read off the dAPI cannot pass.
    function test_Deleverage_FloorMovesWithTheDapiValue() public {
        uint256 loanId = _open();
        uint256 ps = _pushIntoBand(loanId, 125);

        (uint256 sold, uint256 out) = ace.deleverage(loanId, 0, "");

        assertGt(sold, 0, "the crank runs");
        assertEq(out, _floorFor(sold, ps), "the floor tracked the dAPI, not the callback");
    }

    /// @notice THE WINDOWLESS CLASS AS THE WHOLE FLOOR: `minPrice` and `lastObserved` are one read here.
    /// @dev Genesis CALLS `lastObserved` on every market naming a record, so a class that cannot answer bars
    /// @dev the whole market at creation, not merely the crank -- a curator vault market could not arm at all.
    /// @dev This class holds no window, so the sizing read and the head are the same number by construction.
    /// @dev Its own deployment on purpose -- the shared one is built by the fixture and is not band-armed.
    function test_Api3Record_TheWindowlessFloor_GenesisAdmitsAndTheCrankClears() public {
        assertTrue(record.supportsPair(recQ, recC), "the record prices this ordered pair");
        assertEq(record.lastObserved(recQ, recC), record.minPrice(recQ, recC), "no window: the head and the floor are one read");

        MarketParams memory p = AceFixtures.marketParams(address(usdc), address(vault));
        p.record = address(record);
        p.deleverageFloorEpsBps = ProtocolPolicy.DELEVERAGE_FLOOR_EPS_BPS;
        p.deleverageBandBps = BAND_BPS;
        p.deleverageTargetBps = 4000;
        p.deleverageStopBps = 1;
        AceFixtures.Deployment memory d = AceFixtures.deploy(p);
        assertEq(d.ace.idToMarketParams(d.id).record, address(record), "genesis admitted the windowless record");

        usdc.mint(alice, 15_000e6);
        vm.startPrank(alice);
        usdc.approve(address(d.ace), 15_000e6);
        d.ace.deposit(d.id, 15_000e6);
        vm.stopPrank();

        vault.mint(borrower, COLL);
        vm.startPrank(borrower);
        vault.approve(address(d.positionManager), COLL);
        uint256 loanId = d.ace.open(d.id, COLL, PRINCIPAL, 0, borrower, OpenBounds(0, 0, 0));
        vm.stopPrank();

        uint256 value = _toDapi((d.read.triggerPrice(loanId) * 105) / 100);
        dapi.set(int224(int256(value))); // ONE write moves the whole floor: there is no second source to keep in sync
        uint256 ps = _fromDapi(value);

        (uint256 sold, uint256 out) = d.ace.deleverage(loanId, 0, "");
        assertGt(sold, 0, "the crank runs on the record alone");
        uint256 den = 10000 * d.read.marketState(d.id).unitScale;
        uint256 floor = (sold * ps * (10000 - d.ace.idToMarketParams(d.id).deleverageFloorEpsBps) + den - 1) / den;
        assertEq(out, floor, "and the floor is the dAPI value, read once");
    }

    /// @notice The pair rail on EVERY read this record answers.
    /// @dev Nothing asserted this before, on any read: a live wire only ever calls the pair the market was
    /// @dev created against, so a dropped `_requirePair` is invisible end to end and survives the whole suite.
    /// @dev A direct wrong-pair call is the only thing that can catch it, and this is that call.
    /// @dev `supportsPair` is the deliberate exception: genesis asks it as a QUESTION and reads false as the refusal.
    function testRevert_Api3Record_WrongPair_RefusedOnEveryRead() public {
        assertFalse(record.supportsPair(recC, recQ), "the inverted pair is not this record's");
        assertFalse(record.supportsPair(recQ, address(this)), "nor a foreign collateral");

        vm.expectRevert(Api3OracleRecord.WrongPair.selector);
        record.minPrice(recQ, address(this));
        vm.expectRevert(Api3OracleRecord.WrongPair.selector);
        record.minPrice(recC, recQ);
        vm.expectRevert(Api3OracleRecord.WrongPair.selector);
        record.lastObserved(recC, recQ);
        vm.expectRevert(Api3OracleRecord.WrongPair.selector);
        record.persistedBelowDistress(recC, recQ, P);
        vm.expectRevert(Api3OracleRecord.WrongPair.selector);
        record.persistedBelowSettle(recC, recQ, P);
        vm.expectRevert(Api3OracleRecord.WrongPair.selector);
        record.persistedAbove(recC, recQ, P);
    }

    /// @notice A SICK FEED SELLS NOTHING: the one floor read goes dark and the crank halts.
    /// @dev The halt is `NotInBand`, NOT `NoRecordPrice`: a zeroed record answers the band gate false, and that
    /// @dev gate sits upstream of the sizing read, so the floor arithmetic is never reached with nothing to price at.
    /// @dev FRESHNESS ALONE is the discriminator: the identical dAPI value cranks a moment before the gap and after it.
    function testRevert_Deleverage_SickFeed_HaltsRatherThanSellingAtAZeroFloor() public {
        AceFixtures.Deployment memory d = _bandedMarket(address(record));
        uint256 loanId = _openOn(d);
        uint256 value = _toDapi((d.read.triggerPrice(loanId) * 105) / 100);
        dapi.set(int224(int256(value)));

        _warpBy(STALENESS + 1); // the value is untouched; only its freshness is gone
        assertEq(record.minPrice(recQ, recC), 0, "the floor read went dark");
        vm.expectRevert(NotInBand.selector);
        d.ace.deleverage(loanId, 0, "");

        dapi.set(int224(int256(value))); // the SAME value, freshly stamped
        (uint256 sold, uint256 out) = d.ace.deleverage(loanId, 0, "");
        assertGt(sold, 0, "freshness alone was the difference");
        assertEq(out, _floorOn(d, sold, _fromDapi(value)), "and the floor is the value the feed came back with");
    }

    /// @dev Move the dAPI to `pct`% of the loan's trigger, inside the band and above the stop.
    /// @dev ONE write moves the floor, because the floor is the record's own read.
    /// @dev It round-trips through the dAPI's 18-dec human convention first, so `ps` is exactly representable there.
    function _pushIntoBand(uint256 loanId, uint256 pct) internal returns (uint256 ps) {
        uint256 value = _toDapi((read.triggerPrice(loanId) * pct) / 100);
        dapi.set(int224(int256(value)));
        ps = _fromDapi(value);
    }

    /// @dev The record's own normalization, restated: an 18-dec human dAPI value becomes quote atoms per collateral atom.
    function _fromDapi(uint256 value) internal view returns (uint256) {
        return (value * ((uint256(1) << 96) * 10 ** usdc.decimals())) / (1e18 * 10 ** vault.decimals());
    }

    /// @dev Its inverse, floored: the largest dAPI value the record maps at or below `atomPrice`.
    function _toDapi(uint256 atomPrice) internal view returns (uint256) {
        return (atomPrice * (1e18 * 10 ** vault.decimals())) / ((uint256(1) << 96) * 10 ** usdc.decimals());
    }

    function _open() internal returns (uint256 loanId) {
        vault.mint(borrower, COLL);
        vm.startPrank(borrower);
        vault.approve(address(positionManager), COLL);
        loanId = ace.open(id, COLL, PRINCIPAL, 0, borrower, OpenBounds(0, 0, 0));
        vm.stopPrank();
    }

    /// @dev The hub's floor arithmetic restated from the market's stored dials: ceil, keeper eps off.
    function _floorFor(uint256 units, uint256 price) internal view returns (uint256) {
        uint256 den = 10000 * read.marketState(id).unitScale;
        return (units * price * (10000 - ace.idToMarketParams(id).deleverageFloorEpsBps) + den - 1) / den;
    }

    /// @dev The same restatement against an arbitrary deployment, for the tests that build their own.
    function _floorOn(AceFixtures.Deployment memory d, uint256 units, uint256 price) internal view returns (uint256) {
        uint256 den = 10000 * d.read.marketState(d.id).unitScale;
        return (units * price * (10000 - d.ace.idToMarketParams(d.id).deleverageFloorEpsBps) + den - 1) / den;
    }

    /// @dev A funded market with the decline channel armed, over the floor source named.
    /// @dev Its own hub each time: a market's sources are written at genesis and cannot be re-aimed after.
    function _bandedMarket(address rec) internal returns (AceFixtures.Deployment memory d) {
        MarketParams memory p = AceFixtures.marketParams(address(usdc), address(vault));
        p.record = rec;
        p.deleverageFloorEpsBps = ProtocolPolicy.DELEVERAGE_FLOOR_EPS_BPS;
        p.deleverageBandBps = BAND_BPS;
        p.deleverageTargetBps = 4000;
        p.deleverageStopBps = 1;
        d = AceFixtures.deploy(p);

        usdc.mint(alice, 15_000e6);
        vm.startPrank(alice);
        usdc.approve(address(d.ace), 15_000e6);
        d.ace.deposit(d.id, 15_000e6);
        vm.stopPrank();
    }

    /// @dev The suite's standard loan, opened on whichever deployment is passed.
    function _openOn(AceFixtures.Deployment memory d) internal returns (uint256 loanId) {
        vault.mint(borrower, COLL);
        vm.startPrank(borrower);
        vault.approve(address(d.positionManager), COLL);
        loanId = d.ace.open(d.id, COLL, PRINCIPAL, 0, borrower, OpenBounds(0, 0, 0));
        vm.stopPrank();
    }
}
