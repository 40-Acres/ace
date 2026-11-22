// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.36;

import {FullMath} from "@uniswap/v4-core/src/libraries/FullMath.sol";
import {Constants} from "../Constants.sol";

/// @title LoanMath
/// @notice The pure loan-side formulas: the trigger price, the origination fee, and that fee's split.
/// @notice One home for the fee chain, so a repricing changes arithmetic here and nowhere else.
/// @dev All `internal` ON PURPOSE: no hot path pays a DELEGATECALL to price a trigger.
/// @dev The live share is a PARAMETER: this library compiles into off-hub contracts, where a storage read would read their own slot.
/// @dev Each share-less form prices the ceiling, `MAX_PROTOCOL_SHARE_BPS`: right for a rail, never for a charge.
library LoanMath {
    /// @notice Triggerable price, in the market's own price frame; pure debt arithmetic, zero with no collateral.
    /// @dev THE trigger formula, one home. Trigger is WHEN, never at what price a fill happens.
    /// @dev Rounds UP: a higher trigger arms earlier, so rounding favours lenders, as `requiredAt` does.
    /// @dev ONE division, so exactly one truncation.
    function triggerPrice(uint256 debt, uint256 collateralUnits, uint256 minCoverageWad, uint256 unitScale) internal pure returns (uint256) {
        if (collateralUnits == 0) return 0;
        return FullMath.mulDivRoundingUp(minCoverageWad * debt, unitScale, collateralUnits * 1e18);
    }

    /// @notice The borrower's ALL-IN origination cost: the lender's rate with ACE's share `shareBps` charged on top.
    /// @notice Priced for `tenor` at `lenderAprBps`, bps per `SECONDS_PER_YEAR`; no market's term range enters it.
    /// @notice It never falls as the share rises, so a fee priced at the ceiling bounds the fee at every share.
    /// @dev ACE has no accrual: duration is priced here explicitly, a term booked up front or the time an extension adds.
    /// @dev ONE ceil, on the FUSED product, and that single rounding is what bounds the fee by the principal.
    /// @dev Ceiling the lender leg and flooring ACE's on top instead would overshoot the principal by a wei.
    function originationFee(uint256 principal, uint64 tenor, uint256 lenderAprBps, uint256 shareBps) internal pure returns (uint256) {
        uint256 n = lenderAprBps * uint256(tenor) * (10000 + shareBps);
        return FullMath.mulDivRoundingUp(principal, n, 10000 * 10000 * Constants.SECONDS_PER_YEAR);
    }

    /// @notice The all-in fee at the ceiling share: what a rail bounds, and what a hub without a share view charged.
    function originationFee(uint256 principal, uint64 tenor, uint256 lenderAprBps) internal pure returns (uint256) {
        return originationFee(principal, tenor, lenderAprBps, Constants.MAX_PROTOCOL_SHARE_BPS);
    }

    /// @notice ACE's slice, recovered from the fused all-in by the INVERSE ratio; zero at a zero share.
    /// @dev Floors, so the rounding residue lands on the LENDER and the protocol never over-takes.
    function protocolCut(uint256 fee, uint256 shareBps) internal pure returns (uint256) {
        return (fee * shareBps) / (10000 + shareBps);
    }

    /// @notice ACE's slice at the ceiling share.
    function protocolCut(uint256 fee) internal pure returns (uint256) {
        return protocolCut(fee, Constants.MAX_PROTOCOL_SHARE_BPS);
    }

    /// @notice What the lender side keeps, as the exact residue rather than a second product.
    /// @dev Subtraction, so the two floors cancel and the split closes to the wei.
    function lenderCut(uint256 fee, uint256 shareBps) internal pure returns (uint256) {
        return fee - protocolCut(fee, shareBps);
    }

    /// @notice The lender side at the ceiling share.
    function lenderCut(uint256 fee) internal pure returns (uint256) {
        return lenderCut(fee, Constants.MAX_PROTOCOL_SHARE_BPS);
    }

    /// @notice The refundable half of the lender fee, held in escrow and earned down over the term.
    /// @dev Phi applies to the LENDER cut, never to the whole fee: ACE's slice is not refundable.
    function escrowCut(uint256 fee, uint256 shareBps) internal pure returns (uint256) {
        return (lenderCut(fee, shareBps) * Constants.REBATE_PHI_BPS) / 10000;
    }

    /// @notice The escrow cut at the ceiling share.
    function escrowCut(uint256 fee) internal pure returns (uint256) {
        return escrowCut(fee, Constants.MAX_PROTOCOL_SHARE_BPS);
    }

    /// @notice What reaches the lender's pool at the draw, and is their money immediately.
    function tickCut(uint256 fee, uint256 shareBps) internal pure returns (uint256) {
        return lenderCut(fee, shareBps) - escrowCut(fee, shareBps);
    }

    /// @notice The tick cut at the ceiling share.
    function tickCut(uint256 fee) internal pure returns (uint256) {
        return tickCut(fee, Constants.MAX_PROTOCOL_SHARE_BPS);
    }

    /// @notice Whether a `tenor` priced at `lenderAprBps` keeps its all-in fee inside `MAX_FEE_SHARE_BPS` of the draw, at the ceiling share.
    /// @notice At maxTenor it bounds every shorter term too, because the fee is monotone in tenor; at the ceiling it bounds every share.
    /// @notice THE rail the payout subtraction rests on, so genesis checks it once.
    /// @dev It bounds the PRODUCT of rate and term; neither dial alone can bound the fee.
    /// @dev Division form, exact for integers: `r <= floor(A / B)` iff `r * B <= A`, and it never multiplies the rate, so no rate panics.
    function feeFundable(uint256 lenderAprBps, uint64 tenor) internal pure returns (bool) {
        if (tenor == 0) return false;
        return lenderAprBps <= Constants.MAX_FEE_SHARE_BPS * 10000 * Constants.SECONDS_PER_YEAR / (uint256(tenor) * (10000 + Constants.MAX_PROTOCOL_SHARE_BPS));
    }

    /// @notice The live debt floor: no repay leaves a live loan under it, and a crank that would closes the loan.
    /// @dev Half the smallest loan, rounded DOWN, so a loan born at `minPrincipal` always holds at least twice it.
    function debtFloor(uint256 minPrincipal) internal pure returns (uint256) {
        return minPrincipal / 2;
    }
}
