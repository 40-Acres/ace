// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.36;

/// @title AllInFeeSpec
/// @notice The borrower-side origination chain as integer arithmetic, written from the decision record.
/// @dev Re-spelled on purpose: a test that called `LoanMath` would compare the code to itself.
/// @dev `ps` is a parameter, so a sweep can price shares the shipped constant does not take.
/// @dev Plain multiplication, never FullMath: every caller bounds its fuzz so the products cannot overflow.
library AllInFeeSpec {
    uint256 internal constant PHI_BPS = 5000; // the shipped rebate share, re-spelled rather than imported
    uint256 internal constant FEE_SHARE_BPS = 2500; // the fee ceiling, re-spelled too: a spec that imports proves nothing

    /// @notice The borrower's ALL-IN cost: the lender's rate with the protocol's share charged on top.
    /// @dev ONE ceil, taken on the fused product, and that is what bounds the fee by the principal.
    function feeAllIn(uint256 principal, uint64 tenor, uint256 baseBps, uint64 minTenor, uint256 ps) internal pure returns (uint256) {
        uint256 n = baseBps * uint256(tenor) * (10000 + ps);
        uint256 d = 10000 * 10000 * uint256(minTenor);
        return (principal * n + d - 1) / d;
    }

    /// @notice ACE's slice, recovered from the fused all-in by the INVERSE ratio.
    /// @dev Floors, so the residue lands on the LENDER and the protocol can never over-take.
    function protocolFee(uint256 allIn, uint256 ps) internal pure returns (uint256) {
        return (allIn * ps) / (10000 + ps);
    }

    /// @notice What the lender side keeps: the exact residue, so the two floors cancel identically.
    function lenderFee(uint256 allIn, uint256 ps) internal pure returns (uint256) {
        return allIn - protocolFee(allIn, ps);
    }

    /// @notice The refundable half: phi of the LENDER fee, never of the all-in.
    function feeEscrow(uint256 allIn, uint256 ps) internal pure returns (uint256) {
        return (lenderFee(allIn, ps) * PHI_BPS) / 10000;
    }

    /// @notice What reaches the funding ticks' qIndexes at the draw, and is lender money immediately.
    function tickFee(uint256 allIn, uint256 ps) internal pure returns (uint256) {
        return lenderFee(allIn, ps) - feeEscrow(allIn, ps);
    }

    /// @notice The payout the borrower actually receives.
    function payout(uint256 principal, uint64 tenor, uint256 baseBps, uint64 minTenor, uint256 ps) internal pure returns (uint256) {
        return principal - feeAllIn(principal, tenor, baseBps, minTenor, ps);
    }

    /// @notice The inverse: the smallest draw whose payout still clears `owed`.
    /// @dev Ceils, because a floor leaves the continuation a wei short and every migration reverts.
    function principalForOwed(uint256 owed, uint64 tenor, uint256 baseBps, uint64 minTenor, uint256 ps) internal pure returns (uint256) {
        uint256 n = baseBps * uint256(tenor) * (10000 + ps);
        uint256 d = 10000 * 10000 * uint256(minTenor);
        return (owed * d + (d - n) - 1) / (d - n);
    }

    /// @notice The genesis rail: the all-in fee at this term takes at most `FEE_SHARE_BPS` of the draw.
    /// @notice Bounding at maxTenor bounds every rung under it, because the fee is monotone in tenor.
    /// @dev NOT strict, unlike the bound it replaced. A SHARE cap admits exactly its own bound.
    /// @dev The old rail was strict only because it existed to keep the inverse's denominator off zero.
    function fundable(uint256 baseBps, uint64 tenor, uint64 minTenor, uint256 ps) internal pure returns (bool) {
        return 10000 * baseBps * uint256(tenor) * (10000 + ps) <= FEE_SHARE_BPS * 10000 * 10000 * uint256(minTenor);
    }

    /// @notice The rail's slack `D' - N'`, which is QUANTISED at 1000 and therefore never 1.
    /// @dev Only meaningful on a market the rail admits; below it this underflows, which is the point.
    function slack(uint256 baseBps, uint64 tenor, uint64 minTenor, uint256 ps) internal pure returns (uint256) {
        return 10000 * 10000 * uint256(minTenor) - baseBps * uint256(tenor) * (10000 + ps);
    }
}
