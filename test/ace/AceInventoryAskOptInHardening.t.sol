// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.36;

import {Ace, NoInventoryAsk, NoMarket} from "../../src/ace/hub/Ace.sol";
import {MarketParams, MigrateArgs, OpenBounds} from "../../src/ace/hub/Types.sol";
import {NoRecordPrice} from "../../src/ace/hub/Borrower.sol";
import {AceLens} from "../../src/ace/lens/AceLens.sol";
import {AceInventoryLens} from "../../src/ace/lens/AceInventoryLens.sol";
import {PositionManager} from "../../src/ace/positions/PositionManager.sol";
import {PocDeployConfig} from "../../src/config/Defaults.sol";
import {MockERC20} from "../mocks/MockERC20.sol";
import {MockStakeVault} from "../mocks/MockStakeVault.sol";
import {MockPersistenceRecord} from "../mocks/MockPersistenceRecord.sol";
import {AceFixtures} from "../utils/AceFixtures.sol";
import {AceReader} from "../utils/AceReader.sol";
import {WarpClock} from "../utils/WarpClock.sol";

/// @title AceInventoryAskOptInHardening
/// @notice The seams the opt-in ask shares with other verbs: a loan moved across the flag, a record gone dark, an id no loan sits at.
/// @dev The same twin as `AceInventoryAskOptIn`: two markets that differ in the flag alone, so each row has its control beside it.
contract AceInventoryAskOptInHardeningTest is WarpClock {
    Ace internal ace;
    AceReader internal read;
    AceLens internal lens;
    PositionManager internal positionManager;
    MockERC20 internal usdc;
    MockStakeVault internal vault;
    MockPersistenceRecord internal record;
    bytes32 internal onId; // the ask-on twin
    bytes32 internal offId; // the same params with the flag unset

    address internal alice = AceFixtures.LENDER;
    address internal stranger = address(0xB04E5);
    address internal borrower = address(0xB0BA);
    address internal keeper = address(0xCAFE);

    uint256 internal constant COLL = 10_000e18;
    uint256 internal constant PRINCIPAL = 4_500e6;
    uint256 internal constant BUDGET = 2_000e6;

    function setUp() public {
        _warpTo(1_000_000);
        usdc = new MockERC20("USD Coin", "USDC", 6);
        vault = new MockStakeVault(42);
        record = new MockPersistenceRecord(address(usdc), address(vault));
        record.setObserved(AceFixtures.px(1e18, address(usdc), address(vault)));
        record.setMinPrice(AceFixtures.px(2e18, address(usdc), address(vault)));
        MarketParams memory p = AceFixtures.marketParams(address(usdc), address(vault));
        p.record = address(record);
        AceFixtures.Deployment memory d = AceFixtures.deploy(p);
        (ace, positionManager, read, onId) = (d.ace, d.positionManager, d.read, d.id);
        p.inventoryAsk = false;
        offId = ace.createMarket(p);
        lens = new AceLens(address(ace));
        usdc.mint(stranger, BUDGET);
        vm.prank(stranger);
        usdc.approve(address(ace), BUDGET);
    }

    function _rest(bytes32 id, uint256 amt) internal {
        usdc.mint(alice, amt);
        vm.startPrank(alice);
        usdc.approve(address(ace), amt);
        ace.deposit(id, amt);
        vm.stopPrank();
    }

    /// @dev One lender-funded loan in `id`, still live.
    function _open(bytes32 id, uint256 principal) internal returns (uint256 loanId) {
        _rest(id, 5_000e6);
        vault.mint(borrower, COLL);
        vm.startPrank(borrower);
        vault.approve(address(positionManager), COLL);
        loanId = ace.open(id, COLL, principal, 0, borrower, OpenBounds(0, 0, 0));
        vm.stopPrank();
    }

    /// @dev The borrower's own move into `dst`, at a principal that clears the source's debt out of the fresh draw.
    function _moveTo(uint256 loanId, bytes32 dst) internal returns (uint256 next) {
        _rest(dst, 5_000e6);
        vm.prank(borrower);
        next = ace.refinanceTo(MigrateArgs(loanId, dst, PRINCIPAL, 0, OpenBounds(0, 0, 0), 0, address(0)));
        assertEq(ace.loanMarket(next), dst, "fixture: the successor sits in the destination");
        assertTrue(ace.isClosed(loanId), "fixture: and the source loan retired");
    }

    /// @dev Title moves on persisted distress, and the pot it leaves is asserted rather than assumed.
    function _settle(bytes32 id, uint256 loanId) internal returns (uint256 pot) {
        record.setBelow(true);
        vm.prank(keeper);
        ace.finalize(loanId);
        record.setBelow(false);
        pot = read.invPotOf(id, loanId);
        assertGt(pot, 0, "fixture: the settlement left a pot");
    }

    function _expectRefusedAsk(uint256 loanId, bytes4 why) internal {
        vm.prank(stranger);
        vm.expectRevert(why);
        ace.buyInventory(loanId, BUDGET, 0, stranger);
    }

    // ---- a loan moved across the flag ----

    /// @notice A loan its borrower moved out of an ask-on market into an ask-off one leaves a pot nobody may buy.
    /// @dev The pot is written under the DESTINATION, so the destination's flag is the one that answers for it.
    function test_RefinanceTo_ALoanMovedIntoTheAskOffMarketLeavesAPotNobodyMayBuy() public {
        uint256 src = _open(onId, 3_000e6);
        uint256 next = _moveTo(src, offId);
        uint256 pot = _settle(offId, next);
        _warpTo(read.inventoryAskOpensAt(next));

        _expectRefusedAsk(next, NoInventoryAsk.selector);
        assertEq(lens.inventoryAskOpensAt(next), type(uint256).max, "the successor's pot never opens");
        assertEq(read.invPotOf(onId, next), 0, "and nothing was written under the market the loan left");

        assertEq(lens.inventoryAskOpensAt(src), uint256(read.loan(src).closedAt) + 1 hours, "CONTROL: the retired source still reads by its own market");
        vm.prank(stranger);
        (uint256 unitsOut, uint256 filled) = ace.buyInventory(src, BUDGET, 0, stranger);
        assertEq(unitsOut + filled, 0, "CONTROL: that market has the ask, and a loan that closed clean has nothing to sell");

        vm.prank(alice);
        assertEq(ace.redeemInKind(next, alice), pot, "the lender takes the successor's whole pot in kind");
        assertEq(vault.balanceOf(stranger), 0, "and none of it ever reached the stranger");
    }

    /// @notice THE CONTROL, run the other way: moved out of the ask-off market into the ask-on one, the same loan's pot sells.
    /// @dev The retired source keeps answering by its own market, so the flag is read off the market and never carried on the loan.
    function test_RefinanceTo_ALoanMovedIntoTheAskOnMarketLeavesAPotTheAskSells() public {
        uint256 src = _open(offId, 3_000e6);
        uint256 next = _moveTo(src, onId);
        uint256 pot = _settle(onId, next);
        _warpTo(read.inventoryAskOpensAt(next));

        assertEq(lens.inventoryAskOpensAt(next), uint256(read.loan(next).closedAt) + 1 hours, "the successor's ask opens at the hold's end");
        vm.prank(stranger);
        (uint256 unitsOut,) = ace.buyInventory(next, BUDGET, 0, stranger);
        assertGt(unitsOut, 0, "the successor's pot sells under the destination's flag");
        assertEq(vault.balanceOf(stranger), unitsOut, "delivered to the buyer");
        assertEq(read.invPotOf(onId, next), pot - unitsOut, "out of the destination's pot");

        _expectRefusedAsk(src, NoInventoryAsk.selector);
        assertEq(lens.inventoryAskOpensAt(src), type(uint256).max, "and the retired source still reads never, by the market it closed in");
    }

    // ---- the lender's door owes nothing to the record ----

    /// @notice With the ask off the in-kind exit is the only door, so it must open whatever the record says.
    /// @dev A record that cannot price shuts the mark, and one that cannot answer shuts the twin's ask. Neither shuts this.
    function test_AskOff_TheLendersDoorOpensUnderADarkAndASickRecord() public {
        uint256 a = _open(offId, PRINCIPAL);
        uint256 b = _open(offId, PRINCIPAL);
        uint256 potA = _settle(offId, a);
        uint256 potB = _settle(offId, b);

        record.setMinPrice(0);
        vm.expectRevert(NoRecordPrice.selector);
        lens.inventoryMark(offId, a);
        vm.prank(alice);
        assertEq(ace.redeemInKind(a, alice), potA, "a record that cannot price leaves the lender's door open");

        record.setSick(true);
        vm.prank(alice);
        assertEq(ace.redeemInKind(b, alice), potB, "and so does a record that cannot answer");
        assertEq(vault.balanceOf(alice), potA + potB, "both pots delivered whole");
    }

    /// @notice The trough still COUNTS an ask-off pot the record cannot price, and quotes nothing for it.
    /// @dev No sale will ever close this trough: the lender's in-kind exit is what empties it.
    function test_Trough_AnAskOffPotUnderADarkRecordIsCountedAndNotPriced() public {
        uint256 off = _open(offId, PRINCIPAL);
        uint256 pot = _settle(offId, off);
        AceInventoryLens trough = new AceInventoryLens(address(ace), address(lens));
        record.setMinPrice(0);

        (uint256 quoted, uint256 units, bool priced, uint256 nextOffset) = trough.settledInventory(offId, 0, 10);
        assertFalse(priced, "the record priced nothing");
        assertEq(quoted, 0, "so nothing is quoted");
        assertEq(units, pot, "and the pot is still counted");
        assertEq(nextOffset, 1, "over the market's one loan");

        vm.prank(alice);
        ace.redeemInKind(off, alice);
        (, units,,) = trough.settledInventory(offId, 0, 10);
        assertEq(units, 0, "the in-kind exit emptied the trough");
    }

    // ---- an id no loan sits at ----

    /// @notice An id no loan sits at is refused as NO MARKET, never as a market without the ask.
    /// @dev An unwritten market reads the flag as off too, so this pins that the market's existence is asked first.
    function test_AnIdNoLoanSitsAtIsNoMarketAndNeverTheAsksRefusal() public {
        _expectRefusedAsk(999, NoMarket.selector);
    }
}

