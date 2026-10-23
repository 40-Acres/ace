// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.36;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {Clones} from "@openzeppelin/contracts/proxy/Clones.sol";
import {Math} from "@openzeppelin/contracts/utils/math/Math.sol";
import {SignedMath} from "@openzeppelin/contracts/utils/math/SignedMath.sol";
import {ReentrancyGuardTransient} from "@openzeppelin/contracts/utils/ReentrancyGuardTransient.sol";
import {TickBitmap} from "@uniswap/v4-core/src/libraries/TickBitmap.sol";
import {TickMath} from "@uniswap/v4-core/src/libraries/TickMath.sol";
import {PoolId} from "@uniswap/v4-core/src/types/PoolId.sol";
import {Constants} from "../ace/hub/Constants.sol";
import {LoanMath} from "../ace/hub/libraries/LoanMath.sol";
import {Permits} from "../ace/hub/libraries/Permits.sol";
import {MarketParams} from "../ace/hub/Types.sol";
import {IAceLenderOps} from "../interfaces/IAceLenderOps.sol";
import {IContinuousClearingAuction} from "../interfaces/ILaunchAuction.sol";
import {LaunchLock} from "../entities/launch/LaunchLock.sol";
import {LaunchOpsBudget} from "../entities/launch/LaunchOpsBudget.sol";
import {LaunchTokenFactory} from "../entities/launch/LaunchTokenFactory.sol";
import {LockAccount} from "../entities/launch/LockAccount.sol";
import {RunwayHook} from "../entities/launch/RunwayHook.sol";
import {PriceGrid} from "./PriceGrid.sol";
import {SetValue} from "./sets/SetValue.sol";

/// @notice The hub as this vault holds it: the lender surface plus the in-kind redeem, the only door a forfeit's pot has here.
interface ILaunchVaultHub is IAceLenderOps {
    function redeemInKind(uint256 loanId, address to) external returns (uint256);
}

/// @notice The two calls this vault makes on Permit2's IAllowanceTransfer: the stored allowance a bidder signed, and the one pull against it.
interface IAllowanceTransfer {
    function allowance(address owner, address token, address spender) external view returns (uint160 amount, uint48 expiration, uint48 nonce);
    function transferFrom(address from, address to, uint160 amount, address token) external;
}

