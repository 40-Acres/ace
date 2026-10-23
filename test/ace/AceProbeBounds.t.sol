// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.36;

import {Test} from "forge-std/Test.sol";
import {Probe} from "../../src/ace/hub/libraries/Probe.sol";

/// @notice A target whose answer WIDTH and first WORD are both dials, plus the two ways to answer nothing.
/// @dev Width is in BYTES so the 31/32 edge is expressible; the pile above 32 is zeros the probe must not buy.
contract WidthSource {
    error Nope(); // what the reverting mode reverts with, so a bubbled selector would be recognisable

    uint256 public word = 7e18; // the first word of every answer
    uint256 public width = 32; // bytes returned
    bool public reverting; // reverts with `Nope()` when set
    bool public silent; // reverts with NO data at all when set

    function set(uint256 w, uint256 n) external {
        word = w;
        width = n;
    }

    function setReverting(bool v) external {
        reverting = v;
    }

    function setSilent(bool v) external {
        silent = v;
    }

    /// @notice The one question the probe asks here; the answer's shape is whatever the dials say.
    function ask() external view returns (uint256) {
        if (silent) {
            assembly {
                revert(0, 0)
            }
        }
        if (reverting) revert Nope();
        uint256 v = word;
        uint256 n = width;
        assembly {
            mstore(0, v)
            return(0, n)
        }
    }
}

