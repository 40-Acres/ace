// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.36;

import {Test, stdError} from "forge-std/Test.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {PositionManager} from "../src/ace/positions/PositionManager.sol";
import {AceFixtures} from "./utils/AceFixtures.sol";
import {LoanManagerStub} from "./utils/LoanManagerStub.sol";
import {MockERC20} from "./mocks/MockERC20.sol";

/// @notice Direct, isolated exercise of PositionManager's custody ledger with the test contract as LOAN_MANAGER.
/// @notice It reaches edges the hub integration never produces: non-manager callers, phantom releases, over-releases, zero-unit calls.
/// @dev The ERC20-style display mirror and the local ownerOf title map are DELETED; title lives on the hub.
/// @dev What survives and is pinned here: per-loan collateralOf, the custodiedOf aggregate, the manager gate.
contract EscrowDirectTest is Test, LoanManagerStub {
    PositionManager internal positionManager;
    MockERC20 internal coll;

    address internal alice = address(0xA11CE);
    address internal bob = address(0xB0B);
    address internal stranger = address(0x57A);
    address internal payer = address(0xBEEF);

    function setUp() public {
        coll = new MockERC20("Vote MON", "vMON", 18);
        positionManager = AceFixtures.plainEscrow(IERC20(address(coll)), address(this)); // this == LOAN_MANAGER
        _stubLoanConfig(address(coll), address(0)); // the config the positionManager reads back for every id
        coll.mint(payer, 1_000_000e18);
        vm.prank(payer);
        coll.approve(address(positionManager), type(uint256).max);
    }

    // ---- access control: only LOAN_MANAGER moves the ledger ----

    function testRevert_pull_fromNonManager() public {
        vm.prank(stranger);
        vm.expectRevert(PositionManager.NotLoanManager.selector);
        positionManager.pull(1, payer, 100e18);
    }

    function testRevert_release_fromNonManager() public {
        positionManager.pull(1, payer, 100e18);
        vm.prank(stranger);
        vm.expectRevert(PositionManager.NotLoanManager.selector);
        positionManager.release(1, alice, 1);
    }

    // even a would-be no-op (zero units) is gated; no path around the modifier
    function testRevert_pull_zeroUnits_fromNonManager() public {
        vm.prank(stranger);
        vm.expectRevert(PositionManager.NotLoanManager.selector);
        positionManager.pull(1, payer, 0);
    }

    // ---- repeated pulls aggregate on the loan's own ledger ----

    function test_repeatedPulls_aggregateOnLoanLedger() public {
        positionManager.pull(1, payer, 100e18);
        positionManager.pull(1, payer, 40e18);

        assertEq(positionManager.collateralOf(1), 140e18, "loan ledger aggregates both pulls");
        assertEq(coll.balanceOf(address(positionManager)), 140e18, "custody matches, one pot both times");
        assertEq(positionManager.custodiedOf(address(coll)), 140e18, "and so does the pot-level aggregate");
    }

    // ---- zero-unit calls ----

    // a zero-unit pull credits nothing and moves nothing; there is no address to bring into being
    function test_pull_zeroUnits_creditsNothing() public {
        positionManager.pull(7, payer, 0);

        assertEq(positionManager.collateralOf(7), 0, "no units credited");
        assertEq(coll.balanceOf(address(positionManager)), 0, "no custody moved");
        assertEq(positionManager.custodiedOf(address(coll)), 0, "and the aggregate is untouched");
    }

    function test_release_zeroUnits_noOp() public {
        positionManager.pull(1, payer, 100e18);
        positionManager.release(1, alice, 0);

        assertEq(positionManager.collateralOf(1), 100e18, "ledger unchanged by zero-unit release");
        assertEq(coll.balanceOf(address(positionManager)), 100e18, "custody unchanged");
    }

    // ---- underflow guards: cannot release phantom or excess units ----

    // releasing a loanId that was never pulled underflows collateralOf (== 0) and reverts
    function testRevert_release_neverPulled_underflows() public {
        vm.expectRevert(stdError.arithmeticError);
        positionManager.release(99, alice, 1);
    }

    // releasing more than the loan holds underflows the per-loan ledger first
    function testRevert_release_moreThanPulled_underflows() public {
        positionManager.pull(1, payer, 100e18);
        vm.expectRevert(stdError.arithmeticError);
        positionManager.release(1, alice, 100e18 + 1);
    }

    // per-loan collateralOf is the binding guard: one loan cannot over-release another's custody
    function testRevert_release_cannotDrainAcrossLoans() public {
        positionManager.pull(1, payer, 100e18); // loan 1
        positionManager.pull(2, payer, 100e18); // loan 2; total custody 200 but loan 1 only holds 100
        vm.expectRevert(stdError.arithmeticError);
        positionManager.release(1, alice, 150e18);
    }

    // ---- full release lifecycle ----

    function test_release_exactBalance_drainsToZero() public {
        positionManager.pull(1, payer, 100e18);
        positionManager.release(1, bob, 100e18); // destination is the manager's argument, nothing else

        assertEq(positionManager.collateralOf(1), 0, "ledger fully drained");
        assertEq(coll.balanceOf(address(positionManager)), 0, "the pot is fully drained: this loan was its only claimant");
        assertEq(positionManager.custodiedOf(address(coll)), 0, "and the aggregate came back to zero with it");
        assertEq(coll.balanceOf(bob), 100e18, "collateral delivered to the destination");
    }

    // release pays the manager's `to` argument: fixed-destination, no local title read
    function test_release_paysTheNamedDestination() public {
        positionManager.pull(1, payer, 100e18);
        positionManager.release(1, bob, 30e18);

        assertEq(positionManager.collateralOf(1), 70e18, "loan ledger debited");
        assertEq(coll.balanceOf(bob), 30e18, "destination received the collateral");
    }

    // ---- custody mirrors the ledger on the happy path ----

    function test_pull_movesCustody_ledgerMirrors() public {
        positionManager.pull(1, payer, 250e18);
        assertEq(coll.balanceOf(address(positionManager)), 250e18, "the custodian's pot received it");
        assertEq(positionManager.custodiedOf(address(coll)), coll.balanceOf(address(positionManager)), "I-A holds exactly");
        assertEq(positionManager.collateralOf(1), 250e18, "and the whole aggregate belongs to this one loan");
    }
}
