// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.36;

import {FullMath} from "@uniswap/v4-core/src/libraries/FullMath.sol";
import {LoanMath} from "../../src/ace/hub/libraries/LoanMath.sol";
import {MigrateArgs, OpenBounds} from "../../src/ace/hub/Types.sol";
import {DrawMoreRig} from "../utils/DrawMoreRig.sol";

/// @title AceDrawMoreEscrowTest
/// @notice A top-up re-anchors one fee schedule rather than storing a tranche per draw; the refund at a close must still be the tranches' sum.
/// @notice THE ORACLE is written apart from the hub: each tranche `e_i` earns linearly from its own start `t_i` to the shared end `x`.
/// @notice So a close at `t` refunds the sum of `e_i (x - t) / (x - t_i)`; an extension moves `x` and carries the unearned part as one tranche.
/// @notice The hub floors once per re-anchor and once at the close, each loss scaled by later ratios of at most one: N + 1 short, and never over.
/// @dev The oracle keeps a floored and a ceiled copy, so the bound is asserted on both sides without trusting either rounding.
contract AceDrawMoreEscrowTest is DrawMoreRig {
    uint256[] internal lo; // each tranche's escrow, every carry floored
    uint256[] internal hi; // each tranche's escrow, every carry ceiled
    uint64[] internal start; // each tranche's start
    uint64 internal end; // the shared end every tranche earns to
    uint256 internal reanchors; // top-ups and extensions so far: each is one floor in the hub

    function setUp() public override {
        super.setUp();
        _deposit(id, alice, 40 * P);
    }

    /* ============================== the oracle ============================== */

    /// @dev A loan at a fifth of the price for `LONG`, and its open escrow as the oracle's first tranche.
    function _openTracked() internal returns (uint256 loanId) {
        loanId = _openIn(id, borrower, P, LONG, 2000);
        uint256 e = read.feeEscrowOf(loanId);
        lo.push(e);
        hi.push(e);
        start.push(uint64(_now()));
        end = read.loan(loanId).expiry;
    }

    /// @dev A tranche's share still unearned at `t`, floored or ceiled.
    function _share(uint256 e, uint64 t0, uint64 t, bool up) internal view returns (uint256) {
        if (t >= end) return 0;
        return up ? FullMath.mulDivRoundingUp(e, end - t, end - t0) : FullMath.mulDiv(e, end - t, end - t0);
    }

    /// @dev The oracle's refund at the clock, floored and ceiled.
    function _oracle() internal view returns (uint256 down, uint256 up) {
        uint64 t = uint64(_now());
        for (uint256 i; i < lo.length; i++) {
            down += _share(lo[i], start[i], t, false);
            up += _share(hi[i], start[i], t, true);
        }
    }

    /// @dev A top-up opens a tranche of its escrow cut from now; the others keep their own starts and the end.
    function _topTracked(address who, uint256 loanId, uint256 amount) internal {
        uint256 cut = LoanMath.escrowCut(_top(who, loanId, amount));
        lo.push(cut);
        hi.push(cut);
        start.push(uint64(_now()));
        reanchors++;
    }

    /// @dev An extension carries every tranche's unearned part into one tranche from now, adds its own escrow cut, and moves the end.
    function _extendTracked(address who, uint256 loanId) internal {
        (uint256 down, uint256 up) = _oracle();
        uint256 cut = LoanMath.escrowCut(_extend(who, loanId));
        delete lo;
        delete hi;
        delete start;
        lo.push(down + cut);
        hi.push(up + cut);
        start.push(uint64(_now()));
        end = read.loan(loanId).expiry;
        reanchors++;
    }

    /// @dev The holder repays in full and the hub credits the refund; the oracle's sandwich must hold it.
    function _closeAndCheck(uint256 loanId) internal {
        (uint256 down, uint256 up) = _oracle();
        uint256 debt = read.debtOf(loanId);
        _fund(borrower, debt);
        vm.prank(borrower);
        ace.repay(loanId, debt);
        uint256 refund = read.quoteOwedOf(loanId, borrower);
        assertLe(refund, up, "the hub refunded more than the tranches' sum");
        assertGe(refund + reanchors + 1, down, "the hub refunded more than N + 1 short of the tranches' sum");
        _assertSolvent();
    }

    /* ============================== the fuzz rows ============================== */

    /// @notice Two top-ups at fuzzed times and amounts, an optional holder extension, then a close: the refund is the tranches' sum within N + 1.
    function testFuzz_TheRefundIsTheTranchesSum(uint32 d1, uint32 d2, uint32 de, uint32 dc, uint256 a1, uint256 a2, bool ext) public {
        uint256 loanId = _openTracked();
        _warpBy(bound(d1, 1, 10 days));
        _topTracked(borrower, loanId, bound(a1, MIN_PRINCIPAL, P / 4));
        _warpBy(bound(d2, 1, 10 days));
        _topTracked(borrower, loanId, bound(a2, MIN_PRINCIPAL, P / 4));
        if (ext) {
            _warpBy(bound(de, 1, end - _now() - 1));
            _extendTracked(borrower, loanId);
        }
        _warpBy(bound(dc, 0, end - _now() - 1));
        _closeAndCheck(loanId);
    }

    /// @notice B-6: strangers' last-quarter extensions interleave with the holder's top-ups, each re-anchor a floor, and the bound still holds.
    function testFuzz_StrangerExtensionsInterleaveWithTopUps(uint256 seed) public {
        uint256 loanId = _openTracked();
        for (uint256 i; i < 8; i++) {
            seed = uint256(keccak256(abi.encode(seed, i)));
            uint256 left = end - _now();
            _warpBy(bound(seed, 1, left - 1));
            if (end - _now() <= LONG / 4) _extendTracked(stranger, loanId);
            else if (end - _now() >= TEN7) _topTracked(borrower, loanId, bound(seed >> 128, MIN_PRINCIPAL, P / 10));
        }
        _closeAndCheck(loanId);
    }

    /// @notice A refinance after a top-up nets the re-anchored refund: the borrower's out sits inside the oracle's sandwich.
    function testFuzz_ARefinanceAfterATopUpNetsTheRefund(uint32 d1, uint32 d2, uint256 a1) public {
        uint256 loanId = _openTracked();
        _warpBy(bound(d1, 1, 10 days));
        _topTracked(borrower, loanId, bound(a1, MIN_PRINCIPAL, P / 4));
        _warpBy(bound(d2, 1, end - _now() - 1));
        (uint256 down, uint256 up) = _oracle();
        uint256 debt = read.debtOf(loanId);
        uint256 newP = debt + P;
        uint256 feeNew = _fee(newP, TEN7);
        uint256 bal0 = usdc.balanceOf(borrower);
        vm.prank(borrower);
        ace.refinanceTo(MigrateArgs(loanId, id, newP, TEN7, OpenBounds(0, 0, 0), 0, address(0)));
        uint256 out = usdc.balanceOf(borrower) - bal0;
        assertLe(out, newP - feeNew + up - debt, "the refinance netted more than the tranches' refund");
        assertGe(out + reanchors + 1, newP - feeNew + down - debt, "the refinance netted more than N + 1 short of it");
        _assertSolvent();
    }

    /// @notice A settlement after a top-up earns the whole escrow to the lender: none of it refunds, and the books stay whole.
    function test_ASettlementAfterATopUpEarnsTheEscrowWhole() public {
        uint256 loanId = _openTracked();
        _warpBy(2 days);
        _topTracked(borrower, loanId, P / 4);
        _warpBy(1 days);
        assertGt(read.feeEscrowOf(loanId), 0, "PREMISE: an escrow to earn");
        rec.setBandPrice(read.triggerPrice(loanId) - 1);
        ace.finalize(loanId);
        assertEq(read.feeEscrowOf(loanId), 0, "settlement earned the escrow whole");
        assertEq(read.quoteOwedOf(loanId, borrower), 0, "and refunded none of it");
        _assertSolvent();
    }
}
