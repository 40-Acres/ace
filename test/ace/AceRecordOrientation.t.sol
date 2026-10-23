// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.36;

import {Test} from "forge-std/Test.sol";
import {Ace} from "../../src/ace/hub/Ace.sol";
import {MarketParams} from "../../src/ace/hub/Types.sol";
import {PositionManager} from "../../src/ace/positions/PositionManager.sol";
import {MockERC20} from "../mocks/MockERC20.sol";
import {MockMultiPairRecord} from "../mocks/MockMultiPairRecord.sol";
import {MockPersistenceRecord} from "../mocks/MockPersistenceRecord.sol";
import {MockStakeVault} from "../mocks/MockStakeVault.sol";
import {AceFixtures} from "../utils/AceFixtures.sol";

/// @notice A record that also DECLARES its unit scale, the way the real `PersistenceRecord` does.
contract MockScaledRecord is MockPersistenceRecord {
    uint256 public UNIT_SCALE;

    constructor(address quote, address collateral, uint256 unitScale) MockPersistenceRecord(quote, collateral) {
        UNIT_SCALE = unitScale;
    }
}

/// @notice A record whose `UNIT_SCALE()` reverts: the probe must read it as ABSENT, never bubble it.
contract MockRevertingScaleRecord is MockPersistenceRecord {
    constructor(address quote, address collateral) MockPersistenceRecord(quote, collateral) {}

    function UNIT_SCALE() external pure returns (uint256) {
        revert("no scale");
    }
}

/// @notice A record whose `UNIT_SCALE()` answers 31 bytes: one short of the probe's decode floor.
/// @dev The probe must SKIP it rather than decode it, which is what keeps a malformed answer non-fatal.
/// @dev Drop the length guard and `abi.decode` reverts here, bubbling a record's garbage out of genesis.
contract MockShortScaleRecord is MockPersistenceRecord {
    constructor(address quote, address collateral) MockPersistenceRecord(quote, collateral) {}

    function UNIT_SCALE() external pure {
        assembly {
            mstore(0x00, 0)
            return(0x00, 31)
        }
    }
}

/// @notice A record whose `UNIT_SCALE()` answers 64 bytes with a settable FIRST word.
/// @dev Over the floor, so the probe decodes: the head is the declaration and the tail is ignored.
/// @dev A dynamic-type answer lands its offset (0x20) in the head, so garbage shapes fail closed.
contract MockWideScaleRecord is MockPersistenceRecord {
    uint256 internal head;

    constructor(address quote, address collateral, uint256 first) MockPersistenceRecord(quote, collateral) {
        head = first;
    }

    function UNIT_SCALE() external view {
        uint256 h = head;
        assembly {
            mstore(0x00, h)
            mstore(0x20, 0xdead)
            return(0x00, 64)
        }
    }
}

/// @notice A record with a catch-all fallback: it ANSWERS every unknown selector rather than reverting.
/// @dev The liar shape the probe must not be satisfied by -- an answer is not a declaration.
/// @dev Four lens-exposure mocks had to declare a REAL scale once this rail landed, which is the proof.
contract MockFallbackScaleRecord is MockPersistenceRecord {
    constructor(address quote, address collateral) MockPersistenceRecord(quote, collateral) {}

    fallback() external {
        assembly {
            mstore(0x00, 0xdeadbeefdeadbeefdeadbeefdeadbeefdeadbeefdeadbeefdeadbeefdeadbeef)
            return(0x00, 0x20)
        }
    }
}

