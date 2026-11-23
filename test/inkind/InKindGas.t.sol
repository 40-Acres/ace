// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.36;

import {MockERC20} from "../mocks/MockERC20.sol";
import {AceVault} from "../../src/vault/AceVault.sol";
import {Listing} from "./InKindSurface.sol";
import {InKindRig} from "./InKindRig.sol";

/// @title InKindGas
/// @notice THE SHARE-MOVE GATE: a share move reads no token, so these rows price the worst one with forty tokens paid out in the batch it closes.
/// @notice The worst cases are an exit and a fee-minting entry right after a forty-token batch was collected; a transfer is close behind.
/// @dev THE STATED BUDGET is a quarter of EIP-7825's 2^24 transaction gas cap, leaving three quarters to whatever composes the transfer.
/// @dev Cold by `vm.cool` on the vault, its terms and both holders, plus the 21,000 transaction base. Re-measure under `FOUNDRY_PROFILE=deploy`.
contract InKindGasTest is InKindRig {
    uint256 internal constant TX_BASE = 21_000;
    uint256 internal constant WORST_TRANSFER_BUDGET = (1 << 24) / 4; // the stated budget: a quarter of EIP-7825's per-transaction cap
    uint256 internal constant N = 40; // tokens paid out in the batch the measured move closes

    address[] internal _toks_;
    uint256 internal _n;

    /// @dev A vault listing `N` fresh tokens, alice and bob in, and one loan per token defaulted and collected in one batch.
    function _payEveryToken() internal returns (uint256[] memory ids) {
        _n = N;
        Listing[] memory l = new Listing[](_n);
        for (uint256 i; i < _n; i++) {
            _toks_.push(address(new MockERC20("T", "T", 18)));
            l[i] = _listing(_toks_[i], CAP);
        }
        vault = _deploy(_cfg(0), _ik(), l);
        _lp(alice, LP_CASH);
        _lp(bob, LP_CASH);
        _warpBy(MIN_TENOR);
        ids = new uint256[](_n);
        for (uint256 i; i < _n; i++) {
            ids[i] = _open(_toks_[i]);
        }
        _toExpiry(ids[0]);
        vm.prank(keeper);
        vault.collectForfeited(ids);
        _nextBlock();
    }

    /// @dev Cold-measure alice sending bob a tenth of her shares.
    function _measureTransfer() internal returns (uint256 used) {
        uint256 x = vault.balanceOf(alice) / 10;
        vm.cool(address(vault));
        vm.cool(address(terms));
        vm.cool(alice);
        vm.cool(bob);
        vm.prank(alice);
        uint256 g = gasleft();
        vault.transfer(bob, x);
        used = g - gasleft() + TX_BASE;
    }

    /// @notice The worst transfer: the first move after a forty-token batch was collected, closing it, cold.
    function test_gas_theWorstTransferFitsTheStatedBudget() public {
        _payEveryToken();
        uint256 used = _measureTransfer();
        emit log_named_uint(string.concat("INKIND-GATE N=", vm.toString(_n), " worst transfer gas"), used);
        assertLt(used, WORST_TRANSFER_BUDGET, "the worst transfer must fit the stated budget");
        assertGt(_claimable(bob, _toks_[_n - 1]), 0, "LIVENESS: the last token's payout reached bob");
    }

    // ---- the worst share move is an exit or an entry, not a transfer ----

    uint16 internal constant FEE_BPS = 1000; // a fee-charging vault, so the measured verb mints the curator's fee before it moves the holder's shares

    /// @dev Land `amt` of the asset on the vault, have a sync observe it, and let it vest whole, moving no share.
    function _gain(uint256 amt) internal {
        usdc.mint(address(vault), amt);
        vault.crank();
        _warpBy(VEST_W);
    }

    /// @dev The tracker's clock word at its root: batch count, and the open batch's block.
    function _clockWord() internal view returns (uint64 count, uint64 foldBlock) {
        uint256 w = uint256(vm.load(address(vault), bytes32(uint256(INKIND_ROOT) + 6)));
        (count, foldBlock) = (uint48(w), uint48(w >> 48));
    }

    /// @dev `_payEveryToken` on a fee vault, armed so the next fee-minting share move is the worst one.
    /// @dev The curator and alice each hold tracked shares, so the fee mint and the holder's own leg each write a standing checkpoint trace.
    /// @dev The defaults push NAV under the fee high-water, so a late gain past it makes the measured verb mint the fee and close the batch first.
    function _payEveryTokenFeeArmed() internal {
        _n = N;
        Listing[] memory l = new Listing[](_n);
        for (uint256 i; i < _n; i++) {
            _toks_.push(address(new MockERC20("T", "T", 18)));
            l[i] = _listing(_toks_[i], CAP);
        }
        vault = _deploy(_cfg(FEE_BPS), _ik(), l);
        _lp(alice, LP_CASH);
        _lp(bob, LP_CASH);
        _gain(10_000e6);
        vault.collectFee();
        _warpBy(MIN_TENOR);
        _gain(10_000e6);
        vault.collectFee();
        _lp(alice, PRINCIPAL);
        uint256[] memory ids = new uint256[](_n);
        for (uint256 i; i < _n; i++) {
            ids[i] = _open(_toks_[i]);
        }
        _toExpiry(ids[0]);
        vm.prank(keeper);
        vault.collectForfeited(ids);
        _nextBlock();
        _gain(100_000e6);
        _nextBlock();
        _premiseArmed();
    }

    /// @dev The state the worst case needs, read before the measured call, so a fixture drift fails here rather than measuring a cheaper path.
    function _premiseArmed() internal view {
        assertGt(AceVault(address(vault)).pendingFeeShares(), 0, "premise: the measured verb mints the curator's fee");
        assertGt(_tracked(curator), 0, "premise: the curator holds tracked shares, so the fee mint writes a standing trace");
        assertGt(_tracked(alice), 0, "premise: alice holds tracked shares");
        (, uint64 fb) = _clockWord();
        assertEq(lens.rewardTokens(address(vault)).length, _n, "premise: every token was paid out");
        assertGt(uint256(fb), 0, "premise: the collect's batch waits to close");
        assertLt(uint256(fb), block.number, "premise: from an earlier block, so the measured verb closes it");
    }

    /// @dev Cold the accounts a real exit or entry transaction first touches.
    function _coolAll() internal {
        vm.cool(address(vault));
        vm.cool(address(terms));
        vm.cool(alice);
        vm.cool(curator);
        vm.cool(address(ace));
        vm.cool(address(usdc));
    }

    /// @dev The measured call closed the batch and minted the fee, tracked to the curator; the closed batch credits both sides the last token.
    function _assertWorstPathRan(uint64 count0, uint256 curatorBal0) internal view {
        (uint64 count, uint64 fb) = _clockWord();
        assertEq(count, count0, "LIVENESS: the measured call opened no batch");
        assertEq(uint256(fb), 0, "LIVENESS: and closed the one that waited");
        assertGt(vault.balanceOf(curator), curatorBal0, "LIVENESS: the measured call minted the curator's fee");
        assertEq(_tracked(curator), vault.balanceOf(curator), "LIVENESS: the fee mint was tracked to the curator");
        assertGt(_claimable(curator, _toks_[_n - 1]), 0, "LIVENESS: the closed batch credits the curator the last token");
        assertGt(_claimable(alice, _toks_[_n - 1]), 0, "LIVENESS: and alice");
    }

    /// @dev Measure `cd` sent by alice to the vault, cold, plus the transaction base, and check the worst path ran inside it.
    function _measureWorst(bytes memory cd, string memory label) internal returns (uint256 used) {
        (uint64 count0,) = _clockWord();
        uint256 bal0 = vault.balanceOf(curator);
        _coolAll();
        vm.prank(alice);
        uint256 g = gasleft();
        (bool ok, bytes memory ret) = address(vault).call(cd);
        used = g - gasleft() + TX_BASE;
        if (!ok) {
            assembly ("memory-safe") {
                revert(add(ret, 32), mload(ret))
            }
        }
        emit log_named_uint(string.concat("INKIND-GATE N=", vm.toString(_n), " worst ", label, " gas"), used);
        _assertWorstPathRan(count0, bal0);
    }

    /// @notice An LP's redeem right after a forty-token batch: the fee mint closes it and checkpoints the curator, the burn the owner, cold.
    function test_gas_theWorstRedeemFitsTheStatedBudget() public {
        _payEveryTokenFeeArmed();
        uint256 x = vault.balanceOf(alice) / 10;
        uint256 used = _measureWorst(abi.encodeCall(vault.redeem, (x, alice, alice)), "redeem");
        assertLt(used, WORST_TRANSFER_BUDGET, "the worst redeem must fit the stated budget");
    }

    /// @notice A requester's claim right after a forty-token batch: the fee mint, then the escrow's burn charges the requester, all cold.
    function test_gas_theWorstClaimExitFitsTheStatedBudget() public {
        _payEveryTokenFeeArmed();
        uint256 x = vault.balanceOf(alice) / 10;
        vm.prank(alice);
        vault.requestExit(x);
        _premiseArmed();
        uint256 used = _measureWorst(abi.encodeCall(vault.claimExit, (x, alice, 0)), "claimExit");
        assertLt(used, WORST_TRANSFER_BUDGET, "the worst claimExit must fit the stated budget");
    }

    /// @notice A fee-minting deposit right after a forty-token batch: the fee mint, then the depositor's own checkpoint, all cold.
    function test_gas_theWorstFeeMintingDepositFitsTheStatedBudget() public {
        _payEveryTokenFeeArmed();
        usdc.mint(alice, PRINCIPAL);
        vm.prank(alice);
        usdc.approve(address(vault), PRINCIPAL);
        uint256 used = _measureWorst(abi.encodeCall(vault.deposit, (PRINCIPAL, alice)), "fee-minting deposit");
        assertLt(used, WORST_TRANSFER_BUDGET, "the worst deposit must fit the stated budget");
    }
}

