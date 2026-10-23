// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.36;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {VestingWalletUpgradeable} from "../../../vendor/oz-upgradeable/VestingWalletUpgradeable.sol";
import {Clones} from "@openzeppelin/contracts/proxy/Clones.sol";
import {Math} from "@openzeppelin/contracts/utils/math/Math.sol";
import {ReentrancyGuardTransient} from "@openzeppelin/contracts/utils/ReentrancyGuardTransient.sol";
import {IPoolManager} from "@uniswap/v4-core/src/interfaces/IPoolManager.sol";
import {StateLibrary} from "@uniswap/v4-core/src/libraries/StateLibrary.sol";
import {PoolId, PoolIdLibrary} from "@uniswap/v4-core/src/types/PoolId.sol";
import {PoolKey} from "@uniswap/v4-core/src/types/PoolKey.sol";
import {Bid, Checkpoint, IContinuousClearingAuction, IV4PositionManager, LAUNCH_DEAD, LAUNCH_MPS} from "../../interfaces/ILaunchAuction.sol";
import {LaunchTokenFactory} from "./LaunchTokenFactory.sol";

/// @title LaunchVestingWallet
/// @notice OpenZeppelin's VestingWalletUpgradeable as the implementation every budget clones: locked at construction, so only clones initialize.
contract LaunchVestingWallet is VestingWalletUpgradeable {
    constructor() {
        _disableInitializers();
    }
}

