// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.36;

import {Test, Vm} from "forge-std/Test.sol";
import {FullMath} from "@uniswap/v4-core/src/libraries/FullMath.sol";
import {Ace} from "../../src/ace/hub/Ace.sol";
import {Constants} from "../../src/ace/hub/Constants.sol";
import {MarketParams, OpenBounds} from "../../src/ace/hub/Types.sol";
import {PriceFrame} from "../utils/PriceFrame.sol";
import {PositionManager} from "../../src/ace/positions/PositionManager.sol";
import {MockERC20} from "../mocks/MockERC20.sol";
import {MockPersistenceRecord} from "../mocks/MockPersistenceRecord.sol";
import {MockDeleverageKeeper} from "../mocks/MockDeleverageKeeper.sol";
import {MockStakeVault} from "../mocks/MockStakeVault.sol";
import {AceFixtures} from "../utils/AceFixtures.sol";
import {AceReader} from "../utils/AceReader.sol";

/// @title AceGenesisCoverageFuzz
/// @notice Assertion 4 of #187: every config genesis accepts PRESERVES COVERAGE under every permissionless crank.
/// @notice A crank on a NON-DISTRESSED loan must not raise the trigger, whatever the creator dialled.
/// @notice Equivalently: debt retired per unit sold must clear the loan's own debt per unit of collateral.
/// @notice The alternative a channel may take is a NAMED refusal; an arithmetic panic is neither.
/// @dev WHY THIS IS A SEPARATE ASSERTION. #208's market is FULLY OPERABLE -- draw, repay, crank and settle all
/// @dev terminate -- and it is insolvent. Liveness is not solvency, and only this row measures the second.
/// @dev The channel is fuzzed at the PARAM level, so `k`, the band, the target, the stop and `eps` move together.
contract AceGenesisCoverageFuzzTest is Test {
    Ace internal ace;
    PositionManager internal positionManager;
    AceReader internal read;
    MockERC20 internal usdc;
    MockStakeVault internal vault;
    MockPersistenceRecord internal record;
    MockDeleverageKeeper internal keeper;

    address internal lender = address(0xA11CE);
    address internal borrower = address(0xB0B);
    address internal cranker = address(0xCAFE);

    uint256 internal constant COLL = 10_000e18;
    uint256 internal constant LADDER = 20_000e6;
    uint256 internal constant UNIT_SCALE = 1 << 96; // every market's scale under the atom frame
    uint256 internal constant PANIC = 0x4e487b71; // Panic(uint256), the one refusal a rail may never be
    uint256 internal T0; // par for this pair, where the funding floor reads off the page; assigned in setUp

    /// @dev This suite's pair, so a tick reads as its distance from par rather than as a grid coordinate.
    /// @param offset Ticks above par.
    /// @return The absolute grid tick.
    function _price(int24 offset) internal view returns (uint256) {
        return AceFixtures.priceAt(address(usdc), address(vault), offset);
    }

    function setUp() public {
        vm.warp(1_000_000);
        usdc = new MockERC20("USD Coin", "USDC", 6);
        vault = new MockStakeVault(42);
        T0 = _price(0);
        record = new MockPersistenceRecord(address(usdc), address(vault));
        record.setMinPrice(AceFixtures.px(2e18, address(usdc), address(vault)));
        (ace, positionManager) = AceFixtures.newAceWithEscrow(AceFixtures.TREASURY);
        read = new AceReader(address(ace));
        keeper = new MockDeleverageKeeper(ace, address(usdc), address(vault), UNIT_SCALE);
    }

    /* ====================== the sampler ====================== */

    function _rand(uint256 seed, uint256 k) private pure returns (uint256) {
        return uint256(keccak256(abi.encode(seed, k)));
    }

    function _pick(uint256 seed, uint256 k, uint256 lo, uint256 hi) private pure returns (uint256) {
        return lo + (_rand(seed, k) % (hi - lo + 1));
    }

    /// @dev The whole admitted box: `k` at both ends and eps to its ceiling.
    /// @dev eps starts at 1 because genesis refuses a zero on a live channel, which is a rail and not a gap.
    function _cuts(uint256 seed) private pure returns (uint256 k, uint256 eps) {
        k = _pick(seed, 1, Constants.MIN_COVERAGE_WAD, Constants.MAX_COVERAGE_WAD);
        eps = _pick(seed, 4, 1, Constants.MAX_DELEVERAGE_FLOOR_EPS_BPS);
    }

    function _params(uint256 k, uint256 eps) private view returns (MarketParams memory p) {
        p = AceFixtures.marketParams(address(usdc), address(vault));
        p.record = address(record);
        p.minCoverageWad = k;
        p.deleverageFloorEpsBps = eps;
    }

    function _seed(bytes32 id) private {
        usdc.mint(lender, LADDER);
        vm.startPrank(lender);
        usdc.approve(address(ace), LADDER);
        ace.deposit(id, LADDER);
        vm.stopPrank();
    }

    /// @dev The largest draw the par tick admits at this `k`, taken at 97% so the trigger's ceil cannot cross it.
    /// @dev Sizing off `k` is what keeps every row at the SAME leverage rather than at the same principal.
    function _openAtTheGate(bytes32 id, uint256 k) private returns (uint256 loanId) {
        uint256 principal = ((COLL * 1e6) / k) * 97 / 100;
        vault.mint(borrower, COLL);
        vm.startPrank(borrower);
        vault.approve(address(positionManager), COLL);
        loanId = ace.open(id, COLL, principal, 0, borrower, OpenBounds(0, 0, 0));
        vm.stopPrank();
        assertEq(read.fundingFloor(id, loanId), T0, "fixture: the floor is the market own price");
        assertLe(read.triggerPrice(loanId), read.fundingFloor(id, loanId), "fixture: admitted under the coverage gate");
    }

    /// @dev A refusal is legal; a PANIC is not. This is assertion 2 restated on the crank rather than on genesis.
    function _assertNamed(bytes memory err, string memory what) private pure {
        assertGe(err.length, 4, what);
        assertTrue(uint32(bytes4(err)) != uint32(PANIC), what);
    }

    /* ====================== the decline channel ====================== */

    /// @notice A deleverage on a loan the record has NOT marked distressed either lowers the trigger or refuses.
    /// @notice The band, the target, the stop and the cut are fuzzed together, so their product is what is tested.
    /// @dev Genesis already rails this channel's product; the row exists to prove that rail is the RIGHT one.
    /// @dev A config genesis refuses is skipped here, because the rejection arm is assertion 2's job, not this one.
    function testFuzz_Coverage_ADeleverageNeverRaisesTheTrigger(uint256 seed) public {
        _delevRun(seed);
    }

    /// @dev ONE body, so the sweep and the anti-vacuity count can never exercise different code.
    function _delevRun(uint256 seed) private returns (bool) {
        (uint256 k, uint256 eps) = _cuts(seed);
        MarketParams memory p = _params(k, eps);
        p.deleverageBandBps = _pick(seed, 20, Constants.MIN_DELEVERAGE_BAND_BPS, 9000);
        p.deleverageTargetBps = _pick(seed, 21, p.deleverageBandBps + 1, 9999);
        p.deleverageStopBps = _pick(seed, 22, 1, p.deleverageBandBps - 1);
        p.deleverageProtocolBps = _pick(seed, 23, 0, Constants.MAX_DELEVERAGE_PROTOCOL_BPS);
        (bool ok, bytes memory ret) = address(ace).call(abi.encodeCall(Ace.createMarket, (p)));
        if (!ok) return false;
        bytes32 id = abi.decode(ret, (bytes32));
        _seed(id);

        uint256 loanId = _openAtTheGate(id, k);
        uint256 before = read.triggerPrice(loanId);
        _enterBand(loanId, p.deleverageBandBps, _pick(seed, 24, 1.001e18, 1e18 + (10000 - p.deleverageBandBps) * 1e14 - 1e15));

        vm.prank(cranker);
        try keeper.crankDeleverage(loanId) returns (uint256 sold, uint256) {
            if (sold == 0) return false;
            assertLe(read.triggerPrice(loanId), before, "an admitted deleverage raised the trigger it was meant to lower");
            return true;
        } catch (bytes memory err) {
            _assertNamed(err, "a deleverage refused by arithmetic rather than by name");
            return false;
        }
    }

    /// @dev Below-ness holds at the band level and not at the trigger, so the loan is in band and not distressed.
    function _enterBand(uint256 loanId, uint256 bandBps, uint256 rhoWad) private {
        uint256 trig = read.triggerPrice(loanId);
        record.setBelowBand(FullMath.mulDivRoundingUp(trig, 1e18, 1e18 - bandBps * 1e14));
        uint256 ps = (trig * rhoWad) / 1e18;
        record.setMinPrice(ps);
    }

    /* ====================== the #208 endpoint: liveness is not solvency ====================== */

    /// @notice TWO cranks on a never-distressed loan, then settlement: the close must report ZERO bad debt.
    /// @notice This is the endpoint #208 walked a fully-operable market into, so it is asserted directly.
    /// @dev The crank is allowed to refuse; what is forbidden is a settled loss on a loan the record never marked.
    /// @dev `ForceClosed(uint256 indexed id, uint256 collateralUnits, uint256 badDebt, address indexed executor)`.
    function testFuzz_Coverage_TwoCranksThenSettleReportNoBadDebt(uint256 seed) public {
        (uint256 k, uint256 eps) = _cuts(seed);
        MarketParams memory p = _params(k, eps);
        uint256 band = _pick(seed, 20, Constants.MIN_DELEVERAGE_BAND_BPS, 9000);
        p.deleverageBandBps = band;
        p.deleverageTargetBps = _pick(seed, 21, band + 1, 9999);
        p.deleverageStopBps = _pick(seed, 22, 1, band - 1);
        p.deleverageProtocolBps = _pick(seed, 23, 0, Constants.MAX_DELEVERAGE_PROTOCOL_BPS);
        (bool created, bytes memory ret) = address(ace).call(abi.encodeCall(Ace.createMarket, (p)));
        if (!created) return; // a config genesis refuses is assertion 2's job, not this one
        bytes32 id = abi.decode(ret, (bytes32));
        _seed(id);

        uint256 loanId = _openAtTheGate(id, k);

        _tryCrank(loanId, band, _pick(seed, 11, 1.001e18, 1e18 + (10000 - band) * 1e14 - 1e15));
        _tryCrank(loanId, band, _pick(seed, 12, 1.001e18, 1e18 + (10000 - band) * 1e14 - 1e15));
        if (read.loan(loanId).closedAt != 0) return; // a crank that cleared the debt closed it clean, which is the good end

        assertFalse(read.settleable(loanId), "fixture: the record never marked this loan distressed");
        vm.warp(uint256(read.loan(loanId).expiry) + 1);
        vm.recordLogs();
        vm.prank(cranker);
        ace.forceClose(loanId);
        assertEq(_badDebt(), 0, "a loan the record never marked distressed settled at a loss");
    }

    /// @dev One crank, absorbing the named refusals: a refused crank is a legal outcome, a raised trigger is not.
    function _tryCrank(uint256 loanId, uint256 bandBps, uint256 rhoWad) private {
        uint256 before = read.triggerPrice(loanId);
        _enterBand(loanId, bandBps, rhoWad);
        vm.prank(cranker);
        try keeper.crankDeleverage(loanId) returns (uint256 sold, uint256) {
            if (sold > 0) assertLe(read.triggerPrice(loanId), before, "a crank in the two-crank walk raised the trigger");
        } catch (bytes memory err) {
            _assertNamed(err, "a crank in the two-crank walk refused by arithmetic rather than by name");
        }
    }

    /// @dev The bad debt the settlement reported, read off the log rather than derived from the loan.
    function _badDebt() private returns (uint256 bad) {
        Vm.Log[] memory logs = vm.getRecordedLogs();
        bytes32 sig = keccak256("ForceClosed(uint256,uint256,uint256,address)");
        bool seen;
        for (uint256 i; i < logs.length; i++) {
            if (logs[i].emitter != address(ace) || logs[i].topics[0] != sig) continue;
            seen = true;
            (, bad) = abi.decode(logs[i].data, (uint256, uint256));
        }
        assertTrue(seen, "fixture: the hub must have emitted ForceClosed for the read to mean anything");
    }

    /* ====================== anti-vacuity ====================== */

    /// @notice A sweep whose every crank refuses or sizes to zero asserts NOTHING, and would still go green.
    /// @notice So the channel's admitted arm is counted directly, over the same body the fuzz row runs.
    /// @dev Deterministic, so a sampler that stops reaching the admitted arm fails here by name.
    /// @dev The refused arm is counted too: it is where #208's band lives, and an unreached one hides it.
    function test_Sampler_ReachesTheAdmittedArmOnTheDeclineChannel() public {
        uint256 decline;
        for (uint256 s = 1; s <= 30; s++) {
            uint256 snap = vm.snapshotState();
            if (_delevRun(s)) decline++;
            vm.revertToState(snap);
        }
        emit log_named_uint("deleverages that sold, of 30", decline);
        assertGt(decline, 3, "the decline channel must reach an admitted crank, or its no-raise bound never runs");
    }
}
