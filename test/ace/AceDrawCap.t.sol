// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.36;

import {Test} from "forge-std/Test.sol";
import {TickMath} from "@uniswap/v4-core/src/libraries/TickMath.sol";
import {Ace} from "../../src/ace/hub/Ace.sol";
import {Constants} from "../../src/ace/hub/Constants.sol";
import {MarketParams, OpenBounds} from "../../src/ace/hub/Types.sol";
import {NoRecordPrice} from "../../src/ace/hub/Borrower.sol";
import {InsufficientCash} from "../../src/ace/hub/Borrower.sol";
import {AceLens} from "../../src/ace/lens/AceLens.sol";
import {PositionManager} from "../../src/ace/positions/PositionManager.sol";
import {PriceFrame} from "../utils/PriceFrame.sol";
import {ProtocolPolicy} from "../../src/config/Defaults.sol";
import {MockERC20} from "../mocks/MockERC20.sol";
import {MockPersistenceRecord} from "../mocks/MockPersistenceRecord.sol";
import {MockStakeVault} from "../mocks/MockStakeVault.sol";
import {AceFixtures} from "../utils/AceFixtures.sol";
import {AceReader} from "../utils/AceReader.sol";

/// @title AceDrawCap
/// @notice The draw-time inert cap: a market priced ABOVE the windowed price funds no loan.
/// @notice Its cash stays fully withdrawable, because the cap gates borrowing and nothing else.
/// @dev The cap is DERIVED from the record via `Borrower.persistedPrice`, never passed in explicitly.
/// @dev THREE MARKETS, one per side of the cap: it used to sort the ticks inside one market's ladder.
contract AceDrawCapTest is Test {
    Ace internal ace;
    AceReader internal read;
    PositionManager internal positionManager;
    MockERC20 internal usdc;
    MockStakeVault internal vault;
    MockPersistenceRecord internal record;
    bytes32 internal id;

    address internal alice = address(0xA11CE);
    address internal bob = address(0xB0B2);
    address internal borrower = address(0xB0110);
    address internal keeper = address(0xCAFE);

    uint256 internal T1; // ~0.95 of par, below the cap; assigned in setUp, since par is not a compile-time value
    uint256 internal T2; // par itself, the cap price
    uint256 internal T4; // ~1.10 of par, above the cap

    bytes32 internal idLow; // the market bidding at T1
    bytes32 internal idHigh; // the market bidding at T4

    uint256 internal constant COLL = 200_000e18;
    uint64 internal constant TENOR = ProtocolPolicy.MIN_TENOR;

    /// @dev This suite's pair, so a price reads as its distance from par rather than as an absolute.
    /// @param offset Steps above par.
    /// @return The price in the hub's frame.
    function _price(int24 offset) internal view returns (uint256) {
        return AceFixtures.priceAt(address(usdc), address(vault), offset);
    }

    function setUp() public {
        vm.warp(1_000_000);
        usdc = new MockERC20("USD Coin", "USDC", 6);
        vault = new MockStakeVault(42);
        (T1, T2, T4) = (_price(-540), _price(0), _price(960));
        record = new MockPersistenceRecord(address(usdc), address(vault));

        MarketParams memory p = AceFixtures.marketParams(address(usdc), address(vault));
        p.record = address(record);
        p.baseBps = 1;
        p.price = T2;
        AceFixtures.Deployment memory d = AceFixtures.deploy(p);
        (ace, positionManager, read, id) = (d.ace, d.positionManager, d.read, d.id);
        /// @dev THREE MARKETS ON ONE PAIR, one per side of the cap. The cap used to sort the TICKS inside a
        /// @dev single market's ladder; a market carries one price, so the sorting it does now is over markets.
        p.price = T1;
        idLow = ace.createMarket(p);
        p.price = T4;
        idHigh = ace.createMarket(p);
        record.setAbove(true); // healthy, so no distress gate interferes with a draw-cap assertion
    }

    // ---- helpers ----

    /// @dev THE CAP: `persistedPrice` reads the record's windowed min, so this sets the draw's ceiling.
    /// @dev The three markets share one record, so a single call caps all of them at once.
    function _cap(uint256 price) internal {
        record.setMinPrice(price);
    }

    function _deposit(address who, bytes32 mid, uint256 amt) internal {
        usdc.mint(who, amt);
        vm.startPrank(who);
        usdc.approve(address(ace), amt);
        ace.deposit(mid, amt);
        vm.stopPrank();
    }

    function _open(bytes32 mid, uint256 principal) internal returns (uint256 loanId) {
        vault.mint(borrower, COLL);
        usdc.mint(borrower, 1e6);
        vm.startPrank(borrower);
        vault.approve(address(positionManager), COLL);
        usdc.approve(address(ace), 1e6);
        loanId = ace.open(mid, COLL, principal, 0, borrower, OpenBounds(0, 0, 0));
        vm.stopPrank();
    }

    /// @dev Collateral the borrower needs on hand before a refusal probe, so the revert is the cap's and not custody's.
    function _armBorrower() internal {
        vault.mint(borrower, COLL);
        vm.prank(borrower);
        vault.approve(address(positionManager), COLL);
    }

    // ============ the draw ============

    /// @notice A market priced ABOVE the cap funds nothing, however much cash rests in it.
    /// @dev WAS "the draw skips an above-cap tick and funds from the one below". Both halves are here still,
    /// @dev one market each: the refusal below, and the at-cap market funding in the row after it.
    function test_Draw_RefusesAnAboveCapMarket() public {
        _deposit(alice, idHigh, 1000e6);
        _cap(T2); // below the high market's own price

        _armBorrower();
        vm.prank(borrower);
        vm.expectRevert(InsufficientCash.selector); // refuses exactly as an empty market would
        ace.open(idHigh, COLL, 100e6, 0, borrower, OpenBounds(0, 0, 0));
    }

    /// @notice The market sitting exactly AT the cap funds, and its own price is the loan's floor.
    /// @dev Equality is admitted: the cap is a price a verb may act AT or below.
    function test_Draw_FundsTheAtCapMarket() public {
        _deposit(alice, id, 1000e6);
        _cap(T2);

        uint256 loanId = _open(id, 500e6);

        assertEq(read.claimOf(id, loanId), 500e6, "the at-cap market funded the whole draw");
        assertEq(read.fundingFloor(id, loanId), T2, "and the floor is the market's own price");
    }

    /// @notice A market well BELOW the cap funds too, at its own price rather than at the cap.
    /// @dev The cap is a ceiling, never an anchor: nothing re-prices a market up to it.
    function test_Draw_BelowTheCapFundsAtItsOwnPrice() public {
        _deposit(alice, idLow, 1000e6);
        _cap(T2);

        uint256 loanId = _open(idLow, 500e6);

        assertEq(read.claimOf(idLow, loanId), 500e6, "the below-cap market funded the whole draw");
        assertEq(read.fundingFloor(idLow, loanId), T1, "at T1, not lifted to the cap");
    }

    /// @notice A zero cap is the bootstrap fail-closed sentinel, and the RECORD is what it names.
    function test_Draw_CapZeroFailsClosed() public {
        _deposit(alice, id, 1000e6);
        _cap(0);

        _armBorrower();
        vm.prank(borrower);
        vm.expectRevert(NoRecordPrice.selector); // the record cannot price, and the cap test is never reached
        ace.open(id, COLL, 100e6, 0, borrower, OpenBounds(0, 0, 0));
    }

    /// @notice DOCTRINE: caps gate borrowing only. Above-cap cash is inert to draws and still exits whole.
    function test_AboveCapCash_IsInertToDrawsYetFullyWithdrawable() public {
        _deposit(alice, idHigh, 1000e6);
        _cap(T2);

        _armBorrower();
        vm.prank(borrower);
        vm.expectRevert(InsufficientCash.selector);
        ace.open(idHigh, COLL, 100e6, 0, borrower, OpenBounds(0, 0, 0));

        vm.prank(alice);
        uint256 out = ace.withdraw(idHigh, type(uint256).max, alice, 0);
        assertEq(out, 1000e6, "inert above-cap cash withdraws in full");
    }

    /// @notice The QUOTE refuses the same above-cap market the draw refuses, on the same selector.
    /// @dev And on the at-cap market it names the floor a real `open` then stores, so quote is bound to execution.
    function test_Quote_RefusesTheSameAboveCapMarketTheDrawRefuses() public {
        _deposit(alice, idHigh, 1000e6);
        _deposit(alice, id, 1000e6);
        _cap(T2);

        vm.expectRevert(InsufficientCash.selector);
        ace.previewOpen(idHigh, COLL, 500e6, TENOR, borrower, OpenBounds(0, 0, 0));

        uint256 quoted = ace.previewOpen(id, COLL, 500e6, TENOR, borrower, OpenBounds(0, 0, 0)).postDrawFloor;
        assertEq(quoted, T2, "the quote floors at the at-cap market's own price");
        assertEq(read.fundingFloor(id, _open(id, 500e6)), quoted, "and the draw stores exactly that");
    }

    /// @notice THE `MIN_TICK` CORNER IS GONE, and so is the corner: there is no anchor and no grid to align.
    /// @notice It asked whether any admissible spacing could align the tick whose price floors to zero, so that
    /// @notice a lender could rest cash somewhere a division would later blow up. Proven by exhaustion: none could.
    /// @notice THE PROPERTY IT PROTECTED SURVIVES WHOLE and is stronger for being asked once instead of per deposit:
    /// @notice a market's price cannot be zero, because genesis refuses it. `AcePriceRail` is where that now lives.
    /// @notice What is gone is the SEARCH -- the corner existed because a lender picked a coordinate each time.

    /// @dev THE ROTATION SECTION IS DELETED with the rotation subsystem it drove.
    /// @dev It held `test_Backfill_SkipsAboveCapCash` and `test_Backfill_RotatesWhenUncapped`.
    /// @dev Both asked whether a BACKFILL respects the draw cap; there is no backfill any more.
    /// @dev The cap's own guard survives untouched above, on the draw walk, which is its only reader.
}

