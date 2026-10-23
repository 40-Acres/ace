// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.36;

import {Vm} from "forge-std/Test.sol";
import {FullMath} from "@uniswap/v4-core/src/libraries/FullMath.sol";
import {Ace} from "../../src/ace/hub/Ace.sol";
import {MarketParams, MigrateArgs, OpenBounds} from "../../src/ace/hub/Types.sol";
import {AceLens} from "../../src/ace/lens/AceLens.sol";
import {PositionManager} from "../../src/ace/positions/PositionManager.sol";
import {MockERC20} from "../mocks/MockERC20.sol";
import {MockBlockableERC20} from "../mocks/MockBlockableERC20.sol";
import {MockDeleverageKeeper} from "../mocks/MockDeleverageKeeper.sol";
import {MockPersistenceRecord} from "../mocks/MockPersistenceRecord.sol";
import {MockStakeVault} from "../mocks/MockStakeVault.sol";
import {AceFixtures} from "../utils/AceFixtures.sol";
import {AceReader} from "../utils/AceReader.sol";
import {WarpClock} from "../utils/WarpClock.sol";
import {AceRefinanceWithdrawFixture} from "./AceRefinanceWithdraw.t.sol";

/// @notice The exit events under their ruled signatures, declared here so the suite pins the shape rather than importing it.
library RecipientEvents {
    event BuyInventory(uint256 indexed loanId, address indexed payer, address indexed unitsTo, uint256 unitsOut, uint256 stableFilled);
    event CollateralWithdrawn(uint256 indexed id, address indexed to, uint256 units, uint256 unitsLeft, uint256 newTrigger);

    bytes32 internal constant BUY = keccak256("BuyInventory(uint256,address,address,uint256,uint256)");
    bytes32 internal constant BUY_OLD = keccak256("BuyInventory(uint256,address,uint256,uint256)"); // the single-address form
    bytes32 internal constant WITHDRAWN = keccak256("CollateralWithdrawn(uint256,address,uint256,uint256,uint256)");
    bytes32 internal constant WITHDRAWN_OLD = keccak256("CollateralWithdrawn(uint256,uint256,uint256,uint256)"); // no recipient
    bytes32 internal constant OPENED = keccak256("Opened(uint256,bytes32,address,uint256,uint256,uint256,uint64)");
    bytes32 internal constant REFINANCED = keccak256("Refinanced(uint256,uint256,uint256,uint64,uint256,address)");
    bytes32 internal constant DELEVERAGED = keccak256("Deleveraged(uint256,uint256,uint256,uint256,address)");
}

/// @notice Log scans over a recorded call: counts and first positions, by topic0, emitter and optionally the indexed id.
library LogScan {
    uint256 internal constant NONE = type(uint256).max; // no such log; asserted away at every call site
    bytes32 internal constant TRANSFER = keccak256("Transfer(address,address,uint256)");

    function count(Vm.Log[] memory logs, bytes32 topic, address emitter) internal pure returns (uint256 n) {
        for (uint256 i; i < logs.length; i++) {
            if (logs[i].emitter == emitter && logs[i].topics.length != 0 && logs[i].topics[0] == topic) n++;
        }
    }

    /// @dev The first log with this topic0 from this emitter whose first indexed word is `id`.
    function indexOf(Vm.Log[] memory logs, bytes32 topic, address emitter, uint256 id) internal pure returns (uint256) {
        for (uint256 i; i < logs.length; i++) {
            Vm.Log memory l = logs[i];
            if (l.emitter == emitter && l.topics.length > 1 && l.topics[0] == topic && l.topics[1] == bytes32(id)) return i;
        }
        return NONE;
    }

    /// @dev The first ERC-20 `Transfer` this token logged to `to`.
    function transferTo(Vm.Log[] memory logs, address token, address to) internal pure returns (uint256) {
        for (uint256 i; i < logs.length; i++) {
            Vm.Log memory l = logs[i];
            if (l.emitter == token && l.topics.length == 3 && l.topics[0] == TRANSFER && l.topics[2] == word(to)) return i;
        }
        return NONE;
    }

    function word(address a) internal pure returns (bytes32) {
        return bytes32(uint256(uint160(a)));
    }
}

