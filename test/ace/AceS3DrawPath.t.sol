// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.36;

import {WarpClock} from "../utils/WarpClock.sol";
import {FullMath} from "@uniswap/v4-core/src/libraries/FullMath.sol";
import {Ace} from "../../src/ace/hub/Ace.sol";
import {InsufficientCash} from "../../src/ace/hub/Borrower.sol";
import {FillOverCollateralized} from "../../src/ace/hub/Orders.sol";
import {MarketParams, OpenBounds, Order} from "../../src/ace/hub/Types.sol";
import {PositionManager} from "../../src/ace/positions/PositionManager.sol";
import {MockERC20} from "../mocks/MockERC20.sol";
import {MockPersistenceRecord} from "../mocks/MockPersistenceRecord.sol";
import {AceFixtures} from "../utils/AceFixtures.sol";
import {AceReader} from "../utils/AceReader.sol";

/// @title AceS3ZeroFreshDeficit
/// @notice Audit run 2026-10-03-251533, phase 3, F1: a draw that takes NO fresh cash is refused in a lender-made reserve deficit.
/// @notice `cashAdmits(M, 0, 0)` reduces to `rollReserve <= cash`, so a zero-fresh home refinance refuses while another loan's reservation exceeds cash.
/// @notice It would move neither number, so the refusal protects no reservation.
/// @notice `drawableOf` reads zero in both the admitted and the refused state, so the subtractive spelling cannot tell them apart.
/// @dev The sibling `arm` fix (a re-arm needing no more lands in a deficit) never reached the draw's own cash leg.
/// @dev RULED, not fixed (B1): the refusal stands, decided by other loans' reservations, pinned KNOWN below; the control and premises stay.
contract AceS3ZeroFreshDeficitTest is WarpClock {
    Ace internal ace;
    AceReader internal read;
    PositionManager internal pm;
    MockERC20 internal usdc;
    MockERC20 internal coll;
    bytes32 internal id;

    address internal alice = address(0xA11CE); // the market's one lender
    address internal armedBorrower = address(0xA4ED); // arms a home roll; its reservation is what the lender goes under
    address internal bob = address(0xB0B); // an unarmed borrower who only wants to re-term at the same principal

    uint64 internal constant TEN7 = 7 days;
    uint64 internal constant TEN28 = 28 days;
    uint256 internal constant P = 10_000e6;
    uint256 internal constant UNITS = 2 * P * 1e12; // twice the coverage the market asks: collateral never binds here

    function setUp() public {
        _warpTo(1_000_000);
        usdc = new MockERC20("USD Coin", "USDC", 6);
        coll = new MockERC20("Collateral", "COLL", 18);
        MockPersistenceRecord rec = new MockPersistenceRecord(address(usdc), address(coll));
        rec.setMinPrice(AceFixtures.px(1.1e18, address(usdc), address(coll))); // Live and over the price: the cap never binds
        MarketParams memory p = AceFixtures.marketParams(address(usdc), address(coll));
        p.record = address(rec);
        p.lender = alice;
        p.baseBps = 40;
        p.minTenor = TEN7;
        p.maxTenor = TEN28;
        AceFixtures.Deployment memory d = AceFixtures.deploy(p);
        (ace, pm, read, id) = (d.ace, d.positionManager, d.read, d.id);
    }

    function _deposit(uint256 amt) internal {
        usdc.mint(alice, amt);
        vm.startPrank(alice);
        usdc.approve(address(ace), amt);
        ace.deposit(id, amt);
        vm.stopPrank();
    }

    function _open(address who, uint64 tenor) internal returns (uint256 loanId) {
        coll.mint(who, UNITS);
        vm.startPrank(who);
        coll.approve(address(pm), UNITS);
        loanId = ace.open(id, UNITS, P, tenor, who, OpenBounds(0, 0, 0));
        vm.stopPrank();
    }

    /// @dev Alice funds both loans and the armed loan's reservation; the armed one is 7 days, bob's is 28 so his refund covers a 7-day fee.
    function _book() internal returns (uint256 armedId, uint256 bobId, uint256 rr) {
        _deposit(3 * P);
        armedId = _open(armedBorrower, TEN7);
        vm.prank(armedBorrower);
        ace.setAutoRefinance(armedId, TEN7, 0, 0);
        bobId = _open(bob, TEN28);
        rr = read.rollReserve(id);
        assertGt(rr, 0, "PREMISE: the armed loan reserved");
    }

    /// @dev The lender takes the market down to exactly `keep`: her own consent, always open at or under the reserve.
    function _withdrawTo(uint256 keep) internal {
        uint256 out = ace.restingOf(id) - keep; // hoisted: a call in the argument list eats the prank
        vm.prank(alice);
        ace.withdraw(id, out, alice, 0);
        assertEq(ace.restingOf(id), keep, "fixture: the market rests exactly what the row asks");
    }

    /// @notice CONTROL: with exactly the reserve resting, bob's refinance at his old debt lands, and moves neither cash nor reserve.
    function test_Control_AZeroFreshRefinanceLandsWithExactlyTheReserveResting() public {
        (, uint256 bobId, uint256 rr) = _book();
        _withdrawTo(rr);
        assertEq(ace.drawableOf(id), 0, "PREMISE: nothing is drawable");
        vm.prank(bob);
        uint256 newId = ace.refinance(bobId, P, TEN7, OpenBounds(0, 0, 0));
        assertEq(read.debtOf(newId), P, "the successor carries the old debt");
        assertEq(ace.restingOf(id), rr, "the refinance drew no fresh cash");
        assertEq(read.rollReserve(id), rr, "and touched no reservation");
    }

    /// @notice PREMISE: the subtractive spelling reads zero at the reserve and one atom under it, so it cannot tell the two states apart.
    function test_Premise_DrawableOfReadsZeroOnBothSidesOfTheReserve() public {
        (,, uint256 rr) = _book();
        _withdrawTo(rr);
        assertEq(ace.drawableOf(id), 0, "at exactly the reserve, nothing is drawable");
        _withdrawTo(rr - 1);
        assertEq(ace.drawableOf(id), 0, "one atom under it, drawableOf still reads zero, not a deficit");
    }

    /// @notice PREMISE: a lender who refills the deficit exactly, resting no unreserved cash at all, makes the same refinance land.
    /// @dev So the refusal turns on the deficit alone, never on there being cash a zero-fresh draw could use.
    function test_Premise_RefillingTheDeficitExactlyAdmitsIt() public {
        (, uint256 bobId, uint256 rr) = _book();
        _withdrawTo(0);
        _deposit(rr); // a refill within the deficit is admitted under the minimum lot
        assertEq(ace.drawableOf(id), 0, "PREMISE: still nothing drawable");
        vm.prank(bob);
        uint256 newId = ace.refinance(bobId, P, TEN7, OpenBounds(0, 0, 0));
        assertEq(read.debtOf(newId), P, "it lands once cash covers the OTHER loan's reservation");
        assertEq(ace.restingOf(id), rr, "and still draws nothing");
    }

    /// @notice KNOWN, ruled (B1): in a lender-made deficit a zero-fresh refinance refuses `InsufficientCash`, one atom under the reserve.
    /// @dev Was the run's RED row. The refusal turns on the OTHER loan's reservation, not on a lender act: it is no clean lender veto.
    /// @dev An armed borrower disarming lifts it, and a re-terming armed loan releases its own share before the cash test.
    function test_Known_AZeroFreshRefinanceInADeficitRefusesOnOtherLoansReservations() public {
        (, uint256 bobId, uint256 rr) = _book();
        _withdrawTo(rr - 1);
        vm.prank(bob);
        vm.expectRevert(InsufficientCash.selector);
        ace.refinance(bobId, P, TEN7, OpenBounds(0, 0, 0));
    }
}

