// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.36;

import {WarpClock} from "../utils/WarpClock.sol";
import {Ace} from "../../src/ace/hub/Ace.sol";
import {InsufficientCash} from "../../src/ace/hub/Borrower.sol";
import {LendingAbovePrice} from "../../src/ace/hub/Lender.sol";
import {MarketParams, OpenBounds} from "../../src/ace/hub/Types.sol";
import {PositionManager} from "../../src/ace/positions/PositionManager.sol";
import {MockERC20} from "../mocks/MockERC20.sol";
import {MockPersistenceRecord} from "../mocks/MockPersistenceRecord.sol";
import {AceFixtures} from "../utils/AceFixtures.sol";
import {AceReader} from "../utils/AceReader.sol";

/// @title AceS11RefillAtTheRollsPrice
/// @notice Phase 11 (variants), run 2026-10-03-251533, finding V-RF1: the R-g relaxation never reached the deposit door.
/// @notice R-g lets a HOME roll draw at `min(price, record)`, so a record under the price no longer refuses it.
/// @notice A reserve deficit is cured only by a deposit, and `restRefusal` still refuses EVERY deposit at `price > record`.
/// @notice So at exactly the record R-g exists for, the lender could not refill the cash only those home rolls would draw.
/// @notice FIXED (Y-9 leg C): `restRefusal`'s price leg now exempts a lot that only refills the reserve.
/// @dev Shipped `minDebt` (5,000 USDC), so the refill is #690's sub-floor lot: the cure the #666 review built for a deficit.
contract AceS11RefillAtTheRollsPrice is WarpClock {
    Ace internal ace;
    AceReader internal read;
    PositionManager internal pm;
    MockERC20 internal usdc;
    MockERC20 internal coll;
    MockPersistenceRecord internal rec;
    bytes32 internal id;

    address internal alice = address(0xA11CE); // the sole lender
    address internal borrower = address(0xB0B); // armed, set-and-forget
    address internal keeper = address(0xCAFE);

    uint64 internal constant TEN7 = 7 days;
    uint256 internal constant P = 50_000e6;
    uint256 internal constant UNITS = 100_000e18; // trigger at 0.7 of the price
    uint256 internal loanId;

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
        p.maxTenor = TEN7;
        p.settleBountyBps = 50;
        p.minCoverageWad = 1.4e18;
        p.minDebt = 5_000e6; // the shipped floor: the reserve sits far under it, so the refill is a sub-floor lot
        AceFixtures.Deployment memory d = AceFixtures.deploy(p);
        (ace, pm, read, id) = (d.ace, d.positionManager, d.read, d.id);

        usdc.mint(alice, 10 * P);
        vm.prank(alice);
        usdc.approve(address(ace), type(uint256).max);
        vm.prank(alice);
        ace.deposit(id, 2 * P);

        coll.mint(borrower, UNITS);
        vm.startPrank(borrower);
        coll.approve(address(pm), UNITS);
        loanId = ace.open(id, UNITS, P, TEN7, borrower, OpenBounds(0, 0, 0));
        ace.setAutoRefinance(loanId, TEN7, 0, 0);
        vm.stopPrank();
        assertGt(read.rollReserve(id), 0, "PREMISE: arming reserved the roll's fresh cash");
        assertLt(read.rollReserve(id), p.minDebt, "PREMISE: the reserve sits under minDebt, so its refill is a sub-floor lot");
    }

    function _px(uint256 human) internal view returns (uint256) {
        return AceFixtures.px(human, address(usdc), address(coll));
    }

    /// @dev The lender empties the market, which every rule lets it do: the reserve is left uncovered by its whole size.
    function _empty() internal returns (uint256 deficit) {
        vm.prank(alice);
        ace.withdraw(id, type(uint256).max, alice, 0);
        deficit = read.rollReserve(id) - ace.restingOf(id);
        assertEq(ace.restingOf(id), 0, "PREMISE: nothing rests");
    }

    function _refill(uint256 amt) internal returns (bool landed, bytes4 why) {
        vm.prank(alice);
        try ace.deposit(id, amt) {
            landed = true;
        } catch (bytes memory err) {
            why = bytes4(err);
        }
    }

    function _foldRolled() internal returns (bool) {
        _warpTo(read.loan(loanId).expiry);
        vm.prank(keeper);
        ace.forceClose(loanId);
        return read.invPotOf(id, loanId) == 0;
    }

    /// @notice CONTROL, R-g as ruled: with the reserve intact, a record under the price still ROLLS the armed loan.
    function test_Control_WithTheReserveIntactARecordUnderThePriceRolls() public {
        rec.setMinPrice(_px(0.9e18));
        assertTrue(_foldRolled(), "R-g: the home roll is judged at min(price, record) and rolls");
    }

    /// @notice CONTROL: at a record over the price, the lender refills the deficit with the sub-floor lot and the fold rolls.
    function test_Control_AtARecordOverThePriceTheRefillLandsAndTheFoldRolls() public {
        uint256 deficit = _empty();
        (bool landed,) = _refill(deficit);
        assertTrue(landed, "the #690 refill lands");
        assertTrue(_foldRolled(), "and the armed loan rolls");
    }

    /// @notice At a record under the price the deficit refuses the roll on the cash leg, and the refill that cures it is admitted.
    /// @dev Was the run's premise that the price leg refused the cure; leg C exempts a lot that only refills the reserve.
    function test_AtARecordUnderThePriceTheCureIsAdmitted() public {
        uint256 deficit = _empty();
        rec.setMinPrice(_px(0.9e18));
        _warpTo(read.loan(loanId).expiry);
        (bool ok, bytes4 reason,) = ace.tryContinue(loanId);
        assertFalse(ok, "the deficit refuses the roll");
        assertEq(reason, InsufficientCash.selector, "on the cash leg, the one the refill cures");
        (bool landed, bytes4 why) = _refill(deficit);
        assertTrue(landed, "the refill lands");
        assertEq(why, bytes4(0), "with no refusal at all");
        (ok,,) = ace.tryContinue(loanId);
        assertTrue(ok, "and the roll is admitted again");
    }

    /// @notice MEASURE: what an UNCURED deficit costs. Settled at the write-once price, the lender's pot is worth the record, not par.
    function test_Measure_TheLenderTheRefillWouldHaveServedTakesTheStalePrice() public {
        _empty();
        rec.setMinPrice(_px(0.9e18));
        assertFalse(_foldRolled(), "PREMISE: the fold settled");
        uint256 pot = read.invPotOf(id, loanId);
        uint256 worthAtRecord = (pot * _px(0.9e18)) / (1 << 96);
        emit log_named_uint("lender's claim at par (USDC atoms)", P);
        emit log_named_uint("pot taken (COLL atoms)", pot);
        emit log_named_uint("pot worth at the record (USDC atoms)", worthAtRecord);
        assertLt(worthAtRecord, P, "the settlement the lender could not cure leaves it under par");
    }

    /// @notice A lender refilling a reserve deficit is not refused at a record the home roll it backs accepts.
    /// @dev Was the run's RED row: leg C exempts a deficit-only lot from the price leg.
    function test_ALenderCanCureADeficitAtARecordTheHomeRollAccepts() public {
        uint256 deficit = _empty();
        rec.setMinPrice(_px(0.9e18));
        (bool landed, bytes4 why) = _refill(deficit);
        if (!landed) {
            assertEq(why, LendingAbovePrice.selector, "PREMISE: the only refusal is the price leg");
            assertTrue(false, "a reserve refill was refused at a record the home roll accepts");
        }
        assertTrue(_foldRolled(), "and the refilled reserve rolls the armed loan");
    }
}
