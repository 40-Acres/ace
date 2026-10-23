// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.36;

import {Test} from "forge-std/Test.sol";
import {WarpClock} from "./utils/WarpClock.sol";
import {PersistenceRecord} from "./utils/PersistenceRecord.sol";

/// @notice The capacity amplifier's depth source: minimum venue depth over a window, writer-only.
/// @dev JIT add-observe-remove depth never raises the read; only capital parked for the whole window counts.
/// @dev Own bids are excluded by construction: the writer measures its pool and the market ladder never writes here.
contract PersistenceDepthTest is WarpClock {
    PersistenceRecord internal record;
    uint256 constant WINDOW = 30 minutes;
    uint256 constant T0 = 10 days; // warp base: absolute off this, NEVER off _now() (via-IR hoists the read)

    function setUp() public {
        _warpTo(T0); // clear of timestamp-zero boundary math
        // record-only suite: two placeholder frame legs, and a depth window of 30 inside the 63s ring
        record = new PersistenceRecord(
            PersistenceRecord.Config({
                writer: address(this),
                truncCapBps: 500,
                initialPrice: 1e18,
                obsInterval: 1,
                volRefFloor: 1e18,
                obsCap: 64,
                unitScale: 1e30,
                volRefBps: 5000,
                depthWindow: 30,
                quote: address(0x9001),
                collateral: address(0xC011),
                persistenceWindow: 30,
                pendingWindow: 30
            })
        );
    }

    function test_Depth_WriterOnly() public {
        vm.prank(address(0xBAD));
        vm.expectRevert(PersistenceRecord.NotWriter.selector);
        record.observeDepth(1_000e6);
    }

    function test_Depth_MinOverWindow() public {
        record.observeDepth(1_000e6);
        _warpTo(T0 + 10 minutes);
        record.observeDepth(400e6);
        _warpTo(T0 + 20 minutes);
        record.observeDepth(800e6);
        _warpTo(T0 + 35 minutes); // first obs now sits at-or-before window start: spanned
        assertEq(record.minDepthOverWindow(WINDOW), 400e6, "the low watermark is the read");
    }

    function test_Depth_JITSpikeNeverCounts() public {
        record.observeDepth(100e6);
        _warpTo(T0 + 40 minutes); // baseline spans the whole window
        record.observeDepth(10_000e6); // JIT add...
        _warpTo(T0 + 41 minutes);
        record.observeDepth(100e6); // ...observe...remove
        _warpTo(T0 + 42 minutes);
        assertEq(record.minDepthOverWindow(WINDOW), 100e6, "spike inside the window never raises the min");
    }

    function test_Depth_SilencePersists() public {
        record.observeDepth(700e6);
        _warpTo(T0 + 2 * WINDOW); // no further observations
        assertEq(record.minDepthOverWindow(WINDOW), 700e6, "standing depth persists through silence");
    }

    function test_Depth_NoSpanReadsZero() public view {
        // no depth observation at or before window start: nothing proven, read 0
        assertEq(record.minDepthOverWindow(WINDOW), 0, "unproven window reads zero");
    }

    function test_Depth_RemovalLowersImmediately() public {
        record.observeDepth(1_000e6);
        _warpTo(T0 + 40 minutes);
        record.observeDepth(50e6); // depth pulled
        assertEq(record.minDepthOverWindow(WINDOW), 50e6, "a pull marks the min instantly");
    }

    // --- hardening additions ---

    /// @notice The DEPTH read is its own buffer: interleaved price writes never move its low watermark.
    /// @dev ONE DIRECTION ONLY, and the asymmetry is deliberate rather than an omission.
    /// @dev The reverse does NOT hold: `_truncate` pro-rates the step by `_denom()`, which reads depth.
    /// @dev So a depth write CAN move a later price, and this asserts nothing about `lastObserved`.
    function test_Depth_IndependentOfPriceStream() public {
        record.observeDepth(1_000e6);
        record.observe(1.05e18, 1e18); // interleaved price write (full weight: volume at volRef)
        _warpTo(T0 + 10 minutes);
        record.observeDepth(400e6);
        record.observe(0.98e18, 1e18); // another price write (full weight)
        _warpTo(T0 + 20 minutes);
        record.observeDepth(800e6);
        _warpTo(T0 + WINDOW + 5 minutes); // the first depth obs now spans the window

        // the depth read reflects only the depth stream's low watermark, price writes notwithstanding
        assertEq(record.minDepthOverWindow(WINDOW), 400e6, "depth read ignores the price stream");
        // the price stream still MOVED, which is the whole reason the reverse independence is not asserted
        assertTrue(record.lastObserved() != 1e18, "the price writes landed; their exact value is depth-dependent"); // setUp's initialPrice
    }

    /// @notice Boundary-exact: an observation timestamped at the window start counts as spanning, since `o.time <= boundary`.
    /// @dev One second short of a full window nothing spans and the read is zero.
    function test_Depth_BoundaryExactTimestampSpans() public {
        record.observeDepth(500e6);

        _warpTo(T0 + WINDOW - 1); // obs sits one second after window start: nothing spans
        assertEq(record.minDepthOverWindow(WINDOW), 0, "one second short of a full window proves nothing");

        _warpTo(T0 + WINDOW); // boundary now lands exactly on the obs timestamp
        assertEq(record.minDepthOverWindow(WINDOW), 500e6, "obs exactly at window start counts as spanning");
    }
}
