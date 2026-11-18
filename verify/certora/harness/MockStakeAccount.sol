// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.36;

/// @title MockStakeAccount
/// @notice The three reads `NftAccountRecord` makes on an account, each able to REVERT instead of answering.
/// @notice The revert switches are the point: REC-2 and REC-3 are about the record's `try`/`catch` legs, and a
/// @notice summarized call always returns, so a summary could never reach them.
/// @dev Holds no stake and mints no receipt. Every answer is storage the prover sets, so it explores the whole domain.
contract MockStakeAccount {
    bool internal held; // what holdsStake answers when it answers
    uint256 internal supply; // what totalSupply answers when it answers
    uint256 internal back; // what backing answers when it answers
    bool internal heldReverts; // holdsStake reverts instead of answering
    bool internal supplyReverts; // totalSupply reverts instead of answering
    bool internal backReverts; // backing reverts instead of answering

    /// @notice Whether this account holds its staked NFT.
    /// @return True when it holds the stake.
    function holdsStake() external view returns (bool) {
        if (heldReverts) revert();
        return held;
    }

    /// @notice The receipt supply, read through IERC20 by the record.
    /// @return The supply.
    function totalSupply() external view returns (uint256) {
        if (supplyReverts) revert();
        return supply;
    }

    /// @notice The quote-side backing behind the whole receipt supply.
    /// @return The backing.
    function backing() external view returns (uint256) {
        if (backReverts) revert();
        return back;
    }

    /// @notice The supply a spec compares the record's answer against, without a call the record would catch.
    /// @return The stored supply.
    function supplyView() external view returns (uint256) {
        return supply;
    }

    /// @notice The backing a spec compares the record's answer against, without a call the record would catch.
    /// @return The stored backing.
    function backingView() external view returns (uint256) {
        return back;
    }

    /// @notice Whether any of the three reads is set to revert.
    /// @return True when at least one read reverts.
    function anyReverts() external view returns (bool) {
        return heldReverts || supplyReverts || backReverts;
    }

    /// @notice Whether the account answers that it holds its stake, without a call the record would catch.
    /// @return The stored flag.
    function heldView() external view returns (bool) {
        return held;
    }

    /// @notice Sets the backing, for the monotonicity rule that prices one account at two backings.
    /// @param b The backing to answer with.
    /// @dev Monotonicity compares two prices, so it needs two states; every other rule reads the prover's initial one.
    function setBacking(uint256 b) external {
        back = b;
    }

    /// @notice Sets the receipt supply, for the monotonicity rule that prices one account at two supplies.
    /// @param s The supply to answer with.
    /// @dev A rising supply divides the same backing across more receipts, so the price must not rise.
    function setSupply(uint256 s) external {
        supply = s;
    }
}
