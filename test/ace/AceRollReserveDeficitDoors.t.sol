// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.36;

import {WarpClock} from "../utils/WarpClock.sol";
import {Ace} from "../../src/ace/hub/Ace.sol";
import {AceLens} from "../../src/ace/lens/AceLens.sol";
import {BelowMinLot} from "../../src/ace/hub/Lender.sol";
import {PocDeployConfig} from "../../src/config/Defaults.sol";
import {MarketParams, OpenBounds} from "../../src/ace/hub/Types.sol";
import {PositionManager} from "../../src/ace/positions/PositionManager.sol";
import {MockERC20} from "../mocks/MockERC20.sol";
import {MockPersistenceRecord} from "../mocks/MockPersistenceRecord.sol";
import {AceFixtures} from "../utils/AceFixtures.sol";
import {AceReader} from "../utils/AceReader.sol";

/// @title AceRollReserveDeficitDoors
/// @notice A market under its roll reserve, by the lender's own withdraw: what the lens and the lender's deposit door answer there.
/// @notice The lens answers `setAutoRefinance`'s question as the hub does, including a re-arm that needs no more than it holds.
/// @notice A deposit into a deficit stays within it or clears a whole `minDebt` past it; nothing between rests.
/// @dev Pinned at the SHIPPED `minDebt`, where a reserve sits far under the floor.
contract AceRollReserveDeficitDoorsTest is WarpClock {
    Ace internal ace;
    AceReader internal read;
    AceLens internal lens;
    PositionManager internal pm;
    MockERC20 internal usdc;
    MockERC20 internal coll;
    MockPersistenceRecord internal rec;
    bytes32 internal sid;

    address internal alice = address(0xA11CE);
    address internal borrower = address(0xB0B);

    uint64 internal constant TEN7 = 7 days;
    uint64 internal constant TEN28 = 28 days;
    uint256 internal constant P = 50_000e6;
    uint256 internal constant UNITS = 100_000e18;
    uint256 internal constant FLOOR = PocDeployConfig.MIN_DEBT;

    function setUp() public {
        _warpTo(1_000_000);
        usdc = new MockERC20("USD Coin", "USDC", 6);
        coll = new MockERC20("Collateral", "COLL", 18);
        rec = new MockPersistenceRecord(address(usdc), address(coll));
        rec.setMinPrice(AceFixtures.px(1.1e18, address(usdc), address(coll)));
        MarketParams memory p = AceFixtures.marketParams(address(usdc), address(coll));
        p.record = address(rec);
        p.lender = alice;
        p.baseBps = 40;
        p.minTenor = TEN7;
        p.maxTenor = TEN28;
        p.settleBountyBps = 50;
        p.minCoverageWad = 1.4e18;
        p.minDebt = FLOOR;
        AceFixtures.Deployment memory d = AceFixtures.deploy(p);
        (ace, pm, read, sid) = (d.ace, d.positionManager, d.read, d.id);
        lens = new AceLens(address(ace));
    }

    function _deposit(uint256 amt) internal {
        usdc.mint(alice, amt);
        vm.startPrank(alice);
        usdc.approve(address(ace), amt);
        ace.deposit(sid, amt);
        vm.stopPrank();
    }

    /// @dev An armed loan with `P` resting beside it, then the lender empties the market: a deficit of the whole reserve.
    function _armedThenEmptied(uint64 tenor) internal returns (uint256 loanId, uint256 rr) {
        _deposit(2 * P);
        coll.mint(borrower, UNITS);
        vm.startPrank(borrower);
        coll.approve(address(pm), UNITS);
        loanId = ace.open(sid, UNITS, P, TEN7, borrower, OpenBounds(0, 0, 0));
        ace.setAutoRefinance(loanId, tenor, 0, 0);
        vm.stopPrank();
        rr = read.rollReserve(sid);
        assertGt(rr, 0, "PREMISE: the loan reserved");
        assertLt(rr, FLOOR, "PREMISE: the reserve sits under the shipped floor");
        vm.prank(alice);
        ace.withdraw(sid, type(uint256).max, alice, 0);
        assertEq(ace.restingOf(sid), 0, "PREMISE: the lender's own withdraw left the market under its reserve");
    }

    /* ================================================================= */
    /*  the lens answers the hub's re-arm question                        */
    /* ================================================================= */

    /// @notice In a deficit, a same-need re-arm lands at the hub, and `armable` says so beforehand.
    function test_TheLensAgreesWithTheHubOnASameNeedReArmInADeficit() public {
        (uint256 loanId, uint256 rr) = _armedThenEmptied(TEN7);
        (bool can, uint256 quoted) = lens.armable(loanId, TEN7);
        vm.prank(borrower);
        ace.setAutoRefinance(loanId, TEN7, 100, 0); // a buffer tweak at the same need
        assertEq(read.reservedOf(loanId), rr, "the hub kept the reservation");
        assertEq(quoted, rr, "the lens quotes the same need");
        assertTrue(can, "and answered that the re-arm lands");
    }

    /// @notice The same on a SHORTER roll, which frees reserve and so lands in any cash state.
    function test_TheLensAgreesWithTheHubOnAShorterReArmInADeficit() public {
        (uint256 loanId, uint256 rr28) = _armedThenEmptied(TEN28);
        (bool can, uint256 r7) = lens.armable(loanId, TEN7);
        assertLt(r7, rr28, "PREMISE: the shorter roll needs less than the loan holds");
        vm.prank(borrower);
        ace.setAutoRefinance(loanId, TEN7, 0, 0);
        assertEq(read.reservedOf(loanId), r7, "the hub shrank the reservation");
        assertTrue(can, "and the lens answered that it lands");
    }

    /* ================================================================= */
    /*  a deposit into a deficit stays within it or clears a floor        */
    /* ================================================================= */

    /// @notice A floor-sized lot into a deficit would rest `FLOOR - rr` unreserved, which no minimum ticket can draw: refused.
    function test_AFloorSizedDepositIntoADeficitRefuses() public {
        _armedThenEmptied(TEN7);
        usdc.mint(alice, FLOOR);
        vm.startPrank(alice);
        usdc.approve(address(ace), FLOOR);
        vm.expectRevert(BelowMinLot.selector);
        ace.deposit(sid, FLOOR);
        vm.stopPrank();
    }

    /// @notice One atom short of a whole floor past the deficit still rests unreserved dust: refused.
    function test_ADepositOneAtomShortOfAWholeFloorPastTheDeficitRefuses() public {
        (, uint256 rr) = _armedThenEmptied(TEN7);
        uint256 amt = rr + FLOOR - 1;
        usdc.mint(alice, amt);
        vm.startPrank(alice);
        usdc.approve(address(ace), amt);
        vm.expectRevert(BelowMinLot.selector);
        ace.deposit(sid, amt);
        vm.stopPrank();
    }

    /// @notice A deposit that refills the deficit and clears exactly one floor past it lands, and a minimum ticket can draw that floor.
    function test_ADepositClearingAWholeFloorPastTheDeficitLands() public {
        (, uint256 rr) = _armedThenEmptied(TEN7);
        _deposit(rr + FLOOR);
        assertEq(ace.restingOf(sid), rr + FLOOR, "the lot rested whole");
        assertEq(lens.drawableOf(sid), FLOOR, "and exactly one floor of it is unreserved");
        (bool ok,,) = lens.tryQuoteOpen(sid, UNITS, FLOOR, TEN7, address(0xB0B2), OpenBounds(0, 0, 0));
        assertTrue(ok, "which the smallest ticket can draw");
    }
}
