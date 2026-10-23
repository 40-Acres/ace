// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.36;

import {BelowMinDebt, Borrower, CollateralOutOfRange, TenorOutOfRange} from "./Borrower.sol";
import {LoanMath} from "./libraries/LoanMath.sol";
import {Recipients} from "./libraries/Recipients.sol";
import {Cfg, LoanBook, Market, OpenBounds, Order} from "./Types.sol";
import {IPositionManager} from "../../interfaces/IPositionManager.sol";
import {Mul512} from "../../utils/Mul512.sol";
import {Math} from "@openzeppelin/contracts/utils/math/Math.sol";

error MinFillOutOfRange(); // the maker's fill floor sits outside [minDebt, principal]
error NotMaker(); // only the order's own maker may retire it
error OrderClosed(); // the maker has retired the order and taken the escrow back
error FillOverOrder(); // this fill asks for more principal or more collateral than is left
error FillBelowMin(); // this fill is under the maker's own floor on a single fill
error FillOverCollateralized(); // more collateral per principal than the REMAINING escrow; that ratio, not `liqLow`, is the band's low end at a fill
error FillUnderCollateralized(); // this fill takes so little collateral its trigger lands over the band's high end
error RemainderBelowMin(); // this fill would strand a remainder no legal fill could take
error BadLiquidationBand(); // the band is inverted, or its low end is zero and would size an unbounded escrow
error OrderPrincipalOutOfRange(); // coverage times the order principal exceeds the sizing numerator's range

