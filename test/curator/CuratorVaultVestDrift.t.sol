// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.36;

import {FullMath} from "@uniswap/v4-core/src/libraries/FullMath.sol";
import {CuratorVaultBase} from "./CuratorVaultBase.sol";
import {VaultConfig} from "../../src/curator/AceVault.sol";
import {CapListing, ProductConfig} from "../../src/curator/AceVaultCaps.sol";
import {CuratedVaults} from "../utils/CuratedVaults.sol";
import {AccumVault} from "./CuratorVaultVestAccumulator.t.sol";

/// @title CuratorVaultVestDrift
/// @notice Bunni-class confirmation for the vest accumulator: N alternating 1-wei gross rises and falls inside ONE window.
/// @notice A rise grosses the basis DOWN, so it reads back exactly, and a fall scales it DOWN; together they must not walk `unvested()` off the exact pile.
/// @notice The exact pile is the first gain decayed linearly to the one maturity, plus each rise and less each fall, tracked here at 1e18 precision.
/// @notice `unvested()` sits within one wei an op of the exact pile either way, reads back exactly at each rise, and reads zero at maturity.
/// @dev Drives `_stampVest(1)` and `_burnVest(1)` through the shipped `AccumVault` harness: exactly what `_sync` runs on a 1-wei move.
/// @dev The pile is kept over the window in seconds, so a 1-wei stamp's maturity shift floors to zero and the maturity never moves.
/// @dev MUTANTS: `_grossed` Floor -> Ceil, and `_scaled` Floor -> Ceil.
contract CuratorVaultVestDriftTest is CuratorVaultBase {
    uint256 internal constant Q = 1e18;

    AccumVault internal v;
    uint256 internal pQ; // the exact pile times Q, as of `tLast`, floored
    uint256 internal tLast;
    uint256 internal maturity;
    uint256 internal worstOverQ; // the furthest `unvested()` sat above the exact pile, times Q
    uint256 internal worstUnderQ; // the furthest it sat below, times Q

    function setUp() public override {
        super.setUp();
        record.setMinPrice(T2);
    }

    function _accum(uint64 window) internal returns (AccumVault a) {
        VaultConfig memory cfg = _cfg(0);
        cfg.vestWindow = window;
        (ProductConfig memory pc, CapListing[] memory c) =
            CuratedVaults.prepared(cfg, CuratedVaults.Terms(10e6, 1.4e18, 1 days, CuratedVaults.UNCAPPED), _listing());
        a = new AccumVault(cfg, pc, c);
    }

    /// @dev Decays the exact pile to now: linear toward the one maturity.
    function _decay() internal {
        uint256 t = _now();
        pQ = t >= maturity ? 0 : FullMath.mulDiv(pQ, maturity - t, maturity - tLast);
        tLast = t;
    }

    /// @dev `unvested()` and the basis's own unrounded pile against the exact pile, after `ops` alternating moves.
    function _check(uint256 ops) internal {
        assertEq(uint256(v.maturity()), maturity, "PREMISE: no 1-wei stamp moved the maturity");
        uint256 uQ = v.unvested() * Q;
        if (uQ > pQ && uQ - pQ > worstOverQ) worstOverQ = uQ - pQ;
        if (pQ > uQ && pQ - uQ > worstUnderQ) worstUnderQ = pQ - uQ;
        assertLe(uQ, pQ + ops * Q + Q, "unvested() sits at most one wei an op over the exact pile");
        assertGe(uQ + ops * Q + Q, pQ, "and at most one wei an op under it: the floored basis drifts down, never past that");
        uint256 realQ = maturity <= _now() ? 0 : FullMath.mulDiv(uint256(v.basis()) * Q, maturity - _now(), _window());
        assertGe(uQ, realQ, "the read is the basis's own pile, ceiled: never under it");
        assertLe(uQ, realQ + Q, "and never a wei over it");
    }

    function _window() internal view returns (uint256) {
        return uint256(v.VEST_WINDOW());
    }

    /// @dev One 1-wei rise, and its read-back law at the instant it lands.
    function _rise() internal {
        uint256 u = v.unvested();
        v.stamp(1);
        pQ += Q;
        assertEq(v.unvested(), u + 1, "a 1-wei rise defers exactly that wei: the floored basis reads back exactly");
    }

    /// @dev One 1-wei fall, and its read-back law at the instant it lands.
    function _fall() internal {
        uint256 u = v.unvested();
        v.burn(1);
        pQ -= Q;
        assertLe(v.unvested(), u - 1, "a 1-wei fall retires at least that wei");
        assertGe(v.unvested() + 2, u, "and at most one wei of floor beyond it");
    }

    /// @dev The first gain, then `n` alternating 1-wei rises and falls `dt` apart, then maturity.
    function _drift(uint64 window, uint256 gain, uint256 n, uint256 seed, uint256 maxDt) internal {
        v = _accum(window);
        v.stamp(gain);
        maturity = _now() + window;
        tLast = _now();
        pQ = gain * Q;
        _check(0);
        for (uint256 i; i < n; ++i) {
            _warpBy(1 + (uint256(keccak256(abi.encode(seed, i))) % maxDt));
            _decay();
            if (i % 2 == 0) _rise();
            else _fall();
            _check(i + 1);
        }
        emit log_named_uint("ops", n);
        emit log_named_uint("worst over the exact pile, 1e-18 wei", worstOverQ);
        emit log_named_uint("worst under the exact pile, 1e-18 wei", worstUnderQ);
        _warpTo(maturity);
        assertEq(v.unvested(), 0, "everything has vested at maturity: no dust is stranded in the pile");
        assertGt(v.basis(), 0, "PREMISE: the basis is still live, so the zero is the clock's and not a burnt-out pile");
    }

    /// @notice N alternating 1-wei moves at a fuzzed window, pile and spacing, all inside the first half of the window.
    function testFuzz_AlternatingWeiMoves_NoDrift(uint256 wSeed, uint256 gSeed, uint256 nSeed, uint256 seed) public {
        uint64 window = uint64(bound(wSeed, 1 hours, 7 days));
        uint256 n = bound(nSeed, 2, 50);
        uint256 gain = bound(gSeed, 4 * uint256(window), 1e24);
        _drift(window, gain, n, seed, uint256(window) / (2 * n));
    }

    /// @notice Fifty moves one second apart at the window's start, where `r / W` is near one and each rounding is worth most.
    function test_FiftyMovesAtTheWindowStart_NoDrift() public {
        _drift(1 days, 1_000_003, 50, 0, 1);
    }

    /// @notice Fifty moves spread across the first half of a one-hour window over a pile barely four windows deep.
    function test_FiftyMovesOnAThinPile_NoDrift() public {
        _drift(1 hours, 4 * 3600 + 7, 50, 0x7417, 36);
    }
}
