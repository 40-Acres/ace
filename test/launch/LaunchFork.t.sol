// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.36;

import {Vm} from "forge-std/Vm.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {IERC721} from "@openzeppelin/contracts/token/ERC721/IERC721.sol";
import {Math} from "@openzeppelin/contracts/utils/math/Math.sol";
import {IHooks} from "@uniswap/v4-core/src/interfaces/IHooks.sol";
import {IPoolManager} from "@uniswap/v4-core/src/interfaces/IPoolManager.sol";
import {CustomRevert} from "@uniswap/v4-core/src/libraries/CustomRevert.sol";
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
import {RevenueRouter} from "../../src/ace/treasury/RevenueRouter.sol";
import {OpenBounds} from "../../src/ace/hub/Types.sol";
import {
    AuctionParameters,
    IContinuousClearingAuction,
    ILBPStrategy,
    LiquidityAllocationBracket,
    MigratorParameters,
    PoolParameters,
    PositionDefinition
} from "../../src/interfaces/ILaunchAuction.sol";
import {InitializerHook} from "../../vendor/launcher/InitializerHook.sol";
import {VestingWallet} from "@openzeppelin/contracts/finance/VestingWallet.sol";
import {LaunchLock, Leg} from "../../src/entities/launch/LaunchLock.sol";
import {LaunchOpsBudget} from "../../src/entities/launch/LaunchOpsBudget.sol";
import {LaunchTokenFactory} from "../../src/entities/launch/LaunchTokenFactory.sol";
import {LockAccount} from "../../src/entities/launch/LockAccount.sol";
import {RunwayHook} from "../../src/entities/launch/RunwayHook.sol";
import {MockERC20} from "../mocks/MockERC20.sol";
import {AceFixtures} from "../utils/AceFixtures.sol";
import {IAllowanceTransfer, ICcaBidding, ILBPStrategyLaunch, IPositionsView} from "./CcaInterfaces.sol";
import {LaunchMarketParams} from "./LaunchFixture.sol";
import {RunwaySalt} from "./RunwayMocks.sol";

