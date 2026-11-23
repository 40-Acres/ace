// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.36;

import {Math} from "@openzeppelin/contracts/utils/math/Math.sol";
import {SafeCast} from "@openzeppelin/contracts/utils/math/SafeCast.sol";
import {TransientSlot} from "@openzeppelin/contracts/utils/TransientSlot.sol";
import {IAceLenderOps} from "../../interfaces/IAceLenderOps.sol";
import {AceVaultFlows, VaultLayout} from "./AceVaultFlows.sol";

/// @title AceVaultNav
/// @notice How an AceVault values itself: the deferred gain, the sync that books gross NAV against it, the trough hold, and the fee they price.
/// @notice Every write to the NAV mark, its high, the fee high-water and the vest is here; the hold is written here and by the guardian's exemption.
/// @dev Internal: it compiles into the vault and runs on its storage, so it holds no figures of its own and takes the vault's as arguments.
/// @dev The gates' arithmetic at the bottom reads no storage, so `AceVaultLens` runs this same code to say why entry is shut.
library AceVaultNav {
    uint16 internal constant GATE_BPS = 500; // entry shuts while a gain over this share of NAV vests
    uint16 internal constant HOLD_BPS = 1; // a loss or deferred gain is material past this share of the mark and MIN_SEED atoms
    uint48 internal constant TROUGH_MARKED = type(uint48).max; // the hold's mark: a material loss (fall, booking or drawdown) seen over an unsold pot

    // ---- the deferred gain: one weighted accumulator, a basis and a maturity, read decayed to now ----

    /// @dev The deferred gain now: the stored vest read at this instant over `window`.
    function unvested(uint64 window) internal view returns (uint256) {
        VaultLayout storage $ = AceVaultFlows.vaultLayout();
        return readVest($.vestBasis, $.vestMaturity, window);
    }

    /// @dev What a (basis, maturity) pair reads as now, CEIL, which favours stayers on an exit and the entrant on an entry; zero once matured or burnt out.
    function readVest(uint128 basis, uint64 maturity, uint64 window) internal view returns (uint256) {
        if (basis == 0 || maturity <= block.timestamp) return 0;
        return Math.mulDiv(basis, maturity - block.timestamp, window, Math.Rounding.Ceil);
    }

    /// @dev The vest a `rise` onto `deferred` stamps: a size-blended maturity and a FLOORED basis reading back exactly the sum; saturates, never reverts.
    function grossed(uint256 deferred, uint256 rise, uint64 window) internal view returns (uint128 basis, uint64 maturity) {
        maturity = blended(deferred, rise, AceVaultFlows.vaultLayout().vestMaturity, window);
        basis = uint128(Math.min(Math.mulDiv(deferred + rise, window, maturity - block.timestamp), type(uint128).max));
    }

    /// @dev The basis left after a `fall` against `deferred`; FLOOR, retiring the fall's share of the basis.
    function scaled(uint256 deferred, uint256 fall) internal view returns (uint128) {
        if (fall >= deferred) return 0;
        return SafeCast.toUint128(Math.mulDiv(AceVaultFlows.vaultLayout().vestBasis, deferred - fall, deferred, Math.Rounding.Floor));
    }

    /// @dev Fold an observed NAV rise into the vest.
    function stampVest(uint256 amount, uint64 window) internal {
        if (amount == 0) return;
        VaultLayout storage $ = AceVaultFlows.vaultLayout();
        ($.vestBasis, $.vestMaturity) = grossed(unvested(window), amount, window);
    }

    /// @dev A NAV fall retires the vest pro rata: a gain already wiped out cannot still be pending.
    function burnVest(uint256 amount, uint64 window) internal {
        uint256 deferred = unvested(window);
        if (deferred == 0 || amount == 0) return;
        AceVaultFlows.vaultLayout().vestBasis = scaled(deferred, amount);
    }

    /// @dev The deferred gain a sync at `gross` would leave, through the sync's own helpers, so a view and the verb after it never round apart.
    function deferredAt(uint256 gross, uint64 window) internal view returns (uint256) {
        uint256 deferred = unvested(window);
        VaultLayout storage $ = AceVaultFlows.vaultLayout();
        uint256 mark = $.navMark;
        if (gross > mark) {
            (uint128 basis, uint64 maturity) = grossed(deferred, gross - mark, window);
            return readVest(basis, maturity, window);
        }
        if (gross < mark && deferred != 0) return readVest(scaled(deferred, mark - gross), $.vestMaturity, window);
        return deferred;
    }

    /// @dev NAV at `gross`: gross less the deferred gain a sync there would leave.
    function navAt(uint256 gross, uint64 window) internal view returns (uint256) {
        return Math.saturatingSub(gross, deferredAt(gross, window));
    }

    /// @dev The last requester's release: the deferred gain vests whole, and the mark takes `gross`, the sync's own read, which nothing since has moved.
    function release(uint256 gross) internal {
        VaultLayout storage $ = AceVaultFlows.vaultLayout();
        ($.vestBasis, $.navMark) = (0, gross);
    }

    // ---- the sync ----

    /// @dev Book `gross` against the mark: a rise is stamped into the vest, a fall burns it pro rata, a new high lifts `navHigh`, and the mark takes it.
    /// @dev Outside in kind it then marks or clears the trough hold.
    /// @return rise The rise the vest took in, zero on a fall or no move.
    function sync(uint256 gross, uint64 window, bool inKind, address ace, address asset) internal returns (uint256 rise) {
        VaultLayout storage $ = AceVaultFlows.vaultLayout();
        uint256 mark = $.navMark;
        if (gross > mark) {
            rise = gross - mark;
            stampVest(rise, window);
        } else if (gross < mark) {
            burnVest(mark - gross, window);
        }
        $.navMark = gross;
        if (gross > $.navHigh) $.navHigh = gross;
        if (!inKind) markTrough(mark, gross, window, ace, asset);
    }

    // ---- entries and exits: cash in or out moves the mark and the high with it, so it reads as neither growth nor loss ----

    /// @dev Book an entry of `assets` for `shares`, `virtualSupply` counting them: the mark and `navHigh` rise by it, the fee high-water carried per share.
    function bookEntry(uint256 assets, uint256 shares, uint256 virtualSupply, bool feeOn) internal {
        VaultLayout storage $ = AceVaultFlows.vaultLayout();
        if (feeOn) {
            uint256 highWater = $.feeHighWater;
            $.feeHighWater = Math.max(highWater + assets, Math.mulDiv(highWater, virtualSupply, virtualSupply - shares, Math.Rounding.Ceil));
        }
        $.navMark += assets;
        $.navHigh += assets;
    }

    /// @dev Book an exit of `assets` for `shares` at `nav`, `virtualSupply` net of them: the fee high-water scales per share, never under `nav - assets`.
    /// @dev The mark falls with the cash, so the next sync reads no fall, and `navHigh` with it, so the drawdown stays where it was.
    function bookExit(uint256 assets, uint256 shares, uint256 nav, uint256 virtualSupply, bool feeOn) internal {
        VaultLayout storage $ = AceVaultFlows.vaultLayout();
        if (feeOn) $.feeHighWater = Math.max(Math.mulDiv($.feeHighWater, virtualSupply, virtualSupply + shares), Math.saturatingSub(nav, assets));
        $.navMark = Math.saturatingSub($.navMark, assets);
        $.navHigh = Math.saturatingSub($.navHigh, assets);
    }

    // ---- the performance fee ----

    /// @dev The fee shares a collection at `nav` mints: `feeBps` of the rise past the high-water, priced net of the fee; none with no live supply.
    function feeShares(uint256 nav, uint16 feeBps, uint256 supply, bool live) internal view returns (uint256) {
        uint256 highWater = AceVaultFlows.vaultLayout().feeHighWater;
        if (!live || nav <= highWater) return 0;
        uint256 fee = Math.mulDiv(nav - highWater, feeBps, 10_000); // at most half of NAV, so `nav - fee` never reaches zero
        return Math.mulDiv(fee, supply, nav - fee);
    }

    /// @dev After a collection at `nav`, lift the fee high-water to `nav` if it passes; with no live supply it re-stamps at `nav` either way.
    function liftHighWater(uint256 nav, bool live) internal {
        VaultLayout storage $ = AceVaultFlows.vaultLayout();
        uint256 highWater = $.feeHighWater;
        if (live ? nav > highWater : nav != highWater) $.feeHighWater = nav;
    }

    // ---- the trough hold: entry stays shut after a material loss over an unsold pot, until the recovery after it vests ----

    /// @dev The sync's leg: a material loss from `mark` to `gross` over an unsold pot marks the hold.
    /// @dev The next sync with none unsold stores the vest maturity while the deferred gain is material, else 0.
    function markTrough(uint256 mark, uint256 gross, uint64 window, address ace, address asset) private {
        VaultLayout storage $ = AceVaultFlows.vaultLayout();
        bool marked = $.troughHold == TROUGH_MARKED;
        if (!marked && !lossMarks(mark, gross)) return;
        bool unsoldNow = potsUnsold(ace, asset);
        if (marked == unsoldNow) return; // marked over a pot still unsold, or a loss with none unsold: nothing moves
        $.troughHold = unsoldNow ? TROUGH_MARKED : material(unvested(window), gross) ? uint48($.vestMaturity) : 0; // a maturity is at most a week out
    }

    /// @dev Whether a sync from `mark` to `gross` marks the hold: its loss is material against the mark. The guardian's exemption marks by this too.
    function lossMarks(uint256 mark, uint256 gross) internal view returns (bool) {
        return material(loss(mark, gross), mark);
    }

    /// @dev The loss a sync from `mark` to `gross` weighs: the fall or the booked value a door collect left in `BOOKED`, and with either the drawdown.
    function loss(uint256 mark, uint256 gross) private view returns (uint256 amount) {
        amount = Math.max(Math.saturatingSub(mark, gross), TransientSlot.tload(TransientSlot.asUint256(AceVaultFlows.BOOKED)));
        if (amount != 0) amount = Math.max(amount, drawdown(gross));
    }

    /// @dev The drawdown at `gross`, gross NAV's fall below its high, as the hold's loss and `borrow`'s total room read it; refinance and the lens restate it.
    function drawdown(uint256 gross) internal view returns (uint256) {
        return Math.saturatingSub(AceVaultFlows.vaultLayout().navHigh, gross);
    }

    /// @dev Whether a hub pot or a door key is unsold with no exemption at the hub's settled count; in kind's open batch is the vault's to add.
    function potsUnsold(address ace, address asset) internal view returns (bool) {
        (uint256 unsoldPots, uint256 settledPots) = IAceLenderOps(ace).lenderUnresolved(address(this), asset);
        VaultLayout storage $ = AceVaultFlows.vaultLayout();
        return unsold(unsoldPots, $.openSeized, settledPots, $.exemptSettled);
    }

    /// @dev The hold at `gross`: it binds while `deferred` is material and its second has not come; a mark is a second never come.
    function troughHeld(uint256 deferred, uint256 gross) internal view returns (bool) {
        return material(deferred, gross) && block.timestamp < AceVaultFlows.vaultLayout().troughHold;
    }

    /// @dev Whether the stored hold alone shuts entry, from storage and blind to a hub pot.
    /// @dev It shuts while its second is to come, the deferred gain is material, no open key stands unexempted and the gain gate is open.
    function shutByHoldAlone(uint64 window, uint256 floor) internal view returns (bool) {
        VaultLayout storage $ = AceVaultFlows.vaultLayout();
        uint48 holdUntil = $.troughHold;
        if (holdUntil == 0 || holdUntil == TROUGH_MARKED || block.timestamp >= holdUntil || ($.openSeized != 0 && $.exemptSettled == 0)) return false;
        (uint256 deferred, uint256 mark) = (unvested(window), $.navMark);
        return material(deferred, mark) && !gainVesting(deferred, Math.saturatingSub(mark, deferred), floor);
    }

    // ---- the gates' arithmetic: no storage read, and the lens's as much as the vault's ----

    /// @dev Whether `amount` is material to the trough hold against `ref`: over `MIN_SEED` atoms and over `HOLD_BPS` of `ref`, compared without a product.
    function material(uint256 amount, uint256 ref) internal pure returns (bool) {
        return amount > AceVaultFlows.MIN_SEED && amount > Math.mulDiv(ref, HOLD_BPS, 10_000);
    }

    /// @dev Whether a deferred gain `deferred` is still vesting against `nav`: over `floor` and over `GATE_BPS` of `nav`.
    function gainVesting(uint256 deferred, uint256 nav, uint256 floor) internal pure returns (bool) {
        return deferred > floor && deferred * 10_000 > nav * GATE_BPS;
    }

    /// @dev Whether entry waits on a pot: one unsold at the hub or a door key open, and no exemption at the hub's count `settledPots`.
    function unsold(uint256 hubUnsold, uint256 openKeys, uint256 settledPots, uint256 exempt) internal pure returns (bool) {
        return (hubUnsold != 0 || openKeys != 0) && settledPots != exempt;
    }

    /// @dev The maturity a `rise` stamped now onto `deferred` maturing at `maturity` leaves, over a `window` in seconds.
    function blended(uint256 deferred, uint256 rise, uint256 maturity, uint256 window) internal view returns (uint64) {
        uint256 end = block.timestamp + window;
        return uint64((deferred == 0 || maturity <= block.timestamp) ? end : maturity + Math.mulDiv(end - maturity, rise, deferred + rise));
    }
}
