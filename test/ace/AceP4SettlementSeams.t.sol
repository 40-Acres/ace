// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.36;

import {WarpClock} from "../utils/WarpClock.sol";
import {Ace} from "../../src/ace/hub/Ace.sol";
import {AceLens} from "../../src/ace/lens/AceLens.sol";
import {InsufficientCash} from "../../src/ace/hub/Borrower.sol";
import {MarketInit} from "../../src/ace/hub/MarketInit.sol";
import {LoanMath} from "../../src/ace/hub/libraries/LoanMath.sol";
import {MarketParams, OpenBounds} from "../../src/ace/hub/Types.sol";
import {PositionManager} from "../../src/ace/positions/PositionManager.sol";
import {MockERC20} from "../mocks/MockERC20.sol";
import {MockPersistenceRecord} from "../mocks/MockPersistenceRecord.sol";
import {AceFixtures} from "../utils/AceFixtures.sol";
import {AceReader} from "../utils/AceReader.sol";

/// @title AceP4Base
/// @notice Audit run 2026-09-13-670568 phase 4: one record-backed sole-tenant market with a healthy armed loan.
/// @dev RECORD-BACKED because arming needs a record (`ArmNeedsRecord`); the phase measured the recordless class, which cannot arm now.
/// @dev The record's windowed minimum is the mock's default, over the market's price, so it caps no draw and proves no distress.
abstract contract AceP4Base is WarpClock {
    Ace internal ace;
    AceReader internal read;
    AceLens internal lens;
    PositionManager internal pm;
    MockERC20 internal usdc;
    MockERC20 internal coll;
    bytes32 internal mid;
    MarketParams internal params;

    address internal alice = address(0xA11CE); // the market's one named lender
    address internal borrower = address(0xB0B);
    address internal keeper = address(0xCA11E5);

    uint256 internal constant PRINCIPAL = 11e6;
    uint256 internal constant COLL = 10_000e18;

    function setUp() public {
        _warpTo(1_000_000);
        usdc = new MockERC20("USD Coin", "USDC", 6);
        coll = new MockERC20("Collateral", "COLL", 18);
        params = AceFixtures.marketParams(address(usdc), address(coll));
        params.record = address(new MockPersistenceRecord(address(usdc), address(coll)));
        params.lender = alice;
        AceFixtures.Deployment memory d = AceFixtures.deploy(params);
        (ace, pm, read, mid) = (d.ace, d.positionManager, d.read, d.id);
        lens = new AceLens(address(ace));
    }

    function _rest(uint256 amt) internal {
        usdc.mint(alice, amt);
        vm.startPrank(alice);
        usdc.approve(address(ace), amt);
        ace.deposit(mid, amt);
        vm.stopPrank();
    }

    /// @dev A healthy loan at the market's minTenor, armed home-only on that same tenor.
    function _armedLoan() internal returns (uint256 loanId) {
        coll.mint(borrower, COLL);
        vm.startPrank(borrower);
        coll.approve(address(pm), COLL);
        loanId = ace.open(mid, COLL, PRINCIPAL, 0, borrower, OpenBounds(0, 0, 0));
        ace.setAutoRefinance(loanId, read.loan(loanId).tenor, 0, 0);
        vm.stopPrank();
    }

    /// @dev The successor's principal at or after expiry, where the refund is zero and the owed amount is the whole debt.
    function _derivedAtExpiry() internal view returns (uint256) {
        return LoanMath.principalForOwed(PRINCIPAL, params.minTenor, params.baseBps, params.minTenor);
    }
}

