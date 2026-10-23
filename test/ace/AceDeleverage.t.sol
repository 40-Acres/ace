// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.36;

import {Test, stdError} from "forge-std/Test.sol";
import {WarpClock} from "../utils/WarpClock.sol";
import {Vm} from "forge-std/Vm.sol";
import {Ace} from "../../src/ace/hub/Ace.sol";
import {MarketParams, OpenBounds} from "../../src/ace/hub/Types.sol";
import {DeleverageDisabled, Distressed, LoanClosed, NotInBand} from "../../src/ace/hub/Deleverage.sol";
import {BelowCallerFloor} from "../../src/ace/hub/Ace.sol";
import {GUARD_TRIP} from "../utils/GuardTrip.sol";
import {PositionManager} from "../../src/ace/positions/PositionManager.sol";
import {FullMath} from "@uniswap/v4-core/src/libraries/FullMath.sol";
import {AceLens} from "../../src/ace/lens/AceLens.sol";
import {OracleRecord} from "../../src/oracle/OracleRecord.sol";
import {PersistenceRecord} from "../utils/PersistenceRecord.sol";
import {MockAggregatorV3} from "../mocks/MockAggregatorV3.sol";
import {MockERC20} from "../mocks/MockERC20.sol";
import {MockPersistenceRecord} from "../mocks/MockPersistenceRecord.sol";
import {MockDeleverageKeeper} from "../mocks/MockDeleverageKeeper.sol";
import {MockStakeVault} from "../mocks/MockStakeVault.sol";
import {PocDeployConfig} from "../../src/config/Defaults.sol";
import {AceFixtures} from "../utils/AceFixtures.sol";
import {AceReader} from "../utils/AceReader.sol";

/// @notice The per-leg claim door alone: `abi.encodeCall(Ace.claimOwed, ...)` is ambiguous once the name is overloaded.
/// @dev Typed rather than `encodeWithSignature`, so a re-signature breaks the BUILD instead of an assertion.
interface IClaimOwedPerLeg {
    function claimOwed(uint256 loanId, address toUnits, address toQuote) external returns (uint256, uint256);
}

/// @notice A keeper that also reaches the caller-floor overload, which `MockDeleverageKeeper` does not wrap.
contract FloorKeeper is MockDeleverageKeeper {
    constructor(Ace a, address q, address c, uint256 s) MockDeleverageKeeper(a, q, c, s) {}

    function crankDeleverageWithFloor(uint256 id, uint256 minStableOut) external returns (uint256, uint256) {
        return ACE.deleverage(id, minStableOut, "");
    }
}

/// @notice A keeper that re-enters the hub from inside the disposal hand-off.
/// @dev The hand-off is the ONE untrusted hop, and the loan is mid-write: collateral debited, debt not yet melted.
/// @dev Each mode is a different door back in.
contract ReentrantKeeper is MockDeleverageKeeper {
    enum Mode {
        None,
        Deleverage,
        Refinance,
        Repay,
        WithdrawCollateral
    }

    Mode public mode;
    uint256 public target;

    constructor(Ace a, address q, address c, uint256 s) MockDeleverageKeeper(a, q, c, s) {}

    function arm(Mode m, uint256 id) external {
        (mode, target) = (m, id);
    }

    /// @dev Pays nothing: every armed mode is expected to revert the whole crank.
    /// @dev A payment leg here would give a broken guard a second way to fail and blur which one fired.
    function onAceDeleverage(uint256, uint256, bytes calldata) external override {
        if (mode == Mode.Deleverage) ACE.deleverage(target, 0, "");
        else if (mode == Mode.Refinance) ACE.refinance(target, 1, 0, OpenBounds(0, 0, 0));
        else if (mode == Mode.Repay) ACE.repay(target, 1);
        else if (mode == Mode.WithdrawCollateral) ACE.withdrawCollateral(target, 1, address(this));
    }
}

/// @notice A keeper that reads the loan back through the lens door WHILE it holds the released units.
contract MidFlightProbeKeeper is MockDeleverageKeeper {
    AceReader public immutable READ;
    uint256 public target;
    uint256 public midDebt;
    uint256 public midUnits;
    uint256 public midCollateralHeld;

    constructor(Ace a, AceReader r, address q, address c, uint256 s) MockDeleverageKeeper(a, q, c, s) {
        READ = r;
    }

    function arm(uint256 id) external {
        target = id;
    }

    function onAceDeleverage(uint256 unitsSold, uint256 quoteOwed, bytes calldata) external override {
        lastUnitsSold = unitsSold;
        lastQuoteOwed = quoteOwed;
        midDebt = READ.debtOf(target);
        midUnits = READ.loan(target).collateralUnits;
        midCollateralHeld = COLLATERAL.balanceOf(address(this));
        MockERC20(QUOTE).mint(address(this), quoteOwed);
        MockERC20(QUOTE).approve(msg.sender, quoteOwed);
    }
}

