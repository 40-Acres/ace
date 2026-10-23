// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.36;

import {Test} from "forge-std/Test.sol";
import {LoanAccounting} from "../../src/ace/hub/libraries/LoanAccounting.sol";
import {Constants} from "../../src/ace/hub/Constants.sol";
import {Cfg, LoanBook, Market} from "../../src/ace/hub/Types.sol";

/// @title AceZeroFloorGuards
/// @notice The zero-funding-floor guards inside the settlement fold, pinned as ARITHMETIC.
/// @notice They are fail-closed defence for a state the entry rails make unconstructible: a live loan
/// @notice funds no tick only at a zero principal, and a zero principal needs a zero market quantum.
/// @notice Both doors are now shut, so no hub verb can stage the state end to end any more.
/// @dev WHY THIS SUITE EXISTS. The guards are DIVISION guards, not policy: `sliverUnits` divides by the
/// @dev floor to convert a debt-sized bounty into units, so deleting the zero leg turns a total function
/// @dev into one that panics. "Unreachable" and "deletable" are different properties, and a guard with no
/// @dev test is how a later size pass talks itself into dropping one. This suite gives it a live hit.
/// @dev The storage structs are declared here directly: `sliverUnits` is internal and reads three fields,
/// @dev so it inlines with no link edge, no market, no ladder and no deployment.
contract AceZeroFloorGuardsTest is Test {
    LoanBook internal B;
    Market internal M;

    uint256 internal constant DEBT = 4_500e6;
    uint256 internal constant UNITS = 10_000e18;
    uint256 internal constant UNIT_SCALE = 1 << 96; // every market's scale under the atom frame
    uint256 internal constant ID = 1;

    function setUp() public {
        B.loans[ID].debt = DEBT;
    }

    /// @dev THE FLOOR IS DERIVED NOW, so `price` lives on the CONFIG rather than in a per-loan mapping:
    /// @dev `fundingFloor(M, c, id)` is `M.claim[id] == 0 ? 0 : c.p.price`. The two things a row sets are
    /// @dev therefore the market's price and whether the loan holds a claim -- and the claim IS the flag.
    function _cfg(uint256 price) internal pure returns (Cfg memory c) {
        c.p.settleBountyBps = Constants.MAX_SETTLE_BOUNTY_BPS; // the widest sliver a creator may promise
        c.p.price = price;
        c.unitScale = UNIT_SCALE;
    }

    /// @notice THE GUARD: a loan whose draw funded nothing pays a ZERO sliver rather than dividing by zero.
    /// @notice That is the right answer as well as a total one -- there is no floor to convert the bounty at.
    /// @dev THE ZERO IS REACHED DIFFERENTLY: it was a zero in the per-loan floor mapping, and it is a RETIRED
    /// @dev CLAIM now, which is the same state said once instead of twice. A market's own price is never zero.
    function test_SliverUnits_AZeroFundingFloorPaysNothing_RatherThanDividing() public view {
        assertEq(M.claim[ID], 0, "fixture: the loan holds no claim, so it carries no funding floor");
        assertEq(LoanAccounting.sliverUnits(B, M, _cfg(1e18), ID, UNITS), 0, "no floor, no sliver, no division");
    }

    /// @notice The non-vacuous control: with a real floor the same call pays a real, correctly sized sliver.
    /// @dev Without this row the test above would pass just as well against a function that always returns 0.
    function test_SliverUnits_ARealFloorPaysTheDebtSizedSliver() public {
        M.claim[ID] = DEBT; // the claim IS the funded flag, so this is what lifts the floor off zero
        uint256 expected = (DEBT * Constants.MAX_SETTLE_BOUNTY_BPS * UNIT_SCALE) / (10000 * 1e18);
        assertGt(expected, 0, "fixture: the derived expectation is a real payment");
        assertEq(LoanAccounting.sliverUnits(B, M, _cfg(1e18), ID, UNITS), expected, "the sliver is sized off DEBT, converted at the floor");
    }

    /// @notice And the sliver is clamped to the position: a bounty wider than the collateral takes the lot.
    /// @dev The clamp is what keeps the fold total from the OTHER side, at a floor so low the bounty explodes.
    function test_SliverUnits_ClampsToTheAvailableUnits() public {
        M.claim[ID] = DEBT;
        assertEq(LoanAccounting.sliverUnits(B, M, _cfg(1), ID, UNITS), UNITS, "the sliver never exceeds what the loan holds");
    }

    /// @notice A retired claim stays zero at every position size, so the guard never leaks through the clamp.
    function testFuzz_SliverUnits_AZeroFloorPaysNothingAtEveryPositionSize(uint256 units) public view {
        assertEq(LoanAccounting.sliverUnits(B, M, _cfg(1e18), ID, units), 0, "the zero leg answers before the clamp does");
    }
}
