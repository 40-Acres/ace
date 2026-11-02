// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.36;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {Math} from "@openzeppelin/contracts/utils/math/Math.sol";
import {IAceDeleverageCallback} from "../../interfaces/IAceDeleverageCallback.sol";
import {Borrower, LoanMatured, NoRecordPrice} from "./Borrower.sol";
import {Settlement} from "./Settlement.sol";
import {LoanAccounting} from "./libraries/LoanAccounting.sol";
import {LoanMath} from "./libraries/LoanMath.sol";
import {Transfers} from "./libraries/Transfers.sol";
import {Cfg, Loan, LoanBook, Market} from "./Types.sol";
import {IPositionManager} from "../../interfaces/IPositionManager.sol";
import {FullMath} from "@uniswap/v4-core/src/libraries/FullMath.sol";

error LoanClosed(); // the loan is retired: no sale verb touches it
error Distressed(); // persistent distress: the settlement machine owns the loan, deleverage stands down
error DeleverageDisabled(); // the market's deleverage band is zero
error NotInBand(); // margin not persistently below the band: nothing to deleverage
error DeleverageStopped(); // margin below the per-market stop floor: title-transfer settlement owns the loan
error CloseUnfilled(); // a closing sale filled short: it retires the whole debt or nothing

/* ========================================================================= */
/*  TABLE OF CONTENTS                                                        */
/*  1. DELEVERAGE  sell into the band, above the stop                        */
/*  2. DISPOSAL    sizing, the close, the waterfall, the sale core           */
/* ========================================================================= */

