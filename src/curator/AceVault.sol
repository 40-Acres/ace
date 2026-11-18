// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.36;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {IERC721} from "@openzeppelin/contracts/token/ERC721/IERC721.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {SafeCast} from "@openzeppelin/contracts/utils/math/SafeCast.sol";
import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import {ERC4626} from "@openzeppelin/contracts/token/ERC20/extensions/ERC4626.sol";
import {Math} from "@openzeppelin/contracts/utils/math/Math.sol";
import {ReentrancyGuardTransient} from "@openzeppelin/contracts/utils/ReentrancyGuardTransient.sol";
import {TransientSlot} from "@openzeppelin/contracts/utils/TransientSlot.sol";
import {MarketParams} from "../ace/hub/Types.sol";
import {IAceLenderOps} from "../interfaces/IAceLenderOps.sol";
import {IAceVaultDoor} from "../interfaces/IAceVaultDoor.sol";
import {HubRatePeriod} from "../interfaces/HubRatePeriod.sol";
import {Extension, IRollPolicy} from "../interfaces/IRollPolicy.sol";
import {IVaultDoor} from "../interfaces/IVaultDoor.sol";
import {IVaultTerms, Lend} from "../interfaces/IVaultTerms.sol";
import {AceVaultCaps, CapListing, ProductConfig} from "./AceVaultCaps.sol";
import {AceVaultFlows, BorrowRequest, Ctx, Request, Terms, VaultConfig, VaultLayout} from "./AceVaultFlows.sol";
import {AceVaultInKind} from "./AceVaultInKind.sol";
import {AceVaultTail} from "./AceVaultTail.sol";

