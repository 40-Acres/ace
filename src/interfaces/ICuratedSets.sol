// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.36;

import {PoolKey} from "@uniswap/v4-core/src/types/PoolKey.sol";
import {MarketParams} from "../ace/hub/Types.sol";

/// @notice One of a set's ranges: its ticks and the liquidity the hook holds there for the set.
struct Range {
    int24 tickLower;
    int24 tickUpper;
    uint128 liquidity;
}

/// @notice A curator's edit to one range slot: a negative delta removes into idle, a positive one adds out of idle.
/// @dev An empty slot takes the edit's ticks; a held slot must be named by its own ticks.
struct RangeEdit {
    uint8 slot;
    int24 tickLower;
    int24 tickUpper;
    int128 liquidityDelta;
}

/// @notice A curator's exact-input swap out of idle, through the set's own pool.
struct SwapLeg {
    bool zeroForOne;
    uint128 amountIn;
    uint160 sqrtPriceLimitX96;
}

/// @notice What a set's valuation reads: its ranges and idle in currency order, and its lending book.
/// @dev `bookUsdc` is the book at face; `bookToken` is collateral recovered in kind and not yet pulled into idle.
struct Valued {
    Range[] ranges;
    uint256 idle0;
    uint256 idle1;
    uint256 bookUsdc;
    uint256 bookToken;
}

/// @notice The hook's write-once wiring, fixed at deploy.
/// @dev A zero `ace` deploys a hook whose sets never lend.
struct HookWiring {
    address pm;
    address usdc;
    address token;
    address record;
    address factory;
    address shareImpl;
    address ace;
    address lenderImpl;
}

/// @notice One lending round's terms: the market a set's round opens as its sole lender, and when its cash stops resting.
/// @dev No fill fee: a round's market sells no settled pot, so it has no buyer to charge one.
struct LendTerms {
    uint256 price;
    uint256 minCoverageWad;
    uint256 baseBps;
    uint64 minTenor;
    uint64 maxTenor;
    uint256 minDebt;
    uint256 settleBountyBps;
    uint64 restUntil;
}

/// @notice A new set's write-once terms.
/// @dev `fee` and `tickSpacing` name the set's pool, which must already be initialized with the hook.
/// @dev `lossCapBps` is the most per-share value the curator's moves may lose at once; it refills by that much per loss window.
struct SetTerms {
    uint24 fee;
    int24 tickSpacing;
    uint16 feeBps;
    uint16 lendCapBps;
    uint16 lossCapBps;
    string name;
    string symbol;
}

/// @notice A set's fixed terms and counters.
struct SetInfo {
    address curator;
    address share;
    uint24 fee;
    int24 tickSpacing;
    uint16 feeBps;
    uint16 lendCapBps;
    uint16 lossCapBps;
    uint256 idle0;
    uint256 idle1;
    uint256 curatorOwed0;
    uint256 curatorOwed1;
}

/// @notice The registry a hook reports each new set share to.
interface ISetFactory {
    function noteShare(address share, uint256 setId) external;
}

/// @notice One lending round of a set: the sole lender of one market, its units fixed at open.
interface ISetLender {
    function open(MarketParams calldata p, uint256 amount, uint64 restUntil) external returns (bytes32 market);
    function recall(uint256 amount) external returns (uint256 paid);
    function move(address from, address to, uint256 amount) external;
    function claim(address holder) external returns (uint256 usdcOut, uint256 tokenOut);
    function windDown() external returns (uint256 paid);
    function collect() external returns (uint256 paid);
    function redeem(uint256 loanId) external returns (uint256 out);
    function settle(uint256 maxNew) external returns (bool clean);
    function done() external view returns (bool);
    function valueOf(address holder) external view returns (uint256 usdcFace, uint256 tokenAmt);
    function unitsOf(address holder) external view returns (uint256);
    function units() external view returns (uint256);
    function market() external view returns (bytes32);
    function restUntil() external view returns (uint64);
}

/// @notice The hub surface a set's round reaches: its market's lender verbs, the in-kind redeem, and the reads that judge them.
/// @dev Every member must exist on the hub with this exact signature: a call compiles against this declaration alone.
interface ISetLenderHub {
    function createMarket(MarketParams calldata p) external returns (bytes32 id);
    function idToMarketParams(bytes32 id) external view returns (MarketParams memory);
    function deposit(bytes32 id, uint256 assets) external;
    function withdraw(bytes32 id, uint256 assets, address to, uint256 minPaid) external returns (uint256 paid);
    function collect(address quote, address to) external returns (uint256 paid);
    function redeemInKind(uint256 loanId, address to) external returns (uint256 out);
    function lenderAssets(address lender, address quote) external view returns (uint256);
    function restingOf(bytes32 id) external view returns (uint256);
    function loanMarket(uint256 id) external view returns (bytes32);
    function isLiveLoan(uint256 id) external view returns (bool);
    function marketLoansLength(bytes32 id) external view returns (uint256);
    function marketLoans(bytes32 id, uint256 offset, uint256 limit) external view returns (uint256[] memory);
}

/// @title ICuratedSets
/// @notice A v4 hook holding curated sets of liquidity on one (USDC, TOKEN) pair, each run by a fixed curator.
interface ICuratedSets {
    function openSet(SetTerms calldata terms, uint256 seed0, uint256 seed1, uint256 shares, address to) external returns (uint256 setId, address share);
    function deposit(uint256 setId, uint256 shares, uint256 max0, uint256 max1, address to, uint64 deadline) external returns (uint256 paid0, uint256 paid1);
    function exit(uint256 setId, uint256 shares, uint256 min0, uint256 min1, address to, uint64 deadline) external returns (uint256 out0, uint256 out1);
    function place(uint256 setId, RangeEdit[] calldata edits, uint160 expectedSqrtP, uint16 tolBps) external;
    function recentre(uint256 setId, RangeEdit[] calldata edits, SwapLeg calldata swap, uint160 expectedSqrtP, uint16 tolBps) external;
    function migrate(
        uint256 setId,
        PoolKey calldata newKey,
        RangeEdit[] calldata edits,
        uint160 expectedSqrtPOld,
        uint160 expectedSqrtPNew,
        uint16 tolBps,
        uint64 deadline
    ) external;
    function collect(uint256 setId) external;
    function claimCuratorFee(uint256 setId) external returns (uint256 amount0, uint256 amount1);
    function lend(uint256 setId, LendTerms calldata terms, uint256 amount) external returns (address round);
    function recall(uint256 setId, address round, uint256 amount) external returns (uint256 paid);
    function closeRound(uint256 setId, address round) external;
    function pullRound(uint256 setId, address round) external;
    function roundsOf(uint256 setId) external view returns (address[] memory);
    function valueAt(uint256 setId, uint256 oracleQ96) external view returns (uint256);
    function shareValue(uint256 setId, uint256 oracleQ96) external view returns (uint256 value, uint256 supply);
    function lossOf(uint256 setId) external view returns (uint64 at, uint64 spentPpb, uint16 capBps);
    function pair() external view returns (address usdc, address token, address record);
    function notEntered() external view returns (bool);
    function setInfo(uint256 setId) external view returns (SetInfo memory);
    function rangesOf(uint256 setId) external view returns (Range[] memory);
    function poolKeyOf(uint256 setId) external view returns (PoolKey memory);
    function setCount() external view returns (uint256);
}
