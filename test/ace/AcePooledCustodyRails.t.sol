// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.36;

import {Test} from "forge-std/Test.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {PositionManager} from "../../src/ace/positions/PositionManager.sol";
import {AceFixtures} from "../utils/AceFixtures.sol";
import {LoanManagerStub} from "../utils/LoanManagerStub.sol";
import {MockERC20} from "../mocks/MockERC20.sol";
import {MockBurnableERC20} from "../mocks/MockBurnableERC20.sol";

/// @title AcePooledCustodyRails
/// @notice The rails that replace what the per-loan clone used to enforce structurally.
/// @notice Driven directly against the custodian with this contract as LOAN_MANAGER, no hub in the way.
/// @dev Under clones a cross-collateral carry was IMPOSSIBLE: tokens had to physically move, and the
/// @dev destination vault refused a token it did not hold. Deleting the clone deleted that guard, so
/// @dev `carryIn` has to check what the clone used to check, and this file is what proves it does.
/// @dev The aggregate rail is the other half: a per-loan ledger over-credit used to hurt only that loan.
/// @dev Pooled it takes someone else's units, so a `pull` over-credit must revert WHERE IT HAPPENS.
/// @dev A carry is outside that rail: its pairing is the hub's (`the design record`).
contract AcePooledCustodyRailsTest is Test, LoanManagerStub {
    PositionManager internal pm;
    MockERC20 internal tokenX; // the collateral loan A is funded in
    MockERC20 internal tokenY; // a DIFFERENT collateral, for loan B
    MockBurnableERC20 internal burnable; // the banned class: a holder balance that can fall on its own

    address internal alice = address(0xA11CE);
    address internal bob = address(0xB0B);
    address internal donor = address(0xD0405);
    address internal payer = address(0xBEEF);

    uint256 internal constant A_UNITS = 100e18;
    uint256 internal constant B_UNITS = 40e18;
    uint256 internal constant DONATION = 7e18;

    uint256 internal constant LOAN_A = 1;
    uint256 internal constant LOAN_B = 2;

    function setUp() public {
        tokenX = new MockERC20("Token X", "X", 18);
        tokenY = new MockERC20("Token Y", "Y", 18);
        burnable = new MockBurnableERC20("Burnable", "BRN", 18);
        pm = AceFixtures.plainEscrow(IERC20(address(tokenX)), address(this)); // this == LOAN_MANAGER
        _stubLoanConfig(address(tokenX), address(0)); // the default pair every unnamed id resolves to

        tokenX.mint(payer, 1_000_000e18);
        tokenY.mint(payer, 1_000_000e18);
        burnable.mint(payer, 1_000_000e18);
        vm.startPrank(payer);
        tokenX.approve(address(pm), type(uint256).max);
        tokenY.approve(address(pm), type(uint256).max);
        burnable.approve(address(pm), type(uint256).max);
        vm.stopPrank();

        vm.label(address(pm), "PositionManager");
    }

    // ---- the collateral handshake `carryIn` has to make for itself ----

    /// @notice THE REGRESSION THIS WHOLE RAIL EXISTS FOR: a carry between two DIFFERENT collaterals.
    /// @dev Without the check, loan B's ledger claims X units while `release(B)` sends Y, draining every
    /// @dev other Y loan, and the X units sit in the pot counted by nobody.
    /// @dev `carryIn` is the ONE two-loan verb, so it is the one place two independent config reads exist.
    function testRevert_carryCustody_CrossCollateral() public {
        _stubLoanConfigFor(LOAN_A, address(tokenX), address(0));
        _stubLoanConfigFor(LOAN_B, address(tokenY), address(0));
        pm.pull(LOAN_A, payer, A_UNITS);
        pm.pull(LOAN_B, payer, B_UNITS);
        pm.carryOut(LOAN_A, A_UNITS);
        _stubClosed(LOAN_A, true);

        vm.expectRevert(PositionManager.CollateralMismatch.selector);
        pm.carryIn(LOAN_A, LOAN_B, A_UNITS);

        assertEq(pm.collateralOf(LOAN_B), B_UNITS, "B is still credited only its own Y units");
        assertEq(pm.custodiedOf(address(tokenY)), B_UNITS, "and the Y aggregate never grew by X units");
    }

    /// @notice The mismatch is refused in BOTH directions, so the check is on inequality and not on an order.
    function testRevert_carryCustody_CrossCollateral_OtherDirection() public {
        _stubLoanConfigFor(LOAN_A, address(tokenY), address(0));
        _stubLoanConfigFor(LOAN_B, address(tokenX), address(0));
        pm.pull(LOAN_A, payer, B_UNITS);
        pm.carryOut(LOAN_A, B_UNITS);
        _stubClosed(LOAN_A, true);

        vm.expectRevert(PositionManager.CollateralMismatch.selector);
        pm.carryIn(LOAN_A, LOAN_B, B_UNITS);
    }

    /// @notice A matching pair is admitted, so the guard refuses the mismatch and nothing else.
    /// @dev Without this the two rows above would pass against a `carryIn` that reverted unconditionally.
    function test_carryCustody_SameCollateral_IsAdmitted() public {
        pm.pull(LOAN_A, payer, A_UNITS);
        pm.carryOut(LOAN_A, A_UNITS);
        _stubClosed(LOAN_A, true);

        pm.carryIn(LOAN_A, LOAN_B, A_UNITS);

        assertEq(pm.collateralOf(LOAN_A), 0, "the source gave up its whole credit");
        assertEq(pm.collateralOf(LOAN_B), A_UNITS, "and the successor took it");
    }

    /// @notice Custody may only be carried out of a loan the hub has ALREADY closed.
    /// @dev Satisfiable by construction: `_closeForRefinance` sets `closed` before the successor opens.
    /// @dev It makes carrying a LIVE loan's collateral permanently impossible, not merely unreachable today.
    function testRevert_carryCustody_FromLiveLoan() public {
        pm.pull(LOAN_A, payer, A_UNITS);
        pm.carryOut(LOAN_A, A_UNITS);
        // the stub leaves LOAN_A live, which is exactly the state the hub never produces here

        vm.expectRevert(PositionManager.CarryFromLiveLoan.selector);
        pm.carryIn(LOAN_A, LOAN_B, A_UNITS);

        assertEq(pm.collateralOf(LOAN_B), 0, "nothing was credited to the successor");
    }

    // ---- `custodiedOf` as a RUNTIME rail, not a fuzz target ----

    /// @notice A pull onto a short pot reverts: a standing shortfall refuses new credit, not only releases.
    /// @dev The pot is made short by an external burn, which is the reachable way to break I-A.
    /// @dev The refused pull is innocent: the halt is token-wide, and a stranger's release reverts too (rows below).
    function testRevert_pull_OverCreditTripsCustodyUnderfunded() public {
        _stubLoanConfig(address(burnable), address(0));
        pm.pull(LOAN_A, payer, A_UNITS);
        burnable.burn(address(pm), 60e18); // the pot now holds 40 against a ledger claiming 100

        vm.expectRevert(PositionManager.CustodyUnderfunded.selector);
        pm.pull(LOAN_B, payer, 10e18);

        assertEq(pm.collateralOf(LOAN_B), 0, "the second loan was never credited");
        assertEq(pm.custodiedOf(address(burnable)), A_UNITS, "and the aggregate did not grow past the pot");
    }

    /// @notice A healthy pull into a pot that already carries another loan is admitted unchanged.
    /// @dev Pins that the rail is a solvency check and not a one-loan-per-token restriction.
    function test_pull_SecondLoanOnAFundedPot_IsAdmitted() public {
        pm.pull(LOAN_A, payer, A_UNITS);
        pm.pull(LOAN_B, payer, B_UNITS);

        assertEq(pm.custodiedOf(address(tokenX)), A_UNITS + B_UNITS, "the aggregate is the sum of both");
        assertEq(pm.custodiedOf(address(tokenX)), tokenX.balanceOf(address(pm)), "and the pot funds it exactly");
    }

    /// @notice `retireCustody` and the carry move value between LEDGER KEYS, so the aggregate cannot move.
    /// @dev That invariance is why both verbs are free under the rail; a carry cannot under-fund the pot only while it is paired.
    /// @dev Asserted bit-identical, which is the only form that would catch a stray `custodiedOf` write.
    function test_custodyAggregate_InvariantAcrossRetireAndCarry() public {
        pm.pull(LOAN_A, payer, A_UNITS);
        pm.pull(LOAN_B, payer, B_UNITS);
        uint256 aggregate = pm.custodiedOf(address(tokenX));
        uint256 pot = tokenX.balanceOf(address(pm));

        pm.retireCustody(LOAN_A, A_UNITS);
        assertEq(pm.custodiedOf(address(tokenX)), aggregate, "retireCustody moved the aggregate");
        assertEq(tokenX.balanceOf(address(pm)), pot, "and it moved a token");
        assertEq(pm.retiredOf(LOAN_A), A_UNITS, "the units are on A's retired ledger");

        _stubClosed(LOAN_B, true);
        pm.carryOut(LOAN_B, B_UNITS);
        assertEq(pm.custodiedOf(address(tokenX)), aggregate, "carryOut moved the aggregate");
        pm.carryIn(LOAN_B, 3, B_UNITS);
        assertEq(pm.custodiedOf(address(tokenX)), aggregate, "carryIn moved the aggregate");
        assertEq(tokenX.balanceOf(address(pm)), pot, "and the whole carry moved a token");
    }

    /// @notice The surplus view is exactly what the pot holds beyond what the ledger owes.
    /// @dev It is the pot-level number a per-loan custody address used to give a reader for free.
    function test_uncreditedSurplus_CountsADonation() public {
        pm.pull(LOAN_A, payer, A_UNITS);
        assertEq(pm.uncreditedSurplus(address(tokenX)), 0, "a clean pot has no surplus");

        tokenX.mint(donor, DONATION);
        vm.prank(donor);
        tokenX.transfer(address(pm), DONATION);

        assertEq(pm.uncreditedSurplus(address(tokenX)), DONATION, "the donation is the whole surplus");
        assertEq(pm.custodiedOf(address(tokenX)), A_UNITS, "and it credited no ledger");
        assertEq(pm.collateralOf(LOAN_A), A_UNITS, "least of all the loan that was already open");
    }

    /// @notice The surplus counts a STRANDING too, not only a donation: both are pot minus ledger.
    function test_uncreditedSurplus_CountsAStrandedForeignBalance() public {
        tokenY.mint(address(pm), DONATION); // a foreign token: no market here quotes in it

        assertEq(pm.custodiedOf(address(tokenY)), 0, "nothing is owed in Y");
        assertEq(pm.uncreditedSurplus(address(tokenY)), DONATION, "so the whole balance is surplus");
    }

    // ---- a decreasing balance becomes a truthful DoS, not first-come theft ----

    /// @notice An external burn against the shared pot makes `release` REVERT rather than pay in full.
    /// @dev Unpooled, a burn damaged only its own loan. Pooled, the first callers out would be paid
    /// @dev in full from a short pot and the tail would get nothing, with no socialization and no admin.
    /// @dev The rail converts that silent first-come theft into a revert, which is the whole claim.
    function testRevert_release_AfterAnExternalBurn_RevertsRatherThanPayingFirstComeFirstServed() public {
        _stubLoanConfig(address(burnable), address(0));
        pm.pull(LOAN_A, payer, A_UNITS);
        pm.pull(LOAN_B, payer, A_UNITS); // two equal loans, 200 in the pot, 200 owed

        burnable.burn(address(pm), 50e18); // the pot is now 150 against 200 owed

        vm.expectRevert(PositionManager.CustodyUnderfunded.selector);
        pm.release(LOAN_A, alice, A_UNITS); // A is first in the queue and would have been paid in full

        assertEq(burnable.balanceOf(alice), 0, "the first caller took nothing out of a short pot");
        assertEq(burnable.balanceOf(address(pm)), 150e18, "so B's units are still there to argue over");
        assertEq(pm.collateralOf(LOAN_B), A_UNITS, "and B's credit is intact rather than silently drained");
    }

    /// @notice The same rail on the retired leg, so a settled claimant cannot be paid out of a short pot.
    function testRevert_releaseRetired_AfterAnExternalBurn_Reverts() public {
        _stubLoanConfig(address(burnable), address(0));
        pm.pull(LOAN_A, payer, A_UNITS);
        pm.pull(LOAN_B, payer, A_UNITS);
        pm.retireCustody(LOAN_A, A_UNITS);

        burnable.burn(address(pm), 50e18);

        vm.expectRevert(PositionManager.CustodyUnderfunded.selector);
        pm.releaseRetired(LOAN_A, alice, A_UNITS);

        assertEq(burnable.balanceOf(alice), 0, "a settled claim is refused out of a short pot too");
    }

    /// @notice A burn that leaves the pot STILL SOLVENT does not brick anything.
    /// @dev The rail is a solvency check, so a surplus burn is inert; without this it could read as
    /// @dev a ban on every balance change, which would be a different and much stronger claim.
    function test_release_AfterABurnOfPureSurplus_StillPays() public {
        _stubLoanConfig(address(burnable), address(0));
        pm.pull(LOAN_A, payer, A_UNITS);
        burnable.mint(address(pm), DONATION); // uncredited surplus, owed to nobody

        burnable.burn(address(pm), DONATION); // burn exactly the surplus, leaving the ledger fully funded

        pm.release(LOAN_A, bob, A_UNITS);

        assertEq(burnable.balanceOf(bob), A_UNITS, "a solvent pot still pays in full");
        assertEq(pm.custodiedOf(address(burnable)), 0, "and the aggregate came back to zero");
    }
}
