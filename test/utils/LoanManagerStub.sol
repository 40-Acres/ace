// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.36;

/// @title LoanManagerStub
/// @notice The loan-manager surface `PositionManager` reads back, for positionManager-only tests that stand up no hub.
/// @dev With ONE positionManager a loan's collateral and quote are no longer positionManager immutables.
/// @dev The positionManager resolves them per loan by calling `escrowConfigOf` on its own loan manager.
/// @dev So a test that IS the loan manager must answer, or every entry point reverts before its guard.
/// @dev One default config serves every id, since most of these suites run one collateral.
/// @dev A per-loan override exists for the carry tests, which need two loans on two different tokens.
contract LoanManagerStub {
    /// @notice A per-loan override of the default pair, for the tests that need two collaterals at once.
    struct Cfg {
        address collateral;
        address quote;
        bool set;
    }

    address internal stubCollateral;
    address internal stubQuote;

    mapping(uint256 => Cfg) internal perLoan;
    mapping(uint256 => bool) internal stubClosed;

    /// @notice Answers for EVERY loan id, which is what a PositionManager-only ledger test wants.
    /// @param collateral The token the positionManager will take into custody.
    /// @param quote The market's accounting token; unread on the custody path.
    function _stubLoanConfig(address collateral, address quote) internal {
        stubCollateral = collateral;
        stubQuote = quote;
    }

    /// @notice Per-loan config, for a suite whose loans all quote the same pair.
    /// @param loanId The loan being overridden.
    /// @param collateral The token this one loan is funded in.
    /// @param quote The market's accounting token; unread on the custody path.
    function _stubLoanConfigFor(uint256 loanId, address collateral, address quote) internal {
        perLoan[loanId] = Cfg(collateral, quote, true);
    }

    /// @notice Marks a loan closed; the carry gate reads it back through `isLiveLoan`.
    /// @param loanId The loan to close.
    /// @param isClosed_ The liveness answer this stub gives for it.
    function _stubClosed(uint256 loanId, bool isClosed_) internal {
        stubClosed[loanId] = isClosed_;
    }

    /// @notice The read `PositionManager` makes on pull, release, carryIn and releaseRetired.
    /// @param loanId The loan whose pair is being resolved.
    /// @return collateral The loan's collateral token.
    /// @return quote The loan's quote token.
    function escrowConfigOf(uint256 loanId) external view returns (address collateral, address quote) {
        Cfg memory c = perLoan[loanId];
        if (c.set) return (c.collateral, c.quote);
        return (stubCollateral, stubQuote);
    }

    /// @notice Loan lifecycle state. Kept beside `isLiveLoan` because both are real hub views.
    function isClosed(uint256 loanId) external view returns (bool) {
        return stubClosed[loanId];
    }

    /// @notice What the carry actually gates on: the source must not be a LIVE LOAN.
    /// @dev The stub models loans only: an unstubbed id reads LIVE here, where the hub reads an unopened id as not live.
    function isLiveLoan(uint256 loanId) external view returns (bool) {
        return !stubClosed[loanId];
    }
}
