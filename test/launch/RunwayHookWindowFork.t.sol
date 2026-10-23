// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.36;

import {console2} from "forge-std/console2.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {IERC721} from "@openzeppelin/contracts/token/ERC721/IERC721.sol";
import {IHooks} from "@uniswap/v4-core/src/interfaces/IHooks.sol";
import {IPoolManager} from "@uniswap/v4-core/src/interfaces/IPoolManager.sol";
import {Hooks} from "@uniswap/v4-core/src/libraries/Hooks.sol";
import {StateLibrary} from "@uniswap/v4-core/src/libraries/StateLibrary.sol";
import {TickMath} from "@uniswap/v4-core/src/libraries/TickMath.sol";
import {PoolSwapTest} from "@uniswap/v4-core/src/test/PoolSwapTest.sol";
import {Currency} from "@uniswap/v4-core/src/types/Currency.sol";
import {PoolId, PoolIdLibrary} from "@uniswap/v4-core/src/types/PoolId.sol";
import {PoolKey} from "@uniswap/v4-core/src/types/PoolKey.sol";
import {SwapParams} from "@uniswap/v4-core/src/types/PoolOperation.sol";
import {WarpClock} from "../utils/WarpClock.sol";
import {Ace} from "../../src/ace/hub/Ace.sol";
import {LaunchLock, Leg} from "../../src/entities/launch/LaunchLock.sol";
import {LaunchTokenFactory} from "../../src/entities/launch/LaunchTokenFactory.sol";
import {RunwayHook} from "../../src/entities/launch/RunwayHook.sol";
import {AceFixtures} from "../utils/AceFixtures.sol";
import {IAllowanceTransfer, ICcaBidding, ILBPStrategyLaunch, IPositionsView} from "./CcaInterfaces.sol";
import {RunwaySalt} from "./RunwayMocks.sol";

