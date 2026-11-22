// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.36;

import {FullMath} from "@uniswap/v4-core/src/libraries/FullMath.sol";
import {FairnessHarness} from "./FairnessHarness.sol";
import {Order} from "../../src/ace/hub/Types.sol";

/// @title FairnessP14OrderSplitMeasure
/// @notice #946 measured: the S3 order-split pair of `FairnessP14OrderSplit`, run on the rig's 5% cut market and on the same market with no cut.
/// @notice A measurement row: it asserts only the fixture and logs the maker's and the filling lender's signed split-vs-whole differences.
contract FairnessP14OrderSplitMeasureTest is FairnessHarness {
    uint256 internal constant ASK = 4 * MIN_PRINCIPAL; // four minimum loans, or one loan a crank restores
    uint256 internal constant THETA = 6500;
    uint256 internal constant PRINT = 7800;

    struct End {
        uint256 maker;
        uint256 lender;
        uint256 closedByCrank;
        uint256 sold;
        uint256 debtLeft; // debt the cranks left across the loans, settled at expiry
    }

    /// @dev `FairnessP14OrderSplit._run` on market `mid`: one ask filled in `fills` lots, one crank each, the rest settled at expiry.
    function _run(bytes32 mid, uint256 fills) internal returns (End memory e) {
        _deposit(mid, alice, 2 * ASK);
        _budget();
        coll.mint(borrower, 2 * _units(ASK, THETA));
        uint256 liq = _pxOf(THETA);
        vm.prank(borrower);
        uint256 orderId = ace.postOrder(mid, ASK, liq, liq, MIN_PRINCIPAL, 0, 0); // an explicit floor: since #946 a zero one fills whole only
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
            else e.debtLeft += read.loan(loans[i]).debt;
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
            pots += read.invPotOf(mid, loans[i]);
        }
        (uint256 resting, uint256 lent, uint256 owed) = read.lenderPools(alice, address(usdc));
        e.maker = quote + _valueAt(units, px);
        e.lender = usdc.balanceOf(alice) + resting + lent + owed + _valueAt(pots, px);
    }

    function _pair(bytes32 mid) internal returns (End memory whole, End memory split) {
        uint256 snap = vm.snapshotState();
        whole = _run(mid, 1);
        vm.revertToState(snap);
        split = _run(mid, 4);
        vm.revertToState(snap);
    }

    function _signed(string memory pos, string memory neg, uint256 x, uint256 y) internal {
        if (x >= y) emit log_named_decimal_uint(pos, x - y, 6);
        else emit log_named_decimal_uint(neg, y - x, 6);
    }

    function _measure(bytes32 mid, string memory tag) internal {
        (End memory whole, End memory split) = _pair(mid);
        assertTrue(whole.closedByCrank == 0 && whole.sold > 0, "fixture: the one loan is restored, not closed");
        assertEq(split.closedByCrank, 4, "fixture: every minimum loan is closed whole by its crank");
        emit log_named_decimal_uint(string.concat(tag, ": the ask"), ASK, 6);
        emit log_named_decimal_uint(string.concat(tag, ": the whole fill's debt left to settle at expiry"), whole.debtLeft, 6);
        _signed(
            string.concat(tag, ": the split leaves the maker better by"), string.concat(tag, ": the split leaves the maker worse by"), split.maker, whole.maker
        );
        _signed(
            string.concat(tag, ": the split leaves the lender better by"),
            string.concat(tag, ": the split leaves the lender worse by"),
            split.lender,
            whole.lender
        );
    }

    /// @notice S3 at the rig's 5% cut and at no cut, side by side.
    function test_Measure_946_OrderSplit_AtTheCutAndAtNoCut() public {
        _measure(id, "S3 at a 5% cut");
        _measure(bandOnNoCut, "S3 at no cut");
    }
}
