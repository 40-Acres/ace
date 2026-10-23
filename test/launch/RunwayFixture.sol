// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.36;

import {IHooks} from "@uniswap/v4-core/src/interfaces/IHooks.sol";
import {IPoolManager} from "@uniswap/v4-core/src/interfaces/IPoolManager.sol";
import {Currency} from "@uniswap/v4-core/src/types/Currency.sol";
import {PoolKey} from "@uniswap/v4-core/src/types/PoolKey.sol";
import {PoolManager} from "../../vendor/v4/PoolManager.sol";
import {WarpClock} from "../utils/WarpClock.sol";
import {Ace} from "../../src/ace/hub/Ace.sol";
import {LaunchLock, Leg} from "../../src/entities/launch/LaunchLock.sol";
import {LaunchOpsBudget} from "../../src/entities/launch/LaunchOpsBudget.sol";
import {LaunchTokenFactory} from "../../src/entities/launch/LaunchTokenFactory.sol";
import {MockERC20} from "../mocks/MockERC20.sol";
import {AceFixtures} from "../utils/AceFixtures.sol";
import {MockLaunchAuction} from "./MockLaunchAuction.sol";
import {MockPositions, MockRunwayStrategy, RunwaySalt} from "./RunwayMocks.sol";

/// @title RunwayFixture
/// @notice One hub, a local v4 PoolManager, a stand-in strategy and PositionManager, and the launch factory on them, its hook mined in setUp.
/// @dev Each launch registers a fresh settable auction, so a row can drive settlement and refunds by hand.
abstract contract RunwayFixture is WarpClock {
    string internal constant NAME = "Runway Launch";
    string internal constant SYMBOL = "RWY";
    uint128 internal constant SUPPLY = 1_000_000e18; // the auction's supply; the pool's reserve is the same again
    uint256 internal constant TICK = 1 << 40; // the auction's Q96 price tick
    uint256 internal constant FLOOR = 720 << 40; // about $0.01 a token, Q96 USDC atoms per token atom
    uint24 internal constant FEE = 10_000;
    int24 internal constant SPACING = 200;
    uint256 internal constant BLOCK_SECONDS = 13;
    uint256 internal constant TEAM_AMT = 100_000e18;
    uint256 internal constant OPS = 200_000e18; // under a tenth of the default supply, 2.3M
    uint256 internal constant SHARE = 2_000; // the default team share of the raise
    uint256 internal constant TEAM_LINEAR = 1; // schedule id of the default leg: a 30-day cliff, linear over a year
    uint64 internal constant BLOCKS = 100; // the default auction's length, which divides its whole
    address internal constant DEAD = 0x000000000000000000000000000000000000dEaD;

    Ace internal ace;
    MockERC20 internal usdc;
    PoolManager internal manager;
    MockPositions internal posm;
    MockRunwayStrategy internal strat;
    LaunchTokenFactory internal factory;
    uint256 internal T0;

    address internal team = address(0x7EA4);
    address internal operator = address(0x0905);
    address internal alice = address(0xA11CE5);
    address internal bob = address(0xB0B);
    address internal stranger = address(0x57A1);
    address internal cutSink = address(0xC075); // every fixture factory's cut recipient

    /// @dev What one launch made, as the factory recorded it, and the launch time it was built against.
    struct Made {
        address token;
        LaunchLock lock;
        MockLaunchAuction auction;
        LaunchOpsBudget budget;
        uint256 launchBy;
        PoolKey key;
    }

    function setUp() public virtual {
        T0 = _now();
        (ace,) = AceFixtures.newAceWithEscrow(AceFixtures.TREASURY);
        usdc = new MockERC20("USD Coin", "USDC", 6);
        manager = new PoolManager(address(this));
        posm = new MockPositions(IPoolManager(address(manager)));
        strat = new MockRunwayStrategy(address(posm));
        factory = _factory(BLOCK_SECONDS, FEE);
    }

    /// @dev A factory on the fixture's strategy, its hook salt mined against the address the factory is about to land at.
    function _factory(uint256 blockSeconds, uint24 fee) internal returns (LaunchTokenFactory) {
        return _factory(blockSeconds, fee, SPACING);
    }

    function _factory(uint256 blockSeconds, uint24 fee, int24 spacing) internal returns (LaunchTokenFactory f) {
        return _factory(blockSeconds, fee, spacing, 0);
    }

    /// @dev A factory taking `cutBps` of every live launch's raise for `cutSink`.
    function _factory(uint256 blockSeconds, uint24 fee, int24 spacing, uint256 cutBps) internal returns (LaunchTokenFactory f) {
        address at = vm.computeCreateAddress(address(this), vm.getNonce(address(this)));
        bytes32 salt = RunwaySalt.mine(at, address(manager), address(strat));
        f = new LaunchTokenFactory(address(ace), address(strat), address(usdc), blockSeconds, fee, spacing, salt, cutSink, cutBps);
        require(address(f) == at, "fixture: the factory landed off its prediction");
    }

    /// @dev The default launch: a 100-block auction from two blocks out, one team leg on a year's vest, an ops budget and a 20% share.
    function _input() internal view returns (LaunchTokenFactory.LaunchInput memory p) {
        uint64 b = uint64(vm.getBlockNumber());
        (p.name, p.symbol) = (NAME, SYMBOL);
        (p.auctionSupply, p.floorPrice, p.tickSpacing) = (SUPPLY, FLOOR, TICK);
        (p.startBlock, p.endBlock) = (b + 2, b + 2 + BLOCKS);
        (p.teamShareBps, p.buyerDuration) = (SHARE, 30 days);
        p.legs = new Leg[](1);
        p.legs[0] = Leg({beneficiary: team, amount: TEAM_AMT, cliff: 30 days, duration: 365 days});
        (p.opsAmount, p.operator) = (OPS, operator);
    }

    /// @dev The supply a launch of `p` mints: the strategy's two halves, every team leg and the ops amount.
    function _supplyOf(LaunchTokenFactory.LaunchInput memory p) internal pure returns (uint256 s) {
        s = 2 * uint256(p.auctionSupply) + p.opsAmount;
        for (uint256 i; i < p.legs.length; ++i) {
            s += p.legs[i].amount;
        }
    }

    /// @dev The launch of `p`'s launchBy, launched in this block: the migration block at the assumed slowest block time, plus a day.
    function _launchBy(LaunchTokenFactory.LaunchInput memory p) internal view returns (uint256) {
        return _now() + (uint256(p.endBlock) + 1 - vm.getBlockNumber()) * BLOCK_SECONDS + 1 days;
    }

    /// @dev `team` launches `p`; the strategy registers a fresh settable auction, set to the launch's token and end.
    function _launch(LaunchTokenFactory.LaunchInput memory p) internal returns (Made memory m) {
        MockLaunchAuction a = new MockLaunchAuction();
        strat.setNext(address(a));
        m.launchBy = _launchBy(p);
        vm.prank(team);
        m.token = factory.launch(p);
        (address lock, address auction, address budget) = factory.launchOf(m.token);
        (m.lock, m.auction, m.budget) = (LaunchLock(lock), MockLaunchAuction(auction), LaunchOpsBudget(budget));
        m.key = _keyOf(m.token);
        a.set(m.token, address(usdc), lock, p.endBlock);
        a.setUnsold(budget, 0);
    }

    function _launch() internal returns (Made memory) {
        return _launch(_input());
    }

    /// @dev The launch pool of `t`: against the fixture's USDC, at the factory's fee and spacing, behind its hook.
    function _keyOf(address t) internal view returns (PoolKey memory) {
        (address c0, address c1) = t < address(usdc) ? (t, address(usdc)) : (address(usdc), t);
        return PoolKey(Currency.wrap(c0), Currency.wrap(c1), FEE, SPACING, IHooks(address(factory.HOOK())));
    }
}
