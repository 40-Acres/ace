// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.36;

import {Vm} from "forge-std/Vm.sol";
import {WarpClock} from "../utils/WarpClock.sol";
import {Ace, PushRefused} from "../../src/ace/hub/Ace.sol";
import {Borrower} from "../../src/ace/hub/Borrower.sol";
import {MarketParams, MigrateArgs, Order, OpenBounds} from "../../src/ace/hub/Types.sol";
import {LoanMath} from "../../src/ace/hub/libraries/LoanMath.sol";
import {PositionManager} from "../../src/ace/positions/PositionManager.sol";
import {IPermit2} from "../../src/interfaces/IPermit2.sol";
import {MockERC20} from "../mocks/MockERC20.sol";
import {MockBlacklistERC20} from "../mocks/MockBlacklistERC20.sol";
import {MockPermit2} from "../mocks/MockPermit2.sol";
import {MockPersistenceRecord} from "../mocks/MockPersistenceRecord.sol";
import {DeleverageCrank} from "../utils/DeleverageCrank.sol";
import {AceFixtures} from "../utils/AceFixtures.sol";
import {AceReader} from "../utils/AceReader.sol";

/// @notice The per-quote sweep door, called through its own interface so this suite compiles on a hub that may lack it.
interface IRevenuePot {
    function sweepRevenue(address quote) external;
}

/// @notice The funding surface every quote in this suite shares, whichever mock it is.
interface IQuoteToken {
    function mint(address to, uint256 amount) external;
    function approve(address spender, uint256 amount) external returns (bool);
}

