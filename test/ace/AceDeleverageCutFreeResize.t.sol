// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.36;

import {Test} from "forge-std/Test.sol";
import {FullMath} from "@uniswap/v4-core/src/libraries/FullMath.sol";
import {Ace} from "../../src/ace/hub/Ace.sol";
import {AceLens} from "../../src/ace/lens/AceLens.sol";
import {Constants} from "../../src/ace/hub/Constants.sol";
import {LoanMath} from "../../src/ace/hub/libraries/LoanMath.sol";
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
/// @notice #413: a crank whose cut-charging restore does not fit under its cap re-sizes CUT-FREE, then caps.
/// @notice It sells `u` and takes the cut when `u < C` and `u <= securedBase`; otherwise `min(free, securedBase)`, with no cut.
/// @notice Where that sale's net melt would leave the debt under its debt floor the crank closes the loan instead, selling `uClose`.
/// @dev `free` is the restore sized with no cut: the cut multiplies the sale, so a crank that takes none must not be sized as if it did.
/// @dev "No cut" is read off the DEBT, `debt drop == stableOut`, never off `protocolRevenue`: the crank piggybacks the revenue sweep.
contract AceDeleverageCutFreeResizeTest is Test {
    /// @dev Which branch one crank took, so the anti-vacuity count can tell the four apart.
    enum Arm {
        Refused, // genesis refused the draw, the sizing asked for nothing, or nothing sold
        Charged, // `u` fit under the cap: the restore sold whole and took its cut
        Resized, // `u` did not fit and the cut-free restore did: it sold `free` and took no cut
        Capped, // not even `free` fit: it sold the cap and took no cut
        Closed // the restore's net melt would have left dust: the crank sold `uClose` and closed the loan
    }

    /// @dev One crank's inputs and the figures it is held to, every one read BEFORE the crank runs.
    struct Run {
        uint256 loanId;
        uint256 cut; // the market's deleverage cut, bps
        uint256 floor; // the debt floor, half the market's `minPrincipal`
        uint256 units; // collateral held before the crank
        uint256 debt; // debt before the crank
        uint256 u; // the restore sized WITH the cut
        uint256 free; // the restore sized with NO cut
        uint256 base; // `securedBase`
        uint256 cap; // the restore's one cap, `securedBase`
        uint256 eps; // the market's floor eps, bps
        uint256 ps; // the record price the crank sizes and fills at
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

    /// @dev Every figure one crank is held to, read before it runs.
    function _read(bytes32 mid, uint256 loanId, MarketParams memory p, uint256 ps) internal view returns (Run memory r) {
        (r.loanId, r.cut, r.floor, r.eps, r.ps) = (loanId, p.deleverageProtocolBps, LoanMath.debtFloor(p.minPrincipal), p.deleverageFloorEpsBps, ps);
        r.units = read.loan(loanId).collateralUnits;
        r.debt = read.loan(loanId).debt;
        uint256 trig = read.triggerPrice(loanId);
        r.u = _sizing(p, p.deleverageProtocolBps, r.units, trig, ps);
        r.free = _sizing(p, 0, r.units, trig, ps);
        r.base = _securedBase(mid, loanId, p);
        r.cap = r.base;
    }

    /// @dev `Deleverage._owed` on a `Run`: the keeper's ceiled bill for `units`.
    function _owedRun(Run memory r, uint256 units) internal pure returns (uint256) {
        return FullMath.mulDivRoundingUp(r.ps, units * (10000 - r.eps), 10000 * UNIT_SCALE);
    }

    /// @dev The close decision on a `Run`: the restore `_fit` would sell, its net melt, and whether that leaves the debt under the debt floor.
    function _closes(Run memory r) internal pure returns (bool) {
        bool charge = r.u < r.units && r.u <= r.cap;
        uint256 gross = _owedRun(r, charge ? r.u : (r.free < r.cap ? r.free : r.cap));
        uint256 net = gross - (charge ? FullMath.mulDiv(gross, r.cut, 10000) : 0);
        return r.debt < r.floor + net;
    }

    /// @dev The close's size on a `Run`: the exact inverse of `_owed`'s ceil.
    function _uClose(Run memory r) internal pure returns (uint256) {
        return FullMath.mulDiv(r.debt - 1, 10000 * UNIT_SCALE, r.ps * (10000 - r.eps)) + 1;
    }

    /* ============================== THE PROPERTY ============================== */

    /// @dev The whole admitted box with the cut never zero, the opening slack and the debt floor drawn too, so every cap gets its turn.
    /// @dev FROZEN SAMPLER: the arm count reads these draws, so reach a rare arm by widening a range, never by biasing one.
    /// @dev The floor is drawn up to half the draw, so `minPrincipal`, twice it, never refuses the draw itself.
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
        p.minPrincipal = 2 * (_pick(seed, 8, 0, 1) == 0 ? 1 : _pick(seed, 9, 1, principal / 2));
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
    function _crankOnce(uint256 seed) internal returns (Arm) {
        (bool ok, Run memory r) = _setUpDraw(seed);
        if (!ok) return Arm.Refused; // a config genesis refuses is `AceGenesisRails`' subject, not this one
        return _crankRun(r);
    }

    /// @dev The review's five, plus a bound against the pre-#413 sale `min(u, cap)`, transcribed so the change can only ever shrink a sale.
    function _assertProperties(Run memory r, bool charge, uint256 sold, uint256 out) internal view {
        uint256 debtAfter = read.loan(r.loanId).debt;
        uint256 cutPaid = charge ? FullMath.mulDiv(out, r.cut, 10000) : 0;
        assertEq(r.debt - debtAfter, out - cutPaid, "(i) the cut is charged exactly when u < C and u fits under securedBase");
        assertLe(sold, r.cap, "(ii) a restore never passes securedBase");
        if (!charge) assertLe(sold, r.free, "(iii) a crank that takes no cut never sells more than the cut-free restore");
        assertGe(debtAfter, r.floor, "(iv) a restore never lands the debt under the debt floor");
        if (sold > 0) assertLt(debtAfter * r.units, r.debt * read.loan(r.loanId).collateralUnits, "(v) every crank that sells lowers D/C");
        assertLe(sold, r.u < r.cap ? r.u : r.cap, "the sale never exceeds what today's min(u, cap) sold");
        assertEq(r.units - read.loan(r.loanId).collateralUnits, sold, "the collateral debit is exactly the units the crank reports sold");
    }

    /// @dev A closing crank: the decision said close, it sold exactly `uClose`, took no cut, and retired the whole debt.
    function _assertClose(Run memory r, uint256 sold, uint256 out) internal view {
        assertTrue(_closes(r), "(iv) a crank closes only where the restore's net melt would leave dust");
        assertEq(sold, _uClose(r), "the close sold exactly uClose");
        assertEq(out, _owedRun(r, sold), "at its ceiled bill");
        assertGe(out, r.debt, "which covers the whole debt");
        assertEq(read.loan(r.loanId).debt, 0, "and the debt is retired");
    }

    /// @notice THE PROPERTY, sampled over the admitted box with a non-zero cut: a crank that takes no cut never out-sells the cut-free restore.
    function testFuzz_ACutFreeCrankNeverSellsMoreThanTheCutFreeRestore(uint256 seed) public {
        _crankOnce(seed);
    }

    /// @notice A sweep that never reaches an arm asserts nothing about it, so every arm is counted, deterministically.
    /// @dev Same body as the fuzz row, so a sampler that stops reaching an arm fails here by name instead of going green.
    /// @dev Measured: 49 charged, 15 closed, 0 re-sized, 0 capped of 64; only the deleted room re-sized here, so the reserve sweep owns those two.
    function test_TheFuzzBodyReachesEveryArm() public {
        uint256[5] memory hits;
        for (uint256 s = 1; s <= 64; ++s) {
            uint256 snap = vm.snapshotState();
            ++hits[uint256(_crankOnce(s))];
            vm.revertToState(snap);
        }
        emit log_named_uint("cranks that took the cut, of 64", hits[uint256(Arm.Charged)]);
        emit log_named_uint("cranks re-sized to the cut-free restore, of 64", hits[uint256(Arm.Resized)]);
        emit log_named_uint("cranks that sold the cap, of 64", hits[uint256(Arm.Capped)]);
        emit log_named_uint("cranks that closed the loan, of 64", hits[uint256(Arm.Closed)]);
        assertGt(hits[uint256(Arm.Charged)], 0, "the body never reached a crank that takes the cut");
        assertGt(hits[uint256(Arm.Closed)], 0, "the body never reached a crank that closes the loan");
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
        assertLt(r.free, r.cap, "PREMISE: and the cut-free restore fits under securedBase");

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
    /// @notice Unless that sale would leave the debt under its debt floor: then the crank closes the loan instead.
    /// @dev Two legs at the PoC dials and theta 0.85: a floor at half the draw makes the first a close, the settlement reserve caps the second.
    function test_Control_ACapUnderTheCutFreeRestoreStillSellsTheCap() public {
        MarketParams memory p = _shipped();
        uint256 principal = _gate(p.minCoverageWad, 50);
        p.minPrincipal = principal; // the debt floor at half the draw
        (Run memory r, uint256 sold, uint256 out) = _crankAtTheta(p, principal, 0.85e18);
        assertTrue(_closes(r), "PREMISE: the restore's melt would leave the debt under a floor at half the draw");
        assertGt(read.loan(r.loanId).closedAt, 0, "so the crank closes the loan");
        assertEq(sold, _uClose(r), "selling exactly uClose");
        assertEq(out, r.debt, "whose bill lands on the debt: one unit is worth under a quote atom here");
        assertEq(read.loan(r.loanId).debt, 0, "and the debt is retired");

        p = _shipped();
        (r, sold, out) = _crankAtTheta(p, _gate(p.minCoverageWad, 97), 0.85e18);
        assertLt(r.base, r.free, "PREMISE: near the coverage line the secured base is under the cut-free restore");
        assertFalse(_closes(r), "PREMISE: and its melt leaves the debt over the floor, so the reserve is the cap");
        assertEq(sold, r.base, "the secured base is what sells");
        assertEq(r.debt - read.loan(r.loanId).debt, out, "with no cut: every wei of proceeds melted debt");
    }

    /// @notice O40, DISCLOSED: an under-filled crank that lifts the loan out of the band stands the channel down short of target.
    /// @notice A stranger's `repay` of the same melt does the same and lifts it further: `k(D-X)/C < k(D-X)/(C-f)`, `f` the units sold.
    /// @dev So a partial fill buys the borrower nothing that a repay, permissionless above the debt floor, does not already buy.
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
        assertGe(
            read.loan(loanId).debt, LoanMath.debtFloor(p.minPrincipal), "PREMISE: the stranger's repay leaves at least the floor, so no borrower was needed"
        );
        assertLt(read.triggerPrice(loanId), trigCrank, "the same melt as a repay keeps every unit, so it lifts the margin further");
        vm.expectRevert(NotInBand.selector);
        keeper.crankDeleverage(loanId);
    }

    /* ============================== THE RESERVE'S CORNER ============================== */

    /// @dev The main sampler re-sizes against `securedBase` too rarely to count on, so this corner gets its own sweep.
    /// @dev Thin coverage, a draw near the coverage line, the debt floor at dust: the settlement reserve binds and no close interferes.
    /// @dev FROZEN SAMPLER, as `_drawParams`, whose other dials it keeps; only `k`, the draw and `minPrincipal` are its own.
    function _drawReserveParams(uint256 seed) internal view returns (MarketParams memory p, uint256 principal) {
        (p,) = _drawParams(seed);
        p.minCoverageWad = _pick(seed, 11, Constants.MIN_COVERAGE_WAD, 2e18);
        principal = _gate(p.minCoverageWad, _pick(seed, 12, 80, 97));
        p.minPrincipal = 2;
    }

    /// @dev Crank a read `Run` once, hold it to the five properties and the exact figure, or to the close's, and say which arm it took.
    /// @dev The five properties come first and the exact figure last: the cut-free leg is the property, the figure ties the twins to the hub.
    function _crankRun(Run memory r) internal returns (Arm) {
        if (r.u == 0) return Arm.Refused; // at or above target, or a dust restore: the crank returns before any cap is read
        bool charge = r.u < r.units && r.u <= r.cap;
        (uint256 sold, uint256 out) = keeper.crankDeleverage(r.loanId);
        if (read.loan(r.loanId).closedAt != 0) {
            _assertClose(r, sold, out);
            return Arm.Closed;
        }
        assertFalse(_closes(r), "a crank the decision closes did not close");
        _assertProperties(r, charge, sold, out);
        assertEq(sold, charge ? r.u : (r.free < r.cap ? r.free : r.cap), "the hub sold something other than the cut-free re-size predicts");
        if (sold == 0) return Arm.Refused;
        if (charge) return Arm.Charged;
        return r.free <= r.cap ? Arm.Resized : Arm.Capped;
    }

    /// @dev ONE body for the reserve sweep's fuzz row and its count.
    function _crankReserveOnce(uint256 seed) internal returns (Arm arm) {
        (MarketParams memory p, uint256 principal) = _drawReserveParams(seed);
        (bool ok, bytes32 mid) = _create(p);
        if (!ok) return Arm.Refused;
        uint256 loanId = _open(mid, COLL, principal);
        uint256 trig = read.triggerPrice(loanId);
        uint256 ps = _pick(seed, 10, _level(trig, p.deleverageStopBps) + 1, _level(trig, p.deleverageBandBps) - 1);
        _arm(ps);
        arm = _crankRun(_read(mid, loanId, p, ps));
    }

    /// @notice THE PROPERTY at the reserve's corner: with `securedBase` as the cap, only a restore that fits is charged, and none out-sells `free`.
    function testFuzz_AtTheReserveACutFreeCrankNeverSellsMoreThanTheCutFreeRestore(uint256 seed) public {
        _crankReserveOnce(seed);
    }

    /// @notice The reserve sweep reaches all three restore arms with `securedBase` as the cap, counted the same way as the main sweep.
    function test_TheReserveSweepReachesEveryArmOnTheBase() public {
        uint256[5] memory hits;
        for (uint256 s = 1; s <= 64; ++s) {
            uint256 snap = vm.snapshotState();
            ++hits[uint256(_crankReserveOnce(s))];
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

    /// @dev The PoC dials on a q18/c6 pair with the debt floor at dust, and a 20-quote loan whose trigger sits at `thetaBps` of par.
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
        p.minPrincipal = 2;
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
    /// @dev The settlement reserve is the restore's one cap; the debt floor is dust here, so no close interferes with its edge.
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
        assertFalse(_closes(r), "PREMISE: and its melt leaves the debt over the floor");
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
    uint256 internal constant SIM_FLOOR_CLOSES = SIM_DEBT_U + 1; // a debt floor one atom over where the charged restore lands: the crank closes
    uint256 internal constant SIM_UCLOSE_U = 5316321104731525834580; // the smallest sale whose ceiled bill covers the 5,000 debt
    uint256 internal constant SIM_OUT_CLOSE_U = 5000000000; // its bill: one unit is worth under a quote atom here, so it lands on the debt
    uint256 internal constant SIM_UNITS_CREDIT_U = 4683678895268474165420; // the lot less the close's sale, credited to the borrower

    /// @dev The sim's `ledger_delev(.., cut 500)` fixture on the hub: the PoC dials, the market bidding at exactly 1.0, the record at 0.95.
    /// @dev `floor` is the debt floor; the market stores twice it as `minPrincipal`, as the sim's ledger does.
    function _simFixture(uint256 floor) internal returns (bytes32 mid, uint256 loanId, MarketParams memory p) {
        p = _shipped();
        p.price = AceFixtures.px(1e18, address(usdc), address(vault));
        p.settleBountyBps = 50;
        p.minPrincipal = 2 * floor;
        bool ok;
        (ok, mid) = _create(p);
        assertTrue(ok, "PREMISE: genesis admits the sim's fixture");
        loanId = _open(mid, COLL, 5_000e6);
        assertEq(read.triggerPrice(loanId), AceFixtures.px(0.7e18, address(usdc), address(vault)) + 1, "PREMISE: the sim's trigger, 0.7 plus a wei");
        _arm(AceFixtures.px(0.95e18, address(usdc), address(vault)));
    }

    /// @notice HUB AND SIM AGREE on the charged restore and on the close at the sim's own fixture, pinned to `deleverage_hub_parity_pins`.
    /// @dev The record is the only floor leg at 0.95, so #498's divergence is off; the base does not bind, so the restore is uncapped.
    /// @dev The second leg sets the floor one atom over where the charged restore lands, so the same crank closes instead.
    function test_SimParity_TheSimsFixtureChargesAndClosesAsTheSimDoes() public {
        (bytes32 mid, uint256 loanId, MarketParams memory p) = _simFixture(5e6); // the fixture's 10 USDC minPrincipal
        Run memory r = _read(mid, loanId, p, AceFixtures.px(0.95e18, address(usdc), address(vault)));
        assertLt(r.u, r.base, "PREMISE: the hub's secured base does not bind");
        (uint256 sold, uint256 out) = keeper.crankDeleverage(loanId);
        assertEq(sold, SIM_U, "charged arm: units sold, as the sim pins");
        assertEq(out, SIM_OUT_U, "charged arm: proceeds, as the sim pins");
        assertEq(read.loan(loanId).debt, SIM_DEBT_U, "charged arm: debt after, net of the 500 bps cut, as the sim pins");

        (mid, loanId, p) = _simFixture(SIM_FLOOR_CLOSES);
        r = _read(mid, loanId, p, AceFixtures.px(0.95e18, address(usdc), address(vault)));
        assertTrue(_closes(r), "PREMISE: the charged restore's landing is one atom under the floor, so the decision closes");
        uint256 escrow = read.feeEscrowOf(loanId);
        (sold, out) = keeper.crankDeleverage(loanId);
        assertGt(read.loan(loanId).closedAt, 0, "close arm: the crank closed the loan, as the sim's does");
        assertEq(sold, SIM_UCLOSE_U, "close arm: units sold, as the sim pins");
        assertEq(out, SIM_OUT_CLOSE_U, "close arm: proceeds, as the sim pins");
        assertEq(read.unitsOwedOf(loanId, borrower), SIM_UNITS_CREDIT_U, "close arm: the borrower's units credit, as the sim pins");
        assertEq(read.quoteOwedOf(loanId, borrower) - escrow, out - 5_000e6, "close arm: the bill's overshoot credited, as the sim pins");
    }

    /* ============================== HUB AND SIM: THE RESERVE BINDS AND THE BRANCH CLOSES ============================== */

    uint256 internal constant SIM_CLOSE_PRINCIPAL = 6_000e6; // near enough the coverage line that the settlement reserve binds
    uint256 internal constant SIM_CLOSE_FLOOR = 2_500e6; // a debt floor over what the reserve-capped restore would leave, so the crank closes
    uint256 internal constant SIM_BASE = 3969999999999999954826; // securedBase: the lot less the claim's need and the keeper sliver
    uint256 internal constant SIM_UCLOSE = 6379585325890483845728; // the smallest sale whose ceiled bill covers the 6,000 debt
    uint256 internal constant SIM_OUT_CLOSE = 6000000000; // its bill: one unit is worth under a quote atom here, so it lands on the debt
    uint256 internal constant SIM_UNITS_CREDIT = 3620414674109516154272; // the lot less the close's sale, credited to the borrower
    uint256 internal constant SIM_QUOTE_CREDIT = 0; // the bill's overshoot of the debt, credited to the borrower

    /// @notice HUB AND SIM AGREE where `securedBase` is the binding cap AND the crank closes, pinned to the sim's own literals.
    /// @dev The sim fixture's dials and 0.95 record, a 6,000 draw, and a 2,500 floor: the record is the only floor leg.
    function test_SimParity_TheReserveBindsAndTheBranchCloses() public {
        MarketParams memory p = _shipped();
        p.price = AceFixtures.px(1e18, address(usdc), address(vault));
        p.settleBountyBps = 50;
        p.minPrincipal = 2 * SIM_CLOSE_FLOOR;
        (bool ok, bytes32 mid) = _create(p);
        assertTrue(ok, "PREMISE: genesis admits the fixture");
        uint256 loanId = _open(mid, COLL, SIM_CLOSE_PRINCIPAL);
        uint256 ps = AceFixtures.px(0.95e18, address(usdc), address(vault));
        _arm(ps);
        Run memory r = _read(mid, loanId, p, ps);
        assertEq(r.base, SIM_BASE, "PREMISE: the hub's secured base, as the sim pins");
        assertLt(r.base, r.free, "PREMISE: the reserve binds under the cut-free restore");
        assertLt(r.base, r.u, "PREMISE: and under the cut-charging one, so the restore would sell the base with no cut");
        uint256 melt = FullMath.mulDivRoundingUp(ps, r.base * (10000 - p.deleverageFloorEpsBps), 10000 * UNIT_SCALE);
        assertLt(r.debt, SIM_CLOSE_FLOOR + melt, "PREMISE: and that melt would leave dust, so the branch closes");
        uint256 escrow = read.feeEscrowOf(loanId);
        (uint256 sold, uint256 out) = keeper.crankDeleverage(loanId);
        assertTrue(read.loan(loanId).closedAt != 0, "the reserve-bound crank closed the loan, as the sim's does");
        assertEq(sold, SIM_UCLOSE, "close: units sold, as the sim pins");
        assertEq(out, SIM_OUT_CLOSE, "close: proceeds, as the sim pins");
        assertEq(read.unitsOwedOf(loanId, borrower), SIM_UNITS_CREDIT, "close: the borrower's units credit, as the sim pins");
        assertEq(read.quoteOwedOf(loanId, borrower) - escrow, SIM_QUOTE_CREDIT, "close: the borrower's overshoot credit, as the sim pins");
    }
}
