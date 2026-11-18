// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.36;

import {IERC721} from "@openzeppelin/contracts/token/ERC721/IERC721.sol";
import {MockERC20} from "../mocks/MockERC20.sol";
import {Reverting1271Wallet, Signing1271Wallet} from "../mocks/Mock1271Wallet.sol";
import {TenorOutOfRange} from "../../src/ace/hub/Borrower.sol";
import {LoanMath} from "../../src/ace/hub/libraries/LoanMath.sol";
import {MarketParams} from "../../src/ace/hub/Types.sol";
import {AceVault} from "../../src/curator/AceVault.sol";
import {AceVaultFlows, BorrowRequest, Terms} from "../../src/curator/AceVaultFlows.sol";
import {PriceGrid} from "../../src/curator/PriceGrid.sol";
import {IInKindTerms, Listing, Quote, RollQuote} from "./InKindSurface.sol";
import {InKindRig} from "./InKindRig.sol";

/// @title InKindQuote
/// @notice The signed quote: the market it builds, each refusal IN ORDER (cheap first, signature last), its life, and the cap and size bounds.
/// @dev An order test makes its stage AND EVERY LATER STAGE fail, so only a check that runs first can produce the expected error.
contract InKindQuoteTest is InKindRig {
    MockERC20 internal tokC; // never listed

    function setUp() public override {
        super.setUp();
        tokC = new MockERC20("Token C", "TKC", 18);
        _lp(alice, LP_CASH);
    }

    /// @dev A quote that fails every stage from the borrower check on: wrong borrower, past its life, over size, over term.
    function _rotten(address coll) internal returns (Quote memory q) {
        q = _quote(coll, PRICE);
        q.borrower = stranger;
        q.issuedAt = uint64(_now() - terms.QUOTE_TTL() - 1);
        q.maxPrincipal = PRINCIPAL - 1;
        q.maxTenor = MIN_TENOR - 1;
    }

    function _borrowExpecting(bytes4 err, address coll, bytes memory data) internal {
        _fund(coll, borrower, UNITS);
        vm.prank(borrower);
        vm.expectRevert(err);
        vault.borrow(_req(coll, UNITS, PRINCIPAL, MIN_TENOR), data, "");
    }

    /// @dev A fresh vault whose tokA row draws at most `maxPrincipal` a loan, funded by alice.
    function _vaultWithMax(uint128 maxPrincipal) internal {
        Listing[] memory l = _listings();
        l[0].row.maxPrincipal = maxPrincipal;
        vault = _deploy(_cfg(0), _ik(), l);
        _lp(alice, LP_CASH);
    }

    // ---- the market a quote builds ----

    /// @notice A valid quote opens a recordless loan at the gridded signed price, titled to the borrower, paid the hub's payout, nonce spent.
    function test_borrow_opensARecordlessLoanAtTheGriddedSignedPrice() public {
        uint256 cash0 = usdc.balanceOf(borrower);
        uint256 loanId = _open(address(tokA));
        MarketParams memory mp = _mp(loanId);
        assertEq(mp.record, address(0), "recordless: no price record, so nothing settles before expiry");
        assertEq(mp.price, PriceGrid.down(PRICE), "the market's price is the signed price rounded down onto the grid");
        assertFalse(mp.inventoryAsk, "no sale: only the vault's redeemInKind moves a pot");
        assertEq(mp.settleBountyBps, 0, "a vault market pays no settle bounty");
        assertEq(mp.deleverageBandBps, 0, "no deleverage band");
        assertEq(mp.fillFeeBps, 0, "no fill fee where nothing is sold");
        assertEq(mp.lender, address(vault), "the vault is the one lender");
        assertEq(mp.borrower, address(0), "the market names nobody, so the title holder can extend");
        assertEq(mp.quote, address(usdc), "quoted in the vault's asset");
        assertEq(mp.collateral, address(tokA), "against the quoted token");
        assertEq(mp.minCoverageWad, COVERAGE, "the vault-wide coverage");
        assertEq(mp.minPrincipal, MIN_PRINCIPAL, "the vault-wide minimum principal");
        assertEq(mp.lenderAprBps, RATE_BPS, "the row's rate");
        assertEq(mp.minTenor, MIN_TENOR, "the row's shortest term");
        assertEq(mp.maxTenor, ROW_MAX_TENOR, "the row's longest term");
        assertEq(IERC721(ace.POSITION_TITLE()).ownerOf(loanId), borrower, "the borrower holds the title");
        uint256 fee = LoanMath.originationFee(PRINCIPAL, MIN_TENOR, RATE_BPS);
        assertEq(usdc.balanceOf(borrower) - cash0, PRINCIPAL - fee, "the borrower got the hub's whole payout");
        assertTrue(terms.spent(_nonce), "the quote's nonce is spent");
        assertEq(ace.restingOf(ace.loanMarket(loanId)), 0, "nothing the vault funds rests between calls");
    }

    /// @notice `previewTerms` names the market and draw the door then opens.
    function test_previewTerms_namesTheMarketTheDoorOpens() public {
        Quote memory q = _quote(address(tokA), PRICE);
        bytes memory data = _data(q);
        BorrowRequest memory r = _req(address(tokA), UNITS, PRINCIPAL, MIN_TENOR);
        (bytes32 id,, Terms memory t) = lens.previewTerms(address(vault), borrower, r, data);
        uint256 loanId = _borrowWith(q, data, UNITS, PRINCIPAL, MIN_TENOR);
        assertEq(ace.loanMarket(loanId), id, "the preview's market is the door's");
        assertEq(t.units, UNITS, "the pledge");
        assertEq(t.principal, PRINCIPAL, "the draw");
        assertEq(t.tenor, MIN_TENOR, "the term");
    }

    /// @notice A zero tenor takes the row's shortest term.
    function test_borrow_zeroTenorTakesTheRowsShortest() public {
        Quote memory q = _quote(address(tokA), PRICE);
        uint256 loanId = _borrowWith(q, _data(q), UNITS, PRINCIPAL, 0);
        assertEq(read.loan(loanId).tenor, MIN_TENOR, "the row's minTenor");
    }

    // ---- the refusals, in order ----

    /// @notice (1) An unlisted token refuses first, ahead of a mismatched quote, the wrong borrower, a dead quote and a bad signature.
    function testRevert_borrow_unlistedTokenRefusesFirst() public {
        Quote memory q = _rotten(address(tokA));
        _borrowExpecting(IInKindTerms.NotListed.selector, address(tokC), _dataBy(q, ROGUE_KEY));
    }

    /// @notice (2) A quote for another listed token refuses second.
    function testRevert_borrow_collateralMismatchRefusesSecond() public {
        Quote memory q = _rotten(address(tokB));
        _borrowExpecting(IInKindTerms.CollateralMismatch.selector, address(tokA), _dataBy(q, ROGUE_KEY));
    }

    /// @notice (3) A caller other than the quoted borrower refuses third.
    function testRevert_borrow_notTheBorrowerRefusesThird() public {
        Quote memory q = _rotten(address(tokA));
        _borrowExpecting(IInKindTerms.NotTheBorrower.selector, address(tokA), _dataBy(q, ROGUE_KEY));
    }

    /// @notice (4) A quote past its life refuses fourth, ahead of the size, the term and the signature.
    function testRevert_borrow_expiredQuoteRefusesFourth() public {
        Quote memory q = _rotten(address(tokA));
        q.borrower = borrower;
        _borrowExpecting(IInKindTerms.QuoteExpired.selector, address(tokA), _dataBy(q, ROGUE_KEY));
    }

    /// @notice (4) A quote issued after now refuses fourth too, by name, ahead of the nonce, the size, the term and the signature.
    function testRevert_borrow_aQuoteIssuedInTheFutureRefuses() public {
        _open(address(tokA));
        Quote memory q = _rotten(address(tokA));
        (q.borrower, q.issuedAt, q.nonce) = (borrower, uint64(_now() + 1), _nonce - 1);
        assertTrue(terms.spent(q.nonce), "premise: the nonce is spent, so a later stage would refuse it too");
        _borrowExpecting(IInKindTerms.QuoteNotYetIssued.selector, address(tokA), _dataBy(q, ROGUE_KEY));
    }

    /// forge-config: default.fuzz.runs = 64
    /// @notice Any issue time after now refuses by name, up to the uint64 maximum: the life sum is never reached, so it cannot overflow.
    function testFuzz_borrow_anyFutureIssuedAtRefusesByName(uint64 issuedAt) public {
        issuedAt = uint64(bound(issuedAt, _now() + 1, type(uint64).max));
        Quote memory q = _quote(address(tokA), PRICE);
        q.issuedAt = issuedAt;
        _borrowExpecting(IInKindTerms.QuoteNotYetIssued.selector, address(tokA), _data(q));
        assertFalse(terms.spent(q.nonce), "a refused borrow burns no nonce");
    }

    /// @notice The largest issue time refuses by name, never by Panic: the issue check runs before the life is summed in uint64.
    /// @dev Deterministic twin of the fuzz row: the overflowing band is the last QUOTE_TTL seconds of uint64, which a fuzz run may miss.
    function testRevert_borrow_theMaxIssuedAtRefusesByNameNotByPanic() public {
        Quote memory q = _quote(address(tokA), PRICE);
        q.issuedAt = type(uint64).max;
        _borrowExpecting(IInKindTerms.QuoteNotYetIssued.selector, address(tokA), _data(q));
        q.issuedAt = type(uint64).max - terms.QUOTE_TTL() + 1;
        _borrowExpecting(IInKindTerms.QuoteNotYetIssued.selector, address(tokA), _data(q));
    }

    /// @notice A quote issued this very second is live: the issue check is strict, so `issuedAt == now` never refuses.
    function test_borrow_aQuoteIssuedThisSecondIsAdmitted() public {
        Quote memory q = _quote(address(tokA), PRICE);
        assertEq(q.issuedAt, _now(), "premise: issued now");
        assertGt(_borrowWith(q, _data(q), UNITS, PRINCIPAL, MIN_TENOR), 0, "admitted at its issue second");
    }

    /// @notice A draw of exactly the row's maximum principal is admitted under a larger signed quote; one atom over refuses by name.
    function test_borrow_aDrawOfExactlyTheRowsMaxIsAdmitted() public {
        _vaultWithMax(uint128(PRINCIPAL));
        Quote memory over = _quote(address(tokA), PRICE);
        over.maxPrincipal = PRINCIPAL * 10;
        _fund(address(tokA), borrower, UNITS);
        bytes memory overData = _data(over);
        vm.prank(borrower);
        vm.expectRevert(IInKindTerms.OverMaxPrincipal.selector);
        vault.borrow(_req(address(tokA), UNITS, PRINCIPAL + 1, MIN_TENOR), overData, "");
        Quote memory q = _quote(address(tokA), PRICE);
        q.maxPrincipal = PRINCIPAL * 10;
        uint256 loanId = _borrowWith(q, _data(q), UNITS, PRINCIPAL, MIN_TENOR);
        assertEq(read.loan(loanId).debt, PRINCIPAL, "the row's own maximum is lendable");
    }

    /// @notice (4) A spent nonce refuses fourth too: the second quote on one nonce never reaches the size or the signature.
    function testRevert_borrow_spentNonceRefusesFourth() public {
        _open(address(tokA));
        Quote memory q = _rotten(address(tokA));
        (q.borrower, q.issuedAt, q.nonce) = (borrower, uint64(_now()), _nonce - 1);
        _borrowExpecting(IInKindTerms.QuoteUsed.selector, address(tokA), _dataBy(q, ROGUE_KEY));
    }

    /// @notice (5) A draw over the quote's maximum principal refuses fifth, ahead of the term and the signature.
    function testRevert_borrow_principalOverMaxRefusesFifth() public {
        Quote memory q = _rotten(address(tokA));
        (q.borrower, q.issuedAt) = (borrower, uint64(_now()));
        _borrowExpecting(IInKindTerms.OverMaxPrincipal.selector, address(tokA), _dataBy(q, ROGUE_KEY));
    }

    /// @notice A draw of exactly the quote's maximum principal is admitted.
    function test_borrow_principalAtMaxIsAdmitted() public {
        Quote memory q = _quote(address(tokA), PRICE);
        q.maxPrincipal = PRINCIPAL;
        uint256 loanId = _borrowWith(q, _data(q), UNITS, PRINCIPAL, MIN_TENOR);
        assertGt(loanId, 0, "admitted");
    }

    /// @notice The row's maximum principal binds under a larger signed quote: one atom over the row refuses by the same name.
    function testRevert_borrow_principalOverTheRowsMaxRefuses() public {
        _vaultWithMax(uint128(PRINCIPAL - 1));
        Quote memory q = _quote(address(tokA), PRICE);
        q.maxPrincipal = PRINCIPAL * 10;
        _borrowExpecting(IInKindTerms.OverMaxPrincipal.selector, address(tokA), _data(q));
        assertFalse(terms.spent(q.nonce), "a refused borrow burns no nonce");
    }

    /// @notice A term longer than the quote was signed for refuses before the signature: the price was signed for a horizon.
    function testRevert_borrow_tenorOverTheQuotesMaxRefusesBeforeTheSignature() public {
        Quote memory q = _quote(address(tokA), PRICE);
        q.maxTenor = MIN_TENOR;
        _fund(address(tokA), borrower, UNITS);
        bytes memory data = _dataBy(q, ROGUE_KEY);
        vm.prank(borrower);
        vm.expectRevert(IInKindTerms.TenorOverQuote.selector);
        vault.borrow(_req(address(tokA), UNITS, PRINCIPAL, MIN_TENOR + 1 days), data, "");
    }

    /// @notice A term past the row's longest is refused by the hub, which reads the market's maxTenor from the row, whatever the quote signed.
    function testRevert_borrow_aTenorOverTheRowsMaxRefusesAtTheHub() public {
        Quote memory q = _quote(address(tokA), PRICE);
        q.maxTenor = ROW_MAX_TENOR + 1 days;
        _fund(address(tokA), borrower, UNITS);
        bytes memory data = _data(q);
        vm.prank(borrower);
        vm.expectRevert(TenorOutOfRange.selector);
        vault.borrow(_req(address(tokA), UNITS, PRINCIPAL, ROW_MAX_TENOR + 1), data, "");
    }

    /// @notice A zero tenor is judged at the row's shortest term against the quote's maximum, never waved through.
    function testRevert_borrow_zeroTenorIsJudgedAtTheRowsShortest() public {
        Quote memory q = _quote(address(tokA), PRICE);
        q.maxTenor = MIN_TENOR - 1;
        _fund(address(tokA), borrower, UNITS);
        bytes memory data = _data(q);
        vm.prank(borrower);
        vm.expectRevert(IInKindTerms.TenorOverQuote.selector);
        vault.borrow(_req(address(tokA), UNITS, PRINCIPAL, 0), data, "");
    }

    /// @notice (7) A signature by anyone but the appraiser refuses last, every other check having passed.
    function testRevert_borrow_badSignatureRefusesLast() public {
        Quote memory q = _quote(address(tokA), PRICE);
        _borrowExpecting(IInKindTerms.BadSignature.selector, address(tokA), _dataBy(q, ROGUE_KEY));
    }

    /// @notice A signed price the grid rounds to zero is refused by name, as CuratorTerms refuses one.
    function testRevert_borrow_aGriddedToZeroPriceIsRefused() public {
        assertEq(PriceGrid.down(1), 0, "premise: one atom of Q96 price falls off the grid");
        Quote memory q = _quote(address(tokA), 1);
        _borrowExpecting(IInKindTerms.PriceZero.selector, address(tokA), _data(q));
    }

    /// @notice A refused borrow burns no nonce: the same quote still opens once its fault is gone.
    function test_borrow_aRefusedBorrowBurnsNoNonce() public {
        Quote memory q = _quote(address(tokA), PRICE);
        bytes memory data = _data(q);
        _fund(address(tokA), borrower, UNITS);
        vm.prank(borrower);
        vm.expectRevert(IInKindTerms.OverMaxPrincipal.selector);
        vault.borrow(_req(address(tokA), UNITS, PRINCIPAL + 1, MIN_TENOR), data, "");
        assertFalse(terms.spent(q.nonce), "the refused borrow left the nonce unspent");
        vm.prank(borrower);
        vault.borrow(_req(address(tokA), UNITS, PRINCIPAL, MIN_TENOR), data, "");
        assertTrue(terms.spent(q.nonce), "and the good borrow spent it");
    }

    /// @notice The drain stops the door before the quote is read.
    function testRevert_borrow_whileDraining() public {
        vm.prank(guardian);
        vault.setDrain(true);
        Quote memory q = _quote(address(tokA), PRICE);
        _borrowExpecting(AceVault.Draining.selector, address(tokA), _data(q));
    }

    // ---- the cap ----

    /// @notice The cap bounds what is lent against a token: a draw past the room refuses, a draw of exactly the room lands.
    function test_cap_boundsLentExposure() public {
        Listing[] memory l = _listings();
        l[0].cap = 1_500e6;
        vault = _deploy(_cfg(0), _ik(), l);
        _lp(alice, LP_CASH);
        _open(address(tokA));
        Quote memory q = _quote(address(tokA), PRICE);
        _borrowExpecting(AceVaultFlows.OverCap.selector, address(tokA), _data(q));
        uint256 loanId = _openFor(address(tokA), 500e6, MIN_TENOR);
        assertGt(read.loan(loanId).debt, 0, "a draw of exactly the room lands");
    }

    /// @notice A settled loan's claim leaves the row, so the cap reopens at the settle: seized tokens are never valued against it.
    /// @notice The total steps down instead: the drawdown is the claim less the unearned fee escrow the settle credits, and holds the total's room.
    function test_cap_reopensWhenALoanSettles() public {
        Listing[] memory l = _listings();
        l[0].cap = 1_000e6;
        total = 2_500e6;
        vault = _deploy(_cfg(0), _ik(), l);
        _lp(alice, LP_CASH);
        uint256 first = _open(address(tokA));
        assertEq(lens.drawdown(address(vault)), 0, "premise: no loss yet");
        _toExpiry(first);
        (uint256 lent0,) = ace.lenderByCollateral(address(vault), address(usdc), address(tokA));
        uint256 escrow = read.feeEscrowOf(first);
        _collect(first);
        (uint256 lent1,) = ace.lenderByCollateral(address(vault), address(usdc), address(tokA));
        uint256 claim = lent0 - lent1;
        assertGt(claim, 0, "premise: the settle retired the first loan's claim");
        assertEq(lens.drawdown(address(vault)), claim - escrow, "the drawdown is the claim less the unearned escrow the settle credited");
        assertEq(lens.roomOf(address(vault), address(tokB)), total - lens.drawdown(address(vault)), "the total stepped down by it");
        uint256 second = _open(address(tokA));
        assertGt(read.loan(second).debt, 0, "the whole row is open again once the first claim retired");
    }

    // ---- the appraiser key ----

    /// @notice Seating a new appraiser kills every live quote the old key signed, and the new key's quotes open.
    function test_acceptAppraiser_rotationKillsOldQuotes() public {
        address next = vm.addr(ROGUE_KEY);
        _submitAppraiser(next);
        Quote memory old = _quote(address(tokA), PRICE);
        bytes memory oldData = _data(old);
        vm.expectEmit(true, true, false, false, address(terms));
        emit IInKindTerms.AppraiserSet(appraiser, next);
        _acceptAppraiser();
        assertEq(terms.APPRAISER(), next, "the new key signs");
        _borrowExpecting(IInKindTerms.BadSignature.selector, address(tokA), oldData);
        Quote memory fresh = _quote(address(tokA), PRICE);
        uint256 loanId = _borrowWith(fresh, _dataBy(fresh, ROGUE_KEY), UNITS, PRINCIPAL, MIN_TENOR);
        assertGt(loanId, 0, "the new key's quote opens");
    }

    /// @notice Only the curator appoints: the guardian and a stranger are refused.
    function testRevert_submitAppraiser_onlyTheCurator() public {
        vm.prank(guardian);
        vm.expectRevert(IInKindTerms.NotCurator.selector);
        terms.submitAppraiser(stranger);
        vm.prank(stranger);
        vm.expectRevert(IInKindTerms.NotCurator.selector);
        terms.submitAppraiser(stranger);
    }

    /// @notice A zero appointment is refused: zero is the halt's, which lands at once.
    function testRevert_submitAppraiser_zeroIsRefused() public {
        vm.prank(curator);
        vm.expectRevert(IInKindTerms.ZeroAppraiser.selector);
        terms.submitAppraiser(address(0));
    }

    /// @notice An EIP-7702-delegated account is refused where it can be seen: it is never seated, so it is never appointed either.
    function testRevert_submitAppraiser_aDelegatedEoaIsRefused() public {
        address eoa = vm.addr(0x7702);
        vm.etch(eoa, abi.encodePacked(hex"ef0100", address(new Signing1271Wallet())));
        vm.prank(curator);
        vm.expectRevert(IInKindTerms.DelegatedAppraiser.selector);
        terms.submitAppraiser(eoa);
    }

    /// @notice An ERC-1271 appraiser signs by answering for the terms' digest.
    function test_erc1271Appraiser_opensALoan() public {
        Signing1271Wallet w = new Signing1271Wallet();
        _appoint(address(w));
        Quote memory q = _quote(address(tokA), PRICE);
        w.sign(terms.hashQuote(q));
        uint256 loanId = _borrowWith(q, abi.encode(q, bytes("")), UNITS, PRINCIPAL, MIN_TENOR);
        assertGt(loanId, 0, "the contract appraiser's answer opened the loan");
    }

    /// @notice A contract appraiser that reverts is a bad signature, never a bubbled revert.
    function testRevert_erc1271Appraiser_aRevertIsABadSignature() public {
        Reverting1271Wallet w = new Reverting1271Wallet();
        _appoint(address(w));
        Quote memory q = _quote(address(tokA), PRICE);
        _borrowExpecting(IInKindTerms.BadSignature.selector, address(tokA), abi.encode(q, bytes("")));
    }

    // ---- the digests ----

    function _domain() internal view returns (bytes32) {
        (, string memory name, string memory version, uint256 chainId, address verifying,,) = terms.eip712Domain();
        assertEq(verifying, address(terms), "the domain names the terms");
        assertEq(chainId, block.chainid, "and this chain");
        bytes32 t = keccak256("EIP712Domain(string name,string version,uint256 chainId,address verifyingContract)");
        return keccak256(abi.encode(t, keccak256(bytes(name)), keccak256(bytes(version)), chainId, verifying));
    }

    /// @notice The quote digest is EIP-712 over every field, maxTenor and issuedAt included, derived here from the type string alone.
    function test_hashQuote_isTheEip712DigestOverEveryField() public {
        Quote memory q = _quote(address(tokA), PRICE);
        bytes32 th = keccak256("Quote(address collateral,address borrower,uint256 price,uint256 maxPrincipal,uint64 maxTenor,uint256 nonce,uint64 issuedAt)");
        bytes32 want = keccak256(abi.encodePacked(hex"1901", _domain(), keccak256(abi.encode(th, q))));
        assertEq(terms.hashQuote(q), want, "every quote field is bound under the Quote typehash");
    }

    /// @notice The roll digest is EIP-712 under its OWN typehash, issuedAt included, so no quote signature can pass as a roll.
    function test_hashRollQuote_isTheEip712DigestUnderItsOwnTypehash() public view {
        RollQuote memory rq = RollQuote({loanId: 7, expiry: uint64(T0 + 7 days), price: PRICE, issuedAt: uint64(T0)});
        bytes32 th = keccak256("RollQuote(uint256 loanId,uint64 expiry,uint256 price,uint64 issuedAt)");
        bytes32 qth = keccak256("Quote(address collateral,address borrower,uint256 price,uint256 maxPrincipal,uint64 maxTenor,uint256 nonce,uint64 issuedAt)");
        assertTrue(th != qth, "premise: the two types hash apart");
        bytes32 want = keccak256(abi.encodePacked(hex"1901", _domain(), keccak256(abi.encode(th, rq))));
        assertEq(terms.hashRollQuote(rq), want, "every roll field is bound under the RollQuote typehash");
    }
}
