// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.36;

import {Test} from "forge-std/Test.sol";
import {Ace} from "../../src/ace/hub/Ace.sol";
import {MarketParams, OpenBounds} from "../../src/ace/hub/Types.sol";
import {PositionManager} from "../../src/ace/positions/PositionManager.sol";
import {MockBlockableERC20} from "../mocks/MockBlockableERC20.sol";
import {MockERC20} from "../mocks/MockERC20.sol";
import {MockPersistenceRecord} from "../mocks/MockPersistenceRecord.sol";
import {AceFixtures} from "../utils/AceFixtures.sol";
import {AceReader} from "../utils/AceReader.sol";

/// @title AceExpiryFoldUnderQuotePause
/// @notice The armed expiry fold under a globally paused QUOTE, which no suite asks today.
/// @notice `AceExpiryFoldUnderPause` pins the COLLATERAL half and says the carry moves no token.
/// @notice True of collateral. The continuation still moves quote: the successor's payout is a hub self-transfer.
/// @dev So a paused quote reverts the whole fold, and the settle branch is shadowed exactly as it once was.
/// @dev The three controls isolate it: unpaused continues, unarmed settles, and disarming under the pause settles.
contract AceExpiryFoldUnderQuotePauseTest is Test {
    Ace internal ace;
    AceReader internal read;
    PositionManager internal positionManager;
    MockBlockableERC20 internal usdc; // the QUOTE, pausable the way a real stablecoin is
    MockERC20 internal coll;
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
        usdc = new MockBlockableERC20("USD Coin", "USDC", 6);
        coll = new MockERC20("Collateral", "COLL", 18);
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

    /// @notice CONTROL: unpaused, the same fixture CONTINUES, so the row below is the pause talking.
    function test_Control_Unpaused_TheArmedFoldContinues() public {
        uint256 loanId = _armedExpired();
        vm.prank(keeper);
        ace.forceClose(loanId);
        assertTrue(read.loan(loanId).closedAt != 0, "the old loan retired");
        assertEq(read.debtOf(loanId), 0, "into a continuation: debt retired in full");
    }

    /// @notice CONTROL: an UNARMED loan settles under the quote pause, so settlement itself is quote-total.
    function test_Control_PausedQuote_TheUnarmedLoanSettles() public {
        uint256 loanId = _armedExpired();
        vm.prank(borrower);
        ace.setAutoRefinance(loanId, 0, 0, 0);
        usdc.setPaused(true);

        vm.prank(keeper);
        ace.forceClose(loanId);
        assertTrue(read.loan(loanId).closedAt != 0, "settlement is accounting-only and survives the quote pause");
        assertGt(read.debtOf(loanId), 0, "on the settle branch");
    }

    /// @notice CONTROL: the borrower's disarm is a pure storage write, so it works under the quote pause too.
    function test_Control_PausedQuote_TheBorrowerCanDisarmToUnshadowSettlement() public {
        uint256 loanId = _armedExpired();
        usdc.setPaused(true);

        vm.prank(borrower);
        ace.setAutoRefinance(loanId, 0, 0, 0);
        vm.prank(keeper);
        ace.forceClose(loanId);

        assertTrue(read.loan(loanId).closedAt != 0, "disarmed, the same crank settles");
        assertGt(read.debtOf(loanId), 0, "on the settle branch, which a continuation would have zeroed");
    }

    /// @notice THE SUBJECT: an armed expired loan must reach a terminal state under a paused QUOTE.
    /// @notice RED today. The continuation's payout is `safeTransfer(address(this), principal - fee)`, a hub self-transfer.
    /// @dev A pausable quote refuses it, the fold reverts whole, and the settle branch it shadows never runs.
    /// @dev Only the borrower can end the shadow, by disarming; the lenders have no such exit.
    function test_PausedQuote_TheArmedFoldMustStillHaveAnOutcome() public {
        uint256 loanId = _armedExpired();
        usdc.setPaused(true);

        vm.prank(keeper);
        try ace.forceClose(loanId) {
            assertTrue(read.loan(loanId).closedAt != 0, "the armed fold reached a terminal state");
        } catch (bytes memory err) {
            emit log_named_bytes("the armed fold reverted under a paused quote", err);
            assertTrue(false, "an expired armed loan must settle or continue under a paused quote; it does neither");
        }
    }
}
