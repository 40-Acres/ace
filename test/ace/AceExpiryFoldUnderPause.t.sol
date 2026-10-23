// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.36;

import {Test} from "forge-std/Test.sol";
import {Ace} from "../../src/ace/hub/Ace.sol";
import {MarketParams, OpenBounds} from "../../src/ace/hub/Types.sol";
import {PositionManager} from "../../src/ace/positions/PositionManager.sol";
import {MockBlockableStakeVault} from "../mocks/MockBlockableStakeVault.sol";
import {MockERC20} from "../mocks/MockERC20.sol";
import {MockPersistenceRecord} from "../mocks/MockPersistenceRecord.sol";
import {AceFixtures} from "../utils/AceFixtures.sol";
import {AceReader} from "../utils/AceReader.sol";

/// @title AceExpiryFoldUnderPause
/// @notice An ARMED expired loan now CONTINUES under a transfer-paused collateral instead of sticking.
/// @notice `_continuable` is total over LOAN state and knows nothing of token behaviour, so it cannot see a pause.
/// @notice It no longer has to: the continuation's carry is two ledger writes, so it makes no transfer to pause.
/// @dev The continue branch still SHADOWS the settle branch, and that is now harmless rather than a trap.
/// @dev The borrower's disarm remains the branch choice, and is pause-proof: it makes no external call.
/// @dev An UNARMED loan settles under the same pause, which is the control that isolates the arming.
contract AceExpiryFoldUnderPauseTest is Test {
    Ace internal ace;
    AceReader internal read;
    PositionManager internal positionManager;
    MockERC20 internal usdc;
    MockBlockableStakeVault internal coll;
    MockPersistenceRecord internal record;
    bytes32 internal id;

    address internal alice = address(0xA11CE);
    address internal borrower = address(0xB0B);
    address internal keeper = address(0xCAFE);

    uint64 internal constant TEN7 = 7 days;
    uint64 internal constant TEN30 = 30 days;
    uint64 internal constant SPACING = 23 days;
    uint256 internal constant P_CONT = 40_000e6; // leaves the derived continuation inside the gate
    uint256 internal constant COLL = 100_000e18;
    uint256 internal T; // par for this pair; assigned in setUp, since par is not a compile-time value
    uint256 internal DEEP; // the depth the draws in this file never walk down to
    uint256 internal constant TOP = 400_000e6;
    uint256 internal constant DEEP_CASH = 200_000e6;

    /// @dev This suite's pair, so a tick reads as its distance from par rather than as a grid coordinate.
    /// @param offset Ticks above par.
    /// @return The absolute grid tick.
    function _price(int24 offset) internal view returns (uint256) {
        return AceFixtures.priceAt(address(usdc), address(coll), offset);
    }

    function setUp() public {
        vm.warp(1_000_000);
        usdc = new MockERC20("USD Coin", "USDC", 6);
        coll = new MockBlockableStakeVault();
        (T, DEEP) = (_price(0), _price(-6000));
        record = new MockPersistenceRecord(address(usdc), address(coll));

        MarketParams memory p = AceFixtures.marketParams(address(usdc), address(coll));
        p.record = address(record);
        p.minTenor = TEN7;
        p.maxTenor = TEN30;
        AceFixtures.Deployment memory d = AceFixtures.deploy(p);
        (ace, positionManager, read, id) = (d.ace, d.positionManager, d.read, d.id);

        _deposit(TOP);
        _deposit(DEEP_CASH);
    }

    function _deposit(uint256 amt) internal {
        usdc.mint(alice, amt);
        vm.startPrank(alice);
        usdc.approve(address(ace), amt);
        ace.deposit(id, amt);
        vm.stopPrank();
    }

    /// @dev An armed loan one second past expiry whose continuation the gate admits; the fold's canonical fixture.
    function _armedExpired() internal returns (uint256 loanId) {
        coll.mint(borrower, COLL);
        vm.startPrank(borrower);
        coll.approve(address(positionManager), COLL);
        loanId = ace.open(id, COLL, P_CONT, TEN30, borrower, OpenBounds(0, 0, 0));
        ace.setAutoRefinance(loanId, TEN30, 0, 0);
        vm.stopPrank();
        vm.warp(uint256(read.loan(loanId).expiry) + 1);
    }

    /// @notice CONTROL: unpaused, the same fixture CONTINUES, so the RED row below is the pause talking.
    function test_Control_Unpaused_TheArmedFoldContinues() public {
        uint256 loanId = _armedExpired();
        vm.prank(keeper);
        ace.forceClose(loanId);
        assertTrue(read.loan(loanId).closedAt != 0, "the old loan retired");
        assertEq(read.debtOf(loanId), 0, "into a continuation: debt retired in full");
    }

    /// @notice CONTROL: an UNARMED loan settles under a pause, which is what the record's sentence pins.
    function test_Control_Paused_TheUnarmedLoanSettles() public {
        uint256 loanId = _armedExpired();
        vm.prank(borrower);
        ace.setAutoRefinance(loanId, 0, 0, 0);
        coll.setPaused(true);

        vm.prank(keeper);
        ace.forceClose(loanId);
        assertTrue(read.loan(loanId).closedAt != 0, "settlement is accounting-only and survives the pause");
        assertGt(read.debtOf(loanId), 0, "on the settle branch");
    }

    /// @notice THE SUBJECT, INVERTED: an armed fold now CONTINUES under the pause rather than sticking.
    /// @notice Pooled custody made the carry two ledger writes, so the continuation makes no collateral transfer.
    /// @dev The old row asserted the opposite, and it was right about the old shape: the carry moved tokens.
    /// @dev A paused collateral therefore no longer strands a borrower between a dead continuation and a settlement.
    /// @dev The pot assertion is the mechanism, and it is what makes this a claim about the carry and not luck.
    function test_Paused_TheArmedFoldContinuesBecauseTheCarryMovesNoToken() public {
        uint256 loanId = _armedExpired();
        uint256 potBefore = coll.balanceOf(address(positionManager));
        uint256 units = read.loan(loanId).collateralUnits;
        coll.setPaused(true);

        vm.prank(keeper);
        ace.forceClose(loanId);

        assertTrue(read.loan(loanId).closedAt != 0, "the armed loan retired under the pause");
        assertEq(read.debtOf(loanId), 0, "into a CONTINUATION: its debt is retired in full, not settled");
        assertEq(coll.balanceOf(address(positionManager)), potBefore, "and the carry moved no token, which is why");
        assertEq(positionManager.collateralOf(loanId), 0, "the predecessor's LIVE credit is gone");
        /// @dev The crank's sliver is RETIRED to the keeper's owed ledger first; the rest is what carries
        assertGt(positionManager.retiredOf(loanId), 0, "the keeper's in-kind sliver was retired, not transferred");
        assertEq(positionManager.collateralOf(loanId + 1) + positionManager.retiredOf(loanId), units, "and the successor holds every unit the sliver did not");
    }

    /// @notice The borrower's disarm still routes the same crank to SETTLEMENT, pause or no pause.
    /// @dev The exit is pause-proof because `setAutoRefinance(id, 0, 0, 0)` makes no external call.
    /// @dev It is no longer an ESCAPE from a stuck fold, but it is still the borrower's branch choice.
    function test_Paused_TheBorrowerCanStillChooseSettlementOverTheContinuation() public {
        uint256 loanId = _armedExpired();
        coll.setPaused(true);

        vm.prank(borrower);
        ace.setAutoRefinance(loanId, 0, 0, 0);
        vm.prank(keeper);
        ace.forceClose(loanId);

        assertTrue(read.loan(loanId).closedAt != 0, "disarmed, the same crank settles");
        assertGt(read.debtOf(loanId), 0, "on the settle branch, which a continuation would have zeroed");
    }
}
