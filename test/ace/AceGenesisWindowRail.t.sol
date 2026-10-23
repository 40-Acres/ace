// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.36;

import {Test} from "forge-std/Test.sol";
import {PersistenceRecord} from "../utils/PersistenceRecord.sol";
import {MockERC20} from "../mocks/MockERC20.sol";

/// @title AceGenesisWindowRail
/// @notice The borrow blackout must cover the depth feed's maturity: `persistenceWindow >= DEPTH_WINDOW`.
/// @notice IT IS THE RECORD'S OWN CONSTRUCTOR RAIL NOW, not a genesis interview: both sides are its arguments.
/// @dev THE VECTOR, the LIFT leg: an unanchored depth ring keeps `_denom()` on `VOL_REF_FLOOR` until real swaps span `DEPTH_WINDOW`.
/// @dev So a depth window past the blackout leaves borrowing LIVE with the cap liftable at floor cost, which pays the attacker at genesis.
/// @dev Option C (a separate shorter cap window) was refuted and never built: this makes CAP_WINDOW == DISTRESS_WINDOW structural.
/// @dev What the move changed is WHO is refused: a mis-set record cannot be built at all, rather than being built and then refused a market.
contract AceGenesisWindowRailTest is Test {
    MockERC20 internal usdc;
    MockERC20 internal weth;

    uint256 internal constant P = 30 minutes; // the shipped PERSISTENCE_WINDOW
    uint64 internal constant PENDING = 4 hours;
    uint64 internal constant INTERVAL = 60;
    uint256 internal constant CAP = 400; // 399 * 60 = 23940s, over the shipped settle window

    function setUp() public {
        usdc = new MockERC20("USD Coin", "USDC", 6);
        weth = new MockERC20("Wrapped Ether", "WETH", 18);
    }

    /// @dev A record carrying both windows; everything else shipped-shaped.
    function _record(uint256 persistenceWindow, uint256 depthWindow) internal returns (PersistenceRecord) {
        return new PersistenceRecord(
            PersistenceRecord.Config({
                writer: address(this),
                truncCapBps: 5000,
                initialPrice: 1e18,
                obsInterval: INTERVAL,
                volRefFloor: 1e18,
                obsCap: CAP,
                unitScale: 1 << 96,
                volRefBps: 5000,
                depthWindow: depthWindow,
                quote: address(usdc),
                collateral: address(weth),
                persistenceWindow: persistenceWindow,
                pendingWindow: PENDING
            })
        );
    }

    // ============ the vector ============

    /// @dev THE BUG: one second of depth window past the blackout is one second of live borrowing on a floor denominator.
    function test_Record_RefusesADepthWindowPastTheBlackout() public {
        vm.expectRevert(PersistenceRecord.BadParams.selector);
        _record(P, P + 1);
    }

    /// @dev The realistic misconfiguration: a short distress window against a shipped-length depth ring.
    /// @dev Nothing else in the envelope catches it: the window floors admit 120 happily.
    function test_Record_RefusesAShortBlackoutAgainstAShippedDepthWindow() public {
        vm.expectRevert(PersistenceRecord.BadParams.selector);
        _record(120, 1800);
    }

    // ============ what stays admissible ============

    /// @dev The SHIPPED shape: equal windows, carried by the rail rather than by coincidence.
    function test_Record_AdmitsTheShippedEqualWindows() public {
        assertEq(_record(P, P).DEPTH_WINDOW(), P, "equal windows are the shipped shape");
    }

    /// @dev A blackout LONGER than the depth window is strictly safer, so the rail must not be an equality.
    function test_Record_AdmitsABlackoutLongerThanTheDepthWindow() public {
        assertEq(_record(2 * P, P).PERSISTENCE_WINDOW(), 2 * P, "a longer blackout is strictly safer");
    }

    /// @dev `minDepthOverWindow(0)` returns the head entry, so a zero depth window matures the denominator instantly.
    /// @dev Zero is admitted by the same reasoning that refuses an over-long window, not by an exemption.
    function test_Record_AdmitsAZeroDepthWindow() public {
        assertEq(_record(P, 0).DEPTH_WINDOW(), 0, "no depth window, no maturity gap");
    }
}