/// @title LaunchFork
/// @notice The one-call launch against the DEPLOYED launcher on a mainnet fork: the real LBP strategy, its auction, canonical Permit2, real USDC.
/// @notice The factory's shape as registered, the hook's gate through the strategy's own migration, the budget's settlement, refunds and fees.
/// @notice Plus B5 and L4: the real auction against the lock.
/// @dev Skipped cleanly when ALCHEMY_API_KEY is absent, as every fork suite here is.
/// @dev The strategy's auction factory is NOT the one the auction repo's README lists, so these rows check BEHAVIOUR, not source.
contract LaunchForkTest is WarpClock {
    using PoolIdLibrary for PoolKey;
    using StateLibrary for IPoolManager;

    address internal constant STRATEGY = 0x2EEF0e2a9a652d755AccAD95a24541A98B5CA000; // LBPStrategy v3.3.0, mainnet
    address internal constant PERMIT2 = 0x000000000022D473030F116dDEE9F6B43aC78BA3;
    address internal constant USDC = 0xA0b86991c6218b36c1d19D4a2e9Eb0cE3606eB48;
    address internal constant DEAD = 0x000000000000000000000000000000000000dEaD;
    uint256 internal constant FORK_BLOCK = 26_140_979;
    uint256 internal constant BLOCK_SECONDS = 13; // mainnet's 12-second slot, plus a second for missed slots
    uint24 internal constant FEE = 10_000;
    int24 internal constant SPACING = 200;

    uint128 internal constant SUPPLY = 1_000_000e18;
    uint256 internal constant TICK = 1 << 40; // Q96 tick spacing
    uint256 internal constant FLOOR = 720 << 40; // about $0.01 a token, Q96 USDC atoms per token atom
    uint128 internal constant BID = 1_000e6;
    uint256 internal constant TEAM_ALLOC = 50_000e18;
    uint256 internal constant OPS = 200_000e18;
    uint256 internal constant SHARE = 2_000;
    uint256 internal constant TEAM_LINEAR = 1;

    bool internal live;
    Ace internal ace;
    IPoolManager internal pm;
    address internal posm;
    LaunchTokenFactory internal factory;
    RunwayHook internal hook;

    address internal team = address(0x7EA4);
    address internal operator = address(0x0905);
    address internal bidder = address(0xB1DD);
    address internal stranger = address(0x57A1);

    /// @dev What one launch made, read back from the factory's record.
    struct Launch {
        address token;
        LaunchLock lock;
        address auction;
        LaunchOpsBudget budget;
        PoolKey key;
        uint64 start;
        uint64 end;
    }

    function setUp() public {
        string memory key = vm.envOr("ALCHEMY_API_KEY", string(""));
        if (bytes(key).length == 0) return;
        vm.createSelectFork(string.concat("https://eth-mainnet.g.alchemy.com/v2/", key), vm.envOr("ACE_LAUNCH_FORK_BLOCK", FORK_BLOCK));
        _anchorClock();
        if (STRATEGY.code.length == 0) return;
        live = true;
        (ace,) = AceFixtures.newAceWithEscrow(AceFixtures.TREASURY);
        posm = ILBPStrategyLaunch(STRATEGY).positionManager();
        pm = IPositionsView(posm).poolManager();
        address at = vm.computeCreateAddress(address(this), vm.getNonce(address(this)));
        bytes32 salt = RunwaySalt.mine(at, address(pm), STRATEGY);
        factory = new LaunchTokenFactory(address(ace), STRATEGY, USDC, BLOCK_SECONDS, FEE, SPACING, salt, SINK, 0);
        hook = factory.HOOK();
    }

    // ---- the launch, built once per row ----

    /// @dev The default launch: a 100-block auction from two blocks out, one team leg on the minimum cliff, ops, a 20% share.
    function _input() internal view returns (LaunchTokenFactory.LaunchInput memory p) {
        uint64 b = uint64(vm.getBlockNumber());
        (p.name, p.symbol) = ("Launch", "LCH");
        (p.auctionSupply, p.floorPrice, p.tickSpacing) = (SUPPLY, FLOOR, TICK);
        (p.startBlock, p.endBlock) = (b + 2, b + 102);
        (p.teamShareBps, p.buyerDuration) = (SHARE, 30 days);
        p.legs = new Leg[](1);
        p.legs[0] = Leg({beneficiary: team, amount: TEAM_ALLOC, cliff: 30 days, duration: 365 days});
        (p.opsAmount, p.operator) = (OPS, operator);
    }

    /// @dev `team` launches `p`; the strategy's own `InitializerCreated` log must name the auction the factory recorded.
    function _launch(LaunchTokenFactory.LaunchInput memory p) internal returns (Launch memory L) {
        vm.recordLogs();
        vm.prank(team);
        L.token = factory.launch(p);
        (address lock, address auction, address budget) = factory.launchOf(L.token);
        assertEq(_logged(), auction, "fixture: the strategy logged another auction than the factory recorded");
        (L.lock, L.auction, L.budget) = (LaunchLock(lock), auction, LaunchOpsBudget(budget));
        L.key = _key(L.token, address(hook));
        (L.start, L.end) = (p.startBlock, p.endBlock);
    }

    function _launch() internal returns (Launch memory) {
        return _launch(_input());
    }

    /// @dev The operator's wallet settlement made.
    function _wallet(Launch memory L) internal view returns (VestingWallet) {
        return VestingWallet(payable(L.budget.wallet()));
    }

    /// @dev The auction the strategy's own `InitializerCreated` log names, among the logs recorded since `vm.recordLogs`.
    function _logged() internal returns (address a) {
        Vm.Log[] memory logs = vm.getRecordedLogs();
        bytes32 created = keccak256("InitializerCreated(address,(address,address,uint64,uint128,address,address,(uint24,int24,address),bytes,bytes))");
        for (uint256 i; i < logs.length; ++i) {
            if (logs[i].emitter == STRATEGY && logs[i].topics[0] == created) a = address(uint160(uint256(logs[i].topics[1])));
        }
        assertGt(a.code.length, 0, "fixture: the strategy logged no auction");
    }

    /// @dev The v4 key of `t`'s pool against USDC at the factory's fee and spacing, behind `h`.
    function _key(address t, address h) internal pure returns (PoolKey memory) {
        (address c0, address c1) = t < USDC ? (t, USDC) : (USDC, t);
        return PoolKey({currency0: Currency.wrap(c0), currency1: Currency.wrap(c1), fee: FEE, tickSpacing: SPACING, hooks: IHooks(h)});
    }

    /// @dev The sqrt price, Q96, a pool of `t` against USDC starts at when the token clears at `clearingQ96` USDC atoms per token atom.
    function _sqrtAt(address t, uint256 clearingQ96) internal pure returns (uint256) {
        return t < USDC ? Math.sqrt(clearingQ96 << 96) : Math.mulDiv(1 << 144, 1, Math.sqrt(clearingQ96));
    }

    function _sqrtP(PoolKey memory k) internal view returns (uint160 sqrtP) {
        (sqrtP,,,) = pm.getSlot0(k.toId());
    }

    function _fundBidder(address who, address a, uint256 amount) internal {
        deal(USDC, who, amount);
        vm.startPrank(who);
        IERC20(USDC).approve(PERMIT2, type(uint256).max);
        IAllowanceTransfer(PERMIT2).approve(USDC, a, type(uint160).max, type(uint48).max);
        vm.stopPrank();
    }

    function _bid(Launch memory L, address owner, bytes memory hookData) internal returns (uint256) {
        _fundBidder(bidder, L.auction, BID);
        vm.roll(L.start);
        vm.prank(bidder);
        return ICcaBidding(L.auction).submitBid(FLOOR + 10 * TICK, BID, owner, hookData);
    }

    function _hookFailure(bytes4 inner) internal pure returns (bytes memory) {
        return abi.encodeWithSignature("ValidationHookCallFailed(bytes)", abi.encodeWithSelector(inner));
    }

    // ---- three bids: B fully filled until A outbids it at the end, A filled AT the clearing price, C above it ----

    uint256 internal constant P_LOW = FLOOR + 5 * TICK; // outbid by the end
    uint256 internal constant P_MID = FLOOR + 10 * TICK; // the final clearing price, partially filled
    uint256 internal constant P_HIGH = FLOOR + 20 * TICK; // above the final clearing price, fully filled
    uint128 internal constant BID_A = 50_000e6; // at P_MID: alone it can absorb the supply, so it sets the clearing price
    uint128 internal constant BID_B = 1_000e6; // at P_LOW, first in
    uint128 internal constant BID_C = 1_000e6; // at P_HIGH
    address internal buyerA = address(0xA0A0A);
    address internal buyerB = address(0xB0B0B);
    address internal buyerC = address(0xC0C0C);

    struct Bids {
        uint256 a;
        uint256 b;
        uint256 c;
        uint64 hint; // the last checkpoint below P_LOW and P_MID: A's own start block
        uint64 end;
    }

    function _bidAt(Launch memory L, address who, uint64 blk, uint256 price, uint128 amount) internal returns (uint256) {
        _fundBidder(who, L.auction, amount);
        address owner = L.lock.predict(who, 0);
        vm.roll(blk);
        vm.prank(who);
        return ICcaBidding(L.auction).submitBid(price, amount, owner, abi.encode(who));
    }

    function _threeBids(Launch memory L) internal returns (Bids memory x) {
        x.b = _bidAt(L, buyerB, L.start, P_LOW, BID_B);
        x.c = _bidAt(L, buyerC, L.start + 10, P_HIGH, BID_C);
        x.a = _bidAt(L, buyerA, L.start + 20, P_MID, BID_A);
        (x.hint, x.end) = (L.start + 20, L.end);
    }

    /// @dev Every bid exits through the auction's own doors; returns what each owner was refunded there, C, A, B.
    function _exitAll(Launch memory L, Bids memory x) internal returns (uint256 rc, uint256 ra, uint256 rb) {
        vm.roll(x.end);
        rc = _refundOf(L, buyerC, abi.encodeCall(ICcaBidding.exitBid, (x.c)));
        ra = _refundOf(L, buyerA, abi.encodeCall(ICcaBidding.exitPartiallyFilledBid, (x.a, x.hint, 0)));
        rb = _refundOf(L, buyerB, abi.encodeCall(ICcaBidding.exitPartiallyFilledBid, (x.b, x.hint, x.end)));
    }

    function _refundOf(Launch memory L, address who, bytes memory call) internal returns (uint256) {
        address acct = L.lock.predict(who, 0);
        uint256 pre = IERC20(USDC).balanceOf(acct);
        vm.prank(stranger);
        (bool ok, bytes memory ret) = L.auction.call(call);
        if (!ok) {
            assembly ("memory-safe") {
                revert(add(ret, 0x20), mload(ret))
            }
        }
        return IERC20(USDC).balanceOf(acct) - pre;
    }

    function _raisedQ96(address a) internal view returns (uint256) {
        return IContinuousClearingAuction(a).currencyRaisedQ96X7() / 1e7;
    }

    /// @dev Migrates `L` and returns the first position it minted, every one checked to be the launch's budget's.
    function _migrateAndMint(Launch memory L) internal returns (uint256 id) {
        id = IPositionsView(posm).nextTokenId();
        ILBPStrategyLaunch(STRATEGY).migrate(L.auction);
        uint256 last = IPositionsView(posm).nextTokenId();
        assertGt(last, id, "migration minted no position");
        for (uint256 i = id; i < last; ++i) {
            assertEq(IERC721(posm).ownerOf(i), address(L.budget), "an LP position is not the budget's");
        }
    }

    /// @dev The strategy's migration of `a` with every position-manager mint reverting; the strategy's own recovery branch takes over.
    function _failedMigrate(address a) internal {
        vm.mockCallRevert(posm, abi.encodeWithSelector(IPositionsView.modifyLiquidities.selector), "");
        uint256 next = IPositionsView(posm).nextTokenId();
        ILBPStrategyLaunch(STRATEGY).migrate(a);
        vm.clearMockedCalls();
        assertEq(IPositionsView(posm).nextTokenId(), next, "fixture: the failed migration minted a position");
    }

    /// @dev The launch's launchBy, read off the lock: every schedule starts there.
    function _launchBy(Launch memory L) internal view returns (uint256) {
        (uint64 start,,) = L.lock.schedules(0);
        return start;
    }

    /// @dev Move the clock a second past launchBy: settlement opens, and the hook closes the launch's key.
    function _pastLaunchBy(Launch memory L) internal {
        _warpTo(_launchBy(L) + 1);
    }

    /// @dev The default launch with three bids, migrated live: returns its first LP position.
    function _liveLaunch() internal returns (Launch memory L, Bids memory x, uint256 id) {
        L = _launch();
        x = _threeBids(L);
        vm.roll(L.end + 1);
        id = _migrateAndMint(L);
    }

    /// @dev The default launch with three bids, its migration forced into the strategy's recovery branch.
    function _failedLaunch() internal returns (Launch memory L, Bids memory x) {
        L = _launch();
        x = _threeBids(L);
        vm.roll(L.end + 1);
        _failedMigrate(L.auction);
    }

    // ---- the shape, as the deployed strategy and auction registered it ----

    /// @notice Every fixed field, read off the deployed strategy and auction: the factory's shape is what registered, nothing a team typed.
    function test_Fork_TheLaunchRegistersTheFixedShape() public {
        if (!live) return vm.skip(true);
        LaunchTokenFactory.LaunchInput memory p = _input();
        Launch memory L = _launch(p);
        MigratorParameters memory m = ILBPStrategy(STRATEGY).initializers(L.auction);
        assertEq(abi.encode(m.token, m.currency), abi.encode(L.token, USDC), "token and currency");
        assertEq(m.migrationBlock, p.endBlock + 1, "migration the block after the end");
        assertEq(m.reservedTokenAmountForLP, SUPPLY, "the reserve is the auction supply");
        assertEq(abi.encode(m.recipient, m.positionRecipient), abi.encode(L.budget, L.budget), "the leftovers and the LP go to the budget");
        assertEq(abi.encode(m.poolParameters.fee, m.poolParameters.tickSpacing, m.poolParameters.hook), abi.encode(FEE, SPACING, hook), "the pool");
        assertEq(abi.decode(m.positionDefinitions, (PositionDefinition[])).length, 0, "the full-range fallback alone");
        LiquidityAllocationBracket[] memory b = abi.decode(m.lpAllocationSchedule, (LiquidityAllocationBracket[]));
        assertEq(abi.encode(b.length, b[0].lowerThreshold, b[0].rate), abi.encode(1, 0, 8e6), "four fifths of the raise to the pool");

        IContinuousClearingAuction a = IContinuousClearingAuction(L.auction);
        assertEq(abi.encode(a.token(), a.currency(), a.totalSupply()), abi.encode(L.token, USDC, SUPPLY), "the auction's sale");
        assertEq(a.tokensRecipient(), address(L.budget), "unsold tokens are the budget's alone to sweep");
        assertEq(a.fundsRecipient(), STRATEGY, "the raise goes to the strategy");
        assertEq(a.validationHook(), address(L.lock), "the lock is the bid gate");
        assertEq(abi.encode(a.endBlock(), a.claimBlock()), abi.encode(p.endBlock, p.endBlock), "the end and the claim");

        IERC20 t = IERC20(L.token);
        uint256 sum = t.balanceOf(L.auction) + t.balanceOf(STRATEGY) + t.balanceOf(L.lock.predict(team, TEAM_LINEAR)) + t.balanceOf(address(L.budget));
        assertEq(sum, t.totalSupply(), "a unit of the supply is unaccounted for");
        assertEq(t.balanceOf(L.auction), SUPPLY, "the auction holds its supply");
        assertEq(t.balanceOf(address(factory)), 0, "the factory kept some");
    }

    // ---- the hook, through the deployed strategy ----

    /// @notice The hook the factory deployed carries the before-initialize and before-swap bits alone, admits the strategy, and names the factory.
    function test_Fork_TheHookCarriesInitializeAndSwapAlone() public {
        if (!live) return vm.skip(true);
        assertEq(uint160(address(hook)) & Hooks.ALL_HOOK_MASK, Hooks.BEFORE_INITIALIZE_FLAG | Hooks.BEFORE_SWAP_FLAG, "the address carries other bits");
        assertEq(hook.authorized(), STRATEGY, "the hook admits another initializer");
        assertEq(address(hook.FACTORY()), address(factory), "the hook names another factory");
        assertEq(address(hook.poolManager()), address(pm), "the hook is on another PoolManager");
    }

    /// @notice The migration opens exactly the recorded pool, behind the hook, at the clearing price, with liquidity, every position the budget's.
    function test_Fork_TheMigrationOpensExactlyTheRecordedPool() public {
        if (!live) return vm.skip(true);
        (Launch memory L,, uint256 id) = _liveLaunch();
        (PoolKey memory k,) = IPositionsView(posm).getPoolAndPositionInfo(id);
        assertEq(keccak256(abi.encode(k)), keccak256(abi.encode(L.key)), "the LP is not in the recorded pool");
        assertEq(factory.launchByOf(k.toId()), _launchBy(L), "the LP's pool is not recorded");
        uint256 cp = IContinuousClearingAuction(L.auction).clearingPrice();
        assertApproxEqRel(_sqrtP(k), _sqrtAt(L.token, cp), 1e12, "the pool does not start at the clearing price");
        assertGt(pm.getLiquidity(k.toId()), 0, "the recorded pool holds no liquidity");
    }

    /// @notice A stranger cannot open the recorded pool before the migration: the stock sender check refuses it.
    function test_Fork_AStrangerCannotOpenTheRecordedPool() public {
        if (!live) return vm.skip(true);
        Launch memory L = _launch();
        bytes memory reason = abi.encodeWithSelector(InitializerHook.InvalidInitializer.selector, stranger, STRATEGY);
        vm.prank(stranger);
        vm.expectRevert(
            abi.encodeWithSelector(
                CustomRevert.WrappedError.selector, address(hook), IHooks.beforeInitialize.selector, reason, abi.encodePacked(Hooks.HookCallFailed.selector)
            )
        );
        pm.initialize(L.key, uint160(1 << 96));
    }

    /// @notice A squat of the hookless key of the token's predicted address changes nothing: the launch migrates into its own recorded pool.
    function test_Fork_ASquatOfTheHooklessKeyCannotBlockTheLaunch() public {
        if (!live) return vm.skip(true);
        address predicted = vm.computeCreateAddress(address(factory), vm.getNonce(address(factory)));
        PoolKey memory squat = _key(predicted, address(0));
        vm.prank(stranger);
        pm.initialize(squat, uint160(1 << 96));
        (Launch memory L,, uint256 id) = _liveLaunch();
        assertEq(L.token, predicted, "fixture: the token landed off its predicted address");
        (PoolKey memory k,) = IPositionsView(posm).getPoolAndPositionInfo(id);
        assertEq(address(k.hooks), address(hook), "the LP went to another pool");
        assertEq(pm.getLiquidity(squat.toId()), 0, "the squatter's pool holds liquidity");
    }

    /// @notice A distribution NOT made by the factory, naming the Runway hook, never gets a pool behind it.
    /// @notice Its migration's initialize is refused, so the strategy falls into its own recovery branch: its recipient gets the raise and the reserve.
    function test_Fork_ADistributionOutsideTheFactoryGetsNoPool() public {
        if (!live) return vm.skip(true);
        MockERC20 t = new MockERC20("Outside", "OUT", 18);
        address recipient = address(0xFEE);
        uint64 b = uint64(vm.getBlockNumber());
        AuctionParameters memory p = AuctionParameters({
            currency: USDC,
            tokensRecipient: DEAD,
            fundsRecipient: address(1),
            startBlock: b + 2,
            endBlock: b + 102,
            claimBlock: b + 102,
            tickSpacing: TICK,
            validationHook: address(0),
            floorPrice: FLOOR,
            requiredCurrencyRaised: 0,
            auctionStepsData: abi.encodePacked(uint24(100_000), uint40(100))
        });
        LiquidityAllocationBracket[] memory br = new LiquidityAllocationBracket[](1);
        br[0] = LiquidityAllocationBracket({lowerThreshold: 0, rate: 1e7});
        MigratorParameters memory m = MigratorParameters({
            token: address(t),
            currency: USDC,
            migrationBlock: b + 103,
            reservedTokenAmountForLP: SUPPLY,
            recipient: recipient,
            positionRecipient: recipient,
            poolParameters: PoolParameters({fee: FEE, tickSpacing: SPACING, hook: address(hook)}),
            positionDefinitions: abi.encode(new PositionDefinition[](0)),
            lpAllocationSchedule: abi.encode(br)
        });
        t.mint(address(this), 2 * uint256(SUPPLY));
        t.approve(STRATEGY, 2 * uint256(SUPPLY));
        vm.recordLogs();
        ILBPStrategyLaunch(STRATEGY).initializeDistribution(address(t), 2 * uint256(SUPPLY), abi.encode(m, abi.encode(p)), bytes32(0));
        address a = _logged();

        _fundBidder(bidder, a, BID);
        vm.roll(b + 2);
        vm.prank(bidder);
        ICcaBidding(a).submitBid(P_MID, BID, bidder, "");
        vm.roll(b + 103);
        uint256 next = IPositionsView(posm).nextTokenId();
        ILBPStrategyLaunch(STRATEGY).migrate(a);
        assertEq(IPositionsView(posm).nextTokenId(), next, "the outside distribution minted a position");
        assertEq(_sqrtP(_key(address(t), address(hook))), 0, "a pool opened behind the Runway hook for a token the factory never launched");
        assertEq(t.balanceOf(recipient), SUPPLY, "the recovery did not return the whole reserve");
        assertGt(IERC20(USDC).balanceOf(recipient), 0, "the recovery did not return the raise");
    }

    // ---- the time gate: past launchBy, nothing opens the launch's key ----

    address internal squatter = address(0x5017);

    /// @dev A holder of `amount` of the launch token runs its OWN strategy distribution naming the launch's exact key, bids into it,
    /// @dev and migrates it, with itself as recipient and LP owner: the attack a key-only gate admitted.
    function _secondDistribution(Launch memory L, uint256 amount) internal {
        uint64 b = uint64(vm.getBlockNumber());
        LiquidityAllocationBracket[] memory br = new LiquidityAllocationBracket[](1);
        br[0] = LiquidityAllocationBracket({lowerThreshold: 0, rate: 1e7});
        MigratorParameters memory m = MigratorParameters({
            token: L.token,
            currency: USDC,
            migrationBlock: b + 103,
            reservedTokenAmountForLP: uint128(amount / 2),
            recipient: squatter,
            positionRecipient: squatter,
            poolParameters: PoolParameters({fee: FEE, tickSpacing: SPACING, hook: address(hook)}),
            positionDefinitions: abi.encode(new PositionDefinition[](0)),
            lpAllocationSchedule: abi.encode(br)
        });
        AuctionParameters memory p = AuctionParameters({
            currency: USDC,
            tokensRecipient: squatter,
            fundsRecipient: address(1),
            startBlock: b + 2,
            endBlock: b + 102,
            claimBlock: b + 102,
            tickSpacing: TICK,
            validationHook: address(0),
            floorPrice: FLOOR,
            requiredCurrencyRaised: 0,
            auctionStepsData: abi.encodePacked(uint24(100_000), uint40(100))
        });
        deal(L.token, squatter, amount);
        vm.recordLogs();
        vm.startPrank(squatter);
        IERC20(L.token).approve(STRATEGY, amount);
        ILBPStrategyLaunch(STRATEGY).initializeDistribution(L.token, amount, abi.encode(m, abi.encode(p)), keccak256("squat"));
        vm.stopPrank();
        address a = _logged();
        _fundBidder(squatter, a, BID);
        vm.roll(b + 2);
        vm.prank(squatter);
        ICcaBidding(a).submitBid(P_MID, BID, squatter, "");
        vm.roll(b + 103);
        ILBPStrategyLaunch(STRATEGY).migrate(a);
    }

    /// @notice After an ungraduated launch, a holder of a few tokens cannot open the launch's key through a distribution of their own.
    function test_Fork_AnUngraduatedLaunchKeepsItsKeyClosed() public {
        if (!live) return vm.skip(true);
        LaunchTokenFactory.LaunchInput memory p = _input();
        p.requiredRaise = type(uint128).max / 2;
        Launch memory L = _launch(p);
        _bidAt(L, buyerA, L.start, P_MID, BID);
        vm.roll(L.end + 1);
        ILBPStrategyLaunch(STRATEGY).migrate(L.auction);
        _pastLaunchBy(L); // no launch token is liquid before launchBy
        _secondDistribution(L, 2e18);
        assertEq(_sqrtP(L.key), 0, "the launch's key opened for a distribution that is not the launch's");
        L.budget.settle();
        assertFalse(L.budget.live(), "an ungraduated launch read live");
    }

    /// @notice A migration that runs after launchBy is refused by the hook and recovers: no pool, the whole raise and reserve to the budget,
    /// @notice settlement reads failed, and the bids are refunded whole.
    function test_Fork_ALateMigrationRecoversAndRefundsWhole() public {
        if (!live) return vm.skip(true);
        Launch memory L = _launch();
        Bids memory x = _threeBids(L);
        vm.roll(L.end + 1);
        _pastLaunchBy(L);
        uint256 next = IPositionsView(posm).nextTokenId();
        ILBPStrategyLaunch(STRATEGY).migrate(L.auction);
        assertEq(IPositionsView(posm).nextTokenId(), next, "a late migration minted a position");
        assertEq(_sqrtP(L.key), 0, "a late migration opened the launch's key");
        assertEq(_sqrtP(_key(L.token, STRATEGY)), 0, "a late migration opened the strategy's fallback pool");
        uint256 received = IERC20(USDC).balanceOf(address(L.budget));
        assertEq(received, _raisedQ96(L.auction) >> 96, "the budget did not get the whole raise");
        assertEq(IERC20(L.token).balanceOf(address(L.budget)), OPS + SUPPLY, "the budget did not get the whole reserve");
        L.budget.settle();
        assertFalse(L.budget.live(), "a late migration read live");
        uint256 raised = _raisedQ96(L.auction);
        uint256 paid = _refundAndCheck(L, x.c, 0, 0, received, raised);
        paid += _refundAndCheck(L, x.a, x.hint, 0, received, raised);
        paid += _refundAndCheck(L, x.b, x.hint, x.end, received, raised);
        assertApproxEqAbs(paid, received, 3, "the raise did not go back to buyers whole");
    }

    /// @notice The flip: after a failed migration, a second distribution cannot open the launch's key, so settlement still reads failed.
    function test_Fork_TheFlipAfterAFailedMigrationIsRefused() public {
        if (!live) return vm.skip(true);
        (Launch memory L,) = _failedLaunch();
        uint256 received = IERC20(USDC).balanceOf(address(L.budget));
        _pastLaunchBy(L); // no launch token is liquid before launchBy
        _secondDistribution(L, 2e18);
        assertEq(_sqrtP(L.key), 0, "the launch's key opened after its own migration failed");
        L.budget.settle();
        assertFalse(L.budget.live(), "a failed launch read live after the flip");
        assertEq(IERC20(USDC).balanceOf(address(_wallet(L))), 0, "the team took currency from a failure");
        assertEq(L.budget.refundPool(), received, "the bids do not share the whole raise");
    }

    // ---- settlement ----

    /// @notice Nothing settles before launchBy; past it, nothing settles before the end checkpoint or the migration,
    /// @notice even with a currency donation sitting in the budget.
    function test_Fork_SettleIsPendingUntilTheMigration() public {
        if (!live) return vm.skip(true);
        Launch memory L = _launch();
        Bids memory x = _threeBids(L);
        vm.expectRevert(LaunchOpsBudget.TooEarly.selector);
        L.budget.settle();
        _pastLaunchBy(L);
        vm.expectRevert(LaunchOpsBudget.NotFinal.selector);
        L.budget.settle();
        vm.roll(x.end);
        ICcaBidding(L.auction).exitBid(x.c);
        deal(USDC, address(L.budget), 1_000_000e6);
        vm.expectRevert(LaunchOpsBudget.Pending.selector);
        L.budget.settle();
    }

    /// @notice A live launch: the wallet holds the team's capped share and the ops, the reserve's leftover burns, and half vests in half a year.
    function test_Fork_ALiveLaunchSettlesTheTeamsShare() public {
        if (!live) return vm.skip(true);
        (Launch memory L,,) = _liveLaunch();
        uint256 bal = IERC20(USDC).balanceOf(address(L.budget));
        uint256 held = IERC20(L.token).balanceOf(address(L.budget));
        uint256 supply = IERC20(L.token).totalSupply();
        uint256 cap = Math.mulDiv(_raisedQ96(L.auction), SHARE, 10_000 << 96);
        assertApproxEqAbs(bal, cap, 1, "fixture: the strategy sent the budget the share the bracket left");
        _pastLaunchBy(L);
        vm.prank(stranger);
        L.budget.settle();
        VestingWallet w = _wallet(L);
        uint256 share = Math.min(bal, cap);
        assertTrue(L.budget.live(), "a live launch read failed");
        assertEq(IERC20(USDC).balanceOf(address(w)), share, "the wallet does not hold the capped share");
        assertEq(L.budget.refundPool(), bal - share, "the bids' pool is the excess over the cap");
        assertLe(L.budget.refundPool(), 1, "more than rounding dust was left for the bids");
        assertEq(IERC20(L.token).totalSupply(), supply - (held - OPS), "the reserve's leftover did not burn");
        assertEq(IERC20(L.token).balanceOf(address(w)), OPS, "the wallet does not hold exactly the ops tokens");

        _warpTo(_launchBy(L) + 365 days / 2);
        w.release(USDC);
        w.release(L.token);
        assertEq(IERC20(USDC).balanceOf(operator), share / 2, "half the currency share after half a year");
        assertEq(IERC20(L.token).balanceOf(operator), OPS / 2, "half the ops tokens after half a year");
    }

    /// @notice A forced failure: every refund is its bid's spent share, the team takes no currency, and the returned reserve burns.
    function test_Fork_AForcedFailureRefundsEveryBidAndBurnsTheReserve() public {
        if (!live) return vm.skip(true);
        (Launch memory L, Bids memory x) = _failedLaunch();
        assertEq(_sqrtP(L.key), 0, "fixture: a failed migration left the pool open");
        uint256 received = IERC20(USDC).balanceOf(address(L.budget));
        assertGt(received, 0, "fixture: the recovery paid the raise to the budget");
        assertEq(IERC20(L.token).balanceOf(address(L.budget)), OPS + SUPPLY, "fixture: the recovery returned the whole reserve");
        uint256 supply = IERC20(L.token).totalSupply();
        _pastLaunchBy(L);
        L.budget.settle();
        assertFalse(L.budget.live(), "a failure read live");
        assertEq(IERC20(USDC).balanceOf(address(_wallet(L))), 0, "the team got currency from a failure");
        assertEq(L.budget.refundPool(), received, "the bids do not share the whole raise");
        assertEq(IERC20(L.token).totalSupply(), supply - SUPPLY, "the reserve did not burn");

        uint256 raised = _raisedQ96(L.auction);
        uint256 paid = _refundAndCheck(L, x.c, 0, 0, received, raised);
        paid += _refundAndCheck(L, x.a, x.hint, 0, received, raised);
        paid += _refundAndCheck(L, x.b, x.hint, x.end, received, raised);
        assertLe(paid, received, "refunds paid out more than the budget received");
        assertApproxEqAbs(paid, received, 3, "the raise went back to buyers, but for rounding dust");
        assertEq(IERC20(USDC).balanceOf(operator) + IERC20(USDC).balanceOf(team), 0, "currency reached the team");
    }

    function _refundAndCheck(Launch memory L, uint256 id, uint64 h1, uint64 h2, uint256 received, uint256 raised) internal returns (uint256 got) {
        uint256 expect = Math.mulDiv(received, L.budget.spentOf(id, h1, h2), raised);
        address owner = IContinuousClearingAuction(L.auction).bids(id).owner;
        uint256 pre = IERC20(USDC).balanceOf(owner);
        vm.prank(stranger);
        got = L.budget.refund(id, h1, h2);
        assertLe(got, expect, "a refund paid more than its bid's spent share");
        assertApproxEqAbs(got, expect, 2, "a refund is not its bid's spent share, past the last payer's rounding clamp");
        assertEq(IERC20(USDC).balanceOf(owner) - pre, got, "the refund did not reach the bid's owner");
    }

    /// @notice An auction that never graduated refunded its bids itself: settlement reads failure and the bids are owed nothing.
    /// @notice Both halves of the strategy's amount burn: the returned reserve, and the whole auction supply, swept into the budget.
    function test_Fork_AnUngraduatedAuctionOwesNothing() public {
        if (!live) return vm.skip(true);
        LaunchTokenFactory.LaunchInput memory p = _input();
        p.requiredRaise = type(uint128).max / 2;
        Launch memory L = _launch(p);
        uint256 id = _bidAt(L, buyerA, L.start, P_MID, BID);
        vm.roll(L.end + 1);
        ILBPStrategyLaunch(STRATEGY).migrate(L.auction);
        uint256 supply = IERC20(L.token).totalSupply();
        _pastLaunchBy(L);
        L.budget.settle();
        assertFalse(L.budget.live(), "an ungraduated launch read live");
        assertEq(L.budget.refund(id, 0, 0), 0, "an ungraduated bid was paid");
        assertEq(_refundOf(L, buyerA, abi.encodeCall(ICcaBidding.exitBid, (id))), BID, "the auction refunded the whole bid itself");
        assertEq(IERC20(L.token).totalSupply(), supply - 2 * uint256(SUPPLY), "the reserve and the unsold supply did not both burn");
        assertEq(IERC20(L.token).balanceOf(L.auction), 0, "the auction kept unsold tokens");
    }

    /// @notice The budget's `spentOf` is what the deployed auction itself kept at exit, for a full fill, a partial fill and an outbid bid.
    function test_Fork_SpentMatchesTheAuctionsOwnExit() public {
        if (!live) return vm.skip(true);
        Launch memory L = _launch();
        Bids memory x = _threeBids(L);
        (uint256 rc, uint256 ra, uint256 rb) = _exitAll(L, x);
        assertEq(IContinuousClearingAuction(L.auction).clearingPrice(), P_MID, "fixture: A's tick is the final clearing price");
        assertGt(ra, 0, "fixture: A was only partly filled");
        assertGt(rb, 0, "fixture: B was outbid before it filled");
        _assertSpent(L, x.c, 0, 0, BID_C, rc, "fully filled");
        _assertSpent(L, x.a, x.hint, 0, BID_A, ra, "partially filled at the clearing price");
        _assertSpent(L, x.b, x.hint, x.end, BID_B, rb, "outbid");
    }

    /// @dev The budget's spent, in whole currency units rounded up, against what the auction kept at exit.
    function _assertSpent(Launch memory L, uint256 id, uint64 h1, uint64 h2, uint256 amount, uint256 exitRefund, string memory what) internal view {
        uint256 q = L.budget.spentOf(id, h1, h2);
        assertApproxEqAbs((q + (1 << 96) - 1) >> 96, amount - exitRefund, 1, what);
    }

    /// @notice Claiming, exiting or neither changes nothing: what a bid spent persists, so its refund is the same in every order.
    function test_Fork_RefundIgnoresClaimTiming() public {
        if (!live) return vm.skip(true);
        (Launch memory L, Bids memory x) = _failedLaunch();
        _pastLaunchBy(L);
        L.budget.settle();
        uint256 received = L.budget.refundPool();
        uint256 raised = _raisedQ96(L.auction);
        uint256 spentB = L.budget.spentOf(x.b, x.hint, x.end);
        uint256 spentC = L.budget.spentOf(x.c, 0, 0);

        _refundAndCheck(L, x.a, x.hint, 0, received, raised); // A: never exited, never claimed
        vm.prank(stranger);
        ICcaBidding(L.auction).exitPartiallyFilledBid(x.b, x.hint, x.end);
        vm.prank(stranger);
        ICcaBidding(L.auction).claimTokens(x.b);
        assertEq(L.budget.spentOf(x.b, x.hint, x.end), spentB, "B's spent moved when it exited and claimed");
        _refundAndCheck(L, x.b, x.hint, x.end, received, raised); // B: after its claim
        vm.prank(stranger);
        ICcaBidding(L.auction).exitBid(x.c);
        assertEq(L.budget.spentOf(x.c, 0, 0), spentC, "C's spent moved when it exited");
        _refundAndCheck(L, x.c, 0, 0, received, raised); // C: exited, never claimed
    }

    /// @notice A hint the auction would refuse is refused by the budget too; nothing is final before the end checkpoint, nor paid before settlement.
    function test_Fork_BadHintsAndNotFinalRevert() public {
        if (!live) return vm.skip(true);
        Launch memory L = _launch();
        Bids memory x = _threeBids(L);
        vm.expectRevert(LaunchOpsBudget.NotFinal.selector);
        L.budget.spentOf(x.a, x.hint, 0); // mid-auction
        vm.expectRevert(LaunchOpsBudget.NotSettled.selector);
        L.budget.refund(x.a, x.hint, 0);
        vm.roll(x.end);
        ICcaBidding(L.auction).exitBid(x.c); // the final checkpoint
        vm.expectRevert(LaunchOpsBudget.BadHint.selector);
        L.budget.spentOf(x.a, L.start + 10, 0); // before A existed
        vm.expectRevert(LaunchOpsBudget.BadHint.selector);
        L.budget.spentOf(x.a, x.end, 0); // already clearing at A's price
        vm.expectRevert(LaunchOpsBudget.BadHint.selector);
        L.budget.spentOf(x.b, x.hint, x.hint); // an outbid hint that never cleared above B's price
        vm.expectRevert(LaunchOpsBudget.BadHint.selector);
        L.budget.spentOf(x.b, x.hint, 0); // B was outbid, so the final price is not B's
    }

    /// @notice A buyer borrowing against claimed tokens is refunded too: into the account, swept to the beneficiary; the pledge books never move.
    function test_Fork_RefundToABuyerWithALiveLoan() public {
        if (!live) return vm.skip(true);
        Launch memory L = _launch();
        uint256 id = _bidAt(L, buyerA, L.start, P_MID, BID);
        vm.roll(L.end);
        ICcaBidding(L.auction).exitBid(id);
        ICcaBidding(L.auction).claimTokens(id);
        LockAccount acct = LockAccount(L.lock.account(buyerA, 0));
        bytes32 m = _launchMarket(L.token);
        vm.prank(buyerA);
        uint256 loanId = acct.borrow(m, 2_000e18, 10e6, 7 days, OpenBounds(0, 0, 0));
        assertEq(ace.borrowerOf(loanId), address(acct), "fixture: the buyer's account holds a live loan");

        vm.roll(L.end + 1);
        _failedMigrate(L.auction);
        _pastLaunchBy(L);
        L.budget.settle();
        (uint256 pledged, uint256 spent, uint256 capNow) = (acct.pledged(), acct.spent(), acct.capacity(uint64(_now() + 7 days)));
        uint256 got = L.budget.refund(id, 0, 0);
        assertGt(got, 0, "the failure refunded the buyer");
        assertEq(IERC20(USDC).balanceOf(address(acct)), got, "into the buyer's account");
        assertEq(abi.encode(acct.pledged(), acct.spent(), acct.capacity(uint64(_now() + 7 days))), abi.encode(pledged, spent, capNow), "the books moved");
        uint256 pre = IERC20(USDC).balanceOf(buyerA);
        acct.sweep(USDC);
        assertEq(IERC20(USDC).balanceOf(buyerA) - pre, got, "the sweep paid the beneficiary the refund");
    }

    function _launchMarket(address t) internal returns (bytes32 id) {
        address lender = address(0x1E4D);
        id = ace.createMarket(
            LaunchMarketParams.launchParams(
                LaunchMarketParams.Ctx({
                    quote: USDC, token: t, lender: lender, price: AceFixtures.px(0.01e18, USDC, t), baseBps: 40, minDebt: 10e6, minCoverageWad: 1.4e18
                })
            )
        );
        deal(USDC, lender, 100_000e6);
        vm.startPrank(lender);
        IERC20(USDC).approve(address(ace), 100_000e6);
        ace.deposit(id, 100_000e6);
        vm.stopPrank();
    }

    // ---- the LP's fees ----

    /// @notice Every burn is real: at a zero cut, after a one-price partial sale and settlement, the supply is sold * (2 - share) + team + ops.
    /// @notice Its terms are what was sold, the pool's side of the reserve and the allocations; the unsold tokens are swept into the budget and burn.
    /// @notice Before settlement nobody else can sweep them, so they never sit in the budget when settlement reads it.
    function test_Fork_TheSupplyIsTrueAfterSettlement() public {
        if (!live) return vm.skip(true);
        Launch memory L = _launch();
        uint256 id = _bid(L, L.lock.predict(bidder, 0), abi.encode(bidder)); // one small bid: the auction clears at the floor in every block
        vm.roll(L.end + 1);
        _migrateAndMint(L);
        assertEq(IContinuousClearingAuction(L.auction).clearingPrice(), FLOOR, "fixture: the sale was not at one price");
        ICcaBidding(L.auction).exitBid(id);
        uint256 sold = IContinuousClearingAuction(L.auction).bids(id).tokensFilled;

        vm.prank(stranger);
        vm.expectRevert(abi.encodeWithSignature("NotAuthorized(address,address)", address(L.budget), stranger));
        ICcaBidding(L.auction).sweepUnsoldTokens();
        assertEq(IERC20(L.token).balanceOf(L.auction), SUPPLY, "the unsold tokens left the auction before settlement");

        _pastLaunchBy(L);
        L.budget.settle();
        uint256 want = Math.mulDiv(sold, 20_000 - SHARE, 10_000) + TEAM_ALLOC + OPS;
        assertApproxEqRel(IERC20(L.token).totalSupply(), want, 1e12, "the supply is not sold * (2 - share) plus the allocations");
        assertApproxEqAbs(IERC20(L.token).balanceOf(L.auction), sold, 1, "the auction holds other than what it sold");
        assertEq(IERC20(L.token).balanceOf(DEAD), 0, "DEAD holds tokens a burn should have destroyed");
        assertEq(IERC20(L.token).balanceOf(address(L.budget)), 0, "the budget kept unsold tokens");
    }

    /// @notice Swaps through Uniswap's router pay the LP, and collectFees takes its fees without moving its liquidity.
    /// @notice The USDC lands at the operator at once; the token side burns; a second collection with no swap between takes nothing.
    function test_Fork_CollectFeesKeepsLiquidity() public {
        if (!live) return vm.skip(true);
        (Launch memory L,, uint256 id) = _liveLaunch();
        _pastLaunchBy(L);
        L.budget.settle();
        _swapIn(L.key, USDC, 50e6);
        _warpBy(12);
        _swapIn(L.key, L.token, 2_000e18);
        (uint128 liq, uint128 poolLiq) = (IPositionsView(posm).getPositionLiquidity(id), pm.getLiquidity(L.key.toId()));
        (uint256 supply, uint256 q0, uint256 b0) = (IERC20(L.token).totalSupply(), IERC20(USDC).balanceOf(operator), IERC20(USDC).balanceOf(address(L.budget)));
        vm.prank(stranger);
        L.budget.collectFees(id);
        uint256 quoteOut = IERC20(USDC).balanceOf(operator) - q0;
        uint256 burned = supply - IERC20(L.token).totalSupply();
        assertGt(quoteOut, 0, "no USDC fee reached the operator");
        assertGt(burned, 0, "no token fee was burned");
        assertEq(IERC20(USDC).balanceOf(address(L.budget)), b0, "the fees reached the budget");
        assertEq(IERC20(L.token).balanceOf(DEAD), 0, "DEAD holds the fee tokens");
        assertEq(IERC20(L.token).balanceOf(address(L.budget)), 0, "the budget kept fee tokens");
        assertEq(IPositionsView(posm).getPositionLiquidity(id), liq, "collecting moved the position's liquidity");
        assertEq(pm.getLiquidity(L.key.toId()), poolLiq, "collecting moved the pool's liquidity");
        (supply, q0) = (IERC20(L.token).totalSupply(), IERC20(USDC).balanceOf(operator));
        L.budget.collectFees(id);
        assertEq(IERC20(USDC).balanceOf(operator) - q0 + (supply - IERC20(L.token).totalSupply()), 0, "a second collection took fees no swap earned");
    }

    /// @notice On a live launch the LP's USDC fees go to the operator, not to the budget, the wallet or the bids' pool.
    function test_Fork_FeesGoToTheOperator() public {
        if (!live) return vm.skip(true);
        (Launch memory L,, uint256 id) = _liveLaunch();
        _pastLaunchBy(L);
        L.budget.settle();
        _swapIn(L.key, USDC, 50e6);
        (uint256 op0, uint256 w0, uint256 b0) =
            (IERC20(USDC).balanceOf(operator), IERC20(USDC).balanceOf(address(_wallet(L))), IERC20(USDC).balanceOf(address(L.budget)));
        vm.prank(stranger);
        L.budget.collectFees(id);
        assertGt(IERC20(USDC).balanceOf(operator), op0, "the operator got no fees");
        assertEq(IERC20(USDC).balanceOf(address(_wallet(L))), w0, "the fees reached the wallet");
        assertEq(IERC20(USDC).balanceOf(address(L.budget)), b0, "the fees reached the budget");
        assertEq(IERC20(USDC).balanceOf(address(L.budget)), L.budget.refundPool(), "the budget holds more or less than the bids' pool");
    }

    /// @notice A position outside the launch pool is refused: here one that already existed on mainnet before the launch.
    function test_Fork_CollectFeesRefusesAForeignPosition() public {
        if (!live) return vm.skip(true);
        uint256 foreign = IPositionsView(posm).nextTokenId() - 1;
        (Launch memory L,,) = _liveLaunch();
        _pastLaunchBy(L);
        L.budget.settle();
        vm.expectRevert(LaunchOpsBudget.NotOurPosition.selector);
        L.budget.collectFees(foreign);
    }

    /// @dev An exact-input swap of `amount` of `tokenIn` through Uniswap's test router, funded by `deal`.
    function _swapIn(PoolKey memory k, address tokenIn, uint256 amount) internal {
        PoolSwapTest router = new PoolSwapTest(pm);
        deal(tokenIn, address(this), amount);
        IERC20(tokenIn).approve(address(router), amount);
        bool zeroForOne = Currency.unwrap(k.currency0) == tokenIn;
        uint160 limit = zeroForOne ? TickMath.MIN_SQRT_PRICE + 1 : TickMath.MAX_SQRT_PRICE - 1;
        router.swap(k, SwapParams(zeroForOne, -int256(amount), limit), PoolSwapTest.TestSettings(false, false), "");
    }

    // ---- the full launch: team legs and ops ----

    uint256 internal constant SECOND_AMT = 120_000e18;
    address internal holder = address(0xD0A1);

    /// @notice A full launch with two legs and ops registers, every unit is accounted for, each leg lands locked, and it migrates and settles.
    function test_Fork_AFullLaunchWithLegsAndOps() public {
        if (!live) return vm.skip(true);
        LaunchTokenFactory.LaunchInput memory p = _input();
        Leg[] memory legs = new Leg[](2);
        legs[0] = p.legs[0];
        legs[1] = Leg({beneficiary: holder, amount: SECOND_AMT, cliff: 90 days, duration: 180 days});
        p.legs = legs;
        Launch memory L = _launch(p);
        IERC20 t = IERC20(L.token);
        (address a1, address a2) = (L.lock.predict(team, 1), L.lock.predict(holder, 2));
        uint256 sum = t.balanceOf(L.auction) + t.balanceOf(STRATEGY) + t.balanceOf(a1) + t.balanceOf(a2) + t.balanceOf(address(L.budget));
        assertEq(sum, t.totalSupply(), "a unit of the supply is unaccounted for");
        assertEq(t.balanceOf(a2), SECOND_AMT, "the second leg is not in its own account");
        assertEq(LockAccount(a2).releasable(), 0, "a leg releases before launchBy");

        _threeBids(L);
        vm.roll(L.end + 1);
        _migrateAndMint(L);
        _pastLaunchBy(L);
        assertEq(LockAccount(a2).releasable(), 0, "the second leg releases inside its cliff");
        L.budget.settle();
        assertTrue(L.budget.live(), "the full launch did not go live");
        assertEq(t.balanceOf(address(_wallet(L))), OPS, "the wallet does not hold exactly the ops tokens");
        assertEq(t.balanceOf(address(L.budget)), 0, "the budget kept launch tokens");
    }

    /// @notice The wallet vests the team's capped share to the operator from launchBy: nothing at launchBy, half at mid-year, all at a year.
    function test_Fork_TheWalletVestsTheTeamShare() public {
        if (!live) return vm.skip(true);
        (Launch memory L,,) = _liveLaunch();
        _pastLaunchBy(L);
        L.budget.settle();
        VestingWallet w = _wallet(L);
        uint256 share = IERC20(USDC).balanceOf(address(w));
        assertGt(share, 0, "fixture: the live launch gave the team a share");
        assertEq(abi.encode(w.owner(), w.start(), w.duration()), abi.encode(operator, _launchBy(L), 365 days), "the wallet's terms");
        assertEq(w.vestedAmount(USDC, uint64(_launchBy(L))), 0, "the share vested at launchBy");
        assertEq(w.vestedAmount(USDC, uint64(_launchBy(L) + 365 days / 2)), share / 2, "half the share at mid-year");
        _warpTo(_launchBy(L) + 365 days);
        w.release(USDC);
        assertEq(IERC20(USDC).balanceOf(operator), share, "the whole share at a year");
    }

    /// @notice On a failed launch the wallet holds the ops tokens alone, vesting from launchBy, and no currency.
    function test_Fork_AFailedLaunchStreamsTheOpsFromLaunchBy() public {
        if (!live) return vm.skip(true);
        (Launch memory L,) = _failedLaunch();
        _pastLaunchBy(L);
        L.budget.settle();
        VestingWallet w = _wallet(L);
        assertFalse(L.budget.live(), "fixture: the launch failed");
        assertEq(IERC20(USDC).balanceOf(address(w)), 0, "the wallet got currency from a failure");
        assertEq(IERC20(L.token).balanceOf(address(w)), OPS, "the wallet does not hold the ops tokens");
        assertEq(w.start(), _launchBy(L), "the ops vest from somewhere other than launchBy");
        _warpTo(_launchBy(L) + 365 days / 4);
        w.release(L.token);
        assertEq(IERC20(L.token).balanceOf(operator), OPS / 4, "a quarter of the ops at a quarter year");
    }

    // ---- B5 and L4: the real auction against the lock ----

    /// @notice The auction itself refuses a bid owned by the bidder's own wallet, by the hook's own error.
    function test_Fork_B5_RefusesWrongOwner() public {
        if (!live) return vm.skip(true);
        Launch memory L = _launch();
        _fundBidder(bidder, L.auction, BID);
        vm.roll(L.start);
        vm.prank(bidder);
        vm.expectRevert(_hookFailure(LaunchLock.NotBuyerAccount.selector));
        ICcaBidding(L.auction).submitBid(P_MID, BID, bidder, abi.encode(bidder));
    }

    /// @notice Garbage hook data, and a team account as owner, are refused the same way.
    function test_Fork_B5_RefusesGarbageAndTeam() public {
        if (!live) return vm.skip(true);
        Launch memory L = _launch();
        _fundBidder(bidder, L.auction, 2 * uint256(BID));
        (address buyerAcct, address teamAcct) = (L.lock.predict(bidder, 0), L.lock.predict(bidder, TEAM_LINEAR));
        vm.roll(L.start);
        vm.startPrank(bidder);
        vm.expectRevert(_hookFailure(LaunchLock.BadHookData.selector));
        ICcaBidding(L.auction).submitBid(P_MID, BID, buyerAcct, hex"deadbeef");
        vm.expectRevert(_hookFailure(LaunchLock.NotBuyerAccount.selector));
        ICcaBidding(L.auction).submitBid(P_MID, BID, teamAcct, abi.encode(bidder));
        vm.stopPrank();
    }

    /// @notice A stranger exits and claims the bid; the tokens land in the account and stay locked until the buyer schedule starts at launchBy.
    function test_Fork_B5_StrangerClaimLandsInTheAccountAndStaysLocked() public {
        if (!live) return vm.skip(true);
        Launch memory L = _launch();
        address acct = L.lock.predict(bidder, 0);
        uint256 bidId = _bid(L, acct, abi.encode(bidder));
        vm.roll(L.end);
        vm.prank(stranger);
        ICcaBidding(L.auction).exitBid(bidId);
        vm.prank(stranger);
        ICcaBidding(L.auction).claimTokens(bidId);

        assertGt(IERC20(L.token).balanceOf(acct), 0, "the claim landed nothing");
        assertEq(IERC20(L.token).balanceOf(bidder) + IERC20(L.token).balanceOf(stranger), 0, "the claim reached a wallet");
        assertEq(LockAccount(acct).releasable(), 0, "the buyer schedule has not started");
        vm.prank(bidder);
        vm.expectRevert(LockAccount.OverRelease.selector);
        LockAccount(acct).release(1);
    }

    /// @notice An auction that fails to graduate refunds the whole bid to the DEPLOYED account; the sweep pays the bidder.
    function test_Fork_B5_RefundToADeployedAccountSucceeds() public {
        if (!live) return vm.skip(true);
        LaunchTokenFactory.LaunchInput memory p = _input();
        p.requiredRaise = type(uint128).max / 2;
        Launch memory L = _launch(p);
        address acct = L.lock.predict(bidder, 0);
        uint256 bidId = _bid(L, acct, abi.encode(bidder));
        assertGt(acct.code.length, 0, "fixture: the gate deployed the account");
        vm.roll(L.end);
        vm.prank(stranger);
        ICcaBidding(L.auction).exitBid(bidId);
        assertEq(IERC20(USDC).balanceOf(acct), BID, "the whole bid came back to the account");
        vm.prank(stranger);
        LockAccount(acct).sweep(USDC);
        assertEq(IERC20(USDC).balanceOf(bidder), BID, "and the sweep paid the bidder");
    }

    /// @notice L4 in full: the stranger's early deploy IS the account the bid is owned by, undisturbed, and the claim lands in it.
    function test_Fork_L4_PreDeployedAccountOwnsTheBidAndItsTokens() public {
        if (!live) return vm.skip(true);
        Launch memory L = _launch();
        vm.prank(stranger);
        address acct = L.lock.account(bidder, 0);
        bytes32 code = acct.codehash;
        uint256 bidId = _bid(L, acct, abi.encode(bidder));
        assertEq(IContinuousClearingAuction(L.auction).bids(bidId).owner, acct, "the bid is owned by another address");
        assertEq(acct.codehash, code, "the gate touched the pre-deployed account's code");
        assertEq(LockAccount(acct).beneficiary(), bidder, "the account is not the bidder's");
        vm.roll(L.end);
        ICcaBidding(L.auction).exitBid(bidId);
        ICcaBidding(L.auction).claimTokens(bidId);
        assertGt(IERC20(L.token).balanceOf(acct), 0, "the claim did not land in the pre-deployed account");
    }

    // ---- the protocol's cut, through the deployed strategy ----

    address internal constant SINK = address(0x51CC); // setUp's zero-cut factory names it; a cut row's router sweeps to it
    uint256 internal constant CUT = 100; // 1% of a live launch's raise

    /// @dev Swap the suite's factory for one taking CUT of every live raise for a fresh RevenueRouter, its hook mined as setUp's is.
    function _cutFactory() internal returns (RevenueRouter router) {
        return _cutFactory(CUT);
    }

    function _cutFactory(uint256 cutBps) internal returns (RevenueRouter router) {
        router = new RevenueRouter(address(this), SINK);
        address at = vm.computeCreateAddress(address(this), vm.getNonce(address(this)));
        bytes32 salt = RunwaySalt.mine(at, address(pm), STRATEGY);
        factory = new LaunchTokenFactory(address(ace), STRATEGY, USDC, BLOCK_SECONDS, FEE, SPACING, salt, address(router), cutBps);
        hook = factory.HOOK();
    }

    /// @notice The lowest bracket a launch can register, the share cap plus the cut cap, leaving the pool 47% of the raise.
    /// @notice The deployed strategy registers it, migrates it live, and pays the budget the other 53%.
    function test_Fork_TheLowestBracketMigratesLive() public {
        if (!live) return vm.skip(true);
        _cutFactory(factory.MAX_CUT_BPS());
        LaunchTokenFactory.LaunchInput memory p = _input();
        p.teamShareBps = factory.MAX_TEAM_SHARE_BPS();
        Launch memory L = _launch(p);
        LiquidityAllocationBracket[] memory b = abi.decode(ILBPStrategy(STRATEGY).initializers(L.auction).lpAllocationSchedule, (LiquidityAllocationBracket[]));
        assertEq(b[0].rate, 4_700_000, "fixture: the bracket is not the lowest a launch can register");
        _threeBids(L);
        vm.roll(L.end + 1);
        _migrateAndMint(L);
        assertGt(_sqrtP(L.key), 0, "the lowest bracket did not migrate live");
        uint256 raised = _raisedQ96(L.auction);
        uint256 kept = Math.mulDiv(raised, 5_000 + 300, 10_000 << 96);
        assertApproxEqAbs(IERC20(USDC).balanceOf(address(L.budget)), kept, 1, "the budget did not get the share and the cut");
        _pastLaunchBy(L);
        L.budget.settle();
        assertTrue(L.budget.live(), "the lowest bracket read failed");
        assertApproxEqAbs(L.budget.protocolOwed(), Math.mulDiv(raised, 300, 10_000 << 96), 1, "the cut at the cap");
    }

    /// @notice The deployed strategy pays the budget the share AND the cut, and settlement books the cut beside the team's whole share.
    /// @notice Anyone pays the booked cut to the router, and the router's sweep reaches its sink.
    function test_Fork_ALiveLaunchOwesTheCutAndPaysItOnDemand() public {
        if (!live) return vm.skip(true);
        RevenueRouter router = _cutFactory();
        (Launch memory L,,) = _liveLaunch();
        uint256 bal = IERC20(USDC).balanceOf(address(L.budget));
        uint256 share = Math.mulDiv(_raisedQ96(L.auction), SHARE, 10_000 << 96);
        uint256 cut = Math.mulDiv(_raisedQ96(L.auction), CUT, 10_000 << 96);
        assertApproxEqAbs(bal, share + cut, 1, "the strategy did not send the budget the share and the cut");
        _pastLaunchBy(L);
        vm.prank(stranger);
        L.budget.settle();
        uint256 team = Math.min(bal, share);
        assertEq(IERC20(USDC).balanceOf(address(_wallet(L))), team, "the wallet does not hold the team's whole share");
        assertEq(L.budget.protocolOwed(), Math.min(bal - team, cut), "the booked cut");
        assertLe(L.budget.refundPool(), 1, "more than rounding dust was left for the bids");
        assertEq(IERC20(USDC).balanceOf(address(router)), 0, "settlement pushed the cut");

        uint256 owed = L.budget.protocolOwed();
        vm.prank(stranger);
        assertEq(L.budget.payProtocol(), owed, "the payment is not the booked cut");
        assertEq(IERC20(USDC).balanceOf(address(router)), owed, "the cut did not land at the router");
        address[] memory tokens = new address[](1);
        tokens[0] = USDC;
        router.sweep(tokens);
        assertEq(IERC20(USDC).balanceOf(SINK), owed, "the router's sweep did not reach its sink");
    }

    /// @notice A late migration with a cut still recovers whole: settlement reads failed, nothing is owed, and the bids get the whole raise.
    function test_Fork_ALateMigrationRecoversWholeWithACut() public {
        if (!live) return vm.skip(true);
        _cutFactory();
        Launch memory L = _launch();
        Bids memory x = _threeBids(L);
        vm.roll(L.end + 1);
        _pastLaunchBy(L);
        ILBPStrategyLaunch(STRATEGY).migrate(L.auction);
        assertEq(_sqrtP(L.key), 0, "a late migration opened the launch's key");
        uint256 received = IERC20(USDC).balanceOf(address(L.budget));
        assertEq(received, _raisedQ96(L.auction) >> 96, "the budget did not get the whole raise");
        L.budget.settle();
        assertFalse(L.budget.live(), "a late migration read live");
        assertEq(L.budget.protocolOwed(), 0, "a failure owes a cut");
        uint256 raised = _raisedQ96(L.auction);
        uint256 paid = _refundAndCheck(L, x.c, 0, 0, received, raised);
        paid += _refundAndCheck(L, x.a, x.hint, 0, received, raised);
        paid += _refundAndCheck(L, x.b, x.hint, x.end, received, raised);
        assertApproxEqAbs(paid, received, 3, "the raise did not go back to buyers whole");
    }

    /// @notice Circle blacklists the router: settlement still runs, the team still vests its share, and only `payProtocol` waits.
    /// @notice Once Circle clears the router, the waiting cut pays.
    function test_Fork_ABlacklistedRecipientNeverBlocksSettlement() public {
        if (!live) return vm.skip(true);
        RevenueRouter router = _cutFactory();
        address blacklister = IFiatTokenBlacklist(USDC).blacklister();
        vm.prank(blacklister);
        IFiatTokenBlacklist(USDC).blacklist(address(router));
        (Launch memory L,,) = _liveLaunch();
        uint256 share = Math.mulDiv(_raisedQ96(L.auction), SHARE, 10_000 << 96);
        _pastLaunchBy(L);
        L.budget.settle();
        assertTrue(L.budget.live(), "fixture: the launch read failed");
        uint256 owed = L.budget.protocolOwed();
        assertGt(owed, 0, "fixture: no cut was booked");
        VestingWallet w = _wallet(L);
        assertApproxEqAbs(IERC20(USDC).balanceOf(address(w)), share, 1, "a blacklisted router cost the team its share");
        vm.expectRevert("Blacklistable: account is blacklisted");
        L.budget.payProtocol();
        assertEq(L.budget.protocolOwed(), owed, "a refused payment lost the cut");
        _warpTo(_launchBy(L) + 365 days);
        w.release(USDC);
        assertApproxEqAbs(IERC20(USDC).balanceOf(operator), share, 1, "a blacklisted router blocked the team's vest");

        vm.prank(blacklister);
        IFiatTokenBlacklist(USDC).unBlacklist(address(router));
        assertEq(L.budget.payProtocol(), owed, "the cleared router was not paid");
        assertEq(IERC20(USDC).balanceOf(address(router)), owed, "the cut did not land");
    }

    /// @notice The cut thins the pool's side of the reserve, so more of it burns: the supply is sold * (2 - share - cut) + team + ops.
    function test_Fork_TheSupplyIsTrueWithACut() public {
        if (!live) return vm.skip(true);
        _cutFactory();
        Launch memory L = _launch();
        uint256 id = _bid(L, L.lock.predict(bidder, 0), abi.encode(bidder));
        vm.roll(L.end + 1);
        _migrateAndMint(L);
        ICcaBidding(L.auction).exitBid(id);
        uint256 sold = IContinuousClearingAuction(L.auction).bids(id).tokensFilled;
        _pastLaunchBy(L);
        L.budget.settle();
        uint256 want = Math.mulDiv(sold, 20_000 - SHARE - CUT, 10_000) + TEAM_ALLOC + OPS;
        assertApproxEqRel(IERC20(L.token).totalSupply(), want, 1e12, "the supply is not sold * (2 - share - cut) plus the allocations");
    }
}

/// @notice The two blacklist doors on mainnet USDC (FiatTokenV2_2), callable only by its blacklister.
interface IFiatTokenBlacklist {
    function blacklister() external view returns (address);
    function blacklist(address account) external;
    function unBlacklist(address account) external;
}
