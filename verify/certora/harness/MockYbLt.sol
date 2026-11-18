// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.36;

/// @title MockYbLt
/// @notice A YieldBasis liquidity token as `YbRecord` reads it: two rate legs, its asset token and its decimals, all storage.
/// @notice Each rate leg reverts on its own flag, as the upstream nonreentrant `preview_withdraw` does mid-operation.
/// @notice `preview_withdraw` answers PER SHARE COUNT, so a record asking for any count but one share reads a different number.
/// @dev DISPATCHED rather than linked, since the record takes the LT as a constructor argument.
contract MockYbLt {
    uint8 internal dec; // what decimals answers
    address internal assetToken; // what ASSET_TOKEN answers
    uint256 internal pps; // what pricePerShare answers
    mapping(uint256 => uint256) internal withdrawOf; // what preview_withdraw answers, per share count
    bool internal ppsReverts; // pricePerShare reverts instead of answering
    bool internal previewReverts; // preview_withdraw reverts instead of answering

    /// @notice The LT's decimals.
    /// @return The stored decimals.
    function decimals() external view returns (uint8) {
        return dec;
    }

    /// @notice The token the LT redeems into.
    /// @return The stored asset token.
    function ASSET_TOKEN() external view returns (address) {
        return assetToken;
    }

    /// @notice The accounting rate, 18-decimal, or a revert while its flag is set.
    /// @return The stored rate.
    function pricePerShare() external view returns (uint256) {
        require(!ppsReverts, "pps locked");
        return pps;
    }

    /// @notice The redemption quote for `shares`, underlying-native, or a revert while its flag is set.
    /// @param shares The share count asked about.
    /// @return The stored quote for that count.
    function preview_withdraw(uint256 shares) external view returns (uint256) {
        require(!previewReverts, "pool locked");
        return withdrawOf[shares];
    }

    /// @notice The accounting rate a spec compares against.
    /// @return The stored rate.
    function ppsView() external view returns (uint256) {
        return pps;
    }

    /// @notice The redemption quote for `shares`, read without the revert flag.
    /// @param shares The share count.
    /// @return The stored quote.
    function withdrawView(uint256 shares) external view returns (uint256) {
        return withdrawOf[shares];
    }

    /// @notice Whether the accounting read reverts.
    /// @return The stored flag.
    function ppsRevertsView() external view returns (bool) {
        return ppsReverts;
    }

    /// @notice Whether the redemption read reverts.
    /// @return The stored flag.
    function previewRevertsView() external view returns (bool) {
        return previewReverts;
    }

    /// @notice Sets the accounting rate, for a two-state rule.
    /// @param v The rate.
    function setPps(uint256 v) external {
        pps = v;
    }

    /// @notice Sets the redemption quote for `shares`, for a two-state rule.
    /// @param shares The share count.
    /// @param w The quote.
    function setWithdraw(uint256 shares, uint256 w) external {
        withdrawOf[shares] = w;
    }
}
