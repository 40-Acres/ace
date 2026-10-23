// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.36;

import {IPoolManager} from "@uniswap/v4-core/src/interfaces/IPoolManager.sol";
import {PoolKey} from "@uniswap/v4-core/src/types/PoolKey.sol";

/// @notice The launcher's LBP strategy as a test drives it: the distribution it registers, the migration it runs, and its two reads.
interface ILBPStrategyLaunch {
    function initializeDistribution(address token, uint256 totalSupply, bytes calldata configData, bytes32 salt) external;
    function migrate(address initializer) external;
    function initializerFactory() external view returns (address);
    function positionManager() external view returns (address);
}

/// @notice The bidder's side of a Continuous Clearing Auction.
interface ICcaBidding {
    function submitBid(uint256 maxPrice, uint128 amount, address owner, bytes calldata hookData) external payable returns (uint256);
    function exitBid(uint256 bidId) external;
    function exitPartiallyFilledBid(uint256 bidId, uint64 lastFullyFilledCheckpointBlock, uint64 outbidBlock) external;
    function checkpoint() external;
    function claimTokens(uint256 bidId) external;
    function isGraduated() external view returns (bool);
    function sweepUnsoldTokens() external;
}

/// @notice Permit2's allowance door, which the auction pulls an ERC-20 bid through.
interface IAllowanceTransfer {
    function approve(address token, address spender, uint160 amount, uint48 expiration) external;
}

/// @notice v4's PositionManager, as far as a fork row reads it: its PoolManager, its next id, a position's pool and liquidity, and its write door.
interface IPositionsView {
    function poolManager() external view returns (IPoolManager);
    function nextTokenId() external view returns (uint256);
    function getPoolAndPositionInfo(uint256 tokenId) external view returns (PoolKey memory, uint256);
    function getPositionLiquidity(uint256 tokenId) external view returns (uint128);
    function modifyLiquidities(bytes calldata unlockData, uint256 deadline) external payable;
}
