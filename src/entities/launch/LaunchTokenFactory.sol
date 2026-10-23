// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.36;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {Clones} from "@openzeppelin/contracts/proxy/Clones.sol";
import {SafeCast} from "@openzeppelin/contracts/utils/math/SafeCast.sol";
import {ReentrancyGuardTransient} from "@openzeppelin/contracts/utils/ReentrancyGuardTransient.sol";
import {IHooks} from "@uniswap/v4-core/src/interfaces/IHooks.sol";
import {IPoolManager} from "@uniswap/v4-core/src/interfaces/IPoolManager.sol";
import {LPFeeLibrary} from "@uniswap/v4-core/src/libraries/LPFeeLibrary.sol";
import {TickMath} from "@uniswap/v4-core/src/libraries/TickMath.sol";
import {Currency} from "@uniswap/v4-core/src/types/Currency.sol";
import {PoolId, PoolIdLibrary} from "@uniswap/v4-core/src/types/PoolId.sol";
import {PoolKey} from "@uniswap/v4-core/src/types/PoolKey.sol";
import {
    AuctionParameters,
    ICcaFactory,
    ILBPStrategy,
    IV4PositionManager,
    LAUNCH_MPS,
    LiquidityAllocationBracket,
    MigratorParameters,
    PoolParameters,
    PositionDefinition
} from "../../interfaces/ILaunchAuction.sol";
import {LaunchLock, Leg} from "./LaunchLock.sol";
import {LaunchOpsBudget} from "./LaunchOpsBudget.sol";
import {LaunchToken} from "./LaunchToken.sol";
import {RunwayHook} from "./RunwayHook.sol";

