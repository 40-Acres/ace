// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.36;

import {MarketParams} from "../ace/hub/Types.sol";

/// @notice One extension, whole, as the hub hands it to the lender's roll policy.
/// @dev STATIC BY DESIGN, with `caller` at word 0: an echo of the first word equals the yes only for a caller whose top 16 bytes are zero.
/// @dev The hub never asks for such a caller: an extension's caller is the holder or the market lender, and a refinance's the holder.
/// @dev `dst` equals `src` on every ask: an extension stays in place, and only a refinance into the loan's own market reuses its claim.
/// @dev An extension never moves the debt, so `newDebt` is `debt`; a refinance's ask carries the successor's `units`, `newDebt` and `newExpiry`.
/// @dev An extension's `newExpiry` is now plus the loan's own tenor, so `newExpiry - expiry` is exactly the time it adds and is charged for.
struct Extension {
    address caller; // the external caller: the holder, or the market lender holding the holder's grant and paying the fee
    uint256 loanId;
    address borrower; // the loan's title holder
    uint256 units; // the collateral the extended loan keeps
    uint256 debt; // the loan's debt before the extension
    uint256 newDebt; // the debt the extension leaves: `debt` itself, or a refinanced successor's principal
    uint64 expiry; // the loan's expiry before the extension
    uint64 newExpiry; // the expiry the extension leaves
    MarketParams src; // the market the loan is in
    MarketParams dst; // the market the continued loan lands in
}

/// @title IRollPolicy
/// @notice A lender's standing answer to whether one of its loans may run longer on its money.
/// @notice The hub asks with a gas-capped STATICCALL; a revert, a short or long return, or any word but the selector is a no.
/// @notice It is also asked before a `refinanceTo` into the loan's own market reuses the retiring claim; a no there draws the whole principal fresh.
/// @notice Asked under the hub's lock by `extend` and `refinanceTo`: a `nonReentrantView` read, as a vault's NAV makes, reverts; `tryExtend` asks unlocked.
/// @notice A policy MUST FAIL CLOSED: any failure of its own, an inner call out of gas included, answers no.
/// @notice A policy MUST BOUND its work on `data`: the hub fixes the gas it hands the policy, never the payload a caller sends.
/// @dev The hub's gas floor makes the answer a function of state, not of the caller's limit; it makes a fail-open policy deterministic, never safe.
interface IRollPolicy {
    /// @notice Whether the lender consents to this extension.
    /// @param e The extension in question.
    /// @param data The caller's own payload on `extend`; empty from a `refinanceTo`.
    /// @return `IRollPolicy.admitsExtension.selector` to consent; any other answer refuses.
    function admitsExtension(Extension calldata e, bytes calldata data) external view returns (bytes4);
}