/// @title AceP4RollFunding
/// @notice A same-market roll RECYCLES the retiring principal: it draws only the successor's fresh remainder out of cash.
/// @notice Before the recycle it needed a gross second copy resting, which is the lever a stranger's drain pulled.
/// @dev The two rows pin the recycle from both sides: what the roll takes out of cash, and that a gross shortfall no longer refuses.
contract AceP4RollFundingTest is AceP4Base {
    /// @notice CONTROL: with the derived principal resting beside the loan, the fold rolls and takes only the fresh remainder.
    function test_Control_WithTheDerivedPrincipalResting_TheFoldRolls() public {
        uint256 p = _derivedAtExpiry();
        _rest(PRINCIPAL + p);
        uint256 loanId = _armedLoan();
        _warpTo(read.loan(loanId).expiry);
        (bool ok,, uint256 principal) = ace.tryContinue(loanId);
        assertTrue(ok, "control: the roll is admissible");
        assertEq(principal, p, "fixture: the suite rests exactly the principal the predicate derives");

        uint256 n = read.loanCount();
        uint256 restingBefore = ace.restingOf(mid);
        (,, uint256 owedBefore) = read.lenderPools(alice, address(usdc));
        vm.prank(keeper);
        ace.forceClose(loanId);

        assertEq(read.loanCount(), n + 1, "control: the fold opened a successor");
        assertEq(restingBefore - ace.restingOf(mid), p - PRINCIPAL, "the roll took only the fresh remainder out of resting cash");
        (,, uint256 owedAfter) = read.lenderPools(alice, address(usdc));
        assertLt(owedAfter - owedBefore, PRINCIPAL, "the retiring debt funded the successor rather than landing in the lender's credit");
        (uint64 tenor,,) = read.autoPolicyOf(n + 1);
        assertGt(tenor, 0, "and the successor is armed: the market still backs its roll");
    }

    /// @notice One atom short of the GROSS successor, the retiring debt now funds the roll: it rolls and the pot takes nothing.
    function test_OneAtomShortOfTheGrossSuccessor_TheRetiringDebtFundsTheRoll() public {
        uint256 p = _derivedAtExpiry();
        _rest(PRINCIPAL + p - 1);
        uint256 loanId = _armedLoan();
        _warpTo(read.loan(loanId).expiry);
        assertEq(ace.restingOf(mid), p - 1, "fixture: one atom short of the successor");
        assertGt(read.debtOf(loanId), 1, "fixture: the retiring debt alone exceeds the one-atom gap");

        (bool ok,,) = ace.tryContinue(loanId);
        assertTrue(ok, "the predicate admits: the retiring debt covers the gap");

        uint256 n = read.loanCount();
        vm.prank(keeper);
        ace.forceClose(loanId);
        assertEq(read.loanCount(), n + 1, "rolled, not settled");
        assertEq(read.invPotOf(mid, loanId), 0, "and the lender's pot took nothing");
    }
}

/// @title AceP4UnpaidBackstop
/// @notice `settleExpired` is documented as paying nothing "so no keeper steers" and as expecting a lender caller.
/// @notice That lender can still end, at the backstop's opening, a roll their OWN resting cash would fund: the #440 liveness gap.
/// @notice In the record-backed class the pot takes only the claim's need, so ending it moves no coverage to the lender.
/// @dev GREEN on purpose: the hazard is already registered; these rows pin the door the register's lever table omits.
contract AceP4UnpaidBackstopTest is AceP4Base {
    uint256 internal constant DEPOSIT = 40e6; // deep enough that the home roll is funded at every block below

    /// @notice CONTROL: at the block the backstop opens, the PAID door still rolls the same loan.
    function test_Control_AtTheBackstopsOpening_ThePaidDoorRolls() public {
        _rest(DEPOSIT);
        uint256 loanId = _armedLoan();
        _warpTo(read.loan(loanId).expiry + MarketInit.autoRefinanceWindow(read.loan(loanId).tenor));
        uint256 n = read.loanCount();
        vm.prank(keeper);
        ace.forceClose(loanId);
        assertEq(read.loanCount(), n + 1, "control: the paid door rolled");
        assertEq(read.invPotOf(mid, loanId), 0, "control: nothing converted");
    }

    /// @notice PREMISE: the lender, cash still resting, ends an admissible funded roll through the unpaid door; the pot takes the need.
    /// @dev The same state is run through both doors under a snapshot, so the only variable is which verb the caller picked.
    function test_Premise_TheLenderEndsARollTheirOwnRestingCashWouldFund() public {
        _rest(DEPOSIT);
        uint256 loanId = _armedLoan();
        uint256 units = read.loan(loanId).collateralUnits;
        uint256 need = lens.collateralNeeded(mid, loanId);
        uint256 debt = read.debtOf(loanId);
        assertGt(need, 0, "fixture: the claim needs collateral, so the pot has something to take");

        _warpTo(read.loan(loanId).expiry + MarketInit.autoRefinanceWindow(read.loan(loanId).tenor));
        (bool ok,,) = ace.tryContinue(loanId);
        assertTrue(ok, "fixture: at this block the home roll is admissible and funded");
        uint256 resting = ace.restingOf(mid);
        uint256 n = read.loanCount();

        uint256 snap = vm.snapshotState();
        vm.prank(keeper);
        ace.forceClose(loanId);
        assertEq(read.loanCount(), n + 1, "same state, paid door: rolled");
        vm.revertToState(snap);

        vm.prank(alice);
        ace.settleExpired(loanId);
        assertEq(read.loanCount(), n, "same state, unpaid door: settled");
        assertEq(ace.restingOf(mid), resting, "the lender never withdrew: the cash that would have rolled the loan still rests");
        assertEq(read.unitsOwedOf(loanId, alice), 0, "the unpaid door credited its caller no sliver");
        assertEq(read.invPotOf(mid, loanId), need, "and the lender's pot took exactly the claim's need");
        assertEq(read.unitsOwedOf(loanId, borrower), units - need, "the borrower keeps everything above it");
        emit log_named_decimal_uint("debt (USDC)", debt, 6);
        emit log_named_decimal_uint("the claim's need, taken in kind (COLL)", need, 18);
    }
}
