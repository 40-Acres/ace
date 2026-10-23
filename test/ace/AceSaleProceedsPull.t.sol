// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.36;

import {Test, Vm} from "forge-std/Test.sol";
import {Ace} from "../../src/ace/hub/Ace.sol";
import {Lender} from "../../src/ace/hub/Lender.sol";
import {MarketParams, OpenBounds} from "../../src/ace/hub/Types.sol";
import {PositionManager} from "../../src/ace/positions/PositionManager.sol";
import {MockBlockableERC20} from "../mocks/MockBlockableERC20.sol";
import {MockHostileGasERC20} from "../mocks/MockHostileGasERC20.sol";
import {MockStakeVault} from "../mocks/MockStakeVault.sol";
import {MockPersistenceRecord} from "../mocks/MockPersistenceRecord.sol";
import {AceFixtures} from "../utils/AceFixtures.sol";
import {AceReader} from "../utils/AceReader.sol";

/// @dev The three calls every quote mock here answers, so one rig drives both quote shapes.
interface ISaleProceedsQuote {
    function mint(address to, uint256 amount) external;
    function approve(address spender, uint256 amount) external returns (bool);
    function balanceOf(address who) external view returns (uint256);
}

/// @title AceSaleProceedsPullRig
/// @notice A settled loan, rested past the ask hold, in a market whose one lender is `alice`.
/// @dev The quote is the concrete suite's choice, so the hostile shape (a blocklist, a gas burner) is too.
abstract contract AceSaleProceedsPullRig is Test {
    Ace internal ace;
    AceReader internal read;
    PositionManager internal pm;
    ISaleProceedsQuote internal quote;
    MockStakeVault internal coll;
    MockPersistenceRecord internal record;
    bytes32 internal mid;

    address internal alice = address(0xA11CE); // the market's one named lender
    address internal buyer = address(0xB04E5);
    address internal borrower = address(0xB0BA);
    address internal keeper = address(0xCAFE);
    address internal friend = address(0xF41E2D); // a wallet of the lender's that is not the lender

    uint256 internal constant COLL = 10_000e18;
    uint256 internal constant PRINCIPAL = 4_500e6;
    uint256 internal constant BUY = 2_000e6;

    bytes32 internal constant COLLECTED_SIG = Lender.Collected.selector; // from the declared event, so a re-shape moves it
    bytes32 internal constant PUSH_FAILED_SIG = Lender.LenderPushFailed.selector; // likewise

    function _newQuote() internal virtual returns (address);

    function setUp() public {
        vm.warp(1_000_000);
        quote = ISaleProceedsQuote(_newQuote());
        coll = new MockStakeVault(42);
        record = new MockPersistenceRecord(address(quote), address(coll));
        record.setObserved(AceFixtures.px(1e18, address(quote), address(coll)));
        record.setMinPrice(AceFixtures.px(2e18, address(quote), address(coll)));
        MarketParams memory p = AceFixtures.marketParams(address(quote), address(coll));
        p.record = address(record);
        p.lender = alice;
        AceFixtures.Deployment memory d = AceFixtures.deploy(p);
        (ace, pm, read, mid) = (d.ace, d.positionManager, d.read, d.id);
    }

    /// @dev Lend and draw: the loan is live, and the open has paid the borrower.
    function _openLoan() internal returns (uint256 id) {
        quote.mint(alice, 5_000e6);
        vm.startPrank(alice);
        quote.approve(address(ace), 5_000e6);
        ace.deposit(mid, 5_000e6);
        vm.stopPrank();

        coll.mint(borrower, COLL);
        vm.startPrank(borrower);
        coll.approve(address(pm), COLL);
        id = ace.open(mid, COLL, PRINCIPAL, 0, borrower, OpenBounds(0, 0, 0));
        vm.stopPrank();
    }

    /// @dev Settle by distress and rest past the hold, so the next call may buy the pot.
    function _settle(uint256 id) internal {
        record.setBelow(true);
        vm.prank(keeper);
        ace.finalize(id);
        record.setBelow(false);
        vm.warp(read.inventoryAskOpensAt(id));
    }

    function _settledLoan() internal returns (uint256 id) {
        id = _openLoan();
        _settle(id);
    }

    /// @dev A stranger buys part of the pot; `alice` never appears in the call.
    function _buy(uint256 id) internal returns (uint256 unitsOut, uint256 filled) {
        quote.mint(buyer, BUY);
        vm.startPrank(buyer);
        quote.approve(address(ace), BUY);
        (unitsOut, filled) = ace.buyInventory(id, BUY, 1, buyer);
        vm.stopPrank();
    }

    function _owed() internal view returns (uint256) {
        return ace.lenderOwed(alice, address(quote));
    }

    /// @dev Whether the hub emitted `sig` in `logs`, and that event's one-word amount.
    function _seen(Vm.Log[] memory logs, bytes32 sig) internal view returns (bool saw, uint256 amount) {
        for (uint256 i; i < logs.length; i++) {
            if (logs[i].emitter != address(ace) || logs[i].topics.length == 0 || logs[i].topics[0] != sig) continue;
            return (true, abi.decode(logs[i].data, (uint256)));
        }
    }

    /// @dev Fund and approve one `BUY` for the buyer, for rows that make the call themselves at a chosen budget.
    function _fundBuyer() internal {
        quote.mint(buyer, BUY);
        vm.prank(buyer);
        quote.approve(address(ace), BUY);
    }

    /// @dev Bisect the least outer budget at which the buy lands. The bounds are guards, never tuning knobs.
    function _leastBudgetThatBuys(uint256 id) internal returns (uint256) {
        uint256 lo = 60_000; // under the buy's own body, so below the floor on either build profile
        uint256 hi = 8_000_000;
        assertTrue(_buysAt(id, hi), "premise: the buy lands at 8M");
        assertFalse(_buysAt(id, lo), "premise: the low bound is under the floor, so there is an interval to search");
        while (hi - lo > 1_000) {
            uint256 probe = (lo + hi) / 2;
            if (_buysAt(id, probe)) hi = probe;
            else lo = probe;
        }
        return hi;
    }

    /// @dev One probe, snapshotted, so every probe buys the same pot.
    function _buysAt(uint256 id, uint256 cap) internal returns (bool ok) {
        uint256 snap = vm.snapshotState();
        vm.prank(buyer);
        try ace.buyInventory{gas: cap}(id, BUY, 1, buyer) returns (uint256 unitsOut, uint256) {
            ok = unitsOut > 0;
        } catch {}
        vm.revertToState(snap);
    }
}

