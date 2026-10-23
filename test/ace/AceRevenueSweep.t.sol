// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.36;

import {Test} from "forge-std/Test.sol";
import {FullMath} from "@uniswap/v4-core/src/libraries/FullMath.sol";
import {WarpClock} from "../utils/WarpClock.sol";
import {Ace} from "../../src/ace/hub/Ace.sol";
import {MarketParams, OpenBounds} from "../../src/ace/hub/Types.sol";
import {PositionManager} from "../../src/ace/positions/PositionManager.sol";
import {Constants} from "../../src/ace/hub/Constants.sol";
import {ProtocolPolicy} from "../../src/config/Defaults.sol";
import {MockERC20} from "../mocks/MockERC20.sol";
import {MockPersistenceRecord} from "../mocks/MockPersistenceRecord.sol";
import {DeleverageCrank} from "../utils/DeleverageCrank.sol";
import {MockStakeVault} from "../mocks/MockStakeVault.sol";
import {AceFixtures} from "../utils/AceFixtures.sol";
import {AceReader} from "../utils/AceReader.sol";

/// @title AceRevenueSweep
/// @notice The protocol-revenue crank: one pot, one exit, and a destination fixed at deploy.
/// @notice The time gate binds the keeper piggyback only; a deliberate `sweepRevenue` is ungated.
/// @dev Both postures are pinned here because only one can be live per deployment: a funded treasury DELIVERS, `address(0)` is INERT and banks in-market.
/// @dev The destination is a constructor argument precisely so one fixture can exercise both.
contract AceRevenueSweepTest is WarpClock, DeleverageCrank {
    function _deleverageQuote() internal view override returns (address) {
        return address(usdc);
    }

    MockERC20 internal usdc;
    MockStakeVault internal vault;
    MockPersistenceRecord internal record;
    uint256 internal constant BAND_BPS = 3000;

    address internal alice = address(0xA11CE);
    address internal borrower = address(0xB0B);
    address internal keeper = address(0xCAFE);
    address internal treasury = address(0x7EA5);

    uint256 internal T4; // ticks above this pair's par; assigned in setUp, since par is not a compile-time value
    uint256 internal CAP; // finite, above every seeded tick: the disposal floor reads this
    uint256 internal PAR; // the healthy print every market here draws at, in the hub's frame
    uint256 internal constant COLL = 200_000e18;
    uint64 internal constant TENOR = ProtocolPolicy.MIN_TENOR;

    /// @dev This suite's pair, so a tick reads as its distance from par rather than as a grid coordinate.
    /// @param offset Ticks above par.
    /// @return The absolute grid tick.
    function _price(int24 offset) internal view returns (uint256) {
        return AceFixtures.priceAt(address(usdc), address(vault), offset);
    }

    function setUp() public {
        _warpTo(1_000_000);
        usdc = new MockERC20("USD Coin", "USDC", 6);
        vault = new MockStakeVault(42);
        T4 = _price(960);
        CAP = AceFixtures.px(2e18, address(usdc), address(vault));
        PAR = AceFixtures.px(1e18, address(usdc), address(vault));
        record = new MockPersistenceRecord(address(usdc), address(vault));
        record.setMinPrice(CAP);
    }

    function _deploy(address dest) internal returns (AceFixtures.Deployment memory d) {
        MarketParams memory p = AceFixtures.marketParams(address(usdc), address(vault));
        p.record = address(record);
        p.deleverageFloorEpsBps = ProtocolPolicy.DELEVERAGE_FLOOR_EPS_BPS;
        p.deleverageBandBps = BAND_BPS; // the crank that carries the push
        p.deleverageTargetBps = 4000;
        p.deleverageStopBps = 1;
        p.deleverageProtocolBps = 500; // so every crank banks fresh revenue for the next sweep to find
        d = AceFixtures.deployWithTreasury(p, dest);
    }

    /// @dev Bank a protocol cut, arm the band, then age past the sweep period so the next crank may push.
    function _bankAndAge(AceFixtures.Deployment memory d) internal returns (uint256 loanId) {
        loanId = _bank(d);
        _warpBy(Constants.SWEEP_PERIOD + 1); // clears SWEEP_PERIOD, and no further: a matured loan refuses the crank that carries the push
        assertLt(_now(), d.read.loan(loanId).expiry, "guard: the aged loan is still inside its tenor, so the crank is admitted");
    }

    /// @dev Fund the market and open the loan whose origination banks the cut. The clock does not move.
    function _bank(AceFixtures.Deployment memory d) internal returns (uint256 loanId) {
        usdc.mint(alice, 5_000e6);
        vm.startPrank(alice);
        usdc.approve(address(d.ace), 5_000e6);
        d.ace.deposit(d.id, 5_000e6);
        vm.stopPrank();

        vault.mint(borrower, COLL);
        vm.startPrank(borrower);
        vault.approve(address(d.positionManager), COLL);
        loanId = d.ace.open(d.id, COLL, 4_000e6, 0, borrower, OpenBounds(0, 0, 0));
        vm.stopPrank();

        assertGt(d.read.protocolRevenue(d.id), 0, "origination banked a protocol cut");
    }

    /// @dev A SECOND loan: two expiries for a row needing two settlements, or a crank target whose tenor starts now.
    function _openAnother(AceFixtures.Deployment memory d) internal returns (uint256 loanId) {
        vault.mint(borrower, COLL);
        vm.startPrank(borrower);
        vault.approve(address(d.positionManager), COLL);
        loanId = d.ace.open(d.id, COLL, 500e6, 0, borrower, OpenBounds(0, 0, 0));
        vm.stopPrank();
    }

    /// @dev Bank a FRESH origination cut, so the "is there anything left to sweep" rows are not vacuous.
    /// @dev Origination is the revenue source here: the decline channel's own cut is taken only on a
    /// @dev fully-restoring crank, and this fixture's sale is clamped to the debt-securing base first.
    function _bankMore(AceFixtures.Deployment memory d) internal {
        vault.mint(borrower, COLL);
        vm.startPrank(borrower);
        vault.approve(address(d.positionManager), COLL);
        d.ace.open(d.id, COLL, 500e6, 0, borrower, OpenBounds(0, 0, 0));
        vm.stopPrank();
    }

    /// @dev Arm this loan's band, crank, and restore the healthy print every other market here draws at.
    /// @dev The record is SHARED across the hubs this suite deploys, so leaving it low breaks the next open.
    /// @dev Guarded against the tenor: a crank from expiry refuses `LoanMatured`, which would read as the sweep gate failing.
    function _crank(AceFixtures.Deployment memory d, uint256 loanId) internal {
        assertLt(_now(), d.read.loan(loanId).expiry, "guard: the cranked loan is inside its tenor, so the crank is admitted");
        uint256 trig = d.read.triggerPrice(loanId);
        uint256 ps = (trig * 125) / 100; // inside the band, clear of the stop
        record.setBelowBand(FullMath.mulDivRoundingUp(trig, 1e18, 1e18 - BAND_BPS * 1e14));
        record.setMinPrice(ps);
        d.ace.deleverage(loanId, 0, "");
        record.setBelowBand(0);
        record.setMinPrice(CAP);
    }

    /// @notice A funded destination: a keeper crank delivers the pot and clears the counter.
    function test_Sweep_DeliversToTheTreasury_AndClearsTheCounter() public {
        AceFixtures.Deployment memory d = _deploy(treasury);
        uint256 loanId = _bankAndAge(d);
        assertEq(usdc.balanceOf(treasury), 0, "the treasury starts unpaid");

        _crank(d, loanId); // the crank carries the push; nobody calls sweepRevenue directly

        assertGt(usdc.balanceOf(treasury), 0, "revenue reached the treasury");
        assertEq(d.read.protocolRevenue(d.id), 0, "and the counter it swept is cleared");
    }

    /// @notice The time gate: a second crash inside the same period pushes nothing more.
    function test_Sweep_IsRateLimitedByThePeriod() public {
        AceFixtures.Deployment memory d = _deploy(treasury);
        uint256 loanId = _bankAndAge(d);

        _crank(d, loanId);
        uint256 paid = usdc.balanceOf(treasury);
        assertGt(paid, 0, "the first crank delivered");

        _bankMore(d); // fresh revenue, so the refusal below is about the GATE and not about an empty pot
        _crank(d, loanId);

        assertEq(usdc.balanceOf(treasury), paid, "a second crank inside the period pushes nothing");
        assertGt(d.read.protocolRevenue(d.id), 0, "the fresh revenue banks instead of sweeping");
    }

    /// @notice The gate opens at exactly `SWEEP_PERIOD`: one second short refuses, the boundary pays.
    /// @dev The row above cranks in the SAME BLOCK, so it holds for any non-zero period and pins no boundary.
    /// @dev What this pins is the OFF-BY-ONE: that the comparison is `<` against the constant, not `<=`.
    /// @dev It reads `SWEEP_PERIOD` rather than a literal, so it does NOT pin the VALUE -- retune freely while `SWEEP_PERIOD + 1` fits a tenor.
    /// @dev The later cranks run on a loan opened AFTER the first crank, so no loan here is cranked more than one period past its open.
    function test_Sweep_TheGateOpensExactlyAtThePeriod() public {
        AceFixtures.Deployment memory d = _deploy(treasury);
        uint256 loanId = _bankAndAge(d);

        _crank(d, loanId);
        uint256 paid = usdc.balanceOf(treasury);
        assertGt(paid, 0, "the first crank delivered and stamped the clock");

        uint256 fresh = _openAnother(d); // fresh revenue, so each crank below has something real to sweep or refuse
        _warpBy(Constants.SWEEP_PERIOD - 1);
        _crank(d, fresh);
        assertEq(usdc.balanceOf(treasury), paid, "one second short of the period: still refused");
        assertGt(d.read.protocolRevenue(d.id), 0, "and the revenue is banked, waiting");

        _warpBy(1);
        _crank(d, fresh);
        assertGt(usdc.balanceOf(treasury), paid, "at the period exactly, the gate opens and it pays");
    }

    /// @notice `address(0)`: the sweep is structurally inert and revenue banks in-market.
    /// @dev Inertness is the GUARD, never a bet on the token rejecting the zero address: `MockERC20` transfers there happily, and burns the pot.
    function test_Sweep_IsInertWhenTheDestinationIsUnset() public {
        AceFixtures.Deployment memory d = _deploy(address(0));
        uint256 loanId = _bankAndAge(d);
        uint256 banked = d.read.protocolRevenue(d.id);

        _bankMore(d);
        _crank(d, loanId);

        assertGt(d.read.protocolRevenue(d.id), banked, "the pot only grows: an inert sweep never drains it");
        assertEq(usdc.balanceOf(address(0)), 0, "and not one wei was burned to the zero address");
    }

    /// @notice Expiry settlement carries the push, so collection stops being a side effect of distress.
    /// @dev Nobody calls `sweepRevenue` here and no loan declines: the keeper simply settles at tenor.
    function test_Sweep_ExpirySettlementCarriesThePush() public {
        AceFixtures.Deployment memory d = _deploy(treasury);
        uint256 loanId = _bankAndAge(d);
        assertEq(usdc.balanceOf(treasury), 0, "the treasury starts unpaid");

        _warpTo(uint256(d.read.loan(loanId).expiry) + 1);
        vm.prank(keeper);
        d.ace.forceClose(loanId);

        assertGt(usdc.balanceOf(treasury), 0, "the settlement delivered the banked revenue");
        assertEq(d.read.protocolRevenue(d.id), 0, "and cleared the counter it swept");
    }

    /// @notice The expiry piggyback keeps the rate limit: two settlements inside one period pay once.
    /// @dev Both loans open in the SAME block, so their expiries coincide.
    /// @dev Settling them one after the other then lands inside one period, which is what the gate binds.
    function test_Sweep_TheExpiryPiggybackIsRateLimited() public {
        AceFixtures.Deployment memory d = _deploy(treasury);
        usdc.mint(alice, 5_000e6);
        vm.startPrank(alice);
        usdc.approve(address(d.ace), 5_000e6);
        d.ace.deposit(d.id, 5_000e6);
        vm.stopPrank();

        uint256 first = _openAnother(d);
        uint256 second = _openAnother(d);
        _warpTo(uint256(d.read.loan(first).expiry) + 1);
        assertEq(d.read.loan(second).expiry, d.read.loan(first).expiry, "guard: both expire together");

        vm.prank(keeper);
        d.ace.forceClose(first);
        uint256 paid = usdc.balanceOf(treasury);
        assertGt(paid, 0, "the first settlement delivered");

        _bankMore(d); // fresh revenue, so the refusal is about the GATE and not an empty pot
        vm.prank(keeper);
        d.ace.forceClose(second);

        assertEq(usdc.balanceOf(treasury), paid, "a second settlement inside the period pushes nothing");
        assertGt(d.read.protocolRevenue(d.id), 0, "the fresh revenue banks instead");
    }

    /// @notice A DELIBERATE sweep is ungated: it pays inside a period a keeper crank already stamped.
    /// @dev THIS IS THE ROW THAT FAILS BEFORE THE SPLIT -- the whole point of separating the two gates.
    function test_Sweep_ThePublicCallIsUngated() public {
        AceFixtures.Deployment memory d = _deploy(treasury);
        uint256 loanId = _bankAndAge(d);

        _crank(d, loanId); // stamps the clock
        uint256 paid = usdc.balanceOf(treasury);
        assertGt(paid, 0, "the crank delivered and stamped");

        _bankMore(d);
        d.ace.sweepRevenue(d.id); // same period, no warp: the piggyback would refuse this

        assertGt(usdc.balanceOf(treasury), paid, "a deliberate sweep is not refused by the piggyback's clock");
        assertEq(d.read.protocolRevenue(d.id), 0, "and it drained the pot it found");
    }

    /// @notice A deliberate sweep still stamps, so it does close the piggyback gate for a period.
    /// @dev Harmless -- it drained the pot -- but it is a chosen behaviour, so it is pinned not inherited.
    function test_Sweep_ThePublicCallStillStampsTheClock() public {
        AceFixtures.Deployment memory d = _deploy(treasury);
        uint256 loanId = _bankAndAge(d);

        d.ace.sweepRevenue(d.id);
        uint256 paid = usdc.balanceOf(treasury);
        assertGt(paid, 0, "the deliberate sweep paid");

        _bankMore(d);
        _crank(d, loanId); // same period: the piggyback must now refuse

        assertEq(usdc.balanceOf(treasury), paid, "the piggyback is closed for the period the public call stamped");
    }

    /// @notice The destination is fixed per deployment: two hubs, two treasuries, no crosstalk.
    function test_Sweep_DestinationIsPerDeployment() public {
        address other = address(0x7EA6);
        AceFixtures.Deployment memory a = _deploy(treasury);
        AceFixtures.Deployment memory b = _deploy(other);

        uint256 loanA = _bankAndAge(a);
        _bank(b); // B banks its own cut, so "untouched" below is a real quantity; never cranked, it needs no aging to age A past a tenor
        _crank(a, loanA);

        assertGt(usdc.balanceOf(treasury), 0, "hub A paid its own treasury");
        assertEq(usdc.balanceOf(other), 0, "and nothing reached hub B's");
        assertGt(b.read.protocolRevenue(b.id), 0, "hub B's own pot is untouched and still banked");
    }
}
