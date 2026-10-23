// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.36;

import {WarpClock} from "../utils/WarpClock.sol";
import {Ace, ZeroWithdrawal} from "../../src/ace/hub/Ace.sol";
import {Lender} from "../../src/ace/hub/Lender.sol";
import {OpenBounds} from "../../src/ace/hub/Types.sol";
import {PositionManager} from "../../src/ace/positions/PositionManager.sol";
import {MockERC20} from "../mocks/MockERC20.sol";
import {MockStakeVault} from "../mocks/MockStakeVault.sol";
import {AceFixtures} from "../utils/AceFixtures.sol";
import {AceReader} from "../utils/AceReader.sol";

/// @title AceP11ZeroArgDoors
/// @notice MEASUREMENT: the sibling doors disagree on a zero amount. `withdrawCollateral(0)` refuses by name;
/// @notice `withdraw(.., 0)` is admitted, pays nothing, and logs nothing.
/// @dev Green rows: they pin current behaviour so the consolidation can cite it, not a correctness claim.
/// @dev THE SHARPER HALF OF THE MEASUREMENT IS GONE, and its going is the improvement. A zero withdraw used to
/// @dev CLOSE the lender's live lot and re-open an identical one, churning the lot index and emitting the zero
/// @dev `Withdraw` that `Lender.sol`'s own comment said never appeared. There are no lots: a market holds one
/// @dev resting balance, so a zero withdraw touches no index and the only disagreement left is the selector.
contract AceP11ZeroArgDoorsTest is WarpClock {
    Ace internal ace;
    AceReader internal read;
    PositionManager internal pm;
    MockERC20 internal usdc;
    MockStakeVault internal coll;
    bytes32 internal id;
    uint256 internal T;

    address internal alice = address(0xA11CE);
    address internal borrower = address(0xB0B);
    uint64 internal constant TEN = 7 days;

    function setUp() public {
        _warpTo(1_000_000);
        usdc = new MockERC20("USD Coin", "USDC", 6);
        coll = new MockStakeVault(42);
        AceFixtures.Deployment memory d = AceFixtures.deploy(AceFixtures.marketParams(address(usdc), address(coll)));
        (ace, pm, read, id) = (d.ace, d.positionManager, d.read, d.id);
        T = AceFixtures.priceAt(address(usdc), address(coll), 0);
        usdc.mint(alice, 100_000e6);
        vm.startPrank(alice);
        usdc.approve(address(ace), type(uint256).max);
        ace.deposit(id, 100_000e6);
        vm.stopPrank();
    }

    /// @dev A zero-asset withdraw is admitted and SILENT: it pays nothing, logs nothing, moves no token, and leaves the balance whole.
    /// @dev RENAMED from `test_Measure_AZeroWithdrawIsAdmittedAndLogsAZeroPayout`, which pinned `Withdraw(id, alice, alice, 0)`.
    /// @dev By ruling a zero payout is a no-op, so a lender cannot fill an INDEXED `to` of their choosing with zero-value logs.
    function test_Measure_AZeroWithdrawIsAdmittedAndLogsNothing() public {
        address victim = address(0xD00D); // any address a lender might name to spam its recipient-filtered history
        assertEq(ace.restingOf(id), 100_000e6, "PREMISE: the market rests the whole deposit");
        uint256 hubBal = usdc.balanceOf(address(ace));
        vm.recordLogs();
        vm.prank(alice);
        uint256 paid = ace.withdraw(id, 0, alice, 0);
        vm.prank(alice);
        uint256 spam = ace.withdraw(id, 0, victim, 0);
        assertEq(paid + spam, 0, "nothing paid, and neither call reverted");
        assertEq(vm.getRecordedLogs().length, 0, "no `Withdraw` and no zero-value `Transfer`: a zero payout is silent");
        assertEq(usdc.balanceOf(address(ace)), hubBal, "no token moved");
        assertEq(ace.restingOf(id), 100_000e6, "and the resting cash is bit-unchanged either side of it");
    }

    /// @dev The other quote exit is silent the same way: `collect` on an EMPTY pool returns 0 and logs nothing.
    function test_Measure_AnEmptyCollectIsAdmittedAndLogsNothing() public {
        assertEq(ace.lenderOwed(alice, address(usdc)), 0, "PREMISE: a deposit alone pools no credit");
        vm.recordLogs();
        vm.prank(alice);
        uint256 paid = ace.collect(address(usdc), address(0xD00D));
        assertEq(paid, 0, "nothing paid, and no revert");
        assertEq(vm.getRecordedLogs().length, 0, "no `Collected` and no zero-value `Transfer`");
    }

    /// @dev The borrower-side sibling refuses the same zero by name.
    function test_Measure_TheCollateralSiblingRefusesZeroByName() public {
        coll.mint(borrower, 10_000e18);
        vm.startPrank(borrower);
        coll.approve(address(pm), 10_000e18);
        uint256 loanId = ace.open(id, 10_000e18, 1_000e6, TEN, borrower, OpenBounds(0, 0, 0));
        vm.expectRevert(ZeroWithdrawal.selector);
        ace.withdrawCollateral(loanId, 0, borrower);
        vm.stopPrank();
    }
}
