// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.36;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {IERC721} from "@openzeppelin/contracts/token/ERC721/IERC721.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {SafeCast} from "@openzeppelin/contracts/utils/math/SafeCast.sol";
import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import {ERC4626} from "@openzeppelin/contracts/token/ERC20/extensions/ERC4626.sol";
import {Math} from "@openzeppelin/contracts/utils/math/Math.sol";
import {Address} from "@openzeppelin/contracts/utils/Address.sol";
import {ReentrancyGuardTransient} from "@openzeppelin/contracts/utils/ReentrancyGuardTransient.sol";
import {MarketParams} from "../ace/hub/Types.sol";
import {IAceLenderOps} from "../interfaces/IAceLenderOps.sol";
import {AceVaultFlows, BorrowRequest, Ctx, Request, Terms, VaultLayout} from "./AceVaultFlows.sol";

/// @notice Everything a deploy fixes about one vault: EVERY FIELD IS WRITE-ONCE, with no setter, no pause and no upgrade.
/// @notice `perfFeeBps`: bps of NAV GROWTH past a high-water mark, at most `MAX_PERF_FEE_BPS`, minted as shares; zero charges nothing.
/// @notice `vestWindow`: how long a NAV rise takes to become spendable; railed at both ends, as too short a window opens a repayment sandwich.
/// @notice `guardian`: a second key that may switch the drain ON and never off, and exempt dead pots and goods from the entry gate; zero names none.
struct VaultConfig {
    address ace;
    address asset;
    address curator;
    address guardian;
    uint16 perfFeeBps;
    uint64 vestWindow;
}

