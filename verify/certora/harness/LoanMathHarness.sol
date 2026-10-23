// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.36;

import {LoanMath} from "../../../src/ace/hub/libraries/LoanMath.sol";

/// @title LoanMathHarness
/// @notice LoanMath's internal pure functions, exposed one for one so a spec can call them.
/// @dev Each body is a single call: nothing here computes anything LoanMath does not.
contract LoanMathHarness {
    function triggerPrice(uint256 debt, uint256 units, uint256 minCoverageWad, uint256 unitScale) external pure returns (uint256) {
        return LoanMath.triggerPrice(debt, units, minCoverageWad, unitScale);
    }

    function originationFee(uint256 principal, uint64 tenor, uint256 baseBps, uint64 minTenor) external pure returns (uint256) {
        return LoanMath.originationFee(principal, tenor, baseBps, minTenor);
    }

    function protocolCut(uint256 fee) external pure returns (uint256) {
        return LoanMath.protocolCut(fee);
    }

    function lenderCut(uint256 fee) external pure returns (uint256) {
        return LoanMath.lenderCut(fee);
    }

    function escrowCut(uint256 fee) external pure returns (uint256) {
        return LoanMath.escrowCut(fee);
    }

    function tickCut(uint256 fee) external pure returns (uint256) {
        return LoanMath.tickCut(fee);
    }

    function principalForOwed(uint256 owed, uint64 tenor, uint256 baseBps, uint64 minTenor) external pure returns (uint256) {
        return LoanMath.principalForOwed(owed, tenor, baseBps, minTenor);
    }

    function feeFundable(uint256 baseBps, uint64 tenor, uint64 minTenor) external pure returns (bool) {
        return LoanMath.feeFundable(baseBps, tenor, minTenor);
    }
}
