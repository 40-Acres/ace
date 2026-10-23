// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.36;

/// @title Constants
/// @notice Everything the hub freezes at deploy: ACE's own take, and the envelope every market is created inside.
/// @notice Nothing here is creator-set -- a creator dials `MarketParams`, and the rails say how far.
/// @dev `MarketInit` enforces the rails; they live here so the whole immutable surface reads on one screen.
/// @dev A rail loosens only on a ruling, and only before broadcast: immutability is permanent.
/// @dev ONE RELATION BINDS TWO OF THEM: `MIN_COVERAGE_WAD * (10000 - MAX_DELEVERAGE_FLOOR_EPS_BPS) > 1e22`.
/// @dev The deleverage sizing denominator's positivity proof rests on it, so a retune of EITHER must preserve it.
/// @dev Shipped margin is 2.9%. Breaking it does not prove a defect, but it does remove the proof.
/// @dev The two push tails are gas on Ethereum's opcode schedule: a chain that reprices storage or calls re-measures them first.
library Constants {
    // ---- ACE's own take: uniform across every market, never creator-set ----

    uint256 internal constant PROTOCOL_SHARE_BPS = 1000; // ACE's origination take, charged ON TOP of the lender's baseBps, never carved out of it
    uint256 internal constant REBATE_PHI_BPS = 5000; // half the lender fee is refundable: a borrower pays the midpoint of term booked and used
    uint64 internal constant SWEEP_PERIOD = 1 days; // min spacing between keeper-crank sweeps: transfer count against dwell time

    // ---- the swallowed token push: a fixed budget per deploy, railed here, and the two measured tails behind it ----

    uint256 internal constant MIN_PUSH_GAS = 60_000; // the budget's floor: an Ethereum USDC or USDT push needs under 48k
    uint256 internal constant MAX_PUSH_GAS = 250_000; // its ceiling: bounds a hostile quote's burn per push, and the limit every close carries
    uint256 internal constant PUSH_TAIL = 40_000; // the lender push's frame past its budget, 2x measured: a from-zero restore is 20k of it
    uint256 internal constant SWEEP_TAIL = 47_000; // the sweep's frame past its budget: its stamp, counter, restore and event, 2x measured

    // ---- genesis rails: the universal envelope, enforced by MarketInit ----

    uint256 internal constant MIN_COVERAGE_WAD = 1.05e18; // ruled: debt up to ~95% of the bid; MAX_SETTLE_BOUNTY_BPS and the deleverage denominator ride on it
    uint256 internal constant MAX_COVERAGE_WAD = 20e18; // ruled: 20x admits ~5% LTV markets
    uint256 internal constant MAX_DELEVERAGE_PROTOCOL_BPS = 2000; // sanity ceiling; the feasibility rail guards
    uint256 internal constant MAX_FILL_FEE_BPS = 50; // a ceiling on the premium a settled pot's buyer pays over the ask; no keeper pays it
    uint256 internal constant MIN_BASE_BPS = 1; // keeps the origination fee and the tick cut non-zero; the escrow cut may still floor to zero
    uint256 internal constant MAX_PRICE = 1 << 224; // Q96 price ceiling; every overflow argument assumes it, so re-derive them before raising it
    uint256 internal constant MAX_DECIMALS = 18; // bounds the pair's decimal gap, hence how far par sits from 2^96
    uint256 internal constant MAX_DELEVERAGE_FLOOR_EPS_BPS = 200; // ruled unsized: deleverage is never the solvency path; the header relation binds it
    uint256 internal constant MAX_SETTLE_BOUNTY_BPS = 200; // the coverage line holds at BOTH doors iff b <= k-1
    uint256 internal constant MAX_FEE_SHARE_BPS = 2500; // most of a principal an origination fee may consume, at any admissible term
    uint256 internal constant MIN_DELEVERAGE_BAND_BPS = 3000; // solvency floor: below it a fast decline crosses the corridor between prints

    uint64 internal constant AUTO_REFINANCE_WINDOW = 2 hours; // keeper-latency budget, not a risk dial
    uint64 internal constant AUTO_REFINANCE_WINDOW_DIVISOR = 5; // the leg that binds on minute-scale tenors
    uint64 internal constant AUTO_ROLL_HOME_SHARE_DIVISOR = 2; // window / this is the stranger-open tail; the leading rest is the incumbent's alone

    uint64 internal constant INVENTORY_HOLD = 1 hours; // where a market has the ask, settled inventory rests this long before it opens
    uint64 internal constant INVENTORY_HOLD_DIVISOR = 2; // the leg that binds on minute-scale tenors

    uint64 internal constant MIN_TENOR_FLOOR = AUTO_REFINANCE_WINDOW_DIVISOR * AUTO_ROLL_HOME_SHARE_DIVISOR > INVENTORY_HOLD_DIVISOR
        ? AUTO_REFINANCE_WINDOW_DIVISOR * AUTO_ROLL_HOME_SHARE_DIVISOR
        : INVENTORY_HOLD_DIVISOR; // the smallest minTenor at which no tenor-derived window or hold is zero
}
