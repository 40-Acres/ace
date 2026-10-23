// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.36;

import {Test} from "forge-std/Test.sol";
import {Vm} from "forge-std/Vm.sol";
import {stdError} from "forge-std/StdError.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {WarpClock} from "../utils/WarpClock.sol";
import {Ace} from "../../src/ace/hub/Ace.sol";
import {CashCapped, Lender} from "../../src/ace/hub/Lender.sol";
import {MarketParams, OpenBounds} from "../../src/ace/hub/Types.sol";
import {PositionManager} from "../../src/ace/positions/PositionManager.sol";
import {RevenueRouter} from "../../src/ace/treasury/RevenueRouter.sol";
import {MockERC20} from "../mocks/MockERC20.sol";
import {MockBurnableERC20} from "../mocks/MockBurnableERC20.sol";
import {MockPersistenceRecord} from "../mocks/MockPersistenceRecord.sol";
import {MockProxyERC20, MockUsdcImpl} from "../mocks/MockProxyERC20.sol";
import {AceFixtures} from "../utils/AceFixtures.sol";
import {AceReader} from "../utils/AceReader.sol";

/// @title MockCostlyERC20
/// @notice An HONEST quote whose transfer to one named recipient costs a fixed amount of gas, then delivers.
/// @dev Not hostile: given the gas, it pays. It models a token whose honest transfer needs more than the push budget.
contract MockCostlyERC20 {
    string public name = "Costly";
    string public symbol = "CST";
    uint8 public decimals = 6;
    mapping(address => uint256) public balanceOf;
    mapping(address => mapping(address => uint256)) public allowance;
    uint256 public totalSupply;
    address public costlyTo; // the one recipient whose transfer spends `cost`; zero arms none
    uint256 public cost; // gas spent before the move, on a transfer to `costlyTo`

    event Transfer(address indexed from, address indexed to, uint256 value);
    event Approval(address indexed owner, address indexed spender, uint256 value);

    function setCost(address to, uint256 c) external {
        (costlyTo, cost) = (to, c);
    }

    function mint(address to, uint256 amount) external {
        balanceOf[to] += amount;
        totalSupply += amount;
        emit Transfer(address(0), to, amount);
    }

    function approve(address spender, uint256 amount) external returns (bool) {
        allowance[msg.sender][spender] = amount;
        emit Approval(msg.sender, spender, amount);
        return true;
    }

    /// @notice Spends `cost` gas when paying `costlyTo`, then moves the balance like any token.
    function transfer(address to, uint256 amount) external returns (bool) {
        if (to == costlyTo && cost != 0) {
            uint256 start = gasleft();
            while (start - gasleft() < cost) {}
        }
        _move(msg.sender, to, amount);
        return true;
    }

    function transferFrom(address from, address to, uint256 amount) external returns (bool) {
        uint256 a = allowance[from][msg.sender];
        if (a != type(uint256).max) allowance[from][msg.sender] = a - amount;
        _move(from, to, amount);
        return true;
    }

    function _move(address from, address to, uint256 amount) private {
        balanceOf[from] -= amount;
        balanceOf[to] += amount;
        emit Transfer(from, to, amount);
    }
}