/// @title Orders
/// @notice Credit orders: a maker's escrowed, expiring pre-commitment to borrow, fillable by anyone.
/// @notice A maker states a BAND of liquidation prices; the collateral its LOW end implies is escrowed.
/// @notice Order ids come from the loan counter, so an id names a loan or an order and never both.
/// @notice A fill IS an open, through the one open body, with every gate it already carries.
library Orders {
    /// @notice What a maker states at post; the collateral is derived, never stated.
    struct PostArgs {
        bytes32 market;
        address maker;
        uint256 principal;
        uint256 liqLow; // the escrow is sized here, plus the fill slack; fills follow the REMAINING escrow, so a full take triggers at or under it
        uint256 liqHigh; // the worst trigger the maker will accept; equal to `liqLow` pins one price
        uint256 minFillPrincipal;
        uint64 tenor;
        uint64 expiry;
    }

    /// @dev `market` is indexed because order ids are GLOBAL: without it no log filter is market-scoped.
    event OrderPosted(
        uint256 indexed id,
        bytes32 indexed market,
        address indexed maker,
        uint256 collateralUnits,
        uint256 principal,
        uint256 minFillPrincipal,
        uint64 tenor,
        uint64 expiry
    );
    event OrderFilled(uint256 indexed id, uint256 indexed loanId, address indexed filler, uint256 principalOut, uint256 unitsOut);
    event OrderRetired(uint256 indexed id, address indexed to, uint256 unitsReturned);

    /// @notice Escrows the collateral the band's LOW end implies, and rests the terms.
    /// @dev Ids come from the SAME counter as loans, which is what makes every loan verb fail closed on one.
    /// @dev The escrow is pulled LAST, after the record exists: no half-created order can be observed.
    /// @param B The loan book, which allocates the id and holds the order.
    /// @param M The market this ask is against.
    /// @param c The market's config cache.
    /// @param a The maker's stated terms.
    /// @return id The new order id.
    function post(LoanBook storage B, Market storage M, Cfg memory c, PostArgs memory a) public returns (uint256 id) {
        a.tenor = Borrower.tenorOrMin(a.tenor, c.p.minTenor); // resolved HERE, so the order, its fills and its log carry the term
        if (a.principal < c.p.minDebt) revert BelowMinDebt();
        if (a.tenor < c.p.minTenor || a.tenor > c.p.maxTenor) revert TenorOutOfRange();
        /// @dev Rejected here rather than at the derivation, which answers a zero price with a max-units sentinel.
        if (a.liqLow == 0 || a.liqHigh < a.liqLow) revert BadLiquidationBand();
        uint256 minFill = a.minFillPrincipal == 0 ? c.p.minDebt : a.minFillPrincipal;
        if (minFill < c.p.minDebt || minFill > a.principal) revert MinFillOutOfRange();
        /// @dev Sized at the LOW end, so the escrow covers the fattest fill the band admits.
        uint256 units = collateralFor(c, a.principal, a.liqLow, minFill);
        id = ++B.count;
        Order storage o = B.orders[id];
        o.market = a.market;
        o.maker = a.maker;
        o.tenor = a.tenor;
        o.collateralUnits = units;
        o.principal = a.principal;
        o.minFillPrincipal = minFill; // the RESOLVED value: the sentinel lives in calldata and never in storage
        o.liqHigh = a.liqHigh;
        o.expiry = a.expiry;
        M.orderIds.push(id);
        IPositionManager(c.positionManager).pull(id, a.maker, units);
        emit OrderPosted(id, a.market, a.maker, units, a.principal, minFill, a.tenor, a.expiry);
    }

    /// @notice The collateral the band's LOW end implies, at the market's own coverage rule.
    /// @notice CEILS, so the realised trigger sits at or below the stated price and never above it.
    /// @dev `requiredAt` is the function the coverage line itself calls: ONE spelling, no second copy to drift.
    /// @dev Each fill ceils its own requirement and adds the line's atom, so an order that can split needs two atoms per minimum fill.
    /// @dev An order that can only fill whole needs the line's one atom: under two minimum fills, a partial would strand its remainder.
    /// @dev No take lowers the remaining ratio, so with the low end at or under the market's price a full pro-rata take clears its line.
    /// @param c The market's config cache.
    /// @param principal The quote wanted.
    /// @param liquidationPrice The price to size at; `post` passes the band's low end.
    /// @param minFillPrincipal The maker's floor on one fill, which sizes the slack.
    /// @return The collateral units to escrow.
    function collateralFor(Cfg memory c, uint256 principal, uint256 liquidationPrice, uint256 minFillPrincipal) internal pure returns (uint256) {
        if (principal > type(uint256).max / c.p.minCoverageWad) revert OrderPrincipalOutOfRange();
        // both doublings fit: minFill is at most principal, which the line above bounds by max / minCoverageWad, and coverage is at least 2 wei
        uint256 slack = principal < 2 * minFillPrincipal ? 1 : Math.ceilDiv(2 * principal, minFillPrincipal);
        uint256 limit = type(uint256).max / 1e18;
        if (slack > limit) revert CollateralOutOfRange();
        uint256 budget = limit - slack; // reserve the additive slack before sizing the collateral
        uint256 num = c.p.minCoverageWad * principal;
        if (liquidationPrice <= limit && Mul512.gt512(num, c.unitScale, budget, liquidationPrice * 1e18)) revert CollateralOutOfRange();
        /// @dev Above that price branch, Q96 is smaller than the divisor, so `requiredAt`'s inner quotient fits.
        uint256 required = Borrower.requiredAt(c, principal, liquidationPrice);
        if (required > budget) revert CollateralOutOfRange();
        return required + slack;
    }

    /// @notice Draws part or all of a resting order, as an ordinary open titled to the MAKER.
    /// @notice Permissionless: the lender who wants the loan to exist fills it, deposit and fill in one multicall.
    /// @dev The custody hand-off is the carry pair, debit here and credit inside the open with the same `unitsOut`; the custodian checks no pairing.
    /// @dev `payer` is the zero address because the carry moves no token; `payee` is the maker.
    /// @dev The order's own expiry rides as the open's deadline, so the HUB refuses a late fill; zero never expires.
    /// @dev A fill NEVER closes the order: the last of the principal can go and leave escrow only `close` returns.
    /// @param B The loan book.
    /// @param M The order's market.
    /// @param c The market's config cache.
    /// @param id The order to draw against.
    /// @param principalOut Quote to draw on this fill.
    /// @param unitsOut Collateral to carry into the loan.
    /// @return loanId The loan this fill created.
    function fill(LoanBook storage B, Market storage M, Cfg memory c, uint256 id, uint256 principalOut, uint256 unitsOut) public returns (uint256 loanId) {
        Order storage o = B.orders[id];
        if (o.closed) revert OrderClosed();
        if (principalOut > o.principal || unitsOut > o.collateralUnits) revert FillOverOrder();
        if (principalOut < o.minFillPrincipal) revert FillBelowMin();
        /// @dev THE BAND: the low end is the escrow's REMAINING ratio, division-free, at or under `liqLow`; the high end is the stored `liqHigh`.
        if (Mul512.gt512(unitsOut, o.principal, principalOut, o.collateralUnits)) revert FillOverCollateralized();
        if (LoanMath.triggerPrice(principalOut, unitsOut, c.p.minCoverageWad, c.unitScale) > o.liqHigh) revert FillUnderCollateralized();
        uint256 rp = o.principal - principalOut;
        /// @dev The remaining PRINCIPAL is always zero or at least the floor: `collateralFor`'s one-atom arm relies on it to refuse every partial.
        if (rp != 0 && rp < o.minFillPrincipal) revert RemainderBelowMin();
        o.principal -= principalOut;
        o.collateralUnits -= unitsOut;
        IPositionManager(c.positionManager).carryOut(id, unitsOut);
        OpenBounds memory bnd = OpenBounds(0, 0, o.expiry);
        loanId = Borrower.openCarried(B, M, c, Borrower.OpenArgs(o.market, o.maker, address(0), o.maker, unitsOut, principalOut, o.tenor, bnd), id);
        emit OrderFilled(id, loanId, msg.sender, principalOut, unitsOut);
    }

    /// @notice Retires a resting order and returns whatever escrow is left.
    /// @notice `to` is the maker's own choice, which is what lets a blacklisted maker recover elsewhere.
    /// @notice `to` is never zero, the hub or the positionManager: refused after the maker check, before the closed flag.
    /// @dev A spent escrow makes no transfer, so a collateral refusing zero-value transfers cannot block the close.
    /// @param B The loan book.
    /// @param c The market's config cache.
    /// @param id The order to retire.
    /// @param to Recipient of the remaining escrow.
    /// @return units The collateral returned.
    function close(LoanBook storage B, Cfg memory c, uint256 id, address to) public returns (uint256 units) {
        Order storage o = B.orders[id];
        if (msg.sender != o.maker) revert NotMaker();
        Recipients.check(to, c.positionManager);
        if (o.closed) revert OrderClosed();
        units = o.collateralUnits;
        o.collateralUnits = 0;
        /// @dev Principal zeroes WITH the escrow, so a retired record can never read as fillable.
        /// @dev What went unfilled is in the events; a closed record holding a live-looking remainder is not worth keeping.
        o.principal = 0;
        o.closed = true;
        if (units > 0) IPositionManager(c.positionManager).release(id, to, units);
        emit OrderRetired(id, to, units);
    }
}
