// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.36;

import {WarpClock} from "../utils/WarpClock.sol";
import {FullMath} from "@uniswap/v4-core/src/libraries/FullMath.sol";
import {Ace} from "../../src/ace/hub/Ace.sol";
import {GateRefused, NoRecordPrice} from "../../src/ace/hub/Borrower.sol";
import {MarketParams, OpenBounds} from "../../src/ace/hub/Types.sol";
import {PositionManager} from "../../src/ace/positions/PositionManager.sol";
import {MockERC20} from "../mocks/MockERC20.sol";
import {MockDeleverageKeeper} from "../mocks/MockDeleverageKeeper.sol";
import {MockPersistenceRecord} from "../mocks/MockPersistenceRecord.sol";
import {FloodRecord, SelectiveRecord} from "../mocks/UntrustedDependencyMocks.sol";
import {AceFixtures} from "../utils/AceFixtures.sol";
import {ProtocolPolicy} from "../../src/config/Defaults.sol";
import {AceReader} from "../utils/AceReader.sol";

error RecordUnreadable(); // the record did not answer at all; mirrors the src error, same name and arity so the same selector

/// @notice The hub's total continuation door, declared test-side as the neighbouring fold suites declare it.
interface IAceAuto {
    function setAutoRefinance(uint256 id, uint64 tenor, uint16 minBufferBps, uint16 maxFeeBps) external;
    function tryContinue(uint256 id) external view returns (bool ok, bytes4 reason, uint256 principal);
}

