// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.36;

import {Test, console2} from "forge-std/Test.sol";
import {StdInvariant} from "forge-std/StdInvariant.sol";
import {Ace} from "../../src/ace/hub/Ace.sol";
import {Order} from "../../src/ace/hub/Types.sol";
import {PositionManager} from "../../src/ace/positions/PositionManager.sol";
import {AceSplitOrderHandler} from "./AceSplitOrderHandler.sol";

/// @title AceSplitOrderInvariants
/// @notice Credit orders that can SPLIT, over long random walks: every legal fill inside [coverage line, pro-rata cap] opens.
/// @notice And the escrow is conserved: what was posted is exactly what the fills carried, what the close returned, and what still rests.
/// @dev Two regimes, one handler: whole-unit collateral, where every per-fill ceiling is a whole unit, and a fine 6/6 pair at 3.0.
/// @dev The fill property is LATCHED by the handler, because only the handler knows a refusal was of a legal fill.
/// @dev Config (foundry.toml [invariant]): runs = 256, depth = 32, fail_on_revert = false.
abstract contract AceSplitOrderInvariantsBase is StdInvariant, Test {
    AceSplitOrderHandler internal handler;
    Ace internal ace;
    PositionManager internal pm;

    /// @dev The regime: collateral decimals and one whole collateral's price in whole quote, as a WAD.
    function _regime() internal pure virtual returns (uint8 collDec, uint256 humanPriceWad);

    function setUp() public {
        (uint8 collDec, uint256 humanPriceWad) = _regime();
        handler = new AceSplitOrderHandler(collDec, humanPriceWad);
        handler.baselineDeleverage(); // pre-snapshot, but it needs the handler's own code deployed to be called back
        ace = handler.ace();
        pm = handler.positionManager();

        bytes4[] memory sel = new bytes4[](9);
        sel[0] = AceSplitOrderHandler.postOrder.selector;
        sel[1] = AceSplitOrderHandler.fillAtCap.selector;
        sel[2] = AceSplitOrderHandler.fillInBand.selector;
        sel[3] = AceSplitOrderHandler.closeOrder.selector;
        sel[4] = AceSplitOrderHandler.repay.selector;
        sel[5] = AceSplitOrderHandler.withdrawCollateral.selector;
        sel[6] = AceSplitOrderHandler.deleverage.selector;
        sel[7] = AceSplitOrderHandler.warp.selector;
        /// @dev Weighted toward the property: a cap fill is twice as likely as any other single verb.
        sel[8] = AceSplitOrderHandler.fillAtCap.selector;
        targetSelector(FuzzSelector({addr: address(handler), selectors: sel}));
        targetContract(address(handler));
    }

    /// @notice Every property below, on ONE walk; the first failure names itself and aborts the rest.
    /// @dev Each regime registers it under its own name, so `make tallies ARGS=<name>` reads one regime's block.
    function _all() internal view {
        _invariant_everyLegalFillOpens();
        _invariant_escrowIsConserved();
        _invariant_theRemainingRatioNeverFalls();
        _invariant_aRemainderIsZeroOrFillable();
    }

    /// @notice THE PROPERTY: no legal fill between the coverage line and the pro-rata cap was ever refused.
    /// @dev TEETH: one atom less slack latches a minimum fill in both regimes; the old slack fails earlier, at the baseline split.
    function _invariant_everyLegalFillOpens() public view {
        assertFalse(handler.capFillRefused(), handler.refusal());
    }

    /// @notice Posted escrow == units the fills carried + units the close returned + units still resting, and the pot agrees.
    function _invariant_escrowIsConserved() public view {
        uint256[] memory ids = handler.orderIds();
        for (uint256 i; i < ids.length; i++) {
            Order memory o = ace.orderOf(ids[i]);
            uint256 accounted = handler.carriedUnits(ids[i]) + handler.returnedUnits(ids[i]) + o.collateralUnits;
            assertEq(handler.postedUnits(ids[i]), accounted, "escrow: posted units are not what was carried, returned and still rests");
            assertEq(pm.collateralOf(ids[i]), o.collateralUnits, "escrow: the order's custody row disagrees with its record");
            if (o.closed) assertEq(o.collateralUnits + o.principal, 0, "escrow: a closed order still holds escrow or principal");
        }
    }

    /// @notice The proof's lemma: a take at or under the cap never lowers the remaining escrow-per-principal below the posted ratio.
    /// @dev `U_rem * D0 >= U0 * D_rem`, cross-multiplied; every figure here is far under 2^128, so the products cannot wrap.
    function _invariant_theRemainingRatioNeverFalls() public view {
        uint256[] memory ids = handler.orderIds();
        for (uint256 i; i < ids.length; i++) {
            Order memory o = ace.orderOf(ids[i]);
            if (o.principal == 0) continue;
            assertGe(
                o.collateralUnits * handler.postedPrincipal(ids[i]),
                handler.postedUnits(ids[i]) * o.principal,
                "ratio: a fill left the remainder poorer than the posted escrow"
            );
        }
    }

    /// @notice A live remainder is never under the maker's own floor, so a legal fill of it always exists.
    function _invariant_aRemainderIsZeroOrFillable() public view {
        uint256[] memory ids = handler.orderIds();
        for (uint256 i; i < ids.length; i++) {
            Order memory o = ace.orderOf(ids[i]);
            assertTrue(o.principal == 0 || o.principal >= o.minFillPrincipal, "remainder: a live remainder sits under the maker's floor");
        }
    }

    /// @notice The campaign report: which channels this run actually reached.
    /// @dev Reported rather than asserted: foundry reverts handler ghosts between runs, so a hard assert here measures one sequence.
    function afterInvariant() public view {
        console2.log("=== AceSplitOrderHandler verb hits (LAST sequence only) ==="); // the heading `make tallies` finds the block by
        console2.log("postOrder calls        ", handler.callCount("postOrder"));
        console2.log("fillAtCap calls        ", handler.callCount("fillAtCap"));
        console2.log("fillInBand calls       ", handler.callCount("fillInBand"));
        console2.log("orders posted          ", handler.ordersPosted());
        console2.log("  splittable           ", handler.splittablePosted());
        console2.log("  whole-only           ", handler.wholeOnlyPosted());
        console2.log("  zero-minFill sentinel", handler.sentinelPosted());
        console2.log("cap fills landed       ", handler.capFills());
        console2.log("  partial (split)      ", handler.partialCapFills());
        console2.log("  exactly minFill      ", handler.minFillCapFills());
        console2.log("in-band fills landed   ", handler.bandFills());
        console2.log("closes                 ", handler.closes());
        console2.log("repays                 ", handler.repays());
        console2.log("withdrawals            ", handler.withdrawals());
        console2.log("deleverages that sold  ", handler.deleveragesSold());
    }
}

/// @title AceSplitOrderWholeUnitInvariants
/// @notice 0-decimal collateral worth 1,000 against a 6-decimal quote: every per-fill ceiling is a whole unit.
contract AceSplitOrderWholeUnitInvariantsTest is AceSplitOrderInvariantsBase {
    function _regime() internal pure override returns (uint8, uint256) {
        return (0, 1_000e18);
    }

    function invariant_wholeUnit_all() public view {
        _all();
    }
}

/// @title AceSplitOrderFineInvariants
/// @notice 6-decimal collateral worth 3.0 against a 6-decimal quote, example 1's pair: the bug bit here only at maximum leverage.
contract AceSplitOrderFineInvariantsTest is AceSplitOrderInvariantsBase {
    function _regime() internal pure override returns (uint8, uint256) {
        return (6, 3e18);
    }

    function invariant_fine_all() public view {
        _all();
    }
}
