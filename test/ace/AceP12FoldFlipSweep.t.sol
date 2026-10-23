// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.36;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {FullMath} from "@uniswap/v4-core/src/libraries/FullMath.sol";
import {WarpClock} from "../utils/WarpClock.sol";
import {Ace} from "../../src/ace/hub/Ace.sol";
import {MarketParams, OpenBounds} from "../../src/ace/hub/Types.sol";
import {PositionManager} from "../../src/ace/positions/PositionManager.sol";
import {IAceDeleverageCallback} from "../../src/interfaces/IAceDeleverageCallback.sol";
import {MockERC20} from "../mocks/MockERC20.sol";
import {MockPersistenceRecord} from "../mocks/MockPersistenceRecord.sol";
import {AceFixtures} from "../utils/AceFixtures.sol";
import {AceReader} from "../utils/AceReader.sol";

/// @notice A keeper that fills an exact share of what the hub hands it: a count of atoms, or bps of the sale, the rest refunded.
contract SweepKeeper is IAceDeleverageCallback {
    Ace public immutable ACE;
    MockERC20 public immutable QUOTE;
    IERC20 public immutable COLLATERAL;
    uint256 public fillAtoms; // non-zero: fill exactly this many atoms, capped at the sale
    uint256 public fillBps; // otherwise: fill this share of the sale, floored

    constructor(Ace ace, MockERC20 quote, IERC20 collateral) {
        (ACE, QUOTE, COLLATERAL) = (ace, quote, collateral);
    }

    function setFill(uint256 atoms, uint256 bps) external {
        (fillAtoms, fillBps) = (atoms, bps);
    }

    function crank(uint256 id) external returns (uint256, uint256) {
        return ACE.deleverage(id, 0, "");
    }

    function onAceDeleverage(uint256 unitsSold, uint256 quoteOwed, bytes calldata) external {
        uint256 fill = fillAtoms != 0 ? (fillAtoms < unitsSold ? fillAtoms : unitsSold) : (unitsSold * fillBps) / 10000;
        if (unitsSold > fill) COLLATERAL.transfer(msg.sender, unitsSold - fill);
        QUOTE.mint(address(this), quoteOwed); // at least what the pull on `fill` takes
        QUOTE.approve(msg.sender, quoteOwed);
    }
}

