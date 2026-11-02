// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.36;

import {Math} from "@openzeppelin/contracts/utils/math/Math.sol";
import {BorrowRequest, Terms} from "./AceVaultFlows.sol";
import {AceVault, VaultConfig} from "./AceVault.sol";
import {PriceGrid} from "./PriceGrid.sol";
import {Constants} from "../ace/hub/Constants.sol";
import {LoanMath} from "../ace/hub/libraries/LoanMath.sol";
import {MarketParams} from "../ace/hub/Types.sol";
import {IAceLenderOps} from "../interfaces/IAceLenderOps.sol";
import {IPersistenceRecord} from "../interfaces/IPersistenceRecord.sol";
import {Extension} from "../interfaces/IRollPolicy.sol";
import {IPriceFrame} from "../interfaces/IPriceFrame.sol";

/// @notice One collateral's lending terms: its price source and buffer, its rate and terms, and its exposure cap.
/// @dev Any `IPersistenceRecord` may price a row; a record minimum under the price blocks an extension.
struct Row {
    address record; // the windowed minimum the door prices off; zero is no row
    uint16 bufferBps; // how far under that minimum the door lends
    uint16 baseBps; // the lender's rate per `minTenor`
    uint64 minTenor;
    uint64 maxTenor;
    uint192 cap; // the most exposure the vault takes on this collateral; zero is removal
}

/// @notice A collateral listed at deploy, live from the first block.
struct Listing {
    address collateral;
    Row row;
}

/// @notice A row waiting out the timelock, in MetaMorpho's `{value, validAt}` shape.
struct PendingRow {
    Row value;
    uint64 validAt;
}

/// @notice A cap raise waiting out the timelock, in MetaMorpho's `{value, validAt}` shape.
struct PendingCap {
    uint192 value;
    uint64 validAt;
}

