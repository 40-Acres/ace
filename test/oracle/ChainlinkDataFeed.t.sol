// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.36;

import {WarpClock} from "../utils/WarpClock.sol";
import {IAggregatorV3} from "../../src/interfaces/IAggregatorV3.sol";
import {ChainlinkDataFeed} from "../../src/oracle/ChainlinkDataFeed.sol";
import {MockAggregatorV3} from "../mocks/MockAggregatorV3.sol";
import {MockShortReturnFeed} from "../mocks/MockShortReturnFeed.sol";

/// @notice Exposes the internal read through an external call, so a short return reverts a frame the test can expect.
contract ChainlinkDataFeedHarness {
    function latest(IAggregatorV3 feed, uint256 maxStaleness) external view returns (uint256, uint256) {
        return ChainlinkDataFeed.latest(feed, maxStaleness);
    }
}

/// @title ChainlinkDataFeedTest
/// @notice The shared round checks, each pinned at its boundary: the fit side reads, the first unfit step answers (0, 0).
/// @dev OracleRecord, YbRecord and NftAccountRecord all read their feed through this one function.
contract ChainlinkDataFeedTest is WarpClock {
    ChainlinkDataFeedHarness internal lib;
    MockAggregatorV3 internal feed;

    int256 internal constant ANSWER = 2e8;
    uint256 internal constant STALENESS = 1 hours;

    function setUp() public {
        _warpTo(365 days); // clear of genesis, so an age can sit on either side of the bound
        lib = new ChainlinkDataFeedHarness();
        feed = new MockAggregatorV3(8);
    }

    /// @dev One round on the feed, then the read under the one-hour bound.
    function _read(uint80 rid, int256 answer, uint256 upd, uint80 answeredIn) internal returns (uint256, uint256) {
        return _readWith(rid, answer, upd, answeredIn, STALENESS);
    }

    /// @dev One round on the feed, then the read under `maxStaleness`.
    /// @dev The mock never lowers its latest round, so a `rid` below it would read an earlier round; the assert refuses one.
    function _readWith(uint80 rid, int256 answer, uint256 upd, uint80 answeredIn, uint256 maxStaleness) internal returns (uint256, uint256) {
        feed.setRound(rid, answer, upd, answeredIn);
        assertEq(feed.latestRound(), rid, "HELPER: the read must be of the round this row wrote");
        return lib.latest(feed, maxStaleness);
    }

    function _assertClosed(uint256 a, uint256 u, string memory why) internal pure {
        assertEq(a, 0, why);
        assertEq(u, 0, string.concat(why, ": the stamp is zeroed with it"));
    }

    // ============ a fit round ============

    /// @notice A fit round returns its own answer and its own stamp, not the chain's time.
    function test_FitRound_ReturnsTheAnswerAndItsStamp() public {
        (uint256 a, uint256 u) = _read(7, ANSWER, _now() - 100, 7);
        assertEq(a, uint256(ANSWER), "the answer, at the feed's own scale");
        assertEq(u, _now() - 100, "the round's stamp");
    }

    // ============ the answer ============

    /// @notice One is the smallest answer that reads; zero is closed.
    function test_Answer_OneReadsZeroIsClosed() public {
        (uint256 a,) = _read(2, 1, _now(), 2);
        assertEq(a, 1, "a positive answer of one reads");
        (uint256 z, uint256 u) = _read(3, 0, _now(), 3);
        _assertClosed(z, u, "a zero answer is closed");
    }

    /// @notice A negative answer is closed at minus one and at the word's floor, never cast into a huge positive.
    function test_Answer_NegativeIsClosed() public {
        (uint256 a, uint256 u) = _read(2, -1, _now(), 2);
        _assertClosed(a, u, "minus one is closed");
        (a, u) = _read(3, type(int256).min, _now(), 3);
        _assertClosed(a, u, "the int256 floor is closed");
    }

    /// @notice The largest answer reads whole: the library frames nothing, so it bounds nothing above.
    function test_Answer_TheCeilingReadsWhole() public {
        (uint256 a,) = _read(2, type(int256).max, _now(), 2);
        assertEq(a, uint256(type(int256).max), "no upper bound here: each record refuses what it cannot frame");
    }

    // ============ the round ============

    /// @notice `answeredInRound == roundId` is complete and reads; one round behind is incomplete and closed.
    function test_Round_AnsweredInTheSameRoundReadsOneBehindIsClosed() public {
        (uint256 a,) = _read(5, ANSWER, _now(), 5);
        assertEq(a, uint256(ANSWER), "answered in its own round");
        (uint256 b, uint256 u) = _read(6, ANSWER, _now(), 5);
        _assertClosed(b, u, "answered in the round before");
    }

    /// @notice The check is `answeredInRound >= roundId`, so an answer carried from a later round still reads.
    function test_Round_AnsweredAheadOfTheRoundReads() public {
        (uint256 a,) = _read(5, ANSWER, _now(), 6);
        assertEq(a, uint256(ANSWER), "answeredInRound above roundId is complete");
    }

    /// @notice Round ids of zero, which an API3 reader proxy reports, read as complete.
    function test_Round_ZeroIdsRead() public {
        (uint256 a,) = _read(0, ANSWER, _now(), 0);
        assertEq(a, uint256(ANSWER), "round 0 answered in round 0 is complete");
    }

    // ============ the stamp ============

    /// @notice A round stamped now reads; one stamped one second ahead of the chain is closed.
    function test_Stamp_NowReadsOneSecondAheadIsClosed() public {
        (uint256 a,) = _read(2, ANSWER, _now(), 2);
        assertEq(a, uint256(ANSWER), "stamped at the chain's own second");
        (uint256 b, uint256 u) = _read(3, ANSWER, _now() + 1, 3);
        _assertClosed(b, u, "one second ahead of the chain");
    }

    /// @notice A stamp at the word's ceiling is closed, not a panic: the future check runs before the subtraction.
    function test_Stamp_TheCeilingIsClosedNotAPanic() public {
        (uint256 a, uint256 u) = _read(2, ANSWER, type(uint256).max, 2);
        _assertClosed(a, u, "the ceiling stamp is closed");
    }

    /// @notice A zero stamp is as old as the chain: stale under any bound short of that, and not special-cased past it.
    function test_Stamp_ZeroIsAsOldAsTheChain() public {
        (uint256 a, uint256 u) = _read(2, ANSWER, 0, 2);
        _assertClosed(a, u, "a zero stamp is stale under a one-hour bound");
        (uint256 b, uint256 v) = _readWith(3, ANSWER, 0, 3, _now());
        assertEq(b, uint256(ANSWER), "a bound as long as the chain's age admits it");
        assertEq(v, 0, "and the stamp it returns is that zero");
    }

    // ============ staleness ============

    /// @notice An age of exactly the bound reads; one second past it is closed.
    function test_Staleness_TheBoundIsInclusive() public {
        (uint256 a,) = _read(2, ANSWER, _now() - STALENESS, 2);
        assertEq(a, uint256(ANSWER), "an age of exactly the bound still reads");
        (uint256 b, uint256 u) = _read(3, ANSWER, _now() - STALENESS - 1, 3);
        _assertClosed(b, u, "one second past the bound");
    }

    /// @notice The bound is the caller's: a zero bound admits only a round stamped this very second.
    function test_Staleness_AZeroBoundAdmitsOnlyThisSecond() public {
        (uint256 a,) = _readWith(2, ANSWER, _now(), 2, 0);
        assertEq(a, uint256(ANSWER), "an age of zero is within a zero bound");
        (uint256 b, uint256 u) = _readWith(3, ANSWER, _now() - 1, 3, 0);
        _assertClosed(b, u, "one second old is past a zero bound");
    }

    /// @notice Staleness is measured against the chain: the same round reads, then goes stale as the clock passes the bound.
    function test_Staleness_TheSameRoundAgesOut() public {
        feed.setRound(2, ANSWER, _now(), 2);
        _warpBy(STALENESS);
        (uint256 a,) = lib.latest(feed, STALENESS);
        assertEq(a, uint256(ANSWER), "at the bound");
        _warpBy(1);
        (uint256 b, uint256 u) = lib.latest(feed, STALENESS);
        _assertClosed(b, u, "one second later");
    }

    // ============ the call ============

    /// @notice A reverting feed answers closed and never bubbles.
    function test_Call_ARevertingFeedIsClosedNotBubbled() public {
        feed.setRound(2, ANSWER, _now(), 2);
        feed.setReverting(true);
        (uint256 a, uint256 u) = lib.latest(feed, STALENESS);
        _assertClosed(a, u, "a reverting feed is caught");
    }

    /// @notice A return too short to decode reverts the read: `try` catches the callee's revert, not the caller's decode.
    function testRevert_Call_AShortReturnRevertsTheRead() public {
        IAggregatorV3 shortFeed = IAggregatorV3(address(new MockShortReturnFeed()));
        vm.expectRevert();
        lib.latest(shortFeed, STALENESS);
    }

    // ============ every check at once ============

    /// @notice Over any round, the read is fit exactly when all four checks pass, and a fit read returns the round verbatim.
    /// @dev The stamp and the bound are drawn around the chain's time, so both sides of every check are reached; the word's ends have their own rows.
    function testFuzz_ClosedUnlessEveryCheckPasses(uint80 rid, int256 answer, uint256 upd, uint80 answeredIn, uint256 maxStaleness) public {
        upd = bound(upd, 0, _now() + 1 days);
        maxStaleness = bound(maxStaleness, 0, _now() + 1);
        (uint256 a, uint256 u) = _readWith(rid, answer, upd, answeredIn, maxStaleness);
        bool fit = answer > 0 && answeredIn >= rid && upd <= _now() && _now() - upd <= maxStaleness;
        assertEq(a, fit ? uint256(answer) : 0, "the answer, or zero");
        assertEq(u, fit ? upd : 0, "the stamp, or zero");
    }
}
