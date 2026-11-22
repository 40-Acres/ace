// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.36;

import {Vm} from "forge-std/Vm.sol";
import {FillBelowMin, Orders, RemainderBelowMin} from "../../src/ace/hub/Orders.sol";
import {Order} from "../../src/ace/hub/Types.sol";
import {AceFillPredicateBase} from "./AceOrderFillPredicate.t.sol";

/// @title AceOrderDefaultWhole
/// @notice THE RULE: a credit order posted with a ZERO fill floor fills whole or not at all; its floor resolves to its own principal.
/// @notice A maker who wants partial fills states an explicit floor, and so accepts that a filler picks the split.
/// @dev `P` is four minimum loans, so the old default (the market's `minPrincipal`) would admit a split, and the rows tell the two rules apart.
contract AceOrderDefaultWholeTest is AceFillPredicateBase {
    function _mp() internal view returns (uint256) {
        return ace.idToMarketParams(id).minPrincipal;
    }

    function _p() internal view returns (uint256) {
        return 4 * _mp();
    }

    /// @notice A zero floor stores and logs the order's whole principal, and escrows the required collateral plus the one atom a whole fill needs.
    function test_AZeroFloor_StoresAndLogsThePrincipal_AndEscrowsTheLinePlusOne() public {
        uint256 p = _p();
        uint256 units = _requiredAt(p, LIQ) + 1;
        uint64 expiry = _far();
        uint256 orderId = read.loanCount() + 1;
        vm.expectEmit(true, true, true, true, address(ace));
        emit Orders.OrderPosted(orderId, id, maker, units, p, p, TEN, expiry);
        assertEq(_post(p, LIQ, LIQ_HIGH, 0, TEN, expiry), orderId, "PREMISE: the order took the next id");
        Order memory o = ace.orderOf(orderId);
        assertEq(o.minFillPrincipal, p, "a zero floor resolves to the order's whole principal");
        assertEq(o.collateralUnits, units, "the escrow is the required collateral plus the one atom of a whole fill");
        assertEq(pm.collateralOf(orderId), units, "and custody holds exactly that");
    }

    /// @notice A default order refuses every partial fill at both doors, here a minimum loan, and admits the whole fill.
    function test_ADefaultOrder_RefusesAPartialFill_AndTheWholeFillLands() public {
        uint256 orderId = _post(_p(), LIQ, LIQ_HIGH, 0, TEN, _far());
        Order memory o = ace.orderOf(orderId);
        _bothRefuse(orderId, _mp(), _proRata(o, _mp()), FillBelowMin.selector, "a default order takes no partial fill");
        _bothRefuse(orderId, _p() - 1, _proRata(o, _p() - 1), FillBelowMin.selector, "not even one atom short of the whole");
        _bothAdmit(orderId, o.principal, o.collateralUnits);
        assertEq(ace.orderOf(orderId).principal, 0, "the whole fill spent the order");
    }

    /// @notice The control: an explicit `minPrincipal` floor still splits, which is the risk the maker opted into.
    function test_Control_AnExplicitMinPrincipalFloor_StillSplits() public {
        uint256 orderId = _post(_p(), LIQ, LIQ_HIGH, _mp(), TEN, _far());
        Order memory o = ace.orderOf(orderId);
        assertEq(o.minFillPrincipal, _mp(), "an explicit floor is stored as stated");
        _bothAdmit(orderId, _mp(), _proRata(o, _mp()));
        assertEq(ace.orderOf(orderId).principal, _p() - _mp(), "the order kept its remainder");
    }

    /// @dev One post, rewound: the order record, the post's logs and the custody it left.
    function _postAndRead(uint256 principal, uint256 minFill) internal returns (bytes memory order, bytes memory logs, uint256 custody) {
        uint256 snap = vm.snapshotState();
        vm.recordLogs();
        uint256 orderId = _post(principal, LIQ, LIQ_HIGH, minFill, TEN, _far());
        Vm.Log[] memory entries = vm.getRecordedLogs();
        order = abi.encode(ace.orderOf(orderId));
        custody = pm.collateralOf(orderId);
        for (uint256 i; i < entries.length; ++i) {
            if (entries[i].emitter == address(ace)) logs = abi.encode(logs, entries[i].topics, entries[i].data);
        }
        vm.revertToState(snap);
    }

    /// forge-config: default.fuzz.runs = 64
    /// @notice A zero floor is field for field the post of an explicit whole-principal floor: the record, the log and the custody.
    function testFuzz_AZeroFloor_IsFieldForFieldAnExplicitWholePost(uint256 principal) public {
        principal = bound(principal, _mp(), LADDER);
        (bytes memory oZero, bytes memory lZero, uint256 cZero) = _postAndRead(principal, 0);
        (bytes memory oWhole, bytes memory lWhole, uint256 cWhole) = _postAndRead(principal, principal);
        assertEq(oZero, oWhole, "the stored order differs");
        assertEq(lZero, lWhole, "the OrderPosted log differs");
        assertEq(cZero, cWhole, "the custody differs");
    }

    /// @notice The boundary the floor's comment states, through the hub: a floor of exactly half the principal splits, one atom over it fills whole.
    /// @dev Half escrows `ceil(2P / (P/2)) = 4` atoms of slack and admits a half fill; half plus one escrows one atom and strands every partial.
    function test_TheSplitBoundary_AHalfFloorSplits_OneAtomOverFillsWhole() public {
        uint256 p = _p();
        uint256 half = p / 2;
        uint256 snap = vm.snapshotState();
        uint256 a = _post(p, LIQ, LIQ_HIGH, half, TEN, _far());
        Order memory o = ace.orderOf(a);
        assertEq(o.collateralUnits, _requiredAt(p, LIQ) + 4, "a half floor escrows two atoms per minimum fill");
        _bothAdmit(a, half, _proRata(o, half));
        assertEq(ace.orderOf(a).principal, half, "a half floor splits the order in two");
        vm.revertToState(snap);

        uint256 b = _post(p, LIQ, LIQ_HIGH, half + 1, TEN, _far());
        o = ace.orderOf(b);
        assertEq(o.collateralUnits, _requiredAt(p, LIQ) + 1, "one atom over half escrows only the whole fill's atom");
        _bothRefuse(b, half, _proRata(o, half), FillBelowMin.selector, "a half fill sits under the floor");
        _bothRefuse(b, half + 1, _proRata(o, half + 1), RemainderBelowMin.selector, "a floor fill strands a remainder under the floor");
        _bothRefuse(b, p - 1, _proRata(o, p - 1), RemainderBelowMin.selector, "and so does one atom short of the whole");
        _bothAdmit(b, p, o.collateralUnits);
    }

    /// @dev One post filled whole at the pro-rata cap, rewound: the loan it opened, the spent order and the fill's logs.
    function _fillWholeAndRead(uint256 principal, uint256 minFill) internal returns (bytes memory loan, bytes memory order, bytes memory logs) {
        uint256 snap = vm.snapshotState();
        uint256 orderId = _post(principal, LIQ, LIQ_HIGH, minFill, TEN, _far());
        Order memory o = ace.orderOf(orderId);
        vm.recordLogs();
        uint256 loanId = _bothAdmit(orderId, o.principal, o.collateralUnits);
        Vm.Log[] memory entries = vm.getRecordedLogs();
        loan = abi.encode(lens.loan(loanId));
        order = abi.encode(ace.orderOf(orderId));
        for (uint256 i; i < entries.length; ++i) {
            if (entries[i].emitter == address(ace)) logs = abi.encode(logs, entries[i].topics, entries[i].data);
        }
        vm.revertToState(snap);
    }

    /// forge-config: default.fuzz.runs = 32
    /// @notice The sentinel and its stated twin stay identical THROUGH the whole fill: the loan opened, the spent order and the fill's logs.
    /// @dev The deterministic cover for the campaign's stated-whole-floor shape, which a short sequence can miss.
    function testFuzz_AZeroFloor_FillsWholeExactlyAsAStatedWholeFloor(uint256 principal) public {
        principal = bound(principal, _mp(), 100 * P);
        (bytes memory lZero, bytes memory oZero, bytes memory gZero) = _fillWholeAndRead(principal, 0);
        (bytes memory lWhole, bytes memory oWhole, bytes memory gWhole) = _fillWholeAndRead(principal, principal);
        assertEq(lZero, lWhole, "the loan the whole fill opened differs");
        assertEq(oZero, oWhole, "the spent order differs");
        assertEq(gZero, gWhole, "the fill's logs differ");
    }
}