/// @title AceRecordOrientation
/// @notice Genesis binds a market's `(quote, collateral)` to the ORDERED PAIR its price sources price.
/// @dev Market ids are `keccak256(abi.encode(params))`, so the two orderings are two distinct markets.
/// @dev Both could name the SAME record, and a record is DIRECTIONAL.
/// @dev A venue record's writer prices against one cached `quote`.
/// @dev The inverse market reads every price upside down: draw cap, distress, settlement, disposal.
/// @dev `cd >= qd` blocks that only for decimal-MISMATCHED pairs, and does so incidentally.
/// @dev That check is doing representability work, not orientation work.
/// @dev EQUAL-DECIMAL pairs are the exposed case, which is every LST against its own underlying.
/// @dev The rail here is the same shape as the positionManager's collateral handshake on a loan vault.
/// @dev The price sources simply never got one.
contract AceRecordOrientationTest is Test {
    Ace internal ace;
    MockERC20 internal usdc;
    MockStakeVault internal vault;
    /// @dev An 18/18 pair on purpose: equal decimals is the case `cd >= qd` cannot catch.
    MockERC20 internal weth;
    MockERC20 internal steth;

    function setUp() public {
        usdc = new MockERC20("USD Coin", "USDC", 6);
        vault = new MockStakeVault(42);
        weth = new MockERC20("Wrapped Ether", "WETH", 18);
        steth = new MockERC20("Staked Ether", "stETH", 18);
        ace = AceFixtures.newAce();
    }

    /// @dev A market wired to sources that price its own ordered pair. The baseline every case varies.
    function _params(address quote, address collateral, address recQuote, address recColl) internal returns (MarketParams memory p) {
        p = AceFixtures.marketParams(quote, collateral);
        /// @dev The frame check runs on ANY market that names a price source, so no sale channel need be live.
        p.record = address(new MockPersistenceRecord(recQuote, recColl));
    }

    // ============ the record leg ============

    function test_Genesis_AdmitsAMatchingFrame() public {
        MarketParams memory p = _params(address(usdc), address(vault), address(usdc), address(vault));
        assertTrue(ace.createMarket(p) != bytes32(0), "a correctly oriented record is admitted");
    }

    /// @dev THE BUG. An 18/18 pair, so `cd >= qd` passes in BOTH directions and cannot help.
    function test_Genesis_RefusesAnInvertedRecord_EqualDecimals() public {
        MarketParams memory p = _params(address(weth), address(steth), address(steth), address(weth));
        vm.expectRevert("record orientation");
        ace.createMarket(p);
    }

    /// @dev The same inversion on the motivating pair: refused for a REASON, not by a decimal side effect.
    function test_Genesis_RefusesAnInvertedRecord_MismatchedDecimals() public {
        MarketParams memory p = _params(address(usdc), address(vault), address(vault), address(usdc));
        vm.expectRevert("record orientation");
        ace.createMarket(p);
    }

    /// @dev A record for an entirely different pair is refused even though neither token is swapped.
    function test_Genesis_RefusesAForeignPair() public {
        MarketParams memory p = _params(address(usdc), address(vault), address(usdc), address(weth));
        vm.expectRevert("record orientation");
        ace.createMarket(p);
    }

    /// @dev An undeclared frame is refused, never treated as "unchecked".
    /// @dev A source declining to state its orientation is the silent-degradation case the rail exists for.
    function test_Genesis_RefusesAnUndeclaredFrame() public {
        MarketParams memory p = _params(address(usdc), address(vault), address(0), address(0));
        vm.expectRevert("record orientation");
        ace.createMarket(p);
    }

    // ============ the unit-scale probe ============

    /// @dev The inversion the frame check alone misses when one record affirms both orderings.
    /// @dev The scale is one constant now, so a decimal-derived number is simply a wrong one.
    function test_Genesis_RefusesARecordWhoseUnitScaleIsTheInverse() public {
        MarketParams memory p = _params(address(usdc), address(vault), address(usdc), address(vault));
        p.record = address(new MockScaledRecord(address(usdc), address(vault), 1e6));
        vm.expectRevert("record unit scale");
        ace.createMarket(p);
    }

    function test_Genesis_AdmitsTheMatchingUnitScale() public {
        MarketParams memory p = _params(address(usdc), address(vault), address(usdc), address(vault));
        p.record = address(new MockScaledRecord(address(usdc), address(vault), 1 << 96));
        assertTrue(ace.createMarket(p) != bytes32(0), "a record declaring THIS market's scale is admitted");
    }

    /// @dev The probe is OPTIONAL: the ORACLE classes carry no unit scale and never will.
    /// @dev Pinned so nobody "tightens" it into a hard require that bricks that whole class.
    function test_Genesis_RecordWithoutAUnitScaleGetterIsAdmitted() public {
        MarketParams memory p = _params(address(usdc), address(vault), address(usdc), address(vault));
        assertTrue(ace.createMarket(p) != bytes32(0), "a getter-less record is not thereby refused");
    }

    /// @dev The never-revert discipline: a reverting getter is ABSENT, not a failure.
    function test_Genesis_UnitScaleProbeDoesNotBubbleAReverter() public {
        MarketParams memory p = _params(address(usdc), address(vault), address(usdc), address(vault));
        p.record = address(new MockRevertingScaleRecord(address(usdc), address(vault)));
        assertTrue(ace.createMarket(p) != bytes32(0), "a reverting UNIT_SCALE() is treated as absent");
    }

    /// @notice ZERO is a REFUSAL, not an absence: no legal `unitScale` is 0, so 0 is a broken record.
    /// @dev The one case a record can DECLARE that the staticcall's ok/length guards cannot distinguish.
    /// @dev A `PersistenceRecord` built with `_unitScale = 0` prices every read at zero and reads live.
    function test_Genesis_RefusesARecordDeclaringAZeroUnitScale() public {
        MarketParams memory p = _params(address(usdc), address(vault), address(usdc), address(vault));
        p.record = address(new MockScaledRecord(address(usdc), address(vault), 0));
        vm.expectRevert("record unit scale");
        ace.createMarket(p);
    }

    /// @notice A SHORT answer is absent, not a failure: the probe never decodes under 32 bytes.
    /// @dev Pins the length guard itself -- without it `abi.decode` reverts and genesis bubbles it.
    function test_Genesis_UnitScaleProbeSkipsAShortAnswer() public {
        MarketParams memory p = _params(address(usdc), address(vault), address(usdc), address(vault));
        p.record = address(new MockShortScaleRecord(address(usdc), address(vault)));
        assertTrue(ace.createMarket(p) != bytes32(0), "31 bytes is under the decode floor, so it is absent");
    }

    /// @notice A WIDE answer is decoded from its FIRST word, and a matching head is admitted.
    function test_Genesis_UnitScaleProbeReadsTheHeadOfAWideAnswer() public {
        MarketParams memory p = _params(address(usdc), address(vault), address(usdc), address(vault));
        p.record = address(new MockWideScaleRecord(address(usdc), address(vault), 1 << 96));
        assertTrue(ace.createMarket(p) != bytes32(0), "the head declares this market's scale");
    }

    /// @notice The same wide shape with the WRONG head is refused: extra returndata buys no pass.
    function test_Genesis_RefusesAWideAnswerWhoseHeadIsWrong() public {
        MarketParams memory p = _params(address(usdc), address(vault), address(usdc), address(vault));
        p.record = address(new MockWideScaleRecord(address(usdc), address(vault), 1e6));
        vm.expectRevert("record unit scale");
        ace.createMarket(p);
    }

    /// @notice The probe compares against THIS market's derived scale, not a constant.
    /// @dev Every market wants the atom frame's scale, so a decimal-derived number like 1e30 is refused.
    function test_Genesis_UnitScaleIsCheckedAgainstThisMarketsOwnScale() public {
        MarketParams memory p = _params(address(weth), address(steth), address(weth), address(steth));
        p.record = address(new MockScaledRecord(address(weth), address(steth), 1e30));
        vm.expectRevert("record unit scale");
        ace.createMarket(p);

        MarketParams memory ok = _params(address(weth), address(steth), address(weth), address(steth));
        ok.record = address(new MockScaledRecord(address(weth), address(steth), 1 << 96));
        assertTrue(ace.createMarket(ok) != bytes32(0), "every market's scale is the atom frame's");
    }

    /// @notice A catch-all fallback cannot fake a declaration: its 32-byte garbage is refused.
    /// @dev Absence must come from a record that DECLINES the selector, never from one that improvises.
    function test_Genesis_RefusesAFallbackFabricatedUnitScale() public {
        MarketParams memory p = _params(address(usdc), address(vault), address(usdc), address(vault));
        p.record = address(new MockFallbackScaleRecord(address(usdc), address(vault)));
        vm.expectRevert("record unit scale");
        ace.createMarket(p);
    }

    /// @notice The FRAME rail outranks the scale probe: a record wrong on both keeps the frame's string.
    /// @dev Ordering pin. The probe sits after the decimals branch, so it must never mask the frame rail.
    function test_Genesis_FrameRailOutranksTheUnitScaleProbe() public {
        MarketParams memory p = _params(address(usdc), address(vault), address(usdc), address(vault));
        p.record = address(new MockScaledRecord(address(vault), address(usdc), 1e6));
        vm.expectRevert("record orientation");
        ace.createMarket(p);
    }

    // ============ the two markets that motivated this ============

    /// @dev Both directions stay CREATABLE as separate markets, each needing sources that AFFIRM its frame.
    /// @dev A single-pair source still cannot serve both directions.
    function test_Genesis_BothDirectionsCoexistWithTheirOwnSources() public {
        bytes32 a = ace.createMarket(_params(address(weth), address(steth), address(weth), address(steth)));
        bytes32 b = ace.createMarket(_params(address(steth), address(weth), address(steth), address(weth)));
        assertTrue(a != b, "two markets, two ids, two correctly oriented records");
    }

    /// @dev A pair-parameterized record AFFIRMING both orderings may serve both direction markets.
    /// @dev The rail requires affirmation PER PAIR rather than forbidding shared records.
    /// @dev Answering both directions correctly (the min/max inversion) is the implementer's obligation.
    function test_Genesis_BothDirectionsMayShareOneMultiPairRecord() public {
        MockMultiPairRecord shared = new MockMultiPairRecord();
        shared.registerPair(address(weth), address(steth));
        shared.registerPair(address(steth), address(weth));

        MarketParams memory a = _params(address(weth), address(steth), address(weth), address(steth));
        a.record = address(shared);
        MarketParams memory b = _params(address(steth), address(weth), address(steth), address(weth));
        b.record = address(shared);

        bytes32 idA = ace.createMarket(a);
        bytes32 idB = ace.createMarket(b);
        assertTrue(idA != idB, "two direction markets admitted against ONE record deployment");
    }
}
