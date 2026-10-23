// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.36;

import {FullMath} from "@uniswap/v4-core/src/libraries/FullMath.sol";
import {Constants} from "../Constants.sol";

/// @title LoanMath
/// @notice The pure loan-side formulas: the trigger price, the origination fee, and that fee's split.
/// @notice One home for the fee chain, so a repricing changes arithmetic here and nowhere else.
/// @dev All `internal` ON PURPOSE: no hot path pays a DELEGATECALL to price a trigger.
/// @dev The shares are READ here, never passed: there is exactly one, and a caller cannot supply a wrong one.
library LoanMath {
    /// @notice Triggerable price, in the market's own price frame; pure debt arithmetic, zero with no collateral.
    /// @dev THE trigger formula, one home. Trigger is WHEN, never at what price a fill happens.
    /// @dev Rounds UP: a higher trigger arms earlier, so rounding favours lenders, as `requiredAt` does.
    /// @dev ONE division, so exactly one truncation.
    function triggerPrice(uint256 debt, uint256 collateralUnits, uint256 minCoverageWad, uint256 unitScale) internal pure returns (uint256) {
        if (collateralUnits == 0) return 0;
        return FullMath.mulDivRoundingUp(minCoverageWad * debt, unitScale, collateralUnits * 1e18);
    }

    /// @notice The borrower's ALL-IN origination cost: the lender's rate with ACE's share charged on top.
    /// @notice Priced for `tenor`, normalized against the market's SHORTEST term.
    /// @notice `baseBps` is the LENDER's rate; the borrower pays it plus the protocol share.
    /// @dev ACE has no accrual, so duration is priced here explicitly, never off elapsed time.
    /// @dev ONE ceil, on the FUSED product, and that single rounding is what bounds the fee by the principal.
    /// @dev Ceiling the lender leg and flooring ACE's on top instead would overshoot the principal by a wei.
    function originationFee(uint256 principal, uint64 tenor, uint256 baseBps, uint64 minTenor) internal pure returns (uint256) {
        uint256 n = baseBps * uint256(tenor) * (10000 + Constants.PROTOCOL_SHARE_BPS);
        return FullMath.mulDivRoundingUp(principal, n, 10000 * 10000 * uint256(minTenor));
    }

    /// @notice ACE's slice, recovered from the fused all-in by the INVERSE ratio.
    /// @dev Floors, so the rounding residue lands on the LENDER and the protocol never over-takes.
    function protocolCut(uint256 fee) internal pure returns (uint256) {
        return (fee * Constants.PROTOCOL_SHARE_BPS) / (10000 + Constants.PROTOCOL_SHARE_BPS);
    }

    /// @notice What the lender side keeps, as the exact residue rather than a second product.
    /// @dev Subtraction, so the two floors cancel and the split closes to the wei.
    function lenderCut(uint256 fee) internal pure returns (uint256) {
        return fee - protocolCut(fee);
    }

    /// @notice The refundable half of the lender fee, held in escrow and earned down over the term.
    /// @dev Phi applies to the LENDER cut, never to the whole fee: ACE's slice is not refundable.
    function escrowCut(uint256 fee) internal pure returns (uint256) {
        return (lenderCut(fee) * Constants.REBATE_PHI_BPS) / 10000;
    }

    /// @notice What reaches the lender's pool at the draw, and is their money immediately.
    function tickCut(uint256 fee) internal pure returns (uint256) {
        return lenderCut(fee) - escrowCut(fee);
    }

    /// @notice The smallest draw whose payout still clears `owed`; the origination fee's inverse.
    /// @notice EXACT against `originationFee`: the derived draw's payout IS `owed`, never a wei over.
    /// @dev Rounds UP: down leaves the continuation a wei short of the old debt and every migration reverts.
    /// @dev The caller must hold `feeFundable`, or the denominator underflows.
    function principalForOwed(uint256 owed, uint64 tenor, uint256 baseBps, uint64 minTenor) internal pure returns (uint256) {
        uint256 d = 10000 * 10000 * uint256(minTenor);
        return FullMath.mulDivRoundingUp(owed, d, d - baseBps * uint256(tenor) * (10000 + Constants.PROTOCOL_SHARE_BPS));
    }

    /// @notice Whether a term's all-in fee stays inside `MAX_FEE_SHARE_BPS` of the draw it prices.
    /// @notice At maxTenor it bounds every shorter term too, because the fee is monotone in tenor.
    /// @notice THE rail the payout subtraction and the inverse both rest on, so genesis checks it once.
    /// @dev It bounds the PRODUCT of rate and term multiple; neither dial alone can bound the fee.
    /// @dev It implies `d - n > 0`, so `principalForOwed`'s no-underflow precondition holds by construction.
    function feeFundable(uint256 baseBps, uint64 tenor, uint64 minTenor) internal pure returns (bool) {
        return 10000 * baseBps * uint256(tenor) * (10000 + Constants.PROTOCOL_SHARE_BPS) <= Constants.MAX_FEE_SHARE_BPS * 10000 * 10000 * uint256(minTenor);
    }
}
