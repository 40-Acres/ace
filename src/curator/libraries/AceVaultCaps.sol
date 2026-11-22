// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.36;

import {Math} from "@openzeppelin/contracts/utils/math/Math.sol";
import {MarketParams} from "../../ace/hub/Types.sol";
import {IAceLenderOps} from "../../interfaces/IAceLenderOps.sol";
import {AceVaultFlows, BorrowRequest, Cap, PendingCap, Terms, VaultLayout} from "./AceVaultFlows.sol";
import {AceVaultTail} from "./AceVaultTail.sol";

/// @notice What a vault's product is and how it lends, fixed at deploy: EVERY FIELD IS WRITE-ONCE.
struct ProductConfig {
    address terms; // the product's terms contract, asked for every market, draw, extension, room and entry cap
    address door; // the contract seized goods are handed to, which returns their cash; zero names none, and one set must name the vault, never in kind
    bool inKind; // seized goods are paid out in kind to the shares that carried the loss, never sold
    bool drainable; // whether the drain can ever be switched on
    uint64 capTimelock; // how long a cap raise waits, one to fourteen days
    uint64 minTenor; // the shortest term any loan of this vault runs, and the floor on every market's
    uint64 maxTenor; // the longest term any loan of this vault runs, and the ceiling on every market's; at most thirty days in kind
}

/// @notice One cap set at deploy, live from the first block: a collateral listed at its row, `address(0)` the wildcard, the vault the total.
struct CapListing {
    address key;
    uint192 cap;
}

