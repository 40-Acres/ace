// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.36;

/// @title MockAggregator
/// @notice A Chainlink-shape feed whose round is storage the prover sets; the PRICE feed only.
/// @notice The sequencer is `MockSequencer`, a distinct contract, so a restart is not coupled to a price round.
/// @notice LINKED RATHER THAN SUMMARIZED, and that is the point: a summary hands each call a FRESH arbitrary answer,
/// @notice so two reads in one rule could disagree and REC-5 would fail on a state no chain can hold.
/// @notice Its past rounds are storage too, one arbitrary round per id, so the settle twin's walk reads one history, honest or not.
/// @dev Storage is read twice and answers the same twice, which is what makes the twin and gate rules mean anything.
/// @dev `decimals` is settable because the record folds it into an immutable at construction.
contract MockAggregator {
    struct Round {
        uint80 id; // the id the feed answers with, free so an answer for another round is reachable
        int256 answer; // the signed answer
        uint256 startedAt; // when the round opened
        uint256 updatedAt; // when the round printed
        uint80 answeredInRound; // the round the answer came from
    }

    uint8 internal dec; // what decimals answers
    uint80 internal roundId; // the round id
    int256 internal answer; // the signed answer, free so a non-positive round is reachable
    uint256 internal startedAt; // when the round opened, which the sequencer gate reads
    uint256 internal updatedAt; // when the round last printed, which the staleness gate reads
    uint80 internal answeredInRound; // the round the answer came from
    mapping(uint80 => Round) internal past; // each past round the walk reads, storage the prover sets
    bool internal pastReverts; // whether a past-round read reverts, as a feed with no data there does

    /// @notice The feed's decimals.
    /// @return The stored decimals.
    function decimals() external view returns (uint8) {
        return dec;
    }

    /// @notice The latest round, in Chainlink's shape.
    /// @return The round id.
    /// @return The signed answer.
    /// @return When the round opened.
    /// @return When the round last printed.
    /// @return The round the answer came from.
    function latestRoundData() external view returns (uint80, int256, uint256, uint256, uint80) {
        return (roundId, answer, startedAt, updatedAt, answeredInRound);
    }

    /// @notice A past round, in Chainlink's shape: the stored round for `id`, or a revert while `pastReverts` is set.
    /// @param id The round asked for.
    /// @return The id the stored round answers with.
    /// @return The signed answer.
    /// @return When the round opened.
    /// @return When the round printed.
    /// @return The round the answer came from.
    function getRoundData(uint80 id) external view returns (uint80, int256, uint256, uint256, uint80) {
        require(!pastReverts, "no data");
        Round memory r = past[id];
        return (r.id, r.answer, r.startedAt, r.updatedAt, r.answeredInRound);
    }

    /// @notice The raw answer a spec compares the record's reading against.
    /// @return The stored answer.
    function answerView() external view returns (int256) {
        return answer;
    }

    /// @notice Sets the answer, for the monotonicity rule that prices one account at two feed answers.
    /// @param a The answer to report.
    /// @dev Monotonicity compares two prices, so it needs two states; every other rule reads the prover's initial one.
    function setAnswer(int256 a) external {
        answer = a;
    }

    /// @notice When the round last printed, for a spec reasoning about staleness.
    /// @return The stored update time.
    function updatedAtView() external view returns (uint256) {
        return updatedAt;
    }

    /// @notice The round id, for the rule about an incomplete round.
    /// @return The stored round id.
    function roundIdView() external view returns (uint80) {
        return roundId;
    }

    /// @notice The round the answer came from, for the rule about an incomplete round.
    /// @return The stored answering round.
    function answeredInRoundView() external view returns (uint80) {
        return answeredInRound;
    }

    /// @notice When the round opened, for a spec reasoning about the sequencer grace.
    /// @return The stored start time.
    function startedAtView() external view returns (uint256) {
        return startedAt;
    }
}
