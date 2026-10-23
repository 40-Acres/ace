// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.36;

import {Test} from "forge-std/Test.sol";
import {Ace} from "../../src/ace/hub/Ace.sol";
import {MarketParams} from "../../src/ace/hub/Types.sol";
import {PocDeployConfig, ProtocolPolicy} from "../../src/config/Defaults.sol";
import {AceFixtures} from "../utils/AceFixtures.sol";
import {PriceFrame} from "../utils/PriceFrame.sol";

/// @dev createMarket reads decimals() off both tokens and nothing else.
contract OffChannelToken {
    uint8 public immutable decimals;

    constructor(uint8 d) {
        decimals = d;
    }
}

/// @notice A record that AFFIRMS the ordered pair, answers every gate, and cannot answer the HEAD: the shape genesis now refuses.
/// @dev It clears `supportsPair`, `minPrice`, `persistedBelowDistress` and `persistedBelowSettle`, so only the head probe can catch it.
contract MuteHeadRecord {
    error NoOpinion();

    address private immutable Q;
    address private immutable C;

    constructor(address quote, address collateral) {
        Q = quote;
        C = collateral;
    }

    function supportsPair(address quote, address collateral) external view returns (bool) {
        return quote == Q && collateral == C;
    }

    function minPrice(address, address) external pure returns (uint256) {
        return 1e18;
    }

    function persistedBelowDistress(address, address, uint256) external pure returns (bool) {
        return false;
    }

    function persistedBelowSettle(address, address, uint256) external pure returns (bool) {
        return false;
    }

    function lastObserved(address, address) external pure returns (uint256) {
        revert NoOpinion();
    }
}

