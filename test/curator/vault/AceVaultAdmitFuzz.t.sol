// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.36;

import {Test} from "forge-std/Test.sol";
import {MarketParams} from "../../../src/ace/hub/Types.sol";
import {AceVaultCaps} from "../../../src/curator/AceVaultCaps.sol";
import {BorrowRequest, Terms} from "../../../src/curator/AceVaultFlows.sol";

/// @title AceVaultAdmitFuzz
/// @notice `AceVaultCaps.admit`, the base's checks on every product answer, against the legs its NatSpec states: it admits exactly when all hold.
/// @notice Mode; the collateral asked; no more principal or units than asked; the term asked whenever one is; market tenors and the drawn term in the rail.
/// @dev Each leg is broken with probability one in eight, so the runs mix admissions with single and multiple refusals.
contract AceVaultAdmitFuzzTest is Test {
    struct Legs {
        bool mode;
        bool collateral;
        bool ask;
        bool tenorAsked;
        bool rail;
    }

    /// @dev The library call as an external one, so a refusal is caught with its data.
    function admitExt(BorrowRequest calldata r, MarketParams calldata mp, Terms calldata t, bool hubAsk, uint64 lo, uint64 hi)
        external
        pure
        returns (Terms memory)
    {
        return AceVaultCaps.admit(r, mp, t, hubAsk, lo, hi);
    }

    function _breaks(uint256 seed, uint256 leg) internal pure returns (bool) {
        return uint256(keccak256(abi.encode(seed, leg))) % 8 == 0;
    }

    function _pick(uint256 seed, uint256 leg, uint256 lo, uint256 hi) internal pure returns (uint256) {
        return lo + uint256(keccak256(abi.encode(seed, leg, "pick"))) % (hi - lo + 1);
    }

    /// @dev A request, a market and a draw that break each leg with probability one in eight, around a rail of `[lo, hi]`.
    function _case(uint256 seed, uint64 lo, uint64 hi, bool hubAsk) internal pure returns (BorrowRequest memory r, MarketParams memory mp, Terms memory t) {
        mp.inventoryAsk = _breaks(seed, 0) ? !hubAsk : hubAsk;
        r.collateral = address(0xC011);
        mp.collateral = _breaks(seed, 1) ? address(0xBAD) : r.collateral;
        r.principal = _pick(seed, 2, 1, 1e30);
        r.units = _pick(seed, 3, 1, 1e30);
        t.principal = _breaks(seed, 4) ? r.principal + _pick(seed, 5, 1, 1e6) : _pick(seed, 6, 0, r.principal);
        t.units = _breaks(seed, 7) ? r.units + 1 : _pick(seed, 8, 0, r.units);
        mp.minTenor = uint64(_breaks(seed, 9) ? _pick(seed, 10, 0, lo - 1) : _pick(seed, 11, lo, hi));
        mp.maxTenor = uint64(_breaks(seed, 12) ? _pick(seed, 13, uint256(hi) + 1, 2 * 365 days) : _pick(seed, 14, mp.minTenor, hi));
        if (mp.maxTenor < mp.minTenor) mp.maxTenor = mp.minTenor;
        uint256 kind = _pick(seed, 15, 0, 3);
        if (kind == 0) t.tenor = 0;
        else if (kind == 1) t.tenor = uint64(_pick(seed, 16, lo, hi));
        else if (kind == 2) t.tenor = uint64(_pick(seed, 17, 1, lo));
        else t.tenor = uint64(_pick(seed, 18, hi, 2 * 365 days));
        r.tenor = _breaks(seed, 19) ? uint64(_pick(seed, 20, 1, 2 * 365 days)) : (_breaks(seed, 21) ? 0 : t.tenor);
        r.minBufferWad = _pick(seed, 22, 0, 1e18);
        t.minBufferWad = _pick(seed, 23, 0, 1e18);
    }

    function _legs(BorrowRequest memory r, MarketParams memory mp, Terms memory t, bool hubAsk, uint64 lo, uint64 hi) internal pure returns (Legs memory g) {
        g.mode = mp.inventoryAsk == hubAsk;
        g.collateral = mp.collateral == r.collateral;
        g.ask = t.principal <= r.principal && t.units <= r.units;
        g.tenorAsked = r.tenor == 0 || t.tenor == r.tenor;
        uint256 drawn = t.tenor == 0 ? mp.minTenor : t.tenor;
        g.rail = mp.minTenor >= lo && mp.maxTenor <= hi && drawn >= lo && drawn <= hi;
    }

    /// @notice It admits exactly when every leg holds, answering the product's draw with the larger buffer; a refusal names a leg that failed.
    /// @notice The mode is judged first and the rail last: a refusal for a later leg means every earlier one held.
    function testFuzz_AdmitRefusesExactlyWhenALegFails(uint256 seed, uint64 lo, uint64 hi, bool hubAsk) public view {
        lo = uint64(bound(lo, 1 days, 365 days));
        hi = uint64(bound(hi, lo, 365 days));
        (BorrowRequest memory r, MarketParams memory mp, Terms memory t) = _case(seed, lo, hi, hubAsk);
        Legs memory g = _legs(r, mp, t, hubAsk, lo, hi);
        bool all = g.mode && g.collateral && g.ask && g.tenorAsked && g.rail;
        try this.admitExt(r, mp, t, hubAsk, lo, hi) returns (Terms memory out) {
            assertTrue(all, "admitted though a leg failed");
            assertEq(out.units, t.units, "the product's units");
            assertEq(out.principal, t.principal, "the product's principal");
            assertEq(out.tenor, t.tenor, "the product's term, zero left zero for the hub to read as the shortest");
            assertEq(out.minBufferWad, r.minBufferWad > t.minBufferWad ? r.minBufferWad : t.minBufferWad, "the larger buffer");
        } catch (bytes memory err) {
            assertFalse(all, "refused though every leg held");
            assertEq(err.length, 4, "a bare named refusal");
            bytes4 s = bytes4(err);
            if (s == AceVaultCaps.WrongInventoryMode.selector) {
                assertFalse(g.mode, "WrongInventoryMode with the mode matching");
            } else if (s == AceVaultCaps.CollateralNotAsked.selector) {
                assertTrue(g.mode && !g.collateral, "CollateralNotAsked out of order or untrue");
            } else if (s == AceVaultCaps.OverAsk.selector) {
                assertTrue(g.mode && !g.ask, "OverAsk out of order or untrue");
            } else if (s == AceVaultCaps.TenorNotAsked.selector) {
                assertTrue(g.mode && !g.tenorAsked, "TenorNotAsked out of order or untrue");
            } else if (s == AceVaultCaps.TenorOutOfRail.selector) {
                assertTrue(g.mode && g.collateral && g.ask && g.tenorAsked && !g.rail, "TenorOutOfRail ahead of a binding leg, or untrue");
            } else {
                assertTrue(false, "a refusal admit does not name");
            }
        }
    }

    /// @notice The rail's edges: a market and a drawn term exactly on `[lo, hi]` land, and one second past either end refuses.
    function testFuzz_TheRailIsInclusiveAtBothEnds(uint64 lo, uint64 hi, bool atLo) public view {
        lo = uint64(bound(lo, 1 days, 365 days - 1));
        hi = uint64(bound(hi, lo + 1, 365 days));
        BorrowRequest memory r;
        MarketParams memory mp;
        Terms memory t;
        (r.collateral, mp.collateral, r.principal, r.units) = (address(1), address(1), 1, 1);
        (mp.minTenor, mp.maxTenor, t.tenor) = (lo, hi, atLo ? lo : hi);
        this.admitExt(r, mp, t, false, lo, hi);
        t.tenor = atLo ? lo - 1 : hi + 1;
        if (atLo) mp.minTenor = lo - 1;
        else mp.maxTenor = hi + 1;
        try this.admitExt(r, mp, t, false, lo, hi) {
            assertTrue(false, "a second past the rail was admitted");
        } catch (bytes memory err) {
            assertEq(bytes4(err), AceVaultCaps.TenorOutOfRail.selector, "TenorOutOfRail");
        }
    }
}
