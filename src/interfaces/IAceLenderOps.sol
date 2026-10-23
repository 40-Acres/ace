// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.36;

import {MarketParams, OpenBounds} from "../ace/hub/Types.sol";

/// @title IAceLenderOps
/// @notice The hub surface a lender-side vault is allowed to reach: its pool reads, its market's cash, and the borrower verbs its door and roll run.
/// @dev Through this type, `redeemInKind` and `multicall` do not compile; a vault that takes a pot in kind must declare a wider type to reach one.
/// @dev Each would put value the vault counts outside its own hands, so no later edit can quietly reach one.
/// @dev The vault is the transient BORROWER of every loan its door opens, so `open` and `setAutoRefinance` belong here.
/// @dev BOTH EXITS PAY OUT OF THE CALLER'S OWN POSITION: `withdraw` is lender-only and `collect` is keyed by `msg.sender`.
/// @dev Both take a `to`, and a vault passes itself by CONVENTION: the type cannot say `to == address(this)`.
/// @dev EVERY MEMBER MUST EXIST ON THE HUB WITH THIS EXACT SIGNATURE: a call compiles against this declaration alone.
/// @dev A verb the hub renamed, or whose ARGUMENTS it re-typed, reverts at RUNTIME behind a green build, its selector being gone.
/// @dev A SAME-TYPE ARGUMENT SWAP keeps the selector and does NOT revert: old `collect(lender, quote)` runs as `(quote, to)`, paying 0.
/// @dev A RETURN change keeps the selector too: a narrower declaration decodes the hub's leading words, a wider one reverts on short returndata.
interface IAceLenderOps {
    function POSITION_MANAGER() external view returns (address);
    function POSITION_TITLE() external view returns (address);
    function idToMarketParams(bytes32 id) external view returns (MarketParams memory);
    function lenderAssets(address lender, address quote) external view returns (uint256);
    function lenderOwed(address lender, address quote) external view returns (uint256);
    function lenderUnresolved(address lender, address quote) external view returns (uint256 unsoldPots, uint256 settledPots);
    function lenderByCollateral(address lender, address quote, address collateral) external view returns (uint256 lent, uint256 unsoldUnits);
    function loanMarket(uint256 id) external view returns (bytes32);
    function restingOf(bytes32 id) external view returns (uint256);
    function debtOf(uint256 loanId) external view returns (uint256);
    function isClosed(uint256 id) external view returns (bool);
    function tryContinue(uint256 id) external view returns (bool ok, bytes4 reason, uint256 principal);
    function createMarket(MarketParams calldata p) external returns (bytes32 id);
    function deposit(bytes32 id, uint256 assets) external;
    function withdraw(bytes32 id, uint256 assets, address to, uint256 minPaid) external returns (uint256 paid);
    function collect(address quote, address to) external returns (uint256 paid);
    function open(bytes32 id, uint256 collateralUnits, uint256 principal, uint64 tenor, address borrower, OpenBounds calldata bnd) external returns (uint256);
    function setAutoRefinance(uint256 id, uint64 tenor, uint16 minBufferBps, uint16 maxFeeBps) external;
    function refinanceByPolicy(uint256 id) external returns (uint256);
}
