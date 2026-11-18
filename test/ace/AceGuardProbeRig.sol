// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.36;

import {WarpClock} from "../utils/WarpClock.sol";
import {Ace} from "../../src/ace/hub/Ace.sol";
import {MarketParams, MigrateArgs, OpenBounds} from "../../src/ace/hub/Types.sol";
import {PositionManager} from "../../src/ace/positions/PositionManager.sol";
import {PositionTitleNFT} from "../../src/ace/positions/PositionTitleNFT.sol";
import {GUARD_TRIP} from "../utils/GuardTrip.sol";
import {MockERC20} from "../mocks/MockERC20.sol";
import {MockPersistenceRecord} from "../mocks/MockPersistenceRecord.sol";
import {MockStakeVault} from "../mocks/MockStakeVault.sol";
import {AceFixtures} from "../utils/AceFixtures.sol";
import {ProtocolPolicy} from "../../src/config/Defaults.sol";
import {AceReader} from "../utils/AceReader.sol";
import {DeleverageCrank} from "../utils/DeleverageCrank.sol";
import {FullMath} from "@uniswap/v4-core/src/libraries/FullMath.sol";

/// @title AceGuardProbeRig
/// @notice The shared rig of the guard probes: a hub with one banded market, a loan to crank, and probes run from inside its callback.
/// @dev The re-entrant context is the deleverage callback, which the hub invokes while holding its lock.
/// @dev `nonReentrant` is a MODIFIER, so it runs BEFORE the body: arguments need not be meaningful and preconditions need not be met.
abstract contract AceGuardProbeRig is WarpClock, DeleverageCrank {
    Ace internal ace;
    AceReader internal read;
    PositionManager internal positionManager;
    PositionTitleNFT internal title;
    MockERC20 internal usdc;
    MockStakeVault internal vault;
    MockPersistenceRecord internal record;
    bytes32 internal id;

    address internal alice = address(0xA11CE);
    address internal borrower = address(0xB0BA);

    /// @dev Ticks are RELATIVE to this pair's par, assigned in `setUp` because par is not a compile-time value.
    /// @dev The offsets are what this suite means; where par sits is the frame's business, not the suite's.
    uint256 internal T2;
    uint256 internal T3;
    uint256 internal T4;
    uint256 internal constant COLL = 10_000e18;
    uint256 internal constant DRAW = 6_000e6;
    uint256 internal constant BAND_BPS = 3000;

    uint256 internal constant GUARDED_ACE_VERBS = 28; // every nonReentrant Ace mutator; a new one must arrive here too
    uint256 internal constant UNGUARDED_ACE_VERBS = 4; // the whole Ace exception list; a shorter list lets an entry drift unseen
    uint256 internal constant GUARDED_ACE_VIEWS = 8; // every nonReentrantView Ace view; a new one must arrive here too
    uint256 internal constant GUARDED_CUSTODY_VERBS = 6; // every nonReentrant PositionManager verb, all onlyLoanManager
    bytes4 internal constant ERROR_STRING = 0x08c379a0; // Error(string): a require refusing by name, so the body ran

    /// @dev One probe: the label a failure prints, the address called, and the calldata to call it with.
    struct Probe {
        string label;
        address target;
        bytes data;
    }

    Probe[] internal probes;
    bytes4[] internal results; // the revert selector each probe produced, or 0x0 when it did not revert
    bool[] internal reverted; // whether each probe reverted at all, which selector 0x0 alone cannot say
    bytes4[] internal wants; // the selector each `_expect` probe must produce; parallel to `probes`
    bool internal armed; // only the crank whose test set this performs the re-entrant calls
    bool internal hubEnteredDuringCallback;

    function _deleverageQuote() internal view override returns (address) {
        return address(usdc);
    }

    /// @dev This suite's pair, so a tick reads as its distance from par rather than as a grid coordinate.
    /// @param offset Ticks above par.
    /// @return The absolute grid tick.
    function _price(int24 offset) internal view returns (uint256) {
        return AceFixtures.priceAt(address(usdc), address(vault), offset);
    }

    function setUp() public virtual {
        usdc = new MockERC20("USD Coin", "USDC", 6);
        vault = new MockStakeVault(42);
        (T2, T3, T4) = (_price(480), _price(720), _price(960));
        record = new MockPersistenceRecord(address(usdc), address(vault));
        record.setMinPrice(AceFixtures.px(2e18, address(usdc), address(vault)));

        MarketParams memory p = AceFixtures.marketParams(address(usdc), address(vault));
        p.record = address(record);
        p.deleverageFloorEpsBps = ProtocolPolicy.DELEVERAGE_FLOOR_EPS_BPS;
        p.deleverageBandBps = BAND_BPS;
        p.deleverageTargetBps = 4000;
        p.deleverageStopBps = 1;
        AceFixtures.Deployment memory d = AceFixtures.deploy(p);
        (ace, positionManager, read, id) = (d.ace, d.positionManager, d.read, d.id);
        title = PositionTitleNFT(ace.POSITION_TITLE());

        _deposit(10_000e6);
        _deposit(10_000e6);
        _deposit(10_000e6);
    }

    // ---- helpers ----

    function _deposit(uint256 amt) internal {
        usdc.mint(alice, amt);
        vm.startPrank(alice);
        usdc.approve(address(ace), amt);
        ace.deposit(id, amt);
        vm.stopPrank();
    }

    function _open() internal returns (uint256 loanId) {
        vault.mint(borrower, COLL);
        vm.startPrank(borrower);
        vault.approve(address(positionManager), COLL);
        loanId = ace.open(id, COLL, DRAW, 0, borrower, OpenBounds(0, 0, 0));
        vm.stopPrank();
    }

    /// @dev Drives the price under the band so one disposal is admissible, then cranks it.
    /// @dev The callback runs the armed probes; everything asserted here is read back after it returns.
    function _crankWithProbes(uint256 loanId) internal {
        uint256 trig = read.triggerPrice(loanId);
        uint256 ps = trig + trig / 20;
        record.setBelowBand(FullMath.mulDivRoundingUp(trig, 1e18, 1e18 - BAND_BPS * 1e14));
        record.setMinPrice(ps);
        armed = true;
        ace.deleverage(loanId, 0, "");
        armed = false;
    }

    /// @dev Runs every armed probe from INSIDE the hub's guarded body, recording what each one did.
    /// @dev A reverting call has no state effect, so probing the whole list in one callback is safe.
    function _deleverageCallback(uint256 unitsSold, uint256 quoteOwed, bytes calldata data) internal override {
        super._deleverageCallback(unitsSold, quoteOwed, data);
        if (!armed) return;
        hubEnteredDuringCallback = !ace.notEntered();
        for (uint256 i; i < probes.length; i++) {
            (bool ok, bytes memory ret) = probes[i].target.call(probes[i].data);
            results.push(ok ? bytes4(0) : bytes4(ret));
            reverted.push(!ok);
        }
    }

    function _probe(string memory label, address target, bytes memory data) internal {
        probes.push(Probe(label, target, data));
    }

    /// @dev A probe carrying the selector its own body must produce, for the surfaces that answer rather than lock.
    function _expect(string memory label, address target, bytes memory data, bytes4 want) internal {
        probes.push(Probe(label, target, data));
        wants.push(want);
    }

    /// @dev A zeroed migration: the guard runs before the body, so the arguments never have to resolve.
    function _emptyMigrateArgs() internal pure returns (MigrateArgs memory) {
        return MigrateArgs(0, bytes32(0), 0, 0, OpenBounds(0, 0, 0), 0, address(0));
    }

    /// @dev Every armed probe must have reverted with `ReentrancyGuardReentrantCall()`, and the label says which failed.
    function _assertAllReentrant() internal view {
        assertEq(results.length, probes.length, "a probe did not run");
        for (uint256 i; i < probes.length; i++) {
            assertEq(results[i], GUARD_TRIP, string.concat("re-entered without tripping the guard: ", probes[i].label));
        }
    }

    /// @dev Every armed probe must have answered with the selector its OWN body produces, never with the guard's.
    function _assertAllExpected() internal view {
        assertEq(results.length, probes.length, "a probe did not run");
        assertEq(wants.length, probes.length, "a probe carries no expectation");
        for (uint256 i; i < probes.length; i++) {
            assertTrue(results[i] != GUARD_TRIP, string.concat("guarded now, so its exception entry is stale: ", probes[i].label));
            assertEq(results[i], wants[i], string.concat("answered with an unexpected selector: ", probes[i].label));
        }
    }
}
