// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.36;

import {Vm} from "forge-std/Vm.sol";
import {WarpClock} from "../utils/WarpClock.sol";
import {Ace, PushRefused} from "../../src/ace/hub/Ace.sol";
import {Borrower} from "../../src/ace/hub/Borrower.sol";
import {MarketParams, OpenBounds} from "../../src/ace/hub/Types.sol";
import {AceLens} from "../../src/ace/lens/AceLens.sol";
import {AceInventoryLens} from "../../src/ace/lens/AceInventoryLens.sol";
import {MockERC20} from "../mocks/MockERC20.sol";
import {MockBlacklistERC20} from "../mocks/MockBlacklistERC20.sol";
import {AceFixtures} from "../utils/AceFixtures.sol";
import {AceReader} from "../utils/AceReader.sol";
import {GUARD_TRIP} from "../utils/GuardTrip.sol";

/// @notice The two hub doors a hook token re-enters, and the lock it reads.
interface IHookedHub {
    function sweepRevenue(address quote) external;
    function deposit(bytes32 id, uint256 assets) external;
    function notEntered() external view returns (bool);
}

/// @notice The shipped lens's pot view, as a hook reads it mid-sweep.
interface IPotView {
    function protocolRevenue(address quote) external view returns (uint256);
}

/// @notice A quote whose transfer to one armed recipient calls back into the hub before it moves a balance.
/// @dev Its hook reads the pot through the lens, then re-enters the sweep for its own quote, another quote's sweep, and `deposit`.
/// @dev `swallow` false bubbles the first refusal, so the transfer itself reverts; true records every refusal and finishes the move.
contract HookQuote {
    string public name = "Hook";
    string public symbol = "HOOK";
    uint8 public decimals = 6;
    mapping(address => uint256) public balanceOf;
    mapping(address => mapping(address => uint256)) public allowance;

    address public hookTo; // the one recipient whose incoming transfer fires the hook; zero while unarmed
    IHookedHub public hub;
    IPotView public lens;
    address public otherQuote;
    bool public swallow;

    bool public ran;
    bool public hubEntered;
    uint256 public seenPot;
    bytes4 public sameWhy;
    bytes4 public otherWhy;
    bytes4 public depositWhy;

    function arm(address to, address h, address l, address other, bool sw) external {
        (hookTo, hub, lens, otherQuote, swallow) = (to, IHookedHub(h), IPotView(l), other, sw);
    }

    function mint(address to, uint256 a) external {
        balanceOf[to] += a;
    }

    function approve(address s, uint256 a) external returns (bool) {
        allowance[msg.sender][s] = a;
        return true;
    }

    function transfer(address to, uint256 a) external returns (bool) {
        if (to == hookTo && to != address(0)) _hook();
        balanceOf[msg.sender] -= a;
        balanceOf[to] += a;
        return true;
    }

    function transferFrom(address f, address t, uint256 a) external returns (bool) {
        uint256 al = allowance[f][msg.sender];
        if (al != type(uint256).max) allowance[f][msg.sender] = al - a;
        balanceOf[f] -= a;
        balanceOf[t] += a;
        return true;
    }

    function _hook() private {
        ran = true;
        hubEntered = !hub.notEntered();
        seenPot = lens.protocolRevenue(address(this));
        (bool ok, bytes memory ret) = address(hub).call(abi.encodeCall(IHookedHub.sweepRevenue, (address(this))));
        if (!ok && !swallow) {
            assembly ("memory-safe") {
                revert(add(ret, 0x20), mload(ret))
            }
        }
        sameWhy = ok ? bytes4(0) : bytes4(ret);
        (ok, ret) = address(hub).call(abi.encodeCall(IHookedHub.sweepRevenue, (otherQuote)));
        otherWhy = ok ? bytes4(0) : bytes4(ret);
        (ok, ret) = address(hub).call(abi.encodeCall(IHookedHub.deposit, (bytes32(0), 0)));
        depositWhy = ok ? bytes4(0) : bytes4(ret);
    }
}