/// @title InKindPayoutGas
/// @notice R7 and R12: a share move reads no token, so its worst case is flat in the tokens paid out; a claim costs about one payout's walk each.
/// @dev Cold by `vm.cool` on every account the measured call touches first, plus the 21,000 transaction base. Re-measure under `FOUNDRY_PROFILE=deploy`.
contract InKindPayoutGasTest is InKindRig {
    uint256 internal constant TX_BASE = 21_000;
    uint256 internal constant WORST_MOVE_BUDGET = (1 << 24) / 4; // a quarter of EIP-7825's per-transaction cap, as the share move's gate
    uint256 internal constant FLAT_SLACK = 2_000; // what forty tokens paid out may add to the worst exit over one
    uint256 internal constant CLAIM_BASE = 120_000; // a claim's cost before its first payout
    uint256 internal constant PER_PAYOUT = 8_000; // one payout's walk: its two reads, a checkpoint search and a mulDiv
    uint256 internal constant COLLECT_ONE_BUDGET = 650_000; // one id into a new batch, the hub's settle included
    uint16 internal constant FEE_BPS = 1000;

    address[] internal _toks_;

    function _gain(uint256 amt) internal {
        usdc.mint(address(vault), amt);
        vault.crank();
        _warpBy(VEST_W);
    }

    function _listN(uint256 n) internal returns (Listing[] memory l) {
        l = new Listing[](n);
        for (uint256 i; i < n; i++) {
            _toks_.push(address(new MockERC20("T", "T", 18)));
            l[i] = _listing(_toks_[i], CAP);
        }
    }

    function _coolAll() internal {
        vm.cool(address(vault));
        vm.cool(address(terms));
        vm.cool(alice);
        vm.cool(bob);
        vm.cool(carol);
        vm.cool(curator);
        vm.cool(address(ace));
        vm.cool(address(usdc));
    }

    function _measure(address who, bytes memory cd, string memory label) internal returns (uint256 used) {
        _coolAll();
        vm.prank(who);
        uint256 g = gasleft();
        (bool ok, bytes memory ret) = address(vault).call(cd);
        used = g - gasleft() + TX_BASE;
        if (!ok) {
            assembly ("memory-safe") {
                revert(add(ret, 32), mload(ret))
            }
        }
        emit log_named_uint(string.concat("INKIND-PAYOUT ", label), used);
    }

    /// @dev The tracker's open-batch block, from its clock word; zero is none.
    function _foldBlock() internal view returns (uint256) {
        return uint48(uint256(vm.load(address(vault), bytes32(uint256(INKIND_ROOT) + 6))) >> 48);
    }

    /// @dev `n` tokens each paid out once in one batch that waits to close; alice and the curator each hold tracked shares from two entries.
    /// @dev A late gain makes the measured exit mint the fee, close the batch and write both checkpoint traces, the worst share move there is.
    function _armWorstExit(uint256 n) internal {
        vault = _deploy(_cfg(FEE_BPS), _ik(), _listN(n));
        _lp(alice, LP_CASH);
        _lp(bob, LP_CASH);
        _gain(10_000e6);
        vault.collectFee();
        _warpBy(MIN_TENOR + 1 hours);
        uint256[] memory ids = new uint256[](n);
        for (uint256 i; i < n; i++) {
            ids[i] = _open(_toks_[i]);
        }
        _warpBy(1 hours);
        _nextBlock();
        _lp(alice, PRINCIPAL);
        _lp(curator, PRINCIPAL);
        _toExpiry(ids[0]);
        vm.prank(keeper);
        vault.collectForfeited(ids);
        _nextBlock();
        _gain(300_000e6);
        _nextBlock();
        assertGt(AceVault(address(vault)).pendingFeeShares(), 0, "premise: the measured exit mints the fee");
        assertGt(_foldBlock(), 0, "premise: the collect's batch waits to close");
        assertLt(_foldBlock(), block.number, "premise: from an earlier block, so the measured exit closes it");
    }

    function _worstClaimExit(uint256 n) internal returns (uint256 used) {
        _armWorstExit(n);
        uint256 x = vault.balanceOf(alice) / 10;
        vm.prank(alice);
        vault.requestExit(x);
        uint256 t0 = _tracked(alice);
        used = _measure(alice, abi.encodeCall(vault.claimExit, (x, alice, 0)), string.concat("worst claimExit, tokens paid out = ", vm.toString(n)));
        assertEq(_foldBlock(), 0, "LIVENESS: the measured call closed the waiting batch");
        assertEq(_tracked(alice), t0 - x, "LIVENESS: and charged the escrow's burn to alice");
        assertLt(used, WORST_MOVE_BUDGET, "the worst exit must fit the stated budget");
    }

    /// @notice R7: forty tokens listed and paid out deploy, collect, and the worst exit costs what it costs with one.
    function test_R7_theWorstExitIsFlatInTheTokensPaidOut() public {
        uint256 snap = vm.snapshotState();
        uint256 one = _worstClaimExit(1);
        vm.revertToState(snap);
        uint256 forty = _worstClaimExit(40);
        assertEq(lens.rewardTokens(address(vault)).length, 40, "premise: forty tokens were paid out");
        assertLe(forty, one + FLAT_SLACK, "the worst exit grew with the tokens paid out: a share move must read no token");
    }

    /// @dev `n` payouts of tokA, each its own batch a block apart, alice the only holder at every one.
    function _payouts(uint256 n) internal {
        _lp(alice, LP_CASH);
        _warpBy(MIN_TENOR + 1 hours);
        uint256[] memory ids = new uint256[](n);
        for (uint256 i; i < n; i++) {
            ids[i] = _openFor(address(tokA), MIN_PRINCIPAL, MIN_TENOR);
        }
        _toExpiry(ids[0]);
        for (uint256 i; i < n; i++) {
            _collect(ids[i]);
            _nextBlock();
        }
        _lp(dave, 1_000e6); // a later block's share move closes the last batch on alice alone
    }

    function _claimGas(uint256 n) internal {
        _payouts(n);
        uint256 want = _claimable(alice, address(tokA));
        uint256 used = _measure(alice, abi.encodeCall(vault.claim, (_toks(address(tokA)), alice)), string.concat("claim, payouts = ", vm.toString(n)));
        assertEq(tokA.balanceOf(alice), want, "R8: the claim paid the lens figure");
        assertLt(used, CLAIM_BASE + n * PER_PAYOUT, "a claim must cost about one payout's walk each");
    }

    /// @notice R12: a claim of one token over one payout.
    function test_R12_claimOnePayout() public {
        _claimGas(1);
    }

    /// @notice R12: a claim over sixteen payouts.
    function test_R12_claimSixteenPayouts() public {
        _claimGas(16);
    }

    /// @notice R12: a claim over 128 payouts.
    function test_R12_claimOneHundredTwentyEightPayouts() public {
        _claimGas(128);
    }

    /// @notice R12: a late joiner's first claim skips the payouts before its first checkpoint by a search, not a walk.
    function test_R12_aLateJoinersFirstClaimSearches() public {
        _payouts(128);
        _lp(carol, LP_CASH);
        _warpBy(MIN_TENOR + 1 hours);
        _defaultAndCollect(_open(address(tokA)));
        _nextBlock();
        _lp(dave, 1_000e6); // a later block's share move closes carol's batch
        uint256 want = _claimable(carol, address(tokA));
        assertGt(want, 0, "premise: carol is owed the last payout");
        uint256 used = _measure(carol, abi.encodeCall(vault.claim, (_toks(address(tokA)), carol)), "late joiner's first claim over 129 payouts");
        assertEq(tokA.balanceOf(carol), want, "R8: paid the lens figure");
        assertLt(used, CLAIM_BASE + 20 * PER_PAYOUT, "the late joiner walked the history instead of searching past it");
    }

    /// @notice R12: one id collected into a new batch.
    function test_R12_collectOneId() public {
        _lp(alice, LP_CASH);
        _warpBy(MIN_TENOR + 1 hours);
        uint256 id = _open(address(tokA));
        _toExpiry(id);
        uint256 used = _measure(keeper, abi.encodeCall(vault.collectForfeited, (_ids(id))), "collect, one id, a new batch");
        assertLt(used, COLLECT_ONE_BUDGET, "one collect must fit its budget");
    }

    // ---- the cursor's walk: per-payout slope, and M1's bounded checkpoint walk ----

    uint256 internal constant SLOPE_PER_PAYOUT = 7_000; // one payout's walk: via-IR, the shipped build, measures 6,690, legacy 6,325; one bound for both
    uint256 internal constant TX_CAP = 1 << 24; // EIP-7825's per-transaction cap
    uint256 internal constant CLAIM_CAP = (1 << 24) / 4; // a claim's stated budget, a quarter of the cap as for the worst share move
    uint256 internal constant WORST_PAYOUT = 9_730; // the dearest payout step measured on the plan's spike: a payout on its own checkpoint
    uint256 internal constant TOKEN_CHARGE = 16; // the library's per-token charge, in steps
    uint256 internal constant FINISHED_TOKEN = 6_000; // what naming a token with nothing left may cost a claim

    /// @notice The cursor reads each payout once: a claim's cost per payout, measured between 16 and 144 payouts, stays under the slope.
    function test_R12_aClaimsCostPerPayoutIsUnderTheSlope() public {
        uint256 snap = vm.snapshotState();
        _payouts(16);
        uint256 g16 = _measure(alice, abi.encodeCall(vault.claim, (_toks(address(tokA)), alice)), "claim, 16 payouts (slope)");
        vm.revertToState(snap);
        _payouts(144);
        uint256 g144 = _measure(alice, abi.encodeCall(vault.claim, (_toks(address(tokA)), alice)), "claim, 144 payouts (slope)");
        emit log_named_uint("INKIND-PAYOUT claim slope per payout", (g144 - g16) / 128);
        assertLt((g144 - g16) / 128, SLOPE_PER_PAYOUT, "a payout costs more than one read of it and its checkpoint");
    }

    /// @dev Alice and bob each LP; `n` floor loans on tokA open and run to expiry. Returns the ids and the two balances.
    function _pairWithLoans(uint256 n) internal returns (uint256[] memory ids, uint256 sa, uint256 sb) {
        sa = _lp(alice, LP_CASH);
        sb = _lp(bob, LP_CASH);
        _warpBy(MIN_TENOR + 1 hours);
        ids = new uint256[](n);
        for (uint256 i; i < n; i++) {
            ids[i] = _openFor(address(tokA), MIN_PRINCIPAL, MIN_TENOR);
        }
        _toExpiry(ids[0]);
    }

    /// @dev `k` blocks, each carrying one wei of bob's shares to alice: a new checkpoint of hers in every block.
    function _drip(uint256 k) internal {
        for (uint256 i; i < k; i++) {
            _nextBlock();
            vm.prank(bob);
            vault.transfer(alice, 1);
        }
    }

    /// @dev One cold claim of `tok` by `who`, its gas with the transaction base, and no log line.
    function _oneClaimGas(address who, address tok) internal returns (uint256 used) {
        _coolAll();
        vm.prank(who);
        uint256 g = gasleft();
        vault.claim(_toks(tok), who);
        used = g - gasleft() + TX_BASE;
    }

    /// @dev Claim `tok` as `who` until the lens shows nothing owed, every call under `cap`; at most `maxCalls`. Returns the dearest call.
    function _claimAllUnder(address who, address tok, uint256 cap, uint256 maxCalls) internal returns (uint256 worst, uint256 calls) {
        while (_claimable(who, tok) != 0) {
            assertLt(calls, maxCalls, "the claims did not finish within their bound: a call made no progress");
            uint256 used = _oneClaimGas(who, tok);
            assertLt(used, cap, "a claim passed the cap");
            if (used > worst) worst = used;
            ++calls;
        }
    }

    /// @notice M1: 8,000 one-block drips to a holder between two payouts; every claim lands under the claim budget, and they pay both exactly.
    /// @dev The first claim, before the gap, leaves alice's cursor on the first payout's checkpoint, so the next walk must cross the gap.
    function test_M1_aClaimCrossesAnEightThousandCheckpointGap() public {
        (uint256[] memory ids, uint256 sa, uint256 sb) = _pairWithLoans(2);
        uint256 want = _collect(ids[0]) * sa / (sa + sb);
        _nextBlock();
        assertLt(_oneClaimGas(alice, address(tokA)), CLAIM_CAP, "the claim before the gap");
        _drip(8_000);
        _nextBlock();
        want += _collect(ids[1]) * (sa + 8_000) / (sa + sb);
        _nextBlock();
        (uint256 worst, uint256 calls) = _claimAllUnder(alice, address(tokA), CLAIM_CAP, 50);
        emit log_named_uint("INKIND-PAYOUT M1 gap of 8,000 checkpoints: dearest claim", worst);
        emit log_named_uint("INKIND-PAYOUT M1 gap of 8,000 checkpoints: claims", calls);
        assertEq(tokA.balanceOf(alice), want, "M1: the claims paid both payouts exactly");
    }

    /// @notice M1: 1,030 pending payouts with five new checkpoints between each; every claim lands under the claim budget and they pay what is owed.
    function test_M1_aBacklogWithFiveCheckpointsAPayoutDrainsUnderTheCap() public {
        uint256 n = 1_030;
        (uint256[] memory ids, uint256 sa, uint256 sb) = _pairWithLoans(n);
        uint256 want;
        for (uint256 i; i < n; i++) {
            want += _collect(ids[i]) * (sa + 5 * i) / (sa + sb);
            _drip(5);
            _nextBlock();
        }
        (uint256 worst, uint256 calls) = _claimAllUnder(alice, address(tokA), CLAIM_CAP, 200);
        emit log_named_uint("INKIND-PAYOUT M1 backlog of 1,030 payouts, 5 checkpoints each: dearest claim", worst);
        emit log_named_uint("INKIND-PAYOUT M1 backlog of 1,030 payouts, 5 checkpoints each: claims", calls);
        assertEq(tokA.balanceOf(alice), want, "M1: the claims paid every payout exactly");
    }

    // ---- option D: one budget per claim across its named tokens, with L1's saturating per-token charge ----

    /// @dev A vault listing `n` fresh tokens, alice its only holder, and one loan per token collected in one batch: one payout each.
    function _paidOnceEach(uint256 n) internal returns (uint256[] memory units) {
        vault = _deploy(_cfg(0), _ik(), _listN(n));
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
    }

    /// @dev One cold claim of `toks` by `who`: what it paid each token, and its gas with the transaction base.
    function _claimList(address who, address[] memory toks) internal returns (uint256[] memory paid, uint256 used) {
        _coolAll();
        vm.prank(who);
        uint256 g = gasleft();
        paid = vault.claim(toks, who);
        used = g - gasleft() + TX_BASE;
    }

    function _count(uint256[] memory a) internal pure returns (uint256 k) {
        for (uint256 i; i < a.length; i++) {
            if (a[i] != 0) ++k;
        }
    }

    // ---- D5: the lens reads in batches ----

    uint256 internal constant LENS_THOUSAND_BUDGET = 9_000_000; // `claimable` over 1,000 payouts: 7.9M batched (legacy), 14.8M read one word a call

    /// @dev The lens's `claimable` for `who` of `tok`, its gas with the transaction base, cold.
    function _claimableGas(address who, address tok) internal returns (uint256 owed, uint256 used) {
        _coolAll();
        vm.cool(address(lens));
        uint256 g = gasleft();
        owed = lens.claimable(address(vault), who, tok);
        used = g - gasleft() + TX_BASE;
    }

    /// @notice D5: the lens's `claimable` over 1,000 payouts reads its words in batches, so an `eth_call` of it stays well under the common caps.
    function test_D5_theLensClaimableOverAThousandPayouts() public {
        _payouts(1_000);
        (uint256 owed, uint256 used) = _claimableGas(alice, address(tokA));
        emit log_named_uint("INKIND-PAYOUT D5 lens claimable over 1,000 payouts", used);
        assertGt(owed, 0, "premise: alice is owed the payouts");
        assertLt(used, LENS_THOUSAND_BUDGET, "D5: the lens read the walk one word a call");
    }

    /// @notice D: a fixed list of forty first-time tokens is bounded by the budget, finishes every token within two calls, then costs ~5k a token.
    function test_D_aFortyTokenListFinishesWithinTwoCalls() public {
        uint256[] memory units = _paidOnceEach(40);
        (uint256[] memory p1, uint256 g1) = _claimList(alice, _toks_);
        uint256 first = _count(p1);
        assertEq(first, 23, "D: the first claim paid other than the 23 whole tokens its 400 steps buy (23 * 17 + 9)");
        (uint256[] memory p2, uint256 g2) = _claimList(alice, _toks_);
        assertEq(first + _count(p2), 40, "D: the second call did not finish the list");
        for (uint256 i; i < 40; i++) {
            assertEq(MockERC20(_toks_[i]).balanceOf(alice), units[i], "D: a token paid other than its whole payout");
        }
        (, uint256 g3) = _claimList(alice, _toks_);
        emit log_named_uint("INKIND-PAYOUT D forty tokens: first call", g1);
        emit log_named_uint("INKIND-PAYOUT D forty tokens: second call", g2);
        emit log_named_uint("INKIND-PAYOUT D forty tokens: every token finished", g3);
        assertLt(g1, CLAIM_CAP, "D: the first call passed the claim budget");
        assertLt(g2, CLAIM_CAP, "D: the second call passed the claim budget");
        assertLt(g3, 100_000 + 40 * FINISHED_TOKEN, "L1: a finished token costs more than its reads");
    }

    /// @notice L1: a fixed list of 200 named tokens, all finished but the 150th, pays the 150th within one call, every call under the budget.
    function test_L1_twoHundredNamedTokensReachTheHundredFiftieth() public {
        _paidOnceEach(200);
        uint256 calls;
        for (uint256 left = 200; left != 0; ++calls) {
            assertLt(calls, 20, "L1: the list never finished");
            (uint256[] memory p, uint256 g) = _claimList(alice, _toks_);
            assertLt(g, CLAIM_CAP, "L1: a call over the list passed the claim budget");
            left -= _count(p);
        }
        _defaultAndCollect(_open(_toks_[149]));
        _nextBlock();
        (uint256[] memory paid, uint256 used) = _claimList(alice, _toks_);
        emit log_named_uint("INKIND-PAYOUT L1 200 named tokens, the 150th pending", used);
        assertGt(paid[149], 0, "L1: 149 finished tokens ahead starved the 150th");
        assertEq(_count(paid), 1, "L1: only the 150th had anything left");
        assertLt(used, CLAIM_CAP, "L1: the call passed the claim budget");
    }

    /// @dev Alice the only holder; `na` payouts of tokA and then `nb` of tokB, each its own batch a block apart.
    function _twoBacklogs(uint256 na, uint256 nb) internal returns (uint256[] memory ua, uint256[] memory ub) {
        _lp(alice, LP_CASH);
        _warpBy(MIN_TENOR + 1 hours);
        uint256[] memory ia = new uint256[](na);
        uint256[] memory ib = new uint256[](nb);
        for (uint256 i; i < na; i++) {
            ia[i] = _openFor(address(tokA), MIN_PRINCIPAL, MIN_TENOR);
        }
        for (uint256 i; i < nb; i++) {
            ib[i] = _openFor(address(tokB), MIN_PRINCIPAL, MIN_TENOR);
        }
        _toExpiry(ia[0]);
        (ua, ub) = (new uint256[](na), new uint256[](nb));
        for (uint256 i; i < na; i++) {
            ua[i] = _collect(ia[i]);
            _nextBlock();
        }
        for (uint256 i; i < nb; i++) {
            ub[i] = _collect(ib[i]);
            _nextBlock();
        }
    }

    function _total(uint256[] memory a) internal pure returns (uint256 s) {
        for (uint256 i; i < a.length; i++) {
            s += a[i];
        }
    }

    /// @notice D: a backlogged first token holds the second back for one call only: [A, B] pays B nothing, then B whole on the next.
    function test_D_aBackloggedFirstTokenHoldsTheSecondBackOneCall() public {
        (uint256[] memory ua, uint256[] memory ub) = _twoBacklogs(390, 5);
        address[] memory ab = _toks(address(tokA), address(tokB));
        (uint256[] memory p1, uint256 g1) = _claimList(alice, ab);
        emit log_named_uint("INKIND-PAYOUT D [A, B], A backlogged: first call", g1);
        assertGt(p1[0], 0, "premise: A took the budget");
        assertEq(p1[1], 0, "D: B was reached past a budget A spent");
        assertLt(g1, CLAIM_CAP, "D: the worst walk passed the claim budget");
        (uint256[] memory p2,) = _claimList(alice, ab);
        assertEq(p1[0] + p2[0], _total(ua), "D: A paid whole over the two calls");
        assertEq(p2[1], _total(ub), "D: B paid whole on the second call");
    }

    /// @notice D: naming a token first pays it now, whatever backlog the token after it holds.
    function test_D_namingATokenFirstPaysItNow() public {
        (, uint256[] memory ub) = _twoBacklogs(390, 5);
        (uint256[] memory p,) = _claimList(alice, _toks(address(tokB), address(tokA)));
        assertEq(p[0], _total(ub), "D: the token named first was not paid whole");
        assertGt(p[1], 0, "D: and the backlog after it took the rest of the budget");
    }

    /// @notice D: the dearest single token, a late joiner's first claim over 1,031 payouts with both searches, costs under its charge's worth.
    function test_D_theDearestTokenCostsUnderItsCharge() public {
        _payouts(1_030);
        _lp(carol, LP_CASH);
        _warpBy(MIN_TENOR + 1 hours);
        _defaultAndCollect(_open(address(tokA)));
        _nextBlock();
        _lp(dave, 1_000e6); // a later block's share move closes carol's batch
        uint256 want = _claimable(carol, address(tokA));
        assertGt(want, 0, "premise: carol is owed the last payout");
        uint256 used = _measure(carol, abi.encodeCall(vault.claim, (_toks(address(tokA)), carol)), "D dearest token: late joiner over 1,031 payouts");
        assertEq(tokA.balanceOf(carol), want, "R8: a single-token claim inside the budget pays claimable");
        assertLt(used, TOKEN_CHARGE * WORST_PAYOUT, "D: the dearest token costs more than its charge covers");
    }
}
