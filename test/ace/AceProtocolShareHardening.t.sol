// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.36;

import {Test} from "forge-std/Test.sol";
import {Ace} from "../../src/ace/hub/Ace.sol";
import {MarketParams, MigrateArgs, OpenBounds} from "../../src/ace/hub/Types.sol";
import {PositionManager} from "../../src/ace/positions/PositionManager.sol";
import {RevenueRouter} from "../../src/ace/treasury/RevenueRouter.sol";
import {GUARD_TRIP} from "../utils/GuardTrip.sol";
import {MockERC20} from "../mocks/MockERC20.sol";
import {MockPersistenceRecord} from "../mocks/MockPersistenceRecord.sol";
import {MockStakeVault} from "../mocks/MockStakeVault.sol";
import {AceFixtures} from "../utils/AceFixtures.sol";
import {AceReader} from "../utils/AceReader.sol";
import {AllInFeeSpec} from "../utils/AllInFeeSpec.sol";
import {BookedQuote} from "../utils/BookedQuote.sol";

/// @notice A "hub" that calls back into the router from inside the router's share verb, and records the answer.
contract RouterReentrantHub {
    RevenueRouter public immutable ROUTER;
    bool public tried;
    bytes public answer; // the inner call's revert data; empty means it went through

    constructor(RevenueRouter r) {
        ROUTER = r;
    }

    function setProtocolShareBps(uint256) external {
        tried = true;
        try ROUTER.sweep(new address[](0)) {}
        catch (bytes memory e) {
            answer = e;
        }
    }
}

