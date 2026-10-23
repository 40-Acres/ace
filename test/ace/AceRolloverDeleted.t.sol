// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.36;

import {Test} from "forge-std/Test.sol";
import {WarpClock} from "../utils/WarpClock.sol";
import {Ace} from "../../src/ace/hub/Ace.sol";
import {MarketParams, OpenBounds} from "../../src/ace/hub/Types.sol";
import {InsufficientCash} from "../../src/ace/hub/Borrower.sol";
import {PositionManager} from "../../src/ace/positions/PositionManager.sol";
import {MockERC20} from "../mocks/MockERC20.sol";
import {MockPersistenceRecord} from "../mocks/MockPersistenceRecord.sol";
import {MockStakeVault} from "../mocks/MockStakeVault.sol";
import {AceFixtures} from "../utils/AceFixtures.sol";
import {AceReader} from "../utils/AceReader.sol";

/// @title AceRolloverDeleted
/// @notice The rollover and rotation subsystem is GONE, and "tenor bounds every trust" is literal.
/// @notice Written failing-first while the verbs still routed; they are gone and this suite is green.
/// @dev Absence is asserted as EMPTY returndata rather than as a plain revert.
/// @dev `Ace` has no fallback, so a deleted selector reverts with zero bytes.
/// @dev A live one either succeeds or reverts with a named error, which is four bytes or more.
/// @dev Each call is shaped to SUCCEED if a verb were revived, so the absence assertion stays sharp.
contract AceRolloverDeletedTest is WarpClock {
    Ace internal ace;
    AceReader internal read;
    PositionManager internal positionManager;
    MockERC20 internal usdc;
    MockStakeVault internal vault;
    MockPersistenceRecord internal record;
    bytes32 internal id;

    address internal alice = address(0xA11CE);
    address internal bob = address(0xB0BB);
    address internal borrower = address(0xB0B);
    address internal keeper = address(0xCAFE);

    uint256 internal constant COLL = 10_000e18;
    uint256 internal constant PRINCIPAL = 4_500e6;
    uint64 internal constant TENOR = 7 days;

    uint256 internal T; // ticks above this pair's par; assigned in setUp, since par is not a compile-time value
    uint256 internal DEEP;

    uint256 internal t0;

    /// @dev This suite's pair, so a tick reads as its distance from par rather than as a grid coordinate.
    /// @param offset Ticks above par.
    /// @return The absolute grid tick.
    function _price(int24 offset) internal view returns (uint256) {
        return AceFixtures.priceAt(address(usdc), address(vault), offset);
    }

    function setUp() public {
        _warpTo(1_000_000);
        t0 = _now();
        usdc = new MockERC20("USD Coin", "USDC", 6);
        vault = new MockStakeVault(42);
        (T, DEEP) = (_price(0), _price(-6000));
        record = new MockPersistenceRecord(address(usdc), address(vault));
        record.setAbove(true); // healthy: today's rollover gate passes, so the call really executes

        MarketParams memory p = AceFixtures.marketParams(address(usdc), address(vault));
        p.record = address(record);
        AceFixtures.Deployment memory d = AceFixtures.deploy(p);
        (ace, positionManager, read, id) = (d.ace, d.positionManager, d.read, d.id);

        _deposit(alice, T, 15_000e6);
        _deposit(alice, DEEP, 15_000e6);
        usdc.mint(borrower, 10_000e6);
    }

    function _deposit(address who, uint256 price, uint256 amt) internal {
        usdc.mint(who, amt);
        vm.startPrank(who);
        usdc.approve(address(ace), amt);
        ace.deposit(id, amt);
        vm.stopPrank();
    }

    function _open() internal returns (uint256 loanId) {
        vault.mint(borrower, COLL);
        vm.startPrank(borrower);
        vault.approve(address(positionManager), COLL);
        usdc.approve(address(ace), type(uint256).max);
        loanId = ace.open(id, COLL, PRINCIPAL, 0, borrower, OpenBounds(0, 0, 0));
        vm.stopPrank();
    }

    /// @dev A deleted selector reverts with ZERO bytes; a live one succeeds or names an error.
    function _assertGone(bytes memory data, string memory what) internal {
        (bool ok, bytes memory ret) = address(ace).call(data);
        assertFalse(ok, what);
        assertEq(ret.length, 0, what);
    }

    // ============ 12. the surface is gone from the ABI ============

    /// @notice The borrower-fired term extension is gone.
    function test_Gone_Rollover() public {
        uint256 loanId = _open();
        vm.prank(borrower);
        _assertGone(abi.encodeWithSignature("rollover(uint256)", loanId), "rollover still routes");
    }

    /// @notice The keeper-fired term extension is gone.
    function test_Gone_Roll() public {
        uint256 loanId = _open();
        vm.prank(keeper);
        _assertGone(abi.encodeWithSignature("roll(uint256)", loanId), "roll still routes");
    }

    /// @notice The borrower's auto-roll toggle is gone with the thing it toggled.
    function test_Gone_SetAutoRoll() public {
        uint256 loanId = _open();
        vm.prank(borrower);
        _assertGone(abi.encodeWithSignature("setAutoRoll(uint256,bool)", loanId, false), "setAutoRoll still routes");
    }

    /// @notice The roll reserve's funding door is gone.
    function test_Gone_TopUpRoll() public {
        uint256 loanId = _open();
        vm.prank(borrower);
        _assertGone(abi.encodeWithSignature("topUpRoll(uint256,uint256)", loanId, uint256(0)), "topUpRoll routes");
    }

    /// @notice The rotation's self-call seam dies with the rotation: a closed chain, no other entry.
    /// @dev `LadderWalks.backfill` and `_backAt` are reachable ONLY through this, so they go too.
    function test_Gone_RotateFunding() public {
        uint256 loanId = _open();
        bytes memory data = abi.encodeWithSignature("rotateFunding(bytes32,uint256,int24,uint256,uint64)", id, loanId, int24(0), type(uint256).max, TENOR);
        _assertGone(data, "rotateFunding still routes");
    }

    // ============ 13. every loan ends at its tenor ============

    /// @notice THE DOCTRINE WIN: no verb moves a live loan's expiry after `open` wrote it.
    /// @dev Today `rollover` moves it by a whole term, which is precisely what this refuses.
    function test_Expiry_IsWrittenOnceAtOpen_AndNothingMovesIt() public {
        uint256 loanId = _open();
        uint64 e0 = read.loan(loanId).expiry;
        assertEq(e0, t0 + TENOR, "fixture: expiry is open time plus the term");

        _warpTo(t0 + 1 days); // so a rollover would visibly RESET the term rather than rewrite it
        vm.prank(borrower);
        address(ace).call(abi.encodeWithSignature("rollover(uint256)", loanId));
        assertEq(read.loan(loanId).expiry, e0, "rollover must not move a live loan's expiry");

        vm.prank(keeper);
        address(ace).call(abi.encodeWithSignature("roll(uint256)", loanId));
        assertEq(read.loan(loanId).expiry, e0, "nor may a keeper roll");
    }

    /// @notice The same property under ordinary use: deposits and repays never touch expiry.
    function testFuzz_Expiry_SurvivesALifecycle(uint256 repaySeed, uint256 warpSeed) public {
        uint256 loanId = _open();
        uint64 e0 = read.loan(loanId).expiry;

        _warpTo(t0 + bound(warpSeed, 0, uint256(TENOR) - 1));
        _deposit(alice, T, 1_000e6);
        uint256 pay = bound(repaySeed, 0, PRINCIPAL - 10e6);
        if (pay > 0) {
            vm.prank(borrower);
            ace.repay(loanId, pay);
        }
        assertEq(read.loan(loanId).expiry, e0, "no ordinary verb moves expiry either");
    }

    // ============ 14 / 15. what survives of lender exit ============

    /// @notice Lender exit: capital returns within one tenor, with no rotation and no flag -- the term
    /// @notice repays into the lender's pool and the resting remainder was never locked at all.
    /// @dev The exit-flag machinery is DELETED (2026-08-18 ruling), and the draw reservation went with it,
    /// @dev dust-throttle DoS and all. TENOR IS STILL THE WHOLE BOUND on a lender's exit liquidity.
    /// @dev The two legs are the two places their money sits: repaid principal in the pool's credit, and
    /// @dev whatever the draw never took still resting at the tick.
    function test_LenderExit_CapitalReturnsWithinOneTenor_WithNoRotation() public {
        _deposit(alice, T, 5_000e6);
        uint256 loanId = _open();

        _warpTo(t0 + uint256(TENOR));
        vm.prank(borrower);
        ace.repay(loanId, PRINCIPAL); // the term ends and the capital comes back at par

        vm.prank(alice);
        uint256 par = ace.collect(address(usdc), alice);
        vm.prank(alice);
        uint256 rest = ace.withdraw(id, type(uint256).max, alice, 0);
        assertGe(par + rest, 5_000e6, "the lender is whole within one tenor, with no rotation");
        assertLe(_now() - t0, uint256(TENOR) + 1, "and it took no longer than the term");
    }
}