/// @title LaunchTokenFactory
/// @notice The ONE way to make a Runway launch: one call births a fixed-supply token, its lock and its ops budget, and registers it.
/// @notice The factory fixes the shape; a team chooses the sale, its share of the raise, its team legs and the ops amount.
/// @notice THE SHAPE: the raise to the pool but the team's share and the cut; leftovers, unsold tokens and the LP to the budget; the lock as bid gate.
/// @notice The protocol's cut is CUT_BPS of a live launch's raise, fixed by this factory for every launch, never a launch input.
/// @notice launchBy is the migration block at MAX_BLOCK_SECONDS a block, plus MIGRATION_WINDOW; every schedule starts there.
/// @notice Each team leg waits at least 30 days past launchBy to unlock and at least 90 to be whole; the buyer schedule vests over 30 days or more.
/// @notice It records each launch's pool with its launchBy: the hook admits that key, from the strategy, only until then.
/// @dev THE ASSUMPTION: blocks until the migration average at most MAX_BLOCK_SECONDS; a migration later than launchBy fails into the strategy's recovery.
/// @dev The strategy is pinned and trusted: it must take exactly its amount and register this auction for this token, or the launch reverts.
/// @dev The auction's address comes from the strategy's auction factory, since the strategy's distribution returns nothing.
/// @dev Redeployable: a new strategy version, or a new hub, is a new factory.
contract LaunchTokenFactory is ReentrancyGuardTransient {
    using PoolIdLibrary for PoolKey;
    using SafeERC20 for IERC20;

    uint256 public constant MIN_TEAM_CLIFF = 30 days; // no team unit unlocks sooner after launchBy
    uint256 public constant MIN_TEAM_VEST = 90 days; // no team leg is whole sooner after launchBy
    uint256 public constant MIN_BUYER_VEST = 30 days; // the buyer schedule vests linearly from launchBy over at least this
    uint256 public constant MAX_OPS_BPS = 1000; // the ops budget is at most a tenth of the supply
    uint256 public constant MAX_TEAM_SHARE_BPS = 5000; // the team takes at most half the raise; the rest, less the cut, is paired into the pool
    uint256 public constant MAX_CUT_BPS = 300; // the protocol's cut of a live launch's raise is at most 3%
    uint256 public constant MIGRATION_WINDOW = 1 days; // launchBy runs this long past the migration block's assumed time
    address internal constant MSG_SENDER = address(1); // the auction factory's placeholder for its caller, here the strategy

    error ZeroBlockSeconds(); // with no block time, launchBy ignores the auction's length, so the key can close before the migration block
    error BadPoolFee(); // above v4's highest static LP fee, the dynamic-fee flag included
    error BadTickSpacing(); // outside v4's tick spacing range
    error ZeroCutRecipient(); // a cut owed to nobody could never be paid
    error CutOverCap(); // a protocol cut above MAX_CUT_BPS
    error ZeroSupply(); // an auction selling nothing
    error BuyerVestTooShort(); // a buyer schedule vesting over less than MIN_BUYER_VEST
    error BadWindow(); // the auction must start after this block and end after it starts, and its blocks must divide its whole
    error ShareOverCap(); // a team share above MAX_TEAM_SHARE_BPS
    error ZeroOperator(); // a budget with no operator has no one to vest to
    error BadLeg(); // a leg of nothing, unlocking within MIN_TEAM_CLIFF of launchBy, or whole within MIN_TEAM_VEST
    error OpsOverCap(); // an ops amount above MAX_OPS_BPS of the supply
    error WrongAuction(); // the strategy did not register this auction for the new token
    error SupplyLeft(); // the factory still holds supply once every allocation is paid: the strategy took less than its amount, or gave some back

    /// @notice Everything a launch chooses; the factory fixes the rest.
    struct LaunchInput {
        string name;
        string symbol;
        uint128 auctionSupply; // what the auction sells; the pool's reserve is the same again
        uint256 floorPrice; // Q96 quote per token, a multiple of `tickSpacing`
        uint256 tickSpacing; // the auction's price tick, Q96
        uint64 startBlock;
        uint64 endBlock;
        uint128 requiredRaise; // what the auction must raise to graduate
        uint256 teamShareBps; // the team's share of the raise, at most MAX_TEAM_SHARE_BPS
        uint64 buyerDuration; // the buyer schedule's linear vest from launchBy, at least MIN_BUYER_VEST
        Leg[] legs; // team allocations, each on its own curve from launchBy
        uint256 opsAmount; // launch tokens the ops budget vests to the operator
        address operator; // the one address the ops wallet and the LP fees pay
    }

    /// @notice Where a launch went: its lock, auction and ops budget; zero for a token not born here.
    struct Launch {
        address lock;
        address auction;
        address budget;
    }

    address public immutable HUB; // the ACE hub every launch's lock pledges into
    address public immutable STRATEGY; // the LBP strategy every launch distributes through
    address public immutable QUOTE; // USDC: every launch raises in it
    address public immutable AUCTION_FACTORY; // the strategy's auction factory, whose oracle names each launch's auction
    uint256 public immutable MAX_BLOCK_SECONDS; // the slowest average block assumed between a launch and its migration
    uint24 public immutable POOL_FEE; // every launch pool's static LP fee, in millionths
    int24 public immutable POOL_TICK_SPACING; // every launch pool's tick spacing
    RunwayHook public immutable HOOK; // every launch pool's hook, made here
    address public immutable BUDGET_IMPL; // the ops budget every launch clones
    uint256 public immutable CUT_BPS; // the cut of every live raise, read by the bracket; BUDGET_IMPL holds the same value for settle, with CUT_RECIPIENT

    mapping(address token => Launch) public launchOf; // zero for any token not born here
    mapping(PoolId => uint64) public launchByOf; // the last second the hook admits each launch's pool; zero for any other key

    /// @notice `creator` launched `token`: its lock, auction and ops budget, and the one pool the hook will admit.
    event Launched(address indexed token, address indexed creator, address lock, address auction, address budget, PoolId poolId);

    /// @param hub The ACE hub.
    /// @param strategy The launcher's LBP strategy on this chain.
    /// @param quote USDC on this chain.
    /// @param maxBlockSeconds The slowest average block time this chain is assumed to run; above its slot time, so missed slots fit.
    /// @param poolFee Every launch pool's static LP fee.
    /// @param poolTickSpacing Every launch pool's tick spacing.
    /// @param hookSalt The salt that lands the hook, deployed here, at an address carrying exactly the before-initialize and before-swap bits.
    /// @param cutRecipient Where every launch's budget pays the protocol's cut; nonzero whenever the cut is.
    /// @param cutBps The protocol's cut of every live launch's raise, at most MAX_CUT_BPS; zero takes none.
    constructor(
        address hub,
        address strategy,
        address quote,
        uint256 maxBlockSeconds,
        uint24 poolFee,
        int24 poolTickSpacing,
        bytes32 hookSalt,
        address cutRecipient,
        uint256 cutBps
    ) {
        if (maxBlockSeconds == 0) revert ZeroBlockSeconds();
        if (poolFee > LPFeeLibrary.MAX_LP_FEE) revert BadPoolFee();
        if (poolTickSpacing < TickMath.MIN_TICK_SPACING || poolTickSpacing > TickMath.MAX_TICK_SPACING) revert BadTickSpacing();
        if (cutBps != 0 && cutRecipient == address(0)) revert ZeroCutRecipient();
        if (cutBps > MAX_CUT_BPS) revert CutOverCap();
        address posm = ILBPStrategy(strategy).positionManager();
        IPoolManager pm = IV4PositionManager(posm).poolManager();
        (HUB, STRATEGY, QUOTE, MAX_BLOCK_SECONDS, POOL_FEE, POOL_TICK_SPACING) = (hub, strategy, quote, maxBlockSeconds, poolFee, poolTickSpacing);
        CUT_BPS = cutBps;
        AUCTION_FACTORY = ILBPStrategy(strategy).initializerFactory();
        HOOK = new RunwayHook{salt: hookSalt}(pm, strategy);
        BUDGET_IMPL = address(new LaunchOpsBudget(quote, address(pm), posm, cutRecipient, cutBps));
    }

    /// @notice Launch a token: born holding its whole supply, the strategy's two halves distributed, then every allocation paid to its contract.
    /// @param p Everything the launch chooses.
    /// @return token The new token.
    function launch(LaunchInput calldata p) external nonReentrant returns (address token) {
        if (p.startBlock <= block.number || p.endBlock <= p.startBlock || LAUNCH_MPS % (p.endBlock - p.startBlock) != 0) revert BadWindow();
        uint64 launchBy = SafeCast.toUint64(block.timestamp + (uint256(p.endBlock) + 1 - block.number) * MAX_BLOCK_SECONDS + MIGRATION_WINDOW);
        token = address(new LaunchToken(p.name, p.symbol, _supply(p)));
        Launch memory L;
        L.lock = address(new LaunchLock(token, HUB, launchBy, p.buyerDuration, p.legs));
        PoolId pool = _poolKey(token).toId();
        L.budget =
            Clones.cloneWithImmutableArgs(BUDGET_IMPL, abi.encode(token, pool, p.operator, p.opsAmount, p.teamShareBps, uint256(p.auctionSupply), launchBy));
        launchByOf[pool] = launchBy;
        L.auction = _distribute(token, p, L.lock, L.budget);
        for (uint256 i; i < p.legs.length; ++i) {
            IERC20(token).safeTransfer(LaunchLock(L.lock).account(p.legs[i].beneficiary, i + 1), p.legs[i].amount);
        }
        IERC20(token).safeTransfer(L.budget, p.opsAmount);
        if (IERC20(token).balanceOf(address(this)) != 0) revert SupplyLeft();
        launchOf[token] = L;
        emit Launched(token, msg.sender, L.lock, L.auction, L.budget, pool);
    }

    /// @dev The supply, the strategy's two halves plus every leg and the ops amount, and every input check but the window's and the lock's.
    function _supply(LaunchInput calldata p) private pure returns (uint256 supply) {
        if (p.auctionSupply == 0) revert ZeroSupply();
        if (p.teamShareBps > MAX_TEAM_SHARE_BPS) revert ShareOverCap();
        if (p.operator == address(0)) revert ZeroOperator();
        if (p.buyerDuration < MIN_BUYER_VEST) revert BuyerVestTooShort();
        supply = 2 * uint256(p.auctionSupply) + p.opsAmount;
        for (uint256 i; i < p.legs.length; ++i) {
            Leg calldata l = p.legs[i];
            if (l.amount == 0 || l.cliff < MIN_TEAM_CLIFF || l.duration < MIN_TEAM_VEST) revert BadLeg();
            supply += l.amount;
        }
        if (p.opsAmount * 10_000 > supply * MAX_OPS_BPS) revert OpsOverCap();
    }

    /// @dev The launch pool: the token against QUOTE behind HOOK, at the fixed fee and spacing.
    function _poolKey(address token) private view returns (PoolKey memory) {
        (address c0, address c1) = token < QUOTE ? (token, QUOTE) : (QUOTE, token);
        return PoolKey(Currency.wrap(c0), Currency.wrap(c1), POOL_FEE, POOL_TICK_SPACING, IHooks(address(HOOK)));
    }

    /// @dev The strategy takes its two halves and registers the auction its factory's oracle names, for this token; a short take is SupplyLeft.
    function _distribute(address token, LaunchInput calldata p, address lock, address budget) private returns (address auction) {
        uint256 amount = 2 * uint256(p.auctionSupply);
        bytes memory auctionData = abi.encode(_auctionParams(p, lock, budget));
        MigratorParameters memory m = _migratorParams(token, p, budget);
        auction = ICcaFactory(AUCTION_FACTORY).getAddress(token, p.auctionSupply, auctionData, keccak256(abi.encode(bytes32(0), m)), STRATEGY);
        IERC20(token).forceApprove(STRATEGY, amount);
        ILBPStrategy(STRATEGY).initializeDistribution(token, amount, abi.encode(m, auctionData), bytes32(0));
        if (ILBPStrategy(STRATEGY).initializers(auction).token != token) revert WrongAuction();
    }

    /// @dev The auction: USDC, the budget alone may sweep unsold tokens, the raise to the strategy, the lock as the bid gate, one even step.
    function _auctionParams(LaunchInput calldata p, address lock, address budget) private view returns (AuctionParameters memory a) {
        uint64 blocks = p.endBlock - p.startBlock;
        (a.currency, a.tokensRecipient, a.fundsRecipient) = (QUOTE, budget, MSG_SENDER);
        (a.startBlock, a.endBlock, a.claimBlock) = (p.startBlock, p.endBlock, p.endBlock);
        (a.tickSpacing, a.validationHook, a.floorPrice, a.requiredCurrencyRaised) = (p.tickSpacing, lock, p.floorPrice, p.requiredRaise);
        a.auctionStepsData = abi.encodePacked(uint24(LAUNCH_MPS / blocks), uint40(blocks));
    }

    /// @dev The migration: the reserve is the auction supply, the leftovers and the LP to the budget, the full-range fallback alone.
    /// @dev One bracket: the pool gets the raise less the team's share and the cut, which the budget receives.
    function _migratorParams(address token, LaunchInput calldata p, address budget) private view returns (MigratorParameters memory m) {
        LiquidityAllocationBracket[] memory b = new LiquidityAllocationBracket[](1);
        b[0] = LiquidityAllocationBracket({lowerThreshold: 0, rate: uint24(LAUNCH_MPS * (10_000 - p.teamShareBps - CUT_BPS) / 10_000)});
        (m.token, m.currency, m.migrationBlock, m.reservedTokenAmountForLP) = (token, QUOTE, p.endBlock + 1, p.auctionSupply);
        (m.recipient, m.positionRecipient) = (budget, budget);
        m.poolParameters = PoolParameters({fee: POOL_FEE, tickSpacing: POOL_TICK_SPACING, hook: address(HOOK)});
        m.positionDefinitions = abi.encode(new PositionDefinition[](0));
        m.lpAllocationSchedule = abi.encode(b);
    }
}
