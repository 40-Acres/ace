// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.36;

import {FullMath} from "@uniswap/v4-core/src/libraries/FullMath.sol";

/// @title The search-shaped twin of DeleverageSizingSMT, for medusa (#353, #355).
/// @notice Same obligation, different SHAPE, because the two engines consume a precondition differently.
/// @notice CHC takes a `require` as a free assumption and reasons backwards from it; a fuzzer must HIT it forwards.
/// @notice Eight narrow `require`s over full-width uint256 draws is a filter random search never clears.
/// @notice So this twin CONSTRUCTS every parameter into the admitted domain instead of rejecting outside it.
/// @dev A green run here is evidence within the budget, never a theorem -- that is the whole difference.
/// @dev CHECK THE LCOV REPORT BEFORE BELIEVING A GREEN. If the tail below is uncovered the run was vacuous.
/// @dev The two feasibility rails stay as `require`: they hold over much of the box, so they filter rather than block.
contract DeleverageSizingFuzz {
    uint256 internal constant MIN_COVERAGE_WAD = 1.05e18;
    uint256 internal constant MAX_COVERAGE_WAD = 20e18;
    uint256 internal constant MAX_PRICE = 1e44; // modelling bound on ps, NOT a shipped rail; see the SMT twin

    uint256 public lastDen; // written so the sizing tail cannot be optimized away as dead
    uint256 public reached; // draws that cleared every gate and computed a denominator

    /// @notice Constructs an admitted config from raw draws, then computes the denominator that must be POSITIVE.
    /// @dev Every `%` here is a DOMAIN CONSTRUCTION, and each one narrows what a green covers -- see the header.
    /// @dev band stops at 9998 so `target` has room above it below 10000; at 9999 the admitted set is empty.
    /// @dev `medusa.json` fails on assertion, underflow AND divide-by-zero, so the `assert` below is caught.
    function fuzz_DenominatorIsStrictlyPositive(
        uint256 kSeed,
        uint256 epsSeed,
        uint256 cutSeed,
        uint256 bandSeed,
        uint256 targetSeed,
        uint256 stopSeed,
        uint256 psSeed,
        uint256 trigSeed
    ) public {
        uint256 k = MIN_COVERAGE_WAD + (kSeed % (MAX_COVERAGE_WAD - MIN_COVERAGE_WAD + 1));
        uint256 eps = 1 + (epsSeed % 200);
        uint256 cut = cutSeed % 2001;
        uint256 band = 3000 + (bandSeed % 6999);
        uint256 target = band + 1 + (targetSeed % (9999 - band));
        uint256 stop = 1 + (stopSeed % (band - 1));

        uint256 feasible = (k * (10000 - eps) / 10000) * (10000 - cut) / 10000;
        require(feasible + target * 1e14 > 1e18, "denominator rail");
        require(stop * 1e14 + feasible > 1e18, "sell-max rail");

        uint256 ps = 1 + (psSeed % MAX_PRICE);
        uint256 tStar = (ps * (1e18 - target * 1e14)) / 1e18;
        /// @dev The STRICT ceiled gate inverted for `trig`: `ps > ceil(trig*1e18/d)` iff `trig <= (ps-1)*d/1e18`.
        uint256 d = 1e18 - stop * 1e14;
        uint256 ceiling = ((ps - 1) * d) / 1e18; // was `(ps*d)/1e18`, the weak form the strict gate excludes
        if (ceiling <= tStar) return; // no admitted trigger in this draw: the sizing would return 0
        uint256 trig = tStar + 1 + (trigSeed % (ceiling - tStar));

        lastDen = FullMath.mulDiv(FullMath.mulDiv(k, ps * (10000 - eps), 1e18 * 10000), 10000 - cut, 10000) - tStar;
        assert(lastDen > 0);
        unchecked {
            reached++;
        }
        trig; // bound above; kept so the admitted-trigger construction reads at the call site
    }
}
