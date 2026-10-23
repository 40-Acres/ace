// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.36;

import {WarpClock} from "../utils/WarpClock.sol";
import {Ace} from "../../src/ace/hub/Ace.sol";
import {GateRefused, NotTheLender} from "../../src/ace/hub/Lender.sol";
import {MarketParams, OpenBounds} from "../../src/ace/hub/Types.sol";
import {PositionManager} from "../../src/ace/positions/PositionManager.sol";
import {MockERC20} from "../mocks/MockERC20.sol";
import {MockPersistenceRecord} from "../mocks/MockPersistenceRecord.sol";
import {MockStakeVault} from "../mocks/MockStakeVault.sol";
import {AceFixtures} from "../utils/AceFixtures.sol";
import {AceReader} from "../utils/AceReader.sol";

/// @title AceSoleTenancyRest
/// @notice ONE lender's cash rests here, and the hub itself enforces it -- not a creator-chosen gate.
/// @notice THE HAZARD THIS PINS: `Lender.restRefusal`'s gate leg is the ONLY admission check on the rest path,
/// @notice and `Lender.bookCash` re-asserts the same tenancy where the cash lands, never assuming the asker did.
/// @dev So deleting `canDeposit` without a replacement would leave BOTH doors open to a stranger. Units stay
/// @dev transferable, so unit custody alone must never be what admits cash to a market's resting ladder.
/// @dev Reasoning: the design record.
contract AceSoleTenancyRestTest is WarpClock {
    Ace internal ace;
    AceReader internal read;
    PositionManager internal pm;
    MockERC20 internal usdc;
    MockStakeVault internal vault;
    MockPersistenceRecord internal record;
    bytes32 internal id;

    address internal alice = address(0xA11CE); // the market's ONE named lender
    address internal mallory = address(0x4A11);
    address internal borrower = address(0xB0B);

    uint64 internal constant TEN7 = 7 days;
    uint256 internal constant TOP = 500_000e6;
    uint256 internal T;

    function setUp() public {
        _warpTo(1_000_000);
        usdc = new MockERC20("USD Coin", "USDC", 6);
        vault = new MockStakeVault(42);
        T = AceFixtures.priceAt(address(usdc), address(vault), 0);
        record = new MockPersistenceRecord(address(usdc), address(vault));

        MarketParams memory p = AceFixtures.marketParams(address(usdc), address(vault));
        p.record = address(record);
        p.minTenor = TEN7;
        p.maxTenor = TEN7;
        p.lender = alice; // the market names ITS lender; nobody else may rest here
        AceFixtures.Deployment memory d = AceFixtures.deploy(p);
        (ace, pm, read, id) = (d.ace, d.positionManager, d.read, d.id);
    }

    function _fund(address who, uint256 amt) internal {
        usdc.mint(who, amt);
        vm.prank(who);
        usdc.approve(address(ace), amt);
    }

    /// @notice The named lender rests, and that is the whole of the deposit door's admission question.
    function test_Rest_TheNamedLenderMayDeposit() public {
        _fund(alice, TOP);
        vm.prank(alice);
        ace.deposit(id, TOP);
        assertGt(read.marketState(id).cash, 0, "the tenant's cash rests");
    }

    /// @notice A STRANGER may not deposit, and the hub says so itself rather than asking a creator-chosen gate.
    /// @dev This is the property the whole deletion rests on: `b.cash` IS the named lender's balance,
    /// @dev so nothing has to attribute a tick between owners. One foreign lot would falsify that.
    function test_Rest_AStrangerMayNotDeposit() public {
        _fund(mallory, TOP);
        vm.prank(mallory);
        vm.expectRevert(GateRefused.selector);
        ace.deposit(id, TOP);
    }

    /// @notice The refusal is NAMED rather than empty, so a keeper reads a reason instead of a bare failure.
    /// @dev It WAS also surfaced by `Ace.rearmRefusal` as the `Gate` ordinal; that view went with the rearm policy,
    /// @dev so the selector on the revert is now the whole of what a caller has to tell two refusals apart.
    function test_Rest_TheRefusalIsStillNamed() public {
        _fund(mallory, TOP);
        vm.prank(mallory);
        /// @dev THE LIVE DOOR, hand-encoded so a revert with NO data is distinguishable from a named one.
        /// @dev It WAS the tick-and-horizon form, which does not dispatch at all and reverted empty for that.
        (bool ok, bytes memory ret) = address(ace).call(abi.encodeWithSignature("deposit(bytes32,uint256)", id, TOP));
        assertFalse(ok, "refused");
        assertGt(ret.length, 0, "and by NAME -- an empty revert would tell a keeper nothing");
        assertEq(bytes4(ret), GateRefused.selector, "and by the GATE name: the ordinal a keeper reads must be the tenancy one");
    }

    /// @notice THE EXIT DOOR CARRIES THE SAME TENANCY CHECK, and it is the half a deposit test cannot see.
    /// @notice Entry is gated by `restRefusal`; withdrawal is gated by `_onlyLender`, a different guard on a
    /// @notice different line, and it is the one that stands between a stranger and the tenant's resting cash.
    /// @dev Measured green BOTH WAYS: with `_onlyLender` deleted from `Lender.withdraw` the whole tree stayed
    /// @dev green, so nothing else in it was holding this. The tenant's own balance is asserted intact after.
    function test_Rest_AStrangerMayNotWithdrawTheTenantsCash() public {
        _fund(alice, TOP);
        vm.prank(alice);
        ace.deposit(id, TOP);

        vm.prank(mallory);
        vm.expectRevert(NotTheLender.selector);
        ace.withdraw(id, type(uint256).max, mallory, 0);

        assertEq(read.marketState(id).cash, TOP, "and every wei of the tenant's cash is still resting");
    }

    /// @notice The named lender's OWN withdrawal goes through, so the row above is a guard and not a brick.
    function test_Rest_TheNamedLenderMayWithdraw() public {
        _fund(alice, TOP);
        vm.prank(alice);
        ace.deposit(id, TOP);

        vm.prank(alice);
        uint256 paid = ace.withdraw(id, type(uint256).max, alice, 0);

        assertEq(paid, TOP, "the tenant takes their whole resting balance");
        assertEq(read.marketState(id).cash, 0, "and the market is empty");
    }
}