/// @title AceUntrustedCallBounds
/// @notice THE INVARIANT: a bound on the COPY is not an answer. `ok = false` must never read as `false`.
/// @notice Every runtime site that reverts on a sick dependency today must still revert once it is rewired.
/// @notice The two already-total sites keep their answers; the six bubbling ones keep their refusal.
/// @dev One test per site, each with a dependency that cannot answer, asserting the site fails CLOSED.
/// @dev The sharp cases are the ones where `false` is PERMISSIVE, and they are named as such below.
/// @dev EVERY SITE CARRIES TWO INDEPENDENT PROPERTIES: totality (it fails closed) and boundedness (it copies one word).
/// @dev Tag each site for BOTH. Site 2 once read "already total" alone and stayed unbounded behind a tag that looked complete.
/// @dev The bomb tests below must therefore cover every DOOR, not every site: two measured `deposit` while the fold went unmeasured.
contract AceUntrustedCallBoundsTest is WarpClock {
    Ace internal ace;
    AceReader internal read;
    PositionManager internal pm;

    MockERC20 internal usdc; // quote, 6 decimals
    MockERC20 internal coll; // collateral, 18 decimals
    MockPersistenceRecord internal record;
    SelectiveRecord internal selective;

    bytes32 internal mid; // a healthy record; the gate doors this suite used to probe no longer exist
    bytes32 internal sid; // a record whose `persistedBelow` can be made unanswerable

    address internal alice = address(0xA11CE); // the lender
    address internal borrower = address(0xB0B);

    uint256 internal TOP; // the ladder's top, named as a distance from this pair's par; assigned in setUp
    uint256 internal constant DEPOSIT = 20_000e6;
    uint256 internal constant PRINCIPAL = 4_500e6;
    uint256 internal constant COLL = 10_000e18;
    uint64 internal constant TEN7 = 7 days;

    OpenBounds internal OFF = OpenBounds(0, 0, 0);

    /// @dev This suite's pair, so a tick reads as its distance from par rather than as a grid coordinate.
    /// @param offset Ticks above par.
    /// @return The absolute grid tick.
    function _price(int24 offset) internal view returns (uint256) {
        return AceFixtures.priceAt(address(usdc), address(coll), offset);
    }

    function setUp() public {
        _warpTo(1_000_000);
        usdc = new MockERC20("USD Coin", "USDC", 6);
        coll = new MockERC20("Collateral", "COLL", 18);
        TOP = _price(0);
        record = new MockPersistenceRecord(address(usdc), address(coll));
        record.setMinPrice(AceFixtures.px(2e18, address(usdc), address(coll)));
        MarketParams memory p = AceFixtures.marketParams(address(usdc), address(coll));
        p.record = address(record);
        AceFixtures.Deployment memory d = AceFixtures.deploy(p);
        (ace, pm, read, mid) = (d.ace, d.positionManager, d.read, d.id);

        selective = new SelectiveRecord(address(usdc), address(coll));
        MarketParams memory q = AceFixtures.marketParams(address(usdc), address(coll));
        q.record = address(selective);
        sid = ace.createMarket(q);
    }

    /* ====== site 2: Borrower `tryPersistedPrice` -- total AND bounded; the caller does the refusing ====== */

    /// @notice A record that cannot answer leaves the continuation predicate refusing, never admitting.
    /// @dev `NoRecordPrice` is PRESERVED here: the total side has no revert to name, so it keeps its own selector.
    function test_Site2_TryPersistedPrice_ASickRecordReadsUnusable_NotUncapped() public {
        uint256 loanId = _armedLoan();
        _warpTo(read.loan(loanId).expiry + 1);
        record.setSick(true);

        (bool ok, bytes4 reason,) = IAceAuto(address(ace)).tryContinue(loanId);
        assertFalse(ok, "FAIL-OPEN: an unreadable record admitted a continuation");
        assertEq(reason, NoRecordPrice.selector, "and the refusal must still name the record");
    }

    /// @notice The total side CONFLATES the two record states the bubbling sites now separate by selector.
    /// @notice A record that answered zero and one that could not answer both attribute `NoRecordPrice` here.
    /// @dev Pinned so the conflation is a visible ruling rather than an accident of `tryPersistedPrice`'s shape.
    /// @dev It is safe -- both refuse -- but the deposit door's fail-open branch turns on exactly this distinction.
    function test_Site2b_TheTotalSide_ReportsOneReasonForBothRecordStates() public {
        uint256 loanId = _armedLoan();
        _warpTo(read.loan(loanId).expiry + 1);

        record.setMinPrice(0); // ANSWERED zero: a ring short of the window, a stale feed
        (bool answeredZero, bytes4 zeroReason,) = IAceAuto(address(ace)).tryContinue(loanId);
        record.setMinPrice(AceFixtures.px(2e18, address(usdc), address(coll)));
        record.setSick(true); // did not answer at all
        (bool unreadable, bytes4 sickReason,) = IAceAuto(address(ace)).tryContinue(loanId);

        assertFalse(answeredZero || unreadable, "both record states must refuse the continuation");
        assertEq(zeroReason, sickReason, "the total side reports ONE reason for both, which is the ruling");
        assertEq(zeroReason, NoRecordPrice.selector, "and that reason is NoRecordPrice");
    }

    /* ====== site 4: Borrower `persistedPrice` -- bubbles today, and the fold-to-false is PERMISSIVE ====== */

    /// @notice THE SHARP DEPOSIT CASE, and it fails by ADMISSION rather than by reverting.
    /// @notice `recordState` maps a zero cap to NoPrice, and `restRefusal`'s NoPrice arm admits, deliberately.
    /// @notice So folding `!ok` into a zero cap opens the lending door on a record nothing can read, silently.
    /// @dev The lot assertions run FIRST: under the naive rewire there is no revert at all for an expectRevert to catch.
    /// @dev RED TODAY on the selector only -- the fail-closed half is already true, and must stay true.
    function test_Site4_PersistedPrice_AnUnreadableRecordRefusesTheDeposit_NeverAdmitsIt() public {
        record.setSick(true);
        usdc.mint(alice, DEPOSIT);
        vm.startPrank(alice);
        usdc.approve(address(ace), DEPOSIT);
        (bool ok, bytes memory ret) = address(ace).call(abi.encodeCall(Ace.deposit, (mid, DEPOSIT)));
        vm.stopPrank();

        assertEq(ace.restingOf(mid), 0, "FAIL-OPEN: cash was booked against a record nothing can read");
        assertEq(read.poolResting(mid), 0, "FAIL-OPEN: cash reached the lender pool on an unreadable record");
        assertFalse(ok, "FAIL-OPEN: the lending door admitted a deposit on an unreadable record");
        assertEq(_selectorOf(ret), RecordUnreadable.selector, "UNREADABLE is not NoPrice: the admitting branch turns on that");
    }

    /// @notice The same read on the draw door: an unreadable record must refuse the open, never uncap it.
    /// @dev RED TODAY: the record's own revert bubbles.
    function test_Site4b_PersistedPrice_AnUnreadableRecordRefusesTheDraw() public {
        _lend(mid);
        record.setSick(true);
        coll.mint(borrower, COLL);
        vm.startPrank(borrower);
        coll.approve(address(pm), COLL);
        vm.expectRevert(RecordUnreadable.selector);
        ace.open(mid, COLL, PRINCIPAL, TEN7, borrower, OFF);
        vm.stopPrank();
    }

    /* ====== site 7: Settlement `finalize` -- bubbles today, must keep failing closed ====== */

    /// @notice A record that cannot answer must not let the settlement door open on an unproved distress.
    /// @dev RED TODAY: the record's own revert bubbles, so the selector is its string and not this one.
    /// @dev `NotSettleable` would read as a deliberate NO about a record that never spoke; the ruling refuses that.
    function test_Site7_Finalize_AnUnanswerableRecordKeepsTheDoorShut() public {
        uint256 loanId = _plainLoanOnSelective();
        selective.setBreakWindow(1, type(uint256).max); // no threshold at all can be answered

        vm.expectRevert(RecordUnreadable.selector);
        ace.finalize(loanId);
        assertFalse(ace.isClosed(loanId), "FAIL-OPEN: settlement ran without the record proving distress");
    }

    /// @dev The custom-error selector a raw call came back with; zero when the revert carried no selector.
    function _selectorOf(bytes memory ret) internal pure returns (bytes4 sel) {
        if (ret.length < 4) return bytes4(0);
        assembly ("memory-safe") {
            sel := mload(add(ret, 32))
        }
    }

    /* ============== the returndata bound: the hub pays for one word of any pile ============== */

    /// @notice The same bound on the record leg: a windowed-min answer of any size costs the hub one word.
    /// @dev Same assertion shape as the gate leg above, and for the same reason.
    function test_ReturnBomb_ThePriceReadCopiesOneWord_NotTheWholePile() public {
        FloodRecord r = new FloodRecord(address(usdc), address(coll));
        MarketParams memory p = AceFixtures.marketParams(address(usdc), address(coll));
        p.record = address(r);
        bytes32 fid = ace.createMarket(p);
        bytes memory call_ = abi.encodeWithSignature("minPrice(address,address)", address(usdc), address(coll));

        r.setWords(1);
        uint256 recSmall = _calleeCost(address(r), call_);
        uint256 depSmall = _depositCost(fid);

        r.setWords(32_768);
        uint256 recBig = _calleeCost(address(r), call_);
        uint256 depBig = _depositCost(fid);

        uint256 callee = recBig - recSmall;
        assertGt(callee, 1_000_000, "fixture: the pile must really cost the CALLEE a megabyte's expansion");
        assertLe(depBig - depSmall, callee + 1_000, "the price read billed the caller for the record's own pile");
    }

    /// @notice The bound where it decides LIVENESS: the fold's own predicate read, not the deposit door's.
    /// @notice Both bomb tests above measure `deposit`, so site 2 could stay unbounded while they passed.
    /// @dev `tryPersistedPrice` is what `forceCloseOrContinue` asks before it must settle, so a pile HERE
    /// @dev inflates the frame that owes the settlement, which is the one frame that cannot be retried cheaper.
    function test_ReturnBomb_TheFoldsOwnPredicateCopiesOneWord_NotTheWholePile() public {
        FloodRecord r = new FloodRecord(address(usdc), address(coll));
        MarketParams memory p = AceFixtures.marketParams(address(usdc), address(coll));
        p.record = address(r);
        bytes32 fid = ace.createMarket(p);
        bytes memory call_ = abi.encodeWithSignature("minPrice(address,address)", address(usdc), address(coll));
        uint256 loanId = _armedLoanOn(fid);

        r.setWords(1);
        uint256 recSmall = _calleeCost(address(r), call_);
        uint256 foldSmall = _foldCost(loanId);

        r.setWords(32_768); // one mebibyte of answer
        uint256 recBig = _calleeCost(address(r), call_);
        uint256 foldBig = _foldCost(loanId);

        uint256 callee = recBig - recSmall;
        assertGt(callee, 1_000_000, "fixture: the pile must really cost the CALLEE a megabyte's expansion");
        assertLe(foldBig - foldSmall, callee + 1_000, "the fold's predicate billed the caller for the record's own pile");
    }

    /* ================================= fixture ================================= */

    /// @dev One fold's cost, under a snapshot: the crank ends the loan either way, so it runs once per measurement.
    function _foldCost(uint256 loanId) internal returns (uint256 cost) {
        uint256 snap = vm.snapshotState();
        uint256 g0 = gasleft();
        ace.forceClose(loanId);
        cost = g0 - gasleft();
        vm.revertToState(snap);
        _warpTo(_now());
    }

    /// @dev An armed loan on a caller-chosen market, warped to expiry so the fold's predicate is what runs next.
    function _armedLoanOn(bytes32 m) internal returns (uint256 loanId) {
        usdc.mint(alice, DEPOSIT);
        vm.startPrank(alice);
        usdc.approve(address(ace), DEPOSIT);
        ace.deposit(m, DEPOSIT);
        vm.stopPrank();
        coll.mint(borrower, COLL);
        vm.startPrank(borrower);
        coll.approve(address(pm), COLL);
        loanId = ace.open(m, COLL, PRINCIPAL, TEN7, borrower, OFF);
        IAceAuto(address(ace)).setAutoRefinance(loanId, TEN7, 0, 0);
        vm.stopPrank();
        _warpTo(_now() + TEN7);
    }

    /// @dev A callee's OWN cost, with a zero-length output window so the caller copies nothing.
    function _calleeCost(address target, bytes memory data) internal view returns (uint256 cost) {
        uint256 g0 = gasleft();
        assembly ("memory-safe") {
            pop(staticcall(gas(), target, add(data, 32), mload(data), 0, 0))
        }
        cost = g0 - gasleft();
    }

    /// @dev One deposit's cost on a market, taken under a snapshot so the measurement leaves no lot behind.
    function _depositCost(bytes32 m) internal returns (uint256 cost) {
        uint256 snap = vm.snapshotState();
        usdc.mint(alice, DEPOSIT);
        vm.startPrank(alice);
        usdc.approve(address(ace), DEPOSIT);
        uint256 g0 = gasleft();
        ace.deposit(m, DEPOSIT);
        cost = g0 - gasleft();
        vm.stopPrank();
        vm.revertToState(snap);
        _warpTo(_now());
    }

    function _lend(bytes32 m) internal {
        usdc.mint(alice, DEPOSIT);
        vm.startPrank(alice);
        usdc.approve(address(ace), DEPOSIT);
        ace.deposit(m, DEPOSIT);
        vm.stopPrank();
    }

    function _armedLoan() internal returns (uint256 loanId) {
        _lend(mid);
        coll.mint(borrower, COLL);
        vm.startPrank(borrower);
        coll.approve(address(pm), COLL);
        loanId = ace.open(mid, COLL, PRINCIPAL, TEN7, borrower, OFF);
        IAceAuto(address(ace)).setAutoRefinance(loanId, TEN7, 0, 0);
        vm.stopPrank();
    }

    function _plainLoanOnSelective() internal returns (uint256 loanId) {
        _lend(sid);
        coll.mint(borrower, COLL);
        vm.startPrank(borrower);
        coll.approve(address(pm), COLL);
        loanId = ace.open(sid, COLL, PRINCIPAL, TEN7, borrower, OFF);
        vm.stopPrank();
    }
}