/// @title AceProbeBounds
/// @notice `Probe.askWord` on its own, where both of its properties are one assertion each.
/// @notice TOTALITY: no code, a revert, and a short answer are all `ok == false`, never an in-band value.
/// @notice BOUNDEDNESS: a megabyte answer costs this caller no more than the callee's own expansion.
/// @dev The door suites measure the bound through `deposit` and the expiry fold; this measures it at the source.
/// @dev The bound is on MEMORY, never on GAS: a callee that burns its allowance still drains the caller.
/// @dev That non-property is pinned in `AceVenueExposureEdges` and is deliberately not re-asserted here.
contract AceProbeBoundsTest is Test {
    WidthSource internal src;
    bytes internal ASK; // encoded once: the encode buffer must not sit inside a gas measurement

    uint256 internal constant MEBI_WORDS = 32_768; // one mebibyte of answer, the pile the doors are measured against

    function setUp() public {
        src = new WidthSource();
        ASK = abi.encodeCall(WidthSource.ask, ());
        Probe.askWord(address(src), ASK); // warms the account, so no measurement below pays a cold access
    }

    /* ============================ totality ============================ */

    /// @notice An address with no code cannot have answered, and the probe must not report that it did.
    /// @dev The early return is what stops solc's absent extcodesize check reading empty returndata as a value.
    function test_AskWord_ACodelessTarget_IsNotAnAnswer() public view {
        (bool ok, uint256 word) = Probe.askWord(address(0xE0A), ASK);
        assertFalse(ok, "a codeless target answered");
        assertEq(word, 0, "and it must carry no word");
    }

    /// @notice The zero address is the codeless case a market with an unset dependency reaches.
    function test_AskWord_TheZeroAddress_IsNotAnAnswer() public view {
        (bool ok,) = Probe.askWord(address(0), ASK);
        assertFalse(ok, "the zero address answered");
    }

    /// @notice A target that reverts with data is not an answer, and its data must not become the word.
    function test_AskWord_ARevertingTarget_IsNotAnAnswer() public {
        src.setReverting(true);
        (bool ok, uint256 word) = Probe.askWord(address(src), ASK);
        assertFalse(ok, "a reverting target answered");
        assertEq(word, 0, "and its revert data must not be read as the word");
    }

    /// @notice A revert carrying NO data is the other refusal shape, and it reads the same.
    function test_AskWord_ASilentRevert_IsNotAnAnswer() public {
        src.setSilent(true);
        (bool ok,) = Probe.askWord(address(src), ASK);
        assertFalse(ok, "a silent revert answered");
    }

    /// @notice A success carrying nothing is the case a `returndatasize` check alone catches.
    function test_AskWord_AnEmptyReturn_IsNotAnAnswer() public {
        src.set(7e18, 0);
        (bool ok, uint256 word) = Probe.askWord(address(src), ASK);
        assertFalse(ok, "an empty return answered");
        assertEq(word, 0, "and stale scratch memory must not surface as the word");
    }

    /// @notice THE EDGE, below: one byte short of a word is not a word.
    /// @dev Without the length check the copy would left-pad, turning a truncated answer into a plausible number.
    function test_AskWord_ThirtyOneBytes_IsNotAnAnswer() public {
        src.set(type(uint256).max, 31);
        (bool ok, uint256 word) = Probe.askWord(address(src), ASK);
        assertFalse(ok, "a 31-byte answer was accepted");
        assertEq(word, 0, "and a truncated max must not read as a number at all");
    }

    /// @notice THE EDGE, at: exactly one word is the smallest legal answer.
    function test_AskWord_ExactlyThirtyTwoBytes_Answers() public {
        src.set(123456789, 32);
        (bool ok, uint256 word) = Probe.askWord(address(src), ASK);
        assertTrue(ok, "the smallest legal answer was refused");
        assertEq(word, 123456789, "and it must carry the word verbatim");
    }

    /// @notice A wider answer is legal, and the word taken is the FIRST one.
    /// @dev A last-word read would pick up the pile's zeros, which is the silent-zero failure the doors fear.
    function test_AskWord_AWiderAnswer_TakesTheFirstWord() public {
        src.set(42e18, 32 * 4);
        (bool ok, uint256 word) = Probe.askWord(address(src), ASK);
        assertTrue(ok, "a wide answer was refused");
        assertEq(word, 42e18, "the probe must take the FIRST word, not the pile's tail");
    }

    /// @notice The max word is a real answer here: `persistedPrice` uses it as the no-record ruling.
    /// @dev So the probe may not reserve it as a sentinel of its own.
    function test_AskWord_TheMaxWord_IsAnAnswer() public {
        src.set(type(uint256).max, 32);
        (bool ok, uint256 word) = Probe.askWord(address(src), ASK);
        assertTrue(ok, "the max word was refused");
        assertEq(word, type(uint256).max, "and it must survive as a value");
    }

    /// @notice Zero is a real answer too, which is why `ok` and the word are separate returns.
    /// @dev `recordState` maps an answered zero to NoPrice and a refusal to `RecordUnreadable`: different facts.
    function test_AskWord_AnAnsweredZero_IsStillAnAnswer() public {
        src.set(0, 32);
        (bool ok, uint256 word) = Probe.askWord(address(src), ASK);
        assertTrue(ok, "an answered zero must read as an ANSWER, or the two record faults collapse");
        assertEq(word, 0, "carrying zero");
    }

    /// @notice Any word at any legal width round-trips; anything short of a word never does.
    function testFuzz_AskWord_TheWidthDecidesAndTheWordSurvives(uint256 w, uint8 extra, bool short_) public {
        uint256 width = short_ ? bound(uint256(extra), 0, 31) : 32 + uint256(extra) * 32;
        src.set(w, width);
        (bool ok, uint256 word) = Probe.askWord(address(src), ASK);
        assertEq(ok, !short_, "the width alone decides whether this was an answer");
        assertEq(word, short_ ? 0 : w, "and a legal answer carries its first word unchanged");
    }

    /* ============================ boundedness ============================ */

    /// @notice THE BOUND: a megabyte answer bills this caller nothing beyond what the callee itself spent.
    /// @notice Stated as an inequality against the measured callee cost, so no gas constant is guessed.
    /// @dev The non-vacuity guard is EXPLICIT: the callee delta must really be a megabyte's expansion.
    /// @dev Under an unbounded copy the caller pays that expansion a SECOND time, which is ~2.2e6 gas.
    function test_AskWord_AMegabyteAnswer_CostsTheCallerOneWord() public {
        src.set(7e18, 32);
        _calleeCost(); // warms every slot `ask()` reads, so no measurement below carries a cold SLOAD
        uint256 calleeSmall = _calleeCost();
        (uint256 probeSmall,,) = _probeCost();

        src.set(7e18, 32 * MEBI_WORDS);
        uint256 calleeBig = _calleeCost();
        (uint256 probeBig, bool ok, uint256 word) = _probeCost();

        uint256 callee = calleeBig - calleeSmall;
        assertGt(callee, 1_000_000, "fixture: the pile must really cost the CALLEE a megabyte's expansion");
        emit log_named_uint("the callee's own cost for the pile", callee);
        emit log_named_uint("what the probe's caller paid on top", (probeBig - probeSmall) - callee);
        assertLe(probeBig - probeSmall, callee + 1_000, "the probe billed its caller for the callee's pile");
        assertTrue(ok, "and a megabyte answer is still an answer");
        assertEq(word, 7e18, "with its first word intact");
    }

    /// @notice The bound holds at a REFUSAL too: a short answer inside a megabyte still copies nothing.
    /// @dev The length check runs before the copy, so this is the path where an unbounded caller pays for nothing at all.
    function test_AskWord_AMegabyteThatIsStillShort_CostsTheCallerNothingExtra() public {
        src.set(7e18, 31);
        _calleeCost(); // same warm-up: a cold slot inside the callee would land in the delta as caller cost
        uint256 calleeSmall = _calleeCost();
        (uint256 probeSmall,,) = _probeCost();

        src.set(7e18, 32 * MEBI_WORDS - 1); // one byte short of the last word, so the pile is legal-looking but odd
        uint256 calleeBig = _calleeCost();
        (uint256 probeBig, bool ok,) = _probeCost();

        uint256 callee = calleeBig - calleeSmall;
        assertGt(callee, 1_000_000, "fixture: the callee must really have built the pile");
        assertLe(probeBig - probeSmall, callee + 1_000, "a nearly-word-aligned pile billed the caller");
        assertTrue(ok, "a byte short of the last word is still over one word, so it answers");
    }

    /* ================================= fixture ================================= */

    /// @dev The callee's OWN cost, taken with a zero-length output window so this frame copies nothing.
    function _calleeCost() internal view returns (uint256 cost) {
        bytes memory data = ASK;
        address t = address(src);
        uint256 g0 = gasleft();
        assembly ("memory-safe") {
            pop(staticcall(gas(), t, add(data, 32), mload(data), 0, 0))
        }
        cost = g0 - gasleft();
    }

    /// @dev One probe, measured; the answer rides back so a compiler cannot elide the call.
    function _probeCost() internal view returns (uint256 cost, bool ok, uint256 word) {
        bytes memory data = ASK;
        address t = address(src);
        uint256 g0 = gasleft();
        (ok, word) = Probe.askWord(t, data);
        cost = g0 - gasleft();
    }
}