/// @title AceGenesisOffChannelFields
/// @notice The lie-guard at the deleverage-off door, read as a SET rather than field by field.
/// @notice AUDIT POC (run 2026-08-31-23b79e, phase 1): its L2 finding is #400, and these rows now pin the fix.
/// @dev The guard's own sentence is that a declared-but-unread field on an immutable preimage is a lie.
/// @dev Four fields go unread when the band is zero -- stop, cut, target and eps -- and the guard names all four.
contract AceGenesisOffChannelFieldsTest is Test {
    Ace internal ace;
    OffChannelToken internal quote;
    OffChannelToken internal collateral;

    function setUp() public {
        ace = AceFixtures.newAce();
        quote = new OffChannelToken(6);
        collateral = new OffChannelToken(18);
    }

    /// @dev A band-off market with every optional seam left unset: the shipped economics, no decline channel.
    function _base() internal view returns (MarketParams memory p) {
        p.quote = address(quote);
        p.collateral = address(collateral);
        p.fillFeeBps = 25;
        p.minCoverageWad = PocDeployConfig.MIN_COVERAGE_WAD;
        p.baseBps = PocDeployConfig.BASE_BPS;
        p.minTenor = ProtocolPolicy.MIN_TENOR;
        p.maxTenor = ProtocolPolicy.MAX_TENOR;
        p.minDebt = PocDeployConfig.MIN_DEBT;
        p.settleBountyBps = PocDeployConfig.SETTLE_BOUNTY_BPS;
        /// @dev Sole tenancy and the market's one price: genesis refuses a zero of either, and every row
        /// @dev below means to trip a DIFFERENT rail, so both are set to something unremarkable here.
        p.lender = address(0x1E4DE2);
        p.price = PriceFrame.priceAt(address(quote), address(collateral), 0);
        p.inventoryAsk = true; // the baseline carries a fill fee, which genesis admits only beside the ask
    }

    /// @notice THE CONTROL. Without it the two rail tests below could pass for the wrong reason.
    function test_Control_BandOffBaselineIsAdmissible() public {
        MarketParams memory p = _base();
        assertEq(p.deleverageBandBps, 0, "fixture: the decline channel really is off");
        bytes32 id = ace.createMarket(p);
        assertEq(ace.idToMarketParams(id).quote, address(quote), "the band-off baseline really does create");
    }

    /// @notice STOP AND CUT, the two dials the guard named first, refused under the one string that now covers all four.
    function test_Rail_StopAndCutAreRefusedWhenTheBandIsOff() public {
        MarketParams memory p = _base();
        p.deleverageStopBps = 1;
        vm.expectRevert(bytes("deleverage off but dials set"));
        ace.createMarket(p);

        p = _base();
        p.deleverageProtocolBps = 1;
        vm.expectRevert(bytes("deleverage off but dials set"));
        ace.createMarket(p);
    }

    /// @notice ONE ECONOMIC MARKET, ONE ID: with the band off, neither the target nor eps may fork the preimage.
    /// @notice Both were once admitted unread -- the target with no bound at all -- so each value spelled the same market again.
    /// @dev Deleverage refuses before it reads either, so the cross-market equality rail was their only reader, and it refused.
    function test_Preimage_ABandOffMarketHasOneId() public {
        bytes32 plain = ace.createMarket(_base());
        assertEq(ace.idToMarketParams(plain).deleverageBandBps, 0, "the plain band-off market creates");

        MarketParams memory p = _base();
        p.deleverageTargetBps = type(uint256).max;
        vm.expectRevert(bytes("deleverage off but dials set"));
        ace.createMarket(p);

        p = _base();
        p.deleverageFloorEpsBps = 100;
        vm.expectRevert(bytes("deleverage off but dials set"));
        ace.createMarket(p);
    }

    /// @notice A codeless `borrower` is a legitimate EOA, so genesis admits it: the gate contract is deleted.
    /// @dev `MarketParams.borrower` is COMPARED against the opener and never called, so no code is needed behind it.
    /// @dev That is why #400 L3, the codeless-gate finding, is moot: there is no call left to revert.
    function test_Genesis_ACodelessBorrowerIsAdmitted() public {
        MarketParams memory p = _base();
        p.borrower = address(0xDEADBEEF);
        assertEq(p.borrower.code.length, 0, "fixture: the gate address really carries no code");
        bytes32 id = ace.createMarket(p);
        assertEq(ace.idToMarketParams(id).borrower, p.borrower, "genesis admits a codeless borrower: it is compared, never called");
    }

    /// @notice An ARMED channel whose record cannot answer the head is REFUSED: the preimage may not claim a source it has not got.
    /// @dev The head is one of the four `IPersistenceRecord` reads, so a record mute on it has not implemented the interface.
    /// @dev No hub verb reads the head and the lens asks it only through a tolerant probe; the draw cap reads `minPrice`.
    /// @dev The revert BUBBLES rather than being renamed, which is the house posture: a source that reverts bricks only the market naming it.
    function test_Genesis_AnArmedRecordThatCannotAnswerTheHeadIsRefused() public {
        MuteHeadRecord rec = new MuteHeadRecord(address(quote), address(collateral));

        MarketParams memory p = _base();
        p.record = address(rec);
        p.deleverageBandBps = 3000;
        p.deleverageTargetBps = 5000;
        p.deleverageStopBps = 1000;
        p.deleverageProtocolBps = 500;
        p.deleverageFloorEpsBps = 100; // an armed band needs a nonzero eps

        vm.expectRevert(MuteHeadRecord.NoOpinion.selector);
        ace.createMarket(p);
    }

    /// @notice THE UNCONDITIONAL HALF: the SAME mute record is refused with the channel OFF too.
    /// @notice This is what the head probe bought over the retired reference leg, which only fired on an armed band.
    /// @dev The interview checks the interface, not the subset one configuration exercises, so the band does not scope it.
    /// @dev Scoping a probe to the band is what let a source pass genesis and then brick a channel nobody can edit.
    function test_Genesis_AMuteRecordIsRefusedEvenWhenTheChannelIsOff() public {
        MuteHeadRecord rec = new MuteHeadRecord(address(quote), address(collateral));
        MarketParams memory p = _base();
        p.record = address(rec);
        assertEq(p.deleverageBandBps, 0, "fixture: the decline channel really is off");
        vm.expectRevert(MuteHeadRecord.NoOpinion.selector);
        ace.createMarket(p);
    }

    /// @notice A market naming NO record still creates: the head probe is scoped to a record that exists.
    /// @dev The lens answers `recordObserving` false for exactly this case, so genesis must not turn it into a refusal.
    function test_Genesis_ARecordlessMarketIsStillAdmitted() public {
        MarketParams memory p = _base();
        assertEq(p.record, address(0), "fixture: no record is named");
        bytes32 id = ace.createMarket(p);
        assertEq(ace.idToMarketParams(id).record, address(0), "a recordless market is a legal shape");
    }
}
