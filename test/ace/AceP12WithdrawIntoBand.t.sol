// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.36;

import {FullMath} from "@uniswap/v4-core/src/libraries/FullMath.sol";
import {WarpClock} from "../utils/WarpClock.sol";
import {Ace} from "../../src/ace/hub/Ace.sol";
import {AceLens} from "../../src/ace/lens/AceLens.sol";
import {NotInBand} from "../../src/ace/hub/Deleverage.sol";
import {MarketParams, OpenBounds} from "../../src/ace/hub/Types.sol";
import {PositionManager} from "../../src/ace/positions/PositionManager.sol";
import {MockERC20} from "../mocks/MockERC20.sol";
import {MockStakeVault} from "../mocks/MockStakeVault.sol";
import {MockPersistenceRecord} from "../mocks/MockPersistenceRecord.sol";
import {MockDeleverageKeeper} from "../mocks/MockDeleverageKeeper.sol";
import {AceFixtures} from "../utils/AceFixtures.sol";
import {ProtocolPolicy} from "../../src/config/Defaults.sol";
import {AceReader} from "../utils/AceReader.sol";

/// @title AceP12WithdrawIntoBand
/// @notice Phase 12 (sequences): WRITER `withdrawCollateral` (the borrower's units), READER `deleverage`'s band gate (anyone).
/// @notice The withdrawal line is a SETTLEMENT bound and the band is a MARGIN bound, so a withdrawal the hub admits can land in the band.
/// @notice The record does not move between the two calls: the crank sells because of the withdrawal, not because of a decline.
/// @dev The sibling door of open #521, whose subject is `open` admitting the same state. Every row here is GREEN: a measurement.
contract AceP12WithdrawIntoBandTest is WarpClock {
    Ace internal ace;
    AceLens internal lens;
    AceReader internal read;
    PositionManager internal pm;
    MockERC20 internal usdc;
    MockStakeVault internal coll;
    MockPersistenceRecord internal record;
    MockDeleverageKeeper internal keeper;
    bytes32 internal id;
    uint256 internal par; // the market's price, and the price the record has sat at for its whole window
    uint256 internal k; // the market's coverage multiplier, read back rather than assumed

    address internal alice = address(0xA11CE);
    address internal borrower = address(0xB0B);
    uint64 internal constant TEN = 7 days;
    uint256 internal constant S = 1 << 96;
    uint256 internal constant DEBT = 1_000e6;

    function setUp() public {
        _warpTo(1_000_000);
        usdc = new MockERC20("USD Coin", "USDC", 6);
        coll = new MockStakeVault(42);
        record = new MockPersistenceRecord(address(usdc), address(coll));
        par = AceFixtures.priceAt(address(usdc), address(coll), 0);
        record.setMinPrice(par);
        record.setBandPrice(par); // a FLAT market: the price sat at par, so it held below any level above par
        MarketParams memory p = AceFixtures.marketParams(address(usdc), address(coll));
        p.record = address(record);
        p.deleverageFloorEpsBps = ProtocolPolicy.DELEVERAGE_FLOOR_EPS_BPS;
        p.deleverageBandBps = 3000; // the fold-flip rig's dials, which are PocMarkets.ybBtcDemoParams'
        p.deleverageTargetBps = 5000;
        p.deleverageStopBps = 1000;
        p.deleverageProtocolBps = 500;
        AceFixtures.Deployment memory d = AceFixtures.deploy(p);
        (ace, pm, read, id) = (d.ace, d.positionManager, d.read, d.id);
        k = p.minCoverageWad;
        lens = new AceLens(address(ace));
        keeper = new MockDeleverageKeeper(ace, address(usdc), address(coll), S);
        usdc.mint(alice, 100_000e6);
        vm.startPrank(alice);
        usdc.approve(address(ace), type(uint256).max);
        ace.deposit(id, 100_000e6);
        vm.stopPrank();
    }

    /// @dev The lot that puts this loan's trigger at `bps` of par.
    function _unitsAt(uint256 bps) internal view returns (uint256) {
        return FullMath.mulDiv(k * DEBT, S * 10000, bps * par * 1e18);
    }

    /// @dev A loan whose trigger sits at half par: 50% margin, clear of a 30% band.
    function _open() internal returns (uint256 loanId) {
        uint256 units = _unitsAt(5000);
        coll.mint(borrower, units);
        vm.startPrank(borrower);
        coll.approve(address(pm), units);
        loanId = ace.open(id, units, DEBT, TEN, borrower, OpenBounds(0, 0, 0));
        vm.stopPrank();
    }

    /// @dev The borrower takes collateral out until the trigger sits at `bps` of par.
    function _withdrawTo(uint256 loanId, uint256 bps) internal returns (uint256 w) {
        w = read.loan(loanId).collateralUnits - _unitsAt(bps);
        vm.prank(borrower);
        ace.withdrawCollateral(loanId, w, borrower);
    }

    /// @notice LEG B alone: on the loan as opened, the crank is refused. Nothing has declined.
    function test_LegB_AloneTheCrankIsRefused() public {
        uint256 loanId = _open();
        vm.expectRevert(NotInBand.selector);
        keeper.crankDeleverage(loanId);
    }

    /// @notice LEG A alone: the withdrawal to a 20% margin is admitted, and the lens said it would be.
    function test_LegA_AloneTheWithdrawalIsAdmitted() public {
        uint256 loanId = _open();
        uint256 w = read.loan(loanId).collateralUnits - _unitsAt(8000);
        assertGe(lens.withdrawableUnits(id, loanId), w, "PREMISE: the withdrawal preview admits it");
        assertFalse(lens.deleverageEligible(loanId), "PREMISE: and nothing is crankable before it");
        _withdrawTo(loanId, 8000);
        assertEq(read.loan(loanId).closedAt, 0, "the loan is live");
        assertLt(read.triggerPrice(loanId), par, "and its trigger is under the price the record has held, so it is not distressed");
    }

    /// @notice THE PAIR, measured: the same withdrawal, then a stranger's crank, with the record untouched between them.
    function test_Measure_TheWithdrawalIsCrankedWithNoPriceMove() public {
        uint256 loanId = _open();
        _withdrawTo(loanId, 8000);
        uint256 lot = read.loan(loanId).collateralUnits;
        uint256 debt0 = read.debtOf(loanId);
        assertTrue(lens.deleverageEligible(loanId), "the lens now reads the loan crankable");
        (uint256 sold, uint256 out) = keeper.crankDeleverage(loanId);
        uint256 melted = debt0 - read.debtOf(loanId);
        uint256 atPar = FullMath.mulDiv(sold, par, S);
        emit log_named_uint("lot after the withdrawal (atoms)        ", lot);
        emit log_named_uint("units the crank sold (atoms)            ", sold);
        emit log_named_uint("share of the lot sold (bps)             ", (sold * 10000) / lot);
        emit log_named_uint("quote the keeper paid (USDC atoms)      ", out);
        emit log_named_uint("debt melted (USDC atoms)                ", melted);
        emit log_named_uint("sold units' value at par (USDC atoms)   ", atPar);
        emit log_named_uint("borrower's loss against par (USDC atoms)", atPar - melted);
        emit log_named_uint("that loss, bps of the lot at par        ", ((atPar - melted) * 10000) / FullMath.mulDiv(lot, par, S));
        assertGt(sold, lot / 5, "MEASURED: over a fifth of the lot sold in the block the borrower withdrew, at an unchanged price");
    }

    /// @notice CONTROL: a shallower withdrawal, to a 35% margin, stays out of the band and the crank is refused again.
    /// @dev So the exposed withdrawals are the ones leaving the margin between the stop and the band.
    function test_Control_AShallowerWithdrawalStaysOutOfTheBand() public {
        uint256 loanId = _open();
        _withdrawTo(loanId, 6500);
        vm.expectRevert(NotInBand.selector);
        keeper.crankDeleverage(loanId);
    }
}
