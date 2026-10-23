// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.36;

import {Test} from "forge-std/Test.sol";
import {Ace} from "../../src/ace/hub/Ace.sol";
import {AceLens} from "../../src/ace/lens/AceLens.sol";
import {MarketParams, OpenBounds} from "../../src/ace/hub/Types.sol";
import {DeleverageStopped} from "../../src/ace/hub/Deleverage.sol";
import {PositionManager} from "../../src/ace/positions/PositionManager.sol";
import {FullMath} from "@uniswap/v4-core/src/libraries/FullMath.sol";
import {MockERC20} from "../mocks/MockERC20.sol";
import {MockPersistenceRecord} from "../mocks/MockPersistenceRecord.sol";
import {MockDeleverageKeeper} from "../mocks/MockDeleverageKeeper.sol";
import {MockStakeVault} from "../mocks/MockStakeVault.sol";
import {AceFixtures} from "../utils/AceFixtures.sol";
import {AceReader} from "../utils/AceReader.sol";

/// @title AceDeleverageActivationTest
/// @notice The M1 deleverage activation: the per-market stop floor and the genesis rails behind it.
/// @notice The protocol cut is re-derived into the sizing so the BORROWER, never the lender, bears it.
/// @notice Every admitted crank stays fully restorable; the placeholder dials are VALIDATION-OWED.
contract AceDeleverageActivationTest is Test {
    Ace internal ace;
    PositionManager internal positionManager;
    AceReader internal read;
    AceLens internal lens;
    MockERC20 internal usdc;
    MockStakeVault internal vault;
    MockPersistenceRecord internal record;
    MockDeleverageKeeper internal keeper;
    bytes32 internal id;

    address internal alice = address(0xA11CE);
    address internal borrower = address(0xB0B);

    uint256 internal constant COLL = 10_000e18;
    uint256 internal constant PRINCIPAL = 4_500e6;
    uint256 internal P; // $2.00 per collateral token, framed in setUp once the pair's decimals are known
    uint256 internal T; // this pair's par tick, assigned in setUp
    uint256 internal constant UNIT_SCALE = 1 << 96; // every market's scale under the atom frame
    uint256 internal constant EPS = 100;
    uint256 internal constant BAND_BPS = 3000; // the M1 placeholder band: 30% margin
    uint256 internal constant TARGET_BPS = 5000; // restores to 50%
    uint256 internal constant STOP_BPS = 1000; // stops below 10%
    uint256 internal constant CUT_BPS = 500; // 5% protocol cut

    uint256 internal constant WITNESS_K = 1147959183673469390; // #353: tuned so `stop below sellmax onset` clears by exactly 1 wei
    uint256 internal constant WITNESS_EPS = 200; // MAX_DELEVERAGE_FLOOR_EPS_BPS
    uint256 internal constant WITNESS_CUT = 2000; // MAX_DELEVERAGE_PROTOCOL_BPS
    uint256 internal constant WITNESS_PS = 10000000000000001; // 0.01 quote per unit, one wei above the stop level the trigger implies
    uint256 internal constant WITNESS_TRIG = 9e15; // the largest trigger the stop gate admits at that price, and the first term lands on it
    uint256 internal constant WITNESS_PRINCIPAL = 78_400_000; // 78.4 quote, so the minimal covering collateral is ~792 whole units
    int24 internal constant WITNESS_TICK = -298020; // the lowest grid tick priced at or above the witness trigger, at spacing 60

    function setUp() public {
        usdc = new MockERC20("USD Coin", "USDC", 6);
        vault = new MockStakeVault(42);
        record = new MockPersistenceRecord(address(usdc), address(vault));
        T = AceFixtures.priceAt(address(usdc), address(vault), 0);
        P = AceFixtures.px(2e18, address(usdc), address(vault));
        record.setMinPrice(P);

        AceFixtures.Deployment memory d = AceFixtures.deploy(_params(CUT_BPS));
        (ace, positionManager, read, id) = (d.ace, d.positionManager, d.read, d.id);
        lens = new AceLens(address(ace));
        keeper = new MockDeleverageKeeper(ace, address(usdc), address(vault), UNIT_SCALE);

        usdc.mint(alice, 15_000e6);
        vm.startPrank(alice);
        usdc.approve(address(ace), 15_000e6);
        ace.deposit(id, 15_000e6);
        vm.stopPrank();
    }

    // ---- helpers ----

    function _params(uint256 cut) internal view returns (MarketParams memory p) {
        p = AceFixtures.marketParams(address(usdc), address(vault));
        p.record = address(record);
        p.deleverageFloorEpsBps = EPS;
        p.deleverageBandBps = BAND_BPS;
        p.deleverageTargetBps = TARGET_BPS;
        p.deleverageStopBps = STOP_BPS;
        p.deleverageProtocolBps = cut;
    }

    function _open() internal returns (uint256 loanId) {
        vault.mint(borrower, COLL);
        vm.startPrank(borrower);
        vault.approve(address(positionManager), COLL);
        loanId = ace.open(id, COLL, PRINCIPAL, 0, borrower, OpenBounds(0, 0, 0));
        vm.stopPrank();
    }

    function _bandLevel(uint256 loanId) internal view returns (uint256) {
        return FullMath.mulDivRoundingUp(read.triggerPrice(loanId), 1e18, 1e18 - BAND_BPS * 1e14);
    }

    function _stopLevel(uint256 loanId) internal view returns (uint256) {
        return FullMath.mulDivRoundingUp(read.triggerPrice(loanId), 1e18, 1e18 - STOP_BPS * 1e14);
    }

    /// @dev Arm the record in the band at sizing price `ps`, which is also the disposal floor.
    /// @dev Below-ness holds at the BAND level, so the entry gate passes and the loan is NOT distressed.
    function _arm(uint256 loanId, uint256 ps) internal {
        record.setBelowBand(_bandLevel(loanId));
        record.setMinPrice(ps);
    }

    /// @dev A restoring price: mid-way through the operating band (above stop, below band).
    function _restorePs(uint256 loanId) internal view returns (uint256) {
        return (_stopLevel(loanId) + _bandLevel(loanId)) / 2;
    }

    // ============ T1: restore-to-target holds with the cut ============

    function test_RestoreToTargetHoldsWithCut() public {
        uint256 loanId = _open();
        uint256 ps = _restorePs(loanId);
        _arm(loanId, ps);

        (uint256 sold,) = keeper.crankDeleverage(loanId);
        assertGt(sold, 0, "the restoring crank ran");

        uint256 tStar = (ps * (1e18 - TARGET_BPS * 1e14)) / 1e18;
        assertLe(read.triggerPrice(loanId), tStar + 1, "restore lands at or better than target, cut and all");
    }

    // ============ T2: the protocol accrues 5% off the top on a restoring crank ============

    function test_ProtocolAccrues5PctOnDeleverage() public {
        uint256 loanId = _open();
        uint256 ps = _restorePs(loanId);
        _arm(loanId, ps);
        keeper.setRoutePrice(ps);
        uint256 rev0 = read.protocolRevenue(id);

        (, uint256 out) = keeper.crankDeleverage(loanId);

        uint256 cut = FullMath.mulDiv(out, CUT_BPS, 10000);
        assertGt(cut, 0, "fixture: the cut is a real number");
        assertEq(read.protocolRevenue(id) - rev0, cut, "protocol took exactly 5% off the top");
    }

    // ============ T3: the sizing sells MORE to cover the cut (borrower-borne) ============

    function test_SizingSellsMoreToCoverTheCut() public {
        uint256 withCut = _open();
        uint256 ps = _restorePs(withCut);
        _arm(withCut, ps);
        (uint256 soldCut,) = keeper.crankDeleverage(withCut);

        // an identical market with the cut OFF, its OWN record so the two markets never cross-contaminate
        MockPersistenceRecord rec2 = new MockPersistenceRecord(address(usdc), address(vault));
        rec2.setMinPrice(P);
        MarketParams memory pn = _params(0);
        pn.record = address(rec2);
        AceFixtures.Deployment memory d = AceFixtures.deploy(pn);
        MockDeleverageKeeper k2 = new MockDeleverageKeeper(d.ace, address(usdc), address(vault), UNIT_SCALE);
        usdc.mint(alice, 15_000e6);
        vm.startPrank(alice);
        usdc.approve(address(d.ace), 15_000e6);
        d.ace.deposit(d.id, 15_000e6);
        vm.stopPrank();
        vault.mint(borrower, COLL);
        vm.startPrank(borrower);
        vault.approve(address(d.positionManager), COLL);
        uint256 noCut = d.ace.open(d.id, COLL, PRINCIPAL, 0, borrower, OpenBounds(0, 0, 0));
        vm.stopPrank();
        AceReader r2 = new AceReader(address(d.ace));
        uint256 trig = r2.triggerPrice(noCut);
        uint256 psN = (FullMath.mulDivRoundingUp(trig, 1e18, 1e18 - STOP_BPS * 1e14) + FullMath.mulDivRoundingUp(trig, 1e18, 1e18 - BAND_BPS * 1e14)) / 2;
        rec2.setBelowBand(FullMath.mulDivRoundingUp(trig, 1e18, 1e18 - BAND_BPS * 1e14));
        rec2.setMinPrice(psN);
        (uint256 soldNoCut,) = k2.crankDeleverage(noCut);

        assertGt(soldNoCut, 0, "the no-cut crank ran");
        assertGt(soldCut, soldNoCut, "the cut market sells MORE units: the borrower bears the cut");
    }

    // ============ T4: genesis rails reject infeasible configs ============

    function test_RailsRejectInfeasible() public {
        Ace hub = AceFixtures.newAce();
        MarketParams memory p = _params(CUT_BPS);

        MarketParams memory a = p;
        a.deleverageProtocolBps = 2001; // over the 20% cap
        vm.expectRevert("deleverage cut too high");
        hub.createMarket(a);

        MarketParams memory b = p;
        b.deleverageStopBps = 0; // no positive floor
        vm.expectRevert("deleverage stop out of band");
        hub.createMarket(b);

        MarketParams memory c = p;
        c.deleverageStopBps = BAND_BPS; // not strictly below the band
        vm.expectRevert("deleverage stop out of band");
        hub.createMarket(c);

        MarketParams memory e = p;
        e.minCoverageWad = 1.05e18; // MIN_COVERAGE_WAD: k(1-eps)(1-cut)+stop < 1
        e.deleverageProtocolBps = 2000;
        e.deleverageStopBps = 1000;
        vm.expectRevert("stop below sellmax onset");
        hub.createMarket(e);

        MarketParams memory f = p;
        f.deleverageBandBps = 0; // channel off but stop, cut and eps still set
        f.deleverageTargetBps = 0;
        vm.expectRevert("deleverage off but dials set");
        hub.createMarket(f);
    }

    // ============ T5: the M1 market shape activates, on the record alone ============

    /// @dev There is ONE shape now: the record is the whole floor, so the gauge market is not a second wiring.
    function test_TheMarketShapeActivatesOnTheRecordAlone() public view {
        MarketParams memory rp = ace.idToMarketParams(id);
        assertEq(rp.deleverageBandBps, BAND_BPS, "band on");
        assertEq(rp.deleverageStopBps, STOP_BPS, "stop on");
        assertEq(rp.record, address(record), "and the disposal floor is the record it names");
    }

    // ============ T6: the stop floor refuses below it, admits above it ============

    function test_StopFloorRefusesBelowAdmitsAbove() public {
        uint256 loanId = _open();
        uint256 stop = _stopLevel(loanId);

        _arm(loanId, stop); // exactly at the stop level: the STRICT gate refuses
        vm.expectRevert(DeleverageStopped.selector);
        keeper.crankDeleverage(loanId);

        _arm(loanId, stop + stop / 20); // ~5% above the stop: admitted
        (uint256 sold,) = keeper.crankDeleverage(loanId);
        assertGt(sold, 0, "just above the stop floor the crank is admitted");
    }

    // ============ T7: a stopped loan settles IN-KIND (title transfer, not a sale) ============

    function test_StoppedLoanSettlesInKind() public {
        uint256 loanId = _open();
        uint256 trig = read.triggerPrice(loanId);

        // below the stop floor: the trade channel refuses
        record.setBelowBand(_bandLevel(loanId));
        record.setMinPrice((trig * 105) / 100); // 5% margin, under the 10% stop
        vm.expectRevert(DeleverageStopped.selector);
        keeper.crankDeleverage(loanId);

        // the decline persists into distress: the title-transfer machine takes the loan
        record.setBelowBand(0); // clear band mode so persistedBelow reads the flat distress flag
        record.setBelow(true);
        ace.finalize(loanId);
        assertGt(read.invPotOf(id, loanId), 0, "settlement moved collateral title to the class in-kind");

        // and a lender redeems that pot as the COLLATERAL TOKEN, not a USDC sale

        uint256 vault0 = vault.balanceOf(alice);
        vm.prank(alice);
        ace.redeemInKind(loanId, alice);
        assertGt(vault.balanceOf(alice) - vault0, 0, "the lender redeemed the asset in-kind, never sold off");
    }

    // ============ T8: every admitted crank is fully-restorable, so the cut is borrower-borne ============

    function testFuzz_AdmittedBandIsFullyRestorable_CutBorrowerBorne(uint256 psSeed) public {
        uint256 loanId = _open();
        uint256 stop = _stopLevel(loanId);
        uint256 band = _bandLevel(loanId);
        uint256 ps = bound(psSeed, stop + 1, band - 1); // anywhere in the operating band
        _arm(loanId, ps);
        keeper.setRoutePrice(ps);
        uint256 rev0 = read.protocolRevenue(id);

        (uint256 sold, uint256 out) = keeper.crankDeleverage(loanId);
        if (sold == 0) return; // at/above target the channel self-extinguishes; nothing to assert

        uint256 tStar = (ps * (1e18 - TARGET_BPS * 1e14)) / 1e18;
        assertLe(read.triggerPrice(loanId), tStar + 1, "restored to target on every admitted crank");
        assertEq(read.protocolRevenue(id) - rev0, FullMath.mulDiv(out, CUT_BPS, 10000), "cut taken, borrower-borne");
    }

    // ============ T9: a gap-down straight through the band refuses, no sale ============

    function test_GapDownThroughBand_RefusesNoSale() public {
        uint256 loanId = _open();
        uint256 trig = read.triggerPrice(loanId);
        record.setBelowBand(_bandLevel(loanId));
        record.setMinPrice((trig * 101) / 100); // gaps to just above the trigger, deep under the stop

        vm.expectRevert(DeleverageStopped.selector);
        keeper.crankDeleverage(loanId);
        assertEq(read.loan(loanId).collateralUnits, COLL, "no units sold on the refusal: straight to settlement");
    }

    // ============ T10: a capped (sell-max) crank re-sizes cut-free, then melts in full with no cut ============

    // DELETED: test_ScopeCappedCrank_NoCutFallback -- its property survives on test_SellMaxWitness_SizingReturnsWholeCollateral_NoCutAndFullMelt

    // ============ T11: the shipped placeholders are the labeled, VALIDATION-OWED values ============

    function test_PlaceholdersAreTheDocumentedValues() public view {
        MarketParams memory p = ace.idToMarketParams(id);
        assertEq(p.deleverageBandBps, 3000, "band placeholder");
        assertEq(p.deleverageTargetBps, 5000, "target placeholder");
        assertEq(p.deleverageStopBps, 1000, "stop placeholder");
        assertEq(p.deleverageProtocolBps, 500, "cut placeholder");
    }

    // ============ T12: the two new fields round-trip through storage ============

    function test_LayoutRoundTrips() public {
        MarketParams memory p = _params(0);
        p.deleverageStopBps = 1234;
        p.deleverageProtocolBps = 777;
        AceFixtures.Deployment memory d = AceFixtures.deploy(p);
        MarketParams memory back = d.ace.idToMarketParams(d.id);
        assertEq(back.deleverageStopBps, 1234, "deleverageStopBps round-trips");
        assertEq(back.deleverageProtocolBps, 777, "deleverageProtocolBps round-trips");
        assertEq(keccak256(abi.encode(back)), d.id, "the whole params blob round-trips by id: the +2 offset landed");
    }

    // ============ T13: keeper economics are unchanged by the cut ============

    function test_KeeperEconomicsUnchangedByTheCut() public {
        uint256 loanId = _open();
        uint256 ps = _restorePs(loanId);
        _arm(loanId, ps);
        keeper.setRoutePrice(ps);

        (uint256 sold, uint256 out) = keeper.crankDeleverage(loanId);
        uint256 realized = (sold * ps) / UNIT_SCALE;
        assertEq(usdc.balanceOf(address(keeper)), realized - out, "the keeper kept eps: the cut is downstream, not its cost");
    }

    // ---- hardening additions (pure additions; no existing test modified) ----

    /// @dev The sizing closed form, mirroring `Deleverage._deleverageSizing` EXACTLY.
    /// @dev Used ONLY to pin the `(1-cut)` factor; the independent oracle is restore-to-target, asserted alongside.
    function _sizeExpected(uint256 units, uint256 trig, uint256 ps, uint256 kk, uint256 eps, uint256 cut) internal pure returns (uint256) {
        uint256 tStar = (ps * (1e18 - TARGET_BPS * 1e14)) / 1e18;
        if (trig <= tStar) return 0;
        uint256 inner = FullMath.mulDiv(kk, ps * (10000 - eps), 1e18 * 10000);
        uint256 den = FullMath.mulDiv(inner, 10000 - cut, 10000) - tStar;
        uint256 u = FullMath.mulDiv(units, trig - tStar, den);
        return u > units ? units : u;
    }

    // ============ H1: restore-to-target is TWO-SIDED, so overselling breaks it too ============

    /// @dev A one-sided bound misses a mutation applying `(1-cut)` TWICE, which oversells past target.
    /// @dev So this fuzzes the whole band and asserts BOTH sides.
    function testFuzz_RestoreToTarget_TwoSided(uint256 psSeed) public {
        uint256 loanId = _open();
        uint256 stop = _stopLevel(loanId);
        uint256 band = _bandLevel(loanId);
        uint256 ps = bound(psSeed, stop + 1, band - 1);
        _arm(loanId, ps);

        (uint256 sold,) = keeper.crankDeleverage(loanId);
        if (sold == 0) return; // at/above target the channel self-extinguishes

        uint256 tStar = (ps * (1e18 - TARGET_BPS * 1e14)) / 1e18;
        assertLe(read.triggerPrice(loanId), tStar + 2, "restore never UNDER-shoots target (cut omitted would)");
        /// @dev the floor IS `ps`, so the sale must not OVER-shoot either (cut doubled would)
        assertApproxEqRel(read.triggerPrice(loanId), tStar, 1e15, "restore never OVER-shoots target");
    }

    // ============ H2: the (1-cut) denominator factor is pinned to the exact wei ============

    /// @dev assertEq on the closed form kills an omitted `(1-cut)` (sells fewer) and a doubled one (sells more).
    /// @dev The delta against a cut-free denominator is pinned nonzero, so the factor cannot vanish.
    function test_SizingFactor_PinnedExactly() public {
        uint256 loanId = _open();
        uint256 ps = _restorePs(loanId);
        _arm(loanId, ps);
        uint256 trig = read.triggerPrice(loanId);
        uint256 kk = ace.idToMarketParams(id).minCoverageWad;

        uint256 expCut = _sizeExpected(COLL, trig, ps, kk, EPS, CUT_BPS);
        uint256 expNoCut = _sizeExpected(COLL, trig, ps, kk, EPS, 0);
        assertGt(expCut, expNoCut, "the cut factor makes the sizing sell strictly more");

        (uint256 sold,) = keeper.crankDeleverage(loanId);
        assertEq(sold, expCut, "sized units match the (1-cut) closed form to the wei");
        uint256 tStar = (ps * (1e18 - TARGET_BPS * 1e14)) / 1e18; // the property that formula serves
        assertApproxEqRel(read.triggerPrice(loanId), tStar, 1e15, "and it restores to target");
    }

    // ============ H3: the stop gate is STRICT at the exact wei boundary ============

    /// @dev `stopLevel - 1` and `stopLevel` are both refused; `stopLevel + 1` is admitted.
    /// @dev That kills `<=` -> `<` and pins the `mulDivRoundingUp` direction of `stopLevel`.
    function test_StopGate_ExactWeiBoundary() public {
        uint256 loanId = _open();
        uint256 stop = _stopLevel(loanId);

        _arm(loanId, stop - 1);
        vm.expectRevert(DeleverageStopped.selector);
        keeper.crankDeleverage(loanId);

        _arm(loanId, stop);
        vm.expectRevert(DeleverageStopped.selector);
        keeper.crankDeleverage(loanId);

        _arm(loanId, stop + 1);
        (uint256 sold,) = keeper.crankDeleverage(loanId);
        assertGt(sold, 0, "one wei above the stop floor is admitted");
    }

    // ============ H5: the "deleverage denominator" rail is redundant given the others ============

    /// @dev Worst case that MINIMIZES k(1-eps)(1-cut)+target under the other rails still clears 1e18; a successful createMarket IS the proof.
    /// @dev REDUNDANT, not unreachable: `target > band > stop` makes `stop below sellmax onset` imply it term for term.
    /// @dev It is checked FIRST, so on a doubly-failing config its message shadows the sell-max rail's, which is why the rail is KEPT.
    /// @dev The RUNTIME denominator rests on the stop gate and the sell-max rail; that bound is stated and swept in AceDeleverageDenominatorBound.
    function test_DenominatorRail_IsRedundant_WorstCaseStillAdmitted() public {
        MarketParams memory p = _params(2000); // cut at the cap
        p.minCoverageWad = 1.05e18; // MIN_COVERAGE_WAD
        p.deleverageFloorEpsBps = 200; // MAX eps: shrinks k(1-eps)(1-cut) the most
        p.deleverageBandBps = 3000; // band at its floor
        p.deleverageTargetBps = 3001; // target just above the band: the smallest admissible target term
        p.deleverageStopBps = 1900; // clears the sell-max rail (stop + k(1-eps)(1-cut) > 1)
        AceFixtures.Deployment memory d = AceFixtures.deploy(p);
        assertEq(d.ace.idToMarketParams(d.id).deleverageBandBps, 3000, "the denominator-worst config is admitted");
    }

    // ============ H6: the in-kind settlement keeps the LR-9 cap identity at every step ============

    /// @dev Extends T7: the LR-9 headroom identity against the class pot, at all three stages.
    function test_StoppedLoanInKind_LR9IdentityHoldsAndRedemptionIsExact() public {
        uint256 loanId = _open();
        uint256 trig = read.triggerPrice(loanId);

        record.setBelowBand(_bandLevel(loanId));
        record.setMinPrice((trig * 105) / 100); // 5% margin, under the 10% stop: the trade channel refuses
        vm.expectRevert(DeleverageStopped.selector);
        keeper.crankDeleverage(loanId);
        assertEq(read.headroom(id), read.invPotOf(id, loanId), "LR-9 identity holds pre-settlement");

        record.setBelowBand(0);
        record.setBelow(true);
        ace.finalize(loanId);
        assertGt(read.invPotOf(id, loanId), 0, "collateral title moved in-kind to the funding class");
        assertEq(read.headroom(id), read.invPotOf(id, loanId), "LR-9 identity holds after settlement");

        uint256 vault0 = vault.balanceOf(alice);
        vm.prank(alice);
        uint256 units = ace.redeemInKind(loanId, alice);
        assertGt(units, 0, "in-kind units were delivered");
        assertEq(vault.balanceOf(alice) - vault0, units, "the lender received EXACTLY the in-kind units, no USDC sale");
        assertEq(read.headroom(id), read.invPotOf(id, loanId), "LR-9 identity holds after in-kind redemption");
    }

    // ============ H7: the sell-max rail buys u <= C and NOT u < C -- the witness, driven through the hub ============

    /// @dev The whole witness fixture as ONE value, so no test frame holds the deployment, both mocks and the loan at once.
    struct Witness {
        AceFixtures.Deployment d;
        MockPersistenceRecord rec;
        MockDeleverageKeeper keep;
        uint256 loanId;
        uint256 units;
    }

    /// @dev The witness market, seeded at the one tick priced above the witness trigger, with the minimal covering collateral.
    /// @dev `units` is `requiredAt(principal, WITNESS_TRIG)`, which is the SMALLEST collateral whose trigger is the witness trigger.
    /// @dev The record sits at its 2e18 default through the deposit and the draw, because a tick priced above it cannot be lent at.
    function _witness() private returns (Witness memory w) {
        MarketParams memory p = _params(WITNESS_CUT);
        w.rec = new MockPersistenceRecord(address(usdc), address(vault));
        p.record = address(w.rec);
        p.minCoverageWad = WITNESS_K;
        p.deleverageFloorEpsBps = WITNESS_EPS;
        p.deleverageStopBps = STOP_BPS;
        w.d = AceFixtures.deploy(p); // the genesis leg the planner never ran: every rail admits the witness
        w.keep = new MockDeleverageKeeper(w.d.ace, address(usdc), address(vault), UNIT_SCALE);
        usdc.mint(alice, 1_000e6);
        vm.startPrank(alice);
        usdc.approve(address(w.d.ace), 1_000e6);
        w.d.ace.deposit(w.d.id, 1_000e6);
        vm.stopPrank();
        w.units = FullMath.mulDivRoundingUp(WITNESS_K * WITNESS_PRINCIPAL, UNIT_SCALE, WITNESS_TRIG * 1e18);
        vault.mint(borrower, w.units);
        vm.startPrank(borrower);
        vault.approve(address(w.d.positionManager), w.units);
        w.loanId = w.d.ace.open(w.d.id, w.units, WITNESS_PRINCIPAL, 0, borrower, OpenBounds(0, 0, 0));
        vm.stopPrank();
    }

    /// @notice #353 section 4: at this `k` the sell-max rail clears by ONE WEI, and at this price the sizing returns `u == C`.
    /// @notice Every dial is admitted by `MarketInit` and `createMarket` is permissionless, so nothing but the creator's choice bars it.
    /// @notice The planner's witness was ARITHMETIC ONLY; this drives the same numbers through createMarket, a draw and a real crank.
    /// @dev What fires here is the SIZING cap; `test_ScopeCappedCrank_NoCutFallback` covers the SCOPE cap, and nothing covered this.
    /// @dev `unitsSold == collateralUnits` did not arise at the hub, and the reason is structural rather than a fixture limit.
    /// @dev Admission demands `units >= requiredAt(debt, floor) + maxClaimTicks` while `securedBase` caps at `requiredAt`, so base < units at open.
    /// @dev Either arm leaves `charge` false, so the no-cut melt is unchanged whichever cap fires.
    /// @dev The cap now also withholds what settlement needs, so the crank melts debt WITHOUT repaying and the loan stays open.
    /// @dev That is the point of the reserve: a sell-max sizing may not sell the units a settlement would have to pay claims with.
    /// @dev `base` here is bare `requiredAt` and is only an UPPER bound; re-deriving the cap exactly would mirror hub logic and drift.
    function test_SellMaxWitness_SizingReturnsWholeCollateral_NoCutAndFullMelt() public {
        Witness memory w = _witness();
        assertEq(w.d.read.triggerPrice(w.loanId), WITNESS_TRIG, "fixture: the loan's trigger is not the witness trigger");
        assertGe(w.d.read.fundingFloor(w.d.id, w.loanId), WITNESS_TRIG, "fixture: the funding floor sits under the witness trigger");
        assertEq(_sizeExpected(w.units, WITNESS_TRIG, WITNESS_PS, WITNESS_K, WITNESS_EPS, WITNESS_CUT), w.units, "the sizing did not ask for u == C");

        w.rec.setBelowBand(FullMath.mulDivRoundingUp(WITNESS_TRIG, 1e18, 1e18 - BAND_BPS * 1e14));
        w.rec.setMinPrice(WITNESS_PS);
        /// @dev bare `requiredAt`, an UPPER bound on what the scope cap allows -- never a mirror of `securedBase`
        /// @dev the cap subtracts the settlement reserve from this, so re-deriving the exact value here would drift
        uint256 base = FullMath.mulDivRoundingUp(WITNESS_K * w.d.read.loan(w.loanId).debt, UNIT_SCALE, w.d.read.fundingFloor(w.d.id, w.loanId) * 1e18);
        uint256 rev0 = w.d.read.protocolRevenue(w.d.id);
        uint256 debt0 = w.d.read.loan(w.loanId).debt;

        (uint256 sold, uint256 out) = w.keep.crankDeleverage(w.loanId);
        emit log_named_uint("witness collateral units held", w.units);
        emit log_named_uint("witness collateral units sold", sold);
        emit log_named_uint("witness proceeds", out);
        /// @dev WAS a STRICT `assertLt`. `securedBase` is `min(requiredAt, units - keep)`, and `keep` carries
        /// @dev the coverage line's epsilon -- which was `maxClaimTicks` atoms and is ONE now. So `sellable`
        /// @dev grew and `requiredAt` became the binding term rather than the slack one: the cap lands ON the
        /// @dev debt-securing units instead of a whole ladder's worth under them. The bound is what matters.
        assertLe(sold, base, "the scope cap did not hold the sale to the debt-securing units");
        assertLt(sold, w.units, "unitsSold reached collateralUnits: the coverage line's dust reserve stopped being structural");
        assertEq(w.d.read.protocolRevenue(w.d.id), rev0, "a crank that could not restore took a protocol cut");
        assertLt(w.d.read.loan(w.loanId).debt, debt0, "the crank melted no debt at all");
        assertEq(w.d.read.loan(w.loanId).closedAt, 0, "the reserved crank closed the loan: settlement's units were sold after all");
    }

    // ============ H8: a partially-filled fully-restoring crank still pays the restore-priced cut ============

    /// @dev One leg of the differential, measured rather than derived: four quantities plus what the FIRST crank alone did.
    struct Leg {
        uint256 relief; // debt melted across the whole walk
        uint256 revenue; // cumulative protocolRevenue the walk accrued
        uint256 units; // collateral units sold, net of every re-credited tail
        uint256 keeperEps; // the keeper's total eps take, which rides on units FILLED
        uint256 cranks; // how many cranks the walk took
        uint256 trigEnd; // the trigger the walk finished at
        uint256 firstRevenue; // the cut the FIRST crank took, before any re-crank
        uint256 trigAfterFirst; // the trigger after that first crank: an under-restore leaves it above target
    }

    /// @dev A price in the LOWER fifth of the operating band, so a half fill still leaves the loan in band for a second crank.
    function _lowBandPs(uint256 loanId) internal view returns (uint256) {
        uint256 stop = _stopLevel(loanId);
        return stop + (_bandLevel(loanId) - stop) / 5;
    }

    /// @dev Walk the loan to target at a fixed `ps`, refusing `firstRefundBps` of the FIRST crank's release and filling the rest whole.
    /// @dev The band is re-checked against `ps` before every crank, so the mock's flag never claims a band the price is not in.
    function _walkToTarget(uint256 loanId, uint256 ps, uint256 firstRefundBps) private returns (Leg memory g) {
        uint256 debt0 = read.loan(loanId).debt;
        uint256 coll0 = read.loan(loanId).collateralUnits;
        uint256 rev0 = read.protocolRevenue(id);
        uint256 keep0 = usdc.balanceOf(address(keeper));
        keeper.setRoutePrice(ps);
        keeper.setRefundBps(firstRefundBps);
        for (uint256 i; i < 8; ++i) {
            if (ps >= _bandLevel(loanId) || ps <= _stopLevel(loanId)) break; // out of the operating band: the walk is done
            _arm(loanId, ps);
            (uint256 sold,) = keeper.crankDeleverage(loanId);
            keeper.setRefundBps(0); // only the FIRST crank is partially filled
            g.cranks++;
            if (g.cranks == 1) (g.firstRevenue, g.trigAfterFirst) = (read.protocolRevenue(id) - rev0, read.triggerPrice(loanId));
            if (sold == 0) break;
        }
        g.relief = debt0 - read.loan(loanId).debt;
        g.units = coll0 - read.loan(loanId).collateralUnits;
        g.revenue = read.protocolRevenue(id) - rev0;
        g.keeperEps = usdc.balanceOf(address(keeper)) - keep0;
        g.trigEnd = read.triggerPrice(loanId);
    }

    /// @notice #353 section 4: `charge` is decided BEFORE the sale and `_dispose` reassigns `unitsSold` after it.
    /// @notice So a keeper that partially fills a fully-restoring crank misses target and still pays the restore-priced cut.
    /// @notice A DIFFERENTIAL, not an assertion about one crank: one full fill against a half fill walked on to target, from one snapshot.
    /// @dev The open question this sizes: each partial crank pays the cut, and the cut enlarges every re-derived sizing.
    /// @dev MEASURED: the split leg sells 1.3e12 wei FEWER units of 4.302e21 (3e-10 relative), and melts ONE wei less debt.
    /// @dev Cumulative protocol revenue and the keeper's eps take come back IDENTICAL to the wei across the two legs.
    /// @dev So there is no second-order channel to bound by `N*cut`: the sizing is exact, so a walk in N steps composes to one step.
    /// @dev The finding is therefore a mis-classified fee event and a comment defect, with no borrower cost past a wei of rounding.
    /// @dev The keeper cannot profit either: `_owed` prices what FILLED, so a smaller fill earns strictly less eps.
    function test_PartialFillOfARestoringCrank_DifferentialAgainstOneFullFill() public {
        uint256 loanId = _open();
        uint256 ps = _lowBandPs(loanId);
        uint256 tStar = (ps * (1e18 - TARGET_BPS * 1e14)) / 1e18;

        uint256 snap = vm.snapshotState();
        Leg memory whole = _walkToTarget(loanId, ps, 0);
        vm.revertToState(snap);
        Leg memory split = _walkToTarget(loanId, ps, 5000);

        emit log_named_uint("full fill: units sold", whole.units);
        emit log_named_uint("full fill: debt relief", whole.relief);
        emit log_named_uint("full fill: protocol revenue", whole.revenue);
        emit log_named_uint("full fill: keeper eps", whole.keeperEps);
        emit log_named_uint("full fill: cranks", whole.cranks);
        emit log_named_uint("half fill then walk: units sold", split.units);
        emit log_named_uint("half fill then walk: debt relief", split.relief);
        emit log_named_uint("half fill then walk: protocol revenue", split.revenue);
        emit log_named_uint("half fill then walk: keeper eps", split.keeperEps);
        emit log_named_uint("half fill then walk: cranks", split.cranks);

        assertGt(whole.units, 0, "fixture: the full-fill leg sold nothing, so there is no differential");
        assertEq(whole.cranks, 1, "fixture: the full-fill leg was meant to reach target in ONE crank");
        assertGt(split.cranks, whole.cranks, "fixture: the half fill did not force a second crank, so it did not under-restore");
        assertGt(split.firstRevenue, 0, "the partially-filled crank took NO cut: the charge-before-the-sale defect is gone");
        assertGt(split.trigAfterFirst, tStar + 1, "fixture: the half-filled crank reached target, so its cut was not restore-priced");
        assertLe(whole.trigEnd, tStar + 1, "the full-fill leg did not reach target");
        assertLe(split.trigEnd, tStar + 1, "the split leg did not reach target");

        assertLe(split.units, whole.units, "the split walk sold MORE units: the second-order channel this differential sizes is real");
        assertApproxEqRel(split.units, whole.units, 1e10, "the two walks stopped composing: the split leg is no longer within rounding");
        assertApproxEqAbs(split.relief, whole.relief, 2, "the borrower's debt relief now differs by more than rounding between the legs");
        assertEq(split.revenue, whole.revenue, "the split walk paid a different total cut: the cut stopped being scale-free in N");
        assertEq(split.keeperEps, whole.keeperEps, "the keeper's eps take moved with the fill schedule, so splitting fills is now payable");
    }
}
