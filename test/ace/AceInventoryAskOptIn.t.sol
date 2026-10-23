// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.36;

import {Ace, InventoryHeld, NoInventoryAsk} from "../../src/ace/hub/Ace.sol";
import {MarketParams, OpenBounds} from "../../src/ace/hub/Types.sol";
import {MarketExists} from "../../src/ace/hub/MarketInit.sol";
import {NotTheLender} from "../../src/ace/hub/Lender.sol";
import {NoRecordPrice, RecordUnreadable} from "../../src/ace/hub/Borrower.sol";
import {ExitToHub} from "../../src/ace/hub/libraries/Recipients.sol";
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

/// @title AceInventoryAskOptIn
/// @notice The hub's post-settlement ask is a per-market choice, fixed at genesis and off unless the creator turns it on.
/// @notice Two markets that differ in that one flag run side by side, so every refusal has a control beside it.
/// @dev The twin is the point: a row that only drove the ask-off market could pass on a hub that sold nothing anywhere.
contract AceInventoryAskOptInTest is WarpClock {
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
        assertTrue(p.inventoryAsk, "fixture: the shared baseline keeps the ask on, so the suites that buy still can");
        AceFixtures.Deployment memory d = AceFixtures.deploy(p);
        (ace, positionManager, read, onId) = (d.ace, d.positionManager, d.read, d.id);
        p.inventoryAsk = false;
        offId = ace.createMarket(p);
        lens = new AceLens(address(ace));
        usdc.mint(stranger, BUDGET);
        vm.prank(stranger);
        usdc.approve(address(ace), BUDGET);
    }

    /// @dev One lender-funded loan in `id`, still live.
    function _open(bytes32 id) internal returns (uint256 loanId) {
        usdc.mint(alice, 5_000e6);
        vm.startPrank(alice);
        usdc.approve(address(ace), 5_000e6);
        ace.deposit(id, 5_000e6);
        vm.stopPrank();
        vault.mint(borrower, COLL);
        vm.startPrank(borrower);
        vault.approve(address(positionManager), COLL);
        loanId = ace.open(id, COLL, PRINCIPAL, 0, borrower, OpenBounds(0, 0, 0));
        vm.stopPrank();
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

    function _settled(bytes32 id) internal returns (uint256 loanId, uint256 pot) {
        loanId = _open(id);
        pot = _settle(id, loanId);
    }

    /// @dev The end of the hold, which is where the twin's ask opens; the reader's figure is the hold's end on either market.
    function _pastHold(uint256 loanId) internal {
        _warpTo(read.inventoryAskOpensAt(loanId));
    }

    function _expectRefusedAsk(uint256 loanId, bytes4 why) internal {
        vm.prank(stranger);
        vm.expectRevert(why);
        ace.buyInventory(loanId, BUDGET, 0, stranger);
    }

    // ---- the refusal ----

    /// @notice An ask-off market's settled pot is not for sale once the hold has run, nor years after it.
    function test_AskOff_AStrangersBuyIsRefusedAfterTheHoldAndForGood() public {
        (uint256 id, uint256 pot) = _settled(offId);
        _pastHold(id);
        _expectRefusedAsk(id, NoInventoryAsk.selector);
        _warpBy(3650 days);
        _expectRefusedAsk(id, NoInventoryAsk.selector);

        assertEq(read.invPotOf(offId, id), pot, "the pot is whole");
        assertEq(usdc.balanceOf(stranger), BUDGET, "no quote left the stranger");
        assertEq(vault.balanceOf(stranger), 0, "and no collateral reached them");
    }

    /// @notice THE CONTROL: the twin sells the same pot at the same instant, so the refusal above is the flag's.
    function test_AskOn_TheTwinSellsThePotAtTheHoldsEnd() public {
        (uint256 id, uint256 pot) = _settled(onId);
        _pastHold(id);
        uint256 owed = read.poolOwed(onId);

        vm.prank(stranger);
        (uint256 unitsOut, uint256 filled) = ace.buyInventory(id, BUDGET, 0, stranger);

        assertGt(unitsOut, 0, "the ask filled");
        assertEq(vault.balanceOf(stranger), unitsOut, "the collateral reached the buyer");
        assertEq(read.invPotOf(onId, id), pot - unitsOut, "out of the pot");
        assertEq(read.poolOwed(onId) - owed, filled, "and every wei of the fill credited the lender");
    }

    /// @notice The flag answers BEFORE the loan's liveness, the hold and the record are read.
    /// @dev Each state is one the twin refuses under another name, which the control row below pins.
    function test_AskOff_TheRefusalPrecedesLivenessTheHoldAndTheRecord() public {
        uint256 id = _open(offId);
        _expectRefusedAsk(id, NoInventoryAsk.selector); // a live loan
        _settle(offId, id);
        _expectRefusedAsk(id, NoInventoryAsk.selector); // inside the hold
        _pastHold(id);
        record.setMinPrice(0);
        _expectRefusedAsk(id, NoInventoryAsk.selector); // a record that cannot price
        record.setSick(true);
        _expectRefusedAsk(id, NoInventoryAsk.selector); // a record that cannot answer
    }

    /// @notice THE CONTROL for the ordering row: ask-on, the same four states refuse exactly as they always have.
    function test_AskOn_TheSameStatesRefuseUnderTheirOwnNames() public {
        uint256 id = _open(onId);
        _expectRefusedAsk(id, InventoryHeld.selector);
        _settle(onId, id);
        _expectRefusedAsk(id, InventoryHeld.selector);
        _warpTo(read.inventoryAskOpensAt(id) - 1);
        _expectRefusedAsk(id, InventoryHeld.selector); // the last held second
        _pastHold(id);
        record.setMinPrice(0);
        _expectRefusedAsk(id, NoRecordPrice.selector);
        record.setSick(true);
        _expectRefusedAsk(id, RecordUnreadable.selector);
    }

    /// @notice The recipient rule still answers first, on either market: a bad destination is named before the flag is.
    function test_AskOff_TheRecipientRuleStillAnswersFirst() public {
        (uint256 id,) = _settled(offId);
        _pastHold(id);
        vm.prank(stranger);
        vm.expectRevert(ExitToHub.selector);
        ace.buyInventory(id, BUDGET, 0, address(ace));
    }

    // ---- the lender's door, and nobody else's ----

    /// @notice The lender takes the whole pot in kind in the block that settles the loan.
    function test_AskOff_TheLenderRedeemsInKindInTheSettlingBlock() public {
        (uint256 id, uint256 pot) = _settled(offId);
        vm.prank(alice);
        assertEq(ace.redeemInKind(id, alice), pot, "the whole pot, with no clock read");
        assertEq(vault.balanceOf(alice), pot, "delivered");
        assertEq(read.invPotOf(offId, id), 0, "and the pot is empty behind it");
    }

    /// @notice And years later it is still there, whole, and still theirs: nothing sold it in the meantime.
    function test_AskOff_TheLenderRedeemsInKindYearsLater() public {
        (uint256 id, uint256 pot) = _settled(offId);
        _warpBy(5 * 365 days);
        _expectRefusedAsk(id, NoInventoryAsk.selector);
        vm.prank(alice);
        assertEq(ace.redeemInKind(id, alice), pot, "the whole pot, undiminished by the wait");
        assertEq(vault.balanceOf(alice), pot, "delivered");
    }

    /// @notice Every door a stranger can try on an ask-off pot: the ask, the ask through a batch, and the in-kind exit.
    function test_AskOff_AStrangerHasNoDoorToThePot() public {
        (uint256 id, uint256 pot) = _settled(offId);
        _pastHold(id);
        uint256 retired = positionManager.retiredOf(id);

        _expectRefusedAsk(id, NoInventoryAsk.selector);
        bytes[] memory batch = new bytes[](1);
        batch[0] = abi.encodeCall(Ace.buyInventory, (id, BUDGET, 0, stranger));
        vm.prank(stranger);
        vm.expectRevert(NoInventoryAsk.selector);
        ace.multicall(batch);
        vm.prank(stranger);
        vm.expectRevert(NotTheLender.selector);
        ace.redeemInKind(id, stranger);
        vm.prank(borrower);
        vm.expectRevert(NotTheLender.selector);
        ace.redeemInKind(id, borrower);

        assertEq(read.invPotOf(offId, id), pot, "the pot is whole");
        assertEq(positionManager.retiredOf(id), retired, "and custody still holds every unit");
        assertEq(vault.balanceOf(stranger), 0, "none reached the stranger");
    }

    // ---- identity ----

    /// @notice The flag is a word of the id preimage, and the only one the twins differ in.
    function test_TheMarketIdCommitsToTheFlag() public view {
        MarketParams memory on = ace.idToMarketParams(onId);
        MarketParams memory off = ace.idToMarketParams(offId);
        assertTrue(on.inventoryAsk, "the twin stored the flag");
        assertFalse(off.inventoryAsk, "and the ask-off market stored its absence");
        assertTrue(onId != offId, "two ids");
        assertEq(keccak256(abi.encode(on)), onId, "each the hash of its own params");
        assertEq(keccak256(abi.encode(off)), offId, "each the hash of its own params");
        on.inventoryAsk = false;
        assertEq(keccak256(abi.encode(on)), offId, "and the flag is the only difference between them");
    }

    /// @notice Fixed at genesis: the params are write-once, so the only way to another answer is another market.
    function test_TheFlagIsWriteOnce() public {
        MarketParams memory off = ace.idToMarketParams(offId);
        vm.expectRevert(MarketExists.selector);
        ace.createMarket(off);
    }

    /// @notice The flag shares the lender's storage word, so no member below it moved.
    function test_TheFlagPacksBesideTheLender() public view {
        uint256 lenderSlot = read.marketSlot(onId, 16);
        assertEq(uint256(vm.load(address(ace), bytes32(lenderSlot))), uint256(uint160(alice)) | (1 << 160), "ask-on: the lender, then the flag");
        lenderSlot = read.marketSlot(offId, 16);
        assertEq(uint256(vm.load(address(ace), bytes32(lenderSlot))), uint256(uint160(alice)), "ask-off: the lender alone");
    }

    // ---- the lens ----

    /// @notice An ask-off market's opening time is NEVER, and that answer comes before the live loan's zero.
    function test_Lens_OpensAtIsNeverOnAnAskOffMarket() public {
        uint256 off = _open(offId);
        uint256 on = _open(onId);
        assertEq(lens.inventoryAskOpensAt(on), 0, "CONTROL: a live loan on the twin reads zero");
        assertEq(lens.inventoryAskOpensAt(off), type(uint256).max, "ask-off answers first: a live loan reads never, not zero");

        _settle(offId, off);
        _settle(onId, on);
        assertEq(lens.inventoryAskOpensAt(on), uint256(read.loan(on).closedAt) + 1 hours, "CONTROL: the twin opens at the hold's end");
        assertEq(lens.inventoryAskOpensAt(off), type(uint256).max, "and a settled ask-off pot never opens");
        assertEq(lens.inventoryAskOpensAt(off + on + 1), 0, "an id no loan sits at has no market to ask, so it still reads zero");
    }

    /// @notice The mark and the trough still price an ask-off pot: a valuation, not a sale anyone can take.
    function test_Lens_AnAskOffPotStillMarksAndStillSizesTheTrough() public {
        (uint256 off, uint256 pot) = _settled(offId);
        (uint256 on,) = _settled(onId);
        uint256 mark = lens.inventoryMark(offId, off);
        assertGt(mark, 0, "the ask-off pot marks");
        assertEq(mark, lens.inventoryMark(onId, on), "at exactly what the twin's identical pot marks");

        AceInventoryLens trough = new AceInventoryLens(address(ace), address(lens));
        (uint256 quoted, uint256 units, bool priced,) = trough.settledInventory(offId, 0, 10);
        assertTrue(priced, "the record priced the page");
        assertEq(units, pot, "the trough counts the pot");
        assertEq(quoted, mark, "at the singular view's own figure");
    }
}

