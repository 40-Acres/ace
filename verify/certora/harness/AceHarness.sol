// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.36;

import {Ace} from "../../../src/ace/hub/Ace.sol";
import {Loan, Market, Storage} from "../../../src/ace/hub/Types.sol";
import {MarketInit} from "../../../src/ace/hub/MarketInit.sol";

/// @title AceHarness
/// @notice The hub plus read-only views, so a spec reads namespaced storage through the hub's own accessors.
/// @notice The prover does not resolve an ERC-7201 annotation on a FILE-LEVEL struct, which is where Types.sol keeps them.
/// @notice It adds views and no state, so the layout is the hub's and every method under test is its own.
contract AceHarness is Ace {
    constructor(address treasury, address positionManager, uint256 pushGas) Ace(treasury, positionManager, pushGas) {}

    /// @notice One market's protocol revenue pot.
    function protocolRevenueOf(bytes32 id) external view returns (uint256) {
        return Storage.markets()[id].s.protocolRevenue;
    }

    /// @notice When a loan closed; zero while it is live.
    function closedAtOf(uint256 loanId) external view returns (uint64) {
        return Storage.book().loans[loanId].closedAt;
    }

    /// @notice The global id counter loans and orders draw from.
    function idCount() external view returns (uint256) {
        return Storage.book().count;
    }

    /// @notice The first instant the unpaid backstop admits a loan: `settleExpired`'s own window test.
    function backstopOpensAt(uint256 loanId) external view returns (uint256) {
        Loan storage L = Storage.book().loans[loanId];
        return uint256(L.expiry) + MarketInit.autoRefinanceWindow(L.tenor);
    }

    /// @notice A loan's debt.
    function loanDebtOf(uint256 loanId) external view returns (uint256) {
        return Storage.book().loans[loanId].debt;
    }

    /// @notice A loan's collateral units.
    function loanUnitsOf(uint256 loanId) external view returns (uint256) {
        return Storage.book().loans[loanId].collateralUnits;
    }

    /// @notice A loan's live claim, read in its own market.
    function loanClaimOf(uint256 loanId) external view returns (uint256) {
        return Storage.markets()[Storage.book().loans[loanId].market].claim[loanId];
    }

    /// @notice A loan's current borrower, the title of record.
    function loanBorrowerOf(uint256 loanId) external view returns (address) {
        return Storage.book().loans[loanId].borrower;
    }

    /// @notice A loan's settled inventory pot, read in its own market.
    function loanPotOf(uint256 loanId) external view returns (uint256) {
        return Storage.markets()[Storage.book().loans[loanId].market].invPotOf[loanId];
    }

    /// @notice Collateral units credited to one claimant on one loan.
    function unitsOwedOf(uint256 loanId, address claimant) external view returns (uint256) {
        return Storage.book().unitsOwed[loanId][claimant];
    }

    /// @notice A market's running backed-burn total and its realized loss at book.
    function marketTotalsOf(bytes32 id) external view returns (uint256 backedBurns, uint256 realizedLoss) {
        Market storage M = Storage.markets()[id];
        return (M.s.cumulativeBackedBurns, M.s.realizedLossAtBook);
    }

    /// @notice The market fields the coverage line reads, which genesis rails.
    function marketRailsOf(bytes32 id) external view returns (uint256 minCoverageWad, uint256 unitScale, uint256 price) {
        Market storage M = Storage.markets()[id];
        return (M.p.minCoverageWad, M.s.unitScale, M.p.price);
    }

    /// @notice A loan's claim in a NAMED market, which need not be the loan's own.
    function claimInMarket(bytes32 id, uint256 loanId) external view returns (uint256) {
        return Storage.markets()[id].claim[loanId];
    }

    /// @notice The smallest debt a market issues, which genesis refuses at zero.
    function marketMinDebtOf(bytes32 id) external view returns (uint256) {
        return Storage.markets()[id].p.minDebt;
    }

    /// @notice The hash of a market's stored params, the preimage `createMarket` derives its id from.
    function marketParamsHashOf(bytes32 id) external view returns (bytes32) {
        return keccak256(abi.encode(Storage.markets()[id].p));
    }

    /// @notice What a market's lender is owed in that market's quote.
    function marketOwedOf(bytes32 id) external view returns (uint256) {
        return Storage.poolOf(Storage.markets()[id].p).owed;
    }

    /// @notice What a market's lender has lent in that market's quote.
    function marketLentOf(bytes32 id) external view returns (uint256) {
        return Storage.poolOf(Storage.markets()[id].p).lent;
    }

    /// @notice What a market's lender has lent in that market's quote against that market's collateral.
    function marketLentByCollateralOf(bytes32 id) external view returns (uint256) {
        return Storage.byCollateralOf(Storage.markets()[id].p).lent;
    }

    /// @notice A loan's armed continuation tenor; zero is disarmed.
    function autoTenorOf(uint256 loanId) external view returns (uint64) {
        return Storage.book().autoPolicyOf[loanId].tenor;
    }

    /// @notice A digest of everything one market holds, so "untouched" is one comparison.
    /// @dev Params, state, the claim and inventory pot of one loan id, and both append-only list lengths.
    /// @param loanId The loan whose per-market claim and inventory pot the digest also covers.
    function marketDigest(bytes32 id, uint256 loanId) external view returns (bytes32) {
        Market storage M = Storage.markets()[id];
        return keccak256(abi.encode(M.p, M.s, M.claim[loanId], M.invPotOf[loanId], M.openedLoans.length, M.orderIds.length));
    }

    /// @notice The maker of a credit order; zero for an id no order was posted under.
    function orderMakerOf(uint256 orderId) external view returns (address) {
        return Storage.book().orders[orderId].maker;
    }

    /// @notice The market a credit order belongs to.
    function orderMarketOf(uint256 orderId) external view returns (bytes32) {
        return Storage.book().orders[orderId].market;
    }

    /// @notice The fee escrow withheld for one loan id.
    function feeEscrowOfLoan(uint256 loanId) external view returns (uint256) {
        return Storage.book().feeEscrowOf[loanId];
    }

    /// @notice Where swept revenue lands; the hub keeps it internal.
    function treasuryOf() external view returns (address) {
        return TREASURY;
    }

    /// @notice A market's quote token; zero for a market never created.
    function marketQuoteOf(bytes32 id) external view returns (address) {
        return Storage.markets()[id].p.quote;
    }

    /// @notice One claimant's quote claim on one loan, as a single word.
    function quoteClaimOf(uint256 loanId, address claimant) external view returns (uint256) {
        return Storage.book().quoteOwed[loanId][claimant];
    }

    /// @notice One market's quote claims pot: what its claimants may pull, held outside the lender's pools.
    function quoteOwedTotalOf(bytes32 id) external view returns (uint256) {
        return Storage.markets()[id].s.quoteOwedTotal;
    }
}
