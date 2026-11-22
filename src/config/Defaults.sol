// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.36;

/// @title Defaults, the single source for the shipped loan-economics params
/// @notice Read these; never re-copy a value, so divergence stays a compile error. The one exception is the hub's per-chain `PUSH_GAS`.
/// @notice Nothing here is secret: a deploy param is PUBLIC on-chain anyway.
/// @notice Validation BOUNDS live in MarketInit; a value here is what this deploy chose inside them, unless its note says no deploy reads it.
/// @dev Two groups, read as ProtocolPolicy.X / PocDeployConfig.Y:
/// @dev   ProtocolPolicy   the keeper eps band-on deploys share, and a one-term tenor pair
/// @dev   PocDeployConfig  THIS PoC market's deploy choices (a future risky-asset market does not inherit)

/// @notice The keeper eps band-on deploys share, and a one-term tenor; deployed markets take the `PocDeployConfig` launch range.
library ProtocolPolicy {
    uint256 internal constant DELEVERAGE_FLOOR_EPS_BPS = 100; // band-on only: the keeper's whole pay, must clear routing impact; band-off leaves eps 0
    uint64 internal constant MIN_TENOR = 7 days; // the one-term tenor; no deploy reads it, deployed markets take `LAUNCH_MIN_TENOR`
    uint64 internal constant MAX_TENOR = 7 days; // == MIN_TENOR, one term; no deploy reads it, deployed markets take the launch range
}

/// @notice This PoC market's deploy choices; NOT global risk defaults (the name says so on purpose).
library PocDeployConfig {
    uint256 internal constant MIN_COVERAGE_WAD = 1.4e18; // trigger coverage multiple; it also caps a draw at 1/k of its funding floor
    int24 internal constant TICK_SPACING = 60; // a v4 pool's spacing; no ACE market has a tick coordinate and no deploy reads it
    uint256 internal constant LENDER_APR_BPS = 2086; // the lender's rate, bps a year: 20.86 percent, 22.94 all-in
    uint64 internal constant PENDING_WINDOW = 4 hours; // W: grace added on top of persistence; no deploy reads it
    uint256 internal constant PERSISTENCE_WINDOW = 30 minutes; // P: distress window; no deploy reads it
    uint256 internal constant TRUNC_BPS = 500; // a windowed record's per-bucket price-move cap; no shipped record truncates and no deploy reads it
    uint256 internal constant MIN_PRINCIPAL = 10000e6; // smallest loan and lender lot; the live debt floor is half, 5000e6
    uint256 internal constant SETTLE_BOUNTY_BPS = 50; // in-kind sliver on finalize + forceClose
    uint256 internal constant PUSH_GAS = 100_000; // Ethereum's push budget, ~2.1x the worst stablecoin push; the hub deploy takes a per-chain value instead
    uint256 internal constant ORACLE_MAX_STALENESS = 25 hours; // a 24h feed heartbeat plus 1h: detects a DEAD feed; freshness is the deviation tier's job
    uint64 internal constant LAUNCH_MIN_TENOR = 7 days; // the launch range's floor; every term pays lenderAprBps a year pro-rata, so APR is flat
    uint64 internal constant LAUNCH_MAX_TENOR = 30 days; // the launch range's ceiling; CONTINUOUS, a borrower names any term between and nothing quantises it
    address internal constant BTC_USD_DAPI_PROXY = 0xCAc4d304032a46C8D0947396B7cBb07986826A36; // API3 BTC/USD; it prices no wrapper
    address internal constant MAINNET_USDC = 0xA0b86991c6218b36c1d19D4a2e9Eb0cE3606eB48; // Ethereum's native USDC
    address internal constant MAINNET_CBBTC = 0xcbB7C0000aB88B473b1f5aFd9ef808440eed33Bf; // Coinbase Wrapped BTC on Ethereum mainnet
    address internal constant CBBTC_USD_FEED = 0x2665701293fCbEB223D11A08D826563EDcCE423A; // Chainlink cbBTC / USD, 8 decimals, a 24h heartbeat
}

uint256 constant HUB_POLICY_GAS = 220_000; // the roll-policy budget every hub the deploy builder makes carries, immutable on the hub