/// @title AceP12FoldFlipSweep
/// @notice The no-flip property swept: from a loan sitting EXACTLY on its armed fold's roll boundary, no legal crank turns ROLL into SETTLE.
/// @notice Pairs: 6/6, 6/8 and 6/18 quote/collateral decimals, and an 18-decimal quote against 8-decimal collateral.
/// @notice Dials: the PoC set, target = band + 1, and stop EXACTLY on the `stop below sellmax onset` rail (one wei of slack).
/// @notice Every market runs the bounty ceiling (200 bps) and a policy at `maxTenor` with the fee share at its 25% ceiling.
/// @dev Start state: the smallest lot the fold admits at expiry, found by bisection on a re-spelled fold and then CHECKED on the hub:
/// @dev the lot admits and one atom less does not, so each row starts on the boundary it claims.
/// @dev Crank: in the last live second, at the record's worst admitted price (one wei over the stop level) and at mid-band.
/// @dev Fills: one atom, one bps, half, and all; then twenty-five consecutive one-atom fills with the fold read after each.
/// @dev The REAL fold runs at `expiry + 1` with the record back at the market's price, so only the crank differs from the untouched state.
/// @dev A flip is logged with its whole state and counted, and every dial set must count zero.
/// @dev Teeth: with the `minDebt` cap mutated out of `Deleverage`, the PoC row counts 8 flips; the other two dial sets melt too little to flip.
contract AceP12FoldFlipSweepTest is WarpClock {
    uint256 internal constant S = 1 << 96;
    uint64 internal constant MIN_TENOR = 7 days;
    uint64 internal constant MAX_TENOR = 30 days;
    uint256 internal constant BASE_BPS = 530; // the fee at 30 days is 24.99% of the draw: `feeFundable`'s ceiling at this grid
    uint256 internal constant BOUNTY = 200; // `MAX_SETTLE_BOUNTY_BPS`
    uint256 internal constant REPEATS = 25;

    address internal lender = address(0xA11CE);
    address internal borrower = address(0xB0B);
    address internal stranger = address(0x5157);

    /// @dev The sweep's two counts. Carried in MEMORY and returned up the stack: a snapshot revert rolls back storage, counters included.
    struct Tally {
        uint256 flips; // fold answers that went from ROLL to SETTLE across a crank
        uint256 landed; // cranks that sold at least one atom: the sweep's anti-vacuity count
        uint256 rows; // boundary loans swept
    }

    struct Dials {
        uint256 k;
        uint256 eps;
        uint256 band;
        uint256 target;
        uint256 stop;
        uint256 cut;
        uint256 tag; // 1 PoC, 2 target = band + 1, 3 stop on the sellmax rail
    }

    /// @dev One market and one loan: everything a flip log has to name.
    struct Row {
        Ace ace;
        AceReader read;
        MockERC20 quote;
        MockERC20 coll;
        MockPersistenceRecord record;
        SweepKeeper keeper;
        bytes32 mid;
        uint256 loanId;
        uint256 p; // the market's price, and the record's answer at the fold
        uint256 debt;
        uint256 units;
        uint256 expiry;
        uint16 buf;
        uint256 tag;
    }

    function _poc() internal pure returns (Dials memory) {
        return Dials({k: 1.4e18, eps: 100, band: 3000, target: 5000, stop: 1000, cut: 500, tag: 1});
    }

    function _bandPlusOne() internal pure returns (Dials memory) {
        return Dials({k: 1.4e18, eps: 100, band: 3000, target: 3001, stop: 1000, cut: 500, tag: 2});
    }

    /// @dev `floor(floor(k * 0.98) * 0.8) + 1768e14 == 1e18 + 1`: the sellmax rail at one wei of slack, at the least admissible k.
    function _railEdge() internal pure returns (Dials memory d) {
        d = Dials({k: 1.05e18 + 3, eps: 200, band: 3000, target: 5000, stop: 1768, cut: 2000, tag: 3});
        uint256 bigK = ((d.k * (10000 - d.eps)) / 10000) * (10000 - d.cut) / 10000;
        require(d.stop * 1e14 + bigK == 1e18 + 1, "fixture: the rail-edge dials must sit one wei inside the rail");
    }

    /* ============================== the three dial sets ============================== */

    /// @notice At the PoC dials no crank, at any fill, from any boundary state here, flips the fold.
    function test_Sweep_PocDials_NeverFlip() public {
        Tally memory t = _sweepDials(_poc());
        assertEq(t.flips, 0, "no crank flipped an admissible fold at the PoC dials");
        assertEq(t.rows, 16, "anti-vacuity: every pair, buffer and size built a boundary loan");
        assertGt(t.landed, 400, "anti-vacuity: the sweep's cranks actually sold");
    }

    /// @notice At the thinnest hysteresis genesis admits (target one bps over the band), still no flip.
    function test_Sweep_TargetOneOverBand_NeverFlip() public {
        Tally memory t = _sweepDials(_bandPlusOne());
        assertEq(t.flips, 0, "no crank flipped an admissible fold at target = band + 1");
        assertEq(t.rows, 16, "anti-vacuity: every pair, buffer and size built a boundary loan");
        assertGt(t.landed, 400, "anti-vacuity: the sweep's cranks actually sold");
    }

    /// @notice With the stop one wei inside the sellmax rail, the case the proof has no margin for.
    function test_Sweep_StopOnTheSellmaxRail() public {
        Tally memory t = _sweepDials(_railEdge());
        emit log_named_uint("rail-edge flips", t.flips);
        emit log_named_uint("rail-edge cranks landed", t.landed);
        assertEq(t.flips, 0, "no crank flipped an admissible fold with the stop on the sellmax rail");
        assertEq(t.rows, 16, "anti-vacuity: every pair, buffer and size built a boundary loan");
        assertGt(t.landed, 400, "anti-vacuity: the sweep's cranks actually sold");
    }

    /* ============================== the sweep ============================== */

    function _sweepDials(Dials memory d) internal returns (Tally memory t) {
        uint8[4] memory qDec = [6, 6, 6, 18];
        uint8[4] memory cDec = [6, 8, 18, 8];
        uint16[2] memory bufs = [uint16(0), 500];
        uint256[2] memory multBps = [uint256(12000), 30000];
        for (uint256 i; i < 4; ++i) {
            for (uint256 j; j < 2; ++j) {
                for (uint256 m; m < 2; ++m) {
                    uint256 snap = vm.snapshotState();
                    Row memory r = _row(d, qDec[i], cDec[i], bufs[j], multBps[m]);
                    ++t.rows;
                    _sweepRow(r, d, t);
                    vm.revertToState(snap);
                }
            }
        }
        emit log_named_uint("rows", t.rows);
        emit log_named_uint("cranks landed", t.landed);
        emit log_named_uint("flips", t.flips);
    }

    /// @dev Every crank shape against one boundary loan, each from the same untouched state.
    function _sweepRow(Row memory r, Dials memory d, Tally memory t) internal {
        uint256[4] memory atoms = [uint256(1), 0, 0, 0];
        uint256[4] memory bps = [uint256(0), 1, 5000, 10000];
        for (uint256 psMode; psMode < 2; ++psMode) {
            for (uint256 f; f < 4; ++f) {
                uint256 snap = vm.snapshotState();
                _warpTo(r.expiry - 1);
                uint256 ps = _armCrank(r, d, psMode);
                r.keeper.setFill(atoms[f], bps[f]);
                _crankAndJudge(r, t, ps, f, psMode, 0);
                vm.revertToState(snap);
            }
        }
        uint256 snap2 = vm.snapshotState();
        _warpTo(r.expiry - 1);
        uint256 psWorst = _armCrank(r, d, 0);
        r.keeper.setFill(1, 0);
        for (uint256 n = 1; n <= REPEATS; ++n) {
            _crankAndJudge(r, t, psWorst, 9, 0, n);
        }
        vm.revertToState(snap2);
    }

    /// @dev Park the record in the band, not distressed, at the chosen price: 0 is one wei over the stop level, 1 is mid-band.
    function _armCrank(Row memory r, Dials memory d, uint256 psMode) internal returns (uint256 ps) {
        uint256 trig = r.read.triggerPrice(r.loanId);
        uint256 stopLevel = FullMath.mulDivRoundingUp(trig, 1e18, 1e18 - d.stop * 1e14);
        uint256 bandLevel = FullMath.mulDivRoundingUp(trig, 1e18, 1e18 - d.band * 1e14);
        ps = psMode == 0 ? stopLevel + 1 : (stopLevel + bandLevel) / 2;
        r.record.setBandPrice(trig); // below the band level, never below the trigger
        r.record.setMinPrice(ps);
    }

    /// @dev One crank at `ps`, then the fold's answer at `expiry + 1`, rolled back so the next crank starts where this one left off.
    function _crankAndJudge(Row memory r, Tally memory t, uint256 ps, uint256 fillTag, uint256 psMode, uint256 repeat) internal {
        r.record.setMinPrice(ps);
        (uint256 sold,) = r.keeper.crank(r.loanId);
        if (sold > 0) ++t.landed;
        if (!_foldRolls(r)) {
            ++t.flips;
            _logFlip(r, ps, fillTag, psMode, repeat, sold);
        }
        _warpTo(r.expiry - 1);
    }

    /// @dev The REAL fold, cranked by a stranger at `expiry + 1` inside a snapshot: true when it rolled into a successor.
    /// @dev Not `tryContinue(id)`: that view judges the whole lot, while the fold judges the lot less the keeper's sliver.
    function _foldRolls(Row memory r) internal returns (bool rolled) {
        uint256 snap = vm.snapshotState();
        _warpTo(r.expiry + 1);
        r.record.setMinPrice(r.p);
        uint256 n = r.read.loanCount();
        vm.prank(stranger);
        r.ace.forceClose(r.loanId);
        rolled = r.read.loanCount() == n + 1;
        vm.revertToState(snap);
    }

    function _logFlip(Row memory r, uint256 ps, uint256 fillTag, uint256 psMode, uint256 repeat, uint256 sold) internal {
        emit log_named_uint("FLIP dials (1 PoC, 2 band+1, 3 rail)", r.tag);
        emit log_named_uint("  quote decimals", r.quote.decimals());
        emit log_named_uint("  collateral decimals", r.coll.decimals());
        emit log_named_uint("  min buffer bps", r.buf);
        emit log_named_uint("  debt at open", r.debt);
        emit log_named_uint("  boundary lot", r.units);
        emit log_named_uint("  fill (0 atom, 1 bps, 2 half, 3 all, 9 repeated atom)", fillTag);
        emit log_named_uint("  price mode (0 stop + 1 wei, 1 mid-band)", psMode);
        emit log_named_uint("  repeat index", repeat);
        emit log_named_uint("  crank price", ps);
        emit log_named_uint("  market price", r.p);
        emit log_named_uint("  sold this crank", sold);
        emit log_named_uint("  debt after", r.read.debtOf(r.loanId));
        emit log_named_uint("  lot after", r.read.loan(r.loanId).collateralUnits);
    }

    /* ============================== one boundary loan ============================== */

    function _row(Dials memory d, uint8 qd, uint8 cd, uint16 buf, uint256 multBps) internal returns (Row memory r) {
        r.quote = new MockERC20("Q", "Q", qd);
        r.coll = new MockERC20("C", "C", cd);
        r.record = new MockPersistenceRecord(address(r.quote), address(r.coll));
        r.p = AceFixtures.priceAt(address(r.quote), address(r.coll), 0);
        r.record.setMinPrice(r.p);
        r.buf = buf;
        r.tag = d.tag;
        uint256 minDebt = 1000 * 10 ** qd;
        AceFixtures.Deployment memory dep = AceFixtures.deploy(_params(r, d, minDebt));
        (r.ace, r.read, r.mid) = (dep.ace, dep.read, dep.id);
        r.keeper = new SweepKeeper(r.ace, r.quote, IERC20(address(r.coll)));
        uint256 cash = 1_000_000 * 10 ** qd;
        r.quote.mint(lender, cash);
        vm.startPrank(lender);
        r.quote.approve(address(r.ace), cash);
        r.ace.deposit(r.mid, cash);
        vm.stopPrank();
        r.debt = minDebt * multBps / 10000;
        r.units = _boundaryLot(r, d.k);
        _openAndArm(r, dep.positionManager);
        _checkBoundary(r);
    }

    function _params(Row memory r, Dials memory d, uint256 minDebt) internal view returns (MarketParams memory p) {
        p = AceFixtures.marketParams(address(r.quote), address(r.coll));
        p.record = address(r.record);
        p.minCoverageWad = d.k;
        p.baseBps = BASE_BPS;
        p.minTenor = MIN_TENOR;
        p.maxTenor = MAX_TENOR;
        p.minDebt = minDebt;
        p.settleBountyBps = BOUNTY;
        p.deleverageFloorEpsBps = d.eps;
        p.deleverageBandBps = d.band;
        p.deleverageTargetBps = d.target;
        p.deleverageStopBps = d.stop;
        p.deleverageProtocolBps = d.cut;
    }

    function _openAndArm(Row memory r, PositionManager pm) internal {
        r.coll.mint(borrower, r.units);
        vm.startPrank(borrower);
        r.coll.approve(address(pm), r.units);
        r.loanId = r.ace.open(r.mid, r.units, r.debt, MIN_TENOR, borrower, OpenBounds(0, 0, 0));
        r.ace.setAutoRefinance(r.loanId, MAX_TENOR, r.buf, 0);
        vm.stopPrank();
        r.expiry = uint256(r.read.loan(r.loanId).expiry);
    }

    /// @dev The row claims a boundary, so the HUB's own fold is asked: the lot rolls at expiry, and one atom less settles.
    function _checkBoundary(Row memory r) internal {
        require(_foldRolls(r), "fixture: the boundary lot must roll the armed fold");
        uint256 snap = vm.snapshotState();
        vm.prank(borrower);
        r.ace.withdrawCollateral(r.loanId, 1, borrower);
        bool rolled = _foldRolls(r);
        vm.revertToState(snap);
        require(!rolled, "fixture: one atom less must settle, or the row is not on the boundary");
    }

    /// @dev The fold at expiry re-spelled: the successor principal at the policy tenor, the sliver off the top, then trigger, buffer, line.
    function _foldAdmits(Row memory r, uint256 k, uint256 lot) internal pure returns (bool) {
        uint256 dd = 10000 * 10000 * uint256(MIN_TENOR);
        uint256 principal = FullMath.mulDivRoundingUp(r.debt, dd, dd - BASE_BPS * uint256(MAX_TENOR) * 11000);
        uint256 sliver = FullMath.mulDiv(r.debt * BOUNTY, S, 10000 * r.p);
        if (sliver >= lot) return false;
        uint256 u = lot - sliver;
        uint256 trig = FullMath.mulDivRoundingUp(k * principal, S, u * 1e18);
        if (trig > r.p) return false;
        if (r.buf != 0 && FullMath.mulDiv(r.p - trig, 1e18, r.p) < uint256(r.buf) * 1e14) return false;
        return u >= FullMath.mulDivRoundingUp(k * principal, S, r.p * 1e18) + 1;
    }

    /// @dev The smallest lot the re-spelled fold admits, by bisection; `_checkBoundary` then holds the re-spelling to the hub.
    function _boundaryLot(Row memory r, uint256 k) internal pure returns (uint256) {
        uint256 hi = 1;
        while (!_foldAdmits(r, k, hi)) hi *= 2;
        uint256 lo = hi / 2;
        while (lo + 1 < hi) {
            uint256 mid = (lo + hi) / 2;
            if (_foldAdmits(r, k, mid)) hi = mid;
            else lo = mid;
        }
        return hi;
    }
}
