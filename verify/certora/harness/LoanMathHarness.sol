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

    function originationFee(uint256 principal, uint64 tenor, uint256 lenderAprBps) external pure returns (uint256) {
        return LoanMath.originationFee(principal, tenor, lenderAprBps);
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

    function feeFundable(uint256 lenderAprBps, uint64 tenor) external pure returns (bool) {
        return LoanMath.feeFundable(lenderAprBps, tenor);
    }

    function originationFeeAt(uint256 principal, uint64 tenor, uint256 lenderAprBps, uint256 shareBps) external pure returns (uint256) {
        return LoanMath.originationFee(principal, tenor, lenderAprBps, shareBps);
    }

    function protocolCutAt(uint256 fee, uint256 shareBps) external pure returns (uint256) {
        return LoanMath.protocolCut(fee, shareBps);
    }

    function lenderCutAt(uint256 fee, uint256 shareBps) external pure returns (uint256) {
        return LoanMath.lenderCut(fee, shareBps);
    }

    function escrowCutAt(uint256 fee, uint256 shareBps) external pure returns (uint256) {
        return LoanMath.escrowCut(fee, shareBps);
    }

    function tickCutAt(uint256 fee, uint256 shareBps) external pure returns (uint256) {
        return LoanMath.tickCut(fee, shareBps);
    }
}
