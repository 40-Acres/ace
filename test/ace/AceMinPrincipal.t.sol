// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.36;

import {FullMath} from "@uniswap/v4-core/src/libraries/FullMath.sol";
import {WarpClock} from "../utils/WarpClock.sol";
import {Ace} from "../../src/ace/hub/Ace.sol";
import {BelowDebtFloor, BelowMinPrincipal, Borrower} from "../../src/ace/hub/Borrower.sol";
import {BelowMinLot, WouldLeaveDust} from "../../src/ace/hub/Lender.sol";
import {MinFillOutOfRange} from "../../src/ace/hub/Orders.sol";
import {MarketParams, MigrateArgs, OpenBounds, Order} from "../../src/ace/hub/Types.sol";
import {AceLens} from "../../src/ace/lens/AceLens.sol";
import {PositionManager} from "../../src/ace/positions/PositionManager.sol";
import {ProtocolPolicy} from "../../src/config/Defaults.sol";
import {MockERC20} from "../mocks/MockERC20.sol";
import {MockDeleverageKeeper} from "../mocks/MockDeleverageKeeper.sol";
import {MockPersistenceRecord} from "../mocks/MockPersistenceRecord.sol";
import {AceFixtures} from "../utils/AceFixtures.sol";
import {AceReader} from "../utils/AceReader.sol";