/// @title LaunchVault
/// @notice A curator's closed-end vault for one Runway launch: it lends opted-in auction refunds to that launch's buyer lock accounts only.
/// @notice One clone per (token, curator, dTicks, baseBps), made by anyone; the implementation is the factory, and the terms never change.
/// @notice ENTRY: 1:1 shares from the auction's end to launchBy plus DEPOSIT_WINDOW, until a stop, by `deposit` or by a keeper's `depositRefund`.
/// @notice LENDING: a beneficiary reserves cash in a market whose borrower is its own buyer account, priced off the hook's window.
/// @notice EXIT: pro rata in kind once home; the curator takes FEE_BPS of USDC paid out above the 1:1 basis, never of tokens.
/// @dev The quote is min(24-36h block-start window, clearing) x (1 - d) on PriceGrid's step; in-block spot can only lower the borrower's own.
/// @dev Room per account is its auction spend at the final clearing price, never its balance: a donation buys no room.
/// @dev Cash rests across calls on purpose: a recordless loan cannot arm, a lock account cannot re-term, and no reservation's price stands stale.
/// @dev RESERVE_TTL bounds a price's age, not a reservation's: a top-up re-prices, a new quote is a new market, and a window drop frees it to anyone.
/// @dev The vault never sells or swaps the launch token; it leaves only through `exit`.
contract LaunchVault is ReentrancyGuardTransient {
    using SafeERC20 for IERC20;

    uint256 public constant DEPOSIT_WINDOW = 3 days; // entry closes this long after launchBy, which is when lending opens
    uint256 public constant LEND_TERM = 30 days; // reservations are taken from openAt for this long
    uint256 public constant RESERVE_TTL = 1 hours; // how long a reservation's price may stand unrefreshed before anyone may recall it
    uint64 public constant MIN_TENOR = 7 days;
    uint64 public constant MAX_TENOR = 30 days;
    uint256 public constant COVERAGE_WAD = 1.25e18; // every market's minCoverageWad
    uint256 public constant MIN_DEBT = 10e6; // every market's minDebt, in quote atoms
    uint256 public constant FEE_BPS = 1000; // the curator's share of USDC paid out above the 1:1 basis
    uint24 public constant MIN_D_TICKS = 1054; // a discount of at least 10%
    uint24 public constant MAX_D_TICKS = 6932; // a discount of at most 50%
    int24 public constant GRID = PriceGrid.TICKS; // PriceGrid's step: every quote snaps down onto it
    uint256 public constant BUYER = 0; // the lock's buyer schedule id
    uint256 internal constant Q96 = 1 << 96;
    uint256 internal constant LINE = Q96 * COVERAGE_WAD / 1e18; // k x 2^96, exact: the hub's coverage line divides by it

    error NotImplementation();
    error NotAClone();
    error ZeroCurator();
    error BadTerms(); // a discount or rate genesis or this vault would refuse
    error NotALaunch(); // the token was not born at the factory
    error NotDepositing(); // entry is open only from the auction's end to openAt, and never after a failed settle or a stop
    error ZeroAssets();
    error NotAnAccount(); // the beneficiary has no buyer account in this lock
    error NothingToDeposit(); // nothing swept, or no live allowance to pull it
    error AlreadyCredited();
    error NotLending(); // reservations open from openAt to lendEnd, on a live launch, until the curator stops
    error NoQuote();
    error BelowMinDebt(); // the room left, the cash free or the ask is under one minimum ticket
    error NoReservation();
    error NotRecallable(); // the reservation is fresh, priced at or under the block-start quote, the term runs and no stop
    error NotCurator();
    error NotHome(); // cash still rests or is lent, or a forfeit is unredeemed
    error ZeroShares();
    error OverShares();

    /// @notice One clone's launch and terms, as its args carry them.
    struct Terms {
        address token;
        address curator;
        uint24 dTicks;
        uint16 baseBps;
        LaunchLock lock;
        IContinuousClearingAuction auction;
        LaunchOpsBudget budget;
        PoolId pool;
        uint64 launchBy;
        bool tokenIs0;
    }

    /// @notice An account's one market holding this vault's cash, and when it was last reserved.
    struct Reservation {
        bytes32 market;
        uint64 reservedAt;
    }

    address public immutable SELF; // the implementation, which is also the clone factory
    LaunchTokenFactory public immutable FACTORY; // the launch factory whose launches this vault serves
    address public immutable HUB; // the ACE hub every launch's lock pledges into
    address public immutable QUOTE; // USDC: deposits, loans and exits
    RunwayHook public immutable HOOK; // every launch pool's hook, whose window prices the quote

    uint256 public totalShares;
    mapping(address => uint256) public sharesOf; // non-transferable; one share per USDC atom deposited
    uint256 public feeOwed; // booked at exits, paid to the curator by `claimFee`
    bool public stopped; // the curator's one-way stop on new deposits and reservations
    mapping(address account => uint256) public creditOf; // at most the token units an account's bids bought
    mapping(uint256 bidId => bool) public credited;
    mapping(address account => Reservation) public reservationOf;
    address[] public accounts; // every account that ever reserved, for recall after the term

    /// @param factory The launch factory; the hub, the quote and the hook are read off it.
    constructor(address factory) {
        LaunchTokenFactory f = LaunchTokenFactory(factory);
        (SELF, FACTORY, HUB, QUOTE, HOOK) = (address(this), f, f.HUB(), f.QUOTE(), f.HOOK());
    }

    // ---- the factory: the implementation only ----

    /// @notice The vault for these terms, cloned now if it is not yet. Anyone may call it, on the implementation alone.
    /// @dev Get-or-create, so a stranger's earlier creation never reverts the honest call.
    function vaultFor(address token, address curator, uint24 dTicks, uint16 baseBps) external nonReentrant returns (address vault) {
        if (address(this) != SELF) revert NotImplementation();
        (bytes memory args, bytes32 salt) = _argsAndSalt(token, curator, dTicks, baseBps);
        vault = Clones.predictDeterministicAddressWithImmutableArgs(SELF, args, salt);
        if (vault.code.length == 0) Clones.cloneDeterministicWithImmutableArgs(SELF, args, salt);
    }

    /// @notice Where the vault for these terms lives, created or not: the spender a bidder's Permit2 allowance names.
    function predictVault(address token, address curator, uint24 dTicks, uint16 baseBps) external view returns (address) {
        (bytes memory args, bytes32 salt) = _argsAndSalt(token, curator, dTicks, baseBps);
        return Clones.predictDeterministicAddressWithImmutableArgs(SELF, args, salt, SELF);
    }

    // ---- entry ----

    /// @notice Whether shares mint now: the auction graduated and its end is checkpointed, openAt is ahead, settle found no failure, and no stop.
    function depositing() external view returns (bool) {
        return _depositing(_args());
    }

    /// @notice Deposit `assets` USDC for as many shares, to the caller.
    function deposit(uint256 assets) external nonReentrant returns (uint256) {
        if (!_depositing(_args())) revert NotDepositing();
        if (assets == 0) revert ZeroAssets();
        IERC20(QUOTE).safeTransferFrom(msg.sender, address(this), assets);
        return _mint(msg.sender, assets);
    }

    /// @notice Sweep `beneficiary`'s buyer account to it, then pull what was swept, up to its Permit2 allowance here, for its shares.
    /// @notice Anyone may call it; the shares go to the beneficiary alone.
    /// @dev The one Permit2 call: from the beneficiary whose account this call swept, at most that sweep, minting only to it.
    function depositRefund(address beneficiary) external nonReentrant returns (uint256 assets) {
        Terms memory a = _args();
        if (!_depositing(a)) revert NotDepositing();
        uint256 swept = LockAccount(_account(a, beneficiary)).sweep(QUOTE);
        (uint160 amt, uint48 exp,) = IAllowanceTransfer(Permits.PERMIT2).allowance(beneficiary, QUOTE, address(this));
        assets = block.timestamp > exp ? 0 : Math.min(swept, amt);
        if (assets == 0) revert NothingToDeposit();
        IAllowanceTransfer(Permits.PERMIT2).transferFrom(beneficiary, address(this), uint160(assets), QUOTE);
        _mint(beneficiary, assets);
    }

    // ---- credit ----

    /// @notice Credit bid `bidId`'s owner with the token units its spend buys at the final clearing price, less one atom. Once per bid.
    /// @notice Anyone may call it; exits and claims never move it. The hints are the budget's `spentOf` hints.
    /// @dev Rounding down then taking an atom keeps it at or under what the bid filled.
    function credit(uint256 bidId, uint64 lastFullyFilled, uint64 outbid) external nonReentrant returns (uint256 units) {
        Terms memory a = _args();
        if (credited[bidId]) revert AlreadyCredited();
        address owner = a.auction.bids(bidId).owner;
        uint256 spent = a.budget.spentOf(bidId, lastFullyFilled, outbid);
        units = spent == 0 ? 0 : Math.saturatingSub(spent / _clearing(a), 1);
        credited[bidId] = true;
        creditOf[owner] += units;
    }

    // ---- the quote ----

    /// @notice The borrower's quote, Q96 USDC atoms per token atom: the block-start quote, lowered further by spot. Zero unless live.
    function quote() external view returns (uint256) {
        return _quote(_args(), true);
    }

    /// @notice The quote off the block-start window alone, which no swap this block can move: what every third-party power reads.
    function blockStartQuote() external view returns (uint256) {
        return _quote(_args(), false);
    }

    // ---- lending ----

    /// @notice Rest up to `assets` for the caller's buyer account, in its own market at the current quote; a new price recalls the old market first.
    /// @notice Capped by the account's room, the vault's free cash, and what already rests there. Every call re-prices and restarts the hour.
    /// @notice A borrower that keeps topping up keeps its cash reserved, within its own room, always at the current quote.
    /// @dev Room is min(capacity, credit - pledged - spent) units, as cash at the quote over the coverage line.
    /// @dev It collects first, so fees and repayments the hub holds for the vault are free cash here; with nothing owed it pays nothing and never reverts.
    function reserve(uint256 assets) external nonReentrant returns (bytes32 id, uint256 reserved) {
        Terms memory a = _args();
        uint256 openAt = a.launchBy + DEPOSIT_WINDOW;
        if (stopped || !a.budget.live() || block.timestamp < openAt || block.timestamp >= openAt + LEND_TERM) revert NotLending();
        ILaunchVaultHub(HUB).collect(QUOTE, address(this));
        address account = _account(a, msg.sender);
        uint256 price = _quote(a, true);
        if (price == 0) revert NoQuote();
        MarketParams memory p = _params(a, account, price);
        id = _switch(account, keccak256(abi.encode(p)));
        reserved = Math.min(Math.min(assets, _room(account, price, id)), Math.saturatingSub(IERC20(QUOTE).balanceOf(address(this)), feeOwed));
        if (reserved < MIN_DEBT) revert BelowMinDebt();
        if (ILaunchVaultHub(HUB).idToMarketParams(id).quote == address(0)) ILaunchVaultHub(HUB).createMarket(p);
        IERC20(QUOTE).forceApprove(HUB, reserved);
        ILaunchVaultHub(HUB).deposit(id, reserved);
    }

    /// @notice Bring `account`'s reserved cash home. Anyone may once its price is an hour old or over the block-start quote, past the term, or stopped.
    function recall(address account) external nonReentrant returns (uint256) {
        Terms memory a = _args();
        Reservation memory r = reservationOf[account];
        if (r.market == 0) revert NoReservation();
        if (
            !stopped && block.timestamp < a.launchBy + DEPOSIT_WINDOW + LEND_TERM && block.timestamp < r.reservedAt + RESERVE_TTL
                && ILaunchVaultHub(HUB).idToMarketParams(r.market).price <= _quote(a, false)
        ) revert NotRecallable();
        return _recall(r.market);
    }

    /// @notice The curator's one-way stop: no new deposit or reservation, and every resting one recallable by anyone.
    function stop() external nonReentrant {
        if (msg.sender != _args().curator) revert NotCurator();
        stopped = true;
    }

    /// @notice Take a settled loan's pot home in kind. Anyone may call it.
    function redeem(uint256 loanId) external nonReentrant returns (uint256) {
        _args();
        return ILaunchVaultHub(HUB).redeemInKind(loanId, address(this));
    }

    // ---- exit ----

    /// @notice Whether nothing rests, nothing is lent and no forfeit is unredeemed: what `exit` needs, uncollected credit aside.
    function isHome() external view returns (bool) {
        return _home(_args().token);
    }

    /// @notice Burn `shares` of the caller's for their pro rata USDC and launch tokens, paid to `to`, once home.
    /// @notice The curator's fee is FEE_BPS of the USDC above the shares' 1:1 basis, booked here; tokens are fee-free.
    function exit(uint256 shares, address to) external nonReentrant returns (uint256 assets, uint256 units) {
        Terms memory a = _args();
        if (shares == 0) revert ZeroShares();
        ILaunchVaultHub(HUB).collect(QUOTE, address(this));
        if (!_home(a.token)) revert NotHome();
        uint256 mine = sharesOf[msg.sender];
        if (shares > mine) revert OverShares();
        uint256 total = totalShares;
        uint256 out = Math.mulDiv(Math.saturatingSub(IERC20(QUOTE).balanceOf(address(this)), feeOwed), shares, total);
        uint256 fee = out > shares ? (out - shares) * FEE_BPS / 10_000 : 0;
        (feeOwed, assets) = (feeOwed + fee, out - fee);
        units = Math.mulDiv(IERC20(a.token).balanceOf(address(this)), shares, total);
        (sharesOf[msg.sender], totalShares) = (mine - shares, total - shares);
        IERC20(QUOTE).safeTransfer(to, assets);
        IERC20(a.token).safeTransfer(to, units);
    }

    /// @notice Pay the booked fee to the curator. Anyone may call it; a curator the quote refuses strands only the fee.
    function claimFee() external nonReentrant returns (uint256 amount) {
        address curator = _args().curator;
        (amount, feeOwed) = (feeOwed, 0);
        IERC20(QUOTE).safeTransfer(curator, amount);
    }

    // ---- reads ----

    /// @notice This clone's launch and terms.
    function terms() external view returns (Terms memory) {
        return _args();
    }

    /// @notice How many accounts ever reserved: `accounts` is their list, for a keeper's recall after the term.
    function accountCount() external view returns (uint256) {
        return accounts.length;
    }

    // ---- internals ----

    /// @dev The clone's args and salt for these terms, refused unless genesis would take the terms and the token is a launch.
    /// @dev baseBps must pass genesis's three fee rails at MAX_TENOR over MIN_TENOR, which caps it at 530.
    function _argsAndSalt(address token, address curator, uint24 dTicks, uint16 baseBps) private view returns (bytes memory args, bytes32 salt) {
        if (curator == address(0)) revert ZeroCurator();
        if (
            dTicks < MIN_D_TICKS || dTicks > MAX_D_TICKS || baseBps < Constants.MIN_BASE_BPS || !LoanMath.feeFundable(baseBps, MAX_TENOR, MIN_TENOR)
                || LoanMath.originationFee(MIN_DEBT, MAX_TENOR, baseBps, MIN_TENOR) >= MIN_DEBT
        ) revert BadTerms();
        Terms memory c;
        (c.token, c.curator, c.dTicks, c.baseBps, c.tokenIs0) = (token, curator, dTicks, baseBps, token < QUOTE);
        (address lock, address auction, address budget) = FACTORY.launchOf(token);
        if (lock == address(0)) revert NotALaunch();
        (c.lock, c.auction, c.budget) = (LaunchLock(lock), IContinuousClearingAuction(auction), LaunchOpsBudget(budget));
        LaunchOpsBudget.Terms memory t = c.budget.terms();
        (c.pool, c.launchBy) = (t.pool, t.launchBy);
        (args, salt) = (abi.encode(c), keccak256(abi.encode(token, curator, dTicks, baseBps)));
    }

    /// @dev The clone's args; the implementation has none, so every verb on it reverts here.
    function _args() private view returns (Terms memory) {
        if (address(this) == SELF) revert NotAClone();
        return abi.decode(Clones.fetchCloneArgs(address(this)), (Terms));
    }

    function _depositing(Terms memory a) private view returns (bool) {
        IContinuousClearingAuction c = a.auction;
        return !stopped && c.isGraduated() && c.lastCheckpointedBlock() == c.endBlock() && block.timestamp < a.launchBy + DEPOSIT_WINDOW
            && (a.budget.wallet() == address(0) || a.budget.live());
    }

    /// @dev `beneficiary`'s buyer account, derived here and never taken as an argument; refused unless the lock made it.
    function _account(Terms memory a, address beneficiary) private view returns (address account) {
        account = a.lock.predict(beneficiary, BUYER);
        if (!a.lock.isAccount(account)) revert NotAnAccount();
    }

    function _mint(address to, uint256 assets) private returns (uint256) {
        (sharesOf[to], totalShares) = (sharesOf[to] + assets, totalShares + assets);
        return assets;
    }

    /// @dev The auction's final clearing price, Q96 USDC atoms per token atom.
    function _clearing(Terms memory a) private view returns (uint256) {
        return a.auction.checkpoints(a.auction.endBlock()).clearingPrice;
    }

    /// @dev In tick space, as a token price: the window's floor, spot if asked, and the clearing tick, less dTicks, snapped down onto GRID.
    /// @dev Token as currency1, a pool tick t prices the token within [1.0001^(-t-1), 1.0001^-t], so its floor is -t - 1.
    /// @dev It inlines PriceGrid's floor path, since `PriceGrid.down` is linked and takes a price; every step floors, so the quote never exceeds its inputs.
    function _quote(Terms memory a, bool withSpot) private view returns (uint256) {
        if (!a.budget.live()) return 0;
        (int24 lo, int24 hi, int24 spot) = HOOK.windowOf(a.pool);
        int256 t = a.tokenIs0 ? int256(lo) : -int256(hi) - 1;
        if (withSpot) t = SignedMath.min(t, a.tokenIs0 ? int256(spot) : -int256(spot) - 1);
        int256 c = TickMath.getTickAtSqrtPrice(SetValue.sqrtPriceX96(_clearing(a), false));
        t = SignedMath.min(t, c) - int256(uint256(a.dTicks));
        if (t < TickMath.MIN_TICK) return 0;
        t = int256(TickBitmap.compress(int24(t), GRID)) * GRID;
        if (t < TickMath.MIN_TICK) return 0;
        uint256 g = TickMath.getSqrtPriceAtTick(int24(t));
        return Math.mulDiv(g, g, Q96);
    }

    /// @dev Make `id` the account's reservation, stamped now: its first is listed, and a different market is recalled first.
    function _switch(address account, bytes32 id) private returns (bytes32) {
        bytes32 old = reservationOf[account].market;
        if (old == 0) accounts.push(account);
        else if (old != id) _recall(old);
        reservationOf[account] = Reservation(id, uint64(block.timestamp));
        return id;
    }

    /// @dev What `account` may still rest in `id` at `price`: its room less what rests there already, saturating.
    /// @dev Room is its units net of the coverage line's atom, over k: the hub's line inverted exactly.
    function _room(address account, uint256 price, bytes32 id) private view returns (uint256) {
        LockAccount acct = LockAccount(account);
        uint256 units = Math.min(acct.capacity(uint64(block.timestamp) + MAX_TENOR), Math.saturatingSub(creditOf[account], acct.pledged() + acct.spent()));
        uint256 room = units <= 1 ? 0 : Math.mulDiv(units - 1, price, LINE);
        return Math.saturatingSub(room, ILaunchVaultHub(HUB).restingOf(id));
    }

    /// @dev `account`'s recordless market at `price`: this vault the lender, the account the one borrower, every channel and bounty off.
    function _params(Terms memory a, address account, uint256 price) private view returns (MarketParams memory p) {
        (p.quote, p.collateral, p.borrower, p.price, p.lender) = (QUOTE, a.token, account, price, address(this));
        (p.minCoverageWad, p.baseBps, p.minTenor, p.maxTenor, p.minDebt) = (COVERAGE_WAD, a.baseBps, MIN_TENOR, MAX_TENOR, MIN_DEBT);
    }

    /// @dev Withdraw everything resting in `id`; an empty market is skipped, since the hub refuses to withdraw nothing.
    function _recall(bytes32 id) private returns (uint256) {
        if (ILaunchVaultHub(HUB).restingOf(id) == 0) return 0;
        return ILaunchVaultHub(HUB).withdraw(id, type(uint256).max, address(this), 0);
    }

    /// @dev Nothing resting or lent in USDC, owed credit aside, and no unredeemed forfeit of `token`.
    function _home(address token) private view returns (bool) {
        ILaunchVaultHub hub = ILaunchVaultHub(HUB);
        (, uint256 unsold) = hub.lenderByCollateral(address(this), QUOTE, token);
        return hub.lenderAssets(address(this), QUOTE) == hub.lenderOwed(address(this), QUOTE) && unsold == 0;
    }
}
