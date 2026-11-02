// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.36;

import {stdError} from "forge-std/StdError.sol";
import {Ace} from "../../src/ace/hub/Ace.sol";
import {BufferBelowMin, ExtensionAddsNoTime, GateRefused, LoanClosed, LoanMatured} from "../../src/ace/hub/Borrower.sol";
import {MarketPairMismatch, NoRecordPrice, NotBorrower, PolicyRefused, RecordUnreadable, TriggerAboveFloor} from "../../src/ace/hub/Borrower.sol";
import {Borrower} from "../../src/ace/hub/Borrower.sol";
import {Loan, MarketParams, MigrateArgs, OpenBounds} from "../../src/ace/hub/Types.sol";
import {AceLens} from "../../src/ace/lens/AceLens.sol";
import {HubLoanTerm} from "../../src/interfaces/HubLoanTerm.sol";
import {IExtendRefusals} from "../../src/interfaces/IExtendRefusals.sol";
import {IPermit2} from "../../src/interfaces/IPermit2.sol";
import {AceFixtures} from "../utils/AceFixtures.sol";
import {ExtendRig} from "../utils/ExtendRig.sol";
import {NoPolicy, YesPolicy} from "../utils/RollPolicyMocks.sol";
import {MockPermit2} from "../mocks/MockPermit2.sol";
import {MockPersistenceRecord} from "../mocks/MockPersistenceRecord.sol";
import {MockStakeVault} from "../mocks/MockStakeVault.sol";

