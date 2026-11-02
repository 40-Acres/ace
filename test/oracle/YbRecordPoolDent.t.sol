// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.36;

import {FullMath} from "@uniswap/v4-core/src/libraries/FullMath.sol";
import {WarpClock} from "../utils/WarpClock.sol";
import {Ace} from "../../src/ace/hub/Ace.sol";
import {MarketParams, OpenBounds} from "../../src/ace/hub/Types.sol";
import {NotInBand} from "../../src/ace/hub/Deleverage.sol";
import {NotSettleable} from "../../src/ace/hub/Settlement.sol";
import {InsufficientCash} from "../../src/ace/hub/Borrower.sol";
import {PositionManager} from "../../src/ace/positions/PositionManager.sol";
import {IAceDeleverageCallback} from "../../src/interfaces/IAceDeleverageCallback.sol";
import {YbRecord} from "../../src/oracle/YbRecord.sol";
import {MockAggregatorV3} from "../mocks/MockAggregatorV3.sol";
import {MockERC20} from "../mocks/MockERC20.sol";
import {MockYbGauge, MockYbLt} from "../mocks/MockYb.sol";
import {AceFixtures} from "../utils/AceFixtures.sol";
import {AceReader} from "../utils/AceReader.sol";

/// @notice The attacker: a permissionless keeper that dents the LT's redemption leg, cranks the hub and restores the leg in one call.
/// @dev The mock's `setPreviewWithdraw` stands in for a flash swap that imbalances the YieldBasis pool; pps and the feed are untouched.
contract PoolDentKeeper is IAceDeleverageCallback {
    Ace public immutable ACE;
    MockERC20 public immutable USDC;
    MockYbLt public immutable LT;
    uint256 public immutable DENTED; // the underlying-native redemption rate while the pool is imbalanced

    constructor(Ace ace, MockERC20 usdc, MockYbLt lt, uint256 dented) {
        (ACE, USDC, LT, DENTED) = (ace, usdc, lt, dented);
    }

    /// @notice Dent, deleverage, restore.
    function deleverageAttack(uint256 loanId) external returns (uint256 sold, uint256 paid) {
        LT.setPreviewWithdraw(DENTED);
        (sold, paid) = ACE.deleverage(loanId, 0, "");
        LT.setPreviewWithdraw(0);
    }

    /// @notice Dent, finalize, restore.
    function finalizeAttack(uint256 loanId) external {
        LT.setPreviewWithdraw(DENTED);
        ACE.finalize(loanId);
        LT.setPreviewWithdraw(0);
    }

    /// @notice Pays exactly what the hub asks.
    function onAceDeleverage(uint256, uint256 quoteOwed, bytes calldata) external {
        require(msg.sender == address(ACE), "only hub");
        USDC.approve(address(ACE), quoteOwed);
    }
}

