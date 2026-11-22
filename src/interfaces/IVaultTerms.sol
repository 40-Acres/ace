// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.36;

import {MarketParams} from "../ace/hub/Types.sol";
import {BorrowRequest, Terms} from "../curator/libraries/AceVaultFlows.sol";
import {Extension} from "./IRollPolicy.sol";

/// @notice Which lending verb a product's write call brackets.
enum Lend {
    Borrow,
    Extend,
    Refinance // a refinance, or a top-up in place, whose consent is the same refinance answer
}

/// @notice What a holder asks `refinanceFor` for: the successor's draw and term, the payout's floors, and any collateral shed.
struct RefinanceRequest {
    address collateral;
    uint256 principal;
    uint64 tenor; // zero takes the market's shortest
    uint256 minPayout; // the least net cash the holder accepts
    uint256 minBufferWad;
    uint64 deadline; // the latest second the refinance may land, or zero for none
    uint256 withdrawUnits; // collateral the successor releases
    address withdrawTo; // where released collateral goes; never the vault
}

/// @title IVaultTerms
/// @notice A product's terms, plugged into an AceVault by address at deploy: read-only answers, plus two write calls only the vault makes.
/// @notice EVERY ANSWER CAN ONLY TIGHTEN: the vault checks each market, draw and term against its own caps, cash and tenor rail first.
/// @notice The vault asks by STATIC CALL; a revert refuses the borrow it was asked for, and refuses no exit, since no exit asks.
/// @notice `entryCap` and `room` read zero on any failure; `admitsExtension` is asked last, and anything but a clean true is a no.
/// @dev `beforeLend` and `afterLend` run with the vault's lock held: a re-entry into any vault mutator, share moves included, reverts.
/// @dev They may write the product's own storage only; their return value is never read, and no approval names this contract.
interface IVaultTerms {
    /// @notice The one vault this product serves; the vault's constructor refuses a product naming any other.
    function VAULT() external view returns (address);

    /// @notice The market a borrow lands in and the draw admitted, for this borrower, request and payload; refuses by revert.
    /// @param borrower Who asks: the vault's caller.
    /// @param r What the borrower asks; the vault binds the answer to it.
    /// @param data The product's own payload, such as a signed quote.
    /// @return mp The market, which must name the vault as lender and its asset as quote.
    /// @return t The draw, at most what was asked.
    function borrowTerms(address borrower, BorrowRequest calldata r, bytes calldata data) external view returns (MarketParams memory mp, Terms memory t);

    /// @notice The market a holder's refinance lands in and its draw; refuses by revert. The vault binds the answer to the request as a borrow's.
    /// @notice A top-up asks it too, at the loan's debt plus the amount, and lands only on the loan's own market admitting all of it.
    /// @param holder The loan's title holder.
    /// @param loanId The loan being refinanced or topped up.
    /// @param r What the holder asks.
    /// @param data The product's own payload.
    /// @return mp The successor's market.
    /// @return t The successor's draw.
    function refinanceTerms(address holder, uint256 loanId, RefinanceRequest calldata r, bytes calldata data)
        external
        view
        returns (MarketParams memory mp, Terms memory t);

    /// @notice Whether the product still consents to one of the vault's loans continuing in its own market; the vault's own legs are asked first.
    /// @notice `extendFor` asks with the holder as `e.borrower`, a same-market `refinanceFor` with the vault, which then holds the title.
    /// @notice The hub lets anyone extend, so `e.caller` may be a stranger: a product that consents only to its vault or holder checks it.
    /// @param e The extension, as the hub handed it to the vault.
    /// @param data The caller's payload.
    /// @return Whether the product consents.
    function admitsExtension(Extension calldata e, bytes calldata data) external view returns (bool);

    /// @notice The most a new placement in this market may draw under the product's own judgment; the vault takes the smaller of this and its own room.
    /// @param mp The market.
    /// @return The product's room, in asset units.
    function room(MarketParams calldata mp) external view returns (uint256);

    /// @notice The most a deposit for `receiver` may bring now, in assets; the vault reads zero while draining or if this fails.
    /// @param receiver The share recipient.
    /// @param nav The vault's NAV the deposit prices at.
    /// @return The cap, `type(uint256).max` for none.
    function entryCap(address receiver, uint256 nav) external view returns (uint256);

    /// @notice Write the product's own record for a lending verb: a borrow's after the pledge arrives and before any cash rests. THE VAULT ONLY.
    /// @notice An extension's runs after its fee is pulled and before the hub's extend; a refinance's once the vault holds the title, before any rest.
    /// @notice A top-up's runs before its rest, the holder keeping the title.
    /// @param kind Which lending verb.
    /// @param mp The market.
    /// @param loanId The loan being extended, refinanced or topped up, zero for a borrow.
    /// @param data The product's own payload.
    function beforeLend(Lend kind, MarketParams calldata mp, uint256 loanId, bytes calldata data) external;

    /// @notice Write the product's own record after a lending verb: a borrow's once the cash and the title have left the vault. THE VAULT ONLY.
    /// @notice An extension's runs once the hub's extend took the fee priced; a refinance's once both titles and the net are home.
    /// @notice A top-up's runs once the hub paid the holder and the vault drained the market.
    /// @param kind Which lending verb.
    /// @param mp The market.
    /// @param loanId The loan opened, extended, refinanced into or topped up.
    /// @param holder The loan's title holder.
    /// @param data The product's own payload.
    function afterLend(Lend kind, MarketParams calldata mp, uint256 loanId, address holder, bytes calldata data) external;
}
