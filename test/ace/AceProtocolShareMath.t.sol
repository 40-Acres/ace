// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.36;

import {Test} from "forge-std/Test.sol";
import {LoanMath} from "../../src/ace/hub/libraries/LoanMath.sol";
import {AllInFeeSpec} from "../utils/AllInFeeSpec.sol";

/// @title AceProtocolShareMath
/// @notice The fee chain at any share in [0, 1000]: what a stored, settable share must keep true of the arithmetic.
/// @dev The spec takes the share as a parameter and never reads `src`, so each row compares the code to the record.
contract AceProtocolShareMathTest is Test {
    uint256 internal constant MAX = 1000; // re-spelled ceiling

    struct In {
        uint256 principal;
        uint64 tenor;
        uint256 rate;
    }

    function _in(uint256 p, uint256 t, uint256 r) internal pure returns (In memory x) {
        x.principal = bound(p, 1, 1e24);
        x.tenor = uint64(bound(t, 1, 10 * 365 days));
        x.rate = bound(r, 1, 100_000);
    }

    /// @notice Every share prices the fee and its split exactly as the record does.
    function testFuzz_TheShareFormsAreTheSpecAtEveryShare(uint256 p, uint256 t, uint256 r, uint256 s) public pure {
        In memory x = _in(p, t, r);
        s = bound(s, 0, MAX);
        uint256 fee = LoanMath.originationFee(x.principal, x.tenor, x.rate, s);
        assertEq(fee, AllInFeeSpec.feeAllIn(x.principal, x.tenor, x.rate, s), "fee");
        assertEq(LoanMath.protocolCut(fee, s), AllInFeeSpec.protocolFee(fee, s), "protocol cut");
        assertEq(LoanMath.lenderCut(fee, s), AllInFeeSpec.lenderFee(fee, s), "lender cut");
        assertEq(LoanMath.escrowCut(fee, s), AllInFeeSpec.feeEscrow(fee, s), "escrow cut");
        assertEq(LoanMath.tickCut(fee, s), AllInFeeSpec.tickFee(fee, s), "tick cut");
    }

    /// @notice The split closes to the wei at every share, zero included.
    function testFuzz_TheSplitClosesAtEveryShare(uint256 fee, uint256 s) public pure {
        fee = bound(fee, 0, 1e30);
        s = bound(s, 0, MAX);
        assertEq(LoanMath.protocolCut(fee, s) + LoanMath.escrowCut(fee, s) + LoanMath.tickCut(fee, s), fee, "split closes");
        assertLe(LoanMath.protocolCut(fee, s) * 10000, LoanMath.lenderCut(fee, s) * s, "the protocol never out-takes its share");
    }

    /// @notice A zero share takes nothing, and the whole fee is the lender's.
    function testFuzz_AZeroShareTakesNothing(uint256 fee) public pure {
        fee = bound(fee, 0, 1e30);
        assertEq(LoanMath.protocolCut(fee, 0), 0, "nothing to the protocol");
        assertEq(LoanMath.lenderCut(fee, 0), fee, "all of it to the lender");
    }

    /// @notice The fee never falls as the share rises, so every genesis rail checked at the ceiling bounds every live fee.
    function testFuzz_TheFeeNeverFallsAsTheShareRises(uint256 p, uint256 t, uint256 r, uint256 s1, uint256 s2) public pure {
        In memory x = _in(p, t, r);
        s1 = bound(s1, 0, MAX);
        s2 = bound(s2, s1, MAX);
        uint256 lo = LoanMath.originationFee(x.principal, x.tenor, x.rate, s1);
        uint256 hi = LoanMath.originationFee(x.principal, x.tenor, x.rate, s2);
        assertLe(lo, hi, "monotone in the share");
        assertLe(hi, LoanMath.originationFee(x.principal, x.tenor, x.rate), "and bounded by the ceiling form");
    }

    /// @notice The share moves only what the borrower pays and the protocol earns: the lender's cut is the same at every share, within a wei.
    function testFuzz_TheLenderCutIsTheSameAtEveryShare(uint256 p, uint256 t, uint256 r, uint256 s) public pure {
        In memory x = _in(p, t, r);
        s = bound(s, 0, MAX);
        uint256 base = LoanMath.originationFee(x.principal, x.tenor, x.rate, 0);
        uint256 lender = LoanMath.lenderCut(LoanMath.originationFee(x.principal, x.tenor, x.rate, s), s);
        assertGe(lender, base, "the lender never earns less than at a zero share");
        assertLe(lender, base + 1, "and never more than a wei over it");
    }

    /// @notice The share-less forms are the ceiling, exactly: they stay correct for every rail that checks at it.
    function testFuzz_TheCeilingFormsAreTheShareFormsAtTheCeiling(uint256 p, uint256 t, uint256 r) public pure {
        In memory x = _in(p, t, r);
        uint256 fee = LoanMath.originationFee(x.principal, x.tenor, x.rate);
        assertEq(fee, LoanMath.originationFee(x.principal, x.tenor, x.rate, MAX), "fee at the ceiling");
        assertEq(LoanMath.protocolCut(fee), LoanMath.protocolCut(fee, MAX), "protocol cut at the ceiling");
        assertEq(LoanMath.escrowCut(fee), LoanMath.escrowCut(fee, MAX), "escrow cut at the ceiling");
        assertEq(LoanMath.tickCut(fee), LoanMath.tickCut(fee, MAX), "tick cut at the ceiling");
    }
}
