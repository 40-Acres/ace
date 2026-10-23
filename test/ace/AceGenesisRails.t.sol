// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.36;

import {Test} from "forge-std/Test.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {Ace} from "../../src/ace/hub/Ace.sol";
import {MarketParams} from "../../src/ace/hub/Types.sol";
import {PositionManager} from "../../src/ace/positions/PositionManager.sol";
import {Constants} from "../../src/ace/hub/Constants.sol";
import {MarketInit} from "../../src/ace/hub/MarketInit.sol";
import {PriceFrame} from "../utils/PriceFrame.sol";
import {PocDeployConfig, ProtocolPolicy} from "../../src/config/Defaults.sol";
import {AceFixtures} from "../utils/AceFixtures.sol";
import {MockPersistenceRecord} from "../mocks/MockPersistenceRecord.sol";

/// @dev createMarket reads `decimals()` off both tokens and nothing else.
contract RailToken {
    uint8 public immutable decimals;

    constructor(uint8 d) {
        decimals = d;
    }
}

/// @title AceGenesisRails
/// @notice The universal admission rails in `MarketInit.init`, proven to BITE.
/// @notice The decimal and lot-ticket rails are pinned in AceDecimalScale and AceGenesisRailGaps instead.
/// @dev `createMarket` is permissionless on an ownerless singleton, so each `require` is the only line.
/// @dev The rails were once exercised on their PASSING arm alone, which proved none of them rejects.
/// @dev Each test perturbs ONE field off an admissible baseline and pins the exact reason string.
contract AceGenesisRailsTest is Test {
    Ace internal ace;
    RailToken internal quote;
    RailToken internal collateral;
    address internal positionManager;

    function setUp() public {
        ace = AceFixtures.newAce();
        positionManager = ace.POSITION_MANAGER();
        quote = new RailToken(6);
        collateral = new RailToken(18);
    }

    /// @dev The shipped PoC economics with every seam a band-off market may leave unset.
    function _base() internal view returns (MarketParams memory p) {
        p.quote = address(quote);
        p.collateral = address(collateral);
        p.record = address(0);
        p.fillFeeBps = 25;
        p.minCoverageWad = PocDeployConfig.MIN_COVERAGE_WAD;
        p.baseBps = PocDeployConfig.BASE_BPS;
        p.minTenor = ProtocolPolicy.MIN_TENOR;
        p.maxTenor = ProtocolPolicy.MAX_TENOR;
        p.minDebt = PocDeployConfig.MIN_DEBT;
        p.settleBountyBps = PocDeployConfig.SETTLE_BOUNTY_BPS;
        /// @dev Sole tenancy: genesis refuses a zero lender, and every row here means to trip a DIFFERENT rail.
        p.lender = address(0x1E4DE2);
        /// @dev And a zero PRICE, for the same reason: a market's one bid is write-once and admitted at genesis.
        p.price = PriceFrame.px(1e18, address(quote), address(collateral));
        p.inventoryAsk = true; // the baseline carries a fill fee, which genesis admits only beside the ask
    }

    function _reject(MarketParams memory p, string memory reason) internal {
        vm.expectRevert(bytes(reason));
        ace.createMarket(p);
    }

    /// @notice THE CONTROL. Without this every test below could pass for the wrong reason.
    function test_Control_BaselineIsAdmissible() public {
        bytes32 id = ace.createMarket(_base());
        assertEq(ace.idToMarketParams(id).quote, address(quote), "the baseline really does create");
    }

    // ============ tokens and grid ============

    function test_Rail_TokensRequired() public {
        MarketParams memory p = _base();
        p.quote = address(0);
        _reject(p, "tokens required");

        p = _base();
        p.collateral = address(0);
        _reject(p, "tokens required");
    }

    function test_Rail_CollateralIsQuote() public {
        MarketParams memory p = _base();
        p.collateral = p.quote;
        _reject(p, "collateral is quote");
    }

    // DELETED with `tickSpacing`: test_Rail_BadSpacing_BothEnds pinned a grid that is gone; successors in AcePriceRail.t.sol

    /// @notice THE FEE-SHARE CEILING: no admissible market may price a term above a quarter of the draw.
    /// @notice The old rail bounded only the SIGN of the slack, so a 99%-fee market was constructible.
    /// @dev THE COUNTEREXAMPLE, pinned exactly: baseBps 200 over a 45x term multiple cleared the old rail
    /// @dev at 693e6 < 700e6, charging 99% of principal, with `payout == 0` reachable for ordinary draws.
    /// @dev It is also why a term-multiple cap cannot do this job: at M=45 this market passes one.
    function test_Rail_FeeShareCeiling_RefusesAFeeThatEatsThePrincipal() public {
        MarketParams memory p = _base();
        p.baseBps = 200;
        p.minTenor = 7 days;
        p.maxTenor = 315 days;
        _reject(p, "fee bps too high");
    }

    /// @notice The ceiling is a SHARE, so the same term multiple is admissible at a low enough rate.
    /// @dev Bounds the row above to the product rather than to either dial, which is the whole point.
    function test_Rail_FeeShareCeiling_TheSameTermMultiplePassesAtALowerRate() public {
        MarketParams memory p = _base();
        p.baseBps = 40; // the shipped rate: 40 * 45 * 11000 * 10000 <= 2500 * 1e8 * 1
        p.minTenor = 7 days;
        p.maxTenor = 315 days;
        bytes32 id = ace.createMarket(p);
        assertTrue(id != bytes32(0), "a 45x grid is fine when the rate leaves the fee inside the share");
    }

    // DELETED with the draw walk: test_Rail_TickSpacingFloor_RefusesWhereTheScanBudgetCanBind guarded a scan budget; a draw reads one price and walks nothing

    // ============ the borrow-side envelope ============

    function test_Rail_FillFeeTooHigh() public {
        MarketParams memory p = _base();
        p.fillFeeBps = 51; // MAX_FILL_FEE_BPS + 1
        _reject(p, "fill fee too high");
    }

    /// @notice THE ANTI-RAIL: the fill-fee-over-eps ratio rail is DELETED, and a deleted rail still needs a witness that it is gone.
    /// @dev The fill fee is paid by a pot's buyer and no deleverage crank reads it, so it shares no budget with eps.
    function test_AntiRail_AFillFeeOverAQuarterOfEpsIsAdmitted() public {
        MarketParams memory p = _base();
        p.deleverageFloorEpsBps = 40; // 25 * 4 == 100 > 40, which the deleted ratio rail refused
        p.deleverageBandBps = 3000;
        p.deleverageTargetBps = 4000;
        p.deleverageStopBps = 1;
        p.record = address(new MockPersistenceRecord(p.quote, p.collateral));
        assertTrue(ace.createMarket(p) != bytes32(0), "a band-on market with a fill fee over eps / 4 is admitted");
    }

    // ============ the inventory ask ============

    /// @notice An ask-off market names no fill fee: with no buyer the fee would be declared and never read.
    function test_Rail_AskOffButFillFeeSet() public {
        MarketParams memory p = _base();
        p.inventoryAsk = false;
        _reject(p, "ask off but fill fee set");
    }

    /// @notice An over-ceiling fee is refused by the CEILING's name whatever the ask says: the ceiling is asked first.
    function test_Rail_AnOverCeilingFeeOnAnAskOffMarketNamesTheCeiling() public {
        MarketParams memory p = _base();
        p.inventoryAsk = false;
        p.fillFeeBps = 51; // MAX_FILL_FEE_BPS + 1
        _reject(p, "fill fee too high");
    }

    /// @notice Ask off and fee zero is the protocol default, and genesis admits it.
    function test_Control_AnAskOffMarketWithNoFillFeeIsAdmitted() public {
        MarketParams memory p = _base();
        p.inventoryAsk = false;
        p.fillFeeBps = 0;
        bytes32 id = ace.createMarket(p);
        assertEq(ace.idToMarketParams(id).quote, address(quote), "the ask-off market really does create");
        assertFalse(ace.idToMarketParams(id).inventoryAsk, "and stores the ask as off");
    }

    /// @notice The fourth corner: ask on with no fee is admitted too, so the rail is the one pairing and nothing wider.
    function test_Control_AnAskOnMarketWithNoFillFeeIsAdmitted() public {
        MarketParams memory p = _base();
        p.fillFeeBps = 0;
        bytes32 id = ace.createMarket(p);
        assertTrue(ace.idToMarketParams(id).inventoryAsk, "an ask-on market needs no fee to exist");
    }

    /// @notice THE WHOLE TABLE: every fill fee the ceiling admits and one past it, under both settings of the ask.
    /// @dev Ask off admits a zero fee alone: ONE basis point is already the pairing's refusal, and past the ceiling the ceiling's name wins.
    /// @dev Ask on admits every fee up to the ceiling. The fee is a word of the id, so each admitted market is a fresh one.
    function test_Rail_TheAskPairingOverEveryFillFee() public {
        uint256 ceiling = 50; // MAX_FILL_FEE_BPS, re-spelled as the rows above re-spell it
        for (uint256 fee; fee <= ceiling + 1; fee++) {
            MarketParams memory p = _base();
            p.fillFeeBps = fee;
            if (fee > ceiling) _reject(p, "fill fee too high");
            else assertEq(ace.idToMarketParams(ace.createMarket(p)).fillFeeBps, fee, "ask on: a fee inside the ceiling is admitted and stored");
            p.inventoryAsk = false;
            if (fee > ceiling) _reject(p, "fill fee too high");
            else if (fee != 0) _reject(p, "ask off but fill fee set");
            else assertFalse(ace.idToMarketParams(ace.createMarket(p)).inventoryAsk, "ask off: the zero fee alone is admitted, and stored off");
        }
    }

    // ============ the tenor grid ============

    // DELETED with the tenor grid: the spacing and rung-count rails; consent is `maxTenor` alone, and its two survivors are the rows above

    // ============ claim-tick co-sizing ============

    /// @dev THE SIX ROLLOVER RAILS ARE DELETED with the six params they bounded.
    /// @dev They were RollBountyTooHigh, RollRunwayTooHigh, RollTargetTooHigh and RollWindowTooLong.
    /// @dev And WindowMinOverMax and WindowSlopeTooHigh, which bounded the health-adaptive window.
    /// @dev The two below replaced them in the same genesis pass and are their successors here.
    /// @dev Their full behaviour lives in `AceCoSizing.t.sol`; these two pin the rail STRINGS.

    /// @notice THE ANTI-RAIL, kept as a row because a deleted rail still needs a witness that it is gone.
    /// @notice The once-inverted pair is ADMITTED, and `minDebt` covers its own floor by construction.
    /// @dev Nothing weakened: the invariant is asserted here, it is simply no longer a rail's job.
    /// @dev IT USED TO BE A PRODUCT -- `maxClaimTicks * ceil(minDebt / maxClaimTicks) >= minDebt` -- because a
    /// @dev draw reached the floor from many lots. One bucket makes the deposit floor and the draw floor the
    /// @dev same number, so the inversion the rail guarded against is not expressible rather than merely unrailed.
    function test_NoRail_TheDepositFloorIsTheDrawFloorAndCoversIt() public {
        MarketParams memory p = _base();
        p.minDebt = 5_000e6; // the old inversion: a wide spread at the creator's 10e6 funded a fraction of it
        bytes32 id = ace.createMarket(p);

        assertEq(ace.idToMarketParams(id).minDebt, 5_000e6, "genesis admits what it used to refuse");
        assertGe(ace.idToMarketParams(id).minDebt, p.minDebt, "and the one floor covers itself, with no product to invert");
    }

    /// @dev DELETED: `test_Rail_ClaimCapOverGasCeiling`. `maxClaimTicks` bounded how many ticks one draw could
    /// @dev fund, and the rail existed because the settlement walk over that list is unbounded gas. There is no
    /// @dev list: a loan holds one claim, so the ceiling has nothing to bound and the gas it protected is O(1).

    // DELETED with `maxClaimTicks`: test_Rail_ClaimCapZero guarded a division by the cap, and one claim divides by nothing

    /// @notice A zero borrower quantum derives a zero lender ticket, so one wei of dust books at any tick.
    /// @notice It also lets a draw fund nothing, leaving a live loan with no funding floor for a guard to read.
    function test_Rail_MinDebtZero() public {
        MarketParams memory p = _base();
        p.minDebt = 0;
        _reject(p, "min debt zero");
    }

    /// @notice One wei is REFUSED, and two is admitted: the floor is IMPLIED, never a calibrated number.
    /// @notice A one-wei market admits a one-wei draw whose fee CEILS to the whole wei, paying nothing.
    /// @dev This row asserted the opposite until the fee ceiling landed, when `minDebt = 1` stayed legal.
    /// @dev The rail is still structural -- it derives the floor from the fee rather than picking one.
    /// @dev At every rate the share bound admits, that derivation lands on exactly 2 wei.
    function test_Rail_MinDebtOneWeiIsRefusedAndTwoIsAdmitted() public {
        MarketParams memory p = _base();
        p.minDebt = 1;
        _reject(p, "min debt under fee");

        p = _base();
        p.minDebt = 2;
        assertTrue(ace.createMarket(p) != bytes32(0), "the quantum is the creator's, anywhere the fee leaves change");
    }

    // ============ fee splits and windows ============

    /// @notice The bounty's old degenerate end handed the keeper the WHOLE position, lenders' claims included.
    /// @notice Settlement is a title transfer, so the ceiling is all that bounds what a creator may promise.
    /// @notice The ceiling is DERIVED, not chosen: coverage survives the sliver iff `b <= k - 1`.
    /// @notice That must hold at every admissible k, so MIN_K = 1.05 binds it to 500 bps; 200 sits 2.5x inside.
    function test_Rail_SettleBpsTooHigh() public {
        MarketParams memory p = _base();
        p.settleBountyBps = 10000; // the old degenerate end, now refused
        _reject(p, "settle bps too high");

        p.settleBountyBps = 501; // past the k-1 bound at MIN_K, so past any safe ceiling
        _reject(p, "settle bps too high");

        p.settleBountyBps = 201; // one past the shipped ceiling
        _reject(p, "settle bps too high");

        p.settleBountyBps = 200; // the ceiling itself is admissible
        ace.createMarket(p);
    }

    /// @dev NO WINDOW RAIL HERE any more: the window left `MarketParams`, so genesis has no value to bound.
    /// @dev Both ends moved onto the record's own constructor and are pinned by `PersistenceRecordWindowsTest`.

    // ============ deleverage seams ============

    /// @dev The decline channel prices its disposal off the record: banded without one, it can never quote a sale.
    function test_Rail_DeleverageRequiresARecord() public {
        MarketParams memory p = _base();
        p.deleverageBandBps = 3000;
        p.deleverageTargetBps = 4000;
        p.deleverageStopBps = 1;
        _reject(p, "record required");
    }

    /// @dev The lie-guard: declared-but-unread fields on an immutable preimage are a lie.
    function test_Rail_DeleverageOffButStopOrCutSet() public {
        MarketParams memory p = _base();
        p.deleverageStopBps = 1; // band is 0, so the channel is off and this is decoration
        _reject(p, "deleverage off but dials set");

        p = _base();
        p.deleverageProtocolBps = 1;
        _reject(p, "deleverage off but dials set");
    }

    /// @notice The same guard over the other two dials a band-off market never reads: the restore target and eps.
    /// @dev Unread off-channel, yet the cross-market equality rail compares them, so admitting one forked a market's id and its routing.
    /// @dev eps 200 is its own ceiling, so the ceiling passes and THIS rail must be what refuses it.
    function test_Rail_DeleverageOffButTargetOrEpsSet() public {
        MarketParams memory p = _base();
        p.deleverageTargetBps = 1;
        _reject(p, "deleverage off but dials set");

        p = _base();
        p.deleverageTargetBps = type(uint256).max; // no ceiling reaches the target with the band off
        _reject(p, "deleverage off but dials set");

        p = _base();
        p.deleverageFloorEpsBps = 1;
        _reject(p, "deleverage off but dials set");

        p = _base();
        p.deleverageFloorEpsBps = Constants.MAX_DELEVERAGE_FLOOR_EPS_BPS;
        _reject(p, "deleverage off but dials set");
    }

    /// @notice THE GUARD'S SCOPE: with the band ON, all four dials nonzero is the ordinary shape, and genesis admits it whole.
    /// @dev The fixed band-on admits in the keeper-budget rows leave the cut at zero, so a cut check leaking out of the else-arm met only a sampler's count.
    /// @dev eps is the shipped policy value, which no ratio to the fill fee binds.
    function test_Control_ABandOnMarketWithEveryDialSetIsAdmitted() public {
        MarketParams memory p = _base();
        p.deleverageBandBps = Constants.MIN_DELEVERAGE_BAND_BPS;
        p.deleverageTargetBps = 4000;
        p.deleverageStopBps = 1000;
        p.deleverageProtocolBps = 500;
        p.deleverageFloorEpsBps = ProtocolPolicy.DELEVERAGE_FLOOR_EPS_BPS;
        p.record = address(new MockPersistenceRecord(p.quote, p.collateral));
        bytes32 id = ace.createMarket(p);

        MarketParams memory s = ace.idToMarketParams(id);
        assertEq(s.deleverageBandBps, 3000, "the band is stored on");
        assertEq(s.deleverageTargetBps, 4000, "the target is stored as given");
        assertEq(s.deleverageStopBps, 1000, "the stop is stored as given");
        assertEq(s.deleverageProtocolBps, 500, "the cut is stored as given");
        assertEq(s.deleverageFloorEpsBps, 100, "eps is stored as given");
    }

    // ============ the collateral factor, the fee rate and the tenor grid ============

    /// @notice `k` bounds the over-collateralization multiple, and MIN_K is load-bearing for a neighbour.
    /// @dev MAX_SETTLE_BOUNTY_BPS is DERIVED from it: coverage survives the sliver iff `b <= k - 1`.
    /// @dev So an admitted `k <= 1` would silently invalidate that ceiling instead of failing here.
    function test_Rail_KOutOfBand_BothEnds() public {
        MarketParams memory p = _base();
        p.minCoverageWad = 1.05e18 - 1; // MIN_COVERAGE_WAD - 1
        _reject(p, "min coverage out of band");

        p = _base();
        p.minCoverageWad = 20e18 + 1; // MAX_COVERAGE_WAD + 1
        _reject(p, "min coverage out of band");

        p = _base();
        p.minCoverageWad = 1.05e18; // MIN_COVERAGE_WAD itself admits, so the two rejections above are not vacuous
        ace.createMarket(p);
    }

    /// @notice `baseBps` is the LENDER's origination rate, and this rail is its FLOOR alone.
    /// @dev Zero is refused deliberately: a market with no origination premium pays its lenders nothing.
    function test_Rail_BaseBpsBelowFloor() public {
        MarketParams memory p = _base();
        p.baseBps = 0; // MIN_BASE_BPS is 1
        _reject(p, "base bps out of band");

        p = _base();
        p.baseBps = 1; // the floor itself admits
        ace.createMarket(p);
    }

    /// @notice THE ONLY CEILING ON THE RATE IS THE FEE-VS-PRINCIPAL RAIL, and this row is where that is said.
    /// @notice The fixture is single-tenor, so the tenor cancels in `feeFundable` and the boundary is an exact integer.
    /// @dev 2272 and 2273 are LITERALS: a mirror of the implementation cannot disagree with it.
    /// @dev So this row is the tripwire if `MAX_FEE_SHARE_BPS` or `PROTOCOL_SHARE_BPS` ever moves.
    function test_Rail_FeeShareIsTheOnlyCeiling() public {
        MarketParams memory p = _base();
        p.baseBps = 501; // what the deleted per-term band used to refuse, and an ordinary rate now
        ace.createMarket(p);

        p = _base();
        p.baseBps = 2272; // `b * 11000 <= 2500 * 10000` at minTenor == maxTenor
        ace.createMarket(p);

        p = _base();
        p.baseBps = 2273;
        _reject(p, "fee bps too high");
    }

    /// @notice A zero tenor is refused HERE, BY NAME: no other rail names it, and one later rail divides by it.
    /// @dev With min == max == 0 the fee rail reads `0 <= 0` and passes, then `min debt under fee` divides by `minTenor`.
    /// @dev So the rail's ORDER is load-bearing: moved below that rail, the first case reverts with EMPTY data instead.
    /// @dev Zero is caught by the derived tenor floor, which subsumes the old zero-only rail; this row keeps the degenerate end.
    function test_Rail_TenorZero() public {
        MarketParams memory p = _base();
        p.minTenor = 0; // the fully degenerate grid FIRST: the one no neighbour refuses by name
        p.maxTenor = 0;
        _reject(p, "min tenor under floor");

        p = _base();
        p.minTenor = 0; // min alone, where the fee rail would also catch it under a different name
        _reject(p, "min tenor under floor");
    }

    /// @dev The floor re-derived here from all three divisors, independent of the constant: the larger of the two legs that can reach zero.
    function _derivedFloor() private pure returns (uint64) {
        uint64 roll = Constants.AUTO_REFINANCE_WINDOW_DIVISOR * Constants.AUTO_ROLL_HOME_SHARE_DIVISOR;
        return roll > Constants.INVENTORY_HOLD_DIVISOR ? roll : Constants.INVENTORY_HOLD_DIVISOR;
    }

    /// @notice THE TENOR FLOOR IS DERIVED, not picked: the smallest `minTenor` at which no tenor-derived window is zero.
    /// @notice It is spelled here from the three divisors, never read off the constant, so a retune of any one moves this row with it.
    /// @dev min == max throughout, so the fee rail cancels the tenor and cannot refuse the short market first.
    function test_Rail_MinTenorFloor_RefusesOneUnderAndAdmitsTheFloor() public {
        uint64 floor = _derivedFloor();
        MarketParams memory p = _base();
        (p.minTenor, p.maxTenor) = (floor - 1, floor - 1);
        _reject(p, "min tenor under floor");

        p = _base();
        (p.minTenor, p.maxTenor) = (floor, floor);
        bytes32 id = ace.createMarket(p);
        assertEq(ace.idToMarketParams(id).minTenor, floor, "the floor itself is admissible");
    }

    /// @notice AT THE FLOOR EVERY TENOR-DERIVED WINDOW IS AT LEAST ONE SECOND, which is the whole reason it exists.
    /// @notice One under it some hold is zero, so the floor is TIGHT rather than merely safe.
    /// @dev Tightness is asserted over BOTH holds, so it survives a retune that makes the inventory leg the binding one.
    function test_MinTenorFloor_EveryDerivedWindowIsAtLeastASecondThere() public pure {
        uint64 floor = _derivedFloor();
        assertGe(MarketInit.autoRefinanceWindow(floor), 1, "the roll window opens before expiry");
        assertGe(MarketInit.homeRollHold(floor), 1, "a stranger may route in the window's trailing second, before expiry");
        assertGe(MarketInit.inventoryHold(floor), 1, "settled inventory rests before its ask opens");
        bool someZero = MarketInit.homeRollHold(floor - 1) == 0 || MarketInit.inventoryHold(floor - 1) == 0;
        assertTrue(someZero, "one under the floor a hold is zero: no smaller floor works");
    }

    /// @notice An inverted tenor grid is refused BY NAME rather than by an arithmetic panic.
    /// @dev Without it `maxTenor - minTenor` underflows at the spacing rail: same refusal, worse report.
    function test_Rail_MaxTenorBelowMin() public {
        MarketParams memory p = _base();
        p.maxTenor = p.minTenor - 1;
        _reject(p, "max tenor below min");
    }
}
