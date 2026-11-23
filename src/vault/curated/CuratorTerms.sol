// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.36;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {ReentrancyGuardTransient} from "@openzeppelin/contracts/utils/ReentrancyGuardTransient.sol";
import {Math} from "@openzeppelin/contracts/utils/math/Math.sol";
import {AceVaultFlows, BorrowRequest, Terms} from "../libraries/AceVaultFlows.sol";
import {AceVault} from "../AceVault.sol";
import {AceVaultCaps} from "../libraries/AceVaultCaps.sol";
import {PriceGrid} from "../libraries/PriceGrid.sol";
import {Constants} from "../../ace/hub/Constants.sol";
import {LoanMath} from "../../ace/hub/libraries/LoanMath.sol";
import {Probe} from "../../ace/hub/libraries/Probe.sol";
import {MarketParams} from "../../ace/hub/Types.sol";
import {HubRatePeriod} from "../../interfaces/HubRatePeriod.sol";
import {IAceLenderOps} from "../../interfaces/IAceLenderOps.sol";
import {IAceVaultDoor} from "../../interfaces/IAceVaultDoor.sol";
import {IDoorSaleCallback} from "../../interfaces/IDoorSaleCallback.sol";
import {IPersistenceRecord} from "../../interfaces/IPersistenceRecord.sol";
import {Extension} from "../../interfaces/IRollPolicy.sol";
import {IPriceFrame} from "../../interfaces/IPriceFrame.sol";
import {IVaultDoor} from "../../interfaces/IVaultDoor.sol";
import {IVaultTerms, Lend, RefinanceRequest} from "../../interfaces/IVaultTerms.sol";

/// @notice One collateral's lending terms: its price source and buffer, its rate and its terms; the vault holds its cap.
/// @dev Any `IPersistenceRecord` may price a row; a record minimum under the price blocks an extension.
struct Row {
    address record; // the windowed minimum a borrow prices off; zero is no row
    uint16 bufferBps; // how far under that minimum the vault lends
    uint16 lenderAprBps; // the lender's rate, bps a year
    uint64 minTenor;
    uint64 maxTenor;
}

/// @notice A collateral listed at deploy, live from the first block.
struct Listing {
    address collateral;
    Row row;
}

/// @notice A row waiting out the timelock: the new row and the time it may be accepted from.
struct PendingRow {
    Row value;
    uint64 validAt;
}

/// @notice Everything a deploy fixes about the terms, named so no two figures transpose.
struct CuratorTermsConfig {
    address vault; // the one AceVault these terms serve, deployed after them at this address
    address ace; // that vault's hub
    address asset; // that vault's asset
    uint256 minPrincipal; // every market's floor ticket
    uint256 coverageWad; // every market's coverage multiple
    uint64 timelock; // how long a new or changed row waits
    uint64 minTenor; // the vault's tenor rail, which every row sits inside
    uint64 maxTenor;
}