/// @title AceMinPrincipalTest
/// @notice A market stores `minPrincipal`, the smallest loan it opens and the smallest lot its lender doors take.
/// @notice A live loan never carries less than half of it, rounded down: the derived debt floor.
/// @dev Reasoning: the design record.
contract AceMinPrincipalTest is WarpClock {
    Ace internal ace;
    AceReader internal read;
    AceLens internal lens;
    PositionManager internal pm;
    MockERC20 internal usdc;
    MockERC20 internal coll;
    bytes32 internal id;

    address internal alice = address(0xA11CE);
    address internal borrower = address(0xB0B);
    uint256 internal constant DEPOSIT = 100_000e6;
    uint256 internal constant UNITS = 1_000_000e18; // far over any line here, so only the size rules refuse

    function setUp() public {
        _warpTo(1_000_000);
        usdc = new MockERC20("USD Coin", "USDC", 6);
        coll = new MockERC20("Collateral", "COLL", 18);
        id = _market(10e6);
    }

    /// @dev A fresh hub and market at `mp`, lent `DEPOSIT` by alice; every handle points at it.
    function _market(uint256 mp) internal returns (bytes32 m) {
        MarketParams memory p = AceFixtures.marketParams(address(usdc), address(coll));
        p.lender = alice;
        p.minPrincipal = mp;
        AceFixtures.Deployment memory d = AceFixtures.deploy(p);
        (ace, pm, read, m) = (d.ace, d.positionManager, d.read, d.id);
        lens = new AceLens(address(ace));
        _deposit(m, DEPOSIT);
        coll.mint(borrower, 10 * UNITS);
        vm.startPrank(borrower);
        coll.approve(address(pm), type(uint256).max);
        usdc.approve(address(ace), type(uint256).max);
        vm.stopPrank();
        usdc.mint(borrower, DEPOSIT);
    }

    function _deposit(bytes32 m, uint256 amt) internal {
        usdc.mint(alice, amt);
        vm.startPrank(alice);
        usdc.approve(address(ace), amt);
        ace.deposit(m, amt);
        vm.stopPrank();
    }

    function _mp() internal view returns (uint256) {
        return ace.idToMarketParams(id).minPrincipal;
    }

    function _open(uint256 principal) internal returns (uint256 loanId) {
        vm.prank(borrower);
        loanId = ace.open(id, UNITS, principal, 0, borrower, OpenBounds(0, 0, 0));
    }

    /* ============================== births ============================== */

    /// @notice RED: an open one atom under `minPrincipal` is refused by name; one at exactly it lands.
    function test_RED_AnOpenUnderMinPrincipalReverts() public {
        uint256 mp = _mp();
        vm.prank(borrower);
        vm.expectRevert(BelowMinPrincipal.selector);
        ace.open(id, UNITS, mp - 1, 0, borrower, OpenBounds(0, 0, 0));
        uint256 loanId = _open(mp);
        assertEq(read.debtOf(loanId), mp, "a loan at exactly minPrincipal opens");
        assertEq(read.principalOf(loanId), mp, "born at minPrincipal");
    }

    /// @notice RED: a refinance successor one atom under `minPrincipal` is refused by name: the successor is a birth.
    function test_RED_ARefinanceSuccessorUnderMinPrincipalReverts() public {
        uint256 mp = _mp();
        uint256 loanId = _open(10 * mp);
        vm.prank(borrower);
        vm.expectRevert(BelowMinPrincipal.selector);
        ace.refinanceTo(MigrateArgs(loanId, id, mp - 1, 0, OpenBounds(0, 0, 0), 0, address(0)));
    }

    /// @notice CONTROL: a successor of exactly `minPrincipal` lands from a loan on its floor; a same-size successor of that loan is refused.
    function test_ARefinanceSuccessorOfExactlyMinPrincipalLands() public {
        uint256 mp = _mp();
        uint256 loanId = _open(mp);
        vm.prank(borrower);
        ace.repay(loanId, mp - 5e6);
        assertEq(read.debtOf(loanId), 5e6, "PREMISE: the old loan sits on its debt floor, half the fixture's 10e6");
        vm.prank(borrower);
        vm.expectRevert(BelowMinPrincipal.selector);
        ace.refinanceTo(MigrateArgs(loanId, id, 5e6, 0, OpenBounds(0, 0, 0), 0, address(0)));
        vm.prank(borrower);
        uint256 newId = ace.refinanceTo(MigrateArgs(loanId, id, mp, 0, OpenBounds(0, 0, 0), 0, address(0)));
        assertEq(read.principalOf(newId), mp, "the successor is born at exactly minPrincipal");
        assertTrue(ace.isClosed(loanId), "and the old loan retired on it");
    }

    /// @notice RED: an order under `minPrincipal` and a fill floor under it are refused at post; the zero sentinel resolves to it.
    function test_RED_OrdersFloorAtMinPrincipal() public {
        uint256 mp = _mp();
        uint256 price = ace.idToMarketParams(id).price;
        vm.startPrank(borrower);
        vm.expectRevert(BelowMinPrincipal.selector);
        ace.postOrder(id, mp - 1, price / 2, price, 0, 7 days, 0);
        vm.expectRevert(MinFillOutOfRange.selector);
        ace.postOrder(id, 4 * mp, price / 2, price, mp - 1, 7 days, 0);
        uint256 orderId = ace.postOrder(id, 4 * mp, price / 2, price, 0, 7 days, 0);
        vm.stopPrank();
        assertEq(ace.orderOf(orderId).minFillPrincipal, mp, "the zero fill floor resolves to minPrincipal");
    }

    /// @notice CONTROL: an order of exactly `minPrincipal` posts, and its whole fill is a birth at exactly it.
    function test_AnOrderOfExactlyMinPrincipalPostsAndFillsWhole() public {
        uint256 mp = _mp();
        uint256 price = ace.idToMarketParams(id).price;
        vm.prank(borrower);
        uint256 orderId = ace.postOrder(id, mp, price / 2, price, 0, 7 days, 0);
        Order memory o = ace.orderOf(orderId);
        assertEq(o.principal, mp, "an order of exactly minPrincipal rests");
        assertEq(o.minFillPrincipal, mp, "and fills only whole");
        uint256 loanId = ace.fillOrder(orderId, mp, o.collateralUnits);
        assertEq(read.principalOf(loanId), mp, "its fill is born at exactly minPrincipal");
        assertEq(read.debtOf(loanId), mp, "and carries it as debt");
    }

    /* ============================== the live floor ============================== */

    /// @notice RED: a repay leaving one atom under half `minPrincipal` is refused; one leaving exactly half lands and the loan stays live.
    function test_RED_ARepayLeavingOneUnderHalfMinPrincipalReverts() public {
        uint256 mp = _mp();
        uint256 loanId = _open(mp);
        uint256 floor = mp / 2;
        vm.prank(borrower);
        vm.expectRevert(BelowDebtFloor.selector);
        ace.repay(loanId, mp - floor + 1);
        vm.prank(borrower);
        ace.repay(loanId, mp - floor);
        assertEq(read.debtOf(loanId), floor, "a fresh minimum loan repays down to exactly half");
        assertFalse(ace.isClosed(loanId), "and stays live");
    }

    /// @notice The floor rounds DOWN: at `minPrincipal = 2f + 1` a repay leaving `f` lands and one leaving `f - 1` reverts.
    function test_TheFloorRoundsDownOnAnOddMinPrincipal() public {
        id = _market(10e6 + 1);
        uint256 mp = _mp();
        uint256 f = 5e6;
        uint256 loanId = _open(mp);
        uint256 snap = vm.snapshotState();
        vm.prank(borrower);
        vm.expectRevert(BelowDebtFloor.selector);
        ace.repay(loanId, mp - f + 1);
        vm.revertToState(snap);
        vm.prank(borrower);
        ace.repay(loanId, mp - f);
        assertEq(read.debtOf(loanId), f, "leaving floor(mp / 2) lands");
    }

    /// @notice At any admitted `minPrincipal`, a fresh minimum loan repays down to exactly half of it, rounded down, and not an atom further.
    function testFuzz_AFreshMinimumLoanRepaysToExactlyHalfAndNoFurther(uint256 mpSeed) public {
        uint256 mp = bound(mpSeed, 2, 1_000e6);
        uint256 f = mp >> 1; // half rounded down, spelled apart from `LoanMath`
        if (mp != _mp()) {
            MarketParams memory p = ace.idToMarketParams(id);
            p.minPrincipal = mp;
            id = ace.createMarket(p);
            _deposit(id, DEPOSIT);
        }
        uint256 loanId = _open(mp);
        if (f > 1) {
            vm.prank(borrower);
            vm.expectRevert(BelowDebtFloor.selector);
            ace.repay(loanId, mp - f + 1);
        }
        vm.prank(borrower);
        ace.repay(loanId, mp - f);
        assertEq(read.debtOf(loanId), f, "a fresh minimum loan repays to exactly half its minPrincipal");
        assertFalse(ace.isClosed(loanId), "and stays live");
    }

    /// @notice The lens answers the same floor the repay enforces.
    function test_LensDebtFloorIsHalfTheStoredMinPrincipal() public {
        assertEq(lens.debtFloor(id), _mp() / 2, "half, on an even minPrincipal");
        id = _market(10e6 + 1);
        assertEq(lens.debtFloor(id), 5e6, "half rounded down, on an odd one");
    }

    /* ============================== the lender doors ============================== */

    /// @notice RED: a deposit one atom under `minPrincipal` is refused `BelowMinLot`; one at exactly it lands.
    function test_RED_ADepositUnderMinPrincipalReverts() public {
        uint256 mp = _mp();
        usdc.mint(alice, 2 * mp);
        vm.startPrank(alice);
        usdc.approve(address(ace), type(uint256).max);
        vm.expectRevert(BelowMinLot.selector);
        ace.deposit(id, mp - 1);
        ace.deposit(id, mp);
        vm.stopPrank();
        assertEq(ace.restingOf(id), DEPOSIT + mp, "the lot at exactly minPrincipal rests");
    }

    /// @notice RED: a withdraw leaving `minPrincipal - 1` resting is refused `WouldLeaveDust`; leaving exactly it, or nothing, lands.
    function test_RED_AWithdrawLeavingUnderMinPrincipalReverts() public {
        uint256 mp = _mp();
        uint256 resting = ace.restingOf(id);
        uint256 snap = vm.snapshotState();
        vm.prank(alice);
        vm.expectRevert(WouldLeaveDust.selector);
        ace.withdraw(id, resting - mp + 1, alice, 0);
        vm.prank(alice);
        ace.withdraw(id, resting - mp, alice, 0);
        assertEq(ace.restingOf(id), mp, "a withdraw may leave exactly minPrincipal");
        vm.revertToState(snap);
        vm.prank(alice);
        ace.withdraw(id, resting, alice, 0);
        assertEq(ace.restingOf(id), 0, "and emptying always lands");
    }

    /* ============================== genesis ============================== */

    /// @notice Genesis refuses `minPrincipal` 0 and 1 (a zero floor), admits 2 (floor 1), and refuses one atom over the cash cap.
    function test_GenesisRailsOnMinPrincipal() public {
        MarketParams memory p = AceFixtures.marketParams(address(usdc), address(coll));
        p.lender = alice;
        p.minPrincipal = 0;
        vm.expectRevert(bytes("debt floor zero"));
        ace.createMarket(p);
        p.minPrincipal = 1;
        vm.expectRevert(bytes("debt floor zero"));
        ace.createMarket(p);
        p.minPrincipal = uint256(type(uint128).max) + 1;
        vm.expectRevert(bytes("min principal over cash cap"));
        ace.createMarket(p);
        p.minPrincipal = 2;
        bytes32 m = ace.createMarket(p);
        assertEq(lens.debtFloor(m), 1, "the least admitted minPrincipal has a floor of one atom");
    }
}

