// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.36;

import {Test} from "forge-std/Test.sol";
import {Ace} from "../../src/ace/hub/Ace.sol";
import {AceLens} from "../../src/ace/lens/AceLens.sol";
import {MarketParams, OpenBounds} from "../../src/ace/hub/Types.sol";
import {DeleverageStopped, NotInBand} from "../../src/ace/hub/Deleverage.sol";
import {PositionManager} from "../../src/ace/positions/PositionManager.sol";
import {MockERC20} from "../mocks/MockERC20.sol";
import {MockPersistenceRecord} from "../mocks/MockPersistenceRecord.sol";
import {MockDeleverageKeeper} from "../mocks/MockDeleverageKeeper.sol";
import {MockStakeVault} from "../mocks/MockStakeVault.sol";
import {AceFixtures} from "../utils/AceFixtures.sol";
import {AceReader} from "../utils/AceReader.sol";

/// @title AceLensGateMirrorTest
/// @notice Pins `AceLens.deleverageBandLevel`/`deleverageStopLevel` to `Deleverage.deleverage`'s own gate, to the wei.
/// @dev The derivation is spelled three times: the crank, the lens, and each test file's own helper -- keep them in sync.
/// @dev This test drives the real crank and asserts on its revert; it does not add a fourth spelling of the formula.
contract AceLensGateMirrorTest is Test {
    Ace internal ace;
    PositionManager internal positionManager;
    AceReader internal read;
    AceLens internal lens;
    MockERC20 internal usdc;
    MockStakeVault internal vault;
    MockPersistenceRecord internal record;
    MockDeleverageKeeper internal keeper;
    bytes32 internal id;

    address internal alice = address(0xA11CE);
    address internal borrower = address(0xB0B);

    uint256 internal constant COLL = 10_000e18;
    uint256 internal constant PRINCIPAL = 4_500e6;
    uint256 internal P; // $2.00 per collateral token, framed in setUp once the pair's decimals are known
    uint256 internal constant UNIT_SCALE = 1 << 96; // every market's scale under the atom frame
    uint256 internal constant BAND_BPS = 3333; // not round: a round pair divides exactly and hides a ceil-vs-floor drift
    uint256 internal constant TARGET_BPS = 5000;
    uint256 internal constant STOP_BPS = 1111; // paired with BAND_BPS to keep the drift observable; see the control test

    function setUp() public {
        usdc = new MockERC20("USD Coin", "USDC", 6);
        vault = new MockStakeVault(42);
        record = new MockPersistenceRecord(address(usdc), address(vault));
        P = AceFixtures.px(2e18, address(usdc), address(vault));
        record.setMinPrice(P);

        MarketParams memory p = AceFixtures.marketParams(address(usdc), address(vault));
        p.record = address(record);
        p.deleverageFloorEpsBps = 100;
        p.deleverageBandBps = BAND_BPS;
        p.deleverageTargetBps = TARGET_BPS;
        p.deleverageStopBps = STOP_BPS;
        p.deleverageProtocolBps = 500;

        AceFixtures.Deployment memory d = AceFixtures.deploy(p);
        (ace, positionManager, read, id) = (d.ace, d.positionManager, d.read, d.id);
        lens = new AceLens(address(ace));
        keeper = new MockDeleverageKeeper(ace, address(usdc), address(vault), UNIT_SCALE);

        usdc.mint(alice, 15_000e6);
        vm.startPrank(alice);
        usdc.approve(address(ace), 15_000e6);
        ace.deposit(id, 15_000e6);
        vm.stopPrank();
    }

    function _open() internal returns (uint256 loanId) {
        vault.mint(borrower, COLL);
        vm.startPrank(borrower);
        vault.approve(address(positionManager), COLL);
        loanId = ace.open(id, COLL, PRINCIPAL, 0, borrower, OpenBounds(0, 0, 0));
        vm.stopPrank();
    }

    /// @dev The crank's error, or `bytes4(0)` when it did not revert. Never re-derives a level.
    /// @dev A SHORT revert fails loudly rather than returning zero: zero already means "did not revert",
    /// @dev and collapsing the two would let a bare `revert()` read as success in every `!=` assertion here.
    function _crankError(uint256 loanId) internal returns (bytes4) {
        try keeper.crankDeleverage(loanId) returns (uint256, uint256) {
            return bytes4(0);
        } catch (bytes memory err) {
            require(err.length >= 4, "crank reverted with no selector: indistinguishable from success");
            return bytes4(err);
        }
    }

    /* ===================== control: the two levels are different numbers ===================== */

    /// @notice Fixture control: band and stop are distinct, so neither pin below can pass on the other's value.
    /// @dev Also pins the ORDER the channel needs -- the band opens strictly above where the stop closes it.
    function test_control_TheBandAndStopLevelsAreDistinctAndOrdered() public {
        uint256 loanId = _open();
        uint256 band = lens.deleverageBandLevel(loanId);
        uint256 stop = lens.deleverageStopLevel(loanId);
        assertGt(band, stop, "the band must open strictly above the stop, or the channel has no operating range");
        assertGt(read.triggerPrice(loanId), 0, "and a live trigger, or both levels are trivially zero");
    }

    /// @notice Fixture control: BOTH levels genuinely round, so a ceil-vs-floor drift is observable at all.
    /// @dev Without this the pins pass under EITHER rounding rule and the mutation that breaks the
    /// @dev mirror survives them -- which is what happened at the round 3000/1000 pair this fixture left.
    function test_control_BothLevelsLeaveARemainder() public {
        uint256 loanId = _open();
        uint256 trig = read.triggerPrice(loanId);
        assertTrue((trig * 1e18) % (1e18 - BAND_BPS * 1e14) != 0, "the band level divides exactly: the ceil is unobservable");
        assertTrue((trig * 1e18) % (1e18 - STOP_BPS * 1e14) != 0, "the stop level divides exactly: the ceil is unobservable");
    }

    /* ===================== T1: the lens's STOP level IS the crank's ===================== */

    /// @notice At the lens's stop level the crank refuses; one wei above it does not. The gate is STRICT.
    /// @dev `minPriceOverWindow` is settable to an exact wei, so this brackets the crank's own level
    /// @dev from both sides: the pair of assertions admits exactly one value, and it is the lens's.
    function test_LensStopLevel_IsTheCranksStopGate_ToTheWei() public {
        uint256 loanId = _open();
        uint256 stop = lens.deleverageStopLevel(loanId);
        record.setBandPrice(lens.deleverageBandLevel(loanId) - 1); // in the band, and not distressed

        record.setMinPrice(stop);
        assertEq(_crankError(loanId), DeleverageStopped.selector, "at the lens's stop level the crank must refuse");

        record.setMinPrice(stop + 1);
        assertTrue(_crankError(loanId) != DeleverageStopped.selector, "one wei above it the stop must no longer bind");
    }

    /* ===================== T2: the lens's BAND level IS the crank's ===================== */

    /// @notice The band gate opens exactly where the lens says: at the level it is shut, a wei under it is open.
    /// @dev The mock answers `persistedBelow(x)` as `x > bandPrice`, so parking the band ON the lens's
    /// @dev level makes the crank's own `persistedBelow(bandLevel)` false IFF the two levels agree.
    function test_LensBandLevel_IsTheCranksBandGate_ToTheWei() public {
        uint256 loanId = _open();
        uint256 band = lens.deleverageBandLevel(loanId);
        record.setMinPrice(band); // above the stop, so a passing band gate cannot be masked by the stop

        record.setBandPrice(band);
        assertEq(_crankError(loanId), NotInBand.selector, "at the lens's band level the channel must still be shut");

        record.setBandPrice(band - 1);
        assertTrue(_crankError(loanId) != NotInBand.selector, "a wei under it the band must open");
    }

    /* ===================== T3: the mirror tracks, it does not just match once ===================== */

    /// @notice The mirror holds as the trigger moves: a repay lowers both levels together, still to the wei.
    /// @dev A constant-offset drift passes T1 and T2 at one trigger and fails here, which is the point.
    function test_LensLevels_TrackTheCrankAfterTheTriggerMoves() public {
        uint256 loanId = _open();
        uint256 stopBefore = lens.deleverageStopLevel(loanId);

        usdc.mint(borrower, 1_000e6);
        vm.startPrank(borrower);
        usdc.approve(address(ace), 1_000e6);
        ace.repay(loanId, 1_000e6);
        vm.stopPrank();

        uint256 stop = lens.deleverageStopLevel(loanId);
        assertLt(stop, stopBefore, "control: the repay actually moved the trigger, so this is a fresh level");

        record.setBandPrice(lens.deleverageBandLevel(loanId) - 1);
        record.setMinPrice(stop);
        assertEq(_crankError(loanId), DeleverageStopped.selector, "the mirror must still be exact at the new trigger");

        record.setMinPrice(stop + 1);
        assertTrue(_crankError(loanId) != DeleverageStopped.selector, "and still bracket it from above");
    }
}
