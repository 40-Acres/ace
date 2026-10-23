// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.36;

import {WarpClock} from "../utils/WarpClock.sol";
import {Ace} from "../../src/ace/hub/Ace.sol";
import {NotInBand} from "../../src/ace/hub/Deleverage.sol";
import {MarketParams, OpenBounds} from "../../src/ace/hub/Types.sol";
import {PositionManager} from "../../src/ace/positions/PositionManager.sol";
import {IPersistenceRecord} from "../../src/interfaces/IPersistenceRecord.sol";
import {MockERC20} from "../mocks/MockERC20.sol";
import {MockPersistenceRecord} from "../mocks/MockPersistenceRecord.sol";
import {MockStakeVault} from "../mocks/MockStakeVault.sol";
import {AceFixtures} from "../utils/AceFixtures.sol";

/// @dev A record that answers every other interview question and reverts on the distress one, which genesis once skipped.
contract DistressMuteRecord is IPersistenceRecord {
    MockPersistenceRecord internal immutable INNER;

    constructor(MockPersistenceRecord inner) {
        INNER = inner;
    }

    function supportsPair(address q, address c) external view returns (bool) {
        return INNER.supportsPair(q, c);
    }

    function persistedBelowDistress(address, address, uint256) external pure returns (bool) {
        revert("distress: not implemented");
    }

    function persistedBelowSettle(address q, address c, uint256 x) external view returns (bool) {
        return INNER.persistedBelowSettle(q, c, x);
    }

    function lastObserved(address q, address c) external view returns (uint256) {
        return INNER.lastObserved(q, c);
    }

    function minPrice(address q, address c) external view returns (uint256) {
        return INNER.minPrice(q, c);
    }
}

/// @notice A record shaped ONE QUESTION AT A TIME: every other call forwards to a healthy inner record.
/// @dev Every call lands in the fallback, so a shaped answer is the RAW returndata genesis decodes, never an encoding.
/// @dev `UNIT_SCALE()` forwards too and the inner record has none, so the optional probe reads it as absent.
contract ShapedRecord {
    enum Shape {
        Answer, // forward to the inner record
        Mute, // revert, naming the question
        Empty, // succeed with zero bytes
        Short, // succeed with 31 bytes, one short of a word
        NotABool, // succeed with the word 2, which no bool encodes
        Wide // the inner answer, then a trailing word
    }

    error Mute(bytes4 question);
    error InnerSilent(bytes4 question);

    MockPersistenceRecord internal immutable INNER;
    mapping(bytes4 => Shape) public shape;

    constructor(MockPersistenceRecord inner) {
        INNER = inner;
    }

    function setShape(bytes4 question, Shape s) external {
        shape[question] = s;
    }

    fallback(bytes calldata data) external returns (bytes memory) {
        Shape s = shape[msg.sig];
        if (s == Shape.Mute) revert Mute(msg.sig);
        if (s == Shape.Empty) return "";
        if (s == Shape.Short) return new bytes(31);
        if (s == Shape.NotABool) return abi.encode(uint256(2));
        (bool ok, bytes memory ret) = address(INNER).staticcall(data);
        if (!ok) revert InnerSilent(msg.sig);
        return s == Shape.Wide ? bytes.concat(ret, abi.encode(uint256(0xdead))) : ret;
    }
}

