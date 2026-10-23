// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.36;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {Clones} from "@openzeppelin/contracts/proxy/Clones.sol";
import {Math} from "@openzeppelin/contracts/utils/math/Math.sol";
import {ReentrancyGuardTransient} from "@openzeppelin/contracts/utils/ReentrancyGuardTransient.sol";
import {MarketParams, OpenBounds} from "../../ace/hub/Types.sol";
import {IAceLenderOps} from "../../interfaces/IAceLenderOps.sol";

/// @dev The hub surface a lock account calls beyond the market read: the open, the per-leg claim, and the close read.
interface IAceLockOps {
    function open(bytes32 id, uint256 collateralUnits, uint256 principal, uint64 tenor, address borrower, OpenBounds calldata bnd) external returns (uint256);
    function claimOwed(uint256 loanId, address toUnits, address toQuote) external returns (uint256 units, uint256 amount);
    function isClosed(uint256 id) external view returns (bool);
    function POSITION_MANAGER() external view returns (address);
    function POSITION_TITLE() external view returns (address);
}

/// @title LockAccount
/// @notice One beneficiary's locked tokens on one vesting schedule, V(t) = total * f(t) with OpenZeppelin's VestingWalletCliff curve.
/// @notice BEFORE IT VESTS, A LOCKED UNIT'S ONLY USE IS ACE COLLATERAL, pledged by this account in its own name on a recordless market.
/// @notice On a REVOCABLE schedule an unvested unit is not even that: its only way out is a revocation, into the lock's own account.
/// @notice THE CAPACITY RULE: a pledge expiring at E needs spent + pledged + u <= V(E), or V(now) if revocable; a release, <= V(now).
/// @notice Together they keep, for every tau >= now, spent + (pledges expiring by tau) <= V(tau), so nothing leaves before it vests.
/// @dev `total` is everything the account holds, has pledged and has spent; a forfeit counts as spent, and only a revocation lowers it.
/// @dev WHY EXPIRY IS ENOUGH, IRREVOCABLY: on a recordless market title moves at or after expiry only, so a pledge leaves no earlier than V(E).
/// @dev WHY NOW, REVOCABLY: a pledge of units not yet vested would sit in the hub's custody, out of any revocation's reach.
/// @dev THE PROOF NEEDS THIS SURFACE: no borrower argument, multicall, refinance, auto-roll, credit operator, order, Permit2, ERC-721 move, fallback, ERC-1271.
/// @dev Every payout goes to the account itself or to the beneficiary; the one recipient argument is `revoke`'s, the lock's own sibling account.
/// @dev THE BENEFICIARY AND THE SCHEDULE ARE THIS CLONE'S IMMUTABLE ARGS: the account cannot be transferred, and a revocation only freezes its curve.
/// @dev UNSUPPORTED: a token whose balance falls other than by this account's own transfers; a fall would shrink `total` and V with it.
/// @dev On such a token the bound above can fail only on the safe side: a destination's booking may exceed V, which only delays it.
contract LockAccount is ReentrancyGuardTransient {
    using SafeERC20 for IERC20;

    error NotBeneficiary(); // only the beneficiary borrows or releases
    error NotALaunchMarket(); // the market is not recordless on this account's token, or no market sits at the id
    error OverCapacity(); // the pledge would exceed what vests by its expiry, or by now on a revocable account
    error OverRelease(); // the release would exceed what has vested now, net of everything pledged and spent
    error LoanLive(); // the hub has not closed this loan yet
    error ZeroAmount(); // a release of nothing
    error LockedAsset(); // a sweep of the locked token or of a loan title, neither of which a sweep may move
    error NotLock(); // only the lock that deployed this account's code revokes or books
    error NotRevocable(); // the schedule is not revocable, or this account is already revoked
    error NothingToRevoke(); // every unit held is releasable now

    /// @dev One pledge, written by `borrow`; `reclaim` zeroes the units and keeps the expiry, which marks the loan as this account's own.
    struct Pledge {
        uint256 units;
        uint64 expiry;
    }

    /// @dev The clone's identity, decoded ONCE per verb from its own code and passed down.
    struct Args {
        address beneficiary;
        uint64 start;
        uint64 cliff;
        uint64 duration;
        bool revocable;
    }

    address public immutable LAUNCH; // the lock that clones this account and deployed its code
    address public immutable TOKEN; // the token this account locks
    address public immutable HUB; // the ACE hub this account pledges into
    address public immutable POSITION_MANAGER; // the hub's custodian, which pulls a pledge
    address public immutable POSITION_TITLE; // the hub's title collection, whose tokens a sweep must not move

    uint256 public spent; // units released to the beneficiary, forfeited to a lender, or booked by the lock for units revoked into this account
    uint256 public pledged; // units in live pledges, booked from before the open to the reclaim
    mapping(uint256 loanId => Pledge) public pledgeOf; // this account's ledger; a loan outside it is never acted on
    bool public revoked; // set once by `revoke`; the whole total is vested from then on

    /// @notice A pledge of `units` into `market`, expiring at `expiry`, opened loan `loanId`.
    event Pledged(uint256 indexed loanId, bytes32 indexed market, uint256 units, uint64 expiry);
    /// @notice `units` vested tokens were paid to the beneficiary.
    event Released(uint256 units);
    /// @notice `units` were booked as spent, for units revoked into this account.
    event Booked(uint256 units);

    /// @dev Runs once, for the implementation; every clone shares these immutables and carries its own args.
    constructor(address token, address hub) {
        (LAUNCH, TOKEN, HUB) = (msg.sender, token, hub);
        POSITION_MANAGER = IAceLockOps(hub).POSITION_MANAGER();
        POSITION_TITLE = IAceLockOps(hub).POSITION_TITLE();
    }

    /// @notice Who this account vests to, and the only address any of its payouts reach.
    function beneficiary() external view returns (address) {
        return _args().beneficiary;
    }

    /// @notice Everything this account holds, has pledged, and has spent: the `total` its curve vests.
    function totalAllocation() external view nonReentrantView returns (uint256) {
        return _total();
    }

    /// @notice V(t): how much of the allocation has vested by `t`; once revoked, the whole total at every `t`, since the curve froze.
    function vestedAmount(uint64 t) external view nonReentrantView returns (uint256) {
        return _vested(_args(), _total(), t);
    }

    /// @notice What `release` would pay now: V(now) less everything spent and pledged.
    function releasable() external view nonReentrantView returns (uint256) {
        return Math.saturatingSub(_vested(_args(), _total(), uint64(block.timestamp)), spent + pledged);
    }

    /// @notice The most a pledge expiring at `expiry` may take: V(expiry), or V(now) on a revocable account, less everything spent and pledged.
    function capacity(uint64 expiry) external view nonReentrantView returns (uint256) {
        Args memory a = _args();
        return Math.saturatingSub(_vested(a, _total(), _horizon(a, expiry)), spent + pledged);
    }

    /// @notice Pledge `units` into market `id` and borrow `principal` in this account's own name; the payout goes to the beneficiary.
    /// @notice Only a recordless market on this account's token, and only up to what vests by the loan's expiry, or by now if revocable.
    /// @dev Recordless means no deleverage band too: genesis refuses a band on a recordless market. No term, price or fee is judged.
    /// @dev The pledge is booked BEFORE the open, and the approval is exactly the pledge, which the custodian's pull consumes.
    /// @dev `tenor` 0 is the market's `minTenor`, the hub's own sentinel, so the expiry booked here is the hub's to the second.
    /// @return loanId The hub's loan, titled to this account.
    function borrow(bytes32 id, uint256 units, uint256 principal, uint64 tenor, OpenBounds calldata bnd) external nonReentrant returns (uint256 loanId) {
        Args memory a = _args();
        if (msg.sender != a.beneficiary) revert NotBeneficiary();
        MarketParams memory p = IAceLenderOps(HUB).idToMarketParams(id);
        if (p.collateral != TOKEN || p.record != address(0)) revert NotALaunchMarket();
        uint64 expiry = uint64(block.timestamp) + (tenor == 0 ? p.minTenor : tenor);
        if (spent + pledged + units > _vested(a, _total(), _horizon(a, expiry))) revert OverCapacity();

        pledged += units;
        IERC20(TOKEN).forceApprove(POSITION_MANAGER, units);
        uint256 cashBefore = IERC20(p.quote).balanceOf(address(this));
        loanId = IAceLockOps(HUB).open(id, units, principal, tenor, address(this), bnd);
        pledgeOf[loanId] = Pledge(units, expiry);
        emit Pledged(loanId, id, units, expiry);
        IERC20(p.quote).safeTransfer(a.beneficiary, IERC20(p.quote).balanceOf(address(this)) - cashBefore);
    }

    /// @notice Bring a closed loan's units home and retire its pledge: what came back is held, what did not is spent. Anyone may call it.
    /// @notice Then collect the loan's quote credit, a fee refund or a residual, BEST-EFFORT: a quote that refuses leaves it owed for a later call.
    /// @notice Acts only on this account's own ledger, and books the units once: a second call collects quote only, a foreign loan nothing.
    /// @dev Two legs through the hub's per-leg claim, so a quote that pauses or refuses this account can never hold the units back.
    /// @dev Units that did not arrive are spent: a forfeit, or a token that delivered short. `total` stays whole.
    /// @return landed The units that arrived.
    function reclaim(uint256 loanId) external nonReentrant returns (uint256 landed) {
        Pledge storage pl = pledgeOf[loanId];
        if (pl.expiry == 0) return 0;
        uint256 units = pl.units;
        if (units != 0) {
            if (!IAceLockOps(HUB).isClosed(loanId)) revert LoanLive();
            pl.units = 0;
            pledged -= units;
            uint256 before = IERC20(TOKEN).balanceOf(address(this));
            IAceLockOps(HUB).claimOwed(loanId, address(this), address(0));
            landed = IERC20(TOKEN).balanceOf(address(this)) - before;
            if (landed < units) spent += units - landed;
        }
        try IAceLockOps(HUB).claimOwed(loanId, address(0), address(this)) {} catch {} // the quote waits here for `sweep`, or in the hub for a retry
    }

    /// @notice Pay `units` of vested tokens to the beneficiary, within V(now) less everything pledged and spent.
    function release(uint256 units) external nonReentrant {
        Args memory a = _args();
        if (msg.sender != a.beneficiary) revert NotBeneficiary();
        if (units == 0) revert ZeroAmount();
        if (spent + pledged + units > _vested(a, _total(), uint64(block.timestamp))) revert OverRelease();
        spent += units;
        IERC20(TOKEN).safeTransfer(a.beneficiary, units);
        emit Released(units);
    }

    /// @notice Pay this account's whole balance of any asset but the locked token to the beneficiary: payouts, refunds, a stray donation. Anyone may call it.
    /// @dev The locked token vests rather than sweeps, and a loan title must stay where the hub reads its borrower.
    function sweep(address token) external nonReentrant returns (uint256 amount) {
        if (token == TOKEN || token == POSITION_TITLE) revert LockedAsset();
        amount = IERC20(token).balanceOf(address(this));
        IERC20(token).safeTransfer(_args().beneficiary, amount);
    }

    /// @notice Revoke: send every held unit above what is releasable now to `to`, and freeze the curve at the total kept. The lock alone calls it, once.
    /// @dev A pledged unit never moves: under the now rule it had vested, and it sits in the hub's custody anyway.
    /// @return moved The units sent to `to`.
    /// @return kept The total this account keeps: what had vested now, or what it had committed if that is more.
    function revoke(address to) external nonReentrant returns (uint256 moved, uint256 kept) {
        Args memory a = _args();
        if (msg.sender != LAUNCH) revert NotLock();
        if (!a.revocable || revoked) revert NotRevocable();
        uint256 held = IERC20(TOKEN).balanceOf(address(this));
        uint256 total = held + pledged + spent;
        moved = held - Math.saturatingSub(_vested(a, total, uint64(block.timestamp)), spent + pledged);
        if (moved == 0) revert NothingToRevoke();
        kept = total - moved;
        revoked = true;
        IERC20(TOKEN).safeTransfer(to, moved);
    }

    /// @notice Book `units` as spent, so units revoked into this account vest on the calendar they left. The lock alone calls it.
    function book(uint256 units) external nonReentrant {
        if (msg.sender != LAUNCH) revert NotLock();
        if (!_args().revocable) revert NotRevocable();
        spent += units;
        emit Booked(units);
    }

    /// @dev Everything this account holds, has pledged, and has spent; only a revocation lowers it, and a donation or a booking raises it.
    function _total() private view returns (uint256) {
        return IERC20(TOKEN).balanceOf(address(this)) + pledged + spent;
    }

    /// @dev Where a pledge's capacity is judged: at its expiry, or now on a revocable account.
    function _horizon(Args memory a, uint64 expiry) private view returns (uint64) {
        return a.revocable ? uint64(block.timestamp) : expiry;
    }

    /// @dev The whole total once revoked; else VestingWalletCliff: zero before the cliff, `total` from the end, linear in between; non-decreasing in `t`.
    /// @dev Restated, not inherited: OpenZeppelin's curve lives in VestingWallet, whose owner transfers and whose total omits a pledge.
    function _vested(Args memory a, uint256 total, uint64 t) private view returns (uint256) {
        if (a.revocable && revoked) return total;
        if (t < a.start + a.cliff) return 0;
        if (t >= a.start + a.duration) return total;
        return Math.mulDiv(total, t - a.start, a.duration);
    }

    /// @dev The clone's immutable args, as its lock wrote them; one EXTCODECOPY and one decode.
    function _args() private view returns (Args memory a) {
        (a.beneficiary,, a.start, a.cliff, a.duration, a.revocable) =
            abi.decode(Clones.fetchCloneArgs(address(this)), (address, uint256, uint64, uint64, uint64, bool));
    }
}
