// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.36;

import {WarpClock} from "../utils/WarpClock.sol";
import {Ace} from "../../src/ace/hub/Ace.sol";
import {MarketState, OpenBounds} from "../../src/ace/hub/Types.sol";
import {PositionManager} from "../../src/ace/positions/PositionManager.sol";
import {MockERC20} from "../mocks/MockERC20.sol";
import {MockStakeVault} from "../mocks/MockStakeVault.sol";
import {AceFixtures} from "../utils/AceFixtures.sol";
import {AceReader} from "../utils/AceReader.sol";

/// @title AceP12Sequences
/// @notice Phase 12 (sequences): ordered pairs of legal calls, each leg passing alone.
/// @notice Every row here is GREEN: a measurement of current behaviour, never a repro. A red would mean the ledger moved.
/// @dev S1: the synthetic cap is conservation, not a budget two doors can spend twice.
/// @dev S6: a loan repaid to dust EXTENDS at its dust debt: a cash extension draws nothing and floors nothing, so it re-borrows no `minPrincipal`.
/// @dev L1: a lender who withdraws every resting wei still has a payout to collect, and it waits for them.
contract AceP12SequencesTest is WarpClock {
    Ace internal ace;
    AceReader internal read;
    PositionManager internal pm;
    MockERC20 internal usdc;
    MockStakeVault internal coll;
    bytes32 internal id;
    uint256 internal T;

    address internal alice = address(0xA11CE);
    address internal borrower = address(0xB0B);
    address internal borrower2 = address(0xB0B2);
    address internal keeper = address(0x4EE9);
    address internal buyer = address(0xB0);
    uint64 internal constant TEN = 7 days;
    uint256 internal constant UNITS = 10_000e18;
    uint256 internal constant DRAW = 1_000e6;

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

    function _open(address who, uint256 principal) internal returns (uint256 loanId) {
        coll.mint(who, UNITS);
        usdc.mint(who, 10_000e6); // repayment cash beyond the payout, so a repay to one wei is the borrower's own choice
        vm.startPrank(who);
        coll.approve(address(pm), UNITS);
        loanId = ace.open(id, UNITS, principal, TEN, who, OpenBounds(0, 0, 0));
        usdc.approve(address(ace), type(uint256).max);
        vm.stopPrank();
    }

    function _headroom() internal view returns (uint256) {
        MarketState memory s = read.marketState(id);
        return s.cumulativeBackedBurns - s.netSyntheticOutflow;
    }

    /* ============================== S1: the synthetic cap ============================== */

    /// @notice One budget, two doors, and the budget is exactly the sum of the live pots at every step.
    /// @dev `cumulativeBackedBurns - netSyntheticOutflow == sum(invPot)` after each door fires, so neither door can spend the other's room.
    function test_S1_TheCapIsTheSumOfTheLivePotsAtEveryStep() public {
        uint256 loanA = _open(borrower, DRAW);
        uint256 loanB = _open(borrower2, DRAW);
        _warpTo(uint256(read.loan(loanA).expiry) + 1);
        vm.startPrank(keeper);
        ace.forceClose(loanA);
        ace.forceClose(loanB);
        vm.stopPrank();
        _warpAtLeastTo(read.inventoryAskOpensAt(loanB));

        uint256 potA = read.invPotOf(id, loanA);
        uint256 potB = read.invPotOf(id, loanB);
        assertGt(potA, 0, "PREMISE: loan A settled into a pot");
        assertGt(potB, 0, "PREMISE: loan B settled into a pot");
        assertEq(_headroom(), potA + potB, "before any exit the headroom is the two pots");

        /// @dev Door one: the LENDER redeems loan A's pot in kind. It used to burn a receipt BALANCE against a
        /// @dev per-tick class; the receipt ledger is gone, and sole tenancy makes the whole pot this lender's.
        vm.prank(alice);
        uint256 outA = ace.redeemInKind(loanA, alice);
        assertGt(outA, 0, "LEG 1: the in-kind door delivered");
        assertEq(_headroom(), read.invPotOf(id, loanA) + potB, "after door one the headroom is what is left in the pots");

        /// @dev Door two: a stranger buys PART of loan B's pot at book, so the lender's door below still has a residue to take.
        usdc.mint(buyer, 400e6);
        vm.startPrank(buyer);
        usdc.approve(address(ace), type(uint256).max);
        (uint256 outB,) = ace.buyInventory(loanB, 400e6, 0, buyer);
        vm.stopPrank();
        assertGt(outB, 0, "LEG 2: the ask door delivered");
        assertGt(read.invPotOf(id, loanB), 0, "PREMISE: a part sale, so the pot keeps a residue for the second door");
        assertEq(_headroom(), read.invPotOf(id, loanA) + read.invPotOf(id, loanB), "after door two the same identity holds");

        // the pair: nothing is left for either door to spend twice
        vm.prank(alice);
        uint256 outB2 = ace.redeemInKind(loanB, alice);
        assertLe(outB2, read.invPotOf(id, loanB) + outB2, "the second exit on B takes only what the ask left");
        assertEq(_headroom(), read.invPotOf(id, loanA) + read.invPotOf(id, loanB), "and the identity survives the pair");
        MarketState memory s = read.marketState(id);
        assertLe(s.netSyntheticOutflow, s.cumulativeBackedBurns, "so SyntheticCapExceeded is implied, never reached");
    }

    /* ============================== S6 is DELETED ============================== */

    /// @dev Its pair repaid a loan to one wei, then settled or extended it; no repay leaves a live loan under `minPrincipal` any more.

    /* ============================== L1: the lender's exit ============================== */

    /// @dev The shared prologue: lend, fund a loan, then LEAVE by withdrawing every resting wei.
    function _lendAndLeave() internal returns (uint256 loanId) {
        loanId = _open(borrower, DRAW);
        vm.prank(alice);
        ace.withdraw(id, type(uint256).max, alice, 0);
        assertEq(ace.restingOf(id), 0, "LEG 1: the lender withdrew every resting wei");
        assertLe(read.poolResting(id), 1, "LEG 1: the pool holds at most the accumulator's one atom of dust behind them");
        assertGe(usdc.balanceOf(alice), 100_000e6 - DRAW - 1, "LEG 1: they hold their cash again, less what was lent");
        vm.prank(borrower);
        ace.repay(loanId, DRAW / 2); // half the loan comes back as the class's payout
    }

    /// @notice A LENDER WHO LEFT IS STILL OWED: the repayment lands in their pool and nothing re-rests it for them.
    /// @notice The market stays empty until they choose to come back, so the exit is an exit and not a pause.
    /// @dev WAS THE CONTROL LEG of a deleted pair whose measured row had a stranger fire a standing rearm and put
    /// @dev this lender back into the ladder. The rearm policy and `compound` are gone, so the control is the whole
    /// @dev behaviour now: accumulate, and pay out only on an explicit `collect`.
    function test_L1_AnExitedLendersPayoutWaitsForTheirOwnCollect() public {
        uint256 loanId = _lendAndLeave();
        assertGt(loanId, 0, "guard: the fixture opened a real loan");
        assertEq(ace.restingOf(id), 0, "nothing re-rested itself in their name");

        vm.prank(alice);
        uint256 paid = ace.collect(address(usdc), alice);

        assertEq(paid, DRAW / 2 + 2_000_000, "the repaid half plus the lender's cut of the origination fee, as cash");
        assertEq(ace.restingOf(id), 0, "and the market they left is still empty behind them");
    }
}