/// @title AceSaleProceedsPull
/// @notice A SALE PAYS NOBODY IN THE BUYER'S CALL: the fill credits the market lender's pool, and nothing is pushed.
/// @notice The credit reaches the lender by the next terminal close's push in any market of the pair, or by their own `collect`.
/// @dev The four close doors are the whole push list; these rows pin that `buyInventory` is not a fifth.
contract AceSaleProceedsPullTest is AceSaleProceedsPullRig {
    function _newQuote() internal override returns (address) {
        return address(new MockBlockableERC20("USD Coin", "USDC", 6));
    }

    function _block(address who, bool on) internal {
        MockBlockableERC20(address(quote)).setBlocked(who, on);
    }

    /// @notice A filled buy credits the lender's pool by exactly the fill and moves no quote to anyone.
    /// @dev `expectCall(..., 0)` is the positive statement: the push door is never entered, not merely entered and refused.
    function test_Sale_AFilledBuyCreditsThePoolAndPaysNobody() public {
        uint256 id = _settledLoan();
        assertEq(_owed(), 0, "premise: the settling close pushed the pool, so the sale is all that will be owed");
        uint256 aliceHad = quote.balanceOf(alice);
        uint256 hubHad = quote.balanceOf(address(ace));

        vm.expectCall(address(ace), abi.encodeWithSelector(Ace.pushToken.selector), 0);
        vm.recordLogs();
        (uint256 unitsOut, uint256 filled) = _buy(id);
        Vm.Log[] memory logs = vm.getRecordedLogs();
        (bool paid,) = _seen(logs, COLLECTED_SIG);
        (bool failed,) = _seen(logs, PUSH_FAILED_SIG);

        assertGt(unitsOut, 0, "premise: the ask filled");
        assertGt(filled, 0, "premise: and raised proceeds");
        assertEq(_owed(), filled, "the whole fill is credited to the lender's pool");
        assertEq(quote.balanceOf(alice), aliceHad, "and none of it reached the lender in the buyer's call");
        assertEq(quote.balanceOf(address(ace)) - hubHad, filled, "the hub holds the fill, which is what the credit is a claim on");
        assertFalse(paid, "no `Collected`: nothing was paid");
        assertFalse(failed, "no `LenderPushFailed`: nothing was even tried");
    }

    /// @notice Credit a refused close left pooled STAYS pooled across a sale, and the fill joins it.
    /// @dev The lender accepts the quote at the buy and the gas is ample, so a push attempted here could only have delivered.
    function test_Sale_ABuyLeavesEarlierPooledCreditWhereItWas() public {
        _block(alice, true);
        uint256 id = _settledLoan();
        uint256 left = _owed();
        assertGt(left, 0, "premise: the settling close's push was refused, so credit stayed pooled");
        _block(alice, false);
        uint256 aliceHad = quote.balanceOf(alice);

        (, uint256 filled) = _buy(id);

        assertGt(filled, 0, "premise: the buy filled");
        assertEq(_owed(), left + filled, "the old credit and the fill wait together");
        assertEq(quote.balanceOf(alice), aliceHad, "and the sale moved none of either");
    }

    /// @notice The lender's own `collect` pays a sale's proceeds, to the wallet they name.
    function test_Sale_TheLendersOwnCollectPaysTheProceeds() public {
        uint256 id = _settledLoan();
        (, uint256 filled) = _buy(id);
        assertGt(filled, 0, "premise: the buy filled");

        vm.expectEmit(true, true, true, true, address(ace));
        emit Lender.Collected(alice, address(quote), friend, filled);
        vm.prank(alice);
        uint256 got = ace.collect(address(quote), friend);

        assertEq(got, filled, "collect pays exactly the fill");
        assertEq(quote.balanceOf(friend), filled, "delivered where the lender pointed it");
        assertEq(_owed(), 0, "leaving the pool empty");
    }

    /// @notice A terminal close in ANOTHER market of the same (lender, quote) pair carries a sale's proceeds home.
    /// @dev The pool is keyed by the pair and the close pushes the whole of it, so the sale needs no push of its own.
    /// @dev Measured against the same close in a snapshot with no sale behind it, so the sale's share is exact.
    function test_Sale_ACloseInAnotherMarketOfThePairCarriesTheProceedsHome() public {
        uint256 id = _settledLoan();
        uint256 other = _openInASecondMarket(40e6);

        uint256 snap = vm.snapshotState();
        (uint256 alone,,) = _closeOther(other);
        vm.revertToState(snap);

        uint256 owed0 = _owed();
        (, uint256 filled) = _buy(id);
        assertGt(filled, 0, "premise: the buy filled, so there are proceeds to carry");
        assertEq(_owed(), owed0 + filled, "premise: the sale's proceeds are waiting in the pool");
        (uint256 got, uint256 collectedN, uint256 named) = _closeOther(other);

        assertEq(got, alone + filled, "the other market's closing repay carried its own credit plus exactly the sale's proceeds");
        assertGt(alone, 0, "premise: that close pushes its own credit even with no sale behind it");
        assertEq(collectedN, 1, "in exactly one `Collected`");
        assertEq(named, got, "naming exactly what the lender received");
        assertEq(_owed(), 0, "the whole pool left, not the close's delta");
    }

    /// @dev The other market's closing repay: what reached the lender, and the hub's `Collected` count and summed amount.
    function _closeOther(uint256 other) internal returns (uint256 got, uint256 collectedN, uint256 named) {
        uint256 had = quote.balanceOf(alice);
        vm.recordLogs();
        _repayInFull(other);
        Vm.Log[] memory logs = vm.getRecordedLogs();
        got = quote.balanceOf(alice) - had;
        for (uint256 i; i < logs.length; i++) {
            if (logs[i].emitter != address(ace) || logs[i].topics.length == 0 || logs[i].topics[0] != COLLECTED_SIG) continue;
            collectedN++;
            named += abi.decode(logs[i].data, (uint256));
        }
    }

    /// @dev A second market, same lender and quote, priced by the market alone; returns its live loan.
    function _openInASecondMarket(uint256 principal) internal returns (uint256 loanId) {
        MarketParams memory p = AceFixtures.marketParams(address(quote), address(coll));
        p.lender = alice;
        bytes32 m2 = ace.createMarket(p);
        quote.mint(alice, 100e6);
        vm.startPrank(alice);
        quote.approve(address(ace), 100e6);
        ace.deposit(m2, 100e6);
        vm.stopPrank();
        coll.mint(borrower, COLL);
        vm.startPrank(borrower);
        coll.approve(address(pm), COLL);
        loanId = ace.open(m2, COLL, principal, 0, borrower, OpenBounds(0, 0, 0));
        vm.stopPrank();
    }

    function _repayInFull(uint256 loanId) internal {
        uint256 debt = read.loan(loanId).debt;
        quote.mint(borrower, debt);
        vm.startPrank(borrower);
        quote.approve(address(ace), debt);
        ace.repay(loanId, debt);
        vm.stopPrank();
    }
}

