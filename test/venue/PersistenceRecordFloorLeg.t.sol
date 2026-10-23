// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.36;

import {WarpClock} from "../utils/WarpClock.sol";
import {FullMath} from "@uniswap/v4-core/src/libraries/FullMath.sol";
import {Ace} from "../../src/ace/hub/Ace.sol";
import {MarketParams, OpenBounds} from "../../src/ace/hub/Types.sol";
import {PositionManager} from "../../src/ace/positions/PositionManager.sol";
import {PersistenceRecord} from "../utils/PersistenceRecord.sol";
import {PocDeployConfig, ProtocolPolicy} from "../../src/config/Defaults.sol";
import {MockERC20} from "../mocks/MockERC20.sol";
import {MockStakeVault} from "../mocks/MockStakeVault.sol";
import {MockDeleverageKeeper} from "../mocks/MockDeleverageKeeper.sol";
import {AceFixtures} from "../utils/AceFixtures.sol";
import {AceReader} from "../utils/AceReader.sol";
import {PriceFrame} from "../utils/PriceFrame.sol";

/// @title PersistenceRecordFloorLegTest
/// @notice The venue record answering the DISPOSAL FLOOR, which is its windowed minimum and nothing else.
/// @notice `lastObserved` is the HEAD, the fast leg, and the crank no longer reads it: it is kept for views and contrast.
/// @dev Bare record, no market: the pair is two placeholders, exactly as the neighbouring record suites declare it.
contract PersistenceRecordFloorLegTest is WarpClock {
    PersistenceRecord internal rec;

    uint256 internal constant TRUNC_BPS = 500; // 5% per bucket at full volume
    address internal constant FQ = address(0x9001); // record-only suite: the declared pair is two placeholders
    address internal constant FC = address(0xC011);

    uint256 internal START; // the deploy anchor, in the hub's fixed price frame

    function setUp() public {
        _warpTo(1_000_000); // non-zero base time
        START = PriceFrame.px(1e18, FQ, FC);
        rec = new PersistenceRecord(
            PersistenceRecord.Config({
                writer: address(this),
                truncCapBps: TRUNC_BPS,
                initialPrice: START,
                obsInterval: 60,
                volRefFloor: 1e18,
                obsCap: 64,
                unitScale: 1 << 96,
                volRefBps: 5000,
                depthWindow: 1800,
                quote: FQ,
                collateral: FC,
                persistenceWindow: 1800,
                pendingWindow: 1800
            })
        );
    }

    /// @notice The number the crank reads for BOTH sizing and the floor: the record's windowed minimum.
    /// @notice IT FAILS CLOSED ON A YOUNG RING, where the head does not, and that asymmetry is the point.
    /// @dev The floor owes a WINDOW; the head owes only its last write, so it answers the anchor immediately.
    /// @dev Reading the head for the floor would let a sale price against an anchor nothing ever held at.
    function test_FloorPrice_AnswersTheWindowedMinimum_AndFailsClosedUntilTheRingSpansIt() public {
        assertEq(rec.minPrice(FQ, FC), 0, "a ring younger than the window cannot floor a sale");
        assertEq(rec.lastObserved(FQ, FC), START, "while the head answers the deploy anchor at once");

        _warpBy(1800);
        rec.observe(START, 1e18);

        assertEq(rec.minPrice(FQ, FC), START, "once the ring spans the window the floor is the price that held");
        assertEq(rec.minPrice(FQ, FC), rec.lastObserved(FQ, FC), "and with no move between them the two agree");
    }

    /// @notice A wrong-pair read is a wiring bug, so it must revert loudly the way every other member of this record does.
    /// @dev The pair is passed INVERTED, which is the mistake an inverse market makes.
    function test_FloorPrice_WrongPair_Reverts() public {
        vm.expectRevert(PersistenceRecord.WrongPair.selector);
        rec.minPrice(FC, FQ);
    }

    /// @notice The head and the floor are different instruments, and a recovery separates them.
    /// @notice The crank reads the FLOOR, so a head that has run ahead of the window buys a keeper nothing.
    /// @dev A dump truncated to -5%, then a recovery truncated to +5% off the new base.
    /// @dev The low bucket is still inside the window, so the floor holds it while the head has already moved on.
    function test_FloorPrice_LagsTheHeadThroughARecovery() public {
        _warpBy(1800);
        rec.observe(PriceFrame.px(0.1e18, FQ, FC), 1e18); // a one-tx dump, capped to -5%
        _warpBy(60);
        rec.observe(PriceFrame.px(2e18, FQ, FC), 1e18); // the recovery, capped to +5%
        _warpBy(60);

        uint256 head = rec.lastObserved(FQ, FC);
        uint256 floorPrice = rec.minPriceOverWindow(FQ, FC, 30 minutes);
        uint256 low = START - (START * TRUNC_BPS) / 10000;

        assertGt(head, floorPrice, "fixture non-vacuity: the head and the floor really did separate");
        assertEq(floorPrice, low, "the floor is still holding the truncated low");
        assertEq(head, low + (low * TRUNC_BPS) / 10000, "while the head took the capped step back up");
    }
}