/// @title AceS3OrderBandDrift
/// @notice Audit run 2026-10-03-251533, phase 3, F3: an order's low end is the REMAINING escrow ratio, not `liqLow`.
/// @notice A lean first fill raises that ratio, so a later fill may land a trigger under the maker's stated safest one.
/// @notice Measurement only: no value moves wrongly; the excess sits in the maker's own loan, withdrawable above its line.
contract AceS3OrderBandDriftTest is WarpClock {
    Ace internal ace;
    AceReader internal read;
    PositionManager internal pm;
    MockERC20 internal usdc;
    MockERC20 internal coll;
    bytes32 internal id;

    address internal alice = address(0xA11CE);
    address internal maker = address(0x4A6E);
    address internal filler = address(0xF111);

    uint64 internal constant TEN = 7 days;
    uint256 internal constant P = 20_000e6;
    uint256 internal constant HALF = 10_000e6;
    uint256 internal LIQ_LOW;
    uint256 internal LIQ_HIGH;

    function setUp() public {
        _warpTo(1_000_000);
        usdc = new MockERC20("USD Coin", "USDC", 6);
        coll = new MockERC20("Collateral", "COLL", 18);
        MarketParams memory p = AceFixtures.marketParams(address(usdc), address(coll));
        p.lender = alice;
        p.minTenor = TEN;
        p.maxTenor = TEN;
        AceFixtures.Deployment memory d = AceFixtures.deploy(p);
        (ace, pm, read, id) = (d.ace, d.positionManager, d.read, d.id);
        LIQ_LOW = AceFixtures.px(0.5e18, address(usdc), address(coll));
        LIQ_HIGH = AceFixtures.px(0.8e18, address(usdc), address(coll));
        usdc.mint(alice, 4 * P);
        vm.startPrank(alice);
        usdc.approve(address(ace), 4 * P);
        ace.deposit(id, 4 * P);
        vm.stopPrank();
        coll.mint(maker, 1e30);
        vm.prank(maker);
        coll.approve(address(pm), type(uint256).max);
    }

    function _post() internal returns (uint256) {
        vm.prank(maker);
        return ace.postOrder(id, P, LIQ_LOW, LIQ_HIGH, HALF, TEN, 0);
    }

    /// @dev The fewest units whose trigger for `principal` is at or under `liq`: the leanest fill the high end admits.
    function _unitsAt(uint256 principal, uint256 liq) internal view returns (uint256) {
        MarketParams memory p = ace.idToMarketParams(id);
        return FullMath.mulDivRoundingUp(p.minCoverageWad * principal, read.marketState(id).unitScale, liq * 1e18);
    }

    /// @notice CONTROL: on a fresh order a half fill carrying the drifted ratio is refused `FillOverCollateralized`.
    function test_Control_TheLowEndBindsTheFirstFill() public {
        uint256 orderId = _post();
        Order memory o = ace.orderOf(orderId);
        uint256 fat = o.collateralUnits - _unitsAt(HALF, LIQ_HIGH); // what the drift lets the second fill take
        vm.prank(filler);
        vm.expectRevert(FillOverCollateralized.selector);
        ace.fillOrder(orderId, HALF, fat);
    }

    /// @notice MEASUREMENT: after a lean half fill at the high end, the second half takes every remaining unit, under `liqLow`.
    function test_Measure_ALaterFillLandsUnderTheMakersSafestTrigger() public {
        uint256 orderId = _post();
        uint256 lean = _unitsAt(HALF, LIQ_HIGH);
        vm.prank(filler);
        uint256 first = ace.fillOrder(orderId, HALF, lean);
        assertLe(read.triggerPrice(first), LIQ_HIGH, "PREMISE: the first fill sits inside the band, at its high end");
        uint256 rest = ace.orderOf(orderId).collateralUnits;
        vm.prank(filler);
        uint256 second = ace.fillOrder(orderId, HALF, rest);
        uint256 trig = read.triggerPrice(second);
        assertLt(trig, LIQ_LOW, "the second fill's trigger sits under the band's low end the maker named");
        // closed form: LH / (2H - L) = 0.5 * 0.8 / 1.1 of par, 7272 bps of liqLow
        assertApproxEqRel(trig * 10_000 / LIQ_LOW, 7272, 0.001e18, "at the closed form");
        assertEq(ace.orderOf(orderId).collateralUnits, 0, "and the escrow is spent: nothing is left for `closeOrder` to return");
    }
}
