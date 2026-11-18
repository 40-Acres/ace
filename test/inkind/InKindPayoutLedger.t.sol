// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.36;

import {IUnclaimedPayouts} from "./InKindClaimBudget.t.sol";
import {InKindRig} from "./InKindRig.sol";

/// @title InKindPayoutLedger
/// @notice How collects become payouts, read off the tracker's own words: one block's collects share a batch, and a token pays once a batch.
/// @notice A batch waiting on zero tracked supply stays open across blocks, so a later block's collect joins its payout rather than opening another.
/// @dev Every payout figure is the collect's own answer; the claims are checked against floors computed here from the shares, never the lens.
contract InKindPayoutLedgerTest is InKindRig {
    uint256 internal constant TOKENS_AT = 4; // every token a payout carried
    uint256 internal constant CLOCK_AT = 6; // batchCount in the low 48 bits, foldBlock above it
    uint256 internal constant BATCHES_AT = 7; // batch => at | supply << 48
    uint256 internal constant PAYOUTS_AT = 10; // token => [batch | units << 48]

    function _root(uint256 k) internal pure returns (bytes32) {
        return bytes32(uint256(INKIND_ROOT) + k);
    }

    function _word(bytes32 slot) internal view returns (uint256) {
        return uint256(vm.load(address(vault), slot));
    }

    function _batchCount() internal view returns (uint256 count, uint256 foldBlock) {
        uint256 w = _word(_root(CLOCK_AT));
        (count, foldBlock) = (uint48(w), uint48(w >> 48));
    }

    function _batch(uint256 k) internal view returns (uint256 at, uint256 supply) {
        uint256 w = _word(keccak256(abi.encode(k, _root(BATCHES_AT))));
        (at, supply) = (uint48(w), w >> 48);
    }

    function _payoutCount(address token) internal view returns (uint256) {
        return _word(keccak256(abi.encode(token, _root(PAYOUTS_AT))));
    }

    function _payout(address token, uint256 i) internal view returns (uint256 batch, uint256 units) {
        bytes32 len = keccak256(abi.encode(token, _root(PAYOUTS_AT)));
        uint256 w = _word(bytes32(uint256(keccak256(abi.encode(len))) + i));
        (batch, units) = (uint48(w), w >> 48);
    }

    function _paidToken(uint256 i) internal view returns (address) {
        return address(uint160(_word(bytes32(uint256(keccak256(abi.encode(_root(TOKENS_AT)))) + i))));
    }

    function _unclaimed(address holder, address token) internal view returns (uint256) {
        return IUnclaimedPayouts(address(lens)).unclaimedPayouts(address(vault), holder, token);
    }

    /// @notice Two collects of one token in one block are one payout of both pots; a second token takes its own payout of the same batch.
    /// @notice A later block's collect closes that batch first and opens the next, so the token's second payout names batch two.
    function test_OneBlocksCollectsShareABatch_ATokenPaysOnceABatch() public {
        uint256 sa = _lp(alice, LP_CASH);
        _warpBy(MIN_TENOR + 1 hours);
        uint256[3] memory a = [_open(address(tokA)), _open(address(tokA)), _open(address(tokA))];
        uint256 b1 = _open(address(tokB));
        _toExpiry(a[0]);
        uint256 blk = _blk; // the rig's stored block clock: via-IR re-reads block.number at its use, past a later roll
        uint256[3] memory u = [_collect(a[0]), _collect(a[1]), _collect(b1)];
        _assertOneBatchOfTwoTokens(blk, u[0] + u[1], u[2]);
        _nextBlock();
        uint256 u3 = _collect(a[2]);
        _assertTheSecondBatch(blk, sa, u3);
        _nextBlock();
        assertEq(_unclaimed(alice, address(tokA)), 2, "the lens counts tokA's two payouts");
        assertEq(_unclaimed(alice, address(tokB)), 1, "and tokB's one");
        vm.prank(alice);
        uint256[] memory paid = vault.claim(_toks(address(tokA), address(tokB)), alice);
        assertEq(paid[0], u[0] + u[1] + u3, "the sole holder takes every unit of tokA");
        assertEq(paid[1], u[2], "and of tokB");
    }

    function _assertOneBatchOfTwoTokens(uint256 blk, uint256 unitsA, uint256 unitsB) internal view {
        (uint256 count, uint256 fb) = _batchCount();
        assertEq(count, 1, "one block's collects open one batch");
        assertEq(fb, blk, "open from the collects' block");
        assertEq(_payoutCount(address(tokA)), 1, "two pots of one token in one batch are one payout");
        (uint256 batch, uint256 units) = _payout(address(tokA), 0);
        assertEq(batch, 1, "of batch one");
        assertEq(units, unitsA, "carrying both pots");
        (batch, units) = _payout(address(tokB), 0);
        assertEq(batch, 1, "the second token's payout names the same batch");
        assertEq(units, unitsB, "and carries its own pot");
        assertEq(_word(_root(TOKENS_AT)), 2, "two tokens paid out");
        assertEq(_paidToken(0), address(tokA), "listed in the order of their first payouts");
        assertEq(_paidToken(1), address(tokB), "tokB second");
    }

    function _assertTheSecondBatch(uint256 blk, uint256 sa, uint256 u3) internal view {
        (uint256 count,) = _batchCount();
        assertEq(count, 2, "a later block's collect opens a second batch");
        (uint256 at, uint256 supply) = _batch(1);
        assertEq(at, blk, "after closing the first at its block");
        assertEq(supply, sa, "on the supply its block ended with");
        assertEq(_payoutCount(address(tokA)), 2, "the token's second payout");
        (uint256 batch, uint256 units) = _payout(address(tokA), 1);
        assertEq(batch, 2, "names batch two");
        assertEq(units, u3, "and carries the third pot alone");
        assertEq(_word(_root(TOKENS_AT)), 2, "a token paid again is not listed again");
    }

    /// @notice With nothing tracked a batch waits open, re-stamped, so a later block's collect joins its one payout; it closes on the first supply.
    /// @dev Alice gifts every share to the vault before the collects, so the tracked supply is zero until bob enters.
    function test_AtZeroTrackedSupplyALaterBlocksCollectJoinsTheWaitingBatch() public {
        uint256 sa = _lp(alice, LP_CASH);
        (uint256 l1, uint256 l2) = (_open(address(tokA)), _open(address(tokA)));
        vm.prank(alice);
        vault.transfer(address(vault), sa);
        _toExpiry(l1);
        uint256 u1 = _collect(l1);
        assertEq(_trackedSupply(), 0, "premise: nothing is tracked at the first collect");
        _nextBlock();
        uint256 u2 = _collect(l2);
        (uint256 count, uint256 fb) = _batchCount();
        assertEq(count, 1, "the waiting batch was not closed");
        assertEq(fb, block.number, "but re-stamped to this block");
        assertEq(_payoutCount(address(tokA)), 1, "so the second pot joined its payout");
        (, uint256 units) = _payout(address(tokA), 0);
        assertEq(units, u1 + u2, "carrying both pots");
        _warpBy(1 hours);
        _nextBlock();
        uint256 stamp = _blk;
        uint256 sb = _lp(bob, 1_000e6);
        assertEq(_trackedSupply(), sb, "premise: bob is the first tracked holder");
        _nextBlock();
        uint256 pb = _claim(bob, address(tokA));
        (uint256 at, uint256 supply) = _batch(1);
        assertEq(at, stamp, "the batch closed on the block that first held a tracked share");
        assertEq(supply, sb, "on that block's tracked supply");
        assertEq(pb, u1 + u2, "bob, the first holder, takes both pots");
        assertEq(_claim(alice, address(tokA)), 0, "alice, who gave her shares away, takes none");
    }
}
