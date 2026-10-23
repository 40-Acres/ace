// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.36;

import {WarpClock} from "../utils/WarpClock.sol";
import {Ace, LoanClosed} from "../../src/ace/hub/Ace.sol";
import {AceLens} from "../../src/ace/lens/AceLens.sol";
import {MarketParams, OpenBounds} from "../../src/ace/hub/Types.sol";
import {PositionManager} from "../../src/ace/positions/PositionManager.sol";
import {MockERC20} from "../mocks/MockERC20.sol";
import {MockPersistenceRecord} from "../mocks/MockPersistenceRecord.sol";
import {MockStakeVault} from "../mocks/MockStakeVault.sol";
import {ProtocolPolicy} from "../../src/config/Defaults.sol";
import {AceFixtures} from "../utils/AceFixtures.sol";
import {AceReader} from "../utils/AceReader.sol";

/// @title AceClosedAt
/// @notice `Loan.closedAt` is the close INSTANT, and `closedAt == 0` IS live.
/// @dev The stamp shares slot 4 with openTime, tenor and expiry, so a wrong shift decodes a NEIGHBOUR, not garbage.
/// @dev Every fixture picks a close instant distinct from all three, which is what makes a misdecode visible.
contract AceClosedAtTest is WarpClock {
    Ace internal ace;
    AceLens internal lens;
    AceReader internal read;
    PositionManager internal pm;
    MockERC20 internal usdc;
    MockStakeVault internal vault;
    MockPersistenceRecord internal record;
    bytes32 internal id;

    address internal alice = address(0xA11CE);
    address internal borrower = address(0xB0B);
    address internal keeper = address(0xCAFE);

    uint64 internal constant TEN7 = ProtocolPolicy.MIN_TENOR;
    uint256 internal constant P = 70_000e6;
    uint256 internal constant COLL = 100_000e18;
    uint256 internal T; // ticks from this pair's par; assigned in setUp, since par is not a compile-time value
    uint256 internal constant TOP = 400_000e6;

    /// @dev Deliberately not a round number and not a multiple of any tenor here.
    uint256 internal constant OFFSET = 12_345;

    /// @dev This suite's pair, so a tick reads as its distance from par rather than as a grid coordinate.
    /// @param offset Ticks above par.
    /// @return The absolute grid tick.
    function _price(int24 offset) internal view returns (uint256) {
        return AceFixtures.priceAt(address(usdc), address(vault), offset);
    }

    function setUp() public {
        _warpTo(1_000_000);
        usdc = new MockERC20("USD Coin", "USDC", 6);
        vault = new MockStakeVault(42);
        T = _price(0);
        record = new MockPersistenceRecord(address(usdc), address(vault));

        MarketParams memory p = AceFixtures.marketParams(address(usdc), address(vault));
        p.record = address(record);

        AceFixtures.Deployment memory d = AceFixtures.deploy(p);
        (ace, pm, read, id) = (d.ace, d.positionManager, d.read, d.id);
        lens = new AceLens(address(ace));

        _deposit(TOP);
        usdc.mint(borrower, 1_000_000e6);
    }

    function _deposit(uint256 amt) internal {
        usdc.mint(alice, amt);
        vm.startPrank(alice);
        usdc.approve(address(ace), amt);
        ace.deposit(id, amt);
        vm.stopPrank();
    }

    function _open(uint256 principal, uint64 tenor) internal returns (uint256 loanId) {
        vault.mint(borrower, COLL);
        vm.startPrank(borrower);
        vault.approve(address(pm), COLL);
        usdc.approve(address(ace), type(uint256).max);
        loanId = ace.open(id, COLL, principal, tenor, borrower, OpenBounds(0, 0, 0));
        vm.stopPrank();
    }

    /// @dev Both decoders and the hub, on one loan.
    /// @dev `Ace.isClosed` is a typed access sharing no raw-slot decoder's error: the only sound oracle here.
    function _assertDecodersAgree(uint256 loanId, string memory why) internal view {
        assertEq(lens.loan(loanId).closedAt != 0, ace.isClosed(loanId), string.concat(why, ": lens vs hub"));
        assertEq(read.loan(loanId).closedAt != 0, ace.isClosed(loanId), string.concat(why, ": reader vs hub"));
        assertEq(lens.loan(loanId).closedAt, read.loan(loanId).closedAt, string.concat(why, ": lens vs reader"));
    }

    /// @notice A live loan carries a zero stamp, and every reader agrees it is live.
    function test_ClosedAt_IsZeroWhileLive() public {
        uint256 loanId = _open(P, TEN7);
        assertEq(read.loan(loanId).closedAt, 0, "an open loan carries no close instant");
        assertFalse(ace.isClosed(loanId), "and the hub reads it live");
        _assertDecodersAgree(loanId, "live");
    }

    /// @notice forceClose stamps the instant it ran, NOT the expiry it ran after.
    /// @dev Closing exactly AT expiry is the one instant that hides a bad shift: expiry shares slot 4.
    /// @dev So this row closes deliberately late.
    function test_ClosedAt_ForceCloseStampsTheCrankInstant() public {
        uint256 loanId = _open(P, TEN7);
        uint64 expiry = read.loan(loanId).expiry;
        _warpTo(uint256(expiry) + OFFSET);
        uint64 when = uint64(_now());
        assertTrue(when != expiry, "guard: the close instant must differ from expiry");

        vm.prank(keeper);
        ace.forceClose(loanId);

        assertEq(read.loan(loanId).closedAt, when, "the stamp is the crank instant");
        _assertDecodersAgree(loanId, "forceClose");
    }

    /// @notice A full repay closes clean and stamps the repay instant.
    function test_ClosedAt_RepayStampsTheCloseInstant() public {
        uint256 loanId = _open(P, TEN7);
        _warpBy(OFFSET);
        uint64 when = uint64(_now());

        vm.startPrank(borrower);
        ace.repay(loanId, type(uint256).max);
        vm.stopPrank();

        assertTrue(ace.isClosed(loanId), "guard: the full repay closed the loan");
        assertEq(read.loan(loanId).closedAt, when, "the stamp is the repay instant");
        _assertDecodersAgree(loanId, "repay");
    }

    /// @notice `finalize` stamps the settlement instant, its own write site distinct from forceClose's.
    /// @dev Settlement lands BEFORE expiry here, so the stamp cannot coincide with the expiry beside it.
    /// @dev Without this row `L.closedAt = 1` in `finalize` survives the whole `test/ace` tree.
    function test_ClosedAt_FinalizeStampsTheSettlementInstant() public {
        uint256 loanId = _open(P, TEN7);
        _warpBy(OFFSET);
        uint64 when = uint64(_now());
        record.setBelow(true);

        vm.prank(keeper);
        ace.finalize(loanId);

        assertEq(read.loan(loanId).closedAt, when, "the stamp is the settlement instant");
        assertLt(when, read.loan(loanId).expiry, "guard: settlement beat expiry, so the two cannot coincide");
        _assertDecodersAgree(loanId, "finalize");
    }

    /// @notice The stamp is distinct from every neighbour sharing slot 4.
    /// @dev The row that fails on a wrong shift: `>> 128` decodes expiry, `>> 64` tenor, unshifted openTime.
    /// @dev All three are non-zero, so a bad decode reads CLOSED.
    function test_ClosedAt_DoesNotAliasItsSlotNeighbours() public {
        uint256 loanId = _open(P, TEN7);
        _warpTo(uint256(read.loan(loanId).expiry) + OFFSET);
        vm.prank(keeper);
        ace.forceClose(loanId);

        uint64 stamp = read.loan(loanId).closedAt;
        assertTrue(stamp != read.loan(loanId).openTime, "the stamp is not openTime");
        assertTrue(stamp != read.loan(loanId).tenor, "the stamp is not tenor");
        assertTrue(stamp != read.loan(loanId).expiry, "the stamp is not expiry");
        assertEq(read.loan(loanId).tenor, TEN7, "guard: the neighbours survived the close");
    }

    /// @notice A never-opened id reads LIVE, exactly as the old boolean did for an unallocated id.
    /// @dev Not a regression, but a rebate consumer must not read it as "open since forever".
    function test_ClosedAt_ANeverOpenedIdReadsLive() public view {
        uint256 ghost = 999_999;
        assertEq(read.loan(ghost).closedAt, 0, "an id that was never opened carries no stamp");
        assertFalse(ace.isClosed(ghost), "and the hub agrees it is not closed");
        assertEq(read.loan(ghost).openTime, 0, "guard: the record really is empty");
    }

    /// @notice The stamp is written once and no refused verb moves it.
    function test_ClosedAt_IsWrittenOnceAndNeverMoves() public {
        uint256 loanId = _open(P, TEN7);
        _warpTo(uint256(read.loan(loanId).expiry) + OFFSET);
        vm.prank(keeper);
        ace.forceClose(loanId);
        uint64 stamp = read.loan(loanId).closedAt;

        _warpBy(1 days);
        vm.prank(keeper);
        vm.expectRevert(LoanClosed.selector);
        ace.forceClose(loanId);

        vm.prank(borrower);
        vm.expectRevert(LoanClosed.selector);
        ace.repay(loanId, 1);

        assertEq(read.loan(loanId).closedAt, stamp, "a refused verb leaves the stamp where it was");
    }
}
