// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.36;

import {WarpClock} from "../utils/WarpClock.sol";
import {FullMath} from "@uniswap/v4-core/src/libraries/FullMath.sol";
import {Ace} from "../../src/ace/hub/Ace.sol";
import {FillOverCollateralized} from "../../src/ace/hub/Orders.sol";
import {MarketParams, MigrateArgs, OpenBounds, Order} from "../../src/ace/hub/Types.sol";
import {PositionManager} from "../../src/ace/positions/PositionManager.sol";
import {MockERC20} from "../mocks/MockERC20.sol";
import {MockPersistenceRecord} from "../mocks/MockPersistenceRecord.sol";
import {AceFixtures} from "../utils/AceFixtures.sol";
import {AceReader} from "../utils/AceReader.sol";

/// @title AceS3ZeroFreshDeficit
/// @notice Audit run 2026-10-03-251533, phase 3, F1: a draw that takes NO fresh cash was refused in a lender-made reserve deficit.
/// @notice The roll reservation is DELETED, so the cash test is resting cash against the fresh draw alone: a zero-fresh refinance always lands.
/// @dev The two premise rows went with `drawableOf` and the deficit they measured; the control and the former KNOWN row remain.
contract AceS3ZeroFreshDeficitTest is WarpClock {
    Ace internal ace;
    AceReader internal read;
    PositionManager internal pm;
    MockERC20 internal usdc;
    MockERC20 internal coll;
    bytes32 internal id;

    address internal alice = address(0xA11CE); // the market's one lender
    address internal otherBorrower = address(0xA4ED); // holds the other loan the lender's cash funded
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

    /// @dev Alice funds both loans; the other one is 7 days, bob's is 28 so his refund covers a 7-day fee.
    /// @dev Alice names an always-yes roll policy: a same-market re-term reuses the claim only on its yes, which is these rows' premise.
    function _book() internal returns (uint256 otherId, uint256 bobId) {
        _deposit(3 * P);
        AceFixtures.installYesPolicy(ace, alice);
        otherId = _open(otherBorrower, TEN7);
        bobId = _open(bob, TEN28);
    }

    /// @dev The lender takes the market down to exactly `keep`: her own consent, always open.
    function _withdrawTo(uint256 keep) internal {
        uint256 out = keep == 0 ? type(uint256).max : ace.restingOf(id) - keep; // hoisted: a call in the argument list eats the prank
        vm.prank(alice);
        ace.withdraw(id, out, alice, 0);
        assertEq(ace.restingOf(id), keep, "fixture: the market rests exactly what the row asks");
    }

    /// @notice CONTROL: with cash resting, bob's refinance at his old debt lands and draws none of it.
    function test_Control_AZeroFreshRefinanceLandsAndDrawsNothing() public {
        (, uint256 bobId) = _book();
        uint256 cash = ace.restingOf(id);
        vm.prank(bob);
        uint256 newId = ace.refinanceTo(MigrateArgs(bobId, id, P, TEN7, OpenBounds(0, 0, 0), 0, address(0)));
        assertEq(read.debtOf(newId), P, "the successor carries the old debt");
        assertEq(ace.restingOf(id), cash, "the refinance drew no fresh cash");
    }

    /// @notice Was KNOWN, ruled (B1): a zero-fresh refinance refused in a lender-made deficit. With nothing reserved it lands at ZERO cash.
    /// @dev The cash test is resting cash against the fresh draw, and the fresh draw is zero, so no other loan can refuse it.
    function test_AZeroFreshRefinanceLandsBesideAnotherLoanAtZeroCash() public {
        (, uint256 bobId) = _book();
        _withdrawTo(0);
        vm.prank(bob);
        uint256 newId = ace.refinanceTo(MigrateArgs(bobId, id, P, TEN7, OpenBounds(0, 0, 0), 0, address(0)));
        assertEq(read.debtOf(newId), P, "it lands with nothing resting");
        assertEq(ace.restingOf(id), 0, "and draws nothing");
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
