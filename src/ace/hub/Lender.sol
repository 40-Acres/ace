// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.36;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {Math} from "@openzeppelin/contracts/utils/math/Math.sol";
import {FullMath} from "@uniswap/v4-core/src/libraries/FullMath.sol";
import {Borrower, RecordUnreadable, ZeroWithdrawTo} from "./Borrower.sol"; // ZeroWithdrawTo is unused here, re-exported for importers of this file
import {Transfers} from "./libraries/Transfers.sol";
import {ExitToHub, Recipients} from "./libraries/Recipients.sol"; // ExitToHub is unused here, re-exported for importers of this file
import {Cfg, LenderCollateral, LenderPools, LenderUnresolved, Market, MarketParams, RecordState, Storage} from "./Types.sol";
import {IPositionManager} from "../../interfaces/IPositionManager.sol";

error NothingResting(); // no cash rests in this market, so there is nothing to withdraw
error WouldLeaveDust(); // a partial withdraw left unreserved cash in `(0, minDebt)`: depth no fresh draw can consume
error EmptyPot(); // no collateral rests against this loan
error SyntheticCapExceeded(); // units left custody beyond what backed burns have credited
error NotTheLender(); // cash or credit booked for anyone but the market's one named lender: the tenancy invariant
error LendingAbovePrice(); // resting cash the market will not lend from is not lending, it is a stale bid
error GateRefused(); // the depositor is not the market's one named lender: sole tenancy refuses the deposit
error BelowMinLot(); // a zero deposit, one under `minDebt` that does more than refill the reserve, or one resting unreserved dust
error CashCapped(); // this deposit would take the market's resting cash past uint128
error UnitsBelowCallerFloor(); // the ask filled fewer units than the buyer's own bound: their number, not the market's
error BelowCallerFloor(); // the caller's own floor refused the fill: a deleverage realized under `minStableOut`, or a withdraw paid under `minPaid`

