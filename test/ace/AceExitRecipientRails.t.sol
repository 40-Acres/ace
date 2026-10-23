// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.36;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {Ace, InventoryHeld, LoanClosed, LoanMatured, NoMarket, NotBorrower, ZeroWithdrawal} from "../../src/ace/hub/Ace.sol";
import {BelowMinDebt, DrawBelowDebt, MarketPairMismatch, QuoteMismatch, ZeroWithdrawTo} from "../../src/ace/hub/Borrower.sol";
import {EmptyPot, ExitToHub, Lender, NotTheLender} from "../../src/ace/hub/Lender.sol";
import {ExitToCustodian} from "../../src/ace/hub/libraries/Recipients.sol";
import {NotMaker, OrderClosed, Orders} from "../../src/ace/hub/Orders.sol";
import {NoClaimLeg} from "../../src/ace/hub/Settlement.sol";
import {MarketParams, OpenBounds, Order} from "../../src/ace/hub/Types.sol";
import {PositionManager} from "../../src/ace/positions/PositionManager.sol";
import {IPersistenceRecord} from "../../src/interfaces/IPersistenceRecord.sol";
import {IPositionManager} from "../../src/interfaces/IPositionManager.sol";
import {MockERC20} from "../mocks/MockERC20.sol";
import {MockPersistenceRecord} from "../mocks/MockPersistenceRecord.sol";
import {MockStakeVault} from "../mocks/MockStakeVault.sol";
import {MockZeroRefusingERC20} from "../mocks/MockZeroRefusingERC20.sol";
import {AceFixtures} from "../utils/AceFixtures.sol";
import {AceReader} from "../utils/AceReader.sol";
import {WarpClock} from "../utils/WarpClock.sol";
import {AceOrderFixture} from "./AceOrderRails.t.sol";
import {AceRefinanceWithdrawFixture} from "./AceRefinanceWithdraw.t.sol";

