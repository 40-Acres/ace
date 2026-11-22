// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.36;

import {Ace} from "../../../src/ace/hub/Ace.sol";
import {Cfg, LenderUnresolved, Loan, Market, Storage} from "../../../src/ace/hub/Types.sol";
import {LoanAccounting} from "../../../src/ace/hub/libraries/LoanAccounting.sol";
import {LoanMath} from "../../../src/ace/hub/libraries/LoanMath.sol";
import {Constants} from "../../../src/ace/hub/Constants.sol";
import {FullMath} from "@uniswap/v4-core/src/libraries/FullMath.sol";

/// @title HubCoverageHarness
/// @notice The hub plus read-only views for the coverage, keeper and liveness rules, each a single read or one library call.
/// @notice A separate contract from AceHarness, so these views leave every other hub conf's scene as it was.
/// @dev No view calls a hub-internal helper such as `_cache`: each builds what it reads from `Storage` alone, as ExtendHarness does.
/// @dev It adds views and no state, so the layout is the hub's and every method under test is its own.
contract HubCoverageHarness is Ace {
    constructor(address treasury, address positionManager, uint256 pushGas, uint256 policyGas) Ace(treasury, positionManager, pushGas, policyGas) {}

    /// @notice The global id counter loans and orders draw from.
    function idCount() external view returns (uint256) {
        return Storage.book().count;
    }

    /// @notice When a loan closed; zero while it is live.
    function closedAtOf(uint256 loanId) external view returns (uint64) {
        return Storage.book().loans[loanId].closedAt;
    }

    /// @notice A loan's collateral units.
    function loanUnitsOf(uint256 loanId) external view returns (uint256) {
        return Storage.book().loans[loanId].collateralUnits;
    }

    /// @notice A loan's debt.
    function loanDebtOf(uint256 loanId) external view returns (uint256) {
        return Storage.book().loans[loanId].debt;
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

    /// @notice A loan's expiry.
    function loanExpiryOf(uint256 loanId) external view returns (uint64) {
        return Storage.book().loans[loanId].expiry;
    }

    /// @notice Collateral units credited to one claimant on one loan.
    function unitsOwedOf(uint256 loanId, address claimant) external view returns (uint256) {
        return Storage.book().unitsOwed[loanId][claimant];
    }

    /// @notice One claimant's quote claim on one loan.
    function quoteClaimOf(uint256 loanId, address claimant) external view returns (uint256) {
        return Storage.book().quoteOwed[loanId][claimant];
    }

    /// @notice The fee escrow withheld for one loan id.
    function feeEscrowOfLoan(uint256 loanId) external view returns (uint256) {
        return Storage.book().feeEscrowOf[loanId];
    }

    /// @notice The maker-side market of a credit order; zero for an id no order was posted under.
    function orderMarketOf(uint256 orderId) external view returns (bytes32) {
        return Storage.book().orders[orderId].market;
    }

    /// @notice A market's quote token; zero for a market never created.
    function marketQuoteOf(bytes32 id) external view returns (address) {
        return Storage.markets()[id].p.quote;
    }

    /// @notice Whether a market names a price record.
    function marketRecordOf(bytes32 id) external view returns (address) {
        return Storage.markets()[id].p.record;
    }

    /// @notice The market fields the coverage line reads, which genesis rails.
    function marketRailsOf(bytes32 id) external view returns (uint256 minCoverageWad, uint256 unitScale, uint256 price) {
        Market storage M = Storage.markets()[id];
        return (M.p.minCoverageWad, M.s.unitScale, M.p.price);
    }

    /// @notice The smallest loan a market opens.
    function marketMinPrincipalOf(bytes32 id) external view returns (uint256) {
        return Storage.markets()[id].p.minPrincipal;
    }

    /// @notice A market's keeper sliver rate.
    function marketSettleBountyBpsOf(bytes32 id) external view returns (uint256) {
        return Storage.markets()[id].p.settleBountyBps;
    }

    /// @notice A market's deleverage dials: the keeper's eps, the band, the target, the stop and the protocol cut.
    function marketDeleverageOf(bytes32 id) external view returns (uint256 eps, uint256 band, uint256 target, uint256 stop, uint256 cut) {
        Market storage M = Storage.markets()[id];
        return (M.p.deleverageFloorEpsBps, M.p.deleverageBandBps, M.p.deleverageTargetBps, M.p.deleverageStopBps, M.p.deleverageProtocolBps);
    }

    /// @notice How long past expiry a band-on market's dark record holds the settle doors.
    function settleDarkGrace() external pure returns (uint256) {
        return Constants.SETTLE_DARK_GRACE;
    }

    /// @notice One quote token's protocol revenue pot, which every market in that quote shares.
    function protocolRevenueOf(address quote) external view returns (uint256) {
        return Storage.revenue()[quote];
    }

    /// @notice One market's quote claims pot.
    function quoteOwedTotalOf(bytes32 id) external view returns (uint256) {
        return Storage.markets()[id].s.quoteOwedTotal;
    }

    /// @notice A market's running backed-burn total and its realized loss at book.
    function marketTotalsOf(bytes32 id) external view returns (uint256 backedBurns, uint256 realizedLoss) {
        Market storage M = Storage.markets()[id];
        return (M.s.cumulativeBackedBurns, M.s.realizedLossAtBook);
    }

    /// @notice What a market's lender is owed in that market's quote.
    function marketOwedOf(bytes32 id) external view returns (uint256) {
        return Storage.poolOf(Storage.markets()[id].p).owed;
    }

    /// @notice What a market's lender has lent in that market's quote.
    function marketLentOf(bytes32 id) external view returns (uint256) {
        return Storage.poolOf(Storage.markets()[id].p).lent;
    }

    /// @notice A market's lender's unsold units of that market's collateral.
    function marketUnsoldUnitsOf(bytes32 id) external view returns (uint256) {
        return Storage.byCollateralOf(Storage.markets()[id].p).unsoldUnits;
    }

    /// @notice A market's pair counts of unsold and settled pots.
    function marketPotCountsOf(bytes32 id) external view returns (uint256 unsoldPots, uint256 settledPots) {
        LenderUnresolved storage u = Storage.unresolvedOf(Storage.markets()[id].p);
        return (u.unsoldPots, u.settledPots);
    }

    /// @notice The units a disposal of this loan may size against now: `LoanAccounting.securedBase` on its market's fields and its lot.
    function securedBaseOf(uint256 loanId) external view returns (uint256) {
        Loan storage L = Storage.book().loans[loanId];
        return LoanAccounting.securedBase(Storage.book(), Storage.markets()[L.market], _fieldsOf(L.market), loanId, L.collateralUnits);
    }

    /// @notice What a settlement of this loan now would owe its claim in units: `LoanAccounting.collateralNeeded`.
    function settlementNeedOf(uint256 loanId) external view returns (uint256) {
        bytes32 m = Storage.book().loans[loanId].market;
        return LoanAccounting.collateralNeeded(Storage.markets()[m], _fieldsOf(m), loanId);
    }

    /// @notice The keeper's sliver a settlement of this loan now would take off its whole lot: `LoanAccounting.sliverUnits`.
    function settlementSliverOf(uint256 loanId) external view returns (uint256) {
        Loan storage L = Storage.book().loans[loanId];
        return LoanAccounting.sliverUnits(Storage.book(), Storage.markets()[L.market], _fieldsOf(L.market), loanId, L.collateralUnits);
    }

    /// @notice The price a deleverage crank on this loan must clear now: its stop level, the trigger over one less the stop margin, ceiled.
    /// @dev The one RE-SPELLING in this harness: `Deleverage.deleverage` computes it inline, so no hub function returns it.
    function stopLevelOf(uint256 loanId) external view returns (uint256) {
        Loan storage L = Storage.book().loans[loanId];
        Market storage M = Storage.markets()[L.market];
        uint256 trig = LoanMath.triggerPrice(L.debt, L.collateralUnits, M.p.minCoverageWad, M.s.unitScale);
        return FullMath.mulDivRoundingUp(trig, 1e18, 1e18 - M.p.deleverageStopBps * 1e14);
    }

    /// @dev A config carrying the market's params and unit scale, the only fields the views' callees read.
    function _fieldsOf(bytes32 m) private view returns (Cfg memory c) {
        Market storage M = Storage.markets()[m];
        c.p = M.p;
        c.unitScale = M.s.unitScale;
    }
}