/// @title AceS2SweepHasNoUncappedExitTest
/// @notice Protocol revenue left the hub ONLY through the gas-capped push; the lender's credit had an uncapped `collect` beside it.
/// @notice A quote whose honest transfer to the treasury needed more than `PUSH_GAS` therefore stranded the market's revenue for good.
/// @notice FIXED (Y-4): the standalone `sweepRevenue` is uncapped and strict; the keeper piggyback keeps the fixed budget.
contract AceS2SweepHasNoUncappedExitTest is WarpClock {
    Ace internal ace;
    AceReader internal read;
    PositionManager internal pm;
    MockCostlyERC20 internal quote;
    MockERC20 internal coll;
    MockPersistenceRecord internal record;
    bytes32 internal mid;
    address internal treasury = AceFixtures.TREASURY;
    uint256 internal loanId;

    address internal alice = address(0xA11CE); // the market's one lender
    address internal borrower = address(0xB0B);
    address internal keeper = address(0xCAFE);

    uint256 internal constant DEPOSIT = 400_000e6;
    uint256 internal constant PRINCIPAL = 40_000e6;
    uint256 internal constant COLL = 100_000e18;
    uint64 internal constant TEN30 = 30 days;
    uint256 internal constant OVER = AceFixtures.PUSH_GAS + 20_000; // an honest transfer cost just past the budget

    function setUp() public {
        _warpTo(1_000_000);
        quote = new MockCostlyERC20();
        coll = new MockERC20("Collateral", "COLL", 18);
        record = new MockPersistenceRecord(address(quote), address(coll));
        MarketParams memory p = AceFixtures.marketParams(address(quote), address(coll));
        p.record = address(record);
        p.lender = alice;
        p.minTenor = 7 days;
        p.maxTenor = TEN30;
        AceFixtures.Deployment memory d = AceFixtures.deployWithTreasury(p, treasury);
        (ace, pm, read, mid) = (d.ace, d.positionManager, d.read, d.id);
        quote.mint(alice, DEPOSIT);
        vm.startPrank(alice);
        quote.approve(address(ace), DEPOSIT);
        ace.deposit(mid, DEPOSIT);
        vm.stopPrank();
        coll.mint(borrower, COLL);
        vm.startPrank(borrower);
        coll.approve(address(pm), COLL);
        loanId = ace.open(mid, COLL, PRINCIPAL, TEN30, borrower, OpenBounds(0, 0, 0));
        vm.stopPrank();
    }

    function _owed() internal view returns (uint256 owed) {
        (,, owed) = read.lenderPools(alice, address(quote));
    }

    /// @notice CONTROL: with a cheap quote the standalone sweep delivers the whole banked revenue.
    function test_Control_ACheapQuoteSweepsTheRevenue() public {
        uint256 banked = read.protocolRevenue(mid);
        assertGt(banked, 0, "fixture: the open banked no protocol revenue");
        vm.prank(keeper);
        ace.sweepRevenue(mid);
        assertEq(read.protocolRevenue(mid), 0, "a cheap sweep left revenue banked");
        assertEq(quote.balanceOf(treasury), banked, "the treasury did not receive the banked revenue");
    }

    /// @notice PREMISE: the token pays the treasury when given the gas, so the failure below is the budget's, not the token's.
    function test_Premise_TheCostlyTransferDeliversWhenFunded() public {
        quote.setCost(treasury, OVER);
        quote.mint(keeper, 1e6);
        vm.prank(keeper);
        bool ok = quote.transfer{gas: 1_000_000}(treasury, 1e6);
        assertTrue(ok, "fixture: the costly token refused a funded transfer");
        assertEq(quote.balanceOf(treasury), 1e6, "fixture: the costly token did not deliver");
    }

    /// @notice At every generous limit the standalone sweep now delivers a costly quote's revenue whole.
    /// @dev Was the run's premise that no limit moved it: the capped push swallowed the failure and restored the counter.
    function test_EveryGenerousLimitDeliversTheRevenueOfACostlyQuote() public {
        quote.setCost(treasury, OVER);
        uint256 banked = read.protocolRevenue(mid);
        uint256[3] memory limits = [uint256(1_000_000), 5_000_000, 15_000_000];
        for (uint256 i; i < limits.length; i++) {
            uint256 snap = vm.snapshotState();
            vm.prank(keeper);
            (bool ok,) = address(ace).call{gas: limits[i]}(abi.encodeCall(Ace.sweepRevenue, (mid)));
            assertTrue(ok, "the strict sweep reverted though its transfer was paid for");
            assertEq(read.protocolRevenue(mid), 0, "the revenue left the hub");
            assertEq(quote.balanceOf(treasury), banked, "and the treasury received all of it");
            vm.revertToState(snap);
        }
    }

    /// @notice PREMISE, THE SIBLING: the same cost aimed at the LENDER fails its push, and its own `collect` brings the credit home.
    function test_Premise_TheLenderHasTheUncappedExitTheProtocolLacks() public {
        quote.setCost(alice, OVER);
        uint256 debt = read.debtOf(loanId);
        quote.mint(borrower, debt);
        vm.startPrank(borrower);
        quote.approve(address(ace), debt);
        vm.recordLogs();
        ace.repay{gas: 5_000_000}(loanId, debt);
        vm.stopPrank();
        uint256 owed = _owed();
        assertGt(owed, 0, "the closing repay's push did not fall back to the credit");
        assertTrue(_sawPushFailed(), "the lender push did not report failure");
        vm.prank(alice);
        uint256 paid = ace.collect(address(quote), alice);
        assertEq(paid, owed, "collect did not pay the whole credit");
        assertEq(_owed(), 0, "collect left credit behind");
        assertEq(quote.balanceOf(alice), owed, "the lender did not receive the credit");
    }

    /// @notice Revenue banked in a market whose quote transfers honestly reaches the treasury when the caller pays for it.
    /// @dev Was the run's RED row; the standalone door's remedy turned it green.
    function test_AnHonestlyPaidSweepDeliversTheRevenue() public {
        quote.setCost(treasury, OVER);
        uint256 banked = read.protocolRevenue(mid);
        vm.prank(keeper);
        ace.sweepRevenue{gas: 15_000_000}(mid);
        assertEq(quote.balanceOf(treasury), banked, "protocol revenue never left the hub though its transfer was paid for");
    }

    function _sawPushFailed() internal returns (bool) {
        bytes32 sig = Lender.LenderPushFailed.selector;
        Vm.Log[] memory logs = vm.getRecordedLogs();
        for (uint256 i; i < logs.length; i++) {
            if (logs[i].emitter == address(ace) && logs[i].topics.length > 0 && logs[i].topics[0] == sig) return true;
        }
        return false;
    }
}

