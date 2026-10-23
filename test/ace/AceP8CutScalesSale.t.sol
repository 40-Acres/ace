// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.36;

import {WarpClock} from "../utils/WarpClock.sol";
import {Ace} from "../../src/ace/hub/Ace.sol";
import {MarketParams, OpenBounds} from "../../src/ace/hub/Types.sol";
import {PositionManager} from "../../src/ace/positions/PositionManager.sol";
import {FullMath} from "@uniswap/v4-core/src/libraries/FullMath.sol";
import {MockERC20} from "../mocks/MockERC20.sol";
import {MockPersistenceRecord} from "../mocks/MockPersistenceRecord.sol";
import {MockDeleverageKeeper} from "../mocks/MockDeleverageKeeper.sol";
import {AceFixtures} from "../utils/AceFixtures.sol";
import {AceReader} from "../utils/AceReader.sol";

/// @title AceP8CutScalesSale
/// @notice Audit run 2026-09-13-670568 phase 8: `deleverageProtocolBps` sizes the restore sale, not only its proceeds.
/// @notice Twin markets differ ONLY in the cut; one loan each, one record state, one crank each, both restored to target.
/// @dev MEASUREMENTS, all green. A red means the sizing or the waterfall moved, never a correctness regression.
contract AceP8CutScalesSaleTest is WarpClock {
    Ace internal ace;
    AceReader internal read;
    PositionManager internal pm;
    MockERC20 internal usdc;
    MockERC20 internal coll;
    MockPersistenceRecord internal record;
    MockDeleverageKeeper internal keeper;

    address internal alice = address(0xA11CE);
    address internal borrower = address(0xB0B);

    uint256 internal constant COLL = 10_000e18; // worth 10,000 USDC at the market price
    uint256 internal constant Q96 = 1 << 96;

    struct Dials {
        uint256 k;
        uint256 eps;
        uint256 band;
        uint256 target;
        uint256 stop;
        uint256 cut;
    }

    struct Crank {
        uint256 unitsSold;
        uint256 debtMelted;
        uint256 protocolCut;
        uint256 keeperMargin; // units sold at the record price, less what the keeper paid
        uint256 equityLost; // units sold at the record price, less the debt they melted
        uint256 marginAfterBps;
    }

    function setUp() public {
        _warpTo(1_000_000);
        usdc = new MockERC20("USD Coin", "USDC", 6);
        coll = new MockERC20("Collateral", "COLL", 18);
        record = new MockPersistenceRecord(address(usdc), address(coll));
        (ace, pm) = AceFixtures.newAceWithEscrow(AceFixtures.TREASURY);
        read = new AceReader(address(ace));
        keeper = new MockDeleverageKeeper(ace, address(usdc), address(coll), Q96);
    }

    function _market(Dials memory d) internal returns (bytes32 id) {
        MarketParams memory p = AceFixtures.marketParams(address(usdc), address(coll));
        p.record = address(record);
        p.minCoverageWad = d.k;
        p.deleverageFloorEpsBps = d.eps;
        p.deleverageBandBps = d.band;
        p.deleverageTargetBps = d.target;
        p.deleverageStopBps = d.stop;
        p.deleverageProtocolBps = d.cut;
        id = ace.createMarket(p);
        usdc.mint(alice, 10_000e6);
        vm.startPrank(alice);
        usdc.approve(address(ace), 10_000e6);
        ace.deposit(id, 10_000e6);
        vm.stopPrank();
    }

    /// @dev A loan whose trigger sits at half the market price, so the settlement reserve never caps the sale below.
    function _loan(bytes32 id, uint256 k) internal returns (uint256 loanId) {
        uint256 principal = FullMath.mulDiv(5_000e6, 1e18, k);
        coll.mint(borrower, COLL);
        vm.startPrank(borrower);
        coll.approve(address(pm), COLL);
        loanId = ace.open(id, COLL, principal, 0, borrower, OpenBounds(0, 0, 0));
        vm.stopPrank();
    }

    /// @dev Record at `trig / x`: in the band, above the stop, not distressed. The same answer serves every twin.
    function _placeRecord(uint256 loanId, uint256 xBps) internal returns (uint256 ps) {
        ps = (read.triggerPrice(loanId) * 10000) / xBps;
        record.setMinPrice(ps);
        record.setBandPrice(ps);
    }

    function _crank(bytes32 id, uint256 loanId, uint256 ps) internal returns (Crank memory c) {
        uint256 units = read.loan(loanId).collateralUnits;
        uint256 debt = read.debtOf(loanId);
        uint256 rev = read.protocolRevenue(id);
        (, uint256 stableOut) = keeper.crankDeleverage(loanId);
        c.unitsSold = units - read.loan(loanId).collateralUnits;
        c.debtMelted = debt - read.debtOf(loanId);
        c.protocolCut = read.protocolRevenue(id) - rev;
        uint256 value = FullMath.mulDiv(c.unitsSold, ps, Q96);
        c.keeperMargin = value - stableOut;
        c.equityLost = value - c.debtMelted;
        c.marginAfterBps = ((ps - read.triggerPrice(loanId)) * 10000) / ps;
    }

    /// @dev The closed-form sizing denominator over `ps`, in WAD: `k (1-eps)(1-cut) - (1-target)`.
    function _den(Dials memory d) internal pure returns (uint256) {
        return (d.k * (10000 - d.eps) * (10000 - d.cut)) / 1e8 - (1e18 - d.target * 1e14);
    }

    function _log(string memory tag, Crank memory c) internal {
        emit log_string(tag);
        emit log_named_decimal_uint("  units sold", c.unitsSold, 18);
        emit log_named_decimal_uint("  debt melted (USDC)", c.debtMelted, 6);
        emit log_named_decimal_uint("  protocol cut (USDC)", c.protocolCut, 6);
        emit log_named_decimal_uint("  keeper margin at the record price (USDC)", c.keeperMargin, 6);
        emit log_named_decimal_uint("  borrower equity lost at the record price (USDC)", c.equityLost, 6);
        emit log_named_uint("  margin after, bps", c.marginAfterBps);
    }

    /// @dev One twin whole: its market, its loan, the record at `trig / x`, one crank, logged. Its own frame (stack).
    /// @dev Every twin of one test shares `k` and the loan, so the trigger and the record answer are identical across them.
    function _twin(string memory tag, Dials memory d, uint256 xBps) internal returns (Crank memory c) {
        record.setBandPrice(0); // back to a healthy record, so the next twin's deposit and draw see a cap over its price
        record.setMinPrice(AceFixtures.px(2e18, address(usdc), address(coll)));
        bytes32 m = _market(d);
        uint256 l = _loan(m, d.k);
        c = _crank(m, l, _placeRecord(l, xBps));
        _log(tag, c);
    }

    /// @dev What every pair of twins must show: both restored, and the sale scaled by the closed form's denominator.
    function _assertScaled(Crank memory c0, Crank memory c, Dials memory d0, Dials memory d) internal {
        assertApproxEqAbs(c0.marginAfterBps, d0.target, 2, "the cut-free twin restored to target");
        assertApproxEqAbs(c.marginAfterBps, d.target, 2, "the cut twin restored to target: same end margin, different cost");
        assertApproxEqRel((c.unitsSold * 1e18) / c0.unitsSold, (_den(d0) * 1e18) / _den(d), 2e15, "the sale scales by den0 / den");
        assertApproxEqRel((c.keeperMargin * 1e18) / c0.keeperMargin, (c.unitsSold * 1e18) / c0.unitsSold, 2e15, "and the keeper margin with it");
    }

    /// @notice MEASURE, the launch dials (PocMarkets): the same restore sells more collateral as the cut rises.
    function test_Measure_LaunchDials_TheCutScalesTheSaleAndTheKeeperMargin() public {
        Dials memory d0 = Dials(1.4e18, 100, 3000, 5000, 1000, 0);
        Dials memory d20 = Dials(1.4e18, 100, 3000, 5000, 1000, 2000);
        Crank memory c0 = _twin("cut 0 bps", d0, 7500);
        Crank memory c5 = _twin("cut 500 bps (the launch dial)", Dials(1.4e18, 100, 3000, 5000, 1000, 500), 7500);
        Crank memory c20 = _twin("cut 2000 bps (the genesis ceiling)", d20, 7500);
        _assertScaled(c0, c20, d0, d20);
        emit log_named_uint("sale at cut 500 over cut 0, bps", (c5.unitsSold * 10000) / c0.unitsSold);
        emit log_named_uint("sale at cut 2000 over cut 0, bps", (c20.unitsSold * 10000) / c0.unitsSold);
        emit log_named_uint("equity lost at cut 500 over cut 0, x100", (c5.equityLost * 100) / c0.equityLost);
        emit log_named_uint("equity lost at cut 2000 over cut 0, x100", (c20.equityLost * 100) / c0.equityLost);
    }

    /// @notice MEASURE, an admissible corner: minimum coverage, maximum eps and cut, one hundred bps of hysteresis.
    function test_Measure_AdmissibleCorner_TheCutMultipliesTheSale() public {
        Dials memory d0 = Dials(1.05e18, 200, 3000, 3100, 1800, 0);
        Dials memory d20 = Dials(1.05e18, 200, 3000, 3100, 1800, 2000);
        Crank memory c0 = _twin("corner, cut 0 bps", d0, 7200);
        Crank memory c20 = _twin("corner, cut 2000 bps", d20, 7200);
        _assertScaled(c0, c20, d0, d20);
        uint256 debt0 = FullMath.mulDiv(5_000e6, 1e18, d20.k);
        emit log_named_uint("sale at cut 2000 over cut 0, bps", (c20.unitsSold * 10000) / c0.unitsSold);
        emit log_named_uint("equity lost at cut 2000 over cut 0, x100", (c20.equityLost * 100) / c0.equityLost);
        emit log_named_uint("protocol cut, bps of the debt before the crank", (c20.protocolCut * 10000) / debt0);
        emit log_named_uint("equity lost at cut 2000, bps of the debt before the crank", (c20.equityLost * 10000) / debt0);
        emit log_named_uint("equity lost at cut 0, bps of the debt before the crank", (c0.equityLost * 10000) / debt0);
    }
}
