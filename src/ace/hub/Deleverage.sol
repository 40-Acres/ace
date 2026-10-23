// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.36;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {Math} from "@openzeppelin/contracts/utils/math/Math.sol";
import {IAceDeleverageCallback} from "../../interfaces/IAceDeleverageCallback.sol";
import {Borrower, NoRecordPrice} from "./Borrower.sol";
import {LoanAccounting} from "./libraries/LoanAccounting.sol";
import {Transfers} from "./libraries/Transfers.sol";
import {Cfg, Loan, LoanBook, Market} from "./Types.sol";
import {IPositionManager} from "../../interfaces/IPositionManager.sol";
import {FullMath} from "@uniswap/v4-core/src/libraries/FullMath.sol";

error LoanClosed(); // the loan is retired: no sale verb touches it
error LoanMatured(); // the tenor has run out: the expiry fold owns the loan, no sale touches it
error Distressed(); // persistent distress: the settlement machine owns the loan, deleverage stands down
error DeleverageDisabled(); // the market's deleverage band is zero
error NotInBand(); // margin not persistently below the band: nothing to deleverage
error DeleverageStopped(); // margin below the per-market stop floor: title-transfer settlement owns the loan

/* ========================================================================= */
/*  TABLE OF CONTENTS                                                        */
/*  1. DELEVERAGE  sell into the band, above the stop                        */
/*  2. DISPOSAL    sizing, the waterfall, and the shared sale core           */
/* ========================================================================= */

