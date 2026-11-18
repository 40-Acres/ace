// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.36;

import {FullMath} from "@uniswap/v4-core/src/libraries/FullMath.sol";
import {FairnessHarness} from "./FairnessHarness.sol";
import {Order} from "../../src/ace/hub/Types.sol";

/// @title FairnessP14OrderSplit
/// @notice Audit run 2026-11-15-f3aae2, phase 14, S3: a face of table row F2.6, the filler of a resting credit order chooses how it SPLITS.
/// @notice One fill of the whole ask opens one loan a crank restores; the same ask filled in minimum lots opens loans every in-band crank closes whole.
/// @notice A closing crank sells the whole debt at the record, so the maker loses the expiry settlement at the price on the part a restore would have left.
/// @dev Two runs, one difference: the number of fills. The maker posts with the default fill floor, zero, which resolves to the market's `minPrincipal`.
/// @dev The PoC row asserts the inversion and stays green; the property row asserts the direction F2.6 would declare and runs once the flag is true.
contract FairnessP14OrderSplitTest is FairnessHarness {
    bool internal constant FIXED_P14_ORDERSPLIT = false; // phase 14 S3 has no issue yet: the split of a fill no longer moves the maker's outcome

    uint256 internal constant ASK = 4 * MIN_PRINCIPAL; // four minimum loans, or one loan a crank restores
    uint256 internal constant THETA = 6500; // the maker's one liquidation price, in bps of par
    uint256 internal constant PRINT = 7800; // in the band and over the stop for a 65% trigger

    struct End {
        uint256 maker; // quote and units, wallet and owed, at the print
        uint256 lender; // wallet, pools and pots at the print; its deposit is the same in both runs
        uint256 closedByCrank; // loans the keeper's crank closed whole
        uint256 sold; // units the cranks sold
    }

    /// @dev Post one ask, fill it in `fills` equal lots as the lender, retire the order, print into the band, crank each loan once, settle the rest at expiry.
    function _run(uint256 fills) internal returns (End memory e) {
        _deposit(id, alice, 2 * ASK);
        _budget();
        coll.mint(borrower, 2 * _units(ASK, THETA));
        uint256 liq = _pxOf(THETA);
        vm.prank(borrower);
        uint256 orderId = ace.postOrder(id, ASK, liq, liq, 0, 0, 0);
        uint256[] memory loans = new uint256[](fills);
        uint256 per = ASK / fills;
        for (uint256 i; i < fills; ++i) {
            Order memory o = ace.orderOf(orderId);
            uint256 unitsOut = i + 1 == fills ? o.collateralUnits : FullMath.mulDiv(o.collateralUnits, per, o.principal);
            vm.prank(alice);
            loans[i] = ace.fillOrder(orderId, per, unitsOut);
        }
        vm.prank(borrower);
        ace.closeOrder(orderId, borrower);

        _warpBy(STEP);
        _printBps(PRINT);
        for (uint256 i; i < fills; ++i) {
            (uint256 u,) = ace.deleverage(loans[i], 0, "");
            e.sold += u;
            if (_closed(loans[i])) ++e.closedByCrank;
        }
        _warpAtLeastTo(read.loan(loans[0]).expiry);
        uint256 px = _pxOf(PRINT);
        uint256 quote = usdc.balanceOf(borrower);
        uint256 units = coll.balanceOf(borrower);
        uint256 pots;
        for (uint256 i; i < fills; ++i) {
            if (!_closed(loans[i])) {
                vm.prank(keeper);
                ace.forceClose(loans[i]);
            }
            quote += read.quoteOwedOf(loans[i], borrower);
            units += read.unitsOwedOf(loans[i], borrower);
            pots += read.invPotOf(id, loans[i]);
        }
        (uint256 resting, uint256 lent, uint256 owed) = read.lenderPools(alice, address(usdc));
        e.maker = quote + _valueAt(units, px);
        e.lender = usdc.balanceOf(alice) + resting + lent + owed + _valueAt(pots, px);
    }

    function _pair() internal returns (End memory whole, End memory split) {
        uint256 snap = vm.snapshotState();
        whole = _run(1);
        vm.revertToState(snap);
        split = _run(4);
        vm.revertToState(snap);
    }

    /// @notice F2.6, the direction a ruling would declare: how a filler splits a maker's ask never leaves the maker worse off.
    function test_F2_6_FillSplit_BandOn_MakerNeverWorse() public {
        if (!FIXED_P14_ORDERSPLIT) return;
        (End memory whole, End memory split) = _pair();
        assertGe(split.maker + ASK / 1e4, whole.maker, "F2.6: the split of the fill left the maker worse off");
    }

    /// @notice S3 as the code stands: the lender fills the ask in minimum lots, each crank closes its loan whole, and the lender nets what the maker loses.
    function test_P14_S3_OrderSplit_FillingInMinimumLotsTurnsEveryCrankIntoAWholeClose() public {
        (End memory whole, End memory split) = _pair();
        assertTrue(whole.closedByCrank == 0 && whole.sold > 0, "fixture: the one loan is restored, not closed");
        assertEq(split.closedByCrank, 4, "fixture: every minimum loan is closed whole by its crank");
        assertLt(split.maker, whole.maker, "S3: the split leaves the maker worse off");
        assertGt(split.lender, whole.lender, "S3: and the filling lender better off");
        emit log_named_decimal_uint("S3: the ask", ASK, 6);
        emit log_named_decimal_uint("S3: the maker's loss to the split", whole.maker - split.maker, 6);
        emit log_named_decimal_uint("S3: the filling lender's gain from the split", split.lender - whole.lender, 6);
    }
}