/// @title AceInventoryAskRecordlessTwin
/// @notice A market that names no record and HAS the ask still sells its settled pots at book, exactly as before the flag existed.
/// @dev Raw params on a fresh hub, so no shared fixture stands between the row and the protocol's own default.
contract AceInventoryAskRecordlessTwinTest is WarpClock {
    Ace internal ace;
    AceReader internal read;
    PositionManager internal pm;
    MockERC20 internal usdc;
    MockERC20 internal item;
    bytes32 internal onId;
    bytes32 internal offId;

    address internal lender = address(0x1E4DE2);
    address internal borrower = address(0xB0BA);
    address internal stranger = address(0xB04E5);

    function setUp() public {
        _warpTo(1_000_000);
        usdc = new MockERC20("USD Coin", "USDC", 6);
        item = new MockERC20("Item", "ITEM", 18);
        pm = new PositionManager(vm.computeCreateAddress(address(this), vm.getNonce(address(this)) + 1));
        ace = new Ace(address(0x7EA5), address(pm), PocDeployConfig.PUSH_GAS);
        read = new AceReader(address(ace));

        MarketParams memory p;
        p.quote = address(usdc);
        p.collateral = address(item);
        p.price = (uint256(1) << 96) / 1e12; // one quote per whole item, in the hub's frame
        p.minCoverageWad = 1.4e18;
        p.baseBps = 40;
        p.minTenor = 7 days;
        p.maxTenor = 30 days;
        p.minDebt = 10e6;
        p.lender = lender;
        offId = ace.createMarket(p);
        p.inventoryAsk = true;
        onId = ace.createMarket(p);
    }

    function _open(bytes32 id) internal returns (uint256 loanId) {
        usdc.mint(lender, 1_000e6);
        vm.startPrank(lender);
        usdc.approve(address(ace), 1_000e6);
        ace.deposit(id, 1_000e6);
        vm.stopPrank();
        item.mint(borrower, 1_000e18);
        vm.startPrank(borrower);
        item.approve(address(pm), 1_000e18);
        loanId = ace.open(id, 1_000e18, 500e6, 7 days, borrower, OpenBounds(0, 0, 0));
        vm.stopPrank();
    }

    /// @notice Two forfeits, one instant, one budget: the ask-on market sells at book and its ask-off twin refuses.
    /// @dev Book is one quote per whole item and neither market names a fill fee, so 100 quote buys 100 items.
    function test_ARecordlessMarketWithTheAskSellsAtBookWhereItsTwinRefuses() public {
        uint256 on = _open(onId);
        uint256 off = _open(offId);
        _warpTo(uint256(read.loan(off).expiry) + 1);
        ace.forceClose(on);
        ace.forceClose(off);
        uint256 pot = read.invPotOf(onId, on);
        assertGe(pot, 100e18, "fixture: the forfeit left a pot deeper than the buy");
        assertEq(read.invPotOf(offId, off), pot, "fixture: and its twin an identical one");
        _warpTo(read.inventoryAskOpensAt(on));

        usdc.mint(stranger, 200e6);
        vm.startPrank(stranger);
        usdc.approve(address(ace), 200e6);
        (uint256 unitsOut, uint256 filled) = ace.buyInventory(on, 100e6, 0, stranger);
        vm.expectRevert(NoInventoryAsk.selector);
        ace.buyInventory(off, 100e6, 0, stranger);
        vm.stopPrank();

        assertApproxEqRel(unitsOut, 100e18, 1e12, "the ask-on market sold at book: no record floors its ask");
        assertLe(filled, 100e6, "inside the buyer's budget");
        assertGe(filled, 100e6 - 1, "and to the atom of it");
        assertEq(item.balanceOf(stranger), unitsOut, "delivered to the buyer");
        assertEq(read.invPotOf(onId, on), pot - unitsOut, "out of the ask-on pot");
        assertEq(read.invPotOf(offId, off), pot, "while the ask-off twin's pot is whole");
    }
}
