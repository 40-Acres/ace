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
/// @notice An ERC-4626 vault that holds its cash and lends it on the terms its write-once product contract `TERMS` answers.
/// @notice LPs enter pro rata and exit at once from idle the exit requests do not hold; borrowers borrow, extend, top up and refinance through it.
/// @notice Entry can shut, and `maxDeposit` then reads zero; `AceVaultLens` names the gate and holds the vault's other views.
/// @dev No upgrade, and a genesis seed of dead shares; the asset must be non-fee-on-transfer, non-rebasing and hookless, as NAV counts its balance.
/// @dev Trust a vault only by `AceVaultFactory.isAceVault` on the factory a chain's book names: a subclass or a copy is other bytecode.
/// @dev Terms used below. Gross NAV is idle cash plus the vault's balance at the hub; NAV, `totalAssets`, is gross NAV less the deferred gain.
/// @dev The mark is gross NAV at the last sync, plus entries and less exits since. A rise past it vests over `VEST_WINDOW`; what still vests is the pile.
/// @dev A pot is a defaulted loan's collateral the hub settled to this vault; entry waits on an unsold one unless the guardian exempts it.
/// @dev The trough hold keeps entry shut after a material loss over an unsold pot, until the recovery that follows has vested; never in kind.
/// @dev Modes: hub-ask recovers a pot by the hub's inventory ask, door mode hands it to `DOOR` to sell, in kind pays it to the shares that bore the loss.
/// @dev A lending door is a verb that lends: `borrow` (the core door), `extendFor`, `refinanceFor` or `drawMoreFor`; `DOOR`, the door, sells seized goods.
/// @dev An exit request escrows shares for a later claim, like an ERC-7540 async redeem with no price locked; the requests' hold is idle kept for them.
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
    uint256 public constant ASK_RESERVE = AceVaultFlows.ASK_RESERVE; // gas a product read keeps back: a cold call plus the worst caller tail
    uint256 private constant VIRTUAL_SHARES = AceVaultFlows.VIRTUAL_SHARES; // resists inflation; MUST agree with _decimalsOffset()
    uint48 private constant TROUGH_MARKED = type(uint48).max; // the hold's mark: a material loss (fall, booking or drawdown) seen over an unsold pot

    address public immutable ACE;
    address public immutable CURATOR; // capital held here never blocks an LP's release, so it can lose its vesting-gain share to a last requester
    address public immutable GUARDIAN; // a second key: switches the drain on, never off, cuts caps and exempts dead pots; zero names none, never in kind
    uint16 public immutable PERF_FEE_BPS; // bps of NAV growth past the fee high-water
    uint64 public immutable VEST_WINDOW; // seconds a NAV increase takes to become spendable
    uint256 public immutable VEST_FLOOR; // one whole asset unit: a vesting gain worth less never shuts entry by the gain gate
    uint256 public immutable SEED_SHARES; // the genesis seed's shares, at par, held here since `_freeSupply` and the tracker skip this address, never moved
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
        _mintBooked(address(this), seed, seed * VIRTUAL_SHARES);
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

    /// @dev `totalAssets` at a gross the caller already read; the core door prices the requests' hold at it, off the gross its sync read.
    function _totalAssetsAt(uint256 gross) internal view returns (uint256) {
        return Math.saturatingSub(gross, _pendingUnvested(gross));
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
    function _holdsAt(uint256 nav) internal view returns (uint256 exitable, uint256 heldReq) {
        exitable = idle();
        if (AceVaultFlows.layout().draining) return (exitable, 0);
        heldReq = Math.min(exitable, _requestWorth(nav));
    }

    /// @dev The standing requests' worth at `nav`, rounded down, over the supply a quote at `nav` prices against.
    function _requestWorth(uint256 nav) internal view returns (uint256) {
        return Math.mulDiv(AceVaultFlows.layout().requestedShares, nav + 1, _quoteSupply(nav));
    }

    /// @dev THE EXIT GATE: whether idle covers the requests' worth at the last sync's NAV; storage and one balance, never a hub view.
    function _exitsCovered() internal view returns (bool) {
        VaultLayout storage $ = AceVaultFlows.layout();
        return $.requestedShares == 0 || _requestWorth(_totalAssetsAt($.navMark)) <= idle();
    }

    /// @dev What an instant exit may take at `nav`: idle less the requests' hold, all of idle while draining.
    function _instantCashAt(uint256 nav) internal view returns (uint256) {
        (uint256 exitable, uint256 heldReq) = _holdsAt(nav);
        return exitable - heldReq;
    }

    /// @dev The virtual offset backing every 4626 conversion, so inherited previews match the mints.
    function _decimalsOffset() internal pure override returns (uint8) {
        return 6;
    }

    /// @dev Observe gross NAV: a rise is stamped into the vest and a fall burns it pro rata; a new high lifts `navHigh`. FIRST in every verb that moves value.
    /// @return gross The gross NAV observed, which is also the mark this leaves.
    function _sync() internal returns (uint256 gross) {
        gross = grossNav();
        VaultLayout storage $ = AceVaultFlows.layout();
        uint256 mark = $.navMark;
        if (gross > mark) _stampVest(gross - mark);
        else if (gross < mark) _burnVest(mark - gross);
        $.navMark = gross;
        if (gross > $.navHigh) $.navHigh = gross;
        if (!IN_KIND) _markTrough(mark, gross);
    }

    /// @dev THE TROUGH HOLD, `_sync`'s leg: a material loss over an unsold pot marks; the next sync with none unsold stores a material pile's maturity, else 0.
    function _markTrough(uint256 mark, uint256 gross) private {
        VaultLayout storage $ = AceVaultFlows.layout();
        bool marked = $.troughHold == TROUGH_MARKED;
        if (!marked && !AceVaultFlows.material(_loss(mark, gross), mark)) return;
        bool unsold = _unsold();
        if (marked == unsold) return; // marked over a pot still unsold, or a loss with none unsold: nothing moves
        $.troughHold = unsold ? TROUGH_MARKED : AceVaultFlows.material(unvested(), gross) ? uint48($.vestMaturity) : 0; // a maturity is at most a week out
    }

    /// @dev The loss a sync from `mark` to `gross` weighs: the fall or the booked value a door collect left in `BOOKED`, and with either the drawdown.
    function _loss(uint256 mark, uint256 gross) private view returns (uint256 loss) {
        loss = Math.max(Math.saturatingSub(mark, gross), TransientSlot.tload(TransientSlot.asUint256(AceVaultFlows.BOOKED)));
        if (loss != 0) loss = Math.max(loss, _drawdown(gross));
    }

    /// @dev Whether the stored hold alone shuts entry, from storage, blind to a hub pot: a second to come, a material pile, no unexempted key, no gain gate.
    function _shutByHoldAlone() private view returns (bool) {
        VaultLayout storage $ = AceVaultFlows.layout();
        uint48 holdUntil = $.troughHold;
        if (holdUntil == 0 || holdUntil == TROUGH_MARKED || block.timestamp >= holdUntil || ($.openSeized != 0 && $.exemptSettled == 0)) return false;
        (uint256 deferred, uint256 mark) = (unvested(), $.navMark);
        return AceVaultFlows.material(deferred, mark) && !_vesting(deferred, Math.saturatingSub(mark, deferred));
    }

    // ---- the drawdown and the caps ----

    /// @dev The drawdown at `gross`, gross NAV's fall below its high-water: the one figure the total's room and the lens both read.
    function _drawdown(uint256 gross) private view returns (uint256) {
        return Math.saturatingSub(AceVaultFlows.layout().navHigh, gross);
    }

    /// @notice A collateral's effective cap: its row while listed, else the wildcard's.
    function effectiveCap(address collateral) public view returns (uint256) {
        return AceVaultCaps.effective(AceVaultFlows.layout(), collateral);
    }

    /// @notice Set a key's cap and list it: at or under its effective cap it lands at once, by the curator or the guardian; above it, it waits.
    /// @notice The key is a collateral, `address(0)` for the wildcard, or this vault for the total; in kind the wildcard stays zero and the asset is no key.
    function submitCap(address key, uint192 cap) external {
        key; // these compile to nothing; they keep the inputs' ABI names, as the body reads them in the library
        cap;
        _return(_fwd(address(AceVaultCaps)));
    }

    /// @notice Delist a collateral so the wildcard applies: at once unless the wildcard is above its row, else after the timelock.
    function submitDelist(address collateral) external {
        collateral; // compiles to nothing; it keeps the input's ABI name
        _return(_fwd(address(AceVaultCaps)));
    }

    /// @notice Make a key's pending change live once it has waited out the timelock. PERMISSIONLESS.
    function acceptCap(address key) external {
        key; // compiles to nothing; it keeps the input's ABI name
        _return(_fwd(address(AceVaultCaps)));
    }

    /// @notice Drop a key's pending change. The curator or the guardian.
    function revokePendingCap(address key) external {
        key; // compiles to nothing; it keeps the input's ABI name
        _return(_fwd(address(AceVaultCaps)));
    }

    // ---- the core door and the roll policy ----

    /// @notice Borrow against collateral at the product's terms: the vault opens to itself, then pays and hands title over.
    /// @notice The draw is bound to the ask, railed by the tenor bounds, and held under lendable cash, the collateral's room and the total.
    /// @param request What the borrower asks; the product's terms decide what it admits, within it.
    /// @param data The product's own payload, such as a signed quote.
    /// @param permit2 A Permit2 SignatureTransfer for the collateral, or empty to pull on allowance.
    /// @return loanId The loan, titled to the caller.
    function borrow(BorrowRequest calldata request, bytes calldata data, bytes calldata permit2) external nonReentrant returns (uint256 loanId) {
        if (draining()) revert Draining();
        uint256 gross = _sync();
        (MarketParams memory mp, Terms memory draw) = _terms(msg.sender, request, data);
        bytes32 id = AceVaultFlows.place(Ctx(asset(), MANAGER, _instantCashAt(_totalAssetsAt(gross)), _room(mp, draw.principal, gross)), mp, draw, permit2);
        IVaultTerms(TERMS).beforeLend(Lend.Borrow, mp, 0, data);
        loanId = _lend(id, mp, draw, request.minPayout, request.deadline);
        IVaultTerms(TERMS).afterLend(Lend.Borrow, mp, loanId, msg.sender, data);
        _sync();
    }

    /// @dev The product's answer for this request, then the base's checks on it: the mode, the binding to the ask and the tenor rail.
    function _terms(address borrower, BorrowRequest calldata request, bytes calldata data) private view returns (MarketParams memory mp, Terms memory draw) {
        (mp, draw) = IVaultTerms(TERMS).borrowTerms(borrower, request, data);
        draw = AceVaultCaps.admit(request, mp, draw, AceVaultCaps.hubAsk(IN_KIND, DOOR), MIN_TENOR, MAX_TENOR);
    }

    /// @dev The room for `principal` at `gross`, which must be `borrow`'s sync read: `OverTotal` past the total, else the least of the row's and the product's.
    function _room(MarketParams memory mp, uint256 principal, uint256 gross) private view returns (uint256) {
        (uint256 row, uint256 total) = AceVaultCaps.room(ACE, asset(), mp.collateral, gross - idle(), _drawdown(gross));
        if (principal > total) revert AceVaultCaps.OverTotal();
        return Math.min(row, _ask(abi.encodeCall(IVaultTerms.room, (mp))));
    }

    /// @dev The core door's hub leg, then the payout and the title to the caller.
    function _lend(bytes32 id, MarketParams memory mp, Terms memory draw, uint256 minPayout, uint64 deadline) private returns (uint256 loanId) {
        uint256 payout;
        (loanId, payout) = AceVaultFlows.lend(ACE, id, mp, draw, minPayout, deadline);
        IERC20(asset()).safeTransfer(msg.sender, payout);
        IERC721(TITLE).transferFrom(address(this), msg.sender, loanId);
    }

    /// @notice The vault is its own roll policy: it consents to one of its loans running longer exactly while it would lend there now.
    /// @notice The hub asks it for any caller, a stranger included: the exit gate binds a stranger's lengthening as it binds the holder's.
    /// @dev A plain view the hub asks under its lock, so its own legs read no hub view; the product's word is asked last, and any failure there is a no.
    /// @param ext The extension the hub asks about.
    /// @param data The caller's payload.
    /// @return The selector to consent; zero refuses.
    function admitsExtension(Extension calldata ext, bytes calldata data) external view returns (bytes4) {
        bool yes = ext.dst.lender == address(this) && !draining() && _legsOpen(ext) && (ext.newExpiry <= ext.expiry || _exitsCovered() || _shutByHoldAlone())
            && _consents(ext, data);
        return yes ? IRollPolicy.admitsExtension.selector : bytes4(0);
    }

    /// @dev The cap and rail legs of an extension: its collateral's effective cap and the total nonzero, and every tenor inside the rail.
    function _legsOpen(Extension calldata ext) private view returns (bool) {
        VaultLayout storage $ = AceVaultFlows.layout();
        MarketParams calldata dst = ext.dst;
        return AceVaultCaps.effective($, dst.collateral) != 0 && $.caps[address(this)].cap != 0 && dst.minTenor >= MIN_TENOR && dst.maxTenor <= MAX_TENOR
            && Math.saturatingSub(ext.newExpiry, block.timestamp) <= MAX_TENOR;
    }

    /// @dev The product's consent, `Probe.askBool`'s shape without its gas floor: yes only for a success returning exactly the word one.
    function _consents(Extension calldata ext, bytes calldata data) private view returns (bool) {
        return _ask(abi.encodeCall(IVaultTerms.admitsExtension, (ext, data))) == 1;
    }

    /// @dev One word from the product, any failure read as zero: `AceVaultFlows.ask` on `TERMS`, the read the refinance and top-up doors share.
    function _ask(bytes memory callData) private view returns (uint256) {
        return AceVaultFlows.ask(TERMS, callData);
    }

    // ---- the ERC-4626 entry path ----

    /// @notice The share count `deposit` mints, with the pending fee already priced in.
    function previewDeposit(uint256 assets) public view override returns (uint256) {
        uint256 nav = totalAssets();
        return Math.mulDiv(assets, _quoteSupply(nav), nav + 1, Math.Rounding.Floor);
    }

    /// @notice The assets `mint` pulls, rounded UP against the depositor.
    function previewMint(uint256 shares) public view override returns (uint256) {
        uint256 nav = totalAssets();
        return Math.mulDiv(shares, nav + 1, _quoteSupply(nav), Math.Rounding.Ceil);
    }

    /// @dev The supply a quote at `nav` prices against: the fee its verb collects first is already outstanding, plus the virtual offset.
    function _quoteSupply(uint256 nav) internal view returns (uint256) {
        return _virtualSupply() + _pendingFeeShares(nav);
    }

    /// @notice Deposit assets for shares priced pro-rata against NAV; refused while entry is shut, as `maxDeposit` reads.
    function deposit(uint256 assets, address receiver) public override nonReentrant returns (uint256 shares) {
        uint256 nav = _openEntry();
        shares = _sharesAt(assets, nav, Math.Rounding.Floor);
        _enter(receiver, assets, shares, nav);
    }

    /// @notice Mint shares for assets priced pro-rata against NAV; refused as `deposit` is.
    function mint(uint256 shares, address receiver) public override nonReentrant returns (uint256 assets) {
        uint256 nav = _openEntry();
        assets = _assetsAt(shares, nav, Math.Rounding.Ceil);
        _enter(receiver, assets, shares, nav);
    }

    /// @dev Refuses past the entry cap at `nav`, in assets for `mint` as for `deposit`; in kind also past `MAX_SUPPLY`, the fee collected first counted.
    function _enter(address receiver, uint256 assets, uint256 shares, uint256 nav) private {
        uint256 cap = _capAt(receiver, nav);
        if (assets > cap) revert ERC4626ExceededMaxDeposit(receiver, assets, cap);
        if (IN_KIND && shares > Math.saturatingSub(AceVaultInKind.MAX_SUPPLY, totalSupply())) revert OverSupply();
        _deposit(_msgSender(), receiver, assets, shares);
    }

    /// @dev OpenZeppelin's body on this vault's own pull: pull, then mint and book; the asset must be hookless, as a sender hook runs before either.
    function _deposit(address caller, address receiver, uint256 assets, uint256 shares) internal override {
        _transferIn(caller, assets);
        _mintBooked(receiver, assets, shares);
        emit Deposit(caller, receiver, assets, shares);
    }

    /// @dev Mint `shares` for `assets` already held, lifting the mark, `navHigh` and the fee high-water with the entry, so it reads as no growth.
    function _mintBooked(address receiver, uint256 assets, uint256 shares) private {
        _mint(receiver, shares);
        VaultLayout storage $ = AceVaultFlows.layout();
        if (PERF_FEE_BPS != 0) {
            (uint256 highWater, uint256 virtualSupply) = ($.feeHighWater, _virtualSupply());
            $.feeHighWater = Math.max(highWater + assets, Math.mulDiv(highWater, virtualSupply, virtualSupply - shares, Math.Rounding.Ceil));
        }
        $.navMark += assets;
        $.navHigh += assets;
    }

    /// @dev The entry cap at `nav`: zero while draining, else the product's, read by a raw static call that answers zero on any failure.
    function _capAt(address receiver, uint256 nav) private view returns (uint256) {
        return draining() ? 0 : _ask(abi.encodeCall(IVaultTerms.entryCap, (receiver, nav)));
    }

    /// @dev Entry's opening, returning the NAV it prices at: the sync, the gates, then the fee, last because in kind its mint would move the batch they read.
    function _openEntry() internal returns (uint256 nav) {
        nav = _totalAssetsAt(_sync()); // the sync moves no value, so the gross it read is still gross
        uint256 deferred = unvested();
        if (_hasLiveShares()) {
            if (nav == 0) revert EndOfLife();
            if (_vesting(deferred, nav)) revert GainVesting();
        }
        if (_unsold()) revert InventoryUnsold();
        if (_troughHeld(deferred, nav + deferred)) revert RecoveryVesting(); // past the unsold gate the sync left no mark standing
        _collectFeeAt(nav);
    }

    /// @dev Whether shares past the seed's are out: THE ONE live-supply test every zero-supply branch reads, verb and view alike.
    function _hasLiveShares() private view returns (bool) {
        return totalSupply() > SEED_SHARES;
    }

    /// @dev Whether entry waits on a pot: a hub pot or door key no exemption covers, or in kind a batch opened this block over tracked shares.
    function _unsold() internal view returns (bool) {
        if (IN_KIND && AceVaultInKind.layout().foldBlock == block.number && AceVaultInKind.layout().trackedSupply != 0) return true;
        (uint256 unsoldPots, uint256 settledPots) = _hubCounts();
        VaultLayout storage $ = AceVaultFlows.layout();
        return AceVaultFlows.unsold(unsoldPots, $.openSeized, settledPots, $.exemptSettled);
    }

    /// @dev The hub's two counts for this vault in its asset: its settled pots not yet sold, and its pots ever settled.
    function _hubCounts() private view returns (uint256 unsoldPots, uint256 settledPots) {
        return IAceLenderOps(ACE).lenderUnresolved(address(this), asset());
    }

    /// @notice ERC-4626: zero while entry is shut (spent, a gain vesting, an unsold pot or its recovery, a drain), else the cap; never reverts on the product.
    /// @notice In kind it is also no more than the cash the shares left under `MAX_SUPPLY` price at, zero at the bound.
    function maxDeposit(address receiver) public view override returns (uint256) {
        (bool shut, uint256 nav) = _entryShut();
        if (shut) return 0;
        if (!IN_KIND) return _capAt(receiver, nav);
        uint256 quoteSupply = _quoteSupply(nav);
        (bool fits, uint256 scaled) = Math.tryMul(AceVaultInKind.headroom(quoteSupply), nav + 1);
        return Math.min(fits ? scaled / quoteSupply : type(uint256).max, _capAt(receiver, nav));
    }

    /// @notice ERC-4626: `maxDeposit` in shares at the deposit preview's price; `type(uint256).max` for an uncapped vault; in kind, at most the shares left.
    /// @dev Never reverts on the product, which reads zero on any failure; where cap times the quote supply overflows it saturates, over-reporting.
    function maxMint(address receiver) public view override returns (uint256) {
        (bool shut, uint256 nav) = _entryShut();
        if (shut) return 0;
        uint256 quoteSupply = _quoteSupply(nav);
        (bool fits, uint256 scaled) = Math.tryMul(_capAt(receiver, nav), quoteSupply);
        uint256 shares = fits ? scaled / (nav + 1) : type(uint256).max;
        return IN_KIND ? Math.min(shares, AceVaultInKind.headroom(quoteSupply)) : shares;
    }

    /// @dev `_openEntry`'s gates as a view, on the pile its sync would leave; the verb collects its fee only after them, so the view reads what they read.
    /// @return shut Whether entry would refuse.
    /// @return nav The NAV entry would price at, `totalAssets` off one gross read.
    function _entryShut() internal view returns (bool shut, uint256 nav) {
        uint256 deferred;
        (nav, deferred) = _navParts();
        shut = _unsold() || _troughHeld(deferred, nav + deferred) || (_hasLiveShares() && (nav == 0 || _vesting(deferred, nav)));
    }

    /// @dev `totalAssets` and the pile the next sync would leave, off one gross read.
    function _navParts() private view returns (uint256 nav, uint256 deferred) {
        uint256 gross = grossNav();
        deferred = _pendingUnvested(gross);
        nav = Math.saturatingSub(gross, deferred);
    }

    /// @dev The trough hold over pile `deferred` at `gross`: it binds while the pile is material and its second has not come; a mark is a second never come.
    function _troughHeld(uint256 deferred, uint256 gross) private view returns (bool) {
        return AceVaultFlows.material(deferred, gross) && block.timestamp < AceVaultFlows.layout().troughHold;
    }

    /// @dev Whether a pile this large against NAV is still vesting: entry waits, so no entrant buys a recovery cheap.
    function _vesting(uint256 deferred, uint256 nav) internal view returns (bool) {
        return AceVaultFlows.gainVesting(deferred, nav, VEST_FLOOR);
    }

    /// @dev Shares for assets at a NAV the caller already read: OZ's own formula, as OZ's `_convertToShares` re-reads `totalAssets()` itself.
    function _sharesAt(uint256 assets, uint256 nav, Math.Rounding rounding) internal view returns (uint256) {
        return Math.mulDiv(assets, _virtualSupply(), nav + 1, rounding);
    }

    /// @dev Assets for shares at a NAV the caller already read; the exact inverse of `_sharesAt`.
    function _assetsAt(uint256 shares, uint256 nav, Math.Rounding rounding) internal view returns (uint256) {
        return Math.mulDiv(shares, nav + 1, _virtualSupply(), rounding);
    }

    /// @dev The supply plus the virtual offset: the frame every conversion and the fee high-water's carry price in.
    function _virtualSupply() private view returns (uint256) {
        return totalSupply() + VIRTUAL_SHARES;
    }

    // ---- the instant exit: no exit path calls the product ----

    /// @notice The shares an instant `withdraw` burns, rounded UP, priced over the supply the verb's own fee collection leaves.
    function previewWithdraw(uint256 assets) public view override returns (uint256) {
        uint256 nav = totalAssets();
        return Math.mulDiv(assets, _quoteSupply(nav), nav + 1, Math.Rounding.Ceil);
    }

    /// @notice The assets an instant `redeem` pays, rounded DOWN, at the same price.
    function previewRedeem(uint256 shares) public view override returns (uint256) {
        uint256 nav = totalAssets();
        return Math.mulDiv(shares, nav + 1, _quoteSupply(nav), Math.Rounding.Floor);
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
        (uint256 nav, uint256 deferred) = _navParts();
        uint256 quoteSupply = _quoteSupply(nav);
        uint256 bal = balanceOf(owner);
        if (owner == address(this) || (bal == _freeSupply(owner, quoteSupply - VIRTUAL_SHARES) && deferred != 0)) return (0, 0);
        return _exitBound(_instantCashAt(nav), nav, quoteSupply, bal);
    }

    /// @dev What `bal` shares may take of `cash`, in cash and in shares, at `nav` over `quoteSupply`.
    function _exitBound(uint256 cash, uint256 nav, uint256 quoteSupply, uint256 bal) private pure returns (uint256 assets, uint256 shares) {
        assets = Math.min(Math.mulDiv(bal, nav + 1, quoteSupply), cash);
        shares = Math.min(bal, Math.mulDiv(cash, quoteSupply, nav + 1));
        if (Math.mulDiv(shares, nav + 1, quoteSupply) == 0) shares = 0; // a redeem that would pay nothing is refused, so it is not offered
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
        uint256 nav = totalAssets();
        _collectFeeAt(nav);
        (assets, shares) =
            wantShares != 0 ? (_assetsAt(wantShares, nav, Math.Rounding.Floor), wantShares) : (wantAssets, _sharesAt(wantAssets, nav, Math.Rounding.Ceil));
        address by = _msgSender();
        if (by != owner) _spendAllowance(owner, by, shares);
        if (assets == 0) revert ZeroAssets(); // a redeem worth nothing is refused; a withdraw of one wei always pays
        if (shares == _freeSupply(owner, totalSupply()) && unvested() != 0) revert LastOutVesting();
        if (assets > _instantCashAt(nav)) {
            if (wantShares != 0) revert ERC4626ExceededMaxRedeem(owner, shares, maxRedeem(owner));
            revert ERC4626ExceededMaxWithdraw(owner, assets, maxWithdraw(owner));
        }
        _burn(owner, shares);
        _payExit(receiver, assets, shares, nav);
        emit Withdraw(by, receiver, owner, assets, shares);
    }

    /// @dev Book an exit of `assets` for `shares` at `nav`: the high-water scales per virtual share, never under `nav - assets`; mark and high fall by it.
    function _payExit(address receiver, uint256 assets, uint256 shares, uint256 nav) private {
        VaultLayout storage $ = AceVaultFlows.layout();
        if (PERF_FEE_BPS != 0) {
            uint256 virtualSupply = _virtualSupply();
            $.feeHighWater = Math.max(Math.mulDiv($.feeHighWater, virtualSupply, virtualSupply + shares), Math.saturatingSub(nav, assets));
        }
        $.navMark = Math.saturatingSub($.navMark, assets); // the cash leaves gross with the transfer below, so the next sync reads no fall
        $.navHigh = Math.saturatingSub($.navHigh, assets); // and the drawdown stays where it was
        IERC20(asset()).safeTransfer(receiver, assets);
    }

    /// @dev The supply free for `holder`'s last-out test and release: `supply` less shares on this vault, and for an LP every curator share, minted or pending.
    function _freeSupply(address holder, uint256 supply) private view returns (uint256 free) {
        free = supply - balanceOf(address(this));
        if (holder != CURATOR) free -= balanceOf(CURATOR) + (supply - totalSupply());
    }

    // ---- the exit request: escrowed shares whose worth the requests' hold keeps from placements ----

    /// @notice Escrow `shares` of the caller's on this vault and renew the whole request's lease, zero only renewing; idle up to its worth is then held for it.
    /// @notice NO PRICE IS LOCKED: a claim prices at its own NAV, falls passing through and gains vesting as for a free share.
    function requestExit(uint256 shares) external nonReentrant {
        _sync();
        address holder = _msgSender();
        VaultLayout storage $ = AceVaultFlows.layout();
        Request storage req = $.requests[holder];
        if (shares != 0) {
            _context(holder);
            _transfer(holder, address(this), shares);
            _context(address(0));
            req.shares += shares;
            $.requestedShares += shares;
        }
        uint64 expiresAt = uint64(block.timestamp) + REQUEST_LEASE;
        req.expiresAt = expiresAt;
        emit ExitRequested(holder, shares, expiresAt);
    }

    /// @notice Return `shares` of the caller's request to them, at any time.
    function cancelExit(uint256 shares) external nonReentrant {
        _unrequest(_msgSender(), shares);
    }

    /// @notice Return a lapsed request's whole escrow to its holder. PERMISSIONLESS once the lease has run.
    function lapseExit(address holder) external nonReentrant {
        Request memory req = AceVaultFlows.layout().requests[holder];
        if (req.shares == 0) revert NoRequest();
        if (block.timestamp < req.expiresAt) revert RequestLive();
        _unrequest(holder, req.shares);
    }

    /// @dev Hand `shares` of `holder`'s escrow back.
    function _unrequest(address holder, uint256 shares) private {
        _sync();
        VaultLayout storage $ = AceVaultFlows.layout();
        Request storage req = $.requests[holder];
        if (shares > req.shares) revert OverRequest();
        req.shares -= shares;
        $.requestedShares -= shares;
        _transfer(address(this), holder, shares);
        emit ExitReleased(holder, shares);
    }

    /// @notice The shares of `holder`'s request a claim could burn now, against idle, at the price the claim would pay.
    /// @dev It replays the release: for the last requester, every other share a donation or (for an LP) the curator's, it adds the pile back to NAV.
    function maxClaim(address holder) public view returns (uint256 shares) {
        VaultLayout storage $ = AceVaultFlows.layout();
        uint256 own = $.requests[holder].shares;
        (uint256 nav, uint256 deferred) = _navParts();
        if (own == $.requestedShares && _freeSupply(holder, totalSupply()) == 0) nav += deferred;
        (, shares) = _exitBound(idle(), nav, _quoteSupply(nav), own);
    }

    /// @notice Burn `shares` of the caller's request and pay their worth to `receiver` from idle, first come, at its NAV rounded down, at least `minAssets`.
    /// @dev The last requester releases the pile BEFORE the fee, so the fee is charged on it; any other claim leaves its share of the pile to the stayers.
    function claimExit(uint256 shares, address receiver, uint256 minAssets) external nonReentrant returns (uint256 assets) {
        uint256 gross = _sync();
        address holder = _msgSender();
        VaultLayout storage $ = AceVaultFlows.layout();
        Request storage req = $.requests[holder];
        if (shares > req.shares) revert OverRequest();
        if (req.shares == $.requestedShares && _freeSupply(holder, totalSupply()) == 0) _release(gross);
        uint256 nav = totalAssets();
        _collectFeeAt(nav);
        assets = _assetsAt(shares, nav, Math.Rounding.Floor);
        if (assets == 0) revert ZeroAssets();
        if (assets < minAssets) revert ClaimUnderMin();
        if (assets > idle()) revert ERC4626ExceededMaxRedeem(holder, shares, maxClaim(holder));
        req.shares -= shares;
        $.requestedShares -= shares;
        _context(holder);
        _burn(address(this), shares);
        _context(address(0));
        _payExit(receiver, assets, shares, nav);
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
        (uint256 unsoldPots, uint256 settledPots) = _hubCounts();
        if (settledPots != expectedSettled) revert PotsMoved(settledPots);
        VaultLayout storage $ = AceVaultFlows.layout();
        uint256 mark = $.navMark;
        if (!IN_KIND && AceVaultFlows.unsold(unsoldPots, $.openSeized, settledPots, $.exemptSettled) && AceVaultFlows.material(_loss(mark, grossNav()), mark)) {
            $.troughHold = TROUGH_MARKED; // `_markTrough`'s mark rule (keep the two equal), never its clear: a sync clears over the pile it just stamped
        }
        $.exemptSettled = settledPots;
        emit DeadPotsExempted(unsoldPots, settledPots);
    }

    // ---- the permissionless crank: it moves cash and prices nothing ----

    /// @notice Collect everything the hub has credited this vault, every market at once, into idle; NAV-neutral. PERMISSIONLESS.
    function crank() external nonReentrant {
        _sweep();
    }

    /// @dev The crank's body, which the collect, the door's return and the other lending doors also close with.
    function _sweep() private {
        _sync();
        uint256 paid = IAceLenderOps(ACE).collect(asset(), address(this)); // this vault's own pool, to this vault
        if (paid != 0) emit Collected(paid);
        _collectFeeAt(totalAssets());
    }

    // ---- the collect: in kind, or to the door ----

    /// @notice End each named loan of this vault's and take its pot: in kind to this vault, PERMISSIONLESS; in door mode to the door, THE DOOR ONLY.
    /// @notice A repaid or already-collected id yields zero and the batch goes on; one neither expired nor settleable on distress reverts the whole batch.
    /// @return units The units each id handed over.
    function collectForfeited(uint256[] calldata loanIds) external returns (uint256[] memory units) {
        loanIds.length; // compiles to nothing; it keeps the input's ABI name, as the decoder has bounds-checked the array whole
        _return(_collect());
    }

    /// @dev The collect under the lock: a sync sees the settle's NAV fall, the mode's body runs, the sweep takes the hub's credit, the booked word clears.
    function _collect() private nonReentrant returns (bytes memory ret) {
        address lib = address(AceVaultInKind);
        if (!IN_KIND) {
            if (DOOR == address(0)) revert ModeUnbuilt();
            if (msg.sender != DOOR) revert IAceVaultDoor.NotDoor();
            lib = address(AceVaultFlows);
        }
        _sync();
        ret = _delegate(lib);
        _sweep();
        TransientSlot.tstore(TransientSlot.asUint256(AceVaultFlows.BOOKED), 0);
    }

    // ---- door mode: the return and the write-off ----

    /// @notice Take a sale's cash from the door against a seized collateral, and close it from the entry gate if `closes`. THE DOOR ONLY.
    /// @notice Any key takes cash; only `(collateral, 0, false)` refuses. The cash vests, and lowers the drawdown one for one.
    function returnProceeds(address collateral, uint256 cash, bool closes) external {
        collateral; // these compile to nothing; they keep the inputs' ABI names, as the body reads them in the library
        cash;
        closes;
        _return(_proceeds());
    }

    /// @dev The return under the lock: a sync before, the body, a sweep after.
    function _proceeds() private nonReentrant returns (bytes memory ret) {
        if (msg.sender != DOOR) revert IAceVaultDoor.NotDoor();
        _sync();
        ret = _delegate(address(AceVaultFlows));
        _sweep();
    }

    /// @notice Queue a write-off of a seized collateral's residue, due after `CAP_TIMELOCK`. CURATOR ONLY; a collect onto it voids it.
    /// @notice For goods the door cannot sell: accepting it lifts the door's gate over what is left, unasked; a material fall over them still holds entry.
    function submitWriteOff(address collateral) external {
        collateral; // compiles to nothing; it keeps the input's ABI name
        _return(_fwd(address(AceVaultFlows)));
    }

    /// @notice Land a write-off that has waited out the timelock: the residue leaves the ledger and the collateral closes. PERMISSIONLESS.
    function acceptWriteOff(address collateral) external {
        collateral; // compiles to nothing; it keeps the input's ABI name
        _return(_fwd(address(AceVaultFlows)));
    }

    /// @notice Drop a pending write-off. The curator or the guardian; with none pending it refuses `NothingDue`.
    function revokeWriteOff(address collateral) external {
        collateral; // compiles to nothing; it keeps the input's ABI name
        _return(_fwd(address(AceVaultFlows)));
    }

    // ---- the lending doors beyond the borrow ----

    /// @notice Extend a loan of this vault's in place for its title holder, the caller, at its own tenor from now, in any mode.
    /// @notice The fee is the hub's on the time added, pulled from the holder; approve this vault for the title to renew at any time in the term.
    /// @notice Unapproved, the vault is a non-holder at the hub: it renews only in the last quarter, at or above the price and out of the band.
    /// @return fee The fee the hub charged.
    function extendFor(uint256 loanId, uint256 maxFee, uint256 minBufferWad, bytes calldata data, bytes calldata permit2) external returns (uint256 fee) {
        loanId; // these compile to nothing; they keep the inputs' ABI names, as the decoder has bounds-checked each `bytes` whole
        maxFee;
        minBufferWad;
        data.length;
        permit2.length;
        _return(_lendingDoor());
    }

    /// @notice Refinance a loan of this vault's for its title holder, the caller, into the market the product answers, at the product's draw.
    /// @notice The caller approves this vault for the title, which it holds for this call alone; both titles and the net come home in the call.
    /// @return newId The successor loan.
    /// @return out The net paid to the caller.
    function refinanceFor(
        uint256 loanId,
        address collateral,
        uint256 principal,
        uint64 tenor,
        uint256 minPayout,
        uint256 minBufferWad,
        uint64 deadline,
        uint256 withdrawUnits,
        address withdrawTo,
        bytes calldata data
    ) external returns (uint256 newId, uint256 out) {
        loanId; // these compile to nothing; they keep the inputs' ABI names
        collateral;
        principal;
        tenor;
        minPayout;
        minBufferWad;
        deadline;
        withdrawUnits;
        withdrawTo;
        data.length; // decoded whole here, so the forward carries an encoding the vault checked
        _return(_lendingDoor());
    }

    /// @notice Draw more on a loan of this vault's for its title holder, the caller, in place: the same loan and term, at its market's price.
    /// @notice The product consents by its refinance answer, the loan's own market admitting the whole new debt; the caller approves this vault for the title.
    /// @return fee The fee the hub charged, netted from the holder's payout.
    function drawMoreFor(uint256 loanId, uint256 amount, uint256 minPayout, uint256 minBufferWad, uint64 deadline, bytes calldata data)
        external
        returns (uint256 fee)
    {
        loanId; // these compile to nothing; they keep the inputs' ABI names
        amount;
        minPayout;
        minBufferWad;
        deadline;
        data.length; // decoded whole here, so the forward carries an encoding the vault checked
        _return(_lendingDoor());
    }

    /// @dev The other lending doors' wrapper under the lock: drain, sweep, the exit gate and lendable cash as transient words, body, both zeroed, sweep.
    function _lendingDoor() private nonReentrant returns (bytes memory ret) {
        if (draining()) revert Draining();
        _sweep();
        bytes32 gate = AceVaultFlows.LENDING;
        bytes32 cash = bytes32(uint256(gate) + 1);
        TransientSlot.tstore(TransientSlot.asUint256(gate), _exitsCovered() || _shutByHoldAlone() ? 1 : 0);
        TransientSlot.tstore(TransientSlot.asUint256(cash), _instantCashAt(totalAssets()));
        ret = _delegate(address(AceVaultFlows));
        TransientSlot.tstore(TransientSlot.asUint256(gate), 0);
        TransientSlot.tstore(TransientSlot.asUint256(cash), 0);
        _sweep();
    }

    // ---- in kind: the claim and the tracker ----

    /// @notice Pay the caller its credit of each named token to `to`, without exiting; a call walks them in order within a bounded budget, the rest next call.
    /// @notice Name only tokens with payouts left (the lens's `unclaimedPayouts`), the most wanted first; preview one call by an `eth_call` of it.
    /// @return paid The units each token paid.
    function claim(address[] calldata tokens, address to) external returns (uint256[] memory paid) {
        tokens.length; // these compile to nothing; they keep the inputs' ABI names, as the decoder has bounds-checked the array whole
        to;
        _return(_fwd(address(AceVaultInKind)));
    }

    /// @notice Raw storage words of this vault at `slots`, for a lens to read the tracker without a view per figure.
    function extsload(bytes32[] calldata slots) external view returns (bytes32[] memory words) {
        words = new bytes32[](slots.length);
        for (uint256 i; i < slots.length; ++i) {
            bytes32 slot = slots[i];
            bytes32 word;
            assembly ("memory-safe") {
                word := sload(slot)
            }
            words[i] = word;
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
    function _delegate(address lib) private returns (bytes memory ret) {
        bool ok;
        (ok, ret) = lib.delegatecall(abi.encodePacked(msg.data, TAIL0, TAIL1, TAIL2, TAIL3, TAIL4));
        if (!ok) {
            assembly ("memory-safe") {
                revert(add(ret, 0x20), mload(ret))
            }
        }
    }

    /// @dev End the call with `ret` as its raw return data.
    function _return(bytes memory ret) private pure {
        assembly ("memory-safe") {
            return(add(ret, 0x20), mload(ret))
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

    /// @dev The vest a `rise` onto pile `deferred` stamps: a size-blended maturity and a FLOORED basis reading back exactly the sum; saturates, never reverts.
    function _grossed(uint256 deferred, uint256 rise) internal view returns (uint128 basis, uint64 maturity) {
        maturity = AceVaultFlows.blended(deferred, rise, AceVaultFlows.layout().vestMaturity, VEST_WINDOW);
        basis = uint128(Math.min(Math.mulDiv(deferred + rise, VEST_WINDOW, maturity - block.timestamp), type(uint128).max));
    }

    /// @dev The basis left after a `fall` against pile `deferred`; FLOOR, retiring the pile's share.
    function _scaled(uint256 deferred, uint256 fall) internal view returns (uint128) {
        if (fall >= deferred) return 0;
        return SafeCast.toUint128(Math.mulDiv(AceVaultFlows.layout().vestBasis, deferred - fall, deferred, Math.Rounding.Floor));
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
        uint256 deferred = unvested();
        if (deferred == 0 || amount == 0) return;
        AceVaultFlows.layout().vestBasis = _scaled(deferred, amount);
    }

    /// @dev The pile the next `_sync` would leave at `gross`, through the verb's own helpers, so the view and the verb never round apart.
    function _pendingUnvested(uint256 gross) internal view returns (uint256) {
        uint256 deferred = unvested();
        VaultLayout storage $ = AceVaultFlows.layout();
        uint256 mark = $.navMark;
        if (gross > mark) {
            (uint128 basis, uint64 maturity) = _grossed(deferred, gross - mark);
            return _readVest(basis, maturity);
        }
        if (gross < mark && deferred != 0) return _readVest(_scaled(deferred, mark - gross), $.vestMaturity);
        return deferred;
    }

    /// @dev The last requester's release: the pile vests whole, and the mark takes the gross `_sync` read, which nothing since has moved.
    function _release(uint256 gross) internal {
        VaultLayout storage $ = AceVaultFlows.layout();
        ($.vestBasis, $.navMark) = (0, gross);
    }

    // ---- the performance fee ----

    /// @notice Collect the performance fee against the NAV the last sync observed.
    function collectFee() external nonReentrant {
        _sync();
        if (PERF_FEE_BPS != 0) _collectFeeAt(totalAssets()); // the zero-fee test is what skips the NAV read
    }

    /// @dev Mint the fee shares `_pendingFeeShares` prices at `nav`, then lift the high-water to `nav` if it passes; no live supply re-stamps at `nav`.
    function _collectFeeAt(uint256 nav) internal {
        if (PERF_FEE_BPS == 0) return;
        uint256 shares = _pendingFeeShares(nav);
        if (shares != 0) {
            _mint(CURATOR, shares);
            emit FeeCharged(shares, nav);
        }
        VaultLayout storage $ = AceVaultFlows.layout();
        uint256 highWater = $.feeHighWater;
        if (_hasLiveShares() ? nav > highWater : nav != highWater) $.feeHighWater = nav;
    }

    /// @notice The fee shares a collection would mint now.
    function pendingFeeShares() public view returns (uint256) {
        return _pendingFeeShares(totalAssets());
    }

    /// @dev The fee shares a collection at `nav` mints: PERF_FEE_BPS of the rise past the high-water, priced net of the fee; none with no live supply.
    function _pendingFeeShares(uint256 nav) internal view returns (uint256) {
        if (PERF_FEE_BPS == 0) return 0;
        uint256 highWater = AceVaultFlows.layout().feeHighWater;
        if (!_hasLiveShares() || nav <= highWater) return 0;
        uint256 fee = Math.mulDiv(nav - highWater, PERF_FEE_BPS, 10_000); // at most half of NAV, so `nav - fee` never reaches zero
        return Math.mulDiv(fee, totalSupply(), nav - fee);
    }
}
