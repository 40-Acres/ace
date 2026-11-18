// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.36;

/// @title MockYbGauge
/// @notice A YieldBasis staking gauge as `YbRecord` reads it: its asset, its decimals and its LT-per-share, all storage.
/// @notice `convertToAssets` answers PER SHARE COUNT, so a record asking for any count but one share reads a different number.
/// @dev DISPATCHED rather than linked, since the record takes the gauge as a constructor argument.
contract MockYbGauge {
    uint8 internal dec; // what decimals answers
    address internal assetAddr; // what asset answers
    mapping(uint256 => uint256) internal assetsOf; // what convertToAssets answers, per share count
    bool internal reverts; // convertToAssets reverts instead of answering

    /// @notice The gauge's decimals.
    /// @return The stored decimals.
    function decimals() external view returns (uint8) {
        return dec;
    }

    /// @notice The token the gauge stakes.
    /// @return The stored asset.
    function asset() external view returns (address) {
        return assetAddr;
    }

    /// @notice LT units for `shares`, or a revert while the flag is set.
    /// @param shares The share count asked about.
    /// @return The stored conversion for that count.
    function convertToAssets(uint256 shares) external view returns (uint256) {
        require(!reverts, "gauge down");
        return assetsOf[shares];
    }

    /// @notice LT units for `shares`, read without the revert flag.
    /// @param shares The share count.
    /// @return The stored conversion.
    function assetsView(uint256 shares) external view returns (uint256) {
        return assetsOf[shares];
    }

    /// @notice Whether the conversion reverts.
    /// @return The stored flag.
    function revertsView() external view returns (bool) {
        return reverts;
    }
}
