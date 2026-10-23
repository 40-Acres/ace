// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.36;

import {Test} from "forge-std/Test.sol";
import {FullMath} from "@uniswap/v4-core/src/libraries/FullMath.sol";
import {Ace} from "../../src/ace/hub/Ace.sol";
import {Constants} from "../../src/ace/hub/Constants.sol";
import {MarketParams, OpenBounds} from "../../src/ace/hub/Types.sol";
import {PriceFrame} from "../utils/PriceFrame.sol";
import {PositionManager} from "../../src/ace/positions/PositionManager.sol";
import {MockERC20} from "../mocks/MockERC20.sol";
import {MockPersistenceRecord} from "../mocks/MockPersistenceRecord.sol";
import {MockDeleverageKeeper} from "../mocks/MockDeleverageKeeper.sol";
import {MockStakeVault} from "../mocks/MockStakeVault.sol";
import {AceFixtures} from "../utils/AceFixtures.sol";
import {AceReader} from "../utils/AceReader.sol";

/// @title AceDeleverageDenominatorBoundTest
/// @notice #353: `_deleverageSizing` forms `den = Y - tStar` in CHECKED arithmetic and then divides by it.
/// @notice Two obligations, and they are ONE inequality `Y >= T`: `den >= 1` (no underflow, no divide by zero) and `u <= C`.
/// @notice The carriers are the `trig > tStar` sizing guard, the STRICT ceiled stop gate, `stop below sellmax onset`, and `k(1-eps) > 1`.
/// @notice The `deleverage denominator` rail the old sizing header named carries NEITHER of them, and the protocol cut cancels out.
/// @dev Notation, as the code spells it: `K = floor(floor(k(1-eps))(1-cut))`, `z = 1e18 - stop*1e14`, `Y` is `K` with `Ps` interposed.
/// @dev The PROOF is total over every `Ps`; this file is a BOUNDED sweep, and its job is to catch a transcription error in the proof.
/// @dev Nothing here reproduces a live bug: these are guards plus a correction pin, so a green first run is not evidence of a fix.
/// @dev The twin is tied to shipped bytecode by the hub-anchor rows in section 7; without them this file checks a formula nothing runs.
/// @dev The DETERMINISTIC anchor rows hold that tie, never the fuzz row beside them: a sampler finds a counterexample, it cannot keep one.
contract AceDeleverageDenominatorBoundTest is Test {
    /// @dev One sweep's four counters, carried by reference so the inner loop never returns a tuple.
    struct Tally {
        uint256 points; // frontier points that cleared both skips
        uint256 failures; // points where `den >= 1` or `u <= C` did not hold
        uint256 denOne; // points at `den == 1`: the frontier itself, and the anti-vacuity witness
        uint256 sellMax; // points at `Y == trigMax`: where `u == C` is reachable, so `u < C` is false
    }

    Ace internal ace;
    PositionManager internal positionManager;
    AceReader internal read;
    MockERC20 internal usdc;
    MockStakeVault internal vault;
    MockPersistenceRecord internal record;
    MockDeleverageKeeper internal keeper;

    address internal lender = address(0xA11CE);
    address internal borrower = address(0xB0B);
    address internal cranker = address(0xCAFE);

    uint256 internal constant COLL = 10_000e18;
    uint256 internal constant LADDER = 20_000e6;
    uint256 internal constant UNIT_SCALE = 1 << 96; // every market's scale under the atom frame
    uint256 internal T0; // par itself, so the funding floor reads off the page; assigned in setUp

    /// @dev This suite's pair, so a tick reads as its distance from par rather than as a grid coordinate.
    /// @param offset Ticks above par.
    /// @return The absolute grid tick.
    function _price(int24 offset) internal view returns (uint256) {
        return AceFixtures.priceAt(address(usdc), address(vault), offset);
    }

    function setUp() public {
        vm.warp(1_000_000);
        usdc = new MockERC20("USD Coin", "USDC", 6);
        vault = new MockStakeVault(42);
        T0 = _price(0);
        record = new MockPersistenceRecord(address(usdc), address(vault));
        record.setMinPrice(AceFixtures.px(2e18, address(usdc), address(vault)));
        (ace, positionManager) = AceFixtures.newAceWithEscrow(AceFixtures.TREASURY);
        read = new AceReader(address(ace));
        keeper = new MockDeleverageKeeper(ace, address(usdc), address(vault), UNIT_SCALE);
    }

    /* ====== 1. THE TWIN: `_deleverageSizing` re-spelled, and the sweep it drives ====== */

    /// @dev The sizing's first term `Y`, both truncating divisions included.
    /// @dev ONE spelling for the twin and every sweep: only the twin's copy is hub-anchored, so a second copy could drift while green.
    /// @dev `1e22` is the shipped `1e18 * 10000`, written folded because the product is a compile-time constant either way.
    function _y(uint256[3] memory cfg, uint256 ps) private pure returns (uint256) {
        return FullMath.mulDiv(FullMath.mulDiv(cfg[0], ps * (10000 - cfg[1]), 1e22), 10000 - cfg[2], 10000);
    }

    /// @dev `Deleverage._deleverageSizing` re-spelled term for term, its first term `Y` factored into `_y` above.
    function _twin(uint256[3] memory cfg, uint256 target, uint256 units, uint256 trig, uint256 ps) internal pure returns (uint256) {
        uint256 tStar = (ps * (1e18 - target * 1e14)) / 1e18;
        if (trig <= tStar) return 0;
        uint256 den = _y(cfg, ps) - tStar;
        uint256 u = FullMath.mulDiv(units, trig - tStar, den);
        return u > units ? units : u;
    }

    /// @dev `MarketInit`'s own left term, with its own double truncation: the rails compare THIS against `1e18`.
    function _bigK(uint256[3] memory cfg) internal pure returns (uint256) {
        return ((cfg[0] * (10000 - cfg[1])) / 10000) * (10000 - cfg[2]) / 10000;
    }

    /// @dev The smallest stop `stop below sellmax onset` admits, which MAXIMIZES `z` and is the worst case for both obligations.
    function _stopMin(uint256 bigK) internal pure returns (uint256) {
        return bigK >= 1e18 ? 1 : (1e18 - bigK) / 1e14 + 1;
    }

    /// @dev The innermost loop, in its OWN frame: sharing one with the corner loop is stack-too-deep at this optimizer setting.
    /// @dev `ps` starts at 3 because the stop gate cannot admit a lower one, so 1 and 2 are iterations that can never count.
    function _sweepPs(Tally memory t, uint256[3] memory cfg, uint256 z, uint256 target, uint256 psMax) private pure {
        uint256 tw = 1e18 - target * 1e14;
        for (uint256 ps = 3; ps <= psMax; ++ps) {
            uint256 tStar = (ps * tw) / 1e18;
            uint256 trigMax = ((ps - 1) * z) / 1e18; // the largest trigger the STRICT ceiled stop gate admits at this price
            if (trigMax < tStar + 1) continue; // no trigger is reachable here: the sizing guard and the gate exclude each other
            uint256 y = _y(cfg, ps);
            ++t.points;
            if (y < tStar + 1 || y < trigMax) ++t.failures;
            if (y == tStar + 1) ++t.denOne;
            if (y == trigMax) ++t.sellMax;
        }
    }

    /// @dev One corner `(k, eps, cut)` swept over every legal target: a band must fit strictly between the stop and the target.
    function _sweepCorner(Tally memory t, uint256[3] memory cfg, uint256 targetStep, uint256 psMax) private pure {
        uint256 stopMin = _stopMin(_bigK(cfg));
        uint256 z = 1e18 - stopMin * 1e14;
        uint256 lo = stopMin + 1 > Constants.MIN_DELEVERAGE_BAND_BPS ? stopMin + 1 : Constants.MIN_DELEVERAGE_BAND_BPS;
        for (uint256 target = lo + 1; target <= 9999; target += targetStep) {
            _sweepPs(t, cfg, z, target, psMax);
        }
    }

    /* ====== 2. THE BOUNDED SWEEP ====== */

    /// @notice The seven corners of the admitted box, each at the stop the sell-max rail barely admits: the frontier itself.
    /// @notice Per point: `den >= 1` is `Y >= tStar + 1` and `u <= C` is `Y >= trigMax`, and a violation is COUNTED, never asserted inline.
    /// @dev Counting beats a per-point `assertGe`: the latter is a cheatcode call, and there are ~890k points here.
    /// @dev The counters are asserted exactly, so an edit that quietly shrinks the sweep fails instead of going quietly green.
    /// @dev ANTI-VACUITY IS MANDATORY: `den == 1` must be REACHED, or a sweep that stops touching the frontier passes on nothing.
    /// @dev What it reaches: 876,965 points, 0 failures, `den == 1` at 2,953 of them, and `Y == trigMax` at 264,401.
    /// @dev That last count is the sell-max claim's refutation at sweep scale: `u == C` is reachable, so `u < C` is not what the rail buys.
    function test_TheReachableFrontierNeverGoesNonPositive() public {
        Tally memory t;
        _sweepCorner(t, [uint256(1.05e18), 200, 2000], 1, 64);
        _sweepCorner(t, [uint256(1.05e18), 200, 2000], 37, 400);
        _sweepCorner(t, [uint256(1.05e18), 200, 0], 37, 400);
        _sweepCorner(t, [uint256(1.05e18), 1, 2000], 37, 400);
        _sweepCorner(t, [uint256(1.05e18), 1, 0], 37, 400);
        _sweepCorner(t, [uint256(1.2755e18), 200, 2000], 37, 400);
        _sweepCorner(t, [uint256(20e18), 200, 2000], 37, 400);
        emit log_named_uint("frontier points swept", t.points);
        emit log_named_uint("frontier failures", t.failures);
        emit log_named_uint("den == 1 hits", t.denOne);
        emit log_named_uint("Y == trigMax hits (u == C reachable)", t.sellMax);
        assertEq(t.failures, 0, "a reachable config drives the sizing denominator to zero or under");
        assertGt(t.denOne, 0, "the sweep never reached den == 1, so it proves nothing about the frontier");
        assertGt(t.sellMax, 0, "the sweep never reached Y == trigMax, so the u == C witness is not covered here");
        assertEq(t.points, 876965, "the sweep no longer walks the frontier it was sized to walk");
        assertEq(t.denOne, 2953, "the den == 1 count moved: the sizing arithmetic or the sweep's reach changed");
        assertEq(t.sellMax, 264401, "the Y == trigMax count moved: the sizing arithmetic or the sweep's reach changed");
    }

    /* ====== 3. THE CONTROLS: below the coverage relation, and they assert nothing about pass or fail ====== */

    /// @notice `k = 1.0e18` puts `K1` at or under `1e18`, so step 6 of the proof dies and the CLEAN result is gone.
    /// @notice The control found zero failures anyway, which is why the relation is a proof premise and NOT a known cliff.
    /// @dev A future non-zero here would mean the residue below the relation has become reachable, not that a shipped config broke.
    /// @dev Shipped configs cannot enter this region: `MIN_COVERAGE_WAD` is 1.05e18 and genesis refuses anything under it.
    /// @dev What it reaches: 204,931 points and 0 failures.
    function test_ControlBelowTheRelation_CoverageOneCutMax() public {
        Tally memory t;
        _sweepCorner(t, [uint256(1.0e18), 200, 2000], 13, 384);
        emit log_named_uint("control k=1.0e18 cut=2000 points", t.points);
        emit log_named_uint("control k=1.0e18 cut=2000 failures", t.failures);
        assertGt(t.points, 0, "fixture: the control swept nothing, so its zero is not a result");
        assertEq(t.points, 204931, "the control no longer walks the region it was sized to walk");
    }

    /// @notice The same control with the cut OFF, which isolates the cut: it appears on BOTH sides of the bound and cancels.
    /// @dev A non-zero failure count here and not in the cut-on control would mean the cut does NOT cancel, contradicting the proof.
    /// @dev What it reaches: 205,359 points and 0 failures.
    function test_ControlBelowTheRelation_CoverageOneNoCut() public {
        Tally memory t;
        _sweepCorner(t, [uint256(1.0e18), 200, 0], 13, 384);
        emit log_named_uint("control k=1.0e18 cut=0 points", t.points);
        emit log_named_uint("control k=1.0e18 cut=0 failures", t.failures);
        assertGt(t.points, 0, "fixture: the control swept nothing, so its zero is not a result");
        assertEq(t.points, 205359, "the control no longer walks the region it was sized to walk");
    }

    /// @notice Further below the relation still, at `k = 0.9e18`, where the recorded band-floor argument covers only `Ps >= 351`.
    /// @notice `Ps <= 512` therefore sweeps the whole window the band-floor argument leaves unproven, and it too came back clean.
    /// @dev Degradation below the relation is graceful and the residue is dust prices; that is what this control measures.
    /// @dev What it reaches: 271,577 points and 0 failures.
    function test_ControlBelowTheRelation_CoverageZeroNine() public {
        Tally memory t;
        _sweepCorner(t, [uint256(0.9e18), 200, 2000], 13, 512);
        emit log_named_uint("control k=0.9e18 cut=2000 points", t.points);
        emit log_named_uint("control k=0.9e18 cut=2000 failures", t.failures);
        assertGt(t.points, 0, "fixture: the control swept nothing, so its zero is not a result");
        assertEq(t.points, 271577, "the control no longer walks the region it was sized to walk");
    }

    /* ====== 4. THE PROOF PREMISE, AND THE REDUCTION THE PROOF LEANS ON ====== */

    /// @notice T2: the tripwire on step 6 of the proof, `K1 > 1e18`, which is worth the 2.9% margin the whole bound rests on.
    /// @notice A trip here means the CLEAN proof is gone, NOT that a bug is live: the three controls below the relation found zero failures.
    /// @dev A retune of either constant must re-read this relation before it lands.
    /// @dev The compile-time form of this tripwire does not work: a negative `uint256` constant expression compiles clean on 0.8.36.
    function test_TheCoverageRelationHoldsTheDenominatorProof() public pure {
        uint256 k1 = Constants.MIN_COVERAGE_WAD * (10000 - Constants.MAX_DELEVERAGE_FLOOR_EPS_BPS);
        assertGt(k1, 1e18 * 10000, "MIN_COVERAGE_WAD x (10000 - MAX_DELEVERAGE_FLOOR_EPS_BPS) fell to 1e22: the denominator proof is gone");
    }

    /// @notice The proof reasons in plain integer arithmetic while the hub spells the same terms with `FullMath.mulDiv`.
    /// @notice This is the transfer argument: wherever the intermediate product fits a `uint256`, the two agree exactly.
    /// @dev SAMPLED, not exhaustive: it is a fuzz over the fitting region, so it can refute the transfer and never establish it whole.
    /// @dev The sizing's own intermediates fit by construction -- `k <= 20e18` and `Ps` is bounded by `tStar`'s plain multiply.
    function test_TheReductionIsTheShippedArithmetic(uint256 a, uint256 b, uint256 c) public pure {
        a = bound(a, 0, type(uint128).max);
        b = bound(b, 0, type(uint128).max); // a * b then fits a uint256 for every pair in range
        c = bound(c, 1, type(uint256).max);
        assertEq(FullMath.mulDiv(a, b, c), (a * b) / c, "mulDiv and the plain spelling disagree where the product fits");
    }

    /* ====== 5. THE WHOLE ADMITTED BOX, FUZZED ====== */

    /// @notice The bounded sweep is total only over the `Ps` it walks; this row samples the whole admitted box instead.
    /// @notice Stop is pinned at `stopMin` because that is where `z` is largest, which is the worst case for both obligations.
    /// @dev The two skips ride as `vm.assume`: a point outside them is not a config the runtime can present, not a passing case.
    function testFuzz_AnyAdmittedConfigHasAPositiveDenominator(uint256 kS, uint256 epsS, uint256 cutS, uint256 tS, uint256 psS) public {
        uint256[3] memory cfg = [
            bound(kS, Constants.MIN_COVERAGE_WAD, Constants.MAX_COVERAGE_WAD),
            bound(epsS, 1, Constants.MAX_DELEVERAGE_FLOOR_EPS_BPS),
            bound(cutS, 0, Constants.MAX_DELEVERAGE_PROTOCOL_BPS)
        ];
        uint256 stopMin = _stopMin(_bigK(cfg));
        uint256 lo = stopMin + 2 > Constants.MIN_DELEVERAGE_BAND_BPS + 1 ? stopMin + 2 : Constants.MIN_DELEVERAGE_BAND_BPS + 1;
        _assertFrontier(cfg, 1e18 - stopMin * 1e14, bound(tS, lo, 9999), bound(psS, 3, 1e24));
    }

    /// @dev One point of the frontier, in its own frame so the bounding above never shares a stack with the arithmetic.
    function _assertFrontier(uint256[3] memory cfg, uint256 z, uint256 target, uint256 ps) private {
        uint256 tStar = (ps * (1e18 - target * 1e14)) / 1e18;
        uint256 trigMax = ((ps - 1) * z) / 1e18;
        vm.assume(trigMax >= tStar + 1);
        uint256 y = _y(cfg, ps);
        assertGe(y, tStar + 1, "den <= 0 on an admitted config: the checked subtraction would underflow");
        assertGe(y, trigMax, "u > C on an admitted config: the sizing would ask for more collateral than the loan holds");
    }

    /* ====== 6. THE SELL-MAX WITNESS, AT THE ARITHMETIC LEVEL ====== */

    /// @notice `stop below sellmax onset` buys `u <= C` and NOT `u < C`, and one wei of rail slack is all that separates them.
    /// @notice The witness: `k` tuned so the rail clears by exactly 1 wei, at a collateral price of 0.01 quote per unit.
    /// @notice At that price the first term lands EXACTLY on the largest trigger the stop gate admits, so the sizing returns `u == C`.
    /// @dev This is the arithmetic half of the correction pin; `AceDeleverageActivation` drives the same witness through the hub.
    /// @dev Every one of these four dials is admitted by `MarketInit`, and `createMarket` is permissionless, so the creator is the only bar.
    function test_TheSellMaxRailAdmitsAnExactUEqualsC() public pure {
        uint256[3] memory cfg = [uint256(1147959183673469390), 200, 2000];
        uint256 bigK = _bigK(cfg);
        assertEq(bigK, 900000000000000001, "the witness k does not land the rail's left term where the proof puts it");
        assertEq(1000 * 1e14 + bigK, 1e18 + 1, "the witness config does not clear the sell-max rail by exactly one wei");

        uint256 ps = 10000000000000001; // 0.01 quote per unit, one wei above the stop level the witness trigger implies
        uint256 z = 1e18 - 1000 * 1e14;
        uint256 trigMax = ((ps - 1) * z) / 1e18;
        uint256 y = _y(cfg, ps);
        assertEq(trigMax, 9e15, "the largest admitted trigger at the witness price moved");
        assertEq(y, trigMax, "the witness no longer sits on the frontier, so it no longer witnesses u == C");
        assertEq(_twin(cfg, 5000, COLL, trigMax, ps), COLL, "the sizing did not return the whole collateral at the witness point");
    }

    /// @notice The row above says the witness dials are admitted by `MarketInit`; this puts them through `createMarket` and shows it.
    /// @notice One bps lower on the stop and genesis REFUSES BY NAME, which pins `_stopMin` to the rail instead of re-deriving it alongside.
    /// @dev Without this the sweeps run on a SECOND twin -- `_bigK` and `_stopMin` -- with nothing tying either to the shipped genesis arithmetic.
    /// @dev `createMarket` keys the id off the whole preimage, so the refused call and the admitted one are different markets and neither collides.
    function test_TheGenesisRailAdmitsTheWitnessStopAndRefusesOneLower() public {
        uint256[3] memory cfg = [uint256(1147959183673469390), 200, 2000];
        uint256 stop = _stopMin(_bigK(cfg));
        assertEq(stop, 1000, "the witness stop is no longer where `_stopMin` puts it");
        MarketParams memory p = AceFixtures.marketParams(address(usdc), address(vault));
        p.record = address(record);
        (p.minCoverageWad, p.deleverageFloorEpsBps, p.deleverageProtocolBps) = (cfg[0], cfg[1], cfg[2]);
        (p.deleverageBandBps, p.deleverageTargetBps, p.deleverageStopBps) = (3000, 5000, stop - 1);
        vm.expectRevert(bytes("stop below sellmax onset"));
        ace.createMarket(p);
        p.deleverageStopBps = stop;
        ace.createMarket(p);
    }

    /* ====== 7. THE HUB ANCHOR: the twin is the shipped formula, or it is nothing ====== */

    /// @dev Which of the prediction's two twins the anchor's assertion actually pinned on one run.
    /// @dev The composition means a run pins ONE of them, so a sweep that reaches one arm leaves the other tied to nothing.
    enum Arm {
        Refused, // genesis refused the config, the crank reverted, or it sold nothing: no twin was pinned
        Sizing, // the sizing landed at or under both caps, so the hub was held to `_twin`
        Resized, // a cap bound on a market with a cut and the cut-free restore fit under it, so the hub was held to `_twin` at a zero cut
        Cap, // the settlement reserve bound, so the hub was held to `_securedBaseTwin`
        MinDebt // the minDebt cap bound, so the hub was held to `_minDebtRoomTwin`
    }

    function _rand(uint256 seed, uint256 k) private pure returns (uint256) {
        return uint256(keccak256(abi.encode(seed, k)));
    }

    function _pick(uint256 seed, uint256 k, uint256 lo, uint256 hi) private pure returns (uint256) {
        return lo + (_rand(seed, k) % (hi - lo + 1));
    }

    /// @dev The whole admitted box at the param level, so `k`, eps, the band, the target, the stop and the cut move together.
    /// @dev FROZEN SAMPLER: the counterexample row names a seed, so a change here silently re-points it at a different config.
    /// @dev Reach a rare arm by WIDENING the anchor's walk, never by biasing these draws toward it.
    function _anchorParams(uint256 seed) private view returns (MarketParams memory p) {
        p = AceFixtures.marketParams(address(usdc), address(vault));
        p.record = address(record);
        p.minCoverageWad = _pick(seed, 1, Constants.MIN_COVERAGE_WAD, Constants.MAX_COVERAGE_WAD);
        p.deleverageFloorEpsBps = _pick(seed, 4, 1, Constants.MAX_DELEVERAGE_FLOOR_EPS_BPS);
        p.deleverageBandBps = _pick(seed, 20, Constants.MIN_DELEVERAGE_BAND_BPS, 9000);
        p.deleverageTargetBps = _pick(seed, 21, p.deleverageBandBps + 1, 9999);
        p.deleverageStopBps = _pick(seed, 22, 1, p.deleverageBandBps - 1);
        p.deleverageProtocolBps = _pick(seed, 23, 0, Constants.MAX_DELEVERAGE_PROTOCOL_BPS);
    }

    function _seedLadder(bytes32 mid) private {
        usdc.mint(lender, LADDER);
        vm.startPrank(lender);
        usdc.approve(address(ace), LADDER);
        ace.deposit(mid, LADDER);
        vm.stopPrank();
    }

    /// @dev The largest draw tick 0 admits at this `k`, taken at 97% so the trigger's ceil cannot cross it.
    function _openAtTheGate(bytes32 mid, uint256 k) private returns (uint256 loanId) {
        uint256 principal = ((COLL * 1e6) / k) * 97 / 100;
        vault.mint(borrower, COLL);
        vm.startPrank(borrower);
        vault.approve(address(positionManager), COLL);
        loanId = ace.open(mid, COLL, principal, 0, borrower, OpenBounds(0, 0, 0));
        vm.stopPrank();
        assertEq(read.fundingFloor(mid, loanId), T0, "fixture: the floor is the market own price");
    }

    /// @dev Below-ness holds at the band level and not at the trigger, so the loan is in band and never distressed.
    /// @dev The record mock rests its band 1% under the level it is given, so the setup only clears while the band is wider than 1%.
    /// @dev `MIN_DELEVERAGE_BAND_BPS` is 3000, so it clears by a wide margin; were it ever cut under ~101 the anchor's counted arms would go to zero.
    function _enterBand(uint256 loanId, uint256 bandBps, uint256 rhoWad) private {
        uint256 trig = read.triggerPrice(loanId);
        record.setBelowBand(FullMath.mulDivRoundingUp(trig, 1e18, 1e18 - bandBps * 1e14));
        uint256 ps = (trig * rhoWad) / 1e18;
        record.setMinPrice(ps);
    }

    /// @dev `LoanAccounting.collateralNeeded` re-spelled: what the live claim needs at its OWN price, ceiled.
    /// @dev WAS a per-tick sum with a ceiling each; one claim at one price leaves one ceiling.
    function _claimUnits(bytes32 mid, uint256 loanId) private view returns (uint256) {
        uint256 amt = read.claimOf(mid, loanId);
        if (amt == 0) return 0;
        uint256 price = read.fundingFloor(mid, loanId);
        return (amt * UNIT_SCALE + price - 1) / price;
    }

    /// @dev `LoanAccounting.securedBase` re-spelled: `min(requiredAt(debt, floor), units - keep)`, `keep` being the settlement reserve.
    /// @dev The reserve leg BINDS: drop it and the twin over-predicts every crank the position has to reserve against.
    /// @dev Nothing links this copy to `securedBase`: re-read the shipped body when that function changes, because no tool reports the drift.
    /// @dev The zero-debt and zero-price arms are not re-spelled -- the fixture opens a funded loan, so neither is reachable here.
    function _securedBaseTwin(bytes32 mid, uint256 loanId, MarketParams memory p, uint256 units) private view returns (uint256) {
        uint256 debt = read.loan(loanId).debt;
        uint256 floorPrice = read.fundingFloor(mid, loanId);
        uint256 req = FullMath.mulDivRoundingUp(p.minCoverageWad * debt, UNIT_SCALE, floorPrice * 1e18);
        uint256 bty = (debt * p.settleBountyBps * UNIT_SCALE) / (10000 * floorPrice);
        uint256 keep = _claimUnits(mid, loanId) + (bty < units ? bty : units);
        uint256 sellable = units > keep ? units - keep : 0;
        return req < sellable ? req : sellable;
    }

    /// @dev The `minDebt` cap re-spelled: the largest sale whose proceeds, at the eps-discounted floor, leave the debt at or above `minDebt`.
    /// @dev Nothing links this copy to `Deleverage`: re-read the shipped cap when it changes, because no tool reports the drift.
    function _minDebtRoomTwin(uint256 loanId, MarketParams memory p, uint256 ps) private view returns (uint256) {
        uint256 debt = read.loan(loanId).debt;
        uint256 head = debt > p.minDebt ? debt - p.minDebt : 0;
        return FullMath.mulDiv(head, 10000 * UNIT_SCALE, ps * (10000 - p.deleverageFloorEpsBps));
    }

    /// @dev Both caps are re-derived here rather than assumed away: `securedBase` and the `minDebt` room, each AFTER sizing, as the hub reads them.
    /// @dev The sizing sells with its cut only while `u < C` and it fits under both; otherwise the cut-free restore is capped by them.
    /// @dev The arm rides out with the number because the caller cannot recover it: `min` erases which side won.
    /// @dev A TIE keeps the earlier arm -- the figure returned is the same either way.
    function _predict(bytes32 mid, uint256 loanId, MarketParams memory p) private view returns (uint256 got, Arm arm) {
        uint256[3] memory cfg = [p.minCoverageWad, p.deleverageFloorEpsBps, p.deleverageProtocolBps];
        uint256 units = read.loan(loanId).collateralUnits;
        uint256 ps = record.windowMin();
        uint256 trig = read.triggerPrice(loanId);
        uint256 want = _twin(cfg, p.deleverageTargetBps, units, trig, ps);
        uint256 base = _securedBaseTwin(mid, loanId, p, units);
        uint256 room = _minDebtRoomTwin(loanId, p, ps);
        uint256 cap = base < room ? base : room;
        if (want < units && want <= cap) return (want, Arm.Sizing);
        bool cut = cfg[2] > 0; // at a zero cut the re-size is the sizing itself, so only `_twin` at the market's cut is pinned
        cfg[2] = 0;
        got = _twin(cfg, p.deleverageTargetBps, units, trig, ps); // the cut-free restore
        if (got <= cap) return (got, cut ? Arm.Resized : Arm.Sizing);
        (got, arm) = base <= room ? (base, Arm.Cap) : (room, Arm.MinDebt);
    }

    /// @dev ONE body, so the fuzz row and the anti-vacuity count can never exercise different code.
    /// @dev It reports the ARM rather than a bare `sold > 0`: which twin was pinned is the thing a count has to distinguish.
    /// @dev A sale of zero reports `Refused` -- both twins predict zero there, so the equality holds without touching either formula.
    function _anchorRun(uint256 seed) private returns (Arm) {
        MarketParams memory p = _anchorParams(seed);
        (bool ok, bytes memory ret) = address(ace).call(abi.encodeCall(Ace.createMarket, (p)));
        if (!ok) return Arm.Refused; // a config genesis refuses is `AceGenesisRails`' row, not this one
        bytes32 mid = abi.decode(ret, (bytes32));
        _seedLadder(mid);
        uint256 loanId = _openAtTheGate(mid, p.minCoverageWad);
        _enterBand(loanId, p.deleverageBandBps, _pick(seed, 24, 1.001e18, 1e18 + (10000 - p.deleverageBandBps) * 1e14 - 1e15));
        (uint256 want, Arm arm) = _predict(mid, loanId, p);
        vm.prank(cranker);
        try keeper.crankDeleverage(loanId) returns (uint256 sold, uint256) {
            assertEq(sold, want, "the hub sold something other than the twin's prediction: the twin has drifted from the sizing");
            return sold > 0 ? arm : Arm.Refused;
        } catch {
            return Arm.Refused; // a refusal is a legal outcome; what it may never be is a different number of units
        }
    }

    /// @notice The anchor, SAMPLED: on an admitted crank the hub's units MUST be what the twin predicts, or this file checks a dead formula.
    /// @notice The prediction is the sizing composed with the scope cap and the `minDebt` cap, re-sized cut-free whenever the sizing does not fit.
    function testFuzz_TheTwinPredictsTheHubCrank(uint256 seed) public {
        _anchorRun(seed);
    }

    /// @notice #366's counterexample, pinned by seed so the anchor's guard no longer rides on the sampler reaching it.
    /// @notice At this seed the settlement reserve binds, so the crank sells `securedBase` and the cap twin is what gets asserted.
    /// @dev `Arm.Cap` and not merely a run: a refusal would satisfy `_anchorRun` while testing nothing, and the cap arm is the claim.
    function test_TheAnchorHoldsAtTheReportedCounterexample() public {
        assertTrue(_anchorRun(3.5e18) == Arm.Cap, "the pinned counterexample no longer sells against the settlement reserve");
    }

    /// @notice A sweep whose every crank refuses asserts NOTHING, so the admitted cranks are counted directly and deterministically.
    /// @notice ALL FOUR arms are counted, because the prediction is four twins composed and one run can only ever pin one of them.
    /// @dev Same body as the fuzz row, so a sampler that stops reaching an admitted crank fails here by name instead of going green.
    /// @dev 200 seeds because the reserve binds only near `MIN_COVERAGE_WAD`, which a uniform draw reaches about once in seventy.
    function test_TheHubAnchorReachesAnAdmittedCrank() public {
        uint256 sizingHits;
        uint256 resizedHits;
        uint256 capHits;
        uint256 minDebtHits;
        for (uint256 s = 1; s <= 200; ++s) {
            uint256 snap = vm.snapshotState();
            Arm arm = _anchorRun(s);
            if (arm == Arm.Sizing) ++sizingHits;
            if (arm == Arm.Resized) ++resizedHits;
            if (arm == Arm.Cap) ++capHits;
            if (arm == Arm.MinDebt) ++minDebtHits;
            vm.revertToState(snap);
        }
        emit log_named_uint("anchored cranks the sizing twin bound, of 200", sizingHits);
        emit log_named_uint("anchored cranks re-sized cut-free, of 200", resizedHits);
        emit log_named_uint("anchored cranks the scope cap bound, of 200", capHits);
        emit log_named_uint("anchored cranks the minDebt cap bound, of 200", minDebtHits);
        assertGt(sizingHits, 2, "the hub anchor never reached a sizing-bound crank, so `_twin` is tied to nothing");
        assertGt(resizedHits, 0, "the hub anchor never reached a re-sized crank, so the cut-free `_twin` is tied to nothing");
        assertGt(capHits, 0, "the hub anchor never reached a cap-bound crank, so `_securedBaseTwin` is tied to nothing");
        assertGt(minDebtHits, 0, "the hub anchor never reached a minDebt-bound crank, so `_minDebtRoomTwin` is tied to nothing");
    }
}
