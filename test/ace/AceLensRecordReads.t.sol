// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.36;

import {WarpClock} from "../utils/WarpClock.sol";
import {FullMath} from "@uniswap/v4-core/src/libraries/FullMath.sol";
import {Ace} from "../../src/ace/hub/Ace.sol";
import {RecordUnreadable} from "../../src/ace/hub/Borrower.sol";
import {MarketParams, OpenBounds} from "../../src/ace/hub/Types.sol";
import {PositionManager} from "../../src/ace/positions/PositionManager.sol";
import {AceLens} from "../../src/ace/lens/AceLens.sol";
import {IPersistenceRecord} from "../../src/interfaces/IPersistenceRecord.sol";
import {MockERC20} from "../mocks/MockERC20.sol";
import {MockDeleverageKeeper} from "../mocks/MockDeleverageKeeper.sol";
import {AceFixtures} from "../utils/AceFixtures.sol";
import {ProtocolPolicy} from "../../src/config/Defaults.sol";
import {AceReader} from "../utils/AceReader.sol";

/// @notice A record whose answers can be piled, refused, cut short or made dirty, one knob per question.
/// @dev `persistedBelow*(x)` answers `x > bandPrice`, as `SelectiveRecord` does, so the trigger and the band level can differ.
contract PileRecord is IPersistenceRecord {
    enum Mode {
        Answer,
        Revert,
        Short,
        Dirty
    }

    address public immutable QUOTE; // the ordered pair genesis binds against
    address public immutable COLLATERAL; // its collateral half
    uint256 public windowMin; // the minimum it answers
    uint256 public bandPrice; // below-ness holds at any level above this
    uint256 public words = 1; // how many words each answer carries: the pile a reader must not pay for
    Mode public belowMode; // how both persisted-below questions answer
    Mode public priceMode; // how the minimum answers

    constructor(address quote, address collateral) {
        QUOTE = quote;
        COLLATERAL = collateral;
    }

    function setWords(uint256 n) external {
        words = n;
    }

    uint256 public priceWords; // when set, the minimum's own pile, apart from `words`: it is read under the hub's budget

    function setPriceWords(uint256 n) external {
        priceWords = n;
    }

    function setMinPrice(uint256 v) external {
        windowMin = v;
    }

    function setBandPrice(uint256 v) external {
        bandPrice = v;
    }

    function setBelowMode(Mode m) external {
        belowMode = m;
    }

    function setPriceMode(Mode m) external {
        priceMode = m;
    }

    function supportsPair(address quote, address collateral) external view returns (bool) {
        return quote == QUOTE && collateral == COLLATERAL;
    }

    function persistedBelowDistress(address, address, uint256 x) external view returns (bool below) {
        _answer(belowMode, x > bandPrice ? 1 : 0, words);
    }

    function persistedBelowSettle(address, address, uint256 x) external view returns (bool below) {
        _answer(belowMode, x > bandPrice ? 1 : 0, words);
    }

    function lastObserved(address, address) external view returns (uint256) {
        return windowMin;
    }

    function minPrice(address, address) external view returns (uint256 price) {
        _answer(priceMode, windowMin, priceWords == 0 ? words : priceWords);
    }

    /// @dev Halts the frame with the answer: a revert, zero bytes, the word 2, or `word` at the head of a `pile`-word pile.
    function _answer(Mode m, uint256 word, uint256 pile) private pure {
        if (m == Mode.Revert) revert("record down");
        if (m == Mode.Dirty) word = 2;
        uint256 n = m == Mode.Short ? 0 : pile * 32;
        assembly ("memory-safe") {
            mstore(0, word)
            return(0, n)
        }
    }
}

