// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.36;

/// @title BoundaryTitle
/// @notice Stands in for the hub's loan-title collection in the vault's boundary spec: who holds each title, and the two moves the vault and the hub make.
/// @notice It counts each holder's titles and the most it held, so a spec reads the vault's count without a storage hook.
/// @dev Never deployed. A move checks only that `from` holds the title, so it admits every move the real collection does.
contract BoundaryTitle {
    mapping(uint256 id => address) public ownerOf; // a title's holder, zero for none
    mapping(address holder => uint256) public heldBy; // how many titles a holder holds
    mapping(address holder => uint256) public peakOf; // the most a holder has held since the spec cleared it

    /// @notice The hub's mint at an open or a refinance; a reused id leaves its old holder's count.
    function mint(address to, uint256 id) external {
        address was = ownerOf[id];
        if (was != address(0)) heldBy[was] -= 1;
        _land(to, id);
    }

    /// @notice Move a title its holder holds.
    function transferFrom(address from, address to, uint256 id) external {
        require(ownerOf[id] == from, "not the holder");
        heldBy[from] -= 1;
        _land(to, id);
    }

    /// @notice How many titles a holder holds, as the collection answers it.
    function balanceOf(address holder) external view returns (uint256) {
        return heldBy[holder];
    }

    /// @dev Title `id` to `to`, counted, with its peak raised.
    function _land(address to, uint256 id) private {
        ownerOf[id] = to;
        uint256 n = heldBy[to] + 1;
        heldBy[to] = n;
        if (n > peakOf[to]) peakOf[to] = n;
    }
}
