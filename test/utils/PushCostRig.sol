// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.36;

import {Test} from "forge-std/Test.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {Ace} from "../../src/ace/hub/Ace.sol";

interface IMintable {
    function mint(address to, uint256 amount) external;
}

/// @title PushCostRig
/// @notice Measures what `Ace.pushToken` -- the lender push's self-call -- needs as a `{gas:}` budget, per token shape.
/// @notice NEED is the least budget at which the call succeeds, bisected to one gas and re-probed on both sides of the edge.
/// @notice USED is what the callee frame actually spent, read from `vm.lastCallGas` at a generous budget.
/// @dev The call is made pranked as the hub, so `SelfCallOnly` admits it and the callee frame is exactly the self-call's.
/// @dev Every balance is funded in `setUp`, a committed transaction, so each SSTORE's original value is the real one.
/// @dev ALL COLD probes a FRESH COPY of the token each time, untouched in this transaction: its account and every word are cold.
/// @dev WARM models the closing repay: snapshot, `vm.cool`, then a pull INTO the hub, so the hub's word is written this transaction.
/// @dev `vm.cool` cools an account's WORDS but not the ACCOUNT on forge 1.7.1, so a cool-only row is logged as its own state.
/// @dev The rig checks itself: a zero->nonzero write costs exactly 17,100 more, and a fresh account exactly 2,500 more per account.
abstract contract PushCostRig is Test {
    Ace internal ace;
    address internal constant PAYER = address(0x9A7E4); // funds the warm-up pull
    address internal constant LENDER_FUNDED = address(0x1E4D); // already holds the token: a clean nonzero->nonzero write
    address internal lenderEmpty; // never held the token: a zero->nonzero write
    uint256 internal constant AMOUNT = 1_000e6; // what each push moves
    uint256 internal constant HUB_BAL = 1_000_000e6;
    uint256 internal constant LENDER_BAL = 5_000e6;
    uint256 internal constant HI = 1_000_000; // the ceiling budget; every shape must succeed under it
    uint256 internal constant POOL = 44; // fresh copies per shape: each all-cold case takes 19
    uint256 internal constant COLD_SEARCH = 8_192; // the all-cold edge sits within this of the cool-only edge
    uint256 internal constant ZERO_TO_NONZERO_EXTRA = 17_100; // EIP-2200 SSTORE_SET 20,000 less SSTORE_RESET 2,900
    uint256 internal constant COLD_ACCOUNT_EXTRA = 2_500; // EIP-2929 cold account access 2,600 less warm 100
    bytes32 internal constant ZOS_IMPLEMENTATION_SLOT = 0x7050c9e0f4ca769c69bd3a8ef740bc37934f8e2c036e5a723fd8ee048ed3f8c3;
    uint8 internal constant WARM = 0;
    uint8 internal constant COOLED = 1;
    uint8 internal constant FRESH = 2;

    mapping(address => address[]) internal fresh; // untouched copies of a shape, one per all-cold probe
    mapping(address => uint256) internal taken; // copies this transaction has used

    struct Cost {
        uint256 need;
        uint256 used;
        uint256 tokenFrame;
        uint256 callerOverhead;
    }

    function _implOf(address proxy) internal view returns (address) {
        return address(uint160(uint256(vm.load(proxy, ZOS_IMPLEMENTATION_SLOT))));
    }

    /// @dev Fund the hub and the funded lender, and the payer on a shape's main instance; setUp only, so the writes are committed.
    function _fund(address token, bool viaDeal, bool withPayer) internal {
        if (viaDeal) {
            deal(token, address(ace), HUB_BAL);
            deal(token, LENDER_FUNDED, LENDER_BAL);
            if (withPayer) deal(token, PAYER, 1_000e6);
        } else {
            IMintable(token).mint(address(ace), HUB_BAL);
            IMintable(token).mint(LENDER_FUNDED, LENDER_BAL);
            if (withPayer) IMintable(token).mint(PAYER, 1_000e6);
        }
    }

    function _nextCopy(address token) internal returns (address copy) {
        copy = fresh[token][taken[token]];
        taken[token] += 1;
    }

    /// @dev The warm case's earlier pull: one unit INTO the hub, which writes the hub's balance word in this transaction.
    function _prime(address token, bool warm) internal {
        if (!warm) return;
        vm.prank(PAYER);
        (bool ok, bytes memory ret) = token.call(abi.encodeWithSelector(IERC20.transfer.selector, address(ace), 1));
        require(ok && (ret.length == 0 || abi.decode(ret, (bool))), "warm-up pull failed");
    }

    /// @dev One push as the hub; `overhead` is the calling frame's own cost around the call, outside the budget.
    function _push(address token, address to, uint256 g) internal returns (bool ok, uint256 used, uint256 overhead) {
        require(address(ace).code.length > 0, "no hub"); // warms the hub account, as a self-call always finds it
        vm.prank(address(ace));
        uint256 g0 = gasleft();
        try ace.pushToken{gas: g}(token, to, AMOUNT) {
            uint256 g1 = gasleft();
            ok = true;
            used = vm.lastCallGas().gasTotalUsed;
            overhead = g0 - g1 - used;
        } catch {}
    }

    /// @dev FRESH takes a new copy; WARM and COOLED run on the main instance from a snapshot, after `vm.cool`.
    function _probe(address token, address impl, address to, uint8 mode, uint256 g) internal returns (bool ok, uint256 used, uint256 overhead) {
        if (mode == FRESH) return _push(_nextCopy(token), to, g);
        uint256 snap = vm.snapshotState();
        vm.cool(token);
        if (impl != address(0)) vm.cool(impl);
        _prime(token, mode == WARM);
        (ok, used, overhead) = _push(token, to, g);
        vm.revertToState(snap);
    }

    /// @dev The token's own frame, called directly as the hub: the push less its account access and wrapper.
    function _frame(address token, address to) internal returns (uint256 used) {
        vm.prank(address(ace));
        (bool ok, bytes memory ret) = token.call(abi.encodeWithSelector(IERC20.transfer.selector, to, AMOUNT));
        used = vm.lastCallGas().gasTotalUsed;
        require(ok && (ret.length == 0 || abi.decode(ret, (bool))), "direct transfer failed");
    }

    function _frameIn(address token, address impl, address to, uint8 mode) internal returns (uint256 used) {
        if (mode == FRESH) return _frame(_nextCopy(token), to);
        uint256 snap = vm.snapshotState();
        vm.cool(token);
        if (impl != address(0)) vm.cool(impl);
        _prime(token, mode == WARM);
        used = _frame(token, to);
        vm.revertToState(snap);
    }

    /// @dev Bisect the least succeeding budget in (lo, hi], then re-probe both sides of the edge and pin the spend.
    function _cost(address token, address impl, address to, uint8 mode, uint256 lo, uint256 hi) internal returns (Cost memory c) {
        bool ok;
        (ok, c.used, c.callerOverhead) = _probe(token, impl, to, mode, hi);
        assertTrue(ok, "the push fails at the top of the search: the rig is broken, not the budget");
        (ok,,) = _probe(token, impl, to, mode, lo);
        assertFalse(ok, "the push succeeds at the bottom of the search, so the edge is not inside it");
        while (hi - lo > 1) {
            uint256 m = (lo + hi) / 2;
            (ok,,) = _probe(token, impl, to, mode, m);
            if (ok) hi = m;
            else lo = m;
        }
        c.need = hi;
        _edge(token, impl, to, mode, c);
        c.tokenFrame = _frameIn(token, impl, to, mode);
    }

    function _edge(address token, address impl, address to, uint8 mode, Cost memory c) internal {
        (bool okAt, uint256 usedAt,) = _probe(token, impl, to, mode, c.need);
        (bool okBelow,,) = _probe(token, impl, to, mode, c.need - 1);
        assertTrue(okAt, "the edge did not re-probe as a success");
        assertFalse(okBelow, "one gas under the edge succeeded on re-probe");
        assertEq(usedAt, c.used, "the spend moved with the budget, so it is not a property of the token");
    }

    function _row(string memory shape, string memory lender, string memory state, Cost memory c) internal {
        string memory head = string.concat("PUSH-COST | ", shape, " | lender ", lender, " | ", state);
        string memory tail = string.concat(" | need ", vm.toString(c.need), " | used ", vm.toString(c.used), " | token frame ", vm.toString(c.tokenFrame));
        emit log_string(string.concat(head, tail, " | caller overhead ", vm.toString(c.callerOverhead)));
    }

    function _premise(address token) internal {
        address spare = fresh[token][POOL - 1];
        assertGt(IERC20(token).balanceOf(LENDER_FUNDED), 0, "premise: the funded lender holds the token");
        assertEq(IERC20(token).balanceOf(lenderEmpty), 0, "premise: the empty lender holds none");
        assertGe(IERC20(token).balanceOf(address(ace)), AMOUNT, "premise: the hub holds what it pushes");
        assertEq(IERC20(spare).balanceOf(LENDER_FUNDED), LENDER_BAL, "premise: every copy is funded as the main one is");
        assertEq(IERC20(spare).balanceOf(lenderEmpty), 0, "premise: and holds nothing for the empty lender");
    }

    /// @dev One shape: warm and all-cold, each for a funded and an empty lender, plus the cool-only rows between them.
    /// @dev `worst` is the largest need of the four real states, which is the all-cold zero-lender case by construction.
    function _shape(string memory name, address token, address impl, uint256 accounts) internal returns (Cost[4] memory cs, uint256 worst) {
        _premise(token);
        cs[0] = _cost(token, impl, LENDER_FUNDED, WARM, 0, HI);
        cs[1] = _cost(token, impl, lenderEmpty, WARM, 0, HI);
        Cost memory coolFunded = _cost(token, impl, LENDER_FUNDED, COOLED, 0, HI);
        Cost memory coolEmpty = _cost(token, impl, lenderEmpty, COOLED, 0, HI);
        cs[2] = _cost(token, impl, LENDER_FUNDED, FRESH, coolFunded.need - 1, coolFunded.need + COLD_SEARCH);
        cs[3] = _cost(token, impl, lenderEmpty, FRESH, coolEmpty.need - 1, coolEmpty.need + COLD_SEARCH);
        _row(name, "nonzero", "warm (closing repay)", cs[0]);
        _row(name, "ZERO   ", "warm (closing repay)", cs[1]);
        _row(name, "nonzero", "words cold, account warm (vm.cool only)", coolFunded);
        _row(name, "ZERO   ", "words cold, account warm (vm.cool only)", coolEmpty);
        _row(name, "nonzero", "ALL COLD (finalize, settleExpired)", cs[2]);
        _row(name, "ZERO   ", "ALL COLD (finalize, settleExpired)", cs[3]);
        emit log_named_uint(string.concat("PUSH-COST | ", name, " | all cold minus warm, used, nonzero lender"), cs[2].used - cs[0].used);
        assertEq(cs[1].used - cs[0].used, ZERO_TO_NONZERO_EXTRA, "RIG: warm, a zero lender costs exactly one SSTORE_SET over RESET");
        assertEq(cs[3].used - cs[2].used, ZERO_TO_NONZERO_EXTRA, "RIG: cold, a zero lender costs exactly one SSTORE_SET over RESET");
        assertEq(cs[2].used - coolFunded.used, accounts * COLD_ACCOUNT_EXTRA, "RIG: a fresh copy must pay each cold account vm.cool left warm");
        assertEq(cs[3].used - coolEmpty.used, accounts * COLD_ACCOUNT_EXTRA, "RIG: a fresh copy must pay each cold account vm.cool left warm");
        for (uint256 i; i < 4; i++) {
            if (cs[i].need > worst) worst = cs[i].need;
        }
    }
}
