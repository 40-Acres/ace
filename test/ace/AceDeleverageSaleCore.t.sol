// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.36;

import {Test, stdError} from "forge-std/Test.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {Ace} from "../../src/ace/hub/Ace.sol";
import {MarketParams, OpenBounds} from "../../src/ace/hub/Types.sol";
import {NoRecordPrice} from "../../src/ace/hub/Borrower.sol";
import {GUARD_TRIP} from "../utils/GuardTrip.sol";
import {PositionManager} from "../../src/ace/positions/PositionManager.sol";
import {FullMath} from "@uniswap/v4-core/src/libraries/FullMath.sol";
import {MockERC20} from "../mocks/MockERC20.sol";
import {MockPersistenceRecord} from "../mocks/MockPersistenceRecord.sol";
import {MockDeleverageKeeper} from "../mocks/MockDeleverageKeeper.sol";
import {MockStakeVault} from "../mocks/MockStakeVault.sol";
import {AceFixtures} from "../utils/AceFixtures.sol";
import {AceReader} from "../utils/AceReader.sol";

/// @notice A keeper that hands back MORE collateral than it was released.
/// @dev The hub sizes a refund as its OWN balance delta, so an over-return and a donation are one event to it.
contract DonatingDeleverageKeeper is MockDeleverageKeeper {
    uint256 public donation; // units returned on top of every released unit

    constructor(Ace a, address q, address c, uint256 s) MockDeleverageKeeper(a, q, c, s) {}

    function armDonation(uint256 v) external {
        donation = v;
    }

    /// @dev Approves nothing: a wholly refused fill owes nothing, so a payment leg would blur which guard fired.
    function onAceDeleverage(uint256 unitsSold, uint256 quoteOwed, bytes calldata) external override {
        lastUnitsSold = unitsSold;
        lastQuoteOwed = quoteOwed;
        COLLATERAL.transfer(msg.sender, unitsSold + donation);
    }
}

/// @notice A keeper that RE-ENTERS the hub from inside the callback and hands over nothing.
/// @dev The lending review ranked the original BLOCKING: it deposited mid-callback, so the hub's quote
/// @dev balance rose by exactly the floor and a collection measuring a balance delta would have read the
/// @dev deposit as payment, releasing the units for free.
/// @dev THAT ATTACK IS NOW DOUBLY CLOSED, and the second lock is structural: sole tenancy refuses a
/// @dev deposit from anyone but the market's named lender, so a keeper cannot make one at any time.
/// @dev The MUTEX still has to be pinned on its own, or its removal would go unnoticed behind that.
/// @dev So the re-entrant verb is `collect`, which this keeper may legitimately call -- it spends the
/// @dev caller's own pool, and is guarded. Outside a crank it works; inside it must not.
contract ReenteringDeleverageKeeper is MockDeleverageKeeper {
    bool public approvePull; // honour the pull as well, so exact-pull cannot be what refuses

    constructor(Ace a, address q, address c, uint256 s) MockDeleverageKeeper(a, q, c, s) {}

    function setApprovePull(bool v) external {
        approvePull = v;
    }

    /// @dev The SAME call made outside a crank: the control proving this door is genuinely open.
    function collectDirect() external returns (uint256) {
        return ACE.collect(QUOTE, address(this));
    }

    function onAceDeleverage(uint256 unitsSold, uint256 quoteOwed, bytes calldata) external override {
        lastUnitsSold = unitsSold;
        lastQuoteOwed = quoteOwed;
        MockERC20(QUOTE).mint(address(this), approvePull ? quoteOwed * 2 : quoteOwed);
        IERC20(QUOTE).approve(address(ACE), type(uint256).max);
        ACE.collect(QUOTE, address(this)); // guarded, so the lock refuses it whatever it would have moved
        if (!approvePull) IERC20(QUOTE).approve(address(ACE), 0);
    }
}