/// @title YbRecordPoolDentTest
/// @notice A one-transaction dent in the pool-derived redemption leg lowers the draw cap and never flips either below-twin.
/// @dev A ported proof of concept with its harm assertions inverted into refusals: the attack rows fail on a record whose twins take the dent.
contract YbRecordPoolDentTest is WarpClock {
    Ace internal ace;
    PositionManager internal positionManager;
    AceReader internal read;
    bytes32 internal mid;

    MockERC20 internal usdc;
    MockERC20 internal btc;
    MockYbLt internal lt;
    MockAggregatorV3 internal feed;
    YbRecord internal rec;
    PoolDentKeeper internal keeper;

    address internal borrower = address(0xB0B);
    uint256 internal loanId;

    uint256 internal constant COLL = 10_000e18;
    uint256 internal constant PRINCIPAL = 4_500e6;
    uint256 internal constant BAND_BPS = 3000;
    uint256 internal constant Q96 = 1 << 96;
    uint256 internal constant DENTED = 0.96e8; // a 4% redemption discount on a BTC-backed LT, just past the widest gap seen live (3.9%)

    function setUp() public {
        _warpBy(365 days);
        usdc = new MockERC20("USD Coin", "USDC", 6);
        btc = new MockERC20("Coinbase Wrapped BTC", "cbBTC", 8);
        lt = new MockYbLt();
        lt.setAssetToken(address(btc));
        lt.setPps(1e18); // one LT accounts for one underlying, so the feed alone sets the honest price
        feed = new MockAggregatorV3(8);
        feed.push(2e8); // the loan opens well healthy
        rec = new YbRecord(address(feed), address(lt), address(0), address(usdc), address(btc), 1 hours);

        MarketParams memory p = AceFixtures.marketParams(address(usdc), address(lt));
        p.record = address(rec);
        p.deleverageFloorEpsBps = 100;
        p.deleverageBandBps = BAND_BPS;
        p.deleverageTargetBps = 4000;
        p.deleverageStopBps = 1;
        AceFixtures.Deployment memory d = AceFixtures.deploy(p);
        (ace, positionManager, read, mid) = (d.ace, d.positionManager, d.read, d.id);

        usdc.mint(AceFixtures.LENDER, 15_000e6);
        vm.startPrank(AceFixtures.LENDER);
        usdc.approve(address(ace), 15_000e6);
        ace.deposit(mid, 15_000e6);
        vm.stopPrank();

        lt.mint(borrower, COLL);
        vm.startPrank(borrower);
        lt.approve(address(positionManager), COLL);
        loanId = ace.open(mid, COLL, PRINCIPAL, 0, borrower, OpenBounds(0, 0, 0));
        vm.stopPrank();

        keeper = new PoolDentKeeper(ace, usdc, lt, DENTED);
        usdc.mint(address(keeper), 100_000e6);
    }

    /// @dev Moves the USD feed so the record, at pps one and undiscounted, answers about `framed`.
    function _setHonestPrice(uint256 framed) internal {
        feed.push(int256(FullMath.mulDiv(framed, 1e20, Q96)) + 1);
    }

    function _print() internal view returns (uint256) {
        return rec.lastObserved(address(usdc), address(lt));
    }

    // ---- the record ----

    /// @notice The draw cap still takes the realizable rate: a dent lowers it, so the min keeps guarding borrowing power.
    function test_ADentStillLowersTheDrawCap() public {
        uint256 honest = rec.minPrice(address(usdc), address(lt));
        lt.setPreviewWithdraw(DENTED);
        uint256 dented = rec.minPrice(address(usdc), address(lt));
        assertGt(dented, 0, "the dented record still prices: a closed answer would pass the rows below");
        assertLt(dented, honest, "the redemption discount reaches the draw cap");
        assertEq(dented, _print(), "and the last print with it");
    }

    /// @notice Neither below-twin flips at a level the honest price clears, however far a dent pushes the realizable rate.
    function test_ADentFlipsNeitherBelowTwin() public {
        uint256 x = _print() - _print() / 100; // one percent under the honest price
        lt.setPreviewWithdraw(DENTED);
        assertGt(_print(), 0, "PREMISE: the dented record still prices, so the twins answer rather than close");
        assertLt(_print(), x, "PREMISE: the dented print sits under the level");
        assertFalse(rec.persistedBelowDistress(address(usdc), address(lt), x), "a dent cannot open the band");
        assertFalse(rec.persistedBelowSettle(address(usdc), address(lt), x), "a dent cannot open settlement");
    }

    /// @notice CONTROL: a fall in the accounting rate itself still flips both twins.
    function test_AnAccountingFallStillFlipsBothTwins() public {
        uint256 x = _print() - _print() / 100;
        lt.setPps(0.96e18);
        assertTrue(rec.persistedBelowDistress(address(usdc), address(lt), x), "an accounting loss opens the band");
        assertTrue(rec.persistedBelowSettle(address(usdc), address(lt), x), "and settlement");
    }

    /// @notice The below path still asks the redemption leg: a locked LT closes the twins rather than answering off accounting.
    function test_ALockedRedemptionReadClosesBothTwins() public {
        lt.setPreviewLocked(true);
        assertGt(lt.pricePerShare(), 0, "PREMISE: the accounting rate still answers");
        assertFalse(rec.persistedBelowDistress(address(usdc), address(lt), type(uint256).max), "a locked read proves no below-ness");
        assertFalse(rec.persistedBelowSettle(address(usdc), address(lt), type(uint256).max), "on either twin");
        assertEq(rec.minPrice(address(usdc), address(lt)), 0, "and the draw cap closes with it");
    }

    // ---- the hub, through the keeper ----

    /// @notice A loan 2% above its band at the honest price cannot be deleveraged by a one-transaction dent.
    function test_ADentCannotDeleverageAHealthyLoan() public {
        uint256 trig = read.triggerPrice(loanId);
        uint256 bandLevel = FullMath.mulDivRoundingUp(trig, 1e18, 1e18 - BAND_BPS * 1e14);
        _setHonestPrice((bandLevel * 102) / 100);
        assertGt(_print(), bandLevel, "PREMISE: at the honest price the loan is out of the band");
        lt.setPreviewWithdraw(DENTED);
        assertLt(_print(), bandLevel, "PREMISE: the dented print is inside the band");
        lt.setPreviewWithdraw(0);

        vm.expectRevert(NotInBand.selector);
        keeper.deleverageAttack(loanId);
        assertEq(read.loan(loanId).collateralUnits, COLL, "the healthy loan keeps every unit");
    }

    /// @notice A loan 2% above its trigger at the honest price cannot be finalized by a one-transaction dent.
    function test_ADentCannotFinalizeAHealthyLoan() public {
        uint256 trig = read.triggerPrice(loanId);
        _setHonestPrice((trig * 102) / 100);
        assertGt(_print(), trig, "PREMISE: at the honest price the loan is above its trigger");
        lt.setPreviewWithdraw(DENTED);
        assertLt(_print(), trig, "PREMISE: the dented print is under the trigger");
        lt.setPreviewWithdraw(0);

        vm.expectRevert(NotSettleable.selector);
        keeper.finalizeAttack(loanId);
        assertEq(uint256(read.loan(loanId).closedAt), 0, "the healthy loan stays open");
    }

    /// @notice CONTROL: a loan the accounting rate puts under its trigger still finalizes.
    function test_AnHonestFallStillFinalizes() public {
        uint256 trig = read.triggerPrice(loanId);
        _setHonestPrice((trig * 98) / 100);
        ace.finalize(loanId);
        assertGt(uint256(read.loan(loanId).closedAt), 0, "a loan honestly under its trigger settles");
    }

    // ---- the record: a dent is priced, never closed, and never masks a fall ----

    /// @notice The draw cap reads a dent exactly as it reads an equal fall in the accounting rate.
    /// @dev A record answering zero under any discount satisfies a bare `dented < honest`; equality with the fall refuses it.
    function test_ADentPricesTheDrawCapAsAnEqualAccountingFall() public {
        uint256 honest = rec.minPrice(address(usdc), address(lt));
        lt.setPreviewWithdraw(DENTED);
        uint256 dented = rec.minPrice(address(usdc), address(lt));
        lt.setPreviewWithdraw(0);
        lt.setPps(0.96e18); // the accounting rate falls by the dent's 4%, and the mock's redemption leg follows it
        uint256 fallen = rec.minPrice(address(usdc), address(lt));
        assertGt(fallen, 0, "PREMISE: an accounting fall still prices");
        assertLt(fallen, honest, "PREMISE: and prices lower");
        assertEq(dented, fallen, "the draw cap prices a 4% dent as a 4% fall");
    }

    /// @notice A standing discount does not mask an accounting fall: under a dented pool both twins still flip.
    /// @dev Live pools trade at a standing discount, so twins that went dark under one would leave the market unsettleable.
    function test_ADentDoesNotMaskAnAccountingFall() public {
        uint256 x = _print() - _print() / 100;
        lt.setPps(0.98e18); // a 2% accounting fall, under the level
        uint256 fallen = _print();
        lt.setPreviewWithdraw(0.94e8); // and the pool a further 4% under it
        assertGt(_print(), 0, "PREMISE: the record still prices");
        assertLt(_print(), fallen, "PREMISE: the pool trades under the accounting rate");
        assertTrue(rec.persistedBelowDistress(address(usdc), address(lt), x), "the band opens on the accounting fall");
        assertTrue(rec.persistedBelowSettle(address(usdc), address(lt), x), "and settlement");
    }

    /// @notice The recovery read takes the realizable rate: a level between the dented and the honest print is not above under a dent.
    /// @dev Such a level is then neither above nor below, the conservative gap the two rates leave between them.
    function test_ADentTakesPersistedAboveDown() public {
        uint256 honest = _print();
        lt.setPreviewWithdraw(DENTED);
        uint256 dented = _print();
        uint256 x = (dented + honest) / 2;
        assertGt(dented, 0, "PREMISE: the dented record still prices");
        assertTrue(dented < x && x < honest, "PREMISE: the level sits between the two prints");
        assertFalse(rec.persistedAbove(address(usdc), address(lt), x), "a dent takes the level out of above");
        assertFalse(rec.persistedBelowDistress(address(usdc), address(lt), x), "and leaves it out of below");
        assertTrue(rec.persistedAbove(address(usdc), address(lt), dented - 1), "a level under the dented print is still above");
        lt.setPreviewWithdraw(0);
        assertTrue(rec.persistedAbove(address(usdc), address(lt), x), "CONTROL: undented, the level is above");
    }

    /// @notice A zero redemption word closes both twins: the below path still guards the leg it no longer prices off.
    /// @dev Only the below path needs this guard: on the realizable path the min with zero already answers zero.
    function test_AZeroRedemptionWordClosesBothTwins() public {
        lt.setUnderlyingScale(type(uint256).max); // the mock's default redemption word, pps over this, is zero
        assertEq(lt.preview_withdraw(1e18), 0, "PREMISE: the redemption leg answers zero");
        assertGt(lt.pricePerShare(), 0, "PREMISE: the accounting rate still answers");
        assertFalse(rec.persistedBelowDistress(address(usdc), address(lt), type(uint256).max), "a zero word proves no below-ness");
        assertFalse(rec.persistedBelowSettle(address(usdc), address(lt), type(uint256).max), "on either twin");
        assertEq(rec.minPrice(address(usdc), address(lt)), 0, "and the draw cap closes");
    }

    /// @notice The rescale's overflow edge is exact on the twins: the widest word that fits referees, one past it closes both.
    function test_TheRedemptionWordsOverflowEdgeOnTheTwins() public {
        uint256 scale = rec.WITHDRAW_SCALE();
        assertEq(scale, 1e10, "PREMISE: an 8-dec underlying rescales by 1e10");
        uint256 honest = rec.minPrice(address(usdc), address(lt));
        lt.setPreviewWithdraw(type(uint256).max / scale);
        assertTrue(rec.persistedBelowDistress(address(usdc), address(lt), type(uint256).max), "the widest fitting word referees");
        assertTrue(rec.persistedBelowSettle(address(usdc), address(lt), type(uint256).max), "on both twins");
        assertEq(rec.minPrice(address(usdc), address(lt)), honest, "and the min, binding pps, prices honestly");
        lt.setPreviewWithdraw(type(uint256).max / scale + 1);
        assertFalse(rec.persistedBelowDistress(address(usdc), address(lt), type(uint256).max), "one past it closes the band's read");
        assertFalse(rec.persistedBelowSettle(address(usdc), address(lt), type(uint256).max), "and settlement's");
        assertEq(rec.minPrice(address(usdc), address(lt)), 0, "and the draw cap");
    }

    // ---- the gauge variant composes the same split ----

    /// @dev A gauge record over this LT and feed, converting at the mock's live discount.
    function _gaugeRecord() internal returns (MockYbGauge g, YbRecord r) {
        g = new MockYbGauge(address(lt));
        r = new YbRecord(address(feed), address(lt), address(g), address(usdc), address(btc), 1 hours);
    }

    /// @notice On the gauge, a dent lowers the draw cap exactly as an equal fall does, and flips neither twin where the fall flips both.
    function test_Gauge_ADentLowersTheDrawCapAndFlipsNeitherTwin() public {
        (MockYbGauge g, YbRecord r) = _gaugeRecord();
        uint256 honest = r.minPrice(address(usdc), address(g));
        assertLt(honest, rec.minPrice(address(usdc), address(lt)), "PREMISE: the conversion leg composes in");
        uint256 x = honest - honest / 100;
        lt.setPreviewWithdraw(DENTED);
        uint256 dented = r.minPrice(address(usdc), address(g));
        assertGt(dented, 0, "PREMISE: the dented gauge still prices");
        assertLt(dented, x, "PREMISE: the dent puts the draw cap under the level");
        assertEq(r.lastObserved(address(usdc), address(g)), dented, "the last print takes the dent");
        assertFalse(r.persistedAbove(address(usdc), address(g), x), "and so does the recovery read");
        assertFalse(r.persistedBelowDistress(address(usdc), address(g), x), "a dent cannot open the gauge's band");
        assertFalse(r.persistedBelowSettle(address(usdc), address(g), x), "nor its settlement");
        lt.setPreviewWithdraw(0);
        lt.setPps(0.96e18);
        assertEq(r.minPrice(address(usdc), address(g)), dented, "a 4% accounting fall prices the gauge where the dent did");
        assertTrue(r.persistedBelowDistress(address(usdc), address(g), x), "and opens the band");
        assertTrue(r.persistedBelowSettle(address(usdc), address(g), x), "and settlement");
    }

    // ---- the hub: the dent lowers the door and shields nothing ----

    /// @notice A dent refuses the fresh draw the honest print admits: the draw cap is the one read that takes it.
    function test_ADentRefusesAFreshDrawTheHonestPrintAdmits() public {
        uint256 price = ace.idToMarketParams(mid).price;
        _setHonestPrice((price * 102) / 100);
        assertGt(rec.minPrice(address(usdc), address(lt)), price, "PREMISE: the honest draw cap clears the market's price");
        address b2 = address(0xB0B2);
        lt.mint(b2, 2_000e18);
        vm.prank(b2);
        lt.approve(address(positionManager), 2_000e18);

        lt.setPreviewWithdraw(DENTED);
        assertLt(rec.minPrice(address(usdc), address(lt)), price, "PREMISE: the dented draw cap sits under it");
        vm.prank(b2);
        vm.expectRevert(InsufficientCash.selector);
        ace.open(mid, 2_000e18, 900e6, 0, b2, OpenBounds(0, 0, 0));

        lt.setPreviewWithdraw(0);
        vm.prank(b2);
        uint256 id2 = ace.open(mid, 2_000e18, 900e6, 0, b2, OpenBounds(0, 0, 0));
        assertEq(read.loan(id2).collateralUnits, 2_000e18, "CONTROL: undented, the same draw opens");
    }

    /// @notice A loan the accounting rate puts under its trigger finalizes with the pool dented through the call.
    function test_ADentCannotShieldAnHonestFallFromSettlement() public {
        uint256 trig = read.triggerPrice(loanId);
        _setHonestPrice((trig * 98) / 100);
        assertLt(_print(), trig, "PREMISE: the honest print is under the trigger");
        keeper.finalizeAttack(loanId);
        assertGt(uint256(read.loan(loanId).closedAt), 0, "the loan settles with the pool dented");
    }

    /// @notice A loan the accounting rate puts in its band deleverages with the pool dented through the call.
    function test_ADentCannotShieldAnInBandLoanFromDeleverage() public {
        uint256 trig = read.triggerPrice(loanId);
        uint256 bandLevel = FullMath.mulDivRoundingUp(trig, 1e18, 1e18 - BAND_BPS * 1e14);
        _setHonestPrice((bandLevel * 98) / 100);
        assertLt(_print(), bandLevel, "PREMISE: the honest print is in the band");
        assertGt(_print(), trig, "PREMISE: and over the trigger, so the loan is not distressed");
        (uint256 sold, uint256 stableOut) = keeper.deleverageAttack(loanId);
        assertGt(sold, 0, "the crank sells");
        assertGt(stableOut, 0, "and is paid for");
        assertEq(read.loan(loanId).collateralUnits, COLL - sold, "out of the loan's own units");
    }
}
