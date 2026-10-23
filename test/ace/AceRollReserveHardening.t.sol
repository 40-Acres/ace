// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.36;

import {WarpClock} from "../utils/WarpClock.sol";
import {Ace} from "../../src/ace/hub/Ace.sol";
import {AceLens, TornRead} from "../../src/ace/lens/AceLens.sol";
import {InsufficientCash, RollUnbacked} from "../../src/ace/hub/Borrower.sol";
import {BelowMinLot, WouldLeaveDust} from "../../src/ace/hub/Lender.sol";
import {PocDeployConfig} from "../../src/config/Defaults.sol";
import {LoanMath} from "../../src/ace/hub/libraries/LoanMath.sol";
import {MarketInit} from "../../src/ace/hub/MarketInit.sol";
import {MarketParams, OpenBounds} from "../../src/ace/hub/Types.sol";
import {PositionManager} from "../../src/ace/positions/PositionManager.sol";
import {MockERC20} from "../mocks/MockERC20.sol";
import {MockHookERC20} from "../mocks/MockHookERC20.sol";
import {MockPersistenceRecord} from "../mocks/MockPersistenceRecord.sol";
import {AceFixtures} from "../utils/AceFixtures.sol";
import {AceReader} from "../utils/AceReader.sol";

/// @title AceRollReserveHardening
/// @notice The hardening pass over the #666 review fixes: each row kills a mutant the ledger rows let live.
/// @notice The lender doors are pinned at the SHIPPED `minDebt`, where a reserve sits far under the floor.
/// @dev Expected values come from the decision record's sentences or the fee algebra, never from the hub's own predicate.
contract AceRollReserveHardeningTest is WarpClock {
    Ace internal ace;
    AceReader internal read;
    AceLens internal lens;
    PositionManager internal pm;
    MockERC20 internal usdc;
    MockERC20 internal coll;
    MockPersistenceRecord internal rec;
    bytes32 internal id; // the fixture market, `minDebt = 10e6`, for rows where the floor plays no part
    bytes32 internal twin; // same pair and terms, another lender: a legal routed destination

    address internal alice = address(0xA11CE);
    address internal bob = address(0xB0BB);
    address internal borrower = address(0xB0B);
    address internal borrower2 = address(0xB0B2);
    address internal keeper = address(0xCAFE);

    uint64 internal constant TEN7 = 7 days;
    uint64 internal constant TEN28 = 28 days;
    uint256 internal constant P = 50_000e6;
    uint256 internal constant UNITS = 100_000e18;
    uint256 internal constant FLOOR = PocDeployConfig.MIN_DEBT;

    event AutoPolicySet(uint256 indexed id, uint64 tenor, uint16 minBufferBps, uint16 maxFeeBps);

    function setUp() public {
        _warpTo(1_000_000);
        usdc = new MockERC20("USD Coin", "USDC", 6);
        coll = new MockERC20("Collateral", "COLL", 18);
        rec = new MockPersistenceRecord(address(usdc), address(coll));
        rec.setMinPrice(AceFixtures.px(1.1e18, address(usdc), address(coll)));
        AceFixtures.Deployment memory d = AceFixtures.deploy(_params(alice));
        (ace, pm, read, id) = (d.ace, d.positionManager, d.read, d.id);
        lens = new AceLens(address(ace));
        twin = ace.createMarket(_params(bob));
    }

    function _params(address lender) internal view returns (MarketParams memory p) {
        p = AceFixtures.marketParams(address(usdc), address(coll));
        p.record = address(rec);
        p.lender = lender;
        p.baseBps = 40;
        p.minTenor = TEN7;
        p.maxTenor = TEN28;
        p.settleBountyBps = 50;
        p.minCoverageWad = 1.4e18;
    }

    /// @dev The same terms at the shipped `minDebt`; call once per row, since a second create names the same market.
    function _shipped() internal returns (bytes32 sid) {
        MarketParams memory p = _params(alice);
        p.minDebt = FLOOR;
        sid = ace.createMarket(p);
    }

    function _deposit(bytes32 mid, address who, uint256 amt) internal {
        usdc.mint(who, amt);
        vm.startPrank(who);
        usdc.approve(address(ace), amt);
        ace.deposit(mid, amt);
        vm.stopPrank();
    }

    function _openIn(bytes32 mid, address who, uint256 principal) internal returns (uint256 loanId) {
        coll.mint(who, UNITS);
        vm.startPrank(who);
        coll.approve(address(pm), UNITS);
        usdc.approve(address(ace), type(uint256).max);
        loanId = ace.open(mid, UNITS, principal, TEN7, who, OpenBounds(0, 0, 0));
        vm.stopPrank();
    }

    function _arm(uint256 loanId, uint64 tenor) internal {
        vm.prank(read.loan(loanId).borrower);
        ace.setAutoRefinance(loanId, tenor, 0, 0);
    }

    /// @dev What an expiry roll of `debt` at `tenor` draws fresh in `mid`: the floored successor less the debt it recycles.
    function _needIn(bytes32 mid, uint256 debt, uint64 tenor) internal view returns (uint256) {
        MarketParams memory p = ace.idToMarketParams(mid);
        uint256 pp = LoanMath.principalForOwed(debt, tenor, p.baseBps, p.minTenor);
        if (pp < p.minDebt) pp = p.minDebt;
        return pp > debt ? pp - debt : 0;
    }

    /// @dev The lender takes `mid` down to exactly `keep`; zero empties it, which is always allowed.
    function _withdrawTo(bytes32 mid, address lender, uint256 keep) internal {
        uint256 out = keep == 0 ? type(uint256).max : ace.restingOf(mid) - keep; // hoisted: a call in the argument list eats the prank
        vm.prank(lender);
        ace.withdraw(mid, out, lender, 0);
        assertEq(ace.restingOf(mid), keep, "fixture: the market rests exactly what the row asks");
    }

    /// @dev An armed loan in a shipped-floor market resting `P` beside it, and the reserve it took.
    function _armedShipped() internal returns (bytes32 sid, uint256 loanId, uint256 rr) {
        sid = _shipped();
        _deposit(sid, alice, 2 * P);
        loanId = _openIn(sid, borrower, P);
        _arm(loanId, TEN7);
        rr = read.rollReserve(sid);
        assertEq(rr, _needIn(sid, P, TEN7), "PREMISE: the loan reserved its roll's fresh remainder");
        assertGt(rr, 1, "PREMISE: a reserve worth halving");
        assertLt(rr + FLOOR, ace.restingOf(sid), "PREMISE: a whole floor of unreserved cash rests past the reserve");
    }

    /* ================================================================= */
    /*  #690: the deposit door's refill rule                              */
    /* ================================================================= */

    /// @notice A sub-floor top-up one atom past a PARTIAL deficit refuses; the exact remainder lands.
    /// @dev Kills `_refillsReserve` reading `assets <= reserved`: that admits any lot up to the whole reserve, whatever already rests.
    function test_APartialRefillPastTheDeficitRefuses_TheExactRemainderLands() public {
        (bytes32 sid,, uint256 rr) = _armedShipped();
        _withdrawTo(sid, alice, rr / 2); // the lender's consent may leave any amount under the reserve
        uint256 deficit = rr - rr / 2;
        usdc.mint(alice, deficit + 1);
        vm.startPrank(alice);
        usdc.approve(address(ace), deficit + 1);
        vm.expectRevert(BelowMinLot.selector);
        ace.deposit(sid, deficit + 1);
        ace.deposit(sid, deficit);
        vm.stopPrank();
        assertEq(ace.restingOf(sid), rr, "the exact remainder refilled the reserve to the atom");
    }

    /// @notice THE REFILL RULE, fuzzed: under the floor a deposit lands exactly when `cash + amount <= rollReserve`.
    /// @notice A market already holding a floor past its reserve refuses every sub-floor lot, as before the fix.
    /// @dev The spelling is the decision record's, not the hub's saturating `deficit != 0 && assets <= deficit`.
    function testFuzz_ASubFloorDepositLandsExactlyWhenItOnlyRefills(uint256 keepSeed, uint256 lotSeed, bool healthy) public {
        (bytes32 sid,, uint256 rr) = _armedShipped();
        uint256 resting = ace.restingOf(sid);
        uint256 keep = healthy ? bound(keepSeed, rr + FLOOR, resting - 1) : bound(keepSeed, 0, rr);
        _withdrawTo(sid, alice, keep);
        uint256 lot = bound(lotSeed, 1, FLOOR - 1);
        bool admits = keep + lot <= rr;
        usdc.mint(alice, lot);
        vm.startPrank(alice);
        usdc.approve(address(ace), lot);
        if (!admits) vm.expectRevert(BelowMinLot.selector);
        ace.deposit(sid, lot);
        vm.stopPrank();
        assertEq(ace.restingOf(sid), admits ? keep + lot : keep, "the lot rested only when it refilled");
    }

    /// @notice A healthy market, a whole floor past a live reserve, refuses a one-atom lot `BelowMinLot`: there is no deficit to refill.
    /// @dev Kills `_refillsReserve` subtracting plainly (cash over the reserve underflows) and reading the deficit as the whole reserve.
    /// @dev The deterministic twin of the fuzz row's healthy branch, at the SHIPPED floor, so neither kill waits on a seed.
    function test_AHealthyMarketRefusesAOneAtomLotBelowTheFloor() public {
        (bytes32 sid,, uint256 rr) = _armedShipped();
        _withdrawTo(sid, alice, rr + FLOOR);
        assertEq(read.rollReserve(sid), rr, "PREMISE: the reserve is live, so a deficit read as the reserve would admit one atom");
        assertEq(ace.idToMarketParams(sid).minDebt, 5000e6, "PREMISE: the shipped floor");
        usdc.mint(alice, 1);
        vm.startPrank(alice);
        usdc.approve(address(ace), 1);
        vm.expectRevert(BelowMinLot.selector);
        ace.deposit(sid, 1);
        vm.stopPrank();
        assertEq(ace.restingOf(sid), rr + FLOOR, "nothing rested");
    }

    /* ================================================================= */
    /*  #690: the withdraw door's floor on unreserved cash                */
    /* ================================================================= */

    /// @notice THE WITHDRAW RULE, fuzzed: a partial withdraw may leave the reserve or less, or the reserve plus a whole floor.
    /// @dev Aimed so half the range lands in the refused band `(rr, rr + minDebt)`, and both edges are reachable.
    function testFuzz_AWithdrawLeavesTheReserveOrAWholeFloorPastIt(uint256 leftSeed) public {
        (bytes32 sid,, uint256 rr) = _armedShipped();
        uint256 resting = ace.restingOf(sid);
        uint256 left = bound(leftSeed, 1, rr + 2 * FLOOR);
        bool allowed = left <= rr || left >= rr + FLOOR;
        vm.prank(alice);
        if (!allowed) vm.expectRevert(WouldLeaveDust.selector);
        ace.withdraw(sid, resting - left, alice, 0);
        assertEq(ace.restingOf(sid), allowed ? left : resting, "the withdraw left what the rule allows, or nothing moved");
    }

    /* ================================================================= */
    /*  arm: a re-arm to a LARGER need counts its own reservation         */
    /* ================================================================= */

    /// @dev An armed loan at the shipped floor whose market a second draw takes down to `short` atoms under its 28-day need.
    /// @dev A DRAW, not a withdraw: the draw has no remainder test, so it can leave the sub-floor level the lender's door refuses.
    function _armedThenDrawnTo(uint256 short) internal returns (bytes32 sid, uint256 loanId, uint256 r7, uint256 r28) {
        (sid, loanId, r7) = _armedShipped();
        r28 = _needIn(sid, P, TEN28);
        assertGt(r28, r7 + short, "PREMISE: the longer roll needs more");
        uint256 draw = ace.restingOf(sid) - r28 + short;
        _openIn(sid, borrower2, draw);
    }

    /// @notice A re-arm to a larger need lands when the market rests EXACTLY that need, the old share counted as its own.
    /// @dev Kills `arm` asking `cashAdmits(M, r, 0)`: that double-counts the loan's own share and refuses here.
    function test_AReArmToALargerNeedLandsWhenTheCashExactlyCoversIt() public {
        (bytes32 sid, uint256 loanId, uint256 r7, uint256 r28) = _armedThenDrawnTo(0);
        assertEq(ace.restingOf(sid), r28, "PREMISE: the market rests exactly the larger need");
        assertEq(read.rollReserve(sid), r7, "PREMISE: and holds only this loan's current share");
        (bool can, uint256 quoted) = lens.armable(loanId, TEN28);
        assertTrue(can, "the lens says the re-arm is backed");
        assertEq(quoted, r28, "and quotes the need the hub then takes");
        _arm(loanId, TEN28);
        assertEq(read.reservedOf(loanId), r28, "the loan holds the larger need");
        assertEq(read.rollReserve(sid), r28, "and the market holds exactly that one share");
    }

    /// @notice CONTROL: one atom less and the same re-arm refuses, leaving the old reservation in place.
    function test_AReArmToALargerNeedOneAtomShortRefuses() public {
        (bytes32 sid, uint256 loanId, uint256 r7, uint256 r28) = _armedThenDrawnTo(1);
        assertEq(ace.restingOf(sid), r28 - 1, "PREMISE: one atom short of the larger need");
        (bool can,) = lens.armable(loanId, TEN28);
        assertFalse(can, "the lens says the re-arm is one atom unbacked");
        vm.prank(borrower);
        vm.expectRevert(RollUnbacked.selector);
        ace.setAutoRefinance(loanId, TEN28, 0, 0);
        assertEq(read.reservedOf(loanId), r7, "the refused re-arm left the old share");
        assertEq(read.rollReserve(sid), r7, "and the market's reserve");
    }

    /* ================================================================= */
    /*  arm: the partial Cfg carries minDebt                              */
    /* ================================================================= */

    /// @notice Arming a debt the borrower repaid under the floor reserves up to the floor, and the fold draws exactly that.
    /// @dev Kills `_rollCfg` leaving `minDebt` zero, which would reserve one fee and leave the floored roll unbacked.
    function test_ArmingADebtUnderTheFloorReservesUpToTheFloor() public {
        bytes32 sid = _shipped();
        _deposit(sid, alice, 2 * P);
        uint256 loanId = _openIn(sid, borrower, P);
        uint256 d = 1_000e6;
        usdc.mint(borrower, P);
        vm.prank(borrower);
        ace.repay(loanId, P - d); // the borrower's own repay may go under the floor
        assertEq(read.debtOf(loanId), d, "PREMISE: the debt sits under the floor");
        MarketParams memory p = ace.idToMarketParams(sid);
        assertLt(LoanMath.principalForOwed(d, TEN7, p.baseBps, p.minTenor), FLOOR, "PREMISE: the floor binds the successor");
        uint256 want = FLOOR - d; // the successor is exactly one floor, and the retiring debt recycles
        (bool can, uint256 quoted) = lens.armable(loanId, TEN7);
        _arm(loanId, TEN7);
        assertTrue(can, "the lens said the arm was backed");
        assertEq(quoted, want, "and quoted the floored need");
        assertEq(read.reservedOf(loanId), want, "arming reserved up to the floor");
        _withdrawTo(sid, alice, want); // exactly the reserve may stay
        _warpTo(read.loan(loanId).expiry);
        uint256 n = read.loanCount();
        vm.prank(keeper);
        ace.forceClose(loanId);
        assertEq(read.debtOf(n + 1), FLOOR, "the fold rolled into exactly one floor");
        assertEq(ace.restingOf(sid), 0, "spending the reservation to the atom");
    }

    /// @notice A debt the borrower repaid under the escrow's unearned refund still rolls by policy before expiry, into exactly one floor.
    /// @notice The refund covers the whole debt, so nothing is owed past it and the floor alone sizes the successor.
    /// @dev Kills `derivedPrincipal` subtracting the refund plainly: `debt - refundOld` underflows and the total predicate panics.
    /// @dev The refund is `escrow * remaining / tenor` from the fee algebra, floored, never read off the hub's predicate.
    function test_APolicyRollOfADebtUnderItsOwnRefundRollsIntoOneFloor() public {
        bytes32 sid = _shipped();
        _deposit(sid, alice, 2 * P);
        uint256 loanId = _openIn(sid, borrower, P);
        uint256 d = 100_000; // a tenth of a dollar, under what an hour of unearned term refunds
        usdc.mint(borrower, P);
        vm.prank(borrower);
        ace.repay(loanId, P - d); // the borrower's own repay may go under the floor
        _arm(loanId, TEN7);
        assertEq(read.reservedOf(loanId), FLOOR - d, "PREMISE: arming reserved the floored successor less the debt it recycles");
        _warpTo(uint256(read.loan(loanId).expiry) - 1 hours);
        uint256 esc = read.feeEscrowOf(loanId);
        assertEq(esc, 100e6, "PREMISE: half the 200e6 lender fee on 50k at 40 bps for one minTenor is escrowed");
        uint256 refund = (esc * 1 hours) / TEN7;
        assertGt(refund, d, "PREMISE: the unearned refund exceeds the debt it nets against");
        (bool ok, bytes4 why, uint256 p0) = ace.tryContinue(loanId);
        assertTrue(ok, "the predicate answers, and admits the roll");
        assertEq(why, bytes4(0), "naming no refusal");
        assertEq(p0, FLOOR, "the successor is exactly one floor");
        uint256 newId = read.loanCount() + 1;
        vm.prank(keeper);
        ace.refinanceByPolicy(loanId);
        assertEq(read.loan(newId).borrower, borrower, "the roll landed for the same borrower");
        assertEq(read.debtOf(newId), FLOOR, "at one floor");
        assertEq(read.loan(loanId).closedAt, _now(), "and the old loan closed"); // off the clock: a raw read is hoistable under via-IR
    }

    /* ================================================================= */
    /*  the carry's silent disarm is logged                               */
    /* ================================================================= */

    /// @notice The fold's carry into a market with nothing left to reserve disarms the successor, and logs the disarm.
    /// @dev Kills dropping `emit AutoPolicySet(newId, 0, 0, 0)`: an indexer would otherwise read the successor armed.
    function test_TheFoldsUnbackedCarryDisarmsTheSuccessorAndSaysSo() public {
        (bytes32 sid, uint256 loanId, uint256 rr) = _armedShipped();
        _warpTo(read.loan(loanId).expiry);
        _withdrawTo(sid, alice, rr);
        uint256 newId = read.loanCount() + 1;
        vm.expectEmit(true, false, false, true, address(ace));
        emit AutoPolicySet(newId, 0, 0, 0);
        vm.prank(keeper);
        ace.forceClose(loanId);
        _assertBornDisarmed(sid, newId);
    }

    /// @notice The same through the keeper's `refinanceByPolicy` an hour early, where the refund shrinks the fresh need.
    function test_TheKeepersUnbackedCarryDisarmsTheSuccessorAndSaysSo() public {
        (bytes32 sid, uint256 loanId, uint256 rr) = _armedShipped();
        _warpTo(uint256(read.loan(loanId).expiry) - 1 hours);
        (bool ok0,, uint256 p0) = ace.tryContinue(loanId);
        assertTrue(ok0, "PREMISE: the roll is admissible");
        uint256 fresh = p0 - read.debtOf(loanId);
        assertLt(fresh, rr, "PREMISE: before expiry the roll draws under what arming reserved");
        _withdrawTo(sid, alice, fresh);
        uint256 newId = read.loanCount() + 1;
        vm.expectEmit(true, false, false, true, address(ace));
        emit AutoPolicySet(newId, 0, 0, 0);
        vm.prank(keeper);
        ace.refinanceByPolicy(loanId);
        _assertBornDisarmed(sid, newId);
    }

    function _assertBornDisarmed(bytes32 sid, uint256 newId) internal view {
        assertEq(read.loan(newId).borrower, borrower, "the roll landed");
        (uint64 tenor,,) = read.autoPolicyOf(newId);
        assertEq(tenor, 0, "the successor is disarmed");
        assertEq(read.reservedOf(newId), 0, "and holds no share");
        assertEq(read.rollReserve(sid), 0, "so the market reserves nothing");
        assertEq(ace.restingOf(sid), 0, "the roll spent every resting atom");
    }

    /* ================================================================= */
    /*  a routed roll owns no reservation in its destination              */
    /* ================================================================= */

    /// @notice A routed roll's cash leg counts NOTHING as its own in the destination: one atom short, the view refuses.
    /// @notice At exactly its principal the route lands, and its successor is born disarmed with nothing left to reserve.
    /// @dev Kills `_continuationLeg` passing `ap.reserved` routed: the view would admit a roll its own draw then refuses.
    function test_ARoutedRollCountsNoReservationItDoesNotHoldThere() public {
        _deposit(id, alice, 2 * P);
        coll.mint(borrower, UNITS);
        vm.startPrank(borrower);
        coll.approve(address(pm), UNITS);
        uint256 loanId = ace.open(id, UNITS, P, TEN7, borrower, OpenBounds(0, 0, 0));
        ace.setAutoRefinance(loanId, TEN7, 500, 200); // routing consent, with a risk distance
        vm.stopPrank();
        assertGt(read.reservedOf(loanId), 1, "PREMISE: the loan holds a home reservation worth counting");
        _deposit(twin, bob, 2 * P);
        _warpTo(uint256(read.loan(loanId).expiry) - uint256(MarketInit.autoRefinanceWindow(TEN7)) / 2);
        (bool ok0,, uint256 pIn) = ace.tryContinueTo(loanId, twin);
        assertTrue(ok0, "PREMISE: with the destination flush, the route is admissible");

        _withdrawTo(twin, bob, pIn - 1);
        (bool ok, bytes4 why,) = ace.tryContinueTo(loanId, twin);
        assertFalse(ok, "one atom short of the routed principal, the view refuses");
        assertEq(why, InsufficientCash.selector, "on the cash leg: the home reservation is not the destination's");
        vm.prank(keeper);
        vm.expectRevert(InsufficientCash.selector);
        ace.refinanceByPolicyTo(loanId, twin);

        _deposit(twin, bob, 10e6); // back to exactly the principal, through legal lots
        _withdrawTo(twin, bob, pIn);
        uint256 newId = read.loanCount() + 1;
        vm.expectEmit(true, false, false, true, address(ace));
        emit AutoPolicySet(newId, 0, 0, 0);
        vm.prank(keeper);
        ace.refinanceByPolicyTo(loanId, twin);
        assertEq(read.loan(newId).market, twin, "the route landed in the destination");
        assertEq(read.rollReserve(id), 0, "the home reservation left with the loan");
        assertEq(read.rollReserve(twin), 0, "and the destination had nothing left to reserve");
        assertEq(ace.restingOf(twin), 0, "the routed draw took the whole principal: nothing recycled");
    }

    /* ================================================================= */
    /*  the home recycle is capped at the successor's principal           */
    /* ================================================================= */

    /// @notice A home refinance to LESS than the old debt draws no cash and hands the lender back exactly the difference.
    /// @dev Kills `recycled` returning the whole old debt (the draw underflows) and the melt crediting the whole claim as owed.
    function test_AHomeRefinanceUnderTheOldDebtHandsTheLenderTheDifference() public {
        _deposit(id, alice, 2 * P);
        coll.mint(borrower, UNITS);
        vm.startPrank(borrower);
        coll.approve(address(pm), UNITS);
        uint256 loanId = ace.open(id, UNITS, P, TEN28, borrower, OpenBounds(0, 0, 0));
        vm.stopPrank();
        uint256 x = 100e6;
        uint256 np = P - x; // the long term's refund covers the short term's fee and the shortfall, so the refinance nets
        uint256 cashBefore = ace.restingOf(id);
        (uint256 restBefore, uint256 lentBefore, uint256 owedBefore) = read.lenderPools(alice, address(usdc));
        vm.prank(borrower);
        uint256 newId = ace.refinance(loanId, np, TEN7, OpenBounds(0, 0, 0));
        (uint256 restAfter, uint256 lentAfter, uint256 owedAfter) = read.lenderPools(alice, address(usdc));
        MarketParams memory p = ace.idToMarketParams(id);
        uint256 tick = LoanMath.tickCut(LoanMath.originationFee(np, TEN7, p.baseBps, p.minTenor));
        assertEq(ace.restingOf(id), cashBefore, "the successor drew no fresh cash");
        assertEq(restAfter, restBefore, "and the lender's resting pool did not move");
        assertEq(lentBefore - lentAfter, x, "lent carries only the smaller successor");
        assertEq(owedAfter - owedBefore, x + tick, "the lender is owed the principal not re-lent, plus the draw's fee share");
        assertEq(read.claimOf(id, newId), np, "the successor's claim is its whole principal");
    }

    /* ================================================================= */
    /*  the lens reads: saturation and the closed cases                   */
    /* ================================================================= */

    /// @notice `drawableOf` floors at zero in a deficit, reads zero at exactly the reserve, and one floor past it reads one floor.
    /// @dev Kills dropping the saturation: a lender's withdraw may take cash under the reserve, and the view must not revert there.
    function test_DrawableSaturatesInADeficitAndNetsTheReserveOtherwise() public {
        (bytes32 sid,, uint256 rr) = _armedShipped();
        _withdrawTo(sid, alice, rr + FLOOR);
        assertEq(lens.drawableOf(sid), FLOOR, "one whole floor past the reserve is drawable");
        _withdrawTo(sid, alice, rr);
        assertEq(lens.drawableOf(sid), 0, "exactly the reserve leaves nothing drawable");
        _withdrawTo(sid, alice, rr / 2);
        assertEq(lens.drawableOf(sid), 0, "a deficit floors at zero rather than reverting");
        assertTrue(lens.isActive(sid), "while the market still counts as holding cash");
    }

    /// @notice `marketState` decodes the reserve out of the word it shares with `drawCount`, and neither field bleeds into the other.
    function test_TheLensMarketStateDecodesTheReserveBesideTheDrawCount() public {
        (bytes32 sid,, uint256 rr) = _armedShipped();
        assertEq(lens.marketState(sid).rollReserve, rr, "the packed reserve decodes to the one share");
        assertEq(lens.marketState(sid).drawCount, 1, "and the draw count beside it still reads one draw");
        _openIn(sid, borrower2, FLOOR);
        assertEq(lens.marketState(sid).drawCount, 2, "a second draw bumps only the count");
        assertEq(lens.marketState(sid).rollReserve, rr, "and leaves the reserve beside it untouched");
    }

    /// @notice `armable` answers `(false, 0)` for an id naming no loan, a closed loan, and a tenor off the market's grid.
    function test_ArmableRefusesTheClosedAndTheOffGridCases() public {
        _deposit(id, alice, 2 * P);
        uint256 loanId = _openIn(id, borrower, P);
        (bool ok, uint256 q) = lens.armable(loanId + 1, TEN7);
        assertTrue(!ok && q == 0, "no loan, no reservation");
        (ok, q) = lens.armable(loanId, TEN7 - 1);
        assertTrue(!ok && q == 0, "under the grid");
        (ok, q) = lens.armable(loanId, TEN28 + 1);
        assertTrue(!ok && q == 0, "over the grid");
        (ok, q) = lens.armable(loanId, TEN7);
        assertTrue(ok && q == _needIn(id, P, TEN7), "CONTROL: on the grid it quotes the need");
        usdc.mint(borrower, P);
        vm.prank(borrower);
        ace.repay(loanId, type(uint256).max);
        (ok, q) = lens.armable(loanId, TEN7);
        assertTrue(!ok && q == 0, "a closed loan arms nothing");
    }

    /* ================================================================= */
    /*  the documented escape from a strict refusal                       */
    /* ================================================================= */

    /// @notice `refinance` names its way out of `RollUnbacked`: disarm in the same multicall and the refinance lands unarmed.
    function test_DisarmingInTheSameMulticallLetsTheRefinanceLandUnarmed() public {
        uint256 np = P + 1_000e6;
        uint256 need = _needIn(id, np, TEN7);
        _deposit(id, alice, np + need - 1); // the home draw takes only `np - P`, leaving one atom short of the successor's roll
        uint256 loanId = _openIn(id, borrower, P);
        _arm(loanId, TEN7);
        vm.prank(borrower);
        vm.expectRevert(RollUnbacked.selector);
        ace.refinance(loanId, np, TEN7, OpenBounds(0, 0, 0));

        bytes[] memory calls = new bytes[](2);
        calls[0] = abi.encodeCall(Ace.setAutoRefinance, (loanId, 0, 0, 0));
        calls[1] = abi.encodeCall(Ace.refinance, (loanId, np, TEN7, OpenBounds(0, 0, 0)));
        vm.prank(borrower);
        ace.multicall(calls);
        uint256 newId = read.loanCount();
        assertEq(read.debtOf(newId), np, "the refinance landed");
        (uint64 tenor,,) = read.autoPolicyOf(newId);
        assertEq(tenor, 0, "unarmed, as the borrower chose");
        assertEq(read.rollReserve(id), 0, "and nothing is reserved for it");
        assertEq(ace.restingOf(id), need - 1, "the draw took only the fresh remainder");
    }
}

