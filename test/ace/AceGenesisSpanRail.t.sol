// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.36;

import {WarpClock} from "../utils/WarpClock.sol";
import {Ace} from "../../src/ace/hub/Ace.sol";
import {MarketParams} from "../../src/ace/hub/Types.sol";
import {PersistenceRecord} from "../utils/PersistenceRecord.sol";
import {MockERC20} from "../mocks/MockERC20.sol";
import {MockPersistenceRecord} from "../mocks/MockPersistenceRecord.sol";
import {AceFixtures} from "../utils/AceFixtures.sol";
import {PocDeployConfig} from "../../src/config/Defaults.sol";

/// @title AceGenesisSpanRail
/// @notice A record may not answer over a window it can never span: `persistenceWindow + pendingWindow <= ring reach`.
/// @notice THE SUM is the settle window, which is what `finalize` reads over.
/// @notice Checking `persistenceWindow` alone admitted records whose `finalize` read could never answer.
/// @notice IT IS THE RECORD'S OWN CONSTRUCTOR RAIL NOW: both sides are its arguments, so nothing is interviewed.
/// @dev `_minPriceOverWindow` returns its running min only on reaching the boundary observation.
/// @dev Exhausting the ring first returns ZERO, and zero IS the draw cap, so no loan can ever open.
/// @dev A FLOOR, not a ceiling: `OBS_INTERVAL` is the tightest legal gap, so sparse writes reach further.
/// @dev Reach is `(OBS_CAP - 1) * OBS_INTERVAL` -- head to oldest crosses one fewer gap than buckets.
contract AceGenesisSpanRailTest is WarpClock {
    Ace internal ace;
    MockERC20 internal usdc;
    MockERC20 internal weth;

    /// @dev The shipped `PocDeployConfig.PERSISTENCE_WINDOW`.
    uint256 internal constant P = PocDeployConfig.PERSISTENCE_WINDOW;
    /// @dev DERIVED, never a literal: the rail's subject moves whenever either window does.
    uint256 internal constant W = P + PocDeployConfig.PENDING_WINDOW;

    uint64 internal constant IVL = 60;

    function setUp() public {
        usdc = new MockERC20("USD Coin", "USDC", 6);
        weth = new MockERC20("Wrapped Ether", "WETH", 18);
        ace = AceFixtures.newAce();
    }

    /// @dev A record whose ring holds `cap` buckets, carrying the two windows it will answer over.
    function _recordWith(uint256 cap, uint256 persistenceWindow, uint64 pendingWindow) internal returns (PersistenceRecord) {
        return new PersistenceRecord(
            PersistenceRecord.Config({
                writer: address(this),
                truncCapBps: 500,
                initialPrice: 1e18,
                obsInterval: IVL,
                volRefFloor: 1,
                obsCap: cap,
                unitScale: 1 << 96,
                volRefBps: 1000,
                depthWindow: 0,
                quote: address(usdc),
                collateral: address(weth),
                persistenceWindow: persistenceWindow,
                pendingWindow: pendingWindow
            })
        );
    }

    /// @dev A real record, so the span assertions bind to the shipped ring rather than a mock's answer.
    function _record() internal returns (PersistenceRecord) {
        return new PersistenceRecord(
            PersistenceRecord.Config({
                writer: address(this),
                truncCapBps: 500,
                initialPrice: 1e18,
                obsInterval: 60,
                volRefFloor: 1,
                obsCap: 30,
                unitScale: 1e18,
                volRefBps: 1000,
                depthWindow: 0,
                quote: address(usdc),
                collateral: address(weth),
                persistenceWindow: 1200,
                pendingWindow: 480
            })
        );
    }

    // ============ the failure ============

    /// @dev THE BUG: one second past the ring is a record that can never answer, so no loan could open.
    /// @dev Measured against the SETTLE window, so this is also one second short of settleability.
    function test_Record_RefusesAWindowPastTheRingReach() public {
        uint256 cap = W / IVL; // reach is exactly W - IVL here: one bucket short of the sum
        vm.expectRevert(PersistenceRecord.BadParams.selector);
        _recordWith(cap, P, uint64(PocDeployConfig.PENDING_WINDOW));
    }

    /// @dev The realistic misconfiguration: a shipped-length window against a small ring.
    /// @dev Nothing else in the envelope catches it -- the window floors admit the shipped P happily.
    function test_Record_RefusesAShippedWindowAgainstAnUndersizedRing() public {
        vm.expectRevert(PersistenceRecord.BadParams.selector);
        _recordWith(2, P, uint64(PocDeployConfig.PENDING_WINDOW));
    }

    /// @dev THE WEDGE the old per-window rail admitted: a ring spanning P exactly, but not P + pending.
    /// @dev Under that form this built a record whose `finalize` read reverted NotSettleable forever.
    function test_Record_RefusesARingThatSpansOnlyTheDistressWindow() public {
        vm.expectRevert(PersistenceRecord.BadParams.selector);
        _recordWith(P / IVL + 1, P, uint64(PocDeployConfig.PENDING_WINDOW));
    }

    // ============ what stays admissible ============

    /// @dev Exactly at the reach is fine: the ring spans the settle window, so the boundary is reachable.
    /// @dev THE PAIR with the refusal above pins the boundary itself, not merely the direction.
    function test_Record_AdmitsAWindowExactlyAtTheReach() public {
        PersistenceRecord rec = _recordWith(W / IVL + 1, P, uint64(PocDeployConfig.PENDING_WINDOW));
        assertEq(rec.SETTLE_WINDOW(), rec.minGuaranteedSpan(), "a settle window the ring exactly spans is fine");
    }

    /// @dev Room to spare is strictly safer, so the rail must not be an equality.
    function test_Record_AdmitsARingLongerThanTheWindow() public {
        PersistenceRecord rec = _recordWith(2 * W / IVL, P, uint64(PocDeployConfig.PENDING_WINDOW));
        assertGt(rec.minGuaranteedSpan(), rec.SETTLE_WINDOW(), "a longer ring is strictly safer");
    }

    // ============ genesis reads no window at all ============

    /// @dev THE OFFBOARDING, pinned from the hub's side: `createMarket` interviews the record but asks it no window.
    /// @dev An ORACLE-class record owns no ring and declares no span, and genesis neither knows nor cares.
    function test_Genesis_AsksTheRecordNoWindowAtAll() public {
        MarketParams memory p = AceFixtures.marketParams(address(usdc), address(weth));
        p.record = address(new MockPersistenceRecord(address(usdc), address(weth)));
        assertTrue(ace.createMarket(p) != bytes32(0), "a record that declares no window is creatable");
    }

    /// @dev Scoped to a market that NAMES a record: without one `persistedPrice` returns the max sentinel.
    function test_Genesis_AdmitsNoRecordAtAll() public {
        MarketParams memory p = AceFixtures.marketParams(address(usdc), address(weth));
        p.record = address(0);
        assertTrue(ace.createMarket(p) != bytes32(0), "no record, no rail");
    }

    // ============ the getter cannot drift from the ring it describes ============

    /// @dev The reach is `OBS_CAP - 1` GAPS, not `OBS_CAP`: head to oldest crosses one fewer boundary.
    /// @dev Off by one bucket the other way and the rail admits a ring that blinds at exactly W.
    function test_MinGuaranteedSpan_IsOneGapShortOfTheRing() public {
        PersistenceRecord rec = _record();
        assertEq(rec.minGuaranteedSpan(), 29 * uint256(60), "reach is (capacity - 1) x bucket width");
        assertEq(rec.minGuaranteedSpan(), (rec.OBS_CAP() - 1) * rec.OBS_INTERVAL(), "and it is derived, not restated");
    }

    /// @dev THE PROPERTY THE RAIL RESTS ON, under the density that makes it bite.
    /// @dev Fill the ring at the tightest legal spacing, which is the worst case for reach.
    /// @dev At the guaranteed span the record still answers; one second past it answers zero.
    /// @dev A fresh record answers zero trivially, so the fill is what makes this test load-bearing.
    function test_MinPriceOverWindow_AnswersZeroOneSecondPastTheGuarantee() public {
        PersistenceRecord rec = _record();
        uint256 span = rec.minGuaranteedSpan();
        for (uint256 i; i < 40; i++) {
            _warpBy(60);
            rec.observe(1e18, 1);
        }
        assertGt(rec.minPriceOverWindow(address(usdc), address(weth), span), 0, "at the guarantee it answers");
        assertEq(rec.minPriceOverWindow(address(usdc), address(weth), span + 1), 0, "one second past it proves nothing");
    }

    /// @dev THE SETTLE-SIDE TWIN, ported from the retired wedge suite the strong rail made unbuildable.
    /// @dev `finalize` reads `persistedBelow` over the SUM, so the rail rests on THIS read, not the min.
    /// @dev Same fail-safe, same boundary: a window the ring cannot span answers false, never "unproven".
    /// @dev Without it a rail sized off `minPriceOverWindow` alone could drift from what settlement asks.
    function test_PersistedBelow_AnswersFalseOneSecondPastTheGuarantee() public {
        PersistenceRecord rec = _record();
        uint256 span = rec.minGuaranteedSpan();
        for (uint256 i; i < 40; i++) {
            _warpBy(60);
            rec.observe(1e18, 1);
        }
        assertTrue(rec.persistedBelow(address(usdc), address(weth), 2e18, span), "at the guarantee it proves it");
        assertFalse(rec.persistedBelow(address(usdc), address(weth), 2e18, span + 1), "one second past it cannot");
    }
}
