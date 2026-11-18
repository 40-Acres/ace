// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.36;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {IERC721} from "@openzeppelin/contracts/token/ERC721/IERC721.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {Math} from "@openzeppelin/contracts/utils/math/Math.sol";
import {LowLevelCall} from "@openzeppelin/contracts/utils/LowLevelCall.sol";
import {TransientSlot} from "@openzeppelin/contracts/utils/TransientSlot.sol";
import {LoanClosed, LoanMatured} from "../ace/hub/Borrower.sol";
import {EmptyPot} from "../ace/hub/Lender.sol";
import {NotExpired} from "../ace/hub/Settlement.sol";
import {LoanMath} from "../ace/hub/libraries/LoanMath.sol";
import {Permits} from "../ace/hub/libraries/Permits.sol";
import {Probe} from "../ace/hub/libraries/Probe.sol";
import {MarketParams, MigrateArgs, OpenBounds} from "../ace/hub/Types.sol";
import {HubLoanTerm} from "../interfaces/HubLoanTerm.sol";
import {IAceLenderOps} from "../interfaces/IAceLenderOps.sol";
import {IAceVaultDoor} from "../interfaces/IAceVaultDoor.sol";
import {IAceVaultOps} from "../interfaces/IAceVaultOps.sol";
import {IPersistenceRecord} from "../interfaces/IPersistenceRecord.sol";
import {IVaultTerms, Lend, RefinanceRequest} from "../interfaces/IVaultTerms.sol";
import {AceVaultCaps} from "./AceVaultCaps.sol";
import {AceVaultTail} from "./AceVaultTail.sol";

/// @notice Everything a deploy fixes about one vault: EVERY FIELD IS WRITE-ONCE, with no setter, no pause and no upgrade.
struct VaultConfig {
    address ace;
    address asset;
    address curator;
    address guardian; // may switch the drain ON and never off, cut caps, and exempt dead pots and goods from entry; in kind not zero
    uint16 perfFeeBps; // bps of NAV GROWTH past a high-water mark, at most `MAX_PERF_FEE_BPS`, minted as shares; zero charges nothing
    uint64 vestWindow; // how long a NAV rise takes to become spendable; railed at both ends, as too short a window opens a repayment sandwich
    uint256 seed; // the least asset the vault's address must hold at construction, at least `MIN_SEED` atoms; all it holds is booked as dead shares
}

/// @notice What a borrower asks the core door for; a product reads the fields its terms need and ignores the rest.
struct BorrowRequest {
    address collateral;
    uint256 units;
    uint256 principal;
    uint64 tenor; // zero takes the market's shortest
    uint256 minPayout; // the least cash the borrower accepts, held by the hub's open
    uint256 minBufferWad; // the least gap between the market's price and the loan's trigger, where a product passes it on
    uint64 deadline; // the latest second the open may land, or zero for none
}

/// @notice What a product admits, beside the market it built: the draw and its term.
struct Terms {
    uint256 units;
    uint256 principal;
    uint64 tenor; // zero takes the market's shortest
    uint256 minBufferWad;
}

/// @notice One holder's exit request: the shares it escrows on the vault, and when it lapses unless renewed.
struct Request {
    uint256 shares; // escrowed until claimed, cancelled or lapsed; a full word, as a share is a millionth of an asset atom at par
    uint64 expiresAt; // from here anyone may lapse it; a further request renews it
}

/// @notice One cap key's entry: a collateral's row, the wildcard at `address(0)`, or the total at the vault's own address.
struct Cap {
    uint192 cap; // in asset units
    bool listed; // a collateral's own row stands; unlisted, the wildcard's cap applies
}

/// @notice A cap change waiting out the timelock: the new cap and the time it may be accepted from; it never expires.
struct PendingCap {
    Cap value;
    uint64 validAt;
}

/// @notice One collateral's goods at a door-mode vault's door: their booked value less cash returned, a pending write-off, and the entry gate.
struct Seizure {
    uint184 value; // booked at each collect, a recorded pot at its claim, saturating; falls by cash returned, saturating, and to zero at a write-off
    uint64 writeOffAt; // a pending write-off's due time; zero is none, and a collect on the key voids it
    bool open; // the key shuts entry: set by a collect that hands over units, cleared by a closing return or an accepted write-off
}

