// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.36;

import {MockERC20} from "../mocks/MockERC20.sol";
import {Listing} from "./InKindSurface.sol";
import {InKindRig} from "./InKindRig.sol";

/// @notice The lens view a claim's NatSpec points a caller at, which the shared lens surface does not declare.
interface IUnclaimedPayouts {
    function unclaimedPayouts(address vault, address holder, address token) external view returns (uint256);
}

/// @title InKindClaimBudget
/// @notice THE 400/16 CLAIM BUDGET, step for step: a token with nothing left costs one, any other its 16-step charge and then one a payout read.
/// @notice Each row is built so the arithmetic lands on an edge: 400 = 23 * 17 + 9, so nine one-step names leave a fresh token exactly 17.
/// @dev Alice is the only holder, with one checkpoint, so a fresh token with one payout costs exactly 17 steps and pays its whole payout.
contract InKindClaimBudgetTest is InKindRig {
    uint256 internal constant PER_FRESH = 17; // a one-payout token over a one-checkpoint holder: the 16-step charge and one payout read
    address[] internal _toks_;

    /// @dev A vault listing `n` fresh tokens, alice its only holder, and one loan per token collected in one batch: one payout each.
    function _paidOnceEach(uint256 n) internal returns (uint256[] memory units) {
        Listing[] memory l = new Listing[](n);
        for (uint256 i; i < n; i++) {
            _toks_.push(address(new MockERC20("T", "T", 18)));
            l[i] = _listing(_toks_[i], CAP);
        }
        vault = _deploy(_cfg(0), _ik(), l);
        _lp(alice, LP_CASH);
        _warpBy(MIN_TENOR + 1 hours);
        uint256[] memory ids = new uint256[](n);
        for (uint256 i; i < n; i++) {
            ids[i] = _open(_toks_[i]);
        }
        _toExpiry(ids[0]);
        vm.prank(keeper);
        units = vault.collectForfeited(ids);
        _nextBlock();
        for (uint256 i; i < n; i++) {
            assertGt(units[i], 0, "premise: every token came home");
        }
    }

    /// @dev `k` addresses no payout ever carried: each costs a claim exactly one step.
    function _nothing(uint256 k) internal pure returns (address[] memory a) {
        a = new address[](k);
        for (uint256 i; i < k; i++) {
            a[i] = address(uint160(0xDEAD0000 + i));
        }
    }

    /// @dev The listed tokens `[from, to)`.
    function _slice(uint256 from, uint256 to) internal view returns (address[] memory a) {
        a = new address[](to - from);
        for (uint256 i = from; i < to; i++) {
            a[i - from] = _toks_[i];
        }
    }

    function _cat(address[] memory a, address[] memory b) internal pure returns (address[] memory c) {
        c = new address[](a.length + b.length);
        for (uint256 i; i < a.length; i++) {
            c[i] = a[i];
        }
        for (uint256 i; i < b.length; i++) {
            c[a.length + i] = b[i];
        }
    }

    function _claimList(address[] memory toks) internal returns (uint256[] memory paid) {
        vm.prank(alice);
        paid = vault.claim(toks, alice);
        assertEq(paid.length, toks.length, "one answer a named token");
    }

    /// @dev Exactly the first `want` answers from `from` paid their token's whole payout, `units` indexed from `tokFrom`; every later one paid zero.
    function _assertFirstPaid(uint256[] memory paid, uint256 from, uint256[] memory units, uint256 tokFrom, uint256 want) internal pure {
        for (uint256 i = from; i < paid.length; i++) {
            uint256 u = units[tokFrom + i - from];
            if (i - from < want) assertEq(paid[i], u, "BUDGET: a token inside the budget was not paid its whole payout");
            else assertEq(paid[i], 0, "BUDGET: a token past the budget was paid");
        }
    }

    // ---- the per-token arithmetic ----

    /// @notice Forty fresh tokens: the first call pays exactly the first 23 whole (400 - 23 * 17 = 9, under the charge), the second the other 17.
    function test_FortyFreshTokens_TheFirstCallPaysExactlyTwentyThree() public {
        uint256[] memory units = _paidOnceEach(40);
        uint256[] memory p1 = _claimList(_toks_);
        _assertFirstPaid(p1, 0, units, 0, 23);
        uint256[] memory p2 = _claimList(_toks_);
        for (uint256 i; i < 23; i++) {
            assertEq(p2[i], 0, "a finished token pays nothing again");
        }
        _assertFirstPaid(p2, 23, units, 23, 17);
        for (uint256 i; i < 40; i++) {
            assertEq(MockERC20(_toks_[i]).balanceOf(alice), units[i], "every token paid exactly once, whole");
            assertEq(_claimable(alice, _toks_[i]), 0, "and nothing left owed");
        }
    }

    /// @notice Nine names with no payouts cost one step each: 391 = 23 * 17, so the 23rd fresh token meets exactly its charge plus one, and pays.
    function test_NineEmptyNames_TheTwentyThirdFreshTokenGetsItsLastStep() public {
        uint256[] memory units = _paidOnceEach(23);
        uint256[] memory paid = _claimList(_cat(_nothing(9), _toks_));
        for (uint256 i; i < 9; i++) {
            assertEq(paid[i], 0, "a name with no payouts pays nothing");
        }
        _assertFirstPaid(paid, 9, units, 0, 23);
    }

    /// @notice Ten such names leave 390 = 22 * 17 + 16: the 23rd fresh token meets only its charge, pays nothing, and keeps its place.
    function test_TenEmptyNames_TheTwentyThirdFreshTokenStopsAtItsCharge() public {
        uint256[] memory units = _paidOnceEach(23);
        uint256[] memory paid = _claimList(_cat(_nothing(10), _toks_));
        _assertFirstPaid(paid, 10, units, 0, 22);
        assertEq(_claimable(alice, _toks_[22]), units[22], "the stopped token keeps its whole payout owed");
        assertEq(_claimList(_slice(22, 23))[0], units[22], "and the next call pays it");
    }

    /// @notice A finished token costs one step as an empty name does: nine finished leave the 23rd fresh its last step, ten stop it.
    function test_FinishedTokensCostOneStepEach_TheSameEdge() public {
        uint256[] memory units = _paidOnceEach(33);
        uint256[] memory first = _claimList(_slice(0, 10));
        _assertFirstPaid(first, 0, units, 0, 10);
        uint256 snap = vm.snapshotState();
        uint256[] memory nine = _claimList(_cat(_slice(1, 10), _slice(10, 33)));
        for (uint256 i; i < 9; i++) {
            assertEq(nine[i], 0, "a finished token pays nothing");
        }
        _assertFirstPaid(nine, 9, units, 10, 23);
        vm.revertToState(snap);
        uint256[] memory ten = _claimList(_cat(_slice(0, 10), _slice(10, 33)));
        _assertFirstPaid(ten, 10, units, 10, 22);
    }

    /// @notice A list longer than the budget never reverts: 400 empty names spend it whole, and a fresh token named after them keeps its place.
    /// @dev The loop's `budget != 0` is what keeps a 401st name from reading `budget - 1` at zero.
    function test_AListLongerThanTheBudgetNeverReverts() public {
        uint256[] memory units = _paidOnceEach(1);
        address[] memory list = _cat(_nothing(500), _slice(0, 1));
        uint256[] memory paid = _claimList(list);
        for (uint256 i; i < list.length; i++) {
            assertEq(paid[i], 0, "nothing past the spent budget pays");
        }
        assertEq(_claimable(alice, _toks_[0]), units[0], "the fresh token named last keeps its whole payout");
        uint256[] memory again = _claimList(_cat(_nothing(399), _slice(0, 1)));
        assertEq(again[399], 0, "399 empty names leave one step, under the charge");
        assertEq(_claimList(_cat(_nothing(383), _slice(0, 1)))[383], units[0], "383 leave 17, and it pays");
    }

    // ---- unclaimedPayouts: the lens view a claim list should be built from ----

    function _unclaimed(address holder, address token) internal view returns (uint256) {
        return IUnclaimedPayouts(address(lens)).unclaimedPayouts(address(vault), holder, token);
    }

    /// @dev `n` payouts of tokA, each its own batch a block apart, alice the only holder at every one; returns their units.
    function _payouts(uint256 n) internal returns (uint256[] memory units) {
        _lp(alice, LP_CASH);
        _warpBy(MIN_TENOR + 1 hours);
        uint256[] memory ids = new uint256[](n);
        for (uint256 i; i < n; i++) {
            ids[i] = _openFor(address(tokA), MIN_PRINCIPAL, MIN_TENOR);
        }
        _toExpiry(ids[0]);
        units = new uint256[](n);
        for (uint256 i; i < n; i++) {
            units[i] = _collect(ids[i]);
            _nextBlock();
        }
        _lp(dave, 1_000e6); // a later block's share move closes the last batch on alice alone
    }

    function _sum(uint256[] memory a, uint256 from, uint256 to) internal pure returns (uint256 s) {
        for (uint256 i = from; i < to; i++) {
            s += a[i];
        }
    }

    /// @notice It counts the payouts a holder's cursor has not passed: all of them before a claim, the 6 a 384-payout walk left, then none.
    function test_UnclaimedPayouts_FallsByTheWalkAndReachesZero() public {
        uint256[] memory units = _payouts(390);
        assertEq(_unclaimed(alice, address(tokA)), 390, "before any claim every payout is unwalked");
        assertEq(_unclaimed(alice, address(tokB)), 0, "a token no payout carried has none");
        assertEq(_claimList(_slice2(address(tokA)))[0], _sum(units, 0, 384), "premise: one call walks 400 - 16 payouts");
        assertEq(_unclaimed(alice, address(tokA)), 6, "the view counts exactly what the walk left");
        assertEq(_claimList(_slice2(address(tokA)))[0], _sum(units, 384, 390), "the next call pays the rest");
        assertEq(_unclaimed(alice, address(tokA)), 0, "and the view reads none left");
    }

    /// @notice It is an upper bound: a late joiner's view counts every payout, though only the last is owed, and its first claim clears all.
    function test_UnclaimedPayouts_ALateJoinerReadsEveryPayoutAndOneClaimClearsThem() public {
        _payouts(20);
        _lp(carol, LP_CASH);
        _warpBy(MIN_TENOR + 1 hours);
        uint256 pot = _defaultAndCollect(_open(address(tokA)));
        _nextBlock();
        assertEq(_unclaimed(carol, address(tokA)), 21, "the view is at most: every payout, the twenty before carol's first checkpoint included");
        uint256 owed = _claimable(carol, address(tokA));
        assertGt(owed, 0, "premise: carol is owed the last payout");
        assertLt(owed, pot, "premise: and shares it with alice");
        vm.prank(carol);
        assertEq(vault.claim(_slice2(address(tokA)), carol)[0], owed, "carol's first claim pays what she is owed");
        assertEq(_unclaimed(carol, address(tokA)), 0, "and her search skipped the twenty, so none is left");
    }

    function _slice2(address t) internal pure returns (address[] memory a) {
        a = new address[](1);
        a[0] = t;
    }
}
