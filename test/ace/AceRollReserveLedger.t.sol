// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.36;

import {WarpClock} from "../utils/WarpClock.sol";
import {Ace} from "../../src/ace/hub/Ace.sol";
import {AceLens} from "../../src/ace/lens/AceLens.sol";
import {InsufficientCash, RollUnbacked} from "../../src/ace/hub/Borrower.sol";
import {BelowMinLot, WouldLeaveDust} from "../../src/ace/hub/Lender.sol";
import {PocDeployConfig} from "../../src/config/Defaults.sol";
import {LoanMath} from "../../src/ace/hub/libraries/LoanMath.sol";
import {MarketInit} from "../../src/ace/hub/MarketInit.sol";
import {MarketParams, MigrateArgs, OpenBounds} from "../../src/ace/hub/Types.sol";
import {PositionManager} from "../../src/ace/positions/PositionManager.sol";
import {MockERC20} from "../mocks/MockERC20.sol";
import {MockPersistenceRecord} from "../mocks/MockPersistenceRecord.sol";
import {AceFixtures} from "../utils/AceFixtures.sol";
import {AceReader} from "../utils/AceReader.sol";

/// @title AceRollReserveLedger
/// @notice The roll reservation's LEDGER: what arming reserves, and that every close, disarm and re-arm gives it back.
/// @notice The standing identity: a market's `rollReserve` is the sum of its live loans' `reserved`, and nothing else.
/// @dev Re-spells the reservation from the fee algebra, so every row checks the hub rather than echoing it.
contract AceRollReserveLedgerTest is WarpClock {
    Ace internal ace;
    AceReader internal read;
    AceLens internal lens;
    PositionManager internal pm;
    MockERC20 internal usdc;
    MockERC20 internal coll;
    MockPersistenceRecord internal rec;
    bytes32 internal id;
    bytes32 internal twin; // same pair and terms, another lender: a legal refinanceTo destination

    address internal alice = address(0xA11CE);
    address internal bob = address(0xB0BB);
    address internal borrower = address(0xB0B);
    address internal borrower2 = address(0xB0B2);
    address internal keeper = address(0xCAFE);

    uint64 internal constant TEN7 = 7 days;
    uint64 internal constant TEN28 = 28 days;
    uint256 internal constant P = 50_000e6;
    uint256 internal constant UNITS = 100_000e18;

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

    function _deposit(bytes32 mid, address who, uint256 amt) internal {
        usdc.mint(who, amt);
        vm.startPrank(who);
        usdc.approve(address(ace), amt);
        ace.deposit(mid, amt);
        vm.stopPrank();
    }

    function _open(address who, uint256 principal) internal returns (uint256 loanId) {
        coll.mint(who, UNITS);
        vm.startPrank(who);
        coll.approve(address(pm), UNITS);
        usdc.approve(address(ace), type(uint256).max);
        loanId = ace.open(id, UNITS, principal, TEN7, who, OpenBounds(0, 0, 0));
        vm.stopPrank();
    }

    function _arm(uint256 loanId, uint64 tenor) internal {
        vm.prank(read.loan(loanId).borrower);
        ace.setAutoRefinance(loanId, tenor, 0, 0);
    }

    /// @dev What an expiry roll of `debt` at `tenor` draws fresh: the floored successor principal less the debt it recycles.
    function _need(uint256 debt, uint64 tenor) internal view returns (uint256) {
        MarketParams memory p = ace.idToMarketParams(id);
        uint256 pp = LoanMath.principalForOwed(debt, tenor, p.baseBps, p.minTenor);
        if (pp < p.minDebt) pp = p.minDebt;
        return pp > debt ? pp - debt : 0;
    }

    function _withdrawTo(uint256 keep) internal {
        uint256 out = ace.restingOf(id) - keep;
        vm.prank(alice);
        ace.withdraw(id, out, alice, 0);
    }

    /* ================================================================= */
    /*  arming                                                            */
    /* ================================================================= */

    /// @notice Arming reserves exactly the roll's fresh remainder, and every read of it agrees.
    function test_ArmingReservesTheRollsFreshRemainder() public {
        _deposit(id, alice, 2 * P);
        uint256 loanId = _open(borrower, P);
        (bool can, uint256 quoted) = lens.armable(loanId, TEN7);
        _arm(loanId, TEN7);
        uint256 r = _need(P, TEN7);
        assertTrue(can, "the lens said the arm was backed");
        assertEq(quoted, r, "and quoted the reservation the hub then took");
        assertEq(read.reservedOf(loanId), r, "the loan holds exactly its roll's fresh remainder");
        assertEq(read.rollReserve(id), r, "and the market's reserve is that one share");
        assertEq(lens.rollReserve(id), r, "the lens reads the same word");
        assertEq(lens.reservedOf(loanId), r, "for the market and the loan");
        assertEq(lens.drawableOf(id), ace.restingOf(id) - r, "and a fresh draw sees the rest");
    }

    /// @notice One atom short of the reservation refuses `RollUnbacked`; exactly backed, the arm lands.
    function test_ArmingOneAtomShortReverts_ExactlyBackedLands() public {
        uint256 r = _need(P, TEN7);
        _deposit(id, alice, P + r - 1);
        uint256 loanId = _open(borrower, P);
        (bool can,) = lens.armable(loanId, TEN7);
        assertFalse(can, "the lens says the arm is one atom unbacked");
        vm.prank(borrower);
        vm.expectRevert(RollUnbacked.selector);
        ace.setAutoRefinance(loanId, TEN7, 0, 0);

        _deposit(id, alice, P); // the lender tops up; the arm now fits beside nothing else
        (can,) = lens.armable(loanId, TEN7);
        assertTrue(can, "backed, the lens agrees");
        _arm(loanId, TEN7);
        assertEq(read.reservedOf(loanId), r, "the arm reserved its remainder");
    }

    /// @notice A disarm only releases, so it lands even when the lender took the market under its reserve.
    function test_DisarmReleasesAndAlwaysLands() public {
        _deposit(id, alice, 2 * P);
        uint256 loanId = _open(borrower, P);
        _arm(loanId, TEN7);
        vm.prank(alice);
        ace.withdraw(id, type(uint256).max, alice, 0);
        assertLt(ace.restingOf(id), read.rollReserve(id), "PREMISE: the lender's own withdraw is not held to the reserve");
        vm.prank(borrower);
        ace.setAutoRefinance(loanId, 0, 0, 0);
        assertEq(read.reservedOf(loanId), 0, "the disarm freed the loan's share");
        assertEq(read.rollReserve(id), 0, "and the market's reserve with it");
    }

    /// @notice A re-arm at a longer tenor replaces the reservation rather than adding a second one.
    function test_ReArmReplacesTheReservation() public {
        _deposit(id, alice, 2 * P);
        uint256 loanId = _open(borrower, P);
        _arm(loanId, TEN7);
        _arm(loanId, TEN28);
        uint256 r28 = _need(P, TEN28);
        assertGt(r28, _need(P, TEN7), "PREMISE: a longer roll draws a bigger fee");
        assertEq(read.reservedOf(loanId), r28, "the loan holds the new reservation only");
        assertEq(read.rollReserve(id), r28, "and the market does not double-count the old one");
    }

    /* ================================================================= */
    /*  every close gives the reservation back                            */
    /* ================================================================= */

    function _armedLoan() internal returns (uint256 loanId) {
        _deposit(id, alice, 2 * P);
        loanId = _open(borrower, P);
        _arm(loanId, TEN7);
        assertGt(read.rollReserve(id), 0, "PREMISE: the loan reserved");
    }

    function test_RepayToZeroReleases() public {
        uint256 loanId = _armedLoan();
        usdc.mint(borrower, P);
        vm.prank(borrower);
        ace.repay(loanId, type(uint256).max);
        assertTrue(ace.isClosed(loanId), "the repay closed the loan");
        assertEq(read.reservedOf(loanId), 0, "its share is freed");
        assertEq(read.rollReserve(id), 0, "and the market's reserve is empty");
    }

    function test_FinalizeReleases() public {
        uint256 loanId = _armedLoan();
        rec.setBelow(true);
        vm.prank(keeper);
        ace.finalize(loanId);
        assertEq(read.rollReserve(id), 0, "a distress settlement frees the reservation");
        assertEq(read.reservedOf(loanId), 0, "and zeroes the loan's share");
    }

    function test_ForceCloseSettleReleases() public {
        uint256 loanId = _armedLoan();
        vm.prank(alice);
        ace.withdraw(id, type(uint256).max, alice, 0);
        _warpTo(read.loan(loanId).expiry);
        vm.prank(keeper);
        ace.forceClose(loanId);
        assertTrue(ace.isClosed(loanId), "the fold settled for want of the lender's cash");
        assertEq(read.rollReserve(id), 0, "and the settle branch freed the reservation");
    }

    function test_SettleExpiredReleases() public {
        uint256 loanId = _armedLoan();
        _warpTo(uint256(read.loan(loanId).expiry) + MarketInit.autoRefinanceWindow(TEN7));
        vm.prank(keeper);
        ace.settleExpired(loanId);
        assertEq(read.rollReserve(id), 0, "the unpaid backstop frees it too");
    }

    /// @notice The roll spends its reservation and the successor reserves its own, from unreserved cash.
    function test_RollReleasesAndTheSuccessorReReserves() public {
        uint256 loanId = _armedLoan();
        _warpTo(read.loan(loanId).expiry);
        (,, uint256 p) = ace.tryContinue(loanId);
        uint256 n = read.loanCount();
        vm.prank(keeper);
        ace.forceClose(loanId);
        uint256 newId = n + 1;
        assertEq(read.loan(newId).borrower, borrower, "the fold rolled");
        assertEq(read.reservedOf(loanId), 0, "the old share is spent");
        assertEq(read.reservedOf(newId), _need(p, TEN7), "the successor reserves its own roll");
        assertEq(read.rollReserve(id), read.reservedOf(newId), "and the market holds only that");
    }

    /// @notice The borrower's own home refinance carries the policy, and its reservation, to the successor.
    function test_ManualHomeRefinanceCarriesTheReservation() public {
        uint256 loanId = _armedLoan();
        uint256 np = P + 1_000e6;
        vm.prank(borrower);
        uint256 newId = ace.refinance(loanId, np, TEN7, OpenBounds(0, 0, 0));
        assertEq(read.reservedOf(loanId), 0, "the retiring share is freed");
        assertEq(read.reservedOf(newId), _need(np, TEN7), "the successor reserves at its own debt");
        assertEq(read.rollReserve(id), read.reservedOf(newId), "one share, the successor's");
    }

    /// @notice A refinance into another market frees the source's reservation and reserves in the destination.
    function test_RoutedRefinanceMovesTheReservationWithTheLoan() public {
        uint256 loanId = _armedLoan();
        _deposit(twin, bob, 2 * P);
        uint256 np = P + 1_000e6;
        vm.prank(borrower);
        uint256 newId = ace.refinanceTo(MigrateArgs(loanId, twin, np, TEN7, OpenBounds(0, 0, 0), 0, address(0)));
        assertEq(read.rollReserve(id), 0, "the source market holds nothing for a loan that left");
        assertEq(read.reservedOf(newId), _need(np, TEN7), "the successor reserves in its own market");
        assertEq(read.rollReserve(twin), read.reservedOf(newId), "and that market's reserve is its share");
    }

    /// @notice The BORROWER's own refinance of an armed loan refuses `RollUnbacked` when the successor cannot re-reserve.
    /// @notice Keeper refinances and the fold never revert on the carry; their unbacked successor is born disarmed instead.
    function test_TheBorrowersRoutedRefinanceRefusesAnUnbackedSuccessor() public {
        uint256 loanId = _armedLoan();
        _deposit(twin, bob, P + 1_000e6); // exactly the routed draw: nothing left to reserve beside it
        vm.prank(borrower);
        vm.expectRevert(RollUnbacked.selector);
        ace.refinanceTo(MigrateArgs(loanId, twin, P + 1_000e6, TEN7, OpenBounds(0, 0, 0), 0, address(0)));
    }

    /// @notice The same at home: the draw leaves one atom less than the successor's roll needs, so the refinance refuses.
    function test_TheBorrowersHomeRefinanceRefusesAnUnbackedSuccessor() public {
        uint256 np = P + 1_000e6;
        _deposit(id, alice, np + _need(np, TEN7) - 1); // the home draw takes only `np - P`, the recycle covers the rest
        uint256 loanId = _open(borrower, P);
        _arm(loanId, TEN7);
        vm.prank(borrower);
        vm.expectRevert(RollUnbacked.selector);
        ace.refinance(loanId, np, TEN7, OpenBounds(0, 0, 0));
    }

    /// @notice CONTROL: one atom more and the same home refinance carries the policy, armed and reserved.
    function test_TheBorrowersHomeRefinanceCarriesWhenTheSuccessorIsBacked() public {
        uint256 np = P + 1_000e6;
        _deposit(id, alice, np + _need(np, TEN7));
        uint256 loanId = _open(borrower, P);
        _arm(loanId, TEN7);
        vm.prank(borrower);
        uint256 newId = ace.refinance(loanId, np, TEN7, OpenBounds(0, 0, 0));
        assertEq(read.reservedOf(newId), _need(np, TEN7), "the successor reserved exactly its roll");
        assertEq(ace.restingOf(id), read.rollReserve(id), "spending every unreserved atom");
    }

    /* ================================================================= */
    /*  the draw's side of the one cash test                              */
    /* ================================================================= */

    /// @notice A fresh draw of exactly the unreserved cash is quoted; one atom more refuses `InsufficientCash`.
    function test_AFreshDrawSeesCashLessTheReserve() public {
        uint256 loanId = _armedLoan();
        uint256 room = ace.restingOf(id) - read.reservedOf(loanId);
        assertEq(lens.drawableOf(id), room, "the lens nets the reserve out");
        (bool ok,,) = lens.tryQuoteOpen(id, 10 * UNITS, room, TEN7, borrower2, OpenBounds(0, 0, 0));
        assertTrue(ok, "a draw of all the unreserved cash is admitted");
        (bool over, bytes4 why,) = lens.tryQuoteOpen(id, 10 * UNITS, room + 1, TEN7, borrower2, OpenBounds(0, 0, 0));
        assertFalse(over, "one atom into the reservation is refused");
        assertEq(why, InsufficientCash.selector, "as a cash refusal");
    }

    /// @notice CONTROL: the lender's withdraw is consent, so it may take the reserve, and the fold then settles.
    function test_TheLendersWithdrawIsNotHeldToTheReserve_AndTheFoldThenSettles() public {
        uint256 loanId = _armedLoan();
        vm.prank(alice);
        ace.withdraw(id, type(uint256).max, alice, 0);
        assertEq(ace.restingOf(id), 0, "the lender emptied the market, reserve and all");
        _warpTo(read.loan(loanId).expiry);
        (bool ok, bytes4 why,) = ace.tryContinue(loanId);
        assertFalse(ok, "the roll is refused");
        assertEq(why, InsufficientCash.selector, "on cash, which was the lender's to take");
    }

    /// @notice On a 10 USDC `minDebt` a partial repay leaves NO slack: the new need is over the shrink's floor, `minDebt - 1`.
    /// @notice So at the fold any deficit refuses every armed loan, and the first fold's released share is what cures it.
    /// @dev Slack is `reserved - fresh`. The floor keeps it at the shipped `minDebt`; the companion row below shows that case.
    function test_OnATenUsdcFloorARepayLeavesNoSlack_SoADeficitRefusesEveryFoldUntilAReleaseCuresIt() public {
        _deposit(id, alice, 4 * P);
        uint256 a = _open(borrower, P);
        uint256 b = _open(borrower2, P);
        _arm(a, TEN7);
        _arm(b, TEN7);
        usdc.mint(borrower, P);
        vm.prank(borrower);
        ace.repay(a, P / 2); // a's own borrower halves its debt: its roll now needs half the fresh cash it reserved
        assertEq(ace.idToMarketParams(id).minDebt, 10e6, "PREMISE: the fixture's 10 USDC floor, not the shipped one");
        assertGt(_need(read.debtOf(a), TEN7), ace.idToMarketParams(id).minDebt - 1, "PREMISE: the new need is over the floor");
        assertEq(read.reservedOf(a), _need(read.debtOf(a), TEN7), "the repay shrank a's share to its new need: no slack");
        _withdrawTo(read.rollReserve(id) - 1); // the smallest deficit, one atom
        _warpTo(read.loan(a).expiry);
        (bool okA, bytes4 whyA,) = ace.tryContinue(a);
        (bool okB, bytes4 whyB,) = ace.tryContinue(b);
        assertFalse(okA, "the repaid loan is refused too");
        assertEq(whyA, InsufficientCash.selector, "for want of the cash the lender took");
        assertFalse(okB, "and so is the other");
        assertEq(whyB, InsufficientCash.selector, "for the same reason");
        vm.prank(keeper);
        ace.forceClose(a);
        (okB,,) = ace.tryContinue(b);
        assertTrue(okB, "the first fold's released share cured the deficit, so the next roll is admitted");
    }

    /// @notice COMPANION at the SHIPPED `minDebt`: a 50,000 loan's share is under the floor, so a repay leaves it whole and buys slack.
    /// @notice A deficit smaller than that slack spares the repaid loan's fold and refuses the unrepaid one's: per-loan selectivity.
    /// @dev Slack is `reserved - fresh`, and the fold admits iff `cash >= fresh + others`, which is `slack >= deficit`.
    function test_AtTheShippedFloorARepayKeepsSlack_SoADeficitUnderItSparesThatLoan() public {
        bytes32 m = _shipped();
        _deposit(m, alice, 4 * P);
        uint256 a = _openIn(m, borrower, P);
        uint256 b = _openIn(m, borrower2, P);
        _arm(a, TEN7);
        _arm(b, TEN7);
        uint256 armedA = read.reservedOf(a);
        assertLt(armedA, PocDeployConfig.MIN_DEBT - 1, "PREMISE: a 50,000 loan's share is under the shrink's floor");
        usdc.mint(borrower, P);
        vm.startPrank(borrower);
        usdc.approve(address(ace), P);
        ace.repay(a, P / 2);
        vm.stopPrank();
        uint256 needA = _needIn(m, read.debtOf(a), TEN7);
        assertEq(read.reservedOf(a), armedA, "the floor kept a's share whole through the repay");
        assertLt(needA, armedA, "PREMISE: while its roll now needs less");
        uint256 slack = armedA - needA;
        assertGt(slack, 1, "PREMISE: the repay bought a real slack");
        uint256 out = ace.restingOf(m) - (read.rollReserve(m) - slack / 2); // a deficit of half a's slack, over b's zero
        vm.prank(alice);
        ace.withdraw(m, out, alice, 0);
        _warpTo(read.loan(a).expiry);
        (bool okA,,) = ace.tryContinue(a);
        (bool okB, bytes4 whyB,) = ace.tryContinue(b);
        assertTrue(okA, "the repaid loan's slack covers the deficit, so its fold still rolls");
        assertFalse(okB, "the unrepaid loan has no slack, so the same deficit refuses it");
        assertEq(whyB, InsufficientCash.selector, "for want of the cash the lender took");
    }

    /// @dev `_need` against market `m`'s own floor.
    function _needIn(bytes32 m, uint256 debt, uint64 tenor) internal view returns (uint256) {
        MarketParams memory p = ace.idToMarketParams(m);
        uint256 pp = LoanMath.principalForOwed(debt, tenor, p.baseBps, p.minTenor);
        if (pp < p.minDebt) pp = p.minDebt;
        return pp > debt ? pp - debt : 0;
    }

    /// @notice At the exact boundary the view and the verb agree: both roll, to the atom.
    function test_TheViewAndTheVerbAgreeAtTheBoundary() public {
        uint256 loanId = _armedLoan();
        _warpTo(uint256(read.loan(loanId).expiry) - 1 hours);
        (,, uint256 p) = ace.tryContinue(loanId);
        uint256 fresh = p - read.debtOf(loanId);
        _withdrawTo(fresh);
        (bool ok,, uint256 quoted) = ace.tryContinue(loanId);
        assertTrue(ok, "the view admits at exactly the fresh remainder");
        vm.prank(keeper);
        uint256 newId = ace.refinanceByPolicy(loanId);
        assertEq(read.debtOf(newId), quoted, "and the verb rolls into exactly the principal it quoted");
        assertEq(ace.restingOf(id), 0, "spending the fresh remainder to the atom");
    }

    /// @notice THE IDENTITY across a mixed book: the reserve is the sum of the live loans' shares after every step.
    function test_TheReserveIsTheSumOfLiveShares() public {
        _deposit(id, alice, 6 * P);
        uint256 a = _open(borrower, P);
        uint256 b = _open(borrower2, P / 2);
        uint256 c = _open(borrower, P / 4);
        _arm(a, TEN7);
        _arm(b, TEN28);
        _arm(c, TEN7);
        _assertSum(a, b, c);
        vm.prank(borrower2);
        ace.setAutoRefinance(b, 0, 0, 0);
        _assertSum(a, b, c);
        usdc.mint(borrower, P);
        vm.prank(borrower);
        ace.repay(c, type(uint256).max);
        _assertSum(a, b, c);
        _warpTo(read.loan(a).expiry);
        uint256 n = read.loanCount();
        vm.prank(keeper);
        ace.forceClose(a);
        assertEq(read.rollReserve(id), read.reservedOf(n + 1), "after the roll only the successor holds a share");
    }

    function _assertSum(uint256 a, uint256 b, uint256 c) internal view {
        assertEq(read.rollReserve(id), read.reservedOf(a) + read.reservedOf(b) + read.reservedOf(c), "the reserve is the sum of shares");
    }

    /* ================================================================= */
    /*  a re-arm that frees reserve lands in a deficit                    */
    /* ================================================================= */

    /// @notice A re-arm needing no more than the loan already holds lands even in a deficit: it only keeps or frees reserve.
    function test_AReArmNeedingNoMoreLandsInADeficit() public {
        uint256 loanId = _armedLoan();
        _arm(loanId, TEN28);
        uint256 r28 = read.reservedOf(loanId);
        vm.prank(alice);
        ace.withdraw(id, type(uint256).max, alice, 0);
        assertLt(ace.restingOf(id), read.rollReserve(id), "PREMISE: the lender left the market under its reserve");
        vm.startPrank(borrower);
        ace.setAutoRefinance(loanId, TEN28, 100, 0); // the same need, a new buffer
        assertEq(read.reservedOf(loanId), r28, "a parameter tweak keeps the reservation");
        ace.setAutoRefinance(loanId, TEN7, 0, 0); // a shorter roll, a smaller need
        vm.stopPrank();
        assertEq(read.reservedOf(loanId), _need(P, TEN7), "a smaller need shrinks the reservation");
        assertEq(read.rollReserve(id), _need(P, TEN7), "and the market frees the difference");
    }

    /// @notice CONTROL: a re-arm to a LARGER need in a deficit still refuses, since nobody backs the extra.
    function test_AReArmNeedingMoreStillRefusesInADeficit() public {
        uint256 loanId = _armedLoan();
        vm.prank(alice);
        ace.withdraw(id, type(uint256).max, alice, 0);
        vm.prank(borrower);
        vm.expectRevert(RollUnbacked.selector);
        ace.setAutoRefinance(loanId, TEN28, 0, 0);
    }

    /* ================================================================= */
    /*  #690: the lender's doors at the SHIPPED floor                      */
    /* ================================================================= */

    /// @dev The same terms at the shipped `minDebt`, where a reserve sits far under the floor.
    function _shipped() internal returns (bytes32 sid) {
        MarketParams memory p = _params(alice);
        p.minDebt = PocDeployConfig.MIN_DEBT;
        sid = ace.createMarket(p);
    }

    function _openIn(bytes32 mid, address who, uint256 principal) internal returns (uint256 loanId) {
        coll.mint(who, UNITS);
        vm.startPrank(who);
        coll.approve(address(pm), UNITS);
        loanId = ace.open(mid, UNITS, principal, TEN7, who, OpenBounds(0, 0, 0));
        vm.stopPrank();
    }

    /// @dev An armed loan in a shipped-floor market, and the reserve it took.
    function _armedShipped() internal returns (bytes32 sid, uint256 loanId, uint256 rr) {
        sid = _shipped();
        _deposit(sid, alice, 2 * P);
        loanId = _openIn(sid, borrower, P);
        _arm(loanId, TEN7);
        rr = read.rollReserve(sid);
        assertGt(rr, 0, "PREMISE: the loan reserved");
        assertLt(rr, PocDeployConfig.MIN_DEBT, "PREMISE: the reserve sits under the shipped floor");
    }

    /// @notice The lender may leave exactly the reserve resting, and the armed fold still rolls on it.
    function test_690_TheLenderMayLeaveExactlyTheReserveResting() public {
        (bytes32 sid, uint256 loanId, uint256 rr) = _armedShipped();
        uint256 out = ace.restingOf(sid) - rr; // hoisted: a call in the argument list would eat the prank
        vm.prank(alice);
        ace.withdraw(sid, out, alice, 0);
        assertEq(ace.restingOf(sid), rr, "every unreserved dollar left and the reserve stayed");
        _warpTo(read.loan(loanId).expiry);
        (bool ok,,) = ace.tryContinue(loanId);
        assertTrue(ok, "the reserve left behind is the roll's whole fresh need");
    }

    /// @notice Unreserved cash under the floor is dust whatever the reserve beside it; a whole floor of it may stay.
    function test_690_UnreservedDustStillRefuses() public {
        (bytes32 sid,, uint256 rr) = _armedShipped();
        uint256 resting = ace.restingOf(sid);
        uint256 floor_ = PocDeployConfig.MIN_DEBT;
        vm.startPrank(alice);
        vm.expectRevert(WouldLeaveDust.selector);
        ace.withdraw(sid, resting - rr - 1, alice, 0);
        vm.expectRevert(WouldLeaveDust.selector);
        ace.withdraw(sid, resting - rr - (floor_ - 1), alice, 0);
        ace.withdraw(sid, resting - rr - floor_, alice, 0);
        vm.stopPrank();
        assertEq(ace.restingOf(sid), rr + floor_, "the reserve and one whole floor of unreserved cash stay");
    }

    /// @notice A deposit under the floor is admitted when it only refills the reserve, in as many pieces as the lender likes.
    function test_690_ADepositThatOnlyRefillsTheReserveIsAdmitted() public {
        (bytes32 sid, uint256 loanId, uint256 rr) = _armedShipped();
        vm.prank(alice);
        ace.withdraw(sid, type(uint256).max, alice, 0);
        assertEq(ace.restingOf(sid), 0, "PREMISE: the lender emptied the market under its reserve");
        _deposit(sid, alice, rr / 2);
        _deposit(sid, alice, rr - rr / 2);
        assertEq(ace.restingOf(sid), rr, "two sub-floor top-ups refilled the reserve to the atom");
        _warpTo(read.loan(loanId).expiry);
        (bool ok,,) = ace.tryContinue(loanId);
        assertTrue(ok, "and the armed fold rolls again");
    }

    /// @notice CONTROL: a sub-floor deposit one atom past the reserve would rest unreserved dust, so it still refuses.
    function test_690_ASubFloorDepositPastTheReserveRefuses() public {
        (bytes32 sid,, uint256 rr) = _armedShipped();
        vm.prank(alice);
        ace.withdraw(sid, type(uint256).max, alice, 0);
        usdc.mint(alice, rr + 1);
        vm.startPrank(alice);
        usdc.approve(address(ace), rr + 1);
        vm.expectRevert(BelowMinLot.selector);
        ace.deposit(sid, rr + 1);
        vm.stopPrank();
    }
}
