// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.36;

import {IERC721} from "@openzeppelin/contracts/token/ERC721/IERC721.sol";
import {FullMath} from "@uniswap/v4-core/src/libraries/FullMath.sol";
import {Borrower, GateRefused, LoanMatured, NoRecordPrice} from "../../src/ace/hub/Borrower.sol";
import {NotBorrower, PolicyRefused, RecordUnreadable, TriggerAboveFloor} from "../../src/ace/hub/Borrower.sol";
import {LoanMath} from "../../src/ace/hub/libraries/LoanMath.sol";
import {Loan, MarketParams} from "../../src/ace/hub/Types.sol";
import {Extension, IRollPolicy} from "../../src/interfaces/IRollPolicy.sol";
import {ExtendRig} from "../utils/ExtendRig.sol";
import {
    BoolOnePolicy,
    EchoFallbackPolicy,
    EmptyReturnPolicy,
    GasBurnerPolicy,
    GuardedViewPolicy,
    MatchingPolicy,
    NoPolicy,
    ReturnBombPolicy,
    RevertingPolicy,
    TwoWordPolicy,
    WrongWordPolicy,
    YesPolicy
} from "../utils/RollPolicyMocks.sol";

/// @title AceExtendTest
/// @notice `extend` re-anchors a live loan IN PLACE at its own tenor from now: same id, same title, the fee on the time added, paid in cash.
/// @notice The borrower extends; the market lender holding the borrower's grant extends in cash it pays itself.
/// @notice Every extension needs coverage as a new loan at `min(price, record)` and the lender's roll policy returning its selector.
/// @notice Resting cash never funds one, so no drain reaches it; each lender yes commits at most the loan's own tenor ahead.
/// @dev Reasoning: the design record,,.
contract AceExtendTest is ExtendRig {
    YesPolicy internal yes;

    function setUp() public override {
        super.setUp();
        yes = new YesPolicy();
        _setPolicy(alice, address(yes));
        _deposit(id, alice, 3 * P);
    }

    /* ============================== basics ============================== */

    /// @notice The extension keeps the id, the title and the market, and runs the loan's own tenor from now.
    function test_ExtendKeepsTheIdAndTitleAndRunsTheTenorFromNow() public {
        uint256 loanId = _open(P, TEN7, 5000);
        _warpBy(1 days);
        Loan memory l0 = read.loan(loanId);
        uint256 n = read.loanCount();
        uint256 fee = _fee(l0.debt, 1 days);
        _fund(borrower, fee);
        vm.expectEmit(true, true, false, true, address(ace));
        emit Borrower.Extended(loanId, 1 days, uint64(_now()) + TEN7, fee, borrower);
        vm.prank(borrower);
        uint256 got = ace.extend(loanId, 0, "");
        assertEq(got, fee, "the verb returns the fee on the time added");
        Loan memory l1 = read.loan(loanId);
        assertTrue(ace.isLiveLoan(loanId), "the same id is still live");
        assertEq(read.loanCount(), n, "and no successor id was minted");
        assertEq(IERC721(ace.POSITION_TITLE()).ownerOf(loanId), borrower, "the title never moved");
        assertEq(l1.market, l0.market, "nor did the market");
        assertEq(l1.expiry, _now() + TEN7, "the expiry is now plus the loan's own tenor");
        assertEq(l1.collateralUnits, l0.collateralUnits, "the lot is untouched");
    }

    /// @dev What a book read before an extension holds, so each row compares deltas over one call.
    struct Book {
        uint256 hub;
        uint256 payer;
        uint256 revenue;
        uint256 lent;
        uint256 owed;
        uint256 claim;
        uint256 resting;
        uint256 debt;
    }

    function _book(uint256 loanId, address payer) internal view returns (Book memory b) {
        b.hub = usdc.balanceOf(address(ace));
        b.payer = usdc.balanceOf(payer);
        b.revenue = read.protocolRevenue(id);
        (, b.lent, b.owed) = read.poolOf(id);
        b.claim = read.claimOf(id, loanId);
        b.resting = ace.restingOf(id);
        b.debt = read.debtOf(loanId);
    }

    /// @notice The caller pays F; the protocol cut is revenue, the tick cut and the earned old escrow are owed, the escrow cut is escrowed.
    function test_ACashExtensionBooksTheFeeExactly() public {
        uint256 loanId = _open(P, TEN7, 5000);
        _warpBy(2 days);
        uint256 f0 = read.feeEscrowOf(loanId);
        uint256 r = _unearned(loanId, f0);
        uint256 fee = _fee(read.debtOf(loanId), 2 days);
        _fund(borrower, fee);
        Book memory b = _book(loanId, borrower);
        vm.prank(borrower);
        ace.extend(loanId, 0, "");
        assertEq(usdc.balanceOf(borrower), b.payer - fee, "the caller paid the whole fee");
        assertEq(usdc.balanceOf(address(ace)), b.hub + fee, "and the hub holds it");
        assertEq(read.protocolRevenue(id), b.revenue + LoanMath.protocolCut(fee), "the protocol cut is revenue");
        (, uint256 lent, uint256 owed) = read.poolOf(id);
        assertEq(owed, b.owed + (f0 - r) + LoanMath.tickCut(fee), "owed takes the earned old escrow and the tick cut");
        assertEq(lent, b.lent, "lent does not move");
        assertEq(read.feeEscrowOf(loanId), r + LoanMath.escrowCut(fee), "the escrow holds the unearned old escrow and the escrow cut");
        assertEq(read.debtOf(loanId), b.debt, "the debt is unchanged");
        assertEq(read.claimOf(id, loanId), b.claim, "and so is the claim");
        assertEq(ace.restingOf(id), b.resting, "resting cash is untouched");
        _assertDebtIsClaim(loanId);
        _assertSolvent();
    }

    /// @notice A market whose lender took every resting atom home still extends: resting cash never funds an extension.
    function test_ADrainedMarketExtends() public {
        uint256 loanId = _open(P, TEN7, 5000);
        _drain(id, alice);
        assertEq(ace.restingOf(id), 0, "PREMISE: nothing rests");
        _warpBy(1 days);
        _extend(borrower, loanId);
        assertEq(read.loan(loanId).expiry, _now() + TEN7, "a cash extension lands at zero cash");
        assertEq(ace.restingOf(id), 0, "and rests nothing");
    }

    /// @notice After expiry nothing extends: a day late the extension refuses `LoanMatured`, and the loan is unchanged.
    function test_AnExtensionRefusesAfterExpiry() public {
        uint256 loanId = _open(P, TEN7, 5000);
        uint64 x = read.loan(loanId).expiry;
        _warpTo(uint256(x) + 1 days);
        _fund(borrower, _ceiling(loanId));
        vm.prank(borrower);
        vm.expectRevert(LoanMatured.selector);
        ace.extend(loanId, 0, "");
        assertEq(read.loan(loanId).expiry, x, "the term did not move");
        assertTrue(ace.isLiveLoan(loanId), "and the loan stays live, for settlement");
    }

    /* ============================== callers (review E-3) ============================== */

    function _assertRefusedAs(address who, uint256 loanId, bytes4 err) internal {
        _fund(who, _fee(read.debtOf(loanId), TEN7));
        vm.prank(who);
        vm.expectRevert(err);
        ace.extend(loanId, 0, "");
    }

    /// @notice A stranger extends nothing.
    function test_AStrangerIsRefusedNotBorrower() public {
        uint256 loanId = _open(P, TEN7, 5000);
        _assertRefusedAs(stranger, loanId, NotBorrower.selector);
    }

    /// @notice Nor does a keeper: without the borrower only the granted market lender extends, in cash.
    function test_AKeeperIsRefusedNotBorrower() public {
        uint256 loanId = _open(P, TEN7, 5000);
        _assertRefusedAs(keeper, loanId, NotBorrower.selector);
    }

    /// @notice The market lender without the borrower's grant is a stranger here: paying is not consent.
    function test_ALenderWithoutAGrantIsRefusedNotBorrower() public {
        uint256 loanId = _open(P, TEN7, 5000);
        _assertRefusedAs(alice, loanId, NotBorrower.selector);
    }

    /// @notice An operator holding the borrower's grant who is NOT the market lender keeps today's boundary: it opens, never extends.
    function test_AnOperatorWhoIsNotTheLenderIsRefusedNotBorrower() public {
        uint256 loanId = _open(P, TEN7, 5000);
        address router = address(0x2077E2);
        vm.prank(borrower);
        ace.setCreditOperator(router, true);
        _assertRefusedAs(router, loanId, NotBorrower.selector);
    }

    /// @notice The borrower extends, paying the fee in cash.
    function test_TheBorrowerExtends() public {
        uint256 loanId = _open(P, TEN7, 5000);
        _warpBy(1 days);
        _extend(borrower, loanId);
        assertEq(read.loan(loanId).expiry, _now() + TEN7, "in cash");
    }

    /// @notice E-3: the market lender holding the borrower's credit-operator grant extends in CASH it pays itself; the borrower's debt never moves.
    function test_TheLenderHoldingTheGrantExtendsInCashPaidByItself() public {
        uint256 loanId = _open(P, TEN7, 5000);
        vm.prank(borrower);
        ace.setCreditOperator(alice, true);
        _warpBy(1 days);
        uint256 debt = read.debtOf(loanId);
        uint256 fee = _feeNow(loanId);
        _fund(alice, fee);
        uint256 lenderBal = usdc.balanceOf(alice);
        uint256 borrowerBal = usdc.balanceOf(borrower);
        vm.prank(alice);
        ace.extend(loanId, 0, "");
        assertEq(read.loan(loanId).expiry, _now() + TEN7, "the lender's cash extension landed");
        assertEq(usdc.balanceOf(alice), lenderBal - fee, "paid by the lender itself");
        assertEq(usdc.balanceOf(borrower), borrowerBal, "the borrower paid nothing");
        assertEq(read.debtOf(loanId), debt, "and owes nothing more");
    }

    /// @notice A title buyer inherits no operator: the grant is keyed by the borrower who signed it, not by the title.
    function test_ATitleBuyerInheritsNoOperator() public {
        uint256 loanId = _open(P, TEN7, 5000);
        address buyer = address(0xB0E2);
        vm.prank(borrower);
        ace.setCreditOperator(alice, true);
        _moveTitle(loanId, borrower, buyer);
        assertEq(ace.borrowerOf(loanId), buyer, "PREMISE: the buyer holds the loan");
        _assertRefusedAs(alice, loanId, NotBorrower.selector);
    }

    /* ============================== policy answers (reviews E-5, D-11) ============================== */

    /// @dev Install `policy` as the lender's and assert the borrower's own extension, a day in, refuses `PolicyRefused`.
    function _assertPolicyRefuses(address policy) internal {
        _setPolicy(alice, policy);
        uint256 loanId = _open(P, TEN7, 5000);
        _warpBy(1 days);
        _fund(borrower, _fee(read.debtOf(loanId), TEN7));
        vm.prank(borrower);
        vm.expectRevert(PolicyRefused.selector);
        ace.extend(loanId, 0, "");
    }

    /// @notice The selector is a yes.
    function test_TheSelectorIsAYes() public {
        uint256 loanId = _open(P, TEN7, 5000);
        _warpBy(1 days);
        _extend(borrower, loanId);
        assertEq(read.loan(loanId).expiry, _now() + TEN7, "a policy returning its selector consents");
    }

    function test_AZeroPolicyIsARefusal() public {
        _assertPolicyRefuses(address(0));
    }

    function test_ACodelessPolicyIsARefusal() public {
        _assertPolicyRefuses(address(0xC0DE1E55));
    }

    function test_ANoIsARefusal() public {
        _assertPolicyRefuses(address(new NoPolicy()));
    }

    function test_ARevertIsARefusal() public {
        _assertPolicyRefuses(address(new RevertingPolicy()));
    }

    function test_AnEmptyReturnIsARefusal() public {
        _assertPolicyRefuses(address(new EmptyReturnPolicy()));
    }

    /// @notice Two words, the first the selector, is a refusal: the answer is exactly one word.
    function test_TwoWordsAreARefusal() public {
        _assertPolicyRefuses(address(new TwoWordPolicy()));
    }

    function test_AWrongWordIsARefusal() public {
        _assertPolicyRefuses(address(new WrongWordPolicy()));
    }

    /// @notice E-5: the old bool `true`, `uint256(1)`, is a refusal: only the selector consents.
    function test_TheOldBoolOneIsARefusal() public {
        _assertPolicyRefuses(address(new BoolOnePolicy()));
    }

    /// @notice A return bomb whose first word is the selector is a refusal, and the hub survives its copy.
    function test_AReturnBombIsARefusal() public {
        _assertPolicyRefuses(address(new ReturnBombPolicy()));
    }

    /// @notice A policy that burns its whole cap is a refusal, and the hub keeps the gas to say so.
    function test_AGasBurnerIsARefusal() public {
        _assertPolicyRefuses(address(new GasBurnerPolicy()));
    }

    /// @notice D-11: a fallback echoing calldata word 0 is a refusal, because `Extension` is static with `caller` at word 0.
    function test_TheEchoFallbackIsARefusal() public {
        assertTrue(uint160(borrower) >> 32 != 0, "PREMISE: the caller's top 16 bytes are nonzero, so the echo is not the selector");
        _assertPolicyRefuses(address(new EchoFallbackPolicy()));
    }

    /* ============================== the record ============================== */

    /// @notice A record under the loan's trigger refuses the extension, judged as a new loan at `min(price, record)`; at par it lands.
    function test_ALowRecordRefusesTheExtension() public {
        uint256 loanId = _open(P, TEN7, 5000);
        _warpBy(1 days);
        uint256 snap = vm.snapshotState();
        rec.setMinPrice(par * 4 / 10);
        vm.prank(borrower);
        vm.expectRevert(TriggerAboveFloor.selector);
        ace.extend(loanId, 0, "");
        vm.revertToState(snap);
        _extend(borrower, loanId);
        assertEq(read.loan(loanId).expiry, _now() + TEN7, "CONTROL: the same extension lands at a record at par");
    }

    function test_AnUnreadableRecordRefusesRecordUnreadable() public {
        uint256 loanId = _open(P, TEN7, 5000);
        _warpBy(1 days);
        rec.setSick(true);
        vm.prank(borrower);
        vm.expectRevert(RecordUnreadable.selector);
        ace.extend(loanId, 0, "");
    }

    /// @notice E-1: a stale feed, whose windowed minimum reads zero, refuses `NoRecordPrice` by name.
    function test_AStaleFeedRefusesNoRecordPrice() public {
        uint256 loanId = _open(P, TEN7, 5000);
        _warpBy(1 days);
        rec.setMinPrice(0);
        vm.prank(borrower);
        vm.expectRevert(NoRecordPrice.selector);
        ace.extend(loanId, 0, "");
    }

    /// @notice In a market that names its borrower, a title holder it does not name is refused `GateRefused`: new credit, never settlement.
    function test_TheGateRefusesATitleHolderTheMarketDoesNotName() public {
        MarketParams memory p = _params(alice);
        p.borrower = borrower;
        bytes32 named = ace.createMarket(p);
        _deposit(named, alice, 2 * P);
        uint256 loanId = _openIn(named, borrower, P, TEN7, 5000);
        address buyer = address(0xB0E2);
        _moveTitle(loanId, borrower, buyer);
        assertEq(ace.borrowerOf(loanId), buyer, "PREMISE: the buyer holds the loan");
        _warpBy(1 days);
        vm.prank(buyer);
        vm.expectRevert(GateRefused.selector);
        ace.extend(loanId, 0, "");
    }

    /* ============================== what the policy sees (reviews E-6, E-7) ============================== */

    /// @notice E-6: the policy sees every field of the extension, `caller` included, and the caller's payload.
    function test_ThePolicySeesEveryFieldOfTheExtension() public {
        MatchingPolicy m = new MatchingPolicy();
        _setPolicy(alice, address(m));
        uint256 loanId = _open(P, TEN7, 5000);
        _warpBy(1 days);
        bytes memory data = hex"c0ffee";
        Extension memory e = _extensionOf(loanId, borrower);
        m.expect(e, data);
        _fund(borrower, _fee(e.debt, TEN7));
        vm.expectCall(address(m), abi.encodeCall(IRollPolicy.admitsExtension, (e, data)));
        vm.prank(borrower);
        ace.extend(loanId, 0, data);
        assertEq(read.loan(loanId).expiry, e.newExpiry, "the policy matched every field and consented");
    }

    /// @notice E-6: on the lender's cash extension the policy sees the LENDER as `caller` and the holder as `borrower`, the debt unmoved.
    function test_ThePolicySeesTheLenderAsCallerOnItsCashExtension() public {
        MatchingPolicy m = new MatchingPolicy();
        _setPolicy(alice, address(m));
        uint256 loanId = _open(P, TEN7, 5000);
        vm.prank(borrower);
        ace.setCreditOperator(alice, true);
        _warpBy(1 days);
        Extension memory e = _extensionOf(loanId, alice);
        assertEq(e.newDebt, e.debt, "PREMISE: an extension leaves the debt");
        m.expect(e, "");
        _fund(alice, _fee(e.debt, TEN7));
        vm.expectCall(address(m), abi.encodeCall(IRollPolicy.admitsExtension, (e, bytes(""))));
        vm.prank(alice);
        ace.extend(loanId, 0, "");
        assertEq(read.loan(loanId).expiry, e.newExpiry, "the policy matched the lender as caller and consented");
    }

    /// @notice E-7, the documented behaviour: a policy reading a GUARDED hub view answers no inside the verb and yes in the unlocked preview.
    function test_AGuardedViewPolicyIsANoInTheVerbAndAYesInThePreview() public {
        _setPolicy(alice, address(new GuardedViewPolicy(address(ace), alice, address(usdc))));
        uint256 loanId = _open(P, TEN7, 5000);
        _warpBy(1 days);
        (bool ok, bytes4 why, uint256 fee) = ace.tryExtend(loanId, 0, "", borrower);
        assertTrue(ok, "the unlocked preview reads the guarded view and consents");
        assertEq(why, bytes4(0), "with no refusal");
        assertEq(fee, _feeNow(loanId), "at the extension's fee");
        _fund(borrower, fee);
        vm.prank(borrower);
        vm.expectRevert(PolicyRefused.selector);
        ace.extend(loanId, 0, "");
    }

    /* ============================== the escrow across a re-anchored term (review E-11) ============================== */

    /// @notice The earned part of the funded escrow reaches `owed` at the extension, beside the new fee's tick cut; the rest stays escrowed.
    function test_TheEarnedEscrowReachesOwed() public {
        uint256 loanId = _open(P, TEN7, 5000);
        _warpBy(3 days);
        uint256 f0 = read.feeEscrowOf(loanId);
        uint256 earned = f0 - _unearned(loanId, f0);
        assertGt(earned, 0, "PREMISE: part of the escrow is earned");
        (,, uint256 owed0) = read.poolOf(id);
        uint256 fee = _extend(borrower, loanId);
        assertEq(fee, _fee(read.debtOf(loanId), 3 days), "PREMISE: the fee is on the three days added");
        (,, uint256 owed1) = read.poolOf(id);
        assertEq(owed1, owed0 + earned + LoanMath.tickCut(fee), "the earned escrow and the new tick cut are the lender's at the extension");
        assertEq(read.feeEscrowOf(loanId), f0 - earned + LoanMath.escrowCut(fee), "and the unearned part stays in escrow beside the new escrow cut");
    }

    /// @notice E-11: an IMMEDIATE full repay refunds exactly `r + eF`, so an extension costs exactly its protocol cut plus its tick cut.
    /// @dev The first extension and four days make a funded escrow part earned; the second extension's escrow cut joins what is not.
    function test_AnImmediateFullRepayRefundsExactlyTheUnearnedEscrowAndTheNewEscrowCut() public {
        uint256 loanId = _open(P, TEN7, 5000);
        _warpBy(1 days);
        _extend(borrower, loanId);
        _warpBy(4 days);
        uint256 r = _unearned(loanId, read.feeEscrowOf(loanId));
        uint256 eF = LoanMath.escrowCut(_feeNow(loanId));
        assertGt(r, 0, "PREMISE: an unearned funded escrow");
        _repayWhole(loanId);
        assertEq(read.quoteOwedOf(loanId, borrower), r + eF, "the refund is r + eF exactly");
    }

    /// @dev Extend `loanId`, then repay it whole in the same block.
    function _repayWhole(uint256 loanId) internal {
        _extend(borrower, loanId);
        uint256 debt = read.debtOf(loanId);
        _fund(borrower, debt);
        vm.prank(borrower);
        ace.repay(loanId, debt);
        assertTrue(ace.isClosed(loanId), "PREMISE: the repay closed the loan");
    }

    /// @notice E-11: a repay after an extension refunds ONE straight line to within 2 wei: what stayed unearned plus the new cut, over the new term.
    /// @dev At the extension the old escrow earns down to its unearned share, then the whole pot runs from now over the loan's own tenor.
    function testFuzz_ARepayAfterAnExtensionRefundsWithinTwoWeiOfOneStraightLine(uint256 pSeed, uint256 tSeed, uint256 atSeed, uint256 uSeed) public {
        uint256 principal = bound(pSeed, 100 * MIN_PRINCIPAL, 1_000_000e6);
        uint64 t = uint64(bound(tSeed, TEN7, MAX_T / 2));
        _deposit(id, alice, principal);
        uint256 loanId = _open(principal, t, 5000);
        Loan memory l = read.loan(loanId);
        uint256 e0 = read.feeEscrowOf(loanId);
        _warpTo(bound(atSeed, uint256(l.openTime) + 1, uint256(l.expiry) - 1));
        uint256 s = _now();
        uint256 kept = FullMath.mulDiv(e0, uint256(l.expiry) - s, t);
        uint256 fee = _extend(borrower, loanId);
        assertEq(fee, _fee(principal, uint64(s - l.openTime)), "PREMISE: the fee is on the time added");
        assertEq(read.loan(loanId).expiry, s + t, "the extension landed at now plus the tenor");
        uint256 pot = kept + LoanMath.escrowCut(fee);
        _warpTo(bound(uSeed, s, s + t));
        uint256 want = FullMath.mulDiv(pot, s + t - _now(), t);
        uint256 debt = read.debtOf(loanId);
        _fund(borrower, debt);
        vm.prank(borrower);
        ace.repay(loanId, debt);
        assertApproxEqAbs(read.quoteOwedOf(loanId, borrower), want, 2, "the refund is the pot's straight line over the new term, to 2 wei");
    }

    /// @notice O10 across extensions, partial repays and time: the debt is the claim, and O1 holds.
    /// @dev Every run lands an extension: its first step extends, one second into the loan.
    function testFuzz_DebtIsTheClaimAcrossExtensionsRepaysAndTime(uint256[8] memory seeds) public {
        uint256 loanId = _open(P, TEN7, 5000);
        uint256 landed;
        for (uint256 i; i < seeds.length; i++) {
            uint256 s = seeds[i];
            uint256 kind = i == 0 ? 0 : s % 3;
            if (kind == 0) {
                landed += _tryFittedExtension(loanId);
            } else if (kind == 1) {
                uint256 debt = read.debtOf(loanId);
                if (debt > MIN_PRINCIPAL) {
                    uint256 a = bound(s >> 8, 1, debt - MIN_PRINCIPAL); // a partial repay leaves at least minPrincipal
                    _fund(borrower, a);
                    vm.prank(borrower);
                    ace.repay(loanId, a);
                }
            } else {
                _warpBy(bound(s >> 8, 1 hours, 3 days));
            }
            _assertDebtIsClaim(loanId);
            _assertSolvent();
        }
        assertGt(landed, 0, "an extension landed in the run");
    }

    /// @dev One extension now while the loan is inside its term, a second past its open second; 1 when it ran the tenor from now.
    function _tryFittedExtension(uint256 loanId) internal returns (uint256) {
        Loan memory l = read.loan(loanId);
        if (_now() >= l.expiry) return 0;
        if (_now() == l.openTime) _warpBy(1);
        _extend(borrower, loanId);
        return read.loan(loanId).expiry == _now() + l.tenor ? 1 : 0;
    }

    // the dues waterfall rows (repay seniority, deleverage paying dues first, `DuesSettled`) went with dues; AceNoDues pins the claim-only melt
}
