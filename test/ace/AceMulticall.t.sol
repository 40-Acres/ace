// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.36;

import {Test} from "forge-std/Test.sol";
import {Ace} from "../../src/ace/hub/Ace.sol";
import {MarketParams, OpenBounds} from "../../src/ace/hub/Types.sol";
import {SelfCallOnly} from "../../src/ace/hub/Ace.sol";
import {BelowMinLot} from "../../src/ace/hub/Lender.sol";
import {PositionManager} from "../../src/ace/positions/PositionManager.sol";
import {MockERC20} from "../mocks/MockERC20.sol";
import {MockStakeVault} from "../mocks/MockStakeVault.sol";
import {MockPersistenceRecord} from "../mocks/MockPersistenceRecord.sol";
import {AceFixtures} from "../utils/AceFixtures.sol";
import {AceReader} from "../utils/AceReader.sol";

/// @title AceMulticall
/// @notice One transaction, several hub verbs, the caller's own identity throughout.
/// @notice Claim and deposit are two calls by ruling; this is how they ride one transaction.
/// @dev Failing-first; the design record.
contract AceMulticallTest is Test {
    Ace internal ace;
    AceReader internal read;
    PositionManager internal positionManager;
    MockERC20 internal usdc;
    MockStakeVault internal vault;
    MockPersistenceRecord internal record;
    bytes32 internal mid;

    address internal alice = address(0xA11CE);
    address internal borrower = address(0xB0BA);

    /// @dev WAS two rungs the legs deposited at separately. One market takes one balance, so every leg
    /// @dev below stacks onto what `setUp` already rested -- which is what `SEEDED` is for.
    uint256 internal constant SEEDED = 5_000e6;
    uint256 internal constant COLL = 10_000e18;
    uint256 internal constant PRINCIPAL = 4_500e6;

    function setUp() public {
        vm.warp(1_000_000);
        usdc = new MockERC20("USD Coin", "USDC", 6);
        vault = new MockStakeVault(42);
        record = new MockPersistenceRecord(address(usdc), address(vault));
        record.setObserved(AceFixtures.px(1e18, address(usdc), address(vault)));
        record.setMinPrice(AceFixtures.px(2e18, address(usdc), address(vault)));
        MarketParams memory p = AceFixtures.marketParams(address(usdc), address(vault));
        p.record = address(record);
        AceFixtures.Deployment memory d = AceFixtures.deploy(p);
        (ace, positionManager, read, mid) = (d.ace, d.positionManager, d.read, d.id);

        usdc.mint(alice, 10_000e6);
        vm.startPrank(alice);
        usdc.approve(address(ace), type(uint256).max);
        ace.deposit(mid, 5_000e6);
        vm.stopPrank();
    }

    function _openAndRepay() internal returns (uint256 id) {
        vault.mint(borrower, COLL);
        usdc.mint(borrower, 5_000e6);
        vm.startPrank(borrower);
        vault.approve(address(positionManager), COLL);
        usdc.approve(address(ace), type(uint256).max);
        id = ace.open(mid, COLL, PRINCIPAL, 0, borrower, OpenBounds(0, 0, 0));
        ace.repay(id, read.loan(id).debt);
        vm.stopPrank();
    }

    /// @dev The same open, repaid PART WAY, so the lender's credit is still pooled for a `collect` leg to move.
    /// @dev A CLOSING repay is a terminal door and the hub pushes the whole pool to the lender there, which
    /// @dev leaves the batches below with nothing to collect and their first leg asserting over a zero.
    /// @dev The draw is unchanged, so the resting-cash arithmetic these rows also check is untouched.
    function _openAndCredit() internal returns (uint256 id, uint256 owed) {
        vault.mint(borrower, COLL);
        usdc.mint(borrower, 5_000e6);
        vm.startPrank(borrower);
        vault.approve(address(positionManager), COLL);
        usdc.approve(address(ace), type(uint256).max);
        id = ace.open(mid, COLL, PRINCIPAL, 0, borrower, OpenBounds(0, 0, 0));
        ace.repay(id, read.loan(id).debt / 2);
        vm.stopPrank();
        (,, owed) = read.lenderPools(alice, address(usdc));
        assertEq(read.loan(id).closedAt, 0, "fixture: the loan is live, which is what left the credit to collect");
        assertGt(owed, 0, "fixture: and the partial repay really booked some");
    }

    /// @notice The recycling round trip: collect a repaid loan's credit, redeposit the proceeds, one tx.
    /// @notice THIS IS THE WHOLE OF A LENDER'S RE-LEND: the money comes home and goes back out in one transaction.
    function test_ClaimThenDeposit_OneTransaction() public {
        (, uint256 owed) = _openAndCredit();

        bytes[] memory calls = new bytes[](2);
        calls[0] = abi.encodeCall(Ace.collect, (address(usdc), alice));
        calls[1] = abi.encodeCall(Ace.deposit, (mid, 4_500e6));
        vm.prank(alice);
        bytes[] memory out = ace.multicall(calls);

        uint256 paid = abi.decode(out[0], (uint256));
        assertEq(paid, owed, "the collect leg paid the whole credit the market had booked");
        /// @dev The draw took `PRINCIPAL` out of the seeded balance and the deposit leg puts the same figure
        /// @dev back, so a completed round trip leaves the market exactly where it started.
        assertEq(ace.restingOf(mid), SEEDED, "and the deposit leg rested it back in the market");
    }

    /// @notice The caller's identity holds through every leg: `msg.sender` inside a delegatecall is the
    /// @notice ORIGINAL caller, never the hub.
    /// @dev SOLE TENANCY MAKES THIS SELF-ENFORCING, and the witness got sharper for it. The old form
    /// @dev asserted the lot was booked under alice rather than the hub, which needed a per-owner ledger
    /// @dev to read. Now the deposit door itself refuses anyone but the market's named lender -- so a hub
    /// @dev that lost the caller's identity here would revert `NotTheLender` instead of booking it wrong.
    /// @dev The deposit LANDING is therefore the whole proof, and it cannot pass for the wrong reason.
    function test_MsgSenderPreservedThroughDelegatecall() public {
        bytes[] memory calls = new bytes[](1);
        calls[0] = abi.encodeCall(Ace.deposit, (mid, 100e6));
        vm.prank(alice);
        ace.multicall(calls);
        assertEq(ace.restingOf(mid), SEEDED + 100e6, "it landed, so the leg ran as alice and never as the hub");
    }

    /// @notice One failing leg reverts the WHOLE batch, bubbling that leg's own error by name.
    /// @dev The failing leg is an EMPTY deposit, which is the one entry refusal a zero amount always trips.
    function test_InnerRevertBubblesAndRevertsWhole() public {
        bytes[] memory calls = new bytes[](2);
        calls[0] = abi.encodeCall(Ace.deposit, (mid, 100e6));
        // the one entry refusal left
        calls[1] = abi.encodeCall(Ace.deposit, (mid, 0));
        vm.prank(alice);
        vm.expectRevert(BelowMinLot.selector);
        ace.multicall(calls);
        assertEq(ace.restingOf(mid), SEEDED, "the passing first leg rolled back with the batch");
    }

    /// @notice The premise of the row above: a leg AT the floor goes through where an empty one does not.
    /// @dev Without this row the change above reads as a cosmetic swap of one small amount for another.
    /// @dev Was `test_ADustLegPassesWhileTheFloorIsOff`, which sent one wei against a stored floor of zero.
    /// @dev THE FLOOR IS `minDebt` ITSELF NOW. It was `ceil(minDebt / maxClaimTicks)`, because a draw could
    /// @dev reach the debt floor from many lots; one price collapses the two doors onto one number.
    function test_ALegAtTheFloorPasses() public {
        MarketParams memory p = ace.idToMarketParams(mid);
        uint256 ticket = p.minDebt;
        assertEq(ticket, 10e6, "PREMISE: the market's own quantum, which floors BOTH doors");

        bytes[] memory calls = new bytes[](2);
        calls[0] = abi.encodeCall(Ace.deposit, (mid, 100e6));
        calls[1] = abi.encodeCall(Ace.deposit, (mid, ticket));
        vm.prank(alice);
        ace.multicall(calls);
        assertEq(ace.restingOf(mid), SEEDED + 100e6 + ticket, "both legs booked, the floor-sized one included");
    }

    /// @notice The self-call plumbing stays closed: inside a multicall msg.sender is still the CALLER.
    function test_PushRevenueStillSelfCallOnly() public {
        bytes[] memory calls = new bytes[](1);
        calls[0] = abi.encodeCall(Ace.pushToken, (address(usdc), alice, 1));
        vm.prank(alice);
        vm.expectRevert(SelfCallOnly.selector);
        ace.multicall(calls);
    }

    /// @notice The guard composes: two guarded verbs run in sequence, not nested, so neither trips it.
    /// @dev `multicall` delegatecalls, so its legs share ONE address and therefore one transient lock --
    /// @dev which is exactly why this needs pinning, and why the pair must be sequential and not nested.
    function test_TwoGuardedVerbsInOneBatch() public {
        (, uint256 owed) = _openAndCredit();
        bytes[] memory calls = new bytes[](2);
        calls[0] = abi.encodeCall(Ace.collect, (address(usdc), alice));
        calls[1] = abi.encodeCall(Ace.withdraw, (mid, type(uint256).max, alice, 0));
        vm.prank(alice);
        bytes[] memory out = ace.multicall(calls);
        assertEq(abi.decode(out[0], (uint256)), owed, "collect then withdraw, one transaction");
    }
}
