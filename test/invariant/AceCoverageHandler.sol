// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.36;

import {FullMath} from "@uniswap/v4-core/src/libraries/FullMath.sol";
import {Ace} from "../../src/ace/hub/Ace.sol";
import {AceLens} from "../../src/ace/lens/AceLens.sol";
import {Loan, MarketParams, OpenBounds} from "../../src/ace/hub/Types.sol";
import {PositionManager} from "../../src/ace/positions/PositionManager.sol";
import {ProtocolPolicy} from "../../src/config/Defaults.sol";
import {MockERC20} from "../mocks/MockERC20.sol";
import {MockPersistenceRecord} from "../mocks/MockPersistenceRecord.sol";
import {MockRateERC20} from "../mocks/MockRateERC20.sol";
import {AceFixtures} from "../utils/AceFixtures.sol";
import {PriceFrame} from "../utils/PriceFrame.sol";
import {AceReader} from "../utils/AceReader.sol";
import {DeleverageCrank} from "../utils/DeleverageCrank.sol";
import {WarpClock} from "../utils/WarpClock.sol";

/// @title AceCoverageHandler
/// @notice The fuzzing surface for ONE market at 8-dec collateral against an 18-dec quote.
/// @notice That pair is the regime the coverage invariant can actually FAIL in, and `AceHandler` cannot reach it.
/// @dev Par sits ~1e10 above the Q96 unit there, so one collateral atom is worth ~1e10 quote atoms.
/// @dev Settlement and the withdrawal gate each ceil, so a few atoms of sale erosion can outrun the margin.
/// @dev That gap only bites when the coverage margin, MEASURED IN COLLATERAL WEI, falls under the slack.
/// @dev So the regime needs a large `omega` AND dust debt, which is what `repayToDust` exists to reach.
/// @dev THE PER-FUNDED-TICK CEILING ARGUMENT IS GONE: a market names one price and a draw funds one claim.
/// @dev `THIN_SLACK_UNITS` carries the old slack number forward unchanged, so the campaign still reaches the window.
/// @dev A SEPARATE handler and not a parameterized `AceHandler`: that one hardcodes a 6-dec quote in its constructor.
/// @dev Its amounts, seeds and bounds are all tuned to this pair's literals, for 30 invariants.
/// @dev SOLE TENANT: the market names `lenders[0]`, and `lenders[1]` is the stranger the gate must refuse.
/// @dev Every action is bounded and try/catch-guarded (fail_on_revert = false), like its sibling.
contract AceCoverageHandler is WarpClock, DeleverageCrank {
    function _deleverageQuote() internal view override returns (address) {
        return address(usdc);
    }

    uint8 internal constant C_DEC = 8; // the collateral: 8 decimals, fewer than the quote, so par sits above the Q96 unit
    uint8 internal constant Q_DEC = 18; // the quote: 18 decimals
    uint256 internal constant COLL = 8e9; // 80 collateral tokens per draw
    uint256 internal constant PER_SEED = 2.5e18; // 2.5 quote tokens per seeding deposit
    uint256 internal constant SEEDS_N = 16; // seeding deposits; the baseline draw takes the whole of them
    uint256 internal constant THIN_SLACK_UNITS = 32; // collateral atoms the thin window is measured against
    uint256 internal constant MAX_LOANS = 4; // the O(loans) invariants bound on it
    uint256 internal constant BAND_BPS = 3000; // the deleverage channel opens under a 30% margin
    uint256 internal constant TARGET_BPS = 4000; // and restores to 40%

    Ace public ace;
    AceLens public lens;
    PositionManager public positionManager;
    AceReader public read;
    MockERC20 public usdc;
    MockRateERC20 public coll;
    MockPersistenceRecord public record;
    bytes32 public id;
    uint256 public unitScale;

    /// @dev `lenders[0]` IS the market's named tenant; `lenders[1]` is the stranger the deposit gate must refuse.
    /// @dev The stranger is kept rather than dropped so the refusal door stays lit and `strangerRested` can witness it.
    address[2] public lenders = [AceFixtures.LENDER, address(0xA11CF)];
    address[2] public borrowers = [address(0xB0B), address(0xB0C)];

    uint256[] internal _loanIds;
    mapping(uint256 => bool) internal _knownLoan;

    uint256 public loansOpened;
    uint256 public dustRepays; // repays that landed the debt inside the coverage-thin window
    uint256 public lineWithdrawals; // withdrawals driven off the lens that actually moved units
    uint256 public deleveragesDone; // decline-channel cranks that sold units
    uint256 public settlements; // expiry folds that closed a loan
    uint256 public erodedOnTheLine; // deleverages run on a loan already at or under its line: a REACH counter
    uint256 public cranksAttempted; // deleverage calls the handler put to the hub
    uint256 public cranksLanded; // of those, the ones the hub did not refuse
    uint256 public strangerDepositsRefused; // deposits by the non-tenant the sole-tenancy gate turned away
    bool public strangerRested; // a non-tenant's cash landed here: sole tenancy, falsified

    mapping(bytes32 => uint256) public calls;

    constructor() {
        _warpTo(1_000_000);
        usdc = new MockERC20("Quote", "Q", Q_DEC);
        coll = new MockRateERC20("Collateral", "C", C_DEC);
        record = new MockPersistenceRecord(address(usdc), address(coll));

        MarketParams memory p = AceFixtures.marketParams(address(usdc), address(coll));
        p.record = address(record);
        p.lender = lenders[0]; // NAMED, not inherited: a market is sole-tenant and only this address may rest cash
        p.deleverageFloorEpsBps = ProtocolPolicy.DELEVERAGE_FLOOR_EPS_BPS;
        p.deleverageBandBps = BAND_BPS;
        p.deleverageTargetBps = TARGET_BPS;
        p.deleverageStopBps = 1; // tiny, so a near-trigger fixture stays admitted; the cut stays 0

        AceFixtures.Deployment memory d = AceFixtures.deploy(p);
        (ace, positionManager, read, id) = (d.ace, d.positionManager, d.read, d.id);
        lens = new AceLens(address(ace));
        unitScale = read.marketState(id).unitScale;
        /// @dev THE REGIME CHECK, and it is falsifiable: par is the Q96 unit exactly when the two decimals match.
        /// @dev The old form asked `parT > 0` of a tick index, which a raw Q96 price makes trivially true.
        require(p.price > 1 << 96, "FIXTURE: par must sit above the Q96 unit, or the fewer-decimal-collateral regime is not reached");

        record.setAbove(true);
        record.setMinPrice(PriceFrame.px(2e18, address(usdc), address(coll))); // above the market's own price

        for (uint256 i; i < SEEDS_N; i++) {
            _seed(lenders[0], PER_SEED);
        }

        _baseline();
    }

    /// @notice ONE draw, taking the whole seeded depth, so it stands at the market's one price with no slack to spare.
    /// @dev A second baseline loan would split the depth and neither half would reach the tight edge.
    /// @dev The line withdrawal is DELIBERATELY LEFT OUT: reaching it is the campaign's own job to prove.
    function _baseline() internal {
        uint256 loanId = _openStrict(borrowers[0], SEEDS_N * PER_SEED);
        require(read.claimCount(id, loanId) == 1, "BASELINE: the draw funded no claim, so it took no depth");
    }

    /// @notice The two DISPOSAL channels, exercised once pre-snapshot so neither can be silently inert.
    /// @notice Called by the invariant suite's setUp rather than the constructor, and it has to be.
    /// @dev Solver routing calls `onAceDeleverage` back on this address, which has no code inside its own constructor.
    /// @dev Every fuzz action is try/catch-guarded, so a channel dead on every sequence would still tally healthy.
    /// @dev UNGUARDED on purpose: a refusal here must name itself rather than trip a generic require.
    /// @dev Ordered healthy-first: both channels size off real debt, and the dust repay would starve them.
    function baselineDisposal() external {
        uint256 loanId = _loanIds[0];

        _enterBand(loanId);
        uint256 held = read.loan(loanId).collateralUnits;
        ace.deleverage(loanId, 0, "");
        require(read.loan(loanId).collateralUnits < held, "BASELINE: the deleverage sold nothing -- the channel is inert");
        deleveragesDone++;
        _heal();

        _repayTo(loanId, 2e10);
        require(dustRepays > 0, "BASELINE: the repay never reached the coverage-thin window");
    }

    /* ============================ helpers ============================ */

    /// @dev Rest `amt` for `who`, and witness the sole-tenancy gate on the way past it.
    /// @dev A stranger's deposit MUST be refused, so its landing is latched rather than swallowed.
    function _seed(address who, uint256 amt) internal {
        usdc.mint(who, amt);
        vm.startPrank(who);
        usdc.approve(address(ace), amt);
        uint256 had = read.restingOf(id);
        try ace.deposit(id, amt) {
            if (who != lenders[0] && read.restingOf(id) > had) strangerRested = true;
        } catch {
            if (who != lenders[0]) strangerDepositsRefused++;
        }
        vm.stopPrank();
    }

    function _bump(string memory tag) internal {
        calls[keccak256(bytes(tag))]++;
    }

    /// @notice Per-action call count, for the run report.
    function callCount(string memory tag) external view returns (uint256) {
        return calls[keccak256(bytes(tag))];
    }

    /// @notice Every loan id the fuzzer has opened and tracks.
    function loanIds() external view returns (uint256[] memory) {
        return _loanIds;
    }

    /// @dev Collateral, fee headroom and both approvals for one draw by `who`.
    function _fund(address who, uint256 principal) internal {
        coll.mint(who, COLL);
        usdc.mint(who, principal); // headroom for the origination fee, which nets out of the payout
        vm.startPrank(who);
        coll.approve(address(positionManager), COLL);
        usdc.approve(address(ace), principal);
        vm.stopPrank();
    }

    function _track(uint256 loanId) internal {
        if (_knownLoan[loanId]) return;
        _knownLoan[loanId] = true;
        _loanIds.push(loanId);
        loansOpened++;
    }

    /// @dev Fund a draw for `who` and register it if it opens; a refusal is a legitimate fuzz outcome.
    function _open(address who, uint256 principal) internal {
        _fund(who, principal);
        vm.prank(who);
        try ace.open(id, COLL, principal, 0, who, OpenBounds(0, 0, 0)) returns (uint256 loanId) {
            _track(loanId);
        } catch {}
    }

    /// @dev The BASELINE draw, unguarded: a refusal here must name itself, not trip a generic require.
    function _openStrict(address who, uint256 principal) internal returns (uint256 loanId) {
        _fund(who, principal);
        vm.prank(who);
        loanId = ace.open(id, COLL, principal, 0, who, OpenBounds(0, 0, 0));
        _track(loanId);
    }

    /// @dev Repay `loanId` down to `target`, counting the ones that land in the coverage-thin window.
    /// @dev The window is `(k - 1) x debt / omega < n`: the margin in collateral wei under the ceiling slack.
    function _repayTo(uint256 loanId, uint256 target) internal {
        Loan memory l = read.loan(loanId);
        if (l.closedAt != 0 || l.debt <= target) return;
        uint256 pay = l.debt - target;
        usdc.mint(l.borrower, pay);
        vm.startPrank(l.borrower);
        usdc.approve(address(ace), pay);
        try ace.repay(loanId, pay) {
            if (_thin(loanId)) dustRepays++;
        } catch {}
        vm.stopPrank();
    }

    /// @dev Is this loan's coverage margin AT ITS OWN LINE inside the slack a settlement's ceilings can spend?
    /// @dev Measured at the line, never at the holding: a loan that never withdrew is loose whatever its debt.
    /// @dev The line is what a borrower may legally stand on, so it is where the margin has to be counted.
    /// @dev From the expiry second `withdrawableUnits` reads zero, so on a matured loan this figure is the whole holding, not the line.
    function _thin(uint256 loanId) internal view returns (bool) {
        Loan memory l = read.loan(loanId);
        if (l.closedAt != 0 || l.debt == 0) return false;
        uint256 line = l.collateralUnits - lens.withdrawableUnits(id, loanId);
        return lens.collateralNeeded(id, loanId) + THIN_SLACK_UNITS > line;
    }

    /// @dev Park the record inside the deleverage band for `loanId`, exactly as the channel's own suite does.
    function _enterBand(uint256 loanId) internal {
        uint256 trig = read.triggerPrice(loanId);
        if (trig == 0) return;
        uint256 bandLevel = FullMath.mulDivRoundingUp(trig, 1e18, 1e18 - BAND_BPS * 1e14);
        uint256 ps = trig + trig / 50; // a real 2% margin: inside the band, clear of the stop
        record.setBelowBand(bandLevel);
        record.setMinPrice(ps);
    }

    function _heal() internal {
        record.setBelowBand(0);
        record.setBelow(false);
        record.setAbove(true);
        record.setMinPrice(PriceFrame.px(2e18, address(usdc), address(coll)));
    }

    /// @dev One deleverage, counting the ones that sold out from under a loan already standing on its line.
    /// @dev The count is REACH, never a carve-out: every loan is held to exact coverage whatever it reports.
    function _crankDeleverage(uint256 loanId) internal {
        bool onLine = _onTheLine(loanId);
        uint256 before = read.loan(loanId).collateralUnits;
        cranksAttempted++;
        try ace.deleverage(loanId, 0, "") {
            cranksLanded++;
            if (read.loan(loanId).collateralUnits < before) {
                deleveragesDone++;
                if (onLine) erodedOnTheLine++;
            }
        } catch {}
    }

    /// @dev Does this loan sit at or under its withdrawal line, where a sale has no spare units to take?
    function _onTheLine(uint256 loanId) internal view returns (bool) {
        return read.loan(loanId).closedAt == 0 && lens.withdrawableUnits(id, loanId) == 0;
    }

    /* ============================ the actions ============================ */

    /// @notice Rest cash, from the tenant on most seeds and from the stranger on the rest.
    /// @dev The tick argument is GONE with the ladder: this market holds cash at one price and there is nothing to pick.
    function deposit(uint256 actorSeed, uint256 amtSeed) external {
        _bump("deposit");
        _seed(lenders[actorSeed % lenders.length], bound(amtSeed, 1e15, 5 * PER_SEED));
    }

    function open(uint256 borrowerSeed, uint256 drawSeed) external {
        _bump("open");
        if (_loanIds.length >= MAX_LOANS) return;
        _open(borrowers[borrowerSeed % borrowers.length], bound(drawSeed, 1e15, 14 * PER_SEED));
    }

    function repay(uint256 loanSeed, uint256 amtSeed) external {
        _bump("repay");
        if (_loanIds.length == 0) return;
        uint256 loanId = _loanIds[loanSeed % _loanIds.length];
        uint256 debt = read.loan(loanId).debt;
        if (debt == 0) return;
        _repayTo(loanId, debt - bound(amtSeed, 1, debt));
    }

    /// @notice THE ACTION THAT REACHES THE REGIME: repay down to a fuzzed POWER OF TWO of residual debt.
    /// @dev The exposure lives in the bottom decades of the debt, and a uniform residual never visits them.
    /// @dev `repay` above draws its amount uniformly, so it lands inside the thin window with probability ~0.
    function repayToDust(uint256 loanSeed, uint256 expSeed) external {
        _bump("repayToDust");
        if (_loanIds.length == 0) return;
        _repayTo(_loanIds[loanSeed % _loanIds.length], 1 << bound(expSeed, 0, 62));
    }

    function withdrawCollateral(uint256 loanSeed, uint256 unitSeed) external {
        _bump("withdrawCollateral");
        if (_loanIds.length == 0) return;
        uint256 loanId = _loanIds[loanSeed % _loanIds.length];
        Loan memory l = read.loan(loanId);
        if (l.collateralUnits == 0) return;
        vm.prank(l.borrower);
        try ace.withdrawCollateral(loanId, bound(unitSeed, 1, l.collateralUnits), l.borrower) {} catch {}
    }

    /// @notice THE ACTION THAT REACHES THE LINE: take exactly what the shipped view says is spare.
    /// @dev The random-amount sibling above bounds over the whole holding and swallows the refusal.
    /// @dev It therefore lands within the ceiling slack of the line with probability ~0, and never tests the edge.
    function withdrawCollateralMax(uint256 loanSeed) external {
        _bump("withdrawCollateralMax");
        if (_loanIds.length == 0) return;
        _withdrawToLine(_loanIds[loanSeed % _loanIds.length]);
    }

    /// @dev Take exactly the spare units the shipped view reports, and count the ones that land.
    function _withdrawToLine(uint256 loanId) internal {
        Loan memory l = read.loan(loanId);
        uint256 w = lens.withdrawableUnits(id, loanId);
        if (w == 0 || w >= l.collateralUnits) return; // a full drain is refused by name, not by the gate
        vm.prank(l.borrower);
        try ace.withdrawCollateral(loanId, w, l.borrower) {
            lineWithdrawals++;
        } catch {}
    }

    /// @notice THE EROSION PROBE: stand a loan on its line, then sell out from under it.
    /// @dev The gate's slack is what settlement's own ceilings are paid out of, and a sale spends it.
    /// @dev The band has to be armed first, so a lottery sequence needs three specific actions on one loan.
    /// @dev So it is ONE action, exactly as `AceHandler.depositThenExit` compounds its own two-step probe.
    /// @dev Picks among LIVE, UNEXPIRED loans only: a closed or matured loan refuses both legs, and the catches would hide it.
    function withdrawToLineThenDeleverage(uint256 loanSeed) external {
        _bump("withdrawToLineThenDeleverage");
        (bool found, uint256 idx) = _crankableIndex(loanSeed);
        if (!found) return;
        uint256 loanId = _loanIds[idx];
        _withdrawToLine(loanId);
        _enterBand(loanId);
        _crankDeleverage(loanId);
    }

    /// @notice Reward accrual (rate up) or a validator slash (rate down) on the collateral; no hub verb reads a rate now.
    function setRate(uint256 rateSeed) external {
        _bump("setRate");
        coll.setRate(bound(rateSeed, 0.5e18, 3e18));
    }

    /// @notice The decline channel, the other seam that removes units without passing the withdrawal gate.
    /// @dev Picks among LIVE, UNEXPIRED loans only, as the probe above does, and for the same reason.
    function deleverage(uint256 loanSeed) external {
        _bump("deleverage");
        (bool found, uint256 idx) = _crankableIndex(loanSeed);
        if (found) _crankDeleverage(_loanIds[idx]);
    }

    /// @dev The first live, unexpired tracked loan at or after the seed's own pick, wrapping once round.
    /// @dev A seed that already names such a loan still gets that loan, so a written sequence keeps its target.
    /// @dev The same selection as `AceHandler._crankableIndex`: `forceClose` warps past expiry and settles, so bare picks mostly refuse.
    function _crankableIndex(uint256 seed) internal view returns (bool found, uint256 idx) {
        uint256 n = _loanIds.length;
        for (uint256 k; k < n; k++) {
            idx = (seed % n + k) % n;
            Loan memory l = read.loan(_loanIds[idx]);
            if (l.closedAt == 0 && _now() < l.expiry) return (true, idx);
        }
    }

    /// @notice Park the record in a loan's deleverage band, so the decline channel has something to reach.
    function enterBand(uint256 loanSeed) external {
        _bump("enterBand");
        if (_loanIds.length == 0) return;
        _enterBand(_loanIds[loanSeed % _loanIds.length]);
    }

    /// @notice The recovery print: the band closes and the draw cap goes back over the whole seeded span.
    function heal() external {
        _bump("heal");
        _heal();
    }

    /// @notice The expiry fold: the settlement that a thinned line would report as bad debt.
    function forceClose(uint256 loanSeed) external {
        _bump("forceClose");
        if (_loanIds.length == 0) return;
        uint256 loanId = _loanIds[loanSeed % _loanIds.length];
        uint64 exp = read.loan(loanId).expiry;
        if (exp != 0 && _now() < exp) _warpTo(uint256(exp) + 1);
        try ace.forceClose(loanId) {
            if (read.loan(loanId).closedAt != 0) settlements++;
        } catch {}
    }

    function warp(uint256 dtSeed) external {
        _bump("warp");
        _warpBy(bound(dtSeed, 1 minutes, 3 days));
    }
}
