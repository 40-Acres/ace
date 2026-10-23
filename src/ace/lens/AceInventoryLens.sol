// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.36;

import {Math} from "@openzeppelin/contracts/utils/math/Math.sol";
import {FullMath} from "@uniswap/v4-core/src/libraries/FullMath.sol";
import {Loan, MarketParams, MarketState, RecordState} from "../hub/Types.sol";
import {ZeroLimit} from "./AceLens.sol";

error TornRead(); // a guarded hub body is mid-flight, so an aggregate read here would straddle a half-written state

/// @notice The hub views this lens reads directly: the loan pager, the params, and the transient-lock probe.
interface IAceInventoryHub {
    function marketLoans(bytes32 id, uint256 offset, uint256 limit) external view returns (uint256[] memory);
    function idToMarketParams(bytes32 id) external view returns (MarketParams memory);
    function notEntered() external view returns (bool);
}

/// @notice The shipped `AceLens` surface this one aggregates over; nothing here re-derives a storage offset.
/// @dev EVERY MEMBER MUST EXIST ON `AceLens`: an interface call compiles against this declaration alone, so a dropped one reverts at RUNTIME.
interface IAceLensReads {
    function recordStateOf(bytes32 id) external view returns (RecordState state, uint256 cap);
    function marketState(bytes32 id) external view returns (MarketState memory s);
    function invPotOf(bytes32 id, uint256 loanId) external view returns (uint256);
    function loan(uint256 loanId) external view returns (Loan memory l);
}

/// @title AceInventoryLens
/// @notice Sizes the settlement trough: what a market holds as settled collateral that NAV cannot see.
/// @notice A settled loan's recovery rests in its own inventory pot, outside the lender-assets identity.
/// @notice So a lender's reported assets fall by the whole claim, and climb back only as that inventory sells where the market has the ask.
/// @notice WITHOUT THE ASK THE HUB NEVER SELLS IT: the lender takes the pot in kind, and this prices it at what the ask would have asked.
/// @notice `settledInventory` is a mark on settled inventory and nothing else; do not net it against any other figure.
/// @notice `clearingBudget` is a buyer's quote, not a mark: it rounds UP, as the whole-pot buy charges, where the mark floors.
/// @dev The mark is a DISCLOSURE, never an input: a vault whose share price reads it stops being cost-based.
/// @dev A separate address, so these reads add nothing to `AceLens`'s runtime size.
/// @dev The mark prices exactly as `AceLens.inventoryMark` prices one pot, so the aggregate and the singular agree.
contract AceInventoryLens {
    IAceInventoryHub public immutable ACE;
    IAceLensReads public immutable LENS;

    constructor(address ace, address lens) {
        ACE = IAceInventoryHub(ace);
        LENS = IAceLensReads(lens);
    }

    /// @notice One page of a market's settled inventory: what it is worth, how much of it there is.
    /// @notice A ZERO IS NOT AN ALL-CLEAR: page to the end before concluding a market holds nothing.
    /// @dev Non-reverting on a blind record ON PURPOSE, unlike the singular view, which refuses.
    /// @dev A record that cannot price is the state most likely to coincide with a settlement.
    /// @dev The record and the unit scale are read ONCE per call, not once per pot.
    /// @dev The liveness skip is sound: a pot is written only in settlement, which closes the loan in that call.
    /// @dev ETH_CALL ONLY. The walk is paginated but unbounded in aggregate; never call it from a transaction.
    /// @param id The market to size.
    /// @param offset Index into the market's ever-opened loan list.
    /// @param limit Loans to walk this page; the hub clamps it, so a short page is not the end.
    /// @return quoted Page value at the hub's ask price, a valuation whether or not this market has the ask, or 0 when the record cannot price.
    /// @return units Page pot total in collateral atoms; always available, never floored by a price.
    /// @return priced Whether the record priced this call; a false is a live answer, not a failure.
    /// @return nextOffset Where the next page starts; equal to `offset` when the walk is done.
    function settledInventory(bytes32 id, uint256 offset, uint256 limit)
        external
        view
        returns (uint256 quoted, uint256 units, bool priced, uint256 nextOffset)
    {
        if (limit == 0) revert ZeroLimit();
        if (!ACE.notEntered()) revert TornRead();

        uint256 ask;
        (priced, ask) = _ask(id);
        uint256 scale = LENS.marketState(id).unitScale;

        uint256[] memory page = ACE.marketLoans(id, offset, limit);
        nextOffset = offset + page.length;

        for (uint256 i; i < page.length; i++) {
            if (LENS.loan(page[i]).closedAt == 0) continue; // live: settlement has not run, so there is no pot
            uint256 pot = LENS.invPotOf(id, page[i]);
            if (pot == 0) continue;
            units += pot;
            if (priced) quoted += FullMath.mulDiv(pot, ask, scale);
        }
    }

    /// @notice The smallest `stableIn` that buys this loan's whole pot in one `buyInventory`, emptying it; zero when nothing can be bought.
    /// @notice Zero means no pot, a market without the ask, or a record that cannot price; it does not read the hold.
    /// @dev RE-DERIVES `Lender._askLeg`'s two whole-pot tests, which must agree: the floor-priced take reaches the pot, and the ceiled charge fits.
    /// @dev EXACT AT THIS BLOCK: a record floor can rise before inclusion, and a larger budget pays the same whole-pot charge.
    /// @param id The loan's market.
    /// @param loanId The settled loan.
    /// @return The budget, in quote atoms.
    function clearingBudget(bytes32 id, uint256 loanId) external view returns (uint256) {
        if (!ACE.notEntered()) revert TornRead();
        MarketParams memory p = ACE.idToMarketParams(id);
        uint256 pot = LENS.invPotOf(id, loanId);
        if (pot == 0 || !p.inventoryAsk) return 0;
        (bool priced, uint256 ask) = _ask(id);
        if (!priced) return 0;
        uint256 scale = LENS.marketState(id).unitScale;
        uint256 eff = ask + Math.ceilDiv(ask * p.fillFeeBps, 10000);
        uint256 g = FullMath.mulDivRoundingUp(pot, ask, scale);
        return Math.max(FullMath.mulDivRoundingUp(pot, eff, scale), g + Math.ceilDiv(g * p.fillFeeBps, 10000));
    }

    /// @dev ONE ASK FOR THE WHOLE PAGE, since every pot in the market prices at the market's own price.
    /// @dev The ask is the singular view's ask: the market's price, lifted to the record's windowed minimum.
    /// @dev THE ONE ASK SPELLING both reads share, so the quote and the mark never ask differently; its own frame, as the walk has no stack room.
    /// @dev A `false` here is a live answer: `priced` false means the record could not price, so nothing is quoted.
    function _ask(bytes32 id) private view returns (bool priced, uint256 ask) {
        (RecordState state, uint256 cap) = LENS.recordStateOf(id); // reverts NoMarket on an id never created
        priced = state != RecordState.NoPrice;
        uint256 askFloor = cap == type(uint256).max ? 0 : cap; // the max sentinel is NO floor, never an infinite one
        ask = ACE.idToMarketParams(id).price;
        ask = Math.max(ask, askFloor);
    }
}
