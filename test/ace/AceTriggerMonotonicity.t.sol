// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.36;

import {Test} from "forge-std/Test.sol";
import {FullMath} from "@uniswap/v4-core/src/libraries/FullMath.sol";
import {Ace} from "../../src/ace/hub/Ace.sol";
import {LoanMath} from "../../src/ace/hub/libraries/LoanMath.sol";
import {MarketParams, OpenBounds} from "../../src/ace/hub/Types.sol";
import {PositionManager} from "../../src/ace/positions/PositionManager.sol";
import {MockERC20} from "../mocks/MockERC20.sol";
import {MockPersistenceRecord} from "../mocks/MockPersistenceRecord.sol";
import {DeleverageCrank} from "../utils/DeleverageCrank.sol";
import {MockStakeVault} from "../mocks/MockStakeVault.sol";
import {AceFixtures} from "../utils/AceFixtures.sol";
import {ProtocolPolicy} from "../../src/config/Defaults.sol";
import {AceReader} from "../utils/AceReader.sol";

/// @title AceTriggerMonotonicity
/// @notice The doctrine sentence "the trigger falls as debt melts" now holds for BOTH verbs, and this pins it.
/// @notice A repay moves the numerator alone, so it falls by arithmetic.
/// @notice A disposal moves BOTH -- it sells collateral and melts debt -- so it falls only when the melt per unit wins.
/// @notice Genesis rails make it win: the stop check bounds the price and the sell-max rail bounds the take.
/// @dev `triggerPrice = ceil(k * debt * unitScale / (collateralUnits * 1e18))`.
/// @dev The decline channel's guarantee is genesis-enforced rather than checked per crank.
/// @dev This file once characterized where the sentence FAILED. That case was reachable only through a
/// @dev borrower payout dial, and the dial is deleted, so the boundary it measured no longer exists.
/// @dev Every assertion is cross-multiplied, pinning the ratio itself with no division.
contract AceTriggerMonotonicityTest is Test, DeleverageCrank {
    function _deleverageQuote() internal view override returns (address) {
        return address(usdc);
    }

    Ace internal ace;
    AceReader internal read;
    PositionManager internal positionManager;
    MockERC20 internal usdc;
    MockStakeVault internal vault;
    MockPersistenceRecord internal record;
    bytes32 internal id;

    address internal alice = address(0xA11CE);
    address internal borrower = address(0xB0B);
    address internal keeper = address(0xCAFE);

    uint256 internal constant COLL = 10_000e18;
    uint256 internal constant DRAW = 4_500e6;
    uint256 internal constant BAND_BPS = 3000;
    uint256 internal T2; // ticks above this pair's par; assigned in setUp, since par is not a compile-time value
    uint256 internal T3;
    uint256 internal T4;

    struct Skimmed {
        uint256 debtBefore;
        uint256 collBefore;
        uint256 unitsSold;
        uint256 stableOut;
        uint256 pay;
        uint256 debtAfter;
        uint256 collAfter;
    }

    /// @dev This suite's pair, so a tick reads as its distance from par rather than as a grid coordinate.
    /// @param offset Ticks above par.
    /// @return The absolute grid tick.
    function _price(int24 offset) internal view returns (uint256) {
        return AceFixtures.priceAt(address(usdc), address(vault), offset);
    }

    function setUp() public {
        usdc = new MockERC20("USD Coin", "USDC", 6);
        vault = new MockStakeVault(42);
        (T2, T3, T4) = (_price(0), _price(480), _price(960));
        record = new MockPersistenceRecord(address(usdc), address(vault));
        record.setMinPrice(AceFixtures.px(2e18, address(usdc), address(vault))); // finite, above every seeded tick: the disposal floor reads this

        MarketParams memory p = AceFixtures.marketParams(address(usdc), address(vault));
        p.record = address(record);
        p.deleverageFloorEpsBps = ProtocolPolicy.DELEVERAGE_FLOOR_EPS_BPS;
        p.deleverageBandBps = BAND_BPS;
        p.deleverageTargetBps = 4000;
        p.deleverageStopBps = 1;
        AceFixtures.Deployment memory d = AceFixtures.deploy(p);
        (ace, positionManager, read, id) = (d.ace, d.positionManager, d.read, d.id);

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

    /// @dev The trigger recomputed from RAW storage through the shipped pure function.
    function _trigger(uint256 loanId) internal view returns (uint256) {
        MarketParams memory p = ace.idToMarketParams(id);
        return LoanMath.triggerPrice(read.loan(loanId).debt, read.loan(loanId).collateralUnits, p.minCoverageWad, read.marketState(id).unitScale);
    }

    /// @dev Crank one disposal and capture both sides of the ratio around it.
    function _crank(uint256 loanId) internal returns (Skimmed memory s) {
        s.debtBefore = read.loan(loanId).debt;
        s.collBefore = read.loan(loanId).collateralUnits;
        uint256 trig = read.triggerPrice(loanId);
        uint256 ps = trig + trig / 20;
        record.setBelowBand(FullMath.mulDivRoundingUp(trig, 1e18, 1e18 - BAND_BPS * 1e14));
        record.setMinPrice(ps);
        (s.unitsSold, s.stableOut) = ace.deleverage(loanId, 0, "");
        s.debtAfter = read.loan(loanId).debt;
        s.collAfter = read.loan(loanId).collateralUnits;
        s.pay = s.debtBefore - s.debtAfter;
    }

    /// @dev The monotonicity condition, cross-multiplied: the trigger falls iff debt retired per unit sold beats the loan's debt per unit of collateral.
    function _meltBeatsAverage(Skimmed memory s) internal pure returns (bool) {
        return s.pay * s.collBefore > s.debtBefore * s.unitsSold;
    }

    // ============ the half of the doctrine that IS arithmetic ============

    /// @notice A repay moves the numerator alone, so the trigger falls by construction.
    function test_Repay_TriggerFallsByConstruction() public {
        uint256 loanId = _open();
        uint256 collBefore = read.loan(loanId).collateralUnits;
        uint256 t0 = _trigger(loanId);

        usdc.mint(borrower, 1_000e6);
        vm.startPrank(borrower);
        usdc.approve(address(ace), 1_000e6);
        ace.repay(loanId, 1_000e6);
        vm.stopPrank();

        assertEq(read.loan(loanId).collateralUnits, collBefore, "repay moves no collateral at all");
        assertLt(_trigger(loanId), t0, "debt-only paydown: the trigger falls, always");
    }

    // ============ the half that used to be reachable, and is not ============

    /// @notice The trigger falls, and it falls BECAUSE the melt-per-unit condition holds.
    /// @dev No dial to set: full melt is the only behaviour, so this is unconditional rather than a default.
    function test_Deleverage_TriggerFalls_AndTheConditionExplainsIt() public {
        uint256 loanId = _open();
        uint256 t0 = _trigger(loanId);

        Skimmed memory s = _crank(loanId);

        assertGt(s.pay, 0, "the proceeds melted debt");
        assertLt(_trigger(loanId), t0, "the trigger falls");
        assertTrue(_meltBeatsAverage(s), "and the melt-per-unit condition is what makes it fall");
    }

    /// @notice THERE IS NO DIAL: every quote the disposal realizes melts debt, on every crank.
    /// @notice Asserted as an EQUALITY against the crank's own `stableOut`, not as "some debt melted".
    /// @dev The waterfall is PASS-THROUGH at a zero cut, so `pay` and `stableOut` are the same number.
    function test_Deleverage_ThereIsNoDial_EveryQuoteRealizedMelts() public {
        uint256 loanId = _open();

        Skimmed memory s = _crank(loanId);

        assertGt(s.stableOut, 0, "fixture: the crank really realized proceeds to melt");
        assertLt(s.stableOut, s.debtBefore, "fixture: the melt is not clipped by the debt, so equality is the real test");
        assertEq(s.pay, s.stableOut, "every wei realized melted debt, with nothing diverted to the borrower");
    }
}