/// @title AceS2QuoteBalanceFallTest
/// @notice A fall in the hub's QUOTE balance is paid by whichever party exits last, across markets and across lenders.
/// @dev The collateral twin halts every release instead (`PositionManager.CustodyUnderfunded`); the quote side has no such check.
contract AceS2QuoteBalanceFallTest is Test {
    Ace internal ace;
    MockBurnableERC20 internal quote;
    bytes32 internal ma; // alice's market
    bytes32 internal mc; // carol's market: same pair, same price, a different lender
    address internal alice = address(0xA11CE);
    address internal carol = address(0xCA201);
    uint256 internal constant LOT = 100_000e6;

    function setUp() public {
        quote = new MockBurnableERC20("Quote", "Q", 6);
        MockERC20 coll = new MockERC20("Collateral", "COLL", 18);
        MarketParams memory p = AceFixtures.marketParams(address(quote), address(coll));
        p.lender = alice;
        AceFixtures.Deployment memory d = AceFixtures.deploy(p);
        (ace, ma) = (d.ace, d.id);
        p.lender = carol;
        mc = ace.createMarket(p);
        _lend(alice, ma);
        _lend(carol, mc);
    }

    function _lend(address who, bytes32 id) internal {
        quote.mint(who, LOT);
        vm.startPrank(who);
        quote.approve(address(ace), LOT);
        ace.deposit(id, LOT);
        vm.stopPrank();
    }

    /// @notice PREMISE: after a fall of half one lot, the first lender out takes its whole lot and the second cannot.
    function test_Premise_TheLastLenderOutPaysTheWholeFall() public {
        assertEq(quote.balanceOf(address(ace)), 2 * LOT, "fixture: the hub does not hold both lots");
        quote.burn(address(ace), LOT / 2);
        vm.prank(alice);
        uint256 paid = ace.withdraw(ma, type(uint256).max, alice, 0);
        assertEq(paid, LOT, "the first lender out was not paid in full");
        vm.expectRevert();
        vm.prank(carol);
        ace.withdraw(mc, type(uint256).max, carol, 0);
        assertEq(ace.restingOf(mc), LOT, "carol's book moved though her exit failed");
        vm.prank(carol);
        ace.withdraw(mc, LOT / 2, carol, 0);
        assertEq(quote.balanceOf(carol), LOT / 2, "carol could not take what the fall left");
        assertEq(quote.balanceOf(address(ace)), 0, "the hub still holds quote");
        assertEq(ace.restingOf(mc), LOT / 2, "carol's book should still owe her the fallen half");
    }

    /// @notice `restRefusal` is TOTAL: an absurd lot refuses `CashCapped` by name; the cap test subtracts, so it cannot overflow.
    /// @dev Was the run's premise (YI-3) that the plain `cash + assets` sum panicked unnamed.
    function test_AnAbsurdDepositRefusesByName() public {
        assertGt(ace.restingOf(ma), 0, "fixture: the cash-cap sum needs cash resting to overflow");
        vm.expectRevert(CashCapped.selector);
        vm.prank(alice);
        ace.deposit(ma, type(uint256).max);
    }
}

/// @title AceS2UsdcPushCostTest
/// @notice What the hub's push of the USDC shape to a fresh RevenueRouter costs: a vault's quote is its asset, so this is the vault's push too.
/// @dev Each test body is its own transaction after a committed setUp, so every account and word starts cold.
contract AceS2UsdcPushCostTest is Test {
    Ace internal ace;
    address internal usdc;
    RevenueRouter internal router;

    uint256 internal constant SEED = 1_000_000e6;
    uint256 internal constant AMT = 1_000e6;

    function setUp() public {
        ace = AceFixtures.newAce();
        usdc = address(new MockProxyERC20(address(new MockUsdcImpl())));
        router = new RevenueRouter(address(this), address(0xBEEF));
        MockUsdcImpl(usdc).mint(address(ace), SEED); // the plain quote at the hub, for the reference row
    }

    /// @dev One cold push from the hub to a zero-balance router at a fat budget; returns the callee frame's spend.
    function _push(address token) internal returns (uint256 used) {
        vm.prank(address(ace));
        ace.pushToken{gas: 1_000_000}(token, address(router), AMT);
        used = vm.lastCallGas().gasTotalUsed;
    }

    /// @notice REFERENCE: the USDC-shaped push, all cold to a zero recipient, which is the record's sizing case.
    function test_Measure_UsdcShapePushToAFreshRouter() public {
        uint256 used = _push(usdc);
        emit log_named_uint("PUSH-COST usdc-shape, cold, zero router (used)", used);
        assertEq(IERC20(usdc).balanceOf(address(router)), AMT, "fixture: the reference push did not deliver");
    }
}