/// @notice Recipient refusals preserve credits and custody on an ordinary quote.
contract AceExitRecipientRailsTest is WarpClock {
    Ace internal ace;
    AceReader internal read;
    PositionManager internal pm;
    MockERC20 internal asset;
    MockERC20 internal coll;
    IERC20 internal quote;
    MockPersistenceRecord internal record;
    bytes32 internal mid;
    address internal constant LENDER = address(0xA11CE);
    address internal constant BORROWER = address(0xB0B);
    address internal constant PAYEE = address(0xCA401);
    uint256 internal constant COLL = 100_000e18;
    uint256 internal constant DRAW = 40_000e6;
    bytes4 internal constant CUSTODIAN_ERROR = bytes4(keccak256("ExitToCustodian()"));
    address internal constant BUYER = address(0xB1E4);
    uint256 internal constant TAKE = 1_000e18; // well inside the open loan's free collateral
    uint256 internal constant SPEND = 1_000e6; // a buy the settled pot can fill several times over

    /// @dev Every counter a live loan's collateral lives in, plus the three refused destinations' balances.
    struct CollateralSnap {
        uint256 loanUnits;
        uint256 custody;
        uint256 held;
        uint256 pmBalance;
        uint256 hubBalance;
        uint256 zeroBalance;
    }

    /// @dev Every counter an inventory sale moves, on both the goods and the money side.
    struct AskSnap {
        uint256 pot;
        uint256 retired;
        uint256 held;
        uint256 pmBalance;
        uint256 outflow;
        uint256 buyerCash;
        uint256 hubQuote;
        uint256 owed;
    }

    function setUp() public virtual {
        _boot();
    }

    function _boot() internal {
        _warpTo(1_000_000);
        asset = new MockERC20("Quote", "Q", 6);
        coll = new MockERC20("Collateral", "C", 18);
        (ace, pm) = AceFixtures.newAceWithEscrow(AceFixtures.TREASURY);
        read = new AceReader(address(ace));
        asset.mint(LENDER, 400_000e6);
        quote = IERC20(address(asset));
        MarketParams memory p = AceFixtures.marketParams(address(quote), address(coll));
        record = new MockPersistenceRecord(address(quote), address(coll));
        p.record = address(record);
        mid = ace.createMarket(p);
        vm.startPrank(LENDER);
        quote.approve(address(ace), type(uint256).max);
        ace.deposit(mid, 400_000e6);
        vm.stopPrank();
    }

    function _open() internal returns (uint256 id) {
        coll.mint(BORROWER, COLL);
        vm.startPrank(BORROWER);
        coll.approve(address(pm), COLL);
        id = ace.open(mid, COLL, DRAW, 0, BORROWER, OpenBounds(0, 0, 0));
        vm.stopPrank();
    }

    function _closed() internal returns (uint256 id) {
        id = _open();
        asset.mint(BORROWER, DRAW);
        vm.startPrank(BORROWER);
        asset.approve(address(ace), type(uint256).max);
        ace.repay(id, type(uint256).max);
        vm.stopPrank();
        (uint256 u, uint256 q) = ace.owedOf(id, BORROWER);
        assertEq(u, COLL, "fixture: collateral credit exists");
        assertGt(q, 0, "fixture: quote refund exists");
    }

    function _settled() internal returns (uint256 id) {
        id = _open();
        record.setBelow(true);
        ace.finalize(id);
        assertGt(read.invPotOf(mid, id), 0, "fixture: lender inventory exists");
    }

    function _refuseClaim(uint256 id, address toUnits, address toQuote, bytes4 errorSelector, bool single) internal {
        (uint256 u, uint256 q) = ace.owedOf(id, BORROWER);
        uint256 total = read.quoteOwedTotal(mid);
        uint256 hubQuote = quote.balanceOf(address(ace));
        uint256 custody = pm.retiredOf(id);
        uint256 held = coll.balanceOf(address(pm));
        vm.prank(BORROWER);
        vm.expectRevert(errorSelector);
        if (single) ace.claimOwed(id, toUnits);
        else ace.claimOwed(id, toUnits, toQuote);
        (uint256 uAfter, uint256 qAfter) = ace.owedOf(id, BORROWER);
        assertEq(uAfter, u, "units credit preserved");
        assertEq(qAfter, q, "quote credit preserved");
        assertEq(read.quoteOwedTotal(mid), total, "quote total preserved");
        assertEq(quote.balanceOf(address(ace)), hubQuote, "hub quote preserved");
        assertEq(pm.retiredOf(id), custody, "retired ledger preserved");
        assertEq(coll.balanceOf(address(pm)), held, "custody balance preserved");
        assertEq(coll.balanceOf(address(ace)), 0, "hub holds no collateral");
    }

    function test_SingleDestinationRefusesHubAndCustodian() public {
        uint256 id = _closed();
        _refuseClaim(id, address(ace), address(ace), ExitToHub.selector, true);
        _refuseClaim(id, address(pm), address(pm), CUSTODIAN_ERROR, true);
    }

    function test_SplitQuoteRefusesHubBeforeEitherLegMoves() public {
        uint256 id = _closed();
        vm.expectCall(address(pm), abi.encodeWithSelector(IPositionManager.releaseRetired.selector), 0);
        vm.expectCall(address(quote), abi.encodeWithSelector(IERC20.transfer.selector), 0);
        _refuseClaim(id, PAYEE, address(ace), ExitToHub.selector, false);
        _refuseClaim(id, address(0), address(ace), ExitToHub.selector, false);
    }

    function test_SplitCollateralRefusesHubAndCustodian() public {
        uint256 id = _closed();
        _refuseClaim(id, address(ace), PAYEE, ExitToHub.selector, false);
        _refuseClaim(id, address(pm), PAYEE, CUSTODIAN_ERROR, false);
    }

    function test_EmptyRequestedLegStillChecksRecipient() public {
        uint256 id = _closed();
        vm.prank(BORROWER);
        ace.claimOwed(id, PAYEE);
        _refuseClaim(id, address(ace), address(0), ExitToHub.selector, false);
        _refuseClaim(id, address(pm), address(0), CUSTODIAN_ERROR, false);
        _refuseClaim(id, address(0), address(ace), ExitToHub.selector, false);
    }

    function test_ZeroSkipsLegAndLaterPaysExactly() public {
        uint256 id = _closed();
        (, uint256 q) = ace.owedOf(id, BORROWER);
        uint256 total = read.quoteOwedTotal(mid);
        vm.prank(BORROWER);
        (uint256 u, uint256 paid) = ace.claimOwed(id, PAYEE, address(0));
        assertEq(u, COLL, "collateral delivered");
        assertEq(paid, 0, "quote skipped");
        assertEq(read.quoteOwedTotal(mid), total, "skipped aggregate preserved");
        uint256 cash = asset.balanceOf(PAYEE);
        vm.prank(BORROWER);
        (u, paid) = ace.claimOwed(id, address(0), PAYEE);
        assertEq(u, 0, "units skipped");
        assertEq(paid, q, "deferred quote delivered");
        assertEq(asset.balanceOf(PAYEE) - cash, q, "real cash reaches the recipient");
        assertEq(read.quoteOwedTotal(mid), total - q, "aggregate debited exactly");
        assertEq(coll.balanceOf(PAYEE), COLL, "collateral arrived exactly once");
    }

    function test_BothZeroRetainsNoClaimLegOnBothOverloads() public {
        uint256 id = _closed();
        _refuseClaim(id, address(0), address(0), NoClaimLeg.selector, false);
        _refuseClaim(id, address(0), address(0), NoClaimLeg.selector, true);
    }

    function test_SingleValidDestinationPaysBothCredits() public {
        uint256 id = _closed();
        (, uint256 q) = ace.owedOf(id, BORROWER);
        uint256 cash = asset.balanceOf(PAYEE);
        vm.prank(BORROWER);
        (uint256 units, uint256 paid) = ace.claimOwed(id, PAYEE);
        assertEq(units, COLL, "units delivered");
        assertEq(paid, q, "quote delivered");
        assertEq(asset.balanceOf(PAYEE) - cash, q, "cash delivered");
        assertEq(coll.balanceOf(PAYEE), COLL, "collateral delivered to third party");
    }

    function test_RedeemRefusesInvalidRecipientsAndPreservesInventory() public {
        uint256 id = _settled();
        uint256 pot = read.invPotOf(mid, id);
        uint256 custody = pm.retiredOf(id);
        vm.expectCall(address(pm), abi.encodeCall(IPositionManager.releaseRetired, (id, address(0), pot)), 0);
        vm.expectCall(address(pm), abi.encodeCall(IPositionManager.releaseRetired, (id, address(ace), pot)), 0);
        vm.expectCall(address(pm), abi.encodeCall(IPositionManager.releaseRetired, (id, address(pm), pot)), 0);
        vm.startPrank(LENDER);
        vm.expectRevert(ZeroWithdrawTo.selector);
        ace.redeemInKind(id, address(0));
        vm.expectRevert(ExitToHub.selector);
        ace.redeemInKind(id, address(ace));
        vm.expectRevert(CUSTODIAN_ERROR);
        ace.redeemInKind(id, address(pm));
        vm.stopPrank();
        assertEq(read.invPotOf(mid, id), pot, "inventory preserved");
        assertEq(pm.retiredOf(id), custody, "retired custody preserved");
        vm.prank(LENDER);
        assertEq(ace.redeemInKind(id, PAYEE), pot, "valid third-party redeem still takes entire pot");
        assertEq(coll.balanceOf(PAYEE), pot, "all inventory delivered");
    }

    function test_RedeemChecksAuthorityThenRecipientThenPot() public {
        uint256 id = _closed();
        vm.expectRevert(NotTheLender.selector);
        ace.redeemInKind(id, address(ace));
        vm.startPrank(LENDER);
        vm.expectRevert(ExitToHub.selector);
        ace.redeemInKind(id, address(ace));
        vm.expectRevert(EmptyPot.selector);
        ace.redeemInKind(id, PAYEE);
        vm.stopPrank();
    }

    function test_QuoteFirstSkipPreservesCollateralUntilLaterClaim() public {
        uint256 id = _closed();
        (, uint256 q) = ace.owedOf(id, BORROWER);
        uint256 custody = pm.retiredOf(id);
        uint256 held = pm.custodiedOf(address(coll));
        uint256 cash = asset.balanceOf(PAYEE);
        vm.prank(BORROWER);
        (uint256 units, uint256 paid) = ace.claimOwed(id, address(0), PAYEE);
        assertEq(units, 0, "nonempty collateral leg skipped");
        assertEq(paid, q, "quote paid first");
        assertEq(asset.balanceOf(PAYEE) - cash, q, "quote cash delivered");
        (uint256 owedUnits, uint256 owedQuote) = ace.owedOf(id, BORROWER);
        assertEq(owedUnits, COLL, "skipped collateral credit retained");
        assertEq(owedQuote, 0, "quote credit cleared");
        assertEq(pm.retiredOf(id), custody, "skipped retired ledger retained");
        assertEq(pm.custodiedOf(address(coll)), held, "skipped custody aggregate retained");
        vm.prank(BORROWER);
        (units, paid) = ace.claimOwed(id, PAYEE, address(0));
        assertEq(units, COLL, "deferred collateral delivered");
        assertEq(paid, 0, "quote skipped");
        assertEq(coll.balanceOf(PAYEE), COLL, "collateral reaches payee once");
        assertEq(pm.retiredOf(id), custody - COLL, "retired ledger debited exactly");
        assertEq(pm.custodiedOf(address(coll)), held - COLL, "custody aggregate debited exactly");
    }

    /// @notice One rule for every exit: the quote leg refuses the custodian exactly as the units leg does.
    /// @dev The `(PAYEE, pm)` row also proves the quote check lands before the units leg moves anything.
    function test_QuoteLegRefusesTheCustodianToo() public {
        uint256 id = _closed();
        (, uint256 q) = ace.owedOf(id, BORROWER);
        uint256 cash = asset.balanceOf(address(pm));
        vm.expectCall(address(pm), abi.encodeWithSelector(IPositionManager.releaseRetired.selector), 0);
        vm.expectCall(address(quote), abi.encodeWithSelector(IERC20.transfer.selector), 0);
        _refuseClaim(id, address(0), address(pm), ExitToCustodian.selector, false);
        _refuseClaim(id, PAYEE, address(pm), ExitToCustodian.selector, false);
        assertEq(asset.balanceOf(address(pm)), cash, "no quote cash reaches the custodian");
        assertEq(quote.balanceOf(address(pm)), 0, "nor any quote units");
        (uint256 owedUnits, uint256 owedQuote) = ace.owedOf(id, BORROWER);
        assertEq(owedUnits, COLL, "collateral still credited");
        assertEq(owedQuote, q, "quote credit retained");
    }

    function test_RedeemRefusalsPreserveEveryCustodyCounter() public {
        uint256 id = _settled();
        uint256 pot = read.invPotOf(mid, id);
        uint256 retired = pm.retiredOf(id);
        uint256 held = pm.custodiedOf(address(coll));
        uint256 balance = coll.balanceOf(address(pm));
        uint256 outflow = read.marketState(mid).netSyntheticOutflow;
        address[3] memory destinations = [address(0), address(ace), address(pm)];
        bytes4[3] memory errors = [ZeroWithdrawTo.selector, ExitToHub.selector, CUSTODIAN_ERROR];
        for (uint256 i; i < destinations.length; ++i) {
            vm.expectCall(address(pm), abi.encodeCall(IPositionManager.releaseRetired, (id, destinations[i], pot)), 0);
            vm.prank(LENDER);
            vm.expectRevert(errors[i]);
            ace.redeemInKind(id, destinations[i]);
            assertEq(read.invPotOf(mid, id), pot, "inventory retained");
            assertEq(pm.retiredOf(id), retired, "retired ledger retained");
            assertEq(pm.custodiedOf(address(coll)), held, "custody aggregate retained");
            assertEq(coll.balanceOf(address(pm)), balance, "custody token balance retained");
            assertEq(read.marketState(mid).netSyntheticOutflow, outflow, "synthetic outflow retained");
        }
        vm.prank(LENDER);
        uint256 paid = ace.redeemInKind(id, PAYEE);
        assertEq(paid, pot, "whole pot delivered");
        assertEq(read.invPotOf(mid, id), 0, "pot consumed once");
        assertEq(pm.retiredOf(id), retired - pot, "retired debit exact");
        assertEq(pm.custodiedOf(address(coll)), held - pot, "custody debit exact");
        assertEq(coll.balanceOf(address(pm)), balance - pot, "tokens leave custody");
        assertEq(coll.balanceOf(PAYEE), pot, "tokens reach payee");
        assertEq(read.marketState(mid).netSyntheticOutflow, outflow + pot, "synthetic outflow advances exactly");
    }

    /// @notice The event logs the units DELIVERED to `to`, never a burn: the field is the whole pot and the payee's gain.
    /// @dev Pins the #524 P10-F2 closure: the ladder-era verb logged burned class units, so a field going stale must go red here.
    function test_RedeemInKindLogsTheDeliveryNotABurn() public {
        uint256 id = _settled();
        uint256 pot = read.invPotOf(mid, id);
        uint256 before = coll.balanceOf(PAYEE);
        vm.expectEmit(true, true, false, true, address(ace));
        emit Lender.RedeemedInKind(id, LENDER, PAYEE, pot);
        vm.prank(LENDER);
        uint256 out = ace.redeemInKind(id, PAYEE);
        assertEq(out, pot, "the return is the whole pot");
        assertEq(coll.balanceOf(PAYEE) - before, pot, "and the logged units are exactly what reached `to`");
        assertEq(read.invPotOf(mid, id), 0, "nothing of the pot stays behind the log");
    }

    /* ---- withdrawCollateral: the borrower's own exit runs the same rule ---- */

    function _collateralSnap(uint256 id) internal view returns (CollateralSnap memory s) {
        s.loanUnits = read.loan(id).collateralUnits;
        s.custody = pm.collateralOf(id);
        s.held = pm.custodiedOf(address(coll));
        s.pmBalance = coll.balanceOf(address(pm));
        s.hubBalance = coll.balanceOf(address(ace));
        s.zeroBalance = coll.balanceOf(address(0));
    }

    function _assertCollateralUnmoved(uint256 id, CollateralSnap memory a) internal view {
        CollateralSnap memory b = _collateralSnap(id);
        assertEq(b.loanUnits, a.loanUnits, "loan collateral preserved");
        assertEq(b.custody, a.custody, "live custody ledger preserved");
        assertEq(b.held, a.held, "custody aggregate preserved");
        assertEq(b.pmBalance, a.pmBalance, "custody token balance preserved");
        assertEq(b.hubBalance, a.hubBalance, "hub received no collateral");
        assertEq(b.zeroBalance, a.zeroBalance, "nothing burned to zero");
    }

    /// @notice Zero, the hub and the custodian are each refused by name, and nothing moves.
    /// @dev The zero-count expectations prove the check lands before the release AND before the record is read.
    function test_WithdrawCollateralRefusesEveryBadRecipientAndMovesNothing() public {
        uint256 id = _open();
        vm.expectCall(address(pm), abi.encodeWithSelector(IPositionManager.release.selector), 0);
        vm.expectCall(address(record), abi.encodeWithSelector(IPersistenceRecord.minPrice.selector), 0);
        address[3] memory destinations = [address(0), address(ace), address(pm)];
        bytes4[3] memory errors = [ZeroWithdrawTo.selector, ExitToHub.selector, ExitToCustodian.selector];
        for (uint256 i; i < destinations.length; ++i) {
            CollateralSnap memory s = _collateralSnap(id);
            vm.prank(BORROWER);
            vm.expectRevert(errors[i]);
            ace.withdrawCollateral(id, TAKE, destinations[i]);
            _assertCollateralUnmoved(id, s);
        }
    }

    /// @notice The control: a third party the borrower names still receives the withdrawal.
    function test_WithdrawCollateralStillPaysAThirdParty() public {
        uint256 id = _open();
        uint256 held = pm.custodiedOf(address(coll));
        vm.prank(BORROWER);
        ace.withdrawCollateral(id, TAKE, PAYEE);
        assertEq(coll.balanceOf(PAYEE), TAKE, "third party receives the units");
        assertEq(read.loan(id).collateralUnits, COLL - TAKE, "loan debited exactly");
        assertEq(pm.collateralOf(id), COLL - TAKE, "custody debited exactly");
        assertEq(pm.custodiedOf(address(coll)), held - TAKE, "aggregate debited exactly");
    }

    /// @notice Authority first, then the recipient, then the amount and the clock.
    /// @dev Each hub row names a request some later rail would refuse; the recipient must answer first.
    function test_WithdrawCollateralChecksAuthorityThenRecipientThenAmountAndClock() public {
        uint256 id = _open();
        vm.expectCall(address(pm), abi.encodeWithSelector(IPositionManager.release.selector), 0);
        vm.expectRevert(NoMarket.selector);
        ace.withdrawCollateral(type(uint256).max, TAKE, address(ace));
        vm.prank(PAYEE);
        vm.expectRevert(NotBorrower.selector);
        ace.withdrawCollateral(id, TAKE, address(ace));
        vm.startPrank(BORROWER);
        vm.expectRevert(ExitToHub.selector);
        ace.withdrawCollateral(id, 0, address(ace));
        vm.expectRevert(ZeroWithdrawal.selector);
        ace.withdrawCollateral(id, 0, PAYEE);
        vm.expectRevert(ExitToHub.selector);
        ace.withdrawCollateral(id, COLL + 1, address(ace));
        vm.stopPrank();
        _warpTo(read.loan(id).expiry);
        vm.startPrank(BORROWER);
        vm.expectRevert(ExitToHub.selector);
        ace.withdrawCollateral(id, TAKE, address(ace));
        vm.expectRevert(LoanMatured.selector);
        ace.withdrawCollateral(id, TAKE, PAYEE);
        vm.stopPrank();
    }

    /// @notice A retired loan answers `LoanClosed` whatever the recipient: the loan's state precedes the argument.
    function test_WithdrawCollateralOnAClosedLoanIsLoanClosedWhateverTheRecipient() public {
        uint256 id = _closed();
        vm.prank(BORROWER);
        vm.expectRevert(LoanClosed.selector);
        ace.withdrawCollateral(id, 1, address(ace));
    }

    /* ---- buyInventory: the stranger's ask delivers to `unitsTo`, and the rule is the same ---- */

    function _fundBuyer() internal {
        asset.mint(BUYER, 10 * SPEND);
        vm.prank(BUYER);
        asset.approve(address(ace), type(uint256).max);
    }

    /// @dev Settled, the hold rested out, and a funded buyer: an ask that fills.
    function _askable() internal returns (uint256 id) {
        id = _settled();
        _warpTo(read.inventoryAskOpensAt(id));
        _fundBuyer();
    }

    function _askSnap(uint256 id) internal view returns (AskSnap memory s) {
        s.pot = read.invPotOf(mid, id);
        s.retired = pm.retiredOf(id);
        s.held = pm.custodiedOf(address(coll));
        s.pmBalance = coll.balanceOf(address(pm));
        s.outflow = read.marketState(mid).netSyntheticOutflow;
        s.buyerCash = asset.balanceOf(BUYER);
        s.hubQuote = quote.balanceOf(address(ace));
        s.owed = ace.lenderOwed(LENDER, address(quote));
    }

    function _assertAskUnmoved(uint256 id, AskSnap memory a) internal view {
        AskSnap memory b = _askSnap(id);
        assertEq(b.pot, a.pot, "inventory pot preserved");
        assertEq(b.retired, a.retired, "retired ledger preserved");
        assertEq(b.held, a.held, "custody aggregate preserved");
        assertEq(b.pmBalance, a.pmBalance, "custody token balance preserved");
        assertEq(b.outflow, a.outflow, "synthetic outflow preserved");
        assertEq(b.buyerCash, a.buyerCash, "buyer paid nothing");
        assertEq(b.hubQuote, a.hubQuote, "hub quote preserved");
        assertEq(b.owed, a.owed, "lender credit preserved");
        assertEq(coll.balanceOf(address(ace)), 0, "hub holds no collateral");
    }

    /// @notice Zero, the hub and the custodian are refused as `unitsTo`, and neither side of the sale moves.
    /// @dev The zero-count expectations prove the check lands before the release AND before the record is read.
    function test_BuyInventoryRefusesEveryBadUnitsToAndMovesNothing() public {
        uint256 id = _askable();
        vm.expectCall(address(pm), abi.encodeWithSelector(IPositionManager.releaseRetired.selector), 0);
        vm.expectCall(address(record), abi.encodeWithSelector(IPersistenceRecord.minPrice.selector), 0);
        address[3] memory destinations = [address(0), address(ace), address(pm)];
        bytes4[3] memory errors = [ZeroWithdrawTo.selector, ExitToHub.selector, ExitToCustodian.selector];
        for (uint256 i; i < destinations.length; ++i) {
            AskSnap memory s = _askSnap(id);
            vm.prank(BUYER);
            vm.expectRevert(errors[i]);
            ace.buyInventory(id, SPEND, 0, destinations[i]);
            _assertAskUnmoved(id, s);
        }
    }

    /// @notice The control: a third-party `unitsTo` still receives the units, paid for by the buyer.
    /// @dev Asserts the goods and the buyer's cash only; where the proceeds go next is not this suite's subject.
    function test_BuyInventoryStillDeliversToAThirdParty() public {
        uint256 id = _askable();
        AskSnap memory s = _askSnap(id);
        vm.prank(BUYER);
        (uint256 unitsOut, uint256 filled) = ace.buyInventory(id, SPEND, 1, PAYEE);
        assertGt(unitsOut, 0, "the ask filled");
        assertGt(filled, 0, "and charged");
        assertEq(coll.balanceOf(PAYEE), unitsOut, "units reach the named third party");
        assertEq(read.invPotOf(mid, id), s.pot - unitsOut, "pot debited exactly");
        assertEq(pm.retiredOf(id), s.retired - unitsOut, "retired ledger debited exactly");
        assertEq(asset.balanceOf(BUYER), s.buyerCash - filled, "buyer paid exactly the fill");
    }

    /// @notice `unitsTo` is checked before the hold, and on a zero fill too.
    /// @dev The control inside the hold shows the hub row is not the hold speaking under another name.
    function test_BuyInventoryChecksUnitsToBeforeTheHoldAndOnAZeroFill() public {
        uint256 id = _settled();
        _fundBuyer();
        vm.expectCall(address(pm), abi.encodeWithSelector(IPositionManager.releaseRetired.selector), 0);
        vm.expectCall(address(record), abi.encodeWithSelector(IPersistenceRecord.minPrice.selector), 0);
        AskSnap memory s = _askSnap(id);
        vm.startPrank(BUYER);
        vm.expectRevert(ExitToHub.selector);
        ace.buyInventory(id, SPEND, 0, address(ace));
        vm.expectRevert(InventoryHeld.selector);
        ace.buyInventory(id, SPEND, 0, PAYEE);
        vm.stopPrank();
        _warpTo(read.inventoryAskOpensAt(id));
        vm.prank(BUYER);
        vm.expectRevert(ExitToHub.selector);
        ace.buyInventory(id, 0, 0, address(ace));
        _assertAskUnmoved(id, s);
    }

    /// @notice The zero-fill control: with a valid `unitsTo` an empty ask is still a silent no-op.
    function test_BuyInventoryZeroFillToAThirdPartyStillMovesNothing() public {
        uint256 id = _askable();
        AskSnap memory s = _askSnap(id);
        vm.prank(BUYER);
        (uint256 unitsOut, uint256 filled) = ace.buyInventory(id, 0, 0, PAYEE);
        assertEq(unitsOut, 0, "nothing delivered");
        assertEq(filled, 0, "nothing charged");
        _assertAskUnmoved(id, s);
    }

    /* ---- claimOwed: the units recipient is refused before the units leg can move ---- */

    /// @notice Every refused units recipient, on both forms, answers before `releaseRetired` is ever reached.
    /// @dev The zero-count expectation is what sees an attempted release; a reverted call's preserved state cannot.
    function test_ClaimChecksTheUnitsRecipientBeforeTheUnitsLegMoves() public {
        uint256 id = _closed();
        vm.expectCall(address(pm), abi.encodeWithSelector(IPositionManager.releaseRetired.selector), 0);
        _refuseClaim(id, address(0), address(0), NoClaimLeg.selector, true);
        _refuseClaim(id, address(ace), address(ace), ExitToHub.selector, true);
        _refuseClaim(id, address(pm), address(pm), ExitToCustodian.selector, true);
        _refuseClaim(id, address(ace), PAYEE, ExitToHub.selector, false);
        _refuseClaim(id, address(pm), PAYEE, ExitToCustodian.selector, false);
        _refuseClaim(id, address(ace), address(0), ExitToHub.selector, false);
        _refuseClaim(id, address(pm), address(0), ExitToCustodian.selector, false);
    }

    /* ---- withdraw and collect: the quote exits run the same rule, the custodian included ---- */

    /// @dev A live loan partly repaid: the repayment credits the lender's pool, and no close pushes it home.
    function _owedToLender() internal returns (uint256 owed) {
        uint256 id = _open();
        asset.mint(BORROWER, SPEND);
        vm.startPrank(BORROWER);
        asset.approve(address(ace), type(uint256).max);
        ace.repay(id, SPEND);
        vm.stopPrank();
        owed = ace.lenderOwed(LENDER, address(quote));
        assertGt(owed, 0, "fixture: the lender's pool holds credit");
    }

    /// @notice Zero, the hub and the custodian are each refused by name on `withdraw`, and no cash moves.
    function test_WithdrawRefusesEveryBadRecipientAndMovesNothing() public {
        address[3] memory destinations = [address(0), address(ace), address(pm)];
        bytes4[3] memory errors = [ZeroWithdrawTo.selector, ExitToHub.selector, ExitToCustodian.selector];
        uint256 resting = ace.restingOf(mid);
        uint256 hubQuote = quote.balanceOf(address(ace));
        uint256 pmCash = asset.balanceOf(address(pm));
        vm.expectCall(address(quote), abi.encodeWithSelector(IERC20.transfer.selector), 0);
        for (uint256 i; i < destinations.length; ++i) {
            vm.prank(LENDER);
            vm.expectRevert(errors[i]);
            ace.withdraw(mid, SPEND, destinations[i], 0);
            assertEq(ace.restingOf(mid), resting, "resting cash preserved");
            assertEq(quote.balanceOf(address(ace)), hubQuote, "hub quote preserved");
            assertEq(asset.balanceOf(address(pm)), pmCash, "no cash reached the custodian");
            assertEq(quote.balanceOf(address(pm)), 0, "nor any quote units");
        }
    }

    /// @notice The control: `withdraw` still pays a third party the lender names.
    function test_WithdrawStillPaysAThirdParty() public {
        uint256 resting = ace.restingOf(mid);
        vm.prank(LENDER);
        assertEq(ace.withdraw(mid, SPEND, PAYEE, SPEND), SPEND, "the whole ask is paid");
        assertEq(asset.balanceOf(PAYEE), SPEND, "and reaches the named third party as cash");
        assertEq(ace.restingOf(mid), resting - SPEND, "resting cash debited exactly");
    }

    /// @notice Zero, the hub and the custodian are each refused by name on `collect`, and the pool keeps its credit.
    function test_CollectRefusesEveryBadRecipientAndKeepsThePool() public {
        uint256 owed = _owedToLender();
        address[3] memory destinations = [address(0), address(ace), address(pm)];
        bytes4[3] memory errors = [ZeroWithdrawTo.selector, ExitToHub.selector, ExitToCustodian.selector];
        uint256 hubQuote = quote.balanceOf(address(ace));
        uint256 pmCash = asset.balanceOf(address(pm));
        for (uint256 i; i < destinations.length; ++i) {
            vm.expectCall(address(quote), abi.encodeCall(IERC20.transfer, (destinations[i], owed)), 0);
            vm.prank(LENDER);
            vm.expectRevert(errors[i]);
            ace.collect(address(quote), destinations[i]);
            assertEq(ace.lenderOwed(LENDER, address(quote)), owed, "pool credit preserved");
            assertEq(quote.balanceOf(address(ace)), hubQuote, "hub quote preserved");
            assertEq(asset.balanceOf(address(pm)), pmCash, "no cash reached the custodian");
            assertEq(quote.balanceOf(address(pm)), 0, "nor any quote units");
        }
        vm.prank(LENDER);
        assertEq(ace.collect(address(quote), PAYEE), owed, "control: a third party still takes the whole pool");
        assertEq(asset.balanceOf(PAYEE), owed, "as cash");
    }

    /// @notice An empty pool refuses the custodian too: the rule runs before the empty-pool return.
    function test_CollectRefusesTheCustodianWithNothingOwed() public {
        assertEq(ace.lenderOwed(LENDER, address(quote)), 0, "fixture: nothing is owed");
        vm.prank(LENDER);
        vm.expectRevert(ExitToCustodian.selector);
        ace.collect(address(quote), address(pm));
    }
}

