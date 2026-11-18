// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.36;

import {Test} from "forge-std/Test.sol";
import {InKindTerms, InKindTermsConfig, Listing, Row} from "../../src/entities/inkind/InKindTerms.sol";
import {MockERC20} from "../mocks/MockERC20.sol";

/// @title InKindRatePerYear
/// @notice An in-kind row's rate is bps a year, railed at the row's own `maxTenor` alone: 27,651 lists at 30 days and 27,652 does not.
/// @dev The terms bind no hub of their own: their vault's constructor is what probes the hub's rate period.
contract InKindRatePerYearTest is Test {
    bytes4 internal constant BAD_ROW = bytes4(keccak256("BadRow()"));
    address internal constant ITEM = address(0xC011);
    MockERC20 internal usdc;

    function setUp() public {
        usdc = new MockERC20("USD Coin", "USDC", 6);
    }

    function _cfg() internal view returns (InKindTermsConfig memory) {
        return InKindTermsConfig({
            vault: address(0xBEEF),
            asset: address(usdc),
            appraiser: vm.addr(0xA99A),
            minPrincipal: 10e6,
            coverageWad: 1.4e18,
            minTenor: 1 days,
            maxTenor: 30 days
        });
    }

    function _rowAt(uint256 rate, uint64 minTenor) internal pure returns (Listing[] memory l) {
        l = new Listing[](1);
        l[0] = Listing({collateral: ITEM, row: Row({lenderAprBps: uint16(rate), minTenor: minTenor, maxTenor: 30 days, maxPrincipal: 1e12})});
    }

    /// @notice THE EDGE IS THE 30-DAY CEILING'S, whatever the row's shortest term: a day or the whole month.
    function test_InKindRowRailsTheRateAtItsMaxTenor() public {
        uint64[2] memory shortest = [uint64(1 days), uint64(30 days)];
        for (uint256 i; i < shortest.length; ++i) {
            InKindTerms t = new InKindTerms(_cfg(), _rowAt(27_651, shortest[i]), "IK");
            assertEq(t.rowOf(ITEM).lenderAprBps, 27_651, "27,651 a year lists at a 30-day maxTenor");
            Listing[] memory over = _rowAt(27_652, shortest[i]);
            InKindTermsConfig memory c = _cfg();
            vm.expectRevert(BAD_ROW);
            new InKindTerms(c, over, "IK");
        }
    }

    /// @notice THE FLOOR IS 1 BP A YEAR: zero refuses, one lists.
    function test_InKindRowFloorIsOneBpAYear() public {
        assertEq(new InKindTerms(_cfg(), _rowAt(1, 1 days), "IK").rowOf(ITEM).lenderAprBps, 1, "one bp a year lists");
        Listing[] memory zero = _rowAt(0, 1 days);
        InKindTermsConfig memory c = _cfg();
        vm.expectRevert(BAD_ROW);
        new InKindTerms(c, zero, "IK");
    }
}
