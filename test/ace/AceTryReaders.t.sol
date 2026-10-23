// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.36;

import {Test} from "forge-std/Test.sol";
import {Borrower, RecordUnreadable} from "../../src/ace/hub/Borrower.sol";
import {Cfg, RecordState} from "../../src/ace/hub/Types.sol";
import {MockPersistenceRecord} from "../mocks/MockPersistenceRecord.sol";
import {MockRevertingRecord} from "../mocks/MockRevertingRecord.sol";

/// @notice An external door onto the REVERTING reader, so its refusal can be caught at a call boundary.
/// @dev A library `internal` call inlines, and `vm.expectRevert` needs a real frame to watch.
contract RecordStateProbe {
    function recordState(Cfg memory c) external view returns (RecordState s, uint256 cap) {
        return Borrower.recordState(c);
    }
}

/// @title AceTryReaders
/// @notice Borrower's non-reverting record reader, pinned directly: a sick source is an ANSWER (false).
/// @notice Never a revert, because the expiry fold's settle branch must survive every oracle state.
contract AceTryReadersTest is Test {
    address internal constant QUOTE = address(0x0A);
    address internal constant COLL = address(0x0B);

    function _cfg(address record, address collateral) internal pure returns (Cfg memory c) {
        c.p.quote = QUOTE;
        c.p.record = record;
        c.p.collateral = collateral;
    }

    function test_TryPersistedPrice_KeepsTheNoRecordMaxRuling() public view {
        (bool ok, uint256 p) = Borrower.tryPersistedPrice(_cfg(address(0), COLL));
        assertTrue(ok, "no record wired is a ruled answer");
        assertEq(p, type(uint256).max, "the max sentinel: the lender's resting bid is the only brake");
    }

    function test_TryPersistedPrice_ReadsAHealthyRecord() public {
        MockPersistenceRecord rec = new MockPersistenceRecord(QUOTE, COLL);
        rec.setMinPrice(2e18);
        (bool ok, uint256 p) = Borrower.tryPersistedPrice(_cfg(address(rec), COLL));
        assertTrue(ok, "a live record answers");
        assertEq(p, 2e18, "with its windowed minimum");
    }

    function test_TryPersistedPrice_AnswersFalse_WhenTheRecordReverts() public {
        MockRevertingRecord rec = new MockRevertingRecord(QUOTE, COLL);
        rec.setRevoked(true);
        (bool ok, uint256 p) = Borrower.tryPersistedPrice(_cfg(address(rec), COLL));
        assertFalse(ok, "a reverting record is an answer, not a revert");
        assertEq(p, 0, "and no price");
    }

    // ============ the MALFORMED ANSWER: a successful call the caller cannot decode ============

    /// @notice A source that ANSWERS badly is not a source that REVERTS, and try/catch only covers the second.
    /// @dev The decode runs in Borrower's own frame after a successful staticcall, so no catch clause sees it.
    /// @dev Written RED against the try/catch form: these are the fail-closed contract owed to the fold.
    function test_TryPersistedPrice_AnswersFalse_WhenTheRecordAnswersEmpty() public {
        MockRevertingRecord rec = new MockRevertingRecord(QUOTE, COLL);
        rec.setAnswerMode(1);
        (bool ok, uint256 p) = Borrower.tryPersistedPrice(_cfg(address(rec), COLL));
        assertFalse(ok, "an undecodable answer is an answer, not a revert");
        assertEq(p, 0, "and no price");
    }

    /// @notice A 31-byte word is the same failure with the right shape.
    function test_TryPersistedPrice_AnswersFalse_WhenTheRecordAnswersShort() public {
        MockRevertingRecord rec = new MockRevertingRecord(QUOTE, COLL);
        rec.setAnswerMode(2);
        (bool ok, uint256 p) = Borrower.tryPersistedPrice(_cfg(address(rec), COLL));
        assertFalse(ok, "a short answer is a refusal");
        assertEq(p, 0, "and no price");
    }

    // ============ what must NOT change under the hardening ============

    /// @notice An OVER-LONG answer is accepted today and must stay accepted.
    /// @dev Tightening to `== 32` would SILENTLY settle loans with a wider-word source.
    function test_TryPersistedPrice_AcceptsAnOverLongAnswer() public {
        MockRevertingRecord rec = new MockRevertingRecord(QUOTE, COLL);
        rec.setAnswerMode(3);
        (bool ok, uint256 p) = Borrower.tryPersistedPrice(_cfg(address(rec), COLL));
        assertTrue(ok, "a 64-byte answer still decodes");
        assertEq(p, 2e18, "at its first word");
    }

    /// @notice The no-record max ruling is a RULING, not a read, so no hardening may make it fail closed.
    function test_TryPersistedPrice_NoRecordRulingSurvives() public view {
        (bool ok, uint256 p) = Borrower.tryPersistedPrice(_cfg(address(0), COLL));
        assertTrue(ok, "record-less stays a ruled answer");
        assertEq(p, type(uint256).max, "and the sentinel is untouched");
    }

    // ============ tryRecordState: the TOTAL twin, one answer shape per record shape ============

    /// @notice No record wired is a RULING, and it decodes as `None` with the uncapped sentinel.
    function test_TryRecordState_KeepsTheNoRecordRuling() public view {
        (bool ok, RecordState s, uint256 cap) = Borrower.tryRecordState(_cfg(address(0), COLL));
        assertTrue(ok, "no record wired is a ruled answer, never an unreadable one");
        assertEq(uint8(s), uint8(RecordState.None), "and it decodes as None, not as NoPrice");
        assertEq(cap, type(uint256).max, "carrying the uncapped sentinel");
    }

    function test_TryRecordState_ReadsAHealthyRecord() public {
        MockPersistenceRecord rec = new MockPersistenceRecord(QUOTE, COLL);
        rec.setMinPrice(2e18);
        (bool ok, RecordState s, uint256 cap) = Borrower.tryRecordState(_cfg(address(rec), COLL));
        assertTrue(ok, "a live record answers");
        assertEq(uint8(s), uint8(RecordState.Live), "Live");
        assertEq(cap, 2e18, "with its windowed minimum");
    }

    /// @notice A record that ANSWERS ZERO is readable and dark: `ok` stays true and the state is NoPrice.
    /// @notice THE reason this twin exists -- the deposit door admits a DARK record and refuses an unreadable one.
    function test_TryRecordState_AnsweredZeroIsReadableAndDark() public {
        MockPersistenceRecord rec = new MockPersistenceRecord(QUOTE, COLL);
        rec.setMinPrice(0);
        (bool ok, RecordState s, uint256 cap) = Borrower.tryRecordState(_cfg(address(rec), COLL));
        assertTrue(ok, "answering zero is an ANSWER: the record was read");
        assertEq(uint8(s), uint8(RecordState.NoPrice), "NoPrice");
        assertEq(cap, 0, "and no cap");
    }

    /// @notice THE DISTINCTION `tryPersistedPrice` CANNOT DRAW, asserted on one record in one test.
    /// @dev Both readers see the same zero-answering source; only this one still reports it was read.
    /// @dev Collapse the two here and the deposit door's fail-OPEN on NoPrice becomes a fail-closed.
    function test_TryRecordState_SeparatesReadableFromUnreadable_WhereTryPersistedPriceCannot() public {
        MockPersistenceRecord dark = new MockPersistenceRecord(QUOTE, COLL);
        dark.setMinPrice(0);
        MockRevertingRecord broken = new MockRevertingRecord(QUOTE, COLL);
        broken.setRevoked(true);

        (bool darkOk,) = Borrower.tryPersistedPrice(_cfg(address(dark), COLL));
        (bool brokenOk,) = Borrower.tryPersistedPrice(_cfg(address(broken), COLL));
        assertEq(darkOk, brokenOk, "the older reader really does collapse the two into one false");

        (bool okDark, RecordState sDark,) = Borrower.tryRecordState(_cfg(address(dark), COLL));
        (bool okBroken, RecordState sBroken,) = Borrower.tryRecordState(_cfg(address(broken), COLL));
        assertTrue(okDark, "dark is readable");
        assertFalse(okBroken, "broken is not");
        assertEq(uint8(sDark), uint8(RecordState.NoPrice), "dark decodes as NoPrice");
        assertEq(uint8(sBroken), uint8(RecordState.NoPrice), "and so does broken: `ok` is the only separator");
    }

    function test_TryRecordState_AnswersFalse_WhenTheRecordReverts() public {
        MockRevertingRecord rec = new MockRevertingRecord(QUOTE, COLL);
        rec.setRevoked(true);
        (bool ok,, uint256 cap) = Borrower.tryRecordState(_cfg(address(rec), COLL));
        assertFalse(ok, "a reverting record is an answer, not a revert");
        assertEq(cap, 0, "and no cap");
    }

    function test_TryRecordState_AnswersFalse_WhenTheRecordAnswersEmpty() public {
        MockRevertingRecord rec = new MockRevertingRecord(QUOTE, COLL);
        rec.setAnswerMode(1);
        (bool ok,, uint256 cap) = Borrower.tryRecordState(_cfg(address(rec), COLL));
        assertFalse(ok, "an undecodable answer is an answer, not a revert");
        assertEq(cap, 0, "and no cap");
    }

    function test_TryRecordState_AnswersFalse_WhenTheRecordAnswersShort() public {
        MockRevertingRecord rec = new MockRevertingRecord(QUOTE, COLL);
        rec.setAnswerMode(2);
        (bool ok,, uint256 cap) = Borrower.tryRecordState(_cfg(address(rec), COLL));
        assertFalse(ok, "a short answer is a refusal");
        assertEq(cap, 0, "and no cap");
    }

    /// @notice An OVER-LONG answer is accepted here exactly as `tryPersistedPrice` accepts it.
    /// @dev The two readers must not diverge on a shape neither treats as malformed.
    function test_TryRecordState_AcceptsAnOverLongAnswer() public {
        MockRevertingRecord rec = new MockRevertingRecord(QUOTE, COLL);
        rec.setAnswerMode(3);
        (bool ok, RecordState s, uint256 cap) = Borrower.tryRecordState(_cfg(address(rec), COLL));
        assertTrue(ok, "a 64-byte answer still decodes");
        assertEq(uint8(s), uint8(RecordState.Live), "Live");
        assertEq(cap, 2e18, "at its first word");
    }

    /// @notice The twin is TOTAL exactly where `recordState` is not: same source, one reverts, one answers.
    /// @dev Without this the pair could drift into two readers that both revert.
    /// @dev `Lender.restRefusal` needs that totality: it must answer `Record` where a revert would carry nothing.
    function test_TryRecordState_AnswersWhereRecordStateReverts() public {
        MockRevertingRecord rec = new MockRevertingRecord(QUOTE, COLL);
        rec.setRevoked(true);
        RecordStateProbe probe = new RecordStateProbe();

        vm.expectRevert(RecordUnreadable.selector);
        probe.recordState(_cfg(address(rec), COLL));

        (bool ok,,) = Borrower.tryRecordState(_cfg(address(rec), COLL));
        assertFalse(ok, "the total twin answers the very read that reverts");
    }

    /// @notice And on a HEALTHY source the two agree term for term, so the twin is no second rule.
    function test_TryRecordState_AgreesWithRecordStateOnALiveSource() public {
        MockPersistenceRecord rec = new MockPersistenceRecord(QUOTE, COLL);
        rec.setMinPrice(3e18);
        RecordStateProbe probe = new RecordStateProbe();

        (RecordState rs, uint256 rcap) = probe.recordState(_cfg(address(rec), COLL));
        (bool ok, RecordState ts, uint256 tcap) = Borrower.tryRecordState(_cfg(address(rec), COLL));
        assertTrue(ok, "readable");
        assertEq(uint8(ts), uint8(rs), "the same state");
        assertEq(tcap, rcap, "and the same cap");
        assertEq(tcap, 3e18, "a real one, so the agreement is not over two zeros");
    }
}
