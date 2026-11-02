// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.36;

import {FullMath} from "@uniswap/v4-core/src/libraries/FullMath.sol";
import {Constants} from "../../src/ace/hub/Constants.sol";

/// @title RefinanceMath
/// @notice The origination fee's inverse, for tests that size a `refinanceTo` retiring a given debt.
/// @dev The hub's `LoanMath.principalForOwed` moved here, body unchanged, once no `src` code called it.
library RefinanceMath {
    /// @notice The smallest draw whose payout still clears `owed`: EXACT against `LoanMath.originationFee`, never a wei over.
    /// @dev Rounds UP; the caller must hold `LoanMath.feeFundable`, or the denominator underflows.
    function principalForOwed(uint256 owed, uint64 tenor, uint256 baseBps, uint64 minTenor) internal pure returns (uint256) {
        uint256 d = 10000 * 10000 * uint256(minTenor);
        return FullMath.mulDivRoundingUp(owed, d, d - baseBps * uint256(tenor) * (10000 + Constants.PROTOCOL_SHARE_BPS));
    }
}