/// @notice `refinanceTo`'s withdrawal leg runs the one recipient rule at the top of the shared migration body.
/// @notice Any units, or any named recipient, is checked; zero units and no recipient stay a plain refinance.
contract AceRefinanceWithdrawRecipientRailsTest is AceRefinanceWithdrawFixture {
    uint256 internal constant COLL_R = 12_000e18;
    uint256 internal constant TAKE_R = 1_000e18;
    address internal stranger = address(0x57A1);

    /// @dev The retiring loan, its custody, the id counter, and every balance a refused roll could have touched.
    struct RollSnap {
        uint256 units;
        uint256 custody;
        uint256 debt;
        uint256 count;
        uint256 hubQuote;
        uint256 pmBalance;
        uint256 hubUnits;
        uint256 zeroUnits;
        uint256 sinkUnits;
    }

    function setUp() public {
        _boot();
    }

    function _rollSnap(uint256 id) internal view returns (RollSnap memory s) {
        s.units = read.loan(id).collateralUnits;
        s.custody = pm.collateralOf(id);
        s.debt = read.loan(id).debt;
        s.count = read.loanCount();
        s.hubQuote = usdc.balanceOf(address(ace));
        s.pmBalance = vault.balanceOf(address(pm));
        s.hubUnits = vault.balanceOf(address(ace));
        s.zeroUnits = vault.balanceOf(address(0));
        s.sinkUnits = vault.balanceOf(sink);
    }

    function _assertRollUnmoved(uint256 id, RollSnap memory a) internal view {
        RollSnap memory b = _rollSnap(id);
        assertEq(b.units, a.units, "old loan keeps its lot");
        assertEq(b.custody, a.custody, "and its custody");
        assertEq(b.debt, a.debt, "and its debt");
        assertEq(b.count, a.count, "no successor id was allocated");
        assertEq(b.hubQuote, a.hubQuote, "no quote moved");
        assertEq(b.pmBalance, a.pmBalance, "custody token balance preserved");
        assertEq(b.hubUnits, a.hubUnits, "hub received no collateral");
        assertEq(b.zeroUnits, a.zeroUnits, "nothing burned to zero");
        assertEq(b.sinkUnits, a.sinkUnits, "no release reached anyone");
        assertTrue(read.loan(id).closedAt == 0, "the old loan was not retired");
    }

    function _otherCollateralMarket() internal returns (bytes32) {
        MockStakeVault other = new MockStakeVault(43);
        MarketParams memory p = AceFixtures.marketParams(address(usdc), address(other));
        p.record = address(new MockPersistenceRecord(address(usdc), address(other)));
        return ace.createMarket(p);
    }

    function _otherQuoteMarket() internal returns (bytes32) {
        MockERC20 other = new MockERC20("Other", "O", 6);
        MarketParams memory p = AceFixtures.marketParams(address(other), address(vault));
        p.record = address(new MockPersistenceRecord(address(other), address(vault)));
        return ace.createMarket(p);
    }

    /// @notice Zero, the hub and the custodian are each refused by name, and the whole roll stays unwritten.
    /// @dev The zero-count carry proves the check precedes the close, not merely the release.
    function test_RefinanceToRefusesEveryBadWithdrawToAndMovesNothing() public {
        uint256 oldId = _open(flat, COLL_R, P);
        vm.expectCall(address(pm), abi.encodeWithSelector(IPositionManager.carryOut.selector), 0);
        vm.expectCall(address(pm), abi.encodeWithSelector(IPositionManager.release.selector), 0);
        address[3] memory destinations = [address(0), address(ace), address(pm)];
        bytes4[3] memory errors = [ZeroWithdrawTo.selector, ExitToHub.selector, ExitToCustodian.selector];
        for (uint256 i; i < destinations.length; ++i) {
            RollSnap memory s = _rollSnap(oldId);
            _refuses(_args(oldId, flat, NEWP, TAKE_R, destinations[i]), errors[i], "a bad withdrawal recipient is refused by name");
            _assertRollUnmoved(oldId, s);
        }
    }

    /// @notice The control: a third party the borrower names still receives the withdrawal.
    function test_RefinanceToStillPaysAThirdParty() public {
        uint256 oldId = _open(flat, COLL_R, P);
        uint256 newId = _migrate(_args(oldId, flat, NEWP, TAKE_R, sink));
        assertEq(vault.balanceOf(sink), TAKE_R, "third party receives the units");
        assertEq(read.loan(newId).collateralUnits, COLL_R - TAKE_R, "successor debited exactly");
        assertEq(pm.collateralOf(newId), COLL_R - TAKE_R, "custody debited exactly");
    }

    /// @notice Authority is asked before the recipient.
    function test_RefinanceToAStrangerIsNotBorrowerWhateverTheRecipient() public {
        uint256 oldId = _open(flat, COLL_R, P);
        vm.prank(stranger);
        vm.expectRevert(NotBorrower.selector);
        fin.refinanceTo(_args(oldId, flat, NEWP, TAKE_R, address(ace)));
    }

    /// @notice The recipient is refused before either pair rail compares the two markets.
    /// @dev The controls name the rails a valid recipient meets, so the hub rows are not those rails in disguise.
    function test_RefinanceToRecipientPrecedesThePairRails() public {
        uint256 oldId = _open(flat, COLL_R, P);
        bytes32 otherColl = _otherCollateralMarket();
        bytes32 otherQuote = _otherQuoteMarket();
        RollSnap memory s = _rollSnap(oldId);
        vm.expectCall(address(pm), abi.encodeWithSelector(IPositionManager.carryOut.selector), 0);
        _refuses(_args(oldId, otherColl, NEWP, TAKE_R, address(ace)), ExitToHub.selector, "the hub before the collateral rail");
        _refuses(_args(oldId, otherQuote, NEWP, TAKE_R, address(pm)), ExitToCustodian.selector, "the custodian before the quote rail");
        _refuses(_args(oldId, otherColl, NEWP, TAKE_R, sink), MarketPairMismatch.selector, "control: the collateral rail");
        _refuses(_args(oldId, otherQuote, NEWP, TAKE_R, sink), QuoteMismatch.selector, "control: the quote rail");
        _assertRollUnmoved(oldId, s);
    }

    /// @notice The recipient is refused before the draw can refuse, so no close, melt or open is ever written.
    function test_RefinanceToRecipientPrecedesTheDrawRails() public {
        uint256 oldId = _open(flat, COLL_R, P);
        RollSnap memory s = _rollSnap(oldId);
        vm.expectCall(address(pm), abi.encodeWithSelector(IPositionManager.carryOut.selector), 0);
        vm.expectCall(address(pm), abi.encodeWithSelector(IPositionManager.release.selector), 0);
        _refuses(_args(oldId, flat, P / 2, TAKE_R, address(ace)), ExitToHub.selector, "the hub before a draw that cannot retire the debt");
        _refuses(_args(oldId, flat, 1, TAKE_R, address(0)), ZeroWithdrawTo.selector, "zero before a draw under minDebt");
        _refuses(_args(oldId, flat, 1, TAKE_R, address(pm)), ExitToCustodian.selector, "the custodian before a draw under minDebt");
        _assertRollUnmoved(oldId, s);
    }

    /// @notice The controls for the draw rows: with a valid recipient each draw fails for its own reason.
    function test_RefinanceToDrawRailsStillSpeakForAValidRecipient() public {
        uint256 oldId = _open(flat, COLL_R, P);
        _refuses(_args(oldId, flat, P / 2, TAKE_R, sink), DrawBelowDebt.selector, "control: the netting refuses a short draw");
        _refuses(_args(oldId, flat, 1, TAKE_R, sink), BelowMinDebt.selector, "control: the open refuses a dust draw");
    }

    /// @notice A NAMED recipient is checked even with zero units: naming the hub or the custodian is refused.
    function test_RefinanceToANamedRecipientIsCheckedEvenWithZeroUnits() public {
        uint256 oldId = _open(flat, COLL_R, P);
        RollSnap memory s = _rollSnap(oldId);
        vm.expectCall(address(pm), abi.encodeWithSelector(IPositionManager.carryOut.selector), 0);
        _refuses(_args(oldId, flat, NEWP, 0, address(ace)), ExitToHub.selector, "the hub is refused with no units");
        _refuses(_args(oldId, flat, NEWP, 0, address(pm)), ExitToCustodian.selector, "the custodian is refused with no units");
        _assertRollUnmoved(oldId, s);
    }

    /// @notice Zero units and no recipient is a plain refinance, and releases nothing.
    function test_RefinanceToZeroUnitsAndNoRecipientIsAPlainRefinance() public {
        uint256 oldId = _open(flat, COLL_R, P);
        vm.expectCall(address(pm), abi.encodeWithSelector(IPositionManager.release.selector), 0);
        uint256 newId = _migrate(_args(oldId, flat, NEWP, 0, address(0)));
        assertTrue(read.loan(oldId).closedAt != 0, "the old loan retired");
        assertEq(read.loan(newId).collateralUnits, COLL_R, "the whole lot carried across");
        assertEq(pm.collateralOf(newId), COLL_R, "and custody agrees");
    }

    /// @notice Zero units to a valid third party is admitted, and that party receives nothing.
    function test_RefinanceToZeroUnitsToAValidThirdPartyIsAdmittedAndReleasesNothing() public {
        uint256 oldId = _open(flat, COLL_R, P);
        vm.expectCall(address(pm), abi.encodeWithSelector(IPositionManager.release.selector), 0);
        uint256 newId = _migrate(_args(oldId, flat, NEWP, 0, sink));
        assertEq(read.loan(newId).collateralUnits, COLL_R, "the whole lot carried across");
        assertEq(pm.collateralOf(newId), COLL_R, "and custody agrees");
        assertEq(vault.balanceOf(sink), 0, "a named recipient with nothing to take receives nothing");
    }
}

