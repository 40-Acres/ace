// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.36;

import {Ace} from "../../../src/ace/hub/Ace.sol";
import {LoanMath} from "../../../src/ace/hub/libraries/LoanMath.sol";
import {IRollPolicy} from "../../../src/interfaces/IRollPolicy.sol";
import {Loan, Market, MarketParams, MigrateArgs, Storage} from "../../../src/ace/hub/Types.sol";

/// @title ExtendHarness
/// @notice The hub plus read-only views, so a spec reads an extension's every write through code rather than a raw slot.
/// @notice The verbs under proof are the hub's own: `extend`, `refinanceTo` and `forceClose`.
/// @notice MUNGED ONLY: there the libraries are internal and inline; unmunged each verb is a linked library call the prover cannot follow.
/// @dev A separate contract from AceHarness, so these views leave every other hub conf's scene as it was.
/// @dev Each body is a single read or one library call: nothing here computes anything the hub does not.
contract ExtendHarness is Ace {
    constructor(address treasury, address positionManager, uint256 pushGas, uint256 policyGas) Ace(treasury, positionManager, pushGas, policyGas) {}

    /// @notice The global id counter loans and orders draw from.
    function idCount() external view returns (uint256) {
        return Storage.book().count;
    }

    /// @notice A loan's market, holder, collateral, debt and close stamp.
    function loanOf(uint256 id) external view returns (bytes32 market, address borrower, uint256 units, uint256 debt, uint64 closedAt) {
        Loan storage L = Storage.book().loans[id];
        return (L.market, L.borrower, L.collateralUnits, L.debt, L.closedAt);
    }

    /// @notice A loan's term: when it opened, how long it runs and when it expires.
    function termOf(uint256 id) external view returns (uint64 openTime, uint64 tenor, uint64 expiry) {
        Loan storage L = Storage.book().loans[id];
        return (L.openTime, L.tenor, L.expiry);
    }

    /// @notice When a loan's term opened, one field of `termOf`, for an invariant that cannot destructure.
    function loanOpenTime(uint256 id) external view returns (uint64) {
        return Storage.book().loans[id].openTime;
    }

    /// @notice How long a loan's term runs, one field of `termOf`.
    function loanTenor(uint256 id) external view returns (uint64) {
        return Storage.book().loans[id].tenor;
    }

    /// @notice When a loan expires, one field of `termOf`.
    function loanExpiry(uint256 id) external view returns (uint64) {
        return Storage.book().loans[id].expiry;
    }

    /// @notice The origination fee market `m` charges on `debt` for `added` seconds, as the hub prices an extension.
    /// @dev `LoanMath.originationFee` on the market's stored rate and shortest term, unsummarized past the spec's mulDiv.
    function originationFeeOf(bytes32 m, uint256 debt, uint64 added) external view returns (uint256) {
        MarketParams storage p = Storage.markets()[m].p;
        return LoanMath.originationFee(debt, added, p.baseBps, p.minTenor);
    }

    /// @notice The origination fee a loan's own open charged, as `_record` stored it.
    function lastFeeOf(uint256 id) external view returns (uint256) {
        return Storage.book().loans[id].lastFee;
    }

    /// @notice One loan's claim in a named market.
    function claimOf(bytes32 m, uint256 id) external view returns (uint256) {
        return Storage.markets()[m].claim[id];
    }

    /// @notice One loan's funded fee escrow.
    function feeEscrowOf(uint256 id) external view returns (uint256) {
        return Storage.book().feeEscrowOf[id];
    }

    /// @notice Whether a borrower granted an operator its credit delegation.
    function creditOperatorOf(address borrower, address operator) external view returns (bool) {
        return Storage.book().creditOperator[borrower][operator];
    }

    /// @notice One market's quote token, and its three booked pots: resting cash, protocol revenue and the claims pot.
    function marketOf(bytes32 m) external view returns (address quote, uint256 cash, uint256 revenue, uint256 quoteOwedTotal) {
        Market storage M = Storage.markets()[m];
        return (M.p.quote, M.s.cash, M.s.protocolRevenue, M.s.quoteOwedTotal);
    }

    /// @notice One market's collateral, record and lender: the contracts and the party it names.
    function marketWiringOf(bytes32 m) external view returns (address collateral, address record, address lender) {
        MarketParams storage p = Storage.markets()[m].p;
        return (p.collateral, p.record, p.lender);
    }

    /// @notice One market's tenor grid and its smallest debt.
    function marketTermsOf(bytes32 m) external view returns (uint64 minTenor, uint64 maxTenor, uint256 minPrincipal) {
        MarketParams storage p = Storage.markets()[m].p;
        return (p.minTenor, p.maxTenor, p.minPrincipal);
    }

    /// @notice How many draws and extensions a market has ever made.
    function drawCountOf(bytes32 m) external view returns (uint64) {
        return Storage.markets()[m].s.drawCount;
    }

    /// @notice The pool a market's lender draws on: resting, lent and owed.
    function poolOf(bytes32 m) external view returns (uint256 resting, uint256 lent, uint256 owed) {
        Market storage M = Storage.markets()[m];
        return (Storage.poolOf(M.p).resting, Storage.poolOf(M.p).lent, Storage.poolOf(M.p).owed);
    }

    /// @notice The roll policy a lender named; zero consents to none.
    function rollPolicyOf(address lender) external view returns (address) {
        return Storage.lenders().rollPolicyOf[lender];
    }

    /// @notice The one word a roll policy returns to consent.
    function policyYes() external pure returns (bytes32) {
        return bytes32(IRollPolicy.admitsExtension.selector);
    }

    /// @notice The protocol's share of a fee.
    function protocolCut(uint256 fee) external pure returns (uint256) {
        return LoanMath.protocolCut(fee);
    }

    /// @notice The refundable escrow share of a fee.
    function escrowCut(uint256 fee) external pure returns (uint256) {
        return LoanMath.escrowCut(fee);
    }

    /// @notice The lender's at-once share of a fee.
    function tickCut(uint256 fee) external pure returns (uint256) {
        return LoanMath.tickCut(fee);
    }
}