/// @title AceProtocolShareHardening
/// @notice The halves of a fee the per-door suite does not pin: the lender split at a top-up and an extension, and a refinance's net.
/// @notice A share-less slip there is invisible at the ceiling and at the protocol cut, because the lender cut is near share-blind.
/// @dev Expected values come from `AllInFeeSpec` and the reader, never `LoanMath`.
/// @dev Every row also holds the hub's balance to its books, across two markets on one lender pool.
contract AceProtocolShareHardeningTest is Test {
    Ace internal ace;
    PositionManager internal pm;
    AceReader internal read;
    bytes32 internal id;
    bytes32 internal awayId; // the second market a cross-market refinance lands in; created on first use

    MockERC20 internal usdc;
    MockStakeVault internal vault;
    MockPersistenceRecord internal record;

    address internal alice = AceFixtures.LENDER;
    address internal borrower = address(0xB0B);
    address internal treasury = AceFixtures.TREASURY;

    uint256 internal constant MAX = 1000; // re-spelled ceiling
    uint64 internal constant TEN7 = 7 days;
    uint64 internal constant TEN30 = 30 days;
    uint256 internal constant RATE = 2190; // bps a year
    uint256 internal constant COLL = 100_000e18;
    uint256 internal constant CASH = 900_000e6;
    uint256 internal constant P = 10_000e6;
    uint256 internal constant TOP_UP = 5_000e6;
    uint256 internal constant NEW_P = 20_000e6;

    OpenBounds internal OFF = OpenBounds(0, 0, 0);

    /// @notice A loan's fee pots at one instant, plus what its escrow would refund right then.
    struct Snap {
        uint256 revenue;
        uint256 owed;
        uint256 escrow;
        uint256 refundNow;
    }

    function setUp() public {
        vm.warp(1_000_000);
        usdc = new MockERC20("USD Coin", "USDC", 6);
        vault = new MockStakeVault(42);
        record = new MockPersistenceRecord(address(usdc), address(vault));
        AceFixtures.Deployment memory d = AceFixtures.deploy(_params(RATE));
        (ace, pm, read, id) = (d.ace, d.positionManager, d.read, d.id);
        _deposit(id, CASH);
        AceFixtures.installYesPolicy(ace, alice);
    }

    /* ============================== a top-up splits its whole fee at the live share ============================== */

    function testFuzz_DrawMore_SplitsTheWholeFeeAtTheLiveShare(uint256 s) public {
        _assertDrawMoreSplitAt(bound(s, 0, MAX));
    }

    /// @notice Zero is where a ceiling-form tick or escrow cut is furthest off; half catches a slip a zero alone could hide.
    function test_DrawMore_SplitsAtZeroAndHalf() public {
        _assertDrawMoreSplitAt(0);
        _assertDrawMoreSplitAt(500);
    }

    /* ============================== an extension splits its whole fee at the live share ============================== */

    function testFuzz_Extend_SplitsTheWholeFeeAtTheLiveShare(uint256 s) public {
        _assertExtendSplitAt(bound(s, 0, MAX));
    }

    function test_Extend_SplitsAtZeroAndHalf() public {
        _assertExtendSplitAt(0);
        _assertExtendSplitAt(500);
    }

    /* ============================== a refinance nets the successor's fee at the live share ============================== */

    /// @notice `_net` prices the successor's fee a second time, so a slip there pays the borrower short and leaves the hub over-funded.
    function testFuzz_RefinanceHome_NetsAtTheLiveShare(uint256 s) public {
        _assertRefinanceNetAt(bound(s, 0, MAX), false);
    }

    function testFuzz_RefinanceAway_NetsAtTheLiveShare(uint256 s) public {
        _assertRefinanceNetAt(bound(s, 0, MAX), true);
    }

    function test_Refinance_NetsAtZeroAndHalf_HomeAndAway() public {
        _assertRefinanceNetAt(0, false);
        _assertRefinanceNetAt(500, false);
        _assertRefinanceNetAt(0, true);
        _assertRefinanceNetAt(500, true);
    }

    /* ============================== one loan's life across five shares ============================== */

    /// @notice Each step reads the share live at its own moment, books exactly that share's cut, and leaves the hub solvent.
    /// @notice Revenue is the sum of each fee's own slice: a step priced at an earlier share, or at the ceiling, breaks the sum.
    function testFuzz_ALifeAcrossFiveSharesBooksEachFeeAtItsOwnShare(uint256[5] memory s) public {
        for (uint256 i; i < 5; ++i) {
            s[i] = bound(s[i], 0, MAX);
        }
        bytes32 away = _awayMarket();
        uint256 expected;

        _setShare(s[0]);
        uint256 a = _open(P, TEN30);
        expected += AllInFeeSpec.protocolFee(AllInFeeSpec.feeAllIn(P, TEN30, RATE, s[0]), s[0]);
        _assertRevenueAndSolvency(expected);

        vm.warp(block.timestamp + 3 days);
        _setShare(s[1]);
        uint64 term = read.loan(a).expiry - uint64(block.timestamp);
        vm.prank(borrower);
        uint256 fee = ace.drawMore(a, TOP_UP, OFF);
        assertEq(fee, AllInFeeSpec.feeAllIn(TOP_UP, term, RATE, s[1]), "the top-up priced at the share live at its moment");
        expected += AllInFeeSpec.protocolFee(fee, s[1]);
        _assertRevenueAndSolvency(expected);

        vm.warp(block.timestamp + 5 days);
        _setShare(s[2]);
        uint64 added = uint64(block.timestamp) + TEN30 - read.loan(a).expiry;
        uint256 debtNow = read.debtOf(a);
        fee = _extend(a);
        assertEq(fee, AllInFeeSpec.feeAllIn(debtNow, added, RATE, s[2]), "the extension priced at the share live at its moment");
        expected += AllInFeeSpec.protocolFee(fee, s[2]);
        _assertRevenueAndSolvency(expected);

        vm.warp(block.timestamp + 2 days);
        _setShare(s[3]);
        vm.prank(borrower);
        uint256 b = ace.refinanceTo(MigrateArgs(a, away, NEW_P, TEN30, OFF, 0, address(0)));
        fee = AllInFeeSpec.feeAllIn(NEW_P, TEN30, RATE + 365, s[3]);
        assertEq(read.loan(b).lastFee, fee, "the successor priced at the share live at the refinance");
        expected += AllInFeeSpec.protocolFee(fee, s[3]);
        _assertRevenueAndSolvency(expected);

        vm.warp(block.timestamp + 4 days);
        _setShare(s[4]);
        _repay(b, read.debtOf(b));
        assertFalse(ace.isLiveLoan(b), "fixture: the full repay closed the successor");
        assertEq(read.feeEscrowOf(b), 0, "a closed loan holds no escrow");
        _assertRevenueAndSolvency(expected); // a repay prices no fee, so the last share books nothing
    }

    /* ============================== the router's share verb holds its guard ============================== */

    /// @notice A named hub calling back into the router from inside the share verb trips the router's guard.
    /// @dev The hub is the owner's pick, so this pins the guard the repo's default asks for rather than a reachable attack.
    function test_TheRouterShareVerbRefusesReentryFromTheHub() public {
        address owner = makeAddr("owner");
        RevenueRouter router = new RevenueRouter(owner, makeAddr("sink"));
        RouterReentrantHub hub = new RouterReentrantHub(router);
        vm.prank(owner);
        router.setProtocolShareBps(address(hub), 0);
        assertTrue(hub.tried(), "fixture: the router reached the hub");
        assertEq(hub.answer(), abi.encodeWithSelector(GUARD_TRIP), "the inner sweep hit the router's guard");
    }

    /* ============================== per-row assertions ============================== */

    function _assertDrawMoreSplitAt(uint256 s) internal {
        uint256 loanId = _open(P, TEN30);
        _setShare(s);
        vm.warp(block.timestamp + 3 days);
        uint64 term = read.loan(loanId).expiry - uint64(block.timestamp);
        uint256 fee = AllInFeeSpec.feeAllIn(TOP_UP, term, RATE, s);
        Snap memory b = _snap(loanId);
        uint256 bal = usdc.balanceOf(borrower);
        vm.prank(borrower);
        assertEq(ace.drawMore(loanId, TOP_UP, OFF), fee, "fixture: the top-up charged the live share's all-in");
        assertEq(usdc.balanceOf(borrower) - bal, TOP_UP - fee, "fixture: the holder was paid the draw net of it");
        _assertSplit(b, _snap(loanId), fee, s);
        _assertSolvent();
    }

    function _assertExtendSplitAt(uint256 s) internal {
        uint256 loanId = _open(P, TEN30);
        _setShare(s);
        vm.warp(block.timestamp + 5 days);
        uint64 added = uint64(block.timestamp) + TEN30 - read.loan(loanId).expiry;
        uint256 fee = AllInFeeSpec.feeAllIn(read.debtOf(loanId), added, RATE, s);
        Snap memory b = _snap(loanId);
        assertEq(_extend(loanId), fee, "fixture: the extension charged the live share's all-in");
        _assertSplit(b, _snap(loanId), fee, s);
        _assertSolvent();
    }

    /// @dev The escrow first earns to now, moving exactly what it will not refund into `owed`, and then takes the new escrow cut.
    function _assertSplit(Snap memory b, Snap memory a, uint256 fee, uint256 s) internal pure {
        assertEq(a.revenue - b.revenue, AllInFeeSpec.protocolFee(fee, s), "revenue rose by the live share's slice");
        assertEq(a.escrow, b.refundNow + AllInFeeSpec.feeEscrow(fee, s), "the escrow is what it would refund, plus the live share's escrow cut");
        assertEq(a.owed - b.owed, (b.escrow - b.refundNow) + AllInFeeSpec.tickFee(fee, s), "owed rose by the earned escrow plus the live share's tick cut");
    }

    function _assertRefinanceNetAt(uint256 s, bool away) internal {
        bytes32 dst = away ? _awayMarket() : id;
        uint256 rate = away ? RATE + 365 : RATE;
        uint256 loanId = _open(P, TEN30);
        _setShare(s);
        vm.warp(block.timestamp + 2 days);
        uint256 fee = AllInFeeSpec.feeAllIn(NEW_P, TEN30, rate, s);
        uint256 refund = read.earlyExitRefund(loanId);
        uint256 debt = read.debtOf(loanId);
        uint256 bal = usdc.balanceOf(borrower);
        vm.prank(borrower);
        uint256 newId = ace.refinanceTo(MigrateArgs(loanId, dst, NEW_P, TEN30, OFF, 0, address(0)));
        assertEq(read.loan(newId).lastFee, fee, "the successor's fee is the live share's all-in");
        assertEq(usdc.balanceOf(borrower) - bal, NEW_P - fee + refund - debt, "the borrower nets the new draw less that fee, plus the refund, less the debt");
        _assertSolvent();
    }

    function _assertRevenueAndSolvency(uint256 expected) internal view {
        assertEq(read.revenuePot(address(usdc)), expected, "revenue is the sum of each fee's slice at its own share");
        _assertSolvent();
    }

    /// @dev Every market on this hub quotes usdc and lends from one pool, so one equality covers them all.
    function _assertSolvent() internal view {
        uint256 n = awayId == bytes32(0) ? 1 : 2;
        bytes32[] memory markets = new bytes32[](n);
        markets[0] = id;
        if (n == 2) markets[1] = awayId;
        address[] memory lenders = new address[](1);
        lenders[0] = alice;
        assertEq(usdc.balanceOf(address(ace)), BookedQuote.total(ace, read, markets, lenders, address(usdc)), "solvency identity");
    }

    /* ============================== fixtures ============================== */

    function _snap(uint256 loanId) internal view returns (Snap memory x) {
        bytes32 m = read.loan(loanId).market;
        x.revenue = read.revenuePot(address(usdc));
        x.owed = read.poolOwed(m);
        x.escrow = read.feeEscrowOf(loanId);
        x.refundNow = read.earlyExitRefund(loanId);
    }

    function _setShare(uint256 s) internal {
        vm.prank(treasury);
        ace.setProtocolShareBps(s);
    }

    function _awayMarket() internal returns (bytes32) {
        if (awayId == bytes32(0)) {
            awayId = ace.createMarket(_params(RATE + 365));
            _deposit(awayId, CASH);
        }
        return awayId;
    }

    function _params(uint256 rate) internal view returns (MarketParams memory p) {
        p = AceFixtures.marketParams(address(usdc), address(vault));
        p.record = address(record);
        p.lenderAprBps = rate;
        p.minTenor = TEN7;
        p.maxTenor = TEN30;
    }

    function _deposit(bytes32 mid, uint256 amt) internal {
        usdc.mint(alice, amt);
        vm.startPrank(alice);
        usdc.approve(address(ace), amt);
        ace.deposit(mid, amt);
        vm.stopPrank();
    }

    function _open(uint256 principal, uint64 tenor) internal returns (uint256 loanId) {
        vault.mint(borrower, COLL);
        vm.startPrank(borrower);
        vault.approve(address(pm), COLL);
        loanId = ace.open(id, COLL, principal, tenor, borrower, OFF);
        vm.stopPrank();
    }

    /// @dev The holder extends in cash at the quoted fee, approving exactly it.
    function _extend(uint256 loanId) internal returns (uint256 fee) {
        (bool ok,, uint256 quoted) = ace.tryExtend(loanId, 0, "", borrower);
        assertTrue(ok, "fixture: the extension is admitted");
        usdc.mint(borrower, quoted);
        vm.startPrank(borrower);
        usdc.approve(address(ace), quoted);
        fee = ace.extend(loanId, 0, "");
        vm.stopPrank();
        assertEq(fee, quoted, "the extension charged what it quoted");
    }

    function _repay(uint256 loanId, uint256 amount) internal {
        usdc.mint(borrower, amount);
        vm.startPrank(borrower);
        usdc.approve(address(ace), amount);
        ace.repay(loanId, amount);
        vm.stopPrank();
    }
}