/// @title Deleverage
/// @notice Selling collateral against a LIVE loan to restore margin once the record proves the band.
/// @notice A sale here is a TRADE. When a loan ends instead, title moves and that is `Settlement`.
/// @dev Disposal is KEEPER-ROUTED: ACE ships no venue, releases the units, then validates the proceeds.
/// @dev The floor is the record's windowed minimum, less `deleverageFloorEpsBps`, and it is the price the sale was sized at.
/// @dev A sale never takes a live loan's debt under `minDebt`, so a third party's crank cannot choose what the loan's expiry fold decides.
library Deleverage {
    using SafeERC20 for IERC20;

    /// @dev One disposal's arguments, handed to the shared body as ONE value.
    /// @dev Every field is a uint256, so the sole call site constructs it BY NAME: a transposition would compile.
    struct Disposal {
        uint256 id;
        uint256 unitsSold;
        uint256 floorPrice;
    }

    /// @dev `executor` is the EXTERNAL caller of the crank, which a periphery sponsor pays against.
    event Deleveraged(uint256 indexed id, uint256 unitsSold, uint256 stableOut, uint256 debtPaid, address indexed executor);
    /// @dev `from` is the payer; on a deleverage that is the hub itself, and the keeper is `Deleveraged.executor`.
    event Recash(uint256 indexed loanId, uint256 amount, address indexed from);

    /* ====== 1. DELEVERAGE ====== */

    /// @notice Sells just enough collateral to restore the target margin once the record proves the band.
    /// @notice Every unit of proceeds, net of any protocol cut, melts debt. Permissionless, and only before distress and before expiry.
    /// @notice From the expiry second it refuses with `LoanMatured`, the same condition and error as a collateral withdrawal.
    /// @notice A crank whose with-cut restore does not fit its caps re-sizes cut-free, then caps: it takes no cut and may still stop short of target.
    /// @notice The position keeps what settlement would need, so a fully reserved crank sells nothing and returns zero.
    /// @notice At or under `minDebt` it returns zero right after the disabled, closed and matured gates; no record read or later refusal runs.
    /// @dev Selling helps only while `pay/u > D/C`, and NO per-crank test of that exists: the runtime stop check bounds the price.
    /// @dev What bounds the take is the `stop below sellmax onset` rail with the stop gate: together they hold the sizing at `u <= C`.
    /// @dev Being in the band buys no exemption from the fill floor: the windowed minimum less eps binds every crank.
    /// @dev Every admitted crank lowers `D/C` and the cap idles the expiry fold's `minDebt` floor: bar atom rounding, no crank flips an armed roll.
    /// @dev The crank's `< expiry` and the fold's `>= expiry` must stay disjoint: no second admits both.
    function deleverage(LoanBook storage B, Market storage M, Cfg memory c, uint256 id, bytes calldata data)
        public
        returns (uint256 unitsSold, uint256 stableOut)
    {
        Loan storage L = B.loans[id];
        if (c.p.deleverageBandBps == 0) revert DeleverageDisabled(); // precede sizing
        if (L.closedAt != 0) revert LoanClosed();
        if (block.timestamp >= L.expiry) revert LoanMatured(); // before the record reads: a matured crank makes no external call
        uint256 head = Math.saturatingSub(L.debt, c.p.minDebt); // the most a melt may take off this loan
        if (head == 0) return (0, 0); // at or under minDebt: no record read, no callback, no event
        if (Borrower.inDistress(L, c)) revert Distressed();
        uint256 ps;
        uint256 free;
        {
            uint256 trig = Borrower.triggerPrice(L, c);
            /// @dev the price where margin == band, ceiled against the borrower; below it the channel opens
            uint256 bandLevel = FullMath.mulDivRoundingUp(trig, 1e18, 1e18 - c.p.deleverageBandBps * 1e14);
            /// @dev A record that cannot answer is UNREADABLE, never out of band: the band never spoke.
            if (!Borrower.persistedBelowOrRevert(c, bandLevel)) revert NotInBand();
            ps = Borrower.persistedPrice(c); // ONE read: it sizes the sale and it is the disposal floor
            if (ps == 0) revert NoRecordPrice();
            /// @dev Ceiled against the borrower and STRICT (`ps > stopLevel`): with the sell-max rail it caps the sizing at `u <= C`.
            /// @dev `u == C` is admitted, not excluded, and benign.
            uint256 stopLevel = FullMath.mulDivRoundingUp(trig, 1e18, 1e18 - c.p.deleverageStopBps * 1e14);
            if (ps <= stopLevel) revert DeleverageStopped();
            (unitsSold, free) = _deleverageSizing(c, L.collateralUnits, trig, ps);
        }
        if (unitsSold == 0) return (0, 0); // at or above target, or a dust restore; `_fit` follows because its room's no-wrap bound needs a sale
        bool charge;
        (unitsSold, charge) = _fit(B, M, c, id, unitsSold, free, head, ps);
        if (unitsSold == 0) return (0, 0); // a cap, or a cut-free restore under one unit, left nothing to sell: no callback, no zero-unit event
        L.collateralUnits -= unitsSold;
        (unitsSold, stableOut) = _dispose(B, c, Disposal({id: id, unitsSold: unitsSold, floorPrice: ps}), data);
        uint256 pay = _meltAll(B, M, c, id, stableOut, charge);
        emit Deleveraged(id, unitsSold, stableOut, pay, msg.sender);
    }

    /* ====== 2. DISPOSAL: sizing, the waterfall, and the sale core ====== */

    /// @dev Closed-form restore-to-target `u = C (T - T*) / (k m (1-cut) Ps/1e18 - T*)`, k = minCoverageWad.
    /// @dev Returns it twice: `u` with the cut, and `free` with none, the restore a crank that takes no cut is sized to.
    /// @dev Rounded down to dust. Positivity is NOT the `deleverage denominator` rail, and the cut cancels out of the bound.
    /// @dev Four facts carry it: the early return below, the strict ceiled stop gate, `stop below sellmax onset`, and `k (1-eps) > 1`.
    /// @dev `free`'s denominator `y - T*` is at least `u`'s, so it is positive whenever `u`'s is, and `free <= u`.
    /// @dev The same bound gives `u <= units`, so the clamp below is a backstop against a retune, never a live path.
    /// @dev `tStar` divides through mulDiv, so the restore target is exact at any record width.
    /// @dev `y` pairs the eps complement with `minCoverageWad`, railed at `MAX_COVERAGE_WAD`, so `ps` never rides a plain product.
    /// @dev Melt-per-unit is `(1-eps)(1-cut)Ps`, so the cut scales the sale by `(y - T*) / (y (1-cut) - T*)`, always above `1/(1-cut)`; borrower-borne.
    /// @dev Actual restore lands ON target, since the floor IS `Ps`: the sale is priced at exactly what it was sized at.
    function _deleverageSizing(Cfg memory c, uint256 units, uint256 trig, uint256 ps) private pure returns (uint256 u, uint256 free) {
        uint256 tStar = FullMath.mulDiv(ps, 1e18 - c.p.deleverageTargetBps * 1e14, 1e18); // the trigger the sale restores to
        if (trig <= tStar) return (0, 0); // already at or above target: sizing and trigger are one inequality
        uint256 y = FullMath.mulDiv(ps, c.p.minCoverageWad * (10000 - c.p.deleverageFloorEpsBps), 1e18 * 10000);
        u = Math.min(FullMath.mulDiv(units, trig - tStar, FullMath.mulDiv(y, 10000 - c.p.deleverageProtocolBps, 10000) - tStar), units);
        free = Math.min(FullMath.mulDiv(units, trig - tStar, y - tStar), units);
    }

    /// @dev Sells `u` and charges the cut iff `u < units` and `u <= cap = min(securedBase, room)`; else sells `min(free, cap)` with no cut.
    /// @dev Neither cap is ever crossed, and `free <= u`, so the sale never exceeds `min(u, cap)`.
    /// @dev `room` is the exact inverse of `_owed`: the largest sale whose proceeds cannot melt the debt under `minDebt`.
    /// @dev `ps * (10000 - eps)` cannot wrap: the sizing sold, so `ps < (trig + 1) * 1e4`, and a live trigger never exceeds the price, at most `MAX_PRICE`.
    function _fit(LoanBook storage B, Market storage M, Cfg memory c, uint256 id, uint256 u, uint256 free, uint256 head, uint256 ps)
        private
        view
        returns (uint256 sold, bool charge)
    {
        uint256 units = B.loans[id].collateralUnits;
        uint256 room = FullMath.mulDiv(head, 10000 * c.unitScale, ps * (10000 - c.p.deleverageFloorEpsBps));
        uint256 cap = Math.min(LoanAccounting.securedBase(B, M, c, id, units), room);
        if (u < units && u <= cap) return (u, true);
        return (Math.min(free, cap), false);
    }

    /// @dev The decline channel's waterfall: a protocol cut off the top, then every remaining unit melts debt.
    /// @dev The cut is taken only when the cut-charging restore fit (`charge`); a re-sized crank melts in full.
    /// @dev A PARTIAL FILL keeps `charge` and pays the cut on what filled; the sizing priced the cut in, so it is borrower-borne, never lender-borne.
    /// @dev The cut floors PER CRANK, and a keeper sizes each crank by its refund: a sale split over N cranks forgoes under N quote atoms of cut.
    /// @dev A partial fill can lift the loan out of band short of target; a repay of that melt, permissionless above `minDebt`, lifts it further.
    /// @dev The `minDebt` cap bounds `net` by `debt - minDebt`, so a melt never closes the loan and nothing is left to credit back.
    /// @dev The subtraction stays CHECKED: were the cap ever to regress into an overshoot, the crank reverts rather than under-credits.
    function _meltAll(LoanBook storage B, Market storage M, Cfg memory c, uint256 id, uint256 stableOut, bool charge) private returns (uint256 net) {
        if (stableOut == 0) return 0; // a wholly refused fill is an exact no-op
        net = stableOut;
        if (charge && c.p.deleverageProtocolBps > 0) {
            // truncates down, loan-favourable
            uint256 cut = FullMath.mulDiv(stableOut, c.p.deleverageProtocolBps, 10000);
            if (cut > 0) {
                LoanAccounting.accrueProtocolFee(M, cut);
                net = stableOut - cut;
            }
        }
        B.loans[id].debt -= net;
        Borrower.shrinkReserve(B, M, c, id); // a lower debt needs no more roll than it had: an armed share only shrinks
        LoanAccounting.meltLoan(M, id, net);
        emit Recash(id, net, address(this));
    }

    /// @dev What the keeper owes for `units`. Ceil: the payer never rounds in their own favour.
    /// @dev The eps complement pairs with `units`, which entry caps at `max / 1e18`, so `floorPrice` never rides a plain product.
    function _owed(Cfg memory c, uint256 units, uint256 floorPrice) private pure returns (uint256) {
        return FullMath.mulDivRoundingUp(floorPrice, units * (10000 - c.p.deleverageFloorEpsBps), 10000 * c.unitScale);
    }

    /// @dev COLLATERAL is debited before the hand-off, at the whole `unitsSold`: the keeper needs the units.
    /// @dev The DEBT leg CANNOT be, and this is the reason: what filled is a balance delta, unreadable until it returns.
    /// @dev So a loan reads OVER-distressed inside the callback, which is the conservative side and is chosen.
    /// @dev The keeper routes the units as it likes; ACE collects by an exact pull on what actually filled.
    function _dispose(LoanBook storage B, Cfg memory c, Disposal memory d, bytes calldata data) private returns (uint256 filled, uint256 stableOut) {
        uint256 preColl = IERC20(c.p.collateral).balanceOf(address(this)); // detect a partial-fill refund
        IPositionManager(c.positionManager).release(d.id, msg.sender, d.unitsSold);
        IAceDeleverageCallback(msg.sender).onAceDeleverage(d.unitsSold, _owed(c, d.unitsSold, d.floorPrice), data);
        filled = _recreditRefund(B, c, d, preColl);
        stableOut = _owed(c, filled, d.floorPrice);
        if (stableOut > 0) Transfers.pullQuote(c, msg.sender, stableOut);
    }

    /// @dev On a partial fill, re-credit the unsold tail; the next crank re-sizes from scratch.
    function _recreditRefund(LoanBook storage B, Cfg memory c, Disposal memory d, uint256 preColl) private returns (uint256) {
        Loan storage L = B.loans[d.id];
        uint256 refund = IERC20(c.p.collateral).balanceOf(address(this)) - preColl;
        refund = Math.min(refund, d.unitsSold); // a donation mid-sell must not underflow `filled`
        if (refund == 0) return d.unitsSold;
        IERC20(c.p.collateral).forceApprove(c.positionManager, refund);
        IPositionManager(c.positionManager).pull(d.id, address(this), refund);
        L.collateralUnits += refund; // net debit is now `filled`
        return d.unitsSold - refund;
    }
}
