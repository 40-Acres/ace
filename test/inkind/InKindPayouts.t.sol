// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.36;

import {ERC4626} from "@openzeppelin/contracts/token/ERC20/extensions/ERC4626.sol";
import {Checkpoints} from "@openzeppelin/contracts/utils/structs/Checkpoints.sol";
import {AceVault} from "../../src/vault/AceVault.sol";
import {AceVaultFactory} from "../../src/vault/AceVaultFactory.sol";
import {AceVaultBaseRig} from "../curator/vault/AceVaultBaseRig.sol";
import {InKindVaults} from "../utils/InKindVaults.sol";
import {VaultSeed} from "../utils/VaultSeed.sol";
import {IInKindVault} from "./InKindSurface.sol";
import {InKindRig} from "./InKindRig.sol";

/// @title InKindPayouts
/// @notice Per-payout claims over block-keyed tracked checkpoints: a holder earns from the block its shares arrive, untouched.
/// @notice A claim pays each payout pro rata to the holder's checkpoint at its batch block, within one budget of steps a call; there is no cap on tokens.
/// @dev Every claim here also asserts it paid exactly what the lens showed just before it (R8).
contract InKindPayoutsTest is InKindRig {
    uint256 internal constant HOUR = 1 hours;
    uint256 internal constant WINDOW = 384; // payouts one claim of one token walks when each is one step: the budget, 400, less the token's charge, 16
    bytes32 internal constant HOLDERS_OFFSET = bytes32(uint256(8)); // the tracker's holder mapping, from its root

    /// @dev Claim `tok` as `who` in one call, asserting it paid exactly the lens figure read just before it (R8).
    /// @dev R8 holds per call only while a token's walk fits one claim's budget, which every row using this keeps.
    function _claimOne(address who, address tok) internal returns (uint256 got) {
        uint256 want = _claimable(who, tok);
        vm.prank(who);
        got = vault.claim(_toks(tok), who)[0];
        assertEq(got, want, "R8: the claim paid exactly what claimable showed");
    }

    /// @dev Advance `secs` and a block, never backwards.
    function _step(uint256 secs) internal {
        _warpBy(secs);
        _nextBlock();
    }

    // ---- R1-R6: who earns a payout ----

    /// @notice R1: a holder nobody ever touched earns its pro-rata share from the block its shares were minted.
    function test_R1_aNeverTouchedHolderEarnsFromItsMint() public {
        uint256 sa = _lp(alice, LP_CASH);
        uint256 sc = _lp(carol, LP_CASH);
        _warpBy(MIN_TENOR);
        uint256 pot = _defaultAndCollect(_open(address(tokA)));
        _nextBlock();
        assertApproxEqAbs(_claimable(carol, address(tokA)), pot * sc / (sa + sc), 2, "carol earns her share untouched");
        uint256 pc = _claimOne(carol, address(tokA));
        uint256 pa = _claimOne(alice, address(tokA));
        assertLe(pa + pc, pot, "never past the pot");
    }

    /// @notice R2: a holder entering between two batches, after the first collect's block, earns only the later one.
    function test_R2_aHolderEnteringBetweenBatchesEarnsOnlyTheLater() public {
        uint256 sa = _lp(alice, LP_CASH);
        _warpBy(MIN_TENOR);
        uint256 id1 = _open(address(tokA));
        uint256 pot1 = _defaultAndCollect(id1);
        _nextBlock();
        uint256 sc = _lp(carol, LP_CASH);
        uint256 id2 = _open(address(tokA));
        uint256 pot2 = _defaultAndCollect(id2);
        _nextBlock();
        assertApproxEqAbs(_claimable(carol, address(tokA)), pot2 * sc / (sa + sc), 2, "carol earns only the batch after her entry");
        uint256 pc = _claimOne(carol, address(tokA));
        uint256 pa = _claimOne(alice, address(tokA));
        assertApproxEqAbs(pa, pot1 + pot2 * sa / (sa + sc), 3, "alice the first whole and her slice of the second");
        assertLe(pa + pc, pot1 + pot2, "never past what came home");
    }

    /// @notice R3: a raw gift of shares to the vault leaves the donor's tracker, so the donor earns only on what it still holds.
    function test_R3_aRawGiftToTheVaultLeavesTheDonorsTracker() public {
        uint256 sa = _lp(alice, LP_CASH);
        uint256 sb = _lp(bob, LP_CASH);
        _warpBy(MIN_TENOR);
        vm.prank(alice);
        vault.transfer(address(vault), sa / 4);
        assertEq(_tracked(alice), sa - sa / 4, "the donor's tracker fell with its balance");
        uint256 pot = _defaultAndCollect(_open(address(tokA)));
        _nextBlock();
        uint256 held = sa - sa / 4;
        assertApproxEqAbs(_claimable(alice, address(tokA)), pot * held / (held + sb), 2, "the donor earns on what it holds");
        _claimOne(alice, address(tokA));
    }

    /// @notice R4: shares in an exit request keep earning for their requester, with no touch.
    function test_R4_anEscrowEarnsForItsRequesterUntouched() public {
        uint256 sa = _lp(alice, LP_CASH);
        uint256 sb = _lp(bob, LP_CASH);
        _warpBy(MIN_TENOR);
        vm.prank(alice);
        vault.requestExit(sa / 2);
        uint256 pot = _defaultAndCollect(_open(address(tokA)));
        _nextBlock();
        assertApproxEqAbs(_claimable(alice, address(tokA)), pot * sa / (sa + sb), 2, "the escrow earns for its requester");
        _claimOne(alice, address(tokA));
    }

    /// @notice R5: an exit after a payout neither pays nor forfeits it; the exited holder still claims it.
    function test_R5_anExitedHolderStillClaimsWhatItWasOwed() public {
        _lp(alice, LP_CASH);
        _lp(bob, LP_CASH);
        _warpBy(MIN_TENOR);
        uint256 pot = _defaultAndCollect(_open(address(tokA)));
        _nextBlock();
        uint256 c = _claimable(alice, address(tokA));
        assertGt(c, 0, "premise: alice is owed a share");
        assertLt(c, pot, "premise: bob shares the pot");
        uint256 sh = vault.maxRedeem(alice);
        vm.prank(alice);
        vault.redeem(sh, alice, alice);
        assertEq(_claimable(alice, address(tokA)), c, "the exit forfeited nothing");
        assertEq(_claimOne(alice, address(tokA)), c, "and it stays claimable");
    }

    // ---- V2 and I4: the claim's window ----

    /// @dev `n` payouts of tokA, each its own batch a block apart, alice the only holder; returns each payout's units.
    function _payoutsOfOneToken(uint256 n) internal returns (uint256[] memory units) {
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
        for (uint256 i = from; i < to && i < a.length; i++) {
            s += a[i];
        }
    }

    /// @notice V2, I4 and D: one claim spends one budget across all it names, so naming a token again in the same call adds nothing past it.
    /// @notice The lens shows everything owed; successive calls each settle one budget's walk, and together they pay exactly that.
    /// @dev Alice is the only holder at every batch, with one checkpoint, so each payout is one step, credits her its whole units, and a window is a sum.
    function test_V2_I4_aClaimSpendsOneBudgetAcrossItsTokensAndClaimableIsAllOwed() public {
        uint256[] memory units = _payoutsOfOneToken(800);
        assertEq(_claimable(alice, address(tokA)), _sum(units, 0, 800), "claimable is every payout owed, not one claim's window");
        address[] memory t = new address[](3);
        (t[0], t[1], t[2]) = (address(tokA), address(tokA), address(tokA));
        vm.prank(alice);
        uint256[] memory paid = vault.claim(t, alice);
        assertEq(paid[0], _sum(units, 0, WINDOW), "the first naming walks the whole budget less its charge");
        assertEq(paid[1] + paid[2], 0, "and a token named again in the same call finds the budget spent");
        assertEq(_claimable(alice, address(tokA)), _sum(units, WINDOW, 800), "claimable is then the rest");
        vm.prank(alice);
        assertEq(vault.claim(_toks(address(tokA)), alice)[0], _sum(units, WINDOW, 2 * WINDOW), "a second call walks the next budget");
        _claimOne(alice, address(tokA));
        assertEq(_claimable(alice, address(tokA)), 0, "and the third the last of it, then nothing");
        assertEq(tokA.balanceOf(alice), _sum(units, 0, 800), "every payout paid exactly once");
    }

    // ---- R11: each holder equals a block model ----

    mapping(address => uint256) internal m; // the model's tracked balance
    mapping(address => uint256) internal credit;
    address[4] internal mh;

    /// @dev Collect `id` now, check the batch's supply against the model, and credit each holder its floored model share.
    function _mBatch(uint256 id) internal returns (uint256 u) {
        u = _collect(id);
        uint256 supply;
        for (uint256 i; i < 4; i++) {
            supply += m[mh[i]];
        }
        assertEq(_trackedSupply(), supply, "R11: the batch's supply is the model's tracked shares");
        for (uint256 i; i < 4; i++) {
            credit[mh[i]] += u * m[mh[i]] / supply;
        }
        _nextBlock();
    }

    function _mDepositNow(address h, uint256 amt) internal {
        m[h] += _lp(h, amt);
    }

    /// @notice R11: from unaligned clocks, with top-ups, a transfer, a gift and three batches, each holder's claim equals a block model.
    /// @dev The model credits each batch over the balances standing at its block's end, as the tracker does; nothing else is shared.
    function testFuzz_R11_eachHolderEqualsTheBlockModel(uint256 off, uint256[7] memory gaps) public {
        mh = [dave, alice, bob, carol];
        _warpBy(bound(off, 0, HOUR - 1));
        _nextBlock();
        for (uint256 i; i < 7; i++) {
            gaps[i] = bound(gaps[i], 1, 4 days);
        }
        _mDepositNow(dave, LP_CASH);
        uint256[3] memory ids = [_open(address(tokA)), _open(address(tokA)), _open(address(tokA))];
        _step(gaps[0]);
        _mDepositNow(alice, 50_000e6);
        _step(gaps[1]);
        _mDepositNow(bob, 30_000e6);
        _step(gaps[2]);
        _mDepositNow(carol, 20_000e6);
        _step(gaps[3]);
        _mDepositNow(alice, 10_000e6);
        _warpAtLeastTo(_expiry(ids[0]));
        _step(gaps[4] > HOUR ? gaps[4] : HOUR);
        uint256 u = _mBatch(ids[0]);
        _step(gaps[5]);
        u += _mBatch(ids[1]);
        uint256 x = m[bob] / 2;
        vm.prank(bob);
        vault.transfer(carol, x);
        (m[bob], m[carol]) = (m[bob] - x, m[carol] + x);
        uint256 g = m[alice] / 4;
        vm.prank(alice);
        vault.transfer(address(vault), g);
        m[alice] -= g;
        _step(gaps[6]);
        u += _mBatch(ids[2]);
        uint256 paid;
        for (uint256 i; i < 4; i++) {
            uint256 got = _claimOne(mh[i], address(tokA));
            assertEq(got, credit[mh[i]], "R11: the holder's claim equals the block model");
            paid += got;
        }
        assertLe(paid, u, "R11: never past what came home");
    }

    // ---- R13: the checkpoint push order ----

    /// @dev The holder's checkpoint keys, read raw from the tracker: they must strictly ascend.
    function _assertKeysAscend(address h) internal view {
        bytes32 base = keccak256(abi.encode(h, bytes32(uint256(INKIND_ROOT) + uint256(HOLDERS_OFFSET))));
        uint256 n = uint256(vm.load(address(vault), base));
        bytes32 first = keccak256(abi.encode(base));
        uint256 last;
        for (uint256 i; i < n; i++) {
            uint256 key = uint48(uint256(vm.load(address(vault), bytes32(uint256(first) + i))));
            if (i != 0) assertGt(key, last, "R13: a holder's checkpoint keys stopped ascending");
            last = key;
        }
    }

    /// @dev Whether `err` is a refusal one of R13's moves is ruled to make: an entry gate, or an exit priced to nothing, last-out or over its max.
    function _ruledRefusal(bytes memory err) internal pure returns (bool) {
        if (err.length < 4) return false;
        bytes4 s = bytes4(err);
        return s == AceVault.GainVesting.selector || s == AceVault.EndOfLife.selector || s == AceVault.OverSupply.selector || s == AceVault.ZeroAssets.selector
            || s == AceVault.LastOutVesting.selector || s == AceVault.OverRequest.selector || s == ERC4626.ERC4626ExceededMaxDeposit.selector
            || s == ERC4626.ERC4626ExceededMaxRedeem.selector || s == ERC4626.ERC4626ExceededMaxWithdraw.selector;
    }

    /// @dev Run `cd` as `who` on the vault; a ruled refusal is a skipped step, and any other revert fails the row (D1).
    /// @dev The unordered checkpoint insertion R13 was written for is one such revert, named on its own.
    function _try(address who, bytes memory cd) internal {
        vm.prank(who);
        (bool ok, bytes memory err) = address(vault).call(cd);
        if (ok) return;
        assertTrue(err.length < 4 || bytes4(err) != Checkpoints.CheckpointUnorderedInsertion.selector, "R13: a share move reverted on checkpoint order");
        assertTrue(_ruledRefusal(err), string.concat("D1: a move reverted outside the ruled refusals: ", vm.toString(err)));
    }

    function _actor(uint256 r) internal view returns (address) {
        address[3] memory a = [alice, bob, carol];
        return a[r % 3];
    }

    /// @notice R13: fuzzed moves at random forward times, same-block steps and hour boundaries never revert `CheckpointUnorderedInsertion`.
    function testFuzz_R13_noMoveRevertsOnCheckpointOrder(uint256 seed) public {
        for (uint256 i; i < 24; i++) {
            uint256 r = uint256(keccak256(abi.encode(seed, i)));
            uint256 kind = r % 4;
            if (kind == 1) _nextBlock();
            else if (kind == 2) _step(HOUR - (_now() % HOUR));
            else if (kind == 3) _step(1 + (r >> 200) % 2 days);
            (address a, address b) = (_actor(r >> 8), _actor(r >> 16));
            uint256 amt = 1e6 + (r >> 32) % 50_000e6;
            uint256 act = (r >> 24) % 8;
            if (act < 2) {
                usdc.mint(a, amt);
                vm.prank(a);
                usdc.approve(address(vault), amt);
                _try(a, abi.encodeCall(vault.deposit, (amt, act == 0 ? a : b)));
            } else if (act == 2) {
                _try(a, abi.encodeCall(vault.transfer, (b, vault.balanceOf(a) / 3)));
            } else if (act == 3) {
                _try(a, abi.encodeCall(vault.redeem, (vault.maxRedeem(a) / 2, a, a)));
            } else if (act == 4) {
                _try(a, abi.encodeCall(vault.requestExit, (vault.balanceOf(a) / 4)));
            } else if (act == 5) {
                _try(a, abi.encodeCall(vault.claimExit, (vault.maxClaim(a), a, 0)));
            } else if (act == 6) {
                (uint256 asked,) = lens.requestOf(address(vault), a);
                _try(a, abi.encodeCall(vault.cancelExit, (asked / 2)));
            } else {
                _try(a, abi.encodeCall(vault.transfer, (address(vault), vault.balanceOf(a) / 5)));
            }
        }
        _assertKeysAscend(alice);
        _assertKeysAscend(bob);
        _assertKeysAscend(carol);
    }

    // ---- R17: no tracker figure is written at deploy ----

    /// @dev The tracker's fixed words at its root, the token list's length, the tracked supply and the clock word, all zero, read raw.
    function _assertNoClockWord(address v) internal view {
        for (uint256 k = 4; k <= 6; k++) {
            assertEq(uint256(vm.load(v, bytes32(uint256(INKIND_ROOT) + k))), 0, "R17: a deploy wrote a tracker word");
        }
    }

    /// @notice R17: a directly deployed in-kind vault writes no clock word: the tracker stores no vesting age and no decimals.
    function test_R17_aDeployWritesNoClockWord() public view {
        _assertNoClockWord(address(vault));
    }

    /// @notice R17 on the factory path, the only production deploy: the factory's vault writes none either.
    function test_R17_aFactoryDeployWritesNoClockWord() public {
        bytes memory code = type(AceVault).creationCode;
        AceVaultFactory f = new AceVaultFactory(keccak256(code), address(ace));
        bytes32 salt = keccak256("R17");
        address predicted = f.predict(address(this), salt);
        bytes memory termsArgs = abi.encode(InKindVaults.termsConfig(predicted, address(usdc), _ik()), InKindVaults.termsListings(_listings()), NAME);
        address t = InKindVaults.create(InKindVaults.TERMS_ARTIFACT, termsArgs);
        VaultSeed.approve(_cfg(0), address(f));
        address v = f.deploy(code, _cfg(0), InKindVaults.product(t, _ik()), InKindVaults.caps(predicted, _listings(), total), NAME, SYMBOL, salt);
        assertEq(v, predicted, "premise: the vault landed on the factory's prediction");
        assertTrue(IInKindVault(v).IN_KIND(), "premise: an in-kind vault");
        _assertNoClockWord(v);
    }
}

/// @title InKindPayoutsHubAsk
/// @notice R14 (C6): outside in-kind mode the tracker's `claim` refuses `ModeUnbuilt`, since its fold would write storage.
contract InKindPayoutsHubAskTest is AceVaultBaseRig {
    function test_R14_aHubAskVaultRefusesClaim() public {
        address[] memory t = new address[](1);
        t[0] = address(coll);
        vm.prank(alice);
        vm.expectRevert(IInKindVault.ModeUnbuilt.selector);
        IInKindVault(address(vault)).claim(t, alice);
    }
}