/// @title AceDeleverageTest
/// @notice The decline channel: band entry proven by the record, closed-form restore-to-target sizing, all proceeds melting debt.
/// @notice Pins the doctrine inequality, the class-blind fill floor, the no-ratchet seam, and the self-extinguishing band.
contract AceDeleverageTest is WarpClock {
    Ace internal ace;
    PositionManager internal positionManager;
    AceReader internal read;
    MockERC20 internal usdc;
    MockStakeVault internal vault;
    MockPersistenceRecord internal record;
    MockDeleverageKeeper internal keeper;
    bytes32 internal id;

    address internal alice = address(0xA11CE);
    address internal borrower = address(0xB0B);

    uint256 internal constant COLL = 10_000e18;
    uint256 internal constant PRINCIPAL = 4_500e6;
    uint256 internal constant P_WAD = 2e18; // the HUMAN healthy price, for the 8-decimal feed
    uint256 internal constant PS_BAND_WAD = 0.7e18; // the HUMAN price the band sits at, for the 8-decimal feed
    uint256 internal constant UNIT_SCALE = 1 << 96; // every market's scale under the atom frame
    uint256 internal constant EPS = 100;
    uint256 internal constant BAND_BPS = 3000; // channel opens below 30% margin
    uint256 internal constant TARGET_BPS = 4000; // and restores to 40%
    uint256 internal constant RESERVE_PRINCIPAL = 6_000e6; // a par-tick draw large enough that the claims cost most of the position
    uint256 internal T; // this pair's par tick, assigned in setUp
    uint256 internal P; // healthy market price, $2.00 per token, framed in setUp
    uint256 internal PS_BAND; // ~10% margin over the 0.63 trigger: inside the band
    uint256 internal RESERVE_PS; // in band over that draw's 0.84 trigger, and clear of the 1 bps stop

    function setUp() public {
        usdc = new MockERC20("USD Coin", "USDC", 6);
        vault = new MockStakeVault(42);
        record = new MockPersistenceRecord(address(usdc), address(vault));
        T = AceFixtures.priceAt(address(usdc), address(vault), 0);
        P = AceFixtures.px(P_WAD, address(usdc), address(vault));
        PS_BAND = AceFixtures.px(PS_BAND_WAD, address(usdc), address(vault));
        RESERVE_PS = AceFixtures.px(0.85e18, address(usdc), address(vault));
        record.setMinPrice(P);

        AceFixtures.Deployment memory d = AceFixtures.deploy(_params());
        (ace, positionManager, read, id) = (d.ace, d.positionManager, d.read, d.id);
        keeper = new MockDeleverageKeeper(ace, address(usdc), address(vault), UNIT_SCALE);

        usdc.mint(alice, 15_000e6);
        vm.startPrank(alice);
        usdc.approve(address(ace), 15_000e6);
        ace.deposit(id, 15_000e6);
        vm.stopPrank();
    }

    function _params() internal view returns (MarketParams memory p) {
        p = AceFixtures.marketParams(address(usdc), address(vault));
        p.record = address(record);
        p.deleverageFloorEpsBps = EPS;
        p.deleverageBandBps = BAND_BPS;
        p.deleverageTargetBps = TARGET_BPS;
        p.deleverageStopBps = 1; // tiny: keeps this suite's near-trigger fixtures admitted; cut stays 0
    }

    function _open() internal returns (uint256 loanId) {
        vault.mint(borrower, COLL);
        vm.startPrank(borrower);
        vault.approve(address(positionManager), COLL);
        loanId = ace.open(id, COLL, PRINCIPAL, 0, borrower, OpenBounds(0, 0, 0));
        vm.stopPrank();
    }

    /// @dev Put the record in the band at `ps`: below-ness holds at the band level but NOT at the trigger.
    /// @dev Band mode sits 1% under the given level, and `ps` is both the sizing read and the disposal floor.
    function _enterBand(uint256 loanId, uint256 ps) internal {
        uint256 trig = read.triggerPrice(loanId);
        uint256 bandLevel = FullMath.mulDivRoundingUp(trig, 1e18, 1e18 - BAND_BPS * 1e14);
        record.setBelowBand(bandLevel);
        record.setMinPrice(ps);
    }

    // ============ the qualification rule ============

    /// @dev Invariant 1, the doctrine inequality: every completed deleverage strictly lowers the trigger.
    /// @dev Fuzzed across the band's price range and loan sizes.
    function test_Deleverage_TrigLoweringInequality_Holds(uint256 psSeed, uint256 principalSeed) public {
        // ceiling: the tick-0 funding floor refuses any draw whose trigger lands above 1e18
        uint256 principal = bound(principalSeed, 1_000e6, 6_000e6);
        vault.mint(borrower, COLL);
        vm.startPrank(borrower);
        vault.approve(address(positionManager), COLL);
        uint256 loanId = ace.open(id, COLL, principal, 0, borrower, OpenBounds(0, 0, 0));
        vm.stopPrank();

        uint256 trig = read.triggerPrice(loanId);
        // anywhere from just above the trigger to just inside the band
        uint256 ps = bound(psSeed, trig + trig / 100, (trig * 1e18) / (1e18 - BAND_BPS * 1e14) - 1);
        _enterBand(loanId, ps);

        (uint256 sold,) = keeper.crankDeleverage(loanId);

        if (sold > 0 && read.loan(loanId).closedAt == 0) {
            assertLt(read.triggerPrice(loanId), trig, "a completed deleverage strictly lowers the trigger");
        }
    }

    /// @dev Non-vacuity of the pass-through ruling, at a price barely above the trigger.
    /// @dev A waterfall taking 25% protocol and 5% lender retires too little per unit and RAISES the trigger.
    /// @dev The pass-through channel lowers it at that same price, which is why proceeds pass through.
    function test_Deleverage_AWaterfallWouldRaiseTheTrigger_WhichIsWhyProceedsPassThrough() public {
        uint256 loanId = _open();
        uint256 trig = read.triggerPrice(loanId);
        uint256 ps = trig + trig / 200; // rho = 1.005, under the shipped waterfall's rho* of 1.0126
        _enterBand(loanId, ps);
        uint256 debt0 = read.debtOf(loanId);

        (uint256 sold, uint256 out) = keeper.crankDeleverage(loanId);
        assertGt(sold, 0, "the pass-through channel still works here");
        assertLt(read.triggerPrice(loanId), trig, "and lowers the trigger");
        assertEq(debt0 - read.debtOf(loanId), out, "because every unit of proceeds melted debt");

        // the same sale under a waterfall: melt = out * 0.75 * 0.95, trigger rises
        uint256 meltCarved = (out * 7500 * 9500) / 1e8;
        uint256 trigCarved = FullMath.mulDivRoundingUp(PocK() * (debt0 - meltCarved), UNIT_SCALE, (COLL - sold) * 1e18);
        assertGt(trigCarved, trig, "a carved waterfall would have raised it: dumping, not deleveraging");
    }

    function PocK() internal view returns (uint256) {
        return ace.idToMarketParams(id).minCoverageWad;
    }

    /// @dev Invariant 3: the sale restores the target margin, so one crank exits the band.
    /// @dev Fill-floor overshoot only ever helps.
    function test_Deleverage_RestoresTheTargetMargin() public {
        uint256 loanId = _open();
        _enterBand(loanId, PS_BAND);

        (uint256 sold,) = keeper.crankDeleverage(loanId);
        assertGt(sold, 0, "the crank ran");

        uint256 tStar = (PS_BAND * (1e18 - TARGET_BPS * 1e14)) / 1e18;
        assertLe(read.triggerPrice(loanId), tStar + 1, "the trigger landed at or better than target");
    }

    /// @dev Even against a record that never stops asserting below-ness, the second crank is a no-op.
    /// @dev Sizing and trigger are one inequality, so the channel self-extinguishes at target.
    function test_Deleverage_SecondCrank_SelfExtinguishes() public {
        uint256 loanId = _open();
        _enterBand(loanId, PS_BAND);
        keeper.crankDeleverage(loanId);

        uint256 trig = read.triggerPrice(loanId);
        uint256 bandLevel = FullMath.mulDivRoundingUp(trig, 1e18, 1e18 - BAND_BPS * 1e14);
        assertLt(bandLevel, PS_BAND, "deleveraging lowered the band level below the market price");
        vm.expectRevert(NotInBand.selector);
        keeper.crankDeleverage(loanId); // the honest record refuses: the loan left the band
    }

    // ============ gates ============

    function test_Deleverage_BandZero_Disabled() public {
        MarketParams memory p = _params();
        p.deleverageBandBps = 0;
        p.deleverageTargetBps = 0;
        p.deleverageStopBps = 0; // channel off: the lie-guard requires every dial cleared too
        p.deleverageFloorEpsBps = 0;
        AceFixtures.Deployment memory d = AceFixtures.deploy(p);
        MockDeleverageKeeper k = new MockDeleverageKeeper(d.ace, address(usdc), address(vault), UNIT_SCALE);

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

        vm.expectRevert(DeleverageDisabled.selector);
        k.crankDeleverage(loanId);
    }

    function test_Deleverage_RefusedInDistress() public {
        uint256 loanId = _open();
        record.setBelow(true); // persisted below EVERYTHING, the trigger included

        vm.expectRevert(Distressed.selector);
        keeper.crankDeleverage(loanId); // the settlement machine owns a distressed loan
    }

    function test_Deleverage_HealthyLoan_NotInBand() public {
        uint256 loanId = _open(); // record sits at P, margin ~68%

        vm.expectRevert(NotInBand.selector);
        keeper.crankDeleverage(loanId);
    }

    /// @dev Invariant 6: a silent or non-spanning record proves nothing, so the channel is inert.
    function test_Deleverage_SilentRecord_ChannelIsInert() public {
        uint256 loanId = _open();
        // flag mode, below = false: the record cannot prove the band was entered
        record.setBelow(false);
        record.setMinPrice(PS_BAND);

        vm.expectRevert(NotInBand.selector);
        keeper.crankDeleverage(loanId);
    }

    function test_Deleverage_RecoveryDissolvesEligibility() public {
        uint256 loanId = _open();
        _enterBand(loanId, PS_BAND);
        record.setBelowBand(0); // recovery: below-ness no longer provable
        record.setBelow(false);

        vm.expectRevert(NotInBand.selector);
        keeper.crankDeleverage(loanId);
    }

    /// @dev A stale-HIGH record refuses by arithmetic: sizing at the stale price finds the loan above target and sells nothing.
    /// @dev Better that than selling cheap against a floor the market cannot meet.
    function test_Deleverage_StaleHighFloor_SizesZeroRatherThanSellingCheap() public {
        uint256 loanId = _open();
        uint256 trig = read.triggerPrice(loanId);
        uint256 bandLevel = FullMath.mulDivRoundingUp(trig, 1e18, 1e18 - BAND_BPS * 1e14);
        record.setBelowBand(bandLevel); // the band test passes...
        record.setMinPrice(P); // ...but the sizing read still carries the stale healthy price

        (uint256 sold, uint256 out) = keeper.crankDeleverage(loanId);
        assertEq(sold, 0, "sized zero");
        assertEq(out, 0, "and booked nothing");
        assertEq(read.loan(loanId).collateralUnits, COLL, "the loan is untouched");
    }

    // ============ the fill floor, class-blind ============

    /// @dev Invariant 2 / D5: the decline trigger buys no exemption from the floor.
    function test_Deleverage_CrashStall_TheNewTriggerBuysNoExemptionFromTheFloor() public {
        uint256 loanId = _open();
        _enterBand(loanId, PS_BAND);
        keeper.setShortfall(1); // one wei under the floor

        vm.expectRevert(stdError.arithmeticError);
        keeper.crankDeleverage(loanId);

        assertEq(read.loan(loanId).collateralUnits, COLL, "nothing moved through the refusal");
        keeper.setShortfall(0);
        (uint256 sold,) = keeper.crankDeleverage(loanId);
        assertGt(sold, 0, "and the same crank clears unshorted");
    }

    /// @dev D5 on an ORACLE-class market: same refusal, same code, no class branch.
    function test_Deleverage_OracleClass_NoFloorExemption() public {
        (Ace hub, PositionManager esc,, uint256 loanId, MockAggregatorV3 feed) = _oracleMarket();
        esc; // silence
        MockDeleverageKeeper k = new MockDeleverageKeeper(hub, address(usdc), address(vault), UNIT_SCALE);
        feed.push(int256((PS_BAND_WAD * 1e8) / 1e18)); // the crash, tracked immediately by the class

        k.setShortfall(1);
        vm.expectRevert(stdError.arithmeticError);
        k.crankDeleverage(loanId);

        k.setShortfall(0);
        (uint256 sold,) = k.crankDeleverage(loanId);
        assertGt(sold, 0, "the ORACLE-class deleverage clears at the oracle floor, never under it");
    }

    /// @dev E5 pinned: a degraded feed produces inaction on the decline path, never action.
    function test_Deleverage_DegradedFeed_FailsTowardInaction() public {
        (Ace hub,,, uint256 loanId, MockAggregatorV3 feed) = _oracleMarket();
        MockDeleverageKeeper k = new MockDeleverageKeeper(hub, address(usdc), address(vault), UNIT_SCALE);
        feed.push(int256((PS_BAND_WAD * 1e8) / 1e18));
        _warpBy(2 hours); // past MAX_STALENESS: the feed is unfit

        vm.expectRevert(NotInBand.selector);
        k.crankDeleverage(loanId);
    }

    // ============ the venue class keeps its grading ============

    /// @dev C1's consequence, pinned on the REAL record: one low print cannot fire the band, but the whole window below it can.
    /// @dev This test fails on any fast-down band operator.
    function test_Deleverage_VenueClass_BandIsPersistenceGraded_OneLowPrintDoesNotFire() public {
        // 271 buckets x 60s spans the settle window, which is what the genesis span rail demands
        PersistenceRecord real = new PersistenceRecord(
            PersistenceRecord.Config({
                writer: address(this),
                truncCapBps: 10000,
                initialPrice: P,
                obsInterval: 60,
                volRefFloor: 1,
                obsCap: 271,
                unitScale: UNIT_SCALE,
                volRefBps: 10000,
                depthWindow: 0,
                quote: address(usdc),
                collateral: address(vault),
                persistenceWindow: PocDeployConfig.PERSISTENCE_WINDOW,
                pendingWindow: PocDeployConfig.PENDING_WINDOW
            })
        );
        MarketParams memory p = _params();
        p.record = address(real);
        _warpBy(PocDeployPersistence() + 1); // age the ring past W so it spans
        real.observe(P, 1e18); // and print, or the draw below refuses: a silent record answers no price
        AceFixtures.Deployment memory d = AceFixtures.deploy(p);
        MockDeleverageKeeper k = new MockDeleverageKeeper(d.ace, address(usdc), address(vault), UNIT_SCALE);

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

        real.observe(PS_BAND, 1e18); // ONE low print
        vm.expectRevert(NotInBand.selector);
        k.crankDeleverage(loanId); // the anchor above the band level breaks below-ness

        // the decline HOLDS across the whole window: one bucket per minute, then the band is proven
        for (uint256 i = 0; i < PocDeployPersistence() / 60 + 2; i++) {
            _warpBy(60);
            real.observe(PS_BAND, 1e18);
        }
        (uint256 sold,) = k.crankDeleverage(loanId);
        assertGt(sold, 0, "persistent decline deleverages; a print never does");
    }

    /// @dev The window lives on the RECORD now, and this suite's records are all built at the shipped one.
    function PocDeployPersistence() internal pure returns (uint256) {
        return PocDeployConfig.PERSISTENCE_WINDOW;
    }

    // ============ partial fills and the no-ratchet seam ============

    function test_Deleverage_PartialFill_Telescopes() public {
        uint256 loanId = _open();
        _enterBand(loanId, PS_BAND);

        keeper.setRefundBps(5000);
        (uint256 firstLeg,) = keeper.crankDeleverage(loanId);
        uint256 oneShot = keeper.lastUnitsSold();
        keeper.setRefundBps(0);
        _enterBand(loanId, PS_BAND); // the band level moved with the melt; re-arm at the same price
        (uint256 secondLeg,) = keeper.crankDeleverage(loanId);

        assertGt(secondLeg, 0, "the tail is still sellable");
        assertLe(firstLeg + secondLeg, oneShot + 1, "two partials never sell more than one full crank");
    }

    /// @dev A wholly refused fill is an exact no-op on every ledger the channel touches.
    function test_Deleverage_WhollyRefused_IsAnExactNoOp() public {
        uint256 loanId = _open();
        _enterBand(loanId, PS_BAND);
        keeper.setRefundBps(10000);
        uint256 debt0 = read.debtOf(loanId);

        (uint256 filled, uint256 out) = keeper.crankDeleverage(loanId);

        assertEq(filled, 0, "nothing sold");
        assertEq(out, 0, "nothing booked");
        assertEq(read.debtOf(loanId), debt0, "no debt melted");
        assertEq(read.loan(loanId).collateralUnits, COLL, "the position is whole");
    }

    // ============ the waterfall ============

    /// @dev Invariant 7: no protocol fee, no lender share, no borrower payout, so the whole disposal melts debt.
    /// @dev The keeper's take is eps alone.
    function test_Deleverage_NoProtocolFee_NoLenderShare_NoBorrowerPayout() public {
        uint256 loanId = _open();
        _enterBand(loanId, PS_BAND);
        keeper.setRoutePrice(PS_BAND); // routes exactly at the sizing price
        uint256 revenue0 = read.protocolRevenue(id);
        uint256 borrower0 = usdc.balanceOf(borrower);
        uint256 debt0 = read.debtOf(loanId);

        (uint256 sold, uint256 out) = keeper.crankDeleverage(loanId);

        assertGt(sold, 0, "the crank ran");
        assertEq(read.protocolRevenue(id), revenue0, "no protocol cut on the decline channel");
        assertEq(usdc.balanceOf(borrower), borrower0, "no borrower payout below full repayment");
        assertEq(debt0 - read.debtOf(loanId), out, "every unit of proceeds melted debt");
        uint256 realized = (sold * PS_BAND) / UNIT_SCALE;
        assertEq(usdc.balanceOf(address(keeper)), realized - out, "the keeper kept eps and nothing else");
    }

    /// @dev The handles one clamp-arm row needs: its own hub, lens, reader and keeper, plus the market and the loan.
    struct Clamp {
        Ace hub;
        AceLens lens;
        AceReader r;
        MockDeleverageKeeper k;
        bytes32 mid;
        uint256 loanId;
    }

    /// @dev A market bidding at `price`, a loan opened against the whole position, and the record parked in band at `ps`.
    /// @dev The keeper sliver is zeroed, so the sale's reserve is `collateralNeeded` alone and can be READ from the shipped lens.
    /// @dev The sliver term is pinned in `AceDeleverageCoverageErosion` off settlement's own credit, not restated here.
    /// @dev The arm is selected by the MARKET'S PRICE, which is the loan's funding floor: it used to be a tick to fund at.
    function _clampFixture(uint256 price, uint256 principal, uint256 ps) private returns (Clamp memory c) {
        MarketParams memory p = _params();
        p.settleBountyBps = 0;
        p.price = price;
        AceFixtures.Deployment memory d = AceFixtures.deploy(p);
        (c.hub, c.mid) = (d.ace, d.id);
        c.lens = new AceLens(address(d.ace));
        c.r = AceReader(_readerFor(d.ace));
        c.k = new MockDeleverageKeeper(d.ace, address(usdc), address(vault), UNIT_SCALE);
        usdc.mint(alice, 15_000e6);
        vm.startPrank(alice);
        usdc.approve(address(d.ace), 15_000e6);
        record.setMinPrice(2 * P); // raised BEFORE the deposit: the gate refuses lending above the price
        d.ace.deposit(c.mid, 15_000e6);
        vm.stopPrank();
        vault.mint(borrower, COLL);
        vm.startPrank(borrower);
        vault.approve(address(d.positionManager), COLL);
        c.loanId = d.ace.open(c.mid, COLL, principal, 0, borrower, OpenBounds(0, 0, 0));
        vm.stopPrank();
        uint256 trig = c.r.triggerPrice(c.loanId);
        record.setBelowBand(FullMath.mulDivRoundingUp(trig, 1e18, 1e18 - BAND_BPS * 1e14));
        record.setMinPrice(ps);
    }

    /// @dev `Borrower.requiredAt` at the loan's frozen funding floor: the cap leg, and the ONLY leg with no lens surface to read.
    function _requiredAt(Clamp memory c) private view returns (uint256) {
        uint256 k = c.hub.idToMarketParams(c.mid).minCoverageWad;
        return FullMath.mulDivRoundingUp(k * c.r.debtOf(c.loanId), UNIT_SCALE, c.r.fundingFloor(c.mid, c.loanId) * 1e18);
    }

    /// @dev `securedBase` clamps the decline channel to the debt-securing portion, less what settlement must keep.
    /// @dev The base is read off the FROZEN funding floor, so a keeper cannot crash the print to widen it.
    /// @dev THIS ROW IS THE CAP ARM: a high funding floor makes bare `requiredAt` the smaller of the two legs.
    /// @dev The arm is ASSERTED, not left to the fixture, so the row cannot drift onto the other one in silence.
    function test_Deleverage_SizingClampedToSecuredBase() public {
        // fund only a HIGH tick so the funding floor is high and the debt-securing portion is small
        Clamp memory c = _clampFixture(AceFixtures.priceAt(address(usdc), address(vault), 9600), PRINCIPAL, PS_BAND); // ~2.61 quote per token
        uint256 units = c.r.loan(c.loanId).collateralUnits;
        uint256 keep = c.lens.collateralNeeded(c.mid, c.loanId);
        uint256 req = _requiredAt(c);
        assertLt(req, units - keep, "fixture: this row means to sit on the cap arm, so the reserve must be the larger leg");

        (uint256 sold,) = c.k.crankDeleverage(c.loanId);

        assertEq(sold, req, "the sale is clamped to the debt-securing portion");
        assertGt(c.r.loan(c.loanId).collateralUnits, keep, "the reserve is not what bound this sale");
    }

    /// @dev The OTHER arm of the same clamp: a flat tick-0 ladder makes the claims cost most of the position.
    /// @dev The reserve is then the smaller leg, so the sale stops at what settlement must keep and not at `requiredAt`.
    /// @dev The pair exists because `securedBase` is a MIN, and a row on one arm asserts nothing whatever about the other.
    /// @dev The reserve is read from the LENS, so unlike a copied formula it cannot go stale against a hub edited elsewhere.
    function test_Deleverage_SizingClampedToTheSettlementReserve() public {
        Clamp memory c = _clampFixture(T, RESERVE_PRINCIPAL, RESERVE_PS);
        uint256 units = c.r.loan(c.loanId).collateralUnits;
        uint256 keep = c.lens.collateralNeeded(c.mid, c.loanId);
        assertGt(_requiredAt(c), units - keep, "fixture: this row means to sit on the reserve arm, so the cap must be the larger leg");

        (uint256 sold,) = c.k.crankDeleverage(c.loanId);

        assertEq(sold, units - keep, "the sale is clamped to what settlement must keep");
        assertEq(c.r.loan(c.loanId).collateralUnits, keep, "the position is left holding exactly the settlement reserve");
    }

    // ============ genesis rails ============

    function test_Genesis_DeleverageRails() public {
        Ace hub = AceFixtures.newAce();

        MarketParams memory p = _params();
        p.deleverageBandBps = 2999; // one bps under the floor: the band may not open this late
        vm.expectRevert("deleverage band out of band");
        hub.createMarket(p);

        p.deleverageBandBps = BAND_BPS;
        p.deleverageTargetBps = BAND_BPS; // no hysteresis
        vm.expectRevert("deleverage target below band");
        hub.createMarket(p);

        p.deleverageTargetBps = 10000; // a full-margin target is a forced full sale
        vm.expectRevert("deleverage target too high");
        hub.createMarket(p);

        p.deleverageTargetBps = TARGET_BPS;
        p.record = address(0);
        vm.expectRevert("record required");
        hub.createMarket(p);
    }

    /// @dev The floor's other side, so the row above pins a BOUNDARY rather than a range.
    function test_Genesis_DeleverageBandFloor_AdmitsTheFloorItself() public {
        Ace hub = AceFixtures.newAce();

        MarketParams memory p = _params();
        p.deleverageBandBps = 3000;
        bytes32 mid = hub.createMarket(p);

        assertEq(hub.idToMarketParams(mid).deleverageBandBps, 3000, "the floor itself is admitted");
    }

    // ============ gates the entry point never had a test for ============

    /// @dev A settled loan is out of reach: `deleverage` reads `L.collateralUnits` and `L.debt`, which `closeClean` zeroes.
    /// @dev Without the gate the channel would size against a corpse.
    function test_Deleverage_ClosedLoan_Refused() public {
        uint256 loanId = _open();
        uint256 debt = read.debtOf(loanId);
        usdc.mint(borrower, debt);
        vm.startPrank(borrower);
        usdc.approve(address(ace), debt);
        ace.repay(loanId, debt);
        vm.stopPrank();
        assertTrue(read.loan(loanId).closedAt != 0, "precondition: the loan is settled");

        vm.expectRevert(LoanClosed.selector);
        keeper.crankDeleverage(loanId);
    }

    /// @dev The caller-floor overload: an unreachable floor refuses the crank whole, and nothing is half-applied.
    function test_Deleverage_CallerFloor_UnreachableFloor_RefusesTheWholeCrank() public {
        FloorKeeper k = new FloorKeeper(ace, address(usdc), address(vault), UNIT_SCALE);
        uint256 loanId = _open();
        _enterBand(loanId, PS_BAND);
        uint256 debt0 = read.debtOf(loanId);

        vm.expectRevert(BelowCallerFloor.selector);
        k.crankDeleverageWithFloor(loanId, type(uint256).max);

        assertEq(read.loan(loanId).collateralUnits, COLL, "the position is whole through the refusal");
        assertEq(read.debtOf(loanId), debt0, "and no debt melted");
    }

    /// @dev The floor binds INCLUSIVELY (`s < minStableOut`), and it binds on a no-op too.
    /// @dev A wholly refused fill books zero, which a keeper asking for one unit must be told rather than handed as success.
    function test_Deleverage_CallerFloor_BindsOnAWhollyRefusedFill_ButZeroClears() public {
        FloorKeeper k = new FloorKeeper(ace, address(usdc), address(vault), UNIT_SCALE);
        uint256 loanId = _open();
        _enterBand(loanId, PS_BAND);
        k.setRefundBps(10000); // the route refuses everything

        vm.expectRevert(BelowCallerFloor.selector);
        k.crankDeleverageWithFloor(loanId, 1);

        (uint256 sold, uint256 out) = k.crankDeleverageWithFloor(loanId, 0);
        assertEq(sold, 0, "the same crank at a zero floor is a clean no-op");
        assertEq(out, 0, "equality clears the floor: 0 < 0 is false");
    }

    /// @dev The event must carry what FILLED, not what was released, and the melt it actually caused.
    /// @dev Run against a partial fill so the two numbers differ and a released-units event would fail.
    function test_Deleverage_EmitsDeleveraged_WithTheFilledNumbers() public {
        uint256 loanId = _open();
        _enterBand(loanId, PS_BAND);
        keeper.setRefundBps(5000);
        uint256 debt0 = read.debtOf(loanId);

        vm.recordLogs();
        (uint256 sold, uint256 out) = keeper.crankDeleverage(loanId);
        Vm.Log[] memory logs = vm.getRecordedLogs();

        assertLt(sold, keeper.lastUnitsSold(), "fixture: released more than filled, so the two differ");
        bytes32 sig = keccak256("Deleveraged(uint256,uint256,uint256,uint256,address)");
        bool seen;
        for (uint256 i; i < logs.length; i++) {
            if (logs[i].emitter != address(ace) || logs[i].topics[0] != sig) continue;
            seen = true;
            assertEq(uint256(logs[i].topics[1]), loanId, "the event names the loan");
            (uint256 u, uint256 o, uint256 paid) = abi.decode(logs[i].data, (uint256, uint256, uint256));
            assertEq(u, sold, "unitsSold is the FILLED amount");
            assertEq(o, out, "stableOut is what was pulled");
            assertEq(paid, debt0 - read.debtOf(loanId), "debtPaid is the measured melt");
        }
        assertTrue(seen, "the hub emitted Deleveraged");
    }

    // ============ the untrusted hop: reentrancy from inside the callback ============

    /// @dev The same channel, re-entered: the hub holds ONE transient slot, so this must refuse on the guard, not on `NotInBand`.
    /// @dev A second sizing pass would read a debited-but-unmelted loan and size against a momentarily far-too-high trigger.
    function test_Deleverage_ReentrantDeleverage_FromTheCallback_Refused() public {
        (ReentrantKeeper k, uint256 loanId) = _armedReentrantKeeper();
        k.arm(ReentrantKeeper.Mode.Deleverage, loanId);
        vm.expectRevert(GUARD_TRIP);
        k.crankDeleverage(loanId);
    }

    /// @dev A DIFFERENT verb, re-entered: the guard slot covers a nested CROSS-VERB call.
    /// @dev A refinance mid-disposal would retire the very loan the crank is part-way through writing.
    function test_Deleverage_ReentrantRefinance_FromTheCallback_Refused() public {
        (ReentrantKeeper k, uint256 loanId) = _armedReentrantKeeper();
        k.arm(ReentrantKeeper.Mode.Refinance, loanId);
        vm.expectRevert(GUARD_TRIP);
        k.crankDeleverage(loanId);
    }

    /// @dev The borrower's own cure, re-entered by the keeper.
    /// @dev A repay landing between the collateral debit and the melt would melt claims the disposal is about to melt again.
    function test_Deleverage_ReentrantRepay_FromTheCallback_Refused() public {
        (ReentrantKeeper k, uint256 loanId) = _armedReentrantKeeper();
        usdc.mint(address(k), 1e6);
        vm.prank(address(k));
        usdc.approve(address(ace), 1e6);
        k.arm(ReentrantKeeper.Mode.Repay, loanId);
        vm.expectRevert(GUARD_TRIP);
        k.crankDeleverage(loanId);
    }

    /// @dev Collateral withdrawal, re-entered: the guard must fire BEFORE the `NotBorrower` check.
    /// @dev Otherwise the refusal would depend on who the keeper is rather than on when it called.
    function test_Deleverage_ReentrantWithdrawCollateral_FromTheCallback_Refused() public {
        (ReentrantKeeper k, uint256 loanId) = _armedReentrantKeeper();
        k.arm(ReentrantKeeper.Mode.WithdrawCollateral, loanId);
        vm.expectRevert(GUARD_TRIP);
        k.crankDeleverage(loanId);
    }

    /// @dev CEI seen from the far side of the hand-off: when the keeper holds the units the collateral debit is ALREADY written.
    /// @dev The melt is not, and that ordering is what makes the reentrancy refusals above load-bearing, not belt-and-braces.
    function test_Deleverage_TheCallbackSeesCollateralDebitedAndDebtUnmelted() public {
        MidFlightProbeKeeper k = new MidFlightProbeKeeper(ace, read, address(usdc), address(vault), UNIT_SCALE);
        uint256 loanId = _open();
        _enterBand(loanId, PS_BAND);
        k.arm(loanId);
        uint256 debt0 = read.debtOf(loanId);

        (uint256 sold, uint256 out) = k.crankDeleverage(loanId);

        assertEq(k.midUnits(), COLL - sold, "the collateral debit is written before the hand-off");
        assertEq(k.midCollateralHeld(), sold, "and the units are really in the keeper's hands");
        assertEq(k.midDebt(), debt0, "while the melt has not happened yet");
        assertEq(read.debtOf(loanId), debt0 - out, "the melt lands only after the fill is measured");
    }

    // ============ crossing another melt path, sequentially ============

    /// @dev A melt on a live loan lowers the trigger and can carry the loan out of the band on its own.
    /// @dev Pinned as a SEQUENCE because it is the realistic interleave: both paths share the loan's debt and its claim ladder.
    /// @dev Neither may leave the other mis-sized -- `meltLoan` reverts `MeltExceedsClaims` if the two disagree on the claim total.
    function test_Deleverage_AfterAClaimMelt_StillRestoresTargetFromTheNewDebt() public {
        uint256 loanId = _open();
        uint256 debt0 = read.debtOf(loanId);

        // melt a slice of the debt first, so the deleverage that follows sizes off the new number
        uint256 slice = debt0 / 4;
        usdc.mint(borrower, slice);
        vm.startPrank(borrower);
        usdc.approve(address(ace), slice);
        ace.repay(loanId, slice);
        vm.stopPrank();
        assertEq(read.debtOf(loanId), debt0 - slice, "precondition: the melt landed");

        uint256 trig = read.triggerPrice(loanId);
        uint256 ps = (trig * 105) / 100; // the band moved DOWN with the melt: re-arm against the new trigger
        _enterBand(loanId, ps);
        (uint256 sold,) = keeper.crankDeleverage(loanId);

        assertGt(sold, 0, "the decline channel sizes off the post-melt debt");
        uint256 tStar = (ps * (1e18 - TARGET_BPS * 1e14)) / 1e18;
        assertLt(read.triggerPrice(loanId), trig, "and still only ever lowers the trigger");
        assertLe(read.triggerPrice(loanId), tStar + 1, "landing at or better than target from the new debt");
    }

    // ============ the claim/debt invariant every melt path shares ============

    /// @notice `totalClaim == debt` on every live loan, EXACTLY. The draw writes claim equal to the take
    /// @notice and the take sums to the principal, so the two seed level; the origination fee lands in
    /// @notice the class index, never in claim. Every melt then debits both by the same amount.
    /// @notice This is WHY the melt's funding-floor delete, which fires at `amount == totalClaim`,
    /// @notice coincides with the clean close, which fires at `debt == 0` -- and that coincidence is what
    /// @notice makes a LIVE loan carrying no funding floor unconstructible.
    /// @dev The three melt paths that can move a live loan's debt are walked in one run, after the draw:
    /// @dev partial repay, a withdrawal-funded repay, and deleverage. A future change that debits debt
    /// @dev without debiting claim reopens the zero-floor state the entry rails exist to close.
    function test_INVARIANT_TotalClaimNeverFallsBelowDebt_AcrossEveryMeltPath() public {
        uint256 loanId = _open();
        assertGt(read.debtOf(loanId), 0, "fixture: the draw funded a real debt, so the invariant has a subject");
        _assertClaimTracksDebt(loanId, "the draw seeds claim level with debt");

        uint256 slice = read.debtOf(loanId) / 4;
        usdc.mint(borrower, slice);
        vm.startPrank(borrower);
        usdc.approve(address(ace), slice);
        ace.repay(loanId, slice);
        vm.stopPrank();
        _assertClaimTracksDebt(loanId, "a partial repay debits claim and debt by the SAME amount");

        // the borrower's own delever: shed collateral, sell it off-chain, repay the proceeds
        uint256 shed = COLL / 20;
        vm.prank(borrower);
        ace.withdrawCollateral(loanId, shed, borrower);
        uint256 proceeds = read.debtOf(loanId) / 8;
        usdc.mint(borrower, proceeds);
        vm.startPrank(borrower);
        usdc.approve(address(ace), proceeds);
        ace.repay(loanId, proceeds);
        vm.stopPrank();
        _assertClaimTracksDebt(loanId, "so does a withdraw-sell-repay round trip");

        _enterBand(loanId, (read.triggerPrice(loanId) * 105) / 100);
        (uint256 melted,) = keeper.crankDeleverage(loanId);
        assertGt(melted, 0, "fixture: the decline channel really sold");
        assertGt(read.debtOf(loanId), 0, "fixture: the loan is still live at the end, not closed out from under us");
        _assertClaimTracksDebt(loanId, "and so does a deleverage");
    }

    /// @notice The THIRD `meltLoan` call site, which the walk above does not reach: a refinance.
    /// @notice A refinance retires the whole old debt in one melt and re-draws the successor from scratch.
    /// @dev Walked separately because the loan does not survive it, so it cannot ride the sequence above.
    /// @dev Both ends are asserted: the retired loan carries no claim, and the successor seeds level again.
    function test_INVARIANT_ClaimTracksDebt_AcrossTheRefinanceMelt() public {
        uint256 loanId = _open();
        _assertClaimTracksDebt(loanId, "fixture: the draw seeds claim level with debt");
        uint256 debt0 = read.debtOf(loanId);
        assertGt(debt0, 0, "fixture: there is a debt for the melt to retire");

        uint64 tenor = ace.idToMarketParams(id).minTenor; // HOISTED: a call in the argument list eats the prank
        vm.prank(borrower);
        uint256 newId = ace.refinance(loanId, debt0 + 100e6, tenor, OpenBounds(0, 0, 0));

        assertTrue(read.loan(loanId).closedAt != 0, "the old loan was retired by the roll");
        _assertClaimTracksDebt(loanId, "and the melt took its claim to zero with its debt");
        assertGt(read.debtOf(newId), 0, "fixture: the successor really drew");
        _assertClaimTracksDebt(newId, "while the successor's fresh draw seeds claim level with debt again");
    }

    /// @dev The loan's live claim, against its debt. WAS a sum over the funded ticks; there is one claim now.
    function _assertClaimTracksDebt(uint256 loanId, string memory why) internal view {
        assertEq(read.claimOf(id, loanId), read.debtOf(loanId), why);
    }

    // ============ the one-price restore, fuzzed ============

    /// @dev ONE read sizes the sale and floors the fill, so the restore lands ON target at every price in the band.
    /// @dev Fuzzed over the whole band rather than over a second leg, which no longer exists.
    function testFuzz_Deleverage_LandsAtTargetAtEveryPriceInTheBand(uint256 psSeed) public {
        uint256 loanId = _open();
        uint256 trig = read.triggerPrice(loanId);
        uint256 ps = bound(psSeed, trig + trig / 100, (trig * 1e18) / (1e18 - BAND_BPS * 1e14) - 1);
        _enterBand(loanId, ps);

        (uint256 sold,) = keeper.crankDeleverage(loanId);
        assertGt(sold, 0, "the sale never vanishes anywhere in the band");

        uint256 tStar = (ps * (1e18 - TARGET_BPS * 1e14)) / 1e18;
        assertLe(read.triggerPrice(loanId), tStar + 1, "at or better than target at every price in the band");
    }

    // ============ helpers ============

    /// @dev A banded loan plus a keeper that re-enters from the callback.
    function _armedReentrantKeeper() internal returns (ReentrantKeeper k, uint256 loanId) {
        k = new ReentrantKeeper(ace, address(usdc), address(vault), UNIT_SCALE);
        loanId = _open();
        _enterBand(loanId, PS_BAND);
    }

    /// @dev An ORACLE-class market with the deleverage channel on: feed at P, staleness 1h.
    function _oracleMarket() internal returns (Ace hub, PositionManager esc, bytes32 mid, uint256 loanId, MockAggregatorV3 feed) {
        _warpBy(365 days);
        feed = new MockAggregatorV3(8);
        feed.push(int256((P_WAD * 1e8) / 1e18));
        OracleRecord orec = new OracleRecord(address(feed), address(usdc), address(vault), 1 hours);
        MarketParams memory p = _params();
        p.record = address(orec);
        AceFixtures.Deployment memory d = AceFixtures.deploy(p);
        (hub, esc, mid) = (d.ace, d.positionManager, d.id);
        usdc.mint(alice, 15_000e6);
        vm.startPrank(alice);
        usdc.approve(address(hub), 15_000e6);
        hub.deposit(mid, 15_000e6);
        vm.stopPrank();
        vault.mint(borrower, COLL);
        vm.startPrank(borrower);
        vault.approve(address(esc), COLL);
        loanId = hub.open(mid, COLL, PRINCIPAL, 0, borrower, OpenBounds(0, 0, 0));
        vm.stopPrank();
    }

    mapping(address => address) internal _readers;

    function _readerFor(Ace hub) internal returns (address r) {
        r = _readers[address(hub)];
        if (r == address(0)) {
            r = address(new AceReader(address(hub)));
            _readers[address(hub)] = r;
        }
    }
}