/// @notice An HONEST quote whose transfer to one address costs a fixed amount of gas: `laps` fresh SSTOREs, then a normal move.
/// @dev Nothing fails and nothing lies; the transfer is only dear, the shape a capped push cannot fund and an uncapped one can.
contract DearQuote {
    string public name = "Dear";
    string public symbol = "DEAR";
    uint8 public decimals = 6;
    mapping(address => uint256) public balanceOf;
    mapping(address => mapping(address => uint256)) public allowance;
    address public dearTo; // the one recipient a transfer is dear to
    uint256 public laps; // fresh slots written per dear transfer, ~22,100 gas each
    uint256 private _next = 1e9; // the first slot the next dear transfer writes, so every lap is a zero-to-nonzero store

    function setCost(address to, uint256 n) external {
        (dearTo, laps) = (to, n);
    }

    function mint(address to, uint256 a) external {
        balanceOf[to] += a;
    }

    function approve(address s, uint256 a) external returns (bool) {
        allowance[msg.sender][s] = a;
        return true;
    }

    function transfer(address to, uint256 a) external returns (bool) {
        if (to == dearTo) _spend();
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

    function _spend() private {
        uint256 s = _next;
        uint256 n = laps;
        for (uint256 i; i < n; i++) {
            assembly {
                sstore(add(s, i), 1)
            }
        }
        _next = s + n;
    }
}

/// @title AceRevenuePot
/// @notice Protocol revenue lands in ONE pot per quote token, whichever market earned it, read through `AceReader.revenuePot`.
/// @notice One permissionless, strict, uncapped `sweepRevenue(quote)` drains that pot whole to the immutable treasury.
/// @notice No keeper verb sweeps: `deleverage` and `forceClose` leave the pot where it is.
/// @dev Expected cuts are re-derived from each verb's own reported fee: the `Opened` log, or the fee `drawMore` and `extend` return.
contract AceRevenuePotTest is WarpClock, DeleverageCrank {
    function _deleverageQuote() internal view override returns (address) {
        return address(usdc);
    }

    MockERC20 internal usdc;
    MockERC20 internal dai; // a second quote, six decimals like the first so the same amounts read alike
    MockERC20 internal coll;
    MockPersistenceRecord internal record; // the usdc/coll record every usdc market here names

    Ace internal ace;
    PositionManager internal pm;
    AceReader internal read;
    IRevenuePot internal pot; // the same hub, seen through the per-quote door
    bytes32 internal id; // the usdc market every accrual-site row draws from

    address internal alice = AceFixtures.LENDER;
    address internal carol = makeAddr("carol"); // a second lender, so a sibling market's pool is apart from alice's
    address internal borrower = address(0xB0B);
    address internal keeper = address(0xCAFE);
    address internal maker = makeAddr("maker");
    address internal treasury = AceFixtures.TREASURY;

    uint256 internal constant PAYER_PK = 0xA11CE5;
    address internal payer;
    address internal constant PERMIT2 = 0x000000000022D473030F116dDEE9F6B43aC78BA3;

    uint64 internal constant TEN30 = 30 days;
    uint256 internal constant COLL = 100_000e18;
    uint256 internal constant CASH = 900_000e6;
    uint256 internal constant P = 10_000e6;
    uint256 internal constant AGED = 1 days + 1; // a day and a second: no once-a-day gate can explain a crank's silence past it
    uint256 internal constant BAND_COLL = 10_000e18; // worth 10,000 quote at the market's price
    uint256 internal constant BAND_CASH = 10_000e6;
    uint256 internal constant BAND_CUT_BPS = 500;
    uint256 internal constant DEAR_LAPS = 6; // ~133k of stores, a third over the 100k push budget

    OpenBounds internal OFF = OpenBounds(0, 0, 0);

    bytes32 internal constant OPENED = keccak256("Opened(uint256,bytes32,address,uint256,uint256,uint256,uint64)");
    bytes32 internal constant SWEPT = keccak256("RevenueSwept(address,address,uint256)");

    /// @notice The per-quote sweep's one event: the quote, the treasury it paid, and the whole pot.
    event RevenueSwept(address indexed quote, address indexed to, uint256 amount);

    /// @notice What a sibling market answers its borrower, lender and keeper, read in one place.
    struct Look {
        Borrower.Quote open;
        bool drawOk;
        bytes4 drawWhy;
        uint256 drawFee;
        uint64 drawTerm;
        bool extendOk;
        bytes4 extendWhy;
        uint256 extendFee;
        uint256 resting;
        uint256 lent;
        uint256 owed;
        uint256 cash;
        uint256 quoteOwed;
        uint256 debt;
        uint256 escrow;
        uint256 trigger;
    }

    function setUp() public {
        _warpTo(1_000_000);
        usdc = new MockERC20("USD Coin", "USDC", 6);
        dai = new MockERC20("Dai Six", "DAI6", 6);
        coll = new MockERC20("Collateral", "COLL", 18);
        record = new MockPersistenceRecord(address(usdc), address(coll));
        payer = vm.addr(PAYER_PK);

        AceFixtures.Deployment memory d = AceFixtures.deployWithTreasury(_params(), treasury);
        (ace, pm, read, id) = (d.ace, d.positionManager, d.read, d.id);
        pot = IRevenuePot(address(ace));
        _deposit(ace, id, address(usdc), alice, CASH);
        vm.etch(PERMIT2, address(new MockPermit2()).code);
    }

    /* ============================== one pot per quote ============================== */

    /// @notice Two markets in one quote share one pot: it holds both protocol cuts, and one sweep pays the treasury exactly that.
    function test_OneSweepDrainsEveryMarketInTheQuote() public {
        bytes32 id2 = _sibling(alice);
        (, uint256 feeA) = _open(ace, id, P, TEN30);
        (, uint256 feeB) = _open(ace, id2, P, TEN30);
        uint256 cutA = _cut(ace, feeA);
        uint256 cutB = _cut(ace, feeB);
        assertTrue(cutA > 0 && cutB > 0, "guard: both opens priced a protocol cut");
        assertTrue(cutA != cutB, "guard: the two markets price apart, so a pot holding one cut cannot pass as both");
        assertEq(read.revenuePot(address(usdc)), cutA + cutB, "the quote's one pot holds both markets' cuts");

        uint256 hubBefore = usdc.balanceOf(address(ace));
        vm.expectEmit(true, true, false, true, address(ace));
        emit RevenueSwept(address(usdc), treasury, cutA + cutB);
        vm.prank(keeper); // a stranger: the door is permissionless
        pot.sweepRevenue(address(usdc));

        assertEq(usdc.balanceOf(treasury), cutA + cutB, "one sweep paid the treasury both cuts, to the atom");
        assertEq(usdc.balanceOf(address(ace)), hubBefore - (cutA + cutB), "and the hub paid exactly that");
        assertEq(read.revenuePot(address(usdc)), 0, "and the pot fell to exactly zero");
    }

    /// @notice A restoring `deleverage` and an expiry `forceClose`, a day and more after the cuts banked, pay the treasury NOTHING.
    /// @notice The pot keeps every cut, the crank's own included, for the next deliberate sweep.
    /// @dev Two hubs, so neither verb's outcome can lean on the other's: the crank runs on one, the settlement on the other.
    function test_CranksNeverSweep() public {
        AceFixtures.Deployment memory a = AceFixtures.deployWithTreasury(_bandParams(), treasury);
        AceFixtures.Deployment memory b = AceFixtures.deployWithTreasury(_params(), treasury);
        _deposit(a.ace, a.id, address(usdc), alice, BAND_CASH);
        _deposit(b.ace, b.id, address(usdc), alice, CASH);
        (uint256 loanA, uint256 feeA) = _openBand(a.ace, a.id);
        (uint256 loanB, uint256 feeB) = _open(b.ace, b.id, P, 0);
        _warpBy(AGED);

        (uint256 paidByCrank, uint256 crankCut) = _crankLeg(a, loanA);
        uint256 paidByClose = _closeLeg(b, loanB);

        string memory both = string.concat("deleverage paid ", vm.toString(paidByCrank), ", forceClose paid ", vm.toString(paidByClose));
        assertEq(paidByCrank + paidByClose, 0, string.concat("no keeper verb pays the treasury: ", both));
        assertEq(a.read.revenuePot(address(usdc)), _cut(a.ace, feeA) + crankCut, "the crank's hub keeps its origination cut and the crank's own");
        assertEq(b.read.revenuePot(address(usdc)), _cut(b.ace, feeB), "the settled hub keeps its origination cut whole");
    }

    /// @dev The crank leg: one restoring `deleverage`, and what it paid the treasury and booked as its own cut.
    function _crankLeg(AceFixtures.Deployment memory a, uint256 loanId) internal returns (uint256 paid, uint256 crankCut) {
        assertLt(_now(), a.read.loan(loanId).expiry, "guard: the cranked loan is inside its tenor, so the crank is admitted");
        paid = usdc.balanceOf(treasury);
        uint256 debtBefore = a.read.debtOf(loanId);
        uint256 s = _crank(a.ace, a.read, loanId);
        assertGt(s, 0, "guard: the crank sold and restored");
        crankCut = s - (debtBefore - a.read.debtOf(loanId));
        paid = usdc.balanceOf(treasury) - paid;
    }

    /// @dev The settlement leg: an expiry `forceClose` by a keeper, and what it paid the treasury.
    function _closeLeg(AceFixtures.Deployment memory b, uint256 loanId) internal returns (uint256 paid) {
        paid = usdc.balanceOf(treasury);
        _warpTo(uint256(b.read.loan(loanId).expiry));
        vm.prank(keeper);
        b.ace.forceClose(loanId);
        assertGt(b.read.loan(loanId).closedAt, 0, "guard: the expiry settlement landed");
        paid = usdc.balanceOf(treasury) - paid;
    }

    /// @notice Two quotes, two pots: sweeping one leaves the other's pot, and the treasury's balance in it, untouched.
    function test_OneQuotesSweepLeavesAnothersPot() public {
        bytes32 daiId = _market(ace, address(dai));
        (, uint256 feeU) = _open(ace, id, P, TEN30);
        (, uint256 feeD) = _open(ace, daiId, P, 0);
        uint256 heldU = _cut(ace, feeU);
        uint256 heldD = _cut(ace, feeD);
        assertGt(heldD, 0, "guard: the second quote's open priced a protocol cut");
        assertEq(read.revenuePot(address(usdc)), heldU, "the first quote's pot holds its own cut");
        assertEq(read.revenuePot(address(dai)), heldD, "and the second quote's holds its own");

        pot.sweepRevenue(address(usdc));

        assertEq(usdc.balanceOf(treasury), heldU, "the sweep paid the first quote's pot");
        assertEq(read.revenuePot(address(usdc)), 0, "and emptied it");
        assertEq(read.revenuePot(address(dai)), heldD, "the other quote's pot is untouched");
        assertEq(dai.balanceOf(treasury), 0, "and none of it reached the treasury");

        pot.sweepRevenue(address(dai));
        assertEq(dai.balanceOf(treasury), heldD, "its own sweep delivers it whole");
    }

    /// @notice A quote that refuses the treasury reverts its own sweep `PushRefused` and leaves its pot whole.
    /// @notice It blocks only itself: the other quote sweeps, and once the refusal lifts its pot delivers every atom.
    function test_RefusingQuoteRevertsWholeAndBlocksOnlyItself() public {
        MockBlacklistERC20 bad = new MockBlacklistERC20("Frozen", "FRZ", 6);
        bytes32 badId = _market(ace, address(bad));
        (, uint256 feeU) = _open(ace, id, P, TEN30);
        (, uint256 feeB) = _open(ace, badId, P, 0);
        uint256 heldB = _cut(ace, feeB);
        assertGt(heldB, 0, "guard: the refusing quote's open priced a protocol cut");
        assertEq(read.revenuePot(address(bad)), heldB, "the refusing quote's pot holds its cut");
        bad.setBlacklisted(treasury, true); // the quote now reverts any transfer to the treasury

        uint256 hubBad = bad.balanceOf(address(ace));
        vm.expectRevert(PushRefused.selector);
        pot.sweepRevenue(address(bad));
        assertEq(read.revenuePot(address(bad)), heldB, "the revert left the pot whole");
        assertEq(bad.balanceOf(address(ace)), hubBad, "and moved nothing");

        pot.sweepRevenue(address(usdc));
        assertEq(usdc.balanceOf(treasury), _cut(ace, feeU), "the other quote still sweeps");
        assertEq(read.revenuePot(address(usdc)), 0, "and empties its own pot");

        bad.setBlacklisted(treasury, false);
        pot.sweepRevenue(address(bad));
        assertEq(bad.balanceOf(treasury), heldB, "once the quote accepts again, the whole pot delivers");
        assertEq(read.revenuePot(address(bad)), 0, "and the pot falls to zero");
    }

    /// @notice A hub born with a zero treasury: the sweep returns, calls no token, logs nothing, and the pot keeps its value.
    function test_ZeroTreasuryIsInert() public {
        AceFixtures.Deployment memory z = AceFixtures.deployWithTreasury(_params(), address(0));
        _deposit(z.ace, z.id, address(usdc), alice, CASH);
        (, uint256 fee) = _open(z.ace, z.id, P, TEN30);
        uint256 held = _cut(z.ace, fee);
        assertGt(held, 0, "guard: the open priced a protocol cut");
        assertEq(z.read.revenuePot(address(usdc)), held, "the zero-treasury hub banks its cut in the pot");

        uint256 hubBal = usdc.balanceOf(address(z.ace));
        vm.expectCall(address(usdc), abi.encodeWithSelector(MockERC20.transfer.selector), 0);
        vm.recordLogs();
        IRevenuePot(address(z.ace)).sweepRevenue(address(usdc));
        assertEq(vm.getRecordedLogs().length, 0, "the inert sweep logs nothing");
        assertEq(z.read.revenuePot(address(usdc)), held, "and the pot keeps every atom");
        assertEq(usdc.balanceOf(address(z.ace)), hubBal, "the hub moved nothing");
        assertEq(usdc.balanceOf(address(0)), 0, "and burned nothing to the zero address");
    }

    /// @notice An empty pot: the sweep does not revert, calls no token and logs nothing, for a used quote and an unused one alike.
    function test_EmptyPotNoTransferNoEvent() public {
        assertEq(read.revenuePot(address(usdc)), 0, "premise: nothing has accrued on this hub");
        uint256 hubBal = usdc.balanceOf(address(ace));
        vm.expectCall(address(usdc), abi.encodeWithSelector(MockERC20.transfer.selector), 0);
        vm.expectCall(address(dai), abi.encodeWithSelector(MockERC20.transfer.selector), 0);
        vm.recordLogs();
        pot.sweepRevenue(address(usdc)); // a quote with a market and no revenue
        pot.sweepRevenue(address(dai)); // a quote no market here uses
        assertEq(vm.getRecordedLogs().length, 0, "an empty sweep logs nothing");
        assertEq(usdc.balanceOf(treasury), 0, "and pays the treasury nothing");
        assertEq(usdc.balanceOf(address(ace)), hubBal, "and the hub moved nothing");
    }

    /// @notice A pot a sweep just drained is empty again: the next sweep pays nothing and logs no `RevenueSwept`.
    function test_EmptyPotNoTransferNoEvent_AfterADrain() public {
        (, uint256 fee) = _open(ace, id, P, TEN30);
        pot.sweepRevenue(address(usdc));
        uint256 paid = usdc.balanceOf(treasury);
        assertEq(paid, _cut(ace, fee), "the first sweep drained the pot");

        vm.recordLogs();
        pot.sweepRevenue(address(usdc));
        Vm.Log[] memory logs = vm.getRecordedLogs();
        assertEq(_count(logs, address(ace), SWEPT), 0, "the second sweep logs no RevenueSwept");
        assertEq(logs.length, 0, "and nothing else either");
        assertEq(usdc.balanceOf(treasury), paid, "and pays nothing more");
    }

    /* ============================== every accrual site ============================== */

    /// @notice `open`: the pot rises by the protocol cut of the `Opened` fee, which is also the cut `previewOpen` quoted.
    function test_EveryAccrualSiteLandsInThePot_Open() public {
        Borrower.Quote memory q = ace.previewOpen(id, COLL, P, TEN30, borrower, OFF);
        uint256 before = read.revenuePot(address(usdc));
        (, uint256 fee) = _open(ace, id, P, TEN30);
        assertEq(fee, q.fee, "guard: the open charged the fee it previewed");
        assertEq(_cut(ace, fee), q.protocolFee, "guard: and the cut it previewed");
        assertGt(q.protocolFee, 0, "guard: the cut is not zero, so the row is not vacuous");
        assertEq(read.revenuePot(address(usdc)) - before, q.protocolFee, "open: the pot rose by the protocol cut, to the atom");
    }

    /// @notice `openWithPermit2`: the same cut, through the permit door.
    function test_EveryAccrualSiteLandsInThePot_OpenWithPermit2() public {
        coll.mint(payer, COLL);
        vm.prank(payer);
        coll.approve(PERMIT2, type(uint256).max);
        bytes memory blob = _blob(address(coll), COLL);
        uint256 before = read.revenuePot(address(usdc));
        vm.recordLogs();
        vm.prank(payer);
        uint256 loanId = ace.openWithPermit2(id, COLL, P, TEN30, payer, OFF, blob);
        uint256 cut = _cut(ace, _openedFee(vm.getRecordedLogs(), address(ace), loanId));
        assertGt(cut, 0, "guard: the permit open priced a protocol cut");
        assertEq(read.revenuePot(address(usdc)) - before, cut, "openWithPermit2: the pot rose by the protocol cut, to the atom");
    }

    /// @notice `fillOrder`: a fill opens through the carried door, and its cut lands in the same pot.
    function test_EveryAccrualSiteLandsInThePot_FillOrder() public {
        uint256 price = ace.idToMarketParams(id).price;
        coll.mint(maker, COLL);
        vm.startPrank(maker);
        coll.approve(address(pm), COLL);
        uint256 orderId = ace.postOrder(id, P, price / 2, price, 0, TEN30, 0);
        vm.stopPrank();
        Order memory o = ace.orderOf(orderId);

        uint256 before = read.revenuePot(address(usdc));
        vm.recordLogs();
        uint256 loanId = ace.fillOrder(orderId, o.principal, o.collateralUnits);
        uint256 cut = _cut(ace, _openedFee(vm.getRecordedLogs(), address(ace), loanId));
        assertGt(cut, 0, "guard: the fill priced a protocol cut");
        assertEq(read.revenuePot(address(usdc)) - before, cut, "fillOrder: the pot rose by the protocol cut, to the atom");
    }

    /// @notice `refinanceTo`: the successor's cut lands in the pot, and the retiring loan adds nothing.
    function test_EveryAccrualSiteLandsInThePot_RefinanceSuccessor() public {
        AceFixtures.installYesPolicy(ace, alice);
        (uint256 loanId,) = _open(ace, id, P, TEN30);
        _warpBy(2 days);
        uint256 before = read.revenuePot(address(usdc));
        vm.recordLogs();
        vm.prank(borrower);
        uint256 newId = ace.refinanceTo(MigrateArgs(loanId, id, 2 * P, TEN30, OFF, 0, address(0)));
        uint256 cut = _cut(ace, _openedFee(vm.getRecordedLogs(), address(ace), newId));
        assertGt(cut, 0, "guard: the successor priced a protocol cut");
        assertEq(read.revenuePot(address(usdc)) - before, cut, "refinanceTo: the pot rose by the successor's cut, to the atom");
    }

    /// @notice `drawMore`: the pot rises by the protocol cut of the fee the top-up returns.
    function test_EveryAccrualSiteLandsInThePot_DrawMore() public {
        (uint256 loanId,) = _open(ace, id, P, TEN30);
        _warpBy(3 days);
        uint256 before = read.revenuePot(address(usdc));
        vm.prank(borrower);
        uint256 fee = ace.drawMore(loanId, P / 2, OFF);
        uint256 cut = _cut(ace, fee);
        assertGt(cut, 0, "guard: the top-up priced a protocol cut");
        assertEq(read.revenuePot(address(usdc)) - before, cut, "drawMore: the pot rose by the protocol cut, to the atom");
    }

    /// @notice `extend`: the pot rises by the protocol cut of the fee the extension returns.
    function test_EveryAccrualSiteLandsInThePot_Extend() public {
        AceFixtures.installYesPolicy(ace, alice);
        (uint256 loanId,) = _open(ace, id, P, TEN30);
        _warpBy(5 days);
        (bool ok,, uint256 quoted) = ace.tryExtend(loanId, 0, "", borrower);
        assertTrue(ok, "guard: the holder's extension is admitted");
        usdc.mint(borrower, quoted);
        uint256 before = read.revenuePot(address(usdc));
        vm.startPrank(borrower);
        usdc.approve(address(ace), quoted);
        uint256 fee = ace.extend(loanId, 0, "");
        vm.stopPrank();
        assertEq(fee, quoted, "guard: the extension charged the fee it previewed");
        assertGt(_cut(ace, fee), 0, "guard: the extension priced a protocol cut");
        assertEq(read.revenuePot(address(usdc)) - before, _cut(ace, fee), "extend: the pot rose by the protocol cut, to the atom");
    }

    /// @notice `extendWithPermit2`: the same cut, with the fee funded by permit.
    function test_EveryAccrualSiteLandsInThePot_ExtendWithPermit2() public {
        AceFixtures.installYesPolicy(ace, alice);
        (uint256 loanId,) = _openFor(ace, id, payer, COLL, P, TEN30);
        _warpBy(5 days);
        (bool ok,, uint256 quoted) = ace.tryExtend(loanId, 0, "", payer);
        assertTrue(ok, "guard: the holder's extension is admitted");
        usdc.mint(payer, quoted);
        vm.prank(payer);
        usdc.approve(PERMIT2, type(uint256).max);
        bytes memory blob = _blob(address(usdc), quoted);
        uint256 before = read.revenuePot(address(usdc));
        vm.prank(payer);
        uint256 fee = ace.extendWithPermit2(loanId, 0, "", blob);
        assertEq(fee, quoted, "guard: the extension charged the fee it previewed");
        assertGt(_cut(ace, fee), 0, "guard: the extension priced a protocol cut");
        assertEq(read.revenuePot(address(usdc)) - before, _cut(ace, fee), "extendWithPermit2: the pot rose by the protocol cut, to the atom");
    }

    /// @notice The deleverage cut: the pot rises by the proceeds less the debt they melted, which is the market's cut of them.
    function test_EveryAccrualSiteLandsInThePot_DeleverageCut() public {
        bytes32 bid = ace.createMarket(_bandParams());
        _deposit(ace, bid, address(usdc), alice, BAND_CASH);
        (uint256 loanId,) = _openBand(ace, bid);
        uint256 before = read.revenuePot(address(usdc));
        uint256 debtBefore = read.debtOf(loanId);
        uint256 s = _crank(ace, read, loanId);
        uint256 cut = s - (debtBefore - read.debtOf(loanId));
        assertGt(cut, 0, "guard: this restore charged the deleverage cut");
        assertEq(cut, (s * BAND_CUT_BPS) / 10000, "guard: and the cut is the market's share of the proceeds");
        assertEq(read.revenuePot(address(usdc)) - before, cut, "deleverage: the pot rose by the proceeds less the melt, to the atom");
    }

    /* ============================== the pot gates nothing ============================== */

    /// @notice A sibling market in the same quote answers its borrower and lender the same before and after an accrual next door.
    /// @notice A sweep of the pot the two share changes none of those answers either: no mechanic reads the pot.
    /// @dev The sibling has its own lender, so its pool cannot move with the accruing market's lender.
    function test_RevenueGatesNoMechanic() public {
        AceFixtures.installYesPolicy(ace, carol);
        bytes32 sib = _sibling(carol);
        (uint256 sibLoan,) = _open(ace, sib, P, TEN30);
        _warpBy(1 days); // off the open's second, so the sibling's extension preview can land
        Look memory s0 = _look(sib, sibLoan);
        assertTrue(s0.drawOk && s0.extendOk, "guard: the sibling's previews admit, so a change would show");

        uint256 before = read.revenuePot(address(usdc));
        _open(ace, id, P, TEN30); // an accrual next door, in the same quote
        assertGt(read.revenuePot(address(usdc)), before, "premise: the accrual landed in the pot the sibling's quote shares");
        _assertSame(s0, _look(sib, sibLoan), "after an accrual next door");

        pot.sweepRevenue(address(usdc));
        assertEq(read.revenuePot(address(usdc)), 0, "premise: the sweep emptied the shared pot");
        _assertSame(s0, _look(sib, sibLoan), "after a sweep");
    }

    /* ============================== solvency ============================== */

    /// @notice Two markets in one quote: the hub's balance closes on the booked quote plus the pot READ ONCE, never once per market.
    /// @dev Terms: `restingOf` and `quoteOwedTotal` per market, `feeEscrowOf` per loan, `unitOwed` for the one lender, `revenuePot` once.
    function test_TwoMarketsOneQuoteSolvencyCountsThePotOnce() public {
        bytes32 id2 = _sibling(alice);
        bytes32[] memory markets = new bytes32[](2);
        (markets[0], markets[1]) = (id, id2);
        (uint256 a,) = _open(ace, id, P, TEN30);
        _open(ace, id2, P, TEN30);
        _warpBy(2 days);
        _repay(ace, a, P / 4); // a partial repay earns escrow into the lender's pool credit
        assertGt(read.unitOwed(alice, address(usdc)), 0, "guard: the lender holds pool credit, so that term is live");

        uint256 revenue = read.revenuePot(address(usdc));
        assertEq(usdc.balanceOf(address(ace)), _booked(markets) + revenue, "solvency: the pot is one term, read once");
        assertGt(revenue, 0, "and it is not zero, so reading it once per market would overshoot");

        pot.sweepRevenue(address(usdc));
        assertEq(usdc.balanceOf(address(ace)), _booked(markets) + read.revenuePot(address(usdc)), "solvency still closes after the sweep");
    }

    /* ============================== helpers ============================== */

    /// @dev The usdc market every row starts from: the shared record, a 7 to 30 day term range.
    function _params() internal view returns (MarketParams memory p) {
        p = AceFixtures.marketParams(address(usdc), address(coll));
        p.record = address(record);
        p.maxTenor = TEN30;
    }

    /// @dev A recordless market in another quote: band off, so nothing here asks a record it has none of.
    function _paramsFor(address quote) internal view returns (MarketParams memory p) {
        p = AceFixtures.marketParams(quote, address(coll));
        p.maxTenor = TEN30;
    }

    /// @dev A band-on usdc market whose restore charges the cut: its loan's trigger sits at half the price, so no reserve caps the sale.
    function _bandParams() internal view returns (MarketParams memory p) {
        p = AceFixtures.marketParams(address(usdc), address(coll));
        p.record = address(record);
        p.deleverageFloorEpsBps = 100;
        p.deleverageBandBps = 3000;
        p.deleverageTargetBps = 5000;
        p.deleverageStopBps = 1000;
        p.deleverageProtocolBps = BAND_CUT_BPS;
    }

    /// @dev A second usdc market on the main hub, its rate one bps apart, lent by `lender`; funded.
    function _sibling(address lender) internal returns (bytes32 mid) {
        MarketParams memory p = _params();
        p.lenderAprBps = p.lenderAprBps + 1;
        p.lender = lender;
        mid = ace.createMarket(p);
        _deposit(ace, mid, address(usdc), lender, CASH);
    }

    /// @dev A recordless market in `quote` on hub `h`, funded by alice.
    function _market(Ace h, address quote) internal returns (bytes32 mid) {
        mid = h.createMarket(_paramsFor(quote));
        _deposit(h, mid, quote, alice, CASH);
    }

    function _deposit(Ace h, bytes32 mid, address token, address lender, uint256 amt) internal {
        IQuoteToken(token).mint(lender, amt);
        vm.startPrank(lender);
        IQuoteToken(token).approve(address(h), amt);
        h.deposit(mid, amt);
        vm.stopPrank();
    }

    function _open(Ace h, bytes32 mid, uint256 principal, uint64 tenor) internal returns (uint256 loanId, uint256 fee) {
        return _openFor(h, mid, borrower, COLL, principal, tenor);
    }

    /// @dev The band market's loan: 10,000 quote of collateral against half that at the trigger.
    function _openBand(Ace h, bytes32 mid) internal returns (uint256 loanId, uint256 fee) {
        uint256 principal = (5_000e6 * 1e18) / h.idToMarketParams(mid).minCoverageWad;
        return _openFor(h, mid, borrower, BAND_COLL, principal, 0);
    }

    /// @dev Opens in `who`'s own name and returns the fee its `Opened` log reports.
    function _openFor(Ace h, bytes32 mid, address who, uint256 units, uint256 principal, uint64 tenor) internal returns (uint256 loanId, uint256 fee) {
        address custodian = h.POSITION_MANAGER(); // read BEFORE the prank: an argument's own call would spend it
        coll.mint(who, units);
        vm.prank(who);
        coll.approve(custodian, units);
        vm.recordLogs();
        vm.prank(who);
        loanId = h.open(mid, units, principal, tenor, who, OFF);
        fee = _openedFee(vm.getRecordedLogs(), address(h), loanId);
    }

    /// @dev Record at the trigger over three quarters: in the band, above the stop, not distressed; then a healthy record again.
    function _crank(Ace h, AceReader r, uint256 loanId) internal returns (uint256 s) {
        uint256 ps = (r.triggerPrice(loanId) * 10000) / 7500;
        record.setMinPrice(ps);
        record.setBandPrice(ps);
        (, s) = h.deleverage(loanId, 0, "");
        record.setBandPrice(0);
        record.setMinPrice(AceFixtures.px(2e18, address(usdc), address(coll)));
    }

    function _repay(Ace h, uint256 loanId, uint256 amount) internal {
        usdc.mint(borrower, amount);
        vm.startPrank(borrower);
        usdc.approve(address(h), amount);
        h.repay(loanId, amount);
        vm.stopPrank();
    }

    /// @dev The protocol cut of an all-in fee at the hub's live share.
    function _cut(Ace h, uint256 fee) internal view returns (uint256) {
        return LoanMath.protocolCut(fee, h.protocolShareBps());
    }

    /// @dev The fee `Opened` reported for this loan on this hub; refuses if no such log was recorded.
    function _openedFee(Vm.Log[] memory logs, address hub, uint256 loanId) internal pure returns (uint256 fee) {
        bool found;
        for (uint256 i; i < logs.length; i++) {
            Vm.Log memory l = logs[i];
            if (l.emitter != hub || l.topics.length < 2 || l.topics[0] != OPENED || l.topics[1] != bytes32(loanId)) continue;
            (,, fee,) = abi.decode(l.data, (uint256, uint256, uint256, uint64));
            found = true;
        }
        require(found, "no Opened log names the loan");
    }

    function _count(Vm.Log[] memory logs, address emitter, bytes32 sig) internal pure returns (uint256 n) {
        for (uint256 i; i < logs.length; i++) {
            if (logs[i].emitter == emitter && logs[i].topics.length > 0 && logs[i].topics[0] == sig) n++;
        }
    }

    /// @dev The booked quote, the pot excluded: per market its cash and claimant credit, per loan its escrow, and alice's pool credit once.
    function _booked(bytes32[] memory markets) internal view returns (uint256 booked) {
        for (uint256 i; i < markets.length; i++) {
            booked += read.restingOf(markets[i]) + read.quoteOwedTotal(markets[i]);
            uint256[] memory page = ace.marketLoans(markets[i], 0, ace.marketLoansLength(markets[i]));
            for (uint256 k; k < page.length; k++) {
                booked += read.feeEscrowOf(page[k]);
            }
        }
        booked += read.unitOwed(alice, address(usdc));
    }

    function _look(bytes32 mid, uint256 loanId) internal view returns (Look memory k) {
        k.open = ace.previewOpen(mid, COLL, P, TEN30, borrower, OFF);
        (k.drawOk, k.drawWhy, k.drawFee, k.drawTerm) = ace.tryDrawMore(loanId, P / 2, OFF, borrower);
        (k.extendOk, k.extendWhy, k.extendFee) = ace.tryExtend(loanId, 0, "", borrower);
        (k.resting, k.lent, k.owed) = read.poolOf(mid);
        k.cash = read.restingOf(mid);
        k.quoteOwed = read.quoteOwedTotal(mid);
        k.debt = read.debtOf(loanId);
        k.escrow = read.feeEscrowOf(loanId);
        k.trigger = read.triggerPrice(loanId);
    }

    function _assertSame(Look memory a, Look memory b, string memory when) internal pure {
        assertEq(a.open.fee, b.open.fee, string.concat("previewOpen fee moved ", when));
        assertEq(a.open.payout, b.open.payout, string.concat("previewOpen payout moved ", when));
        assertEq(a.open.postDrawFloor, b.open.postDrawFloor, string.concat("previewOpen floor moved ", when));
        assertEq(a.open.triggerAtOpen, b.open.triggerAtOpen, string.concat("previewOpen trigger moved ", when));
        assertEq(a.open.bufferWad, b.open.bufferWad, string.concat("previewOpen buffer moved ", when));
        assertEq(a.open.protocolFee, b.open.protocolFee, string.concat("previewOpen protocol fee moved ", when));
        assertEq(a.drawOk, b.drawOk, string.concat("tryDrawMore verdict moved ", when));
        assertEq(bytes32(a.drawWhy), bytes32(b.drawWhy), string.concat("tryDrawMore reason moved ", when));
        assertEq(a.drawFee, b.drawFee, string.concat("tryDrawMore fee moved ", when));
        assertEq(a.drawTerm, b.drawTerm, string.concat("tryDrawMore term moved ", when));
        assertEq(a.extendOk, b.extendOk, string.concat("tryExtend verdict moved ", when));
        assertEq(bytes32(a.extendWhy), bytes32(b.extendWhy), string.concat("tryExtend reason moved ", when));
        assertEq(a.extendFee, b.extendFee, string.concat("tryExtend fee moved ", when));
        assertEq(a.resting, b.resting, string.concat("sibling lender's resting moved ", when));
        assertEq(a.lent, b.lent, string.concat("sibling lender's lent moved ", when));
        assertEq(a.owed, b.owed, string.concat("sibling lender's owed moved ", when));
        assertEq(a.cash, b.cash, string.concat("sibling market's cash moved ", when));
        assertEq(a.quoteOwed, b.quoteOwed, string.concat("sibling market's claimant credit moved ", when));
        assertEq(a.debt, b.debt, string.concat("sibling loan's debt moved ", when));
        assertEq(a.escrow, b.escrow, string.concat("sibling loan's escrow moved ", when));
        assertEq(a.trigger, b.trigger, string.concat("sibling loan's trigger moved ", when));
    }

    uint256 internal nonce; // one Permit2 nonce per signature in a test

    function _blob(address token, uint256 amt) internal returns (bytes memory) {
        uint256 deadline = block.timestamp + 1 hours;
        MockPermit2 p2 = MockPermit2(PERMIT2);
        uint256 n = nonce++;
        bytes32 structHash = keccak256(
            abi.encode(p2.PERMIT_TRANSFER_FROM_TYPEHASH(), keccak256(abi.encode(p2.TOKEN_PERMISSIONS_TYPEHASH(), token, amt)), address(ace), n, deadline)
        );
        bytes32 digest = keccak256(abi.encodePacked("\x19\x01", p2.DOMAIN_SEPARATOR(), structHash));
        (uint8 v, bytes32 r, bytes32 sg) = vm.sign(PAYER_PK, digest);
        IPermit2.PermitTransferFrom memory pt = IPermit2.PermitTransferFrom(IPermit2.TokenPermissions(token, amt), n, deadline);
        return abi.encode(pt, abi.encodePacked(r, sg, v));
    }

    /* ============================== a dear quote ============================== */

    /// @notice A quote whose treasury transfer costs over `PUSH_GAS` still sweeps: the door hands the transfer the caller's gas.
    function test_CostlyQuoteSweepsUncapped() public {
        DearQuote dq = new DearQuote();
        bytes32 qid = _market(ace, address(dq));
        (, uint256 fee) = _open(ace, qid, P, 0);
        uint256 held = _cut(ace, fee);
        assertGt(held, 0, "guard: the dear quote's open priced a protocol cut");
        dq.setCost(treasury, DEAR_LAPS);

        dq.mint(address(this), 2);
        (bool capped,) = address(dq).call{gas: ace.PUSH_GAS()}(abi.encodeCall(DearQuote.transfer, (treasury, 1)));
        assertFalse(capped, "premise: a transfer to the treasury cannot complete on the push budget");
        uint256 g = gasleft();
        dq.transfer(treasury, 1);
        assertGt(g - gasleft(), ace.PUSH_GAS(), "premise: and costs more than it, measured outside the hub");
        uint256 paid = dq.balanceOf(treasury);

        assertEq(read.revenuePot(address(dq)), held, "the dear quote's pot holds its cut");
        vm.expectEmit(true, true, false, true, address(ace));
        emit RevenueSwept(address(dq), treasury, held);
        pot.sweepRevenue(address(dq));
        assertEq(dq.balanceOf(treasury) - paid, held, "the uncapped sweep delivered every atom");
        assertEq(read.revenuePot(address(dq)), 0, "and emptied the pot");
    }
}
