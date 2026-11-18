// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.36;

import {IERC1271} from "@openzeppelin/contracts/interfaces/IERC1271.sol";
import {EIP7702Utils} from "@openzeppelin/contracts/account/utils/EIP7702Utils.sol";
import {MAGIC_VALUE, Permissive1271Wallet, Signing1271Wallet} from "../mocks/Mock1271Wallet.sol";
import {PolicyRefused} from "../../src/ace/hub/Borrower.sol";
import {Loan} from "../../src/ace/hub/Types.sol";
import {Extension, IRollPolicy} from "../../src/interfaces/IRollPolicy.sol";
import {IAceVaultLens, IInKindTerms, IInKindVault, InKindConfig, Quote, RollQuote} from "./InKindSurface.sol";
import {InKindRig} from "./InKindRig.sol";

/// @title InKindDelegatedAppraiser
/// @notice An EIP-7702 delegation on the appraiser's EOA is never asked to sign: an account holding only a designator verifies by ECDSA alone.
/// @notice ATTACKER'S ORDER: the curator seats a clean EOA, the EOA later delegates to a permissive wallet, then anyone forges a quote or a roll.
/// @notice OZ `SignatureChecker` branches on live `code.length`, so the 23-byte designator would hand every check to the delegate's `isValidSignature`.
/// @dev THE CHECK READS THE ACCOUNT AT EACH SIGNATURE: no code, or exactly a designator, verifies by `ECDSA.tryRecover`; any other code by ERC-1271 only.
/// @dev Seating refuses zero and a delegated account by name, at the constructor and at an accepted appointment, and stores only the address.
/// @dev No verification mode is stored, so a Safe appointed before it is deployed signs by ERC-1271 once it is, with no re-appointment.
/// @dev The delegation is etched as `0xef0100 || delegate`; every row that relies on it first proves the EVM follows it.
contract InKindDelegatedAppraiserTest is InKindRig {
    uint256 internal constant EOA_KEY = 0x7702A99;
    uint256 internal constant NEXT_KEY = 0x7702B77; // a would-be appraiser the curator appoints
    uint256 internal constant SECP256K1_N = 0xFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFEBAAEDCE6AF48A03BBFD25E8CD0364141; // the curve order a high-s copy reflects across
    address internal eoa;
    address internal delegate;
    uint256 internal loanId;

    /// @dev A vault is born with a clean EOA appraiser, a loan opens on its honest ECDSA quote, and only then does the EOA install the delegation.
    function setUp() public override {
        super.setUp();
        eoa = vm.addr(EOA_KEY);
        InKindConfig memory ik = _ik();
        ik.appraiser = eoa;
        vault = _deploy(_cfg(0), ik, _listings());
        _lp(alice, LP_CASH);
        assertEq(terms.APPRAISER(), eoa, "premise: the clean EOA was seated");
        Quote memory q = _quote(address(tokA), PRICE);
        loanId = _borrowWith(q, _dataBy(q, EOA_KEY), UNITS, PRINCIPAL, MIN_TENOR);
        delegate = address(new Permissive1271Wallet());
        vm.etch(eoa, abi.encodePacked(hex"ef0100", delegate));
    }

    /// @dev The delegation is live and the EVM routes an ERC-1271 ask of the EOA to the delegate, which answers yes to anything.
    function _premiseDelegated() internal view {
        assertEq(eoa.code.length, 23, "premise: the account holds exactly the 23-byte designator");
        assertEq(EIP7702Utils.fetchDelegate(eoa), delegate, "premise: the appraiser now carries a 7702 delegation");
        assertEq(terms.APPRAISER(), eoa, "premise: the vault still names the now-delegated EOA");
        bytes4 answer = IERC1271(eoa).isValidSignature(keccak256("anything at all"), hex"00");
        assertEq(answer, MAGIC_VALUE, "premise: the EVM follows the designator, so the delegate would answer for the EOA");
    }

    /// @dev Borrow the rig's standard draw on `data`: refused `BadSignature`, no cash out, no nonce burned.
    function _assertBorrowRefused(Quote memory q, bytes memory data) internal {
        _fund(address(tokA), borrower, UNITS);
        uint256 cash = usdc.balanceOf(borrower);
        bytes memory cd = abi.encodeCall(IInKindVault.borrow, (_req(address(tokA), UNITS, PRINCIPAL, MIN_TENOR), data, bytes("")));
        vm.prank(borrower);
        (bool ok, bytes memory err) = address(vault).call(cd);
        assertFalse(ok, "BUG: a quote the seat does not verify opened a loan");
        assertEq(err, abi.encodeWithSelector(IInKindTerms.BadSignature.selector), "refused by name: BadSignature");
        assertEq(usdc.balanceOf(borrower), cash, "the borrower was paid nothing");
        assertFalse(terms.spent(q.nonce), "a refused borrow burns no nonce");
    }

    /// @dev The roll quote the appraiser would sign for `id` now, at the market's own price.
    function _rq(uint256 id) internal view returns (RollQuote memory) {
        return RollQuote({loanId: id, expiry: uint64(_expiry(id)), price: _mp(id).price, issuedAt: uint64(_now())});
    }

    /// @dev The extension the hub hands the vault when the holder extends `id` now: its own tenor from now, `dst` a copy of `src`.
    function _ext(uint256 id) internal view returns (Extension memory e) {
        Loan memory l = read.loan(id);
        (e.caller, e.loanId, e.borrower, e.units, e.debt, e.newDebt) = (l.borrower, id, l.borrower, l.collateralUnits, l.debt, l.debt);
        (e.expiry, e.newExpiry, e.src, e.dst) = (l.expiry, uint64(_now()) + l.tenor, _mp(id), _mp(id));
    }

    /// @dev The holder extends the setUp loan on `data` and must land a fresh term from now.
    function _assertExtends(bytes memory data) internal {
        _armFee(loanId, MIN_TENOR);
        vm.prank(borrower);
        ace.extend(loanId, 0, data);
        assertEq(_expiry(loanId), _now() + MIN_TENOR, "the loan runs its term again from now");
    }

    /// @dev The holder extends the setUp loan on `data` and the hub must refuse it, the expiry standing.
    function _assertExtendRefused(bytes memory data) internal {
        uint256 e0 = _expiry(loanId);
        _armFee(loanId, MIN_TENOR);
        vm.prank(borrower);
        vm.expectRevert(PolicyRefused.selector);
        ace.extend(loanId, 0, data);
        assertEq(_expiry(loanId), e0, "the loan's expiry did not move");
    }

    function _toWindow() internal {
        _warpAtLeastTo(_expiry(loanId) - 1 hours);
    }

    // ---- the borrow door, once the appraiser's EOA delegates ----

    /// @notice A quote signed by a key that is not the appraiser's refuses `BadSignature`: the permissive delegate is never asked.
    function test_borrow_aForeignKeysQuoteIsRefusedOnceTheAppraiserDelegates() public {
        _premiseDelegated();
        Quote memory q = _quote(address(tokA), PRICE);
        _assertBorrowRefused(q, _dataBy(q, ROGUE_KEY));
    }

    /// @notice A quote carrying garbage where the signature goes refuses `BadSignature`.
    function test_borrow_garbageSignatureBytesAreRefusedOnceTheAppraiserDelegates() public {
        _premiseDelegated();
        Quote memory q = _quote(address(tokA), PRICE);
        _assertBorrowRefused(q, abi.encode(q, hex"deadbeef"));
    }

    /// @notice The appraiser's own ECDSA quote still prices once it delegates: a designator takes the ECDSA branch, so the vault keeps lending.
    function test_borrow_theAppraisersOwnQuoteStillPricesOnceItDelegates() public {
        _premiseDelegated();
        Quote memory q = _quote(address(tokA), PRICE);
        uint256 cash = usdc.balanceOf(borrower);
        uint256 id = _borrowWith(q, _dataBy(q, EOA_KEY), UNITS, PRINCIPAL, MIN_TENOR);
        assertEq(read.loan(id).borrower, borrower, "the delegated key's quote opened a loan titled to the borrower");
        assertGt(usdc.balanceOf(borrower), cash, "and paid the borrower in the same call");
        assertTrue(terms.spent(q.nonce), "the quote nonce is cashed");
    }

    /// @notice The preview runs the door's own check, so it refuses a forged payload `BadSignature` rather than quoting it admissible.
    function test_previewTerms_aForgedPayloadRefusesBadSignatureOnceTheAppraiserDelegates() public {
        _premiseDelegated();
        Quote memory q = _quote(address(tokA), PRICE);
        bytes memory cd =
            abi.encodeCall(IAceVaultLens.previewTerms, (address(vault), borrower, _req(address(tokA), UNITS, PRINCIPAL, MIN_TENOR), _dataBy(q, ROGUE_KEY)));
        vm.prank(stranger);
        (bool ok, bytes memory err) = address(lens).staticcall(cd);
        assertFalse(ok, "BUG: the preview quoted forged terms as admissible");
        assertEq(err, abi.encodeWithSelector(IInKindTerms.BadSignature.selector), "refused by name: BadSignature");
    }

    /// @notice The delegate is never asked: the honest preview and borrow price with no `isValidSignature` call at all.
    /// @dev The ask would land on the appraiser's own address, where the EVM runs the delegate's code, so that is the call counted.
    function test_borrow_theDelegateIsNeverAsked() public {
        _premiseDelegated();
        Quote memory q = _quote(address(tokA), PRICE);
        bytes memory data = _dataBy(q, EOA_KEY);
        vm.expectCall(eoa, abi.encodeWithSelector(IERC1271.isValidSignature.selector), 0);
        (bytes32 pid,,) = lens.previewTerms(address(vault), borrower, _req(address(tokA), UNITS, PRINCIPAL, MIN_TENOR), data);
        uint256 id = _borrowWith(q, data, UNITS, PRINCIPAL, MIN_TENOR);
        assertEq(ace.loanMarket(id), pid, "the honest quote opened the previewed market");
    }

    /// @notice A delegated appraiser keeps ECDSA's low-s rule: a high-s copy of its own quote signature refuses `BadSignature`.
    /// @dev The check calls `ECDSA.tryRecover` itself, so a swap to bare `ecrecover` would admit the copy; the nonce bounds the harm, this row pins the rule.
    function test_borrow_aHighSCopyOfTheDelegatedAppraisersSignatureRefuses() public {
        _premiseDelegated();
        Quote memory q = _quote(address(tokA), PRICE);
        bytes32 h = terms.hashQuote(q);
        (uint8 v, bytes32 r, bytes32 s) = vm.sign(EOA_KEY, h);
        bytes32 highS = bytes32(SECP256K1_N - uint256(s));
        uint8 flipped = v == 27 ? 28 : 27;
        assertEq(ecrecover(h, flipped, r, highS), eoa, "premise: bare ecrecover takes the high-s copy for the appraiser");
        _assertBorrowRefused(q, abi.encode(q, abi.encodePacked(r, highS, flipped)));
    }

    // ---- the roll policy, once the appraiser's EOA delegates ----

    /// @notice A roll quote signed by a foreign key gets no consent: the vault answers `bytes4(0)`.
    function test_admitsExtension_aForgedRollIsRefusedOnceTheAppraiserDelegates() public {
        _premiseDelegated();
        _toWindow();
        Extension memory e = _ext(loanId);
        assertEq(vault.admitsExtension(e, _rollData(_rq(loanId), ROGUE_KEY)), bytes4(0), "BUG: a forged roll quote won consent");
        assertEq(vault.admitsExtension(e, abi.encode(_rq(loanId), hex"deadbeef")), bytes4(0), "BUG: garbage roll signature bytes won consent");
    }

    /// @notice The same forgery driven through the hub: the holder's `extend` on a forged roll is refused, and the expiry stands.
    function test_extend_aForgedRollIsRefusedAtTheHubOnceTheAppraiserDelegates() public {
        _premiseDelegated();
        _toWindow();
        _assertExtendRefused(_rollData(_rq(loanId), ROGUE_KEY));
    }

    /// @notice The appraiser's own roll quote still extends once it delegates, so a holder can still extend before its loan forfeits.
    function test_extend_theAppraisersOwnRollStillExtendsOnceItDelegates() public {
        _premiseDelegated();
        _toWindow();
        _assertExtends(_rollData(_rq(loanId), EOA_KEY));
    }

    /// @notice The delegate is never asked on the roll: the honest roll extends with no `isValidSignature` call at all.
    function test_extend_theDelegateIsNeverAsked() public {
        _premiseDelegated();
        _toWindow();
        bytes memory data = _rollData(_rq(loanId), EOA_KEY);
        vm.expectCall(eoa, abi.encodeWithSelector(IERC1271.isValidSignature.selector), 0);
        _assertExtends(data);
    }

    // ---- the seat ----

    /// @notice An appointment whose account delegates while it waits is refused at the accept, and the seat keeps its incumbent.
    function test_acceptAppraiser_refusesAnAccountThatDelegatedWhilePending() public {
        address next = vm.addr(NEXT_KEY);
        _submitAppraiser(next);
        vm.etch(next, abi.encodePacked(hex"ef0100", delegate));
        assertEq(EIP7702Utils.fetchDelegate(next), delegate, "premise: the appointee delegated while pending");
        vm.prank(stranger);
        vm.expectRevert(IInKindTerms.DelegatedAppraiser.selector);
        terms.acceptAppraiser();
        assertEq(terms.APPRAISER(), eoa, "the seat kept its incumbent");
    }

    /// @notice RECOVERY BY ROTATION: the delegated incumbent cannot be re-appointed, a clean key is, and lending follows the new key alone.
    function test_rotation_theCuratorSwapsADelegatedAppraiserForACleanKey() public {
        _premiseDelegated();
        vm.prank(curator);
        vm.expectRevert(IInKindTerms.DelegatedAppraiser.selector);
        terms.submitAppraiser(eoa);
        address next = vm.addr(NEXT_KEY);
        _submitAppraiser(next);
        _toWindow();
        Quote memory old = _quote(address(tokA), PRICE);
        bytes memory oldQuote = _dataBy(old, EOA_KEY);
        bytes memory oldRoll = _rollData(_rq(loanId), EOA_KEY);
        _acceptAppraiser();
        assertEq(terms.APPRAISER(), next, "the clean key holds the seat");

        _assertBorrowRefused(old, oldQuote);
        _assertExtendRefused(oldRoll);
        Quote memory q = _quote(address(tokA), PRICE);
        uint256 id = _borrowWith(q, _dataBy(q, NEXT_KEY), UNITS, PRINCIPAL, MIN_TENOR);
        assertEq(read.loan(id).borrower, borrower, "the new key's quote opened a loan");
        _assertExtends(_rollData(_rq(loanId), NEXT_KEY));
    }

    // ---- contract code at the seat ----

    /// @notice A Safe appointed before it is deployed signs by ERC-1271 once it is, with no re-appointment: the check reads the code at each signature.
    function test_seatBeforeDeploy_aContractDeployedAtTheSeatedAddressSignsWithoutAReappointment() public {
        address safe = makeAddr("appraiser safe, not yet deployed");
        assertEq(safe.code.length, 0, "premise: nothing is deployed at the address yet");
        _appoint(safe);
        _toWindow();
        Quote memory q = _quote(address(tokA), PRICE);
        RollQuote memory rq = _rq(loanId);
        bytes memory d = abi.encode(q, bytes(""));
        _assertBorrowRefused(q, d);

        vm.etch(safe, address(new Signing1271Wallet()).code);
        assertEq(EIP7702Utils.fetchDelegate(safe), address(0), "premise: what landed is a contract, not a delegation");
        Signing1271Wallet(safe).sign(terms.hashQuote(q));
        Signing1271Wallet(safe).sign(terms.hashRollQuote(rq));
        uint256 id = _borrowWith(q, d, UNITS, PRINCIPAL, MIN_TENOR);
        assertEq(read.loan(id).borrower, borrower, "the deployed wallet's blessing opens a loan with no re-appointment");
        _assertExtends(abi.encode(rq, bytes("")));
        assertEq(terms.APPRAISER(), safe, "and the seat never moved");
    }

    /// @notice A designator is judged by its prefix, not its size: a deployed 23-byte contract is seated and asked by ERC-1271 like any other code.
    /// @dev The runtime answers the magic value to any call: PUSH4 selector, shift it left, store it, return one word, then seven STOP bytes of padding.
    function test_seat_aTwentyThreeByteContractIsNoDelegationAndAnswersByErc1271() public {
        address tiny = makeAddr("23-byte contract appraiser");
        vm.etch(tiny, hex"631626ba7e60e01b60005260206000f300000000000000");
        assertEq(tiny.code.length, 23, "premise: the contract is exactly a designator's size");
        assertEq(EIP7702Utils.fetchDelegate(tiny), address(0), "premise: and does not open with the designator prefix");
        assertEq(IERC1271(tiny).isValidSignature(keccak256("anything at all"), ""), MAGIC_VALUE, "premise: it answers the magic value");
        _appoint(tiny);
        assertEq(terms.APPRAISER(), tiny, "a 23-byte contract is seated, not refused as a delegation");

        Quote memory q = _quote(address(tokA), PRICE);
        vm.expectCall(tiny, abi.encodeWithSelector(IERC1271.isValidSignature.selector), 1);
        uint256 id = _borrowWith(q, abi.encode(q, bytes("")), UNITS, PRINCIPAL, MIN_TENOR);
        assertEq(read.loan(id).borrower, borrower, "its ERC-1271 answer for the quote opened a loan");
    }

    /// @notice Contract code answers by ERC-1271 alone: the key behind the contract's address signs nothing, and the wallet's blessing prices.
    /// @dev No chain holds a contract at an address whose key is known, so only an etch reaches this; it pins that the 1271 branch never falls to ECDSA.
    function test_contractSeat_theKeyBehindItsAddressSignsNothing() public {
        address wallet = vm.addr(NEXT_KEY);
        vm.etch(wallet, address(new Signing1271Wallet()).code);
        assertEq(EIP7702Utils.fetchDelegate(wallet), address(0), "premise: the account holds contract code, not a delegation");
        _appoint(wallet);
        _toWindow();
        Quote memory q = _quote(address(tokA), PRICE);
        _assertBorrowRefused(q, _dataBy(q, NEXT_KEY));
        _assertExtendRefused(_rollData(_rq(loanId), NEXT_KEY));

        Signing1271Wallet(wallet).sign(terms.hashQuote(q));
        uint256 id = _borrowWith(q, abi.encode(q, bytes("")), UNITS, PRINCIPAL, MIN_TENOR);
        assertEq(read.loan(id).borrower, borrower, "the wallet's blessing opened a loan");
    }

    // ---- controls ----

    /// @notice CONTROL: the same foreign key is refused while the appraiser is a clean EOA, so the rows above isolate the delegation.
    function test_control_aForeignKeyIsRefusedBeforeTheDelegation() public {
        vm.etch(eoa, "");
        assertEq(EIP7702Utils.fetchDelegate(eoa), address(0), "premise: no delegation");
        Quote memory q = _quote(address(tokA), PRICE);
        _fund(address(tokA), borrower, UNITS);
        bytes memory data = _dataBy(q, ROGUE_KEY);
        vm.prank(borrower);
        vm.expectRevert(IInKindTerms.BadSignature.selector);
        vault.borrow(_req(address(tokA), UNITS, PRINCIPAL, MIN_TENOR), data, "");
        _toWindow();
        assertEq(vault.admitsExtension(_ext(loanId), _rollData(_rq(loanId), ROGUE_KEY)), bytes4(0), "a clean EOA's roll needs its own key");
        assertEq(vault.admitsExtension(_ext(loanId), _rollData(_rq(loanId), EOA_KEY)), IRollPolicy.admitsExtension.selector, "and its own key admits");
    }

    /// @notice CONTROL: clearing the delegation changes nothing: the appraiser's key prices and extends, a foreign key refuses `BadSignature`.
    /// @dev A designator and no code both take the ECDSA branch, so neither installing a delegation nor clearing one moves the check.
    function test_control_clearingTheDelegationChangesNothing() public {
        _premiseDelegated();
        vm.etch(eoa, "");
        assertEq(EIP7702Utils.fetchDelegate(eoa), address(0), "premise: the delegation is cleared");
        Quote memory bad = _quote(address(tokA), PRICE);
        _assertBorrowRefused(bad, _dataBy(bad, ROGUE_KEY));
        Quote memory q = _quote(address(tokA), PRICE);
        uint256 id = _borrowWith(q, _dataBy(q, EOA_KEY), UNITS, PRINCIPAL, MIN_TENOR);
        assertEq(read.loan(id).borrower, borrower, "the appraiser's own key prices a borrow");
        _toWindow();
        _assertExtends(_rollData(_rq(loanId), EOA_KEY));
    }

    /// @notice CONTROL: a delegated appraiser does not pre-empt the static refusals; each still lands by its own name ahead of any signature.
    function test_control_staticRefusalsStillLandFirstWhileDelegated() public {
        _premiseDelegated();
        _fund(address(tokA), borrower, UNITS * 3);
        Quote memory early = _quote(address(tokA), PRICE);
        early.issuedAt = uint64(_now() + 1);
        bytes memory e = _dataBy(early, ROGUE_KEY);
        vm.prank(borrower);
        vm.expectRevert(IInKindTerms.QuoteNotYetIssued.selector);
        vault.borrow(_req(address(tokA), UNITS, PRINCIPAL, MIN_TENOR), e, "");

        Quote memory aged = _quote(address(tokA), PRICE);
        aged.issuedAt = uint64(_now() - terms.QUOTE_TTL() - 1);
        bytes memory a = _dataBy(aged, ROGUE_KEY);
        vm.prank(borrower);
        vm.expectRevert(IInKindTerms.QuoteExpired.selector);
        vault.borrow(_req(address(tokA), UNITS, PRINCIPAL, MIN_TENOR), a, "");

        Quote memory used = _quote(address(tokA), PRICE);
        used.nonce = 1; // the setUp loan's nonce, already cashed
        bytes memory u = _dataBy(used, ROGUE_KEY);
        vm.prank(borrower);
        vm.expectRevert(IInKindTerms.QuoteUsed.selector);
        vault.borrow(_req(address(tokA), UNITS, PRINCIPAL, MIN_TENOR), u, "");
    }
}