/// @notice A vault's vest, fee, request, exemption and cap state: one ERC-7201 namespace, shared by `AceVault` and its linked libraries.
/// @dev The caps, the pending caps, `navHigh` and the door's ledger are APPENDED, so every member above keeps its slot.
/// @custom:storage-location erc7201:ace.curatorvault
struct VaultLayout {
    uint256 feeHighWater; // fee threshold in assets: a collection lifts it to NAV; an entry or an exit carries it per virtual share
    uint256 navMark; // gross NAV at the last sync; a rise above it defers, a fall passes through
    uint128 vestBasis; // grossed, read back as basis * (maturity - now) / VEST_WINDOW
    uint64 vestMaturity; // when the deferred pile finishes; it only ever moves LATER
    bool draining; // lending stopped: no placement, no extension, entry shut; packs into the vest's word
    uint48 troughHold; // zero none; all ones a material loss seen over an unsold pot; else the second the hold lifts by; packs into the vest's word
    uint256 requestedShares; // escrowed shares of every standing request
    mapping(address holder => Request) requests;
    uint256 exemptSettled; // the hub's settled count at the guardian's last dead-pot exemption; any settlement since voids it, and a collect zeroes it then
    mapping(address key => Cap) caps;
    mapping(address key => PendingCap) pendingCaps;
    uint256 navHigh; // gross NAV's high-water: a sync lifts it, an entry adds its cash, an exit or a claim takes its cash; never reset
    mapping(address collateral => Seizure) seized; // door mode: goods handed to the door, keyed by the market's collateral
    uint256 openSeized; // door mode: the keys still open, each shutting entry
}

/// @notice What a vault hands its door body: the cash, custody, and the bounds it read before resting anything.
struct Ctx {
    address asset;
    address manager; // the hub's custodian, approved for exactly the pledge
    uint256 lendable; // what the requests' hold leaves a placement
    uint256 room; // the collateral's cap room
}

/// @notice A refinance's successor between its stages: the market and draw, the market id, and the hub's lent figures before the call.
struct Refi {
    MarketParams mp;
    Terms t; // the base's admitted draw, its term resolved
    bytes32 id;
}

/// @dev The two settle verbs `endLoan` ends a loan by, named for their selectors.
interface IAceSettle {
    function finalize(uint256 id) external;
    function forceClose(uint256 id) external;
}