/// @title Deleverage
/// @notice Selling collateral against a LIVE loan to restore margin once the record proves the band.
/// @notice A sale here is a TRADE: a restore, or a close that retires the whole debt and closes the loan clean. Title moves only in `Settlement`.
/// @dev Disposal is KEEPER-ROUTED: ACE ships no venue, releases the units, then validates the proceeds.
/// @dev The floor is the record's windowed minimum, less `deleverageFloorEpsBps`, and it is the price the sale was sized at.
/// @dev No crank leaves a live loan under its debt floor: a restore that would is replaced by a sale of the whole debt, filled whole or reverted.
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

    /// @notice Sells just enough collateral to restore the target margin, or to close the loan, once the record proves the band.
    /// @notice Every unit of a restore's proceeds, net of any protocol cut, melts debt. Permissionless, and only before distress and before expiry.
    /// @notice A closing sale takes no cut; its overshoot of the debt is credited to the borrower.
    /// @notice From the expiry second it refuses with `LoanMatured`, the same condition and error as a collateral withdrawal.
    /// @notice A crank whose with-cut restore does not fit its cap re-sizes cut-free, then caps: it takes no cut and may still stop short of target.
    /// @notice The position keeps what settlement would need, so a fully reserved restore sells nothing and returns zero.
    /// @notice A loan AT its debt floor closes on any admitted crank whose restore sells a unit: any melt would leave it under.
    /// @dev The close decision is a SIZE rule on the full fill's net melt, never a per-crank health test.
    /// @dev Selling helps only while `pay/u > D/C`, and NO per-crank test of that exists: the runtime stop check bounds the price.
    /// @dev What bounds the take is the `stop below sellmax onset` rail with the stop gate: together they hold the sizing at `u <= C`.
    /// @dev Being in the band buys no exemption from the fill floor: the windowed minimum less eps binds every crank.
    /// @dev Every admitted crank lowers `D/C`, which only eases an extension's admission: bar atom rounding, no crank turns one into a refusal.
    /// @dev The crank's `< expiry` and `forceClose`'s `>= expiry` must stay disjoint: no second admits both.
    function deleverage(LoanBook storage B, Market storage M, Cfg memory c, uint256 id, bytes calldata data)
        public
        returns (uint256 unitsSold, uint256 stableOut)
    {
        Loan storage L = B.loans[id];
        if (c.p.deleverageBandBps == 0) revert DeleverageDisabled(); // precede sizing
        if (L.closedAt != 0) revert LoanClosed();
        if (block.timestamp >= L.expiry) revert LoanMatured(); // before the record reads: a matured crank makes no external call
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
        if (unitsSold == 0) return (0, 0); // at or above target, or a dust restore; the close's no-wrap bound needs a restore
        bool charge;
        (unitsSold, charge) = _fit(B, M, c, id, unitsSold, free);
        uint256 pay;
        /// @dev `floor + melt`, never `debt - melt`: a melt at or past the debt routes to the close and cannot underflow.
        if (L.debt < LoanMath.debtFloor(c.p.minPrincipal) + _net(c, _owed(c, unitsSold, ps), charge)) {
            (unitsSold, stableOut, pay) = _closeSale(B, M, c, id, ps, data);
        } else {
            if (unitsSold == 0) return (0, 0); // the reserve, or a cut-free restore under one unit, left nothing to sell: no callback, no event
            L.collateralUnits -= unitsSold;
            (unitsSold, stableOut) = _dispose(B, c, Disposal({id: id, unitsSold: unitsSold, floorPrice: ps}), data);
            pay = _meltAll(B, M, c, id, stableOut, charge);
        }
        emit Deleveraged(id, unitsSold, stableOut, pay, msg.sender);
    }

    /* ====== 2. DISPOSAL: sizing, the close, the waterfall, and the sale core ====== */

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

    /// @dev Sells `u` and charges the cut iff `u < units` and `u <= cap = securedBase`; else sells `min(free, cap)` with no cut.
    /// @dev The cap is never crossed, and `free <= u`, so the sale never exceeds `min(u, cap)`.
    function _fit(LoanBook storage B, Market storage M, Cfg memory c, uint256 id, uint256 u, uint256 free) private view returns (uint256 sold, bool charge) {
        uint256 units = B.loans[id].collateralUnits;
        uint256 cap = LoanAccounting.securedBase(B, M, c, id, units);
        if (u < units && u <= cap) return (u, true);
        return (Math.min(free, cap), false);
    }

    /// @dev The protocol cut on `gross` when the restore charges it, truncated down, loan-favourable: the decision and the melt share it.
    function _cut(Cfg memory c, uint256 gross, bool charge) private pure returns (uint256) {
        return charge ? FullMath.mulDiv(gross, c.p.deleverageProtocolBps, 10000) : 0;
    }

    /// @dev What `gross` of proceeds melts, net of the cut it would pay.
    function _net(Cfg memory c, uint256 gross, bool charge) private pure returns (uint256) {
        return gross - _cut(c, gross, charge);
    }

    /// @dev The close: sells `uClose`, the exact inverse of `_owed`'s ceil, the smallest sale whose bill covers the whole debt.
    /// @dev `ps * (10000 - eps)` cannot wrap: the restore sold a unit, so `ps < (trig + 1) * 1e4`, and `trig <= 20 * 2^224` on a uint128 debt.
    /// @dev `uClose <= C`: the strict stop gate and the `stop below sellmax onset` rail give `C ps (1-eps) / S > D`; the debit stays CHECKED.
    /// @dev The fill must be EXACT, or a live loan would be left under the reserve: a short fill, a wholly refused one included, reverts.
    /// @dev The books run in `repay`'s order: the escrow split over the live claim, the melt, the clean close, then the overshoot.
    /// @dev No cut is taken, and the title is untouched, as after a repay.
    function _closeSale(LoanBook storage B, Market storage M, Cfg memory c, uint256 id, uint256 ps, bytes calldata data)
        private
        returns (uint256 units, uint256 out, uint256 debt)
    {
        Loan storage L = B.loans[id];
        debt = L.debt;
        units = FullMath.mulDiv(debt - 1, 10000 * c.unitScale, ps * (10000 - c.p.deleverageFloorEpsBps)) + 1;
        L.collateralUnits -= units;
        uint256 filled;
        (filled, out) = _dispose(B, c, Disposal({id: id, unitsSold: units, floorPrice: ps}), data);
        if (filled != units) revert CloseUnfilled();
        L.debt -= debt;
        LoanAccounting.earnFeeEscrowProRata(B, M, id); // BEFORE the melt: it credits over the claim the melt retires
        LoanAccounting.meltLoan(M, id, debt);
        emit Recash(id, debt, address(this));
        Settlement.closeClean(B, M, c, id);
        LoanAccounting.creditQuote(B, M, id, L.borrower, out - debt); // the ceil's overshoot, under one unit's price plus an atom
    }

    /// @dev The decline channel's waterfall: a protocol cut off the top, then every remaining unit melts debt and the claim alike.
    /// @dev The cut is taken only when the cut-charging restore fit (`charge`); a re-sized crank melts in full.
    /// @dev A PARTIAL FILL keeps `charge` and pays the cut on what filled; the sizing priced the cut in, so it is borrower-borne, never lender-borne.
    /// @dev The cut floors PER CRANK, and a keeper sizes each crank by its refund: a sale split over N cranks forgoes under N quote atoms of cut.
    /// @dev A partial fill can lift the loan out of band short of target; a repay of that melt, permissionless above the floor, lifts it further.
    /// @dev The close decision bounds every restore fill's net melt by `debt - floor`, so a melt never closes the loan; the subtraction stays CHECKED.
    /// @dev A partial restore fill melts monotonically less than the full fill the decision judged, so it never lands in dust.
    function _meltAll(LoanBook storage B, Market storage M, Cfg memory c, uint256 id, uint256 stableOut, bool charge) private returns (uint256 net) {
        if (stableOut == 0) return 0; // a wholly refused fill is an exact no-op
        uint256 cut = _cut(c, stableOut, charge);
        if (cut > 0) LoanAccounting.accrueProtocolFee(M, cut);
        net = stableOut - cut;
        B.loans[id].debt -= net;
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