/// @title AceNoRecordPriceFailClosed
/// @notice A record answering 0 fail-closes the draw AND the quote, in lockstep; lenders come and go.
/// @dev REBUILT from AceGenesisLockout: creation now refuses a record younger than its window.
/// @dev Its genesis-timing half lives in `AceYoungRecordRail`, measured on `createMarket` instead.
/// @dev The state is reached by zeroing a mock record's windowed min AFTER creation, no longer by youth.
contract AceNoRecordPriceFailClosedTest is Test {
    Ace internal ace;
    AceReader internal read;
    PositionManager internal positionManager;
    MockERC20 internal usdc;
    MockStakeVault internal vault;
    MockPersistenceRecord internal record;
    bytes32 internal id;

    address internal alice = address(0xA11CE);
    address internal borrower = address(0xB0B);

    uint256 internal T2; // par itself; assigned in setUp, since par is not a compile-time value
    uint256 internal constant LADDER = 40_000e6;
    uint256 internal constant COLL = 200_000e18;
    uint256 internal constant PRINCIPAL = 4_000e6;
    uint64 internal constant TENOR = ProtocolPolicy.MIN_TENOR;

    /// @dev This suite's pair, so a tick reads as its distance from par rather than as a grid coordinate.
    /// @param offset Ticks above par.
    /// @return The absolute grid tick.
    function _price(int24 offset) internal view returns (uint256) {
        return AceFixtures.priceAt(address(usdc), address(vault), offset);
    }

    function setUp() public {
        vm.warp(1_000_000);
        usdc = new MockERC20("USD Coin", "USDC", 6);
        vault = new MockStakeVault(42);
        T2 = _price(0);
        record = new MockPersistenceRecord(address(usdc), address(vault));

        MarketParams memory p = AceFixtures.marketParams(address(usdc), address(vault));
        p.record = address(record);
        AceFixtures.Deployment memory d = AceFixtures.deploy(p);
        (ace, positionManager, read, id) = (d.ace, d.positionManager, d.read, d.id);
        record.setAbove(true); // healthy, so no distress gate interferes with the cap assertion

        usdc.mint(alice, LADDER);
        vm.startPrank(alice);
        usdc.approve(address(ace), LADDER);
        ace.deposit(id, LADDER);
        vm.stopPrank();

        vault.mint(borrower, COLL);
        usdc.mint(borrower, 1e6);
        vm.startPrank(borrower);
        vault.approve(address(positionManager), COLL);
        usdc.approve(address(ace), 1e6);
        vm.stopPrank();

        record.setMinPrice(0); // NO PRICE: the windowed min answers 0, so the record fails closed
    }

    function _expectLockedOut() internal {
        vm.prank(borrower);
        vm.expectRevert(NoRecordPrice.selector);
        ace.open(id, COLL, PRINCIPAL, 0, borrower, OpenBounds(0, 0, 0));
    }

    /// @notice The quote fails closed in LOCKSTEP with the draw: a UI or keeper view cannot diverge.
    function test_NoPrice_QuoteFailsClosedInLockstepWithOpen() public {
        assertEq(read.restingOf(id), LADDER, "the market is funded: cash is not the constraint");
        vm.expectRevert(NoRecordPrice.selector);
        ace.previewOpen(id, COLL, PRINCIPAL, TENOR, borrower, OpenBounds(0, 0, 0));
        _expectLockedOut();

        record.setMinPrice(AceFixtures.px(2e18, address(usdc), address(vault))); // the record sees again
        uint256 quoted = ace.previewOpen(id, COLL, PRINCIPAL, TENOR, borrower, OpenBounds(0, 0, 0)).postDrawFloor;
        assertGt(quoted, 0, "the quote prices the open once the record answers");
        vm.prank(borrower);
        assertEq(read.fundingFloor(id, ace.open(id, COLL, PRINCIPAL, 0, borrower, OpenBounds(0, 0, 0))), quoted, "and matches what executes");
    }

    /// @notice The blind cap gates BORROWING only. Lenders come and go throughout.
    function test_NoPrice_DepositAndWithdrawUnaffected() public {
        /// @dev WAS a `max` recall, which emptied the market. One market holds ONE balance, so the setUp's
        /// @dev own depth is in it too; the round trip is asked for by amount and judged on the delta.
        uint256 restingBefore = ace.restingOf(id);
        usdc.mint(alice, 1_000e6);
        vm.startPrank(alice);
        usdc.approve(address(ace), 1_000e6);
        ace.deposit(id, 1_000e6);
        uint256 back = ace.withdraw(id, 1_000e6, alice, 0);
        assertEq(back, 1_000e6, "deposit and withdraw are untouched by the blind cap");
        assertEq(ace.restingOf(id), restingBefore, "and the market is exactly where it started");
        vm.stopPrank();
        _expectLockedOut();
    }
}

