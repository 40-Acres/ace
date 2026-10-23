// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.36;

import {FullMath} from "@uniswap/v4-core/src/libraries/FullMath.sol";
import {WarpClock} from "../utils/WarpClock.sol";
import {Ace} from "../../src/ace/hub/Ace.sol";
import {AceLens} from "../../src/ace/lens/AceLens.sol";
import {MarketParams, OpenBounds} from "../../src/ace/hub/Types.sol";
import {PositionManager} from "../../src/ace/positions/PositionManager.sol";
import {ProtocolPolicy} from "../../src/config/Defaults.sol";
import {IAceDeleverageCallback} from "../../src/interfaces/IAceDeleverageCallback.sol";
import {IPersistenceRecord} from "../../src/interfaces/IPersistenceRecord.sol";
import {Distressed} from "../../src/ace/hub/Deleverage.sol";
import {Deleverage, DeleverageStopped} from "../../src/ace/hub/Deleverage.sol";
import {NoRecordPrice} from "../../src/ace/hub/Borrower.sol";
import {MockERC20} from "../mocks/MockERC20.sol";
import {MockStakeVault} from "../mocks/MockStakeVault.sol";
import {MockPersistenceRecord} from "../mocks/MockPersistenceRecord.sol";
import {MockDeleverageKeeper} from "../mocks/MockDeleverageKeeper.sol";
import {AceFixtures} from "../utils/AceFixtures.sol";
import {AceReader} from "../utils/AceReader.sol";