/// @title Lender
/// @notice The singleton's lender flow: rest cash, collect the accumulated credit, take settled collateral.
/// @notice ONE LENDER PER MARKET, so nothing here apportions: the resting cash and a loan's pot are wholly theirs.
/// @notice `msg.sender` is always the EXTERNAL caller; `withdraw` and `redeemInKind` check it against the market's named lender.
/// @notice `collect` checks no authority: its ledger key IS `msg.sender`, so a caller can only ever spend their own pool.
library Lender {
    using SafeERC20 for IERC20;

    uint256 internal constant MAX_PAGE = 256; // hard ceiling on one page, so no caller can request an OOG read

    /* ===================================================================== */
    /*  ADMISSION -- what a market will and will not take resting cash on     */
    /*  It lives HERE rather than on the hub because `Lender` is LINKED, so   */
    /*  these bytes are charged to the library and not to `Ace`'s own budget. */
    /* ===================================================================== */

    /// @notice Why a market refuses to take resting cash, answered rather than reverted.
    /// @dev PURELY INTERNAL: no error or return carries the ordinal out, so members may be reordered freely.
    enum Refusal {
        None,
        Gate,
        Price,
        Record,
        MinLot,
        CashCap
    }

    /// @dev Raises the market's cash and folds the lender's resting pool in one step, so the two cannot drift.
    /// @dev THE bound `cash <= type(uint128).max` is enforced here, cash's one increaser.
    /// @dev Refused on the RESTING side, whose payer has another route; a draw-side cast would brick draws.
    /// @dev THE POOL IS PER (lender, quote), so this market's cash joins the same lender's other markets.
    /// @dev The CAP stays PER MARKET, deliberately: it bounds one market's own book, never a lender's size.
    function creditCash(Market storage M, uint256 a) private {
        uint256 c = M.s.cash + a;
        if (c > type(uint128).max) revert CashCapped();
        M.s.cash = c;
        Storage.poolOf(M.p).resting += a;
    }

    /// @dev NOT THE ONLY WRITER of this pair -- `Borrower._fund` inlines it on the draw, so a bound added here is owed there too.
    function debitCash(Market storage M, uint256 a) internal {
        M.s.cash -= a;
        Storage.poolOf(M.p).resting -= a;
    }

    /// @notice Whether `msg.sender` could rest `assets` here, answered rather than reverted.
    /// @notice THE one admission spelling, and the deposit door is its only asker.
    /// @dev TOTAL by construction: every refusal is a named ordinal, which is what lets `_refuse` map one to one.
    /// @dev The external read is a staticcall that fails closed, so nothing can mutate before `bookCash`.
    /// @dev A DEPOSIT NAMES NO PRICE AND NO TERM: the market carries both, and the term is checked at the draw.
    /// @param assets The quote that would rest.
    /// @return Why the market refuses, or `None`.
    function restRefusal(Market storage M, Cfg memory c, uint256 assets) internal view returns (Refusal) {
        /// @dev SOLE TENANCY, enforced by the hub: an address compare against the market's one named lender, never a call.
        /// @dev `bookCash` re-asserts the same tenancy where the cash lands, not only where it is asked.
        if (msg.sender != c.p.lender) return Refusal.Gate;
        (bool got, RecordState state, uint256 cap) = Borrower.tryRecordState(c);
        if (!got) return Refusal.Record;
        /// @dev Live ONLY: None admits by ruling, and NoPrice is this door's fail-open case.
        /// @dev A refill only a home roll can draw is exempt: that roll is judged at `min(price, record)`, never capped.
        if (state == RecordState.Live && c.p.price > cap && !_refillsReserve(M, assets)) return Refusal.Price;
        // THE floor is on what ARRIVES; the balance it joins matters only in a roll-reserve deficit, to the dust test below
        if (assets == 0 || (assets < c.p.minDebt && !_refillsReserve(M, assets))) return Refusal.MinLot; // a reserve refill rests no dust
        if (assets > type(uint128).max - M.s.cash) return Refusal.CashCap; // subtracted, so an absurd lot refuses by name, never panics
        // into a deficit, a lot stays within it or clears a whole floor past it; after the cap, so the sum is known to fit
        if (_unreservedDust(M.s.cash + assets, M.s.rollReserve, c.p.minDebt)) return Refusal.MinLot;
        return Refusal.None;
    }

    /// @notice Rest cash in this market. Admission is the caller's to have asked.
    /// @dev No share price exists to defend, so no lock, no virtual shares, no entry valuation.
    function bookCash(Market storage M, Cfg memory c, uint256 assets) internal {
        /// @dev The tenancy invariant, asserted where the cash actually lands rather than only where it is asked.
        if (msg.sender != c.p.lender) revert NotTheLender();
        creditCash(M, assets);
    }

    /// @notice The deposit door: the one admission asked, then the booking, with `msg.sender` as the depositor.
    function openCash(Market storage M, Cfg memory c, uint256 assets) internal {
        Refusal r = restRefusal(M, c, assets);
        if (r != Refusal.None) _refuse(r);
        bookCash(M, c, assets);
    }

    /// @dev The refusal-to-error map, one for one, so a caller tells two refusals apart by selector.
    function _refuse(Refusal r) private pure {
        if (r == Refusal.Gate) revert GateRefused();
        if (r == Refusal.Price) revert LendingAbovePrice();
        if (r == Refusal.Record) revert RecordUnreadable();
        if (r == Refusal.MinLot) revert BelowMinLot();
        revert CashCapped();
    }

    /// @notice One page of an append-only loan list; the hub pays a call site rather than a loop.
    /// @dev Clamps rather than reverts: `limit` over MAX_PAGE yields MAX_PAGE, past-the-end yields empty.
    function slice(uint256[] storage s, uint256 offset, uint256 limit) public view returns (uint256[] memory out) {
        uint256 n = s.length;
        if (offset >= n) return new uint256[](0);
        uint256 take = Math.min(Math.min(n - offset, limit), MAX_PAGE);
        out = new uint256[](take);
        for (uint256 i; i < take; i++) {
            out[i] = s[offset + i];
        }
    }

    event Deposit(bytes32 indexed market, address indexed lender, uint256 assets);
    /// @notice Resting cash left the market; `to` is where the lender sent it.
    event Withdraw(bytes32 indexed market, address indexed lender, address indexed to, uint256 assets);
    /// @notice A lender's accumulated credit in one quote was paid out, across every market they run.
    /// @notice `to` is the lender's own choice on `collect`, and the lender itself on the push at a terminal close.
    event Collected(address indexed lender, address indexed quote, address indexed to, uint256 paid);
    /// @notice A terminal close could not pay the lender: the quote refused, or the transfer ran past its fixed budget; never skipped.
    /// @notice The credit stays for a later push or `collect`.
    /// @notice It carries NO reason: a reason is returndata, and the push reads one word of it and copies nothing more.
    event LenderPushFailed(address indexed lender, address indexed quote, uint256 amount);
    event RedeemedInKind(uint256 indexed loanId, address indexed lender, address to, uint256 units);

    /// @dev Whether `left` rests unreserved cash in `(0, minDebt)`. SATURATING: `left` may sit under the reserve by the lender's consent.
    function _unreservedDust(uint256 left, uint256 reserved, uint256 minDebt) private pure returns (bool) {
        uint256 free = Math.saturatingSub(left, reserved);
        return free != 0 && free < minDebt;
    }

    /// @dev A deposit that only refills a reserve deficit rests no unreserved cash, so the floor has nothing to guard.
    function _refillsReserve(Market storage M, uint256 assets) private view returns (bool) {
        uint256 cash = M.s.cash;
        uint256 reserved = M.s.rollReserve;
        uint256 deficit = Math.saturatingSub(reserved, cash);
        return deficit != 0 && assets <= deficit;
    }

    /// @dev The authority check the market-keyed exits run; the market names its lender in its own id preimage.
    function _onlyLender(Cfg memory c) private view {
        if (msg.sender != c.p.lender) revert NotTheLender();
    }

    /// @notice Rest cash as this market's standing bid at its own price.
    /// @dev `msg.data[0:0]` is the empty-blob sentinel: it routes `_depositCash` back to the allowance pull.
    function depositCash(Market storage M, Cfg memory c, bytes32 id, uint256 a) public {
        _depositCash(M, c, id, a, msg.data[0:0]);
    }

    /// @notice `depositCash` funded by a Permit2 SignatureTransfer instead of a standing ERC20 allowance.
    function depositCashPermit(Market storage M, Cfg memory c, bytes32 id, uint256 a, bytes calldata permit2) public {
        _depositCash(M, c, id, a, permit2);
    }

    /// @notice Withdraw resting cash to `to`; always available, it is the caller's own money.
    /// @notice `to` is the lender's choice of wallet, never zero, the hub or the positionManager; it also routes around a quote's freeze of the lender.
    /// @notice `minPaid` is the lender's floor on the fill: a draw landing first shrinks `paid`, and this refuses that.
    /// @notice A ZERO PAYOUT past every refusal (`NothingResting`, `WouldLeaveDust`) returns 0 silently: no `to` collects zero-value logs.
    /// @dev FLOOR-OR-ZERO ON UNRESERVED CASH: a remainder whose part past the roll reserve lies in `(0, minDebt)` reverts `WouldLeaveDust`.
    /// @dev That part is depth no fresh draw can consume; reserved cash is a roll's to draw, so leaving only it is never dust.
    /// @dev `paid < resting` is the conjunct that keeps emptying always allowed, so a lender's own money stays reachable.
    function withdraw(Market storage M, Cfg memory c, bytes32 id, uint256 assets, address to, uint256 minPaid) public returns (uint256 paid) {
        _onlyLender(c);
        Recipients.check(to, c.positionManager);
        uint256 resting = M.s.cash;
        if (resting == 0) revert NothingResting();
        paid = Math.min(assets, resting);
        if (paid < minPaid) revert BelowCallerFloor();
        if (paid < resting && _unreservedDust(resting - paid, M.s.rollReserve, c.p.minDebt)) revert WouldLeaveDust();
        if (paid == 0) return 0; // after every refusal, so only the log and the zero transfer are dropped
        debitCash(M, paid);
        IERC20(c.p.quote).safeTransfer(to, paid);
        emit Withdraw(id, msg.sender, to, paid);
    }

    /// @notice Pay the caller's whole pool in one quote to `to`: fees, repayments, sale proceeds, every market.
    /// @notice LENDER-ONLY by construction: the ledger key is `msg.sender`, so a caller can only ever spend their own pool.
    /// @notice ONE CALL COVERS EVERY MARKET they run in this quote, because the pool is keyed by the pair.
    /// @dev The recipient rule runs BEFORE the empty-pool return, so a bad `to` is refused even when nothing is owed.
    /// @dev A SEPARATE TRANSACTION from any close, so a quote that reverts fails only this call; it recovers a refused push.
    /// @dev Nothing is lost if the lender never calls: the pool keeps the money, sale proceeds included, until a close's push or this call takes it.
    /// @param custodian The hub's positionManager, passed in because a pool names no market to read it from.
    function collect(address quote, address to, address custodian) public returns (uint256 paid) {
        Recipients.check(to, custodian);
        LenderPools storage pool = Storage.lenders().pools[msg.sender][quote];
        paid = pool.owed;
        if (paid == 0) return 0;
        pool.owed = 0; // CEI: the pool clears before the token moves
        IERC20(quote).safeTransfer(to, paid);
        emit Collected(msg.sender, quote, to, paid);
    }

    /* ===================================================================== */
    /*  THE ASK -- one settled loan's pot, priced at the market's own price   */
    /* ===================================================================== */

    /// @dev Only the scalars the ask needs; the hub holds tokens and does the transfers.
    struct FillCfg {
        uint256 unitScale;
        uint256 fillFeeBps;
        uint256 askFloor; // the ask never prices below this; 0 means no floor (no record wired)
        uint256 price; // THE MARKET'S OWN, and it must never be a loan's funding floor -- see the note on `fillAsk`
    }

    struct BuyArgs {
        uint256 stableIn;
        uint256 minUnitsOut;
    }

    /// @dev Aggregate of a buy: units out and stable filled are one result.
    struct BuyOut {
        uint256 unitsOut;
        uint256 stableFilled;
    }

    /// @notice Buy collateral out of ONE settled loan's pot.
    /// @notice There is NO bid side: collateral enters a pot only by title transfer at settlement.
    /// @dev Proceeds (fee included) go straight to the lender's pool: the seller is the market's one lender.
    /// @dev CEI: the pot is debited HERE, before the hub moves any token.
    /// @dev Permissionless. The gate is economic -- the ask price and the caller's own bound -- never identity.
    /// @dev NO FLAG AND NO CLOCK HERE: whether a market sells its pots at all, and when one may be bought, are both gated in the hub verb.
    /// @dev `cfg.price` IS `MarketParams.price`, NEVER a funding floor: the claim has retired, so that reads zero and the ask under-prices or bricks.
    function fillAsk(Market storage M, uint256 loanId, FillCfg memory cfg, BuyArgs memory a) external returns (BuyOut memory o) {
        uint256 pot = M.invPotOf[loanId];
        if (pot != 0) {
            (uint256 deliver, uint256 total) = _askLeg(pot, a.stableIn, cfg);
            if (total != 0) {
                _debitPot(M, loanId, pot, deliver); // inside both guards, so the pot is nonzero
                Storage.poolOf(M.p).owed += total;
                (o.stableFilled, o.unitsOut) = (total, deliver);
            }
        }
        if (o.unitsOut < a.minUnitsOut) revert UnitsBelowCallerFloor();
    }

    /// @dev The ask: units delivered and quote paid (incl. fee) at the market's price.
    /// @dev THE FLOOR: the ask is `max(price, askFloor)`, so a nonzero floor lifts it or the arb takes the gap.
    /// @dev PAY FOR WHAT YOU RECEIVE: `deliver` settles first and the charge re-prices off it, never off `take`.
    /// @dev The re-price rounds UP, so the pot is never short of the ask value of what left it.
    /// @dev The charge's fee rounds UP too; on the part leg the charge stays within `remaining` ONLY because `effPrice` ceils the same fee: keep both UP.
    /// @dev THE WHOLE POT SELLS WHOLE: a take of all of it delivers every atom at the ceiled charge, if the budget covers it, so a pot can empty.
    /// @dev ORDER: the whole-pot test precedes the `gross == 0` return, which a sub-quantum tail always hits; `take == inv` bounds its `g` by `remaining`.
    function _askLeg(uint256 inv, uint256 remaining, FillCfg memory cfg) private pure returns (uint256 deliver, uint256 total) {
        uint256 askPrice = Math.max(cfg.price, cfg.askFloor);
        // all-in price per unit incl. fee, fee rounded UP so the part leg's total never exceeds `remaining`
        uint256 effPrice = askPrice + Math.ceilDiv(askPrice * cfg.fillFeeBps, 10000);
        uint256 affordable = FullMath.mulDiv(remaining, cfg.unitScale, effPrice);
        uint256 take = Math.min(inv, affordable);
        if (take == 0) return (0, 0);
        if (take == inv) {
            uint256 g = FullMath.mulDivRoundingUp(inv, askPrice, cfg.unitScale);
            total = g + Math.ceilDiv(g * cfg.fillFeeBps, 10000); // raw, as on the part leg: the 50 bps genesis fee cap keeps it far from overflow
            if (total <= remaining) return (inv, total);
        }
        uint256 gross = FullMath.mulDiv(take, askPrice, cfg.unitScale);
        if (gross == 0) return (0, 0);
        deliver = FullMath.mulDiv(gross, cfg.unitScale, askPrice); // whole units that quote buys; a part sale leaves its sub-unit dust in the pot
        gross = FullMath.mulDivRoundingUp(deliver, askPrice, cfg.unitScale); // re-priced off what LEAVES, sub-atom to the pot
        total = gross + Math.ceilDiv(gross * cfg.fillFeeBps, 10000); // the fee rounds UP too, toward the lender
    }

    /// @notice Take the collateral a settled loan left, in kind.
    /// @notice `to` is never zero, the hub or the positionManager.
    /// @dev Reads NO clock and NO record, and must not start: the ask's hold is worth nothing if this waits, and without the ask it is a pot's only door.
    /// @dev CEI: the pot is debited before the token moves.
    /// @dev THE WHOLE POT, never a slice: one lender owns it, so there is no pro-rata and no residue.
    function redeemInKind(Market storage M, Cfg memory c, uint256 loanId, address to) public returns (uint256 out) {
        _onlyLender(c);
        Recipients.check(to, c.positionManager);
        out = M.invPotOf[loanId];
        if (out == 0) revert EmptyPot();
        _debitPot(M, loanId, out, out);
        M.s.netSyntheticOutflow += out; // exit in kind: units leave market custody
        if (M.s.netSyntheticOutflow > M.s.cumulativeBackedBurns) revert SyntheticCapExceeded();
        /// @dev Delivered straight off the custodian's retired ledger: settled inventory never moved to the hub
        IPositionManager(c.positionManager).releaseRetired(loanId, to, out);
        emit RedeemedInKind(loanId, msg.sender, to, out);
    }

    /// @dev A pot just emptied: take it off its pair's unsold count, saturating, so a count bug never freezes the collateral it holds.
    /// @dev NEVER `settledPots`: it only rises, which is how a reader tells a new pot from one that emptied.
    function _resolve(MarketParams storage p) private {
        LenderUnresolved storage u = Storage.unresolvedOf(p);
        if (u.unsoldPots != 0) u.unsoldPots -= 1;
    }

    /// @dev Units leave a pot: its ledger, its collateral's unsold units and, on emptying, the pair's count, at ONE site for every exit.
    /// @dev Callers hold `pot != 0`: past that guard an empty pot's `take == pot` would let anyone zero the count.
    /// @dev The units saturate, so a split bug never freezes a sale or a redeem.
    function _debitPot(Market storage M, uint256 loanId, uint256 pot, uint256 take) private {
        M.invPotOf[loanId] = pot - take;
        LenderCollateral storage x = Storage.byCollateralOf(M.p);
        x.unsoldUnits = Math.saturatingSub(x.unsoldUnits, take);
        if (take == pot) _resolve(M.p);
    }

    /// @dev The shared deposit body; an empty `permit2` blob routes the pull to the standing allowance.
    function _depositCash(Market storage M, Cfg memory c, bytes32 id, uint256 assets, bytes calldata permit2) private {
        openCash(M, c, assets);
        Transfers.pullQuotePermit(c, msg.sender, assets, permit2);
        emit Deposit(id, msg.sender, assets);
    }
}