/// @title AceDeleverageCallBounds
/// @notice Sites 5 and 8, both on the deleverage path, and both PERMISSIVE if `!ok` ever reads as `false`.
/// @notice `inDistress` false ADMITS a sale the settlement machine owns; a folded band check ADMITS one out of band.
/// @dev Each has a non-vacuity twin: the same fixture with the record answering, where the crank really does sell.
contract AceDeleverageCallBoundsTest is WarpClock {
    Ace internal ace;
    AceReader internal read;
    PositionManager internal pm;

    MockERC20 internal usdc;
    MockERC20 internal coll;
    SelectiveRecord internal record;
    MockDeleverageKeeper internal keeper;
    bytes32 internal mid;

    address internal alice = address(0xA11CE);
    address internal borrower = address(0xB0B);

    uint256 internal constant COLL = 10_000e18;
    uint256 internal constant PRINCIPAL = 4_500e6;
    uint256 internal P; // healthy market price, in the hub's frame; assigned in setUp
    uint256 internal PS_BAND; // inside the band over the ~0.63 trigger, in the hub's frame
    uint256 internal T_PAR; // par for this pair, where the ladder rests
    uint256 internal constant UNIT_SCALE = 1 << 96; // every market's scale under the atom frame
    uint256 internal constant BAND_BPS = 3000;
    uint256 internal constant TARGET_BPS = 4000;

    /// @dev This suite's pair, so a tick reads as its distance from par rather than as a grid coordinate.
    /// @param offset Ticks above par.
    /// @return The absolute grid tick.
    function _price(int24 offset) internal view returns (uint256) {
        return AceFixtures.priceAt(address(usdc), address(coll), offset);
    }

    function setUp() public {
        _warpTo(1_000_000);
        usdc = new MockERC20("USD Coin", "USDC", 6);
        coll = new MockERC20("Collateral", "COLL", 18);
        T_PAR = _price(0);
        P = AceFixtures.px(2e18, address(usdc), address(coll));
        PS_BAND = AceFixtures.px(0.7e18, address(usdc), address(coll));
        record = new SelectiveRecord(address(usdc), address(coll));
        record.setMinPrice(P);

        MarketParams memory p = AceFixtures.marketParams(address(usdc), address(coll));
        p.record = address(record);
        p.deleverageFloorEpsBps = ProtocolPolicy.DELEVERAGE_FLOOR_EPS_BPS;
        p.deleverageBandBps = BAND_BPS;
        p.deleverageTargetBps = TARGET_BPS;
        p.deleverageStopBps = 1;
        AceFixtures.Deployment memory d = AceFixtures.deploy(p);
        (ace, pm, read, mid) = (d.ace, d.positionManager, d.read, d.id);
        keeper = new MockDeleverageKeeper(ace, address(usdc), address(coll), UNIT_SCALE);

        usdc.mint(alice, 15_000e6);
        vm.startPrank(alice);
        usdc.approve(address(ace), 15_000e6);
        ace.deposit(mid, 15_000e6);
        vm.stopPrank();
    }

    /* ====== site 5: Borrower `inDistress` at Deleverage:73 -- `false` ADMITS the sale ====== */

    /// @notice The non-vacuity half: with the record answering, this exact fixture SELLS.
    /// @dev Without it, the assertion below could be passing on any unrelated refusal.
    function test_Site5_Control_TheSameFixtureDeleveragesWhenTheRecordAnswers() public {
        uint256 loanId = _openInBand();
        (uint256 sold,) = keeper.crankDeleverage(loanId);
        assertGt(sold, 0, "fixture: the crank must sell here, or the broken-record case proves nothing");
    }

    /// @notice THE SHARP ONE: a record that cannot answer the DISTRESS question must stop the sale dead.
    /// @notice Folding `!ok` into `false` here inverts a safety check and admits a sale on a distressed loan.
    /// @dev The units assertion runs FIRST: under the folded rewire there is no revert for an expectRevert to catch.
    /// @dev RED TODAY on the selector only -- the fail-closed half is already true, and must stay true.
    function test_Site5_InDistress_AnUnanswerableRecordStopsTheSale_NeverAdmitsIt() public {
        uint256 loanId = _openInBand();
        uint256 trig = read.triggerPrice(loanId);
        record.setBreakWindow(1, trig); // only the distress question is unanswerable; the band question still answers
        uint256 units = read.loan(loanId).collateralUnits;

        (bool ok, bytes memory ret) = address(keeper).call(abi.encodeCall(MockDeleverageKeeper.crankDeleverage, (loanId)));
        assertEq(read.loan(loanId).collateralUnits, units, "FAIL-OPEN: a sale ran against a loan whose distress is unknown");
        assertFalse(ok, "FAIL-OPEN: the sale completed with the safety guard unanswered");
        assertEq(_selectorOf(ret), RecordUnreadable.selector, "and it must refuse as UNREADABLE, never as a clean not-distressed");
    }

    /* ====== site 8: the band check at Deleverage:80 -- `ok && w != 1` would ADMIT ====== */

    /// @notice A record that cannot answer the BAND question must refuse the sale, and say the RECORD is why.
    /// @notice `NotInBand` would be a false claim -- the band gate saying no about a record that never spoke.
    /// @dev The units assertion runs FIRST: `ok && w != 1 -> NotInBand` admits, and admission carries no revert.
    /// @dev RED TODAY: the record's own revert bubbles.
    function test_Site8_BandCheck_AnUnanswerableRecordRefusesAsUnreadable_NotAsOutOfBand() public {
        uint256 loanId = _openInBand();
        uint256 trig = read.triggerPrice(loanId);
        record.setBreakWindow(trig + 1, type(uint256).max); // the distress question still answers; the band one does not
        uint256 units = read.loan(loanId).collateralUnits;

        (bool ok, bytes memory ret) = address(keeper).call(abi.encodeCall(MockDeleverageKeeper.crankDeleverage, (loanId)));
        assertEq(read.loan(loanId).collateralUnits, units, "FAIL-OPEN: a sale ran without the band ever being proved");
        assertFalse(ok, "FAIL-OPEN: the sale completed on a band the record never answered");
        assertEq(_selectorOf(ret), RecordUnreadable.selector, "the band gate must not claim a NO the record never gave");
    }

    /// @dev The custom-error selector a raw call came back with; zero when the revert carried no selector.
    function _selectorOf(bytes memory ret) internal pure returns (bytes4 sel) {
        if (ret.length < 4) return bytes4(0);
        assembly ("memory-safe") {
            sel := mload(add(ret, 32))
        }
    }

    /* ================================= fixture ================================= */

    /// @dev A loan sitting inside the deleverage band, priced exactly as the channel's own suite prices it.
    function _openInBand() internal returns (uint256 loanId) {
        coll.mint(borrower, COLL);
        vm.startPrank(borrower);
        coll.approve(address(pm), COLL);
        loanId = ace.open(mid, COLL, PRINCIPAL, 0, borrower, OpenBounds(0, 0, 0));
        vm.stopPrank();

        uint256 trig = read.triggerPrice(loanId);
        uint256 bandLevel = FullMath.mulDivRoundingUp(trig, 1e18, 1e18 - BAND_BPS * 1e14);
        record.setBandPrice((bandLevel * 99) / 100); // below-ness holds at the band level, not at the trigger
        record.setMinPrice(PS_BAND);
    }
}