/// @title CuratorTerms
/// @notice The oracle-priced terms a curator runs on an AceVault: one row per collateral, and the vault lends at the row's record less its buffer.
/// @notice THE PRICE is the record's windowed minimum less the row's buffer, rounded down onto a 50-tick grid, so nearby borrows share a market.
/// @notice EVERY MARKET names nobody as borrower, pays no fill fee and no settle bounty, and runs no deleverage band.
/// @notice THE MODE IS THE VAULT'S: beside a hub-ask vault its markets sell settled pots at the hub's ask; in kind or as the door they sell none there.
/// @notice A NEW OR CHANGED ROW waits the timelock and anyone accepts it after; caps are the vault's, and its timelock governs them.
/// @notice ITS ROOM only tightens the vault's: a pot unsold at the hub holds its row at the record's minimum until it sells or is collected.
/// @notice AN EXTENSION is consented to while the record admits the market's price and the row still names its record, rate and terms.
/// @notice A REFINANCE keeps the loan's market while the row names it and the buffered minimum covers its price, else today's; a top-up needs the first.
/// @notice AS THE DOOR anyone collects a forfeit here, and the CURATOR sells it at once, to a buyer it names, at any price over the floor.
/// @notice IN KIND there is no door: a collect here forwards to the vault's, which takes the pot home, and a sale or cash return refuses `NotDoor`.
/// @notice THE FLOOR is max(d, min(s, v)): s the units' share of their key's booked value, v their `saleRecord` value, d that less `MAX_SALE_DISCOUNT_BPS`.
/// @notice Goods worth their booked share fetch at least it, others their record value; it binds on an open key, and an accepted write-off lifts it.
/// @notice A DARK RECORD leaves the share alone as the floor, since the share reads no price; distressed goods behind one wait for the write-off.
/// @notice No listing or timelock precedes a sale, and `minOut` is the curator's own bound: a sale under value moves it to the buyer, who may be the curator.
/// @notice A sale's cash vests at the vault, and an exit while goods sit here prices them at zero.
/// @dev A door vault must name a guardian; a lost curator key strands the goods here, with no sale and no write-off, while the exemption still reopens entry.
/// @dev The sale runs under this contract's lock and outside the vault's: a buyer's callback finds the item's key still open, at its booked value.
/// @dev A collect onto a key voids its pending write-off, so new defaults delay that escape; a zero cap stops new loans, not a re-term of a live one.
/// @dev A product whose `borrowTerms` builds a recordless market pins no record, so its goods take the booked share alone, as behind a dark record.
/// @dev `MIN_PRINCIPAL` and `COVERAGE_WAD` are every market's, fixed at deploy and checked against the hub's genesis rails.
/// @dev The hub, the asset and the rail are copies of the vault's, taken before it existed; terms whose copy disagrees lend nothing.
/// @dev A product overrides `borrowTerms`, `refinanceTerms`, `admitsExtension` and `room`, and may call the internal `_names`, `_buffered` and `_market`.
/// @dev A product's gate belongs in `_productBeforeLend`, run on every vault lend after the sealed checks, and `admitsExtension`, on every extension.
/// @dev The two product hooks are `view`, so a product writes no state there; `_productAfterLend` follows the caller check alone; `entryCap` stays sealed.
contract CuratorTerms is IVaultTerms, IVaultDoor, ReentrancyGuardTransient {
    using SafeERC20 for IERC20;

    error NotCurator();
    error NotVault(); // only the vault makes the write calls
    error NotListed(); // the collateral has no row, so a borrow has no price
    error BadRow(); // a row naming no record, the vault's own tokens, terms genesis would refuse, or tenors outside the vault's rail
    error BadTerms(); // a minPrincipal or coverage genesis would refuse, so no borrow could ever open
    error TimelockOutOfBounds();
    error NothingDue(); // nothing pending for this collateral has waited out the timelock
    error PriceZero(); // the record answers no price, or the buffered price falls off the grid
    error TenorRailOutOfBounds(); // the rail sits outside one day to a year, or its ends cross
    error VaultMismatch(); // the vault runs another hub, asset, tenor rail or door than these terms were built for, so no loan opens
    error GuardianUnset(); // a door vault names no guardian, so nothing could exempt goods that never sell
    error NothingToSell(); // no units, or the vault's own cash, which is never inventory
    error SharesAreNotAGood(); // the vault's own share is never inventory
    error BadBuyer(); // the vault, where the goods would strand, or these terms, a sale to itself
    error SaleUnderMin(); // the buyer stated no cash, or less than the curator's minOut, so the goods go back
    error UnderFloor(); // the buyer stated less than the floor while the item's key is open
    error SalePaidShort(); // the cash that arrived fell short of the figure the buyer stated

    uint64 public constant MIN_TIMELOCK = 1 days;
    uint64 public constant MAX_TIMELOCK = 14 days;
    uint256 public constant MAX_SALE_DISCOUNT_BPS = 2000; // the most an open key's sale may take under the record's minimum
    uint256 internal constant Q96 = 1 << 96;
    uint256 private constant SEIZED = 9; // the vault's seized-goods mapping, at its root plus nine

    address public immutable override(IVaultTerms, IVaultDoor) VAULT;
    address public immutable ACE;
    address public immutable ASSET;
    uint256 public immutable MIN_PRINCIPAL; // every market's floor ticket
    uint256 public immutable COVERAGE_WAD; // every market's coverage multiple
    uint64 public immutable TIMELOCK; // how long a new or changed row waits
    uint64 public immutable MIN_TENOR; // the vault's rail floor, under which no row lists
    uint64 public immutable MAX_TENOR; // the vault's rail ceiling, over which no row lists

    mapping(address collateral => Row) internal _rows;
    mapping(address collateral => PendingRow) internal _pendingRows;
    mapping(address collateral => address) public saleRecord; // the record a sale's floor prices off: that of the market the latest pot came from

    /// @notice A row was submitted and goes live at `validAt`.
    event SubmitCollateral(address indexed collateral, Row row, uint64 validAt);
    /// @notice A row went live.
    event SetCollateral(address indexed collateral, Row row);
    /// @notice A pending row was dropped.
    event RevokePending(address indexed by, address indexed collateral);
    /// @notice A seized good was sold for cash; `units` is what was offered up, `paid` what the buyer stated and delivered, now at the vault.
    event Sold(address indexed item, uint256 units, address indexed buyer, uint256 paid);

    /// @param c The terms' write-once config.
    /// @param listings The collaterals listed at deploy.
    constructor(CuratorTermsConfig memory c, Listing[] memory listings) {
        if (
            c.minPrincipal < 2 || c.minPrincipal > type(uint128).max || c.coverageWad < Constants.MIN_COVERAGE_WAD || c.coverageWad > Constants.MAX_COVERAGE_WAD
        ) {
            revert BadTerms();
        }
        if (c.timelock < MIN_TIMELOCK || c.timelock > MAX_TIMELOCK) revert TimelockOutOfBounds();
        if (c.minTenor < AceVaultCaps.MIN_TENOR_RAIL || c.maxTenor > AceVaultCaps.MAX_TENOR_RAIL || c.minTenor > c.maxTenor) revert TenorRailOutOfBounds();
        HubRatePeriod.requirePerYear(c.ace);
        (VAULT, ACE, ASSET) = (c.vault, c.ace, c.asset);
        (MIN_PRINCIPAL, COVERAGE_WAD, TIMELOCK, MIN_TENOR, MAX_TENOR) = (c.minPrincipal, c.coverageWad, c.timelock, c.minTenor, c.maxTenor);
        for (uint256 i; i < listings.length; i++) {
            Listing memory l = listings[i];
            _checkRow(l.collateral, l.row);
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

    /// @notice Submit a collateral's row, new or changed, to go live after the timelock. CURATOR ONLY.
    /// @notice A record minimum under a market's price blocks its extensions; a new record, rate or tenor stops the old markets' extensions.
    function submitCollateral(address collateral, Row calldata row) external {
        if (msg.sender != AceVault(VAULT).CURATOR()) revert NotCurator();
        _checkRow(collateral, row);
        uint64 validAt = uint64(block.timestamp) + TIMELOCK;
        _pendingRows[collateral] = PendingRow(row, validAt);
        emit SubmitCollateral(collateral, row, validAt);
    }

    /// @notice Make live a collateral's pending row once it has waited out the timelock. PERMISSIONLESS.
    /// @notice A pending row never expires: it stays acceptable until accepted, replaced by a new submit, or dropped by `revokePending`.
    function accept(address collateral) external {
        PendingRow memory p = _pendingRows[collateral];
        if (p.validAt == 0 || block.timestamp < p.validAt) revert NothingDue();
        _rows[collateral] = p.value;
        delete _pendingRows[collateral];
        emit SetCollateral(collateral, p.value);
    }

    /// @notice Drop a collateral's pending row. The vault's curator or guardian.
    function revokePending(address collateral) external {
        AceVault v = AceVault(VAULT);
        if (msg.sender != v.CURATOR() && msg.sender != v.GUARDIAN()) revert NotCurator();
        delete _pendingRows[collateral];
        emit RevokePending(msg.sender, collateral);
    }

    /// @dev A row prices the pair off a record that affirms it, never lists the vault's own tokens, carries terms genesis admits, and sits in the rail.
    function _checkRow(address collateral, Row memory row) internal view {
        if (row.record == address(0) || collateral == address(0) || collateral == ASSET || collateral == VAULT) revert BadRow();
        if (!IPriceFrame(row.record).supportsPair(ASSET, collateral)) revert BadRow();
        if (row.bufferBps >= 10_000 || row.lenderAprBps < Constants.MIN_LENDER_APR_BPS) revert BadRow();
        if (row.minTenor < MIN_TENOR || row.maxTenor < row.minTenor || row.maxTenor > MAX_TENOR) revert BadRow();
        if (!LoanMath.feeFundable(row.lenderAprBps, row.maxTenor)) revert BadRow();
        if (LoanMath.originationFee(MIN_PRINCIPAL, row.maxTenor, row.lenderAprBps) >= MIN_PRINCIPAL) revert BadRow();
    }

    // ---- the answers the vault asks ----

    /// @notice The row's market at the gridded buffered minimum, and the asked draw; the tenor defaults to the row's shortest.
    /// @dev The market sells at the hub's ask only in hub-ask mode, by `AceVaultCaps.hubAsk`: the expression the base checks every borrow against.
    function borrowTerms(address, BorrowRequest calldata r, bytes calldata) public view virtual returns (MarketParams memory mp, Terms memory t) {
        Row memory w = _rows[r.collateral];
        mp = _market(w, r.collateral, _buffered(w, r.collateral));
        t = Terms(r.units, r.principal, r.tenor == 0 ? w.minTenor : r.tenor, r.minBufferWad);
    }

    /// @notice A refinance's market: the loan's own while its row still names it and its price is at or under today's buffered minimum, else today's.
    /// @notice The draw is the asked principal, the tenor defaulting to the row's shortest; a vault top-up lands only on the loan's own market.
    function refinanceTerms(address, uint256 loanId, RefinanceRequest calldata r, bytes calldata)
        public
        view
        virtual
        returns (MarketParams memory mp, Terms memory t)
    {
        Row memory w = _rows[r.collateral];
        uint256 buffered = _buffered(w, r.collateral);
        IAceLenderOps hub = IAceLenderOps(ACE);
        mp = hub.idToMarketParams(hub.loanMarket(loanId));
        if (mp.collateral != r.collateral || !_names(w, mp) || buffered < mp.price) mp = _market(w, r.collateral, buffered);
        t = Terms(0, r.principal, r.tenor == 0 ? w.minTenor : r.tenor, r.minBufferWad);
    }

    /// @notice An extension's price and row legs: the record's windowed minimum at or over the market's price, and the row unchanged in record, rate and terms.
    /// @dev A buffer edit keeps an old market extending: the price leg still judges it, by the record against the market's price.
    function admitsExtension(Extension calldata e, bytes calldata) public view virtual returns (bool) {
        if (!_names(_rows[e.dst.collateral], e.dst)) return false;
        return IPersistenceRecord(e.dst.record).minPrice(e.dst.quote, e.dst.collateral) >= e.dst.price;
    }

    /// @dev Whether row `w` still names market `mp`: the same record, rate and both tenors.
    function _names(Row memory w, MarketParams memory mp) internal pure returns (bool) {
        return w.record == mp.record && w.lenderAprBps == mp.lenderAprBps && w.minTenor == mp.minTenor && w.maxTenor == mp.maxTenor;
    }

    /// @dev The row's record minimum for `collateral` less its buffer, unrounded; a collateral with no row refuses `NotListed`.
    function _buffered(Row memory w, address collateral) internal view returns (uint256) {
        if (w.record == address(0)) revert NotListed();
        return Math.mulDiv(IPersistenceRecord(w.record).minPrice(ASSET, collateral), 10_000 - w.bufferBps, 10_000);
    }

    /// @dev Today's market for `collateral` under row `w`, at `buffered` gridded down; a price off the grid refuses `PriceZero`.
    function _market(Row memory w, address collateral, uint256 buffered) internal view returns (MarketParams memory mp) {
        uint256 price = PriceGrid.down(buffered);
        if (price == 0) revert PriceZero();
        mp.quote = ASSET;
        mp.collateral = collateral;
        mp.record = w.record;
        mp.price = price;
        mp.minCoverageWad = COVERAGE_WAD;
        mp.lenderAprBps = w.lenderAprBps;
        mp.minTenor = w.minTenor;
        mp.maxTenor = w.maxTenor;
        mp.minPrincipal = MIN_PRINCIPAL;
        mp.lender = VAULT;
        AceVault v = AceVault(VAULT);
        mp.inventoryAsk = AceVaultCaps.hubAsk(v.IN_KIND(), v.DOOR());
    }

    /// @notice The collateral's room with its unsold hub pot units held at the market record's minimum; uncapped while none is unsold at the hub.
    /// @notice While a pot is unsold, a record that reverts, burns its gas or answers short leaves no room, as does a pot too large to price.
    /// @dev Goods collected to this door leave the hub's count, the vault's row then holding them at their booked value; in kind nothing is booked.
    /// @dev Zero room is the refusal, so a failed `Probe.askWord` folds into it; the 1/64 a burning record leaves is enough to return it.
    function room(MarketParams calldata mp) public view virtual returns (uint256) {
        (uint256 lent, uint256 unsold) = IAceLenderOps(ACE).lenderByCollateral(VAULT, ASSET, mp.collateral);
        if (unsold == 0) return type(uint256).max;
        (bool ok, uint256 m) = Probe.askWord(mp.record, abi.encodeCall(IPersistenceRecord.minPrice, (ASSET, mp.collateral)));
        (uint256 high,) = Math.mul512(unsold, m);
        if (!ok || high >= Q96) return 0; // unpriced: a failed read, or a pot worth 2^256 or more, past any cap
        uint256 parked = Math.mulDiv(unsold, m, Q96);
        return Math.saturatingSub(AceVault(VAULT).effectiveCap(mp.collateral), Math.saturatingAdd(lent, parked));
    }

    /// @notice No entry cap of the terms' own.
    function entryCap(address, uint256) external pure returns (uint256) {
        return type(uint256).max;
    }

    /// @notice Before a loan: refuse unless the vault is the one these terms were built for, then ask `_productBeforeLend`. THE VAULT ONLY.
    /// @dev The hub, the asset and the rail are copies taken before the vault existed; a copy that disagrees with it refuses every loan.
    /// @dev The vault's door is none or these terms, and a door vault names a guardian.
    /// @dev Sealed, so no product skips these checks; a product's own runs after all three, in `_productBeforeLend`.
    function beforeLend(Lend kind, MarketParams calldata mp, uint256 loanId, bytes calldata data) external view {
        if (msg.sender != VAULT) revert NotVault();
        AceVault v = AceVault(VAULT);
        address door = v.DOOR();
        if (v.ACE() != ACE || v.asset() != ASSET || v.MIN_TENOR() != MIN_TENOR || v.MAX_TENOR() != MAX_TENOR || (door != address(0) && door != address(this))) {
            revert VaultMismatch();
        }
        if (door != address(0) && v.GUARDIAN() == address(0)) revert GuardianUnset();
        _productBeforeLend(kind, mp, loanId, data);
    }

    /// @notice After a loan: refuse any caller but the vault, then ask `_productAfterLend`. THE VAULT ONLY.
    /// @dev Sealed, like `beforeLend`, but it checks the caller alone: the vault runs `beforeLend`'s copy checks first on every lend.
    function afterLend(Lend kind, MarketParams calldata mp, uint256 loanId, address holder, bytes calldata data) external view {
        if (msg.sender != VAULT) revert NotVault();
        _productAfterLend(kind, mp, loanId, holder, data);
    }

    /// @dev A product's own check before every lend the vault makes, past all three vault checks; none here.
    function _productBeforeLend(Lend kind, MarketParams calldata mp, uint256 loanId, bytes calldata data) internal view virtual {}

    /// @dev A product's own read after every lend the vault makes, past the caller check alone; none here.
    function _productAfterLend(Lend kind, MarketParams calldata mp, uint256 loanId, address holder, bytes calldata data) internal view virtual {}

    // ---- the door ----

    /// @notice End each named loan of the vault's and take its pot to this door, or in kind home to the vault. PERMISSIONLESS and key-free.
    /// @notice A repaid or collected id, or one whose record cannot answer, yields zero; one neither expired nor settleable on distress reverts the batch.
    /// @notice Each pot pins its collateral's `saleRecord` to its own market's record, so a later row change moves no floor; in kind nothing reads it.
    function collectForfeited(uint256[] calldata loanIds) external nonReentrant returns (uint256[] memory out) {
        out = IAceVaultDoor(VAULT).collectForfeited(loanIds);
        IAceLenderOps hub = IAceLenderOps(ACE);
        for (uint256 i; i < loanIds.length; ++i) {
            if (out[i] == 0) continue;
            MarketParams memory mp = hub.idToMarketParams(hub.loanMarket(loanIds[i]));
            saleRecord[mp.collateral] = mp.record;
        }
    }

    /// @notice Sell goods at this door for cash and return the cash to the vault against the item, closing it once none is left. CURATOR ONLY.
    /// @notice While the item's key is open it refuses a sale under the floor; a dark record leaves the booked share, an accepted write-off none.
    /// @dev THE BUYER STATES WHAT IT PAYS AND THE DOOR PULLS EXACTLY THAT, after the callback, which is told the larger of `minOut`, the floor and one atom.
    /// @dev `type(uint256).max` sells this door's whole balance at execution, so a dust donation holds the key open only if the buyer sends units back.
    /// @param item The good to sell.
    /// @param units How much of it to offer up.
    /// @param buyer Who receives the goods and owes the cash.
    /// @param minOut The least cash the curator will take for it.
    /// @param data Opaque routing payload handed to the buyer.
    /// @return paid The cash the buyer stated and delivered.
    function sell(address item, uint256 units, address buyer, uint256 minOut, bytes calldata data) external nonReentrant returns (uint256 paid) {
        if (msg.sender != AceVault(VAULT).CURATOR()) revert NotCurator();
        if (item == ASSET) revert NothingToSell();
        if (item == VAULT) revert SharesAreNotAGood();
        if (buyer == VAULT || buyer == address(this)) revert BadBuyer();
        IERC20 goods = IERC20(item);
        if (units == type(uint256).max) units = goods.balanceOf(address(this));
        if (units == 0) revert NothingToSell();
        uint256 floor = _floor(item, units);
        goods.safeTransfer(buyer, units);
        paid = IDoorSaleCallback(buyer).onDoorSale(item, units, Math.max(Math.max(minOut, floor), 1), data);
        if (paid == 0 || paid < minOut) revert SaleUnderMin();
        if (paid < floor) revert UnderFloor();
        IERC20 cash = IERC20(ASSET);
        uint256 held = cash.balanceOf(address(this));
        cash.safeTransferFrom(buyer, address(this), paid);
        if (cash.balanceOf(address(this)) - held < paid) revert SalePaidShort();
        _return(item, paid, goods.balanceOf(address(this)) == 0);
        emit Sold(item, units, buyer, paid);
    }

    /// @notice Send the cash this door holds to the vault, as a counted donation that vests. PERMISSIONLESS.
    /// @dev Through the vault's own `returnProceeds`, under the asset's key, which no market names: it takes the vault's lock, so no lending verb can count it.
    /// @return cash The cash forwarded.
    function forwardCash() external nonReentrant returns (uint256 cash) {
        cash = IERC20(ASSET).balanceOf(address(this));
        _return(ASSET, cash, false);
    }

    /// @dev Approve the vault exactly `cash` and return it against `key`; a return of nothing that closes nothing calls nothing.
    function _return(address key, uint256 cash, bool closes) private {
        if (cash == 0 && !closes) return;
        IERC20(ASSET).forceApprove(VAULT, cash);
        IAceVaultDoor(VAULT).returnProceeds(key, cash, closes);
    }

    /// @dev The least a sale of `units` of `item` takes: zero on a closed key, else max(d, min(s, v)), each rounded up.
    /// @dev s is the units' pro-rata share of the key's booked value over the door's balance, v their record value, d that less the discount.
    /// @dev A `saleRecord` that cannot answer, starved of gas included, leaves the share, which reads no price.
    /// @dev A price too large to discount sets an unpayable floor, so every sale refuses until the write-off.
    function _floor(address item, uint256 units) private view returns (uint256) {
        (bool open, uint256 booked) = _key(item);
        if (!open) return 0;
        uint256 share = Math.mulDiv(booked, units, Math.max(units, IERC20(item).balanceOf(address(this))), Math.Rounding.Ceil);
        (bool ok, uint256 m) = Probe.askWord(saleRecord[item], abi.encodeCall(IPersistenceRecord.minPrice, (ASSET, item)));
        if (!ok || m == 0) return share;
        uint256 keep = 10_000 - MAX_SALE_DISCOUNT_BPS;
        if (m > type(uint256).max / keep) return type(uint256).max;
        uint256 discounted = Math.mulDiv(units, m * keep, Q96 * 10_000, Math.Rounding.Ceil);
        if (discounted >= share) return discounted;
        return Math.min(share, Math.mulDiv(units, m, Q96, Math.Rounding.Ceil)); // `discounted` is under `share`, so the record value cannot overflow
    }

    /// @dev `item`'s key at the vault, read raw at the slot `IAceVaultDoor` names for a door: the open flag at bit 248, the booked value in bits 0-183.
    function _key(address item) private view returns (bool open, uint256 booked) {
        bytes32[] memory s = new bytes32[](1);
        s[0] = keccak256(abi.encode(item, uint256(AceVaultFlows.ROOT) + SEIZED));
        uint256 word = uint256(AceVault(VAULT).extsload(s)[0]);
        return ((word >> 248) & 1 != 0, word & type(uint184).max);
    }
}
