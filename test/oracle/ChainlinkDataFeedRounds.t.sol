// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.36;

import {WarpClock} from "../utils/WarpClock.sol";
import {IAggregatorV3} from "../../src/interfaces/IAggregatorV3.sol";
import {ChainlinkDataFeed} from "../../src/oracle/ChainlinkDataFeed.sol";
import {MockAggregatorV3} from "../mocks/MockAggregatorV3.sol";
import {MockShortReturnFeed} from "../mocks/MockShortReturnFeed.sol";

/// @notice Exposes the two id-carrying reads through external calls, so a short return reverts a frame the test can expect.
contract ChainlinkRoundsHarness {
    function latestRound(IAggregatorV3 feed, uint256 maxStaleness) external view returns (uint80, uint256, uint256) {
        return ChainlinkDataFeed.latestRound(feed, maxStaleness);
    }

    function pastRound(IAggregatorV3 feed, uint80 id) external view returns (uint256, uint256) {
        return ChainlinkDataFeed.pastRound(feed, id);
    }
}

/// @title ChainlinkDataFeedRoundsTest
/// @notice `latestRound` is `latest` with its id; `pastRound` checks a past round as `latest` does, less the age bound.
/// @dev The settle twin's hold reads history through `pastRound`, so every unfit shape must close it, and a fit one read whole.
contract ChainlinkDataFeedRoundsTest is WarpClock {
    ChainlinkRoundsHarness internal lib;
    MockAggregatorV3 internal feed;

    int256 internal constant ANSWER = 2e8;

    function setUp() public {
        _warpTo(365 days);
        lib = new ChainlinkRoundsHarness();
        feed = new MockAggregatorV3(8);
    }

    function _past(uint80 id, int256 answer, uint256 upd, uint80 answeredIn) internal returns (uint256, uint256) {
        feed.setRound(id, answer, upd, answeredIn);
        return lib.pastRound(feed, id);
    }

    function _assertClosed(uint256 a, uint256 u, string memory why) internal pure {
        assertEq(a, 0, why);
        assertEq(u, 0, string.concat(why, ": the stamp is zeroed with it"));
    }

    /// @notice The latest round's id rides with its answer and stamp, and is zero with them when the round is unfit.
    function test_LatestRound_CarriesItsId() public {
        feed.setRound(9, ANSWER, _now() - 100, 9);
        (uint80 id, uint256 a, uint256 u) = lib.latestRound(feed, 1 hours);
        assertEq(id, 9, "the round's id");
        assertEq(a, uint256(ANSWER), "its answer");
        assertEq(u, _now() - 100, "its stamp");
        feed.setRound(10, ANSWER, _now() - 1 hours - 1, 10);
        (id, a, u) = lib.latestRound(feed, 1 hours);
        assertEq(id, 0, "a stale round's id is zero");
        _assertClosed(a, u, "a stale round");
    }

    /// @notice A fit past round reads whole however old it is: a past round is old by design.
    function test_PastRound_ReadsAnOldRoundWhole() public {
        (uint256 a, uint256 u) = _past(3, ANSWER, 1, 3);
        assertEq(a, uint256(ANSWER), "a year-old round's answer");
        assertEq(u, 1, "and its stamp");
        (a, u) = _past(4, ANSWER, _now(), 4);
        assertEq(u, _now(), "a stamp at the chain's own second reads");
    }

    /// @notice Each unfit shape closes a past round: zero or negative, incomplete, unstamped, stamped ahead, or a round with no data.
    function test_PastRound_EveryUnfitShapeIsClosed() public {
        (uint256 a, uint256 u) = _past(2, 0, _now(), 2);
        _assertClosed(a, u, "a zero answer");
        (a, u) = _past(3, -1, _now(), 3);
        _assertClosed(a, u, "a negative answer");
        (a, u) = _past(4, ANSWER, _now(), 3);
        _assertClosed(a, u, "an incomplete round");
        (a, u) = _past(5, ANSWER, _now() + 1, 5);
        _assertClosed(a, u, "a stamp ahead of the chain");
        (a, u) = lib.pastRound(feed, 77);
        _assertClosed(a, u, "a round the feed has no data for reverts, and is caught");
        feed.setRound(6, ANSWER, _now(), 6);
        feed.setReverting(true);
        (a, u) = lib.pastRound(feed, 6);
        _assertClosed(a, u, "a reverting feed");
    }

    /// @notice An answer for another round than the one asked is closed, never read as the round asked for.
    function test_PastRound_AnotherRoundsAnswerIsClosed() public {
        feed.setRound(8, ANSWER, _now(), 8);
        vm.mockCall(address(feed), abi.encodeCall(IAggregatorV3.getRoundData, (8)), abi.encode(uint80(9), ANSWER, _now(), _now(), uint80(9)));
        (uint256 a, uint256 u) = lib.pastRound(feed, 8);
        _assertClosed(a, u, "the id answered is not the id asked");
    }

    /// @notice A zero stamp closes a past round, which `latest` leaves to its age bound.
    function test_PastRound_AZeroStampIsClosed() public {
        vm.mockCall(address(feed), abi.encodeCall(IAggregatorV3.getRoundData, (8)), abi.encode(uint80(8), ANSWER, 0, 0, uint80(8)));
        (uint256 a, uint256 u) = lib.pastRound(feed, 8);
        _assertClosed(a, u, "an unstamped round");
    }

    /// @notice A return too short to decode is not caught: the read reverts rather than answering, for both reads.
    function test_ShortReturn_Reverts() public {
        MockShortReturnFeed short = new MockShortReturnFeed();
        vm.expectRevert();
        lib.pastRound(IAggregatorV3(address(short)), 1);
        vm.expectRevert();
        lib.latestRound(IAggregatorV3(address(short)), 1 hours);
    }

    /// @notice The fit side's edges read whole: a one-atom answer, and a round answered in a later round.
    /// @dev Kills a `pastRound` stricter than its spec, which would delay seizures on rounds the feed printed honestly.
    function test_PastRound_TheFitEdgesReadWhole() public {
        (uint256 a, uint256 u) = _past(2, 1, _now() - 10, 2);
        assertEq(a, 1, "a one-atom answer is positive");
        assertEq(u, _now() - 10, "and reads with its stamp");
        (a, u) = _past(3, ANSWER, _now() - 10, 4);
        assertEq(a, uint256(ANSWER), "answered in a later round is complete");
        assertEq(u, _now() - 10, "and reads with its stamp");
    }
}
