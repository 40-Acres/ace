// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.36;

import {WarpClock} from "../utils/WarpClock.sol";
import {Ace} from "../../src/ace/hub/Ace.sol";
import {InsufficientCash} from "../../src/ace/hub/Borrower.sol";
import {MarketInit} from "../../src/ace/hub/MarketInit.sol";
import {ExitToHub} from "../../src/ace/hub/libraries/Recipients.sol";
import {MarketParams, OpenBounds} from "../../src/ace/hub/Types.sol";
import {PositionManager} from "../../src/ace/positions/PositionManager.sol";
import {MockERC20} from "../mocks/MockERC20.sol";
import {MockPersistenceRecord} from "../mocks/MockPersistenceRecord.sol";
import {AceFixtures} from "../utils/AceFixtures.sol";
import {AceReader} from "../utils/AceReader.sol";

/// @title AceS4OwnRefinanceStaleBidTest
/// @notice Audit run 2026-10-03-251533, phase 4, F1: a borrower's OWN home refinance still asks the draw cap.
/// @notice The policy roll of the same loan is judged at `min(price, record)` (R-g); the borrower's door refuses at `price > record`.
/// @notice So under a record below the lender's price the borrower could not re-term, even when the refinance drew no fresh cash.
/// @notice FIXED (Y-9 leg B) for the zero-fresh case only; a re-term drawing fresh cash keeps the draw cap.
/// @dev Record-backed market at par; the loan's trigger sits at 0.7 of the price, so a 0.9 record leaves it healthy.
contract AceS4OwnRefinanceStaleBidTest is WarpClock {
    Ace internal ace;
    AceReader internal read;
    PositionManager internal pm;
    MockERC20 internal usdc;
    MockERC20 internal coll;
    MockPersistenceRecord internal rec;
    bytes32 internal id;

    address internal alice = address(0xA11CE);
    address internal borrower = address(0xB0B);
    address internal keeper = address(0xCAFE);

    uint64 internal constant TEN7 = 7 days;
    uint64 internal constant TEN28 = 28 days;
    uint256 internal constant P = 50_000e6;
    uint256 internal constant UNITS = 100_000e18; // trigger at 0.7 of the price
    uint16 internal constant BUF = 1000;

    function setUp() public {
        _warpTo(1_000_000);
        usdc = new MockERC20("USD Coin", "USDC", 6);
        coll = new MockERC20("Collateral", "COLL", 18);
        rec = new MockPersistenceRecord(address(usdc), address(coll));
        rec.setMinPrice(_px(1.1e18));
        MarketParams memory p = AceFixtures.marketParams(address(usdc), address(coll));
        p.record = address(rec);
        p.lender = alice;
        p.baseBps = 40;
        p.minTenor = TEN7;
        p.maxTenor = TEN28;
        p.settleBountyBps = 50;
        p.minCoverageWad = 1.4e18;
        AceFixtures.Deployment memory d = AceFixtures.deploy(p);
        (ace, pm, read, id) = (d.ace, d.positionManager, d.read, d.id);
    }

    function _px(uint256 human) internal view returns (uint256) {
        return AceFixtures.px(human, address(usdc), address(coll));
    }

    function _deposit(uint256 amt) internal {
        usdc.mint(alice, amt);
        vm.startPrank(alice);
        usdc.approve(address(ace), amt);
        ace.deposit(id, amt);
        vm.stopPrank();
    }

    function _open(uint64 tenor) internal returns (uint256 loanId) {
        coll.mint(borrower, UNITS);
        vm.startPrank(borrower);
        coll.approve(address(pm), UNITS);
        loanId = ace.open(id, UNITS, P, tenor, borrower, OpenBounds(0, 0, 0));
        vm.stopPrank();
    }

    /// @dev A fully lent market and an unarmed 28-day loan, one hour in: a 7-day re-term at the same principal draws nothing fresh.
    function _zeroFreshBook() internal returns (uint256 loanId) {
        _deposit(P);
        loanId = _open(TEN28);
        assertEq(ace.restingOf(id), 0, "PREMISE: the market is fully lent");
        _warpBy(1 hours);
    }

    /// @notice CONTROL: with the record over the price, the borrower's zero-fresh re-term lands in a fully lent market.
    function test_Control_ARecordOverThePriceAdmitsTheZeroFreshReterm() public {
        uint256 loanId = _zeroFreshBook();
        vm.prank(borrower);
        uint256 newId = ace.refinance(loanId, P, TEN7, OpenBounds(0, 0, 0));
        assertEq(read.debtOf(newId), P, "the successor carries the old debt");
        assertEq(ace.restingOf(id), 0, "and drew nothing fresh");
    }

    /// @notice A record under the price but far over the trigger does not refuse a re-term that lends nothing fresh.
    /// @dev Was the run's RED row: a zero-fresh draw is now judged at `min(price, record)`, as the home roll is.
    function test_ARecordUnderThePriceDoesNotRefuseAZeroFreshReterm() public {
        uint256 loanId = _zeroFreshBook();
        rec.setMinPrice(_px(0.9e18));
        vm.prank(borrower);
        try ace.refinance(loanId, P, TEN7, OpenBounds(0, 0, 0)) returns (uint256 newId) {
            assertEq(read.debtOf(newId), P, "the successor carries the old debt");
            assertEq(ace.restingOf(id), 0, "and drew nothing fresh");
        } catch (bytes memory err) {
            assertEq(bytes4(err), InsufficientCash.selector, "PREMISE: the refusal is the draw cap's");
            assertTrue(false, "a zero-fresh home re-term was refused by the fresh-draw cap");
        }
    }

    /// @dev An armed 7-day loan with cash for its roll, warped into the pre-expiry window; returns the derived principal.
    function _armedInWindow() internal returns (uint256 loanId, uint256 principal) {
        _deposit(2 * P);
        loanId = _open(TEN7);
        vm.prank(borrower);
        ace.setAutoRefinance(loanId, TEN7, BUF, 0);
        _warpTo(uint256(read.loan(loanId).expiry) - 1 hours);
        rec.setMinPrice(_px(0.9e18));
        bool ok;
        (ok,, principal) = ace.tryContinue(loanId);
        assertTrue(ok, "PREMISE: the home policy roll is admitted under the 0.9 record");
        assertGt(principal, P, "PREMISE: the roll capitalises its fee, so it draws a small fresh remainder");
    }

    /// @notice MEASURE: the same loan, the same block, the same principal and tenor: the policy door rolls, the borrower's door refuses.
    /// @dev STAYS REFUSED after leg B: this roll capitalises its fee, so it draws fresh cash, and a fresh draw keeps the draw cap.
    /// @dev The armed borrower's route to that roll is `refinanceByPolicy`, which anyone may crank inside the window.
    function test_Measure_ThePolicyDoorRollsWhatTheBorrowersOwnDoorRefuses() public {
        (uint256 loanId, uint256 principal) = _armedInWindow();
        uint256 snap = vm.snapshotState();
        vm.prank(borrower);
        vm.expectRevert(InsufficientCash.selector);
        ace.refinance(loanId, principal, TEN7, OpenBounds(0, 0, 0));
        vm.revertToState(snap);
        vm.prank(keeper);
        uint256 newId = ace.refinanceByPolicy(loanId);
        assertEq(read.debtOf(newId), principal, "the policy door wrote the principal the borrower asked for");
    }

    /// @notice CONTROL: over the price, the borrower's door takes that same roll, so the record is the only difference.
    function test_Control_AtARecordOverThePrice_TheBorrowersDoorTakesTheSameRoll() public {
        (uint256 loanId, uint256 principal) = _armedInWindow();
        rec.setMinPrice(_px(1.1e18));
        vm.prank(borrower);
        uint256 newId = ace.refinance(loanId, principal, TEN7, OpenBounds(0, 0, 0));
        assertEq(read.debtOf(newId), principal, "the borrower's own door rolls once the record clears the price");
    }

    /// @notice CONTROL: the window helper is where the measure row says it is.
    function test_Premise_TheWindowIsOpen() public {
        (uint256 loanId,) = _armedInWindow();
        assertLe(read.loan(loanId).expiry - _now(), MarketInit.autoRefinanceWindow(TEN7), "inside the window");
    }
}

