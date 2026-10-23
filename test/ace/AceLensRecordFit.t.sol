// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.36;

import {Test} from "forge-std/Test.sol";
import {Ace} from "../../src/ace/hub/Ace.sol";
import {MarketParams} from "../../src/ace/hub/Types.sol";
import {AceLens} from "../../src/ace/lens/AceLens.sol";
import {IPersistenceRecord} from "../../src/interfaces/IPersistenceRecord.sol";
import {MockERC20} from "../mocks/MockERC20.sol";
import {MockPersistenceRecord} from "../mocks/MockPersistenceRecord.sol";
import {MockStakeVault} from "../mocks/MockStakeVault.sol";
import {AceFixtures} from "../utils/AceFixtures.sol";
import {ShapedRecord} from "./AceP11GenesisInterview.t.sol";

/// @title AceLensRecordFit
/// @notice `AceLens.recordFitFor`'s `supported` against the real genesis, one record question and one answer shape at a time.
/// @dev Differential, never lens-vs-lens: each case asks the lens, then `createMarket`, and the two must agree.
contract AceLensRecordFitTest is Test {
    Ace internal ace;
    AceLens internal lens;
    MockERC20 internal usdc;
    MockStakeVault internal coll;
    MockPersistenceRecord internal inner;

    function setUp() public {
        usdc = new MockERC20("USD Coin", "USDC", 6);
        coll = new MockStakeVault(42);
        inner = new MockPersistenceRecord(address(usdc), address(coll));
        AceFixtures.Deployment memory d = AceFixtures.deploy(AceFixtures.marketParams(address(usdc), address(coll)));
        ace = d.ace;
        lens = new AceLens(address(ace));
    }

    /// @dev Every question genesis puts to a record: the orientation, the four interview reads and the optional unit scale.
    function _questions() internal pure returns (bytes4[6] memory) {
        return [
            IPersistenceRecord.supportsPair.selector,
            IPersistenceRecord.minPrice.selector,
            IPersistenceRecord.persistedBelowDistress.selector,
            IPersistenceRecord.persistedBelowSettle.selector,
            IPersistenceRecord.lastObserved.selector,
            bytes4(keccak256("UNIT_SCALE()"))
        ];
    }

    /// @dev One shaped record: the lens's verdict, then genesis's by raw call, so a refusal is an answer rather than a revert.
    function _verdicts(bytes4 question, ShapedRecord.Shape s) internal returns (bool supported, bool created) {
        ShapedRecord r = new ShapedRecord(inner);
        r.setShape(question, s);
        (supported,) = lens.recordFitFor(address(r), address(usdc), address(coll));
        MarketParams memory p = AceFixtures.marketParams(address(usdc), address(coll));
        p.record = address(r);
        (created,) = address(ace).call(abi.encodeCall(Ace.createMarket, (p)));
    }

    /// @dev `supported` is true exactly where genesis admits the source, over every question and every answer shape.
    /// @dev Both verdicts must occur, so agreement is not two constant answers matching by accident.
    function test_Supported_IsWhatGenesisAdmits_EveryQuestionEveryShape() public {
        _assertMatrix("twins answer 0");
    }

    /// @dev The same matrix with both below twins answering 1 at level 0, which genesis's bool decode admits.
    function test_Supported_IsWhatGenesisAdmits_WhenTheTwinsAnswerOne() public {
        inner.setBelow(true);
        assertTrue(inner.persistedBelowDistress(address(usdc), address(coll), 0), "PREMISE: the distress twin answers 1 at level 0");
        assertTrue(inner.persistedBelowSettle(address(usdc), address(coll), 0), "PREMISE: and so does the settle twin");
        _assertMatrix("twins answer 1");
    }

    /// @dev Every question against every shape, the lens's verdict against genesis's, and both verdicts seen.
    function _assertMatrix(string memory pass) internal {
        bytes4[6] memory qs = _questions();
        uint256 admitted;
        uint256 refused;
        for (uint256 i; i < qs.length; ++i) {
            for (uint8 s; s <= uint8(ShapedRecord.Shape.Wide); ++s) {
                (bool supported, bool created) = _verdicts(qs[i], ShapedRecord.Shape(s));
                assertEq(supported, created, string.concat("lens and genesis disagree (", pass, "): question ", vm.toString(i), ", shape ", vm.toString(s)));
                if (created) admitted++;
                else refused++;
            }
        }
        assertGt(admitted, 0, string.concat("some shapes are admitted (", pass, ")"));
        assertGt(refused, 0, string.concat("and some refused (", pass, ")"));
    }

    /// @dev The six reads genesis puts to a source, verbatim: the twins are asked at level 0, the scale with no argument.
    function _expectTheSixReads(address src) internal {
        (address q, address c) = (address(usdc), address(coll));
        vm.expectCall(src, abi.encodeCall(IPersistenceRecord.supportsPair, (q, c)));
        vm.expectCall(src, abi.encodeCall(IPersistenceRecord.minPrice, (q, c)));
        vm.expectCall(src, abi.encodeCall(IPersistenceRecord.persistedBelowDistress, (q, c, 0)));
        vm.expectCall(src, abi.encodeCall(IPersistenceRecord.persistedBelowSettle, (q, c, 0)));
        vm.expectCall(src, abi.encodeCall(IPersistenceRecord.lastObserved, (q, c)));
        vm.expectCall(src, abi.encodeWithSignature("UNIT_SCALE()"));
    }

    /// @dev Genesis's side of the calldata pin: these six reads are what `createMarket` asks of a record.
    function test_Calldata_GenesisAsksTheSixReads() public {
        address real = address(AceFixtures.venueRecord(address(this), 1e18, address(usdc), address(coll)));
        MarketParams memory p = AceFixtures.marketParams(address(usdc), address(coll));
        p.record = real;
        _expectTheSixReads(real);
        ace.createMarket(p);
    }

    /// @dev The lens's side: it asks the same six reads with the same arguments, so a twin asked at another level fails here.
    function test_Calldata_TheLensAsksTheSixReadsGenesisAsks() public {
        address real = address(AceFixtures.venueRecord(address(this), 1e18, address(usdc), address(coll)));
        _expectTheSixReads(real);
        (bool supported,) = lens.recordFitFor(real, address(usdc), address(coll));
        assertTrue(supported, "the venue record is supported");
    }

    /// @dev A record declaring a unit scale other than the hub's frame is refused by both; one declaring the frame is admitted by both.
    function test_Supported_ReadsTheUnitScaleAsGenesisDoes() public {
        (bool supported, bool created) = _verdicts(bytes4(keccak256("UNIT_SCALE()")), ShapedRecord.Shape.NotABool);
        assertFalse(created, "PREMISE: genesis refuses a record declaring the scale 2");
        assertFalse(supported, "and the lens does not call it supported");

        address real = address(AceFixtures.venueRecord(address(this), 1e18, address(usdc), address(coll)));
        (supported,) = lens.recordFitFor(real, address(usdc), address(coll));
        assertTrue(supported, "a record declaring the hub's frame is supported");
        MarketParams memory p = AceFixtures.marketParams(address(usdc), address(coll));
        p.record = real;
        assertEq(ace.idToMarketParams(ace.createMarket(p)).record, real, "and genesis admits it");
    }
}
