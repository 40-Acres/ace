// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.36;

import {Ace} from "../../src/ace/hub/Ace.sol";
import {AceLens} from "../../src/ace/lens/AceLens.sol";
import {Borrower, DrawBelowDebt} from "../../src/ace/hub/Borrower.sol";
import {Constants} from "../../src/ace/hub/Constants.sol";
import {MarketParams, MigrateArgs, OpenBounds} from "../../src/ace/hub/Types.sol";
import {PositionManager} from "../../src/ace/positions/PositionManager.sol";
import {MockERC20} from "../mocks/MockERC20.sol";
import {MockPersistenceRecord} from "../mocks/MockPersistenceRecord.sol";
import {MockStakeVault} from "../mocks/MockStakeVault.sol";
import {AceFixtures} from "../utils/AceFixtures.sol";
import {AceReader} from "../utils/AceReader.sol";
import {AllInFeeSpec} from "../utils/AllInFeeSpec.sol";
import {WarpClock} from "../utils/WarpClock.sol";

interface IAceContinue {
    function tryContinue(uint256 id) external view returns (bool ok, bytes4 reason, uint256 principal);
    function setAutoRefinance(uint256 id, uint64 tenor, uint16 minBufferBps, uint16 maxFeeBps) external;
}

/// @notice The MANUAL continuation: the caller names the principal, so a stale inverse shows up as a revert.
/// @notice `_net` is where it lands, and the boundary it enforces is one wei wide in both directions.
/// @dev The armed path derives its own principal and can never disagree with itself; this path can.
/// @dev The boundary principal is the RECORD's inverse, not the hub's, so a wrong hub is caught, not mirrored.
/// @dev Also pins the `Quote` word order: an INSERT rather than an append passes the arity check alone.
contract AceAllInFeeNettingTest is WarpClock {
    Ace internal ace;
    AceLens internal lens;
    PositionManager internal pm;
    AceReader internal read;
    IAceContinue internal auto_;
    bytes32 internal idA;
    bytes32 internal idB;

    MockERC20 internal usdc;
    MockStakeVault internal vault;
    MockPersistenceRecord internal record;

    address internal alice = address(0xA11CE);
    address internal borrower = address(0xB0B);

    uint256 internal constant PS = Constants.PROTOCOL_SHARE_BPS;
    uint64 internal constant TEN7 = 7 days;
    uint64 internal constant TEN30 = 30 days;
    uint256 internal constant BASE_BPS_A = 40; // the launch rung: 40 bps to the LENDER per shortest term
    uint256 internal constant BASE_BPS_B = 80; // twice A's, so the two markets price the same debt differently

    uint256 internal constant P = 10_000e6;
    uint256 internal constant COLL = 100_000e18;
    uint256 internal constant TOP_CASH = 900_000e6;

    OpenBounds internal OFF = OpenBounds(0, 0, 0);

    function setUp() public {
        _warpTo(1_000_000);
        usdc = new MockERC20("USD Coin", "USDC", 6);
        vault = new MockStakeVault(42);
        record = new MockPersistenceRecord(address(usdc), address(vault));

        AceFixtures.Deployment memory d = AceFixtures.deploy(_params(BASE_BPS_A));
        (ace, pm, read, idA) = (d.ace, d.positionManager, d.read, d.id);
        lens = new AceLens(address(ace));
        auto_ = IAceContinue(address(ace));
        idB = ace.createMarket(_params(BASE_BPS_B));

        _deposit(idA, TOP_CASH);
        _deposit(idB, TOP_CASH);
    }

    /* ============================== the manual boundary, same market ============================== */

    /// @notice The smallest manual draw that retires the old debt nets to EXACTLY nothing; a wei less is refused.
    /// @notice The boundary is the record's inverse at the widened factor, so a hub that kept the carve is caught.
    /// @dev Rolled mid-term, so `refundOld` is non-zero and rides both sides of the netting inequality.
    function test_TheManualBoundary_MidTermWithARefund_IsOneWeiWide() public {
        uint256 loanId = _open(idA, P, TEN30);
        _warpBy(15 days);

        uint256 refundOld = read.earlyExitRefund(loanId);
        assertGt(refundOld, 0, "fixture: a mid-term roll must carry an unearned escrow");
        uint256 pExact = AllInFeeSpec.principalForOwed(read.debtOf(loanId) - refundOld, TEN30, BASE_BPS_A, TEN7, PS);

        vm.prank(borrower);
        vm.expectRevert(DrawBelowDebt.selector);
        ace.refinance(loanId, pExact - 1, TEN30, OFF);

        uint256 owedBefore = read.quoteOwedTotal(idA);
        uint256 wallet = usdc.balanceOf(borrower);
        vm.prank(borrower);
        uint256 newId = ace.refinance(loanId, pExact, TEN30, OFF);

        assertEq(read.debtOf(newId), pExact, "the successor carries the boundary draw as its whole debt");
        assertEq(read.quoteOwedTotal(idA) - owedBefore, 0, "the boundary draw nets to nothing: not a wei over the old debt");
        assertEq(usdc.balanceOf(borrower), wallet, "and pays the borrower nothing either, since a refinance pays its net out in cash");
        assertTrue(read.loan(loanId).closedAt != 0, "and the old loan retired on it");
    }

    /// @notice At expiry there is no refund left, so the boundary is the inverse of the whole debt.
    /// @dev The zero-refund branch is the one a stale inverse hides in: nothing else absorbs a wei of error.
    function test_TheManualBoundary_AtExpiryWithNoRefund_IsOneWeiWide() public {
        uint256 loanId = _open(idA, P, TEN30);
        _warpTo(uint256(read.loan(loanId).expiry));

        assertEq(read.earlyExitRefund(loanId), 0, "fixture: no calendar time is left to rebate");
        uint256 debtOld = read.debtOf(loanId);
        uint256 pExact = AllInFeeSpec.principalForOwed(debtOld, TEN30, BASE_BPS_A, TEN7, PS);

        vm.prank(borrower);
        vm.expectRevert(DrawBelowDebt.selector);
        ace.refinance(loanId, pExact - 1, TEN30, OFF);

        uint256 owedBefore = read.quoteOwedTotal(idA);
        uint256 wallet = usdc.balanceOf(borrower);
        vm.prank(borrower);
        uint256 newId = ace.refinance(loanId, pExact, TEN30, OFF);

        assertEq(read.quoteOwedTotal(idA) - owedBefore, 0, "the boundary draw nets to nothing at expiry too");
        assertEq(usdc.balanceOf(borrower), wallet, "neither booked nor paid out in cash");
        assertEq(pExact - _allIn(pExact, BASE_BPS_A), debtOld, "and its payout IS the debt it replaced, with no refund to help");
        assertGt(newId, loanId, "the successor opened");
    }

    /// @notice A boundary priced at the SOURCE market's rate is refused when the destination charges more.
    /// @notice The netting reads the DESTINATION's `baseBps`, and this is the case that tells the two apart.
    /// @dev A migration that carried the source's fee would open here and leave the hub short by the difference.
    function test_TheManualBoundary_CrossMarket_IsPricedByTheDestination() public {
        uint256 loanId = _open(idA, P, TEN30);
        _warpBy(15 days);

        uint256 owed = read.debtOf(loanId) - read.earlyExitRefund(loanId);
        uint256 pSource = AllInFeeSpec.principalForOwed(owed, TEN30, BASE_BPS_A, TEN7, PS);
        uint256 pDest = AllInFeeSpec.principalForOwed(owed, TEN30, BASE_BPS_B, TEN7, PS);
        assertGt(pDest, pSource, "fixture: B must charge more, or the two boundaries cannot be told apart");

        vm.prank(borrower);
        vm.expectRevert(DrawBelowDebt.selector);
        ace.refinanceTo(MigrateArgs(loanId, idB, pSource, TEN30, OFF, 0, address(0)));

        vm.prank(borrower);
        vm.expectRevert(DrawBelowDebt.selector);
        ace.refinanceTo(MigrateArgs(loanId, idB, pDest - 1, TEN30, OFF, 0, address(0)));

        uint256 owedBefore = read.quoteOwedTotal(idA);
        uint256 wallet = usdc.balanceOf(borrower);
        vm.prank(borrower);
        uint256 newId = ace.refinanceTo(MigrateArgs(loanId, idB, pDest, TEN30, OFF, 0, address(0)));

        assertEq(read.loan(newId).market, idB, "the successor lives in the destination market");
        assertEq(read.quoteOwedTotal(idA) - owedBefore, 0, "and the destination's boundary nets to nothing");
        assertEq(usdc.balanceOf(borrower), wallet, "neither booked nor paid out in cash");
    }

    /// @notice The armed derivation and the manual netting agree to the WEI: the hub's principal is the boundary.
    /// @notice A drift of one wei between the inverse and the forward fee would show here and nowhere else.
    /// @dev The two spellings live on opposite sides of the hub, and only this pairing puts them in one assertion.
    function test_TheHubsDerivedPrincipalIsExactlyTheManualBoundary() public {
        uint256 loanId = _open(idA, P, TEN7);
        vm.prank(borrower);
        auto_.setAutoRefinance(loanId, TEN7, 0, 0);
        _warpTo(uint256(read.loan(loanId).expiry) - 1 hours);

        (bool ok,, uint256 derived) = auto_.tryContinue(loanId);
        assertTrue(ok, "fixture: the continuation must be admitted for its principal to mean anything");

        vm.prank(borrower);
        vm.expectRevert(DrawBelowDebt.selector);
        ace.refinance(loanId, derived - 1, TEN7, OFF);

        uint256 owedBefore = read.quoteOwedTotal(idA);
        uint256 wallet = usdc.balanceOf(borrower);
        vm.prank(borrower);
        uint256 newId = ace.refinance(loanId, derived, TEN7, OFF);

        assertEq(read.debtOf(newId), derived, "the manual verb drew the derived principal exactly");
        assertEq(read.quoteOwedTotal(idA) - owedBefore, 0, "and it netted to nothing, so the two spellings agree to the wei");
        assertEq(usdc.balanceOf(borrower), wallet, "neither booked nor paid out in cash");
    }

    /// @notice Over every roll time in the term, the record's inverse is the boundary the verb enforces.
    /// @dev Fuzzed on the CLOCK rather than the principal: `refundOld` is what moves the boundary around.
    function testFuzz_TheManualBoundaryTracksTheRefundAtEveryRollTime(uint256 elapsedSeed) public {
        uint256 loanId = _open(idA, P, TEN30);
        _warpBy(bound(elapsedSeed, 0, uint256(TEN30)));

        uint256 pExact = AllInFeeSpec.principalForOwed(read.debtOf(loanId) - read.earlyExitRefund(loanId), TEN30, BASE_BPS_A, TEN7, PS);

        vm.prank(borrower);
        vm.expectRevert(DrawBelowDebt.selector);
        ace.refinance(loanId, pExact - 1, TEN30, OFF);

        uint256 owedBefore = read.quoteOwedTotal(idA);
        uint256 wallet = usdc.balanceOf(borrower);
        vm.prank(borrower);
        ace.refinance(loanId, pExact, TEN30, OFF);
        assertEq(read.quoteOwedTotal(idA) - owedBefore, 0, "the boundary is exact at every roll time, never merely sufficient");
        assertEq(usdc.balanceOf(borrower), wallet, "neither booked nor paid out in cash");
    }

    /* ============================== the ~11% larger escrow, over the domain ============================== */

    /// @notice The refund is the record's floored pro-rata of the escrow on the NEW base, at every exit time.
    /// @notice Covers the whole term in one statement: the whole escrow at t=0, nothing at t=tenor, floored between.
    /// @dev The launch-fixture rows pin single numbers; this pins the base itself across principal and clock.
    function testFuzz_TheRefundIsTheProRataOfTheNewEscrowBase(uint256 principalSeed, uint256 elapsedSeed) public {
        uint256 principal = bound(principalSeed, 10e6, 60_000e6);
        uint256 elapsed = bound(elapsedSeed, 0, uint256(TEN30));
        uint256 loanId = _open(idA, principal, TEN30);

        uint256 allIn = _allIn(principal, BASE_BPS_A);
        uint256 escrow = AllInFeeSpec.feeEscrow(allIn, PS);
        assertEq(read.feeEscrowOf(loanId), escrow, "the withheld escrow must be phi of the LENDER cut of the all-in");

        _warpBy(elapsed);
        assertEq(read.earlyExitRefund(loanId), (escrow * (uint256(TEN30) - elapsed)) / uint256(TEN30), "the refund is the floored pro-rata of that base");
    }

    /// @notice An open closed in the SAME block still costs the borrower the take plus the tick half, never nothing.
    /// @notice So the bigger escrow did not turn the round trip into a free option on the ladder.
    /// @dev Generalises the launch-fixture round trip to every principal the tick can fund.
    function testFuzz_AnInstantRoundTripRefundsTheEscrowAndIsStillAStrictLoss(uint256 principalSeed) public {
        uint256 principal = bound(principalSeed, 10e6, 60_000e6);
        uint256 loanId = _open(idA, principal, TEN30);
        uint256 allIn = _allIn(principal, BASE_BPS_A);

        _repayFull(loanId);

        uint256 refunded = read.quoteOwedOf(loanId, borrower);
        assertEq(refunded, AllInFeeSpec.feeEscrow(allIn, PS), "the whole escrow comes back, and not a wei more");
        assertEq(allIn - refunded, AllInFeeSpec.protocolFee(allIn, PS) + AllInFeeSpec.tickFee(allIn, PS), "what stays is the take plus the tick half");
        assertGt(allIn - refunded, 0, "an instant round trip is never free");
    }

    /* ============================== the quote's word order ============================== */

    /// @notice `protocolFee` was APPENDED: the five words before it still carry the fields they always did.
    /// @notice An INSERT would keep the arity at six and silently re-point every integrator's decode.
    /// @dev Each WORD is matched against a value derived outside the struct, so a reordering cannot move both.
    /// @dev Matching the raw words against the typed members would prove nothing: the two move together.
    function test_TheQuoteWordOrderIsTheStructOrderWithTheTakeAppendedLast() public {
        (bool ok, bytes memory ret) = address(ace).staticcall(abi.encodeCall(Ace.previewOpen, (idA, COLL, P, TEN30, borrower, OFF)));
        assertTrue(ok, "fixture: the quote itself must succeed before its shape can be judged");
        assertEq(ret.length, 6 * 32, "the quote must be exactly six words");

        (uint256 w0, uint256 w1, uint256 w2, uint256 w3, uint256 w4, uint256 w5) = abi.decode(ret, (uint256, uint256, uint256, uint256, uint256, uint256));
        assertEq(w0, AllInFeeSpec.feeAllIn(P, TEN30, BASE_BPS_A, TEN7, PS), "word 0 must still be the all-in fee");
        assertEq(w1, P - w0, "word 1 must still be the payout");
        assertEq(w3, _trigger(P), "word 3 must still be the trigger at open");
        assertEq(w4, ((w2 - w3) * 1e18) / w2, "word 4 must still be the buffer measured against word 2");
        assertEq(w5, AllInFeeSpec.protocolFee(w0, PS), "and the take must be word 5, appended after them");

        uint256 loanId = _open(idA, P, TEN30);
        assertEq(w2, read.fundingFloor(idA, loanId), "word 2 must still be the funding floor the draw goes on to set");
    }

    /// @notice The lens tuple mirrors the struct field for field, so the two doors cannot drift apart.
    /// @dev `Quote`'s own comment promises this mirroring; here it is a test rather than a promise.
    function test_TheLensTupleMirrorsTheQuoteFieldForField() public {
        Borrower.Quote memory q = ace.previewOpen(idA, COLL, P, TEN30, borrower, OFF);
        _assertFieldsAreDistinct(q);

        (uint256 fee, uint256 payout, uint256 floor_, uint256 trigger, uint256 buffer, uint256 protocolFee) = lens.quoteOpen(idA, COLL, P, TEN30, borrower);
        assertEq(fee, q.fee, "return 0 must be the all-in fee");
        assertEq(payout, q.payout, "return 1 must be the payout");
        assertEq(floor_, q.postDrawFloor, "return 2 must be the funding floor");
        assertEq(trigger, q.triggerAtOpen, "return 3 must be the trigger");
        assertEq(buffer, q.bufferWad, "return 4 must be the buffer");
        assertEq(protocolFee, q.protocolFee, "return 5 must be the take");
        assertEq(protocolFee, AllInFeeSpec.protocolFee(fee, PS), "and the take must be the record's inverse ratio of it");
    }

    /// @notice The bounded door returns the SAME struct as the hub's, so the sixth field is not lens-only.
    function test_TheBoundedLensQuoteCarriesTheSameSixFields() public view {
        Borrower.Quote memory hub = ace.previewOpen(idA, COLL, P, TEN30, borrower, OFF);
        Borrower.Quote memory viaLens = lens.quoteOpenWithBounds(idA, COLL, P, TEN30, borrower, OFF);
        assertEq(keccak256(abi.encode(hub)), keccak256(abi.encode(viaLens)), "the bounded lens quote must be the hub's, word for word");
    }

    /* ============================== helpers ============================== */

    /// @dev The five legacy words must differ, or a permutation would pass the positional check by accident.
    function _assertFieldsAreDistinct(Borrower.Quote memory q) private pure {
        uint256[5] memory v = [q.fee, q.payout, q.postDrawFloor, q.triggerAtOpen, q.bufferWad];
        for (uint256 i; i < v.length; i++) {
            for (uint256 j = i + 1; j < v.length; j++) {
                assertTrue(v[i] != v[j], "fixture: two quote fields collided, so the order check proves nothing");
            }
        }
    }

    /// @dev The trigger, spelled from the record: `ceil(k * debt * unitScale / (units * 1e18))`.
    function _trigger(uint256 debt) private view returns (uint256) {
        uint256 den = COLL * 1e18;
        return (ace.idToMarketParams(idA).minCoverageWad * debt * read.marketState(idA).unitScale + den - 1) / den;
    }

    /// @dev The all-in this market charges, from the record's spelling rather than the hub's.
    function _allIn(uint256 principal, uint256 baseBps) private pure returns (uint256) {
        return AllInFeeSpec.feeAllIn(principal, TEN30, baseBps, TEN7, PS);
    }

    function _params(uint256 baseBps) private view returns (MarketParams memory p) {
        p = AceFixtures.marketParams(address(usdc), address(vault));
        p.record = address(record);
        p.baseBps = baseBps;
        p.minTenor = TEN7;
        p.maxTenor = TEN30;
    }

    function _deposit(bytes32 mid, uint256 amt) private {
        usdc.mint(alice, amt);
        vm.startPrank(alice);
        usdc.approve(address(ace), amt);
        ace.deposit(mid, amt);
        vm.stopPrank();
    }

    function _repayFull(uint256 loanId) private {
        uint256 debt = read.debtOf(loanId);
        usdc.mint(borrower, debt);
        vm.startPrank(borrower);
        usdc.approve(address(ace), debt);
        ace.repay(loanId, debt);
        vm.stopPrank();
    }

    function _open(bytes32 mid, uint256 principal, uint64 tenor) private returns (uint256 loanId) {
        vault.mint(borrower, COLL);
        vm.startPrank(borrower);
        vault.approve(address(pm), COLL);
        loanId = ace.open(mid, COLL, principal, tenor, borrower, OFF);
        vm.stopPrank();
    }
}
