// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.36;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {SafeCast} from "@openzeppelin/contracts/utils/math/SafeCast.sol";
import {Math} from "@openzeppelin/contracts/utils/math/Math.sol";
import {LowLevelCall} from "@openzeppelin/contracts/utils/LowLevelCall.sol";
import {AutoPolicyDisarmed, Borrower, LoanClosed} from "../ace/hub/Borrower.sol";
import {NotExpired} from "../ace/hub/Settlement.sol";
import {Permits} from "../ace/hub/libraries/Permits.sol";
import {MarketParams, OpenBounds} from "../ace/hub/Types.sol";
import {IAceLenderOps} from "../interfaces/IAceLenderOps.sol";

/// @notice What a borrower asks the core door for; a product reads the fields its terms need and ignores the rest.
struct BorrowRequest {
    address collateral;
    uint256 units;
    uint256 principal;
    uint64 tenor; // zero takes the market's shortest
    bool arm; // ask for the auto-roll; the product decides whether to grant it
    uint256 minPayout; // the least cash the borrower accepts, held by the hub's open
    uint256 minBufferWad; // the least gap between the market's price and the loan's trigger, where a product passes it on
    uint64 deadline; // the latest second the open may land, or zero for none
}

/// @notice What a product admits, beside the market it built: the draw, its term, and whether the door arms it.
struct Terms {
    uint256 units;
    uint256 principal;
    uint64 tenor; // never zero: a zero arm tenor disarms
    bool arm;
    uint256 minBufferWad;
}

/// @notice One reservation the vault's markets carry for a loan: an upper bound on its roll need, and whether the vault promised that roll.
struct Roll {
    uint128 need;
    bool funded;
}

/// @notice One holder's exit request: the shares it escrows on the vault, and when it lapses unless renewed.
struct Request {
    uint256 shares; // escrowed until claimed, cancelled or lapsed; a full word, as a share is a millionth of an asset atom at par
    uint64 expiresAt; // from here anyone may lapse it; a further request renews it
}

/// @notice A vault's vest, fee, request, exemption and roll state: one ERC-7201 namespace, shared by the base and its door library.
/// @custom:storage-location erc7201:ace.curatorvault
struct VaultLayout {
    uint256 feeHighWater; // fee threshold in assets: a collection lifts it to NAV, an entry adds its cash, an exit or a claim takes its cash
    uint256 navMark; // gross NAV at the last sync; a rise above it defers, a fall passes through
    uint128 vestBasis; // grossed, read back as basis * (maturity - now) / VEST_WINDOW
    uint64 vestMaturity; // when the deferred pile finishes; it only ever moves LATER
    bool draining; // lending stopped: no placement, no promised successor, entry shut; packs into the vest's word
    uint256 requestedShares; // escrowed shares of every standing request
    mapping(address holder => Request) requests;
    uint256 exemptSettled; // the hub's settled count at the guardian's last dead-pot exemption; any settlement since voids it
    uint256 rollHold; // the exact sum of every recorded need
    uint256 rollFloor; // the largest minDebt booked since the book was last empty: it only rises while a record stands, and resets as the hold empties
    mapping(uint256 loanId => Roll) rollOf;
}

/// @notice What a vault hands its door and roll bodies: the hub, the cash, custody, and the bounds it read before resting anything.
struct Ctx {
    address ace;
    address asset;
    address manager; // the hub's custodian, approved for exactly the pledge
    bool legs; // the curator's legs and the drain admit new lending
    uint256 lendable; // what the holds leave a placement
    uint256 room; // the collateral's cap room
}

/// @dev The three settle verbs a product door may end a loan by, named for their selectors.
interface IAceSettle {
    function finalize(uint256 id) external;
    function forceClose(uint256 id) external;
    function settleExpired(uint256 id) external;
}