/// @title AceMinPrincipalCorridorTest
/// @notice A minimum loan on the shipped corridor: trimmed at band entry to about 1.079 floors, closed by its first crank only past theta 0.7248.
/// @dev A charged restore melts `K (theta - t*) / (theta (K - t*))` of the debt: `K = k (1 - eps)(1 - cut)`, `t* = 1 - target`, theta = trigger / price.
/// @dev At theta 0.70 that is 0.4606 of `2f`, leaving 1.0788 f; it leaves less than `f` once it tops one half, which is theta 0.7248.
/// @dev The lot is twice the coverage line's, so the settlement reserve never binds and the closed form is the hub's sale.
contract AceMinPrincipalCorridorTest is WarpClock {
    Ace internal ace;
    AceReader internal read;
    PositionManager internal pm;
    MockERC20 internal usdc;
    MockERC20 internal coll;
    MockPersistenceRecord internal record;
    MockDeleverageKeeper internal keeper;
    bytes32 internal id;
    uint256 internal par;

    address internal borrower = address(0xB0B);
    uint256 internal constant S = 1 << 96;
    uint256 internal constant MP = 10e6; // the fixture's minPrincipal; the floor is 5e6

    function setUp() public {
        _warpTo(1_000_000);
        usdc = new MockERC20("USD Coin", "USDC", 6);
        coll = new MockERC20("Collateral", "COLL", 18);
        record = new MockPersistenceRecord(address(usdc), address(coll));
        par = AceFixtures.priceAt(address(usdc), address(coll), 0);
        record.setMinPrice(par);
        MarketParams memory p = AceFixtures.marketParams(address(usdc), address(coll));
        p.record = address(record);
        p.minCoverageWad = 1.4e18;
        p.minPrincipal = MP;
        p.deleverageFloorEpsBps = ProtocolPolicy.DELEVERAGE_FLOOR_EPS_BPS;
        (p.deleverageBandBps, p.deleverageTargetBps, p.deleverageStopBps, p.deleverageProtocolBps) = (3000, 5000, 1000, 500);
        AceFixtures.Deployment memory d = AceFixtures.deploy(p);
        (ace, pm, read, id) = (d.ace, d.positionManager, d.read, d.id);
        keeper = new MockDeleverageKeeper(ace, address(usdc), address(coll), S);
        usdc.mint(AceFixtures.LENDER, 1_000e6);
        vm.startPrank(AceFixtures.LENDER);
        usdc.approve(address(ace), 1_000e6);
        ace.deposit(id, 1_000e6);
        vm.stopPrank();
    }

    /// @dev A loan at exactly `minPrincipal` on twice its line's lot, then the record parked so the trigger sits at `thetaWad` of it.
    function _armedMinimumLoan(uint256 thetaWad) internal returns (uint256 loanId, uint256 ps) {
        uint256 units = 2 * Borrower.coverageLine(1.4e18, S, MP, par);
        coll.mint(borrower, units);
        vm.startPrank(borrower);
        coll.approve(address(pm), units);
        loanId = ace.open(id, units, MP, 0, borrower, OpenBounds(0, 0, 0));
        vm.stopPrank();
        ps = FullMath.mulDiv(read.triggerPrice(loanId), 1e18, thetaWad);
        record.setBandPrice(ps);
        record.setMinPrice(ps);
    }

    /// @notice At band entry the first crank TRIMS a minimum loan to about 1.079 floors: it restores, live, over the floor.
    function test_AMinimumLoanIsTrimmedAtBandEntryOnTheShippedCorridor() public {
        (uint256 loanId,) = _armedMinimumLoan(0.7e18 + 1e12); // just inside the band, which opens at theta 0.70
        (uint256 sold,) = keeper.crankDeleverage(loanId);
        assertGt(sold, 0, "PREMISE: the crank sold");
        assertEq(read.loan(loanId).closedAt, 0, "the minimum loan stays live at band entry");
        uint256 debt = read.loan(loanId).debt;
        assertGe(debt, MP / 2, "at or over its debt floor");
        assertApproxEqRel(debt, (MP / 2) * 10788 / 10000, 0.001e18, "trimmed to about 1.079 floors, the closed form's figure");
    }

    /// @notice The first crank closes a minimum loan only from a margin under 27.5%: a restore just below theta 0.7248, a close just above it.
    function test_AMinimumLoanClosesFromAMarginUnderTwentySevenPointFivePercent() public {
        uint256 snap = vm.snapshotState();
        (uint256 a,) = _armedMinimumLoan(0.7238e18);
        keeper.crankDeleverage(a);
        assertEq(read.loan(a).closedAt, 0, "just under theta 0.7248 the crank restores");
        assertGe(read.loan(a).debt, MP / 2, "and leaves the debt at or over its floor");
        vm.revertToState(snap);
        (uint256 b,) = _armedMinimumLoan(0.7258e18);
        keeper.crankDeleverage(b);
        assertGt(read.loan(b).closedAt, 0, "just over theta 0.7248 the same crank closes the loan");
        assertEq(read.loan(b).debt, 0, "retiring its whole debt");
    }
}
