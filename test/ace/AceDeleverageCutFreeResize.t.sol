// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.36;

import {Test} from "forge-std/Test.sol";
import {FullMath} from "@uniswap/v4-core/src/libraries/FullMath.sol";
import {Ace} from "../../src/ace/hub/Ace.sol";
import {AceLens} from "../../src/ace/lens/AceLens.sol";
import {Constants} from "../../src/ace/hub/Constants.sol";
import {MarketParams, OpenBounds} from "../../src/ace/hub/Types.sol";
import {NotInBand} from "../../src/ace/hub/Deleverage.sol";
import {PositionManager} from "../../src/ace/positions/PositionManager.sol";
import {MockERC20} from "../mocks/MockERC20.sol";
import {MockPersistenceRecord} from "../mocks/MockPersistenceRecord.sol";
import {MockDeleverageKeeper} from "../mocks/MockDeleverageKeeper.sol";
import {MockStakeVault} from "../mocks/MockStakeVault.sol";
import {AceFixtures} from "../utils/AceFixtures.sol";
import {AceReader} from "../utils/AceReader.sol";

/// @title AceDeleverageCutFreeResizeTest
/// @notice #413: a crank whose cut-charging restore does not fit under its caps re-sizes CUT-FREE, then caps.
/// @notice It sells `u` and takes the cut when `u < C` and `u <= min(securedBase, room)`; otherwise `min(free, that cap)`, with no cut.
/// @dev `free` is the restore sized with no cut: the cut multiplies the sale, so a crank that takes none must not be sized as if it did.
/// @dev "No cut" is read off the DEBT, `debt drop == stableOut`, never off `protocolRevenue`: the crank piggybacks the revenue sweep.
contract AceDeleverageCutFreeResizeTest is Test {
    /// @dev Which branch one crank took, so the anti-vacuity count can tell the three apart.
    enum Arm {
        Refused, // genesis refused the draw, the sizing asked for nothing, or nothing sold
        Charged, // `u` fit under both caps: the restore sold whole and took its cut
        Resized, // `u` did not fit and the cut-free restore did: it sold `free` and took no cut
        Capped // not even `free` fit: it sold the cap and took no cut
    }

    /// @dev One crank's inputs and the figures it is held to, every one read BEFORE the crank runs.
    struct Run {
        uint256 loanId;
        uint256 cut; // the market's deleverage cut, bps
        uint256 minDebt;
        uint256 units; // collateral held before the crank
        uint256 debt; // debt before the crank
        uint256 u; // the restore sized WITH the cut
        uint256 free; // the restore sized with NO cut
        uint256 base; // `securedBase`
        uint256 room; // the `minDebt` cap's room
        uint256 cap; // min(base, room)
    }

    Ace internal ace;
    PositionManager internal positionManager;
    AceReader internal read;
    AceLens internal lens;
    MockERC20 internal usdc;
    MockStakeVault internal vault;
    MockPersistenceRecord internal record;
    MockDeleverageKeeper internal keeper;

    address internal borrower = address(0xB0B);
    address internal stranger = address(0x5157);

    uint256 internal constant COLL = 10_000e18;
    uint256 internal constant LADDER = 20_000e6;
    uint256 internal constant UNIT_SCALE = 1 << 96; // every market's scale under the atom frame

    uint256 internal constant WITNESS_K = 1147959183673469390; // the sell-max rail clears by exactly one wei at eps 200, cut 2000, stop 1000
    uint256 internal constant WITNESS_PS = 10000000000000001; // one wei above the stop level the witness trigger implies
    uint256 internal constant WITNESS_TRIG = 9e15; // the largest trigger the stop gate admits at that price, and the sizing lands on it
    uint256 internal constant WITNESS_PRINCIPAL = 78_400_000;

    function setUp() public {
        vm.warp(1_000_000);
        usdc = new MockERC20("USD Coin", "USDC", 6);
        vault = new MockStakeVault(42);
        record = new MockPersistenceRecord(address(usdc), address(vault));
        (ace, positionManager) = AceFixtures.newAceWithEscrow(AceFixtures.TREASURY);
        read = new AceReader(address(ace));
        lens = new AceLens(address(ace));
        keeper = new MockDeleverageKeeper(ace, address(usdc), address(vault), UNIT_SCALE);
    }

    /* ============================== the fixture ============================== */

    /// @dev The PoC deploy's decline dials on this suite's pair: k 1.4, eps 100, band 3000, target 5000, stop 1000, cut 500.
    function _shipped() internal view returns (MarketParams memory p) {
        p = AceFixtures.marketParams(address(usdc), address(vault));
        p.record = address(record);
        p.minCoverageWad = 1.4e18;
        p.deleverageFloorEpsBps = 100;
        (p.deleverageBandBps, p.deleverageTargetBps, p.deleverageStopBps, p.deleverageProtocolBps) = (3000, 5000, 1000, 500);
    }

    /// @dev Create `p`'s market on the shared hub and seed its lender; false when genesis refuses it.
    /// @dev The record is reset first: a row that armed an earlier loan left it under this market's price, where cash cannot rest or lend.
    function _create(MarketParams memory p) internal returns (bool ok, bytes32 mid) {
        record.setBandPrice(0);
        record.setMinPrice(AceFixtures.px(2e18, address(usdc), address(vault))); // above every market's price here
        bytes memory ret;
        (ok, ret) = address(ace).call(abi.encodeCall(Ace.createMarket, (p)));
        if (!ok) return (false, mid);
        mid = abi.decode(ret, (bytes32));
        usdc.mint(AceFixtures.LENDER, LADDER);
        vm.startPrank(AceFixtures.LENDER);
        usdc.approve(address(ace), LADDER);
        ace.deposit(mid, LADDER);
        vm.stopPrank();
    }

    /// @dev `pct` percent of the largest draw `COLL` carries at par at this `k`.
    function _gate(uint256 k, uint256 pct) internal pure returns (uint256) {
        return ((COLL * 1e6) / k) * pct / 100;
    }

    function _open(bytes32 mid, uint256 units, uint256 principal) internal returns (uint256 loanId) {
        vault.mint(borrower, units);
        vm.startPrank(borrower);
        vault.approve(address(positionManager), units);
        loanId = ace.open(mid, units, principal, 0, borrower, OpenBounds(0, 0, 0));
        vm.stopPrank();
    }

    /// @dev The record persists at `ps` and the band rests ON it: in band while `bandLevel > ps`, distressed only if `trig > ps`.
    function _arm(uint256 ps) internal {
        record.setBandPrice(ps);
        record.setMinPrice(ps);
    }

    function _level(uint256 trig, uint256 bps) internal pure returns (uint256) {
        return FullMath.mulDivRoundingUp(trig, 1e18, 1e18 - bps * 1e14);
    }

    function _pick(uint256 seed, uint256 k, uint256 lo, uint256 hi) internal pure returns (uint256) {
        return lo + (uint256(keccak256(abi.encode(seed, k))) % (hi - lo + 1));
    }

    /* ============================== the twins ============================== */

    /// @dev `Deleverage`'s restore sizing re-spelled at a chosen cut; a `cut` of 0 is the cut-free restore, bit for bit.
    function _sizing(MarketParams memory p, uint256 cut, uint256 units, uint256 trig, uint256 ps) internal pure returns (uint256) {
        uint256 tStar = FullMath.mulDiv(ps, 1e18 - p.deleverageTargetBps * 1e14, 1e18);
        if (trig <= tStar) return 0;
        uint256 y = FullMath.mulDiv(ps, p.minCoverageWad * (10000 - p.deleverageFloorEpsBps), 1e22);
        uint256 u = FullMath.mulDiv(units, trig - tStar, FullMath.mulDiv(y, 10000 - cut, 10000) - tStar);
        return u > units ? units : u;
    }

    /// @dev `LoanAccounting.securedBase` re-spelled: `min(requiredAt(debt, floor), units - collateralNeeded - sliver)`.
    /// @dev `collateralNeeded` is the lens's; `requiredAt` and the sliver are transcribed, so re-read them when the hub's change.
    function _securedBase(bytes32 mid, uint256 loanId, MarketParams memory p) internal view returns (uint256) {
        uint256 debt = read.loan(loanId).debt;
        uint256 units = read.loan(loanId).collateralUnits;
        uint256 req = FullMath.mulDivRoundingUp(p.minCoverageWad * debt, UNIT_SCALE, p.price * 1e18);
        uint256 sliver = FullMath.mulDiv(debt * p.settleBountyBps, UNIT_SCALE, 10000 * p.price);
        uint256 keep = lens.collateralNeeded(mid, loanId) + (sliver < units ? sliver : units);
        uint256 sellable = units > keep ? units - keep : 0;
        return req < sellable ? req : sellable;
    }

    /// @dev Every figure one crank is held to, read before it runs; the `minDebt` room is the exact inverse of `_owed`.
    function _read(bytes32 mid, uint256 loanId, MarketParams memory p, uint256 ps) internal view returns (Run memory r) {
        (r.loanId, r.cut, r.minDebt) = (loanId, p.deleverageProtocolBps, p.minDebt);
        r.units = read.loan(loanId).collateralUnits;
        r.debt = read.loan(loanId).debt;
        uint256 trig = read.triggerPrice(loanId);
        r.u = _sizing(p, p.deleverageProtocolBps, r.units, trig, ps);
        r.free = _sizing(p, 0, r.units, trig, ps);
        r.base = _securedBase(mid, loanId, p);
        r.room = FullMath.mulDiv(r.debt > p.minDebt ? r.debt - p.minDebt : 0, 10000 * UNIT_SCALE, ps * (10000 - p.deleverageFloorEpsBps));
        r.cap = r.base < r.room ? r.base : r.room;
    }

    /* ============================== THE PROPERTY ============================== */

    /// @dev The whole admitted box with the cut never zero, the opening slack and `minDebt` drawn too, so every cap gets its turn.
    /// @dev FROZEN SAMPLER: the arm count reads these draws, so reach a rare arm by widening a range, never by biasing one.
    function _drawParams(uint256 seed) internal view returns (MarketParams memory p, uint256 principal) {
        p = AceFixtures.marketParams(address(usdc), address(vault));
        p.record = address(record);
        p.minCoverageWad = _pick(seed, 1, Constants.MIN_COVERAGE_WAD, Constants.MAX_COVERAGE_WAD);
        p.deleverageFloorEpsBps = _pick(seed, 2, 1, Constants.MAX_DELEVERAGE_FLOOR_EPS_BPS);
        p.deleverageBandBps = _pick(seed, 3, Constants.MIN_DELEVERAGE_BAND_BPS, 9000);
        p.deleverageTargetBps = _pick(seed, 4, p.deleverageBandBps + 1, 9999);
        p.deleverageStopBps = _pick(seed, 5, 1, p.deleverageBandBps - 1);
        p.deleverageProtocolBps = _pick(seed, 6, 1, Constants.MAX_DELEVERAGE_PROTOCOL_BPS);
        principal = _gate(p.minCoverageWad, _pick(seed, 7, 30, 97));
        p.minDebt = _pick(seed, 8, 0, 1) == 0 ? 2 : _pick(seed, 9, 2, (principal * 95) / 100);
    }

    /// @dev One drawn market, one loan on it, the record parked anywhere strictly between its stop and band levels.
    function _setUpDraw(uint256 seed) internal returns (bool ok, Run memory r) {
        (MarketParams memory p, uint256 principal) = _drawParams(seed);
        bytes32 mid;
        (ok, mid) = _create(p);
        if (!ok) return (false, r);
        uint256 loanId = _open(mid, COLL, principal);
        uint256 trig = read.triggerPrice(loanId);
        uint256 ps = _pick(seed, 10, _level(trig, p.deleverageStopBps) + 1, _level(trig, p.deleverageBandBps) - 1);
        _arm(ps);
        r = _read(mid, loanId, p, ps);
    }

    /// @dev ONE body, so the fuzz row and the anti-vacuity count can never exercise different code.
    /// @dev The five properties come first and the exact figure last: the cut-free leg is the property, the figure ties the twins to the hub.
    function _crankOnce(uint256 seed) internal returns (Arm) {
        (bool ok, Run memory r) = _setUpDraw(seed);
        if (!ok) return Arm.Refused; // a config genesis refuses is `AceGenesisRails`' subject, not this one
        if (r.u == 0) return Arm.Refused; // at or above target, or a dust restore: the crank returns before any cap is read
        bool charge = r.u < r.units && r.u <= r.cap;
        (uint256 sold, uint256 out) = keeper.crankDeleverage(r.loanId);
        _assertProperties(r, charge, sold, out);
        assertEq(sold, charge ? r.u : (r.free < r.cap ? r.free : r.cap), "the hub sold something other than the cut-free re-size predicts");
        if (sold == 0) return Arm.Refused;
        if (charge) return Arm.Charged;
        return r.free <= r.cap ? Arm.Resized : Arm.Capped;
    }

    /// @dev The review's five, plus a bound against the pre-#413 sale `min(u, cap)`, transcribed so the change can only ever shrink a sale.
    function _assertProperties(Run memory r, bool charge, uint256 sold, uint256 out) internal view {
        uint256 debtAfter = read.loan(r.loanId).debt;
        uint256 cutPaid = charge ? FullMath.mulDiv(out, r.cut, 10000) : 0;
        assertEq(r.debt - debtAfter, out - cutPaid, "(i) the cut is charged exactly when u < C and u fits under min(securedBase, room)");
        assertLe(sold, r.cap, "(ii) the sale never passes min(securedBase, room)");
        if (!charge) assertLe(sold, r.free, "(iii) a crank that takes no cut never sells more than the cut-free restore");
        assertGe(debtAfter, r.minDebt, "(iv) the debt never lands under minDebt");
        if (sold > 0) assertLt(debtAfter * r.units, r.debt * read.loan(r.loanId).collateralUnits, "(v) every crank that sells lowers D/C");
        assertLe(sold, r.u < r.cap ? r.u : r.cap, "the sale never exceeds what today's min(u, cap) sold");
        assertEq(r.units - read.loan(r.loanId).collateralUnits, sold, "the collateral debit is exactly the units the crank reports sold");
    }

    /// @notice THE PROPERTY, sampled over the admitted box with a non-zero cut: a crank that takes no cut never out-sells the cut-free restore.
    function testFuzz_ACutFreeCrankNeverSellsMoreThanTheCutFreeRestore(uint256 seed) public {
        _crankOnce(seed);
    }

    /// @notice A sweep that never reaches an arm asserts nothing about it, so all three are counted, deterministically.
    /// @dev Same body as the fuzz row, so a sampler that stops reaching an arm fails here by name instead of going green.
    function test_TheFuzzBodyReachesEveryArm() public {
        uint256[4] memory hits;
        for (uint256 s = 1; s <= 64; ++s) {
            uint256 snap = vm.snapshotState();
            ++hits[uint256(_crankOnce(s))];
            vm.revertToState(snap);
        }
        emit log_named_uint("cranks that took the cut, of 64", hits[uint256(Arm.Charged)]);
        emit log_named_uint("cranks re-sized to the cut-free restore, of 64", hits[uint256(Arm.Resized)]);
        emit log_named_uint("cranks that sold the cap, of 64", hits[uint256(Arm.Capped)]);
        assertGt(hits[uint256(Arm.Charged)], 0, "the body never reached a crank that takes the cut");
        assertGt(hits[uint256(Arm.Resized)], 0, "the body never reached a crank that re-sizes cut-free");
        assertGt(hits[uint256(Arm.Capped)], 0, "the body never reached a crank whose cap is under the cut-free restore");
        emit log_named_uint("draws that cranked nothing, of 64", hits[uint256(Arm.Refused)]);
        assertLe(hits[uint256(Arm.Refused)], 8, "over an eighth of the draws assert nothing: the fuzz row is going vacuous");
    }

    /* ============================== THE SIZING CAP: u == C ============================== */

    /// @notice THE SIZING CAP: at the sell-max rail's one-wei edge the sizing asks for the whole position, `u == C`.
    /// @notice That crank cannot restore with the cut, so it re-sizes cut-free and sells `min(free, cap)`; here the cut-free restore fits.
    /// @dev The witness of `AceDeleverageActivation`, moved twice so `free < cap`: target one notch over the band, and the market at ~1.87x the trigger.
    /// @dev The target shrinks `free` to ~0.47 C; the price grows `securedBase` toward its peak, `C k / (k + 1)` at `trig / floor = k / (k + 1)`.
    /// @dev The coverage-erosion rail-edge fixture cannot show this: its sizing is ~0.9996 C, not C, and its `free` (~0.52 C) tops its peak base (~0.512 C).
    function test_SizingCap_UEqualsC_ResizesCutFree() public {
        MarketParams memory p = _shipped();
        p.minCoverageWad = WITNESS_K;
        (p.deleverageFloorEpsBps, p.deleverageProtocolBps) = (200, 2000);
        (p.deleverageBandBps, p.deleverageTargetBps, p.deleverageStopBps) = (3000, 3001, 1000);
        p.price = FullMath.mulDiv(WITNESS_TRIG, 1e18, 0.5345e18);
        (bool ok, bytes32 mid) = _create(p);
        assertTrue(ok, "PREMISE: genesis admits the witness dials, the sell-max rail by one wei");
        uint256 loanId = _open(mid, FullMath.mulDivRoundingUp(WITNESS_K * WITNESS_PRINCIPAL, UNIT_SCALE, WITNESS_TRIG * 1e18), WITNESS_PRINCIPAL);
        assertEq(read.triggerPrice(loanId), WITNESS_TRIG, "PREMISE: the loan's trigger is the witness trigger");
        _arm(WITNESS_PS);
        Run memory r = _read(mid, loanId, p, WITNESS_PS);
        assertEq(r.u, r.units, "PREMISE: the sizing asks for the whole position, u == C");
        assertLt(r.free, r.cap, "PREMISE: and the cut-free restore fits under min(securedBase, room)");

        (uint256 sold, uint256 out) = keeper.crankDeleverage(loanId);
        assertEq(sold, r.free, "the sizing cap re-sized cut-free: it sold min(free, cap), not the whole secured base");
        assertEq(r.debt - read.loan(loanId).debt, out, "and took no cut: every wei of proceeds melted debt");
        uint256 tStar = FullMath.mulDiv(WITNESS_PS, 1e18 - p.deleverageTargetBps * 1e14, 1e18);
        assertApproxEqRel(read.triggerPrice(loanId), tStar, 1e12, "a cut-free restore lands the trigger on target");
    }

    /* ============================== CONTROLS ============================== */

    /// @dev One market at `p`, one loan of `COLL` at `principal`, armed at margin `thetaWad`, read, then cranked once.
    function _crankAtTheta(MarketParams memory p, uint256 principal, uint256 thetaWad) internal returns (Run memory r, uint256 sold, uint256 out) {
        (bool ok, bytes32 mid) = _create(p);
        assertTrue(ok, "PREMISE: genesis admits the row's dials");
        uint256 loanId = _open(mid, COLL, principal);
        uint256 ps = FullMath.mulDiv(read.triggerPrice(loanId), 1e18, thetaWad);
        _arm(ps);
        r = _read(mid, loanId, p, ps);
        (sold, out) = keeper.crankDeleverage(loanId);
    }

    /// @notice CONTROL: when even the cut-free restore does not fit, the crank sells the cap, exactly as before #413, with no cut.
    /// @dev Two legs at the PoC dials and theta 0.85: the `minDebt` room binds the first, the settlement reserve the second.
    function test_Control_ACapUnderTheCutFreeRestoreStillSellsTheCap() public {
        MarketParams memory p = _shipped();
        uint256 principal = _gate(p.minCoverageWad, 50);
        p.minDebt = principal / 2;
        (Run memory r, uint256 sold, uint256 out) = _crankAtTheta(p, principal, 0.85e18);
        assertLt(r.room, r.free, "PREMISE: the minDebt room is under the cut-free restore");
        assertLt(r.room, r.base, "PREMISE: and under the secured base, so the room is the cap");
        assertEq(sold, r.room, "a room under the cut-free restore is what sells");
        assertEq(r.debt - read.loan(r.loanId).debt, out, "with no cut: every wei of proceeds melted debt");
        assertEq(read.loan(r.loanId).debt, p.minDebt, "and the debt lands ON minDebt: one unit is worth under a quote atom here");

        p = _shipped();
        (r, sold, out) = _crankAtTheta(p, _gate(p.minCoverageWad, 97), 0.85e18);
        assertLt(r.base, r.free, "PREMISE: near the coverage line the secured base is under the cut-free restore");
        assertLt(r.base, r.room, "PREMISE: and under the room, so the reserve is the cap");
        assertEq(sold, r.base, "the secured base is what sells");
        assertEq(r.debt - read.loan(r.loanId).debt, out, "with no cut: every wei of proceeds melted debt");
    }

    /// @notice O40, DISCLOSED: an under-filled crank that lifts the loan out of the band stands the channel down short of target.
    /// @notice A stranger's `repay` of the same melt does the same and lifts it further: `k(D-X)/C < k(D-X)/(C-f)`, `f` the units sold.
    /// @dev So a partial fill buys the borrower nothing that a repay, permissionless above `minDebt`, does not already buy.
    /// @dev The channel can reopen as soon as the trailing window clears the new band level; one fixed record here shows the stand-down only.
    function test_ABandLiftingPartialStandsDownLikeTheEquivalentRepay() public {
        MarketParams memory p = _shipped();
        (bool ok, bytes32 mid) = _create(p);
        assertTrue(ok, "PREMISE: genesis admits the PoC dials");
        uint256 loanId = _open(mid, COLL, _gate(p.minCoverageWad, 50));
        uint256 ps = FullMath.mulDiv(read.triggerPrice(loanId), 1e18, 0.705e18); // just inside the band, which opens at theta 0.70
        _arm(ps);
        uint256 debt0 = read.loan(loanId).debt;
        uint256 snap = vm.snapshotState();

        keeper.setRefundBps(5000);
        keeper.crankDeleverage(loanId);
        uint256 melt = debt0 - read.loan(loanId).debt;
        uint256 trigCrank = read.triggerPrice(loanId);
        assertGt(melt, 0, "PREMISE: the half fill melted debt");
        assertGt(trigCrank, FullMath.mulDiv(ps, 1e18 - p.deleverageTargetBps * 1e14, 1e18) + 1, "PREMISE: and stopped short of target");
        vm.expectRevert(NotInBand.selector);
        keeper.crankDeleverage(loanId);

        vm.revertToState(snap);
        usdc.mint(stranger, melt);
        vm.startPrank(stranger);
        usdc.approve(address(ace), melt);
        ace.repay(loanId, melt);
        vm.stopPrank();
        assertGe(read.loan(loanId).debt, p.minDebt, "PREMISE: the stranger's repay leaves at least minDebt, so no borrower was needed");
        assertLt(read.triggerPrice(loanId), trigCrank, "the same melt as a repay keeps every unit, so it lifts the margin further");
        vm.expectRevert(NotInBand.selector);
        keeper.crankDeleverage(loanId);
    }

    /* ============================== THE RESERVE'S CORNER ============================== */

    /// @dev The main sampler reaches `securedBase` as the cap in ~1% of draws and never re-sizes against it, so this corner gets its own sweep.
    /// @dev Thin coverage, a draw near the coverage line, `minDebt` at dust: the settlement reserve binds and the room stays slack.
    /// @dev FROZEN SAMPLER, as `_drawParams`, whose other dials it keeps; only `k`, the draw and `minDebt` are its own.
    function _drawReserveParams(uint256 seed) internal view returns (MarketParams memory p, uint256 principal) {
        (p,) = _drawParams(seed);
        p.minCoverageWad = _pick(seed, 11, Constants.MIN_COVERAGE_WAD, 2e18);
        principal = _gate(p.minCoverageWad, _pick(seed, 12, 80, 97));
        p.minDebt = 2;
    }

    /// @dev Crank a read `Run` once, hold it to the five properties and the exact figure, and say which arm it took.
    function _crankRun(Run memory r) internal returns (Arm) {
        if (r.u == 0) return Arm.Refused;
        bool charge = r.u < r.units && r.u <= r.cap;
        (uint256 sold, uint256 out) = keeper.crankDeleverage(r.loanId);
        _assertProperties(r, charge, sold, out);
        assertEq(sold, charge ? r.u : (r.free < r.cap ? r.free : r.cap), "the hub sold something other than the cut-free re-size predicts");
        if (sold == 0) return Arm.Refused;
        if (charge) return Arm.Charged;
        return r.free <= r.cap ? Arm.Resized : Arm.Capped;
    }

    /// @dev ONE body for the reserve sweep's fuzz row and its count; true in `baseIsCap` when `securedBase`, not the room, was the cap.
    function _crankReserveOnce(uint256 seed) internal returns (Arm arm, bool baseIsCap) {
        (MarketParams memory p, uint256 principal) = _drawReserveParams(seed);
        (bool ok, bytes32 mid) = _create(p);
        if (!ok) return (Arm.Refused, false);
        uint256 loanId = _open(mid, COLL, principal);
        uint256 trig = read.triggerPrice(loanId);
        uint256 ps = _pick(seed, 10, _level(trig, p.deleverageStopBps) + 1, _level(trig, p.deleverageBandBps) - 1);
        _arm(ps);
        Run memory r = _read(mid, loanId, p, ps);
        baseIsCap = r.base <= r.room;
        arm = _crankRun(r);
    }

    /// @notice THE PROPERTY at the reserve's corner: with `securedBase` as the cap, only a restore that fits is charged, and none out-sells `free`.
    function testFuzz_AtTheReserveACutFreeCrankNeverSellsMoreThanTheCutFreeRestore(uint256 seed) public {
        _crankReserveOnce(seed);
    }

    /// @notice The reserve sweep reaches all three arms with `securedBase` as the cap, counted the same way as the main sweep.
    function test_TheReserveSweepReachesEveryArmOnTheBase() public {
        uint256[4] memory hits;
        for (uint256 s = 1; s <= 64; ++s) {
            uint256 snap = vm.snapshotState();
            (Arm arm, bool baseIsCap) = _crankReserveOnce(s);
            if (baseIsCap) ++hits[uint256(arm)];
            vm.revertToState(snap);
        }
        emit log_named_uint("base-capped draws that took the cut, of 64", hits[uint256(Arm.Charged)]);
        emit log_named_uint("base-capped draws re-sized cut-free, of 64", hits[uint256(Arm.Resized)]);
        emit log_named_uint("base-capped draws that sold the base, of 64", hits[uint256(Arm.Capped)]);
        assertGt(hits[uint256(Arm.Charged)], 0, "the sweep never charged a restore that fit under the base");
        assertGt(hits[uint256(Arm.Resized)], 0, "the sweep never re-sized a restore the base refused");
        assertGt(hits[uint256(Arm.Capped)], 0, "the sweep never reached a base under the cut-free restore");
    }

    /* ============================== THE BASE'S EDGE ============================== */

    /// @dev One q18/c6 market on the shared hub, its record, its keeper, and one loan on it.
    struct Q18 {
        bytes32 mid;
        uint256 loanId;
        MarketParams p;
        MockPersistenceRecord rec;
        MockDeleverageKeeper k;
    }

    /// @dev The PoC dials on a q18/c6 pair with `minDebt` at dust, and a 20-quote loan whose trigger sits at `thetaBps` of par.
    /// @dev One wei of price moves this pair's sizing by far under one c6 unit, so a record price can land `u` on any count.
    function _q18Loan(uint256 thetaBps) internal returns (Q18 memory s) {
        MockERC20 q = new MockERC20("Q18", "Q18", 18);
        MockERC20 c6 = new MockERC20("C6", "C6", 6);
        s.rec = new MockPersistenceRecord(address(q), address(c6));
        MarketParams memory p = AceFixtures.marketParams(address(q), address(c6));
        p.record = address(s.rec);
        p.minCoverageWad = 1.4e18;
        p.deleverageFloorEpsBps = 100;
        (p.deleverageBandBps, p.deleverageTargetBps, p.deleverageStopBps, p.deleverageProtocolBps) = (3000, 5000, 1000, 500);
        p.minDebt = 2;
        s.rec.setMinPrice(2 * p.price); // above the market, so the ladder lends
        s.mid = ace.createMarket(p);
        s.p = ace.idToMarketParams(s.mid);
        q.mint(AceFixtures.LENDER, 1_000e18);
        vm.startPrank(AceFixtures.LENDER);
        q.approve(address(ace), 1_000e18);
        ace.deposit(s.mid, 1_000e18);
        vm.stopPrank();
        uint256 units = FullMath.mulDiv(1.4e18 * 20e18, UNIT_SCALE * 10000, thetaBps * p.price * 1e18);
        c6.mint(borrower, units);
        vm.startPrank(borrower);
        c6.approve(address(positionManager), units);
        s.loanId = ace.open(s.mid, units, 20e18, 0, borrower, OpenBounds(0, 0, 0));
        vm.stopPrank();
        s.k = new MockDeleverageKeeper(ace, address(q), address(c6), UNIT_SCALE);
    }

    /// @dev The lowest in-band record price at which the cut-charging restore sizes to at most `want`: the sizing falls as the price rises.
    function _priceSizingAtMost(MarketParams memory p, uint256 units, uint256 trig, uint256 want) internal pure returns (uint256 lo) {
        lo = _level(trig, p.deleverageStopBps) + 1;
        uint256 hi = _level(trig, p.deleverageBandBps) - 1;
        while (lo < hi) {
            uint256 m = lo + (hi - lo) / 2;
            if (_sizing(p, p.deleverageProtocolBps, units, trig, m) <= want) hi = m;
            else lo = m + 1;
        }
    }

    /// @dev Park `s`'s record at `ps`, in band and clear of distress, and read the crank's figures there.
    function _armQ18(Q18 memory s, uint256 ps) internal returns (Run memory r) {
        s.rec.setBandPrice(ps);
        s.rec.setMinPrice(ps);
        r = _read(s.mid, s.loanId, s.p, ps);
    }

    /// @notice THE BASE'S EDGE IS STRICT, a second pin of `u <= cap` from the other cap: a restore of exactly `securedBase` units keeps its cut.
    /// @notice One unit more and it no longer fits: the crank re-sizes to the cut-free restore and takes no cut.
    /// @dev `AceDeleverageMinDebtCap` pins the room's edge on another pair; here `minDebt` is dust, so the settlement reserve is the cap.
    /// @dev One loan, two record prices: `securedBase` does not read the record, so only the sizing moves between the legs.
    function test_BaseEdge_ARestoreOfExactlyTheBaseKeepsItsCut_OneUnitMoreResizes() public {
        Q18 memory s = _q18Loan(8500);
        uint256 units = read.loan(s.loanId).collateralUnits;
        uint256 trig = read.triggerPrice(s.loanId);
        uint256 base = _securedBase(s.mid, s.loanId, s.p);
        uint256 snap = vm.snapshotState();

        Run memory r = _armQ18(s, _priceSizingAtMost(s.p, units, trig, base));
        assertEq(r.u, base, "PREMISE: the record lands the cut-charging restore on exactly the secured base");
        assertEq(r.base, base, "PREMISE: and the base did not move with the record");
        assertLt(r.base, r.room, "PREMISE: the base, not the room, is the cap");
        (uint256 sold, uint256 out) = s.k.crankDeleverage(s.loanId);
        uint256 cut = FullMath.mulDiv(out, 500, 10000);
        assertGt(cut, 0, "PREMISE: the cut is not rounded away");
        assertEq(sold, base, "u == securedBase fits: the whole restore sells");
        assertEq(r.debt - read.loan(s.loanId).debt, out - cut, "and `charge` holds at u == cap: the cut came off the proceeds");

        vm.revertToState(snap);
        r = _armQ18(s, _priceSizingAtMost(s.p, units, trig, base + 1));
        assertEq(r.u, base + 1, "PREMISE: the record lands the cut-charging restore one unit over the secured base");
        assertLt(r.free, base, "PREMISE: and the cut-free restore fits under it");
        (sold, out) = s.k.crankDeleverage(s.loanId);
        assertEq(sold, r.free, "u == cap + 1 does not fit: the crank re-sizes to the cut-free restore, not the base");
        assertEq(r.debt - read.loan(s.loanId).debt, out, "and takes no cut: every wei of proceeds melted debt");
    }

    /* ============================== HUB AND SIM, ONE FIXTURE ============================== */

    uint256 internal constant SIM_U = 2899989044485832172553; // the cut-charging restore at the sim fixture
    uint256 internal constant SIM_OUT_U = 2727439697; // its proceeds at the eps-discounted 0.95
    uint256 internal constant SIM_DEBT_U = 2408932287; // 5000e6 less the proceeds net of the 500 bps cut
    uint256 internal constant SIM_FREE = 2673161458952120902443; // the cut-free restore at the same fixture
    uint256 internal constant SIM_OUT_FREE = 2514108353; // its proceeds
    uint256 internal constant SIM_MIN_DEBT_RESIZED = 2379225975; // 5000e6 less the mean of the two proceeds: a head between the restores

    /// @dev The sim's `ledger_delev(.., cut 500)` fixture on the hub: the PoC dials, the market bidding at exactly 1.0, the record at 0.95.
    function _simFixture(uint256 minDebt) internal returns (bytes32 mid, uint256 loanId, MarketParams memory p) {
        p = _shipped();
        p.price = AceFixtures.px(1e18, address(usdc), address(vault));
        p.settleBountyBps = 50;
        p.minDebt = minDebt;
        bool ok;
        (ok, mid) = _create(p);
        assertTrue(ok, "PREMISE: genesis admits the sim's fixture");
        loanId = _open(mid, COLL, 5_000e6);
        assertEq(read.triggerPrice(loanId), AceFixtures.px(0.7e18, address(usdc), address(vault)) + 1, "PREMISE: the sim's trigger, 0.7 plus a wei");
        _arm(AceFixtures.px(0.95e18, address(usdc), address(vault)));
    }

    /// @notice HUB AND SIM AGREE on `_fit`'s two live arms at the sim's own fixture, pinned to the literals `deleverage_hub_parity_pins` pins in the sim.
    /// @dev The record is the only floor leg at 0.95, so #498's divergence is off; neither side's base binds, so the sim's reserve-free base is moot.
    function test_SimParity_TheSimsFixtureChargesAndResizesAsTheSimDoes() public {
        (bytes32 mid, uint256 loanId, MarketParams memory p) = _simFixture(10e6);
        Run memory r = _read(mid, loanId, p, AceFixtures.px(0.95e18, address(usdc), address(vault)));
        assertLt(r.u, r.base, "PREMISE: the hub's secured base does not bind");
        assertLt(r.u, r.room, "PREMISE: nor does the room, at a 10 USDC minDebt");
        (uint256 sold, uint256 out) = keeper.crankDeleverage(loanId);
        assertEq(sold, SIM_U, "charged arm: units sold, as the sim pins");
        assertEq(out, SIM_OUT_U, "charged arm: proceeds, as the sim pins");
        assertEq(read.loan(loanId).debt, SIM_DEBT_U, "charged arm: debt after, net of the 500 bps cut, as the sim pins");

        (mid, loanId, p) = _simFixture(SIM_MIN_DEBT_RESIZED);
        r = _read(mid, loanId, p, AceFixtures.px(0.95e18, address(usdc), address(vault)));
        assertLt(r.free, r.room, "PREMISE: the cut-free restore fits under the room");
        assertLt(r.room, r.u, "PREMISE: and the cut-charging one does not");
        assertLt(r.room, r.base, "PREMISE: the room, not the base, is the cap");
        (sold, out) = keeper.crankDeleverage(loanId);
        assertEq(sold, SIM_FREE, "re-sized arm: units sold, as the sim pins");
        assertEq(out, SIM_OUT_FREE, "re-sized arm: proceeds, as the sim pins");
        assertEq(read.loan(loanId).debt, 5_000e6 - SIM_OUT_FREE, "re-sized arm: no cut, as the sim pins");
    }
}
