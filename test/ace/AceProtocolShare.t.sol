// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.36;

import {Test} from "forge-std/Test.sol";
import {Ace, NotTreasury, ShareOverCeiling} from "../../src/ace/hub/Ace.sol";
import {Borrower} from "../../src/ace/hub/Borrower.sol";
import {Constants} from "../../src/ace/hub/Constants.sol";
import {MarketParams, MarketState, MigrateArgs, Order, OpenBounds} from "../../src/ace/hub/Types.sol";
import {PositionManager} from "../../src/ace/positions/PositionManager.sol";
import {IPermit2} from "../../src/interfaces/IPermit2.sol";
import {GUARD_TRIP} from "../utils/GuardTrip.sol";
import {MockERC20} from "../mocks/MockERC20.sol";
import {MockPermit2} from "../mocks/MockPermit2.sol";
import {MockPersistenceRecord} from "../mocks/MockPersistenceRecord.sol";
import {MockStakeVault} from "../mocks/MockStakeVault.sol";
import {AceFixtures} from "../utils/AceFixtures.sol";
import {AceReader} from "../utils/AceReader.sol";
import {AllInFeeSpec} from "../utils/AllInFeeSpec.sol";

/// @notice A quote that calls the hub's share setter from inside its own `transfer`, then pays normally.
/// @dev The hub is deployed with THIS token as its treasury, so `msg.sender == TREASURY` passes and only the guard is left to refuse.
contract ShareReentrantQuote {
    string public constant name = "USD Coin";
    string public constant symbol = "USDC";
    uint8 public constant decimals = 6;
    uint256 public totalSupply;
    mapping(address => uint256) public balanceOf;
    mapping(address => mapping(address => uint256)) public allowance;

    Ace public hub; // armed while non-zero; one shot
    bool public tried;
    bytes public answer; // the inner call's revert data; empty means it went through

    function arm(Ace h) external {
        hub = h;
    }

    function mint(address to, uint256 amount) external {
        balanceOf[to] += amount;
        totalSupply += amount;
    }

    function approve(address spender, uint256 amount) external returns (bool) {
        allowance[msg.sender][spender] = amount;
        return true;
    }

    function transfer(address to, uint256 amount) external returns (bool) {
        Ace h = hub;
        if (address(h) != address(0)) {
            hub = Ace(address(0));
            tried = true;
            try h.setProtocolShareBps(0) {}
            catch (bytes memory e) {
                answer = e;
            }
        }
        balanceOf[msg.sender] -= amount;
        balanceOf[to] += amount;
        return true;
    }

    function transferFrom(address from, address to, uint256 amount) external returns (bool) {
        allowance[from][msg.sender] -= amount;
        balanceOf[from] -= amount;
        balanceOf[to] += amount;
        return true;
    }
}

