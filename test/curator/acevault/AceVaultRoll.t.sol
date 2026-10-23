// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.36;

import {IERC721} from "@openzeppelin/contracts/token/ERC721/IERC721.sol";
import {Borrower, LoanClosed} from "../../../src/ace/hub/Borrower.sol";
import {MarketParams, OpenBounds} from "../../../src/ace/hub/Types.sol";
import {AceVault} from "../../../src/curator/AceVault.sol";
import {AceFixtures} from "../../utils/AceFixtures.sol";
import {MockPersistenceRecord} from "../../mocks/MockPersistenceRecord.sol";
import {AceVaultRig} from "./AceVaultRig.sol";

/// @notice `roll`, the only way a vault loan rolls: permissionless and unpaid, gated on the price leg, funding the successor only on the curator's legs.
contract AceVaultRollTest is AceVaultRig {
    uint256 internal loanId;

    function setUp() public override {
        super.setUp();
        loanId = _borrow(MIN_TENOR, true);
    }

    /// @notice Inside the window anyone may roll; the successor is live, titled to the borrower, funded, and nothing rests.
    function test_ARollInsideTheWindowFundsTheSuccessor() public {
        _toWindow(loanId);
        uint256 strangerCash = usdc.balanceOf(stranger);
        vm.prank(stranger);
        uint256 newId = vault.roll(loanId, "");
        assertTrue(ace.isLiveLoan(newId), "the successor is live");
        assertTrue(ace.isClosed(loanId), "the old loan closed");
        assertEq(IERC721(ace.POSITION_TITLE()).ownerOf(newId), borrower, "the title stays the borrower's");
        assertEq(usdc.balanceOf(stranger), strangerCash, "roll pays its caller nothing");
        assertEq(_need(loanId), 0, "the old record left at the vault's roll");
        assertTrue(_funded(newId), "the successor's next roll is promised");
        _assertRecordCovers(newId);
        assertEq(vault.rollHold(), _need(newId), "the hold is exactly the successor's record");
        _assertNothingRests(_mid(newId));
        _assertNoAllowances();
    }

    /// @notice The successor's record is the hub's rule at the market's longest term, sized off the old debt.
    function test_TheSuccessorRecordIsTheLongestTermBound() public {
        _toWindow(loanId);
        MarketParams memory mp = _mp(loanId);
        uint256 debt = ace.debtOf(loanId);
        uint256 up = _succUp(mp, debt);
        uint256 newId = vault.roll(loanId, "");
        assertEq(_need(newId), Borrower.rollNeed(mp.baseBps, mp.minTenor, mp.minDebt, up, mp.maxTenor), "rollNeed(successorPrincipal(debt, max), max)");
        assertGe(up, ace.debtOf(newId), "the bound covers the successor the hub wrote");
    }

    /// @notice A loan the vault never promised to roll does not roll through it.
    function test_AnUnarmedLoanDoesNotRoll() public {
        uint256 bare = _borrow(MIN_TENOR, false);
        _toWindow(bare);
        vm.expectRevert(AceVault.RollUnfunded.selector);
        vault.roll(bare, "");
    }

    /// @notice A loan in a market that is not this vault's is refused by name.
    function test_AForeignLoanIsRefused() public {
        MarketParams memory p = AceFixtures.marketParams(address(usdc), address(coll));
        p.record = address(record);
        p.lender = stranger;
        p.settleBountyBps = 0;
        bytes32 fm = ace.createMarket(p);
        usdc.mint(stranger, 10_000e6);
        vm.startPrank(stranger);
        usdc.approve(address(ace), 10_000e6);
        ace.deposit(fm, 10_000e6);
        vm.stopPrank();
        coll.mint(bob, UNITS);
        vm.startPrank(bob);
        coll.approve(address(pm), UNITS);
        uint256 foreign = ace.open(fm, UNITS, PRINCIPAL, 0, bob, OpenBounds(0, 0, 0));
        vm.stopPrank();
        vm.expectCall(address(ace), abi.encodeWithSelector(ace.deposit.selector), 0);
        vm.expectCall(address(ace), abi.encodeWithSelector(ace.refinanceByPolicy.selector), 0);
        vm.expectRevert(AceVault.NotOurLoan.selector);
        vault.roll(foreign, "");
    }

    /// @notice The price leg gates the current roll: a record under the market's price refuses it.
    function test_ThePriceLegRefusesTheCurrentRoll() public {
        _toWindow(loanId);
        MarketParams memory mp = _mp(loanId);
        MockPersistenceRecord(mp.record).setMinPrice(mp.price - 1);
        vm.expectRevert(AceVault.NotLending.selector);
        vault.roll(loanId, "");
    }

    /// @notice The drain never stops a current roll; it leaves the successor unfunded, recorded in the hold.
    function test_TheDrainLeavesTheRollRunningAndTheSuccessorUnfunded() public {
        vm.prank(curator);
        vault.setDrain(true);
        _toWindow(loanId);
        uint256 newId = vault.roll(loanId, "");
        assertTrue(ace.isLiveLoan(newId), "the current roll ran");
        assertGt(_need(newId), 0, "the successor's reservation is recorded");
        assertFalse(_funded(newId), "but its next roll is not promised");
        assertEq(vault.rollHold(), _need(newId), "the unfunded reservation still counts in the hold");
        _toWindow(newId);
        vm.expectRevert(AceVault.RollUnfunded.selector);
        vault.roll(newId, "");
    }

    /// @notice A cap cut to zero leaves the current roll running and the successor unfunded.
    function test_ACapCutLeavesTheSuccessorUnfunded() public {
        vm.prank(guardian);
        vault.submitCap(address(coll), 0);
        _toWindow(loanId);
        uint256 newId = vault.roll(loanId, "");
        assertTrue(ace.isLiveLoan(newId), "the current roll ran");
        assertFalse(_funded(newId), "a removed collateral funds no next roll");
    }

    /// @notice A nonzero cap cut under the exposure leaves no room for the successor's need, so the current roll runs and the successor goes unfunded.
    function test_ANonzeroCapCutUnderTheExposureLeavesTheSuccessorUnfunded() public {
        vm.prank(guardian);
        vault.submitCap(address(coll), 1);
        _toWindow(loanId);
        uint256 newId = vault.roll(loanId, "");
        assertTrue(ace.isLiveLoan(newId), "the current roll ran");
        assertFalse(_funded(newId), "a cap with no room left funds no next roll");
    }

    /// @notice A cap cut that still leaves room for the successor's need keeps the promise.
    function test_ACapCutWithRoomLeftKeepsTheSuccessorFunded() public {
        vm.prank(guardian);
        vault.submitCap(address(coll), uint192(10 * PRINCIPAL));
        _toWindow(loanId);
        uint256 newId = vault.roll(loanId, "");
        assertTrue(_funded(newId), "room under the cut still funds the next roll");
    }

    /// @notice A record change accepted behind the timelock leaves the current roll on its own market's record, and the successor unfunded.
    function test_ARecordChangeLeavesTheSuccessorUnfunded() public {
        MockPersistenceRecord other = _record(address(coll), 2e18);
        vm.prank(curator);
        vault.submitCollateral(address(coll), _row(address(other), type(uint192).max));
        _warpBy(TIMELOCK);
        vault.accept(address(coll));
        _toWindow(loanId);
        uint256 newId = vault.roll(loanId, "");
        assertTrue(ace.isLiveLoan(newId), "the current roll ran on its market's own record");
        assertFalse(_funded(newId), "the row no longer prices that market");
    }

    /// @notice An exit run before the window cannot starve a promised roll: the hold stays behind.
    function test_AnExitRunBeforeTheWindowCannotStarveTheRoll() public {
        _warpBy(VEST_W + 1);
        uint256 m = vault.maxWithdraw(alice);
        vm.prank(alice);
        vault.withdraw(m, alice, alice);
        assertEq(vault.idle(), vault.rollHoldNow(), "premise: the run took everything but the hold");
        _toWindow(loanId);
        uint256 newId = vault.roll(loanId, "");
        assertTrue(ace.isLiveLoan(newId), "the promised roll ran out of the hold");
        _assertNothingRests(_mid(newId));
    }

    /// @notice From idle sitting at the hold the promised roll runs, and its successor is booked unfunded: its hold growth finds nothing lendable.
    function test_AtTheHoldTheRollRunsAndTheSuccessorIsUnfunded() public {
        _warpBy(VEST_W + 1);
        uint256 m = vault.maxWithdraw(alice);
        vm.prank(alice);
        vault.withdraw(m, alice, alice);
        assertEq(vault.idle(), vault.rollHoldNow(), "premise: the run took everything but the hold");
        assertEq(vault.lendable(), 0, "premise: nothing is lendable");
        _toWindow(loanId);
        uint256 before = _need(loanId);
        uint256 newId = vault.roll(loanId, "");
        assertTrue(ace.isLiveLoan(newId), "the promised roll ran out of the hold");
        assertGt(_need(newId), before, "premise: the successor's record outgrows the old one, so promising it would grow the hold");
        assertFalse(_funded(newId), "so its next roll is not promised");
        assertEq(vault.rollHold(), _need(newId), "and its reservation still counts in the hold");
    }

    /// @notice The drain stops the promise even where it would cost no new hold: a loan repaid down rolls to a smaller record, still unfunded.
    function test_TheDrainLeavesARepaidDownSuccessorUnfunded() public {
        _repayAs(borrower, loanId, PRINCIPAL - 100e6);
        vm.prank(curator);
        vault.setDrain(true);
        _toWindow(loanId);
        uint256 before = _need(loanId);
        uint256 newId = vault.roll(loanId, "");
        assertTrue(ace.isLiveLoan(newId), "the current roll ran");
        assertGt(_need(newId), 0, "premise: the successor's reservation is recorded");
        assertLe(_need(newId), before, "premise: no larger than the old record, so promising it would need no new hold");
        assertFalse(_funded(newId), "the drain still leaves its next roll unpromised");
    }

    /// @notice After expiry the roll is best-effort: until somebody settles it, the vault's roll still runs through the open policy door.
    function test_ALateRollStillRunsUntilSomebodySettles() public {
        _warpAtLeastTo(_expiry(loanId) + 30 minutes);
        uint256 newId = vault.roll(loanId, "");
        assertTrue(ace.isLiveLoan(newId), "a late roll ran");
    }

    /// @notice The hub's paid fold stays open to anyone: at expiry it settles a vault loan, whose market holds no cash to continue it.
    function test_TheHubsFoldSettlesAVaultLoanAtExpiry() public {
        _warpAtLeastTo(_expiry(loanId));
        vm.prank(stranger);
        ace.forceClose(loanId);
        assertTrue(ace.isClosed(loanId), "the fold settled it: the borrower's protection is rolling inside the window");
        vm.expectRevert(LoanClosed.selector);
        vault.roll(loanId, "");
    }

    /// @notice A successor the carry did not arm is never recorded: the record follows the hub's arming, read after the roll.
    function test_ASuccessorTheCarryDidNotArmIsNeverRecorded() public {
        _toWindow(loanId);
        uint256 own = read.reservedOf(loanId);
        deal(address(usdc), address(vault), own);
        uint256 newId = vault.roll(loanId, "");
        assertTrue(ace.isLiveLoan(newId), "the roll itself ran out of the reservation's refill");
        (bool ok, bytes4 why,) = ace.tryContinue(newId);
        ok;
        assertEq(why, bytes4(keccak256("AutoPolicyDisarmed()")), "premise: the carry left the successor disarmed");
        assertEq(_need(newId), 0, "no record for a successor the hub did not arm");
        assertFalse(_funded(newId), "and so no promise");
        assertEq(vault.rollHold(), 0, "the hold dropped the old record and took nothing on");
    }
}
