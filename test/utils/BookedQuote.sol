// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.36;

import {Ace} from "../../src/ace/hub/Ace.sol";
import {MarketState} from "../../src/ace/hub/Types.sol";
import {AceReader} from "./AceReader.sol";

/// @title BookedQuote
/// @notice The quote the hub's books say it holds in one token: the right-hand side of every solvency equality.
/// @dev ONE spelling shared by the campaigns that assert solvency, so the terms cannot drift between suites.
/// @dev Extracted verbatim from `AceInvariants._bookedQuote`, whose header keeps the sum's reasoning; `marketPots` carries its own.
library BookedQuote {
    /// @notice Each market's three pots and its loans' fee escrows, plus each lender's uncollected pool credit in `token`.
    /// @dev `markets` must be exactly the markets quoting in `token`: a market in another quote mixes denominations.
    /// @dev `lenders` must be DISTINCT: the credit leg is per (lender, quote), so a repeat counts a pool twice.
    function total(Ace ace, AceReader read, bytes32[] memory markets, address[] memory lenders, address token) internal view returns (uint256 booked) {
        for (uint256 i; i < markets.length; i++) {
            booked += marketPots(read, markets[i]);
            uint256 loans = ace.marketLoansLength(markets[i]);
            uint256[] memory page = ace.marketLoans(markets[i], 0, loans);
            for (uint256 k; k < page.length; k++) {
                booked += read.feeEscrowOf(page[k]);
            }
        }
        for (uint256 a; a < lenders.length; a++) {
            (,, uint256 owed) = read.lenderPools(lenders[a], token);
            booked += owed;
        }
    }

    /// @notice The THREE quote pots one market books. Fee escrows are per-loan and pool credit is per lender.
    /// @dev `unitOwed` moved to the pool leg: it was per market and is now per (lender, quote).
    /// @dev `cash` stays market-side, where it rests; `AceInvariants._invariant_cashIsTheRestingPool` pins the matching `pools.resting`.
    /// @dev So counting `pools.resting` here too would be the double-count that property exists to make impossible.
    function marketPots(AceReader read, bytes32 marketId) internal view returns (uint256) {
        MarketState memory s = read.marketState(marketId);
        return s.cash + s.protocolRevenue + s.quoteOwedTotal;
    }
}