/// @title AceVault
/// @notice An ERC-4626 vault that holds its cash and lends it through one door, on the terms its write-once product contract `TERMS` answers.
/// @notice LPs enter pro rata and exit at once from idle the exit requests do not hold; borrowers borrow, extend, top up and refinance through it.
/// @notice Entry can shut, and `maxDeposit` then reads zero; `AceVaultLens` names the gate and holds the vault's other views.
/// @dev No upgrade, and a genesis seed of dead shares; the asset must be non-fee-on-transfer, non-rebasing and hookless, as NAV counts its balance.
/// @dev Trust a vault only by `AceVaultFactory.isAceVault` on the factory a chain's book names: a subclass or a copy is other bytecode.
contract AceVault is ERC4626, ReentrancyGuardTransient, IAceVaultDoor {
    using SafeERC20 for IERC20;

    error ZeroCurator(); // a zero curator reverts every fee mint; the vault itself as curator would count its escrow out of an LP's free twice
    error ZeroGuardian(); // in kind only the guardian's exemption lifts a pot that cannot come home, and neither none nor the vault can call it
    error HubHasNoCode(); // raised by `HubRatePeriod.requirePerYear`: the hub is write-once, so a vault pointed at nothing is unrepairable
    error PerfFeeOutOfBounds();
    error VestWindowOutOfBounds(); // a window too short to defer defeats the deferral as fully as zero; both ends railed
    error TimelockOutOfBounds(); // the cap timelock sits outside one to fourteen days
    error TenorRailOutOfBounds(); // the tenor rail sits outside one day to a year, or its ends cross
    error TermsNotBound(); // the product names another vault, or has no code
    error ModeUnbuilt(); // a verb of a mode this vault is not in: a hub-ask vault has no door to collect to
    error NotDrainable(); // the product was deployed without a drain
    error ZeroAssets(); // an exit or a claim that prices to nothing
    error SeedTooSmall(); // the config names a seed under MIN_SEED atoms
    error SeedUnfunded(); // the vault's address holds less than the seed the config names
    error EndOfLife(); // NAV is zero while live shares are out: spent, and it takes no new capital
    error GainVesting(); // entry waits while a gain over GATE_BPS of NAV and one asset unit vests
    error LastOutVesting(); // the last free holder (for an LP, the curator not counted) would leave a vesting gain: request, and the last claim releases it
    error Draining(); // lending is stopped: no placement opens
    error RequestLive(); // a request lapses only once its lease has run
    error NoRequest(); // there is no request to lapse
    error OverRequest(); // asked past the caller's request
    error ClaimUnderMin(); // the claim pays less than the caller's minimum
    error InventoryUnsold(); // a settled pot of this vault's has not sold, or in kind is not yet home or came home this block: entry waits
    error RecoveryVesting(); // a material loss over an unsold pot has cleared: entry waits to its stored second while the whole vesting pile stays material
    error NotGuardian(); // only the guardian exempts a dead pot, and a vault with none has no override
    error PotsMoved(uint256 settledPots); // a pot settled since the guardian read the count: re-read and resubmit
    error OverSupply(); // in kind, entry mints no share past 2^160, so no holder's tracked count can overflow

    uint16 public constant MAX_PERF_FEE_BPS = 5000; // < 10000 is load-bearing: at 100% a zero high-water makes the fee all of NAV, and the mint divides by zero
    uint64 public constant REQUEST_LEASE = 30 days; // a request lapses this long after it was last made or renewed
    uint64 public constant MIN_VEST_WINDOW = 1 hours; // below this a gain matures before an entrant has held any risk
    uint64 public constant MAX_VEST_WINDOW = 7 days; // the longest a NAV rise may defer before it is spendable
    uint16 public constant GATE_BPS = AceVaultFlows.GATE_BPS; // entry shuts while a gain over this share of NAV vests
    uint16 public constant HOLD_BPS = AceVaultFlows.HOLD_BPS; // the trough hold weighs a loss or a pile against this share of the mark, and MIN_SEED atoms
    uint256 public constant MIN_SEED = AceVaultFlows.MIN_SEED; // the least genesis seed, in atoms: dead shares a rounding walk has to wear through
    uint64 public constant MIN_CAP_TIMELOCK = 1 days;
    uint64 public constant MAX_CAP_TIMELOCK = 14 days;
    uint64 public constant MIN_TENOR_RAIL = AceVaultCaps.MIN_TENOR_RAIL; // the shortest rail floor a vault may take
    uint64 public constant MAX_TENOR_RAIL = AceVaultCaps.MAX_TENOR_RAIL; // in kind the constructor caps the rail at AceVaultInKind.MAX_TENOR_RAIL, 30 days
    uint256 public constant ASK_RESERVE = 12_000; // gas a product read keeps back: a cold call's charge plus the worst caller tail, maxMint's
    uint256 private constant VIRTUAL_SHARES = AceVaultFlows.VIRTUAL_SHARES; // resists inflation; MUST agree with _decimalsOffset()
    uint48 private constant TROUGH_MARKED = type(uint48).max; // the hold's mark: a material loss (fall, booking or drawdown) seen over an unsold pot

    address public immutable ACE;
    address public immutable CURATOR; // capital held here never blocks an LP's release, so it can lose its vesting-gain share to a last requester
    address public immutable GUARDIAN; // a second key: switches the drain on, never off, cuts caps and exempts dead pots; zero names none, never in kind
    uint16 public immutable PERF_FEE_BPS; // bps of NAV growth past the fee high-water
    uint64 public immutable VEST_WINDOW; // seconds a NAV increase takes to become spendable
    uint256 public immutable VEST_FLOOR; // one whole asset unit: a vesting gain worth less never shuts entry by the gain gate
    uint256 public immutable SEED_SHARES; // the genesis seed's shares, at par, held here since `_free` and the tracker skip this address, never moved
    address public immutable override TERMS; // the product's terms contract
    address public immutable override DOOR; // where seized goods go and whence their cash returns; zero names none
    bool public immutable IN_KIND; // seized goods are paid out in kind to the shares that carried the loss, and never sold
    bool public immutable DRAINABLE; // whether the drain can ever be switched on
    uint64 public immutable CAP_TIMELOCK; // how long a cap raise waits
    uint64 public immutable MIN_TENOR; // the rail's floor on every market's tenors and every drawn term
    uint64 public immutable MAX_TENOR; // the rail's ceiling on every market's tenors, every drawn term and every extended one
    address internal immutable MANAGER; // the hub's custodian, approved for exactly each pledge
    address internal immutable TITLE; // the hub's loan-title collection, handed over by `transferFrom`
    bytes32 internal immutable TAIL0; // the forwarded calls' suffix, packed at deploy by `AceVaultTail.pack`
    bytes32 internal immutable TAIL1;
    bytes32 internal immutable TAIL2;
    bytes32 internal immutable TAIL3;
    bytes32 internal immutable TAIL4;

    /// @notice Emitted once, at construction, naming the product; the factory's registry says whether the code is the pinned one.
    event VaultDeployed(address indexed curator, address indexed asset, address indexed terms);
    event Collected(uint256 amount);
    event FeeCharged(uint256 shares, uint256 highWater);
    event ValueDeferred(uint256 amount);
    /// @notice A holder escrowed `shares` more, zero for a renewal, and the whole request now lapses at `expiresAt`.
    event ExitRequested(address indexed holder, uint256 shares, uint64 expiresAt);
    /// @notice `shares` of a request went back to its holder, by a cancel or a lapse.
    event ExitReleased(address indexed holder, uint256 shares);
    /// @notice The drain moved.
    event DrainSet(address indexed by, bool on);
    /// @notice The guardian exempted the pots standing at these hub counts from the entry gate, until the next settlement.
    event DeadPotsExempted(uint256 unsold, uint256 settled);

    /// @notice Rail and fix every write-once field, book the seed and the deploy's caps, and register this vault as its own roll policy at the hub.
    /// @notice The seed is all of the asset this address holds, at least `cfg.seed`, minted at par to this vault; the product is not asked.
    /// @param cfg The vault's write-once config.
    /// @param pc The product and how the vault lends for it.
    /// @param caps The caps live from the first block; anything unlisted reads zero, so a vault naming none lends nothing.
    constructor(VaultConfig memory cfg, ProductConfig memory pc, CapListing[] memory caps, string memory name_, string memory symbol_)
        ERC20(name_, symbol_)
        ERC4626(IERC20(cfg.asset))
    {
        if (cfg.curator == address(0) || cfg.curator == address(this)) revert ZeroCurator();
        if (pc.inKind && (cfg.guardian == address(0) || cfg.guardian == address(this))) revert ZeroGuardian();
        if (cfg.perfFeeBps > MAX_PERF_FEE_BPS) revert PerfFeeOutOfBounds();
        if (cfg.vestWindow < MIN_VEST_WINDOW || cfg.vestWindow > MAX_VEST_WINDOW) revert VestWindowOutOfBounds();
        HubRatePeriod.requirePerYear(cfg.ace); // a hub with no code reverts `HubHasNoCode` there, a hub quoting no year `HubRateNotPerYear`
        if (pc.door != address(0) && (pc.inKind || pc.door.code.length == 0 || IVaultDoor(pc.door).VAULT() != address(this))) {
            revert IAceVaultDoor.DoorNotBound();
        }
        if (pc.capTimelock < MIN_CAP_TIMELOCK || pc.capTimelock > MAX_CAP_TIMELOCK) revert TimelockOutOfBounds();
        uint64 ceiling = pc.inKind ? AceVaultInKind.MAX_TENOR_RAIL : MAX_TENOR_RAIL;
        if (pc.minTenor < MIN_TENOR_RAIL || pc.maxTenor > ceiling || pc.minTenor > pc.maxTenor) revert TenorRailOutOfBounds();
        if (pc.terms.code.length == 0 || IVaultTerms(pc.terms).VAULT() != address(this)) revert TermsNotBound();
        if (cfg.seed < MIN_SEED) revert SeedTooSmall();
        uint256 seed = IERC20(cfg.asset).balanceOf(address(this));
        if (seed < cfg.seed) revert SeedUnfunded();
        ACE = cfg.ace;
        MANAGER = IAceLenderOps(cfg.ace).POSITION_MANAGER();
        TITLE = IAceLenderOps(cfg.ace).POSITION_TITLE();
        CURATOR = cfg.curator;
        GUARDIAN = cfg.guardian;
        PERF_FEE_BPS = cfg.perfFeeBps;
        VEST_WINDOW = cfg.vestWindow;
        VEST_FLOOR = uint256(10) ** (decimals() - _decimalsOffset());
        (TERMS, DOOR, IN_KIND, DRAINABLE) = (pc.terms, pc.door, pc.inKind, pc.drainable);
        (CAP_TIMELOCK, MIN_TENOR, MAX_TENOR) = (pc.capTimelock, pc.minTenor, pc.maxTenor);
        (TAIL0, TAIL1, TAIL2, TAIL3) = _tail(cfg, pc);
        TAIL4 = AceVaultTail.word4(TITLE, pc.minTenor, pc.maxTenor);
        AceVaultCaps.init(caps, pc.inKind, cfg.asset);
        SEED_SHARES = seed * VIRTUAL_SHARES; // par on an empty vault: `seed * (0 + 1e6) / (0 + 1)`
        _booked(address(this), seed, seed * VIRTUAL_SHARES);
        emit Deposit(msg.sender, address(this), seed, seed * VIRTUAL_SHARES); // under the factory the sender is CREATE3's proxy: key the seed by owner
        IAceLenderOps(cfg.ace).setRollPolicy(address(this)); // the vault is its own roll policy: `admitsExtension` below
        emit VaultDeployed(cfg.curator, cfg.asset, pc.terms);
    }

    /// @dev The suffix's first four words: `AceVaultTail.pack`'s, the terms across words 2 and 3, and the door bit in door mode.
    function _tail(VaultConfig memory cfg, ProductConfig memory pc) private pure returns (bytes32 w0, bytes32 w1, bytes32 w2, bytes32 w3) {
        (w0, w1, w2, w3) = AceVaultTail.pack(cfg.ace, cfg.curator, cfg.guardian, cfg.asset, pc.capTimelock, pc.inKind);
        (w2, w3) = AceVaultTail.withTerms(w2, w3, pc.terms);
        if (pc.door != address(0)) w0 = AceVaultTail.withDoor(w0);
    }

    // ---- the state at the root ----

    /// @notice The fee threshold in assets: a collection lifts it to NAV; an entry or an exit carries it per virtual share, so no flow moves the gap per share.
    function feeHighWater() public view returns (uint256) {
        return AceVaultFlows.layout().feeHighWater;
    }

    /// @notice Whether lending is stopped: no placement, no extension, and entry shut.
    function draining() public view returns (bool) {
        return AceVaultFlows.layout().draining;
    }

    // ---- valuation and the requests' hold ----

    /// @notice Gross NAV less the unvested pile: a rise vests, and a fall burns the pile first and passes the rest through, so a sync never lowers it.
    function totalAssets() public view override returns (uint256) {
        return _totalAssetsAt(grossNav());
    }

    /// @dev `totalAssets` at a gross the caller already read; the door prices the requests' hold at it, off the gross its sync read.
    function _totalAssetsAt(uint256 g) internal view returns (uint256) {
        return Math.saturatingSub(g, _pendingUnvested(g));
    }

    /// @notice NAV before deferral: the asset balance plus the hub's (vault, asset) pool, resting, lent and owed.
    /// @dev Two reads at any market count, the hub's refusing mid-hub-body; a payout naming this vault is a counted donation.
    function grossNav() public view returns (uint256) {
        return idle() + IAceLenderOps(ACE).lenderAssets(address(this), asset());
    }

    /// @notice The asset the vault holds: every unit an exit, a claim or a placement can reach.
    function idle() public view returns (uint256) {
        return IERC20(asset()).balanceOf(address(this));
    }

    /// @notice What a placement may take: idle less what the standing requests hold; nothing while draining.
    function lendable() public view returns (uint256) {
        return draining() ? 0 : _instantCashAt(totalAssets());
    }

    /// @dev Idle and the requests' hold at a NAV the caller already read, so a verb prices the requests' hold without reading the hub again.
    function _holdsAt(uint256 a) internal view returns (uint256 exitable, uint256 heldReq) {
        exitable = idle();
        if (AceVaultFlows.layout().draining) return (exitable, 0);
        heldReq = Math.min(exitable, _requestWorth(a));
    }

    /// @dev The standing requests' worth at NAV `a`, rounded down, over the supply a quote at `a` prices against.
    function _requestWorth(uint256 a) internal view returns (uint256) {
        return Math.mulDiv(AceVaultFlows.layout().requestedShares, a + 1, _quoteSupply(a));
    }

    /// @dev THE EXIT GATE: whether idle covers the requests' worth at the last sync's NAV; storage and one balance, never a hub view.
    function _exitsCovered() internal view returns (bool) {
        VaultLayout storage $ = AceVaultFlows.layout();
        return $.requestedShares == 0 || _requestWorth(_totalAssetsAt($.navMark)) <= idle();
    }

    /// @dev What an instant exit may take at NAV `a`: idle less the requests' hold, all of idle while draining.
    function _instantCashAt(uint256 a) internal view returns (uint256) {
        (uint256 exitable, uint256 heldReq) = _holdsAt(a);
        return exitable - heldReq;
    }

    /// @dev The virtual offset backing every 4626 conversion, so inherited previews match the mints.
    function _decimalsOffset() internal pure override returns (uint8) {
        return 6;
    }

    /// @dev Observe gross NAV: a rise is stamped into the vest and a fall burns it pro rata; a new high lifts `navHigh`. FIRST in every verb that moves value.
    /// @return g The gross NAV observed, which is also the mark this leaves.
    function _sync() internal returns (uint256 g) {
        g = grossNav();
        VaultLayout storage $ = AceVaultFlows.layout();
        uint256 m = $.navMark;
        if (g > m) _stampVest(g - m);
        else if (g < m) _burnVest(m - g);
        $.navMark = g;
        if (g > $.navHigh) $.navHigh = g;
        if (!IN_KIND) _markTrough(m, g);
    }

    /// @dev THE TROUGH HOLD, `_sync`'s leg: a material loss over an unsold pot marks; the next sync with none unsold stores a material pile's maturity, else 0.
    function _markTrough(uint256 m, uint256 g) private {
        VaultLayout storage $ = AceVaultFlows.layout();
        bool marked = $.troughHold == TROUGH_MARKED;
        if (!marked && !AceVaultFlows.material(_loss(m, g), m)) return;
        bool unsold = _unsold();
        if (marked == unsold) return; // marked over a pot still unsold, or a loss with none unsold: nothing moves
        $.troughHold = unsold ? TROUGH_MARKED : AceVaultFlows.material(unvested(), g) ? uint48($.vestMaturity) : 0; // a maturity is at most a week out
    }

    /// @dev The loss a sync from mark `m` to gross `g` weighs: the fall or the booked value a door collect left in `BOOKED`, and with either the drawdown.
    function _loss(uint256 m, uint256 g) private view returns (uint256 l) {
        l = Math.max(Math.saturatingSub(m, g), TransientSlot.tload(TransientSlot.asUint256(AceVaultFlows.BOOKED)));
        if (l != 0) l = Math.max(l, _drawdown(g));
    }

    /// @dev Whether a stored hold shuts entry, by storage alone and so blind to a hub pot: a second to come, a material pile, no unexempted key, no gain gate.
    function _holdOnly() private view returns (bool) {
        VaultLayout storage $ = AceVaultFlows.layout();
        uint48 t = $.troughHold;
        if (t == 0 || t == TROUGH_MARKED || block.timestamp >= t || ($.openSeized != 0 && $.exemptSettled == 0)) return false;
        (uint256 u, uint256 m) = (unvested(), $.navMark);
        return AceVaultFlows.material(u, m) && !_vesting(u, Math.saturatingSub(m, u));
    }

    // ---- the drawdown and the caps ----

    /// @dev The drawdown at gross `g`, gross NAV's fall below its high-water: the one figure the total's room and the lens both read.
    function _drawdown(uint256 g) private view returns (uint256) {
        return Math.saturatingSub(AceVaultFlows.layout().navHigh, g);
    }

    /// @notice A collateral's effective cap: its row while listed, else the wildcard's.
    function effectiveCap(address collateral) public view returns (uint256) {
        return AceVaultCaps.effective(AceVaultFlows.layout(), collateral);
    }

    /// @notice Set a key's cap and list it: at or under its effective cap it lands at once, by the curator or the guardian; above it, it waits.
    /// @notice The key is a collateral, `address(0)` for the wildcard, or this vault for the total; in kind the wildcard stays zero and the asset is no key.
    function submitCap(address, uint192) external {
        _return(_fwd(address(AceVaultCaps)));
    }

    /// @notice Delist a collateral so the wildcard applies: at once unless the wildcard is above its row, else after the timelock.
    function submitDelist(address) external {
        _return(_fwd(address(AceVaultCaps)));
    }

    /// @notice Make a key's pending change live once it has waited out the timelock. PERMISSIONLESS.
    function acceptCap(address) external {
        _return(_fwd(address(AceVaultCaps)));
    }

    /// @notice Drop a key's pending change. The curator or the guardian.
    function revokePendingCap(address) external {
        _return(_fwd(address(AceVaultCaps)));
    }

    // ---- the door and the roll policy ----

    /// @notice Borrow against collateral at the product's terms: the vault opens to itself, then pays and hands title over.
    /// @notice The draw is bound to the ask, railed by the tenor bounds, and held under lendable cash, the collateral's room and the total.
    /// @param r What the borrower asks; the product's terms decide what it admits, within it.
    /// @param data The product's own payload, such as a signed quote.
    /// @param permit2 A Permit2 SignatureTransfer for the collateral, or empty to pull on allowance.
    /// @return loanId The loan, titled to the caller.
    function borrow(BorrowRequest calldata r, bytes calldata data, bytes calldata permit2) external nonReentrant returns (uint256 loanId) {
        if (draining()) revert Draining();
        uint256 g = _sync();
        (MarketParams memory mp, Terms memory t) = _terms(msg.sender, r, data);
        bytes32 id = AceVaultFlows.place(Ctx(asset(), MANAGER, _instantCashAt(_totalAssetsAt(g)), _room(mp, t.principal, g)), mp, t, permit2);
        IVaultTerms(TERMS).beforeLend(Lend.Borrow, mp, 0, data);
        loanId = _lend(id, mp, t, r.minPayout, r.deadline);
        IVaultTerms(TERMS).afterLend(Lend.Borrow, mp, loanId, msg.sender, data);
        _sync();
    }

    /// @dev The product's answer for this request, then the base's checks on it: the mode, the binding to the ask and the tenor rail.
    function _terms(address borrower, BorrowRequest calldata r, bytes calldata data) private view returns (MarketParams memory mp, Terms memory t) {
        (mp, t) = IVaultTerms(TERMS).borrowTerms(borrower, r, data);
        t = AceVaultCaps.admit(r, mp, t, AceVaultCaps.hubAsk(IN_KIND, DOOR), MIN_TENOR, MAX_TENOR);
    }

    /// @dev The room for `p` at gross `g`, which must be the door's own sync read: `OverTotal` past the total, else the least of the row's and the product's.
    function _room(MarketParams memory mp, uint256 p, uint256 g) private view returns (uint256) {
        (uint256 row, uint256 total) = AceVaultCaps.room(ACE, asset(), mp.collateral, g - idle(), _drawdown(g));
        if (p > total) revert AceVaultCaps.OverTotal();
        return Math.min(row, _ask(abi.encodeCall(IVaultTerms.room, (mp))));
    }

    /// @dev The door's hub leg, then the payout and the title to the caller.
    function _lend(bytes32 id, MarketParams memory mp, Terms memory t, uint256 minPayout, uint64 deadline) private returns (uint256 loanId) {
        uint256 payout;
        (loanId, payout) = AceVaultFlows.lend(ACE, id, mp, t, minPayout, deadline);
        IERC20(asset()).safeTransfer(msg.sender, payout);
        IERC721(TITLE).transferFrom(address(this), msg.sender, loanId);
    }

    /// @notice The vault is its own roll policy: it consents to one of its loans running longer exactly while it would lend there now.
    /// @notice The hub asks it for any caller, a stranger included: the exit gate binds a stranger's lengthening as it binds the holder's.
    /// @dev A plain view the hub asks under its lock, so its own legs read no hub view; the product's word is asked last, and any failure there is a no.
    /// @param e The extension the hub asks about.
    /// @param data The caller's payload.
    /// @return The selector to consent; zero refuses.
    function admitsExtension(Extension calldata e, bytes calldata data) external view returns (bytes4) {
        bool yes =
            e.dst.lender == address(this) && !draining() && _legsOpen(e) && (e.newExpiry <= e.expiry || _exitsCovered() || _holdOnly()) && _consents(e, data);
        return yes ? IRollPolicy.admitsExtension.selector : bytes4(0);
    }

    /// @dev The cap and rail legs of an extension: its collateral's effective cap and the total nonzero, and every tenor inside the rail.
    function _legsOpen(Extension calldata e) private view returns (bool) {
        VaultLayout storage $ = AceVaultFlows.layout();
        MarketParams calldata m = e.dst;
        return AceVaultCaps.effective($, m.collateral) != 0 && $.caps[address(this)].cap != 0 && m.minTenor >= MIN_TENOR && m.maxTenor <= MAX_TENOR
            && Math.saturatingSub(e.newExpiry, block.timestamp) <= MAX_TENOR;
    }

    /// @dev The product's consent, `Probe.askBool`'s shape without its gas floor: yes only for a success returning exactly the word one.
    function _consents(Extension calldata e, bytes calldata data) private view returns (bool) {
        return _ask(abi.encodeCall(IVaultTerms.admitsExtension, (e, data))) == 1;
    }

    /// @dev One word from the product by raw static call, keeping `ASK_RESERVE` back; a revert, a bomb, a burn or a wrong-sized answer reads zero.
    /// @dev Not `Probe.askBool`, whose floor reverts a short caller: a 4626 max view must not revert, and every caller's zero is its closed answer.
    function _ask(bytes memory cd) private view returns (uint256 v) {
        address terms = TERMS;
        assembly ("memory-safe") {
            let g := gas()
            if gt(g, ASK_RESERVE) {
                let ok := staticcall(sub(g, ASK_RESERVE), terms, add(cd, 0x20), mload(cd), 0, 0x20)
                if and(ok, eq(returndatasize(), 0x20)) { v := mload(0) }
            }
        }
    }

    // ---- the ERC-4626 entry path ----

    /// @notice The share count `deposit` mints, with the pending fee already priced in.
    function previewDeposit(uint256 assets) public view override returns (uint256) {
        uint256 a = totalAssets();
        return Math.mulDiv(assets, _quoteSupply(a), a + 1, Math.Rounding.Floor);
    }

    /// @notice The assets `mint` pulls, rounded UP against the depositor.
    function previewMint(uint256 shares) public view override returns (uint256) {
        uint256 a = totalAssets();
        return Math.mulDiv(shares, a + 1, _quoteSupply(a), Math.Rounding.Ceil);
    }

    /// @dev The supply a quote at NAV `a` prices against: the fee its verb collects first is already outstanding, plus the virtual offset.
    function _quoteSupply(uint256 a) internal view returns (uint256) {
        return _virtualSupply() + _pendingFeeShares(a);
    }

    /// @notice Deposit assets for shares priced pro-rata against NAV; refused while entry is shut, as `maxDeposit` reads.
    function deposit(uint256 assets, address receiver) public override nonReentrant returns (uint256 shares) {
        uint256 a = _openEntry();
        shares = _sharesAt(assets, a, Math.Rounding.Floor);
        _enter(receiver, assets, shares, a);
    }

    /// @notice Mint shares for assets priced pro-rata against NAV; refused as `deposit` is.
    function mint(uint256 shares, address receiver) public override nonReentrant returns (uint256 assets) {
        uint256 a = _openEntry();
        assets = _assetsAt(shares, a, Math.Rounding.Ceil);
        _enter(receiver, assets, shares, a);
    }

    /// @dev Refuses past the entry cap at NAV `a`, in assets for `mint` as for `deposit`; in kind also past `MAX_SUPPLY`, the fee collected first counted.
    function _enter(address receiver, uint256 assets, uint256 shares, uint256 a) private {
        uint256 cap = _capAt(receiver, a);
        if (assets > cap) revert ERC4626ExceededMaxDeposit(receiver, assets, cap);
        if (IN_KIND && shares > Math.saturatingSub(AceVaultInKind.MAX_SUPPLY, totalSupply())) revert OverSupply();
        _deposit(_msgSender(), receiver, assets, shares);
    }

    /// @dev OpenZeppelin's body on this vault's own pull: pull, then mint and book; the asset must be hookless, as a sender hook runs before either.
    function _deposit(address caller, address receiver, uint256 assets, uint256 shares) internal override {
        _transferIn(caller, assets);
        _booked(receiver, assets, shares);
        emit Deposit(caller, receiver, assets, shares);
    }

    /// @dev Mint `shares` for `assets` already held, lifting the mark, `navHigh` and the fee high-water with the entry, so it reads as no growth.
    function _booked(address receiver, uint256 assets, uint256 shares) private {
        _mint(receiver, shares);
        VaultLayout storage $ = AceVaultFlows.layout();
        if (PERF_FEE_BPS != 0) {
            (uint256 h, uint256 sv) = ($.feeHighWater, _virtualSupply());
            $.feeHighWater = Math.max(h + assets, Math.mulDiv(h, sv, sv - shares, Math.Rounding.Ceil));
        }
        $.navMark += assets;
        $.navHigh += assets;
    }

    /// @dev The entry cap at NAV `a`: zero while draining, else the product's, read by a raw static call that answers zero on any failure.
    function _capAt(address receiver, uint256 a) private view returns (uint256) {
        return draining() ? 0 : _ask(abi.encodeCall(IVaultTerms.entryCap, (receiver, a)));
    }

    /// @dev Entry's opening, returning the NAV it prices at: the sync, the gates, then the fee, last because in kind its mint would move the batch they read.
    function _openEntry() internal returns (uint256 a) {
        a = _totalAssetsAt(_sync()); // the sync moves no value, so the gross it read is still gross
        uint256 u = unvested();
        if (_live()) {
            if (a == 0) revert EndOfLife();
            if (_vesting(u, a)) revert GainVesting();
        }
        if (_unsold()) revert InventoryUnsold();
        if (_held(u, a + u)) revert RecoveryVesting(); // past the unsold gate the sync left no mark standing
        _collectFeeAt(a);
    }

    /// @dev Whether shares past the seed's are out: THE ONE live-supply test every zero-supply branch reads, verb and view alike.
    function _live() private view returns (bool) {
        return totalSupply() > SEED_SHARES;
    }

    /// @dev Whether entry waits on a pot: a hub pot or door key no exemption covers, or in kind a batch opened this block over tracked shares.
    function _unsold() internal view returns (bool) {
        if (IN_KIND && AceVaultInKind.layout().foldBlock == block.number && AceVaultInKind.layout().trackedSupply != 0) return true;
        (uint256 u, uint256 s) = _hubCounts();
        VaultLayout storage $ = AceVaultFlows.layout();
        return AceVaultFlows.unsold(u, $.openSeized, s, $.exemptSettled);
    }

    /// @dev The hub's two counts for this vault in its asset: its settled pots not yet sold, and its pots ever settled.
    function _hubCounts() private view returns (uint256 u, uint256 s) {
        return IAceLenderOps(ACE).lenderUnresolved(address(this), asset());
    }

    /// @notice ERC-4626: zero while entry is shut (spent, a gain vesting, an unsold pot or its recovery, a drain), else the cap; never reverts on the product.
    /// @notice In kind it is also no more than the cash the shares left under `MAX_SUPPLY` price at, zero at the bound.
    function maxDeposit(address receiver) public view override returns (uint256) {
        (bool shut, uint256 a) = _entryShut();
        if (shut) return 0;
        if (!IN_KIND) return _capAt(receiver, a);
        uint256 q = _quoteSupply(a);
        (bool ok, uint256 n) = Math.tryMul(AceVaultInKind.headroom(q), a + 1);
        return Math.min(ok ? n / q : type(uint256).max, _capAt(receiver, a));
    }

    /// @notice ERC-4626: `maxDeposit` in shares at the deposit preview's price; `type(uint256).max` for an uncapped vault; in kind, at most the shares left.
    /// @dev Never reverts on the product, which reads zero on any failure; where cap times the quote supply overflows it saturates, over-reporting.
    function maxMint(address receiver) public view override returns (uint256) {
        (bool shut, uint256 a) = _entryShut();
        if (shut) return 0;
        uint256 q = _quoteSupply(a);
        (bool ok, uint256 n) = Math.tryMul(_capAt(receiver, a), q);
        uint256 m = ok ? n / (a + 1) : type(uint256).max;
        return IN_KIND ? Math.min(m, AceVaultInKind.headroom(q)) : m;
    }

    /// @dev `_openEntry`'s gates as a view, on the pile its sync would leave; the verb collects its fee only after them, so the view reads what they read.
    /// @return shut Whether entry would refuse.
    /// @return a The NAV entry would price at, `totalAssets` off one gross read.
    function _entryShut() internal view returns (bool shut, uint256 a) {
        uint256 u;
        (a, u) = _navParts();
        shut = _unsold() || _held(u, a + u) || (_live() && (a == 0 || _vesting(u, a)));
    }

    /// @dev `totalAssets` and the pile the next sync would leave, off one gross read.
    function _navParts() private view returns (uint256 a, uint256 u) {
        uint256 g = grossNav();
        u = _pendingUnvested(g);
        a = Math.saturatingSub(g, u);
    }

    /// @dev The trough hold over pile `u` at gross `g`: it binds while the pile is material and its second has not come; a mark reads as a second never come.
    function _held(uint256 u, uint256 g) private view returns (bool) {
        return AceVaultFlows.material(u, g) && block.timestamp < AceVaultFlows.layout().troughHold;
    }

    /// @dev Whether a pile this large against NAV is still vesting: entry waits, so no entrant buys a recovery cheap.
    function _vesting(uint256 u, uint256 a) internal view returns (bool) {
        return AceVaultFlows.gainVesting(u, a, VEST_FLOOR);
    }

    /// @dev Shares for assets at a NAV the caller already read: OZ's own formula, as OZ's `_convertToShares` re-reads `totalAssets()` itself.
    function _sharesAt(uint256 assets, uint256 a, Math.Rounding r) internal view returns (uint256) {
        return Math.mulDiv(assets, _virtualSupply(), a + 1, r);
    }

    /// @dev Assets for shares at a NAV the caller already read; the exact inverse of `_sharesAt`.
    function _assetsAt(uint256 shares, uint256 a, Math.Rounding r) internal view returns (uint256) {
        return Math.mulDiv(shares, a + 1, _virtualSupply(), r);
    }

    /// @dev The supply plus the virtual offset: the frame every conversion and the fee high-water's carry price in.
    function _virtualSupply() private view returns (uint256) {
        return totalSupply() + VIRTUAL_SHARES;
    }

    // ---- the instant exit: no exit path calls the product ----

    /// @notice The shares an instant `withdraw` burns, rounded UP, priced over the supply the verb's own fee collection leaves.
    function previewWithdraw(uint256 assets) public view override returns (uint256) {
        uint256 a = totalAssets();
        return Math.mulDiv(assets, _quoteSupply(a), a + 1, Math.Rounding.Ceil);
    }

    /// @notice The assets an instant `redeem` pays, rounded DOWN, at the same price.
    function previewRedeem(uint256 shares) public view override returns (uint256) {
        uint256 a = totalAssets();
        return Math.mulDiv(shares, a + 1, _quoteSupply(a), Math.Rounding.Floor);
    }

    /// @notice The cash `owner` can take at once: their shares at the fee-inclusive price, capped by idle the requests do not hold.
    /// @notice ZERO for this vault itself, and for the last free holder (for an LP, the curator not counted) while a gain vests: the verb refuses it.
    function maxWithdraw(address owner) public view override returns (uint256) {
        (uint256 assets,) = _exitMax(owner);
        return assets;
    }

    /// @notice The shares `owner` can redeem at once, the same bound in shares; zero where `maxWithdraw` is, and where they would pay nothing.
    function maxRedeem(address owner) public view override returns (uint256) {
        (, uint256 shares) = _exitMax(owner);
        return shares;
    }

    /// @dev What `owner` may take at once, in cash and in shares, zero wherever the verb would refuse; it reads the free supply after the fee.
    function _exitMax(address owner) private view returns (uint256, uint256) {
        (uint256 a, uint256 u) = _navParts();
        uint256 q = _quoteSupply(a);
        uint256 bal = balanceOf(owner);
        if (owner == address(this) || (bal == _free(owner, q - VIRTUAL_SHARES) && u != 0)) return (0, 0);
        return _bound(_instantCashAt(a), a, q, bal);
    }

    /// @dev What `bal` shares may take of `cash`, in cash and in shares, at NAV `a` over quote supply `q`.
    function _bound(uint256 cash, uint256 a, uint256 q, uint256 bal) private pure returns (uint256 assets, uint256 shares) {
        assets = Math.min(Math.mulDiv(bal, a + 1, q), cash);
        shares = Math.min(bal, Math.mulDiv(cash, q, a + 1));
        if (Math.mulDiv(shares, a + 1, q) == 0) shares = 0; // a redeem that would pay nothing is refused, so it is not offered
    }

    /// @notice ERC-4626: pay `assets` to `receiver` at once, burning `owner`'s shares rounded UP; the caller is the owner or a spender.
    function withdraw(uint256 assets, address receiver, address owner) public override nonReentrant returns (uint256 shares) {
        if (assets == 0) return 0; // ERC-4626: a zero ask is a no-op
        (, shares) = _exitNow(receiver, owner, assets, 0);
    }

    /// @notice ERC-4626: burn `shares` of `owner`'s and pay their worth at once, rounded DOWN, to `receiver`.
    function redeem(uint256 shares, address receiver, address owner) public override nonReentrant returns (uint256 assets) {
        if (shares == 0) return 0; // ERC-4626: a zero ask is a no-op
        (assets,) = _exitNow(receiver, owner, 0, shares);
    }

    /// @dev The instant exit behind `redeem` and `withdraw`, naming one amount; not OZ's `_withdraw`, as its refusals sit between the spend and the burn.
    function _exitNow(address receiver, address owner, uint256 wantAssets, uint256 wantShares) private returns (uint256 assets, uint256 shares) {
        _sync();
        uint256 a = totalAssets();
        _collectFeeAt(a);
        (assets, shares) =
            wantShares != 0 ? (_assetsAt(wantShares, a, Math.Rounding.Floor), wantShares) : (wantAssets, _sharesAt(wantAssets, a, Math.Rounding.Ceil));
        address by = _msgSender();
        if (by != owner) _spendAllowance(owner, by, shares);
        if (assets == 0) revert ZeroAssets(); // a redeem worth nothing is refused; a withdraw of one wei always pays
        if (shares == _free(owner, totalSupply()) && unvested() != 0) revert LastOutVesting();
        if (assets > _instantCashAt(a)) {
            if (wantShares != 0) revert ERC4626ExceededMaxRedeem(owner, shares, maxRedeem(owner));
            revert ERC4626ExceededMaxWithdraw(owner, assets, maxWithdraw(owner));
        }
        _burn(owner, shares);
        _pay(receiver, assets, shares, a);
        emit Withdraw(by, receiver, owner, assets, shares);
    }

    /// @dev Book an exit of `assets` for `shares` at NAV `a`: the high-water scales per virtual share, never under `a - assets`; mark and high fall by it.
    function _pay(address receiver, uint256 assets, uint256 shares, uint256 a) private {
        VaultLayout storage $ = AceVaultFlows.layout();
        if (PERF_FEE_BPS != 0) {
            uint256 sv = _virtualSupply();
            $.feeHighWater = Math.max(Math.mulDiv($.feeHighWater, sv, sv + shares), Math.saturatingSub(a, assets));
        }
        $.navMark = Math.saturatingSub($.navMark, assets); // the cash leaves gross with the transfer below, so the next sync reads no fall
        $.navHigh = Math.saturatingSub($.navHigh, assets); // and the drawdown stays where it was
        IERC20(asset()).safeTransfer(receiver, assets);
    }

    /// @dev The supply free for `holder`'s last-out test and release: `supply` less shares on this vault, and for an LP every curator share, minted or pending.
    function _free(address holder, uint256 supply) private view returns (uint256 s) {
        s = supply - balanceOf(address(this));
        if (holder != CURATOR) s -= balanceOf(CURATOR) + (supply - totalSupply());
    }

    // ---- the exit request: escrowed shares whose worth the requests' hold keeps from placements ----

    /// @notice Escrow `shares` of the caller's on this vault and renew the whole request's lease, zero only renewing; idle up to its worth is then held for it.
    /// @notice NO PRICE IS LOCKED: a claim prices at its own NAV, falls passing through and gains vesting as for a free share.
    function requestExit(uint256 shares) external nonReentrant {
        _sync();
        address holder = _msgSender();
        VaultLayout storage $ = AceVaultFlows.layout();
        Request storage r = $.requests[holder];
        if (shares != 0) {
            _context(holder);
            _transfer(holder, address(this), shares);
            _context(address(0));
            r.shares += shares;
            $.requestedShares += shares;
        }
        uint64 expiresAt = uint64(block.timestamp) + REQUEST_LEASE;
        r.expiresAt = expiresAt;
        emit ExitRequested(holder, shares, expiresAt);
    }

    /// @notice Return `shares` of the caller's request to them, at any time.
    function cancelExit(uint256 shares) external nonReentrant {
        _unrequest(_msgSender(), shares);
    }

    /// @notice Return a lapsed request's whole escrow to its holder. PERMISSIONLESS once the lease has run.
    function lapseExit(address holder) external nonReentrant {
        Request memory r = AceVaultFlows.layout().requests[holder];
        if (r.shares == 0) revert NoRequest();
        if (block.timestamp < r.expiresAt) revert RequestLive();
        _unrequest(holder, r.shares);
    }

    /// @dev Hand `shares` of `holder`'s escrow back.
    function _unrequest(address holder, uint256 shares) private {
        _sync();
        VaultLayout storage $ = AceVaultFlows.layout();
        Request storage r = $.requests[holder];
        if (shares > r.shares) revert OverRequest();
        r.shares -= shares;
        $.requestedShares -= shares;
        _transfer(address(this), holder, shares);
        emit ExitReleased(holder, shares);
    }

    /// @notice The shares of `holder`'s request a claim could burn now, against idle, at the price the claim would pay.
    /// @dev It replays the release: for the last requester, every other share a donation or (for an LP) the curator's, it adds the pile back to NAV.
    function maxClaim(address holder) public view returns (uint256 shares) {
        VaultLayout storage $ = AceVaultFlows.layout();
        uint256 own = $.requests[holder].shares;
        (uint256 a, uint256 u) = _navParts();
        if (own == $.requestedShares && _free(holder, totalSupply()) == 0) a += u;
        (, shares) = _bound(idle(), a, _quoteSupply(a), own);
    }

    /// @notice Burn `shares` of the caller's request and pay their worth to `receiver` from idle, first come, at its NAV rounded down, at least `minAssets`.
    /// @dev The last requester releases the pile BEFORE the fee, so the fee is charged on it; any other claim leaves its share of the pile to the stayers.
    function claimExit(uint256 shares, address receiver, uint256 minAssets) external nonReentrant returns (uint256 assets) {
        uint256 g = _sync();
        address holder = _msgSender();
        VaultLayout storage $ = AceVaultFlows.layout();
        Request storage r = $.requests[holder];
        if (shares > r.shares) revert OverRequest();
        if (r.shares == $.requestedShares && _free(holder, totalSupply()) == 0) _release(g);
        uint256 a = totalAssets();
        _collectFeeAt(a);
        assets = _assetsAt(shares, a, Math.Rounding.Floor);
        if (assets == 0) revert ZeroAssets();
        if (assets < minAssets) revert ClaimUnderMin();
        if (assets > idle()) revert ERC4626ExceededMaxRedeem(holder, shares, maxClaim(holder));
        r.shares -= shares;
        $.requestedShares -= shares;
        _context(holder);
        _burn(address(this), shares);
        _context(address(0));
        _pay(receiver, assets, shares, a);
        emit Withdraw(holder, receiver, holder, assets, shares);
    }

    // ---- the curator surface ----

    /// @notice Stop or resume lending: ON by the curator or the guardian, OFF by the curator alone, each at once; refused for a vault without a drain.
    /// @notice While it stands nothing lends or extends, entry shuts and exits take all of idle first come: settle first, or exits leave at the pre-loss price.
    function setDrain(bool on) external nonReentrant {
        if (!DRAINABLE) revert NotDrainable();
        address by = _msgSender();
        if (by != CURATOR && !(on && by == GUARDIAN)) revert NotCurator();
        _sync();
        AceVaultFlows.layout().draining = on;
        emit DrainSet(by, on);
    }

    /// @notice Exempt the pots and door goods standing now from the entry gate, for those that can never sell. GUARDIAN ONLY; none without one.
    /// @notice It refuses `PotsMoved` unless the hub's settled count is still the one named; any later settlement, a stranger's too, voids it until renewed.
    function exemptDeadPots(uint256 expectedSettled) external nonReentrant {
        if (GUARDIAN == address(0) || _msgSender() != GUARDIAN) revert NotGuardian();
        (uint256 u, uint256 s) = _hubCounts();
        if (s != expectedSettled) revert PotsMoved(s);
        VaultLayout storage $ = AceVaultFlows.layout();
        uint256 m = $.navMark;
        if (!IN_KIND && AceVaultFlows.unsold(u, $.openSeized, s, $.exemptSettled) && AceVaultFlows.material(_loss(m, grossNav()), m)) {
            $.troughHold = TROUGH_MARKED; // `_markTrough`'s mark rule (keep the two equal), never its clear: a sync clears over the pile it just stamped
        }
        $.exemptSettled = s;
        emit DeadPotsExempted(u, s);
    }

    // ---- the permissionless crank: it moves cash and prices nothing ----

    /// @notice Collect everything the hub has credited this vault, every market at once, into idle; NAV-neutral. PERMISSIONLESS.
    function crank() external nonReentrant {
        _sweep();
    }

    /// @dev The crank's body, which the collect, the door's return and the lending doors also close with.
    function _sweep() private {
        _sync();
        uint256 paid = IAceLenderOps(ACE).collect(asset(), address(this)); // this vault's own pool, to this vault
        if (paid != 0) emit Collected(paid);
        _collectFeeAt(totalAssets());
    }

    // ---- the collect: in kind, or to the door ----

    /// @notice End each named loan of this vault's and take its pot: in kind to this vault, PERMISSIONLESS; in door mode to the door, THE DOOR ONLY.
    /// @notice A repaid or already-collected id yields zero and the batch goes on; one neither expired nor settleable on distress reverts the whole batch.
    /// @return The units each id handed over.
    function collectForfeited(uint256[] calldata loanIds) external returns (uint256[] memory) {
        loanIds.length; // compiles to nothing; it keeps the input's ABI name, as the decoder has bounds-checked the array whole
        _return(_collect());
    }

    /// @dev The collect under the lock: a sync sees the settle's NAV fall, the mode's body runs, the sweep takes the hub's credit, the booked word clears.
    function _collect() private nonReentrant returns (bytes memory r) {
        address lib = address(AceVaultInKind);
        if (!IN_KIND) {
            if (DOOR == address(0)) revert ModeUnbuilt();
            if (msg.sender != DOOR) revert IAceVaultDoor.NotDoor();
            lib = address(AceVaultFlows);
        }
        _sync();
        r = _delegate(lib);
        _sweep();
        TransientSlot.tstore(TransientSlot.asUint256(AceVaultFlows.BOOKED), 0);
    }

    // ---- door mode: the return and the write-off ----

    /// @notice Take a sale's cash from the door against a seized collateral, and close it from the entry gate if `closes`. THE DOOR ONLY.
    /// @notice Any key takes cash; only `(c, 0, false)` refuses. The cash vests, and lowers the drawdown one for one.
    function returnProceeds(address, uint256, bool) external {
        _return(_proceeds());
    }

    /// @dev The return under the lock: a sync before, the body, a sweep after.
    function _proceeds() private nonReentrant returns (bytes memory r) {
        if (msg.sender != DOOR) revert IAceVaultDoor.NotDoor();
        _sync();
        r = _delegate(address(AceVaultFlows));
        _sweep();
    }

    /// @notice Queue a write-off of a seized collateral's residue, due after `CAP_TIMELOCK`. CURATOR ONLY; a collect onto it voids it.
    /// @notice For goods the door cannot sell: accepting it lifts the door's gate over what is left, unasked; a material fall over them still holds entry.
    function submitWriteOff(address) external {
        _return(_fwd(address(AceVaultFlows)));
    }

    /// @notice Land a write-off that has waited out the timelock: the residue leaves the ledger and the collateral closes. PERMISSIONLESS.
    function acceptWriteOff(address) external {
        _return(_fwd(address(AceVaultFlows)));
    }

    /// @notice Drop a pending write-off. The curator or the guardian; with none pending it refuses `NothingDue`.
    function revokeWriteOff(address) external {
        _return(_fwd(address(AceVaultFlows)));
    }

    // ---- the lending doors beyond the borrow ----

    /// @notice Extend a loan of this vault's in place for its title holder, the caller, at its own tenor from now, in any mode.
    /// @notice The fee is the hub's on the time added, pulled from the holder; approve this vault for the title to renew at any time in the term.
    /// @notice Unapproved, the vault is a non-holder at the hub: it renews only in the last quarter, at or above the price and out of the band.
    /// @return The fee the hub charged.
    function extendFor(uint256, uint256, uint256, bytes calldata data, bytes calldata permit2) external returns (uint256) {
        data.length; // these compile to nothing; they keep the inputs' ABI names, as the decoder has bounds-checked each `bytes` whole
        permit2.length;
        _return(_lendingDoor());
    }

    /// @notice Refinance a loan of this vault's for its title holder, the caller, into the market the product answers, at the product's draw.
    /// @notice The caller approves this vault for the title, which it holds for this call alone; both titles and the net come home in the call.
    /// @return The successor loan.
    /// @return The net paid to the caller.
    function refinanceFor(uint256, address, uint256, uint64, uint256, uint256, uint64, uint256, address, bytes calldata data)
        external
        returns (uint256, uint256)
    {
        data.length; // decoded whole here, so the forward carries an encoding the vault checked
        _return(_lendingDoor());
    }

    /// @notice Draw more on a loan of this vault's for its title holder, the caller, in place: the same loan and term, at its market's price.
    /// @notice The product consents by its refinance answer, the loan's own market admitting the whole new debt; the caller approves this vault for the title.
    /// @return The fee the hub charged, netted from the holder's payout.
    function drawMoreFor(uint256, uint256, uint256, uint256, uint64, bytes calldata data) external returns (uint256) {
        data.length; // decoded whole here, so the forward carries an encoding the vault checked
        _return(_lendingDoor());
    }

    /// @dev The lending doors' wrapper under the lock: drain, sweep, the policy's exit gate and lendable cash as transient words, body, both zeroed, sweep.
    function _lendingDoor() private nonReentrant returns (bytes memory r) {
        if (draining()) revert Draining();
        _sweep();
        bytes32 gate = AceVaultFlows.LENDING;
        bytes32 cash = bytes32(uint256(gate) + 1);
        TransientSlot.tstore(TransientSlot.asUint256(gate), _exitsCovered() || _holdOnly() ? 1 : 0);
        TransientSlot.tstore(TransientSlot.asUint256(cash), _instantCashAt(totalAssets()));
        r = _delegate(address(AceVaultFlows));
        TransientSlot.tstore(TransientSlot.asUint256(gate), 0);
        TransientSlot.tstore(TransientSlot.asUint256(cash), 0);
        _sweep();
    }

    // ---- in kind: the claim and the tracker ----

    /// @notice Pay the caller its credit of each named token to `to`, without exiting; a call walks them in order within a bounded budget, the rest next call.
    /// @notice Name only tokens with payouts left (the lens's `unclaimedPayouts`), the most wanted first; preview one call by an `eth_call` of it.
    /// @return The units each token paid.
    function claim(address[] calldata tokens, address) external returns (uint256[] memory) {
        tokens.length; // compiles to nothing; it keeps the input's ABI name, as the decoder has bounds-checked the array whole
        _return(_fwd(address(AceVaultInKind)));
    }

    /// @notice Raw storage words of this vault at `slots`, for a lens to read the tracker without a view per figure.
    function extsload(bytes32[] calldata slots) external view returns (bytes32[] memory words) {
        words = new bytes32[](slots.length);
        for (uint256 i; i < slots.length; ++i) {
            bytes32 s = slots[i];
            bytes32 w;
            assembly ("memory-safe") {
                w := sload(s)
            }
            words[i] = w;
        }
    }

    /// @dev Name `who` in the tracker's context word for the one share move about to run, in kind only; zero clears it.
    function _context(address who) private {
        if (IN_KIND) TransientSlot.tstore(TransientSlot.asAddress(AceVaultInKind.CONTEXT), who);
    }

    /// @dev Every share move, then in kind the tracker's leg, linked code that calls no other contract; no supply bound here, so no exit can revert on it.
    function _update(address from, address to, uint256 value) internal override {
        super._update(from, to, value);
        if (IN_KIND) AceVaultInKind.moved(from, to, value);
    }

    // ---- the forwarded verbs: each named here, its body run in a linked library as this vault ----

    /// @dev This call's own calldata, run in linked library `lib` as this vault under the lock; its answer is kept in memory.
    function _fwd(address lib) private nonReentrant returns (bytes memory) {
        return _delegate(lib);
    }

    /// @dev DELEGATECALL `lib` with this call's calldata, unchanged, then the vault's packed suffix, whose words stay the vault's whatever the caller appended.
    function _delegate(address lib) private returns (bytes memory r) {
        bool ok;
        (ok, r) = lib.delegatecall(abi.encodePacked(msg.data, TAIL0, TAIL1, TAIL2, TAIL3, TAIL4));
        if (!ok) {
            assembly ("memory-safe") {
                revert(add(r, 0x20), mload(r))
            }
        }
    }

    /// @dev End the call with `r` as its raw return data.
    function _return(bytes memory r) private pure {
        assembly ("memory-safe") {
            return(add(r, 0x20), mload(r))
        }
    }

    // ---- the share token: every move takes the lock ----

    /// @notice ERC-20 transfer, under the vault's lock, so no product write call can move shares mid-verb.
    function transfer(address to, uint256 value) public override(ERC20, IERC20) nonReentrant returns (bool) {
        return super.transfer(to, value);
    }

    /// @notice ERC-20 transferFrom, under the vault's lock, as `transfer` is.
    function transferFrom(address from, address to, uint256 value) public override(ERC20, IERC20) nonReentrant returns (bool) {
        return super.transferFrom(from, to, value);
    }

    // ---- deferral: one weighted accumulator, and this contract holds the only copy of it ----

    /// @notice Value observed but not yet recognized; the live figure, decayed to this instant.
    function unvested() public view returns (uint256) {
        VaultLayout storage $ = AceVaultFlows.layout();
        return _readVest($.vestBasis, $.vestMaturity);
    }

    /// @dev What a (basis, maturity) pair reads as now, CEIL, which favours stayers on an exit and the entrant on an entry; zero once matured or burnt out.
    function _readVest(uint128 basis, uint64 maturity) internal view returns (uint256) {
        if (basis == 0 || maturity <= block.timestamp) return 0;
        return Math.mulDiv(basis, maturity - block.timestamp, VEST_WINDOW, Math.Rounding.Ceil);
    }

    /// @dev The vest a rise of `d` onto pile `u` stamps: a size-blended maturity and a FLOORED basis reading back exactly `u + d`, saturating, never reverting.
    function _grossed(uint256 u, uint256 d) internal view returns (uint128 basis, uint64 maturity) {
        maturity = AceVaultFlows.blended(u, d, AceVaultFlows.layout().vestMaturity, VEST_WINDOW);
        basis = uint128(Math.min(Math.mulDiv(u + d, VEST_WINDOW, maturity - block.timestamp), type(uint128).max));
    }

    /// @dev The basis left after a fall of `d` against a pile of `u`; FLOOR, retiring the pile's share.
    function _scaled(uint256 u, uint256 d) internal view returns (uint128) {
        if (d >= u) return 0;
        return SafeCast.toUint128(Math.mulDiv(AceVaultFlows.layout().vestBasis, u - d, u, Math.Rounding.Floor));
    }

    /// @dev Fold an observed NAV rise into the vest.
    function _stampVest(uint256 amount) internal {
        if (amount == 0) return;
        VaultLayout storage $ = AceVaultFlows.layout();
        ($.vestBasis, $.vestMaturity) = _grossed(unvested(), amount);
        emit ValueDeferred(amount);
    }

    /// @dev A NAV fall retires the vest pro rata: a gain already wiped out cannot still be pending.
    function _burnVest(uint256 amount) internal {
        uint256 u = unvested();
        if (u == 0 || amount == 0) return;
        AceVaultFlows.layout().vestBasis = _scaled(u, amount);
    }

    /// @dev The pile the next `_sync` would leave at gross `g`, through the verb's own helpers, so the view and the verb never round apart.
    function _pendingUnvested(uint256 g) internal view returns (uint256) {
        uint256 u = unvested();
        VaultLayout storage $ = AceVaultFlows.layout();
        uint256 m = $.navMark;
        if (g > m) {
            (uint128 basis, uint64 maturity) = _grossed(u, g - m);
            return _readVest(basis, maturity);
        }
        if (g < m && u != 0) return _readVest(_scaled(u, m - g), $.vestMaturity);
        return u;
    }

    /// @dev The last requester's release: the pile vests whole, and the mark takes the gross `_sync` read, which nothing since has moved.
    function _release(uint256 g) internal {
        VaultLayout storage $ = AceVaultFlows.layout();
        ($.vestBasis, $.navMark) = (0, g);
    }

    // ---- the performance fee ----

    /// @notice Collect the performance fee against the NAV the last sync observed.
    function collectFee() external nonReentrant {
        _sync();
        if (PERF_FEE_BPS != 0) _collectFeeAt(totalAssets()); // the zero-fee test is what skips the NAV read
    }

    /// @dev Mint the fee shares `_pendingFeeShares` prices at NAV `a`, then lift the high-water to `a` if `a` passes it; no live supply re-stamps at `a`.
    function _collectFeeAt(uint256 a) internal {
        if (PERF_FEE_BPS == 0) return;
        uint256 shares = _pendingFeeShares(a);
        if (shares != 0) {
            _mint(CURATOR, shares);
            emit FeeCharged(shares, a);
        }
        VaultLayout storage $ = AceVaultFlows.layout();
        uint256 h = $.feeHighWater;
        if (_live() ? a > h : a != h) $.feeHighWater = a;
    }

    /// @notice The fee shares a collection would mint now.
    function pendingFeeShares() public view returns (uint256) {
        return _pendingFeeShares(totalAssets());
    }

    /// @dev The fee shares a collection at NAV `a` mints: PERF_FEE_BPS of the rise past the high-water, priced net of the fee; none with no live supply.
    function _pendingFeeShares(uint256 a) internal view returns (uint256) {
        if (PERF_FEE_BPS == 0) return 0;
        uint256 h = AceVaultFlows.layout().feeHighWater;
        if (!_live() || a <= h) return 0;
        uint256 fee = Math.mulDiv(a - h, PERF_FEE_BPS, 10_000); // at most half of NAV, so `a - fee` never reaches zero
        return Math.mulDiv(fee, totalSupply(), a - fee);
    }
}