/// @title AceVaultCaps
/// @notice The vault's caps and the checks it runs on a product's answer before anything is pulled.
/// @notice THREE KINDS OF KEY: a collateral's own row, `address(0)` for any collateral without one, and the vault's own address for the total.
/// @notice A collateral's EFFECTIVE cap is its row while listed, else the wildcard's; every change is judged against it.
/// @notice A cut, or a listing at or under the effective cap, lands at once by the curator or the guardian, and drops what was pending on that key.
/// @notice A raise, a listing above it, or a delisting under a higher wildcard waits the timelock, by the curator alone; anyone accepts it after.
/// @notice A ROW bounds what is lent against its collateral now; THE TOTAL bounds what is lent plus the drawdown, so a default frees nothing under it.
/// @notice IN KIND the wildcard stays zero and the asset is no key, so every collateral that lends is one the curator listed.
/// @dev DELEGATECALL-linked: each runs in the vault's context, so `address(this)` is the vault and `msg.sender` its caller.
/// @dev The four cap verbs are the vault's own, its calldata forwarded unchanged; each reads the vault's figures from the suffix the vault appends.
library AceVaultCaps {
    uint64 internal constant MIN_TENOR_RAIL = 1 days; // the shortest rail floor a vault, or the terms it names, may take
    uint64 internal constant MAX_TENOR_RAIL = 365 days; // the longest rail ceiling, an LP's worst wait for a fully lent vault to drain

    error NotCurator();
    error WildcardInKind(); // in kind the wildcard stays zero, so every collateral that lends is one the curator listed
    error NotListed(); // only a listed collateral has a row to delist
    error NothingDue(); // nothing pending for this key has waited out the timelock
    error OverTotal(); // the placement passes the vault-wide total, counted with the drawdown
    error CollateralNotAsked(); // the market's collateral is not the one the borrower asked for
    error OverAsk(); // the draw takes more principal or pledges more units than the borrower asked
    error TenorNotAsked(); // the draw's term is not the one the borrower asked for
    error TenorOutOfRail(); // the market's tenors or the drawn term sit outside the vault's rail
    error WrongInventoryMode(); // the market's inventory ask does not match how this vault recovers seized goods

    /// @notice A cap change waits the timelock until `validAt`.
    event SubmitCap(address indexed key, uint256 cap, bool listed, uint64 validAt);
    /// @notice A cap took effect: at deploy, at once, or accepted after its timelock.
    event SetCap(address indexed by, address indexed key, uint256 cap, bool listed);
    /// @notice A pending cap change was dropped, by a revoke or by a cut on its key.
    event RevokePendingCap(address indexed by, address indexed key);

    /// @notice Book the deploy's caps, each live at once: a collateral's row listed, the wildcard and the total at their figures.
    /// @notice In kind a nonzero wildcard or the asset as a key refuses.
    function init(CapListing[] calldata caps, bool inKind, address asset) external {
        VaultLayout storage $ = AceVaultFlows.vaultLayout();
        for (uint256 i; i < caps.length; i++) {
            (address key, uint192 cap) = (caps[i].key, caps[i].cap);
            if (inKind) _checkInKind(key, cap, asset);
            $.caps[key] = Cap(cap, true);
            emit SetCap(msg.sender, key, cap, true);
        }
    }

    /// @notice Set `key`'s cap and list it: at or under its effective cap it lands at once, by the curator or the guardian; over it, it waits.
    /// @notice In kind a nonzero wildcard or the asset as a key refuses.
    function submitCap(address key, uint192 cap) external {
        VaultLayout storage $ = AceVaultFlows.vaultLayout();
        if (AceVaultTail.inKind()) _checkInKind(key, cap, AceVaultTail.asset());
        _change($, key, Cap(cap, true), cap <= effective($, key));
    }

    /// @notice Delist `collateral`, so the wildcard's cap applies: at once unless the wildcard is above its row, else after the timelock.
    function submitDelist(address collateral) external {
        VaultLayout storage $ = AceVaultFlows.vaultLayout();
        Cap memory row = $.caps[collateral];
        if (!row.listed || _special(collateral)) revert NotListed();
        _change($, collateral, Cap(0, false), $.caps[address(0)].cap <= row.cap);
    }

    /// @notice Make `key`'s pending change live once it has waited out the timelock. PERMISSIONLESS.
    function acceptCap(address key) external {
        VaultLayout storage $ = AceVaultFlows.vaultLayout();
        PendingCap memory pending = $.pendingCaps[key];
        if (pending.validAt == 0 || block.timestamp < pending.validAt) revert NothingDue();
        delete $.pendingCaps[key];
        $.caps[key] = pending.value;
        emit SetCap(msg.sender, key, pending.value.cap, pending.value.listed);
    }

    /// @notice Drop `key`'s pending change. The curator or the guardian.
    function revokePendingCap(address key) external {
        if (msg.sender != AceVaultTail.curator() && msg.sender != AceVaultTail.guardian()) revert NotCurator();
        delete AceVaultFlows.vaultLayout().pendingCaps[key];
        emit RevokePendingCap(msg.sender, key);
    }

    /// @notice The room a new placement against `collateral` has under its row and under the total, when the hub holds `held` with `drawdown` standing.
    /// @dev The row counts the hub's lent against `collateral` and the value its goods at a door still hold; the total counts all lent plus the drawdown.
    /// @dev Nothing rests between calls, so what the hub holds less what it owes the vault is what is lent.
    /// @return row The row's room.
    /// @return total The total's room.
    function room(address ace, address asset, address collateral, uint256 held, uint256 drawdown) external view returns (uint256 row, uint256 total) {
        VaultLayout storage $ = AceVaultFlows.vaultLayout();
        IAceLenderOps hub = IAceLenderOps(ace);
        (uint256 lent,) = hub.lenderByCollateral(address(this), asset, collateral);
        row = rowRoom(effective($, collateral), lent, $.seized[collateral].value);
        total = totalRoom($.caps[address(this)].cap, held, hub.lenderOwed(address(this), asset), drawdown);
    }

    /// @notice A row's room: `effectiveCap` less what is lent against it, less what its goods at a door still hold; zero, never below.
    function rowRoom(uint256 effectiveCap, uint256 lent, uint256 seized) internal pure returns (uint256) {
        return Math.saturatingSub(Math.saturatingSub(effectiveCap, lent), seized);
    }

    /// @notice The total's room: its cap less what is lent, the hub's `held` less what it `owed`, and the `drawdown`; zero, never below.
    function totalRoom(uint256 cap, uint256 held, uint256 owed, uint256 drawdown) internal pure returns (uint256) {
        return Math.saturatingSub(cap, held - owed + drawdown);
    }

    /// @notice Whether a vault recovers seized goods through the hub's inventory ask: neither in kind nor in door mode.
    /// @dev The one spelling `borrow`'s check and the lens's preview both take.
    function hubAsk(bool inKind, address door) internal pure returns (bool) {
        return !inKind && door == address(0);
    }

    /// @notice The base's checks on a product's borrow answer, before anything moves: the mode, the binding to the ask, the tenor rail.
    /// @dev The market takes the collateral asked; the draw takes no more principal or units than asked, and the term asked whenever one is.
    /// @dev The market's tenors and the drawn term, zero meaning the market's shortest, sit inside `[minTenor, maxTenor]`.
    /// @return The draw to place, its buffer the larger of the ask's and the product's.
    function admit(BorrowRequest calldata request, MarketParams calldata mp, Terms calldata draw, bool hubAsk, uint64 minTenor, uint64 maxTenor)
        external
        pure
        returns (Terms memory)
    {
        if (mp.inventoryAsk != hubAsk) revert WrongInventoryMode();
        if (mp.collateral != request.collateral) revert CollateralNotAsked();
        if (draw.principal > request.principal || draw.units > request.units) revert OverAsk();
        if (request.tenor != 0 && draw.tenor != request.tenor) revert TenorNotAsked();
        uint64 drawn = draw.tenor == 0 ? mp.minTenor : draw.tenor;
        if (mp.minTenor < minTenor || mp.maxTenor > maxTenor || drawn < minTenor || drawn > maxTenor) revert TenorOutOfRail();
        return Terms(draw.units, draw.principal, draw.tenor, Math.max(request.minBufferWad, draw.minBufferWad));
    }

    /// @notice `key`'s effective cap: the wildcard and the total are their own; a collateral's is its row while listed, else the wildcard's.
    function effective(VaultLayout storage $, address key) internal view returns (uint256) {
        Cap memory entry = $.caps[key];
        return (entry.listed || _special(key)) ? entry.cap : $.caps[address(0)].cap;
    }

    /// @dev Land `next` on `key` at once when `lands`, by the curator or the guardian, dropping any pending change; else queue it, curator only.
    /// @dev A forwarded verb's helper: the keys and the timelock are the vault's, from the suffix it appended.
    function _change(VaultLayout storage $, address key, Cap memory next, bool lands) private {
        address curator = AceVaultTail.curator();
        if (lands) {
            if (msg.sender != curator && msg.sender != AceVaultTail.guardian()) revert NotCurator();
            $.caps[key] = next;
            if ($.pendingCaps[key].validAt != 0) {
                delete $.pendingCaps[key];
                emit RevokePendingCap(msg.sender, key);
            }
            emit SetCap(msg.sender, key, next.cap, next.listed);
            return;
        }
        if (msg.sender != curator) revert NotCurator();
        uint64 validAt = uint64(block.timestamp) + AceVaultTail.capTimelock();
        $.pendingCaps[key] = PendingCap(next, validAt);
        emit SubmitCap(key, next.cap, next.listed, validAt);
    }

    /// @dev The wildcard and the total, which are their own effective caps and never delist.
    function _special(address key) private view returns (bool) {
        return key == address(0) || key == address(this);
    }

    /// @dev In kind the asset is no key, and the wildcard takes no cap but zero.
    function _checkInKind(address key, uint192 cap, address asset) private pure {
        if (key == asset) revert AceVaultFlows.CashIsNotCollateral();
        if (key == address(0) && cap != 0) revert WildcardInKind();
    }
}