/// @title AceSaleProceedsPullGas
/// @notice A buyer is never exposed to the quote's `transfer`: a quote that burns every unit it is handed is not called.
contract AceSaleProceedsPullGasTest is AceSaleProceedsPullRig {
    function _newQuote() internal override returns (address) {
        return address(new MockHostileGasERC20("USD Coin", "USDC", 6));
    }

    /// @notice A GAS-BURNING QUOTE IS NEVER CALLED BY A BUY, even with a pool already held and a budget that would try a push.
    /// @dev The pool is held by a close whose push the quote refused, so a pushing sale would have something to carry.
    /// @dev The budget is the buy's measured floor plus 250k, measured before the burn is armed: enough to fund a push, were there one.
    /// @dev The pull is `transferFrom`, which the mock leaves honest, so any call into the burn would be a push.
    function test_Sale_AGasBurningQuoteIsNeverCalledByABuy() public {
        MockHostileGasERC20 hostile = MockHostileGasERC20(address(quote));
        uint256 id = _openLoan();
        hostile.setReverting(true);
        _settle(id);
        hostile.setReverting(false);
        uint256 held = _owed();
        assertGt(held, 0, "premise: the refused close push left a pool held");
        _fundBuyer();
        uint256 cap = _leastBudgetThatBuys(id) + 250_000;
        uint256 aliceHad = quote.balanceOf(alice);
        hostile.setBurnAll(true);

        vm.expectCall(address(ace), abi.encodeWithSelector(Ace.pushToken.selector), 0);
        vm.prank(buyer);
        (uint256 unitsOut, uint256 filled) = ace.buyInventory{gas: cap}(id, BUY, 1, buyer);

        assertGt(unitsOut, 0, "the buy landed");
        assertEq(coll.balanceOf(buyer), unitsOut, "delivered");
        assertEq(_owed(), held + filled, "the fill joined the held pool");
        assertEq(quote.balanceOf(alice), aliceHad, "and nothing moved to the lender");
    }
}