/// @title CuratorVault
/// @notice The oracle-priced vault a curator deploys: one row per collateral, and the door lends at the row's record less its buffer.
/// @notice THE PRICE is the record's windowed minimum less the row's buffer, rounded down onto a 50-tick grid, so nearby borrows share a market.
/// @notice EVERY MARKET names nobody as borrower, sells settled pots at the hub's ask, pays no fill fee and no settle bounty, and runs no deleverage band.
/// @notice A NEW ROW OR A CAP RAISE waits the timelock and anyone accepts it after; a cap cut lands at once, by the curator or the guardian.
/// @notice THE CAP IS A BRAKE, not a bound, never a utilization cap: exposure is lent plus unsold units at the minimum, and only new lending reads it.
/// @notice AN EXTENSION lands while the record admits the market's price, the row still names its record, terms and a cap, and idle covers exits.
/// @dev `MIN_PRINCIPAL` and `COVERAGE_WAD` are every market's, fixed at deploy and checked against the hub's genesis rails.
contract CuratorVault is AceVault {
    error NotListed(); // the collateral has no row, so the door has no price for it
    error BadRow(); // a row naming no record, the vault's own tokens, or terms genesis would refuse
    error BadTerms(); // a minPrincipal or coverage genesis would refuse, so no borrow could ever open
    error TimelockOutOfBounds();
    error NothingDue(); // nothing pending for this collateral has waited out the timelock
    error PriceZero(); // the record answers no price, or the buffered price falls off the grid

    uint64 public constant MIN_TIMELOCK = 1 days;
    uint64 public constant MAX_TIMELOCK = 14 days;
    uint256 internal constant Q96 = 1 << 96;

    uint256 public immutable MIN_PRINCIPAL; // every market's floor ticket
    uint256 public immutable COVERAGE_WAD; // every market's coverage multiple
    uint64 public immutable TIMELOCK; // how long a new row or a cap raise waits

    mapping(address collateral => Row) internal _rows;
    mapping(address collateral => PendingRow) internal _pendingRows;
    mapping(address collateral => PendingCap) internal _pendingCaps;

    /// @notice A row was submitted and goes live at `validAt`.
    event SubmitCollateral(address indexed collateral, Row row, uint64 validAt);
    /// @notice A row went live.
    event SetCollateral(address indexed collateral, Row row);
    /// @notice A cap raise was submitted and goes live at `validAt`.
    event SubmitCap(address indexed collateral, uint256 cap, uint64 validAt);
    /// @notice A cap was set: cut at once, or a raise accepted.
    event SetCap(address indexed by, address indexed collateral, uint256 cap);
    /// @notice Whatever was pending for a collateral was dropped.
    event RevokePending(address indexed by, address indexed collateral);

    /// @param cfg The vault's write-once config.
    /// @param minPrincipal Every market's floor ticket.
    /// @param coverageWad Every market's coverage multiple.
    /// @param timelock How long a new row or a cap raise waits, one to fourteen days.
    /// @param listings The collaterals listed at deploy.
    constructor(
        VaultConfig memory cfg,
        uint256 minPrincipal,
        uint256 coverageWad,
        uint64 timelock,
        Listing[] memory listings,
        string memory name_,
        string memory symbol_
    ) AceVault(cfg, name_, symbol_) {
        if (minPrincipal < 2 || minPrincipal > type(uint128).max || coverageWad < Constants.MIN_COVERAGE_WAD || coverageWad > Constants.MAX_COVERAGE_WAD) {
            revert BadTerms();
        }
        if (timelock < MIN_TIMELOCK || timelock > MAX_TIMELOCK) revert TimelockOutOfBounds();
        (MIN_PRINCIPAL, COVERAGE_WAD, TIMELOCK) = (minPrincipal, coverageWad, timelock);
        for (uint256 i; i < listings.length; i++) {
            Listing memory l = listings[i];
            _checkRow(l.collateral, l.row, minPrincipal);
            _rows[l.collateral] = l.row;
            emit SetCollateral(l.collateral, l.row);
        }
    }

    // ---- the table ----

    /// @notice A collateral's live row; a zero record is no row.
    function rowOf(address collateral) external view returns (Row memory) {
        return _rows[collateral];
    }

    /// @notice A collateral's pending row and when it may be accepted; zero is none.
    function pendingRowOf(address collateral) external view returns (Row memory row, uint64 validAt) {
        PendingRow memory p = _pendingRows[collateral];
        return (p.value, p.validAt);
    }

    /// @notice A collateral's pending cap raise and when it may be accepted; zero is none.
    function pendingCapOf(address collateral) external view returns (uint192 cap, uint64 validAt) {
        PendingCap memory p = _pendingCaps[collateral];
        return (p.value, p.validAt);
    }

    /// @notice Submit a collateral's row, new or changed, to go live after the timelock. CURATOR ONLY.
    /// @notice A record minimum under a market's price blocks its extensions; a new record, rate or tenor stops the old markets' extensions.
    /// @notice It also drops a pending cap raise: the row carries its own cap, and the raise was judged against the row it replaces.
    function submitCollateral(address collateral, Row calldata row) external nonReentrant {
        _onlyCurator();
        _checkRow(collateral, row, MIN_PRINCIPAL);
        if (_pendingCaps[collateral].validAt != 0) _revokePending(collateral);
        uint64 validAt = uint64(block.timestamp) + TIMELOCK;
        _pendingRows[collateral] = PendingRow(row, validAt);
        emit SubmitCollateral(collateral, row, validAt);
    }

    /// @notice Set a listed collateral's cap: a cut lands at once, by the curator or the guardian; a raise waits the timelock, the curator's alone.
    /// @notice A cut also drops whatever is pending for the collateral, so no earlier submission can lift it back.
    function submitCap(address collateral, uint192 cap) external nonReentrant {
        Row storage w = _rows[collateral];
        if (w.record == address(0)) revert NotListed();
        if (cap < w.cap) {
            if (msg.sender != CURATOR && msg.sender != GUARDIAN) revert NotCurator();
            w.cap = cap;
            if (_pendingRows[collateral].validAt != 0 || _pendingCaps[collateral].validAt != 0) _revokePending(collateral);
            emit SetCap(msg.sender, collateral, cap);
            return;
        }
        _onlyCurator();
        uint64 validAt = uint64(block.timestamp) + TIMELOCK;
        _pendingCaps[collateral] = PendingCap(cap, validAt);
        emit SubmitCap(collateral, cap, validAt);
    }

    /// @notice Make live whatever is pending for a collateral and has waited out the timelock. PERMISSIONLESS.
    function accept(address collateral) external nonReentrant {
        bool done;
        PendingRow memory p = _pendingRows[collateral];
        if (p.validAt != 0 && block.timestamp >= p.validAt) {
            _rows[collateral] = p.value;
            delete _pendingRows[collateral];
            emit SetCollateral(collateral, p.value);
            done = true;
        }
        PendingCap memory q = _pendingCaps[collateral];
        if (q.validAt != 0 && block.timestamp >= q.validAt) {
            _rows[collateral].cap = q.value;
            delete _pendingCaps[collateral];
            emit SetCap(msg.sender, collateral, q.value);
            done = true;
        }
        if (!done) revert NothingDue();
    }

    /// @notice Drop whatever is pending for a collateral. The curator or the guardian.
    function revokePending(address collateral) external nonReentrant {
        if (msg.sender != CURATOR && msg.sender != GUARDIAN) revert NotCurator();
        _revokePending(collateral);
    }

    /// @dev Drop the pending row and raise, and say so: every path that drops one emits it, so an indexer replaying events ends right.
    function _revokePending(address collateral) internal {
        delete _pendingRows[collateral];
        delete _pendingCaps[collateral];
        emit RevokePending(msg.sender, collateral);
    }

    /// @dev A row prices the pair off a record that affirms it, never lists this vault's own tokens, and carries terms genesis admits at the floor ticket.
    function _checkRow(address collateral, Row memory row, uint256 minPrincipal) internal view {
        if (row.record == address(0) || collateral == address(0) || collateral == asset() || collateral == address(this)) revert BadRow();
        if (!IPriceFrame(row.record).supportsPair(asset(), collateral)) revert BadRow();
        if (row.bufferBps >= 10_000 || row.baseBps < Constants.MIN_BASE_BPS) revert BadRow();
        if (row.minTenor < Constants.MIN_TENOR_FLOOR || row.maxTenor < row.minTenor || row.maxTenor > type(uint40).max) revert BadRow();
        if (!LoanMath.feeFundable(row.baseBps, row.maxTenor, row.minTenor)) revert BadRow();
        if (LoanMath.originationFee(minPrincipal, row.maxTenor, row.baseBps, row.minTenor) >= minPrincipal) revert BadRow();
    }

    // ---- the hooks ----

    /// @dev The row's market at the gridded buffered minimum, and the asked draw; the tenor defaults to the row's shortest.
    function _borrowTerms(BorrowRequest calldata r, bytes calldata) internal view override returns (MarketParams memory mp, Terms memory t) {
        Row memory w = _rows[r.collateral];
        if (w.record == address(0)) revert NotListed();
        uint256 m = IPersistenceRecord(w.record).minPrice(asset(), r.collateral);
        uint256 price = PriceGrid.down(Math.mulDiv(m, 10_000 - w.bufferBps, 10_000));
        if (price == 0) revert PriceZero();
        mp.quote = asset();
        mp.collateral = r.collateral;
        mp.record = w.record;
        mp.price = price;
        mp.minCoverageWad = COVERAGE_WAD;
        mp.baseBps = w.baseBps;
        mp.minTenor = w.minTenor;
        mp.maxTenor = w.maxTenor;
        mp.minPrincipal = MIN_PRINCIPAL;
        mp.lender = address(this);
        mp.inventoryAsk = true;
        t = Terms(r.units, r.principal, r.tenor == 0 ? w.minTenor : r.tenor, r.minBufferWad);
    }

    /// @dev An extension's price leg: the record's windowed minimum at or over the market's price, so one high print cannot win it.
    function _priceAdmits(Extension calldata e, bytes calldata) internal view override returns (bool) {
        return IPersistenceRecord(e.dst.record).minPrice(e.dst.quote, e.dst.collateral) >= e.dst.price;
    }

    /// @dev An extension's curator legs: the row still names the market's record, a cap, and the market's rate and tenors.
    /// @dev A buffer edit keeps an old market extending: the price leg still judges it, by the record against the market's price.
    function _legsAdmit(Extension calldata e) internal view override returns (bool) {
        Row storage w = _rows[e.dst.collateral];
        return w.cap != 0 && w.record == e.dst.record && w.baseBps == e.dst.baseBps && w.minTenor == e.dst.minTenor && w.maxTenor == e.dst.maxTenor;
    }

    /// @dev The cap less exposure: the hub's lent against the collateral plus its unsold pot units at the market record's minimum.
    function _room(MarketParams memory mp) internal view override returns (uint256) {
        (uint256 lent, uint256 unsold) = IAceLenderOps(ACE).lenderByCollateral(address(this), asset(), mp.collateral);
        uint256 parked = unsold == 0 ? 0 : Math.mulDiv(unsold, IPersistenceRecord(mp.record).minPrice(asset(), mp.collateral), Q96);
        return Math.saturatingSub(_rows[mp.collateral].cap, lent + parked);
    }
}
