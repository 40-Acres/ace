// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.36;

/// @title SMTChecker harness for the deleverage sizing denominator, FullMath-FREE.
/// @notice NOTHING IN THIS FILE MAY IMPORT FullMath, AND THAT IS THE POINT OF THE FILE.
/// @notice Its 512-bit path is inline assembly, which SMTChecker calls an unsupported language feature.
/// @notice An unsupported construct degrades the WHOLE source unit, so the shipped spelling lives in its own twin.
/// @notice The claim: on any config the genesis rails admit, and any `ps` the stop gate admits, `den` is POSITIVE.
/// @notice `Deleverage._deleverageSizing` asserts that positivity in a comment and proves it nowhere.
/// @notice POSITIVITY, not merely non-underflow: `_deleverageSizing` DIVIDES by `den`, so zero is a division by zero.
/// @notice THE ASSUMPTIONS ARE INLINE, AND THAT IS LOAD-BEARING RATHER THAN A STYLE CHOICE.
/// @notice They used to sit in `_railsAdmit` and `_gatesAdmit`, which NEVER DELIVERED THEM to the caller's targets.
/// @notice Measured both ways in one run: `assert(eps <= 200)` two calls under `require(eps <= 200)` was unproved.
/// @notice The identical assertion under inlined requires PROVED, so the function boundary was the difference.
/// @notice Every target this harness reported while the helpers existed therefore ran with NO preconditions.
/// @notice Do not reintroduce them in any file the model checker reads: an assumption a solver cannot see is none.
/// @notice THE CANARY IS THE GUARD AGAINST THAT RECURRING, and it is the first thing to read in any run.
/// @notice It restates one `require` verbatim, so assumption alone can prove it and nothing else can.
/// @notice If it reports "might happen", every other verdict here describes an unconstrained function.
/// @dev The struct is not tidiness: eight value params plus the locals overflow the stack under non-via-IR.
/// @dev `Stack too deep` is what inlining costs without it, which is why the helpers looked reasonable.
/// @dev Preconditions transcribed from MarketInit.createMarket's `deleverageBandBps != 0` branch.
/// @dev Bounds transcribed from Constants.sol.
/// @dev PRICE BOUNDS ARE A MODELLING ASSUMPTION, not a rail -- `ps` and `trig` are unbounded in the shipped code.
/// @dev They are here so intermediate products cannot overflow uint256; the proof is over the bounded domain only.
/// @dev MAX_PRICE WAS 1e30 AND THAT WAS BELOW REAL MARKETS, which is worth stating because it looked generous.
/// @dev Prices are Q96 atoms-per-atom, so a pair whose QUOTE has more decimals than its collateral scales UP.
/// @dev A DAI(18)-quoted WBTC(8) market at $100k sits near 7.9e43: `1e23 * 1e10 * 2**96 / 1e18`.
/// @dev 1e44 is chosen against the binding product `k * ps * 1e4 < 2**256`, which allows up to ~5.8e53.
contract DeleverageSizingSMT {
    uint256 internal constant MIN_COVERAGE_WAD = 1.05e18;
    uint256 internal constant MAX_COVERAGE_WAD = 20e18;
    uint256 internal constant MAX_DELEVERAGE_FLOOR_EPS_BPS = 200;
    uint256 internal constant MAX_DELEVERAGE_PROTOCOL_BPS = 2000;
    uint256 internal constant MIN_DELEVERAGE_BAND_BPS = 3000;
    uint256 internal constant MAX_PRICE = 1e44; // modelling bound on ps and trig, NOT a shipped rail

    /// @notice One admitted configuration, as a struct so the assumptions inline without Stack too deep.
    struct Admitted {
        uint256 k; // minCoverageWad
        uint256 eps; // deleverageFloorEpsBps
        uint256 cut; // deleverageProtocolBps
        uint256 band; // deleverageBandBps
        uint256 target; // deleverageTargetBps
        uint256 stop; // deleverageStopBps
        uint256 ps; // the persisted price the sale is floored at
        uint256 trig; // the loan's trigger price
    }

    /// @notice THE OBLIGATION: `den` is strictly positive on every admitted input.
    /// @notice The first `assert` is the canary the header describes; it must PROVE or the run means nothing.
    /// @dev `FullMath.mulDiv(a,b,c)` equals `a*b/c` wherever `a*b` does not overflow, which MAX_PRICE secures.
    /// @dev The stop gate is spelled STRICT AND CEILED, exactly as the hub spells it, and without FullMath.
    /// @dev Dropping the ceil is free for non-underflow and FATAL for positivity: `ps = 6, trig = 5` floors both to 4.
    /// @dev A removed assumption is only free for a claim monotone in the domain, and this one is not.
    /// @dev THE BAND GATE IS DELIBERATELY NOT MODELLED, and it is a free assumption left on the floor.
    /// @dev `deleverage` also requires the record to have PERSISTED below the band level for its window.
    /// @dev That is a windowed predicate over the record, not an inequality on `ps`, and `ps` is a separate read.
    /// @param a The candidate configuration; every `require` below is an assumption the solver gets for free.
    /// @return The denominator, so the body cannot be optimized away.
    function check_DenominatorIsStrictlyPositive(Admitted memory a) public pure returns (uint256) {
        require(a.k >= MIN_COVERAGE_WAD && a.k <= MAX_COVERAGE_WAD, "coverage");
        require(a.eps > 0 && a.eps <= MAX_DELEVERAGE_FLOOR_EPS_BPS, "eps");
        require(a.cut <= MAX_DELEVERAGE_PROTOCOL_BPS, "cut");
        require(a.band >= MIN_DELEVERAGE_BAND_BPS && a.band < 10000, "band");
        require(a.target > a.band && a.target < 10000, "target");
        require(a.stop > 0 && a.stop < a.band, "stop");
        require((a.k * (10000 - a.eps) / 10000) * (10000 - a.cut) / 10000 + a.target * 1e14 > 1e18, "denominator rail");
        require(a.stop * 1e14 + (a.k * (10000 - a.eps) / 10000) * (10000 - a.cut) / 10000 > 1e18, "sell-max rail");
        require(a.ps > 0 && a.ps <= MAX_PRICE, "ps range");
        require(a.trig > 0 && a.trig <= MAX_PRICE, "trig range");
        require(a.ps > (a.trig * 1e18 + (1e18 - a.stop * 1e14) - 1) / (1e18 - a.stop * 1e14), "stop gate");
        assert(a.eps <= MAX_DELEVERAGE_FLOOR_EPS_BPS); // THE CANARY -- must PROVE; read it before any other verdict
        uint256 tStar = (a.ps * (1e18 - a.target * 1e14)) / 1e18;
        require(a.trig > tStar, "sizing returns 0 below target");
        uint256 den = (a.k * (a.ps * (10000 - a.eps)) / (1e18 * 10000)) * (10000 - a.cut) / 10000 - tStar;
        assert(den > 0);
        return den;
    }
}
