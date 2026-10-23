// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.36;

import {Test} from "forge-std/Test.sol";
import {stdError} from "forge-std/StdError.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {PositionManager} from "../../src/ace/positions/PositionManager.sol";
import {AceFixtures} from "../utils/AceFixtures.sol";
import {LoanManagerStub} from "../utils/LoanManagerStub.sol";
import {MockERC20} from "../mocks/MockERC20.sol";

/// @title AceP6CarryInUnpairedCredit
/// @notice Audit PoC, run 2026-09-13-670568 phase 6 (C-14): `carryIn` credits a ledger that no custodian check ties to a debit.
/// @notice ACCEPTED: the pairing is the hub's, made in one call on both paths; `custodiedOf` never sees a carry.
/// @dev The custody identity invariant (`AceP10CustodyIdentity`) is what catches a pre-broadcast edit that unpairs one.
/// @dev Ruling: `the design record`.
contract AceP6CarryInUnpairedCreditTest is Test, LoanManagerStub {
    PositionManager internal pm;
    MockERC20 internal tokenX;

    address internal payer = address(0xBEEF);
    address internal bob = address(0xB0B);
    address internal dave = address(0xDA7E);

    uint256 internal constant UNITS = 100e18;

    uint256 internal constant LOAN_A = 1; // the retiring loan whose units are carried
    uint256 internal constant LOAN_B = 2; // the honest successor
    uint256 internal constant LOAN_C = 3; // the successor a replayed carry credits a second time
    uint256 internal constant LOAN_D = 4; // an innocent loan on the same collateral

    function setUp() public {
        tokenX = new MockERC20("Token X", "X", 18);
        pm = AceFixtures.plainEscrow(IERC20(address(tokenX)), address(this)); // this == LOAN_MANAGER
        _stubLoanConfig(address(tokenX), address(0));
        tokenX.mint(payer, 1_000_000e18);
        vm.prank(payer);
        tokenX.approve(address(pm), type(uint256).max);
    }

    /// @dev A and D funded; A closed and carried once, honestly, into B.
    function _pairedCarry() internal {
        pm.pull(LOAN_A, payer, UNITS);
        pm.pull(LOAN_D, payer, UNITS);
        pm.carryOut(LOAN_A, UNITS);
        _stubClosed(LOAN_A, true);
        pm.carryIn(LOAN_A, LOAN_B, UNITS);
    }

    /// @notice Positive control: the paired carry is admitted, so the rows below measure the replay, not a broken fixture.
    function test_carryIn_PairedCarryIsAdmitted() public {
        _pairedCarry();
        assertEq(pm.collateralOf(LOAN_B), UNITS, "the successor holds the carried units");
        assertEq(pm.custodiedOf(address(tokenX)), 2 * UNITS, "the aggregate is A's plus D's units");
    }

    /// @notice KNOWN: a second carry out of the same closed source, with no second debit, is ADMITTED at the credit.
    /// @dev `carryIn` checks only token equality and that the source is not a live loan. A pairing guard would turn this red.
    function test_Known_AReplayedCarryIsAdmitted() public {
        _pairedCarry();
        pm.carryIn(LOAN_A, LOAN_C, UNITS);
        assertEq(pm.collateralOf(LOAN_C), UNITS, "the replayed carry credited C with no debit behind it");
        assertEq(pm.custodiedOf(address(tokenX)), 2 * UNITS, "and the aggregate never saw it");
    }

    /// @notice GREEN measurement of the consequence: the unpaired credit is paid out of D's units, and D is the one refused.
    /// @dev The "later victim's exit" the aggregate rail prevents for a `pull` and, for a carry, only the hub's pairing does.
    function test_carryIn_UnpairedCreditIsPaidFromAnotherLoanAndTheVictimCannotExit() public {
        _pairedCarry();
        pm.carryIn(LOAN_A, LOAN_C, UNITS); // unpaired: nothing was debited for it
        assertEq(pm.custodiedOf(address(tokenX)), 2 * UNITS, "custodiedOf never saw the extra credit");

        pm.release(LOAN_B, bob, UNITS);
        pm.release(LOAN_C, bob, UNITS); // the balance check passes: custodiedOf and the pot fell together
        assertEq(tokenX.balanceOf(bob), 2 * UNITS, "B's and C's releases took the whole pot, D's units included");

        vm.expectRevert(stdError.arithmeticError);
        pm.release(LOAN_D, dave, UNITS);
        assertEq(pm.collateralOf(LOAN_D), UNITS, "D is still credited, and nothing is left to pay it");
    }
}