/// @title AceS4TitleToHubTest
/// @notice Audit run 2026-10-03-251533, phase 4, F3 (hand-on to unit 6): `retitle` refused only zero.
/// @notice A title moved to the hub made the hub the owner of record, and every close credit then landed where nobody could claim it.
/// @notice FIXED (Y-12 B, then R-1): `retitle` refuses the hub and the positionManager as every exit does, plus the title collection and the treasury.
contract AceS4TitleToHubTest is WarpClock {
    Ace internal ace;
    AceReader internal read;
    PositionManager internal pm;
    MockERC20 internal usdc;
    MockERC20 internal coll;
    bytes32 internal id;

    address internal alice = address(0xA11CE);
    address internal borrower = address(0xB0B);
    address internal payer = address(0xFA1D);

    uint256 internal constant P = 10_000e6;
    uint256 internal constant UNITS = 20_000e18;

    function setUp() public {
        _warpTo(1_000_000);
        usdc = new MockERC20("USD Coin", "USDC", 6);
        coll = new MockERC20("Collateral", "COLL", 18);
        MarketParams memory p = AceFixtures.marketParams(address(usdc), address(coll));
        p.lender = alice;
        AceFixtures.Deployment memory d = AceFixtures.deploy(p);
        (ace, pm, read, id) = (d.ace, d.positionManager, d.read, d.id);
        usdc.mint(alice, P);
        vm.startPrank(alice);
        usdc.approve(address(ace), P);
        ace.deposit(id, P);
        vm.stopPrank();
    }

    /// @notice The holder cannot move the title to the hub: the transfer reverts `ExitToHub`, so a later payoff credits the holder.
    /// @dev Was the run's measurement that the whole lot and the unearned escrow were credited to the hub, unclaimably.
    function test_ATitleCannotBeMovedToTheHub() public {
        coll.mint(borrower, UNITS);
        vm.startPrank(borrower);
        coll.approve(address(pm), UNITS);
        uint256 loanId = ace.open(id, UNITS, P, 0, borrower, OpenBounds(0, 0, 0));
        address title = ace.POSITION_TITLE();
        vm.expectRevert(ExitToHub.selector);
        IERC721Like(title).transferFrom(borrower, address(ace), loanId);
        vm.stopPrank();
        assertEq(ace.borrowerOf(loanId), borrower, "the borrower is still the owner of record");
        uint256 debt = read.debtOf(loanId);
        usdc.mint(payer, debt);
        vm.startPrank(payer);
        usdc.approve(address(ace), debt);
        ace.repay(loanId, debt);
        vm.stopPrank();
        assertTrue(ace.isClosed(loanId), "a stranger's payoff closed the loan");
        (uint256 units, uint256 quote) = ace.owedOf(loanId, borrower);
        assertEq(units, UNITS, "the whole lot is credited to the holder");
        assertGt(quote, 0, "and so is the unearned fee escrow");
    }
}

interface IERC721Like {
    function transferFrom(address from, address to, uint256 tokenId) external;
}