/// @title PersistenceRecordFloorLegMarketTest
/// @notice The ACE-VENUE wiring: ONE `PersistenceRecord` is the market's whole price surface.
/// @notice Genesis CALLS the head read on every market, and the crank reads the windowed minimum on every sale.
/// @dev The direction property is the point: one number sizes the sale AND prices it, so neither can move without the other.
contract PersistenceRecordFloorLegMarketTest is WarpClock {
    Ace internal ace;
    PositionManager internal positionManager;
    AceReader internal read;
    PersistenceRecord internal rec;
    MockERC20 internal usdc;
    MockStakeVault internal vault;
    MockDeleverageKeeper internal keeper;
    bytes32 internal id;

    address internal alice = address(0xA11CE);
    address internal borrower = address(0xB0B);

    uint256 internal constant COLL = 10_000e18;
    uint256 internal constant PRINCIPAL = 4_500e6;
    uint256 internal constant UNIT_SCALE = 1 << 96; // every market's scale under the atom frame
    uint256 internal constant EPS = ProtocolPolicy.DELEVERAGE_FLOOR_EPS_BPS;
    uint256 internal constant BAND_BPS = 3000; // the channel opens below 30% margin
    uint256 internal constant TARGET_BPS = 4000; // and restores to 40%
    uint64 internal constant OBS_INTERVAL = 60; // bucket width; one observe per warp
    uint256 internal constant OBS_CAP = 271; // (271 - 1) x 60s == P + pending exactly, the genesis span rail

    uint256 internal T; // this pair's par tick
    uint256 internal P; // the healthy print, $2.00 per token
    uint256 internal PS_BAND; // $0.70: inside the band over the ~0.63 trigger, clear of the 1 bps stop
    uint256 internal UP; // $0.85: the head recovered, still under the ~0.90 band level
    uint256 internal DOWN; // $0.65: a new low, still above the stop level

    function setUp() public {
        _warpTo(1_000_000);
        usdc = new MockERC20("USD Coin", "USDC", 6);
        vault = new MockStakeVault(42);
        T = AceFixtures.priceAt(address(usdc), address(vault), 0);
        P = AceFixtures.px(2e18, address(usdc), address(vault));
        PS_BAND = AceFixtures.px(0.7e18, address(usdc), address(vault));
        UP = AceFixtures.px(0.85e18, address(usdc), address(vault));
        DOWN = AceFixtures.px(0.65e18, address(usdc), address(vault));
        rec = _newRecord();
        _spanWindowOn(rec, PocDeployConfig.PERSISTENCE_WINDOW); // a draw refuses a ring that has not printed inside the window
    }

    // ============ genesis: the market this bug makes uncreatable ============

    /// @notice Genesis CALLS the record's head read, not merely its orientation, so a mute record cannot be wired at all.
    /// @notice Every other rail on this wiring passes, so the market's creatability rides on the record answering that member.
    function test_Genesis_VenueMarket_WithTheRecordAsItsOnlyPriceSource_IsCreatable() public {
        Ace hub = AceFixtures.newAce();

        bytes32 mid = hub.createMarket(_params());

        assertEq(hub.idToMarketParams(mid).record, address(rec), "one record is the whole price surface, which is what ACE-VENUE means");
    }

    /// @notice The control that makes the row above non-vacuous: DISARM the channel and the same wiring is still admitted.
    /// @notice The head probe is UNCONDITIONAL, so a disarmed market owes the same answer an armed one does.
    function test_Genesis_SameWiring_WithTheChannelDisarmed_IsAdmitted() public {
        Ace hub = AceFixtures.newAce();
        MarketParams memory p = _params();
        p.deleverageBandBps = 0;
        p.deleverageTargetBps = 0;
        p.deleverageStopBps = 0; // the lie guard: a disarmed channel carries no stop, cut, target or eps
        p.deleverageProtocolBps = 0;
        p.deleverageFloorEpsBps = 0;

        bytes32 mid = hub.createMarket(p);

        assertEq(hub.idToMarketParams(mid).record, address(rec), "pair, span, frame and age all pass on their own");
    }

    // ============ the direction property one price source carries ============

    /// @notice ONE PRICE SOURCE: walking the head UP changes NOTHING -- not the sizing, and not the floor.
    /// @notice The windowed minimum prices admission, distress, sizing AND the floor, so a recovering print moves none of them.
    /// @dev This is the property the head leg used to break: it let a keeper's pay-in ride a print the sale was never sized at.
    /// @dev Differential off one snapshot: both branches warp the same 60s and observe once, so only the head price differs.
    function test_Deleverage_WalkingTheHeadUp_ChangesNeitherSizingNorTheFloor() public {
        _market();
        uint256 loanId = _open();
        _walkIntoBand();

        uint256 snap = vm.snapshotState();
        _warpBy(OBS_INTERVAL);
        rec.observe(PS_BAND, 1e18); // the head stays ON the windowed minimum
        (uint256 sold0, uint256 out0) = keeper.crankDeleverage(loanId);

        vm.revertToState(snap);
        _warpBy(OBS_INTERVAL);
        rec.observe(UP, 1e18); // the head recovers while the window keeps its low
        assertEq(_recordLeg(), PS_BAND, "fixture: the windowed minimum did not move");
        assertEq(rec.lastObserved(address(usdc), address(vault)), UP, "fixture non-vacuity: the head really did");
        (uint256 sold1, uint256 out1) = keeper.crankDeleverage(loanId);

        assertGt(sold0, 0, "fixture non-vacuity: the baseline crank really sold");
        assertEq(sold1, sold0, "sizing reads the windowed minimum, which the head did not move");
        assertEq(out1, out0, "and so does the floor: a recovering head raises the keeper's pay-in not at all");
        assertEq(out1, _owedAt(sold1, PS_BAND), "the floor IS the windowed minimum, never the head");
    }

    /// @notice Walking the head DOWN moves sizing and the floor TOGETHER, because they are one number.
    /// @notice The head sits INSIDE the window, so a new low is also the new windowed minimum and both land at once.
    /// @dev The sale grows and its price falls in step, which is what keeps the restore landing on target rather than past it.
    function test_Deleverage_WalkingTheHeadDown_MovesSizingAndTheFloorTogether() public {
        _market();
        uint256 loanId = _open();
        _walkIntoBand();

        uint256 snap = vm.snapshotState();
        _warpBy(OBS_INTERVAL);
        rec.observe(PS_BAND, 1e18);
        (uint256 sold0,) = keeper.crankDeleverage(loanId);

        vm.revertToState(snap);
        _warpBy(OBS_INTERVAL);
        rec.observe(DOWN, 1e18); // a new low: the head and the window minimum move together
        assertEq(_recordLeg(), DOWN, "fixture: the new low IS the window's minimum");
        (uint256 sold2, uint256 out2) = keeper.crankDeleverage(loanId);

        assertGt(sold2, sold0, "the lower windowed minimum sizes a bigger sale");
        assertEq(out2, _owedAt(sold2, DOWN), "and the floor sits exactly ON it, which is the price the sale was sized at");
        assertLe(read.triggerPrice(loanId), FullMath.mulDiv(DOWN, 1e18 - TARGET_BPS * 1e14, 1e18) + 1, "so the sale still restores target");
    }

    // ============ helpers ============

    /// @dev Venue-class params, wiring ONE record into both price legs the way `Playground.s.sol` does.
    function _params() internal view returns (MarketParams memory p) {
        p = AceFixtures.marketParams(address(usdc), address(vault));
        p.record = address(rec);
        p.deleverageFloorEpsBps = EPS;
        p.deleverageBandBps = BAND_BPS;
        p.deleverageTargetBps = TARGET_BPS;
        p.deleverageStopBps = 1; // tiny: keeps this suite's near-trigger fixture admitted, and the cut stays 0
    }

    /// @dev A full-cap, full-weight ring: a walk lands exactly where the test asks, so ring SHAPE is the only moving part.
    /// @dev `volRefFloor` 1 makes any volume full weight, and a 10000 bps cap admits any step inside one doubling.
    function _newRecord() internal returns (PersistenceRecord) {
        uint256 window = PocDeployConfig.PERSISTENCE_WINDOW;
        return new PersistenceRecord(
            PersistenceRecord.Config({
                writer: address(this),
                truncCapBps: 10000,
                initialPrice: P,
                obsInterval: OBS_INTERVAL,
                volRefFloor: 1,
                obsCap: OBS_CAP,
                unitScale: UNIT_SCALE,
                volRefBps: 10000,
                depthWindow: window,
                quote: address(usdc),
                collateral: address(vault),
                persistenceWindow: window,
                pendingWindow: PocDeployConfig.PENDING_WINDOW
            })
        );
    }

    /// @dev The market, the keeper and a one-tick ladder, built here rather than in `setUp` so genesis is its own subject.
    function _market() internal {
        AceFixtures.Deployment memory d = AceFixtures.deploy(_params());
        (ace, positionManager, read, id) = (d.ace, d.positionManager, d.read, d.id);
        keeper = new MockDeleverageKeeper(ace, address(usdc), address(vault), UNIT_SCALE);
        usdc.mint(alice, 15_000e6);
        vm.startPrank(alice);
        usdc.approve(address(ace), 15_000e6);
        ace.deposit(id, 15_000e6);
        vm.stopPrank();
    }

    function _open() internal returns (uint256 loanId) {
        vault.mint(borrower, COLL);
        vm.startPrank(borrower);
        vault.approve(address(positionManager), COLL);
        loanId = ace.open(id, COLL, PRINCIPAL, 0, borrower, OpenBounds(0, 0, 0));
        vm.stopPrank();
    }

    /// @dev Drives the WHOLE persistence window below the band level, which is the only thing the band gate accepts.
    /// @dev Two buckets past the window, so the healthy deploy anchor has aged out of every read.
    function _walkIntoBand() internal {
        for (uint256 i = 0; i < PocDeployConfig.PERSISTENCE_WINDOW / OBS_INTERVAL + 2; i++) {
            _warpBy(OBS_INTERVAL);
            rec.observe(PS_BAND, 1e18);
        }
    }

    /// @dev The sizing read: the record leg, over this market's own window.
    function _recordLeg() internal view returns (uint256) {
        return rec.minPriceOverWindow(address(usdc), address(vault), PocDeployConfig.PERSISTENCE_WINDOW);
    }

    /// @dev What `Deleverage._owed` charges for `units` at `floorPrice`; ceiled, so the payer never rounds its own way.
    function _owedAt(uint256 units, uint256 floorPrice) internal pure returns (uint256) {
        return FullMath.mulDivRoundingUp(floorPrice, units * (10000 - EPS), 10000 * UNIT_SCALE);
    }
}
