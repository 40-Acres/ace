// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.36;

/// @title AceVaultTail
/// @notice The fixed suffix AceVault appends to every forwarded call: its write-once figures in five words, after the caller's bytes.
/// @notice A forwarded library body reads them from the end of its own calldata, so the last `SIZE` bytes are the vault's whatever the caller sent.
/// @notice Word 0 holds the hub, the cap timelock at bit 160 and the mode byte at bit 224.
/// @notice The mode byte's bit 0 is in-kind mode and bit 1 door mode; each reader takes its own bit alone, and both clear is hub-ask mode.
/// @notice Word 1 holds the curator; its high 96 bits are free.
/// @notice Word 2 holds the guardian and the terms' high 80 bits at bit 160; word 3 the asset and the terms' low 80 bits at bit 160.
/// @notice Word 4 holds the hub's loan-title collection, the rail floor at bit 160 and the rail ceiling at bit 208, 48 bits each.
/// @dev ERC-2771's representation for its appended sender: written by the code that forwards the call, read from `calldatasize()` back.
/// @dev Only the vault's own DELEGATECALL runs a forwarded body, as the library call guard refuses a direct call to a state-changing one.
library AceVaultTail {
    uint256 internal constant SIZE = 160; // five words: `pack`'s four, then `word4`
    uint256 private constant LOW80 = (1 << 80) - 1;

    /// @notice The four words the vault packs once, at deploy, from the figures its named immutables take.
    function pack(address hub, address cur, address guard, address cash, uint64 lock, bool kind)
        internal
        pure
        returns (bytes32 w0, bytes32 w1, bytes32 w2, bytes32 w3)
    {
        uint256 mode = kind ? 1 : 0;
        w0 = bytes32(uint256(uint160(hub)) | (uint256(lock) << 160) | (mode << 224));
        w1 = bytes32(uint256(uint160(cur)));
        (w2, w3) = (bytes32(uint256(uint160(guard))), bytes32(uint256(uint160(cash))));
    }

    /// @notice Words 2 and 3 with the terms' high 80 bits atop the first and its low 80 bits atop the second.
    function withTerms(bytes32 w2, bytes32 w3, address terms_) internal pure returns (bytes32, bytes32) {
        uint256 t = uint160(terms_);
        return (w2 | bytes32((t >> 80) << 160), w3 | bytes32((t & LOW80) << 160));
    }

    /// @notice Word 0 with the mode byte's door bit set.
    function withDoor(bytes32 w0) internal pure returns (bytes32) {
        return w0 | bytes32(uint256(1) << 225);
    }

    /// @notice Word 4: the hub's loan-title collection, the rail floor at bit 160 and the rail ceiling at bit 208.
    /// @dev The vault's constructor rails both ends to at most a few years of seconds, so 48 bits hold each whole.
    function word4(address title_, uint64 floor_, uint64 ceiling) internal pure returns (bytes32) {
        return bytes32(uint256(uint160(title_)) | (uint256(uint48(floor_)) << 160) | (uint256(uint48(ceiling)) << 208));
    }

    /// @notice The hub.
    function ace() internal pure returns (address) {
        return address(uint160(_word(0)));
    }

    /// @notice How long a cap raise waits.
    function capTimelock() internal pure returns (uint64) {
        return uint64(_word(0) >> 160);
    }

    /// @notice Whether the vault runs in kind: the mode byte's bit 0 alone.
    function inKind() internal pure returns (bool) {
        return (_word(0) >> 224) & 1 != 0;
    }

    /// @notice Whether the vault runs in door mode: the mode byte's bit 1 alone.
    function door() internal pure returns (bool) {
        return (_word(0) >> 225) & 1 != 0;
    }

    function curator() internal pure returns (address) {
        return address(uint160(_word(1)));
    }

    function guardian() internal pure returns (address) {
        return address(uint160(_word(2)));
    }

    /// @notice The vault's asset.
    function asset() internal pure returns (address) {
        return address(uint160(_word(3)));
    }

    /// @notice The product's terms contract, rejoined from the high bits of words 2 and 3.
    function terms() internal pure returns (address) {
        return address(uint160(((_word(2) >> 160) << 80) | (_word(3) >> 160)));
    }

    /// @notice The hub's loan-title collection.
    function title() internal pure returns (address) {
        return address(uint160(_word(4)));
    }

    /// @notice The rail's floor.
    function minTenor() internal pure returns (uint64) {
        return uint64(uint48(_word(4) >> 160));
    }

    /// @notice The rail's ceiling.
    function maxTenor() internal pure returns (uint64) {
        return uint64(_word(4) >> 208);
    }

    /// @dev Word `i` of the suffix, counted from its first word, read back from the end of calldata.
    function _word(uint256 i) private pure returns (uint256 w) {
        assembly ("memory-safe") {
            w := calldataload(sub(calldatasize(), sub(SIZE, shl(5, i))))
        }
    }
}