/// @title AceLensRecordReadsTest
/// @notice The lens's record reads take the hub's own shape: one word copied, and an unreadable record refused by the hub's selector.
/// @notice Each refusal row pairs the lens with the hub verb that asks the same question, so the two cannot answer differently.
contract AceLensRecordReadsTest is WarpClock {
    Ace internal ace;
    AceLens internal lens;
    AceReader internal read;
    PositionManager internal pm;
    MockERC20 internal usdc;
    MockERC20 internal coll;
    PileRecord internal rec;
    MockDeleverageKeeper internal keeper;
    bytes32 internal mid;
    uint256 internal loanId;

    address internal alice = address(0xA11CE);
    address internal borrower = address(0xB0B);

    uint256 internal constant COLL = 10_000e18;
    uint256 internal constant PRINCIPAL = 4_500e6;
    uint256 internal constant UNIT_SCALE = 1 << 96;
    uint256 internal constant BAND_BPS = 3000;
    uint256 internal constant TARGET_BPS = 4000;
    uint256 internal constant PILE = 32_768; // one mebibyte of answer
    uint256 internal constant PRICE_PILE = 4_096; // 128 KiB: a pile the minimum's capped read can still produce inside the hub's budget
    uint256 internal P; // healthy market price, in the hub's frame; assigned in setUp
    uint256 internal PS_BAND; // inside the band over the ~0.63 trigger, in the hub's frame

    function setUp() public {
        _warpTo(1_000_000);
        usdc = new MockERC20("USD Coin", "USDC", 6);
        coll = new MockERC20("Collateral", "COLL", 18);
        P = AceFixtures.px(2e18, address(usdc), address(coll));
        PS_BAND = AceFixtures.px(0.7e18, address(usdc), address(coll));
        rec = new PileRecord(address(usdc), address(coll));
        rec.setMinPrice(P);

        MarketParams memory p = AceFixtures.marketParams(address(usdc), address(coll));
        p.record = address(rec);
        p.deleverageFloorEpsBps = ProtocolPolicy.DELEVERAGE_FLOOR_EPS_BPS;
        p.deleverageBandBps = BAND_BPS;
        p.deleverageTargetBps = TARGET_BPS;
        p.deleverageStopBps = 1;
        AceFixtures.Deployment memory d = AceFixtures.deploy(p);
        (ace, pm, read, mid) = (d.ace, d.positionManager, d.read, d.id);
        lens = new AceLens(address(ace));
        keeper = new MockDeleverageKeeper(ace, address(usdc), address(coll), UNIT_SCALE);

        usdc.mint(alice, 15_000e6);
        vm.startPrank(alice);
        usdc.approve(address(ace), 15_000e6);
        ace.deposit(mid, 15_000e6);
        vm.stopPrank();

        coll.mint(borrower, COLL);
        vm.startPrank(borrower);
        coll.approve(address(pm), COLL);
        loanId = ace.open(mid, COLL, PRINCIPAL, 0, borrower, OpenBounds(0, 0, 0));
        vm.stopPrank();

        rec.setBandPrice((_bandLevel() * 99) / 100); // below-ness holds at the band level, not at the trigger
        rec.setMinPrice(PS_BAND);
    }

    /* ====== control: with the record answering, every row below reaches the read it is about ====== */

    /// @notice The non-vacuity half: an in-band, undistressed loan, which the crank really does sell.
    function test_Control_TheFixtureIsInBandUndistressedAndCrankable() public {
        assertFalse(lens.settleable(loanId), "fixture: the settle question answers no at the trigger");
        assertFalse(lens.inDistress(loanId), "fixture: so does the distress question");
        assertTrue(lens.deleverageEligible(loanId), "fixture: and the loan is in band, so all three record reads ran");
        (uint256 sold,) = keeper.crankDeleverage(loanId);
        assertGt(sold, 0, "fixture: the crank sells here, so the refusal rows below are not riding some other refusal");
    }

    /* ====== the returndata bound: a reader pays for one word of any pile ====== */

    /// @notice `settleable` copies one word of the settle answer, as `finalize` does.
    function test_ReturnBomb_SettleableCopiesOneWord() public {
        bytes memory q = abi.encodeCall(IPersistenceRecord.persistedBelowSettle, (address(usdc), address(coll), _trig()));
        rec.setWords(1);
        uint256 calleeSmall = _calleeCost(q);
        uint256 small = _settleableCost();
        rec.setWords(PILE);
        uint256 callee = _calleeCost(q) - calleeSmall;
        uint256 big = _settleableCost();

        assertGt(callee, 1_000_000, "fixture: the pile must really cost the RECORD a mebibyte's expansion");
        assertLe(big - small, callee + 1_000, "settleable billed its reader for the record's own pile");
    }

    /// @notice `inDistress` copies one word of the distress answer, as the hub's distress guard does.
    function test_ReturnBomb_InDistressCopiesOneWord() public {
        bytes memory q = abi.encodeCall(IPersistenceRecord.persistedBelowDistress, (address(usdc), address(coll), _trig()));
        rec.setWords(1);
        uint256 calleeSmall = _calleeCost(q);
        uint256 small = _inDistressCost();
        rec.setWords(PILE);
        uint256 callee = _calleeCost(q) - calleeSmall;
        uint256 big = _inDistressCost();

        assertGt(callee, 1_000_000, "fixture: the pile must really cost the RECORD a mebibyte's expansion");
        assertLe(big - small, callee + 1_000, "inDistress billed its reader for the record's own pile");
    }

    /// @notice `deleverageEligible` asks three questions, distress, band and minimum, and copies one word of each.
    /// @dev The minimum is the crank's capped read under `POLICY_GAS`, so its pile is sized to fit that budget; a pile past it is dark, the row below.
    function test_ReturnBomb_DeleverageEligibleCopiesOneWordPerQuestion() public {
        bytes memory qd = abi.encodeCall(IPersistenceRecord.persistedBelowDistress, (address(usdc), address(coll), _trig()));
        bytes memory qb = abi.encodeCall(IPersistenceRecord.persistedBelowDistress, (address(usdc), address(coll), _bandLevel()));
        bytes memory qp = abi.encodeCall(IPersistenceRecord.minPrice, (address(usdc), address(coll)));
        rec.setWords(1);
        rec.setPriceWords(0); // warms the knob's slot, so the baseline's callee reads are not charged a cold access the pile's are not
        uint256 calleeSmall = _calleeCost(qd) + _calleeCost(qb) + _calleeCost(qp);
        uint256 small = _eligibleCost();
        rec.setWords(PILE);
        rec.setPriceWords(PRICE_PILE);
        uint256 pricePile = _calleeCost(qp);
        uint256 callee = _calleeCost(qd) + _calleeCost(qb) + pricePile - calleeSmall;
        uint256 big = _eligibleCost();

        assertGt(callee, 2_000_000, "fixture: the two below piles must really cost the RECORD");
        assertGt(pricePile, 20_000, "fixture: and so must the minimum's");
        assertLt(pricePile, ace.POLICY_GAS(), "fixture: the minimum's pile fits the budget, so the capped read answers");
        assertLe(big - small, callee + 3_000, "deleverageEligible billed its reader for the record's own piles");
    }

    /// @notice A minimum whose pile costs more than `POLICY_GAS` is dark to the crank's capped read: both the lens and the crank refuse `RecordUnreadable`.
    function test_OverBudgetPricePile_DeleverageEligibleRefusesAsTheCrankDoes() public {
        rec.setPriceWords(PILE);
        assertGt(_calleeCost(abi.encodeCall(IPersistenceRecord.minPrice, (address(usdc), address(coll)))), ace.POLICY_GAS(), "fixture: past the budget");
        vm.expectRevert(RecordUnreadable.selector);
        keeper.crankDeleverage(loanId);
        vm.expectRevert(RecordUnreadable.selector);
        lens.deleverageEligible(loanId);
    }

    /* ====== an unreadable record: the lens refuses as the hub does, never with the record's own words ====== */

    /// @notice A reverting settle answer: `finalize` refuses `RecordUnreadable`, and `settleable` says the same.
    function test_Unreadable_RevertingSettleAnswer_SettleableRefusesAsFinalizeDoes() public {
        rec.setBelowMode(PileRecord.Mode.Revert);
        vm.expectRevert(RecordUnreadable.selector);
        ace.finalize(loanId);
        vm.expectRevert(RecordUnreadable.selector);
        lens.settleable(loanId);
    }

    /// @notice A dirty distress word, 2: the hub's crank refuses `RecordUnreadable`, and `inDistress` says the same.
    function test_Unreadable_DirtyDistressWord_InDistressRefusesAsTheCrankDoes() public {
        rec.setBelowMode(PileRecord.Mode.Dirty);
        vm.expectRevert(RecordUnreadable.selector);
        keeper.crankDeleverage(loanId);
        vm.expectRevert(RecordUnreadable.selector);
        lens.inDistress(loanId);
    }

    /// @notice A zero-byte below answer: the crank refuses `RecordUnreadable`, and `deleverageEligible` says the same.
    function test_Unreadable_ShortBelowAnswer_DeleverageEligibleRefusesAsTheCrankDoes() public {
        rec.setBelowMode(PileRecord.Mode.Short);
        vm.expectRevert(RecordUnreadable.selector);
        keeper.crankDeleverage(loanId);
        vm.expectRevert(RecordUnreadable.selector);
        lens.deleverageEligible(loanId);
    }

    /// @notice A reverting minimum with both below answers readable: the crank's price read refuses, and so does the view's.
    function test_Unreadable_RevertingMinimum_DeleverageEligibleRefusesAsTheCrankDoes() public {
        rec.setPriceMode(PileRecord.Mode.Revert);
        vm.expectRevert(RecordUnreadable.selector);
        keeper.crankDeleverage(loanId);
        vm.expectRevert(RecordUnreadable.selector);
        lens.deleverageEligible(loanId);
    }

    /* ====== requiredAtFloor: the deleverage clamp's cap leg, read rather than copied ====== */

    /// @notice A repaid loan carries no debt, so it needs no units at any floor.
    function test_RequiredAtFloor_ZeroOnceTheDebtIsGone() public {
        assertGt(lens.requiredAtFloor(loanId), 0, "PREMISE: a live loan needs units at its floor");
        uint256 debt = read.loan(loanId).debt;
        usdc.mint(borrower, debt);
        vm.startPrank(borrower);
        usdc.approve(address(ace), debt);
        ace.repay(loanId, debt);
        vm.stopPrank();
        assertEq(lens.requiredAtFloor(loanId), 0, "no debt needs no units");
    }

    /// @notice A settled loan keeps its debt word but loses its claim, so its floor is zero; it reads zero, never the max sentinel.
    function test_RequiredAtFloor_ZeroOnASettledLoan_NotTheMaxSentinel() public {
        rec.setBandPrice(0); // below-ness now holds at the trigger: the settle question answers yes
        ace.finalize(loanId);
        assertTrue(read.loan(loanId).closedAt != 0, "PREMISE: finalize closed the loan");
        assertGt(read.loan(loanId).debt, 0, "PREMISE: settlement leaves the debt word in place");
        assertEq(lens.fundingFloor(mid, loanId), 0, "PREMISE: and retires the claim, so the floor reads zero");
        assertEq(lens.requiredAtFloor(loanId), 0, "a settled loan needs no units");
    }

    /* ================================= fixture ================================= */

    function _trig() internal view returns (uint256) {
        return read.triggerPrice(loanId);
    }

    function _bandLevel() internal view returns (uint256) {
        return FullMath.mulDivRoundingUp(_trig(), 1e18, 1e18 - BAND_BPS * 1e14);
    }

    /// @dev The record's OWN cost for one question, with a zero-length output window so the measuring frame copies nothing.
    function _calleeCost(bytes memory data) internal view returns (uint256 cost) {
        address target = address(rec);
        uint256 g0 = gasleft();
        assembly ("memory-safe") {
            pop(staticcall(gas(), target, add(data, 32), mload(data), 0, 0))
        }
        cost = g0 - gasleft();
    }

    function _settleableCost() internal view returns (uint256 cost) {
        uint256 g0 = gasleft();
        lens.settleable(loanId);
        cost = g0 - gasleft();
    }

    function _inDistressCost() internal view returns (uint256 cost) {
        uint256 g0 = gasleft();
        lens.inDistress(loanId);
        cost = g0 - gasleft();
    }

    function _eligibleCost() internal view returns (uint256 cost) {
        uint256 g0 = gasleft();
        lens.deleverageEligible(loanId);
        cost = g0 - gasleft();
    }
}