/// @title AceVaultFlows
/// @notice The core door's and the roll's bodies: rest all idle, act at the hub, withdraw every resting unit, and book the vault's roll record.
/// @notice DELEGATECALL-linked: each runs in the vault's context, so `address(this)` is the vault and every hub call is the vault's.
/// @notice NOTHING THE VAULT FUNDS RESTS ACROSS A CALL: a market's cash is zero between calls, its reservations stand on paper.
/// @notice The record is an upper bound: each need is the hub's roll need at the market's longest term, so a holder's retune never outgrows it.
/// @dev THE RECORD IS THE VAULT'S OWN: whether it promised a roll is its choice, and the hub shows a market's reserve only through the lens.
/// @dev A member that writes runs only through the vault's guarded wrappers; the library's call protection refuses a direct call.
/// @dev Every hub call precedes every non-hub call the wrapper makes after it: the payout, the title and a product's own hook.
library AceVaultFlows {
    using SafeERC20 for IERC20;

    error OutsideEnvelope(); // the market quotes something other than this vault's asset
    error NotOurLender(); // the market names somebody else as its one lender
    error CashIsNotCollateral(); // a forfeit of the vault's own cash would strand outside its idle
    error SharesAreNotCollateral(); // a forfeit of the vault's own share would sit on it as a donation nobody can request or sell
    error PaysSettleBounty(); // a vault market pays no settle bounty: settling the vault's loans is its own duty
    error PledgeArrivedShort(); // fewer collateral units landed than the terms pledge
    error OverLendable(); // the placement, with the hold its arm adds, passes what the holds leave lendable
    error OverCap(); // the placement passes the collateral's cap room
    error RollNotLendable(); // a roll's draw past its recorded need is new lending, and lendable, the cap room or the curator's legs refuse it

    /// @notice The core door lent: the loan, its market, who took it, and whether the vault promised its first roll.
    event Borrowed(uint256 indexed loanId, bytes32 indexed market, address indexed borrower, uint256 units, uint256 principal, uint256 payout, bool armed);

    bytes32 internal constant ROOT = 0xb7a4de03362d20465bcc8b45bb9625cb4abe76f109b674085f908e1bc61c7000; // erc7201:ace.curatorvault

    /// @notice The vault's state, at its ERC-7201 root.
    function layout() internal pure returns (VaultLayout storage $) {
        bytes32 slot = ROOT;
        assembly ("memory-safe") {
            $.slot := slot
        }
    }

    /// @notice The roll hold a recorded sum keeps idle: zero on an empty book, else three times the sum plus the dust floor.
    /// @dev Two multiples cover the fresh draws still to spend and any one market's reservations; the third absorbs the carry's growth.
    function holdNow(uint256 hold, uint256 floor) internal pure returns (uint256) {
        return hold == 0 ? 0 : 3 * hold + floor;
    }

    /* ============================== THE DOOR ============================== */

    /// @notice The door's checks and pledge: the market is this vault's, the placement fits, and exactly the units arrived.
    /// @dev Runs before the product's `_prime`, so the collateral's token code never meets a primed product.
    /// @return id The market id.
    function place(Ctx memory c, MarketParams memory mp, Terms memory t, bytes calldata permit2) public returns (bytes32 id) {
        if (mp.lender != address(this)) revert NotOurLender();
        if (mp.quote != c.asset) revert OutsideEnvelope();
        if (mp.collateral == c.asset) revert CashIsNotCollateral();
        if (mp.collateral == address(this)) revert SharesAreNotCollateral();
        if (mp.settleBountyBps != 0) revert PaysSettleBounty();
        VaultLayout storage $ = layout();
        uint256 growth;
        if (t.arm) growth = holdNow($.rollHold + _needAt(mp, t.principal), Math.max($.rollFloor, mp.minDebt)) - holdNow($.rollHold, $.rollFloor);
        if (t.principal + growth > c.lendable) revert OverLendable();
        if (t.principal > c.room) revert OverCap();
        _pull(mp.collateral, t.units, c.manager, permit2);
        id = keccak256(abi.encode(mp));
    }

    /// @notice The door's hub leg: create the market if missing, rest all idle, open to this vault, arm and record, withdraw every unit.
    /// @dev Opening to this vault passes the hub's credit-operator gate; the title is handed over by the wrapper after this returns.
    /// @return loanId The loan, titled to this vault until the wrapper hands it over.
    /// @return payout The cash the open paid this vault, measured.
    function lend(address ace, bytes32 id, MarketParams memory mp, Terms memory t, uint256 minPayout, uint64 deadline)
        public
        returns (uint256 loanId, uint256 payout)
    {
        IAceLenderOps hub = IAceLenderOps(ace);
        if (hub.idToMarketParams(id).quote == address(0)) hub.createMarket(mp);
        if (t.tenor == 0) t.tenor = mp.minTenor;
        _rest(hub, IERC20(mp.quote), id);
        (loanId, payout) = _open(hub, IERC20(mp.quote), id, t, OpenBounds(minPayout, t.minBufferWad, deadline));
        if (t.arm) {
            hub.setAutoRefinance(loanId, t.tenor, 0, 0);
            _book(layout(), loanId, _needAt(mp, t.principal), true, mp.minDebt);
        }
        _drain(hub, id);
        emit Borrowed(loanId, id, msg.sender, t.units, t.principal, payout, t.arm);
    }

    /* ============================== THE ROLL ============================== */

    /// @notice The roll's body: size the draw past the record, rest all idle, roll by policy, withdraw every unit, then move the record on.
    /// @notice The successor is recorded only where the hub's carry armed it, funded only where the vault's legs and holds admit its next roll.
    /// @dev The fresh draw is bounded by the old debt's successor at the longest term; what passes the recorded need is new lending.
    /// @return newId The successor.
    function roll(Ctx memory c, uint256 loanId, bytes32 id, MarketParams memory mp) public returns (uint256 newId) {
        IAceLenderOps hub = IAceLenderOps(c.ace);
        (uint256 next, bool fund) = _size(c, hub, loanId, mp);
        _rest(hub, IERC20(mp.quote), id);
        newId = hub.refinanceByPolicy(loanId);
        _drain(hub, id);
        _move(hub, loanId, newId, next, fund, mp.minDebt);
    }

    /// @dev The successor's record bound and whether to promise it; a draw past the record that the legs, lendable or the room refuse reverts.
    function _size(Ctx memory c, IAceLenderOps hub, uint256 loanId, MarketParams memory mp) private view returns (uint256 next, bool fund) {
        VaultLayout storage $ = layout();
        uint256 need = $.rollOf[loanId].need;
        uint256 debt = hub.debtOf(loanId);
        if (debt == 0) revert LoanClosed();
        uint256 up = _succUp(mp, debt);
        uint256 excess = Math.saturatingSub(up - debt, need);
        next = _needAt(mp, up);
        uint256 growth = Math.saturatingSub(holdNow($.rollHold - need + next, $.rollFloor), holdNow($.rollHold, $.rollFloor));
        if (excess != 0 && (!c.legs || excess > c.lendable || excess > c.room)) revert RollNotLendable();
        fund = c.legs && excess + growth <= c.lendable && excess + next <= c.room;
    }

    /// @dev Drop the rolled loan's record, then record the successor wherever the hub's carry armed it.
    function _move(IAceLenderOps hub, uint256 loanId, uint256 newId, uint256 next, bool fund, uint256 minDebt) private {
        VaultLayout storage $ = layout();
        $.rollHold -= $.rollOf[loanId].need;
        delete $.rollOf[loanId];
        (, bytes4 why,) = hub.tryContinue(newId);
        if (why != AutoPolicyDisarmed.selector) _book($, newId, next, fund, minDebt);
        else if ($.rollHold == 0) $.rollFloor = 0;
    }

    /* ============================== SETTLE DOORS ============================== */

    /// @notice End a vault loan through a product's settle door: by `settleExpired` while the vault promised its roll, else at once.
    /// @notice Then drop the closed loan's roll record, so its share of the hold frees in the same call.
    /// @dev At once is `forceClose` at expiry and `finalize` before it, the curator's duty at a zero bounty; a loan already ended is tolerated.
    function endLoan(address ace, uint256 loanId) internal {
        VaultLayout storage $ = layout();
        Roll memory r = $.rollOf[loanId];
        bytes4 verb = r.funded ? IAceSettle.settleExpired.selector : IAceSettle.forceClose.selector;
        (bool ok, bytes memory err) = ace.call(abi.encodeWithSelector(verb, loanId));
        if (!ok && !r.funded && bytes4(err) == NotExpired.selector) (ok, err) = ace.call(abi.encodeWithSelector(IAceSettle.finalize.selector, loanId));
        if (!ok && bytes4(err) != LoanClosed.selector) LowLevelCall.bubbleRevert(err);
        if (r.need == 0) return;
        delete $.rollOf[loanId];
        if (($.rollHold -= r.need) == 0) $.rollFloor = 0;
    }

    /* ============================== INTERNALS ============================== */

    /// @dev The hub's successor for `debt` at the market's longest term: an upper bound on any roll the market's policies run.
    function _succUp(MarketParams memory mp, uint256 debt) private pure returns (uint256) {
        return Borrower.successorPrincipal(mp.baseBps, mp.minTenor, mp.minDebt, debt, mp.maxTenor);
    }

    /// @dev The hub's roll need for `debt` at the market's longest term: an upper bound on the reservation any arming tenor holds.
    function _needAt(MarketParams memory mp, uint256 debt) private pure returns (uint256) {
        return Borrower.rollNeed(mp.baseBps, mp.minTenor, mp.minDebt, debt, mp.maxTenor);
    }

    /// @dev Record a loan's reservation and lift the dust floor to its market's minDebt.
    function _book(VaultLayout storage $, uint256 loanId, uint256 need, bool funded, uint256 minDebt) private {
        $.rollOf[loanId] = Roll(SafeCast.toUint128(need), funded);
        $.rollHold += need;
        if (minDebt > $.rollFloor) $.rollFloor = minDebt;
    }

    /// @dev Take exactly `units` from the caller, by Permit2 or allowance, and approve custody for exactly that pledge.
    function _pull(address token, uint256 units, address manager, bytes calldata permit2) private {
        IERC20 item = IERC20(token);
        uint256 pre = item.balanceOf(address(this));
        if (permit2.length != 0) Permits.pull(token, msg.sender, units, permit2);
        else item.safeTransferFrom(msg.sender, address(this), units);
        if (item.balanceOf(address(this)) - pre != units) revert PledgeArrivedShort();
        item.forceApprove(manager, units);
    }

    /// @dev Open to this vault and measure what the open paid it.
    function _open(IAceLenderOps hub, IERC20 cash, bytes32 id, Terms memory t, OpenBounds memory bnd) private returns (uint256 loanId, uint256 payout) {
        uint256 held = cash.balanceOf(address(this));
        loanId = hub.open(id, t.units, t.principal, t.tenor, address(this), bnd);
        payout = cash.balanceOf(address(this)) - held;
    }

    /// @dev Rest every unit of idle the market's cash cap admits, on an exact allowance the deposit spends.
    function _rest(IAceLenderOps hub, IERC20 cash, bytes32 id) private {
        uint256 amt = Math.min(cash.balanceOf(address(this)), type(uint128).max - hub.restingOf(id));
        if (amt == 0) return;
        cash.forceApprove(address(hub), amt);
        hub.deposit(id, amt);
    }

    /// @dev Withdraw every resting unit; skipped at zero, where the hub refuses `NothingResting`, and never dust, as it takes all.
    function _drain(IAceLenderOps hub, bytes32 id) private {
        if (hub.restingOf(id) != 0) hub.withdraw(id, type(uint256).max, address(this), 0);
    }
}