/// @title AceDeleverageSaleCoreTest
/// @notice The shared sale core reached through `deleverage` alone, with no skim verb anywhere.
/// @notice Covers the balance-delta fill, the tail re-credit, the donation clamp, the two-leg floor and the owed ceil.
/// @dev These helpers were exercised MAINLY through the rate skim suite, which the skim deletion removes.
/// @dev They outlive it, so this coverage has to: every market here is a plain banded one, the surviving shape.
/// @dev The file name carries no `Skim` token deliberately, so a name-matching deletion sweep cannot take it.
contract AceDeleverageSaleCoreTest is Test {
    Ace internal ace;
    PositionManager internal positionManager;
    AceReader internal read;
    MockERC20 internal usdc;
    MockStakeVault internal vault;
    MockPersistenceRecord internal record;
    MockDeleverageKeeper internal keeper;
    bytes32 internal id;

    address internal alice = address(0xA11CE);
    address internal borrower = address(0xB0B);

    uint256 internal constant COLL = 10_000e18;
    uint256 internal constant PRINCIPAL = 4_500e6;
    uint256 internal P; // healthy market price, two quote per whole collateral; framed in setUp
    uint256 internal PS_BAND; // inside the band, well above the stop
    uint256 internal constant UNIT_SCALE = 1 << 96; // every market's scale under the atom frame
    uint256 internal constant EPS = 100;
    uint256 internal constant BAND_BPS = 3000;
    uint256 internal constant TARGET_BPS = 4000;
    uint256 internal DEEP_TICK; // ~0.6977 of par, under PS_BAND: a deposit here is admissible mid-band

    /// @dev This suite's pair, so a tick reads as its distance from par rather than as a grid coordinate.
    /// @param offset Ticks above par.
    /// @return The absolute grid tick.
    function _price(int24 offset) internal view returns (uint256) {
        return AceFixtures.priceAt(address(usdc), address(vault), offset);
    }

    function setUp() public {
        usdc = new MockERC20("USD Coin", "USDC", 6);
        vault = new MockStakeVault(42);
        DEEP_TICK = _price(-3600);
        P = AceFixtures.px(2e18, address(usdc), address(vault));
        PS_BAND = AceFixtures.px(0.7e18, address(usdc), address(vault));
        record = new MockPersistenceRecord(address(usdc), address(vault));
        record.setMinPrice(P);

        AceFixtures.Deployment memory d = AceFixtures.deploy(_paramsWith(address(record)));
        (ace, positionManager, read, id) = (d.ace, d.positionManager, d.read, d.id);
        keeper = new MockDeleverageKeeper(ace, address(usdc), address(vault), UNIT_SCALE);

        _seedLender(ace, id);
    }

    /// @dev The decline channel on: the one sale shape there is.
    function _paramsWith(address rec) internal view returns (MarketParams memory p) {
        p = AceFixtures.marketParams(address(usdc), address(vault));
        p.record = rec;
        p.deleverageFloorEpsBps = EPS;
        p.deleverageBandBps = BAND_BPS;
        p.deleverageTargetBps = TARGET_BPS;
        p.deleverageStopBps = 1; // tiny: keeps the near-trigger fixtures admitted, and leaves the cut at 0
    }

    function _seedLender(Ace hub, bytes32 mid) internal {
        usdc.mint(alice, 15_000e6);
        vm.startPrank(alice);
        usdc.approve(address(hub), 15_000e6);
        hub.deposit(mid, 15_000e6);
        vm.stopPrank();
    }

    function _open() internal returns (uint256 loanId) {
        return _openOn(ace, id, positionManager);
    }

    function _openOn(Ace hub, bytes32 mid, PositionManager pm) internal returns (uint256 loanId) {
        vault.mint(borrower, COLL);
        vm.startPrank(borrower);
        vault.approve(address(pm), COLL);
        loanId = hub.open(mid, COLL, PRINCIPAL, 0, borrower, OpenBounds(0, 0, 0));
        vm.stopPrank();
    }

    /// @dev Put the record in the band at `ps`, which is the one number that both sizes the sale and floors the fill.
    function _enterBand(uint256 loanId, uint256 ps) internal {
        _enterBandOn(read, record, loanId, ps);
    }

    function _enterBandOn(AceReader r, MockPersistenceRecord rec, uint256 loanId, uint256 ps) internal {
        uint256 trig = r.triggerPrice(loanId);
        rec.setBelowBand(FullMath.mulDivRoundingUp(trig, 1e18, 1e18 - BAND_BPS * 1e14));
        rec.setMinPrice(ps);
    }

    /// @dev What `_owed` must return: an INDEPENDENT restatement of the ceil, never a call back into the hub.
    function _owedExact(uint256 units, uint256 floorPrice) internal pure returns (uint256) {
        uint256 den = 10000 * UNIT_SCALE;
        return (units * floorPrice * (10000 - EPS) + den - 1) / den;
    }

    // ============ 1. `_dispose` measures the fill, it does not assume it ============

    /// @notice The hub prices the pull on what the balance delta says FILLED, never on what it released.
    /// @dev A half refund makes the two numbers differ, so a `filled = d.unitsSold` mutation overcharges.
    function test_Dispose_PricesThePullOnTheMeasuredFill_NotTheRelease() public {
        uint256 loanId = _open();
        _enterBand(loanId, PS_BAND);
        keeper.setRefundBps(5000);

        (uint256 filled, uint256 out) = keeper.crankDeleverage(loanId);

        uint256 released = keeper.lastUnitsSold();
        uint256 refund = (released * 5000) / 10000;
        assertGt(refund, 0, "fixture: a real tail came back, so release and fill differ");
        assertEq(filled, released - refund, "the fill is the balance delta, not the release");
        assertEq(out, _owedExact(filled, PS_BAND), "and the pull is priced on the fill");
        assertLt(out, _owedExact(released, PS_BAND), "non-vacuity: pricing the release would have charged strictly more");
    }

    /// @notice A full fill routes through the same measurement: a zero delta means a zero refund.
    function test_Dispose_FullFill_MeasuresZeroRefund_AndChargesTheWholeRelease() public {
        uint256 loanId = _open();
        _enterBand(loanId, PS_BAND);
        uint256 hubBefore = vault.balanceOf(address(ace));

        (uint256 filled, uint256 out) = keeper.crankDeleverage(loanId);

        assertEq(filled, keeper.lastUnitsSold(), "nothing came back, so the fill is the whole release");
        assertEq(out, _owedExact(filled, PS_BAND), "priced on it exactly");
        assertEq(vault.balanceOf(address(ace)), hubBefore, "and the hub holds no collateral of its own afterwards");
        assertEq(vault.balanceOf(address(keeper)), filled, "the keeper kept exactly the units it paid for");
    }

    // ============ 2. `_recreditRefund` returns the unsold tail, exactly ============

    /// @notice The tail lands back on BOTH ledgers: the loan's unit count and real custody.
    /// @dev Asserting only `collateralUnits` would survive a deleted `pull`, with the units stranded in the hub.
    function test_Recredit_PartialFill_ReturnsTheTailToTheLoanAndToCustody() public {
        uint256 loanId = _open();
        _enterBand(loanId, PS_BAND);
        uint256 hubBefore = vault.balanceOf(address(ace));
        keeper.setRefundBps(4000);

        (uint256 filled,) = keeper.crankDeleverage(loanId);

        uint256 released = keeper.lastUnitsSold();
        assertGt(released, filled, "fixture: the route really refused part of it");
        assertEq(read.loan(loanId).collateralUnits, COLL - filled, "the loan is debited by the FILL, not the release");
        assertEq(positionManager.collateralOf(loanId), COLL - filled, "and custody holds exactly that");
        assertEq(vault.balanceOf(address(ace)), hubBefore, "the hub strands none of the tail on the way through");
        assertEq(vault.balanceOf(address(keeper)), filled, "the keeper kept only what it filled");
    }

    /// @notice The re-credit is exact across the whole refund range, not just at one convenient share.
    /// @dev Fuzzed on the SHARE: a test cannot know the sized units up front, and a second loan is no control.
    function testFuzz_Recredit_TailIsExactAtEveryRefundShare(uint256 shareSeed) public {
        uint256 share = bound(shareSeed, 0, 9999);
        uint256 loanId = _open();
        _enterBand(loanId, PS_BAND);
        uint256 hubBefore = vault.balanceOf(address(ace));
        keeper.setRefundBps(share);

        (uint256 filled, uint256 out) = keeper.crankDeleverage(loanId);

        uint256 released = keeper.lastUnitsSold();
        assertEq(filled, released - (released * share) / 10000, "the fill is the release less the measured tail");
        assertEq(read.loan(loanId).collateralUnits, COLL - filled, "the loan carries the tail again");
        assertEq(positionManager.collateralOf(loanId), COLL - filled, "custody agrees");
        assertEq(vault.balanceOf(address(ace)), hubBefore, "nothing strands in the hub at any share");
        assertEq(out, _owedExact(filled, PS_BAND), "and the pull tracks the fill at every share");
    }

    /// @notice A wholly refused fill is an exact no-op through the whole sale core.
    function test_Recredit_WhollyRefused_LeavesEveryLedgerWhole() public {
        uint256 loanId = _open();
        _enterBand(loanId, PS_BAND);
        uint256 debt0 = read.debtOf(loanId);
        uint256 hubBefore = vault.balanceOf(address(ace));
        keeper.setRefundBps(10000);

        (uint256 filled, uint256 out) = keeper.crankDeleverage(loanId);

        assertEq(filled, 0, "nothing filled");
        assertEq(out, 0, "so nothing was owed and nothing pulled");
        assertEq(read.loan(loanId).collateralUnits, COLL, "the position is whole");
        assertEq(positionManager.collateralOf(loanId), COLL, "custody is whole");
        assertEq(read.debtOf(loanId), debt0, "and no debt melted");
        assertEq(vault.balanceOf(address(ace)), hubBefore, "the hub kept nothing back");
    }

    // ============ 3. the donation clamp ============

    /// @notice A keeper returning MORE than it was released must not underflow `filled`.
    /// @dev SOL-AM-DA-1: internal accounting and a balance read disagree here by construction.
    /// @dev Without the clamp `unitsSold - refund` reverts, and anyone giving away a wei can grief the channel.
    function test_Recredit_DonationBeyondTheSale_IsClamped_NotUnderflowed() public {
        uint256 loanId = _open();
        _enterBand(loanId, PS_BAND);
        DonatingDeleverageKeeper k = new DonatingDeleverageKeeper(ace, address(usdc), address(vault), UNIT_SCALE);
        uint256 donation = 1e18;
        vault.mint(address(k), donation);
        uint256 debt0 = read.debtOf(loanId);
        uint256 hubBefore = vault.balanceOf(address(ace));
        k.armDonation(donation);

        (uint256 filled, uint256 out) = k.crankDeleverage(loanId);

        assertGt(k.lastUnitsSold(), 0, "fixture: a real sale was released, so the clamp had something to clamp");
        assertEq(filled, 0, "everything came back, so nothing filled");
        assertEq(out, 0, "and nothing was owed");
        assertEq(read.loan(loanId).collateralUnits, COLL, "the loan keeps every unit it had");
        assertEq(read.debtOf(loanId), debt0, "no debt melted");
        assertEq(vault.balanceOf(address(ace)) - hubBefore, donation, "the excess strands in the hub, never credited to the loan");
        assertEq(positionManager.collateralOf(loanId), COLL, "and custody took back the released units, not the donation");
    }

    /// @notice One wei over the sale is enough: the clamp is a boundary, not a tolerance.
    function test_Recredit_DonationOfOneWei_IsStillClamped() public {
        uint256 loanId = _open();
        _enterBand(loanId, PS_BAND);
        DonatingDeleverageKeeper k = new DonatingDeleverageKeeper(ace, address(usdc), address(vault), UNIT_SCALE);
        vault.mint(address(k), 1);
        k.armDonation(1);

        (uint256 filled,) = k.crankDeleverage(loanId);

        assertEq(filled, 0, "a single wei over the sale must not underflow the fill");
        assertEq(read.loan(loanId).collateralUnits, COLL, "and the loan is untouched");
    }

    // ============ 4. the floor IS the sizing price: ONE number, not the higher of two ============

    /// @notice The disposal floor is the record's windowed minimum, which is the same read that sized the sale.
    /// @dev Non-vacuity is stated against a one-wei floor, so a mutant reading anything but the record price is caught.
    function test_Floor_IsTheRecordsWindowedMinimum() public {
        uint256 loanId = _open();
        _enterBand(loanId, PS_BAND);

        (uint256 filled, uint256 out) = keeper.crankDeleverage(loanId);

        assertGt(filled, 0, "the crank ran");
        assertEq(out, _owedExact(filled, PS_BAND), "the floor is the record's windowed minimum");
        assertGt(out, _owedExact(filled, 1), "non-vacuity: a floor read from anywhere near zero would have priced it lower");
    }

    /// @notice THE COLLAPSE, stated as an identity: the price that SIZED the sale is the price the keeper PAYS.
    /// @notice The head sits far ABOVE the window here, so a floor reading the head instead of the minimum is caught.
    /// @dev `lastObserved` is left at the healthy `P` while `minPrice` walks into the band, so the two genuinely differ.
    /// @dev Under the retired two-leg floor this assertion would have failed: the higher leg won.
    function test_Floor_EqualsTheSizingPrice_EvenWhileTheHeadSitsAboveTheWindow() public {
        uint256 loanId = _open();
        _enterBand(loanId, PS_BAND);
        record.setObserved(P); // the head stays healthy: only the WINDOW walked down

        assertGt(record.lastObserved(address(usdc), address(vault)), record.minPrice(address(usdc), address(vault)), "fixture: head above window");

        (uint256 filled, uint256 out) = keeper.crankDeleverage(loanId);

        assertGt(filled, 0, "the crank ran");
        assertEq(out, _owedExact(filled, PS_BAND), "the floor is the windowed minimum, never the head");
        assertLt(out, _owedExact(filled, P), "non-vacuity: pricing off the head would have charged strictly more");
    }

    /// @notice Fuzzed across the whole band: the per-unit floor tracks the record price the sale was sized at, exactly.
    /// @dev The sized quantity moves with the record, so the invariant is stated per unit rather than in total.
    function testFuzz_Floor_TracksTheSizingPriceAcrossTheBand(uint256 psSeed) public {
        uint256 loanId = _open();
        uint256 trig = read.triggerPrice(loanId);
        uint256 ps = bound(psSeed, trig + trig / 100, (trig * 1e18) / (1e18 - BAND_BPS * 1e14) - 1);
        _enterBand(loanId, ps);

        (uint256 filled, uint256 out) = keeper.crankDeleverage(loanId);

        assertGt(filled, 0, "the crank ran across the band");
        assertEq(out, _owedExact(filled, ps), "one number sizes the sale and prices the fill, at every point in the band");
    }

    /// @notice A record that cannot price is refused twice over: once at genesis, once at the sizing read.
    /// @dev Genesis rejects an unwired record under a live band, so the channel never ships without one.
    /// @dev A wired record that goes dark is refused by name at the sizing read, which is also the floor read.
    function test_Deleverage_RefusesAnUnwiredRecordAtGenesis_AndAZeroPricedOneAtTheSizingRead() public {
        Ace hub = AceFixtures.newAce();
        MarketParams memory p = _paramsWith(address(0));
        vm.expectRevert("record required"); // an unwired record under a live band
        hub.createMarket(p);

        uint256 loanId = _open();
        _enterBand(loanId, PS_BAND);
        record.setMinPrice(0); // the wired record goes dark

        vm.expectRevert(NoRecordPrice.selector);
        keeper.crankDeleverage(loanId); // `deleverage`'s own sizing guard, which IS the fill floor's read
    }

    // ============ 5. `_owed` ceils, to the wei ============

    /// @notice The payer never rounds in their own favour: the owed amount is the ceil, exactly.
    /// @dev The remainder assertion is load-bearing here, not decoration.
    /// @dev A rounding pin on a fixture where the division is exact passes under either rule and proves nothing.
    function test_Owed_CeilsAgainstThePayer_ToTheWei() public {
        uint256 loanId = _open();
        _enterBand(loanId, PS_BAND);

        (uint256 filled, uint256 out) = keeper.crankDeleverage(loanId);

        uint256 num = filled * PS_BAND * (10000 - EPS);
        uint256 den = 10000 * UNIT_SCALE;
        assertGt(num % den, 0, "fixture control: the division has a remainder, so ceil and floor really differ");
        assertEq(out, num / den + 1, "the owed amount is the floor plus one, not the floor");
        assertEq(out, _owedExact(filled, PS_BAND), "and matches the independent restatement");
    }

    /// @notice The ceil holds at every fill size the channel can produce, stated as its definition.
    /// @dev `out` is the least integer whose scaled value covers the sale: one wei less does not.
    function testFuzz_Owed_IsTheLeastCoveringInteger(uint256 shareSeed) public {
        uint256 share = bound(shareSeed, 0, 9000);
        uint256 loanId = _open();
        _enterBand(loanId, PS_BAND);
        keeper.setRefundBps(share);

        (uint256 filled, uint256 out) = keeper.crankDeleverage(loanId);

        assertGt(filled, 0, "fixture: every admitted share still fills something");
        uint256 num = filled * PS_BAND * (10000 - EPS);
        uint256 den = 10000 * UNIT_SCALE;
        assertGe(out * den, num, "the payer covers the sale");
        assertLt((out - 1) * den, num, "and pays the least amount that does");
    }

    // ============ 6. the collection discipline: the hub PULLS, it never reads a balance ============

    /// @notice THE EXPLOIT the lending review ranked blocking, re-aimed at the surviving channel.
    /// @notice A keeper deposits the floor into the hub mid-callback and approves nothing for the pull.
    /// @dev A keeper re-entering the hub mid-callback and paying nothing takes the whole crank down.
    /// @dev It is refused, nothing moves, and the thief keeps neither the units nor anything at the tick.
    function test_Dispose_AKeeperReenteringMidCallbackAndPayingNothing_IsRefused() public {
        uint256 loanId = _open();
        _enterBand(loanId, PS_BAND);
        ReenteringDeleverageKeeper k = new ReenteringDeleverageKeeper(ace, address(usdc), address(vault), UNIT_SCALE);

        vm.expectRevert(GUARD_TRIP);
        k.crankDeleverage(loanId);

        assertEq(read.loan(loanId).collateralUnits, COLL, "no units left the loan");
        assertEq(positionManager.collateralOf(loanId), COLL, "and custody still holds them");
        assertEq(vault.balanceOf(address(k)), 0, "the thief holds no collateral");
        /// @dev WAS `restingOf == 0` at the tick the attacker aimed a deposit at. One market holds one
        /// @dev balance, so a zero there is the rig's whole depth rather than the attacker's leg; what
        /// @dev says nothing of theirs survived is that the market is EXACTLY where the setUp left it.
        assertEq(ace.restingOf(id), 15_000e6 - PRINCIPAL, "and nothing of theirs survived in the market they aimed at");
    }

    /// @notice The SAME attacker HONOURING the pull, so the exact pull cannot be what refuses.
    /// @dev The control leg makes the identical call outside a crank and it lands, so the door is open.
    /// @dev What closes it inside the callback is the shared guard slot, and this pins that by name.
    /// @dev `collect` is the carrier because a keeper may legitimately call it: it spends the caller's own
    /// @dev pool, so the open door hands them nothing of anyone else's and diverts nothing.
    function test_Dispose_TheReentrantDoorIsClosedByTheMutex_NotByThePull() public {
        uint256 loanId = _open();
        _enterBand(loanId, PS_BAND);
        ReenteringDeleverageKeeper k = new ReenteringDeleverageKeeper(ace, address(usdc), address(vault), UNIT_SCALE);

        k.collectDirect(); // outside a crank, from the same contract: the door is genuinely open to it
        assertTrue(ace.notEntered(), "fixture: and the lock is clear afterwards, so the control really ran");

        k.setApprovePull(true);
        vm.expectRevert(GUARD_TRIP);
        k.crankDeleverage(loanId);

        assertEq(read.loan(loanId).collateralUnits, COLL, "the loan is whole through the refusal");
    }

    /// @notice A keeper that keeps the units and approves nothing takes the whole crank down with it.
    /// @dev The pull is an exact `transferFrom` against a zero allowance, so it underflows rather than no-ops.
    function test_Dispose_AKeeperThatReturnsNothing_RevertsTheWholeCrank() public {
        uint256 loanId = _open();
        _enterBand(loanId, PS_BAND);
        keeper.setPayNothing(true);

        vm.expectRevert(stdError.arithmeticError);
        keeper.crankDeleverage(loanId);

        assertEq(read.loan(loanId).collateralUnits, COLL, "units never left the loan");
        assertEq(positionManager.collateralOf(loanId), COLL, "and custody still holds them");
        assertEq(vault.balanceOf(address(keeper)), 0, "the keeper kept nothing either");

        keeper.setPayNothing(false); // the refusal to pay was what bound: the same crank now clears
        (uint256 sold,) = keeper.crankDeleverage(loanId);
        assertGt(sold, 0, "a paying keeper harvests");
    }

    /// @notice A route BETTER than the floor: the keeper keeps the surplus and the hub still books the floor.
    /// @dev ACE splits no upside. The floor is what it pulls, not a share of what the route realized.
    function test_Dispose_ARouteBetterThanTheFloor_KeepsTheSurplus_HubBooksTheFloor() public {
        uint256 loanId = _open();
        _enterBand(loanId, PS_BAND);
        keeper.setRoutePrice(PS_BAND * 2); // a route twice as good as the floor's price
        uint256 debt0 = read.debtOf(loanId);

        (uint256 filled, uint256 out) = keeper.crankDeleverage(loanId);

        assertGt(filled, 0, "the crank ran");
        assertEq(out, _owedExact(filled, PS_BAND), "the hub books the floor, never the realization");
        uint256 realized = (filled * PS_BAND * 2) / UNIT_SCALE;
        assertEq(usdc.balanceOf(address(keeper)), realized - out, "the whole surplus stays with the keeper");
        assertGt(realized - out, 0, "non-vacuity: there really was a surplus to keep");
        assertEq(debt0 - read.debtOf(loanId), out, "and only the floor melted debt");
    }

    /// @notice A record pushed UP converts to DENIAL, never to extraction: the floor rises past what the route can clear.
    /// @notice The crank reverts, nothing is written, and the harvest resumes the moment the push stops.
    /// @dev Now that ONE read both sizes and floors, a push up stalls the crank rather than repricing a second leg.
    /// @dev The push has to stay inside the band, or the crank refuses by name before it ever reaches the floor.
    function test_Floor_ARecordPushedUp_StallsTheCrank_ThenResumes() public {
        uint256 loanId = _open();
        _enterBand(loanId, PS_BAND);
        keeper.setRoutePrice(PS_BAND); // the keeper can only route at the price the market supports
        uint256 debt0 = read.debtOf(loanId);

        uint256 trig = read.triggerPrice(loanId);
        record.setMinPrice((trig * 1e18) / (1e18 - BAND_BPS * 1e14) - 1); // the top of the band: still in, still far above the route
        vm.expectRevert(stdError.arithmeticError); // the pull exceeds what the route earned
        keeper.crankDeleverage(loanId);
        assertEq(read.loan(loanId).collateralUnits, COLL, "the loan is untouched by a stalled crank");
        assertEq(read.debtOf(loanId), debt0, "and no debt melted through the revert");

        record.setMinPrice(PS_BAND);
        (uint256 filled,) = keeper.crankDeleverage(loanId);
        assertGt(filled, 0, "the harvest resumes once the push stops");
    }
}
