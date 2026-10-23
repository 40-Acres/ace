// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.36;

import {Test} from "forge-std/Test.sol";
import {Orders} from "../../src/ace/hub/Orders.sol";
import {Cfg} from "../../src/ace/hub/Types.sol";
import {FullMath} from "@uniswap/v4-core/src/libraries/FullMath.sol";
import {Math} from "@openzeppelin/contracts/utils/math/Math.sol";
import {AceRefinanceWithdrawFixture} from "./AceRefinanceWithdraw.t.sol";
import {AceOrderFixture} from "./AceOrderRails.t.sol";

contract OrderSizingHarness {
    function size(uint256 coverage, uint256 principal, uint256 price, uint256 minFill) external pure returns (uint256) {
        Cfg memory c;
        c.p.minCoverageWad = coverage;
        c.unitScale = 1 << 96;
        return Orders.collateralFor(c, principal, price, minFill);
    }
}

contract AceOrderInputRefusalsTest is Test {
    OrderSizingHarness internal h = new OrderSizingHarness();
    uint256 internal constant U = type(uint256).max;
    uint256 internal constant W = 1e18;
    uint256 internal constant Q = 1 << 96;
    uint256 internal constant LIMIT = U / W;
    bytes4 internal constant PRINCIPAL = bytes4(keccak256("OrderPrincipalOutOfRange()"));
    bytes4 internal constant COLLATERAL = bytes4(keccak256("CollateralOutOfRange()"));

    function test_401_PrincipalProductThresholdAndNextAtom() public {
        uint256 principal = U / 1.4e18;
        assertGt(h.size(1.4e18, principal, U, principal), 1);
        vm.expectRevert(PRINCIPAL);
        h.size(1.4e18, principal + 1, U, principal + 1);
    }

    function test_401_LowPriceQuotientOverflowIsNamed() public {
        vm.expectRevert(COLLATERAL);
        h.size(1.4e18, U / 1.4e18, 1, U / 1.4e18);
    }

    function test_401_RequiredAndFillSlackExceedCap() public {
        vm.expectRevert(COLLATERAL);
        h.size(1.05e18, LIMIT / 2 + 1, Q, 2); // a two-atom minimum fill reserves ceil(2p / 2) = p, so the SUM is what overflows
    }

    function test_401_SlackAloneExceedsCap() public {
        vm.expectRevert(COLLATERAL);
        h.size(1.05e18, LIMIT / 2 + 1, Q, 1); // a one-atom minimum fill reserves 2p = LIMIT + 1, refused before any sizing
    }

    function test_401_ExactCapAndFirstExcessWithRemainder() public {
        // coverage*principal/W is integral; price Q makes the requirement exact.
        uint256 principal = (LIMIT - 1) / 2;
        uint256 exact = 2 * principal + 1;
        assertEq(h.size(2e18, principal, Q, principal), exact);
        vm.expectRevert(COLLATERAL);
        h.size(2e18, principal, Q, principal / 2);
        // A lower price increases the requirement and introduces a nonzero remainder.
        uint256 num = 2e18 * principal;
        uint256 price = Q - 1;
        assertGt(mulmod(num, Q, price * W), 0);
        vm.expectRevert(COLLATERAL);
        h.size(2e18, principal, price, principal);
    }

    function test_401_BothPriceBranchesKeepTheSameCeil() public view {
        uint256 principal = U / 1.4e18;
        uint256 num = principal * 1.4e18;
        uint256 low = FullMath.mulDivRoundingUp(num, Q, LIMIT * W) + 1;
        uint256 high = FullMath.mulDivRoundingUp(FullMath.mulDivRoundingUp(num, Q, LIMIT + 1), 1, W) + 1;
        assertEq(h.size(1.4e18, principal, LIMIT, principal), low);
        assertEq(h.size(1.4e18, principal, LIMIT + 1, principal), high);
    }

    /// @dev The slack the hub reserves: one atom for an order that can only fill whole, two per minimum fill otherwise.
    function _slack(uint256 principal, uint256 minFill) internal pure returns (uint256) {
        return principal / minFill < 2 ? 1 : Math.ceilDiv(2 * principal, minFill);
    }

    function testFuzz_401_AdmittedSizingMatchesTheFormula(uint128 debt, uint128 px, uint128 fill) public view {
        uint256 principal = uint256(debt) + 1;
        uint256 price = uint256(px) + Q;
        uint256 minFill = uint256(fill) % principal + 1;
        uint256 expected = FullMath.mulDivRoundingUp(1.4e18 * principal, Q, price * W) + _slack(principal, minFill);
        assertEq(h.size(1.4e18, principal, price, minFill), expected);
    }

    function testFuzz_401_FullWidthAdmittedSizing(uint256 coverage, uint256 principal, uint256 price, uint256 minFill, bool highPrice) public view {
        coverage = bound(coverage, 1.05e18, 20e18);
        principal = bound(principal, 1, U / coverage);
        // At this price the requirement plus the slack of a two-atom minimum fill stays below the collateral cap.
        price = highPrice ? bound(price, LIMIT + 1, U) : bound(price, 32 * Q, LIMIT);
        minFill = bound(minFill, principal < 2 ? 1 : 2, principal);
        uint256 num = coverage * principal;
        uint256 required = highPrice ? FullMath.mulDivRoundingUp(FullMath.mulDivRoundingUp(num, Q, price), 1, W) : FullMath.mulDivRoundingUp(num, Q, price * W);
        uint256 expected = required + _slack(principal, minFill);
        assertLe(expected, LIMIT, "fixture must be admissible");
        assertEq(h.size(coverage, principal, price, minFill), expected);
    }
}

