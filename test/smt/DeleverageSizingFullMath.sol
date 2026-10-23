// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.36;

import {FullMath} from "@uniswap/v4-core/src/libraries/FullMath.sol";

/// @title The SHIPPED-SPELLING twin of DeleverageSizingSMT, isolated in its own source unit (#353, #355).
/// @notice IT IS A SEPARATE FILE BECAUSE FullMath CONTAMINATES ITS WHOLE SOURCE UNIT, not just its callers.
/// @notice Its 512-bit path is inline assembly, which SMTChecker calls an unsupported language feature, and
/// @notice an unsupported construct degrades the analysis of everything compiled beside it.
/// @notice SPLITTING REMOVED THE CONTAMINATION AND DID NOT BUY A PROOF, and the reason was long misread.
/// @notice The old header blamed nonlinear integer arithmetic for the plain twin's 28 unproved targets.
/// @notice MEASURED 2026-09-19: those targets ran with NO PRECONDITIONS AT ALL, so they evidenced nothing.
/// @notice `require`s inside `_railsAdmit`/`_gatesAdmit` never reached the caller's targets in CHC's encoding.
/// @notice The same `assert(eps <= 200)` was unproved through a helper and PROVED under inlined requires.
/// @notice With the assumptions genuinely in scope the denominator is STILL unproved, so the conclusion was
/// @notice right and its evidence was not. That is why both twins now inline, and why a CANARY guards it.
/// @notice THE ASSUMPTIONS ARE INLINE HERE FOR THE SAME REASON, even though no profile analyses this file.
/// @notice A twin that drifts in SHAPE stops being a twin, and the shape is the thing the finding was about.
/// @dev So a difference between this file's verdict and the plain one's is a fact about the SOLVER, never
/// @dev about the protocol -- the two compute the identical quantity wherever the products do not overflow.
/// @dev Keep the two bodies in step by hand; there is no mechanism that will notice if they drift.
/// @dev The struct is not tidiness: eight value params plus the locals overflow the stack under non-via-IR.
contract DeleverageSizingFullMath {
    uint256 internal constant MIN_COVERAGE_WAD = 1.05e18;
    uint256 internal constant MAX_COVERAGE_WAD = 20e18;
    uint256 internal constant MAX_DELEVERAGE_FLOOR_EPS_BPS = 200;
    uint256 internal constant MAX_DELEVERAGE_PROTOCOL_BPS = 2000;
    uint256 internal constant MIN_DELEVERAGE_BAND_BPS = 3000;
    uint256 internal constant MAX_PRICE = 1e44; // modelling bound on ps and trig, NOT a shipped rail; see the plain twin

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

    /// @notice THE OBLIGATION against the shipped spelling: `den` must be STRICTLY POSITIVE on any admitted input.
    /// @notice `_deleverageSizing` divides by `den`, so a zero denominator is a division by zero, not an edge case.
    /// @notice The first `assert` is the canary: it must PROVE, or the preconditions are not reaching the targets.
    /// @dev The checked subtraction covers non-underflow on its own; the second `assert` carries the strict half.
    /// @dev The stop gate is STRICT AND CEILED, spelled with mulDivRoundingUp because this twin is the shipped form.
    /// @dev The band gate is not modelled here either, for the reason the plain twin states.
    /// @param a The candidate configuration; every `require` below is an assumption the solver gets for free.
    /// @return The denominator, so the body cannot be optimized away.
    function check_DenominatorIsStrictlyPositive_FullMath(Admitted memory a) public pure returns (uint256) {
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
        require(a.ps > FullMath.mulDivRoundingUp(a.trig, 1e18, 1e18 - a.stop * 1e14), "stop gate");
        assert(a.eps <= MAX_DELEVERAGE_FLOOR_EPS_BPS); // THE CANARY -- must PROVE; read it before any other verdict
        uint256 tStar = (a.ps * (1e18 - a.target * 1e14)) / 1e18;
        require(a.trig > tStar, "sizing returns 0 below target");
        uint256 den = FullMath.mulDiv(FullMath.mulDiv(a.k, a.ps * (10000 - a.eps), 1e18 * 10000), 10000 - a.cut, 10000) - tStar;
        assert(den > 0);
        return den;
    }
}
