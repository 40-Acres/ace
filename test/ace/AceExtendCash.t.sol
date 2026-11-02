// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.36;

import {IERC721} from "@openzeppelin/contracts/token/ERC721/IERC721.sol";
import {ExtensionAddsNoTime, GateRefused, LoanClosed, LoanMatured, NotBorrower, PolicyRefused} from "../../src/ace/hub/Borrower.sol";
import {LoanMath} from "../../src/ace/hub/libraries/LoanMath.sol";
import {Loan, MarketParams} from "../../src/ace/hub/Types.sol";
import {AceLens} from "../../src/ace/lens/AceLens.sol";
import {Extension} from "../../src/interfaces/IRollPolicy.sol";
import {IPermit2} from "../../src/interfaces/IPermit2.sol";
import {MockPermit2} from "../mocks/MockPermit2.sol";
import {ExtendRig} from "../utils/ExtendRig.sol";
import {MatchingPolicy, YesPolicy} from "../utils/RollPolicyMocks.sol";

/// @title AceExtendCashTest
/// @notice MANUAL RENEWAL'S ONE DOOR: `extend` takes no mode, the caller pays the fee in cash, and the debt never moves.
/// @notice The borrower extends; so does the market lender holding the borrower's credit grant, in cash it pays itself.
/// @notice `extendWithPermit2` is the sibling door; every extension runs the loan's own tenor from now, and only inside its term.
/// @dev Reasoning: the design record,,.
contract AceExtendCashTest is ExtendRig {
    address internal constant PERMIT2 = 0x000000000022D473030F116dDEE9F6B43aC78BA3;
    uint256 internal constant PBOR_PK = 0xB0B0B; // a borrower with a key, for the rows that sign a permit
    uint256 internal constant PLEND_PK = 0x1E4D; // a lender with a key, for the E-3 permit rows
    uint64 internal constant TEN30 = 30 days;

    AceLens internal lens;
    YesPolicy internal yes;
    address internal pbor;
    address internal plend;

    event Extended(uint256 indexed id, uint64 added, uint64 newExpiry, uint256 fee, address indexed executor);

    function setUp() public override {
        super.setUp();
        lens = new AceLens(address(ace));
        yes = new YesPolicy();
        _setPolicy(alice, address(yes));
        _deposit(id, alice, 4 * P);
        (pbor, plend) = (vm.addr(PBOR_PK), vm.addr(PLEND_PK));
        vm.etch(PERMIT2, address(new MockPermit2()).code);
    }

    /* ============================== helpers ============================== */

    /// @dev `who` extends `loanId` now through the cash door, minted and approved for the fee ceiling first.
    function _ext(address who, uint256 loanId) internal returns (uint256 fee) {
        _fund(who, _ceiling(loanId));
        vm.prank(who);
        fee = ace.extend(loanId, 0, "");
    }

    /// @dev Another market of `alice`'s on the rig's pair with its own tenor grid, so its own id, resting cash to lend.
    function _gridMarket(uint64 minT, uint64 maxT) internal returns (bytes32 mid) {
        MarketParams memory p = _params(alice);
        (p.minTenor, p.maxTenor) = (minT, maxT);
        mid = ace.createMarket(p);
        _deposit(mid, alice, 3 * P);
    }

    function _assertRefused(address who, uint256 loanId, bytes4 err) internal {
        _fund(who, _fee(read.debtOf(loanId), TEN7));
        vm.prank(who);
        vm.expectRevert(err);
        ace.extend(loanId, 0, "");
    }

    function _sign(uint256 pk, address token, uint256 amt, uint256 nonce, uint256 deadline) internal view returns (bytes memory) {
        MockPermit2 p2 = MockPermit2(PERMIT2);
        bytes32 structHash = keccak256(
            abi.encode(p2.PERMIT_TRANSFER_FROM_TYPEHASH(), keccak256(abi.encode(p2.TOKEN_PERMISSIONS_TYPEHASH(), token, amt)), address(ace), nonce, deadline)
        );
        (uint8 v, bytes32 r, bytes32 s) = vm.sign(pk, keccak256(abi.encodePacked("\x19\x01", p2.DOMAIN_SEPARATOR(), structHash)));
        return abi.encodePacked(r, s, v);
    }

    /// @dev A SignatureTransfer blob for `amt` of the quote; build it BEFORE a prank, since its reads are calls.
    function _blob(uint256 pk, uint256 amt, uint256 nonce) internal view returns (bytes memory) {
        uint256 deadline = _now() + 1 hours;
        IPermit2.PermitTransferFrom memory p = IPermit2.PermitTransferFrom(IPermit2.TokenPermissions(address(usdc), amt), nonce, deadline);
        return abi.encode(p, _sign(pk, address(usdc), amt, nonce, deadline));
    }

    /// @dev A funded account whose ONLY approval is to Permit2, so any plain-allowance pull would revert.
    function _permitFund(address who, uint256 amt) internal {
        usdc.mint(who, amt);
        vm.prank(who);
        usdc.approve(PERMIT2, type(uint256).max);
    }

    /// @dev A loan held by the keyed borrower, its hub allowance zeroed, a day into its term.
    function _permitLoan() internal returns (uint256 loanId) {
        loanId = _openIn(id, pbor, P, TEN7, 5000);
        vm.prank(pbor);
        usdc.approve(address(ace), 0);
        _warpBy(1 days);
    }

    /* ============================== the door ============================== */

    /// @notice The door takes no mode: the borrower's call lands, keeps the id and title, runs the tenor from now and logs the new event.
    function test_TheCashDoorTakesNoModeAndRunsTheTenorFromNow() public {
        uint256 loanId = _open(P, TEN7, 5000);
        _warpBy(1 days);
        Loan memory l0 = read.loan(loanId);
        uint256 n = read.loanCount();
        uint256 fee = _fee(l0.debt, 1 days);
        _fund(borrower, fee);
        vm.expectEmit(true, true, false, true, address(ace));
        emit Extended(loanId, 1 days, uint64(_now()) + TEN7, fee, borrower);
        vm.prank(borrower);
        uint256 got = ace.extend(loanId, 0, "");
        assertEq(got, fee, "the verb returns the fee on the time added");
        Loan memory l1 = read.loan(loanId);
        assertTrue(ace.isLiveLoan(loanId), "the same id is still live");
        assertEq(read.loanCount(), n, "and no successor id was minted");
        assertEq(IERC721(ace.POSITION_TITLE()).ownerOf(loanId), borrower, "the title never moved");
        assertEq(l1.expiry, _now() + TEN7, "the expiry is now plus the loan's own tenor");
        assertEq(l1.collateralUnits, l0.collateralUnits, "the lot is untouched");
    }

    /// @notice The debt and the claim never move across two extensions: the debt only ever falls after origination.
    function test_TheDebtAndTheClaimNeverMove() public {
        uint256 loanId = _open(P, TEN7, 5000);
        _warpBy(2 days);
        uint256 debt = read.debtOf(loanId);
        uint256 claim = read.claimOf(id, loanId);
        (, uint256 lent0,) = read.poolOf(id);
        _ext(borrower, loanId);
        _warpBy(3 days);
        _ext(borrower, loanId);
        assertEq(read.debtOf(loanId), debt, "the debt did not move");
        assertEq(ace.debtOf(loanId), debt, "and the hub's guarded read agrees");
        assertEq(read.claimOf(id, loanId), claim, "nor did the claim");
        assertEq(debt, claim, "the debt is the claim");
        (, uint256 lent1,) = read.poolOf(id);
        assertEq(lent1, lent0, "lent did not move");
    }

    /// @notice The caller pays the whole fee: the protocol cut is revenue, the tick cut and the earned old escrow are owed, the escrow cut escrowed.
    function test_TheFeeIsPulledFromTheCallerAndBookedInCash() public {
        uint256 loanId = _open(P, TEN7, 5000);
        _warpBy(2 days);
        uint256 f0 = read.feeEscrowOf(loanId);
        uint256 r = _unearned(loanId, f0);
        uint256 fee = _fee(read.debtOf(loanId), 2 days);
        _fund(borrower, fee);
        uint256 payer0 = usdc.balanceOf(borrower);
        uint256 hub0 = usdc.balanceOf(address(ace));
        uint256 rev0 = read.protocolRevenue(id);
        (, uint256 lent0, uint256 owed0) = read.poolOf(id);
        uint256 resting0 = ace.restingOf(id);
        vm.prank(borrower);
        ace.extend(loanId, 0, "");
        assertEq(usdc.balanceOf(borrower), payer0 - fee, "the caller paid the whole fee");
        assertEq(usdc.balanceOf(address(ace)), hub0 + fee, "and the hub holds it");
        assertEq(read.protocolRevenue(id), rev0 + LoanMath.protocolCut(fee), "the protocol cut is revenue");
        (, uint256 lent1, uint256 owed1) = read.poolOf(id);
        assertEq(owed1, owed0 + (f0 - r) + LoanMath.tickCut(fee), "owed takes the earned old escrow and the tick cut");
        assertEq(lent1, lent0, "lent does not move");
        assertEq(read.feeEscrowOf(loanId), r + LoanMath.escrowCut(fee), "the escrow holds the unearned old escrow and the escrow cut");
        assertEq(ace.restingOf(id), resting0, "resting cash is untouched");
        _assertSolvent();
    }

    /// @notice A caller who cannot pay reverts the whole extension: the term, the escrow, revenue and owed stay where they were.
    function test_ACallerWhoCannotPayRevertsAndNothingMoves() public {
        uint256 loanId = _open(P, TEN7, 5000);
        _warpBy(2 days);
        vm.prank(borrower);
        usdc.approve(address(ace), 0);
        Loan memory l0 = read.loan(loanId);
        uint256 f0 = read.feeEscrowOf(loanId);
        uint256 rev0 = read.protocolRevenue(id);
        (,, uint256 owed0) = read.poolOf(id);
        vm.prank(borrower);
        vm.expectRevert();
        ace.extend(loanId, 0, "");
        assertEq(read.loan(loanId).expiry, l0.expiry, "the term did not move");
        assertEq(read.feeEscrowOf(loanId), f0, "nor the escrow");
        assertEq(read.protocolRevenue(id), rev0, "nor revenue");
        (,, uint256 owed1) = read.poolOf(id);
        assertEq(owed1, owed0, "nor owed");
    }

    /// @notice A market whose lender took every resting atom home still extends: resting cash never funds an extension.
    function test_ADrainedMarketStillExtends() public {
        uint256 loanId = _open(P, TEN7, 5000);
        _drain(id, alice);
        assertEq(ace.restingOf(id), 0, "PREMISE: nothing rests");
        _warpBy(1 days);
        _ext(borrower, loanId);
        assertEq(read.loan(loanId).expiry, _now() + TEN7, "the extension lands at zero cash");
        assertEq(ace.restingOf(id), 0, "and rests nothing");
    }

    /* ============================== callers (review E-3) ============================== */

    /// @notice E-3: the market lender holding the borrower's grant extends in cash it pays itself; the holder pays and owes nothing more.
    function test_E3_TheGrantedLenderPaysAndTheHolderOwesNothingMore() public {
        uint256 loanId = _open(P, TEN7, 5000);
        vm.prank(borrower);
        ace.setCreditOperator(alice, true);
        _warpBy(1 days);
        uint256 debt = read.debtOf(loanId);
        uint256 fee = _feeNow(loanId);
        _fund(alice, fee);
        uint256 lenderBal = usdc.balanceOf(alice);
        uint256 borrowerBal = usdc.balanceOf(borrower);
        vm.expectEmit(true, true, false, true, address(ace));
        emit Extended(loanId, 1 days, uint64(_now()) + TEN7, fee, alice);
        vm.prank(alice);
        ace.extend(loanId, 0, "");
        assertEq(read.loan(loanId).expiry, _now() + TEN7, "the lender's extension landed");
        assertEq(usdc.balanceOf(alice), lenderBal - fee, "paid by the lender itself");
        assertEq(usdc.balanceOf(borrower), borrowerBal, "the borrower paid nothing");
        assertEq(read.debtOf(loanId), debt, "and owes nothing more");
    }

    /// @notice E-3: the escrow the lender funded is the holder's at close: a full repay refunds it to the holder, never to the payer.
    function test_E3_TheEscrowTheLenderFundedRefundsToTheHolder() public {
        uint256 loanId = _open(P, TEN7, 5000);
        vm.prank(borrower);
        ace.setCreditOperator(alice, true);
        _warpBy(1 days);
        _ext(alice, loanId);
        uint256 refund = _unearned(loanId, read.feeEscrowOf(loanId));
        assertGt(refund, 0, "PREMISE: an unearned escrow to refund");
        uint256 debt = read.debtOf(loanId);
        _fund(borrower, debt);
        vm.prank(borrower);
        ace.repay(loanId, debt);
        assertTrue(ace.isClosed(loanId), "PREMISE: the repay closed the loan");
        assertEq(read.quoteOwedOf(loanId, borrower), refund, "the holder takes the unearned escrow");
        assertEq(read.quoteOwedOf(loanId, alice), 0, "and the payer takes none of it");
    }

    /// @notice Nobody else extends: a stranger, a keeper, the lender without the grant, and a granted operator who is not the lender.
    function test_E3_EveryOtherCallerIsRefusedNotBorrower() public {
        uint256 loanId = _open(P, TEN7, 5000);
        _assertRefused(stranger, loanId, NotBorrower.selector);
        _assertRefused(keeper, loanId, NotBorrower.selector);
        _assertRefused(alice, loanId, NotBorrower.selector);
        address router = address(0x2077E2);
        vm.prank(borrower);
        ace.setCreditOperator(router, true);
        _assertRefused(router, loanId, NotBorrower.selector);
    }

    /// @notice The grant read is the lender's own and live: a grant to another operator, or one the holder revoked, admits no lender.
    /// @dev A gate asking only whether the holder ever granted anyone passes both refusals here; the control lands on the live grant.
    function test_E3_AGrantToAnotherOperatorOrARevokedGrantAdmitsNoLender() public {
        uint256 loanId = _open(P, TEN7, 5000);
        vm.prank(borrower);
        ace.setCreditOperator(address(0x2077E2), true);
        _assertRefused(alice, loanId, NotBorrower.selector);
        (bool ok, bytes4 why,) = ace.tryExtend(loanId, 0, "", alice);
        assertFalse(ok, "a grant to another operator admits no lender at the preview");
        assertEq(why, NotBorrower.selector, "refused by the caller leg");
        vm.startPrank(borrower);
        ace.setCreditOperator(alice, true);
        ace.setCreditOperator(alice, false);
        vm.stopPrank();
        _assertRefused(alice, loanId, NotBorrower.selector);
        vm.prank(borrower);
        ace.setCreditOperator(alice, true);
        _warpBy(1 days);
        _ext(alice, loanId);
        assertEq(read.loan(loanId).expiry, _now() + TEN7, "CONTROL: the live grant admits the lender");
    }

    /// @notice The borrower rule judges the HOLDER, never the caller: in a market naming its borrower, the granted lender extends for that holder.
    /// @dev Once the title moves to a holder the market does not name, the same lender on that holder's grant is refused `GateRefused`.
    function test_E3_TheBorrowerRuleJudgesTheHolderNotTheLender() public {
        MarketParams memory p = _params(alice);
        p.borrower = borrower;
        bytes32 named = ace.createMarket(p);
        _deposit(named, alice, 2 * P);
        uint256 loanId = _openIn(named, borrower, P, TEN7, 5000);
        vm.prank(borrower);
        ace.setCreditOperator(alice, true);
        _warpBy(1 days);
        _ext(alice, loanId);
        assertEq(read.loan(loanId).expiry, _now() + TEN7, "the granted lender extends for the holder the market names");
        address buyer = address(0xB0E2);
        _moveTitle(loanId, borrower, buyer);
        vm.prank(buyer);
        ace.setCreditOperator(alice, true);
        _warpBy(1 days);
        _assertRefused(alice, loanId, GateRefused.selector);
    }

    /* ============================== the Permit2 sibling (Q2, review R-7) ============================== */

    /// @notice A signed permit funds the extension with no hub allowance at all, pulling exactly the fee.
    function test_Permit2_ExtendsWithNoHubAllowance() public {
        uint256 loanId = _permitLoan();
        uint256 fee = _feeNow(loanId);
        _permitFund(pbor, fee);
        uint256 bal = usdc.balanceOf(pbor);
        bytes memory blob = _blob(PBOR_PK, fee, 0);
        vm.prank(pbor);
        uint256 got = ace.extendWithPermit2(loanId, 0, "", blob);
        assertEq(got, fee, "the door returns the fee");
        assertEq(read.loan(loanId).expiry, _now() + TEN7, "the extension landed");
        assertEq(usdc.balanceOf(pbor), bal - fee, "the permit paid exactly the fee");
        assertEq(usdc.allowance(pbor, address(ace)), 0, "no allowance to the hub was ever needed");
        assertEq(MockPermit2(PERMIT2).nonceBitmap(pbor, 0) & 1, 1, "and the nonce is spent");
    }

    /// @notice An empty blob is the plain allowance pull, byte for byte.
    function test_Permit2_AnEmptyBlobIsThePlainAllowancePull() public {
        uint256 loanId = _open(P, TEN7, 5000);
        _warpBy(1 days);
        uint256 fee = _feeNow(loanId);
        _fund(borrower, fee);
        uint256 bal = usdc.balanceOf(borrower);
        vm.prank(borrower);
        ace.extendWithPermit2(loanId, 0, "", "");
        assertEq(read.loan(loanId).expiry, _now() + TEN7, "the extension landed");
        assertEq(usdc.balanceOf(borrower), bal - fee, "on the plain allowance");
    }

    /// @notice An over-signed permit moves only the fee: the signed amount is a cap, never the pull.
    function test_Permit2_AnOverSignedPermitPullsOnlyTheFee() public {
        uint256 loanId = _permitLoan();
        uint256 fee = _feeNow(loanId);
        _permitFund(pbor, 2 * fee);
        uint256 bal = usdc.balanceOf(pbor);
        bytes memory blob = _blob(PBOR_PK, 2 * fee, 0);
        vm.prank(pbor);
        ace.extendWithPermit2(loanId, 0, "", blob);
        assertEq(usdc.balanceOf(pbor), bal - fee, "only the fee moved");
    }

    /// @notice E-3 on the permit door: the granted lender spends its OWN permit, and the holder pays nothing.
    function test_Permit2_TheGrantedLenderSpendsItsOwnPermit() public {
        (bytes32 mid, uint256 loanId) = _keyedLenderLoan();
        uint256 fee = _feeNow(loanId);
        _permitFund(plend, fee);
        uint256 lenderBal = usdc.balanceOf(plend);
        uint256 holderBal = usdc.balanceOf(pbor);
        bytes memory blob = _blob(PLEND_PK, fee, 0);
        vm.prank(plend);
        ace.extendWithPermit2(loanId, 0, "", blob);
        assertEq(read.loan(loanId).expiry, _now() + TEN7, "the lender's signed extension landed");
        assertEq(usdc.balanceOf(plend), lenderBal - fee, "paid by the lender's own permit");
        assertEq(usdc.balanceOf(pbor), holderBal, "the holder paid nothing");
        assertEq(read.loan(loanId).market, mid, "in the keyed lender's market");
    }

    /// @notice The lender cannot spend the borrower's permit: the door names `msg.sender` as the owner, so the signature does not match.
    function test_Permit2_TheLenderCannotSpendTheBorrowersPermit() public {
        (, uint256 loanId) = _keyedLenderLoan();
        uint256 fee = _feeNow(loanId);
        _permitFund(pbor, fee);
        _permitFund(plend, fee);
        bytes memory borrowerBlob = _blob(PBOR_PK, fee, 0);
        vm.prank(plend);
        vm.expectRevert(MockPermit2.InvalidSigner.selector);
        ace.extendWithPermit2(loanId, 0, "", borrowerBlob);
    }

    /// @notice A refused extension never reaches the pull: no quote moves and the nonce stays unspent, so the signer can retry.
    function test_Permit2_ARefusedExtensionSpendsNoNonce() public {
        uint256 loanId = _permitLoan();
        uint256 fee = _feeNow(loanId);
        _permitFund(pbor, fee);
        _setPolicy(alice, address(0));
        uint256 bal = usdc.balanceOf(pbor);
        bytes memory blob = _blob(PBOR_PK, fee, 0);
        vm.prank(pbor);
        vm.expectRevert(PolicyRefused.selector);
        ace.extendWithPermit2(loanId, 0, "", blob);
        assertEq(usdc.balanceOf(pbor), bal, "nothing moved");
        assertEq(MockPermit2(PERMIT2).nonceBitmap(pbor, 0), 0, "and the nonce is unspent");
    }

    /// @notice A permit is single-use: the second extension on the same blob, a second later, refuses Permit2's own `InvalidNonce`.
    function test_Permit2_ANonceIsSingleUse() public {
        uint256 loanId = _permitLoan();
        uint256 fee = _feeNow(loanId);
        _permitFund(pbor, 2 * fee);
        bytes memory blob = _blob(PBOR_PK, fee, 0);
        vm.prank(pbor);
        ace.extendWithPermit2(loanId, 0, "", blob);
        _warpBy(1);
        vm.prank(pbor);
        vm.expectRevert(MockPermit2.InvalidNonce.selector);
        ace.extendWithPermit2(loanId, 0, "", blob);
    }

    /// @dev A market lent by the keyed lender, its policy a yes, holding a loan of the keyed borrower who granted the lender.
    function _keyedLenderLoan() internal returns (bytes32 mid, uint256 loanId) {
        mid = ace.createMarket(_params(plend));
        _setPolicy(plend, address(yes));
        _deposit(mid, plend, 3 * P);
        loanId = _openIn(mid, pbor, P, TEN7, 5000);
        vm.startPrank(pbor);
        usdc.approve(address(ace), 0);
        ace.setCreditOperator(plend, true);
        vm.stopPrank();
        _warpBy(1 days);
    }

    /* ============================== the single-term market (review R-1) ============================== */

    /// @notice Single term (7/7): the loan's open second adds no time and refuses `ExtensionAddsNoTime`; the next second extends.
    function test_SingleTerm_TheOpenSecondRefusesAndTheNextSecondExtends() public {
        bytes32 one = _gridMarket(TEN7, TEN7);
        uint256 loanId = _openIn(one, borrower, P, TEN7, 5000);
        _fund(borrower, _ceiling(loanId));
        vm.prank(borrower);
        vm.expectRevert(ExtensionAddsNoTime.selector);
        ace.extend(loanId, 0, "");
        _warpBy(1);
        _ext(borrower, loanId);
        assertEq(read.loan(loanId).expiry, _now() + TEN7, "one second in, the extension lands at now plus the tenor");
    }

    /// @notice Single term (7/7): a loan extends at `expiry - 1`, before any close can race it, for the fee on `tenor - 1`.
    function test_SingleTerm_ExtendsAtExpiryMinusOne() public {
        bytes32 one = _gridMarket(TEN7, TEN7);
        uint256 loanId = _openIn(one, borrower, P, TEN7, 5000);
        uint64 x = read.loan(loanId).expiry;
        _warpTo(uint256(x) - 1);
        uint256 fee = _ext(borrower, loanId);
        assertEq(read.loan(loanId).expiry, _now() + TEN7, "the extension landed a second before expiry, at now plus the tenor");
        assertEq(fee, _fee(read.debtOf(loanId), TEN7 - 1), "for the fee on the tenor less one second");
    }

    /* ============================== no late extend ============================== */

    /// @notice From the expiry second an extension refuses `LoanMatured`, at expiry and a day late, and the term stays where it was.
    function test_ALateExtendRefusesLoanMatured() public {
        uint256 loanId = _open(P, TEN7, 5000);
        uint64 x = read.loan(loanId).expiry;
        _fund(borrower, _ceiling(loanId));
        _warpTo(x);
        vm.prank(borrower);
        vm.expectRevert(LoanMatured.selector);
        ace.extend(loanId, 0, "");
        _warpTo(uint256(x) + 1 days);
        vm.prank(borrower);
        vm.expectRevert(LoanMatured.selector);
        ace.extend(loanId, 0, "");
        assertEq(read.loan(loanId).expiry, x, "the term did not move");
        assertTrue(ace.isLiveLoan(loanId), "and the loan stays live, for settlement");
    }

    /// @notice The term re-anchors at every extension: it opens now and runs the loan's own tenor, which never moves, so `openTime + tenor == expiry`.
    /// @dev No hub path reads `openTime`, so only this row sees a re-spread that leaves the old open time beside the new expiry.
    function test_TheTermReAnchorsAtEveryExtension() public {
        uint256 loanId = _open(P, TEN7, 5000);
        _warpBy(2 days);
        _ext(borrower, loanId);
        Loan memory l = read.loan(loanId);
        assertEq(l.openTime, _now(), "an early extension opens the term now");
        assertEq(l.tenor, TEN7, "the tenor does not move");
        assertEq(uint256(l.openTime) + l.tenor, l.expiry, "and the term runs exactly to the new expiry");
        _warpTo(uint256(l.expiry) - 1);
        _ext(borrower, loanId);
        Loan memory m = read.loan(loanId);
        assertEq(m.expiry, _now() + TEN7, "PREMISE: the last-second extension ran the tenor from now");
        assertEq(m.openTime, _now(), "a last-second extension opens the term now too");
        assertEq(m.tenor, TEN7, "the tenor still does not move");
        assertEq(uint256(m.openTime) + m.tenor, m.expiry, "and the record stays one term");
    }

    /// @notice A `forceClose` sent first simply wins: the late extend then refuses `LoanClosed`.
    function test_AForceCloseSentFirstWins() public {
        uint256 loanId = _open(P, TEN7, 5000);
        _warpTo(read.loan(loanId).expiry);
        vm.prank(keeper);
        ace.forceClose(loanId);
        _fund(borrower, _fee(read.debtOf(loanId), TEN7));
        vm.prank(borrower);
        vm.expectRevert(LoanClosed.selector);
        ace.extend(loanId, 0, "");
    }

    /* ============================== what the policy is asked ============================== */

    /// @notice The policy is asked the extension as the loan stands, its debt unchanged, and the caller's own payload.
    function test_ThePolicyIsAskedTheExtensionWithTheDebtUnchanged() public {
        MatchingPolicy m = new MatchingPolicy();
        _setPolicy(alice, address(m));
        uint256 loanId = _open(P, TEN7, 5000);
        _warpBy(1 days);
        Loan memory l = read.loan(loanId);
        Extension memory e;
        (e.caller, e.loanId, e.borrower, e.units) = (borrower, loanId, borrower, l.collateralUnits);
        (e.debt, e.newDebt, e.expiry, e.newExpiry) = (l.debt, l.debt, l.expiry, uint64(_now()) + TEN7);
        (e.src, e.dst) = (_mp(id), _mp(id));
        m.expect(e, hex"c0ffee");
        _fund(borrower, _fee(l.debt, TEN7));
        uint256 snap = vm.snapshotState();
        vm.prank(borrower);
        vm.expectRevert(PolicyRefused.selector);
        ace.extend(loanId, 0, hex"c0ffef");
        vm.revertToState(snap);
        vm.prank(borrower);
        ace.extend(loanId, 0, hex"c0ffee");
        assertEq(read.loan(loanId).expiry, e.newExpiry, "the matching ask consented, at now plus the tenor");
    }
}