/// @title AceRecordDoors
/// @notice FOUR doors read the same record for the same market, and must name that state ALIKE.
/// @notice `open` and `previewOpen` reach it through the draw walk's cap; the two lens forwarders
/// @notice reach it through `previewOpen` and through the continuation predicate.
/// @notice The pair below is the whole assertion: a record with NO usable price and a record with a
/// @notice usable one and no cash must never collapse onto one selector, nor split across the doors.
/// @dev Both answers are gathered BEFORE any assertion, so one run names every door that disagrees.
/// @dev A predicate-only fix passes the continuation row and fails the three draw rows, by construction.
contract AceRecordDoorsTest is Test {
    Ace internal ace;
    AceLens internal lens;
    AceReader internal read;
    PositionManager internal positionManager;
    MockERC20 internal usdc;
    MockStakeVault internal vault;
    MockPersistenceRecord internal record;
    bytes32 internal id;

    address internal alice = address(0xA11CE);
    address internal borrower = address(0xB0B);

    uint256 internal T2; // par itself, and the cap is set to exactly that price; assigned in setUp
    uint256 internal constant LADDER = 40_000e6;
    uint256 internal constant COLL = 200_000e18;
    uint256 internal constant PRINCIPAL = 4_000e6;
    uint64 internal constant TENOR = ProtocolPolicy.MIN_TENOR;

    uint256 internal loanId; // armed and inside its window, so the continuation door reaches the record leg

    OpenBounds internal OFF = OpenBounds(0, 0, 0);

    /// @dev This suite's pair, so a tick reads as its distance from par rather than as a grid coordinate.
    /// @param offset Ticks above par.
    /// @return The absolute grid tick.
    function _price(int24 offset) internal view returns (uint256) {
        return AceFixtures.priceAt(address(usdc), address(vault), offset);
    }

    function setUp() public {
        vm.warp(1_000_000);
        usdc = new MockERC20("USD Coin", "USDC", 6);
        vault = new MockStakeVault(42);
        T2 = _price(0);
        record = new MockPersistenceRecord(address(usdc), address(vault));

        MarketParams memory p = AceFixtures.marketParams(address(usdc), address(vault));
        p.record = address(record);
        AceFixtures.Deployment memory d = AceFixtures.deploy(p);
        (ace, positionManager, read, id) = (d.ace, d.positionManager, d.read, d.id);
        lens = new AceLens(address(ace));
        record.setAbove(true); // healthy, so no distress gate interferes
        record.setMinPrice(T2); // LIVE, and binding exactly at the seeded tick

        usdc.mint(alice, LADDER);
        vm.startPrank(alice);
        usdc.approve(address(ace), LADDER);
        ace.deposit(id, LADDER);
        vm.stopPrank();

        loanId = _open();
        vm.prank(borrower);
        ace.setAutoRefinance(loanId, TENOR, 0, 0);
        vm.warp(read.loan(loanId).expiry - 1); // inside the refinance window and still before expiry
    }

    /// @notice #270. A record with no usable price is ONE state, and all four doors must name it.
    /// @dev RED today: the three draw doors blame resting cash while the market is demonstrably funded.
    function test_NoUsableRecordPrice_AllFourDoorsNameTheSameState() public {
        record.setMinPrice(0);
        assertGt(read.restingOf(id), PRINCIPAL, "the market is funded: cash is not the constraint");

        (bytes4 o, bytes4 pv, bytes4 q, bytes4 k) = _fourDoors();
        assertEq(o, NoRecordPrice.selector, "ace.open blamed resting cash for the record");
        assertEq(pv, NoRecordPrice.selector, "ace.previewOpen blamed resting cash for the record");
        assertEq(q, NoRecordPrice.selector, "lens.tryQuoteOpen blamed resting cash for the record");
        assertEq(k, NoRecordPrice.selector, "lens.tryContinue blamed resting cash for the record");
    }

    /// @notice THE NEGATIVE TWIN. A live cap over an emptied ladder is a CASH refusal at all four doors.
    /// @notice Without it the row above could be satisfied by collapsing both states onto one selector,
    /// @notice which loses the discrimination a keeper acts on and is worse than the mis-attribution.
    /// @dev Green today and green after: nothing in the fix touches a market whose record answers a price.
    function test_LiveRecordOverAnEmptyLadder_AllFourDoorsSayInsufficientCash() public {
        vm.prank(alice);
        ace.withdraw(id, type(uint256).max, alice, 0);

        assertEq(record.minPrice(address(usdc), address(vault)), T2, "the record is LIVE here");
        assertLt(read.restingOf(id), PRINCIPAL, "the market cannot fund a draw of this size: cash IS the constraint");

        (bytes4 o, bytes4 pv, bytes4 q, bytes4 k) = _fourDoors();
        assertEq(o, InsufficientCash.selector, "ace.open renamed a cash refusal");
        assertEq(pv, InsufficientCash.selector, "ace.previewOpen renamed a cash refusal");
        assertEq(q, InsufficientCash.selector, "lens.tryQuoteOpen renamed a cash refusal");
        assertEq(k, InsufficientCash.selector, "lens.tryContinue renamed a cash refusal");
    }

    /* ========================== helpers ========================== */

    function _open() internal returns (uint256) {
        vault.mint(borrower, COLL);
        vm.startPrank(borrower);
        vault.approve(address(positionManager), COLL);
        uint256 newId = ace.open(id, COLL, PRINCIPAL, TENOR, borrower, OFF);
        vm.stopPrank();
        return newId;
    }

    /// @dev Every door's answer for the CURRENT market state, gathered before anything is asserted.
    function _fourDoors() internal returns (bytes4 openSel, bytes4 previewSel, bytes4 quoteSel, bytes4 continueSel) {
        openSel = _openRefusal();
        previewSel = _previewRefusal();
        (, quoteSel,) = lens.tryQuoteOpen(id, COLL, PRINCIPAL, TENOR, borrower, OFF);
        (, continueSel,) = lens.tryContinue(loanId);
        /// @dev Logged before the asserts, so a red run names every disagreeing door and not just the first.
        emit log_named_bytes32("ace.open          ", bytes32(openSel));
        emit log_named_bytes32("ace.previewOpen   ", bytes32(previewSel));
        emit log_named_bytes32("lens.tryQuoteOpen ", bytes32(quoteSel));
        emit log_named_bytes32("lens.tryContinue  ", bytes32(continueSel));
    }

    /// @dev The verb, reached raw: `expectRevert` would abort the run before the other doors answer.
    function _openRefusal() internal returns (bytes4) {
        vault.mint(borrower, COLL);
        vm.startPrank(borrower);
        vault.approve(address(positionManager), COLL);
        (bool ok, bytes memory err) = address(ace).call(abi.encodeCall(Ace.open, (id, COLL, PRINCIPAL, TENOR, borrower, OFF)));
        vm.stopPrank();
        assertFalse(ok, "the verb admitted a draw every other door refuses");
        return _sel(err);
    }

    function _previewRefusal() internal returns (bytes4) {
        (bool ok, bytes memory err) = address(ace).staticcall(abi.encodeCall(Ace.previewOpen, (id, COLL, PRINCIPAL, TENOR, borrower, OFF)));
        assertFalse(ok, "the quote admitted a draw the verb refuses");
        return _sel(err);
    }

    /// @dev The revert's selector, or zero for a bare or short revert; the shape `AceLens._selOf` uses.
    function _sel(bytes memory err) internal pure returns (bytes4 s) {
        if (err.length < 4) return bytes4(0);
        s = bytes4(err[0]) | (bytes4(err[1]) >> 8) | (bytes4(err[2]) >> 16) | (bytes4(err[3]) >> 24);
    }
}