contract AceOrderInputDoorTest is AceOrderFixture {
    function test_401_PostNamesPrincipalOverflowBeforeCustody() public {
        uint256 count = read.loanCount();
        uint256 balance = vault.balanceOf(maker);
        vm.prank(maker);
        vm.expectRevert(bytes4(keccak256("OrderPrincipalOutOfRange()")));
        ace.postOrder(id, type(uint256).max, LIQ, LIQ_HIGH, MINFILL, TEN, _far());
        assertEq(read.loanCount(), count);
        assertEq(vault.balanceOf(maker), balance);
    }

    function test_401_PostAboveUint128RemainsValid() public {
        uint256 principal = uint256(type(uint128).max) + 1;
        vm.prank(maker);
        uint256 orderId = ace.postOrder(id, principal, type(uint256).max, type(uint256).max, principal, TEN, _far());
        assertEq(ace.orderOf(orderId).principal, principal);
        assertEq(pm.collateralOf(orderId), ace.orderOf(orderId).collateralUnits);
    }

    function test_401_PostCollateralOverflowLeavesNoOrderOrCustody() public {
        uint256 principal = type(uint256).max / ace.idToMarketParams(id).minCoverageWad;
        uint256 nextId = read.loanCount() + 1;
        bytes32 ledger = keccak256(abi.encode(read.loanCount(), ace.orderCount(id), ace.orderOf(nextId), read.marketState(id)));
        bytes32 custody = keccak256(abi.encode(pm.collateralOf(nextId), vault.balanceOf(maker), vault.balanceOf(address(pm))));
        bytes32 quote = keccak256(abi.encode(usdc.balanceOf(maker), usdc.balanceOf(address(ace))));

        vm.prank(maker);
        vm.expectRevert(bytes4(keccak256("CollateralOutOfRange()")));
        ace.postOrder(id, principal, 1, 1, principal, TEN, _far());

        assertEq(keccak256(abi.encode(read.loanCount(), ace.orderCount(id), ace.orderOf(nextId), read.marketState(id))), ledger);
        assertEq(keccak256(abi.encode(pm.collateralOf(nextId), vault.balanceOf(maker), vault.balanceOf(address(pm)))), custody);
        assertEq(keccak256(abi.encode(usdc.balanceOf(maker), usdc.balanceOf(address(ace)))), quote);
    }
}

contract AceWithdrawalInputRefusalsTest is AceRefinanceWithdrawFixture {
    uint256 internal constant COLL = 12_000e18;
    bytes4 internal constant OVER = bytes4(keccak256("WithdrawalExceedsCollateral()"));

    function setUp() public {
        _boot();
    }

    function test_401_DirectOverwithdrawalIsNamedAndAtomic() public {
        uint256 loanId = _open(flat, COLL, P);
        vm.prank(borrower);
        vm.expectRevert(OVER);
        ace.withdrawCollateral(loanId, COLL + 1, sink);
        assertEq(read.loan(loanId).collateralUnits, COLL);
        assertEq(pm.collateralOf(loanId), COLL);
        assertEq(vault.balanceOf(sink), 0);
    }

    function test_401_RefinanceOverwithdrawalRollsBackAllEffects() public {
        uint256 oldId = _open(flat, COLL, P);
        uint256 count = read.loanCount();
        bytes32 marketBefore = keccak256(abi.encode(read.marketState(flat)));
        uint256 cash = usdc.balanceOf(address(ace));
        uint256 wallet = usdc.balanceOf(borrower);
        _refuses(_args(oldId, flat, NEWP, COLL + 1, sink), OVER, "overdraw is named");
        assertEq(read.loanCount(), count);
        assertEq(read.loan(oldId).closedAt, 0);
        assertEq(read.loan(oldId).debt, P);
        assertEq(read.loan(oldId).collateralUnits, COLL);
        assertEq(pm.collateralOf(oldId), COLL);
        assertEq(pm.collateralOf(count + 1), 0);
        assertEq(keccak256(abi.encode(read.marketState(flat))), marketBefore);
        assertEq(usdc.balanceOf(address(ace)), cash);
        assertEq(usdc.balanceOf(borrower), wallet);
        assertEq(vault.balanceOf(sink), 0);
    }

    function test_401_ExistingRefusalPrecedenceSurvivesOverdraw() public {
        uint256 loanId = _open(flat, COLL, P);
        vm.prank(sink);
        vm.expectRevert(bytes4(keccak256("NotBorrower()")));
        ace.withdrawCollateral(loanId, COLL + 1, sink);
        _refuses(_args(loanId, flat, NEWP, COLL + 1, address(0)), bytes4(keccak256("ZeroWithdrawTo()")), "destination first");
        _warpTo(read.loan(loanId).expiry);
        vm.prank(borrower);
        vm.expectRevert(bytes4(keccak256("LoanMatured()")));
        ace.withdrawCollateral(loanId, COLL + 1, sink);
    }
}
