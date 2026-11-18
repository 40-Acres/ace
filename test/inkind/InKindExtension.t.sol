// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.36;

import {InsufficientCash, PolicyRefused} from "../../src/ace/hub/Borrower.sol";
import {Loan, MarketParams, MigrateArgs, OpenBounds} from "../../src/ace/hub/Types.sol";
import {Extension, IRollPolicy} from "../../src/interfaces/IRollPolicy.sol";
import {RollQuote, Row} from "./InKindSurface.sol";
import {GasBurner1271} from "./InKindMocks.sol";
import {InKindRig} from "./InKindRig.sol";

/// @title InKindExtension
/// @notice A loan extends in place through the hub's `extend` on a signed roll quote bound to its current expiry, so the quote lands once.
/// @notice The vault consents while the row still names the market's rate and tenors, a cap and a maxPrincipal over the debt, no drain, exits covered.
/// @notice Empty roll data is refused, so a same-market `refinanceTo` never reuses a claim; the cheap legs run before the signature.
contract InKindExtensionTest is InKindRig {
    uint256 internal loanId;

    function setUp() public override {
        super.setUp();
        _lp(alice, LP_CASH);
        loanId = _open(address(tokA));
    }

    /// @dev The roll quote the appraiser signs for `id` now: bound to its current expiry, at the market's own price.
    function _rq(uint256 id) internal view returns (RollQuote memory) {
        return RollQuote({loanId: id, expiry: uint64(_expiry(id)), price: _mp(id).price, issuedAt: uint64(_now())});
    }

    /// @dev The extension the hub hands the vault when the holder extends `id` now: its own tenor from now, `dst` a copy of `src`.
    function _ext(uint256 id) internal view returns (Extension memory e) {
        Loan memory l = read.loan(id);
        (e.caller, e.loanId, e.borrower, e.units, e.debt, e.newDebt) = (l.borrower, id, l.borrower, l.collateralUnits, l.debt, l.debt);
        (e.expiry, e.newExpiry, e.src, e.dst) = (l.expiry, uint64(_now()) + l.tenor, _mp(id), _mp(id));
    }

    function _toWindow() internal {
        _warpAtLeastTo(_expiry(loanId) - 1 hours);
    }

    function _extend(bytes memory data) internal {
        _armFee(loanId, MIN_TENOR);
        vm.prank(borrower);
        ace.extend(loanId, 0, data);
    }

    function _extendRefused(bytes memory data) internal {
        _armFee(loanId, MIN_TENOR);
        vm.prank(borrower);
        vm.expectRevert(PolicyRefused.selector);
        ace.extend(loanId, 0, data);
    }

    // ---- consent ----

    /// @notice A valid roll quote extends the loan in place by its own term from now, and nothing rests.
    function test_extend_aValidRollQuoteIsAdmitted() public {
        _toWindow();
        _extend(_rollData(_rq(loanId), APPRAISER_KEY));
        assertEq(_expiry(loanId), _now() + MIN_TENOR, "the same loan runs its term again from now");
        assertFalse(ace.isClosed(loanId), "still live");
        assertEq(ace.restingOf(ace.loanMarket(loanId)), 0, "an extension draws no cash");
    }

    /// @notice A roll quote names the expiry it extends from, so once the loan has moved it is spent without a storage write.
    function test_extend_aRollQuoteLandsOnlyOnce() public {
        _toWindow();
        bytes memory data = _rollData(_rq(loanId), APPRAISER_KEY);
        _extend(data);
        _warpBy(1);
        _extendRefused(data);
    }

    function test_extend_aRollPriceUnderTheMarketPriceIsRefused() public {
        _toWindow();
        RollQuote memory rq = _rq(loanId);
        rq.price -= 1;
        _extendRefused(_rollData(rq, APPRAISER_KEY));
    }

    /// @notice A new rate on the row stops the old market extending.
    function test_extend_aRateChangeIsRefused() public {
        Row memory row = _row();
        row.lenderAprBps = RATE_BPS + 10;
        vm.prank(curator);
        terms.submitRow(address(tokA), row);
        _warpBy(TIMELOCK);
        terms.accept(address(tokA));
        _toWindow();
        _extendRefused(_rollData(_rq(loanId), APPRAISER_KEY));
    }

    /// @notice A new tenor range on the row stops the old market extending, even a cut that landed at once.
    function test_extend_aTenorChangeIsRefused() public {
        Row memory row = _row();
        row.maxTenor = MIN_TENOR;
        vm.prank(guardian);
        terms.submitRow(address(tokA), row);
        _toWindow();
        _extendRefused(_rollData(_rq(loanId), APPRAISER_KEY));
    }

    function test_extend_aZeroCapIsRefused() public {
        _setCap(guardian, address(tokA), 0);
        _toWindow();
        _extendRefused(_rollData(_rq(loanId), APPRAISER_KEY));
    }

    /// @notice A maxPrincipal cut under a loan's debt stops its extension on a valid roll quote, as a loan that big would not open now.
    /// @notice A cut to exactly the debt still admits it.
    function test_extend_aMaxPrincipalCutUnderTheDebtStopsItsExtension() public {
        uint256 debt = read.loan(loanId).debt;
        Row memory row = _row();
        _toWindow();
        bytes memory data = _rollData(_rq(loanId), APPRAISER_KEY);
        uint256 snap = vm.snapshotState();
        row.maxPrincipal = uint128(debt - 1);
        vm.prank(guardian);
        terms.submitRow(address(tokA), row);
        _extendRefused(data);
        vm.revertToState(snap);
        row.maxPrincipal = uint128(debt);
        vm.prank(guardian);
        terms.submitRow(address(tokA), row);
        _extend(data);
        assertEq(_expiry(loanId), _now() + MIN_TENOR, "a cut to exactly the debt still extends");
    }

    /// @notice A maxTenor cut back to an old market's value re-admits that market's extensions, restoring the row the curator listed.
    /// @notice No other tenor is admitted: the leg is an EQUALITY match, read off a `dst` that is a copy, never an alias of `src`.
    function test_cut_aMaxTenorCutBackToAnOldMarketsValueReadmitsOnlyThatMarket() public {
        Row memory listed = terms.rowOf(address(tokA));
        Row memory longer = _row();
        longer.maxTenor = MAX_TENOR;
        vm.prank(curator);
        terms.submitRow(address(tokA), longer);
        _warpBy(TIMELOCK);
        terms.accept(address(tokA));
        _toWindow();
        Extension memory e = _ext(loanId);
        bytes memory data = _rollData(_rq(loanId), APPRAISER_KEY);
        assertEq(vault.admitsExtension(e, data), bytes4(0), "premise: the longer row refuses the old market on tenor equality");

        vm.prank(guardian);
        terms.submitRow(address(tokA), listed);
        assertEq(terms.rowOf(address(tokA)).maxTenor, ROW_MAX_TENOR, "the guardian's cut lands at once, back at the listed maxTenor");
        assertEq(vault.admitsExtension(e, data), IRollPolicy.admitsExtension.selector, "so the old market extends again");
        e.dst.maxTenor = ROW_MAX_TENOR - 1 days;
        assertEq(e.src.maxTenor, ROW_MAX_TENOR, "premise: the source market is untouched by the edit to the destination");
        assertEq(vault.admitsExtension(e, data), bytes4(0), "and a market at any other maxTenor stays refused");
    }

    function test_extend_isRefusedWhileDraining() public {
        vm.prank(guardian);
        vault.setDrain(true);
        _toWindow();
        _extendRefused(_rollData(_rq(loanId), APPRAISER_KEY));
    }

    /// @notice A lengthening is refused while idle does not cover the standing exit requests.
    function test_extend_isRefusedWhileExitsAreNotCovered() public {
        uint256 all = vault.balanceOf(alice);
        vm.prank(alice);
        vault.requestExit(all);
        _toWindow();
        _extendRefused(_rollData(_rq(loanId), APPRAISER_KEY));
    }

    /// @notice A roll quote past its life is refused.
    function test_extend_anExpiredRollQuoteIsRefused() public {
        _toWindow();
        RollQuote memory rq = _rq(loanId);
        rq.issuedAt = uint64(_now() - terms.QUOTE_TTL() - 1);
        _extendRefused(_rollData(rq, APPRAISER_KEY));
    }

    /// @notice A roll quote issued after now is refused, and the view answers no rather than reverting.
    function testRevert_extend_aRollIssuedInTheFutureIsRefused() public {
        _toWindow();
        RollQuote memory rq = _rq(loanId);
        rq.issuedAt = uint64(_now() + 1);
        bytes memory data = _rollData(rq, APPRAISER_KEY);
        assertEq(vault.admitsExtension(_ext(loanId), data), bytes4(0), "the vault consents to no roll issued in the future");
        _extendRefused(data);
    }

    /// forge-config: default.fuzz.runs = 64
    /// @notice Any roll issue time after now answers no without a revert, up to the uint64 maximum: the life sum is never reached.
    function testFuzz_admitsExtension_anyFutureIssuedAtAnswersNo(uint64 issuedAt) public {
        _toWindow();
        RollQuote memory rq = _rq(loanId);
        rq.issuedAt = uint64(bound(issuedAt, _now() + 1, type(uint64).max));
        bytes memory data = _rollData(rq, APPRAISER_KEY);
        assertEq(vault.admitsExtension(_ext(loanId), data), bytes4(0), "no consent, and no Panic on the life sum");
    }

    /// @notice The largest roll issue time answers no without a Panic: the issue check runs before the life is summed in uint64.
    function test_admitsExtension_theMaxIssuedAtAnswersNoWithoutAPanic() public {
        _toWindow();
        RollQuote memory rq = _rq(loanId);
        rq.issuedAt = type(uint64).max;
        assertEq(vault.admitsExtension(_ext(loanId), _rollData(rq, APPRAISER_KEY)), bytes4(0), "no consent at the uint64 maximum");
        rq.issuedAt = type(uint64).max - terms.QUOTE_TTL() + 1;
        assertEq(vault.admitsExtension(_ext(loanId), _rollData(rq, APPRAISER_KEY)), bytes4(0), "nor anywhere in the band the life sum would overflow");
    }

    /// @notice The extension's size leg reads the NEW debt: a valid roll whose new debt passes the row's maxPrincipal gets no consent, at it does.
    /// @dev The hub's extend never moves debt, so only a direct ask distinguishes the two; this pins the leg the header names.
    function test_admitsExtension_theSizeLegReadsTheNewDebt() public {
        _toWindow();
        uint128 rowMax = terms.rowOf(address(tokA)).maxPrincipal;
        Extension memory e = _ext(loanId);
        bytes memory data = _rollData(_rq(loanId), APPRAISER_KEY);
        assertLe(e.debt, rowMax, "premise: the loan's debt sits under the row's maxPrincipal");
        e.newDebt = uint256(rowMax) + 1;
        assertEq(vault.admitsExtension(e, data), bytes4(0), "a new debt one atom over the row's maxPrincipal is refused");
        e.newDebt = rowMax;
        assertEq(vault.admitsExtension(e, data), IRollPolicy.admitsExtension.selector, "and exactly at it is admitted");
    }

    function test_extend_aRollQuoteForAnotherLoanIsRefused() public {
        uint256 other = _open(address(tokA));
        _toWindow();
        RollQuote memory rq = _rq(other);
        rq.expiry = uint64(_expiry(loanId));
        _extendRefused(_rollData(rq, APPRAISER_KEY));
    }

    function test_extend_aRollSignedByAStrangerIsRefused() public {
        _toWindow();
        _extendRefused(_rollData(_rq(loanId), ROGUE_KEY));
    }

    /// @notice Seating a new appraiser kills the old one's live roll quotes too.
    function test_extend_aRollQuoteDiesWithTheAppraisersRotation() public {
        _submitAppraiser(vm.addr(ROGUE_KEY));
        _toWindow();
        bytes memory data = _rollData(_rq(loanId), APPRAISER_KEY);
        _acceptAppraiser();
        _extendRefused(data);
    }

    /// @notice Empty data refuses even an extension the same signed data admits, so a claim is never reused on a same-market re-term.
    function test_admitsExtension_refusesEmptyData() public {
        _toWindow();
        Extension memory e = _ext(loanId);
        bytes memory data = _rollData(_rq(loanId), APPRAISER_KEY);
        assertEq(vault.admitsExtension(e, data), IRollPolicy.admitsExtension.selector, "premise: the signed data admits it");
        assertEq(vault.admitsExtension(e, ""), bytes4(0), "the same extension with empty data is refused");
    }

    // ---- refinance in place ----

    /// @notice A same-market `refinanceTo` is refused: the hub's reuse ask carries no data, the vault says no, and the fresh draw finds no cash.
    /// @dev The vault rests no cash between calls, so a refused reuse that draws its whole principal fresh refuses `InsufficientCash`.
    function testRevert_refinanceTo_aSameMarketReTermIsRefused() public {
        uint256 id = _openFor(address(tokA), PRINCIPAL, ROW_MAX_TENOR);
        bytes32 mid = ace.loanMarket(id);
        uint256 debt = ace.debtOf(id);
        Extension memory e = _ext(id);
        (e.newDebt, e.newExpiry) = (debt, uint64(_now()) + MIN_TENOR);
        assertEq(vault.admitsExtension(e, ""), bytes4(0), "the reuse ask, which carries no data, gets no consent");
        assertEq(ace.restingOf(mid), 0, "premise: nothing rests in the market for a fresh draw");
        MigrateArgs memory m = MigrateArgs(id, mid, debt, MIN_TENOR, OpenBounds(0, 0, 0), 0, address(0));
        vm.prank(borrower);
        vm.expectRevert(InsufficientCash.selector);
        ace.refinanceTo(m);
        assertTrue(ace.isLiveLoan(id), "the loan stands as it was");
    }

    // ---- gas ----

    /// @dev Cold, `admitsExtension` on `data` must consent inside the hub's policy budget, and the hub's own capped ask must land.
    function _assertFits(Extension memory e, bytes memory data, address signer, string memory label) internal {
        vm.cool(address(vault));
        vm.cool(address(terms));
        vm.cool(signer);
        uint256 g = gasleft();
        bytes4 answer = vault.admitsExtension(e, data);
        uint256 used = g - gasleft();
        emit log_named_uint(string.concat("INKIND admitsExtension gas, ", label, ", cold"), used);
        assertEq(answer, IRollPolicy.admitsExtension.selector, "the appraiser's signature admits it");
        assertLt(used, ace.POLICY_GAS(), "under the hub's policy budget");
        _extend(data);
        assertEq(_expiry(loanId), _now() + MIN_TENOR, "and the hub's capped ask landed the extension");
    }

    /// @dev Seat an `m`-of-`n` Safe-shaped appraiser, have its first `m` owners sign a roll through its own message hash, and check it fits.
    function _assertSafeFits(uint256 m, uint256 n) internal {
        (address proxy, uint256[] memory keys) = _safe(m, n);
        _appoint(proxy);
        _toWindow();
        RollQuote memory rq = _rq(loanId);
        bytes memory sigs = _safeSigs(proxy, keys, m, terms.hashRollQuote(rq));
        _assertFits(_ext(loanId), abi.encode(rq, sigs), proxy, string.concat(vm.toString(m), "-of-", vm.toString(n), " Safe appraiser"));
    }

    /// @notice With a 3-of-5 Safe appraiser, cold, `admitsExtension` fits the hub's policy budget, and the hub's own ask lands.
    function test_admitsExtension_withA3of5SafeAppraiserFitsThePolicyBudget() public {
        _assertSafeFits(3, 5);
    }

    /// @notice With a 2-of-3 Safe appraiser, the same.
    function test_admitsExtension_withA2of3SafeAppraiserFitsThePolicyBudget() public {
        _assertSafeFits(2, 3);
    }

    /// @notice With the beta's plain EOA appraiser, the same.
    function test_admitsExtension_withAnEoaAppraiserFitsThePolicyBudget() public {
        _toWindow();
        _assertFits(_ext(loanId), _rollData(_rq(loanId), APPRAISER_KEY), appraiser, "EOA appraiser");
    }

    /// @notice The cheap legs run before the signature: a drained vault answers no without handing an appraiser any gas.
    function test_admitsExtension_runsTheCheapLegsBeforeTheSignature() public {
        _appoint(address(new GasBurner1271()));
        vm.prank(guardian);
        vault.setDrain(true);
        _toWindow();
        Extension memory e = _ext(loanId);
        bytes memory data = abi.encode(_rq(loanId), bytes(""));
        uint256 g = gasleft();
        bytes4 answer = vault.admitsExtension{gas: ace.POLICY_GAS()}(e, data);
        uint256 used = g - gasleft();
        assertEq(answer, bytes4(0), "refused");
        assertLt(used, 60_000, "without the appraiser burning the budget");
    }

    /// @notice The same with a zero cap: the curator's legs are cheap and run first.
    function test_admitsExtension_aZeroCapRefusesBeforeTheSignature() public {
        _appoint(address(new GasBurner1271()));
        _setCap(guardian, address(tokA), 0);
        _toWindow();
        Extension memory e = _ext(loanId);
        bytes memory data = abi.encode(_rq(loanId), bytes(""));
        uint256 g = gasleft();
        bytes4 answer = vault.admitsExtension{gas: ace.POLICY_GAS()}(e, data);
        uint256 used = g - gasleft();
        assertEq(answer, bytes4(0), "refused");
        assertLt(used, 60_000, "without the appraiser burning the budget");
    }
}