/// @title AceExtendFromNowHardeningTest
/// @notice The term-from-now extension checked against an oracle written from the rule, not from the code.
/// @notice The rule: closed, caller, matured (`now >= expiry`), no time added (`now == openTime`), lot, borrower rule, record, admission, policy.
/// @notice The fee: `ceil(debt * baseBps * added * 11000 / (1e8 * minTenor))`, `added = newExpiry - expiry`, which under I1 is `now - openTime`.
/// @notice Every refusal is a bare four-byte selector, the same at `tryExtend`, the lens, `extend` and `extendWithPermit2`.
/// @dev Reasoning: the design record; the code review's F2 for the allowance-as-cap rows.
contract AceExtendFromNowHardeningTest is ExtendRig {
    address internal constant PERMIT2 = 0x000000000022D473030F116dDEE9F6B43aC78BA3;
    uint256 internal constant PBOR_PK = 0xB0B0B; // a keyed holder, so the permit door can be signed for
    uint64 internal constant TEN14 = 14 days;
    uint256 internal constant ALL_IN = 11_000; // the lender's 10000 bps plus ACE's 1000, charged on top
    uint256 internal constant UNMEETABLE_BUFFER = 0.9e18; // a 50%-of-par trigger at a par floor leaves a 0.5 buffer

    AceLens internal lens;
    YesPolicy internal yes;
    NoPolicy internal no;
    address internal pbor;

    function setUp() public override {
        super.setUp();
        lens = new AceLens(address(ace));
        yes = new YesPolicy();
        no = new NoPolicy();
        _setPolicy(alice, address(yes));
        _deposit(id, alice, 6 * P);
        pbor = vm.addr(PBOR_PK);
        vm.etch(PERMIT2, address(new MockPermit2()).code);
    }

    /* ============================== the oracle ============================== */

    /// @dev The fee the rule charges for `added` seconds on `debt` in the rig's market, written out rather than read from `LoanMath`.
    function _ruleFee(uint256 debt, uint256 added) internal pure returns (uint256) {
        uint256 d = 10_000 * 10_000 * uint256(TEN7);
        return (debt * BASE * added * ALL_IN + d - 1) / d;
    }

    /// @dev The first leg the rule order refuses, for a holder-held loan `off` seconds into a TEN14 term.
    /// @dev `who`: 0 the holder, 1 the granted lender, 2 the lender without the grant, 3 a stranger.
    /// @dev `recKind`: 0 par, 1 under the trigger, 2 a zero minimum, 3 a record that reverts. `polKind`: 0 yes, 1 no, 2 none.
    function _ruleLeg(uint256 who, uint256 off, uint256 recKind, bool buffered, uint256 polKind) internal pure returns (bytes4) {
        if (who >= 2) return NotBorrower.selector;
        if (off >= TEN14) return LoanMatured.selector;
        if (off == 0) return ExtensionAddsNoTime.selector;
        if (recKind == 3) return RecordUnreadable.selector;
        if (recKind == 2) return NoRecordPrice.selector;
        if (recKind == 1) return TriggerAboveFloor.selector;
        if (buffered) return BufferBelowMin.selector;
        if (polKind != 0) return PolicyRefused.selector;
        return bytes4(0);
    }

    /// @dev A second into the term, biased to its edges: the open second, one in, a middle one, the last one, expiry, and past it.
    function _offset(uint256 seed) internal pure returns (uint256) {
        uint256 k = seed % 6;
        uint256 r = seed >> 8;
        if (k == 0) return 0;
        if (k == 1) return 1;
        if (k == 2) return 2 + r % (TEN14 - 3);
        if (k == 3) return TEN14 - 1;
        if (k == 4) return TEN14;
        return TEN14 + 1 + r % 3 days;
    }

    function _setRecord(uint256 kind) internal {
        if (kind == 1) rec.setMinPrice(par * 4 / 10);
        else if (kind == 2) rec.setMinPrice(0);
        else if (kind == 3) rec.setSick(true);
    }

    /* ============================== helpers ============================== */

    function _sign(uint256 pk, uint256 amt, uint256 nonce, uint256 deadline) internal view returns (bytes memory) {
        MockPermit2 p2 = MockPermit2(PERMIT2);
        bytes32 permitted = keccak256(abi.encode(p2.TOKEN_PERMISSIONS_TYPEHASH(), address(usdc), amt));
        bytes32 structHash = keccak256(abi.encode(p2.PERMIT_TRANSFER_FROM_TYPEHASH(), permitted, address(ace), nonce, deadline));
        (uint8 v, bytes32 r, bytes32 s) = vm.sign(pk, keccak256(abi.encodePacked("\x19\x01", p2.DOMAIN_SEPARATOR(), structHash)));
        return abi.encodePacked(r, s, v);
    }

    /// @dev A SignatureTransfer blob for `amt` of the quote; build it BEFORE a prank, since its reads are calls.
    function _blob(uint256 amt, uint256 nonce) internal view returns (bytes memory) {
        uint256 deadline = _now() + 1 hours;
        IPermit2.PermitTransferFrom memory p = IPermit2.PermitTransferFrom(IPermit2.TokenPermissions(address(usdc), amt), nonce, deadline);
        return abi.encode(p, _sign(PBOR_PK, amt, nonce, deadline));
    }

    /// @dev `who` sends `extend` raw, so the revert data is seen byte for byte.
    function _rawExtend(address who, uint256 loanId, uint256 buf) internal returns (bool ok, bytes memory ret) {
        vm.prank(who);
        (ok, ret) = address(ace).call(abi.encodeCall(Ace.extend, (loanId, buf, bytes(""))));
    }

    /// @dev `who` sends `extendWithPermit2` raw with `blob`.
    function _rawPermitExtend(address who, uint256 loanId, uint256 buf, bytes memory blob) internal returns (bool ok, bytes memory ret) {
        vm.prank(who);
        (ok, ret) = address(ace).call(abi.encodeCall(Ace.extendWithPermit2, (loanId, buf, bytes(""), blob)));
    }

    /// @dev One door's answer measured against the preview's: a landing at the quoted fee, or exactly the four-byte selector, nothing moved.
    function _assertDoorAgrees(uint256 loanId, address payer, bytes4 why, uint256 quoted, bool ok, bytes memory ret, uint256 bal0, string memory door)
        internal
        view
    {
        Loan memory l = read.loan(loanId);
        if (why == bytes4(0)) {
            assertTrue(ok, string.concat(door, ": the preview admitted, so the door lands"));
            assertEq(abi.decode(ret, (uint256)), quoted, string.concat(door, ": at the quoted fee"));
            assertEq(l.expiry, _now() + TEN14, string.concat(door, ": the term runs the tenor from now"));
            assertEq(bal0 - usdc.balanceOf(payer), quoted, string.concat(door, ": and the payer paid exactly the quote"));
        } else {
            assertFalse(ok, string.concat(door, ": the preview refused, so the door refuses"));
            assertEq(ret.length, 4, string.concat(door, ": with a bare four-byte selector"));
            assertEq(bytes4(ret), why, string.concat(door, ": the same selector the preview named"));
            assertEq(usdc.balanceOf(payer), bal0, string.concat(door, ": pulling nothing"));
        }
    }

    function _term(uint256 loanId) internal view returns (uint64 openTime, uint64 tenor, uint64 expiry, uint64 closedAt) {
        bytes32 w = ace.extsload(HubLoanTerm.slot(loanId));
        (openTime, tenor, expiry) = HubLoanTerm.decode(w);
        closedAt = HubLoanTerm.closedAt(w);
    }

    /// @dev `who` asks for `loanId` and is refused `sel` at the hub's preview, the lens, and the verb.
    function _assertRefusedEverywhere(uint256 loanId, address who, uint256 buf, bytes4 sel, string memory why) internal {
        (bool ok, bytes4 reason, uint256 fee) = ace.tryExtend(loanId, buf, "", who);
        assertTrue(!ok && fee == 0, string.concat(why, ": the preview refuses with no fee"));
        assertEq(reason, sel, string.concat(why, ": the preview names the leg"));
        (ok, reason, fee) = lens.tryExtend(loanId, buf, "", who);
        assertEq(reason, sel, string.concat(why, ": the lens forwards it"));
        _fund(who, _ruleFee(P, TEN14));
        uint256 bal = usdc.balanceOf(who);
        (bool landed, bytes memory ret) = _rawExtend(who, loanId, buf);
        assertFalse(landed, string.concat(why, ": the verb refuses"));
        assertEq(ret, abi.encodePacked(sel), string.concat(why, ": with exactly the selector"));
        assertEq(usdc.balanceOf(who), bal, string.concat(why, ": pulling nothing"));
    }

    /// @dev A market of `alice`'s securing ANOTHER collateral, with its own record at par, for the pair-check rows.
    function _foreignCollateralMarket() internal returns (bytes32 mid) {
        MockStakeVault c2 = new MockStakeVault(43);
        MockPersistenceRecord r2 = new MockPersistenceRecord(address(usdc), address(c2));
        r2.setMinPrice(AceFixtures.priceAt(address(usdc), address(c2), 0));
        MarketParams memory p = _params(alice);
        p.collateral = address(c2);
        p.price = AceFixtures.priceAt(address(usdc), address(c2), 0);
        p.record = address(r2);
        mid = ace.createMarket(p);
    }

    /* ============================== 1. one answer, from four doors, by the rule ============================== */

    /// @notice Any second, caller, policy, record and buffer: the hub's preview names exactly the leg the rule order says, at the rule's fee.
    /// @notice The lens forwards it, and `extend`, the empty-blob permit door and a signed permit door each land at it or refuse with its four bytes.
    /// @dev The seeds lean to the landing side, a par record five in eight, a yes policy one in two and no buffer three in four, so both halves are run.
    function testFuzz_EveryDoorGivesTheRulesAnswer(uint256 atSeed, uint256 whoSeed, uint256 polSeed, uint256 recSeed, uint256 bufSeed) public {
        Ask memory a;
        a.loanId = _openIn(id, pbor, P, TEN14, 5000);
        a.who = whoSeed % 4;
        if (a.who == 1) {
            vm.prank(pbor);
            ace.setCreditOperator(alice, true);
        }
        a.caller = a.who == 0 ? pbor : a.who == 3 ? stranger : alice;
        uint256 pol = polSeed % 4 < 2 ? 0 : polSeed % 4 - 1;
        _setPolicy(alice, pol == 0 ? address(yes) : pol == 1 ? address(no) : address(0));
        uint256 off = _offset(atSeed);
        _warpTo(uint256(read.loan(a.loanId).openTime) + off);
        uint256 recKind = recSeed % 8 < 5 ? 0 : recSeed % 8 - 4;
        _setRecord(recKind);
        bool buffered = bufSeed % 4 == 0;
        a.buf = buffered ? UNMEETABLE_BUFFER : 0;

        bytes4 want = _ruleLeg(a.who, off, recKind, buffered, pol);
        (a.ok, a.why, a.quoted) = ace.tryExtend(a.loanId, a.buf, "", a.caller);
        assertEq(a.why, want, "the preview names the leg the rule order names");
        assertEq(a.ok, want == bytes4(0), "and admits exactly when the rule does");
        assertEq(a.quoted, a.ok ? _ruleFee(P, off) : 0, "at the rule's fee on the time added, zero when refused");
        (bool lok, bytes4 lwhy, uint256 lfee) = lens.tryExtend(a.loanId, a.buf, "", a.caller);
        assertTrue(lok == a.ok && lwhy == a.why && lfee == a.quoted, "the lens forwards the hub's answer");
        _assertEveryDoorAgrees(a);
    }

    /// @dev One ask of the fuzz row: the loan, who asks, the buffer, and the preview's answer.
    struct Ask {
        uint256 loanId;
        uint256 who;
        address caller;
        uint256 buf;
        bool ok;
        bytes4 why;
        uint256 quoted;
    }

    /// @dev `extend`, the empty-blob permit door and, for the keyed holder, a signed permit door, each from the same state.
    function _assertEveryDoorAgrees(Ask memory a) internal {
        uint256 snap = vm.snapshotState();
        _fund(a.caller, _ruleFee(P, TEN14));
        uint256 bal = usdc.balanceOf(a.caller);
        (bool s, bytes memory ret) = _rawExtend(a.caller, a.loanId, a.buf);
        _assertDoorAgrees(a.loanId, a.caller, a.why, a.quoted, s, ret, bal, "extend");
        vm.revertToState(snap);

        _fund(a.caller, _ruleFee(P, TEN14));
        bal = usdc.balanceOf(a.caller);
        (s, ret) = _rawPermitExtend(a.caller, a.loanId, a.buf, "");
        _assertDoorAgrees(a.loanId, a.caller, a.why, a.quoted, s, ret, bal, "extendWithPermit2, empty blob");
        vm.revertToState(snap);

        if (a.who != 0) return;
        usdc.mint(pbor, _ruleFee(P, TEN14));
        vm.startPrank(pbor);
        usdc.approve(address(ace), 0);
        usdc.approve(PERMIT2, type(uint256).max);
        vm.stopPrank();
        bytes memory blob = _blob(a.ok ? a.quoted : 1, 0);
        bal = usdc.balanceOf(pbor);
        (s, ret) = _rawPermitExtend(pbor, a.loanId, a.buf, blob);
        _assertDoorAgrees(a.loanId, pbor, a.why, a.quoted, s, ret, bal, "extendWithPermit2, signed");
        if (!a.ok) assertEq(MockPermit2(PERMIT2).nonceBitmap(pbor, 0), 0, "a refused permit door spends no nonce");
    }

    /* ============================== 2. the leg order, two refusals at once ============================== */

    /// @notice Closed runs first: once settled, the holder, the granted lender and a stranger are each refused `LoanClosed`.
    function test_Order_AClosedLoanAnswersLoanClosedToEveryCaller() public {
        uint256 loanId = _open(P, TEN7, 5000);
        vm.prank(borrower);
        ace.setCreditOperator(alice, true);
        _warpTo(read.loan(loanId).expiry);
        vm.prank(keeper);
        ace.forceClose(loanId);
        _assertRefusedEverywhere(loanId, borrower, 0, LoanClosed.selector, "holder");
        _assertRefusedEverywhere(loanId, alice, 0, LoanClosed.selector, "granted lender");
        _assertRefusedEverywhere(loanId, stranger, 0, LoanClosed.selector, "stranger");
    }

    /// @notice The caller runs before the no-time leg: a stranger in the open second is refused `NotBorrower`.
    function test_Order_AStrangerInTheOpenSecondIsRefusedNotBorrower() public {
        uint256 loanId = _open(P, TEN7, 5000);
        _assertRefusedEverywhere(loanId, stranger, 0, NotBorrower.selector, "open second");
    }

    /// @notice Both timing legs run before the borrower rule: a holder the market does not name meets the timing refusal at either edge.
    /// @notice Inside the term the same holder meets `GateRefused`, so the rule really does bind it there.
    function test_Order_TheTimingLegsRunBeforeTheBorrowerRule() public {
        MarketParams memory p = _params(alice);
        p.borrower = borrower;
        bytes32 named = ace.createMarket(p);
        _deposit(named, alice, 2 * P);
        uint256 loanId = _openIn(named, borrower, P, TEN7, 5000);
        address buyer = address(0xB0E2);
        _moveTitle(loanId, borrower, buyer);
        _assertRefusedEverywhere(loanId, buyer, 0, ExtensionAddsNoTime.selector, "open second");
        _warpBy(1);
        _assertRefusedEverywhere(loanId, buyer, 0, GateRefused.selector, "CONTROL: one second in");
        _warpTo(read.loan(loanId).expiry);
        _assertRefusedEverywhere(loanId, buyer, 0, LoanMatured.selector, "expiry");
    }

    /// @notice Neither timing leg reads the record: a reverting record never answers at the open second or from expiry.
    /// @notice One second in, the same record refuses `RecordUnreadable`, so the record leg is reached once the timing legs pass.
    function test_Order_NeitherTimingLegReadsTheRecord() public {
        uint256 loanId = _open(P, TEN7, 5000);
        uint64 x = read.loan(loanId).expiry;
        rec.setSick(true);
        uint256 snap = vm.snapshotState();
        _warpBy(1);
        _assertRefusedEverywhere(loanId, borrower, 0, RecordUnreadable.selector, "CONTROL: one second in");
        vm.revertToState(snap);
        vm.expectCall(address(rec), abi.encodeWithSelector(MockPersistenceRecord.minPrice.selector), 0);
        _assertRefusedEverywhere(loanId, borrower, 0, ExtensionAddsNoTime.selector, "open second");
        _warpTo(x);
        _assertRefusedEverywhere(loanId, borrower, 0, LoanMatured.selector, "expiry");
    }

    /// @notice The timing legs run before admission: a record under the trigger and an unmeetable buffer both lose to them at either edge.
    function test_Order_TheTimingLegsRunBeforeAdmission() public {
        uint256 loanId = _open(P, TEN7, 5000);
        uint64 x = read.loan(loanId).expiry;
        _assertRefusedEverywhere(loanId, borrower, UNMEETABLE_BUFFER, ExtensionAddsNoTime.selector, "open second, buffer");
        rec.setMinPrice(par * 4 / 10);
        _assertRefusedEverywhere(loanId, borrower, 0, ExtensionAddsNoTime.selector, "open second, low record");
        _warpTo(x);
        _assertRefusedEverywhere(loanId, borrower, 0, LoanMatured.selector, "expiry, low record");
        rec.setMinPrice(par);
        _assertRefusedEverywhere(loanId, borrower, UNMEETABLE_BUFFER, LoanMatured.selector, "expiry, buffer");
    }

    /// @notice A SYNTHETIC state, a term word with its tenor zeroed, is the only one where both timing legs hold at once; it fails closed by name.
    /// @notice Inside the term it refuses `ExtensionAddsNoTime`; at expiry, where both legs hold, the matured leg runs first and names `LoanMatured`.
    /// @dev No verb writes a zero tenor, so on every reachable state the two legs never overlap and their order is unobservable but for this row.
    function test_Order_ABrokenTermWordFailsClosedAndMaturedRunsFirst() public {
        uint256 loanId = _open(P, TEN7, 5000);
        bytes32 slot = HubLoanTerm.slot(loanId);
        uint256 w = uint256(vm.load(address(ace), slot));
        vm.store(address(ace), slot, bytes32(w & ~(uint256(type(uint64).max) << 64)));
        (, uint64 t, uint64 x,) = _term(loanId);
        assertEq(t, 0, "PREMISE: the tenor reads zero");
        _warpBy(1);
        _assertRefusedEverywhere(loanId, borrower, 0, ExtensionAddsNoTime.selector, "inside the term");
        _warpTo(x);
        _assertRefusedEverywhere(loanId, borrower, 0, LoanMatured.selector, "at expiry, where both legs hold");
    }

    /// @notice `refinanceTo` refuses `LoanMatured` before its pair checks: into another collateral, `expiry - 1` meets the pair, expiry the clock.
    function test_Order_RefinanceRefusesMaturedBeforeThePairCheck() public {
        bytes32 foreign = _foreignCollateralMarket();
        uint256 loanId = _open(P, TEN7, 5000);
        MigrateArgs memory m = MigrateArgs(loanId, foreign, P, TEN7, OpenBounds(0, 0, 0), 0, address(0));
        uint64 x = read.loan(loanId).expiry;
        _warpTo(uint256(x) - 1);
        vm.prank(borrower);
        vm.expectRevert(MarketPairMismatch.selector);
        ace.refinanceTo(m);
        _warpTo(x);
        vm.prank(borrower);
        vm.expectRevert(LoanMatured.selector);
        ace.refinanceTo(m);
    }

    /* ============================== 3. the fee, by hand ============================== */

    /// @notice A day added on 10,000 USDC at 40 bps a week, ACE's tenth on top, is 6,285,715 atoms: 44 USDC a week, ceiled.
    function test_Fee_ADayAddedIsTheHandComputedFee() public {
        uint256 loanId = _open(P, TEN7, 5000);
        _warpBy(1 days);
        uint256 bal = usdc.balanceOf(borrower) + _ceiling(loanId);
        uint256 fee = _extend(borrower, loanId);
        assertEq(fee, 6_285_715, "4e15 * 86400 * 1.1 / 6.048e13, ceiled");
        assertEq(bal - usdc.balanceOf(borrower), 6_285_715, "and exactly that was pulled");
    }

    /// @notice One second added costs 73 atoms, 72.75 ceiled: the open second is the only free one, and it refuses.
    function test_Fee_OneSecondAddedCostsSeventyThreeAtoms() public {
        uint256 loanId = _open(P, TEN7, 5000);
        _warpBy(1);
        assertEq(_extend(borrower, loanId), 73, "one second, ceiled");
    }

    /// @notice The last second adds the tenor less one second, 43,999,928 atoms, which is under the whole tenor's 44,000,000.
    function test_Fee_TheLastSecondChargesTheTenorLessOneSecond() public {
        uint256 loanId = _open(P, TEN7, 5000);
        _warpTo(uint256(read.loan(loanId).expiry) - 1);
        assertEq(_ceiling(loanId), 44_000_000, "PREMISE: the whole tenor costs 44 USDC");
        assertEq(_extend(borrower, loanId), 43_999_928, "the last second's extension pays for the tenor less one second");
    }

    /// @notice After an extension, the next one pays only for the seconds between them: an hour, 261,905 atoms, logged as 3600 added.
    function test_Fee_TheNextExtensionPaysOnlyForTheSecondsSinceTheLast() public {
        uint256 loanId = _open(P, TEN7, 5000);
        _warpBy(2 days);
        _extend(borrower, loanId);
        _warpBy(1 hours);
        _fund(borrower, _ceiling(loanId));
        vm.expectEmit(true, true, false, true, address(ace));
        emit Borrower.Extended(loanId, 1 hours, uint64(_now()) + TEN7, 261_905, borrower);
        vm.prank(borrower);
        assertEq(ace.extend(loanId, 0, ""), 261_905, "an hour since the last re-anchor, not since the loan first opened");
    }

    /// @notice The granted lender pays, in the same second, exactly the fee the holder would.
    function test_Fee_TheGrantedLenderPaysWhatTheHolderWould() public {
        uint256 loanId = _open(P, TEN7, 5000);
        vm.prank(borrower);
        ace.setCreditOperator(alice, true);
        _warpBy(3 days + 17);
        uint256 snap = vm.snapshotState();
        uint256 byHolder = _extend(borrower, loanId);
        vm.revertToState(snap);
        uint256 byLender = _extend(alice, loanId);
        assertEq(byLender, byHolder, "one fee whoever pays");
        assertEq(byHolder, _ruleFee(P, 3 days + 17), "the fee on the time added");
    }

    /* ============================== 4. the allowance is the cap (review F2) ============================== */

    /// @notice An allowance of exactly the previewed fee lands in the preview's second, and a second later the pull refuses and nothing moves.
    function test_Cap_AnAllowanceOfThePreviewCapsTheFee() public {
        uint256 loanId = _open(P, TEN7, 5000);
        _warpBy(2 days);
        (,, uint256 quoted) = ace.tryExtend(loanId, 0, "", borrower);
        usdc.mint(borrower, 2 * quoted);
        vm.prank(borrower);
        usdc.approve(address(ace), quoted);
        uint256 snap = vm.snapshotState();
        vm.prank(borrower);
        assertEq(ace.extend(loanId, 0, ""), quoted, "CONTROL: in the preview's second the exact allowance lands");
        vm.revertToState(snap);
        _warpBy(1);
        Loan memory l0 = read.loan(loanId);
        uint256 bal = usdc.balanceOf(borrower);
        vm.prank(borrower);
        vm.expectRevert(stdError.arithmeticError);
        ace.extend(loanId, 0, "");
        assertEq(read.loan(loanId).expiry, l0.expiry, "the later landing did not extend");
        assertEq(usdc.balanceOf(borrower), bal, "nor pull anything");
    }

    /// @notice A permit signed for exactly the previewed fee lands in that second, and a second later refuses `InvalidAmount`, its nonce unspent.
    function test_Cap_APermitForThePreviewCapsTheFee() public {
        uint256 loanId = _openIn(id, pbor, P, TEN7, 5000);
        _warpBy(2 days);
        (,, uint256 quoted) = ace.tryExtend(loanId, 0, "", pbor);
        usdc.mint(pbor, 2 * quoted);
        vm.startPrank(pbor);
        usdc.approve(address(ace), 0);
        usdc.approve(PERMIT2, type(uint256).max);
        vm.stopPrank();
        bytes memory blob = _blob(quoted, 0);
        uint256 snap = vm.snapshotState();
        vm.prank(pbor);
        assertEq(ace.extendWithPermit2(loanId, 0, "", blob), quoted, "CONTROL: in the preview's second the permit lands");
        vm.revertToState(snap);
        _warpBy(1);
        uint64 x = read.loan(loanId).expiry;
        vm.prank(pbor);
        vm.expectRevert(MockPermit2.InvalidAmount.selector);
        ace.extendWithPermit2(loanId, 0, "", blob);
        assertEq(read.loan(loanId).expiry, x, "the later landing did not extend");
        assertEq(MockPermit2(PERMIT2).nonceBitmap(pbor, 0), 0, "and the nonce is unspent, so the holder can re-sign");
    }

    /// @notice An allowance of the whole tenor's fee, set at the open, covers an extension landing at any second of the term.
    function testFuzz_Cap_AWholeTenorAllowanceCoversAnySecond(uint256 atSeed) public {
        uint256 loanId = _open(P, TEN7, 5000);
        uint256 ceiling = _ruleFee(P, TEN7);
        usdc.mint(borrower, ceiling);
        vm.prank(borrower);
        usdc.approve(address(ace), ceiling);
        uint256 off = bound(atSeed, 1, TEN7 - 1);
        _warpBy(off);
        vm.prank(borrower);
        uint256 fee = ace.extend(loanId, 0, "");
        assertEq(fee, _ruleFee(P, off), "the fee on the time added");
        assertLe(fee, ceiling, "never more than the whole tenor's");
        assertEq(usdc.allowance(borrower, address(ace)), ceiling - fee, "and the allowance kept the rest");
    }

    /* ============================== 5. HubLoanTerm against the hub's real storage ============================== */

    /// @notice `HubLoanTerm` reads back every term the verbs write: the open, an extension's re-anchor, and the close second.
    /// @notice The expected values come from the clock at each verb, never from another decoder.
    function test_HubLoanTerm_ReadsEveryTermTheVerbsWrite() public {
        uint256 t0 = _now();
        uint256 loanId = _open(P, TEN14, 5000);
        (uint64 o, uint64 t, uint64 x, uint64 c) = _term(loanId);
        assertTrue(o == t0 && t == TEN14 && x == t0 + TEN14 && c == 0, "at the open: (now, tenor, now + tenor, live)");
        _warpBy(5 days);
        uint256 t1 = _now();
        _extend(borrower, loanId);
        (o, t, x, c) = _term(loanId);
        assertTrue(o == t1 && t == TEN14 && x == t1 + TEN14 && c == 0, "after an extension: re-anchored at now, the tenor kept, still live");
        _warpBy(3 days);
        uint256 t2 = _now();
        uint256 debt = read.debtOf(loanId);
        _fund(borrower, debt);
        vm.prank(borrower);
        ace.repay(loanId, debt);
        (o, t, x, c) = _term(loanId);
        assertEq(c, t2, "a full repay writes the close second");
        assertTrue(o == t1 && t == TEN14 && x == t1 + TEN14, "and leaves the term it closed");
        Loan memory l = lens.loan(loanId);
        assertTrue(l.openTime == o && l.tenor == t && l.expiry == x && l.closedAt == c, "the lens reads the same word");
    }

    /// @notice A settlement past expiry writes its own second as the close, not the expiry.
    function test_HubLoanTerm_ClosedAtIsTheSettlingSecond() public {
        uint256 loanId = _open(P, TEN7, 5000);
        uint64 x = read.loan(loanId).expiry;
        _warpTo(uint256(x) + 5 hours);
        vm.prank(keeper);
        ace.forceClose(loanId);
        (,, uint64 expiry, uint64 c) = _term(loanId);
        assertEq(c, uint256(x) + 5 hours, "closedAt is the forceClose second");
        assertEq(expiry, x, "the expiry is untouched");
        assertEq(lens.loan(loanId).closedAt, c, "and the lens reads it");
    }

    /// @notice Each loan has its own word: three loans opened at different seconds on different tenors read back apart, and an unopened id reads zero.
    function test_HubLoanTerm_EachLoanHasItsOwnWord() public {
        uint64[3] memory tenors = [TEN7, TEN14, MAX_T];
        uint256[3] memory ids;
        uint256[3] memory opened;
        for (uint256 i; i < 3; i++) {
            opened[i] = _now();
            ids[i] = _openIn(id, address(uint160(0xA000 + i)), P / 2, tenors[i], 5000);
            _warpBy(1 hours + i);
        }
        for (uint256 i; i < 3; i++) {
            (uint64 o, uint64 t, uint64 x, uint64 c) = _term(ids[i]);
            assertTrue(o == opened[i] && t == tenors[i] && x == opened[i] + tenors[i] && c == 0, "each id decodes its own term");
        }
        (uint64 o2, uint64 t2, uint64 x2, uint64 c2) = _term(ids[2] + 1);
        assertTrue(o2 == 0 && t2 == 0 && x2 == 0 && c2 == 0, "an id never opened reads all zero");
    }

    /* ============================== 6. the lens reads the new term ============================== */

    /// @notice After an extension the lens judges the loan by its NEW expiry: at the old one collateral is still withdrawable, and it withdraws.
    /// @notice At the new expiry the lens reads zero, and the verb refuses `LoanMatured`.
    function test_Lens_AnExtendedLoanIsJudgedByItsNewExpiry() public {
        uint256 loanId = _open(P, TEN7, 5000);
        uint64 oldX = read.loan(loanId).expiry;
        _warpBy(3 days);
        _extend(borrower, loanId);
        uint64 newX = read.loan(loanId).expiry;
        assertEq(lens.loan(loanId).expiry, newX, "the lens reads the new expiry");
        _warpTo(oldX);
        uint256 free = lens.withdrawableUnits(id, loanId);
        assertGt(free, 0, "at the old expiry the lens still frees collateral");
        uint256 units0 = read.loan(loanId).collateralUnits;
        vm.prank(borrower);
        ace.withdrawCollateral(loanId, free, borrower);
        assertEq(read.loan(loanId).collateralUnits, units0 - free, "and the verb agrees: the units left");
        _warpTo(newX);
        assertEq(lens.withdrawableUnits(id, loanId), 0, "at the new expiry the lens frees nothing");
        vm.prank(borrower);
        vm.expectRevert(LoanMatured.selector);
        ace.withdrawCollateral(loanId, 1, borrower);
    }

    /* ============================== 7. the exported refusals ============================== */

    /// @notice `IExtendRefusals` declares the selectors the hub raises bare, so a caller decoding against its ABI names the hub's refusal.
    function test_IExtendRefusals_DecodeTheHubsBareRefusals() public {
        assertEq(IExtendRefusals.ExtensionAddsNoTime.selector, ExtensionAddsNoTime.selector, "the no-time selector is the hub's");
        assertEq(IExtendRefusals.PolicyRefused.selector, PolicyRefused.selector, "the policy selector is the hub's");
        uint256 loanId = _open(P, TEN7, 5000);
        _fund(borrower, _ceiling(loanId));
        (, bytes memory ret) = _rawExtend(borrower, loanId, 0);
        assertEq(ret, abi.encodeWithSelector(IExtendRefusals.ExtensionAddsNoTime.selector), "the open second decodes as the exported error");
        _warpBy(1);
        _setPolicy(alice, address(no));
        (, ret) = _rawExtend(borrower, loanId, 0);
        assertEq(ret, abi.encodeWithSelector(IExtendRefusals.PolicyRefused.selector), "and a policy no as the other");
    }
}
