// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.36;

import {WarpClock} from "../utils/WarpClock.sol";
import {PushRefused} from "../../src/ace/hub/Ace.sol";
import {MarketParams, OpenBounds} from "../../src/ace/hub/Types.sol";
import {RevenueRouter} from "../../src/ace/treasury/RevenueRouter.sol";
import {MockBlockableERC20} from "../mocks/MockBlockableERC20.sol";
import {MockPersistenceRecord} from "../mocks/MockPersistenceRecord.sol";
import {MockStakeVault} from "../mocks/MockStakeVault.sol";
import {AceFixtures} from "../utils/AceFixtures.sol";

/// @title AceRevenueRouter
/// @notice The hub's immutable treasury is a RevenueRouter: the hub pushes to it, and it forwards to a sink.
/// @notice Two hops, two failure points, and each one parks the revenue where it stands rather than losing it.
contract AceRevenueRouterTest is WarpClock {
    MockStakeVault internal vault;
    RevenueRouter internal router;

    address internal owner = makeAddr("owner");
    address internal sink = makeAddr("sink");
    address internal alice = address(0xA11CE);
    address internal borrower = address(0xB0B);

    uint256 internal constant COLL = 10_000e18;
    uint256 internal constant PRINCIPAL = 4_500e6;

    event RevenueSwept(bytes32 indexed market, address indexed to, uint256 amount, uint64 at);
    event RevenueSweepFailed(bytes32 indexed market, address indexed to, uint256 amount, uint64 at);

    function setUp() public {
        _warpTo(1_000_000);
        vault = new MockStakeVault(42);
        router = new RevenueRouter(owner, sink);
    }

    function _list(address a) internal pure returns (address[] memory l) {
        l = new address[](1);
        l[0] = a;
    }

    /// @dev A hub whose treasury is the router, with one open loan's origination cut banked and unswept.
    function _hubWithRevenue(MockBlockableERC20 quote) internal returns (AceFixtures.Deployment memory d, uint256 banked) {
        MockPersistenceRecord record = new MockPersistenceRecord(address(quote), address(vault));
        record.setMinPrice(AceFixtures.priceAt(address(quote), address(vault), 0));
        MarketParams memory p = AceFixtures.marketParams(address(quote), address(vault));
        p.record = address(record);
        d = AceFixtures.deployWithTreasury(p, address(router));

        quote.mint(alice, 30_000e6);
        vm.startPrank(alice);
        quote.approve(address(d.ace), 30_000e6);
        d.ace.deposit(d.id, 30_000e6);
        vm.stopPrank();

        vault.mint(borrower, COLL);
        vm.startPrank(borrower);
        vault.approve(address(d.positionManager), COLL);
        d.ace.open(d.id, COLL, PRINCIPAL, 0, borrower, OpenBounds(0, 0, 0));
        vm.stopPrank();

        banked = d.read.protocolRevenue(d.id);
        assertGt(banked, 0, "guard: origination banked a cut");
    }

    /// @notice I1: the whole path. The hub pays the router, and the router's sweep pays the sink.
    function test_HubPaysTheRouter_AndTheRouterPaysTheSink() public {
        MockBlockableERC20 usdc = new MockBlockableERC20("USD Coin", "USDC", 6);
        (AceFixtures.Deployment memory d, uint256 banked) = _hubWithRevenue(usdc);

        vm.expectEmit(true, true, false, true, address(d.ace));
        emit RevenueSwept(d.id, address(router), banked, uint64(_now()));
        d.ace.sweepRevenue(d.id);
        assertEq(usdc.balanceOf(address(router)), banked, "the hub's push landed in the router");
        assertEq(d.read.protocolRevenue(d.id), 0, "and cleared the hub's counter");

        router.sweep(_list(address(usdc)));
        assertEq(usdc.balanceOf(sink), banked, "the sink holds exactly what the hub banked");
        assertEq(usdc.balanceOf(address(router)), 0, "the router holds nothing");
    }

    /// @notice I2: one router outlives a hub redeploy. Two hubs, two quotes, one router, one sweep.
    function test_OneRouterServesTwoHubs() public {
        MockBlockableERC20 q1 = new MockBlockableERC20("USD Coin", "USDC", 6);
        MockBlockableERC20 q2 = new MockBlockableERC20("Tether USD", "USDT", 6);
        (AceFixtures.Deployment memory d1, uint256 b1) = _hubWithRevenue(q1);
        (AceFixtures.Deployment memory d2, uint256 b2) = _hubWithRevenue(q2);
        assertTrue(address(d1.ace) != address(d2.ace), "guard: two distinct hubs");

        d1.ace.sweepRevenue(d1.id);
        d2.ace.sweepRevenue(d2.id);
        address[] memory both = new address[](2);
        (both[0], both[1]) = (address(q1), address(q2));
        router.sweep(both);

        assertEq(q1.balanceOf(sink), b1, "the first hub's quote reached the sink");
        assertEq(q2.balanceOf(sink), b2, "and the second's");
    }

    /// @notice I3: a quote that refuses the SINK stops at the router, never at the hub.
    /// @notice The hub's sweep succeeds, the router parks the balance, and a repoint recovers it.
    function test_ASinkTheQuoteRefusesParksAtTheRouter_AndARepointRecovers() public {
        MockBlockableERC20 usdc = new MockBlockableERC20("USD Coin", "USDC", 6);
        (AceFixtures.Deployment memory d, uint256 banked) = _hubWithRevenue(usdc);
        usdc.setBlocked(sink, true);

        d.ace.sweepRevenue(d.id);
        assertEq(d.read.protocolRevenue(d.id), 0, "the hub hop is unaffected by the sink");

        vm.expectEmit(true, true, false, true, address(router));
        emit RevenueRouter.SweepFailed(address(usdc), sink, banked);
        router.sweep(_list(address(usdc)));
        assertEq(usdc.balanceOf(address(router)), banked, "parked at the router");

        address next = makeAddr("next");
        vm.prank(owner);
        router.setSink(next);
        router.sweep(_list(address(usdc)));
        assertEq(usdc.balanceOf(next), banked, "the repointed sink receives it all");
    }

    /// @notice I4: a quote that refuses the ROUTER stops at the hub: the strict sweep reverts `PushRefused` and its counter stands.
    function test_AQuoteThatRefusesTheRouterBanksAtTheHub() public {
        MockBlockableERC20 usdc = new MockBlockableERC20("USD Coin", "USDC", 6);
        (AceFixtures.Deployment memory d, uint256 banked) = _hubWithRevenue(usdc);
        usdc.setBlocked(address(router), true);

        vm.expectRevert(PushRefused.selector);
        d.ace.sweepRevenue(d.id);
        assertEq(d.read.protocolRevenue(d.id), banked, "the revert left the hub's counter whole");
        assertEq(usdc.balanceOf(address(router)), 0, "nothing reached the router");

        usdc.setBlocked(address(router), false);
        d.ace.sweepRevenue(d.id);
        assertEq(usdc.balanceOf(address(router)), banked, "the next sweep delivers once the quote relents");
    }
}
