// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.36;

import {Vm} from "forge-std/Test.sol";
import {Ace} from "../../src/ace/hub/Ace.sol";
import {MarketParams, OpenBounds} from "../../src/ace/hub/Types.sol";
import {MarketInit} from "../../src/ace/hub/MarketInit.sol";
import {MockERC20} from "../mocks/MockERC20.sol";
import {MockPersistenceRecord} from "../mocks/MockPersistenceRecord.sol";
import {AceFixtures} from "../utils/AceFixtures.sol";
import {AceSaleProceedsPullRig, ISaleProceedsQuote} from "./AceSaleProceedsPull.t.sol";

/// @title AceSaleProceedsPullHardening
/// @notice The properties the first sale-pull rows leave open, each measured exactly rather than bounded.
/// @notice N fills credit exactly their sum and call `pushToken` zero times; each of the four doors carries exactly the fills, once.
/// @notice A close in a DIFFERENT (lender, quote) pair pays its own lender his own pool and leaves the sale's credit where it is.
/// @dev Every "carries" figure is a DIFFERENTIAL: the same close run in a snapshot with no sale, so the sale's part is isolated.
/// @dev That is an independent derivation, never a restatement of `_pushOwed`: the two runs differ only by the buys.
/// @dev The other-lender rows have the SALE'S OWN LENDER run the foreign close, so a pool keyed by the caller would leak.
contract AceSaleProceedsPullHardeningTest is AceSaleProceedsPullRig {
    address internal bob = address(0xB0B2); // another lender, same quote

    uint8 internal constant REPAY = 0;
    uint8 internal constant FINALIZE = 1;
    uint8 internal constant FORCE_CLOSE = 2;
    uint8 internal constant SETTLE_EXPIRED = 3;

    /// @dev One market a close can run in: who lends, in what, and the record `finalize` reads distress off.
    struct Side {
        bytes32 m;
        address lender;
        ISaleProceedsQuote q;
        MockPersistenceRecord rec;
    }

    /// @dev What one close delivered, read off the lender's wallet and the hub's own events.
    struct Close {
        uint256 got; // the lender's balance delta across the close
        uint256 collectedN; // `Collected` events naming the side's lender, in its quote
        uint256 collectedAmt; // their summed amount
        uint256 failedN; // `LenderPushFailed` events of any kind
        uint256 saleCollectedN; // `Collected` events naming the SALE's lender in the SALE's quote
    }

    function _newQuote() internal override returns (address) {
        return address(new MockERC20("USD Coin", "USDC", 6));
    }

    /* ------------------------------- helpers ------------------------------- */

    function _home() internal view returns (Side memory) {
        return Side(mid, alice, quote, record);
    }

    /// @dev A record-wired market of `lender` in `q`, funded, with one live loan drawn by `borrower`.
    function _foreign(address lender, ISaleProceedsQuote q, uint256 deposit, uint256 principal) internal returns (Side memory s, uint256 loanId) {
        MockPersistenceRecord rec = new MockPersistenceRecord(address(q), address(coll));
        rec.setObserved(AceFixtures.px(1e18, address(q), address(coll)));
        rec.setMinPrice(AceFixtures.px(2e18, address(q), address(coll)));
        MarketParams memory p = AceFixtures.marketParams(address(q), address(coll));
        p.record = address(rec);
        p.lender = lender;
        s = Side(ace.createMarket(p), lender, q, rec);
        q.mint(lender, deposit);
        vm.startPrank(lender);
        q.approve(address(ace), deposit);
        ace.deposit(s.m, deposit);
        vm.stopPrank();
        loanId = _openOn(s, principal);
    }

    function _openOn(Side memory s, uint256 principal) internal returns (uint256 loanId) {
        coll.mint(borrower, COLL);
        vm.startPrank(borrower);
        coll.approve(address(pm), COLL);
        loanId = ace.open(s.m, COLL, principal, 0, borrower, OpenBounds(0, 0, 0));
        vm.stopPrank();
    }

    /// @dev One buy at `budget`, funded fresh, so the rows choose each fill's size.
    function _buyFor(uint256 id, uint256 budget) internal returns (uint256 unitsOut, uint256 filled) {
        quote.mint(buyer, budget);
        vm.startPrank(buyer);
        quote.approve(address(ace), budget);
        (unitsOut, filled) = ace.buyInventory(id, budget, 1, buyer);
        vm.stopPrank();
    }

    /// @dev Two partial fills of the pot; both must fill and the pot must outlast them.
    function _buyTwice(uint256 id) internal returns (uint256 fills) {
        (, uint256 f1) = _buyFor(id, BUY);
        (, uint256 f2) = _buyFor(id, BUY / 2);
        assertGt(f1, 0, "premise: the first fill raised proceeds");
        assertGt(f2, 0, "premise: and so did the second");
        assertGt(read.invPotOf(mid, id), 0, "premise: both were PARTIAL fills, the pot outlasting them");
        fills = f1 + f2;
    }

    /// @dev Run one terminal door on `loanId` as `caller`, and read what it delivered to the side's lender.
    /// @dev The repay door's caller pays the debt itself, funded exactly, so its own wallet ends where it began.
    function _close(uint8 door, Side memory s, uint256 loanId, address caller) internal returns (Close memory r) {
        if (door == FORCE_CLOSE) vm.warp(uint256(read.loan(loanId).expiry) + 1);
        if (door == SETTLE_EXPIRED) {
            uint64 tenor = read.loan(loanId).tenor;
            vm.warp(uint256(read.loan(loanId).expiry) + MarketInit.autoRefinanceWindow(tenor) + 1);
        }
        if (door == FINALIZE) s.rec.setBelow(true);
        uint256 debt = read.loan(loanId).debt;
        if (door == REPAY) {
            s.q.mint(caller, debt);
            vm.prank(caller);
            s.q.approve(address(ace), debt);
        }
        uint256 had = s.q.balanceOf(s.lender);
        vm.recordLogs();
        vm.prank(caller);
        if (door == REPAY) ace.repay(loanId, debt);
        else if (door == FINALIZE) ace.finalize(loanId);
        else if (door == FORCE_CLOSE) ace.forceClose(loanId);
        else ace.settleExpired(loanId);
        Vm.Log[] memory logs = vm.getRecordedLogs();
        if (door == FINALIZE) s.rec.setBelow(false);
        assertTrue(read.loan(loanId).closedAt != 0, "premise: the door closed the loan");
        r.got = s.q.balanceOf(s.lender) - had;
        for (uint256 i; i < logs.length; i++) {
            if (logs[i].emitter != address(ace) || logs[i].topics.length == 0) continue;
            if (logs[i].topics[0] == PUSH_FAILED_SIG) r.failedN++;
            if (logs[i].topics[0] != COLLECTED_SIG) continue;
            address who = address(uint160(uint256(logs[i].topics[1])));
            address tok = address(uint160(uint256(logs[i].topics[2])));
            if (who == alice && tok == address(quote)) r.saleCollectedN++;
            if (who == s.lender && tok == address(s.q)) {
                r.collectedN++;
                r.collectedAmt += abi.decode(logs[i].data, (uint256));
            }
        }
    }

    /* ============ 1. N FILLS: exactly their sum, and not one call into the push door ============ */

    /// @notice N PARTIAL FILLS CREDIT EXACTLY THEIR SUM, beside credit already pooled, and no fill enters `pushToken`.
    /// @dev A partial repay on a second loan pools credit first, so a whole-pool push and a delta push give different numbers.
    /// @dev Each step is checked, not just the end: a push on the k-th fill alone, or a credit that overwrites, reddens at k.
    function testFuzz_Sale_NPartialFillsCreditExactlyTheirSumAndPushNothing(uint8 nSeed, uint256 seed) public {
        uint256 id = _settledLoan();
        uint256 second = _openLoan();
        uint256 part = read.loan(second).debt / 3;
        quote.mint(borrower, part);
        vm.startPrank(borrower);
        quote.approve(address(ace), part);
        ace.repay(second, part);
        vm.stopPrank();
        uint256 held = _owed();
        assertGt(held, 0, "premise: a partial repay pooled credit before any sale");

        uint256 n = bound(nSeed, 2, 5);
        uint256 aliceHad = quote.balanceOf(alice);
        uint256 hubHad = quote.balanceOf(address(ace));
        uint256 potHad = read.invPotOf(mid, id);
        uint256 sum;
        uint256 units;
        vm.expectCall(address(ace), abi.encodeWithSelector(Ace.pushToken.selector), 0);
        vm.recordLogs();
        for (uint256 k; k < n; k++) {
            uint256 budget = bound(uint256(keccak256(abi.encode(seed, k))), 1e6, 1_000e6);
            (uint256 got, uint256 filled) = _buyFor(id, budget);
            assertGt(filled, 0, "premise: every fill in the sequence raised proceeds");
            (sum, units) = (sum + filled, units + got);
            assertEq(_owed(), held + sum, "after each fill the pool is the held credit plus every fill so far, exactly");
            assertEq(quote.balanceOf(alice), aliceHad, "and the lender's wallet has not moved");
        }
        (bool paid,) = _seen(vm.getRecordedLogs(), COLLECTED_SIG);
        assertFalse(paid, "no fill announced a payout");
        assertEq(quote.balanceOf(address(ace)) - hubHad, sum, "the hub holds every fill, which is what the credit is a claim on");
        assertEq(potHad - read.invPotOf(mid, id), units, "the pot gave up exactly what the fills delivered");
        assertGt(read.invPotOf(mid, id), 0, "premise: every fill was partial, the pot outlasting the sequence");
    }

    /* ============ 2. EACH DOOR IN THE PAIR CARRIES EXACTLY THE FILLS, ONCE ============ */

    /// @dev The home pair: a second loan in the sale's own market closes, with and without the sale before it.
    function _assertTheCloseCarriesExactlyTheFills(uint8 door) internal {
        uint256 id = _settledLoan();
        uint256 second = _openLoan();
        address caller = door == REPAY ? borrower : keeper;
        uint256 owed0 = _owed();

        uint256 snap = vm.snapshotState();
        Close memory alone = _close(door, _home(), second, caller);
        vm.revertToState(snap);

        uint256 fills = _buyTwice(id);
        assertEq(_owed(), owed0 + fills, "the fills wait in the pool beside what was there, unpushed");
        Close memory r = _close(door, _home(), second, caller);

        assertEq(r.got, alone.got + fills, "the close delivered its own credit plus EXACTLY the fills, no more and no less");
        assertGt(alone.got, 0, "premise: the close pushes its own credit even with no sale behind it");
        assertEq(r.collectedN, 1, "in exactly one `Collected`");
        assertEq(r.collectedAmt, r.got, "naming exactly what the lender received");
        assertEq(r.failedN, 0, "and no refusal was announced");
        assertEq(_owed(), 0, "leaving the pool empty");
    }

    /// @notice The CLOSING REPAY of another loan carries a sale's proceeds home, exactly and in one `Collected`.
    function test_Carry_TheClosingRepayDeliversExactlyTheFills() public {
        _assertTheCloseCarriesExactlyTheFills(REPAY);
    }

    /// @notice `finalize` of another loan carries them, exactly and once.
    function test_Carry_FinalizeDeliversExactlyTheFills() public {
        _assertTheCloseCarriesExactlyTheFills(FINALIZE);
    }

    /// @notice `forceClose`'s settle branch carries them, exactly and once.
    function test_Carry_ForceCloseDeliversExactlyTheFills() public {
        _assertTheCloseCarriesExactlyTheFills(FORCE_CLOSE);
    }

    /// @notice `settleExpired` carries them, exactly and once.
    function test_Carry_SettleExpiredDeliversExactlyTheFills() public {
        _assertTheCloseCarriesExactlyTheFills(SETTLE_EXPIRED);
    }

    /* ============ 3. A CLOSE IN ANOTHER PAIR LEAVES THE SALE'S CREDIT WHERE IT IS ============ */

    /// @dev A foreign side closes, with and without the sale before it, and `caller` cranks or pays it.
    /// @dev PAIRED: the foreign close must push its own lender's pool, or "it left hers alone" is vacuous.
    function _assertAForeignCloseLeavesTheSaleAlone(uint8 door, Side memory s, uint256 foreignLoan, uint256 id, address caller) internal {
        uint256 snap = vm.snapshotState();
        Close memory alone = _close(door, s, foreignLoan, caller);
        vm.revertToState(snap);

        uint256 owed0 = _owed();
        uint256 fills = _buyTwice(id);
        assertEq(_owed(), owed0 + fills, "the fills join the sale lender's pool, unpushed");
        uint256 aliceHad = quote.balanceOf(alice);
        Close memory r = _close(door, s, foreignLoan, caller);

        assertGt(alone.got, 0, "premise: the foreign close really pushes its own lender's pool");
        assertEq(r.got, alone.got, "and a sale in another pair changes nothing it pays");
        assertEq(r.collectedN, 1, "in one `Collected`, naming its own lender in its own quote");
        assertEq(r.saleCollectedN, 0, "and none naming the sale's lender in the sale's quote");
        assertEq(_owed(), owed0 + fills, "the sale's credit is exactly where the fills put it");
        assertEq(quote.balanceOf(alice), aliceHad, "and not one wei of it reached the sale's lender");

        vm.prank(alice);
        assertEq(ace.collect(address(quote), alice), owed0 + fills, "her own collect still pays exactly that pool");
    }

    /// @dev Bob's market in the sale's quote, record-wired so every door is reachable; ALICE runs his close.
    /// @dev She is the one caller whose own pool a caller-keyed push would reach, which is what gives the row its teeth.
    function _bobsSide(uint8 door) internal {
        uint256 id = _settledLoan();
        (Side memory s, uint256 foreignLoan) = _foreign(bob, quote, 5_000e6, 400e6);
        _assertAForeignCloseLeavesTheSaleAlone(door, s, foreignLoan, id, alice);
    }

    /// @dev Alice's own market in ANOTHER quote: same lender, different pool. A keeper runs the close.
    function _otherQuoteSide(uint8 door) internal {
        uint256 id = _settledLoan();
        ISaleProceedsQuote dai = ISaleProceedsQuote(address(new MockERC20("Dai", "DAI", 18)));
        (Side memory s, uint256 foreignLoan) = _foreign(alice, dai, 5_000e18, 400e18);
        _assertAForeignCloseLeavesTheSaleAlone(door, s, foreignLoan, id, keeper);
    }

    /// @notice ANOTHER LENDER'S closing repay, paid by the sale's lender herself, leaves her sale credit pooled.
    function test_Foreign_AnotherLendersClosingRepayLeavesTheSaleAlone() public {
        _bobsSide(REPAY);
    }

    /// @notice Another lender's `finalize`, cranked by the sale's lender, leaves it pooled.
    function test_Foreign_AnotherLendersFinalizeLeavesTheSaleAlone() public {
        _bobsSide(FINALIZE);
    }

    /// @notice Another lender's `forceClose`, cranked by the sale's lender, leaves it pooled.
    function test_Foreign_AnotherLendersForceCloseLeavesTheSaleAlone() public {
        _bobsSide(FORCE_CLOSE);
    }

    /// @notice Another lender's `settleExpired`, cranked by the sale's lender, leaves it pooled.
    function test_Foreign_AnotherLendersSettleExpiredLeavesTheSaleAlone() public {
        _bobsSide(SETTLE_EXPIRED);
    }

    /// @notice The sale's lender's OWN close in another quote pays her that quote's pool and leaves the sale's untouched.
    function test_Foreign_TheSameLendersOtherQuoteClosingRepayLeavesTheSaleAlone() public {
        _otherQuoteSide(REPAY);
    }

    /// @notice Likewise at `settleExpired`, the door that pays nobody but the market's lender.
    function test_Foreign_TheSameLendersOtherQuoteSettleExpiredLeavesTheSaleAlone() public {
        _otherQuoteSide(SETTLE_EXPIRED);
    }
}