/// @title AceInventoryAskProtocolDefault
/// @notice THE DEFAULT IS OFF, pinned on params no shared fixture touched: a creator who says nothing sells no pot.
/// @dev The shared baseline sets the flag, so a row built on it could not see a default that had flipped.
contract AceInventoryAskProtocolDefaultTest is WarpClock {
    address internal lender = address(0x1E4DE2);
    address internal borrower = address(0xB0BA);
    address internal stranger = address(0xB04E5);

    function test_AMarketThatNamesNoAskSellsNoPot() public {
        _warpTo(1_000_000);
        MockERC20 usdc = new MockERC20("USD Coin", "USDC", 6);
        MockERC20 item = new MockERC20("Item", "ITEM", 18);
        PositionManager pm = new PositionManager(vm.computeCreateAddress(address(this), vm.getNonce(address(this)) + 1));
        Ace ace = new Ace(address(0x7EA5), address(pm), PocDeployConfig.PUSH_GAS);
        AceReader read = new AceReader(address(ace));

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
        bytes32 id = ace.createMarket(p);
        assertFalse(ace.idToMarketParams(id).inventoryAsk, "an unset flag stores as off");

        usdc.mint(lender, 1_000e6);
        vm.startPrank(lender);
        usdc.approve(address(ace), 1_000e6);
        ace.deposit(id, 1_000e6);
        vm.stopPrank();
        item.mint(borrower, 1_000e18);
        vm.startPrank(borrower);
        item.approve(address(pm), 1_000e18);
        uint256 loanId = ace.open(id, 1_000e18, 500e6, 7 days, borrower, OpenBounds(0, 0, 0));
        vm.stopPrank();

        _warpTo(uint256(read.loan(loanId).expiry) + 1);
        ace.forceClose(loanId);
        uint256 pot = read.invPotOf(id, loanId);
        assertGt(pot, 0, "fixture: the expiry left the lender a pot");
        _warpBy(365 days);

        usdc.mint(stranger, 1_000e6);
        vm.startPrank(stranger);
        usdc.approve(address(ace), 1_000e6);
        vm.expectRevert(NoInventoryAsk.selector);
        ace.buyInventory(loanId, 1_000e6, 0, stranger);
        vm.stopPrank();

        vm.prank(lender);
        assertEq(ace.redeemInKind(loanId, lender), pot, "CONTROL: the pot was there, and the lender's door took it whole");
    }
}
