// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.36;

import {FullMath} from "@uniswap/v4-core/src/libraries/FullMath.sol";
import {FairnessHarness} from "./FairnessHarness.sol";
import {Order} from "../../src/ace/hub/Types.sol";
import {FillBelowMin} from "../../src/ace/hub/Orders.sol";

/// @title FairnessP14OrderSplit
/// @notice Audit run 2026-11-15-f3aae2, phase 14, S3: a face of table row F2.6, the filler of a resting credit order chooses how it SPLITS.
/// @notice One fill of the whole ask opens one loan a crank restores; the same ask filled in minimum lots opens loans every in-band crank closes whole.
/// @notice A closing crank sells the whole debt at the record, so the maker loses the expiry settlement at the price on the part a restore would have left.
/// @notice #946 closes it as a CONTROL property: a zero fill floor now resolves to the whole principal, so no filler splits a DEFAULT order.
/// @notice A maker who states a floor of at most half its ask has accepted that a filler picks the split; that pair is bounded by F2.3b's fee bound.
/// @dev Two runs, one difference: the number of fills, on an order whose maker opted into splits with an explicit `minPrincipal` floor.
contract FairnessP14OrderSplitTest is FairnessHarness {
    uint256 internal constant ASK = 4 * MIN_PRINCIPAL; // four minimum loans, or one loan a crank restores
    uint256 internal constant THETA = 6500; // the maker's one liquidation price, in bps of par
    uint256 internal constant PRINT = 7800; // in the band and over the stop for a 65% trigger

    struct End {
        uint256 maker; // quote and units, wallet and owed, at the print
        uint256 lender; // wallet, pools and pots at the print; its deposit is the same in both runs
        uint256 closedByCrank; // loans the keeper's crank closed whole
        uint256 sold; // units the cranks sold
    }

    /// @dev One ask at an explicit `MIN_PRINCIPAL` floor, filled in `fills` lots by the lender, retired, printed into the band, cranked once each, settled.
    function _run(bytes32 mid, uint256 fills) internal returns (End memory e) {
        uint256 orderId = _postAsk(mid, MIN_PRINCIPAL);
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
            pots += read.invPotOf(mid, loans[i]);
        }
        (uint256 resting, uint256 lent, uint256 owed) = read.lenderPools(alice, address(usdc));
        e.maker = quote + _valueAt(units, px);
        e.lender = usdc.balanceOf(alice) + resting + lent + owed + _valueAt(pots, px);
    }

    /// @dev The maker's ask at the fixture's liquidation price, with fill floor `minFill`, funded by the lender's deposit.
    function _postAsk(bytes32 mid, uint256 minFill) internal returns (uint256 orderId) {
        _deposit(mid, alice, 2 * ASK);
        _budget();
        coll.mint(borrower, 2 * _units(ASK, THETA));
        uint256 liq = _pxOf(THETA);
        vm.prank(borrower);
        orderId = ace.postOrder(mid, ASK, liq, liq, minFill, 0, 0);
    }

    function _pair(bytes32 mid) internal returns (End memory whole, End memory split) {
        uint256 snap = vm.snapshotState();
        whole = _run(mid, 1);
        vm.revertToState(snap);
        split = _run(mid, 4);
        vm.revertToState(snap);
    }

    /// @notice F2.6a, ruled: a filler never splits a DEFAULT order; with an explicit floor the maker has accepted the split risk.
    /// @notice Every partial fill of a zero-floor order refuses `FillBelowMin`, a minimum lot and one atom short of the whole alike; the whole fill lands.
    function test_F2_6a_FillSplit_BandOn_NoFillerSplitsADefaultOrder() public {
        uint256 orderId = _postAsk(id, 0);
        Order memory o = ace.orderOf(orderId);
        assertEq(o.minFillPrincipal, ASK, "a default order's floor is its whole principal");
        uint256[2] memory lots = [MIN_PRINCIPAL, ASK - 1];
        for (uint256 i; i < 2; ++i) {
            vm.prank(alice);
            vm.expectRevert(FillBelowMin.selector);
            ace.fillOrder(orderId, lots[i], FullMath.mulDiv(o.collateralUnits, lots[i], o.principal));
        }
        vm.prank(alice);
        ace.fillOrder(orderId, ASK, o.collateralUnits);
        assertEq(ace.orderOf(orderId).principal, 0, "the whole fill lands");
    }

    /// @notice #946's S3 row: a default order's first minimum lot refuses; one opted in by an explicit floor splits into four whole-closed loans.
    /// @notice The opted-in split's cost to the maker is bounded at both cuts by F2.3b's fee bound on its melts: four closes melt the whole ask.
    /// @dev Measured: at no cut the split costs 0.009082 against a bound of about 0.41 on a 40 ask, and at the 5% cut it gains 1.367041.
    /// @dev LOOSE at the 5% cut by ruling: that bound is about 9.6% of the ask, so only a large regression trips it; direction is logged, not asserted.
    function test_946_S3_ADefaultOrderCannotBeSplit_AnOptedInOneCan() public {
        uint256 snap = vm.snapshotState();
        uint256 orderId = _postAsk(id, 0);
        Order memory o = ace.orderOf(orderId);
        vm.prank(alice);
        vm.expectRevert(FillBelowMin.selector);
        ace.fillOrder(orderId, MIN_PRINCIPAL, FullMath.mulDiv(o.collateralUnits, MIN_PRINCIPAL, o.principal));
        vm.revertToState(snap);
        Kind[2] memory ks = [Kind.BandOn, Kind.BandOnNoCut];
        for (uint256 j; j < 2; ++j) {
            (End memory whole, End memory split) = _pair(_mid(ks[j]));
            assertTrue(whole.closedByCrank == 0 && whole.sold > 0, "fixture: the one loan is restored, not closed");
            assertEq(split.closedByCrank, 4, "fixture: the opted-in order splits into four minimum loans, each closed whole by its crank");
            assertGe(
                split.maker + _feeBound(ASK, ASK, ks[j]),
                whole.maker,
                string.concat("F2.6a: the opted-in split cost the maker more than the fee bound, kind ", vm.toString(uint256(ks[j])))
            );
            emit log_named_decimal_uint("S3 opted in: the ask", ASK, 6);
            if (split.maker >= whole.maker) emit log_named_decimal_uint("S3 opted in: the split leaves the maker better by", split.maker - whole.maker, 6);
            else emit log_named_decimal_uint("S3 opted in: the split leaves the maker worse by", whole.maker - split.maker, 6);
        }
    }
}
