// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.36;

import {Test} from "forge-std/Test.sol";
import {Ace} from "../../src/ace/hub/Ace.sol";
import {MarketParams, OpenBounds} from "../../src/ace/hub/Types.sol";
import {PositionManager} from "../../src/ace/positions/PositionManager.sol";
import {Constants} from "../../src/ace/hub/Constants.sol";
import {AceLens} from "../../src/ace/lens/AceLens.sol";
import {NotInBand} from "../../src/ace/hub/Deleverage.sol";
import {FullMath} from "@uniswap/v4-core/src/libraries/FullMath.sol";
import {MockERC20} from "../mocks/MockERC20.sol";
import {MockWindowedRecord} from "../mocks/MockWindowedRecord.sol";
import {AceFixtures} from "../utils/AceFixtures.sol";
import {PriceFrame} from "../utils/PriceFrame.sol";
import {AceReader} from "../utils/AceReader.sol";
import {DeleverageCrank} from "../utils/DeleverageCrank.sol";
import {WarpClock} from "../utils/WarpClock.sol";

/// @title AceDeleverageRestoreRace
/// @notice THE QUESTION: the settlement reserve shrinks each crank, so can a falling market outrun the restore?
/// @notice A slower restore costs only if the loan crosses its own stop before it reaches target.
/// @notice Past the stop `deleverage` reverts `DeleverageStopped` and the loan has no brake left at all.
/// @notice So this is a RACE BETWEEN TWO RATES: units the clamped crank sheds per window, against the fall.
/// @dev EVERY OTHER SUITE IN THIS TREE FIRES ITS CRANKS AT ONE TIMESTAMP, on a record mock that ignores its window.
/// @dev That is fine for sizing and useless here: the whole subject is what happens between prints.
/// @dev `MockWindowedRecord` is timestamped and window-honest, and `test_TheWindowIsHonest_*` proves it.
/// @dev A fixture that silently ignored the clock would make every number below meaningless.
/// @dev THE PRICE PATH: one print per persistence window, held for the whole window, then stepped down.
/// @dev That is the cheapest path the channel admits -- each crank gets exactly one window of persistence.
/// @dev THE MEASURED QUANTITY is the headroom `h = k - 1 - b` at the coverage line, in wad.
/// @dev It is the sale's own room: at the line `C - collateralNeeded - sliverUnits` is about `h * requiredAt/k`.
/// @dev `settleBountyBps <= 200` and `minCoverageWad >= 1.05e18` are enforced INDEPENDENTLY at genesis.
/// @dev So their corner product `h = 0.03` is admissible through `createMarket` and nothing bounds it.
/// @dev 18-DECIMAL COLLATERAL ON PURPOSE: the per-tick ceiling is noise against a 1e22-atom position.
/// @dev The measurement is a RATE, not an atom count, which is why the atom regime does not belong here.
/// @dev THE RESERVE DOES NOT MOVE THIS RACE: three measurements, each read clamped and then with the keep mutated out.
/// @dev All three come back EQUAL, so the numbers below are the sizing geometry's, not the reserve's.
/// @dev The breaking decline is 12% per 30-minute window, clamped and unclamped, at BOTH dial sets.
/// @dev At that rate the smallest headroom that holds is `h = 0.24`, clamped and unclamped alike.
/// @dev One rung under it the floor headroom `h = 0.03` already holds, on a flat book and a spread book both.
/// @dev SO THERE IS NO `h_min` A COUPLING RAIL COULD BUY: below the breaking rate nothing needs buying.
/// @dev ALL OF THAT IS THE SIZING GEOMETRY, measured at a two-atom `minDebt` so the no-flip cap never ends a race.
/// @dev A race near the breaking rate melts the debt under one USDC, so at a real floor the CAP binds first: at 100 USDC the break is 5%.
/// @dev WHY A CLOSED FORM GETS THIS WRONG: it charges the clamp one crank per window and the protocol does not.
/// @dev One window of persistence admits every crank while the loan is in band, and an under-restoring crank leaves it there.
/// @dev `test_AClampedCrankDoesNotConsumeItsWindow` pins that, and it took the breaking rate from 6% to 12%.
/// @dev THE CORNER SWEEPS AT `cut = MAX_DELEVERAGE_PROTOCOL_BPS`, the real admissible worst case, and at `cut = 0`.
/// @dev The cut does not matter: a reserve-capped crank re-sizes cut-free with `charge` false, and `_meltAll` gates the cut on it.
/// @dev WHAT THE RESERVE DOES COST IS GAS, NOT SAFETY: splitting one sale into many charges gas per crank.
/// @dev The units sold and the keeper's `eps` take per unit are unchanged, so only the crank count grows.
/// @dev The keeper-economics rows, all at the genesis-floor `k`, measure 7 to 9 cranks against 1, and about 8x the gas per quote retired.
/// @dev At that `k` on a `MIN_DEBT` loan the clamped restore stops paying its own gas.
/// @dev So the liveness question and the incentive question have OPPOSITE answers, and both are measured here.
/// @dev At the shipped `k = 1.4`, floor lifted, the clamp costs at most one extra crank on a `MIN_DEBT` loan and pays: `AceReserveClampRemeasure`.
/// @dev At the shipped `MIN_DEBT` itself the #674 cap ends that loan's sale first, before the reserve binds; that remeasure pins it too.
/// @dev THE GAS ROWS ASSERT A CEILING, NOT A BAND, because the figure is profile-dependent: via-IR optimizes
/// @dev every one of them ~4% cheaper than legacy, so a two-sided band tuned on one profile fails on the other.
/// @dev Only the upward direction was ever the regression, and each ceiling IS its old band's upper edge, so
/// @dev nothing loosened. The measured pair rides beside each assertion as the thing a mutation moves.
contract AceDeleverageRestoreRaceTest is WarpClock, DeleverageCrank {
    Ace internal ace;
    AceReader internal read;
    AceLens internal lens;
    PositionManager internal positionManager;
    MockERC20 internal usdc;
    MockERC20 internal coll;
    MockWindowedRecord internal record;

    address internal alice = address(0xA11CE);
    address internal borrower = address(0xB0B);

    bytes32 internal mid;
    uint256 internal unitScale;

    uint256 internal constant WINDOW = 30 minutes; // `PocDeployConfig.PERSISTENCE_WINDOW`
    uint64 internal constant TENOR = 7 days; // `ProtocolPolicy.MIN_TENOR`, and MAX == MIN so it is the only term
    int24 internal constant SPACING = 60;
    uint256 internal constant TICKS = 12; // seeded ticks; the walk funds at most `CLAIM_TICKS` of them
    uint256 internal constant CLAIM_TICKS = 10; // `PocDeployConfig.MAX_CLAIM_TICKS`, the shipped cap
    uint256 internal constant LOT = 1_500e6; // per tick, so the ladder is never the binding constraint
    uint256 internal constant POSITION = 10_530e18; // collateral units; coverage is what caps the draw
    uint256 internal position = POSITION; // the position this scenario opens with; a small-loan row shrinks it
    uint256 internal raceMinDebt = 2; // the least genesis admits here, so the minDebt cap never ends a race; the cost row raises it
    uint256 internal constant SEED_PRICE_WAD = 4e18; // above every seeded tick, so the draw cap admits the whole ladder
    uint256 internal parT; // this pair's par tick on THIS suite's spacing; the seeded ladder walks down from it
    uint256 internal constant STEPS = 40; // decline windows per race: 20 hours, well inside the tenor

    /// @dev The five decline dials plus the two the headroom is made of.
    struct Dials {
        uint256 k;
        uint256 b;
        uint256 eps;
        uint256 cut;
        uint256 band;
        uint256 target;
        uint256 stop;
    }

    /// @dev What one race reports. `lostChannel` is the outcome the rail exists to prevent.
    struct Race {
        uint256 loanId;
        bool lostChannel;
        bool closed;
        uint256 steps;
        uint256 cranks;
        uint256 sold;
        uint256 held0;
        uint256 firstSold;
        uint256 heldEnd;
        uint256 debt0;
        uint256 debtEnd;
        uint256 liveTicks;
        uint256 thetaStart;
        uint256 thetaMax;
    }

    function _deleverageQuote() internal view override returns (address) {
        return address(usdc);
    }

    function setUp() public {
        _warpTo(1_000_000);
    }

    /* ============================== the fixture ============================== */

    /// @dev A market on a WINDOW-HONEST record, built through `createMarket` so genesis decides admissibility.
    /// @dev The record is aged past its own window before creation; the DRAW door, not genesis, is what needs that history.
    function _build(Dials memory d) internal {
        usdc = new MockERC20("Quote", "Q", 6);
        coll = new MockERC20("Collateral", "C", 18);
        record = new MockWindowedRecord(address(usdc), address(coll));

        parT = PriceFrame.priceAt(address(usdc), address(coll), 0);
        record.push(PriceFrame.px(SEED_PRICE_WAD, address(usdc), address(coll)));
        _warpBy(WINDOW + 1);

        MarketParams memory p = AceFixtures.marketParams(address(usdc), address(coll));
        p.record = address(record);
        p.minCoverageWad = d.k;
        p.settleBountyBps = d.b;
        p.minDebt = raceMinDebt;
        p.deleverageFloorEpsBps = d.eps;
        p.deleverageProtocolBps = d.cut;
        p.deleverageBandBps = d.band;
        p.deleverageTargetBps = d.target;
        p.deleverageStopBps = d.stop;
        p.fillFeeBps = 0;

        AceFixtures.Deployment memory dep = AceFixtures.deploy(p);
        (ace, positionManager, read, mid) = (dep.ace, dep.positionManager, dep.read, dep.id);
        lens = new AceLens(address(dep.ace));
        unitScale = read.marketState(mid).unitScale;
    }

    /// @dev Seed `n` adjacent ticks, walking DOWN from par, splitting the same total across them.
    /// @dev `n == 1` is the WORST CASE for the reserve and the case the rail must be sized against.
    /// @dev Every claim then sits at the funding floor, so `collateralNeeded` is exactly `requiredAt / k`.
    /// @dev The sale's room is exactly `h * requiredAt / k`, with nothing to cushion it.
    /// @dev A wider span prices its claims ABOVE the floor, so the reserve is smaller and the restore faster.
    function _seed(uint256 n) internal returns (uint256 available) {
        available = TICKS * LOT;
        usdc.mint(alice, available);
        vm.startPrank(alice);
        usdc.approve(address(ace), available);
        for (uint256 i; i < n; i++) {
            ace.deposit(mid, available / n);
        }
        vm.stopPrank();
    }

    /// @dev The largest principal the position admits, by bisection on the hub's OWN preview.
    /// @dev So the loan opens exactly ON its coverage line, which is where the headroom `h` is what it says.
    function _maxPrincipal(uint256 hi) internal view returns (uint256) {
        uint256 lo;
        while (lo < hi) {
            uint256 m = (lo + hi + 1) / 2;
            if (_admits(m)) lo = m;
            else hi = m - 1;
        }
        return lo;
    }

    function _admits(uint256 principal) internal view returns (bool) {
        try ace.previewOpen(mid, position, principal, TENOR, borrower, OpenBounds(0, 0, 0)) {
            return true;
        } catch {
            return false;
        }
    }

    function _open(uint256 principal) internal returns (uint256 loanId) {
        coll.mint(borrower, position);
        vm.startPrank(borrower);
        coll.approve(address(positionManager), position);
        loanId = ace.open(mid, position, principal, TENOR, borrower, OpenBounds(0, 0, 0));
        vm.stopPrank();
    }

    /// @dev Live claims on this loan: ONE while it is funded, zero once it retires.
    /// @dev WAS a count over the funded-tick list, which outlived the claims resting on it.
    function _liveTicks(uint256 loanId) internal view returns (uint256) {
        return read.claimCount(mid, loanId);
    }

    /* ================================ the race ================================ */

    /// @notice One print per window, held for the whole window, stepped down by `declineBps` each time.
    /// @notice A crank fires only where the loan is genuinely in band, and the loop stops the moment it is not.
    /// @dev The loop mirrors `Deleverage`'s own gate arithmetic rather than catching its reverts.
    /// @dev So an outcome names WHICH boundary was crossed instead of collapsing every refusal into one catch.
    /// @dev `thetaMax` is the closest the loan ever came to the stop, which is the margin the rail buys.
    /// @param d The market dials.
    /// @param declineBps How far the price falls between one print and the next.
    /// @param maxSteps The decline's length in windows.
    /// @param ticks How many ticks to seed: 1 is the flat-book worst case, more spreads the claims above the floor.
    /// @return r What the race did.
    function _race(Dials memory d, uint256 declineBps, uint256 maxSteps, uint256 ticks) internal returns (Race memory r) {
        _build(d);
        uint256 available = _seed(ticks);
        uint256 principal = _maxPrincipal(available);
        assertGe(principal, 100e6, "fixture: the position must admit a real draw at these dials");
        r.loanId = _open(principal);
        r.held0 = read.loan(r.loanId).collateralUnits;
        r.debt0 = read.loan(r.loanId).debt;
        assertLt(principal, available, "fixture: COVERAGE must be what caps the draw, or the loan is not on its line");
        assertLe(lens.collateralNeeded(mid, r.loanId), r.held0, "fixture: an admitted loan starts covered");

        MarketParams memory p = ace.idToMarketParams(mid);
        uint256 ps = _bandLevel(read.triggerPrice(r.loanId), p.deleverageBandBps) - 1; // one wei inside the band
        r.thetaStart = FullMath.mulDiv(read.triggerPrice(r.loanId), 1e18, ps);
        assertGe(r.thetaStart, 1e18 - p.deleverageBandBps * 1e14, "fixture: the race must start AT band entry, not deeper");
        assertLt(r.thetaStart, 1e18 - p.deleverageBandBps * 1e14 + 1e12, "fixture: and not above it either");

        for (uint256 i; i < maxSteps; i++) {
            record.push(ps);
            _warpBy(WINDOW + 1); // one whole window of this price, and nothing else in it
            r.steps = i + 1;
            if (read.loan(r.loanId).closedAt != 0) {
                r.closed = true;
                break;
            }
            uint256 trig = read.triggerPrice(r.loanId);
            uint256 theta = FullMath.mulDiv(trig, 1e18, ps);
            if (theta > r.thetaMax) r.thetaMax = theta;
            if (ps <= _stopLevel(trig, p.deleverageStopBps)) {
                r.lostChannel = true;
                break;
            }
            /// @dev CRANK UNTIL THE LOAN LEAVES THE BAND, not once: one window of persistence admits every crank that follows.
            /// @dev An under-restoring clamped crank leaves the loan still in band, so the next crank is admitted too.
            /// @dev Cranking once per window would charge the clamp for a limit the protocol does not impose.
            for (uint256 j; j < 20; j++) {
                if (read.loan(r.loanId).closedAt != 0) break;
                if (ps >= _bandLevel(read.triggerPrice(r.loanId), p.deleverageBandBps)) break; // restored out of band
                (uint256 sold,) = ace.deleverage(r.loanId, 0, "");
                if (sold == 0) break; // the reserve took the whole sale: nothing more this window
                if (r.cranks == 0) r.firstSold = sold;
                r.cranks++;
                r.sold += sold;
            }
            ps = (ps * (10000 - declineBps)) / 10000;
        }
        r.liveTicks = _liveTicks(r.loanId);
        r.heldEnd = read.loan(r.loanId).collateralUnits;
        r.debtEnd = read.loan(r.loanId).debt;
        _report(r, declineBps);
    }

    function _bandLevel(uint256 trig, uint256 bandBps) internal pure returns (uint256) {
        return FullMath.mulDivRoundingUp(trig, 1e18, 1e18 - bandBps * 1e14);
    }

    function _stopLevel(uint256 trig, uint256 stopBps) internal pure returns (uint256) {
        return FullMath.mulDivRoundingUp(trig, 1e18, 1e18 - stopBps * 1e14);
    }

    function _report(Race memory r, uint256 declineBps) internal {
        emit log_named_uint("  decline bps", declineBps);
        emit log_named_uint("  funded ticks", r.liveTicks);
        emit log_named_uint("  steps", r.steps);
        emit log_named_uint("  position left, bps of the opening", r.held0 == 0 ? 0 : (r.heldEnd * 10000) / r.held0);
        emit log_named_uint("  cranks", r.cranks);
        emit log_named_uint("  first crank sold, bps of the position", r.held0 == 0 ? 0 : (r.firstSold * 10000) / r.held0);
        emit log_named_uint("  total sold, bps of the position", r.held0 == 0 ? 0 : (r.sold * 10000) / r.held0);
        emit log_named_uint("  debt left, bps of the draw", r.debt0 == 0 ? 0 : (r.debtEnd * 10000) / r.debt0);
        emit log_named_uint("  worst theta, 1e18", r.thetaMax);
        emit log_named_uint("  LOST THE CHANNEL", r.lostChannel ? 1 : 0);
        emit log_named_uint("  closed by the melt", r.closed ? 1 : 0);
    }

    /// @dev Survival is "never crossed its own stop": a melt that retires the loan counts, a stop does not.
    function _survived(Race memory r) internal pure returns (bool) {
        return !r.lostChannel;
    }

    /* ===================== the record honours its window ===================== */

    /// @notice THE CONTROL THIS WHOLE FILE RESTS ON: the record refuses a crank that has not persisted.
    /// @notice The shipped `MockPersistenceRecord` would admit both cranks below, because it drops the window.
    /// @dev Leg 1: a fresh print inside the band, cranked in the SAME block, is refused.
    /// @dev The window still holds the seed price, which is above the band level.
    /// @dev Leg 2: the identical crank one whole window later is admitted.
    /// @dev Without this row a silently window-blind mock would make every rate in this file a fiction.
    function test_TheWindowIsHonest_ACrankNeedsAWholeWindowOfPersistence() public {
        Race memory r;
        _build(_corner(Constants.MIN_COVERAGE_WAD));
        r.loanId = _open(_maxPrincipal(_seed(TICKS)));
        MarketParams memory p = ace.idToMarketParams(mid);
        uint256 ps = _bandLevel(read.triggerPrice(r.loanId), p.deleverageBandBps) - 1;

        record.push(ps);
        vm.expectRevert(NotInBand.selector);
        ace.deleverage(r.loanId, 0, "");

        _warpBy(WINDOW + 1);
        (uint256 sold,) = ace.deleverage(r.loanId, 0, "");
        assertGt(sold, 0, "one whole window of the same price admits the crank the same block refused");
    }

    /// @notice A price that fell only PART way through the window is refused, which is the wick case.
    /// @dev The window still contains the pre-fall print, so `persistedBelow` sees a value above the band.
    /// @dev This is the leg that makes a per-window step the CHEAPEST admissible path rather than an arbitrary one.
    function test_TheWindowIsHonest_APartialWindowDoesNotCount() public {
        Race memory r;
        _build(_corner(Constants.MIN_COVERAGE_WAD));
        r.loanId = _open(_maxPrincipal(_seed(TICKS)));
        MarketParams memory p = ace.idToMarketParams(mid);
        uint256 band = _bandLevel(read.triggerPrice(r.loanId), p.deleverageBandBps);

        record.push(band + 1); // still out of band
        _warpBy(WINDOW / 2);
        record.push(band - 1); // in band, but only for half a window
        _warpBy(WINDOW / 2);
        vm.expectRevert(NotInBand.selector);
        ace.deleverage(r.loanId, 0, "");

        _warpBy(WINDOW / 2 + 1); // now the whole window is the fallen price
        (uint256 sold,) = ace.deleverage(r.loanId, 0, "");
        assertGt(sold, 0, "and it is admitted once the fall has actually persisted");
    }

    /* ============================== the sweep ============================== */

    /// @dev The headroom grid, in wad. The floor is 0.03, which is `MIN_COVERAGE_WAD` against a 200 bps bounty.
    /// @dev Below that nothing is admissible, so the grid starts exactly where `createMarket` does.
    function _grid() internal pure returns (uint256[] memory g) {
        g = new uint256[](10);
        (g[0], g[1], g[2], g[3], g[4]) = (0.03e18, 0.05e18, 0.08e18, 0.12e18, 0.16e18);
        (g[5], g[6], g[7], g[8], g[9]) = (0.2e18, 0.24e18, 0.28e18, 0.32e18, 0.4e18);
    }

    /// @notice The smallest grid headroom whose CLAMPED restore survives `declineBps` per window.
    /// @dev `k` is derived as `1e18 + b * 1e14 + h`, the exact shape of the proposed genesis rail.
    /// @dev So a measured `h` reads straight off as that rail's constant term.
    /// @dev A grid point genesis refuses is SKIPPED, never clamped: it is not an admissible market.
    /// @dev MONOTONICITY IS CHECKED, NOT ASSUMED: a larger headroom losing where a smaller one survived is reported.
    /// @dev That ordering is the premise a single-threshold rail rests on, so hiding a break in it would be dishonest.
    /// @return hMin The first surviving headroom, or `max` if none in the grid survived.
    function _sweep(bool corner, uint256 ticks, uint256 declineBps, uint256 steps) internal returns (uint256 hMin) {
        uint256[] memory g = _grid();
        uint256 b = corner ? Constants.MAX_SETTLE_BOUNTY_BPS : 50;
        bool found;
        bool broke;
        emit log_named_uint("SWEEP: decline per window, bps", declineBps);
        emit log_named_uint("SWEEP: windows", steps);
        emit log_named_uint("SWEEP: seeded ticks", ticks);
        for (uint256 i; i < g.length; i++) {
            uint256 k = 1e18 + b * 1e14 + g[i];
            if (k < Constants.MIN_COVERAGE_WAD) continue; // genesis refuses this headroom outright
            Race memory r = _race(corner ? _corner(k) : _poc(k), declineBps, steps, ticks);
            emit log_named_uint("h, 1e18", g[i]);
            emit log_named_uint("  SURVIVED (1 = yes)", _survived(r) ? 1 : 0);
            if (_survived(r)) {
                if (!found) (hMin, found) = (g[i], true);
            } else if (found) {
                broke = true;
            }
        }
        assertFalse(broke, "a LARGER headroom lost where a smaller one survived: a single-threshold rail cannot hold");
        if (!found) hMin = type(uint256).max;
        emit log_named_uint("SWEEP RESULT: smallest surviving h, 1e18 (max = none)", hMin);
    }

    /// @notice The other axis: hold the headroom and sweep the DECLINE, to find where the restore first loses.
    /// @dev Run before the headroom sweep is meaningful: it establishes whether any rate breaks the floor headroom.
    /// @dev If the floor headroom survives every plausible rate there is no `h_min` to find, which is an answer.
    /// @return breakBps The first rate that lost the channel, or 0 if none in the ladder did.
    function _rateSweep(Dials memory base, uint256 ticks, uint256 h) internal returns (uint256 breakBps) {
        uint256[] memory rates = new uint256[](8);
        (rates[0], rates[1], rates[2], rates[3]) = (800, 900, 1000, 1100);
        (rates[4], rates[5], rates[6], rates[7]) = (1200, 1500, 2000, 3000);
        base.k = 1e18 + base.b * 1e14 + h;
        emit log_named_uint("RATE SWEEP at h, 1e18", h);
        emit log_named_uint("RATE SWEEP cut bps", base.cut);
        emit log_named_uint("RATE SWEEP seeded ticks", ticks);
        for (uint256 i; i < rates.length; i++) {
            Race memory r = _race(base, rates[i], STEPS, ticks);
            emit log_named_uint("rate bps", rates[i]);
            emit log_named_uint("  SURVIVED", _survived(r) ? 1 : 0);
            if (!_survived(r)) {
                breakBps = rates[i];
                break;
            }
        }
        emit log_named_uint("RATE SWEEP RESULT: first losing rate, bps (0 = survived all)", breakBps);
    }

    /* ===================== the measurement, at both dial sets ===================== */

    /// @notice THE MEASURED BOUNDARY, and the two rows are one pin split so a mutation names which side moved.
    /// @notice The dials are the WORST headroom `createMarket` admits: flat book, `h = 0.03`, `k = MIN_COVERAGE_WAD`, 200 bps bounty.
    /// @notice There the clamped restore HOLDS a 10% fall per 30-minute window.
    /// @dev 40 windows of it, which is a 98.5% total collapse over 20 hours, and the channel is never lost.
    /// @dev Pinned rather than logged: this is the number a genesis rail would be argued from.
    function test_CornerFloor_Clamped_HoldsATenPercentWindow() public {
        Race memory r = _race(_corner(Constants.MIN_COVERAGE_WAD), 1000, STEPS, 1);
        _requireClampBinds(r);
        assertFalse(r.lostChannel, "the worst admissible headroom holds a 10% fall per window for 40 windows");
        assertGt(r.cranks, 4, "fixture: the channel must actually be cranking, or the row proves nothing");
    }

    /// @notice And it LOSES at 12% per window. That is the failure a headroom rail would exist to buy off.
    /// @dev The companion row above is what makes this one a boundary rather than an isolated red.
    /// @dev TEETH FOR THE CLAMP: drop `securedBase`'s keep term and read the UNCLAMPED boundary off the rate ladder below.
    /// @dev It is the SAME 12%, which is the finding: the clamp does not move this line at all.
    function test_CornerFloor_Clamped_LosesATwelvePercentWindow() public {
        Race memory r = _race(_corner(Constants.MIN_COVERAGE_WAD), 1200, STEPS, 1);
        _requireClampBinds(r);
        assertTrue(r.lostChannel, "a 12% fall per window outruns the restore at the worst headroom");
        assertLt(r.steps, STEPS, "and it does so inside the decline, not at its end");
    }

    /// @dev THE GUARD AGAINST A VACUOUS RACE: the clamp must be what sized the first crank.
    /// @dev At `h = 0.03` the sizing wants ~4,480 bps of the position and the reserve allows ~285.
    /// @dev So a first crank anywhere near the sized amount means the reserve is inert.
    /// @dev The row would then be measuring the UNCLAMPED restore while claiming to measure the clamped one.
    /// @dev It is also the mutation handle: revert the keep term and every row carrying this goes red here.
    /// @dev That is how the clamped and unclamped outcomes can be told apart at all.
    function _requireClampBinds(Race memory r) internal pure {
        require((r.firstSold * 10000) / r.held0 < 1000, "FIXTURE: the reserve did not bind, so this race is not the clamped one");
    }

    /// @notice The same boundary at PoC dials, whose smallest admissible headroom is 0.045 rather than 0.03.
    function test_PocFloor_Clamped_HoldsATenPercentWindow() public {
        Race memory r = _race(_poc(Constants.MIN_COVERAGE_WAD), 1000, STEPS, 1);
        _requireClampBinds(r);
        assertFalse(r.lostChannel, "PoC dials at their own smallest admissible headroom hold a 10% window");
    }

    /// @notice And PoC dials lose at 12% too, so the boundary is not a property of the corner's eps and cut.
    function test_PocFloor_Clamped_LosesATwelvePercentWindow() public {
        Race memory r = _race(_poc(Constants.MIN_COVERAGE_WAD), 1200, STEPS, 1);
        _requireClampBinds(r);
        assertTrue(r.lostChannel, "a 12% fall per window outruns the restore at PoC dials too");
    }

    /// @notice THE RATE LADDER behind the two boundary rows, and the number a headroom rail would be argued from.
    /// @notice PINNED, not logged: this is the row a clamp mutation is read through.
    /// @notice Revert the keep term and whatever this prints instead IS the unclamped boundary.
    /// @notice That comparison decides whether a genesis rail on the headroom buys the loan anything at all.
    /// @dev 600 would mean the clamped restore at the worst admissible headroom holds a 5% fall and loses a 6% one.
    /// @dev The book is flat and the decline runs 40 consecutive 30-minute windows.
    function test_Corner_FlatBook_DeclineRateSweep() public {
        assertEq(_rateSweep(_corner(0), 1, 0.03e18), 1200, "the corner floor's measured breaking decline, bps per window");
    }

    /// @notice The same ladder at PoC dials, so the boundary is not read off one eps and cut.
    function test_PocDials_FlatBook_DeclineRateSweep() public {
        assertEq(_rateSweep(_poc(0), 1, 0.045e18), 1200, "the PoC floor's measured breaking decline, bps per window");
    }

    /// @notice THE `minDebt` CAP'S MEASURED COST: at a 100 USDC floor the PoC floor's breaking decline falls from 12% to 5% per window.
    /// @notice Once a declining loan's debt reaches `minDebt` the channel sells nothing more, so the loan crosses its stop and settles.
    /// @dev The draw is ~10,029 USDC, so the floor is ~1% of it; a race retires ~99% of the debt at 4% per window (debt left ~1.07%).
    /// @dev The 5% leg is re-run at the two-atom floor the rows above use, where it survives: the cap, not the geometry, is what lost it.
    /// @dev The accepted cost of the no-flip rule: the stranded tail de-risks by title transfer at `finalize`, never as lender bad debt.
    function test_TheMinDebtCapLowersTheBreakingDecline_AtAHundredUsdcFloor() public {
        Dials memory d = _poc(0);
        d.k = 1e18 + d.b * 1e14 + 0.045e18;
        raceMinDebt = 100e6;
        Race memory holds = _race(d, 400, STEPS, 1);
        assertFalse(holds.lostChannel, "at a 100 USDC floor a 4% fall per window still holds");
        Race memory loses = _race(d, 500, STEPS, 1);
        assertTrue(loses.lostChannel, "and a 5% fall per window loses the channel");
        assertEq(loses.debtEnd, 100e6, "with the debt parked exactly on the floor: the cap stopped the restore");
        raceMinDebt = 2;
        Race memory control = _race(d, 500, STEPS, 1);
        assertFalse(control.lostChannel, "the same 5% race at a two-atom floor holds, so the floor is the whole difference");
    }

    /// @notice THE PROTOCOL CUT DOES NOT MOVE THIS RACE EITHER, and the reason is structural rather than numeric.
    /// @notice A reserve-capped crank re-sizes cut-free with `charge` false, and `_meltAll` gates the cut on `charge`.
    /// @notice So the CLAMPED restore is already cut-free at every dial value the envelope admits.
    /// @dev Corner dials with `deleverageProtocolBps` swept from its ceiling to zero, everything else identical.
    /// @dev Both land on the same breaking rate, so `h_min` never depended on the cut.
    /// @dev Worth pinning because it was argued both ways before it was measured.
    function test_TheProtocolCutDoesNotMoveTheBreakingRate() public {
        Dials memory noCut = _corner(0);
        noCut.cut = 0;
        assertEq(_rateSweep(noCut, 1, 0.03e18), 1200, "cut = 0 breaks at the same rate as cut = MAX_DELEVERAGE_PROTOCOL_BPS");
    }

    /// @notice THE DELIVERABLE, worst case: a FLAT BOOK, where the sale's room is exactly `h * requiredAt / k`.
    /// @notice One funded tick means every claim prices at the funding floor, so nothing cushions the reserve.
    /// @notice This is what a genesis rail has to be sized against, since a one-tick draw is ordinary.
    /// @notice IT MEASURES `h_min` ITSELF, AND THE ANSWER IS THAT THERE IS NONE TO BUY.
    /// @notice Below the breaking rate the floor headroom already holds, so no rail is needed.
    /// @notice AT the breaking rate NO headroom in the grid holds, so no rail helps.
    /// @notice The clamped and unclamped boundaries are the SAME rate, so the clamp is not what loses it.
    /// @dev Three decline rates, each swept over the headroom grid. The emitted table is the evidence.
    /// @dev Asserted loosely on purpose: the ASSERTION is monotonicity plus "some admissible headroom works".
    /// @dev The NUMBER is the log; a hard-coded threshold would pin today's arithmetic, not the property.
    /// @dev The grid reaches 0.30, which at a 200 bps bounty is `minCoverageWad = 1.32e18`.
    /// @dev That is far past anything a coupling rail would plausibly demand, and it still loses.
    function test_Corner_FlatBook_HeadroomSweep_AtTheBreakingRate() public {
        assertEq(_sweep(true, 1, 1200, STEPS), 0.24e18, "h_min at the breaking rate, and the mutation says whether the clamp caused it");
    }

    /// @notice And one rung UNDER the breaking rate the floor headroom is already enough, at 0.03.
    /// @dev The pair makes "there is no h_min to find" a measurement rather than an absence of data.
    /// @dev The grid's smallest point wins below the line and its largest point loses above it.
    function test_Corner_FlatBook_HeadroomSweep_UnderTheBreakingRate() public {
        assertEq(_sweep(true, 1, 1100, STEPS), 0.03e18, "one rung under the breaking rate the floor headroom already holds");
    }

    /// @notice The same sweep on a SPREAD book, which is the cushion a flat book does not get.
    /// @notice Claims above the funding floor make `collateralNeeded` smaller than `requiredAt / k`.
    /// @notice So the reserve keeps back less and the same headroom buys a faster restore.
    /// @dev Reported beside the flat book so a rail is never sized off the lucky case.
    function test_Corner_SpreadBook_HeadroomSweep_UnderTheBreakingRate() public {
        assertEq(_sweep(true, TICKS, 1100, STEPS), 0.03e18, "a spread book needs no extra headroom either");
    }

    /// @notice THE MECHANISM behind every equality above: A CLAMPED CRANK DOES NOT CONSUME ITS WINDOW.
    /// @notice One window of persistence admits every crank that follows while the loan is still in band.
    /// @notice An under-restoring clamped crank leaves it in band by construction, so the next crank runs too.
    /// @notice The reserve therefore splits one large sale into many small ones INSIDE one window.
    /// @notice It does not slow the restore, which is why the clamped and unclamped breaking rates come out equal.
    /// @dev The loan is armed DEEP in the band -- theta 0.80 against a band edge of 0.70 -- so one clamped crank cannot restore it out.
    /// @dev That is exactly the state a one-crank-per-window model mis-scores.
    /// @dev Both cranks run at the SAME instant on the test clock, asserted, so nothing rides on a second window.
    function test_AClampedCrankDoesNotConsumeItsWindow() public {
        _build(_corner(Constants.MIN_COVERAGE_WAD));
        uint256 loanId = _open(_maxPrincipal(_seed(1)));
        MarketParams memory p = ace.idToMarketParams(mid);
        uint256 trig = read.triggerPrice(loanId);
        uint256 ps = FullMath.mulDiv(trig, 1e18, 0.8e18); // deep in the band, clear of the stop at 0.8231
        assertLt(ps, _bandLevel(trig, p.deleverageBandBps), "fixture: the arming level must be inside the band");
        assertGt(ps, _stopLevel(trig, p.deleverageStopBps), "fixture: and clear of the stop");

        record.push(ps);
        _warpBy(WINDOW + 1);
        uint256 at = _clock;

        (uint256 first,) = ace.deleverage(loanId, 0, "");
        assertGt(first, 0, "fixture: the first crank must sell");
        assertLt((first * 10000) / read.loan(loanId).collateralUnits, 1000, "fixture: and it must be the RESERVE that sized it");
        assertLt(FullMath.mulDiv(read.triggerPrice(loanId), 1e18, ps), 0.8e18, "the clamped crank did restore something");
        assertGt(
            FullMath.mulDiv(read.triggerPrice(loanId), 1e18, ps),
            1e18 - p.deleverageBandBps * 1e14,
            "and left the loan STILL IN BAND, which is what admits the next crank"
        );

        (uint256 second,) = ace.deleverage(loanId, 0, "");
        assertEq(_clock, at, "both cranks ran in the same block, on ONE window of persistence");
        assertGt(second, 0, "SO THE SECOND CRANK IS ADMITTED IMMEDIATELY: the reserve costs sales, not time");
    }

    /* ===================== keeper economics: cranks, gas, pay ===================== */

    /// @dev What one restore from band entry to target cost the keeper and paid it.
    struct Restore {
        uint256 cranks;
        uint256 gas; // measured around the `deleverage` calls only, so fixture work is not charged to the keeper
        uint256 unitsSold;
        uint256 quotePaid; // what the keeper handed ACE for those units
        uint256 gross; // the same units valued at the reference the sale itself used
        uint256 pay; // gross less quotePaid: the eps discount, which is the keeper's WHOLE revenue
        uint256 debtBefore;
        uint256 debtAfter;
        bool restoredOut;
    }

    /// @notice ONE loan, armed at the DEEPEST margin the channel admits, cranked until it restores out of band.
    /// @notice Clamped that is many small sales; unclamped it is one large one. Same restore, same window.
    /// @dev THE DEEPEST FILL, not band entry, and the difference is the whole measurement.
    /// @dev At the band EDGE any restore at all exits the band, so even the corner's clamped crank finishes in one.
    /// @dev The multi-crank cost the reserve is accused of never appears there; one wei above the stop is where it does.
    /// @dev The price is held FIXED for the whole restore -- this measures the cost of restoring, not a race.
    /// @dev Gas is metered around each `deleverage` call alone, so seeding and reads are not charged to the keeper.
    /// @dev Pay is `units * floorPrice / unitScale - quotePaid`, and the floor IS `ps`, so the discount is exactly eps.
    function _restoreFromDeepestFill(Dials memory d, uint256 ticks, uint256 pct) internal returns (Restore memory r) {
        _build(d);
        uint256 available = _seed(ticks);
        uint256 loanId = _open((_maxPrincipal(available) * pct) / 100);
        r.debtBefore = read.loan(loanId).debt;

        MarketParams memory p = ace.idToMarketParams(mid);
        uint256 ps = _stopLevel(read.triggerPrice(loanId), p.deleverageStopBps) + 1;
        assertLt(ps, _bandLevel(read.triggerPrice(loanId), p.deleverageBandBps), "fixture: the corridor must be open");
        record.push(ps);
        _warpBy(WINDOW + 1);

        for (uint256 i; i < 400; i++) {
            if (read.loan(loanId).closedAt != 0) break;
            if (ps >= _bandLevel(read.triggerPrice(loanId), p.deleverageBandBps)) {
                r.restoredOut = true;
                break;
            }
            uint256 before = gasleft();
            (uint256 sold,) = ace.deleverage(loanId, 0, "");
            r.gas += before - gasleft();
            if (sold == 0) break;
            r.cranks++;
            r.unitsSold += sold;
            r.quotePaid += lastQuoteOwed;
        }
        r.debtAfter = read.loan(loanId).debt;
        r.gross = FullMath.mulDiv(r.unitsSold, ps, unitScale);
        r.pay = r.gross > r.quotePaid ? r.gross - r.quotePaid : 0;

        emit log_named_uint("  cranks", r.cranks);
        emit log_named_uint("  total gas", r.gas);
        emit log_named_uint("  gas per crank", r.cranks == 0 ? 0 : r.gas / r.cranks);
        emit log_named_uint("  keeper pay, quote wei", r.pay);
        emit log_named_uint("  debt retired, quote wei", r.debtBefore - r.debtAfter);
        emit log_named_uint("  restored out of the band (1 = yes)", r.restoredOut ? 1 : 0);
    }

    /// @dev Gas charged per QUOTE TOKEN of debt retired, which is the only form the two paths compare in.
    /// @dev A clamped restore stops at the band edge and an unclamped one overshoots to target.
    /// @dev They do different amounts of work, so their raw totals are not comparable; per unit of work they are.
    /// @dev CEILINGED, NOT PINNED, wherever it is asserted against a constant: see the contract header.
    /// @dev The legacy build and the via_ir build meter the same cranks differently, by 6, 6 and 11 gas per quote.
    /// @dev This block USED to claim each pin was centred on that pair. It was not -- all three sat on the legacy
    /// @dev figure, which is why relighting the via_ir lane found them red at once. Centring is not reintroduced.
    /// @dev Foundry also meters a whole test body as one EIP-2929 context, worth about one gas per quote.
    /// @dev The gap these rows report is ~9x, far outside both, so the slack costs the conclusion nothing.
    function _gasPerQuote(Restore memory r) internal pure returns (uint256) {
        return (r.gas * 1e6) / (r.debtBefore - r.debtAfter);
    }

    /// @dev The keeper's take as bps of the debt it retired: `eps / (1 - eps)` on a clamped crank.
    /// @dev The cut divides in on an unclamped one, so this is where it shows up in the keeper's own accounts.
    function _payBps(Restore memory r) internal pure returns (uint256) {
        return (r.pay * 10000) / (r.debtBefore - r.debtAfter);
    }

    /// @notice THE KEEPER-ECONOMICS PINS, split one per row so a clamp mutation names EVERY number it moves.
    /// @notice A single row would stop at its first failed assertion and hide the other two.
    /// @dev Corner dials, flat book, loan on its coverage line, armed one wei above its own stop.
    function test_KeeperEconomics_Corner_CrankCount() public {
        assertEq(_restoreFromDeepestFill(_corner(Constants.MIN_COVERAGE_WAD), 1, 100).cranks, 7, "cranks to restore out of band");
    }

    /// @notice THE NUMBER THE CONCERN RESTS ON: gas per quote token of debt retired, clamped.
    /// @dev If the reserve made keeping uneconomic, this is where it would show, and the mutation says by how much.
    /// @dev THE CEILING BINDS ONLY THE DEAR DIRECTION, so it does not itself catch the reserve being neutered:
    /// @dev that mutation collapses 7 cranks toward 1 and drives this number DOWN. `_Corner_CrankCount` is what
    /// @dev fails then, and it is the row to keep green-sensitive if this one is ever re-tuned.
    function test_KeeperEconomics_Corner_GasPerQuoteRetired() public {
        uint256 g = _gasPerQuote(_restoreFromDeepestFill(_corner(Constants.MIN_COVERAGE_WAD), 1, 100));
        assertLt(g, 155, "gas per quote of debt retired"); // legacy 149, IR 143; WAS 157 before the tick walk went
    }

    /// @notice And the revenue side: the keeper's take as bps of the debt it retired.
    function test_KeeperEconomics_Corner_PayPerQuoteRetired() public {
        assertEq(_payBps(_restoreFromDeepestFill(_corner(Constants.MIN_COVERAGE_WAD), 1, 100)), 204, "keeper pay, bps of debt retired");
    }

    function test_KeeperEconomics_Poc_CrankCount() public {
        assertEq(_restoreFromDeepestFill(_poc(Constants.MIN_COVERAGE_WAD), 1, 100).cranks, 9, "cranks to restore out of band");
    }

    function test_KeeperEconomics_Poc_GasPerQuoteRetired() public {
        assertLt(_gasPerQuote(_restoreFromDeepestFill(_poc(Constants.MIN_COVERAGE_WAD), 1, 100)), 137, "gas per quote of debt retired"); // legacy 131, IR 125
    }

    function test_KeeperEconomics_Poc_PayPerQuoteRetired() public {
        assertEq(_payBps(_restoreFromDeepestFill(_poc(Constants.MIN_COVERAGE_WAD), 1, 100)), 101, "keeper pay, bps of debt retired");
    }

    /// @notice THE SMALLEST ADMISSIBLE LOAN, which is where the concern bites hardest.
    /// @notice Gas is charged PER CRANK and the debt retired per crank scales with the loan.
    /// @notice So gas per unit of work rises as the loan shrinks while the keeper's `eps` take per unit does not.
    /// @dev The position is sized so the draw lands near `Defaults.MIN_DEBT`, which the rows above sit at ~2x.
    /// @dev This is the review's owed keeper-economics row, and it is the number to price a gas market against.
    function test_KeeperEconomics_Poc_MinDebtLoan_GasPerQuoteRetired() public {
        position = 5_450e18;
        Restore memory r = _restoreFromDeepestFill(_poc(Constants.MIN_COVERAGE_WAD), 1, 100);
        emit log_named_uint("  debt at open, quote wei", r.debtBefore);
        assertLt(r.debtBefore, 6_000e6, "fixture: the loan must be near MIN_DEBT, not a multiple of it");
        assertLt(_gasPerQuote(r), 265, "gas per quote of debt retired at the smallest admissible loan"); // legacy 254, IR 243; WAS 268
    }

    uint256 internal constant GAS_PRICE_WEI = 30 gwei; // AN ASSUMPTION ABOUT THE WORLD, named so it can be argued with
    uint256 internal constant ETH_IN_QUOTE = 3_000e6; // quote wei per 1e18 wei of gas token, at the same assumption

    /// @notice THE FINDING, PINNED AS A DEFECT: at the genesis-floor `k` on the smallest admissible loan, the CLAMPED restore does not pay its gas.
    /// @notice At the shipped `k = 1.4` it pays at the same debt and gas, floor lifted; at the shipped `MIN_DEBT` the #674 cap ends the sale first.
    /// @notice Mutate the reserve away and the same restore clears it easily.
    /// @notice So the settlement reserve makes the keeper-incentive problem WORSE, and this row is where a later reader will find that.
    /// @dev The mechanism is not a smaller take: gas is charged PER CRANK while `eps` is charged per UNIT SOLD.
    /// @dev The reserve splits one sale into many without changing the units, so only the crank count grows.
    /// @dev Pay per unit of work barely moves (101 bps clamped against 106 unclamped); gas per unit of work goes up 7.4x.
    /// @dev The gas price and the gas-token price are ASSUMPTIONS and are named above.
    /// @dev The protocol quantities they multiply -- gas used, units sold, quote paid, debt retired -- are all measured.
    function test_KeeperEconomics_MinDebtLoan_ClampedRestoreDoesNotPayItsOwnGas() public {
        position = 5_450e18;
        Restore memory r = _restoreFromDeepestFill(_poc(Constants.MIN_COVERAGE_WAD), 1, 100);
        uint256 gasCost = (r.gas * GAS_PRICE_WEI * ETH_IN_QUOTE) / 1e18;
        emit log_named_uint("  keeper pay, quote wei", r.pay);
        emit log_named_uint("  gas cost at the named assumption, quote wei", gasCost);
        assertLt(r.pay, gasCost, "DEFECT PIN: the clamped restore costs the keeper more gas than it earns");
    }

    /* ========================= the two dial sets ========================= */

    /// @dev The worst headroom `createMarket` admits today: `b` at its ceiling, `k` at its floor, `h = 0.03`.
    /// @dev The eps and the cut also sit at their ceilings, and the stop one bps above the sell-max onset.
    function _corner(uint256 k) internal pure returns (Dials memory d) {
        d = Dials({k: k, b: Constants.MAX_SETTLE_BOUNTY_BPS, eps: 200, cut: 2000, band: 3000, target: 4000, stop: 1769});
    }

    /// @dev The shipped decline dials: b = 50, eps = 100, cut = 500, band 3000 / target 5000 / stop 1000.
    /// @dev `k` is the caller's: every fixed row passes the genesis floor 1.05, not the shipped 1.4; only the headroom sweeps vary it.
    function _poc(uint256 k) internal pure returns (Dials memory d) {
        d = Dials({k: k, b: 50, eps: 100, cut: 500, band: 3000, target: 5000, stop: 1000});
    }
}