/// @title AceEventRecipients
/// @notice An exit's log names who paid and where the goods went, so an indexer never has to guess which address it holds.
/// @dev `buyInventory` and `withdrawCollateral`: every fixed row names a recipient other than the caller, so a swapped field cannot pass.
contract AceEventRecipientsTest is WarpClock {
    Ace internal ace;
    AceReader internal read;
    AceLens internal lens; // the shipped withdrawable view sizes the fuzz row, so its bound is not re-derived here
    PositionManager internal pm;
    MockERC20 internal asset;
    MockBlockableERC20 internal coll; // it logs `Transfer`, so a row can order the release against the hub's event
    MockPersistenceRecord internal record;
    bytes32 internal mid;
    address internal constant LENDER = address(0xA11CE);
    address internal constant BORROWER = address(0xB0B);
    address internal constant RECIPIENT = address(0xCA401); // the third-party recipient, never a caller
    address internal constant BUYER = address(0xB1E4); // the paying caller of the ask
    uint256 internal constant COLL = 100_000e18;
    uint256 internal constant DRAW = 40_000e6;
    uint256 internal constant TAKE = 1_000e18; // well inside the open loan's free collateral
    uint256 internal constant SPEND = 1_000e6; // a buy the settled pot can fill several times over

    function setUp() public {
        _warpTo(1_000_000);
        asset = new MockERC20("Quote", "Q", 6);
        coll = new MockBlockableERC20("Collateral", "C", 18);
        (ace, pm) = AceFixtures.newAceWithEscrow(AceFixtures.TREASURY);
        read = new AceReader(address(ace));
        lens = new AceLens(address(ace));
        asset.mint(LENDER, 400_000e6);
        MarketParams memory p = AceFixtures.marketParams(address(asset), address(coll));
        record = new MockPersistenceRecord(address(asset), address(coll));
        p.record = address(record);
        mid = ace.createMarket(p);
        vm.startPrank(LENDER);
        asset.approve(address(ace), type(uint256).max);
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

    /// @dev Settled, the hold rested out, and a funded buyer: an ask that fills.
    function _askable() internal returns (uint256 id) {
        id = _open();
        record.setBelow(true);
        ace.finalize(id);
        assertGt(read.invPotOf(mid, id), 0, "fixture: lender inventory exists");
        _warpTo(read.inventoryAskOpensAt(id));
        asset.mint(BUYER, 10 * SPEND);
        vm.prank(BUYER);
        asset.approve(address(ace), type(uint256).max);
    }

    /// @dev The fill a buy WOULD make, read off a dry run that is then unwound.
    function _dryBuy(uint256 id) internal returns (uint256 unitsOut, uint256 filled) {
        uint256 root = vm.snapshotState();
        vm.prank(BUYER);
        (unitsOut, filled) = ace.buyInventory(id, SPEND, 1, RECIPIENT);
        vm.revertToState(root);
        assertGt(unitsOut, 0, "fixture: the ask fills");
        assertGt(filled, 0, "fixture: and charges");
    }

    /// @dev What a withdrawal WOULD leave, read off a dry run that is then unwound.
    function _dryWithdraw(uint256 id) internal returns (uint256 left, uint256 trig) {
        uint256 before = read.triggerPrice(id);
        uint256 root = vm.snapshotState();
        vm.prank(BORROWER);
        ace.withdrawCollateral(id, TAKE, RECIPIENT);
        (left, trig) = (read.loan(id).collateralUnits, read.triggerPrice(id));
        vm.revertToState(root);
        assertEq(left, COLL - TAKE, "fixture: the withdrawal debits exactly TAKE");
        assertGt(trig, before, "fixture: shedding units raises the trigger, so a stale one cannot pass");
    }

    /* ---- buyInventory: the caller pays, `unitsTo` receives, and the log names both ---- */

    function test_BuyInventory_LogsTheCallerAsPayer_AndUnitsToAsRecipient() public {
        uint256 id = _askable();
        (uint256 unitsOut, uint256 filled) = _dryBuy(id);
        uint256 cashBefore = asset.balanceOf(BUYER);
        vm.expectEmit(true, true, true, true, address(ace));
        emit RecipientEvents.BuyInventory(id, BUYER, RECIPIENT, unitsOut, filled);
        vm.prank(BUYER);
        ace.buyInventory(id, SPEND, 1, RECIPIENT);
        assertEq(coll.balanceOf(RECIPIENT), unitsOut, "control: the units reached the logged recipient");
        assertEq(coll.balanceOf(BUYER), 0, "and none reached the payer");
        assertEq(cashBefore - asset.balanceOf(BUYER), filled, "control: the logged payer is the one who paid the logged fill");
        assertEq(asset.balanceOf(RECIPIENT), 0, "and the recipient paid nothing");
    }

    function test_BuyInventory_ExactlyOneLogUnderTheNewSignature_NoneUnderTheOld() public {
        uint256 id = _askable();
        vm.recordLogs();
        vm.prank(BUYER);
        (uint256 unitsOut, uint256 filled) = ace.buyInventory(id, SPEND, 1, RECIPIENT);
        Vm.Log[] memory logs = vm.getRecordedLogs();
        assertEq(LogScan.count(logs, RecipientEvents.BUY, address(ace)), 1, "one hub log under the new signature");
        assertEq(LogScan.count(logs, RecipientEvents.BUY_OLD, address(ace)), 0, "and none under the old one");
        uint256 at = LogScan.indexOf(logs, RecipientEvents.BUY, address(ace), id);
        assertLt(at, logs.length, "and it is keyed by the bought loan");
        Vm.Log memory l = logs[at];
        assertEq(l.topics.length, 4, "three indexed fields");
        assertEq(l.topics[2], LogScan.word(BUYER), "topic2 is the payer");
        assertEq(l.topics[3], LogScan.word(RECIPIENT), "topic3 is the recipient");
        assertEq(l.data.length, 64, "two data words");
        (uint256 u, uint256 f) = abi.decode(l.data, (uint256, uint256));
        assertEq(u, unitsOut, "data carries the returned unitsOut");
        assertEq(f, filled, "and the returned stableFilled");
    }

    /* ---- withdrawCollateral: the log carries the recipient the borrower named ---- */

    function test_WithdrawCollateral_LogsTheThirdPartyItPaid() public {
        uint256 id = _open();
        (uint256 left, uint256 trig) = _dryWithdraw(id);
        vm.expectEmit(true, true, true, true, address(ace));
        emit RecipientEvents.CollateralWithdrawn(id, RECIPIENT, TAKE, left, trig);
        vm.prank(BORROWER);
        ace.withdrawCollateral(id, TAKE, RECIPIENT);
        assertEq(coll.balanceOf(RECIPIENT), TAKE, "control: the units reached the logged recipient");
    }

    function test_CollateralWithdrawn_ExactlyOneLogUnderTheNewSignature_NoneUnderTheOld() public {
        uint256 id = _open();
        vm.recordLogs();
        vm.prank(BORROWER);
        ace.withdrawCollateral(id, TAKE, RECIPIENT);
        Vm.Log[] memory logs = vm.getRecordedLogs();
        assertEq(LogScan.count(logs, RecipientEvents.WITHDRAWN, address(ace)), 1, "one hub log under the new signature");
        assertEq(LogScan.count(logs, RecipientEvents.WITHDRAWN_OLD, address(ace)), 0, "and none under the old one");
        uint256 at = LogScan.indexOf(logs, RecipientEvents.WITHDRAWN, address(ace), id);
        assertLt(at, logs.length, "and it is keyed by the loan withdrawn from");
        Vm.Log memory l = logs[at];
        assertEq(l.topics.length, 3, "two indexed fields");
        assertEq(l.topics[2], LogScan.word(RECIPIENT), "topic2 is the recipient");
        assertEq(l.data.length, 96, "three data words");
        (uint256 units, uint256 left, uint256 trig) = abi.decode(l.data, (uint256, uint256, uint256));
        assertEq(units, TAKE, "units is what left");
        assertEq(left + units, COLL, "unitsLeft plus units is the pre-call lot, an oracle the ledger does not supply");
        assertEq(left, read.loan(id).collateralUnits, "unitsLeft is the loan's post-withdrawal lot");
        assertEq(trig, read.triggerPrice(id), "newTrigger is the trigger read after the call");
    }

    function test_WithdrawCollateral_LogsBeforeTheRelease() public {
        uint256 id = _open();
        vm.recordLogs();
        vm.prank(BORROWER);
        ace.withdrawCollateral(id, TAKE, RECIPIENT);
        Vm.Log[] memory logs = vm.getRecordedLogs();
        uint256 logged = LogScan.indexOf(logs, RecipientEvents.WITHDRAWN, address(ace), id);
        uint256 moved = LogScan.transferTo(logs, address(coll), RECIPIENT);
        assertLt(logged, logs.length, "the withdrawal is logged");
        assertLt(moved, logs.length, "and the release moved the units");
        assertEq(logs[moved].topics[1], LogScan.word(address(pm)), "the transfer found is the custodian's release");
        assertEq(abi.decode(logs[moved].data, (uint256)), TAKE, "of exactly the logged units");
        assertLt(logged, moved, "the event precedes the transfer it describes, as the refinance leg's does");
    }

    /// @dev Any admissible amount to any legal recipient: the log carries the call's `to` and `units`, and the lot conserves.
    function testFuzz_WithdrawCollateral_LogsTheCallsRecipientUnitsAndLot(uint256 units, address to) public {
        vm.assume(to != address(0) && to != address(ace) && to != address(pm)); // the three refused recipients
        uint256 id = _open();
        uint256 free = lens.withdrawableUnits(mid, id);
        assertGt(free, 0, "fixture: the open loan has room to shed");
        units = bound(units, 1, free);
        assertEq(read.loan(id).collateralUnits, COLL, "fixture: the pre-call lot is the opened one");
        uint256 trigBefore = read.triggerPrice(id);
        uint256 toBefore = coll.balanceOf(to);

        vm.recordLogs();
        vm.prank(BORROWER);
        ace.withdrawCollateral(id, units, to);
        Vm.Log[] memory logs = vm.getRecordedLogs();

        assertEq(LogScan.count(logs, RecipientEvents.WITHDRAWN, address(ace)), 1, "one withdrawal log");
        uint256 at = LogScan.indexOf(logs, RecipientEvents.WITHDRAWN, address(ace), id);
        assertLt(at, logs.length, "keyed by the loan withdrawn from");
        assertEq(logs[at].topics[2], LogScan.word(to), "to is the call's recipient");
        (uint256 u, uint256 left, uint256 trig) = abi.decode(logs[at].data, (uint256, uint256, uint256));
        assertEq(u, units, "units is the call's amount");
        assertEq(left + u, COLL, "unitsLeft plus units is the pre-call lot");
        assertEq(left, read.loan(id).collateralUnits, "unitsLeft is the post-call lot");
        assertEq(trig, read.triggerPrice(id), "newTrigger is the post-call trigger");
        assertGe(trig, trigBefore, "shedding units never lowers the trigger");
        assertEq(coll.balanceOf(to) - toBefore, units, "control: the logged recipient received exactly the logged units");
    }
}

/// @notice `refinanceTo`'s withdrawal leg logs `CollateralWithdrawn` against the SUCCESSOR, after its `Opened`.
/// @notice `Opened.collateralUnits` is the lot BEFORE the leg, so an indexer subtracts `units`, as it does a deleverage's `unitsSold`.
contract AceEventRecipientsRefinanceTest is AceRefinanceWithdrawFixture {
    uint256 internal constant COLL = 12_000e18;
    uint256 internal constant TAKE = 1_000e18; // inside the successor's line at the flat price

    function setUp() public {
        _boot();
    }

    /// @dev The successor a migration WOULD open, and its post-leg lot and trigger, read off a dry run that is then unwound.
    function _dryMigrate(uint256 oldId) internal returns (uint256 newId, uint256 left, uint256 trig) {
        uint256 root = vm.snapshotState();
        uint256 whole = read.triggerPrice(_migrate(_args(oldId, flat, NEWP, 0, sink))); // the same successor with no leg
        vm.revertToState(root);
        root = vm.snapshotState();
        newId = _migrate(_args(oldId, flat, NEWP, TAKE, sink));
        (left, trig) = (read.loan(newId).collateralUnits, read.triggerPrice(newId));
        vm.revertToState(root);
        assertEq(left, COLL - TAKE, "fixture: the leg debits exactly TAKE");
        assertGt(trig, whole, "fixture: the leg raises the successor's trigger, so a pre-leg read cannot pass");
    }

    function test_RefinanceTo_TheWithdrawalLegLogsCollateralWithdrawnToItsRecipient() public {
        uint256 oldId = _open(flat, COLL, P);
        (uint256 newId, uint256 left, uint256 trig) = _dryMigrate(oldId);
        vm.expectEmit(true, true, true, true, address(ace));
        emit RecipientEvents.CollateralWithdrawn(newId, sink, TAKE, left, trig);
        assertEq(_migrate(_args(oldId, flat, NEWP, TAKE, sink)), newId, "the dry run named the same successor");
        assertEq(vault.balanceOf(sink), TAKE, "control: the units reached the logged recipient");
    }

    function test_RefinanceTo_OpenedMinusWithdrawnIsTheSuccessorsLedger() public {
        uint256 oldId = _open(flat, COLL, P);
        vm.recordLogs();
        uint256 newId = _migrate(_args(oldId, flat, NEWP, TAKE, sink));
        Vm.Log[] memory logs = vm.getRecordedLogs();
        assertEq(LogScan.count(logs, RecipientEvents.WITHDRAWN, address(ace)), 1, "one withdrawal log for the leg");
        assertEq(LogScan.count(logs, RecipientEvents.WITHDRAWN_OLD, address(ace)), 0, "and none under the old signature");

        uint256 opened = LogScan.indexOf(logs, RecipientEvents.OPENED, address(ace), newId);
        uint256 withdrawn = LogScan.indexOf(logs, RecipientEvents.WITHDRAWN, address(ace), newId);
        uint256 refinanced = LogScan.indexOf(logs, RecipientEvents.REFINANCED, address(ace), oldId);
        assertLt(opened, logs.length, "the successor's Opened is logged");
        assertLt(withdrawn, logs.length, "the withdrawal is keyed by the successor's id");
        assertLt(refinanced, logs.length, "Refinanced still logs under its unchanged topic0");
        assertLt(opened, withdrawn, "Opened comes first");
        assertLt(withdrawn, refinanced, "and the leg lands before the announcement");

        (uint256 openedUnits,,,) = abi.decode(logs[opened].data, (uint256, uint256, uint256, uint64));
        (uint256 units, uint256 left,) = abi.decode(logs[withdrawn].data, (uint256, uint256, uint256));
        assertEq(openedUnits, COLL, "Opened logs the lot BEFORE the leg");
        assertEq(units, TAKE, "the leg logs what it shed");
        assertEq(openedUnits - units, left, "Opened minus the leg is unitsLeft");
        assertEq(left, read.loan(newId).collateralUnits, "and unitsLeft is the successor's ledger");

        Vm.Log memory r = logs[refinanced];
        assertEq(r.topics.length, 4, "Refinanced keeps its three indexed fields");
        assertEq(r.topics[2], bytes32(newId), "naming the successor");
        assertEq(r.data.length, 96, "and its three data words");
    }

    function test_RefinanceTo_TheLegLogsBeforeItsRelease() public {
        uint256 oldId = _open(flat, COLL, P);
        vm.recordLogs();
        uint256 newId = _migrate(_args(oldId, flat, NEWP, TAKE, sink));
        Vm.Log[] memory logs = vm.getRecordedLogs();
        uint256 logged = LogScan.indexOf(logs, RecipientEvents.WITHDRAWN, address(ace), newId);
        uint256 moved = LogScan.transferTo(logs, address(vault), sink);
        assertLt(logged, logs.length, "the leg is logged");
        assertLt(moved, logs.length, "and the release moved the units");
        assertEq(logs[moved].topics[1], LogScan.word(address(pm)), "the transfer found is the custodian's release");
        assertEq(abi.decode(logs[moved].data, (uint256)), TAKE, "of exactly the leg's units");
        assertLt(logged, moved, "the event precedes the transfer it describes, as withdrawCollateral's does");
    }

    function test_RefinanceTo_ZeroUnitsToANamedRecipientLogsNoWithdrawal() public {
        uint256 oldId = _open(flat, COLL, P);
        vm.recordLogs();
        uint256 newId = _migrate(_args(oldId, flat, NEWP, 0, sink));
        Vm.Log[] memory logs = vm.getRecordedLogs();
        assertEq(LogScan.count(logs, RecipientEvents.WITHDRAWN, address(ace)), 0, "a leg that sheds nothing logs nothing");
        assertEq(LogScan.count(logs, RecipientEvents.WITHDRAWN_OLD, address(ace)), 0, "under either signature");
        assertLt(LogScan.indexOf(logs, RecipientEvents.REFINANCED, address(ace), oldId), logs.length, "control: the refinance landed");
        assertEq(read.loan(newId).collateralUnits, COLL, "and carried the whole lot");
    }
}

/// @notice The published fold: a live loan's lot is `Opened.collateralUnits` less every `CollateralWithdrawn.units` and `Deleveraged.unitsSold`.
/// @notice Folded from the RECORDED logs alone, across a partially filled crank, so the net-fill term is the one under test.
/// @dev The crank hands back half its release, so a fold that read the release, or dropped the crank, misses by a nonzero amount.
contract AceEventRecipientsFoldTest is WarpClock {
    Ace internal ace;
    AceReader internal read;
    AceLens internal lens;
    PositionManager internal pm;
    MockERC20 internal usdc;
    MockStakeVault internal vault;
    MockPersistenceRecord internal record;
    MockDeleverageKeeper internal keeper;
    bytes32 internal mid;
    address internal constant BORROWER = address(0xB0B);
    address internal constant RECIPIENT = address(0xCA401); // the first third-party recipient
    address internal constant LATER = address(0xCA402); // the second, so each withdrawal's recipient is its own
    uint256 internal constant COLL = 10_000e18;
    uint256 internal constant PRINCIPAL = 4_500e6;
    uint256 internal constant NEWP = 4_700e6; // over the old draw, so the refinance netting needs no repay leg
    uint256 internal constant TAKE = 500e18; // the first withdrawal, well inside the line at the healthy price
    uint256 internal constant BAND_BPS = 3000;
    uint256 internal constant REFUND_BPS = 5000; // the route hands back half of what it was released

    /// @dev What the fold read off the logs for one id, with the count of each term so none is vacuous.
    struct Fold {
        uint256 opened;
        uint256 withdrawn;
        uint256 sold;
        uint256 nOpened;
        uint256 nWithdrawn;
        uint256 nSold;
    }

    function setUp() public {
        _warpTo(1_000_000);
        usdc = new MockERC20("USD Coin", "USDC", 6);
        vault = new MockStakeVault(42);
        record = new MockPersistenceRecord(address(usdc), address(vault));
        MarketParams memory p = AceFixtures.marketParams(address(usdc), address(vault));
        p.record = address(record);
        p.deleverageFloorEpsBps = 100;
        p.deleverageBandBps = BAND_BPS;
        p.deleverageTargetBps = 4000;
        p.deleverageStopBps = 1;
        AceFixtures.Deployment memory d = AceFixtures.deploy(p);
        (ace, pm, read, mid) = (d.ace, d.positionManager, d.read, d.id);
        lens = new AceLens(address(ace));
        keeper = new MockDeleverageKeeper(ace, address(usdc), address(vault), read.marketState(mid).unitScale);
        usdc.mint(AceFixtures.LENDER, 15_000e6);
        vm.startPrank(AceFixtures.LENDER);
        usdc.approve(address(ace), type(uint256).max);
        ace.deposit(mid, 15_000e6);
        vm.stopPrank();
    }

    function _open() internal returns (uint256 id) {
        vault.mint(BORROWER, COLL);
        vm.startPrank(BORROWER);
        vault.approve(address(pm), COLL);
        id = ace.open(mid, COLL, PRINCIPAL, 0, BORROWER, OpenBounds(0, 0, 0));
        vm.stopPrank();
    }

    function _withdraw(uint256 id, uint256 units, address to) internal {
        vm.prank(BORROWER);
        ace.withdrawCollateral(id, units, to);
    }

    /// @dev Parks the record in band 5% over the trigger, then cranks with half the release refused: a partial fill.
    /// @dev `kept` is read off the keeper's own refund rule, never off the hub, so a hub that books the release cannot set it.
    function _partialCrank(uint256 id) internal returns (uint256 filled, uint256 kept) {
        uint256 trig = read.triggerPrice(id);
        record.setBelowBand(FullMath.mulDivRoundingUp(trig, 1e18, 1e18 - BAND_BPS * 1e14));
        record.setMinPrice((trig * 105) / 100);
        keeper.setRefundBps(REFUND_BPS);
        (filled,) = keeper.crankDeleverage(id);
        uint256 released = keeper.lastUnitsSold();
        kept = released - (released * REFUND_BPS) / 10000;
        assertGt(kept, 0, "fixture: the route kept some of the release");
        assertLt(kept, released, "fixture: and handed the rest back, so the net fill and the release differ");
    }

    /// @dev Half of what the shipped lens says the loan may still shed at the record's current price.
    function _halfFree(uint256 id) internal view returns (uint256 take) {
        take = lens.withdrawableUnits(mid, id) / 2;
        assertGt(take, 0, "fixture: the loan still has room to shed");
    }

    /// @dev Folds the logs for `id`, checking each `unitsLeft` against the running fold as of its own log.
    function _fold(Vm.Log[] memory logs, uint256 id) internal view returns (Fold memory f) {
        for (uint256 i; i < logs.length; i++) {
            Vm.Log memory l = logs[i];
            if (l.emitter != address(ace) || l.topics.length < 2 || l.topics[1] != bytes32(id)) continue;
            if (l.topics[0] == RecipientEvents.OPENED) {
                (f.opened,,,) = abi.decode(l.data, (uint256, uint256, uint256, uint64));
                f.nOpened++;
            } else if (l.topics[0] == RecipientEvents.WITHDRAWN) {
                assertEq(f.nOpened, 1, "Opened precedes every withdrawal it is folded against");
                (uint256 units, uint256 left,) = abi.decode(l.data, (uint256, uint256, uint256));
                f.withdrawn += units;
                f.nWithdrawn++;
                assertEq(left, f.opened - f.withdrawn - f.sold, "unitsLeft is the fold as of its own log");
            } else if (l.topics[0] == RecipientEvents.DELEVERAGED) {
                (uint256 sold,,) = abi.decode(l.data, (uint256, uint256, uint256));
                f.sold += sold;
                f.nSold++;
            }
        }
    }

    /// @dev The fold must equal both the ledger and the custodian's balance, which holds only this loan's units.
    function _assertFoldIsLedger(Vm.Log[] memory logs, uint256 id, string memory why) internal view returns (Fold memory f) {
        f = _fold(logs, id);
        uint256 ledger = read.loan(id).collateralUnits;
        assertEq(f.opened - f.withdrawn - f.sold, ledger, why);
        assertEq(vault.balanceOf(address(pm)), ledger, "and custody holds exactly that many units");
    }

    /// @dev `getRecordedLogs` drains the buffer, so a row that folds mid-sequence stitches the two drains back together.
    function _concat(Vm.Log[] memory a, Vm.Log[] memory b) internal pure returns (Vm.Log[] memory c) {
        c = new Vm.Log[](a.length + b.length);
        for (uint256 i; i < a.length; i++) {
            c[i] = a[i];
        }
        for (uint256 i; i < b.length; i++) {
            c[a.length + i] = b[i];
        }
    }

    /// @dev The fold is checked right after the crank as well as at the end, so a ledger the crank got wrong fails on the fold itself.
    function test_Fold_OpenedLessWithdrawnLessNetFill_IsTheLiveLedger() public {
        vm.recordLogs();
        uint256 id = _open();
        _withdraw(id, TAKE, RECIPIENT);
        (uint256 filled, uint256 kept) = _partialCrank(id);
        Vm.Log[] memory early = vm.getRecordedLogs();
        _assertFoldIsLedger(early, id, "the published fold IS the live ledger, right after the crank");
        uint256 later = _halfFree(id);
        _withdraw(id, later, LATER);
        Vm.Log[] memory logs = _concat(early, vm.getRecordedLogs());

        Fold memory f = _assertFoldIsLedger(logs, id, "the published fold IS the live ledger, after the last withdrawal");
        assertEq(filled, kept, "the crank returns the units the route kept");
        assertEq(f.nOpened, 1, "one Opened");
        assertEq(f.nWithdrawn, 2, "two withdrawals");
        assertEq(f.nSold, 1, "one crank");
        assertEq(f.opened, COLL, "Opened logs the whole lot");
        assertEq(f.withdrawn, TAKE + later, "each withdrawal logs what its call took");
        assertEq(f.sold, kept, "the crank logs its net fill, not its release");
        assertEq(read.loan(id).collateralUnits, COLL - TAKE - kept - later, "the ledger is the lot less each take, net of the refund");
        assertEq(vault.balanceOf(RECIPIENT), TAKE, "control: the first recipient got the first withdrawal");
        assertEq(vault.balanceOf(LATER), later, "and the second the second");
    }

    /// @notice The same fold on a `refinanceTo` successor: its `Opened` is the lot BEFORE its own leg, which it then logs.
    function test_Fold_RefinancedSuccessor_FromItsOpenedThroughItsLegAndACrank() public {
        uint256 oldId = _open();
        uint64 tenor = ace.idToMarketParams(mid).minTenor; // HOISTED: a call in the argument list eats the prank
        vm.recordLogs();
        vm.prank(BORROWER);
        uint256 newId = ace.refinanceTo(MigrateArgs(oldId, mid, NEWP, tenor, OpenBounds(0, 0, 0), TAKE, RECIPIENT));
        (uint256 filled, uint256 kept) = _partialCrank(newId);
        Vm.Log[] memory early = vm.getRecordedLogs();
        _assertFoldIsLedger(early, newId, "the published fold IS the successor's live ledger, right after the crank");
        uint256 later = _halfFree(newId);
        _withdraw(newId, later, LATER);
        Vm.Log[] memory logs = _concat(early, vm.getRecordedLogs());

        Fold memory f = _assertFoldIsLedger(logs, newId, "the published fold IS the successor's live ledger, after the last withdrawal");
        assertEq(filled, kept, "the crank returns the units the route kept");
        assertEq(f.nOpened, 1, "one Opened for the successor");
        assertEq(f.nWithdrawn, 2, "the leg and the later withdrawal");
        assertEq(f.nSold, 1, "one crank");
        assertEq(f.opened, COLL, "the successor's Opened logs the carried lot, before its leg");
        assertEq(f.withdrawn, TAKE + later, "the leg and the withdrawal log what each took");
        assertEq(f.sold, kept, "the crank logs its net fill, not its release");
        assertEq(read.loan(newId).collateralUnits, COLL - TAKE - kept - later, "the ledger is the carried lot less each take, net of the refund");
        assertEq(vault.balanceOf(RECIPIENT), TAKE, "control: the leg's recipient got the leg");
        assertEq(vault.balanceOf(LATER), later, "and the later recipient the later withdrawal");
    }
}