/// @notice `closeOrder` runs the one recipient rule after the maker check, and a spent escrow makes no transfer.
contract AceOrderCloseRecipientRailsTest is AceOrderFixture {
    /// @dev The order record, its custody, and every balance a refused close could have touched.
    struct OrderSnap {
        uint256 units;
        uint256 principal;
        bool closed;
        uint256 custody;
        uint256 held;
        uint256 pmBalance;
        uint256 hubBalance;
        uint256 zeroBalance;
    }

    function _orderSnap(uint256 orderId) internal view returns (OrderSnap memory s) {
        Order memory o = ace.orderOf(orderId);
        (s.units, s.principal, s.closed) = (o.collateralUnits, o.principal, o.closed);
        s.custody = pm.collateralOf(orderId);
        s.held = pm.custodiedOf(address(vault));
        s.pmBalance = vault.balanceOf(address(pm));
        s.hubBalance = vault.balanceOf(address(ace));
        s.zeroBalance = vault.balanceOf(address(0));
    }

    function _assertOrderUnmoved(uint256 orderId, OrderSnap memory a) internal view {
        OrderSnap memory b = _orderSnap(orderId);
        assertEq(b.units, a.units, "escrow record preserved");
        assertEq(b.principal, a.principal, "principal preserved");
        assertEq(b.closed, a.closed, "open state preserved");
        assertEq(b.custody, a.custody, "order custody preserved");
        assertEq(b.held, a.held, "custody aggregate preserved");
        assertEq(b.pmBalance, a.pmBalance, "custody token balance preserved");
        assertEq(b.hubBalance, a.hubBalance, "hub received no collateral");
        assertEq(b.zeroBalance, a.zeroBalance, "nothing burned to zero");
    }

    /// @notice Zero, the hub and the custodian are each refused by name, and the order stays open and whole.
    function test_CloseOrderRefusesEveryBadRecipientAndMovesNothing() public {
        uint256 orderId = _postDefault();
        vm.expectCall(address(pm), abi.encodeWithSelector(IPositionManager.release.selector), 0);
        address[3] memory destinations = [address(0), address(ace), address(pm)];
        bytes4[3] memory errors = [ZeroWithdrawTo.selector, ExitToHub.selector, ExitToCustodian.selector];
        for (uint256 i; i < destinations.length; ++i) {
            OrderSnap memory s = _orderSnap(orderId);
            vm.prank(maker);
            vm.expectRevert(errors[i]);
            ace.closeOrder(orderId, destinations[i]);
            _assertOrderUnmoved(orderId, s);
        }
    }

    /// @notice The control: a third party the maker names still receives the escrow.
    function test_CloseOrderStillPaysAThirdParty() public {
        uint256 orderId = _postDefault();
        uint256 units = ace.orderOf(orderId).collateralUnits;
        vm.prank(maker);
        assertEq(ace.closeOrder(orderId, rescue), units, "the whole escrow is returned");
        assertEq(vault.balanceOf(rescue), units, "and reaches the named third party");
        assertEq(pm.collateralOf(orderId), 0, "custody debited exactly");
    }

    /// @notice The maker first, then the recipient, then the closed flag.
    /// @dev The control names the refusal a valid recipient meets, so the hub row is not `OrderClosed` in disguise.
    function test_CloseOrderChecksMakerThenRecipientThenClosed() public {
        uint256 orderId = _postDefault();
        vm.prank(stranger);
        vm.expectRevert(NotMaker.selector);
        ace.closeOrder(orderId, address(ace));
        vm.prank(maker);
        ace.closeOrder(orderId, maker);
        vm.expectCall(address(pm), abi.encodeWithSelector(IPositionManager.release.selector), 0);
        vm.startPrank(maker);
        vm.expectRevert(ExitToHub.selector);
        ace.closeOrder(orderId, address(ace));
        vm.expectRevert(OrderClosed.selector);
        ace.closeOrder(orderId, maker);
        vm.stopPrank();
    }

    /// @notice The rule is unconditional: a spent escrow still refuses the hub.
    function test_CloseOrderOnAFullyFilledOrderStillRefusesTheHub() public {
        uint256 orderId = _postDefault();
        Order memory o = ace.orderOf(orderId);
        _fill(orderId, o.principal, o.collateralUnits);
        OrderSnap memory s = _orderSnap(orderId);
        vm.prank(maker);
        vm.expectRevert(ExitToHub.selector);
        ace.closeOrder(orderId, address(ace));
        _assertOrderUnmoved(orderId, s);
    }

    /// @notice A fully filled order closes with no release at all, and every other effect of the close still lands.
    function test_CloseOrderOnAFullyFilledOrderMakesNoTransfer() public {
        uint256 orderId = _postDefault();
        Order memory o = ace.orderOf(orderId);
        _fill(orderId, o.principal, o.collateralUnits);
        assertEq(ace.orderOf(orderId).collateralUnits, 0, "fixture: the fill spent the whole escrow");
        vm.expectCall(address(pm), abi.encodeWithSelector(IPositionManager.release.selector), 0);
        vm.expectEmit(address(ace));
        emit Orders.OrderRetired(orderId, maker, 0);
        vm.prank(maker);
        uint256 units = ace.closeOrder(orderId, maker);
        assertEq(units, 0, "nothing was left to return");
        assertTrue(ace.orderOf(orderId).closed, "the order is still marked closed");
        assertEq(ace.orderOf(orderId).principal, 0, "and its principal zeroed");
    }

    /// @notice A collateral that refuses zero-value transfers cannot block the close of a spent order.
    function test_CloseOrderOnAFullyFilledOrderSurvivesACollateralRefusingZeroTransfers() public {
        MockZeroRefusingERC20 z = new MockZeroRefusingERC20();
        bytes32 zid = ace.createMarket(AceFixtures.marketParams(address(usdc), address(z)));
        usdc.mint(lender, LADDER);
        vm.startPrank(lender);
        usdc.approve(address(ace), LADDER);
        ace.deposit(zid, LADDER);
        vm.stopPrank();
        z.mint(maker, 1e36);
        uint256 low = AceFixtures.px(0.5e18, address(usdc), address(z));
        uint256 high = AceFixtures.px(0.6e18, address(usdc), address(z));
        vm.startPrank(maker);
        z.approve(address(pm), type(uint256).max);
        uint256 orderId = ace.postOrder(zid, P, low, high, MINFILL, TEN, _far());
        vm.stopPrank();
        Order memory o = ace.orderOf(orderId);
        _fill(orderId, o.principal, o.collateralUnits);
        assertEq(ace.orderOf(orderId).collateralUnits, 0, "fixture: the fill spent the whole escrow");
        vm.prank(maker);
        uint256 units = ace.closeOrder(orderId, maker);
        assertEq(units, 0, "nothing was left to return");
        assertTrue(ace.orderOf(orderId).closed, "and the close landed");
    }
}