/// @title AceP11GenesisInterview
/// @notice Genesis interviews a record on all four price questions, `persistedBelowDistress` included.
/// @notice Distress is the one the deleverage channel asks first on every crank, and genesis once skipped it.
/// @dev Skipped, a record answering three and reverting the fourth passed genesis with the band ARMED.
/// @dev Every `deleverage` on that market then refused `RecordUnreadable`, permanently: the class the closed #379 named.
contract AceP11GenesisInterviewTest is WarpClock {
    Ace internal ace;
    PositionManager internal pm;
    MockERC20 internal usdc;
    MockStakeVault internal coll;
    MockPersistenceRecord internal inner;

    address internal alice = address(0xA11CE);
    address internal borrower = address(0xB0B);
    uint64 internal constant TEN7 = 7 days;

    function _px(uint256 humanWad) internal view returns (uint256) {
        return AceFixtures.px(humanWad, address(usdc), address(coll));
    }

    function setUp() public {
        _warpTo(1_000_000);
        usdc = new MockERC20("USD Coin", "USDC", 6);
        coll = new MockStakeVault(42);
        inner = new MockPersistenceRecord(address(usdc), address(coll));
        inner.setMinPrice(_px(1.1e18));
        inner.setBelow(false); // healthy: nothing persisted below any level
        AceFixtures.Deployment memory d = AceFixtures.deploy(AceFixtures.marketParams(address(usdc), address(coll)));
        (ace, pm) = (d.ace, d.positionManager);
    }

    function _bandParams(address record) internal view returns (MarketParams memory p) {
        p = AceFixtures.marketParams(address(usdc), address(coll));
        p.record = record;
        p.minTenor = TEN7;
        p.maxTenor = TEN7;
        p.minCoverageWad = 1.4e18;
        p.deleverageBandBps = 3000;
        p.deleverageTargetBps = 4000;
        p.deleverageStopBps = 1;
        p.deleverageFloorEpsBps = 200;
    }

    function _openOn(bytes32 mid) internal returns (uint256 loanId) {
        usdc.mint(alice, 400_000e6);
        vm.startPrank(alice);
        usdc.approve(address(ace), 400_000e6);
        ace.deposit(mid, 400_000e6);
        vm.stopPrank();
        coll.mint(borrower, 100_000e18);
        vm.startPrank(borrower);
        coll.approve(address(pm), 100_000e18);
        loanId = ace.open(mid, 100_000e18, 50_000e6, TEN7, borrower, OpenBounds(0, 0, 0));
        vm.stopPrank();
    }

    // ---- premise ----

    /// @dev The mute record answers every OTHER genesis question, so a refusal below is the distress question's alone.
    function test_Premise_TheMuteRecordAnswersEveryQuestionButDistress() public {
        DistressMuteRecord mute = new DistressMuteRecord(inner);
        (address q, address c) = (address(usdc), address(coll));
        assertTrue(mute.supportsPair(q, c), "PREMISE: it affirms the pair");
        mute.minPrice(q, c);
        mute.persistedBelowSettle(q, c, 0);
        mute.lastObserved(q, c);
        vm.expectRevert(bytes("distress: not implemented"));
        mute.persistedBelowDistress(q, c, 0);
    }

    // ---- control ----

    /// @dev The same market on a record answering all four questions refuses by the band, which is the healthy answer.
    function test_Control_TheFullRecordRefusesByTheBand() public {
        bytes32 mid = ace.createMarket(_bandParams(address(inner)));
        uint256 loanId = _openOn(mid);
        vm.expectRevert(NotInBand.selector);
        ace.deleverage(loanId, 0, "");
    }

    /// @dev Band OFF, the full record: genesis admits it, so the band-off refusal below is the mute record's alone.
    function test_Control_TheFullRecordCreatesWithTheBandOff() public {
        MarketParams memory p = AceFixtures.marketParams(address(usdc), address(coll));
        p.record = address(inner);
        assertEq(p.deleverageBandBps, 0, "fixture: the decline channel really is off");
        bytes32 mid = ace.createMarket(p);
        assertEq(ace.idToMarketParams(mid).record, address(inner), "the full record is wired");
    }

    // ---- the fix ----

    /// @dev Genesis refuses a record that cannot answer the distress question at all, the one `deleverage` asks first.
    /// @dev A presence check at one probe price: it does not prove the record answers at every threshold a crank asks.
    /// @dev The revert BUBBLES rather than being renamed, exactly as it does on the other interview questions.
    /// @dev The params are built BEFORE the expectation: `_bandParams` staticcalls `decimals()`, which would consume it.
    function test_GenesisRefusesARecordThatCannotAnswerTheDistressQuestion() public {
        MarketParams memory p = _bandParams(address(new DistressMuteRecord(inner)));
        assertEq(p.deleverageBandBps, 3000, "fixture: the decline channel really is armed");
        vm.expectRevert(bytes("distress: not implemented"));
        ace.createMarket(p);
    }

    /// @dev Unconditional on a record existing, like its siblings: `AceLens.inDistress` reads it on a band-off market too.
    function test_GenesisRefusesADistressMuteRecordEvenWithTheBandOff() public {
        MarketParams memory p = AceFixtures.marketParams(address(usdc), address(coll));
        p.record = address(new DistressMuteRecord(inner));
        assertEq(p.deleverageBandBps, 0, "fixture: the decline channel really is off");
        vm.expectRevert(bytes("distress: not implemented"));
        ace.createMarket(p);
    }

    // ---- the whole interview, one question at a time ----

    /// @dev The four questions `_requireAnswers` asks; genesis promises no order among them.
    function _questions() internal pure returns (bytes4[4] memory) {
        return [
            IPersistenceRecord.minPrice.selector,
            IPersistenceRecord.persistedBelowDistress.selector,
            IPersistenceRecord.persistedBelowSettle.selector,
            IPersistenceRecord.lastObserved.selector
        ];
    }

    function _bandOffParams(address record) internal view returns (MarketParams memory p) {
        p = AceFixtures.marketParams(address(usdc), address(coll));
        p.record = record;
    }

    function _shaped(bytes4 question, ShapedRecord.Shape s) internal returns (ShapedRecord r) {
        r = new ShapedRecord(inner);
        r.setShape(question, s);
    }

    /// @dev One question mute, one band state: genesis refuses, and the question's OWN revert surfaces.
    function _assertRefusesMute(bytes4 question, bool armed) internal {
        address r = address(_shaped(question, ShapedRecord.Shape.Mute));
        MarketParams memory p = armed ? _bandParams(r) : _bandOffParams(r);
        assertEq(p.deleverageBandBps, armed ? 3000 : 0, "fixture: the band is in the state the row names");
        vm.expectRevert(abi.encodeWithSelector(ShapedRecord.Mute.selector, question));
        ace.createMarket(p);
    }

    /// @dev Genesis against one shaped question, band off, by raw call so the revert data itself can be read.
    function _tryCreate(bytes4 question, ShapedRecord.Shape s) internal returns (bool ok, bytes memory ret) {
        MarketParams memory p = _bandOffParams(address(_shaped(question, s)));
        (ok, ret) = address(ace).call(abi.encodeCall(Ace.createMarket, (p)));
    }

    /// @dev The shaped record answering everything creates band armed AND off, so each refusal below is one shape's alone.
    function test_Control_AShapedRecordAnsweringEverythingCreates() public {
        ShapedRecord r = new ShapedRecord(inner);
        bytes32 armed = ace.createMarket(_bandParams(address(r)));
        bytes32 off = ace.createMarket(_bandOffParams(address(r)));
        assertEq(ace.idToMarketParams(armed).deleverageBandBps, 3000, "the armed market stood up on the shaped record");
        assertEq(ace.idToMarketParams(off).record, address(r), "and so did the band-off one");
    }

    function test_GenesisRefusesARecordMuteOnlyOnMinPrice_BandArmed() public {
        _assertRefusesMute(IPersistenceRecord.minPrice.selector, true);
    }

    function test_GenesisRefusesARecordMuteOnlyOnMinPrice_BandOff() public {
        _assertRefusesMute(IPersistenceRecord.minPrice.selector, false);
    }

    function test_GenesisRefusesARecordMuteOnlyOnDistress_BandArmed() public {
        _assertRefusesMute(IPersistenceRecord.persistedBelowDistress.selector, true);
    }

    function test_GenesisRefusesARecordMuteOnlyOnDistress_BandOff() public {
        _assertRefusesMute(IPersistenceRecord.persistedBelowDistress.selector, false);
    }

    function test_GenesisRefusesARecordMuteOnlyOnSettle_BandArmed() public {
        _assertRefusesMute(IPersistenceRecord.persistedBelowSettle.selector, true);
    }

    function test_GenesisRefusesARecordMuteOnlyOnSettle_BandOff() public {
        _assertRefusesMute(IPersistenceRecord.persistedBelowSettle.selector, false);
    }

    function test_GenesisRefusesARecordMuteOnlyOnTheHead_BandArmed() public {
        _assertRefusesMute(IPersistenceRecord.lastObserved.selector, true);
    }

    function test_GenesisRefusesARecordMuteOnlyOnTheHead_BandOff() public {
        _assertRefusesMute(IPersistenceRecord.lastObserved.selector, false);
    }

    // ---- an answer that is not a word ----

    /// @dev Zero bytes cannot decode as a word, so every question refuses them, by the decode and with no reason attached.
    function test_GenesisRefusesAnEmptyAnswerToEveryQuestion() public {
        bytes4[4] memory qs = _questions();
        for (uint256 i; i < qs.length; ++i) {
            (bool ok, bytes memory ret) = _tryCreate(qs[i], ShapedRecord.Shape.Empty);
            assertFalse(ok, string.concat("an empty answer is refused, question ", vm.toString(i)));
            assertEq(ret.length, 0, string.concat("refused by the decode, not by a rail, question ", vm.toString(i)));
        }
    }

    /// @dev 31 bytes is one short of a word: refused exactly as the empty answer is.
    function test_GenesisRefusesAShortAnswerToEveryQuestion() public {
        bytes4[4] memory qs = _questions();
        for (uint256 i; i < qs.length; ++i) {
            (bool ok, bytes memory ret) = _tryCreate(qs[i], ShapedRecord.Shape.Short);
            assertFalse(ok, string.concat("a short answer is refused, question ", vm.toString(i)));
            assertEq(ret.length, 0, string.concat("refused by the decode, not by a rail, question ", vm.toString(i)));
        }
    }

    /// @dev The word 2 is no bool: both below-questions refuse it at genesis, as `AceLens` would on every read after.
    function test_GenesisRefusesANonBooleanAnswerToEitherBelowQuestion() public {
        bytes4[2] memory qs = [IPersistenceRecord.persistedBelowDistress.selector, IPersistenceRecord.persistedBelowSettle.selector];
        for (uint256 i; i < qs.length; ++i) {
            (bool ok, bytes memory ret) = _tryCreate(qs[i], ShapedRecord.Shape.NotABool);
            assertFalse(ok, string.concat("a non-bool below-answer is refused, question ", vm.toString(i)));
            assertEq(ret.length, 0, string.concat("refused by the decode, not by a rail, question ", vm.toString(i)));
        }
    }

    /// @dev A trailing word buys no refusal: genesis decodes the leading word, as every runtime read of the record does.
    function test_GenesisAdmitsAWideAnswerToEveryQuestion() public {
        ShapedRecord r = new ShapedRecord(inner);
        bytes4[4] memory qs = _questions();
        for (uint256 i; i < qs.length; ++i) {
            r.setShape(qs[i], ShapedRecord.Shape.Wide);
        }
        bytes32 id = ace.createMarket(_bandParams(address(r)));
        assertEq(ace.idToMarketParams(id).record, address(r), "an over-long answer is still an answer");
    }

    /// @dev A zero and a false are the legitimate cold answers: creation never depends on the record having printed.
    function test_GenesisAdmitsARecordAnsweringZeroAndFalseEverywhere() public {
        inner.setMinPrice(0);
        inner.setObserved(0);
        (address q, address c) = (address(usdc), address(coll));
        assertEq(inner.minPrice(q, c) + inner.lastObserved(q, c), 0, "fixture: both price answers are cold");
        assertFalse(inner.persistedBelowDistress(q, c, 0) || inner.persistedBelowSettle(q, c, 0), "fixture: both below answers are false");
        bytes32 armed = ace.createMarket(_bandParams(address(inner)));
        bytes32 off = ace.createMarket(_bandOffParams(address(inner)));
        assertEq(ace.idToMarketParams(armed).record, address(inner), "a cold record arms a band");
        assertEq(ace.idToMarketParams(off).record, address(inner), "and wires a band-off market");
    }

    // ---- where the interview sits ----

    /// @dev The frame rail runs FIRST: a record refusing the pair AND every question is refused by name, not by its own revert.
    function test_TheFrameRailOutranksTheInterview() public {
        ShapedRecord r = new ShapedRecord(new MockPersistenceRecord(address(0), address(0)));
        bytes4[4] memory qs = _questions();
        for (uint256 i; i < qs.length; ++i) {
            r.setShape(qs[i], ShapedRecord.Shape.Mute);
        }
        MarketParams memory p = _bandOffParams(address(r));
        vm.expectRevert(bytes("record orientation"));
        ace.createMarket(p);
    }
}
