// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.36;

import {EIP7702Utils} from "@openzeppelin/contracts/account/utils/EIP7702Utils.sol";
import {Math} from "@openzeppelin/contracts/utils/math/Math.sol";
import {MockBlockableERC20} from "../mocks/MockBlockableERC20.sol";
import {MockERC20} from "../mocks/MockERC20.sol";
import {Permissive1271Wallet} from "../mocks/Mock1271Wallet.sol";
import {AceFixtures} from "../utils/AceFixtures.sol";
import {Constants} from "../../src/ace/hub/Constants.sol";
import {PolicyRefused} from "../../src/ace/hub/Borrower.sol";
import {Loan, MarketParams} from "../../src/ace/hub/Types.sol";
import {AceVault} from "../../src/curator/AceVault.sol";
import {AceVaultFlows} from "../../src/curator/AceVaultFlows.sol";
import {Extension, IRollPolicy} from "../../src/interfaces/IRollPolicy.sol";
import {IInKindTerms, IInKindVault, InKindConfig, Listing, Quote, RollQuote, Row} from "./InKindSurface.sol";
import {GasBurner1271} from "./InKindMocks.sol";
import {InKindRig} from "./InKindRig.sol";

/// @title InKindHardening
/// @notice The rows a mutation sweep over InKindTerms and AceVaultInKind found missing: each kills a mutant the other suites let live.
/// @notice Grouped by what they pin: the tracker, the fold's timing, the quote's order, the roll, the table, the rails.
contract InKindHardeningTest is InKindRig {
    function _borrowExpecting(bytes4 err, address coll, bytes memory data) internal {
        _fund(coll, borrower, UNITS);
        vm.prank(borrower);
        vm.expectRevert(err);
        vault.borrow(_req(coll, UNITS, PRINCIPAL, MIN_TENOR), data, "");
    }

    /// @dev The rig's seated appraiser EOA installs a delegation to `delegate`.
    function _delegateAppraiser(address delegate) internal returns (address eoa) {
        eoa = appraiser;
        vm.etch(eoa, abi.encodePacked(hex"ef0100", delegate));
        assertEq(EIP7702Utils.fetchDelegate(eoa), delegate, "premise: the appraiser now carries a delegation");
    }

    /// @dev A roll quote for `id` issued now, at its current expiry and the market's price.
    function _rq(uint256 id) internal view returns (RollQuote memory) {
        return RollQuote({loanId: id, expiry: uint64(_expiry(id)), price: _mp(id).price, issuedAt: uint64(_now())});
    }

    /// @dev The extension the hub hands the vault when the holder extends `id` now: its own tenor from now, `dst` a copy of `src`.
    function _ext(uint256 id) internal view returns (Extension memory e) {
        Loan memory l = read.loan(id);
        (e.caller, e.loanId, e.borrower, e.units, e.debt, e.newDebt) = (l.borrower, id, l.borrower, l.collateralUnits, l.debt, l.debt);
        (e.expiry, e.newExpiry, e.src, e.dst) = (l.expiry, uint64(_now()) + l.tenor, _mp(id), _mp(id));
    }

    /// @dev The borrower extends `id` by one minimum term on `data`, paying the fee.
    function _extend(uint256 id, bytes memory data) internal {
        _armFee(id, MIN_TENOR);
        vm.prank(borrower);
        ace.extend(id, 0, data);
    }

    // ---- the tracker ----

    /// @dev `h`'s checkpoint count, read raw at the tracker's holder mapping.
    function _checkpoints(address h) internal view returns (uint256) {
        return uint256(vm.load(address(vault), keccak256(abi.encode(h, bytes32(uint256(INKIND_ROOT) + 8)))));
    }

    /// @notice A self-transfer moves no tracked share and writes no checkpoint.
    function test_aSelfTransferMovesNoTrackedShare() public {
        uint256 own = _lp(alice, 1_000e6);
        _warpBy(1 days);
        _nextBlock();
        vm.prank(alice);
        vault.transfer(alice, own / 2);
        assertEq(_tracked(alice), own, "alice keeps every tracked share");
        assertEq(_checkpoints(alice), 1, "and no checkpoint was written past the deposit's");
        assertEq(_trackedSupply(), own, "nor did the tracked supply move");
    }

    /// @notice A zero-value transfer moves no tracker state: no checkpoint for either side and no tracked supply.
    function test_aZeroValueTransferTouchesNoCheckpoint() public {
        uint256 sh = _lp(alice, 1_000e6);
        _warpBy(MIN_TENOR);
        _nextBlock();
        vm.prank(alice);
        vault.transfer(bob, 0);
        assertEq(_tracked(alice), sh, "alice's tracked balance still reads as stored");
        assertEq(_checkpoints(alice) + _checkpoints(bob), 1, "a zero move writes no checkpoint");
        assertEq(_trackedSupply(), sh, "and moves no tracked supply");
    }

    /// @notice A zero-asset deposit mints nothing and never reaches the tracker, so an empty lot is never merged into.
    function test_aZeroDepositLeavesTheTrackerAlone() public {
        _lp(alice, 1_000e6);
        vm.prank(carol);
        uint256 sh = vault.deposit(0, carol);
        assertEq(sh, 0, "premise: no shares minted");
        assertEq(_tracked(carol), 0, "and nothing tracked");
    }

    // ---- the fold's timing ----

    /// @notice A collect first folds an earlier block's collect, so shares that reach a holder after it, in its own block, share only the new pot.
    function test_collect_foldsAnEarlierCollectBeforeItsOwn() public {
        uint256 sa = _lp(alice, 600_000e6);
        uint256 a = _open(address(tokA));
        uint256 b = _open(address(tokB));
        uint256 potA = _defaultAndCollect(a);
        _nextBlock();
        _warpBy(1 hours);
        uint256 potB = _expectedPot(b);
        assertEq(_collect(b), potB, "the second collect is this block's first tracker step");
        uint256 sc = sa / 3;
        vm.prank(alice);
        vault.transfer(carol, sc);
        assertEq(_tracked(carol), sc, "premise: carol received shares in the second collect's block, after it");
        _nextBlock();
        assertEq(_claimable(carol, address(tokA)), 0, "carol's shares arrived after the first collect's block, so none of its pot is hers");
        assertApproxEqAbs(_claimable(alice, address(tokA)), potA, 1, "the first pot went to the block-end holder");
        assertApproxEqAbs(_claimable(carol, address(tokB)), Math.mulDiv(potB, sc, sa), 1, "while the second pot is shared");
    }

    /// @notice With no tracked shares a fold waits, re-stamped to the block that first holds some, so it lands on that block's end balances.
    function test_aZeroSupplyFoldLandsOnTheBlockEndHolders() public {
        uint256 sa = _lp(alice, LP_CASH);
        uint256 loanId = _open(address(tokA));
        vm.prank(alice);
        vault.transfer(address(vault), sa);
        assertEq(_trackedSupply(), 0, "premise: alice gifted every share to the vault, so nothing is tracked");
        _toExpiry(loanId);
        uint256 pot = _expectedPot(loanId);
        _collect(loanId);
        _nextBlock();
        uint256 sb = _lp(bob, 1_000e6);
        vm.prank(bob);
        vault.transfer(carol, sb);
        assertEq(_tracked(carol), sb, "premise: bob handed every share to carol inside the block the batch waited into");
        _nextBlock();
        assertEq(_claimable(bob, address(tokA)), 0, "bob held the shares only mid-block");
        assertApproxEqAbs(_claim(carol, address(tokA)), pot, 1, "the block-end holder takes the pot");
    }

    /// @notice A fold empties what it credits: two pots of one token collected a block apart are credited once each, and the claim pays both.
    function test_twoPotsOfOneTokenAreCreditedOnceEach() public {
        _lp(alice, LP_CASH);
        _warpBy(MIN_TENOR);
        uint256 first = _open(address(tokA));
        _warpBy(1 days);
        uint256 second = _open(address(tokA));
        uint256 pot1 = _defaultAndCollect(first);
        _nextBlock();
        uint256 pot2 = _defaultAndCollect(second);
        _nextBlock();
        assertApproxEqAbs(_claimable(alice, address(tokA)), pot1 + pot2, 2, "each pot credited once");
        assertApproxEqAbs(_claim(alice, address(tokA)), pot1 + pot2, 2, "and the claim pays exactly both");
        assertLe(tokA.balanceOf(address(vault)), 2, "leaving only rounding dust in the vault");
    }

    // ---- the quote's order and bounds ----

    /// @notice A quote past its life on a spent nonce refuses as expired: the life is read before the nonce.
    function testRevert_borrow_expiryRefusesBeforeTheSpentNonce() public {
        _lp(alice, LP_CASH);
        _open(address(tokA));
        Quote memory q = _quote(address(tokA), PRICE);
        (q.nonce, q.issuedAt, q.maxPrincipal, q.maxTenor) = (_nonce - 1, uint64(_now() - terms.QUOTE_TTL() - 1), PRINCIPAL - 1, MIN_TENOR - 1);
        assertTrue(terms.spent(q.nonce), "premise: the nonce is spent");
        _borrowExpecting(IInKindTerms.QuoteExpired.selector, address(tokA), _dataBy(q, ROGUE_KEY));
    }

    /// @notice A term over the quote refuses before the grid: a price the grid zeroes still reads as a term fault first.
    function testRevert_borrow_termRefusesBeforeTheGrid() public {
        _lp(alice, LP_CASH);
        Quote memory q = _quote(address(tokA), 1);
        q.maxTenor = MIN_TENOR;
        bytes memory data = _dataBy(q, ROGUE_KEY);
        _fund(address(tokA), borrower, UNITS);
        vm.prank(borrower);
        vm.expectRevert(IInKindTerms.TenorOverQuote.selector);
        vault.borrow(_req(address(tokA), UNITS, PRINCIPAL, MIN_TENOR + 1 days), data, "");
    }

    /// @notice A price the grid zeroes refuses before the signature is checked, with the appraiser delegated to a permissive wallet.
    function testRevert_borrow_gridRefusesBeforeTheSignatureWhileDelegated() public {
        _lp(alice, LP_CASH);
        _delegateAppraiser(address(new Permissive1271Wallet()));
        Quote memory q = _quote(address(tokA), 1);
        _borrowExpecting(IInKindTerms.PriceZero.selector, address(tokA), _dataBy(q, ROGUE_KEY));
    }

    /// @notice A delegated appraiser verifies by ECDSA alone, so a delegate that burns gas is never reached and a forgery refuses by name.
    function testRevert_borrow_aDelegatedAppraisersDelegateIsNeverCalled() public {
        _lp(alice, LP_CASH);
        _delegateAppraiser(address(new GasBurner1271()));
        Quote memory q = _quote(address(tokA), PRICE);
        bytes memory data = _dataBy(q, ROGUE_KEY);
        _fund(address(tokA), borrower, UNITS);
        bytes memory cd = abi.encodeCall(IInKindVault.borrow, (_req(address(tokA), UNITS, PRINCIPAL, MIN_TENOR), data, bytes("")));
        vm.prank(borrower);
        uint256 g = gasleft();
        (bool ok, bytes memory err) = address(vault).call{gas: 2_000_000}(cd);
        uint256 used = g - gasleft();
        assertFalse(ok, "refused");
        assertEq(bytes4(err), IInKindTerms.BadSignature.selector, "by ECDSA recovery, not by the delegate's answer");
        assertLt(used, 400_000, "and the delegate burned none of the budget");
    }

    /// @notice A quote is good through the last second of its life, `issuedAt + QUOTE_TTL`, and the life is five minutes.
    function test_borrow_atTheQuotesDeadlineSecondIsAdmitted() public {
        _lp(alice, LP_CASH);
        assertEq(terms.QUOTE_TTL(), 5 minutes, "a quote lives five minutes from its issue time");
        Quote memory q = _quote(address(tokA), PRICE);
        bytes memory data = _data(q);
        _warpTo(q.issuedAt + terms.QUOTE_TTL());
        assertGt(_borrowWith(q, data, UNITS, PRINCIPAL, MIN_TENOR), 0, "admitted at the life's last second");
    }

    /// @notice A term of exactly the quote's maximum is admitted.
    function test_borrow_aTermOfExactlyTheQuotesMaxIsAdmitted() public {
        _lp(alice, LP_CASH);
        Quote memory q = _quote(address(tokA), PRICE);
        q.maxTenor = MIN_TENOR;
        uint256 loanId = _borrowWith(q, _data(q), UNITS, PRINCIPAL, MIN_TENOR);
        assertEq(read.loan(loanId).tenor, MIN_TENOR, "lent for the quote's own horizon");
    }

    /// @notice A cap cut under what is lent leaves no room, refused by name: the room saturates at zero rather than underflowing.
    function testRevert_borrow_aCapCutUnderTheLentRefusesOverCap() public {
        _lp(alice, LP_CASH);
        _open(address(tokA));
        _setCap(guardian, address(tokA), uint192(PRINCIPAL / 2));
        Quote memory q = _quote(address(tokA), PRICE);
        q.maxPrincipal = MIN_PRINCIPAL;
        bytes memory data = _data(q);
        _fund(address(tokA), borrower, UNITS);
        vm.prank(borrower);
        vm.expectRevert(AceVaultFlows.OverCap.selector);
        vault.borrow(_req(address(tokA), UNITS, MIN_PRINCIPAL, MIN_TENOR), data, "");
    }

    // ---- the roll ----

    /// @notice A delegated appraiser's roll verifies by ECDSA alone, so a gas-burning delegate costs the hub's budget nothing.
    function test_admitsExtension_aDelegatedAppraisersDelegateIsNeverCalled() public {
        _lp(alice, LP_CASH);
        uint256 loanId = _open(address(tokA));
        _delegateAppraiser(address(new GasBurner1271()));
        _warpAtLeastTo(_expiry(loanId) - 1 hours);
        Extension memory e = _ext(loanId);
        bytes memory data = abi.encode(_rq(loanId), bytes(""));
        uint256 g = gasleft();
        bytes4 answer = vault.admitsExtension{gas: AceFixtures.POLICY_GAS}(e, data);
        uint256 used = g - gasleft();
        assertEq(answer, bytes4(0), "refused");
        assertLt(used, 60_000, "without the delegate burning the budget");
    }

    /// @notice A roll quote is good through the last second of its life, `issuedAt + QUOTE_TTL`.
    function test_extend_atTheRollQuotesDeadlineSecondIsAdmitted() public {
        _lp(alice, LP_CASH);
        uint256 loanId = _open(address(tokA));
        _warpAtLeastTo(_expiry(loanId) - 1 hours);
        RollQuote memory rq = _rq(loanId);
        bytes memory data = _rollData(rq, APPRAISER_KEY);
        _warpTo(rq.issuedAt + terms.QUOTE_TTL());
        _extend(loanId, data);
        assertEq(_expiry(loanId), _now() + MIN_TENOR, "extended at the life's last second");
    }

    /// @notice A new minTenor on the row stops the old market extending, as a new rate does.
    function test_extend_aMinTenorChangeIsRefused() public {
        _lp(alice, LP_CASH);
        uint256 loanId = _open(address(tokA));
        Row memory row = _row();
        row.minTenor = MIN_TENOR + 1 days;
        vm.prank(curator);
        terms.submitRow(address(tokA), row);
        _warpBy(TIMELOCK);
        terms.accept(address(tokA));
        assertEq(terms.rowOf(address(tokA)).minTenor, MIN_TENOR + 1 days, "premise: only the row's minTenor moved");
        _warpAtLeastTo(_expiry(loanId) - 1 hours);
        bytes memory data = _rollData(_rq(loanId), APPRAISER_KEY);
        _armFee(loanId, MIN_TENOR);
        vm.prank(borrower);
        vm.expectRevert(PolicyRefused.selector);
        ace.extend(loanId, 0, data);
    }

    /// @notice The vault consents only to an extension that leaves it the lender: the same signed roll naming another lender is refused.
    function test_admitsExtension_refusesAnotherLendersDestination() public {
        _lp(alice, LP_CASH);
        uint256 loanId = _open(address(tokA));
        _warpAtLeastTo(_expiry(loanId) - 1 hours);
        Extension memory e = _ext(loanId);
        bytes memory data = _rollData(_rq(loanId), APPRAISER_KEY);
        assertEq(vault.admitsExtension(e, data), IRollPolicy.admitsExtension.selector, "premise: the vault consents with itself as the lender");
        e.dst.lender = stranger;
        assertEq(vault.admitsExtension(e, data), bytes4(0), "and refuses the same roll naming another lender");
    }

    /// @notice A direct ask that does not lengthen the loan needs no exit cover: only a lengthening waits on idle covering the requests.
    /// @dev The hub never asks this vault such a question with data, since a same-market `refinanceTo` sends none; this pins the view's answer.
    function test_admitsExtension_aNonLengtheningAskNeedsNoExitCover() public {
        _lp(alice, LP_CASH);
        uint256 loanId = _open(address(tokA));
        uint256 all = vault.balanceOf(alice);
        vm.prank(alice);
        vault.requestExit(all);
        _warpAtLeastTo(_expiry(loanId) - 1 hours);
        Extension memory e = _ext(loanId);
        bytes memory data = _rollData(_rq(loanId), APPRAISER_KEY);
        assertEq(vault.admitsExtension(e, data), bytes4(0), "premise: a lengthening is refused while the requests are not covered");
        e.newExpiry = e.expiry;
        assertEq(vault.admitsExtension(e, data), IRollPolicy.admitsExtension.selector, "the same ask at the current expiry is admitted");
    }

    // ---- the collect ----

    /// @notice The collect tolerates only an empty pot: a redeem the token itself refuses reverts the collect, never reads as nothing.
    function testRevert_collect_aRedeemTheTokenRefusesBubbles() public {
        MockBlockableERC20 odd = new MockBlockableERC20("Odd", "ODD", 18);
        Listing[] memory l = _listings();
        l[1].collateral = address(odd);
        vault = _deploy(_cfg(0), _ik(), l);
        _lp(alice, LP_CASH);
        uint256 loanId = _open(address(odd));
        _toExpiry(loanId);
        odd.setBlocked(address(vault), true);
        vm.prank(keeper);
        vm.expectRevert(bytes("blocked"));
        vault.collectForfeited(_ids(loanId));
    }

    /// @notice A keeper batch holding a repaid id yields zero for it and still collects the live pot.
    function test_collect_aRepaidIdYieldsZero() public {
        _lp(alice, LP_CASH);
        uint256 repaid = _open(address(tokA));
        uint256 live = _open(address(tokB));
        _repayAll(repaid);
        _toExpiry(live);
        uint256 pot = _expectedPot(live);
        uint256 bal0 = tokB.balanceOf(address(vault));
        vm.prank(keeper);
        uint256[] memory out = vault.collectForfeited(_ids(repaid, live));
        assertEq(out[0], 0, "the repaid id yields zero");
        assertEq(out[1], pot, "and the batch goes on to the live pot");
        assertEq(tokB.balanceOf(address(vault)) - bal0, pot, "which came home whole");
    }

    // ---- the table ----

    /// @dev The rig's row with its largest loan raised past the rig's cap: a widening, so it waits.
    function _maxPrincipalRaise() internal pure returns (Row memory row) {
        row = _row();
        row.maxPrincipal = uint128(uint256(CAP) * 2);
    }

    /// @notice The curator may revoke what is pending, as the guardian may.
    function test_revokePendingByTheCurator() public {
        vm.prank(curator);
        terms.submitRow(address(tokA), _maxPrincipalRaise());
        vm.expectEmit(true, true, false, false, address(terms));
        emit IInKindTerms.RevokePending(curator, address(tokA));
        vm.prank(curator);
        terms.revokePending(address(tokA));
        (, uint64 validAt) = terms.pendingRowOf(address(tokA));
        assertEq(validAt, 0, "nothing pending");
    }

    /// @notice An accept clears what it landed: nothing reads pending after it, and a second accept has nothing due.
    function test_accept_clearsThePendingRow() public {
        vm.prank(curator);
        terms.submitRow(address(tokA), _maxPrincipalRaise());
        _warpBy(TIMELOCK);
        terms.accept(address(tokA));
        (, uint64 validAt) = terms.pendingRowOf(address(tokA));
        assertEq(validAt, 0, "nothing left pending");
        vm.expectRevert(IInKindTerms.NothingDue.selector);
        terms.accept(address(tokA));
    }

    /// @notice A row naming no token, or the vault itself, is refused.
    function testRevert_submitRow_zeroOrTheVaultAsCollateral() public {
        vm.prank(curator);
        vm.expectRevert(IInKindTerms.BadRow.selector);
        terms.submitRow(address(0), _row());
        vm.prank(curator);
        vm.expectRevert(IInKindTerms.BadRow.selector);
        terms.submitRow(address(vault), _row());
    }

    /// @notice A row whose fee at its longest term passes the hub's fee share is refused; one bps under the bound is admitted.
    /// @dev At the row's 14-day longest term the bound is 59253 bps a year, `2500 * 1e4 * 365 days / (14 days * 11000)` floored.
    function test_submitRow_theFeeShareBoundsTheRate() public {
        address c = address(new MockERC20("C", "C", 18));
        Row memory row = _row();
        row.lenderAprBps = 59_254; // one past the share rail at the row's 14-day longest term
        vm.prank(curator);
        vm.expectRevert(IInKindTerms.BadRow.selector);
        terms.submitRow(c, row);
        row.lenderAprBps = 59_253;
        vm.prank(curator);
        terms.submitRow(c, row);
        (, uint64 validAt) = terms.pendingRowOf(c);
        assertEq(validAt, _now() + TIMELOCK, "one bps under the bound is admitted, and waits");
    }

    // ---- the write-once rails ----

    /// @notice A token listed twice at deploy is refused.
    function testRevert_constructor_aDuplicateListing() public {
        Listing[] memory l = _listings();
        l[1].collateral = address(tokA);
        _deployExpecting(IInKindTerms.BadRow.selector, _ik(), l);
    }

    /// @notice A single-term vault, its minimum and maximum equal, deploys.
    function test_constructor_equalVaultTenorsAreAdmitted() public {
        InKindConfig memory ik = _ik();
        ik.maxTenor = ik.minTenor;
        Listing[] memory l = _listings();
        (l[0].row.maxTenor, l[1].row.maxTenor) = (MIN_TENOR, MIN_TENOR);
        IInKindVault v = _deploy(_cfg(0), ik, l);
        assertEq(v.MAX_TENOR(), v.MIN_TENOR(), "a single-term vault deploys");
    }

    /// @notice The floor ticket is admitted from two atoms to the uint128 maximum, and refused one past it.
    function test_constructor_minPrincipalEnds() public {
        InKindConfig memory ik = _ik();
        ik.minPrincipal = 2;
        assertEq(_termsOf(_deploy(_cfg(0), ik, new Listing[](0))).MIN_PRINCIPAL(), 2, "two atoms admitted");
        ik.minPrincipal = type(uint128).max;
        assertEq(_termsOf(_deploy(_cfg(0), ik, new Listing[](0))).MIN_PRINCIPAL(), type(uint128).max, "the uint128 maximum admitted");
        ik.minPrincipal = uint256(type(uint128).max) + 1;
        _deployExpecting(IInKindTerms.BadTerms.selector, ik, new Listing[](0));
    }

    /// @notice The coverage is admitted at both of the hub's ends, and refused one past the top.
    function test_constructor_coverageEnds() public {
        InKindConfig memory ik = _ik();
        ik.coverageWad = Constants.MIN_COVERAGE_WAD;
        assertEq(_termsOf(_deploy(_cfg(0), ik, new Listing[](0))).COVERAGE_WAD(), Constants.MIN_COVERAGE_WAD, "the least coverage admitted");
        ik.coverageWad = Constants.MAX_COVERAGE_WAD;
        assertEq(_termsOf(_deploy(_cfg(0), ik, new Listing[](0))).COVERAGE_WAD(), Constants.MAX_COVERAGE_WAD, "the most coverage admitted");
        ik.coverageWad = Constants.MAX_COVERAGE_WAD + 1;
        _deployExpecting(IInKindTerms.BadTerms.selector, ik, new Listing[](0));
    }

    /// @notice The sealed NAV is exactly the base's: right after a sync it is gross less the vesting pile, the identity the fee test reads.
    function test_totalAssets_isGrossLessTheVestingPile() public {
        _lp(alice, LP_CASH);
        assertEq(vault.totalAssets(), LP_CASH + vault.MIN_SEED(), "a fresh deposit and the genesis seed are the whole NAV");
        usdc.mint(address(vault), 10_000e6);
        vault.crank();
        _warpBy(VEST_W / 2);
        uint256 u = AceVault(address(vault)).unvested();
        assertGt(u, 0, "premise: part of the gain still vests");
        assertEq(vault.totalAssets(), vault.grossNav() - u, "NAV is gross less the pile, to the wei");
    }
}