/// @title AceDeleverageMinDebtCapTest
/// @notice `deleverage` never takes a live loan's debt under `minDebt`, so no third party's crank flips an armed fold from ROLL to SETTLE.
/// @notice At or under `minDebt` the crank sells nothing and returns `(0, 0)`; above it, the sale stops exactly at `minDebt` and takes no cut.
/// @dev The flip it closes: a crank melted debt under the floor, `derivedPrincipal` re-sized the successor AT the floor against the reduced lot,
/// @dev and `tryContinue` refused `TriggerAboveFloor` although the sale left the live loan healthier.
/// @dev Every row runs at the PoC deploy's own dials (band 3000, target 5000, stop 1000, cut 500, k 1.4) unless it says otherwise.
contract AceDeleverageMinDebtCapTest is WarpClock {
    Ace internal ace;
    AceLens internal lens;
    AceReader internal read;
    PositionManager internal pm;
    MockERC20 internal usdc;
    MockStakeVault internal coll;
    MockPersistenceRecord internal record;
    MockDeleverageKeeper internal keeper;
    bytes32 internal id;
    uint256 internal par; // the market's price, and the record's windowed minimum unless a row moves it

    address internal alice = address(0xA11CE);
    address internal borrower = address(0xB0B);
    address internal stranger = address(0x5157);
    uint256 internal constant K = 1.4e18;
    uint256 internal constant S = 1 << 96;
    uint256 internal constant MIN_DEBT = 10e6; // the fixture's admission quantum
    uint256 internal constant BAND = 3000;
    uint256 internal constant STOP = 1000;
    uint256 internal constant TARGET = 5000;
    uint256 internal constant THETA = 8500; // the live trigger as bps of par: 15% margin, inside the band, clear of the stop

    function setUp() public {
        _warpTo(1_000_000);
        usdc = new MockERC20("USD Coin", "USDC", 6);
        coll = new MockStakeVault(42);
        record = new MockPersistenceRecord(address(usdc), address(coll));
        par = AceFixtures.priceAt(address(usdc), address(coll), 0);
        record.setMinPrice(par);
        MarketParams memory p = AceFixtures.marketParams(address(usdc), address(coll));
        p.record = address(record);
        p.deleverageFloorEpsBps = ProtocolPolicy.DELEVERAGE_FLOOR_EPS_BPS;
        p.deleverageBandBps = BAND;
        p.deleverageTargetBps = TARGET;
        p.deleverageStopBps = STOP;
        p.deleverageProtocolBps = 500;
        AceFixtures.Deployment memory d = AceFixtures.deploy(p);
        (ace, pm, read, id) = (d.ace, d.positionManager, d.read, d.id);
        lens = new AceLens(address(ace));
        keeper = new MockDeleverageKeeper(ace, address(usdc), address(coll), S);
        usdc.mint(alice, 100_000e6);
        vm.startPrank(alice);
        usdc.approve(address(ace), type(uint256).max);
        ace.deposit(id, 100_000e6);
        vm.stopPrank();
    }

    /* ============================== helpers ============================== */

    /// @dev A loan of `debt` whose live trigger sits at `thetaBps` of par. Unarmed; the clock stays where the open ran.
    function _open(uint256 debt, uint256 thetaBps) internal returns (uint256 loanId) {
        uint256 units = FullMath.mulDiv(K * debt, S * 10000, thetaBps * par * 1e18);
        coll.mint(borrower, units);
        vm.startPrank(borrower);
        coll.approve(address(pm), units);
        loanId = ace.open(id, units, debt, ProtocolPolicy.MIN_TENOR, borrower, OpenBounds(0, 0, 0));
        vm.stopPrank();
    }

    function _arm(uint256 loanId) internal {
        vm.prank(borrower);
        ace.setAutoRefinance(loanId, ProtocolPolicy.MIN_TENOR, 0, 0);
    }

    function _expiryOf(uint256 loanId) internal view returns (uint256) {
        return uint256(read.loan(loanId).expiry);
    }

    /// @dev The record proves the band and NOT the trigger: persisted below the band level, not below the trigger.
    function _enterBand(uint256 loanId) internal {
        uint256 trig = read.triggerPrice(loanId);
        record.setBelowBand(FullMath.mulDivRoundingUp(trig, 1e18, 1e18 - BAND * 1e14));
    }

    /// @dev The paid fold, cranked by a stranger; true when it ROLLED (one successor minted), false when it settled.
    function _fold(uint256 loanId) internal returns (bool rolled) {
        uint256 n = read.loanCount();
        vm.prank(stranger);
        ace.forceClose(loanId);
        assertGt(read.loan(loanId).closedAt, 0, "the fold closed the loan on either branch");
        rolled = read.loanCount() == n + 1;
    }

    /// @dev What the REAL fold does at `expiry + 1` with nothing done in between, run in a snapshot and rolled back: true when it rolls.
    /// @dev Not `tryContinue(id)`: that view judges the whole lot, while the fold judges the lot less the keeper's sliver.
    function _foldRollsAtExpiry(uint256 loanId) internal returns (bool rolled) {
        uint256 snap = vm.snapshotState();
        _warpTo(_expiryOf(loanId) + 1);
        record.setMinPrice(par);
        rolled = _fold(loanId);
        vm.revertToState(snap);
    }

    /// @dev The borrower's own hand: repay to `left`, then withdraw back to the same trigger, so the loan still sits in the sale region.
    function _repayTo(uint256 loanId, uint256 left) internal {
        uint256 amount = read.debtOf(loanId) - left;
        usdc.mint(borrower, amount);
        vm.startPrank(borrower);
        usdc.approve(address(ace), amount);
        ace.repay(loanId, amount);
        uint256 keep = FullMath.mulDiv(K * left, S * 10000, THETA * par * 1e18);
        ace.withdrawCollateral(loanId, read.loan(loanId).collateralUnits - keep, borrower);
        vm.stopPrank();
    }

    /* ============================== THE PROPERTY ============================== */

    /// @notice A stranger's crank in the last live second no longer flips the armed fold: at every size from `minDebt` to 2x, it ROLLS.
    /// @dev 1.0 / 1.2 / 1.39 used to SETTLE: the melt took debt under `minDebt` and the successor re-sized at it on the reduced lot.
    /// @dev 2.0 is the control that rolled before the cap too. Each row is its own snapshot of the same market.
    function test_NoFlip_ACrankInTheLastLiveSecondLeavesTheArmedFoldRolling() public {
        uint256[4] memory multBps = [uint256(10000), 12000, 13900, 20000];
        for (uint256 i; i < multBps.length; ++i) {
            uint256 snap = vm.snapshotState();
            uint256 debt = MIN_DEBT * multBps[i] / 10000;
            uint256 loanId = _open(debt, THETA);
            _arm(loanId);
            assertTrue(_foldRollsAtExpiry(loanId), "PREMISE: untouched, the armed fold rolls");
            _warpTo(_expiryOf(loanId) - 1);
            _enterBand(loanId);
            (uint256 sold,) = keeper.crankDeleverage(loanId);
            uint256 debtAfter = read.debtOf(loanId);
            _warpTo(_expiryOf(loanId) + 1);
            (bool ok, bytes4 reason,) = ace.tryContinue(loanId);
            assertTrue(ok, string.concat("the continuation is still admissible after the crank; reason ", vm.toString(bytes32(reason))));
            assertTrue(_fold(loanId), "and the fold ROLLS: the crank did not choose the branch");
            assertGe(debtAfter, MIN_DEBT, "because the crank left the debt at or above minDebt");
            assertEq(sold > 0, multBps[i] > 10000, "and it sold exactly when there was head over minDebt");
            vm.revertToState(snap);
        }
    }

    /// @notice The unarmed-then-armed order: a crank lands on an unarmed loan, the borrower arms after, and the fold still rolls.
    /// @dev Why the cap is on EVERY loan: an armed-only cap is front-run by a crank in the block before `setAutoRefinance` lands.
    function test_NoFlip_AnUnarmedLoanCrankedThenArmedStillRolls() public {
        uint256 loanId = _open(MIN_DEBT * 12 / 10, THETA);
        _warpTo(_expiryOf(loanId) - 1 days);
        _enterBand(loanId);
        (uint256 sold,) = keeper.crankDeleverage(loanId);
        assertGt(sold, 0, "PREMISE: the unarmed loan was cranked");
        uint256 debtAfter = read.debtOf(loanId);
        _arm(loanId);
        _warpTo(_expiryOf(loanId) + 1);
        assertTrue(_fold(loanId), "the borrower armed after the crank, and the fold rolls");
        assertEq(debtAfter, MIN_DEBT, "because the crank stopped at minDebt");
    }

    /* ============================== THE CAP ============================== */

    /// @notice Above `minDebt` a crank that would restore past it stops EXACTLY at `minDebt`, and every wei of proceeds melts debt.
    /// @dev The capped crank is not a restore, so it takes no protocol cut: the debt falls by the whole `stableOut`.
    function test_Cap_TheCrankStopsAtMinDebtAndTakesNoCut() public {
        uint256 loanId = _open(MIN_DEBT * 12 / 10, THETA);
        _warpTo(_expiryOf(loanId) - 1 days);
        _enterBand(loanId);
        uint256 debtBefore = read.debtOf(loanId);
        uint256 unitsBefore = read.loan(loanId).collateralUnits;
        (uint256 sold, uint256 stableOut) = keeper.crankDeleverage(loanId);
        assertGt(sold, 0, "the crank sold");
        assertEq(read.debtOf(loanId), MIN_DEBT, "and stopped exactly at minDebt");
        assertEq(debtBefore - read.debtOf(loanId), stableOut, "every wei of proceeds melted debt: no cut on a capped crank");
        assertEq(unitsBefore - read.loan(loanId).collateralUnits, sold, "the lot fell by exactly what sold");
    }

    /// @notice A capped crank that fills PARTIALLY still takes no cut, and still leaves the debt at or above `minDebt`.
    function test_Cap_APartialFillOfACappedCrankTakesNoCut() public {
        uint256 loanId = _open(MIN_DEBT * 12 / 10, THETA);
        _warpTo(_expiryOf(loanId) - 1 days);
        _enterBand(loanId);
        keeper.setRefundBps(5000);
        uint256 debtBefore = read.debtOf(loanId);
        (uint256 sold, uint256 stableOut) = keeper.crankDeleverage(loanId);
        assertGt(sold, 0, "half the capped sale filled");
        assertGt(read.debtOf(loanId), MIN_DEBT, "a half fill of the capped sale lands above minDebt");
        assertEq(debtBefore - read.debtOf(loanId), stableOut, "and melts every wei of what it realized");
    }

    /// @notice At or under `minDebt` the crank sells nothing: it returns `(0, 0)` and never calls the keeper back.
    /// @dev Both ways to be there: opened exactly at `minDebt`, and repaid under it by the borrower's own hand.
    function test_Cap_ACrankAtOrUnderMinDebtSellsNothing() public {
        uint256 atFloor = _open(MIN_DEBT, THETA);
        uint256 under = _open(MIN_DEBT * 15 / 10, THETA);
        _repayTo(under, MIN_DEBT / 2);
        _warpTo(_expiryOf(atFloor) - 1 days);
        uint256[2] memory loans = [atFloor, under];
        vm.expectCall(address(keeper), abi.encodeWithSelector(IAceDeleverageCallback.onAceDeleverage.selector), 0); // across BOTH cranks
        for (uint256 i; i < 2; ++i) {
            uint256 loanId = loans[i];
            _enterBand(loanId);
            uint256 debtBefore = read.debtOf(loanId);
            uint256 unitsBefore = read.loan(loanId).collateralUnits;
            (uint256 sold, uint256 stableOut) = keeper.crankDeleverage(loanId);
            assertEq(sold, 0, "nothing sold");
            assertEq(stableOut, 0, "nothing realized");
            assertEq(read.debtOf(loanId), debtBefore, "no debt moved");
            assertEq(read.loan(loanId).collateralUnits, unitsBefore, "no collateral moved");
        }
    }

    /// @notice UNDER `minDebt` the return also precedes the record: a distressed loan returns `(0, 0)`, never `Distressed`.
    /// @dev Repaid under the floor by the borrower's own hand, then distressed; the premise leg is a loan over `minDebt` that does refuse.
    function test_Order_UnderMinDebtADistressedLoanReturnsZeroNotDistressed() public {
        uint256 over = _open(MIN_DEBT * 2, THETA);
        uint256 under = _open(MIN_DEBT * 15 / 10, THETA);
        _repayTo(under, MIN_DEBT / 2);
        record.setBelow(true); // flag mode: persisted below every level, both triggers included
        vm.expectRevert(Distressed.selector);
        keeper.crankDeleverage(over);
        vm.expectCall(address(record), abi.encodeWithSelector(IPersistenceRecord.persistedBelowDistress.selector), 0);
        (uint256 sold, uint256 stableOut) = keeper.crankDeleverage(under);
        assertEq(sold + stableOut, 0, "under minDebt the crank returns (0, 0) before any record read");
        assertEq(read.debtOf(under), MIN_DEBT / 2, "and nothing moved");
    }

    /// @notice The lens mirrors the cap: a loan at or under `minDebt` is not eligible, one atom over it is.
    function test_Lens_DeleverageEligibleIsFalseAtOrUnderMinDebt() public {
        uint256 atFloor = _open(MIN_DEBT, THETA);
        uint256 oneOver = _open(MIN_DEBT + 1, THETA);
        _warpTo(_expiryOf(atFloor) - 1 days);
        _enterBand(atFloor);
        assertFalse(lens.deleverageEligible(atFloor), "at minDebt the crank can sell nothing, so the lens says no");
        _enterBand(oneOver);
        assertTrue(lens.deleverageEligible(oneOver), "one atom over, the crank can sell, so the lens says yes");
        (uint256 sold,) = keeper.crankDeleverage(oneOver);
        assertGt(sold, 0, "and the real crank agrees");
    }

    /* ============================== BOUNDARIES ============================== */

    /// @notice One atom of head: the crank sells the units that atom buys and lands on `minDebt` exactly.
    function test_Boundary_OneAtomOverMinDebtMeltsExactlyThatAtom() public {
        uint256 loanId = _open(MIN_DEBT + 1, THETA);
        _warpTo(_expiryOf(loanId) - 1 days);
        _enterBand(loanId);
        (uint256 sold, uint256 stableOut) = keeper.crankDeleverage(loanId);
        assertGt(sold, 0, "an atom of head admits a sale on this pair, where one quote atom buys ~1e12 collateral atoms");
        assertEq(stableOut, 1, "that realizes exactly the one atom of head");
        assertEq(read.debtOf(loanId), MIN_DEBT, "and lands on minDebt");
    }

    /// @notice A head too small to buy a single collateral atom sells nothing: `room` floors to zero, the crank returns `(0, 0)`.
    /// @dev An 18-decimal quote against a 6-decimal collateral: one collateral atom is worth ~1e12 quote atoms at par.
    function test_Boundary_ARoomOfZeroSellsNothingEvenWithAHead() public {
        (AceFixtures.Deployment memory d, MockDeleverageKeeper k, uint256 loanId) = _q18Loan(3); // three quote atoms of head
        uint256 debt = d.read.debtOf(loanId);
        vm.expectCall(address(k), abi.encodeWithSelector(IAceDeleverageCallback.onAceDeleverage.selector), 0);
        (uint256 sold, uint256 stableOut) = k.crankDeleverage(loanId);
        assertEq(sold, 0, "no whole collateral atom fits in three quote atoms of head");
        assertEq(stableOut, 0, "so nothing is realized");
        assertEq(d.read.debtOf(loanId), debt, "and the debt is untouched");
    }

    /// @notice The lens mirrors the ROOM, not only the floor: a head that buys no whole unit reads ineligible, as the crank returns `(0, 0)`.
    /// @dev The control is the same market with a head worth whole units: the lens says yes and the crank sells, so the no is the room's.
    function test_Lens_DeleverageEligibleIsFalseWhenTheRoomIsZero() public {
        (AceFixtures.Deployment memory d, MockDeleverageKeeper k, uint256 loanId) = _q18Loan(3);
        AceLens l18 = new AceLens(address(d.ace));
        assertGt(d.read.debtOf(loanId), d.ace.idToMarketParams(d.id).minDebt, "PREMISE: the loan carries a head over minDebt");
        assertFalse(l18.deleverageEligible(loanId), "a head that buys no whole unit is not eligible");
        (uint256 sold, uint256 stableOut) = k.crankDeleverage(loanId);
        assertEq(sold + stableOut, 0, "and the real crank agrees: (0, 0)");

        (d, k, loanId) = _q18Loan(1e17); // a tenth of a quote token: ~1e5 collateral atoms of room
        l18 = new AceLens(address(d.ace));
        assertTrue(l18.deleverageEligible(loanId), "control: a head worth whole units is eligible on the same market shape");
        (sold,) = k.crankDeleverage(loanId);
        assertGt(sold, 0, "and the real crank sells");
    }

    /// @dev A fresh 18-decimal-quote, 6-decimal-collateral market and one loan `head` quote atoms over its `minDebt`, the record in band.
    function _q18Loan(uint256 head) internal returns (AceFixtures.Deployment memory d, MockDeleverageKeeper k, uint256 loanId) {
        MockERC20 q = new MockERC20("Q18", "Q18", 18);
        MockERC20 c6 = new MockERC20("C6", "C6", 6);
        MockPersistenceRecord rec = new MockPersistenceRecord(address(q), address(c6));
        uint256 p18 = AceFixtures.priceAt(address(q), address(c6), 0);
        rec.setMinPrice(p18);
        MarketParams memory p = AceFixtures.marketParams(address(q), address(c6));
        p.record = address(rec);
        p.minDebt = 10e18;
        p.deleverageFloorEpsBps = ProtocolPolicy.DELEVERAGE_FLOOR_EPS_BPS;
        p.deleverageBandBps = BAND;
        p.deleverageTargetBps = TARGET;
        p.deleverageStopBps = STOP;
        p.deleverageProtocolBps = 500;
        d = AceFixtures.deploy(p);
        k = new MockDeleverageKeeper(d.ace, address(q), address(c6), S);
        q.mint(alice, 1_000e18);
        vm.startPrank(alice);
        q.approve(address(d.ace), type(uint256).max);
        d.ace.deposit(d.id, 1_000e18);
        vm.stopPrank();
        uint256 debt = 10e18 + head;
        uint256 units = FullMath.mulDiv(K * debt, S * 10000, THETA * p18 * 1e18);
        c6.mint(borrower, units);
        vm.startPrank(borrower);
        c6.approve(address(d.positionManager), units);
        loanId = d.ace.open(d.id, units, debt, ProtocolPolicy.MIN_TENOR, borrower, OpenBounds(0, 0, 0));
        vm.stopPrank();
        _warpTo(uint256(d.read.loan(loanId).expiry) - 1 days);
        rec.setBelowBand(FullMath.mulDivRoundingUp(d.read.triggerPrice(loanId), 1e18, 1e18 - BAND * 1e14));
    }

    /* ============================== FUZZ ============================== */

    /// @notice Whatever the size, margin, record price, fill and moment, a legal crank never turns an admissible fold into a refusal.
    /// @dev The REAL fold runs at `expiry + 1` twice from one state: once untouched (snapshot), once after the crank.
    /// @dev The record price at the crank ranges from just over the stop level to the band level, so it sits BELOW par in part of the range.
    /// @dev At the fold both branches read the record back at par: the property holds the record path fixed and varies only the crank.
    function testFuzz_FoldBranchInvariantUnderAnyLegalPreCrank(uint256 debtSeed, uint256 thetaSeed, uint256 psSeed, uint256 fillSeed, uint256 whenSeed) public {
        uint256 debt = bound(debtSeed, MIN_DEBT, 3 * MIN_DEBT);
        uint256 loanId = _open(debt, bound(thetaSeed, 5100, 8900));
        _arm(loanId);
        uint256 opened = _now();
        _warpTo(bound(whenSeed, opened, _expiryOf(loanId) - 1));
        uint256 trig = read.triggerPrice(loanId);
        record.setBandPrice(trig); // below the band level, not below the trigger: in band, not distressed
        uint256 stopLevel = FullMath.mulDivRoundingUp(trig, 1e18, 1e18 - STOP * 1e14);
        uint256 bandLevel = FullMath.mulDivRoundingUp(trig, 1e18, 1e18 - BAND * 1e14);
        uint256 ps = bound(psSeed, stopLevel + 1, bandLevel - 1);
        bool rolledBase = _foldRollsAtExpiry(loanId);

        record.setMinPrice(ps);
        keeper.setRefundBps(bound(fillSeed, 0, 9999));
        keeper.crankDeleverage(loanId);
        uint256 debtAfter = read.debtOf(loanId);

        _warpTo(_expiryOf(loanId) + 1);
        record.setMinPrice(par);
        bool rolledAfter = _fold(loanId);
        if (rolledBase) assertTrue(rolledAfter, "a fold that rolled untouched still rolls after the crank");
        assertGe(debtAfter, MIN_DEBT, "no crank takes the debt under minDebt");
    }

    /* ============================== HARDENING: the cap's exact edges ============================== */

    /// @dev One q18/c6 market and one loan, with the floor, the debt and the trigger's margin all named by the caller.
    struct Q18 {
        AceFixtures.Deployment d;
        MockDeleverageKeeper k;
        uint256 loanId;
        uint256 ps; // the record's windowed minimum: it sizes the sale, floors it, and prices the room
    }

    /// @dev `_q18Loan` with `minDebt`, the debt and theta as arguments; `minDebt` is genesis-fixed, so each floor is its own market.
    function _q18At(uint256 minDebt, uint256 debt, uint256 thetaBps) internal returns (Q18 memory s) {
        MockERC20 q = new MockERC20("Q18", "Q18", 18);
        MockERC20 c6 = new MockERC20("C6", "C6", 6);
        MockPersistenceRecord rec = new MockPersistenceRecord(address(q), address(c6));
        s.ps = AceFixtures.priceAt(address(q), address(c6), 0);
        rec.setMinPrice(s.ps);
        MarketParams memory p = AceFixtures.marketParams(address(q), address(c6));
        p.record = address(rec);
        p.minDebt = minDebt;
        p.deleverageFloorEpsBps = ProtocolPolicy.DELEVERAGE_FLOOR_EPS_BPS;
        p.deleverageBandBps = BAND;
        p.deleverageTargetBps = TARGET;
        p.deleverageStopBps = STOP;
        p.deleverageProtocolBps = 500;
        s.d = AceFixtures.deploy(p);
        s.k = new MockDeleverageKeeper(s.d.ace, address(q), address(c6), S);
        q.mint(alice, 1_000e18);
        vm.startPrank(alice);
        q.approve(address(s.d.ace), type(uint256).max);
        s.d.ace.deposit(s.d.id, 1_000e18);
        vm.stopPrank();
        uint256 units = FullMath.mulDiv(K * debt, S * 10000, thetaBps * s.ps * 1e18);
        c6.mint(borrower, units);
        vm.startPrank(borrower);
        c6.approve(address(s.d.positionManager), units);
        s.loanId = s.d.ace.open(s.d.id, units, debt, ProtocolPolicy.MIN_TENOR, borrower, OpenBounds(0, 0, 0));
        vm.stopPrank();
        _warpTo(uint256(s.d.read.loan(s.loanId).expiry) - 1 days);
        rec.setBelowBand(FullMath.mulDivRoundingUp(s.d.read.triggerPrice(s.loanId), 1e18, 1e18 - BAND * 1e14));
    }

    /// @dev `Deleverage._owed` on a `Q18` market, transcribed: what the keeper owes for `units`, ceiled.
    function _owedQ(Q18 memory s, uint256 units) internal view returns (uint256) {
        uint256 epsC = 10000 - s.d.ace.idToMarketParams(s.d.id).deleverageFloorEpsBps;
        return FullMath.mulDivRoundingUp(s.ps, units * epsC, 10000 * s.d.read.marketState(s.d.id).unitScale);
    }

    /// @notice THE ROOM EDGE IS STRICT: a restore whose sale is EXACTLY `room` is not capped and keeps its cut.
    /// @notice One atom less head and the restore no longer fits: the crank re-sizes to the cut-free restore and takes no cut.
    /// @notice A head one atom short of THAT restore's proceeds is capped, cut-free, and lands within one unit's value of `minDebt`.
    /// @dev Four copies of one loan that differ only in `minDebt`: far under it, a head of its proceeds, one atom less, one atom short of `u0`'s.
    /// @dev One c6 unit is worth ~1e12 q18 atoms, so a head of `owed(u)` buys exactly `u` units and `owed(u) - 1` exactly `u - 1`.
    /// @dev The cut is read off the debt, never `protocolRevenue`: the crank piggybacks the revenue sweep, which empties that counter.
    function test_Boundary_ASaleOfExactlyRoomKeepsItsCut_OneAtomLessHeadIsResized() public {
        uint256 debt = 20e18;
        Q18 memory s = _q18At(2, debt, 7100); // theta 0.71: just inside the band, where the reserve admits more than the restore asks
        (uint256 u, uint256 owedU) = s.k.crankDeleverage(s.loanId);
        uint256 cut = FullMath.mulDiv(owedU, 500, 10000);
        assertGt(u, 1, "PREMISE: the free restore sold");
        assertGt(cut, 0, "PREMISE: its cut is not rounded away");
        assertEq(debt - s.d.read.debtOf(s.loanId), owedU - cut, "PREMISE: it RESTORED: neither the reserve nor the cap bound, so it took its cut");
        assertGt(_owedQ(s, 1), 1, "PREMISE: one unit is worth more than one quote atom, so the room steps by single units");

        s = _q18At(debt - owedU, debt, 7100);
        vm.expectEmit(true, true, false, true, address(s.d.ace));
        emit Deleverage.Deleveraged(s.loanId, u, owedU, owedU - cut, address(s.k));
        (uint256 sold, uint256 out) = s.k.crankDeleverage(s.loanId);
        assertEq(sold, u, "a head of exactly the proceeds admits the whole sale: room == u is not capped");
        assertEq(out, owedU, "and realizes the same proceeds");
        assertEq(s.d.read.debtOf(s.loanId), debt - owedU + cut, "`charge` stays true at room == u: the cut is charged, so the debt lands it ABOVE minDebt");

        _assertOneAtomLessHeadIsResized(debt, owedU, u);
    }

    /// @dev The third copy: `minDebt` one atom higher, so the head is one atom short of the free restore's proceeds.
    /// @dev The room is then `u - 1`, so `u` no longer fits: the crank re-sizes to the cut-free restore `u0`, which does.
    function _assertOneAtomLessHeadIsResized(uint256 debt, uint256 owedU, uint256 u) internal {
        uint256 minDebt = debt - owedU + 1;
        Q18 memory s = _q18At(minDebt, debt, 7100);
        uint256 u0 = _freeQ(s);
        uint256 want = _owedQ(s, u0);
        assertLt(u0, u - 1, "PREMISE: the cut-free restore fits under the one-unit-short room");
        vm.expectEmit(true, true, false, true, address(s.d.ace));
        emit Deleverage.Deleveraged(s.loanId, u0, want, want, address(s.k));
        (uint256 sold, uint256 out) = s.k.crankDeleverage(s.loanId);
        assertEq(sold, u0, "one atom less head: u no longer fits, so the crank re-sizes to the cut-free restore");
        assertEq(out, want, "and realizes that many units' proceeds");
        uint256 left = s.d.read.debtOf(s.loanId);
        assertEq(left, debt - out, "a re-sized crank takes no cut: every wei of proceeds melted debt");
        assertGe(left, minDebt, "never under minDebt");
        _assertOneAtomShortOfTheCutFreeRestoreLandsOnMinDebt(debt, u0, want);
    }

    /// @dev The fourth copy: the head one atom short of the cut-free restore's proceeds, so the room is `u0 - 1` and the cap is the sale.
    function _assertOneAtomShortOfTheCutFreeRestoreLandsOnMinDebt(uint256 debt, uint256 u0, uint256 owedU0) internal {
        uint256 minDebt = debt - owedU0 + 1;
        Q18 memory s = _q18At(minDebt, debt, 7100);
        uint256 want = _owedQ(s, u0 - 1);
        vm.expectEmit(true, true, false, true, address(s.d.ace));
        emit Deleverage.Deleveraged(s.loanId, u0 - 1, want, want, address(s.k));
        (uint256 sold, uint256 out) = s.k.crankDeleverage(s.loanId);
        assertEq(sold, u0 - 1, "one atom less head than the cut-free restore's proceeds buys one unit less: the cap binds");
        assertEq(out, want, "and realizes that many units' proceeds");
        uint256 left = s.d.read.debtOf(s.loanId);
        assertEq(left, debt - out, "a capped crank takes no cut: every wei of proceeds melted debt");
        assertGe(left, minDebt, "never under minDebt");
        assertLt(left - minDebt, _owedQ(s, 1), "and within one unit's value of it: the cap's rounding bound");
    }

    /// @dev `Deleverage`'s restore sizing on a `Q18` loan with NO cut: what a crank that takes no cut is re-sized to.
    function _freeQ(Q18 memory s) internal view returns (uint256) {
        MarketParams memory p = s.d.ace.idToMarketParams(s.d.id);
        uint256 units = s.d.read.loan(s.loanId).collateralUnits;
        uint256 trig = s.d.read.triggerPrice(s.loanId);
        uint256 tStar = FullMath.mulDiv(s.ps, 1e18 - p.deleverageTargetBps * 1e14, 1e18);
        uint256 y = FullMath.mulDiv(s.ps, p.minCoverageWad * (10000 - p.deleverageFloorEpsBps), 1e22);
        return FullMath.mulDiv(units, trig - tStar, y - tStar);
    }

    /// @notice #413: a head BETWEEN the two restores' proceeds re-sizes the crank cut-free, so it restores and lands clear of `minDebt`.
    /// @dev The cut-charging restore `u` no longer fits under the room and the cut-free one does; before #413 the crank sold the whole room.
    function test_Boundary_AHeadBetweenTheTwoRestoresResizesCutFree() public {
        uint256 debt = 20e18;
        Q18 memory s = _q18At(2, debt, 7100);
        uint256 free = _freeQ(s);
        uint256 owedFree = _owedQ(s, free);
        (, uint256 owedU) = s.k.crankDeleverage(s.loanId);
        assertLt(owedFree + 1, owedU, "PREMISE: the cut-free restore realizes less than the cut-charging one, by more than an atom");

        uint256 minDebt = debt - (owedFree + owedU) / 2;
        s = _q18At(minDebt, debt, 7100);
        assertEq(_freeQ(s), free, "PREMISE: the same shape sizes the same cut-free restore");
        (uint256 sold, uint256 out) = s.k.crankDeleverage(s.loanId);
        assertEq(sold, free, "a head between the two restores sells the cut-free restore, not the whole room");
        assertEq(out, owedFree, "and realizes its proceeds");
        uint256 left = s.d.read.debtOf(s.loanId);
        assertEq(left, debt - out, "with no cut: every wei of proceeds melted debt");
        assertGt(left - minDebt, _owedQ(s, 1), "so the debt lands clear of minDebt: the room was not the sale");
        uint256 tStar = FullMath.mulDiv(s.ps, 1e18 - TARGET * 1e14, 1e18);
        assertApproxEqRel(s.d.read.triggerPrice(s.loanId), tStar, 1e12, "a cut-free restore lands the trigger on target");
    }

    /// @notice The lens and the crank agree at the one-unit room edge, on the atom.
    /// @notice A head one atom short of a unit's price reads ineligible and sells nothing; a head of exactly that price sells one unit.
    function test_Boundary_LensAndCrankAgreeAtTheOneUnitRoomEdge() public {
        Q18 memory s = _q18At(10e18, 10e18 + 1e17, THETA); // a probe for one unit's price on this shape
        uint256 owed1 = _owedQ(s, 1);
        assertGt(owed1, 1, "PREMISE: one unit is worth more than one quote atom");

        s = _q18At(10e18, 10e18 + owed1 - 1, THETA);
        assertEq(_owedQ(s, 1), owed1, "PREMISE: the same shape prices one unit the same");
        AceLens l = new AceLens(address(s.d.ace));
        assertFalse(l.deleverageEligible(s.loanId), "one atom short of a unit's price: the lens says no");
        vm.expectCall(address(s.k), abi.encodeWithSelector(IAceDeleverageCallback.onAceDeleverage.selector), 0);
        (uint256 sold, uint256 out) = s.k.crankDeleverage(s.loanId);
        assertEq(sold + out, 0, "and the crank sells nothing, with no callback");

        s = _q18At(10e18, 10e18 + owed1, THETA);
        l = new AceLens(address(s.d.ace));
        assertTrue(l.deleverageEligible(s.loanId), "a head of exactly one unit's price: the lens says yes");
        (sold, out) = s.k.crankDeleverage(s.loanId);
        assertEq(sold, 1, "and the crank sells exactly one unit");
        assertEq(out, owed1, "for exactly that unit's price");
        assertEq(s.d.read.debtOf(s.loanId), 10e18, "landing the debt ON minDebt");
    }

    /// @notice An unbounded record price never reverts the lens and never wraps the crank: both say there is nothing to sell.
    /// @dev Past `max / (1e4 - eps)` the lens's `ps * (1e4 - eps)` would wrap, so it answers false; the crank's sizing sells nothing first.
    function test_Lens_AnUnboundedRecordPriceIsIneligibleAndNeverReverts() public {
        uint256 loanId = _open(MIN_DEBT * 2, THETA);
        _warpTo(_expiryOf(loanId) - 1 days);
        _enterBand(loanId);
        assertTrue(lens.deleverageEligible(loanId), "PREMISE: at par the loan is eligible");
        uint256 edge = type(uint256).max / (10000 - ace.idToMarketParams(id).deleverageFloorEpsBps);
        uint256[3] memory prices = [edge, edge + 1, type(uint256).max];
        for (uint256 i; i < prices.length; ++i) {
            record.setMinPrice(prices[i]);
            assertFalse(lens.deleverageEligible(loanId), "an unbounded price reads ineligible, and the view does not revert");
            (uint256 sold, uint256 out) = keeper.crankDeleverage(loanId);
            assertEq(sold + out, 0, "and the crank's sizing sells nothing: the room's product is never formed");
        }
        assertEq(read.debtOf(loanId), MIN_DEBT * 2, "nothing moved");
    }

    /// @notice The rest of the refusal order: at `minDebt` the return also outranks `NoRecordPrice` and `DeleverageStopped`.
    /// @dev Each premise leg is a loan over `minDebt` in the same record state, which does refuse.
    function test_Order_TheMinDebtReturnOutranksAZeroPriceAndTheStop() public {
        uint256 over = _open(MIN_DEBT * 2, THETA);
        uint256 atFloor = _open(MIN_DEBT, THETA);
        _warpTo(_expiryOf(atFloor) - 1 days);
        _enterBand(over); // both loans sit at THETA, so one band serves both

        record.setMinPrice(0);
        vm.expectRevert(NoRecordPrice.selector);
        keeper.crankDeleverage(over);
        (uint256 sold, uint256 out) = keeper.crankDeleverage(atFloor);
        assertEq(sold + out, 0, "a zero record price: at minDebt the crank returns (0, 0), never NoRecordPrice");

        record.setMinPrice(FullMath.mulDivRoundingUp(read.triggerPrice(over), 1e18, 1e18 - STOP * 1e14)); // ON the stop level
        vm.expectRevert(DeleverageStopped.selector);
        keeper.crankDeleverage(over);
        (sold, out) = keeper.crankDeleverage(atFloor);
        assertEq(sold + out, 0, "at the stop: at minDebt the crank returns (0, 0), never DeleverageStopped");
    }
}
