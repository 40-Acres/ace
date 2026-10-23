// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.36;

import {Test} from "forge-std/Test.sol";
import {WarpClock} from "../utils/WarpClock.sol";
import {Ace} from "../../src/ace/hub/Ace.sol";
import {MarketParams, OpenBounds} from "../../src/ace/hub/Types.sol";
import {NoRecordPrice} from "../../src/ace/hub/Borrower.sol";
import {PersistenceRecord} from "../utils/PersistenceRecord.sol";
import {OracleRecord} from "../../src/oracle/OracleRecord.sol";
import {MockAggregatorV3} from "../mocks/MockAggregatorV3.sol";
import {MockERC20} from "../mocks/MockERC20.sol";
import {MockPersistenceRecord} from "../mocks/MockPersistenceRecord.sol";
import {MockStakeVault} from "../mocks/MockStakeVault.sol";
import {AceFixtures} from "../utils/AceFixtures.sol";
import {PocDeployConfig} from "../../src/config/Defaults.sol";

/// @title AceYoungRecordRail
/// @notice Genesis ADMITS a young record; the DRAW DOOR is what refuses it, and for every class alike.
/// @notice A market on a cold record is creatable and inert: no draw lands until the record prints.
/// @dev The genesis age rail is DELETED: the record itself now answers 0 for silence, so its job is subsumed.
/// @dev The lockout it used to impose still exists, but its length is the RECORD's window now, not the market's.
/// @dev The span rail survives and is unrelated: too SHORT a ring is a different defect with a different fix.
/// @dev The ORACLE sentinel now clears only the SPAN rail; there is no age test left for it to exempt.
contract AceYoungRecordRailTest is WarpClock {
    Ace internal ace;
    MockERC20 internal usdc;
    MockStakeVault internal vault;
    PersistenceRecord internal record;
    PersistenceRecord internal slowRecord; // same ring and same anchor, twice the distress window

    uint256 internal constant INIT_PRICE = 1e18;
    uint256 internal constant COLL = 10_000e18; // draw-door sizing, borrowed from the deleverage suite
    uint256 internal constant PRINCIPAL = 4_500e6;
    uint256 internal constant W = PocDeployConfig.PERSISTENCE_WINDOW;
    uint256 internal constant PENDING = PocDeployConfig.PENDING_WINDOW;
    /// @dev Sized for the SLOW market at `2 * W`: the span rail demands the ring cover W + pending.
    uint256 internal constant OBS_CAP = (2 * W + PENDING) / 60 + 1;

    uint256 internal genesis;

    function setUp() public {
        _warpTo(1_000_000);
        usdc = new MockERC20("USD Coin", "USDC", 6);
        vault = new MockStakeVault(42);
        record = new PersistenceRecord(
            PersistenceRecord.Config({
                writer: address(this),
                truncCapBps: 5000,
                initialPrice: INIT_PRICE,
                obsInterval: 60,
                volRefFloor: 1,
                obsCap: OBS_CAP,
                unitScale: 1e30,
                volRefBps: 5000,
                depthWindow: 1800,
                quote: address(usdc),
                collateral: address(vault),
                persistenceWindow: 1800,
                pendingWindow: 3600
            })
        );
        slowRecord = new PersistenceRecord(
            PersistenceRecord.Config({
                writer: address(this),
                truncCapBps: 5000,
                initialPrice: INIT_PRICE,
                obsInterval: 60,
                volRefFloor: 1,
                obsCap: OBS_CAP,
                unitScale: 1e30,
                volRefBps: 5000,
                depthWindow: 1800,
                quote: address(usdc),
                collateral: address(vault),
                persistenceWindow: 2 * W,
                pendingWindow: uint64(PENDING)
            })
        );
        genesis = _now();
        ace = AceFixtures.newAce();
    }

    /// @dev The window is the RECORD's now, so a market cannot name one and this takes no window argument.
    /// @dev An ignored `uint64` used to sit here, which made two call sites passing different windows identical.
    function _params() internal returns (MarketParams memory p) {
        p = AceFixtures.marketParams(address(usdc), address(vault));
        p.record = address(record);
        p.lender = address(this); // this suite funds its markets itself, and only the named lender may rest
    }

    /// @dev Deploy `p` and fund one rung at par, leaving the market ready for exactly one draw.
    /// @dev The deposit door fails OPEN on a silent record, so the lender leg succeeds and the draw is the only subject.
    /// @dev Stops SHORT of the draw: `vm.expectRevert` binds to the next call, so an `open` here would arm on the deploy.
    function _fundedMarket(MarketParams memory p) internal returns (AceFixtures.Deployment memory d) {
        d = AceFixtures.deploy(p);
        usdc.mint(address(this), 15_000e6);
        usdc.approve(address(d.ace), 15_000e6);
        d.ace.deposit(d.id, 15_000e6);
        vault.mint(address(this), COLL);
        vault.approve(address(d.positionManager), COLL);
    }

    /// @notice A market on a record younger than its window is CREATABLE, and every draw against it refuses.
    /// @dev Creation succeeding is half the assertion -- the market exists, it is simply inert.
    function test_Draw_RefusesAgainstARecordYoungerThanItsWindow() public {
        MarketParams memory p = _params();
        assertTrue(ace.createMarket(p) != bytes32(0), "a young record no longer blocks creation");
        AceFixtures.Deployment memory d = _fundedMarket(p);
        vm.expectRevert(NoRecordPrice.selector);
        d.ace.open(d.id, COLL, PRINCIPAL, 0, address(this), OpenBounds(0, 0, 0));
    }

    /// @notice At `genesis + W` the record itself REFUSES -- its head sits ON the boundary -- and genesis admits anyway.
    /// @dev That is the whole shape of the change: creation reads no price, so no boundary decides anything here.
    function test_Genesis_AdmitsAtTheBoundaryExactly() public {
        MarketParams memory p = _params();
        _warpTo(genesis + W);
        assertTrue(ace.createMarket(p) != bytes32(0), "creation reads no price, so the record's boundary cannot block it");
    }

    /// @notice The lockout's length is the RECORD's window -- it just binds one door later than the deleted age rail.
    /// @dev Two records anchored together, one print each: the SHORTER window draws, twice that still refuses.
    /// @dev The refusal is the WALK, not the print: at `2 * W` the constructor anchor sits after the boundary.
    function test_Draw_LockoutLengthIsTheRecordsOwnWindow() public {
        _warpBy(W + 1);
        record.observe(INIT_PRICE, 1); // one print: the anchor still spans W, but not 2 * W
        slowRecord.observe(INIT_PRICE, 1);

        AceFixtures.Deployment memory fast = _fundedMarket(_params());
        fast.ace.open(fast.id, COLL, PRINCIPAL, 0, address(this), OpenBounds(0, 0, 0)); // the anchor is inside W

        MarketParams memory slowP = _params();
        slowP.record = address(slowRecord);
        AceFixtures.Deployment memory slow = _fundedMarket(slowP);
        vm.expectRevert(NoRecordPrice.selector);
        slow.ace.open(slow.id, COLL, PRINCIPAL, 0, address(this), OpenBounds(0, 0, 0));
    }

    /// @notice ORACLE-class records need no exemption: there is no span sentinel and no rail to be exempt from.
    /// @dev The class used to declare an unbounded span so the hub's rail would pass; both are gone.
    function test_Genesis_OracleClassIsExempt() public {
        (OracleRecord rec,) = _oracleRecord();

        MarketParams memory p = _params();
        p.record = address(rec);
        assertTrue(ace.createMarket(p) != bytes32(0), "a live feed has no history to be too young for");
    }

    /// @notice The sharp pin: creation must not depend on third-party feed uptime.
    /// @dev `minPrice` answers 0 on a stale feed, and genesis discards that answer rather than refusing on it.
    function test_Genesis_OracleClassIsExemptEvenWithAStaleFeed() public {
        (OracleRecord rec,) = _oracleRecord();
        _warpTo(genesis + PocDeployConfig.ORACLE_MAX_STALENESS + 1);
        assertEq(rec.minPrice(address(usdc), address(vault)), 0, "the stale feed answers closed");

        MarketParams memory p = _params();
        p.record = address(rec);
        assertTrue(ace.createMarket(p) != bytes32(0), "a dead feed still cannot block creation");
    }

    function test_Genesis_RecordlessMarketIsUnaffected() public {
        MarketParams memory p = AceFixtures.marketParams(address(usdc), address(vault));
        assertTrue(ace.createMarket(p) != bytes32(0), "no record, nothing to be too young");
    }

    /// @notice An old, fully-WRAPPED ring is admitted: eviction cannot outrun the span rail.
    /// @dev Refusal-by-eviction is unreachable by construction, so this pins the complement.
    /// @dev Bucket starts sit >= OBS_INTERVAL apart, so a full ring's reach is >= minGuaranteedSpan.
    /// @dev The span rail already holds that at or above W + pending, so a wrapped ring always spans W.
    /// @dev The young case is therefore the ONLY reachable refusal, which keeps the rail's name honest.
    function test_Genesis_WrappedRingStillSpansAfterEviction() public {
        for (uint256 i = 0; i < OBS_CAP + 2; i++) {
            _warpBy(60);
            record.observe(INIT_PRICE, 1);
        }
        assertGt(record.minPriceOverWindow(address(usdc), address(vault), W), 0, "the wrapped ring still spans the window");
        assertTrue(ace.createMarket(_params()) != bytes32(0), "an evicted anchor is no refusal");
    }

    // ============ the sentinel, isolated from any real ring ============

    /// @notice The span rail's boundary is INCLUSIVE: a record spanning exactly `W + PENDING` is admitted.
    function test_Genesis_AdmitsAFiniteSpanRecordThatAlreadyAnswers() public {
        MockPersistenceRecord warm = new MockPersistenceRecord(address(usdc), address(vault));
        warm.setMinGuaranteedSpan(W + PENDING); // exactly the span rail's floor, nothing to spare
        warm.setMinPrice(1e18);

        MarketParams memory p = _params();
        p.record = address(warm);
        assertTrue(ace.createMarket(p) != bytes32(0), "a warm ring-backed record is admitted");
    }

    /// @notice REGRESSION PIN on the FIXTURE: a default `MockPersistenceRecord` is a RING, not an oracle.
    /// @notice While its default was the sentinel, every suite naming it skipped the old rail unnoticed.
    /// @dev The two fixture assertions ARE the point: they keep the mock honest for every suite naming it.
    /// @dev Genesis caps the settle window at 7 days BEFORE the span check, so a lower default would gate fixtures there.
    function test_Fixture_DefaultMockIsRingClass_NotTheOracleSentinel() public {
        MockPersistenceRecord def = new MockPersistenceRecord(address(usdc), address(vault));
        assertTrue(def.minGuaranteedSpan() != type(uint256).max, "the fixture must not claim the ORACLE sentinel");
        assertGe(def.minGuaranteedSpan(), 7 days, "and it must clear the settle-window ceiling, or it gates fixtures");

        def.setMinPrice(0); // a silent ring-class record: creatable now, and refused at the draw door
        MarketParams memory p = _params();
        p.record = address(def);
        assertTrue(ace.createMarket(p) != bytes32(0), "a ring-class record with no price still creates");
    }

    /// @dev `test_Genesis_SpanRailOutranksTheYouthRail` was DELETED when the windows moved onto the record.
    /// @dev It asserted `createMarket` reverts "window over record span", a hub rail that no longer exists.
    /// @dev The span is the RECORD's own constructor rail now: `AceGenesisSpanRail` owns that boundary.
    /// @dev Its sibling there, `test_Genesis_AsksTheRecordNoWindowAtAll`, pins the hub side of the same move.

    function _oracleRecord() internal returns (OracleRecord rec, MockAggregatorV3 feed) {
        feed = new MockAggregatorV3(8);
        feed.push(int256(100_000e8));
        rec = new OracleRecord(address(feed), address(usdc), address(vault), PocDeployConfig.ORACLE_MAX_STALENESS);
    }
}
