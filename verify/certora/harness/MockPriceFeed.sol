// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.36;

/// @title MockPriceFeed
/// @notice A Chainlink-shape price feed whose latest round is storage the prover sets, for the oracle-class records.
/// @notice Every field is free, so a non-positive, incomplete, future-stamped or stale round is reachable, and so is a revert.
/// @notice DISPATCHED rather than linked: a record takes its feed as a constructor argument, which `link` cannot bind.
/// @dev Storage answers the same twice, which is what makes a two-read rule mean anything.
/// @dev It answers in full or reverts; a return too short to decode is the one feed behaviour it cannot produce.
contract MockPriceFeed {
    uint8 internal dec; // what decimals answers
    uint80 internal roundId; // the latest round's id
    int256 internal answer; // the signed answer
    uint256 internal startedAt; // when the round opened, which no record reads
    uint256 internal updatedAt; // when the round printed, which the staleness gate reads
    uint80 internal answeredInRound; // the round the answer came from
    bool internal reverts; // the latest-round read reverts instead of answering

    /// @notice The feed's decimals.
    /// @return The stored decimals.
    function decimals() external view returns (uint8) {
        return dec;
    }

    /// @notice The latest round, in Chainlink's shape, or a revert while `reverts` is set.
    /// @return The round id.
    /// @return The signed answer.
    /// @return When the round opened.
    /// @return When the round printed.
    /// @return The round the answer came from.
    function latestRoundData() external view returns (uint80, int256, uint256, uint256, uint80) {
        require(!reverts, "feed down");
        return (roundId, answer, startedAt, updatedAt, answeredInRound);
    }

    /// @notice The raw answer a spec compares the record's reading against.
    /// @return The stored answer.
    function answerView() external view returns (int256) {
        return answer;
    }

    /// @notice When the round printed.
    /// @return The stored stamp.
    function updatedAtView() external view returns (uint256) {
        return updatedAt;
    }

    /// @notice The latest round's id.
    /// @return The stored id.
    function roundIdView() external view returns (uint80) {
        return roundId;
    }

    /// @notice The round the answer came from.
    /// @return The stored answering round.
    function answeredInRoundView() external view returns (uint80) {
        return answeredInRound;
    }

    /// @notice Whether the latest-round read reverts.
    /// @return The stored flag.
    function revertsView() external view returns (bool) {
        return reverts;
    }

    /// @notice Sets the answer, for a rule that prices one state at two answers.
    /// @param a The answer to report.
    function setAnswer(int256 a) external {
        answer = a;
    }

    /// @notice Sets the whole latest round, for a rule that moves one feed and reads a pair priced off another.
    /// @param r The round id.
    /// @param a The answer.
    /// @param u The stamp.
    /// @param inRound The answering round.
    /// @param down Whether the read reverts.
    function setRound(uint80 r, int256 a, uint256 u, uint80 inRound, bool down) external {
        roundId = r;
        answer = a;
        updatedAt = u;
        answeredInRound = inRound;
        reverts = down;
    }
}

/// @title MockPriceFeedB
/// @notice A second feed contract with its own storage, so a two-pair rule can move one pair's feed and not the other's.
contract MockPriceFeedB is MockPriceFeed {}