/// @title AceProtocolShare
/// @notice The origination share is a stored hub word: 1000 at birth, set only by TREASURY, anywhere in [0, 1000], at once.
/// @notice Every fee door charges and splits at the LIVE share, and a change never reaches a fee already booked.
/// @dev Expected values come from `AllInFeeSpec`, which takes the share as a parameter and never reads `src`.
/// @dev Each door is asked at shares 0 and 500 as well as fuzzed: 0 catches a door left on the ceiling form,
/// @dev and 500 catches a door left on the plain cache, whose share reads zero.
contract AceProtocolShareTest is Test {
    Ace internal ace;
    PositionManager internal pm;
    AceReader internal read;
    bytes32 internal id;

    MockERC20 internal usdc;
    MockStakeVault internal vault;
    MockPersistenceRecord internal record;

    address internal alice = AceFixtures.LENDER;
    address internal borrower = address(0xB0B);
    address internal maker = makeAddr("maker");
    address internal treasury = AceFixtures.TREASURY;

    uint256 internal constant PAYER_PK = 0xA11CE5;
    address internal payer;
    address internal constant PERMIT2 = 0x000000000022D473030F116dDEE9F6B43aC78BA3;

    uint256 internal constant MAX = 1000; // re-spelled: the ceiling the user ruled, never read back out of `src`
    uint64 internal constant TEN7 = 7 days;
    uint64 internal constant TEN30 = 30 days;
    uint256 internal constant RATE = 2190; // bps a year
    uint256 internal constant COLL = 100_000e18;
    uint256 internal constant CASH = 900_000e6;
    uint256 internal constant P = 10_000e6;

    OpenBounds internal OFF = OpenBounds(0, 0, 0);

    event ProtocolShareSet(uint256 previous, uint256 shareBps);

    /// @notice The three pots a fee lands in, read off the hub.
    struct Pots {
        uint256 revenue;
        uint256 owed;
        uint256 escrow;
    }

    function setUp() public {
        vm.warp(1_000_000);
        usdc = new MockERC20("USD Coin", "USDC", 6);
        vault = new MockStakeVault(42);
        record = new MockPersistenceRecord(address(usdc), address(vault));
        payer = vm.addr(PAYER_PK);

        AceFixtures.Deployment memory d = AceFixtures.deploy(_params(RATE));
        (ace, pm, read, id) = (d.ace, d.positionManager, d.read, d.id);
        _deposit(ace, id, CASH);
        vm.etch(PERMIT2, address(new MockPermit2()).code);
    }

    /* ============================== T1: the setter ============================== */

    function test_AFreshHubChargesTheCeiling() public view {
        assertEq(ace.protocolShareBps(), MAX, "a hub is born at the 10% ceiling");
        assertEq(Constants.MAX_PROTOCOL_SHARE_BPS, MAX, "and the ceiling is the ruled 1000 bps");
    }

    /// @notice The constructor announces the starting share, so an indexer rebuilds the whole history from events.
    function test_TheConstructorAnnouncesTheStartingShare() public {
        address predictedHub = vm.computeCreateAddress(address(this), vm.getNonce(address(this)) + 1);
        PositionManager m = new PositionManager(predictedHub);
        vm.expectEmit(false, false, false, true, predictedHub);
        emit ProtocolShareSet(0, MAX);
        Ace h = new Ace(treasury, address(m), AceFixtures.PUSH_GAS, AceFixtures.POLICY_GAS);
        assertEq(address(h), predictedHub, "guard: the prediction named the hub that emitted");
    }

    function testFuzz_OnlyTheTreasurySetsTheShare(address caller, uint256 s) public {
        vm.assume(caller != treasury);
        s = bound(s, 0, MAX);
        vm.prank(caller);
        vm.expectRevert(NotTreasury.selector);
        ace.setProtocolShareBps(s);
        assertEq(ace.protocolShareBps(), MAX, "a refused caller moved nothing");
    }

    /// @notice The named parties are refused too, the market's own lender and creator included.
    function test_NeitherTheLenderNorABorrowerNorTheCreatorSetsTheShare() public {
        address[3] memory who = [alice, borrower, address(this)];
        for (uint256 i; i < who.length; ++i) {
            vm.prank(who[i]);
            vm.expectRevert(NotTreasury.selector);
            ace.setProtocolShareBps(0);
        }
        assertEq(ace.protocolShareBps(), MAX, "unchanged");
    }

    function test_TheCeilingLands_AndOneOverItRefuses() public {
        _setShare(MAX);
        assertEq(ace.protocolShareBps(), MAX, "exactly the ceiling lands");
        vm.prank(treasury);
        vm.expectRevert(ShareOverCeiling.selector);
        ace.setProtocolShareBps(MAX + 1);
        assertEq(ace.protocolShareBps(), MAX, "one over refused, nothing moved");
    }

    function testFuzz_AnythingOverTheCeilingRefuses(uint256 s) public {
        s = bound(s, MAX + 1, type(uint256).max);
        vm.prank(treasury);
        vm.expectRevert(ShareOverCeiling.selector);
        ace.setProtocolShareBps(s);
    }

    /// @notice The ceiling is not a ratchet: zero lands, and the share rises back to the ceiling.
    function test_TheShareFallsToZero_AndRisesBackToTheCeiling() public {
        _setShare(0);
        assertEq(ace.protocolShareBps(), 0, "zero lands");
        _setShare(MAX);
        assertEq(ace.protocolShareBps(), MAX, "and the share rises back");
    }

    function testFuzz_TheSetterAnnouncesBothEnds(uint256 a, uint256 b) public {
        a = bound(a, 0, MAX);
        b = bound(b, 0, MAX);
        vm.expectEmit(false, false, false, true, address(ace));
        emit ProtocolShareSet(MAX, a);
        _setShare(a);
        vm.expectEmit(false, false, false, true, address(ace));
        emit ProtocolShareSet(a, b);
        _setShare(b);
        assertEq(ace.protocolShareBps(), b, "the last write stands");
    }

    /// @notice A hub with no treasury keeps the ceiling for good: not even a call from the zero address moves it.
    function test_AZeroTreasuryHubIsFrozenAtTheCeiling() public {
        AceFixtures.Deployment memory d = AceFixtures.deployWithTreasury(_params(RATE), address(0));
        vm.prank(address(0));
        vm.expectRevert(NotTreasury.selector);
        d.ace.setProtocolShareBps(0);
        assertEq(d.ace.protocolShareBps(), MAX, "frozen at the ceiling");
    }

    /// @notice TREASURY calling in from inside a hub verb trips the guard, so no verb ever sees the share move under it.
    function test_TheSetterRefusesReentryFromInsideAHubVerb() public {
        ShareReentrantQuote q = new ShareReentrantQuote();
        MockPersistenceRecord r = new MockPersistenceRecord(address(q), address(vault));
        MarketParams memory p = AceFixtures.marketParams(address(q), address(vault));
        p.record = address(r);
        p.lenderAprBps = RATE;
        p.minTenor = TEN7;
        p.maxTenor = TEN30;
        AceFixtures.Deployment memory d = AceFixtures.deployWithTreasury(p, address(q));

        q.mint(alice, CASH);
        vm.startPrank(alice);
        q.approve(address(d.ace), CASH);
        d.ace.deposit(d.id, CASH);
        vm.stopPrank();

        q.arm(d.ace);
        vault.mint(borrower, COLL);
        vm.startPrank(borrower);
        vault.approve(address(d.positionManager), COLL);
        d.ace.open(d.id, COLL, P, TEN30, borrower, OFF); // the payout transfer is the hook
        vm.stopPrank();

        assertTrue(q.tried(), "fixture: the hook fired inside `open`");
        assertEq(q.answer(), abi.encodeWithSelector(GUARD_TRIP), "the inner setter hit the hub's guard");
        assertEq(d.ace.protocolShareBps(), MAX, "and the share did not move");
    }

    /* ============================== T2: every fee door charges the live share ============================== */

    function testFuzz_Open_ChargesAndSplitsAtTheLiveShare(uint256 s) public {
        _assertOpenAt(bound(s, 0, MAX));
    }

    function test_Open_ChargesAndSplitsAtZeroAndHalf() public {
        _assertOpenAt(0);
        _assertOpenAt(500);
    }

    function testFuzz_PreviewOpen_QuotesTheLiveShare(uint256 s) public {
        _assertPreviewAt(bound(s, 0, MAX));
    }

    function test_PreviewOpen_QuotesZeroAndHalf() public {
        _assertPreviewAt(0);
        _assertPreviewAt(500);
    }

    function testFuzz_OpenWithPermit2_ChargesTheLiveShare(uint256 s) public {
        _assertPermitOpenAt(bound(s, 0, MAX));
    }

    function test_OpenWithPermit2_ChargesZeroAndHalf() public {
        _assertPermitOpenAt(0);
        _assertPermitOpenAt(500);
    }

    function testFuzz_FillOrder_ChargesTheLiveShare(uint256 s) public {
        _assertFillAt(bound(s, 0, MAX));
    }

    function test_FillOrder_ChargesZeroAndHalf() public {
        _assertFillAt(0);
        _assertFillAt(500);
    }

    function testFuzz_DrawMore_ChargesTheLiveShare(uint256 s) public {
        _assertDrawMoreAt(bound(s, 0, MAX));
    }

    function test_DrawMore_ChargesZeroAndHalf() public {
        _assertDrawMoreAt(0);
        _assertDrawMoreAt(500);
    }

    function testFuzz_Extend_ChargesTheLiveShare(uint256 s) public {
        _assertExtendAt(bound(s, 0, MAX), false);
    }

    function test_Extend_ChargesZeroAndHalf() public {
        _assertExtendAt(0, false);
        _assertExtendAt(500, false);
    }

    function testFuzz_ExtendWithPermit2_ChargesTheLiveShare(uint256 s) public {
        _assertExtendAt(bound(s, 0, MAX), true);
    }

    function test_ExtendWithPermit2_ChargesZeroAndHalf() public {
        _assertExtendAt(0, true);
        _assertExtendAt(500, true);
    }

    function testFuzz_RefinanceHome_ChargesTheLiveShare(uint256 s) public {
        _assertRefinanceAt(bound(s, 0, MAX), false);
    }

    function test_RefinanceHome_ChargesZeroAndHalf() public {
        _assertRefinanceAt(0, false);
        _assertRefinanceAt(500, false);
    }

    function testFuzz_RefinanceAway_ChargesTheLiveShare(uint256 s) public {
        _assertRefinanceAt(bound(s, 0, MAX), true);
    }

    function test_RefinanceAway_ChargesZeroAndHalf() public {
        _assertRefinanceAt(0, true);
        _assertRefinanceAt(500, true);
    }

    /* ============================== T3: a change reaches no fee already booked ============================== */

    /// @notice Two hubs run the same loan; one cuts its share to zero mid-term. Every exit pays the same on both.
    /// @notice The escrow is stored as an amount, so its earn-down and refund never re-read the share.
    function test_AShareCutMidTermChangesNoBookedFee() public {
        AceFixtures.Deployment memory twin = AceFixtures.deploy(_params(RATE));
        _deposit(twin.ace, twin.id, CASH);

        uint256 a = _openOn(ace, pm, id, P, TEN30);
        uint256 b = _openOn(twin.ace, twin.positionManager, twin.id, P, TEN30);
        assertEq(read.feeEscrowOf(a), twin.read.feeEscrowOf(b), "fixture: both loans booked the same escrow");

        _setShare(0);
        vm.warp(block.timestamp + 11 days);
        assertEq(read.earlyExitRefund(a), twin.read.earlyExitRefund(b), "the refund owed does not read the share");

        _repay(ace, a, 3_000e6);
        _repay(twin.ace, b, 3_000e6);
        assertEq(read.feeEscrowOf(a), twin.read.feeEscrowOf(b), "a partial repay earns the same escrow down");
        assertEq(read.poolOwed(id), twin.read.poolOwed(twin.id), "and credits the lender the same");

        uint256 aliceBefore = usdc.balanceOf(alice);
        uint256 bobBefore = usdc.balanceOf(borrower);
        _repay(ace, a, read.debtOf(a));
        uint256 aliceCut = usdc.balanceOf(alice) - aliceBefore;
        uint256 bobPaid = bobBefore - usdc.balanceOf(borrower);

        aliceBefore = usdc.balanceOf(alice);
        bobBefore = usdc.balanceOf(borrower);
        _repay(twin.ace, b, twin.read.debtOf(b));
        assertEq(usdc.balanceOf(alice) - aliceBefore, aliceCut, "the closing push pays the lender the same");
        assertEq(bobBefore - usdc.balanceOf(borrower), bobPaid, "and the borrower nets the same refund");
        assertEq(read.revenuePot(address(usdc)), twin.read.revenuePot(address(usdc)), "the booked protocol cut is untouched by the cut");

        uint256 c = _openOn(ace, pm, id, P, TEN30);
        uint256 fee = AllInFeeSpec.feeAllIn(P, TEN30, RATE, 0);
        assertEq(read.feeEscrowOf(c), AllInFeeSpec.feeEscrow(fee, 0), "the next fee books at the new share");
        _assertSolvency(ace, read, id);
    }

    /* ============================== helpers: per-door assertions ============================== */

    function _assertOpenAt(uint256 s) internal {
        _setShare(s);
        uint256 fee = AllInFeeSpec.feeAllIn(P, TEN30, RATE, s);
        Pots memory before = _pots(0);
        uint256 bal = usdc.balanceOf(borrower);
        uint256 loanId = _openOn(ace, pm, id, P, TEN30);
        assertEq(usdc.balanceOf(borrower) - bal, P - fee, "open pays the principal net of the all-in at the live share");
        _assertBooked(before, _pots(loanId), fee, s);
    }

    function _assertPreviewAt(uint256 s) internal {
        _setShare(s);
        Borrower.Quote memory q = ace.previewOpen(id, COLL, P, TEN30, borrower, OFF);
        uint256 fee = AllInFeeSpec.feeAllIn(P, TEN30, RATE, s);
        assertEq(q.fee, fee, "the quote's fee is the all-in at the live share");
        assertEq(q.protocolFee, AllInFeeSpec.protocolFee(fee, s), "and its protocol fee is the live share's slice");
        assertEq(q.payout, P - fee, "and its payout is the principal net of it");
    }

    function _assertPermitOpenAt(uint256 s) internal {
        _setShare(s);
        uint256 fee = AllInFeeSpec.feeAllIn(P, TEN30, RATE, s);
        vault.mint(payer, COLL);
        vm.prank(payer);
        vault.approve(PERMIT2, type(uint256).max);
        bytes memory blob = _blob(address(vault), COLL);
        Pots memory before = _pots(0);
        vm.prank(payer);
        uint256 loanId = ace.openWithPermit2(id, COLL, P, TEN30, payer, OFF, blob);
        _assertBooked(before, _pots(loanId), fee, s);
    }

    function _assertFillAt(uint256 s) internal {
        _setShare(s);
        uint256 price = ace.idToMarketParams(id).price;
        vault.mint(maker, COLL);
        vm.startPrank(maker);
        vault.approve(address(pm), COLL);
        uint256 orderId = ace.postOrder(id, P, price / 2, price, 0, TEN30, 0);
        vm.stopPrank();
        Order memory o = ace.orderOf(orderId);
        uint256 fee = AllInFeeSpec.feeAllIn(P, TEN30, RATE, s);
        Pots memory before = _pots(0);
        uint256 bal = usdc.balanceOf(maker);
        uint256 loanId = ace.fillOrder(orderId, o.principal, o.collateralUnits);
        assertEq(usdc.balanceOf(maker) - bal, P - fee, "the fill pays the maker net of the live share's all-in");
        _assertBooked(before, _pots(loanId), fee, s);
    }

    function _assertDrawMoreAt(uint256 s) internal {
        uint256 loanId = _openOn(ace, pm, id, P, TEN30);
        _setShare(s);
        vm.warp(block.timestamp + 3 days);
        uint256 amount = 5_000e6;
        uint64 term = read.loan(loanId).expiry - uint64(block.timestamp);
        uint256 fee = AllInFeeSpec.feeAllIn(amount, term, RATE, s);

        (bool ok,, uint256 quoted,) = ace.tryDrawMore(loanId, amount, OFF, borrower);
        assertTrue(ok, "fixture: the top-up is admitted");
        assertEq(quoted, fee, "the preview quotes the live share");

        uint256 revenueBefore = read.revenuePot(address(usdc));
        uint256 bal = usdc.balanceOf(borrower);
        vm.prank(borrower);
        assertEq(ace.drawMore(loanId, amount, OFF), fee, "the top-up charges the all-in at the live share");
        assertEq(usdc.balanceOf(borrower) - bal, amount - fee, "and nets it from the payout");
        assertEq(read.revenuePot(address(usdc)) - revenueBefore, AllInFeeSpec.protocolFee(fee, s), "and banks the live share's slice");
    }

    function _assertExtendAt(uint256 s, bool viaPermit) internal {
        AceFixtures.installYesPolicy(ace, alice);
        address who = viaPermit ? payer : borrower;
        uint256 loanId = viaPermit ? _openPermitLoan() : _openOn(ace, pm, id, P, TEN30);
        _setShare(s);
        vm.warp(block.timestamp + 5 days);
        uint64 added = uint64(block.timestamp) + TEN30 - read.loan(loanId).expiry;
        uint256 fee = AllInFeeSpec.feeAllIn(read.debtOf(loanId), added, RATE, s);

        (bool ok,, uint256 quoted) = ace.tryExtend(loanId, 0, "", who);
        assertTrue(ok, "fixture: the extension is admitted");
        assertEq(quoted, fee, "the preview quotes the live share");

        usdc.mint(who, fee);
        uint256 revenueBefore = read.revenuePot(address(usdc));
        uint256 charged;
        if (viaPermit) {
            vm.prank(who);
            usdc.approve(PERMIT2, type(uint256).max);
            bytes memory blob = _blob(address(usdc), fee);
            vm.prank(who);
            charged = ace.extendWithPermit2(loanId, 0, "", blob);
        } else {
            vm.startPrank(who);
            usdc.approve(address(ace), fee);
            charged = ace.extend(loanId, 0, "");
            vm.stopPrank();
        }
        assertEq(charged, fee, "the extension charges the all-in at the live share");
        assertEq(read.revenuePot(address(usdc)) - revenueBefore, AllInFeeSpec.protocolFee(fee, s), "and banks the live share's slice");
    }

    function _assertRefinanceAt(uint256 s, bool away) internal {
        AceFixtures.installYesPolicy(ace, alice);
        bytes32 dst = away ? _awayMarket() : id;
        uint256 rate = away ? RATE + 365 : RATE;
        uint256 loanId = _openOn(ace, pm, id, P, TEN30);
        _setShare(s);
        vm.warp(block.timestamp + 2 days);

        uint256 newP = 20_000e6;
        uint256 fee = AllInFeeSpec.feeAllIn(newP, TEN30, rate, s);
        uint256 revenueBefore = read.revenuePot(address(usdc));
        vm.prank(borrower);
        uint256 newId = ace.refinanceTo(MigrateArgs(loanId, dst, newP, TEN30, OFF, 0, address(0)));
        assertEq(read.feeEscrowOf(newId), AllInFeeSpec.feeEscrow(fee, s), "the successor's escrow is the live share's cut");
        assertEq(read.revenuePot(address(usdc)) - revenueBefore, AllInFeeSpec.protocolFee(fee, s), "and its protocol cut is the live share's slice");
    }

    /// @dev The fee's three pots, each moved by exactly the live share's cut of it.
    function _assertBooked(Pots memory before, Pots memory afterwards, uint256 fee, uint256 s) internal pure {
        assertEq(afterwards.revenue - before.revenue, AllInFeeSpec.protocolFee(fee, s), "revenue rose by the live share's slice");
        assertEq(afterwards.owed - before.owed, AllInFeeSpec.tickFee(fee, s), "the lender's owed rose by the tick cut");
        assertEq(afterwards.escrow, AllInFeeSpec.feeEscrow(fee, s), "the escrow holds the escrow cut");
        assertEq(AllInFeeSpec.protocolFee(fee, s) + AllInFeeSpec.tickFee(fee, s) + AllInFeeSpec.feeEscrow(fee, s), fee, "the split closes");
    }

    /* ============================== helpers: fixtures ============================== */

    function _setShare(uint256 s) internal {
        vm.prank(treasury);
        ace.setProtocolShareBps(s);
    }

    bytes32 internal awayId; // the second market a cross-market refinance lands in; created once per test

    function _awayMarket() internal returns (bytes32) {
        if (awayId == bytes32(0)) {
            awayId = ace.createMarket(_params(RATE + 365));
            _deposit(ace, awayId, CASH);
        }
        return awayId;
    }

    function _pots(uint256 loanId) internal view returns (Pots memory p) {
        p.revenue = read.revenuePot(address(usdc));
        p.owed = read.poolOwed(id);
        if (loanId != 0) p.escrow = read.feeEscrowOf(loanId);
    }

    function _params(uint256 rate) internal view returns (MarketParams memory p) {
        p = AceFixtures.marketParams(address(usdc), address(vault));
        p.record = address(record);
        p.lenderAprBps = rate;
        p.minTenor = TEN7;
        p.maxTenor = TEN30;
    }

    function _deposit(Ace h, bytes32 mid, uint256 amt) internal {
        usdc.mint(alice, amt);
        vm.startPrank(alice);
        usdc.approve(address(h), amt);
        h.deposit(mid, amt);
        vm.stopPrank();
    }

    function _openOn(Ace h, PositionManager m, bytes32 mid, uint256 principal, uint64 tenor) internal returns (uint256 loanId) {
        vault.mint(borrower, COLL);
        vm.startPrank(borrower);
        vault.approve(address(m), COLL);
        loanId = h.open(mid, COLL, principal, tenor, borrower, OFF);
        vm.stopPrank();
    }

    function _openPermitLoan() internal returns (uint256 loanId) {
        vault.mint(payer, COLL);
        vm.startPrank(payer);
        vault.approve(address(pm), COLL);
        loanId = ace.open(id, COLL, P, TEN30, payer, OFF);
        vm.stopPrank();
    }

    function _repay(Ace h, uint256 loanId, uint256 amount) internal {
        usdc.mint(borrower, amount);
        vm.startPrank(borrower);
        usdc.approve(address(h), amount);
        h.repay(loanId, amount);
        vm.stopPrank();
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

    /// @dev The solvency identity, exact: the hub's quote balance is the booked pots and not a wei more.
    function _assertSolvency(Ace h, AceReader r, bytes32 mid) internal view {
        MarketState memory m = r.marketState(mid);
        (uint256 resting,, uint256 owed) = r.poolOf(mid);
        uint256 pot;
        for (uint256 i = 1; i <= r.loanCount(); i++) {
            pot += r.feeEscrowOf(i);
        }
        assertEq(usdc.balanceOf(address(h)), resting + r.revenuePot(address(usdc)) + pot + owed + m.quoteOwedTotal, "solvency identity");
    }
}