/// @title RunwayHookWindowFork
/// @notice The two-flag Runway hook against the DEPLOYED launcher on a mainnet fork: the strategy migrates a live launch into it.
/// @notice Swaps on the real launch pool then sample each block's start, and the hook's gas is measured there.
/// @dev Skipped cleanly when ALCHEMY_API_KEY is absent, as every fork suite here is.
contract RunwayHookWindowForkTest is WarpClock {
    using PoolIdLibrary for PoolKey;
    using StateLibrary for IPoolManager;

    address internal constant STRATEGY = 0x2EEF0e2a9a652d755AccAD95a24541A98B5CA000; // LBPStrategy v3.3.0, mainnet
    address internal constant PERMIT2 = 0x000000000022D473030F116dDEE9F6B43aC78BA3;
    address internal constant USDC = 0xA0b86991c6218b36c1d19D4a2e9Eb0cE3606eB48;
    uint256 internal constant FORK_BLOCK = 26_140_979;
    uint256 internal constant BLOCK_SECONDS = 13;
    uint24 internal constant FEE = 10_000;
    int24 internal constant SPACING = 200;
    uint128 internal constant SUPPLY = 1_000_000e18;
    uint256 internal constant TICK = 1 << 40; // Q96 tick spacing
    uint256 internal constant FLOOR = 720 << 40; // about $0.01 a token, Q96 USDC atoms per token atom
    uint128 internal constant BID = 1_000e6;

    bool internal live;
    IPoolManager internal pm;
    address internal posm;
    LaunchTokenFactory internal factory;
    RunwayHook internal hook;
    PoolSwapTest internal swapper;
    address internal token;
    address internal budget;
    PoolKey internal key;
    PoolId internal id;
    uint256 internal firstLp; // the migration's first LP position

    address internal team = address(0x7EA4);
    address internal operator = address(0x0905);
    address internal bidder = address(0xB1DD);

    /// @dev Every row starts in the migration block of a live launch: one bid, migrated by the deployed strategy, no swap yet.
    function setUp() public {
        string memory k = vm.envOr("ALCHEMY_API_KEY", string(""));
        if (bytes(k).length == 0) return;
        vm.createSelectFork(string.concat("https://eth-mainnet.g.alchemy.com/v2/", k), vm.envOr("ACE_LAUNCH_FORK_BLOCK", FORK_BLOCK));
        _anchorClock();
        if (STRATEGY.code.length == 0) return;
        live = true;
        (Ace ace,) = AceFixtures.newAceWithEscrow(AceFixtures.TREASURY);
        posm = ILBPStrategyLaunch(STRATEGY).positionManager();
        pm = IPositionsView(posm).poolManager();
        address at = vm.computeCreateAddress(address(this), vm.getNonce(address(this)));
        bytes32 salt = RunwaySalt.mine(at, address(pm), STRATEGY);
        factory = new LaunchTokenFactory(address(ace), STRATEGY, USDC, BLOCK_SECONDS, FEE, SPACING, salt, address(0x51CC), 0);
        hook = factory.HOOK();
        swapper = new PoolSwapTest(pm);
        _liveLaunch();
    }

    /// @dev The default launch: a 100-block auction from two blocks out, one team leg, ops, a 20% share.
    function _input() internal view returns (LaunchTokenFactory.LaunchInput memory p) {
        uint64 b = uint64(vm.getBlockNumber());
        (p.name, p.symbol) = ("Launch", "LCH");
        (p.auctionSupply, p.floorPrice, p.tickSpacing) = (SUPPLY, FLOOR, TICK);
        (p.startBlock, p.endBlock) = (b + 2, b + 102);
        (p.teamShareBps, p.buyerDuration) = (2_000, 30 days);
        p.legs = new Leg[](1);
        p.legs[0] = Leg({beneficiary: team, amount: 50_000e18, cliff: 30 days, duration: 365 days});
        (p.opsAmount, p.operator) = (200_000e18, operator);
    }

    /// @dev Launch, one bid from a buyer account, then the deployed strategy's migration in the block after the end.
    function _liveLaunch() internal {
        LaunchTokenFactory.LaunchInput memory p = _input();
        vm.prank(team);
        token = factory.launch(p);
        (address lock, address auction, address b) = factory.launchOf(token);
        budget = b;
        (address c0, address c1) = token < USDC ? (token, USDC) : (USDC, token);
        key = PoolKey(Currency.wrap(c0), Currency.wrap(c1), FEE, SPACING, IHooks(address(hook)));
        id = key.toId();
        deal(USDC, bidder, BID);
        vm.roll(p.startBlock);
        vm.startPrank(bidder);
        IERC20(USDC).approve(PERMIT2, type(uint256).max);
        IAllowanceTransfer(PERMIT2).approve(USDC, auction, type(uint160).max, type(uint48).max);
        ICcaBidding(auction).submitBid(FLOOR + 10 * TICK, BID, LaunchLock(lock).predict(bidder, 0), abi.encode(bidder));
        vm.stopPrank();
        vm.roll(p.endBlock + 1);
        firstLp = IPositionsView(posm).nextTokenId();
        ILBPStrategyLaunch(STRATEGY).migrate(auction);
    }

    /// @dev An exact-input swap of `amount` of `tokenIn` through the launch pool, funded by `deal`.
    function _swapIn(address tokenIn, uint256 amount) internal {
        deal(tokenIn, address(this), amount);
        IERC20(tokenIn).approve(address(swapper), amount);
        bool zeroForOne = Currency.unwrap(key.currency0) == tokenIn;
        uint160 limit = zeroForOne ? TickMath.MIN_SQRT_PRICE + 1 : TickMath.MAX_SQRT_PRICE - 1;
        swapper.swap(key, SwapParams(zeroForOne, -int256(amount), limit), PoolSwapTest.TestSettings(false, false), "");
    }

    function _tick() internal view returns (int24 t) {
        (, t,,) = pm.getSlot0(id);
    }

    function _nextBlock() internal {
        vm.roll(vm.getBlockNumber() + 1);
        _warpBy(12);
    }

    function _min(int24 a, int24 b) internal pure returns (int24) {
        return a < b ? a : b;
    }

    function _max(int24 a, int24 b) internal pure returns (int24) {
        return a > b ? a : b;
    }

    /// @notice The deployed strategy migrates a live launch into the two-flag hook: the recorded pool opens behind it, with liquidity, the LP the budget's.
    function test_Fork_TheStrategyMigratesLiveIntoTheTwoFlagHook() public {
        if (!live) return vm.skip(true);
        assertEq(uint160(address(hook)) & Hooks.ALL_HOOK_MASK, Hooks.BEFORE_INITIALIZE_FLAG | Hooks.BEFORE_SWAP_FLAG, "the hook's bits");
        assertGt(IPositionsView(posm).nextTokenId(), firstLp, "the migration minted no position");
        (PoolKey memory k,) = IPositionsView(posm).getPoolAndPositionInfo(firstLp);
        assertEq(keccak256(abi.encode(k)), keccak256(abi.encode(key)), "the LP is not in the recorded pool");
        assertEq(IERC721(posm).ownerOf(firstLp), budget, "the LP is not the budget's");
        (uint160 sqrtP,,,) = pm.getSlot0(id);
        assertGt(sqrtP, 0, "the recorded pool did not open");
        assertGt(pm.getLiquidity(id), 0, "the recorded pool holds no liquidity");
    }

    /// @notice The first swap in the migration block samples the price the strategy opened the pool at, never the price it swapped to.
    function test_Fork_TheMigrationBlocksFirstSwapSamplesTheOpeningPrice() public {
        if (!live) return vm.skip(true);
        int24 opened = _tick();
        _swapIn(USDC, 50e6);
        assertTrue(_tick() != opened, "fixture: the swap moved the price");
        (int24 lo, int24 hi, int24 spot) = hook.windowOf(id);
        assertEq(abi.encode(lo, hi, spot), abi.encode(opened, opened, _tick()), "the migration block's window is not the opening price");
    }

    /// @notice Swaps on the real pool sample each block's start: a block's window holds what the earlier blocks left, never this block's moves.
    function test_Fork_SwapsSampleTheBlockStartTick() public {
        if (!live) return vm.skip(true);
        int24 opened = _tick();
        _swapIn(token, 2_000e18);
        int24 first = _tick();
        _nextBlock();
        _swapIn(USDC, 50e6);
        int24 second = _tick();
        assertTrue(opened != first && first != second, "fixture: each swap moved the price");
        (int24 lo, int24 hi, int24 spot) = hook.windowOf(id);
        assertEq(abi.encode(lo, hi, spot), abi.encode(_min(opened, first), _max(opened, first), second), "this block's swap reached the window");
        _nextBlock();
        (lo, hi,) = hook.windowOf(id);
        assertEq(abi.encode(lo, hi), abi.encode(_min(_min(opened, first), second), _max(_max(opened, first), second)), "the window is not the three starts");
    }

    /// @notice The hook's gas on the real pool, each swap its own transaction, the same buy every time.
    /// @notice A block's sample is the gap between its first swap and a later one; the migration block's gap also holds the pool's own first fee write.
    /// @dev forge-config: default.isolate = true
    /// @dev forge-config: deploy.isolate = true
    function test_Fork_TheHooksGas() public {
        if (!live) return vm.skip(true);
        _swapIn(USDC, 10e6);
        uint256 poolFirst = vm.lastCallGas().gasTotalUsed;
        _swapIn(USDC, 10e6);
        uint256 laterInMigration = vm.lastCallGas().gasTotalUsed;
        _nextBlock();
        _swapIn(USDC, 10e6);
        uint256 blockFirst = vm.lastCallGas().gasTotalUsed;
        _swapIn(USDC, 10e6);
        uint256 later = vm.lastCallGas().gasTotalUsed;
        console2.log("fork swap gas, the pool's first swap", poolFirst);
        console2.log("fork swap gas, a later swap in the migration block", laterInMigration);
        console2.log("fork swap gas, a block's first swap", blockFirst);
        console2.log("fork swap gas, a later swap in that block", later);
        assertGt(poolFirst, laterInMigration, "the pool's first sample cost nothing");
        assertGt(blockFirst, later, "a block's sample cost nothing");
        assertLe(blockFirst - later, 8_000, "a block's sample costs more than a rewrite");
    }
}
