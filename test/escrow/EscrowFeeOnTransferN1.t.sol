// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.36;

import {Test} from "forge-std/Test.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {PositionManager} from "../../src/ace/positions/PositionManager.sol";
import {AceFixtures} from "../utils/AceFixtures.sol";
import {LoanManagerStub} from "../utils/LoanManagerStub.sol";
import {MockFeeOnTransferERC20} from "../mocks/MockFeeOnTransferERC20.sol";

/// @notice N1 token safety: `pull` measures the real balance delta and rejects any shortfall.
/// @notice Crediting the REQUESTED units instead would over-state what positionManager physically holds.
/// @notice That phantom collateral makes lenders under-recover and bricks the trailing release.
/// @dev SafeERC20 does not cover this: a fee-on-transfer move succeeds and returns true.
/// @dev So the guard is the measured delta, pinned here from both sides -- fee token and clean token.
/// @dev Both of the original rows started from a ZERO balance, so neither said anything about a SHARED pot.
/// @dev The two shared-balance rows below are what actually establish the claim under pooled custody.
contract EscrowFeeOnTransferN1Test is Test, LoanManagerStub {
    PositionManager internal positionManager;
    MockFeeOnTransferERC20 internal coll; // 1% fee-on-transfer collateral

    address internal alice = address(0xA11CE); // title holder / borrower
    address internal payer = address(0xBEEF);

    function setUp() public {
        coll = new MockFeeOnTransferERC20("Reflect", "RFLCT", 18, 100); // 1% fee
        positionManager = AceFixtures.plainEscrow(IERC20(address(coll)), address(this)); // this == LOAN_MANAGER
        _stubLoanConfig(address(coll), address(0)); // the config the positionManager reads back for every id
        coll.mint(payer, 1_000_000e18);
        vm.prank(payer);
        coll.approve(address(positionManager), type(uint256).max);
    }

    /// @notice The guard rejects a fee-on-transfer collateral at entry, so a phantom-collateral market can never originate.
    /// @notice It reverts FeeOnTransferUnsupported because the positionManager received less than it requested.
    function test_N1_PullRejectsFeeOnTransferCollateral() public {
        vm.expectRevert(PositionManager.FeeOnTransferUnsupported.selector);
        positionManager.pull(1, payer, 100e18);
    }

    /// @notice A standard (fee-free) token still pulls exactly, so the guard is inert for good collateral.
    function test_N1_PullExactForFeeFreeCollateral() public {
        MockFeeOnTransferERC20 clean = new MockFeeOnTransferERC20("Clean", "CLN", 18, 0); // 0% fee
        PositionManager e = AceFixtures.plainEscrow(IERC20(address(clean)), address(this));
        _stubLoanConfig(address(clean), address(0)); // this positionManager's loans hold the CLEAN token
        clean.mint(payer, 1_000e18);
        vm.prank(payer);
        clean.approve(address(e), type(uint256).max);

        e.pull(1, payer, 100e18);
        assertEq(e.collateralOf(1), 100e18, "ledger credited exactly");
        assertEq(clean.balanceOf(address(e)), 100e18, "the pot matches the ledger -- no desync");
    }

    /// @notice The shortfall must still be caught when the pot ALREADY holds another loan's collateral.
    /// @dev The old rows both pulled into an empty custodian, so a `pre` of zero was doing the work.
    /// @dev A `post > units` implementation would pass those and pass every real market too, silently.
    function testRevert_pull_FeeOnTransfer_RevertsWhenTheCustodianAlreadyHoldsAnotherLoan() public {
        coll.mint(address(positionManager), 500_000e18); // loan 1's units, already resting in the pot
        assertGt(coll.balanceOf(address(positionManager)), 0, "fixture: the pot is genuinely non-empty");

        vm.expectRevert(PositionManager.FeeOnTransferUnsupported.selector);
        positionManager.pull(2, payer, 100e18);
    }

    /// @notice A clean pull into a NON-EMPTY pot credits its own loan and nobody else's.
    /// @dev The pot legitimately exceeds either loan's ledger; only the DELTA may be credited.
    function test_pull_CleanToken_CreditsOnlyItsOwnLoan() public {
        MockFeeOnTransferERC20 clean = new MockFeeOnTransferERC20("Clean", "CLN", 18, 0); // 0% fee
        PositionManager e = AceFixtures.plainEscrow(IERC20(address(clean)), address(this));
        _stubLoanConfig(address(clean), address(0));
        clean.mint(payer, 1_000e18);
        vm.prank(payer);
        clean.approve(address(e), type(uint256).max);

        e.pull(1, payer, 300e18);
        e.pull(2, payer, 100e18);

        assertEq(e.collateralOf(2), 100e18, "loan 2 is credited its own units and no part of loan 1's");
        assertEq(e.collateralOf(1), 300e18, "loan 1's credit is untouched by the second pull");
        assertEq(clean.balanceOf(address(e)), 400e18, "while the pot carries both");
        assertEq(e.custodiedOf(address(clean)), 400e18, "and the aggregate is the sum of the two ledgers");
    }
}