/// @title LaunchOpsBudget
/// @notice One launch's ops budget, and the LBP strategy's recipient: it receives the team's share, the protocol's cut and whatever comes back.
/// @notice SETTLE, once, by anyone, after launchBy: live, the team gets its share of the raise and the protocol its cut; failed, the bids share it all.
/// @notice The cut is booked, never pushed: `payProtocol` pays it to CUT_RECIPIENT, so a recipient the quote refuses strands only the cut.
/// @notice Settlement clones an OpenZeppelin VestingWallet for the operator, from launchBy over a year, and sends it the ops tokens and the share.
/// @notice It then sweeps the auction's unsold tokens in and burns every launch token left here; the split is fixed for good.
/// @notice It owns the launch's LP and collects its fees without moving liquidity: the currency to the operator at once, the token side burned.
/// @dev Live is the pool's price being set. The hook admits only the strategy, for this key, by launchBy; settlement waits until the key has closed.
/// @dev Failed is the WHOLE reserve here with no pool: the strategy's recovery returns it, and no launch token is liquid before launchBy.
/// @dev Past launchBy, tokens vest; if migrate waits until a holder can donate the reserve, that donation latches failure first.
/// @dev Only this budget may sweep the unsold tokens, and it does so after reading live or failed, so they can never latch a failure.
/// @dev The team's share of the raise is senior to the cut, CUT_BPS of it; each is capped at what is left, and currency past both goes to the bids.
/// @dev WHAT A BID SPENT, which the auction never stores, is recomputed from its persistent state with its own exit arithmetic; each bid is refunded once.
/// @dev A clone of one implementation; its args are its launch, read by `terms`. The implementation has none, so its verbs revert.
contract LaunchOpsBudget is ReentrancyGuardTransient {
    using PoolIdLibrary for PoolKey;
    using SafeERC20 for IERC20;
    using StateLibrary for IPoolManager;

    uint8 internal constant DECREASE_LIQUIDITY = 0x01; // v4-periphery Actions codes the PositionManager decodes; that library is not a dependency here
    uint8 internal constant TAKE = 0x0e;

    error AlreadySettled(); // settlement runs once
    error TooEarly(); // settlement opens only after launchBy, when the hook has closed the launch's key
    error NotFinal(); // the auction's end is not checkpointed yet, so the raise is not final
    error Pending(); // the pool is not live and the reserve has not come back: the migration has not run
    error NotSettled(); // nothing is refunded before settlement fixes the split
    error AlreadyRefunded(); // each bid is refunded once
    error BadHint(); // a checkpoint hint the auction's own exit would refuse
    error NotLive(); // fees are collected only from a pool that went live
    error NotOurPosition(); // the position is not in this launch's pool

    address public immutable FACTORY; // the launch factory that made the implementation, whose record names each launch's auction
    address public immutable QUOTE; // USDC: the raise, the team's share, the protocol's cut and the LP's fees
    IPoolManager public immutable POOL_MANAGER; // the v4 PoolManager the launch pool lives in
    address public immutable POSITION_MANAGER; // v4's PositionManager, which holds the LP positions this budget owns
    address public immutable WALLET_IMPL; // the locked LaunchVestingWallet this implementation's constructor deployed; each settlement clones it
    address public immutable CUT_RECIPIENT; // where `payProtocol` sends the protocol's cut
    uint256 public immutable CUT_BPS; // the protocol's cut of a live launch's raise, in basis points, beside the team's share

    bool public live; // settlement found the pool live
    address public wallet; // the operator's VestingWallet, made at settlement; zero before, so it also marks settlement
    uint256 public refundPool; // the currency the bids share, fixed at settlement
    uint256 public protocolOwed; // the cut settlement booked and `payProtocol` has not yet paid
    uint256 public refundedOut; // currency refunded so far, across every bid
    mapping(uint256 bidId => bool) public refunded; // each bid refunded already
    address internal _settledAuction; // the auction, kept at settlement
    uint256 internal _raised; // the auction's final raise, Q96, kept at settlement

    /// @notice Settlement fixed the split for good: live or failed, the team's currency, the protocol's cut, the bids' pool, and the tokens burned.
    event Settled(bool live, uint256 teamCurrency, uint256 protocolCut, uint256 refundPool, uint256 burned);
    /// @notice Bid `bidId`'s owner was refunded `amount`.
    event Refunded(uint256 indexed bidId, address indexed owner, uint256 amount);

    /// @notice One clone's launch, as its args carry it.
    struct Terms {
        address token;
        PoolId pool;
        address operator;
        uint256 opsAllocation;
        uint256 shareBps;
        uint256 reserve;
        uint64 launchBy;
    }

    /// @param quote USDC on this chain.
    /// @param poolManager The v4 PoolManager.
    /// @param positionManager v4's PositionManager, the strategy's.
    /// @param cutRecipient Where the protocol's cut is paid.
    /// @param cutBps The protocol's cut of a live launch's raise; the factory caps it.
    constructor(address quote, address poolManager, address positionManager, address cutRecipient, uint256 cutBps) {
        (FACTORY, QUOTE, POOL_MANAGER, POSITION_MANAGER) = (msg.sender, quote, IPoolManager(poolManager), positionManager);
        (CUT_RECIPIENT, CUT_BPS) = (cutRecipient, cutBps);
        WALLET_IMPL = address(new LaunchVestingWallet());
    }

    /// @notice The launch: token, pool, operator, ops allocation, the team's share in basis points, the strategy's reserve, and launchBy.
    function terms() public view returns (Terms memory) {
        return abi.decode(Clones.fetchCloneArgs(address(this)), (Terms));
    }

    /// @notice Fix the split, once, by anyone, after launchBy: live gives the team its capped share and books the cut, failed refunds the bids everything.
    /// @notice The operator's wallet gets the ops tokens and the share; the unsold are swept in, best effort, and every launch token left burns.
    function settle() external nonReentrant {
        if (wallet != address(0)) revert AlreadySettled();
        Terms memory t = terms();
        if (block.timestamp <= t.launchBy) revert TooEarly();
        IContinuousClearingAuction c = _final(t.token);
        (uint160 sqrtPriceX96,,,) = POOL_MANAGER.getSlot0(t.pool);
        bool isLive = sqrtPriceX96 != 0;
        if (!isLive && IERC20(t.token).balanceOf(address(this)) < t.opsAllocation + t.reserve) revert Pending();
        uint256 raised = c.currencyRaisedQ96X7() / LAUNCH_MPS;
        (uint256 team, uint256 cut, uint256 pool) = _split(isLive, IERC20(QUOTE).balanceOf(address(this)), raised, t.shareBps);
        address w = Clones.clone(WALLET_IMPL);
        VestingWalletUpgradeable(payable(w)).initialize(t.operator, t.launchBy, 365 days);
        (wallet, refundPool, protocolOwed, live, _settledAuction, _raised) = (w, pool, cut, isLive, address(c), raised);
        try c.sweepUnsoldTokens() {} catch {} // a refused sweep leaves the unsold in the auction and never blocks refunds
        IERC20(t.token).safeTransfer(w, t.opsAllocation);
        uint256 burned = IERC20(t.token).balanceOf(address(this));
        if (burned != 0) IERC20(t.token).safeTransfer(LAUNCH_DEAD, burned);
        if (team != 0) IERC20(QUOTE).safeTransfer(w, team);
        emit Settled(isLive, team, cut, pool, burned);
    }

    /// @notice Pay the cut settlement booked to CUT_RECIPIENT. Anyone may call it; before settlement, or once paid, it moves nothing.
    /// @return amount What was paid.
    function payProtocol() external nonReentrant returns (uint256 amount) {
        amount = protocolOwed;
        if (amount == 0) return 0;
        protocolOwed = 0;
        IERC20(QUOTE).safeTransfer(CUT_RECIPIENT, amount);
    }

    /// @notice Pay bid `bidId`'s owner its spent share of the refund pool, once. Anyone may call it; a bid owed nothing is still marked.
    /// @param lastFullyFilled The auction's own exit hint, for a bid at or under the final clearing price; ignored above it.
    /// @param outbid The auction's own outbid hint, or zero for a bid AT the final clearing price.
    /// @return amount What was paid.
    function refund(uint256 bidId, uint64 lastFullyFilled, uint64 outbid) external nonReentrant returns (uint256 amount) {
        if (refunded[bidId]) revert AlreadyRefunded();
        address owner;
        (owner, amount) = _due(bidId, lastFullyFilled, outbid);
        refunded[bidId] = true;
        refundedOut += amount;
        if (amount != 0) IERC20(QUOTE).safeTransfer(owner, amount);
        emit Refunded(bidId, owner, amount);
    }

    /// @notice What bid `bidId` spent in the auction, Q96 currency, by the auction's own exit arithmetic; zero if it never graduated.
    function spentOf(uint256 bidId, uint64 lastFullyFilled, uint64 outbid) external view nonReentrantView returns (uint256) {
        IContinuousClearingAuction c = _final(terms().token);
        return _spent(c, c.endBlock(), c.bids(bidId), lastFullyFilled, outbid);
    }

    /// @notice What `refund` would pay bid `bidId` now; zero once it was refunded.
    function owed(uint256 bidId, uint64 lastFullyFilled, uint64 outbid) external view nonReentrantView returns (uint256 amount) {
        if (refunded[bidId]) return 0;
        (, amount) = _due(bidId, lastFullyFilled, outbid);
    }

    /// @notice Collect position `tokenId`'s fees without moving its liquidity: the currency to the operator, the token side burned.
    function collectFees(uint256 tokenId) external nonReentrant {
        if (!live) revert NotLive();
        Terms memory t = terms();
        (PoolKey memory k,) = IV4PositionManager(POSITION_MANAGER).getPoolAndPositionInfo(tokenId);
        if (PoolId.unwrap(k.toId()) != PoolId.unwrap(t.pool)) revert NotOurPosition();
        bytes[] memory params = new bytes[](3);
        params[0] = abi.encode(tokenId, uint256(0), uint128(0), uint128(0), bytes(""));
        params[1] = abi.encode(QUOTE, t.operator, uint256(0)); // zero takes the whole open delta
        params[2] = abi.encode(t.token, LAUNCH_DEAD, uint256(0));
        IV4PositionManager(POSITION_MANAGER).modifyLiquidities(abi.encode(abi.encodePacked(DECREASE_LIQUIDITY, TAKE, TAKE), params), block.timestamp);
    }

    /// @dev The recorded auction, once its end is checkpointed: nothing it raised or a bid spent is final before that.
    function _final(address token) private view returns (IContinuousClearingAuction c) {
        (, address a,) = LaunchTokenFactory(FACTORY).launchOf(token);
        c = IContinuousClearingAuction(a);
        if (c.lastCheckpointedBlock() != c.endBlock()) revert NotFinal();
    }

    /// @dev Live: the team's share of the raise, then the cut, each capped at what is left, and the rest to the bids. Failed: all to the bids.
    function _split(bool isLive, uint256 bal, uint256 raised, uint256 shareBps) private view returns (uint256 team, uint256 cut, uint256 pool) {
        if (isLive) {
            team = Math.min(bal, Math.mulDiv(raised, shareBps, 10_000 << 96));
            cut = Math.min(bal - team, Math.mulDiv(raised, CUT_BPS, 10_000 << 96));
        }
        pool = bal - team - cut;
    }

    /// @dev A bid's owner and its share of the pool, once settlement has fixed the pool.
    function _due(uint256 bidId, uint64 lastFullyFilled, uint64 outbid) private view returns (address owner, uint256 amount) {
        if (wallet == address(0)) revert NotSettled();
        IContinuousClearingAuction c = IContinuousClearingAuction(_settledAuction);
        Bid memory b = c.bids(bidId);
        (owner, amount) = (b.owner, _share(_spent(c, c.endBlock(), b, lastFullyFilled, outbid)));
    }

    /// @dev The bid's share of the pool by what it spent of the raise, rounded down and clamped to what the pool still holds.
    function _share(uint256 spent) private view returns (uint256) {
        uint256 raised = _raised;
        if (spent == 0 || raised == 0) return 0;
        uint256 pool = refundPool;
        return Math.min(Math.mulDiv(pool, spent, raised), pool - refundedOut);
    }

    /// @dev The auction's `exitBid` arithmetic above the final clearing price, and its `exitPartiallyFilledBid` arithmetic at or under it.
    /// @dev Hint checks and rounding are the auction's own: every spend rounds UP, as the auction rounds it.
    function _spent(IContinuousClearingAuction c, uint64 end, Bid memory b, uint64 lastFullyFilled, uint64 outbid) private view returns (uint256 spent) {
        if (!c.isGraduated()) return 0;
        Checkpoint memory fin = c.checkpoints(end);
        Checkpoint memory start = c.checkpoints(b.startBlock);
        if (b.maxPrice > fin.clearingPrice) return _fullFill(b, fin.cumulativeMps - start.cumulativeMps);

        Checkpoint memory last = c.checkpoints(lastFullyFilled);
        if (last.clearingPrice >= b.maxPrice || c.checkpoints(last.next).clearingPrice < b.maxPrice || lastFullyFilled < b.startBlock) {
            revert BadHint();
        }
        spent = _fullFill(b, last.cumulativeMps - start.cumulativeMps);

        Checkpoint memory upper = fin;
        if (outbid != 0) {
            Checkpoint memory out = c.checkpoints(outbid);
            upper = c.checkpoints(out.prev);
            if (out.clearingPrice <= b.maxPrice || upper.clearingPrice > b.maxPrice) revert BadHint();
        } else if (upper.clearingPrice != b.maxPrice) {
            revert BadHint();
        }
        if (upper.clearingPrice == b.maxPrice) {
            uint256 tickDemand = c.ticks(b.maxPrice).currencyDemandQ96;
            if (tickDemand != 0) {
                spent += Math.mulDiv(
                    b.amountQ96, upper.currencyRaisedAtClearingPriceQ96X7, tickDemand * (LAUNCH_MPS - b.startCumulativeMps), Math.Rounding.Ceil
                );
            }
        }
    }

    /// @dev The share of the bid spent over `mpsDelta` of the schedule it was alive for, rounded up.
    function _fullFill(Bid memory b, uint24 mpsDelta) private pure returns (uint256) {
        return Math.mulDiv(b.amountQ96, mpsDelta, LAUNCH_MPS - b.startCumulativeMps, Math.Rounding.Ceil);
    }
}
