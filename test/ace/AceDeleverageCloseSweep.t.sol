// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.36;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {FullMath} from "@uniswap/v4-core/src/libraries/FullMath.sol";
import {WarpClock} from "../utils/WarpClock.sol";
import {Ace} from "../../src/ace/hub/Ace.sol";
import {Borrower} from "../../src/ace/hub/Borrower.sol";
import {CloseUnfilled} from "../../src/ace/hub/Deleverage.sol";
import {LoanMath} from "../../src/ace/hub/libraries/LoanMath.sol";
import {MarketParams, OpenBounds} from "../../src/ace/hub/Types.sol";
import {PositionManager} from "../../src/ace/positions/PositionManager.sol";
import {IAceDeleverageCallback} from "../../src/interfaces/IAceDeleverageCallback.sol";
import {MockERC20} from "../mocks/MockERC20.sol";
import {MockPersistenceRecord} from "../mocks/MockPersistenceRecord.sol";
import {AceFixtures} from "../utils/AceFixtures.sol";
import {AceReader} from "../utils/AceReader.sol";
import {_extended} from "../utils/Extended.sol";

/// @notice A keeper that fills an exact share of what the hub hands it: a count of atoms, or bps of the sale, the rest refunded.
contract CloseSweepKeeper is IAceDeleverageCallback {
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

/// @title AceDeleverageCloseSweep
/// @notice The close decision swept: every legal crank closes the loan clean, is refused whole, or leaves it live at or over its debt floor.
/// @notice A crank that leaves the loan live never turns the borrower's admissible extension into a refusal.
/// @notice Pairs: 6/6, 6/8 and 6/18 quote/collateral decimals, and an 18-decimal quote against 8-decimal collateral.
/// @notice Dials: the PoC set, target = band + 1, and stop EXACTLY on the `stop below sellmax onset` rail (one wei of slack).
/// @dev Rows: 1.2x and 3x the debt floor, each on its coverage line (the thinnest lot `open` admits) and at an 85% trigger.
/// @dev The market stores `minPrincipal = 2 * floor`, so a 1.2x row opens at `minPrincipal`, repays to its size and withdraws to its lot.
/// @dev Crank: in the last live second, at one wei over the stop level and at mid-band.
/// @dev Fills: one atom, one bps, half and all; then twenty-five consecutive one-atom fills.
/// @dev Each crank lands CLOSED, REFUSED (a short closing fill reverts `CloseUnfilled`) or JUDGED (live: the floor and the extension asked).
/// @dev The extension runs at `expiry - 1` with the record back at the market's price, so only the crank differs from the untouched state.
contract AceDeleverageCloseSweepTest is WarpClock {
    uint256 internal constant S = 1 << 96;
    uint64 internal constant MIN_TENOR = 7 days;
    uint64 internal constant MAX_TENOR = 30 days;
    uint256 internal constant BOUNTY = 200; // `MAX_SETTLE_BOUNTY_BPS`
    uint256 internal constant REPEATS = 25;
    uint256 internal constant THETA = 8500; // the margin row's trigger as bps of the price

    address internal lender = address(0xA11CE);
    address internal borrower = address(0xB0B);

    /// @dev The sweep's counts, carried in MEMORY and returned up the stack: a snapshot revert rolls back storage, counters included.
    struct Tally {
        uint256 rows; // loans swept
        uint256 landed; // cranks that sold at least one atom
        uint256 closed; // cranks that closed the loan
        uint256 refused; // short closing fills, reverted `CloseUnfilled`
        uint256 judged; // cranks that left the loan live
        uint256 dust; // live loans left under the debt floor, or closed ones holding debt
        uint256 flips; // extensions that landed untouched and were refused after a crank
        uint256 extendable; // rows whose extension landed untouched: the flip check's denominator
    }

    struct Dials {
        uint256 k;
        uint256 eps;
        uint256 band;
        uint256 target;
        uint256 stop;
        uint256 cut;
    }

    /// @dev One market and one loan.
    struct Row {
        Ace ace;
        AceReader read;
        MockERC20 quote;
        MockERC20 coll;
        MockPersistenceRecord record;
        CloseSweepKeeper keeper;
        bytes32 mid;
        uint256 loanId;
        uint256 p; // the market's price, and the record's answer at the extension
        uint256 floor; // the live debt floor, half the market's `minPrincipal`
        uint256 expiry;
        bool extendsUntouched;
    }

    function _poc() internal pure returns (Dials memory) {
        return Dials({k: 1.4e18, eps: 100, band: 3000, target: 5000, stop: 1000, cut: 500});
    }

    function _bandPlusOne() internal pure returns (Dials memory) {
        return Dials({k: 1.4e18, eps: 100, band: 3000, target: 3001, stop: 1000, cut: 500});
    }

    /// @dev `floor(floor(k * 0.98) * 0.8) + 1768e14 == 1e18 + 1`: the sellmax rail at one wei of slack, at the least admissible k.
    function _railEdge() internal pure returns (Dials memory d) {
        d = Dials({k: 1.05e18 + 3, eps: 200, band: 3000, target: 5000, stop: 1768, cut: 2000});
        uint256 bigK = ((d.k * (10000 - d.eps)) / 10000) * (10000 - d.cut) / 10000;
        require(d.stop * 1e14 + bigK == 1e18 + 1, "fixture: the rail-edge dials must sit one wei inside the rail");
    }

    /* ============================== the three dial sets ============================== */

    /// @notice At the PoC dials no crank leaves dust, and none refuses an extension that landed untouched.
    function test_Sweep_PocDials() public {
        _assertSwept(_sweepDials(_poc()));
    }

    /// @notice At the thinnest hysteresis genesis admits (target one bps over the band), the same.
    function test_Sweep_TargetOneOverBand() public {
        _assertSwept(_sweepDials(_bandPlusOne()));
    }

    /// @notice With the stop one wei inside the sellmax rail, the case the proof has no margin for, the same.
    function test_Sweep_StopOnTheSellmaxRail() public {
        _assertSwept(_sweepDials(_railEdge()));
    }

    /// @dev The property, then anti-vacuity: every row built, cranks sold, and both the close and the live half were reached.
    function _assertSwept(Tally memory t) internal pure {
        assertEq(t.dust, 0, "no crank left a live loan under the debt floor, or a closed one holding debt");
        assertEq(t.flips, 0, "no crank turned an admissible extension into a refusal");
        assertEq(t.rows, 16, "anti-vacuity: every pair, size and margin built a loan");
        assertGt(t.extendable, 0, "anti-vacuity: some row's extension landed untouched, so the flip check bites");
        assertGt(t.landed, 0, "anti-vacuity: the sweep's cranks actually sold");
        assertGt(t.closed, 0, "anti-vacuity: some crank closed a loan");
        assertGt(t.judged, 0, "anti-vacuity: some crank left a live loan whose floor and extension were asked");
    }

    /* ============================== the sweep ============================== */

    function _sweepDials(Dials memory d) internal returns (Tally memory t) {
        uint8[4] memory qDec = [6, 6, 6, 18];
        uint8[4] memory cDec = [6, 8, 18, 8];
        uint256[2] memory multBps = [uint256(12000), 30000];
        for (uint256 i; i < 4; ++i) {
            for (uint256 m; m < 2; ++m) {
                for (uint256 onLine; onLine < 2; ++onLine) {
                    uint256 snap = vm.snapshotState();
                    Row memory r = _row(d, qDec[i], cDec[i], multBps[m], onLine == 1);
                    ++t.rows;
                    if (r.extendsUntouched) ++t.extendable;
                    t = this.sweepRowFrame(r, d, t);
                    vm.revertToState(snap);
                }
            }
        }
        emit log_named_uint("rows", t.rows);
        emit log_named_uint("extendable rows", t.extendable);
        emit log_named_uint("cranks landed", t.landed);
        emit log_named_uint("closed", t.closed);
        emit log_named_uint("refused", t.refused);
        emit log_named_uint("judged", t.judged);
    }

    /// @dev `_sweepRow` in its own call frame: via-IR inlines it into `_sweepDials` otherwise, and the merged frame is too deep for the stack.
    function sweepRowFrame(Row memory r, Dials memory d, Tally memory t) external returns (Tally memory) {
        _sweepRow(r, d, t);
        return t;
    }

    /// @dev Every crank shape against one loan, each from the same untouched state, then a run of one-atom fills.
    function _sweepRow(Row memory r, Dials memory d, Tally memory t) internal {
        uint256[4] memory atoms = [uint256(1), 0, 0, 0];
        uint256[4] memory bps = [uint256(0), 1, 5000, 10000];
        for (uint256 psMode; psMode < 2; ++psMode) {
            for (uint256 f; f < 4; ++f) {
                uint256 snap = vm.snapshotState();
                _warpTo(r.expiry - 1);
                uint256 ps = _armCrank(r, d, psMode);
                r.keeper.setFill(atoms[f], bps[f]);
                _crankAndJudge(r, t, ps);
                vm.revertToState(snap);
            }
        }
        uint256 snap2 = vm.snapshotState();
        _warpTo(r.expiry - 1);
        uint256 psWorst = _armCrank(r, d, 0);
        r.keeper.setFill(1, 0);
        for (uint256 n = 1; n <= REPEATS; ++n) {
            if (!_crankAndJudge(r, t, psWorst)) break; // a refused or closing crank ends the run of one-atom fills
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

    /// @dev One crank at `ps`, classified. Returns false when it was REFUSED or CLOSED the loan: nothing is left for a further fill.
    function _crankAndJudge(Row memory r, Tally memory t, uint256 ps) internal returns (bool live) {
        r.record.setMinPrice(ps);
        uint256 trig0 = r.read.triggerPrice(r.loanId);
        (bool ok, bytes memory ret) = address(r.keeper).call(abi.encodeCall(CloseSweepKeeper.crank, (r.loanId)));
        if (!ok) {
            assertEq(bytes4(ret), CloseUnfilled.selector, "the only refusal is a short closing fill");
            ++t.refused;
            return false;
        }
        (uint256 sold,) = abi.decode(ret, (uint256, uint256));
        if (sold > 0) ++t.landed;
        uint256 debt = r.read.loan(r.loanId).debt;
        if (r.read.loan(r.loanId).closedAt != 0) {
            ++t.closed;
            if (debt != 0) ++t.dust;
            return false;
        }
        ++t.judged;
        if (debt < r.floor) ++t.dust;
        assertLe(r.read.triggerPrice(r.loanId), trig0, "a crank never raises the trigger");
        if (r.extendsUntouched && !_extendsBeforeExpiry(r)) ++t.flips;
        _warpTo(r.expiry - 1);
        return true;
    }

    /// @dev The REAL `extend` by the borrower at `expiry - 1` inside a snapshot, the record back at the price: true when it extended in place.
    function _extendsBeforeExpiry(Row memory r) internal returns (bool rolled) {
        uint256 snap = vm.snapshotState();
        _warpTo(r.expiry - 1);
        r.record.setMinPrice(r.p);
        r.record.setBandPrice(0); // the crank parked the band at the old trigger; the extension asks the live record
        (,, uint256 fee) = r.ace.tryExtend(r.loanId, 0, "", borrower);
        r.quote.mint(borrower, fee);
        vm.startPrank(borrower);
        r.quote.approve(address(r.ace), fee);
        try r.ace.extend(r.loanId, 0, "") {} catch {}
        vm.stopPrank();
        rolled = _extended(r.read, r.loanId, uint64(r.expiry));
        vm.revertToState(snap);
    }

    /* ============================== one loan ============================== */

    function _row(Dials memory d, uint8 qd, uint8 cd, uint256 multBps, bool onLine) internal returns (Row memory r) {
        r.quote = new MockERC20("Q", "Q", qd);
        r.coll = new MockERC20("C", "C", cd);
        r.record = new MockPersistenceRecord(address(r.quote), address(r.coll));
        r.p = AceFixtures.priceAt(address(r.quote), address(r.coll), 0);
        r.record.setMinPrice(r.p);
        r.floor = 1000 * 10 ** qd;
        AceFixtures.Deployment memory dep = AceFixtures.deploy(_params(r, d));
        (r.ace, r.read, r.mid) = (dep.ace, dep.read, dep.id);
        require(LoanMath.debtFloor(r.ace.idToMarketParams(r.mid).minPrincipal) == r.floor, "fixture: the debt floor is half minPrincipal");
        r.keeper = new CloseSweepKeeper(r.ace, r.quote, IERC20(address(r.coll)));
        uint256 cash = 1_000_000 * 10 ** qd;
        r.quote.mint(lender, cash);
        vm.startPrank(lender);
        r.quote.approve(address(r.ace), cash);
        r.ace.deposit(r.mid, cash);
        vm.stopPrank();
        AceFixtures.installYesPolicy(r.ace, lender); // an extension lands only on its lender's yes
        uint256 debt = r.floor * multBps / 10000;
        uint256 units = onLine ? Borrower.coverageLine(d.k, S, debt, r.p) : FullMath.mulDiv(d.k * debt, S * 10000, THETA * r.p * 1e18);
        _open(r, dep.positionManager, units, debt);
        assertEq(r.read.loan(r.loanId).debt, debt, "fixture: the loan carries its row's debt");
        assertEq(r.read.loan(r.loanId).collateralUnits, units, "fixture: on its row's lot");
        r.extendsUntouched = _extendsBeforeExpiry(r);
    }

    function _params(Row memory r, Dials memory d) internal view returns (MarketParams memory p) {
        p = AceFixtures.marketParams(address(r.quote), address(r.coll));
        p.record = address(r.record);
        p.minCoverageWad = d.k;
        p.minTenor = MIN_TENOR;
        p.maxTenor = MAX_TENOR;
        p.minPrincipal = 2 * r.floor;
        p.settleBountyBps = BOUNTY;
        p.deleverageFloorEpsBps = d.eps;
        p.deleverageBandBps = d.band;
        p.deleverageTargetBps = d.target;
        p.deleverageStopBps = d.stop;
        p.deleverageProtocolBps = d.cut;
    }

    /// @dev A debt under `minPrincipal` cannot be born: open at `minPrincipal` on twice the lot, repay to `debt`, then withdraw to `units`.
    function _open(Row memory r, PositionManager pm, uint256 units, uint256 debt) internal {
        uint256 mp = 2 * r.floor;
        uint256 born = debt < mp ? mp : debt;
        uint256 lot = debt < mp ? 2 * units : units; // 2 > mp / debt at every sub-mp row, so the open clears its line
        r.coll.mint(borrower, lot);
        vm.startPrank(borrower);
        r.coll.approve(address(pm), lot);
        r.loanId = r.ace.open(r.mid, lot, born, MIN_TENOR, borrower, OpenBounds(0, 0, 0));
        if (born > debt) {
            r.quote.approve(address(r.ace), born - debt);
            r.ace.repay(r.loanId, born - debt);
            r.ace.withdrawCollateral(r.loanId, lot - units, borrower);
        }
        vm.stopPrank();
        r.expiry = uint256(r.read.loan(r.loanId).expiry);
    }
}
