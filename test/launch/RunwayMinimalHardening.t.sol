// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.36;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {LaunchOpsBudget} from "../../src/entities/launch/LaunchOpsBudget.sol";
import {RunwayFixture} from "./RunwayFixture.sol";

/// @title RunwayMinimalHardening
/// @notice Rows for the minimal rewrite's changed lines that a mutation pass found killed only by accident.
/// @notice `wallet != 0` is settlement's only latch; without it a second settle fails only for want of the ops tokens.
contract RunwayMinimalHardeningTest is RunwayFixture {
    uint24 internal constant MPS = 1e7;
    uint256 internal constant Q = 1 << 96;
    uint160 internal constant PRICE = 1 << 96;

    /// @notice A second settle is refused even once the ops tokens are back in the budget, and the first split stands.
    /// @notice Without the latch, anyone who sent the budget the ops amount, the operator included, could settle again.
    /// @notice That second split would take the bids' pool into a fresh wallet as the team's capped share.
    function test_ASecondSettleIsRefusedWithTheOpsDonatedBack() public {
        Made memory m = _launch();
        m.auction.setState(m.auction.endBlock(), true, 10_000e6 * Q * MPS);
        strat.openPool(m.key, PRICE);
        usdc.mint(address(m.budget), 2_500e6);
        strat.send(m.token, address(m.budget), 400_000e18);
        _warpTo(m.launchBy + 1);
        m.budget.settle();
        address w = m.budget.wallet();
        assertEq(m.budget.refundPool(), 500e6, "fixture: the excess over the share is the bids' pool");

        strat.send(m.token, address(m.budget), OPS);
        vm.prank(operator);
        vm.expectRevert(LaunchOpsBudget.AlreadySettled.selector);
        m.budget.settle();
        assertEq(m.budget.wallet(), w, "a second settle made another wallet");
        assertEq(m.budget.refundPool(), 500e6, "a second settle moved the bids' pool");
        assertEq(usdc.balanceOf(address(m.budget)), 500e6, "the bids' pool left the budget");
        assertEq(usdc.balanceOf(w), 2_000e6, "the wallet holds other than the first split's share");
        assertEq(IERC20(m.token).balanceOf(address(m.budget)), OPS, "the donated tokens moved");
    }
}
