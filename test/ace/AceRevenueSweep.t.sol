// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.36;

import {Test} from "forge-std/Test.sol";
import {WarpClock} from "../utils/WarpClock.sol";
import {Ace} from "../../src/ace/hub/Ace.sol";
import {MarketParams, OpenBounds} from "../../src/ace/hub/Types.sol";
import {PositionManager} from "../../src/ace/positions/PositionManager.sol";
import {ProtocolPolicy} from "../../src/config/Defaults.sol";
import {MockERC20} from "../mocks/MockERC20.sol";
import {MockPersistenceRecord} from "../mocks/MockPersistenceRecord.sol";
import {MockStakeVault} from "../mocks/MockStakeVault.sol";
import {AceFixtures} from "../utils/AceFixtures.sol";
import {AceReader} from "../utils/AceReader.sol";

/// @title AceRevenueSweep
/// @notice The protocol-revenue sweep: one pot per quote, one exit, and a destination fixed at deploy.
/// @notice No clock gates the door, and no keeper verb sweeps: `AceRevenuePot` pins the second.
/// @dev Both postures are pinned here because only one can be live per deployment: a funded treasury DELIVERS, `address(0)` is INERT and banks in the pot.
/// @dev The destination is a constructor argument precisely so one fixture can exercise both.
contract AceRevenueSweepTest is WarpClock {
    MockERC20 internal usdc;
    MockStakeVault internal vault;
    MockPersistenceRecord internal record;
    uint256 internal constant BAND_BPS = 3000;

    address internal alice = address(0xA11CE);
    address internal borrower = address(0xB0B);
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
        p.deleverageBandBps = BAND_BPS;
        p.deleverageTargetBps = 4000;
        p.deleverageStopBps = 1;
        p.deleverageProtocolBps = 500;
        d = AceFixtures.deployWithTreasury(p, dest);
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

        assertGt(d.read.revenuePot(address(usdc)), 0, "origination banked a protocol cut");
    }

    /// @dev Bank a FRESH origination cut, so the "is there anything left to sweep" rows are not vacuous.
    function _bankMore(AceFixtures.Deployment memory d) internal {
        vault.mint(borrower, COLL);
        vm.startPrank(borrower);
        vault.approve(address(d.positionManager), COLL);
        d.ace.open(d.id, COLL, 500e6, 0, borrower, OpenBounds(0, 0, 0));
        vm.stopPrank();
    }

    /// @notice `address(0)`: the sweep is structurally inert and revenue banks in the pot.
    /// @dev Inertness is the GUARD, never a bet on the token rejecting the zero address: `MockERC20` transfers there happily, and burns the pot.
    /// @dev The door is called DIRECTLY: no keeper verb sweeps, so a crank here would pass whether or not the guard held.
    function test_Sweep_IsInertWhenTheDestinationIsUnset() public {
        AceFixtures.Deployment memory d = _deploy(address(0));
        _bank(d);
        uint256 banked = d.read.revenuePot(address(usdc));

        _bankMore(d);
        d.ace.sweepRevenue(address(usdc));

        assertGt(d.read.revenuePot(address(usdc)), banked, "the pot only grows: an inert sweep never drains it");
        assertEq(usdc.balanceOf(address(0)), 0, "and not one wei was burned to the zero address");
    }

    /// @notice A DELIBERATE sweep is ungated: a second one in the same block, after a fresh accrual, pays again.
    function test_Sweep_ThePublicCallIsUngated() public {
        AceFixtures.Deployment memory d = _deploy(treasury);
        _bank(d);

        d.ace.sweepRevenue(address(usdc));
        uint256 paid = usdc.balanceOf(treasury);
        assertGt(paid, 0, "the first sweep delivered");

        _bankMore(d);
        d.ace.sweepRevenue(address(usdc)); // same block, no warp: no clock gates the door

        assertGt(usdc.balanceOf(treasury), paid, "a second sweep in the same block is not refused by any clock");
        assertEq(d.read.revenuePot(address(usdc)), 0, "and it drained the pot it found");
    }

    /// @notice The destination is fixed per deployment: two hubs, two treasuries, no crosstalk, though both quote the same token.
    function test_Sweep_DestinationIsPerDeployment() public {
        address other = address(0x7EA6);
        AceFixtures.Deployment memory a = _deploy(treasury);
        AceFixtures.Deployment memory b = _deploy(other);

        _bank(a);
        _bank(b); // B banks its own cut in the same quote, so "untouched" below is a real quantity
        a.ace.sweepRevenue(address(usdc));

        assertGt(usdc.balanceOf(treasury), 0, "hub A paid its own treasury");
        assertEq(usdc.balanceOf(other), 0, "and nothing reached hub B's");
        assertGt(b.read.revenuePot(address(usdc)), 0, "hub B's own pot in that quote is untouched and still banked");
    }
}
