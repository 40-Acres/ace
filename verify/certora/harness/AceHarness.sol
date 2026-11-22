// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.36;

import {Ace} from "../../../src/ace/hub/Ace.sol";
import {LenderUnresolved, Loan, LoanBook, Market, Storage} from "../../../src/ace/hub/Types.sol";
import {LoanMath} from "../../../src/ace/hub/libraries/LoanMath.sol";
import {Constants} from "../../../src/ace/hub/Constants.sol";

/// @title AceHarness
/// @notice The hub plus read-only views, so a spec reads namespaced storage through the hub's own accessors.
/// @notice The prover does not resolve an ERC-7201 annotation on a FILE-LEVEL struct, which is where Types.sol keeps them.
/// @notice It adds views and no state, so the layout is the hub's and every method under test is its own.
contract AceHarness is Ace {
    constructor(address treasury, address positionManager, uint256 pushGas, uint256 policyGas) Ace(treasury, positionManager, pushGas, policyGas) {}

    /// @notice One quote token's protocol revenue pot, which every market in that quote shares.
    function protocolRevenueOf(address quote) external view returns (uint256) {
        return Storage.revenue()[quote];
    }

    /// @notice When a loan closed; zero while it is live.
    function closedAtOf(uint256 loanId) external view returns (uint64) {
        return Storage.book().loans[loanId].closedAt;
    }

    /// @notice The global id counter loans and orders draw from.
    function idCount() external view returns (uint256) {
        return Storage.book().count;
    }

    /// @notice A loan's expiry: the first instant `forceClose` admits it.
    function loanExpiryOf(uint256 loanId) external view returns (uint64) {
        return Storage.book().loans[loanId].expiry;
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

    /// @notice The smallest loan a market opens, which genesis refuses under two.
    function marketMinPrincipalOf(bytes32 id) external view returns (uint256) {
        return Storage.markets()[id].p.minPrincipal;
    }

    /// @notice A market's live debt floor, half its `minPrincipal` rounded down, through the hub's own helper.
    function marketDebtFloorOf(bytes32 id) external view returns (uint256) {
        return LoanMath.debtFloor(Storage.markets()[id].p.minPrincipal);
    }

    /// @notice The principal a loan was born with, written once at the birth and never cleared.
    function principalOfLoan(uint256 loanId) external view returns (uint256) {
        return Storage.book().principalOf[loanId];
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

    /// @notice A market's lender's resting pool in that market's quote, across all that lender's markets in it.
    function marketRestingPoolOf(bytes32 id) external view returns (uint256) {
        return Storage.poolOf(Storage.markets()[id].p).resting;
    }

    /// @notice What a market's lender has lent in that market's quote against that market's collateral.
    function marketLentByCollateralOf(bytes32 id) external view returns (uint256) {
        return Storage.byCollateralOf(Storage.markets()[id].p).lent;
    }

    /// @notice A market's lender's unsold units of that market's collateral, which a settlement leaving a pot raises by the pot.
    function marketUnsoldUnitsOf(bytes32 id) external view returns (uint256) {
        return Storage.byCollateralOf(Storage.markets()[id].p).unsoldUnits;
    }

    /// @notice A market's pair counts of unsold and settled pots, each of which a settlement leaving a pot raises by one.
    function marketPotCountsOf(bytes32 id) external view returns (uint256 unsoldPots, uint256 settledPots) {
        LenderUnresolved storage u = Storage.unresolvedOf(Storage.markets()[id].p);
        return (u.unsoldPots, u.settledPots);
    }

    /// @notice A market's keeper sliver rate, which every settlement prices off the debt.
    function marketSettleBountyBpsOf(bytes32 id) external view returns (uint256) {
        return Storage.markets()[id].p.settleBountyBps;
    }

    /// @notice A market's deleverage band: non-zero is the class whose settlement reads the record's price.
    function marketBandBpsOf(bytes32 id) external view returns (uint256) {
        return Storage.markets()[id].p.deleverageBandBps;
    }

    /// @notice How long past expiry a band-on market's dark record holds the settle doors.
    function settleDarkGrace() external pure returns (uint256) {
        return Constants.SETTLE_DARK_GRACE;
    }

    /// @notice A digest of everything one market record holds, so "untouched" is one comparison.
    /// @dev Params, state, the claim and inventory pot of one loan id, both list lengths, and one entry of each list.
    /// @param loanId The loan whose per-market claim and inventory pot the digest also covers.
    /// @param index The position read in both lists; past a list's end it reads zero.
    function marketDigest(bytes32 id, uint256 loanId, uint256 index) external view returns (bytes32) {
        Market storage M = Storage.markets()[id];
        bytes32 record = keccak256(abi.encode(M.p, M.s, M.claim[loanId], M.invPotOf[loanId]));
        bytes32 lists = keccak256(abi.encode(M.openedLoans.length, M.orderIds.length, _entryAt(M.openedLoans, index), _entryAt(M.orderIds, index)));
        return keccak256(abi.encode(record, lists));
    }

    /// @notice One entry of a market's opened-loans list; zero past its end.
    function openedLoanAt(bytes32 id, uint256 index) external view returns (uint256) {
        return _entryAt(Storage.markets()[id].openedLoans, index);
    }

    /// @notice One entry of a market's order list; zero past its end.
    function orderIdAt(bytes32 id, uint256 index) external view returns (uint256) {
        return _entryAt(Storage.markets()[id].orderIds, index);
    }

    /// @notice A digest of one id's loan-side entries in the loan book, with one claimant's owed claims on it.
    /// @dev The loan record, its principal at open, its fee escrow, the claimant's owed units and quote, and its shortfall.
    function loanRecordDigest(uint256 loanId, address claimant) external view returns (bytes32) {
        LoanBook storage B = Storage.book();
        bytes32 owed = keccak256(abi.encode(B.unitsOwed[loanId][claimant], B.quoteOwed[loanId][claimant], B.shortfallOf[loanId]));
        return keccak256(abi.encode(B.loans[loanId], B.principalOf[loanId], B.feeEscrowOf[loanId], owed));
    }

    /// @notice A digest of one order's whole record.
    function orderRecordDigest(uint256 orderId) external view returns (bytes32) {
        return keccak256(abi.encode(Storage.book().orders[orderId]));
    }

    /// @dev The one read both list views and the digest share, so a witness on a view vouches for the digest's read.
    function _entryAt(uint256[] storage list, uint256 index) private view returns (uint256) {
        return index < list.length ? list[index] : 0;
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

    /// @notice A market's one named lender, whose roll policy every extension of its loans asks.
    function marketLenderOf(bytes32 id) external view returns (address) {
        return Storage.markets()[id].p.lender;
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