/// @title AceRollReserveLensGuard
/// @notice The lens's reserve reads refuse `TornRead` from inside a hub body, where a roll may have moved the reserve and not the cash.
/// @dev The probe is a quote token's receive hook on the lender's own withdraw, which runs while the hub's guard is held.
contract AceRollReserveLensGuardTest is WarpClock {
    Ace internal ace;
    AceReader internal read;
    AceLens internal lens;
    PositionManager internal pm;
    MockHookERC20 internal quote;
    MockERC20 internal coll;
    bytes32 internal id;
    uint256 internal loanId;

    address internal alice = address(0xA11CE);
    address internal borrower = address(0xB0B);
    uint256 internal constant P = 50_000e6;
    uint256 internal constant UNITS = 100_000e18;

    bytes4[3] internal seen; // what each reserve read answered mid-body: its revert selector, or zero when it answered
    bool internal probed;

    function setUp() public {
        _warpTo(1_000_000);
        quote = new MockHookERC20("USD Coin", "USDC", 6);
        coll = new MockERC20("Collateral", "COLL", 18);
        MarketParams memory p = AceFixtures.marketParams(address(quote), address(coll));
        p.record = address(new MockPersistenceRecord(address(quote), address(coll))); // arming needs a record
        p.lender = alice;
        p.baseBps = 40;
        p.minTenor = 7 days;
        p.maxTenor = 7 days;
        AceFixtures.Deployment memory d = AceFixtures.deploy(p);
        (ace, pm, read, id) = (d.ace, d.positionManager, d.read, d.id);
        lens = new AceLens(address(ace));
        quote.mint(alice, 2 * P);
        vm.startPrank(alice);
        quote.approve(address(ace), 2 * P);
        ace.deposit(id, 2 * P);
        vm.stopPrank();
        coll.mint(borrower, UNITS);
        vm.startPrank(borrower);
        coll.approve(address(pm), UNITS);
        loanId = ace.open(id, UNITS, P, 7 days, borrower, OpenBounds(0, 0, 0));
        ace.setAutoRefinance(loanId, 7 days, 0, 0);
        vm.stopPrank();
        assertGt(read.rollReserve(id), 0, "PREMISE: the loan reserved");
    }

    /// @dev The receive hook: every reserve read the lens offers, asked while the hub's withdraw body still holds its guard.
    function onTokenReceived(address, uint256) external {
        probed = true;
        try lens.rollReserve(id) returns (uint256) {}
        catch (bytes memory e) {
            seen[0] = bytes4(e);
        }
        try lens.drawableOf(id) returns (uint256) {}
        catch (bytes memory e) {
            seen[1] = bytes4(e);
        }
        try lens.armable(loanId, 7 days) returns (bool, uint256) {}
        catch (bytes memory e) {
            seen[2] = bytes4(e);
        }
    }

    /// @notice Mid-body, `rollReserve`, `drawableOf` and `armable` all refuse `TornRead`; once the body returns they answer.
    function test_TheLensReserveReadsRefuseAMidBodyRead() public {
        quote.setHookTarget(address(this));
        vm.prank(alice);
        ace.withdraw(id, 1_000e6, address(this), 0);
        assertTrue(probed, "fixture: the hook ran inside the withdraw");
        assertEq(seen[0], TornRead.selector, "rollReserve answered mid-body");
        assertEq(seen[1], TornRead.selector, "drawableOf answered mid-body");
        assertEq(seen[2], TornRead.selector, "armable answered mid-body");
        assertEq(lens.rollReserve(id), read.rollReserve(id), "and after the body the read answers");
    }
}