/// @title AceRevenuePotHardening
/// @notice The per-quote sweep at its seams: a re-entering quote, `multicall`, quotes no market names, the event's shape, a fuzzed ledger.
/// @notice And the inventory lens's fixed price frame, on a pair whose decimals are far from the baseline.
/// @dev `AceRevenuePot` and `AceRevenueSweep` pin the door's core rows; nothing here repeats one.
/// @dev Every market here is recordless, so no row depends on a record's answer.
contract AceRevenuePotHardeningTest is WarpClock {
    MockERC20 internal usdc;
    MockERC20 internal dai;
    MockERC20 internal coll;

    Ace internal ace;
    AceReader internal read;
    AceLens internal lens; // the shipped lens, read beside the test reader so the deployed view is exercised
    bytes32 internal id;

    address internal alice = AceFixtures.LENDER;
    address internal carol = makeAddr("carol");
    address internal borrower = address(0xB0B);
    address internal keeper = address(0xCAFE);
    address internal bob = makeAddr("bob");
    address internal treasury = AceFixtures.TREASURY;

    uint64 internal constant TEN30 = 30 days;
    uint256 internal constant COLL = 100_000e18;
    uint256 internal constant CASH = 900_000e6;
    uint256 internal constant P = 10_000e6;

    OpenBounds internal OFF = OpenBounds(0, 0, 0);

    bytes32 internal constant OPENED = keccak256("Opened(uint256,bytes32,address,uint256,uint256,uint256,uint64)");

    event RevenueSwept(address indexed quote, address indexed to, uint256 amount);

    function setUp() public {
        _warpTo(1_000_000);
        usdc = new MockERC20("USD Coin", "USDC", 6);
        dai = new MockERC20("Dai Six", "DAI6", 6);
        coll = new MockERC20("Collateral", "COLL", 18);
        AceFixtures.Deployment memory d = AceFixtures.deployWithTreasury(_paramsFor(address(usdc)), treasury);
        (ace, read, id) = (d.ace, d.read, d.id);
        lens = new AceLens(address(ace));
        _deposit(id, address(usdc), alice, CASH);
    }

    /* ============================== a re-entering quote ============================== */

    /// @notice A quote that calls back from its treasury transfer meets the hub's lock on every door, and the pot pays exactly once.
    /// @notice Bubbled, the guard's refusal fails the transfer, so the sweep reverts `PushRefused` with the pot whole.
    /// @notice Swallowed, the hook saw the pot already cleared, and another quote's pot neither moved nor paid.
    function test_HookQuoteReentryMeetsTheLockAndPaysOnce() public {
        HookQuote hq = new HookQuote();
        bytes32 hid = _market(address(hq), alice);
        bytes32 daiId = _market(address(dai), alice);
        _open(hid, P);
        _open(daiId, P);
        uint256 heldH = read.revenuePot(address(hq));
        uint256 heldD = read.revenuePot(address(dai));
        assertGt(heldH, 0, "guard: the hook quote's open banked a cut");
        assertGt(heldD, 0, "guard: the other quote's pot is not empty, so a leak into it would show");

        hq.arm(treasury, address(ace), address(lens), address(dai), false);
        uint256 hubH = hq.balanceOf(address(ace));
        vm.expectRevert(PushRefused.selector);
        ace.sweepRevenue(address(hq));
        assertEq(read.revenuePot(address(hq)), heldH, "a bubbled re-entry reverts the sweep with the pot whole");
        assertEq(hq.balanceOf(address(ace)), hubH, "and moves nothing");

        hq.arm(treasury, address(ace), address(lens), address(dai), true);
        vm.expectEmit(true, true, false, true, address(ace));
        emit RevenueSwept(address(hq), treasury, heldH);
        ace.sweepRevenue(address(hq));

        assertTrue(hq.ran() && hq.hubEntered(), "guard: the hook ran inside the hub's guarded body");
        assertEq(hq.seenPot(), 0, "CEI: the pot was cleared before the token was called");
        assertEq(bytes32(hq.sameWhy()), bytes32(GUARD_TRIP), "re-entering the same quote's sweep trips the guard");
        assertEq(bytes32(hq.otherWhy()), bytes32(GUARD_TRIP), "so does another quote's sweep: one lock per hub, not per pot");
        assertEq(bytes32(hq.depositWhy()), bytes32(GUARD_TRIP), "and every other guarded verb");
        assertEq(hq.balanceOf(treasury), heldH, "the treasury was paid the pot exactly once");
        assertEq(hq.balanceOf(address(ace)), hubH - heldH, "and the hub paid exactly that");
        assertEq(read.revenuePot(address(hq)), 0, "the pot ends empty");
        assertEq(lens.protocolRevenue(address(hq)), 0, "and the shipped lens agrees");
        assertEq(read.revenuePot(address(dai)), heldD, "the other quote's pot is untouched");
        assertEq(dai.balanceOf(treasury), 0, "and none of it was paid");
    }

    /* ============================== multicall ============================== */

    /// @notice A batch that opens and then sweeps pays the treasury the cut its own open banked, the open running as the caller.
    function test_MulticallOpenThenSweepPaysTheBatchsOwnCut() public {
        Borrower.Quote memory q = ace.previewOpen(id, COLL, P, TEN30, borrower, OFF);
        assertGt(q.protocolFee, 0, "guard: the open prices a cut");
        assertEq(read.revenuePot(address(usdc)), 0, "premise: the pot starts empty, so the sweep can only pay this batch's cut");
        _fundCollateral(borrower, COLL);

        bytes[] memory calls = new bytes[](2);
        calls[0] = abi.encodeCall(Ace.open, (id, COLL, P, TEN30, borrower, OFF));
        calls[1] = abi.encodeCall(Ace.sweepRevenue, (address(usdc)));
        vm.expectEmit(true, true, false, true, address(ace));
        emit RevenueSwept(address(usdc), treasury, q.protocolFee);
        vm.prank(borrower);
        bytes[] memory out = ace.multicall(calls);

        uint256 loanId = abi.decode(out[0], (uint256));
        assertEq(read.loan(loanId).borrower, borrower, "the open leg ran as the caller");
        assertEq(usdc.balanceOf(treasury), q.protocolFee, "the sweep leg paid exactly the open leg's cut");
        assertEq(read.revenuePot(address(usdc)), 0, "and left the pot empty");
        assertEq(out[1].length, 0, "the sweep leg returns nothing");
    }

    /// @notice One batch sweeps two quotes: each pot pays its own amount to the treasury, and both end empty.
    function test_MulticallSweepsTwoQuotes() public {
        bytes32 daiId = _market(address(dai), alice);
        _open(id, P);
        _open(daiId, P);
        uint256 heldU = read.revenuePot(address(usdc));
        uint256 heldD = read.revenuePot(address(dai));
        assertGt(heldU, 0, "guard: the first pot is not empty");
        assertGt(heldD, 0, "guard: the second pot is not empty");

        bytes[] memory calls = new bytes[](2);
        calls[0] = abi.encodeCall(Ace.sweepRevenue, (address(usdc)));
        calls[1] = abi.encodeCall(Ace.sweepRevenue, (address(dai)));
        vm.prank(keeper);
        ace.multicall(calls);

        assertEq(usdc.balanceOf(treasury), heldU, "the first quote paid its own pot");
        assertEq(dai.balanceOf(treasury), heldD, "the second quote paid its own pot");
        assertEq(read.revenuePot(address(usdc)) + read.revenuePot(address(dai)), 0, "and both pots are empty");
    }

    /// @notice A refusing quote anywhere in a batch reverts the whole batch: the quote swept before it is restored too.
    function test_MulticallOneRefusingQuoteRevertsTheWholeBatch() public {
        MockBlacklistERC20 bad = new MockBlacklistERC20("Frozen", "FRZ", 6);
        bytes32 badId = _market(address(bad), alice);
        _open(id, P);
        _open(badId, P);
        uint256 heldU = read.revenuePot(address(usdc));
        uint256 heldB = read.revenuePot(address(bad));
        assertGt(heldU, 0, "guard: the good pot is not empty");
        assertGt(heldB, 0, "guard: the refusing pot is not empty");
        bad.setBlacklisted(treasury, true);

        bytes[] memory calls = new bytes[](2);
        calls[0] = abi.encodeCall(Ace.sweepRevenue, (address(usdc)));
        calls[1] = abi.encodeCall(Ace.sweepRevenue, (address(bad)));
        vm.expectRevert(PushRefused.selector);
        ace.multicall(calls);

        assertEq(read.revenuePot(address(usdc)), heldU, "the good quote's pot is restored with the batch");
        assertEq(usdc.balanceOf(treasury), 0, "and its payment unwound");
        assertEq(read.revenuePot(address(bad)), heldB, "the refusing pot is whole");
    }

    /* ============================== quotes no market names ============================== */

    /// @notice A sweep keyed by an address no market quotes in is a no-op: no revert, no token call, no log.
    /// @notice A live pot in another quote stays put, so a sweep that ignored its key would show here.
    function test_SweepOfAQuoteNoMarketNamesIsANoOp() public {
        _open(id, P);
        uint256 heldU = read.revenuePot(address(usdc));
        assertGt(heldU, 0, "guard: a real pot is live beside the empty ones");
        address eoa = makeAddr("eoa");

        vm.expectCall(address(usdc), abi.encodeWithSelector(MockERC20.transfer.selector), 0);
        vm.recordLogs();
        ace.sweepRevenue(address(0));
        ace.sweepRevenue(eoa);
        ace.sweepRevenue(address(lens)); // code, but no token surface
        ace.sweepRevenue(address(ace)); // the hub itself
        assertEq(vm.getRecordedLogs().length, 0, "no sweep logged anything");
        assertEq(read.revenuePot(address(usdc)), heldU, "the live pot in another quote did not move");
        assertEq(usdc.balanceOf(treasury), 0, "and nothing was paid from it");
    }

    /* ============================== the event's shape ============================== */

    /// @notice `RevenueSwept` is the sweep's one log: the canonical signature, quote and treasury indexed, the amount its one data word.
    function test_RevenueSweptLogShape() public {
        _open(id, P);
        uint256 held = read.revenuePot(address(usdc));
        assertGt(held, 0, "guard: there is a pot to sweep");

        vm.recordLogs();
        ace.sweepRevenue(address(usdc));
        Vm.Log[] memory logs = vm.getRecordedLogs();

        assertEq(logs.length, 1, "the sweep emits exactly one log");
        Vm.Log memory l = logs[0];
        assertEq(l.emitter, address(ace), "from the hub");
        assertEq(l.topics.length, 3, "the signature and two indexed fields");
        assertEq(l.topics[0], keccak256("RevenueSwept(address,address,uint256)"), "the canonical signature");
        assertEq(l.topics[0], Ace.RevenueSwept.selector, "which is the compiled event's");
        assertEq(l.topics[1], bytes32(uint256(uint160(address(usdc)))), "topic 1 is the quote");
        assertEq(l.topics[2], bytes32(uint256(uint160(treasury))), "topic 2 is the treasury");
        assertEq(l.data.length, 32, "one data word: the amount, with no market and no timestamp");
        assertEq(abi.decode(l.data, (uint256)), held, "and it is the whole pot");
    }

    /* ============================== the fuzzed ledger ============================== */

    /// @notice Opens across three markets in two quotes, with the share moved mid-run: each pot is the sum of its quotes' quoted cuts.
    /// @notice One sweep per quote pays the treasury exactly its pot, the hub falls by exactly that, and both pots end at zero.
    /// @dev The expected cut is the one `previewOpen` quoted at the share live at that open, so a change reaches only later fees.
    function testFuzz_AccrueThenSweep_PotsAreTheSumOfTheirCuts(uint256[6] memory ps, uint256 route, uint256 share) public {
        bytes32[3] memory mk = [id, _sibling(carol), _market(address(dai), alice)];
        share = bound(share, 0, 1000);
        uint256 wantU;
        uint256 wantD;
        for (uint256 i; i < 6; i++) {
            if (i == 3) {
                vm.prank(treasury);
                ace.setProtocolShareBps(share);
            }
            uint256 m = (route >> (i * 8)) % 3;
            uint256 principal = bound(ps[i], 10e6, 40_000e6);
            Borrower.Quote memory q = ace.previewOpen(mk[m], COLL, principal, TEN30, borrower, OFF);
            (, uint256 fee) = _open(mk[m], principal);
            assertEq(fee, q.fee, "guard: each open charged the fee it previewed");
            if (m == 2) wantD += q.protocolFee;
            else wantU += q.protocolFee;
        }
        assertEq(read.revenuePot(address(usdc)), wantU, "the usdc pot is the sum of both usdc markets' cuts");
        assertEq(read.revenuePot(address(dai)), wantD, "the dai pot is the sum of the dai market's cuts");
        assertEq(lens.protocolRevenue(address(usdc)), wantU, "the shipped lens reads the same usdc pot");
        assertEq(lens.protocolRevenue(address(dai)), wantD, "and the same dai pot");

        uint256 hubU = usdc.balanceOf(address(ace));
        uint256 hubD = dai.balanceOf(address(ace));
        vm.startPrank(keeper);
        ace.sweepRevenue(address(usdc));
        ace.sweepRevenue(address(dai));
        vm.stopPrank();

        assertEq(usdc.balanceOf(treasury), wantU, "the treasury gained exactly the usdc pot");
        assertEq(dai.balanceOf(treasury), wantD, "and exactly the dai pot");
        assertEq(hubU - usdc.balanceOf(address(ace)), wantU, "the hub paid exactly the usdc pot");
        assertEq(hubD - dai.balanceOf(address(ace)), wantD, "and exactly the dai pot");
        assertEq(read.revenuePot(address(usdc)) + read.revenuePot(address(dai)), 0, "both pots end at zero");
    }

    /* ============================== the inventory lens's fixed frame ============================== */

    /// @notice On an 18-decimal quote over 6-decimal collateral with the top fill fee, the lens's fixed frame prices what the hub sells.
    /// @notice `clearingBudget` buys the whole pot and one atom less does not; the walk's value equals the shipped lens's mark.
    /// @dev The inventory lens asks the lens for no market state at all, so a lens of another layout cannot hand it a wrong scale.
    function test_InventoryLensFixedFrameHoldsOnAWideDecimalPair() public {
        (bytes32 wid, uint256 loanId) = _settledWide();
        uint256 potUnits = lens.invPotOf(wid, loanId);
        assertGt(potUnits, 0, "guard: the settlement left a pot to sell");
        uint256 mark = lens.inventoryMark(wid, loanId);

        AceInventoryLens inv = new AceInventoryLens(address(ace), address(lens));
        vm.expectCall(address(lens), abi.encodeWithSelector(AceLens.marketState.selector), 0);
        uint256 budget = inv.clearingBudget(wid, loanId);
        (uint256 quoted, uint256 units, bool priced,) = inv.settledInventory(wid, 0, 8);
        assertTrue(priced, "guard: a recordless market prices at its own price");
        assertEq(units, potUnits, "the walk counts the pot");
        assertEq(quoted, mark, "and values it as the shipped lens marks it, to the wei");
        assertGt(budget, 0, "guard: the pot has a clearing budget");

        wide.mint(bob, budget);
        vm.prank(bob);
        wide.approve(address(ace), budget);
        uint256 snap = vm.snapshotState();
        vm.prank(bob);
        (uint256 shortOut,) = ace.buyInventory(loanId, budget - 1, 0, bob);
        assertLt(shortOut, potUnits, "one atom under the budget does not clear the pot: the frame is not too generous");
        vm.revertToState(snap);

        vm.prank(bob);
        (uint256 out, uint256 filled) = ace.buyInventory(loanId, budget, 0, bob);
        assertEq(out, potUnits, "the budget buys the whole pot: the frame is not too stingy");
        assertLe(filled, budget, "and charges no more than it");
        assertEq(lens.invPotOf(wid, loanId), 0, "the pot is empty");
    }

    MockERC20 internal wide; // the 18-decimal quote of the wide-pair row

    /// @dev An 18-decimal quote over 6-decimal collateral at the top fill fee: one loan opened, settled at expiry, and the hold run out.
    function _settledWide() internal returns (bytes32 wid, uint256 loanId) {
        wide = new MockERC20("Wide", "W18", 18);
        MockERC20 c6 = new MockERC20("Six", "C6", 6);
        MarketParams memory p = AceFixtures.marketParams(address(wide), address(c6));
        p.fillFeeBps = 50;
        p.minPrincipal = 10e18;
        wid = ace.createMarket(p);
        assertEq(read.marketState(wid).unitScale, 1 << 96, "premise: genesis wrote the one frame into this market too");
        _deposit(wid, address(wide), alice, 900_000e18);

        address custodian = ace.POSITION_MANAGER();
        c6.mint(borrower, 100_000e6);
        vm.prank(borrower);
        c6.approve(custodian, 100_000e6);
        vm.prank(borrower);
        loanId = ace.open(wid, 100_000e6, 10_000e18, p.minTenor, borrower, OFF);
        _warpTo(uint256(read.loan(loanId).expiry));
        vm.prank(keeper);
        ace.forceClose(loanId);
        _warpBy(1 hours); // past the market's inventory hold
    }

    /* ============================== helpers ============================== */

    /// @dev A recordless market in `quote`, band off, a 7 to 30 day term range.
    function _paramsFor(address quote) internal view returns (MarketParams memory p) {
        p = AceFixtures.marketParams(quote, address(coll));
        p.maxTenor = TEN30;
    }

    /// @dev A second usdc market on the hub, its rate one bps apart, lent by `lender`; funded.
    function _sibling(address lender) internal returns (bytes32 mid) {
        MarketParams memory p = _paramsFor(address(usdc));
        p.lenderAprBps = p.lenderAprBps + 1;
        p.lender = lender;
        mid = ace.createMarket(p);
        _deposit(mid, address(usdc), lender, CASH);
    }

    /// @dev A recordless market in `quote` lent by `lender`, funded.
    function _market(address quote, address lender) internal returns (bytes32 mid) {
        MarketParams memory p = _paramsFor(quote);
        p.lender = lender;
        mid = ace.createMarket(p);
        _deposit(mid, quote, lender, CASH);
    }

    function _deposit(bytes32 mid, address token, address lender, uint256 amt) internal {
        MockERC20(token).mint(lender, amt);
        vm.startPrank(lender);
        MockERC20(token).approve(address(ace), amt);
        ace.deposit(mid, amt);
        vm.stopPrank();
    }

    function _fundCollateral(address who, uint256 units) internal {
        address custodian = ace.POSITION_MANAGER(); // read BEFORE the prank: an argument's own call would spend it
        coll.mint(who, units);
        vm.prank(who);
        coll.approve(custodian, units);
    }

    /// @dev Opens in the borrower's name and returns the fee its `Opened` log reports.
    function _open(bytes32 mid, uint256 principal) internal returns (uint256 loanId, uint256 fee) {
        _fundCollateral(borrower, COLL);
        vm.recordLogs();
        vm.prank(borrower);
        loanId = ace.open(mid, COLL, principal, TEN30, borrower, OFF);
        Vm.Log[] memory logs = vm.getRecordedLogs();
        bool found;
        for (uint256 i; i < logs.length; i++) {
            Vm.Log memory l = logs[i];
            if (l.emitter != address(ace) || l.topics.length < 2 || l.topics[0] != OPENED || l.topics[1] != bytes32(loanId)) continue;
            (,, fee,) = abi.decode(l.data, (uint256, uint256, uint256, uint64));
            found = true;
        }
        require(found, "no Opened log names the loan");
    }
}
