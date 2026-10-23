// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.36;

import {IPoolManager} from "@uniswap/v4-core/src/interfaces/IPoolManager.sol";
import {PoolKey} from "@uniswap/v4-core/src/types/PoolKey.sol";

uint24 constant LAUNCH_MPS = 1e7; // the auction's and the strategy's whole, in ten-millionths: the one copy the launch path shares
address constant LAUNCH_DEAD = 0x000000000000000000000000000000000000dEaD; // no key, never calls; the launch token burns whatever is sent here

/// @notice The Continuous Clearing Auction's bid gate, its name and signature as upstream declares them.
/// @dev The interface id is the one selector, so a hook declaring this answers the auction's own ERC-165 probe.
interface IValidationHook {
    /// @notice Validate a bid; the auction refuses the bid when this reverts.
    /// @param maxPrice The most the bidder will pay, Q96.
    /// @param amount The currency the bid commits.
    /// @param owner Who the bid's tokens and refund are paid to.
    /// @param sender Who submitted and paid for the bid.
    /// @param hookData Whatever the hook needs to judge the bid.
    function validate(uint256 maxPrice, uint128 amount, address owner, address sender, bytes calldata hookData) external;
}

/// @notice One auction bid, field for field as upstream stores it; `tokensFilled` is zeroed by a claim, the rest persist.
struct Bid {
    uint64 startBlock;
    uint24 startCumulativeMps;
    uint64 exitedBlock;
    uint256 maxPrice;
    address owner;
    uint256 amountQ96;
    uint256 tokensFilled;
}

/// @notice One auction checkpoint, field for field as upstream stores it; the X7 value is a plain uint256 on the wire.
struct Checkpoint {
    uint256 clearingPrice;
    uint256 currencyRaisedAtClearingPriceQ96X7;
    uint256 cumulativeMpsPerPrice;
    uint24 cumulativeMps;
    uint64 prev;
    uint64 next;
}

/// @notice One auction price tick, field for field as upstream stores it.
struct Tick {
    uint256 next;
    uint256 currencyDemandQ96;
}

/// @notice A Continuous Clearing Auction as the ops budget settles and refunds by it, and a frontend reads it; its one write is the tokens recipient's sweep.
interface IContinuousClearingAuction {
    function token() external view returns (address);
    function currency() external view returns (address);
    function totalSupply() external view returns (uint128);
    function tokensRecipient() external view returns (address);
    function fundsRecipient() external view returns (address);
    function validationHook() external view returns (address);
    function endBlock() external view returns (uint64);
    function claimBlock() external view returns (uint64);
    function bids(uint256 bidId) external view returns (Bid memory);
    function checkpoints(uint64 blockNumber) external view returns (Checkpoint memory);
    function ticks(uint256 priceQ96) external view returns (Tick memory);
    function currencyRaisedQ96X7() external view returns (uint256);
    function isGraduated() external view returns (bool);
    function lastCheckpointedBlock() external view returns (uint64);
    function clearingPrice() external view returns (uint256);
    function sweepUnsoldTokens() external;
}

/// @notice A Continuous Clearing Auction's constructor parameters, field for field as upstream declares them.
struct AuctionParameters {
    address currency;
    address tokensRecipient;
    address fundsRecipient;
    uint64 startBlock;
    uint64 endBlock;
    uint64 claimBlock;
    uint256 tickSpacing;
    address validationHook;
    uint256 floorPrice;
    uint128 requiredCurrencyRaised;
    bytes auctionStepsData;
}

/// @notice The pool the launcher's LBP strategy seeds.
struct PoolParameters {
    uint24 fee;
    int24 tickSpacing;
    address hook;
}

/// @notice What the LBP strategy stores per auction and acts on at migration, field for field as upstream declares it.
struct MigratorParameters {
    address token;
    address currency;
    uint64 migrationBlock; // zero means the auction is not registered with this strategy
    uint128 reservedTokenAmountForLP; // the strategy's own token budget for the pool, beside what the auction sells
    address recipient; // receives unused currency and unused reserve after migration, and both whole if migration fails
    address positionRecipient; // default owner of every minted LP position
    PoolParameters poolParameters;
    bytes positionDefinitions; // abi-encoded PositionDefinition[]
    bytes lpAllocationSchedule; // abi-encoded LiquidityAllocationBracket[]
}

/// @notice One weighted LP position; a zero override takes the default position recipient.
struct PositionDefinition {
    int24 offsetLower;
    int24 offsetUpper;
    uint24 weight;
    address overridePositionRecipient;
}

/// @notice One bracket of the share of raised currency that goes to the pool, in ten-millionths: 1e7 is all of it.
struct LiquidityAllocationBracket {
    uint128 lowerThreshold;
    uint24 rate;
}

/// @notice The launcher's LBP strategy: the distribution a launch registers, pulled from its caller, and the registration it keeps.
/// @dev The deployed strategy's `initializeDistribution` returns nothing, so the auction's address comes from its factory's oracle.
interface ILBPStrategy {
    function initializeDistribution(address token, uint256 totalSupply, bytes calldata configData, bytes32 salt) external;
    function initializers(address initializer) external view returns (MigratorParameters memory);
    function positionManager() external view returns (address);
    function initializerFactory() external view returns (address);
}

/// @notice v4's PositionManager, as far as the launch path uses it: its PoolManager, a position's pool, and the write door fees are collected through.
interface IV4PositionManager {
    function poolManager() external view returns (IPoolManager);
    function getPoolAndPositionInfo(uint256 tokenId) external view returns (PoolKey memory poolKey, uint256 info);
    function modifyLiquidities(bytes calldata unlockData, uint256 deadline) external payable;
}

/// @notice The auction factory's address oracle, as upstream declares it: the strategy's salt is hashed with its migration parameters.
interface ICcaFactory {
    function getAddress(address token, uint256 amount, bytes calldata configData, bytes32 salt, address sender) external view returns (address);
}
