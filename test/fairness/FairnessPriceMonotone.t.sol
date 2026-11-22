// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.36;

import {FairnessHarness} from "./FairnessHarness.sol";

/// @title FairnessPriceMonotone
/// @notice Family F3, price monotonicity: on the same path shifted up, neither the lender nor the borrower ends worse off.
/// @notice Both runs take the same verbs; the higher one is marked at its own last print.
/// @dev The lender rows compare runs that settle by the same door: across the seizure-expiry boundary #933's ruling accepts a residual.
contract FairnessPriceMonotoneTest is FairnessHarness {
    function _shiftPair(Kind k, uint256 thetaBps, uint256[] memory path, uint256 upBps) internal returns (Outcome memory a, Outcome memory b) {
        (a, b) = _pairOf(_baseRun(k, thetaBps, path), _baseRun(k, thetaBps, _shifted(path, upBps)));
    }

    function _shift(uint256 i) internal pure returns (uint256) {
        if (i == 0) return 200;
        if (i == 1) return 500;
        return 1500;
    }

    /// @notice F3 for the lender, band off and recordless: a higher path never leaves it shorter at the end.
    function test_F3_HigherPath_LenderShortfallNeverRises() public {
        for (uint256 k; k < 2; ++k) {
            Kind kind = k == 0 ? Kind.BandOff : Kind.Recordless;
            for (uint256 i; i < 3; ++i) {
                (Outcome memory a, Outcome memory b) = _shiftPair(kind, 9000, _glide(10000, 4000, 100), _shift(i));
                assertEq(a.finalized, b.finalized, "fixture: both runs settle by the same door");
                assertLe(_shortfall(b, Mark.End), _shortfall(a, Mark.End), "F3: the higher path left the lender shorter");
            }
        }
    }

    /// @notice F3 for the band-on lender, both runs cranked from above the turning point of the remainder's book loss.
    function test_F3_HigherPath_BandOn_LenderShortfallNeverRisesAboveTheTurn() public {
        for (uint256 i; i < 3; ++i) {
            (Outcome memory a, Outcome memory b) = _shiftPair(Kind.BandOn, 6500, _flatAt(7600, 4), 200 + 300 * i);
            assertTrue(a.sold > 0 && b.sold > 0, "fixture: both runs are cranked");
            assertLe(_shortfall(b, Mark.End), _shortfall(a, Mark.End), "F3: the higher print left the band-on lender shorter");
        }
    }

    /// @notice #933's at-tenor residual is CLOSED band on: a cranked loan's remainder settles at the record, so neither run leaves the lender short.
    /// @notice Before, the remainder settled at the need and a lower print near the stop melted more debt, turning the product.
    function test_F3_BandOn_NearTheStop_NeitherRunLeavesTheLenderShort() public {
        (Outcome memory a, Outcome memory b) = _shiftPair(Kind.BandOn, 6500, _flatAt(7250, 4), 200);
        assertTrue(a.sold > 0 && b.sold > 0, "fixture: both runs are cranked");
        assertEq(_shortfall(a, Mark.End), 0, "the lower print leaves the band-on lender whole at the end");
        assertEq(_shortfall(b, Mark.End), 0, "and so does the higher one: the residual is closed");
    }

    /// @notice F3 for the borrower, band off and recordless: a higher path never leaves it worse off.
    function test_F3_HigherPath_BorrowerNeverWorse() public {
        for (uint256 k; k < 2; ++k) {
            Kind kind = k == 0 ? Kind.BandOff : Kind.Recordless;
            for (uint256 i; i < 3; ++i) {
                (Outcome memory a, Outcome memory b) = _shiftPair(kind, 9000, _glide(10000, 4000, 100), _shift(i));
                assertGe(_wealth(b), _wealth(a), "F3: the higher path left the borrower worse off");
            }
        }
    }

    /// forge-config: default.fuzz.runs = 64
    /// @notice F3 band off over any trigger, two prints and shift; the lender leg asserts where both runs settle by the same door.
    function testFuzz_F3_HigherPath_BandOff(uint256 thetaBps, uint256 p1, uint256 p2, uint256 upBps) public {
        thetaBps = bound(thetaBps, 3000, 9500);
        uint256[] memory path = new uint256[](2);
        (path[0], path[1]) = (bound(p1, 500, 15000), bound(p2, 500, 15000));
        (Outcome memory a, Outcome memory b) = _shiftPair(Kind.BandOff, thetaBps, path, bound(upBps, 1, 5000));
        assertGe(_wealth(b), _wealth(a), "F3: the higher path left the borrower worse off");
        if (a.finalized == b.finalized) assertLe(_shortfall(b, Mark.End), _shortfall(a, Mark.End), "F3: the higher path left the lender shorter");
    }

    /// @notice F3 for the band-on borrower across distress and the band: the higher print never leaves it worse off.
    function test_F3_HigherPath_BandOn_BorrowerNeverWorse() public {
        if (!FIXED_933) return;
        for (uint256 i; i < 2; ++i) {
            (Outcome memory a, Outcome memory b) = _distressOrBand(i == 0 ? 7300 : 7500);
            assertGe(_wealth(b), _wealth(a), "F3: the higher print left the borrower worse off");
        }
    }

    /// @dev A band-on loan at 65% of par: a print at 64% puts it in distress, one at `highBps` in the band above the stop.
    function _distressOrBand(uint256 highBps) internal returns (Outcome memory a, Outcome memory b) {
        (a, b) = _pairOf(_baseRun(Kind.BandOn, 6500, _dropTo(6400, 4)), _baseRun(Kind.BandOn, 6500, _dropTo(highBps, 4)));
    }
}
