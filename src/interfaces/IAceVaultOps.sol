// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.36;

import {MigrateArgs, OpenBounds} from "../ace/hub/Types.sol";

/// @title IAceVaultOps
/// @notice The hub verbs an AceVault reaches beyond `IAceLenderOps`, each declared only where its mode or door needs it.
/// @dev `redeemInKind` takes a settled loan's pot home in kind, or to a door; only the collect calls it.
/// @dev `extend`, `borrowerOf`, `debtOf` and the term word's `extsload` are `extendFor`'s.
/// @dev `refinanceTo` is `refinanceFor`'s, which also reads `borrowerOf`, `debtOf` and the term word.
/// @dev `drawMore` is `drawMoreFor`'s, which reads what `refinanceFor` reads.
/// @dev EVERY MEMBER MUST EXIST ON THE HUB WITH THIS EXACT SIGNATURE: a call compiles against this declaration alone.
interface IAceVaultOps {
    function redeemInKind(uint256 loanId, address to) external returns (uint256 out);
    function extend(uint256 id, uint256 minBufferWad, bytes calldata data) external returns (uint256 fee);
    function refinanceTo(MigrateArgs calldata m) external returns (uint256);
    function drawMore(uint256 id, uint256 amount, OpenBounds calldata bnd) external returns (uint256 fee);
    function borrowerOf(uint256 id) external view returns (address);
    function debtOf(uint256 loanId) external view returns (uint256);
    function extsload(bytes32 slot) external view returns (bytes32);
}