/// @title AceVaultFlows
/// @notice AceVault's storage and linked bodies: the core door, the loan end, the other lending doors, and door mode's collect, return and write-off.
/// @notice DELEGATECALL-linked: each runs as the vault; a forwarded verb takes the vault's calldata unchanged and reads its figures from the appended suffix.
/// @notice NOTHING THE VAULT FUNDS RESTS ACROSS A CALL: a market's cash is zero between calls.
/// @dev A member that writes runs only through the vault's guarded wrappers; the library's call protection refuses a direct call.
library AceVaultFlows {
    using SafeERC20 for IERC20;

    error OutsideEnvelope(); // the market quotes something other than this vault's asset
    error NotOurLender(); // the market names somebody else as its one lender
    error CashIsNotCollateral(); // a forfeit of the vault's own cash would strand outside its idle
    error SharesAreNotCollateral(); // a forfeit of the vault's own share would sit on it as a donation nobody can request or sell
    error PaysSettleBounty(); // a vault market pays no settle bounty: settling the vault's loans is its own duty
    error PledgeArrivedShort(); // fewer collateral units landed than the terms pledge
    error OverLendable(); // the placement passes what the requests' hold leaves lendable
    error OverCap(); // the placement passes the collateral's cap room

    /// @notice The core door lent: the loan, its market, who took it, and what it paid.
    event Borrowed(uint256 indexed loanId, bytes32 indexed market, address indexed borrower, uint256 units, uint256 principal, uint256 payout);

    uint256 internal constant MIN_SEED = 1e4; // the least genesis seed, in atoms; the vault's `MIN_SEED`, here so a deploy can name it
    uint16 internal constant HOLD_BPS = 1; // the trough hold weighs a loss or a pile against this share of the mark, and MIN_SEED atoms
    uint16 internal constant GATE_BPS = 500; // entry shuts while a gain over this share of NAV vests
    uint256 internal constant VIRTUAL_SHARES = 1e6; // the vault's share offset, 10 ** its `_decimalsOffset`
    uint256 internal constant Q96 = 1 << 96; // the hub's price frame
    bytes32 internal constant ROOT = 0xb7a4de03362d20465bcc8b45bb9625cb4abe76f109b674085f908e1bc61c7000; // erc7201:ace.curatorvault
    bytes32 internal constant LENDING = 0xb4c2d4b34891c0765211169272b8bce7558ad3adc06ef150053a535d7120ce00; // erc7201:ace.curatorvault.lending, transient
    bytes32 internal constant BOOKED = bytes32(uint256(LENDING) + 2); // transient: a door collect's booked rise, read by its trailing sync

    /// @notice The vault's state, at its ERC-7201 root.
    function layout() internal pure returns (VaultLayout storage $) {
        bytes32 slot = ROOT;
        assembly ("memory-safe") {
            $.slot := slot
        }
    }

    /// @dev Whether `x` is material to the trough hold against `ref`: over `MIN_SEED` atoms and over `HOLD_BPS` of `ref`, compared without a product.
    function material(uint256 x, uint256 ref) internal pure returns (bool) {
        return x > MIN_SEED && x > Math.mulDiv(ref, HOLD_BPS, 10_000);
    }

    /// @dev Whether a pile `u` is still vesting against NAV `a`: over `floor` and over `GATE_BPS` of `a`.
    function gainVesting(uint256 u, uint256 a, uint256 floor) internal pure returns (bool) {
        return u > floor && u * 10_000 > a * GATE_BPS;
    }

    /// @dev Whether entry waits on a pot: one unsold at the hub or a door key open, and no exemption at the hub's settled count `s`.
    function unsold(uint256 hubUnsold, uint256 openKeys, uint256 s, uint256 exempt) internal pure returns (bool) {
        return (hubUnsold != 0 || openKeys != 0) && s != exempt;
    }

    /// @dev The maturity a rise of `d` stamped now onto a pile of `u` maturing at `m` leaves, over a window of `w` seconds.
    function blended(uint256 u, uint256 d, uint256 m, uint256 w) internal view returns (uint64) {
        uint256 end = block.timestamp + w;
        return uint64((u == 0 || m <= block.timestamp) ? end : m + Math.mulDiv(end - m, d, u + d));
    }

    /// @notice A door-mode booking of `units` at `price`, `units * price >> 96` floored and saturating; a door computing one must call this.
    function bookValue(uint256 units, uint256 price) internal pure returns (uint256) {
        (bool fits, uint256 v) = Math.tryMul(units, price);
        return fits ? v >> 96 : type(uint256).max;
    }

    /// @notice A collected pot's senior claim: the `bookValue` of the pot, capped at the claim's need, `ceil(debt * 2^96 / price)` units.
    /// @dev The debt is the loan's stored word, read raw: a settlement leaves it in place, while the hub's `debtOf` reads zero once the loan closed.
    /// @param ace The loan's hub.
    /// @param loanId The settled loan the pot came from.
    /// @param pot The units collected.
    /// @param price The loan's market price.
    /// @return The senior claim, in the quote.
    function seniorClaim(address ace, uint256 loanId, uint256 pot, uint256 price) internal view returns (uint256) {
        uint256 debt = uint256(IAceVaultOps(ace).extsload(HubLoanTerm.debtSlot(loanId)));
        return bookValue(Math.min(pot, Math.mulDiv(debt, Q96, price, Math.Rounding.Ceil)), price);
    }

    /* ============================== THE DOOR ============================== */

    /// @notice The door's market checks, moving nothing: `self` the lender, `asset` the quote, neither own token the collateral, no settle bounty.
    function checkMarket(MarketParams memory mp, address asset, address self) internal pure {
        if (mp.lender != self) revert NotOurLender();
        if (mp.quote != asset) revert OutsideEnvelope();
        if (mp.collateral == asset) revert CashIsNotCollateral();
        if (mp.collateral == self) revert SharesAreNotCollateral();
        if (mp.settleBountyBps != 0) revert PaysSettleBounty();
    }

    /// @notice The door's checks and pledge: the market is this vault's, the placement fits, and exactly the units arrived.
    /// @dev Runs before the product's write hook, so the borrower's pull meets no primed product; custody's in `hub.open` runs primed, under the hub's lock.
    /// @return id The market id.
    function place(Ctx memory c, MarketParams memory mp, Terms memory t, bytes calldata permit2) public returns (bytes32 id) {
        checkMarket(mp, c.asset, address(this));
        if (t.principal > c.lendable) revert OverLendable();
        if (t.principal > c.room) revert OverCap();
        _pull(mp.collateral, t.units, c.manager, permit2);
        id = keccak256(abi.encode(mp));
    }

    /// @notice The door's hub leg: create the market if missing, rest all idle, open to this vault, withdraw every unit.
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
        _rest(hub, IERC20(mp.quote), id, type(uint256).max, 1);
        (loanId, payout) = _open(hub, IERC20(mp.quote), id, t, OpenBounds(minPayout, t.minBufferWad, deadline));
        _drain(hub, id);
        emit Borrowed(loanId, id, msg.sender, t.units, t.principal, payout);
    }

    /* ============================== THE LOAN END ============================== */

    /// @notice End a vault loan before its pot is collected: `forceClose` from expiry, `finalize` on distress before it; a loan already ended is tolerated.
    function endLoan(address ace, uint256 loanId) internal {
        (bool ok, bytes memory err) = ace.call(abi.encodeWithSelector(IAceSettle.forceClose.selector, loanId));
        if (!ok && bytes4(err) == NotExpired.selector) (ok, err) = ace.call(abi.encodeWithSelector(IAceSettle.finalize.selector, loanId));
        if (!ok && bytes4(err) != LoanClosed.selector) LowLevelCall.bubbleRevert(err);
    }

    /* ============================== DOOR MODE ============================== */

    /// @notice End each named loan of this vault's and hand its pot to the door, booked at its claim, or whole with no record; an empty or taken pot is zero.
    /// @dev Behind the wrapper's door check and sync; it leaves the booked rise in `BOOKED` for the trailing sync and zeroes an exemption since voided.
    /// @return out The units each id handed over.
    function collectForfeited(uint256[] calldata ids) external returns (uint256[] memory out) {
        (address ace, address asset) = (AceVaultTail.ace(), AceVaultTail.asset());
        IAceLenderOps hub = IAceLenderOps(ace);
        VaultLayout storage $ = layout();
        out = new uint256[](ids.length);
        uint256 booked;
        for (uint256 i; i < ids.length; ++i) {
            MarketParams memory mp = hub.idToMarketParams(hub.loanMarket(ids[i]));
            if (mp.lender != address(this) || mp.quote != asset) revert IAceVaultDoor.NotOurLoan();
            endLoan(ace, ids[i]);
            out[i] = _handOver(ace, ids[i]);
            if (out[i] != 0) booked = Math.saturatingAdd(booked, _book($, ace, ids[i], mp, out[i]));
        }
        TransientSlot.tstore(TransientSlot.asUint256(BOOKED), booked);
        _voidStaleExemption(hub, asset, $);
    }

    /// @dev Zero an exemption a settlement since has voided, so the policy's storage-only read sees the door's keys as unexempted.
    function _voidStaleExemption(IAceLenderOps hub, address asset, VaultLayout storage $) private {
        uint256 x = $.exemptSettled;
        if (x == 0) return;
        (, uint256 s) = hub.lenderUnresolved(address(this), asset);
        if (s != x) $.exemptSettled = 0;
    }

    /// @notice Take `cash` from the door against key `c`, and close `c` from the entry gate if `closes`; only `(c, 0, false)` refuses.
    /// @dev The cash is pulled on the door's exact allowance and measured; the key's value falls by it, saturating, whatever the key.
    function returnProceeds(address c, uint256 cash, bool closes) external {
        if (cash == 0 && !closes) revert IAceVaultDoor.NothingReturned();
        VaultLayout storage $ = layout();
        Seizure storage s = $.seized[c];
        if (cash != 0) {
            IERC20 a = IERC20(AceVaultTail.asset());
            uint256 pre = a.balanceOf(address(this));
            a.safeTransferFrom(msg.sender, address(this), cash);
            if (a.balanceOf(address(this)) - pre != cash) revert IAceVaultDoor.ProceedsShort();
            s.value = uint184(Math.saturatingSub(s.value, cash));
        }
        bool closed = closes && s.open;
        if (closed) _close($, s);
        emit IAceVaultDoor.ProceedsReturned(c, cash, closed);
    }

    /// @notice Queue a write-off of key `c`'s residue, due after the cap timelock. CURATOR ONLY; an empty key refuses `NothingSeized`.
    function submitWriteOff(address c) external {
        if (msg.sender != AceVaultTail.curator()) revert IAceVaultDoor.NotCurator();
        Seizure storage s = layout().seized[c];
        if (s.value == 0 && !s.open) revert IAceVaultDoor.NothingSeized();
        uint64 at = uint64(block.timestamp) + AceVaultTail.capTimelock();
        s.writeOffAt = at;
        emit IAceVaultDoor.WriteOffSubmitted(c, at);
    }

    /// @notice Land key `c`'s write-off once due: its value goes to zero and it closes. PERMISSIONLESS.
    function acceptWriteOff(address c) external {
        VaultLayout storage $ = layout();
        Seizure storage s = $.seized[c];
        uint64 at = s.writeOffAt;
        if (at == 0 || block.timestamp < at) revert IAceVaultDoor.NothingDue();
        uint256 forgiven = s.value;
        (s.value, s.writeOffAt) = (0, 0);
        if (s.open) _close($, s);
        emit IAceVaultDoor.WriteOffAccepted(c, forgiven);
    }

    /// @notice Drop key `c`'s pending write-off. The curator or the guardian; with none pending it refuses `NothingDue`.
    function revokeWriteOff(address c) external {
        if (msg.sender != AceVaultTail.curator() && msg.sender != AceVaultTail.guardian()) revert IAceVaultDoor.NotCurator();
        Seizure storage s = layout().seized[c];
        if (s.writeOffAt == 0) revert IAceVaultDoor.NothingDue();
        s.writeOffAt = 0;
        emit IAceVaultDoor.WriteOffRevoked(msg.sender, c);
    }

    /// @dev One loan's pot to the door, the caller; an empty pot is nothing to hand over.
    function _handOver(address ace, uint256 loanId) private returns (uint256) {
        (bool ok, bytes memory r) = ace.call(abi.encodeCall(IAceVaultOps.redeemInKind, (loanId, msg.sender)));
        if (ok) return abi.decode(r, (uint256));
        if (r.length != 4 || bytes4(r) != EmptyPot.selector) LowLevelCall.bubbleRevert(r);
        return 0;
    }

    /// @dev Book a pot of `units` on its collateral's key, saturating at the record's width, void a pending write-off, open the key, and return the rise.
    /// @dev A recorded pot books the claim it retired, `seniorClaim`, since an in-term take above the need is owed no recovery; a recordless pot books whole.
    function _book(VaultLayout storage $, address ace, uint256 loanId, MarketParams memory mp, uint256 units) private returns (uint256 rise) {
        address c = mp.collateral;
        Seizure storage s = $.seized[c];
        uint256 was = s.value;
        uint256 v = mp.record == address(0) ? bookValue(units, mp.price) : seniorClaim(ace, loanId, units, mp.price);
        s.value = uint184(Math.min(Math.saturatingAdd(was, v), type(uint184).max));
        if (s.writeOffAt != 0) {
            s.writeOffAt = 0;
            emit IAceVaultDoor.WriteOffRevoked(msg.sender, c);
        }
        if (!s.open) {
            s.open = true;
            $.openSeized++;
        }
        rise = s.value - was;
        emit IAceVaultDoor.Seized(loanId, c, units, rise);
    }

    /// @dev Close an open key from the entry gate.
    function _close(VaultLayout storage $, Seizure storage s) private {
        s.open = false;
        $.openSeized--;
    }

    /* ============================== THE RENEWAL ============================== */

    /// @notice Extend a loan of this vault's in place for its title holder, the caller: the hub's fee on the time added, pulled from the holder.
    /// @notice The vault reaches the hub as the holder's title operator, so a holder who approved it for the title renews as the holder would.
    /// @notice Unapproved, the vault is a non-holder at the hub, and renews only where any caller could.
    /// @dev The exit gate is the wrapper's transient word, written before the pull, so the fee in flight never covers the requests.
    /// @return fee The fee the hub charged.
    function extendFor(uint256 loanId, uint256 maxFee, uint256 minBufferWad, bytes calldata data, bytes calldata permit2) external returns (uint256 fee) {
        (MarketParams memory mp, uint64 added) = _extendable(loanId);
        fee = LoanMath.originationFee(IAceVaultOps(AceVaultTail.ace()).debtOf(loanId), added, mp.lenderAprBps);
        if (fee > maxFee) revert IAceVaultDoor.FeeOverMax();
        _pullFee(fee, permit2);
        _bracketed(loanId, minBufferWad, mp, data, fee);
        emit IAceVaultDoor.Renewed(loanId, msg.sender, added, fee);
    }

    /// @dev The product's write calls around the hub's extend: `beforeLend` after the pull, `afterLend` once the fee checks.
    function _bracketed(uint256 loanId, uint256 minBufferWad, MarketParams memory mp, bytes calldata data, uint256 fee) private {
        IVaultTerms terms = IVaultTerms(AceVaultTail.terms());
        terms.beforeLend(Lend.Extend, mp, loanId, data);
        _extendExact(loanId, minBufferWad, data, fee);
        terms.afterLend(Lend.Extend, mp, loanId, msg.sender, data);
    }

    /// @dev The renewal's refusals before any pull: the held loan's, then the exit gate.
    /// @return mp The loan's market.
    /// @return added The time the extension adds: the loan's own tenor from now, past its expiry.
    function _extendable(uint256 loanId) private view returns (MarketParams memory mp, uint64 added) {
        uint64 tenor;
        uint64 expiry;
        (mp, tenor, expiry) = _heldLoan(loanId);
        if (TransientSlot.tload(TransientSlot.asUint256(LENDING)) == 0) revert IAceVaultDoor.RequestsOutweighIdle();
        added = uint64(Math.saturatingSub(block.timestamp + tenor, expiry));
    }

    /// @dev Every lending door's first refusals on a live loan: the caller holds its title, it is this vault's in its asset, and it has not matured.
    /// @return mp The loan's market.
    /// @return tenor The loan's tenor.
    /// @return expiry The loan's expiry.
    function _heldLoan(uint256 loanId) private view returns (MarketParams memory mp, uint64 tenor, uint64 expiry) {
        address ace = AceVaultTail.ace();
        IAceLenderOps hub = IAceLenderOps(ace);
        if (IAceVaultOps(ace).borrowerOf(loanId) != msg.sender) revert IAceVaultDoor.NotTheBorrower();
        mp = hub.idToMarketParams(hub.loanMarket(loanId));
        if (mp.lender != address(this) || mp.quote != AceVaultTail.asset()) revert IAceVaultDoor.NotOurLoan();
        (, tenor, expiry) = HubLoanTerm.decode(IAceVaultOps(ace).extsload(HubLoanTerm.slot(loanId)));
        if (block.timestamp >= expiry) revert LoanMatured();
    }

    /// @dev Pull exactly `fee` from the caller, by Permit2 or allowance, measured.
    function _pullFee(uint256 fee, bytes calldata permit2) private {
        address asset = AceVaultTail.asset();
        IERC20 cash = IERC20(asset);
        uint256 held = cash.balanceOf(address(this));
        if (permit2.length != 0) Permits.pull(asset, msg.sender, fee, permit2);
        else cash.safeTransferFrom(msg.sender, address(this), fee);
        if (cash.balanceOf(address(this)) - held < fee) revert IAceVaultDoor.FeePaidShort();
    }

    /// @dev Approve the hub exactly the fee, extend, zero the allowance, and check the hub took the fee priced.
    function _extendExact(uint256 loanId, uint256 minBufferWad, bytes calldata data, uint256 fee) private {
        address ace = AceVaultTail.ace();
        IERC20 cash = IERC20(AceVaultTail.asset());
        cash.forceApprove(ace, fee);
        uint256 paid = IAceVaultOps(ace).extend(loanId, minBufferWad, data);
        cash.forceApprove(ace, 0);
        if (paid != fee) revert IAceVaultDoor.FeeMismatch();
    }

    /* ============================== THE REFINANCE ============================== */

    /// @notice Refinance a loan of this vault's for its title holder, the caller, into the product's market, holding its title for this call alone.
    /// @dev The exit gate is the wrapper's transient word, asked only of a successor ending after the old expiry, as the vault's own policy asks it.
    /// @return newId The successor loan.
    /// @return out The net the hub paid this vault, sent on to the caller.
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
        return _refinance(loanId, RefinanceRequest(collateral, principal, tenor, minPayout, minBufferWad, deadline, withdrawUnits, withdrawTo), data);
    }

    /// @dev The refinance in its stages, on the request as one struct.
    function _refinance(uint256 loanId, RefinanceRequest memory r, bytes calldata data) private returns (uint256 newId, uint256 out) {
        Refi memory f = _refinanceable(loanId, r, data);
        IVaultTerms terms = IVaultTerms(AceVaultTail.terms());
        IERC721(AceVaultTail.title()).transferFrom(msg.sender, address(this), loanId);
        terms.beforeLend(Lend.Refinance, f.mp, loanId, data);
        (newId, out) = _refinanceAtHub(f, loanId, r);
        _home(f, loanId, newId, out);
        terms.afterLend(Lend.Refinance, f.mp, newId, msg.sender, data);
        emit IAceVaultDoor.Refinanced(loanId, newId, msg.sender, f.t.principal, out);
    }

    /// @dev The successor and its draw: the held loan's refusals, the withdraw leg, the product's answer, the exit gate on a lengthening, and the room.
    function _refinanceable(uint256 loanId, RefinanceRequest memory r, bytes calldata data) private view returns (Refi memory f) {
        (,, uint64 expiry) = _heldLoan(loanId);
        if (r.withdrawTo == address(this)) revert IAceVaultDoor.WithdrawToVault();
        f = _answer(loanId, r, data);
        bool covered = TransientSlot.tload(TransientSlot.asUint256(LENDING)) != 0;
        if (block.timestamp + f.t.tenor > expiry && !covered) revert IAceVaultDoor.RequestsOutweighIdle();
        _refinanceRoom(f, IAceVaultOps(AceVaultTail.ace()).debtOf(loanId));
    }

    /// @dev The product's refinance answer to `r` and the base's checks on it: the market is this vault's, the draw bound to the ask and the rail.
    function _answer(uint256 loanId, RefinanceRequest memory r, bytes calldata data) private view returns (Refi memory f) {
        (f.mp, f.t) = IVaultTerms(AceVaultTail.terms()).refinanceTerms(msg.sender, loanId, r, data);
        checkMarket(f.mp, AceVaultTail.asset(), address(this));
        BorrowRequest memory b = BorrowRequest(r.collateral, f.t.units, r.principal, r.tenor, r.minPayout, r.minBufferWad, r.deadline);
        bool hubAsk = !AceVaultTail.inKind() && !AceVaultTail.door();
        f.t = AceVaultCaps.admit(b, f.mp, f.t, hubAsk, AceVaultTail.minTenor(), AceVaultTail.maxTenor());
        if (f.t.tenor == 0) f.t.tenor = f.mp.minTenor;
        f.id = keccak256(abi.encode(f.mp));
    }

    /// @dev The net new cash, principal over old debt, under lendable and the total's, row's and product's room; once, as the call raises lent by exactly it.
    function _refinanceRoom(Refi memory f, uint256 debtOld) private view {
        (address ace, address asset) = (AceVaultTail.ace(), AceVaultTail.asset());
        uint256 fresh = Math.saturatingSub(f.t.principal, debtOld);
        if (fresh > TransientSlot.tload(TransientSlot.asUint256(bytes32(uint256(LENDING) + 1)))) revert OverLendable();
        uint256 held = IAceLenderOps(ace).lenderAssets(address(this), asset);
        (uint256 row, uint256 total) = AceVaultCaps.room(ace, asset, f.mp.collateral, held, _drawdown(asset, held));
        if (fresh > total) revert AceVaultCaps.OverTotal();
        if (fresh > row || fresh > IVaultTerms(AceVaultTail.terms()).room(f.mp)) revert OverCap();
    }

    /// @dev Create the market if missing, rest at most the principal unless the record sits under the price, refinance as holder of record, then drain.
    function _refinanceAtHub(Refi memory f, uint256 loanId, RefinanceRequest memory r) private returns (uint256 newId, uint256 out) {
        address ace = AceVaultTail.ace();
        IAceLenderOps hub = IAceLenderOps(ace);
        IERC20 cash = IERC20(f.mp.quote);
        if (hub.idToMarketParams(f.id).quote == address(0)) hub.createMarket(f.mp);
        if (!_underPrice(f.mp)) _rest(hub, cash, f.id, f.t.principal, f.mp.minPrincipal);
        uint256 held = cash.balanceOf(address(this));
        OpenBounds memory bnd = OpenBounds(r.minPayout, f.t.minBufferWad, r.deadline);
        newId = IAceVaultOps(ace).refinanceTo(MigrateArgs(loanId, f.id, f.t.principal, f.t.tenor, bnd, r.withdrawUnits, r.withdrawTo));
        out = cash.balanceOf(address(this)) - held;
        _drain(hub, f.id);
    }

    /// @dev Send both titles and the net home; the hub's refinance credits the retired loan nothing, so no claim strands on it.
    function _home(Refi memory f, uint256 loanId, uint256 newId, uint256 out) private {
        IERC721 t = IERC721(AceVaultTail.title());
        t.transferFrom(address(this), msg.sender, newId);
        t.transferFrom(address(this), msg.sender, loanId);
        if (out != 0) IERC20(f.mp.quote).safeTransfer(msg.sender, out); // as the hub skips a zero net, for an asset that refuses zero transfers
    }

    /// @dev Gross NAV's fall below its high-water, with the hub holding `held`: the vault's own figure, read here off the same two balances.
    function _drawdown(address asset, uint256 held) private view returns (uint256) {
        return Math.saturatingSub(layout().navHigh, IERC20(asset).balanceOf(address(this)) + held);
    }

    /* ============================== THE TOP-UP ============================== */

    /// @notice Draw `amount` more on a loan of this vault's for its title holder, the caller, in place: the same loan and term, at its market's price.
    /// @notice The product consents by its refinance answer at the debt plus `amount`, held to being the loan's own market admitting all of it.
    /// @dev The answer takes the checks and room a refinance's does, the new cash being `amount` alone; the term never moves, so no exit gate asks.
    /// @dev The rest runs before the hub's draw, so an amount under the lot floor or a record under the price refuses at the hub's deposit.
    /// @return fee The fee the hub charged.
    function drawMoreFor(uint256 loanId, uint256 amount, uint256 minPayout, uint256 minBufferWad, uint64 deadline, bytes calldata data)
        external
        returns (uint256 fee)
    {
        fee = _topUp(loanId, amount, RefinanceRequest(address(0), 0, 0, minPayout, minBufferWad, deadline, 0, address(0)), data);
        emit IAceVaultDoor.ToppedUp(loanId, msg.sender, amount, fee);
    }

    /// @dev The held loan's refusals, the answer at the debt plus `amount`, refused unless the loan's own market admits it whole, the room, the hub leg.
    function _topUp(uint256 loanId, uint256 amount, RefinanceRequest memory r, bytes calldata data) private returns (uint256 fee) {
        (MarketParams memory src,,) = _heldLoan(loanId);
        uint256 debt = IAceVaultOps(AceVaultTail.ace()).debtOf(loanId);
        (r.collateral, r.principal) = (src.collateral, debt + amount);
        Refi memory f = _answer(loanId, r, data);
        if (f.id != keccak256(abi.encode(src)) || f.t.principal != r.principal) revert IAceVaultDoor.TopUpRefused();
        _refinanceRoom(f, debt);
        fee = _topUpAtHub(f, loanId, amount, r, data);
    }

    /// @dev Inside the product's write calls: rest exactly `amount`, draw it as the holder's title operator, drain; the hub pays the holder last.
    function _topUpAtHub(Refi memory f, uint256 loanId, uint256 amount, RefinanceRequest memory r, bytes calldata data) private returns (uint256 fee) {
        address ace = AceVaultTail.ace();
        IAceLenderOps hub = IAceLenderOps(ace);
        IVaultTerms terms = IVaultTerms(AceVaultTail.terms());
        terms.beforeLend(Lend.Refinance, f.mp, loanId, data);
        _rest(hub, IERC20(f.mp.quote), f.id, amount, amount);
        fee = IAceVaultOps(ace).drawMore(loanId, amount, OpenBounds(r.minPayout, f.t.minBufferWad, r.deadline));
        _drain(hub, f.id);
        terms.afterLend(Lend.Refinance, f.mp, loanId, msg.sender, data);
    }

    /* ============================== INTERNALS ============================== */

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

    /// @dev Rest idle up to `cap` as the market's cash cap admits, on an exact allowance the deposit spends; nothing under `minLot`.
    function _rest(IAceLenderOps hub, IERC20 cash, bytes32 id, uint256 cap, uint256 minLot) private {
        uint256 amt = Math.min(Math.min(cash.balanceOf(address(this)), cap), type(uint128).max - hub.restingOf(id));
        if (amt < minLot) return;
        cash.forceApprove(address(hub), amt);
        hub.deposit(id, amt);
    }

    /// @dev Whether the market's record reads live under its price, as the hub's deposit reads it: the hub then takes no resting cash and lends none fresh.
    function _underPrice(MarketParams memory mp) private view returns (bool) {
        if (mp.record == address(0)) return false;
        (bool ok, uint256 cap) = Probe.askWord(mp.record, abi.encodeCall(IPersistenceRecord.minPrice, (mp.quote, mp.collateral)));
        return ok && cap != 0 && mp.price > cap;
    }

    /// @dev Withdraw every resting unit; skipped at zero, where the hub refuses `NothingResting`, and never dust, as it takes all.
    function _drain(IAceLenderOps hub, bytes32 id) private {
        if (hub.restingOf(id) != 0) hub.withdraw(id, type(uint256).max, address(this), 0);
    }
}