/// @title AceVault
/// @notice An ERC-4626 that HOLDS ITS CASH and lends it through one priced door, into markets that name it as their one lender.
/// @notice NAV is the asset balance plus what the hub holds for this vault in that asset, less the unvested pile; it reads no price.
/// @notice THE DOOR rests all idle, opens the loan to the vault, arms if the product's terms do, withdraws every resting unit, then pays and hands title over.
/// @notice NOTHING RESTS ACROSS A CALL: a market's cash is zero between calls, and its armed loans' reservations stand on paper only.
/// @notice SO A ROLL DRAWING CASH RUNS ONLY THROUGH `roll`: it rests the cover, rolls by policy and withdraws every unit, while the vault lends at the price.
/// @notice TWO HOLDS: the roll hold, idle no exit may take, and the requests' hold, exitable cash no placement may take.
/// @notice ENTRY is pro-rata; it shuts at zero NAV with shares out, while a gain over GATE_BPS vests, and while a settled pot or seized goods are unsold.
/// @notice EXIT IS INSTANT from exitable cash the requests do not hold; `claimExit` pays a request from exitable cash, first come, at the claim's own price.
/// @notice While a gain vests the last free holder requests instead of exiting; for an LP, the curator's shares do not count as free.
/// @notice THE DRAIN stops lending: no placement, no promised successor, entry shut; exits take all of exitable first come; the roll hold stays.
/// @notice NO upgrade: every address, the fee and the vest window fix at deploy.
/// @dev The asset must be non-fee-on-transfer, non-rebasing and hookless: NAV counts its balance, and a deposit pulls before it books.
/// @dev A raw landing of the asset is a COUNTED DONATION: it vests, can refuse the last free holder's instant exit, and can shut entry for the vest.
/// @dev The hub is held as `IAceLenderOps`, so `redeemInKind` and `multicall` are out of reach; a product taking forfeits in kind declares a wider handle.
/// @dev Capital held at `CURATOR` never blocks an LP's release, so it can lose its share of a vesting gain to a last requester: seed from another address.
/// @dev PRODUCT HOOKS over the door and roll: `_borrowTerms`, `_priceAdmits`, `_rollAdmits`, `_room`, `_prime`, `_unprime`, `_afterBorrow`, `_afterRoll`.
/// @dev PRODUCT HOOKS over entry and doors: `_entryCap`, `_holdsSeized`, `_exemptDeadPots`, `_setDrain`, `door`, `lends` and `_delegate`.
abstract contract AceVault is ERC4626, ReentrancyGuardTransient {
    using SafeERC20 for IERC20;

    error NotCurator();
    error ZeroCurator(); // a zero curator reverts every fee mint; the vault itself as curator would count its escrow out of an LP's free twice
    error HubHasNoCode(); // the hub is write-once, so a vault pointed at nothing could never be repaired
    error PerfFeeOutOfBounds();
    error VestWindowOutOfBounds(); // a window too short to defer defeats the deferral as fully as zero; both ends railed
    error ZeroAssets(); // an exit or a claim that prices to nothing
    error EndOfLife(); // NAV is zero while shares are live: spent, and it takes no new capital
    error GainVesting(); // entry waits while a gain over GATE_BPS of NAV and one asset unit vests
    error DoorBroke(); // a product door ran without the vault's guard held
    error LastOutVesting(); // the last free holder (for an LP, the curator not counted) would leave a vesting gain: request, and the last claim releases it
    error Draining(); // lending is stopped: no placement opens
    error RequestLive(); // a request lapses only once its lease has run
    error NoRequest(); // there is no request to lapse
    error OverRequest(); // asked past the caller's request
    error ClaimUnderMin(); // the claim pays less than the caller's minimum
    error InventoryUnsold(); // a settled pot or a held seizure of this vault's has not sold: entry waits for the sale
    error NotGuardian(); // only the guardian exempts a dead pot, and a vault with none has no override
    error PotsMoved(uint256 settledPots); // a pot settled since the guardian read the count: re-read and resubmit
    error NotOurLoan(); // the loan's market does not name this vault as its one lender
    error RollUnfunded(); // the vault never promised this loan's roll, or already ran it
    error NotLending(); // the vault would no longer lend at this loan's price, so it does not roll it

    uint16 public constant MAX_PERF_FEE_BPS = 5000; // < 10000 is load-bearing: at 100% a zero high-water makes the fee all of NAV, and the mint divides by zero
    uint64 public constant REQUEST_LEASE = 30 days; // a request lapses this long after it was last made or renewed
    uint64 public constant MIN_VEST_WINDOW = 1 hours; // below this a gain matures before an entrant has held any risk
    uint64 public constant MAX_VEST_WINDOW = 7 days; // the longest a NAV rise may defer before it is spendable
    uint16 public constant GATE_BPS = 500; // entry shuts while a gain over this share of NAV vests
    uint256 private constant VIRTUAL_SHARES = 1e6; // resists inflation; MUST agree with _decimalsOffset()

    address public immutable ACE;
    address public immutable CURATOR;
    address public immutable GUARDIAN; // a second key: switches the drain on, never off, and exempts dead pots and goods; zero names none
    uint16 public immutable PERF_FEE_BPS; // bps of NAV growth past the fee high-water
    uint64 public immutable VEST_WINDOW; // seconds a NAV increase takes to become spendable
    uint256 public immutable VEST_FLOOR; // one whole asset unit: a pile worth less never shuts entry, so rounding cannot
    address internal immutable MANAGER; // the hub's custodian, approved for exactly each pledge
    address internal immutable TITLE; // the hub's loan-title collection, handed over by `transferFrom`

    /// @notice Emitted once, at construction; there is no registry, so this event is the whole of vault discovery.
    event VaultDeployed(address indexed curator, address indexed asset);
    event Collected(uint256 amount);
    event FeeCharged(uint256 shares, uint256 highWater);
    event ValueDeferred(uint256 amount);
    /// @notice A holder escrowed `shares` more, zero for a renewal, and the whole request now lapses at `expiresAt`.
    event ExitRequested(address indexed holder, uint256 shares, uint64 expiresAt);
    /// @notice `shares` of a request went back to its holder, by a cancel or a lapse.
    event ExitReleased(address indexed holder, uint256 shares);
    /// @notice The drain moved.
    event DrainSet(address indexed by, bool on);
    /// @notice The guardian exempted the pots and goods standing at these hub counts from the entry gate, until the next settlement.
    event DeadPotsExempted(uint256 unsold, uint256 settled);

    constructor(VaultConfig memory cfg, string memory name_, string memory symbol_) ERC20(name_, symbol_) ERC4626(IERC20(cfg.asset)) {
        if (cfg.curator == address(0) || cfg.curator == address(this)) revert ZeroCurator();
        if (cfg.perfFeeBps > MAX_PERF_FEE_BPS) revert PerfFeeOutOfBounds();
        if (cfg.vestWindow < MIN_VEST_WINDOW || cfg.vestWindow > MAX_VEST_WINDOW) revert VestWindowOutOfBounds();
        if (cfg.ace.code.length == 0) revert HubHasNoCode();
        ACE = cfg.ace;
        MANAGER = IAceLenderOps(cfg.ace).POSITION_MANAGER();
        TITLE = IAceLenderOps(cfg.ace).POSITION_TITLE();
        CURATOR = cfg.curator;
        GUARDIAN = cfg.guardian;
        PERF_FEE_BPS = cfg.perfFeeBps;
        VEST_WINDOW = cfg.vestWindow;
        VEST_FLOOR = uint256(10) ** (decimals() - _decimalsOffset());
        emit VaultDeployed(cfg.curator, cfg.asset);
    }

    // ---- the state at the root ----

    /// @notice The fee threshold in assets: a collection lifts it to NAV, an entry adds its cash, an exit or a claim takes its cash.
    function feeHighWater() public view returns (uint256) {
        return AceVaultFlows.layout().feeHighWater;
    }

    /// @notice Escrowed shares of every standing request.
    function requestedShares() external view returns (uint256) {
        return AceVaultFlows.layout().requestedShares;
    }

    /// @notice A holder's standing request: its escrowed shares, and when anyone may lapse it.
    function requestOf(address holder) external view returns (uint256 shares, uint64 expiresAt) {
        Request memory r = AceVaultFlows.layout().requests[holder];
        return (r.shares, r.expiresAt);
    }

    /// @notice Whether lending is stopped: no placement, no promised successor, and entry shut.
    function draining() public view returns (bool) {
        return AceVaultFlows.layout().draining;
    }

    /// @notice A loan's recorded reservation: an upper bound on its roll need, and whether the vault promised to fund that roll.
    function rollOf(uint256 loanId) external view returns (uint128 need, bool funded) {
        return (AceVaultFlows.layout().rollOf[loanId].need, AceVaultFlows.layout().rollOf[loanId].funded);
    }

    /// @notice The exact sum of every recorded reservation; an entry leaves at the vault's roll, at a product's forfeit door, or by `crank(closed)`.
    function rollHold() external view returns (uint256) {
        return AceVaultFlows.layout().rollHold;
    }

    // ---- valuation and the holds ----

    /// @notice Gross NAV less the unvested pile: a fall passes through at once and a rise vests, so a sync never moves it.
    /// @dev An override MAY lower it and MUST NOT add value: a rise counted outside `grossNav` would skip the vest.
    function totalAssets() public view virtual override returns (uint256) {
        return _totalAssetsAt(grossNav());
    }

    /// @dev `totalAssets` at a gross the caller already read; not virtual, so always the base's own figure.
    /// @dev The door and the roll price the requests' hold at it, off the gross their sync read: neither prices a share.
    function _totalAssetsAt(uint256 g) internal view returns (uint256) {
        return Math.saturatingSub(g, _pendingUnvested(g));
    }

    /// @notice NAV before deferral: the asset balance plus the hub's (vault, asset) pool, resting, lent and owed.
    /// @dev Two reads at any market count, the hub's refusing mid-hub-body; a payout naming this vault is a counted donation.
    function grossNav() public view returns (uint256) {
        return idle() + IAceLenderOps(ACE).lenderAssets(address(this), asset());
    }

    /// @notice The asset the vault holds: every unit an exit, a claim, a placement or a roll's cover can reach, held cash included.
    function idle() public view returns (uint256) {
        return IERC20(asset()).balanceOf(address(this));
    }

    /// @notice The roll hold: zero on an empty book, else three times the recorded sum plus the largest minDebt booked since the book was last empty.
    /// @dev That minDebt term only rises while any record stands and resets when the sum reaches zero, so it may over-hold, never under-hold.
    function rollHoldNow() public view returns (uint256) {
        VaultLayout storage $ = AceVaultFlows.layout();
        return AceVaultFlows.holdNow($.rollHold, $.rollFloor);
    }

    /// @notice What a placement may take: idle past the roll hold, less what the standing requests hold; nothing while draining.
    function lendable() public view returns (uint256) {
        return draining() ? 0 : _instantCashAt(totalAssets());
    }

    /// @notice Idle past the roll hold, and the part of it the standing requests hold at their worth now; they hold nothing while draining.
    /// @return exitable What a claim may take.
    /// @return heldReq What instant exits and placements leave for the requests.
    function holds() public view returns (uint256 exitable, uint256 heldReq) {
        return _holdsAt(totalAssets());
    }

    /// @dev `holds` at a NAV the caller already read, so a verb prices the requests' hold without reading the hub again.
    function _holdsAt(uint256 a) internal view returns (uint256 exitable, uint256 heldReq) {
        exitable = _exitable();
        VaultLayout storage $ = AceVaultFlows.layout();
        if ($.draining) return (exitable, 0);
        heldReq = Math.min(exitable, Math.mulDiv($.requestedShares, a + 1, _quoteSupply(a)));
    }

    /// @dev Idle past the roll hold: what a claim may take, which no NAV moves.
    function _exitable() internal view returns (uint256) {
        return Math.saturatingSub(idle(), rollHoldNow());
    }

    /// @dev What an instant exit may take at NAV `a`: exitable less the requests' hold, all of exitable while draining.
    function _instantCashAt(uint256 a) internal view returns (uint256) {
        (uint256 exitable, uint256 heldReq) = _holdsAt(a);
        return exitable - heldReq;
    }

    /// @dev The virtual offset backing every 4626 conversion, so inherited previews match the mints.
    function _decimalsOffset() internal pure override returns (uint8) {
        return 6;
    }

    /// @dev Observe gross NAV: a rise is stamped into the vest and a fall burns it pro rata. FIRST in every verb that reads NAV or moves value.
    /// @dev A stamp is capped at the gross it observed, so the pile this leaves never reads past the mark and `totalAssets` never floors a hole.
    /// @return g The gross NAV observed, which is also the mark this leaves.
    function _sync() internal returns (uint256 g) {
        g = grossNav();
        VaultLayout storage $ = AceVaultFlows.layout();
        uint256 m = $.navMark;
        if (g > m) {
            _stampVest(g - m);
            _capVest(g);
        } else if (g < m) {
            _burnVest(m - g);
        }
        $.navMark = g;
    }

    /// @dev Where a stamp's two ceilings left the pile past `g`, cut the basis to `floor(g * VEST_WINDOW / (maturity - now))`, which reads back exactly `g`.
    /// @dev It binds only where the pile was the whole mark, NAV zero; elsewhere a stamp's extra wei still sits within gross.
    function _capVest(uint256 g) internal {
        VaultLayout storage $ = AceVaultFlows.layout();
        uint64 maturity = $.vestMaturity;
        if (_readVest($.vestBasis, maturity) > g) $.vestBasis = SafeCast.toUint128(Math.mulDiv(g, VEST_WINDOW, maturity - block.timestamp));
    }

    // ---- the product hooks ----

    /// @notice Product hook: the market a borrow lands in and the draw admitted, from the request and the product's payload; refuses by revert.
    /// @notice A VIEW: it holds no cash authority, and the core checks the market is this vault's, in its asset, at a zero settle bounty.
    function _borrowTerms(BorrowRequest calldata r, bytes calldata data) internal view virtual returns (MarketParams memory mp, Terms memory t);

    /// @notice Product hook: whether the vault would still lend at this market's price, which gates the CURRENT roll; none by default.
    function _priceAdmits(MarketParams memory, uint256, bytes calldata) internal view virtual returns (bool) {
        return false;
    }

    /// @notice Product hook: whether the curator's legs admit funding a successor's next roll; none by default.
    function _rollAdmits(MarketParams memory) internal view virtual returns (bool) {
        return false;
    }

    /// @notice Product hook: the room a placement against this market's collateral has under the product's cap; no cap by default.
    function _room(MarketParams memory) internal view virtual returns (uint256) {
        return type(uint256).max;
    }

    /// @notice Product hook: write what the product's own record needs right before the first hub call; it moves no cash.
    function _prime(MarketParams memory, uint256, bytes calldata) internal virtual {}

    /// @notice Product hook: clear what `_prime` wrote, right after the last hub call and before any other call.
    function _unprime(MarketParams memory) internal virtual {}

    /// @notice Product hook: the door's last step, after the title is handed over; it holds no cash authority.
    function _afterBorrow(uint256, BorrowRequest calldata) internal virtual {}

    /// @notice Product hook: the roll's last step, after every unit came home; it holds no cash authority.
    function _afterRoll(MarketParams memory, uint256, uint256) internal virtual {}

    /// @dev The cap entry reads: zero while draining, else the product's own.
    function _cap(address receiver) private view returns (uint256) {
        return draining() ? 0 : _entryCap(receiver);
    }

    /// @notice Product hook: the most a deposit for a receiver may bring now, in assets; `type(uint256).max` caps nothing.
    /// @notice MAY tighten entry by any view of the product's state; MUST NOT read `totalSupply()` or a share balance, which the fee moves first.
    function _entryCap(address) internal view virtual returns (uint256) {
        return type(uint256).max;
    }

    /// @notice Product hook: whether the product holds seized goods it has not sold; entry waits while it does, unless the guardian exempted them.
    /// @notice A product taking forfeits in kind MUST answer its own count, and only from goods `redeemInKind` brought home: the hub stops counting them.
    function _holdsSeized() internal view virtual returns (bool) {
        return false;
    }

    /// @notice Product hook: bracket a product's forfeit, sale or exit door, after `nonReentrant`.
    /// @notice It opens with a sync and closes by collecting the hub's credit into idle.
    /// @notice MUST NOT mint, burn or move shares, write `VaultLayout` save through `AceVaultFlows.endLoan`, or sit on an internal function.
    /// @dev BASE CHECK, else `DoorBroke`: the guard is held; a malicious body is not sandboxed.
    modifier door() {
        if (!_reentrancyGuardEntered()) revert DoorBroke();
        _sync();
        _;
        _sweepCredit();
    }

    /// @notice Product hook: mark a verb that lends; it refuses `Draining()` while the drain stands.
    modifier lends() {
        if (draining()) revert Draining();
        _;
    }

    /// @notice Product hook: one DELEGATECALL into a door library, returning its answer and bubbling its revert; an empty revert is `FailedCall()`.
    /// @notice `lib` MUST be a linked-library constant: whatever it names runs with this vault's storage, balances and approvals.
    /// @dev OpenZeppelin `Address.functionDelegateCall`, unchanged.
    function _delegate(address lib, bytes memory data) internal returns (bytes memory) {
        return Address.functionDelegateCall(lib, data);
    }

    // ---- the door and the roll ----

    /// @notice Borrow against collateral at the product's terms: the vault opens to itself, arms where the terms do, then pays and hands title over.
    /// @param r What the borrower asks; the product's `_borrowTerms` decides what it admits.
    /// @param data The product's own payload, such as a signed quote.
    /// @param permit2 A Permit2 SignatureTransfer for the collateral, or empty to pull on allowance.
    /// @return loanId The loan, titled to the caller.
    function borrow(BorrowRequest calldata r, bytes calldata data, bytes calldata permit2) external nonReentrant lends returns (uint256 loanId) {
        uint256 g = _sync();
        (MarketParams memory mp, Terms memory t) = _borrowTerms(r, data);
        bytes32 id = AceVaultFlows.place(Ctx(ACE, asset(), MANAGER, false, _instantCashAt(_totalAssetsAt(g)), _room(mp)), mp, t, permit2);
        _prime(mp, 0, data);
        loanId = _lend(id, mp, t, r.minPayout, r.deadline);
        _afterBorrow(loanId, r);
        _sync();
    }

    /// @dev The door's hub leg, then `_unprime` before any other call, then the payout and the title to the caller.
    function _lend(bytes32 id, MarketParams memory mp, Terms memory t, uint256 minPayout, uint64 deadline) private returns (uint256 loanId) {
        uint256 payout;
        (loanId, payout) = AceVaultFlows.lend(ACE, id, mp, t, minPayout, deadline);
        _unprime(mp);
        IERC20(asset()).safeTransfer(msg.sender, payout);
        IERC721(TITLE).transferFrom(address(this), msg.sender, loanId);
    }

    /// @notice Roll a loan whose roll the vault promised: permissionless and unpaid, inside the window and best-effort after it until a settle.
    /// @notice It runs only while the vault would still lend at the loan's price; the successor's next roll is promised only where the curator's legs admit it.
    /// @param loanId The loan to roll.
    /// @param data The product's own payload, such as a signed appraisal.
    /// @return newId The successor, titled to the loan's holder.
    function roll(uint256 loanId, bytes calldata data) external nonReentrant returns (uint256 newId) {
        uint256 g = _sync();
        IAceLenderOps hub = IAceLenderOps(ACE);
        bytes32 id = hub.loanMarket(loanId);
        MarketParams memory mp = hub.idToMarketParams(id);
        if (mp.lender != address(this)) revert NotOurLoan();
        if (!AceVaultFlows.layout().rollOf[loanId].funded) revert RollUnfunded();
        if (!_priceAdmits(mp, loanId, data)) revert NotLending();
        bool legs = _rollAdmits(mp) && !draining();
        Ctx memory c = Ctx(ACE, asset(), address(0), legs, legs ? _instantCashAt(_totalAssetsAt(g)) : 0, legs ? _room(mp) : 0);
        _prime(mp, loanId, data);
        newId = AceVaultFlows.roll(c, loanId, id, mp);
        _unprime(mp);
        _afterRoll(mp, loanId, newId);
        _sync();
    }

    /// @notice The market a `borrow` with this request and payload would land in, and the draw the product admits; refuses as the door would.
    /// @return id The market id, which the door creates if missing.
    /// @return mp The market's parameters.
    /// @return t The draw the product admits.
    function previewTerms(BorrowRequest calldata r, bytes calldata data) external view returns (bytes32 id, MarketParams memory mp, Terms memory t) {
        (mp, t) = _borrowTerms(r, data);
        id = keccak256(abi.encode(mp));
    }

    /// @notice Whether the vault would roll a loan in this market now, and whether it would promise that roll's successor.
    /// @dev The amount legs are checked in the verbs; both answers are false for a market that is not this vault's.
    /// @dev It passes the price leg no payload, so a pawn market reads (false, false): its leg needs a signed ROLL appraisal; simulate `roll` with one.
    function wouldLend(bytes32 market) external view returns (bool price, bool rearm) {
        MarketParams memory mp = IAceLenderOps(ACE).idToMarketParams(market);
        if (mp.lender != address(this)) return (false, false);
        price = _priceAdmits(mp, 0, msg.data[0:0]);
        rearm = price && _rollAdmits(mp) && !draining();
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
        return totalSupply() + _pendingFeeShares(a) + VIRTUAL_SHARES;
    }

    /// @notice Deposit assets for shares priced pro-rata against NAV; refused while entry is shut, as `maxDeposit` reads.
    function deposit(uint256 assets, address receiver) public override nonReentrant returns (uint256 shares) {
        shares = _sharesAt(assets, _openEntry(), Math.Rounding.Floor);
        _deposit(_msgSender(), receiver, assets, shares);
    }

    /// @notice Mint shares for assets priced pro-rata against NAV; refused as `deposit` is.
    function mint(uint256 shares, address receiver) public override nonReentrant returns (uint256 assets) {
        assets = _assetsAt(shares, _openEntry(), Math.Rounding.Ceil);
        _deposit(_msgSender(), receiver, assets, shares);
    }

    /// @dev Refuses past the entry cap, asked here so `mint` answers it in assets exactly as `deposit` does.
    /// @dev The mark rises with the cash, after `super._deposit`: a deposit raises gross for a reason that is not growth.
    /// @dev `super._deposit` pulls the cash before it mints, so a sender hook would see neither: the asset must be hookless.
    /// @dev The fee high-water adds the entry's cash as NAV does, so the fee-free gap in assets stays put; the first deposit stamps it.
    function _deposit(address caller, address receiver, uint256 assets, uint256 shares) internal override {
        uint256 cap = _cap(receiver);
        if (assets > cap) revert ERC4626ExceededMaxDeposit(receiver, assets, cap);
        super._deposit(caller, receiver, assets, shares);
        VaultLayout storage $ = AceVaultFlows.layout();
        if (PERF_FEE_BPS != 0) $.feeHighWater += assets;
        $.navMark += assets;
    }

    /// @dev Entry's opening: the sync, the fee, then the gates; returns the NAV entry prices at, the previews' own read.
    /// @dev With shares out, shut at zero NAV and while a gain over GATE_BPS of NAV and one unit vests.
    /// @dev THE UNSOLD-POT GATE runs last, at any supply: an entrant before the sale would buy its recovery at the trough.
    function _openEntry() internal returns (uint256 a) {
        _sync();
        a = totalAssets(); // VIRTUAL: an override may lower NAV, never raise it, so a verb prices off the previews' own read
        _collectFeeAt(a);
        if (totalSupply() != 0) {
            if (a == 0) revert EndOfLife();
            if (_vesting(unvested(), a)) revert GainVesting();
        }
        if (_unsold()) revert InventoryUnsold();
    }

    /// @dev Whether entry waits on a sale: an unsold pot at the hub, or the product's seized goods, that no standing exemption covers.
    /// @dev Goods come home only by `redeemInKind` of a pot the settled count already holds, so a new holding needs a settlement, which voids any exemption.
    /// @dev A never-exempted zero covers nothing, as a pot moves the settled count off zero.
    function _unsold() private view returns (bool) {
        (uint256 u, uint256 s) = _hubCounts();
        return (u != 0 || _holdsSeized()) && s != AceVaultFlows.layout().exemptSettled;
    }

    /// @dev The hub's two counts for this vault in its asset: its settled pots not yet sold, and its pots ever settled.
    function _hubCounts() private view returns (uint256 u, uint256 s) {
        return IAceLenderOps(ACE).lenderUnresolved(address(this), asset());
    }

    /// @notice ERC-4626: zero while entry is shut (a spent vault, a gain vesting, an unsold pot or seizure, or a drain), else the cap.
    function maxDeposit(address receiver) public view override returns (uint256) {
        return _entryShut() ? 0 : _cap(receiver);
    }

    /// @notice ERC-4626: `maxDeposit` in shares at the deposit preview's price; `type(uint256).max` for an uncapped vault.
    /// @dev It never reverts: where cap times the quote supply Q overflows it saturates, over-reporting caps from 2^256 / Q to 2^256 * (NAV + 1) / Q.
    function maxMint(address receiver) public view override returns (uint256) {
        if (_entryShut()) return 0;
        uint256 cap = _cap(receiver);
        uint256 a = totalAssets();
        (bool ok, uint256 n) = Math.tryMul(cap, _quoteSupply(a));
        return ok ? n / (a + 1) : type(uint256).max;
    }

    /// @dev `_openEntry`'s gates as a view, on the pile its sync would leave; the fee it collects first moves only supply, which no gate reads past zero.
    function _entryShut() internal view returns (bool) {
        if (_unsold()) return true;
        if (totalSupply() == 0) return false;
        uint256 a = totalAssets();
        return a == 0 || _vesting(_pendingUnvested(grossNav()), a);
    }

    /// @dev Whether a pile this large against NAV is still vesting: entry waits, so no entrant buys a recovery cheap.
    function _vesting(uint256 u, uint256 a) internal view returns (bool) {
        return u > VEST_FLOOR && u * 10_000 > a * GATE_BPS;
    }

    /// @dev Shares for assets at a NAV the caller already read: OZ's own formula, as OZ's `_convertToShares` re-reads `totalAssets()` itself.
    function _sharesAt(uint256 assets, uint256 a, Math.Rounding r) internal view returns (uint256) {
        return Math.mulDiv(assets, totalSupply() + VIRTUAL_SHARES, a + 1, r);
    }

    /// @dev Assets for shares at a NAV the caller already read; the exact inverse of `_sharesAt`.
    function _assetsAt(uint256 shares, uint256 a, Math.Rounding r) internal view returns (uint256) {
        return Math.mulDiv(shares, a + 1, totalSupply() + VIRTUAL_SHARES, r);
    }

    // ---- the instant exit ----

    /// @notice The shares an instant `withdraw` burns, rounded UP, priced over the supply the verb's own fee collection leaves.
    /// @dev An override MUST quote what the verb pays.
    function previewWithdraw(uint256 assets) public view virtual override returns (uint256) {
        uint256 a = totalAssets();
        return Math.mulDiv(assets, _quoteSupply(a), a + 1, Math.Rounding.Ceil);
    }

    /// @notice The assets an instant `redeem` pays, rounded DOWN, at the same price.
    function previewRedeem(uint256 shares) public view virtual override returns (uint256) {
        uint256 a = totalAssets();
        return Math.mulDiv(shares, a + 1, _quoteSupply(a), Math.Rounding.Floor);
    }

    /// @notice The cash `owner` can take at once: their shares at the fee-inclusive price, capped by exitable cash the requests do not hold.
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
        uint256 a = totalAssets();
        uint256 q = _quoteSupply(a);
        uint256 bal = balanceOf(owner);
        if (owner == address(this) || (bal == _free(owner, q - VIRTUAL_SHARES) && _pendingUnvested(grossNav()) != 0)) return (0, 0);
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
    /// @dev ORDER: the sync and the fee, the price, the auth, a zero payout, the last-out test, the cash bound, the burn, the cash.
    /// @dev It pays exitable cash the requests do not hold, all of exitable while draining; past it OZ's own max refusal names the bound.
    /// @dev An LP's count leaves out every curator share, so the fee shares this verb mints first never let the last LP leave at net.
    function _exitNow(address receiver, address owner, uint256 wantAssets, uint256 wantShares) private returns (uint256 assets, uint256 shares) {
        _sync();
        uint256 a = totalAssets(); // VIRTUAL: an override may lower NAV, never raise it, so a verb prices off the previews' own read
        _collectFeeAt(a);
        (assets, shares) =
            wantShares != 0 ? (_assetsAt(wantShares, a, Math.Rounding.Floor), wantShares) : (wantAssets, _sharesAt(wantAssets, a, Math.Rounding.Ceil));
        address caller = _msgSender();
        if (caller != owner) _spendAllowance(owner, caller, shares);
        if (assets == 0) revert ZeroAssets(); // a redeem worth nothing is refused; a withdraw of one wei always pays
        if (shares == _free(owner, totalSupply()) && unvested() != 0) revert LastOutVesting();
        if (assets > _instantCashAt(a)) {
            if (wantShares != 0) revert ERC4626ExceededMaxRedeem(owner, shares, maxRedeem(owner));
            revert ERC4626ExceededMaxWithdraw(owner, assets, maxWithdraw(owner));
        }
        _burn(owner, shares);
        _pay(receiver, assets);
        emit Withdraw(caller, receiver, owner, assets, shares);
    }

    /// @dev Book an exit's cash after its burn: the fee high-water, saturating, and the mark fall by it; then the cash leaves.
    function _pay(address receiver, uint256 assets) private {
        VaultLayout storage $ = AceVaultFlows.layout();
        if (PERF_FEE_BPS != 0) $.feeHighWater = Math.saturatingSub($.feeHighWater, assets);
        $.navMark = Math.saturatingSub($.navMark, assets); // the cash leaves gross with the transfer below, so the next sync reads no fall
        IERC20(asset()).safeTransfer(receiver, assets);
    }

    /// @dev The supply free for `holder`'s last-out test, max views' zero and release: `supply` less the escrow and donations on this vault.
    /// @dev An LP's figure also leaves out every curator share, minted or pending, so it reads the same before a fee mints and after.
    /// @dev The curator's figure counts its own shares in `supply`: an exit's fee, minted first, counts; a claim's, minted after the release, does not.
    function _free(address holder, uint256 supply) private view returns (uint256 s) {
        s = supply - balanceOf(address(this));
        if (holder != CURATOR) s -= balanceOf(CURATOR) + (supply - totalSupply());
    }

    // ---- the exit request: escrowed shares whose worth the requests' hold keeps from placements ----

    /// @notice Escrow `shares` of the caller's on this vault and renew the whole request's lease; zero only renews.
    /// @notice From here the requests' hold keeps exitable cash up to the request's worth from placements and other instant exits.
    /// @notice NO PRICE IS LOCKED: a claim prices at its own NAV, falls passing through and gains vesting as for a free share.
    function requestExit(uint256 shares) external nonReentrant {
        _sync();
        address holder = _msgSender();
        VaultLayout storage $ = AceVaultFlows.layout();
        Request storage r = $.requests[holder];
        if (shares != 0) {
            _transfer(holder, address(this), shares);
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
    /// @notice A holder who misses a renewal can be lapsed at the boundary: the shares come home and the hold goes with them.
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

    /// @notice The shares of `holder`'s request a claim could burn now, against exitable cash, at the price the claim would pay.
    /// @dev It replays the release: for the last requester, every other share a donation or (for an LP) the curator's, it adds the pile back to NAV.
    /// @dev The quote supply is then read at that NAV, so it carries the fee the claim charges on the pile.
    function maxClaim(address holder) public view returns (uint256 shares) {
        VaultLayout storage $ = AceVaultFlows.layout();
        uint256 own = $.requests[holder].shares;
        uint256 a = totalAssets();
        if (own == $.requestedShares && _free(holder, totalSupply()) == 0) a += _pendingUnvested(grossNav());
        (, shares) = _bound(_exitable(), a, _quoteSupply(a), own);
    }

    /// @notice Burn `shares` of the caller's request and pay their worth to `receiver` now, from exitable cash, held cash first.
    /// @notice FIRST COME among requesters, at the claim's own NAV, rounded DOWN; `minAssets` is the least cash the caller accepts.
    /// @dev The last requester, every other share a donation or (for an LP) the curator's, releases the pile BEFORE the fee, so the fee is charged on it.
    /// @dev Any other claim leaves its share of the pile to the stayers; a claim past exitable is refused as an over-redeem.
    function claimExit(uint256 shares, address receiver, uint256 minAssets) external nonReentrant returns (uint256 assets) {
        uint256 g = _sync();
        address holder = _msgSender();
        VaultLayout storage $ = AceVaultFlows.layout();
        Request storage r = $.requests[holder];
        if (shares > r.shares) revert OverRequest();
        if (r.shares == $.requestedShares && _free(holder, totalSupply()) == 0) _release(g);
        uint256 a = totalAssets(); // VIRTUAL: an override may lower NAV, never raise it, so a verb prices off the previews' own read
        _collectFeeAt(a);
        assets = _assetsAt(shares, a, Math.Rounding.Floor);
        if (assets == 0) revert ZeroAssets();
        if (assets < minAssets) revert ClaimUnderMin();
        if (assets > _exitable()) revert ERC4626ExceededMaxRedeem(holder, shares, maxClaim(holder));
        r.shares -= shares;
        $.requestedShares -= shares;
        _burn(address(this), shares);
        _pay(receiver, assets);
        emit Withdraw(holder, receiver, holder, assets, shares);
    }

    // ---- the curator surface ----

    /// @notice Stop or resume lending: ON by the curator or the guardian, OFF by the curator alone, each at once.
    /// @notice While it stands no placement opens, no successor's next roll is promised, entry shuts, and exits take all of exitable first come.
    /// @notice It never stops a current promised roll, and it never releases the roll hold.
    /// @notice SETTLE FIRST, THEN DRAIN: a drain thrown before a loss is booked pays exits at the pre-loss price.
    /// @notice TRUST: an ON reorders exits; the curator may drain, exit and lift in one bundle.
    function setDrain(bool on) external nonReentrant {
        _setDrain(on);
    }

    /// @notice Product hook: the drain's body; a product with no drain MAY replace it with a bare refusal, which folds the body out.
    function _setDrain(bool on) internal virtual {
        address by = _msgSender();
        if (by != CURATOR && !(on && by == GUARDIAN)) revert NotCurator();
        _sync();
        AceVaultFlows.layout().draining = on;
        emit DrainSet(by, on);
    }

    /// @notice Exempt the pots and seized goods standing now from the entry gate, for those that can never sell. GUARDIAN ONLY; none without one.
    /// @notice It refuses `PotsMoved` unless the hub's settled count is still the one named; the next settlement voids it until it is renewed.
    function exemptDeadPots(uint256 expectedSettled) external nonReentrant {
        _exemptDeadPots(expectedSettled);
    }

    /// @notice Product hook: the override's body; a product with no guardian MAY replace it with a bare `NotGuardian`, which folds the body out.
    /// @dev It writes only the snapshot and reads no NAV, so unlike every other base verb it does not sync first.
    function _exemptDeadPots(uint256 expectedSettled) internal virtual {
        if (GUARDIAN == address(0) || _msgSender() != GUARDIAN) revert NotGuardian();
        (uint256 u, uint256 s) = _hubCounts();
        if (s != expectedSettled) revert PotsMoved(s);
        AceVaultFlows.layout().exemptSettled = s;
        emit DeadPotsExempted(u, s);
    }

    // ---- the permissionless cranks: they move cash and price nothing ----

    /// @notice Collect everything the hub has credited this vault, every market at once, into idle; NAV-neutral. PERMISSIONLESS.
    function crank() external nonReentrant {
        _sweepCredit();
    }

    /// @notice Drop the roll records of loans the hub reports closed, then collect as `crank()` does. PERMISSIONLESS.
    /// @notice A live loan's entry, or an id with none, is skipped, so a stale or repeated id costs only its read.
    /// @param closed Loan ids to check: repaid, settled, or rolled by someone other than this vault.
    function crank(uint256[] calldata closed) external nonReentrant {
        VaultLayout storage $ = AceVaultFlows.layout();
        for (uint256 i; i < closed.length; i++) {
            uint256 need = $.rollOf[closed[i]].need;
            if (need == 0 || !IAceLenderOps(ACE).isClosed(closed[i])) continue;
            delete $.rollOf[closed[i]];
            $.rollHold -= need;
        }
        if ($.rollHold == 0) $.rollFloor = 0;
        _sweepCredit();
    }

    /// @dev The crank's body; a realizing `door` runs it at its close, so a door body never needs to.
    function _sweepCredit() internal {
        _sync();
        uint256 paid = IAceLenderOps(ACE).collect(asset(), address(this)); // this vault's own pool, to this vault
        if (paid != 0) emit Collected(paid);
        _collectFeeAt(totalAssets());
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

    /// @dev The vest a rise of `d` onto a pile of `u` stamps, before the cap: the maturity, blended later by size, and a basis reading `u + d` or a wei above.
    /// @dev The basis SATURATES at uint128 instead of reverting, since every verb reaches it through `_sync`; at the ceiling the pile under-defers.
    function _grossed(uint256 u, uint256 d) internal view returns (uint128 basis, uint64 maturity) {
        uint256 m = AceVaultFlows.layout().vestMaturity;
        uint256 end = block.timestamp + VEST_WINDOW;
        maturity = uint64((u == 0 || m <= block.timestamp) ? end : m + Math.mulDiv(end - m, d, u + d));
        basis = uint128(Math.min(Math.mulDiv(u + d, VEST_WINDOW, maturity - block.timestamp, Math.Rounding.Ceil), type(uint128).max));
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
    /// @dev A rise's pile is capped at `g`, as `_capVest` stores it: the cut basis reads back exactly `g`.
    function _pendingUnvested(uint256 g) internal view returns (uint256) {
        uint256 u = unvested();
        VaultLayout storage $ = AceVaultFlows.layout();
        uint256 m = $.navMark;
        if (g > m) {
            (uint128 basis, uint64 maturity) = _grossed(u, g - m);
            return Math.min(_readVest(basis, maturity), g);
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

    /// @dev Mint the fee shares `_pendingFeeShares` prices at NAV `a`, then lift the high-water to `a` if `a` passes it; an empty vault re-stamps it at `a`.
    /// @dev A TRUE high-water in assets: under it nothing is owed and it does not move, so a loss is never earned back twice.
    function _collectFeeAt(uint256 a) internal {
        if (PERF_FEE_BPS == 0) return;
        uint256 shares = _pendingFeeShares(a);
        if (shares != 0) {
            _mint(CURATOR, shares);
            emit FeeCharged(shares, a);
        }
        VaultLayout storage $ = AceVaultFlows.layout();
        uint256 h = $.feeHighWater;
        if (totalSupply() == 0 ? a != h : a > h) $.feeHighWater = a;
    }

    /// @notice The fee shares a collection would mint now.
    function pendingFeeShares() public view returns (uint256) {
        return _pendingFeeShares(totalAssets());
    }

    /// @dev The fee shares a collection at NAV `a` mints: PERF_FEE_BPS of the rise past the high-water, priced net of the fee; none at zero supply.
    function _pendingFeeShares(uint256 a) internal view returns (uint256) {
        if (PERF_FEE_BPS == 0) return 0;
        uint256 s = totalSupply();
        uint256 h = AceVaultFlows.layout().feeHighWater;
        if (s == 0 || a <= h) return 0;
        uint256 fee = Math.mulDiv(a - h, PERF_FEE_BPS, 10_000); // at most half of NAV, so `a - fee` never reaches zero
        return Math.mulDiv(fee, s, a - fee);
    }

    // ---- internals ----

    function _onlyCurator() internal view {
        if (_msgSender() != CURATOR) revert NotCurator();
    }

    /// @notice ERC-4626: the cash this vault takes and pays; FINAL, since the core's own-token refusal reads it.
    function asset() public view override returns (address) {
        return super.asset();
    }

    /// @dev FINAL: the share token stays hookless, so no override can call out at a mint, a burn or an escrow transfer.
    function _update(address from, address to, uint256 value) internal override {
        super._update(from, to, value);
    }

    /// @dev FINAL: a deposit takes exactly the assets it pulled, so no override can change what arrives.
    function _transferIn(address from, uint256 assets) internal override {
        super._transferIn(from, assets);
    }
}
