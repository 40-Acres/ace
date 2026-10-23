// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.36;

import {WarpClock} from "../utils/WarpClock.sol";
import {Ace} from "../../src/ace/hub/Ace.sol";
import {AceLens} from "../../src/ace/lens/AceLens.sol";
import {ArmNeedsRecord, InsufficientCash} from "../../src/ace/hub/Borrower.sol";
import {BelowCallerFloor, BelowMinLot, ExitToHub, GateRefused, Lender, NotTheLender, WouldLeaveDust, ZeroWithdrawTo} from "../../src/ace/hub/Lender.sol";
import {MarketParams, MigrateArgs, OpenBounds} from "../../src/ace/hub/Types.sol";
import {PositionManager} from "../../src/ace/positions/PositionManager.sol";
import {MockERC20} from "../mocks/MockERC20.sol";
import {MockBlockableERC20} from "../mocks/MockBlockableERC20.sol";
import {AceFixtures} from "../utils/AceFixtures.sol";
import {AceReader} from "../utils/AceReader.sol";

/// @title AceP2StarvedRoll
/// @notice Audit run 2026-09-13-670568 phase 2, F1: a sole lender starved an armed recordless roll and was paid the coverage.
/// @notice A RECORDLESS LOAN CANNOT ARM NOW (`ArmNeedsRecord`), so there is no roll for its lender to refuse before tenor.
/// @notice What stands is the unarmed default: at tenor the loan settles and the lender's pot takes the whole coverage line.
/// @dev The revert row pins the refusal; the premises pin the forfeit and the escape; the KNOWN row pins that no lender act is involved.
contract AceP2StarvedRollTest is WarpClock {
    Ace internal ace;
    AceReader internal read;
    AceLens internal lens;
    PositionManager internal pm;
    MockERC20 internal usdc;
    MockERC20 internal coll;
    bytes32 internal mid;

    address internal alice = address(0xA11CE); // the market's one named lender
    address internal friend = address(0xF41E2D); // a third party willing to fund the roll
    address internal bob = address(0xB0B2); // a second lender, in a second market
    address internal borrower = address(0xB0B);

    uint256 internal constant DEPOSIT = 40e6; // deep enough to fund the successor at the derived principal
    uint256 internal constant PRINCIPAL = 11e6;
    uint256 internal constant COLL = 10_000e18;

    OpenBounds internal OFF = OpenBounds(0, 0, 0);

    function setUp() public {
        _warpTo(1_000_000);
        usdc = new MockERC20("USD Coin", "USDC", 6);
        coll = new MockERC20("Collateral", "COLL", 18);
        MarketParams memory p = _params(alice);
        AceFixtures.Deployment memory d = AceFixtures.deploy(p);
        (ace, pm, read, mid) = (d.ace, d.positionManager, d.read, d.id);
        lens = new AceLens(address(ace));
    }

    function _params(address lender) internal view returns (MarketParams memory p) {
        p = AceFixtures.marketParams(address(usdc), address(coll));
        p.record = address(0); // recordless: the class whose settlement takes the whole coverage line
        p.lender = lender;
    }

    function _rest(bytes32 m, address who, uint256 amt) internal {
        usdc.mint(who, amt);
        vm.startPrank(who);
        usdc.approve(address(ace), amt);
        ace.deposit(m, amt);
        vm.stopPrank();
    }

    /// @dev A healthy unarmed loan: collateral far above its line. A recordless market has no armed kind to open.
    function _loan() internal returns (uint256 loanId) {
        coll.mint(borrower, COLL);
        vm.startPrank(borrower);
        coll.approve(address(pm), COLL);
        loanId = ace.open(mid, COLL, PRINCIPAL, 0, borrower, OFF);
        vm.stopPrank();
    }

    /// @notice REVERT: with the lender's cash resting, arming a recordless loan refuses `ArmNeedsRecord` and reserves nothing.
    function testRevert_ARecordlessLoanCannotArm() public {
        _rest(mid, alice, DEPOSIT);
        uint256 loanId = _loan();
        uint64 tenor = read.loan(loanId).tenor; // read before the prank: an argument's own call would consume it
        vm.prank(borrower);
        vm.expectRevert(ArmNeedsRecord.selector);
        ace.setAutoRefinance(loanId, tenor, 0, 0);
        (uint64 armedTenor,,) = read.autoPolicyOf(loanId);
        assertEq(armedTenor, 0, "no policy was written");
        assertEq(read.reservedOf(loanId), 0, "and no cash was reserved for it");
        (bool ok, uint256 q) = lens.armable(loanId, tenor);
        assertTrue(!ok && q == 0, "the lens agrees: nothing here is armable, at any cash level");
    }

    /// @notice PREMISE: nobody but the named lender can put cash where the home roll draws, not even the borrower.
    function test_Premise_NoThirdPartyCanFundTheHomeRoll() public {
        usdc.mint(friend, DEPOSIT);
        vm.startPrank(friend);
        usdc.approve(address(ace), DEPOSIT);
        vm.expectRevert(GateRefused.selector);
        ace.deposit(mid, DEPOSIT);
        vm.stopPrank();
        usdc.mint(borrower, DEPOSIT);
        vm.startPrank(borrower);
        usdc.approve(address(ace), DEPOSIT);
        vm.expectRevert(GateRefused.selector);
        ace.deposit(mid, DEPOSIT);
        vm.stopPrank();
    }

    /// @notice PREMISE: an unarmed recordless loan, cash still resting, settles at tenor and the pot takes the whole coverage line.
    /// @dev No arm and no withdrawal: this is the forfeit #539 is about, and the lender needs no act to reach it.
    function test_Premise_AnUnarmedRecordlessLoanSettlesToTheLineAtTenor() public {
        _rest(mid, alice, DEPOSIT);
        uint256 loanId = _loan();
        uint256 units = read.loan(loanId).collateralUnits;
        uint256 need = lens.collateralNeeded(mid, loanId);
        uint256 line = units - lens.withdrawableUnits(mid, loanId);
        uint256 debt = read.debtOf(loanId);
        assertGt(line, need, "fixture: the line must exceed need, or there is no coverage to take");
        assertGt(units, line, "fixture: the loan sits above its line, so it is healthy by the market's own rule");

        _warpTo(read.loan(loanId).expiry);
        assertGt(ace.restingOf(mid), 0, "fixture: the lender's cash still rests at expiry");
        uint256 n = read.loanCount();
        vm.prank(alice);
        ace.forceClose(loanId);

        assertEq(read.loanCount(), n, "settled, not rolled");
        uint256 pot = read.invPotOf(mid, loanId);
        uint256 sliver = read.unitsOwedOf(loanId, alice);
        assertEq(pot, line, "the pot holds the whole coverage line");
        assertEq(read.unitsOwedOf(loanId, borrower), units - sliver - line, "the borrower keeps only what sat above the line");

        uint256 price = ace.idToMarketParams(mid).price;
        uint256 scale = read.marketState(mid).unitScale;
        uint256 forfeitAtBook = ((pot - need) * price) / scale;
        emit log_named_decimal_uint("debt (USDC)", debt, 6);
        emit log_named_decimal_uint("coverage above need, at book (USDC)", forfeitAtBook, 6);
        emit log_named_uint("as bps of debt", (forfeitAtBook * 10000) / debt);
    }

    /// @notice PREMISE: the escape is the borrower's own migration, unarmed, into a SECOND lender's market before expiry.
    /// @dev The home lender has taken every resting atom, so the home market can fund nothing; the borrower needs no consent from it.
    function test_Premise_TheEscapeIsTheBorrowersOwnMigration() public {
        bytes32 dst = ace.createMarket(_params(bob));
        _rest(dst, bob, DEPOSIT);
        _rest(mid, alice, DEPOSIT);
        uint256 loanId = _loan();
        vm.prank(alice);
        ace.withdraw(mid, type(uint256).max, alice, 0);
        _warpTo(read.loan(loanId).expiry - 1);
        uint64 tenor = read.loan(loanId).tenor;
        vm.prank(borrower);
        uint256 newId = ace.refinanceTo(MigrateArgs(loanId, dst, 2 * PRINCIPAL, tenor, OFF, 0, address(0)));
        assertEq(ace.loanMarket(newId), dst, "the borrower escaped into the second lender's market");
        assertEq(read.invPotOf(mid, loanId), 0, "and nothing was forfeited on the way out");
        (uint64 newTenor,,) = read.autoPolicyOf(newId);
        assertEq(newTenor, 0, "the successor is unarmed, like the loan it replaced");
    }

    /// @notice KNOWN: a recordless loan has NO ROLL TO REFUSE. Arming refuses, nothing is reserved, and the twins settle alike at tenor.
    /// @dev The lender's veto #514 accepted here is unreachable rather than ruled: no lender act is needed to reach the forfeit.
    /// @dev The forfeit itself is the unarmed default at tenor, and it stands.
    function test_Known_ARecordlessLoanHasNoRollToRefuse() public {
        _rest(mid, alice, DEPOSIT);
        uint256 first = _loan();
        uint256 plain = _loan();
        uint64 tenor = read.loan(first).tenor;
        vm.prank(borrower);
        vm.expectRevert(ArmNeedsRecord.selector);
        ace.setAutoRefinance(first, tenor, 0, 0);
        uint256 line = read.loan(first).collateralUnits - lens.withdrawableUnits(mid, first);
        assertEq(read.loan(plain).expiry, read.loan(first).expiry, "fixture: the twins mature together");
        assertGt(line, lens.collateralNeeded(mid, first), "fixture: the line exceeds the claim's need, so there is coverage to take");
        assertEq(read.rollReserve(mid), 0, "nothing in the market is reserved for any roll");

        uint256 snap = vm.snapshotState();
        uint256 resting = ace.restingOf(mid);
        vm.prank(alice);
        uint256 paid = ace.withdraw(mid, type(uint256).max, alice, 0);
        assertEq(paid, resting, "so the lender's full withdraw takes every resting atom");
        assertEq(ace.restingOf(mid), 0, "and leaves nothing behind for a roll");
        vm.revertToState(snap);

        _warpTo(read.loan(first).expiry);
        vm.startPrank(friend); // a stranger cranks: the lender does nothing at all
        ace.forceClose(first);
        ace.forceClose(plain);
        vm.stopPrank();

        assertEq(read.invPotOf(mid, first), line, "the loan the borrower tried to arm settles to the whole coverage line");
        assertEq(read.invPotOf(mid, first), read.invPotOf(mid, plain), "exactly what the twin that never tried forfeits");
        assertEq(read.unitsOwedOf(first, borrower), read.unitsOwedOf(plain, borrower), "and the borrower keeps the same on both");
    }

    /// @notice FUZZ: whatever the policy, a recordless market refuses `ArmNeedsRecord`, reserves nothing, and its lender takes it all.
    /// @dev The record check runs FIRST, so a bad buffer, an unconsented route or an off-grid tenor answers the same way.
    function testFuzz_ARecordlessMarketReservesNothingWhateverTheArm(uint64 tenor, uint16 minBufferBps, uint16 maxFeeBps) public {
        tenor = uint64(bound(tenor, 1, type(uint64).max));
        _rest(mid, alice, DEPOSIT);
        uint256 loanId = _loan();
        vm.prank(borrower);
        vm.expectRevert(ArmNeedsRecord.selector);
        ace.setAutoRefinance(loanId, tenor, minBufferBps, maxFeeBps);
        assertEq(read.rollReserve(mid), 0, "nothing is reserved");
        assertEq(read.reservedOf(loanId), 0, "for this loan or any other");
        uint256 resting = ace.restingOf(mid);
        vm.prank(alice);
        assertEq(ace.withdraw(mid, type(uint256).max, alice, 0), resting, "and the lender's full withdraw takes every resting atom");
    }
}

/// @title AceP2CollectDestination
/// @notice Audit run 2026-09-13-670568 phase 2, F2: `collect` pays only the lender, so a refused lender strands its yield too.
/// @notice #381, with #392's `minPaid`: both quote exits take a `to` and pay out of the caller's own position; `withdraw` has a floor.
/// @dev The premise row still pins that the lender's OWN address is refused on every leg; the `test_381_*` rows are the way out.
contract AceP2CollectDestinationTest is WarpClock {
    Ace internal ace;
    AceReader internal read;
    PositionManager internal pm;
    MockBlockableERC20 internal usdc;
    MockERC20 internal coll;
    bytes32 internal mid;

    address internal alice = address(0xA11CE);
    address internal borrower = address(0xB0B);
    address internal friend = address(0xF41E2D); // an address the quote does not refuse
    address internal stranger = address(0x5712A); // neither the lender nor anyone they named

    uint256 internal constant DEPOSIT = 40e6;
    uint256 internal constant PRINCIPAL = 11e6;
    uint256 internal constant COLL = 10_000e18;

    function setUp() public {
        _warpTo(1_000_000);
        usdc = new MockBlockableERC20("USD Coin", "USDC", 6);
        coll = new MockERC20("Collateral", "COLL", 18);
        MarketParams memory p = AceFixtures.marketParams(address(usdc), address(coll));
        p.lender = alice;
        AceFixtures.Deployment memory d = AceFixtures.deploy(p);
        (ace, pm, read, mid) = (d.ace, d.positionManager, d.read, d.id);
    }

    /// @dev Lend, draw, repay in full: the lender ends with resting cash AND accumulated credit.
    function _lendAndRepay() internal {
        usdc.mint(alice, DEPOSIT);
        vm.startPrank(alice);
        usdc.approve(address(ace), DEPOSIT);
        ace.deposit(mid, DEPOSIT);
        vm.stopPrank();
        coll.mint(borrower, COLL);
        vm.startPrank(borrower);
        coll.approve(address(pm), COLL);
        uint256 loanId = ace.open(mid, COLL, PRINCIPAL, 0, borrower, OpenBounds(0, 0, 0));
        usdc.mint(borrower, PRINCIPAL);
        usdc.approve(address(ace), PRINCIPAL);
        ace.repay(loanId, PRINCIPAL);
        vm.stopPrank();
    }

    /// @notice CONTROL: an unrefused lender collects the whole credit and withdraws the whole resting cash.
    /// @dev MEASURES THE OUTCOME RATHER THAN THE MECHANISM, which is what the row always meant. The closing
    /// @dev repay now PUSHES the credit, so `collect` finds nothing left to do and the old assertion on a
    /// @dev non-zero `owed` was reading the wrong place. What still has to hold is that an unrefused lender
    /// @dev ends up holding both legs, by whichever route each one travels.
    function test_Control_UnrefusedLender_CollectsAndWithdraws() public {
        uint256 before = usdc.balanceOf(alice);
        _lendAndRepay();

        uint256 credited = usdc.balanceOf(alice) - before;
        assertGt(credited, 0, "control: the credit reached the lender, pushed at the close");
        (,, uint256 owed) = read.lenderPools(alice, address(usdc));
        assertEq(owed, 0, "and nothing was left pooled behind it");
        vm.prank(alice);
        assertEq(ace.collect(address(usdc), alice), 0, "so a collect afterwards is the no-op it should be");
        vm.prank(alice);
        assertGt(ace.withdraw(mid, type(uint256).max, alice, 0), 0, "control: the principal pays out");
    }

    /// @notice PREMISE: once the quote refuses the lender, BOTH quote exits refuse when they pay the lender's own address.
    /// @dev RENAMED from `test_Premise_ARefusedLenderHasNoQuoteExitAtAll`, which the `test_381_*` rows below made false.
    /// @dev THE BLOCK IS ARMED BEFORE THE REPAY NOW, and the row is stronger for it. Armed after, the close's
    /// @dev push had already delivered the credit, so `collect` found an empty pool and returned zero instead
    /// @dev of refusing -- the row was asserting a revert on a state it had itself emptied. Armed first, the
    /// @dev push takes its FALLBACK, the credit stays pooled, and both exits then refuse exactly as before.
    /// @dev So this now covers the fallback path too, without changing what it claims.
    function test_Premise_ARefusedLenderCannotBePaidAtTheirOwnAddress() public {
        usdc.setBlocked(alice, true);
        _lendAndRepay();

        (,, uint256 owed) = read.lenderPools(alice, address(usdc));
        assertGt(owed, 0, "premise: the refused push left the credit pooled, which is what the exits then refuse");
        vm.prank(alice);
        vm.expectRevert(bytes("blocked"));
        ace.collect(address(usdc), alice);
        vm.prank(alice);
        vm.expectRevert(bytes("blocked"));
        ace.withdraw(mid, type(uint256).max, alice, 0);
    }

    /// @dev DELETED WITH THE REARM POLICY: `test_Premise_CompoundingOnlyMovesTheStrandFromOneLegToTheOther`.
    /// @dev It armed a rearm, compounded the credit into resting cash under a blocking quote, and showed the
    /// @dev strand simply moved to the leg `withdraw` reaches -- which the row above already refuses. With no
    /// @dev verb that moves credit between the legs, there is only ONE strand and it is the one pinned above.

    /* ============ #381: both quote legs take a destination, and #392's floor rides on withdraw ============ */

    /// @notice A lender naming themselves as `to` is paid exactly what left the hub, and nobody else is paid.
    function test_381_WithdrawToSelfPaysTheCallerAndNobodyElse() public {
        _lendAndRepay();
        uint256 resting = ace.restingOf(mid);
        assertGt(resting, 0, "premise: resting cash is left to take");
        uint256 aliceHad = usdc.balanceOf(alice);
        uint256 hubHad = usdc.balanceOf(address(ace));

        vm.expectEmit(true, true, true, true, address(ace));
        emit Lender.Withdraw(mid, alice, alice, resting);
        vm.prank(alice);
        uint256 paid = ace.withdraw(mid, type(uint256).max, alice, 0);

        assertEq(paid, resting, "the whole resting balance paid out");
        assertEq(usdc.balanceOf(alice) - aliceHad, paid, "every wei landed at the caller");
        assertEq(hubHad - usdc.balanceOf(address(ace)), paid, "and the hub let go of exactly that, so nothing went anywhere else");
    }

    /// @notice THE PRINCIPAL LEG: a refused lender's `withdraw` pays the whole resting balance to an address the quote accepts.
    function test_381_ARefusedLender_WithdrawsRestingCashToAFriend() public {
        usdc.setBlocked(alice, true);
        _lendAndRepay();
        uint256 resting = ace.restingOf(mid);
        assertGt(resting, 0, "premise: resting cash is left to take");
        uint256 aliceHad = usdc.balanceOf(alice);
        uint256 hubHad = usdc.balanceOf(address(ace));

        vm.expectEmit(true, true, true, true, address(ace));
        emit Lender.Withdraw(mid, alice, friend, resting);
        vm.prank(alice);
        uint256 paid = ace.withdraw(mid, type(uint256).max, friend, resting);

        assertEq(paid, resting, "the whole resting balance paid out");
        assertEq(usdc.balanceOf(friend), resting, "and it landed at the lender's chosen address");
        assertEq(usdc.balanceOf(alice), aliceHad, "and none of it at the caller");
        assertEq(hubHad - usdc.balanceOf(address(ace)), paid, "the hub let go of exactly the payment");
        assertEq(ace.restingOf(mid), 0, "the market is empty behind it");
    }

    /// @notice THE YIELD LEG: a refused lender takes the pooled credit to an address the quote accepts.
    function test_381_ARefusedLender_CollectsThePooledCreditToAFriend() public {
        usdc.setBlocked(alice, true);
        _lendAndRepay();
        (,, uint256 owed) = read.lenderPools(alice, address(usdc));
        assertGt(owed, 0, "premise: the refused push left the credit pooled");

        vm.expectEmit(true, true, true, true, address(ace));
        emit Lender.Collected(alice, address(usdc), friend, owed);
        vm.prank(alice);
        uint256 paid = ace.collect(address(usdc), friend);

        assertEq(paid, owed, "the whole pool paid out");
        assertEq(usdc.balanceOf(friend), owed, "and it landed at the lender's chosen address");
        (,, uint256 left) = read.lenderPools(alice, address(usdc));
        assertEq(left, 0, "nothing left pooled");
    }

    /// @notice #392: a draw landing first shrinks what `withdraw(max)` pays, and the lender's own floor refuses the smaller fill.
    function test_392_MinPaidRefusesTheFillADrawShrank() public {
        _lendAndRepay();
        uint256 seen = ace.restingOf(mid); // what the lender read when they signed
        _draw(PRINCIPAL); // lands first in the block
        uint256 now_ = ace.restingOf(mid);
        assertLt(now_, seen, "premise: the draw lowered the resting balance");

        vm.prank(alice);
        vm.expectRevert(BelowCallerFloor.selector);
        ace.withdraw(mid, type(uint256).max, alice, seen);

        vm.prank(alice);
        vm.expectRevert(BelowCallerFloor.selector);
        ace.withdraw(mid, type(uint256).max, friend, seen);

        vm.prank(alice);
        assertEq(ace.withdraw(mid, type(uint256).max, alice, now_), now_, "a floor AT the fill is met, not refused");
    }

    /// @notice `collect` spends only the caller's own pool: a stranger naming themselves takes nothing of the lender's.
    function test_381_AStrangersCollectPaysNothingOfTheLenders() public {
        usdc.setBlocked(alice, true);
        _lendAndRepay();
        (,, uint256 owed) = read.lenderPools(alice, address(usdc));
        assertGt(owed, 0, "premise: the lender has pooled credit to protect");

        vm.prank(stranger);
        assertEq(ace.collect(address(usdc), stranger), 0, "the stranger's own pool is empty, so nothing is paid");
        assertEq(usdc.balanceOf(stranger), 0, "and nothing reached them");
        (,, uint256 still) = read.lenderPools(alice, address(usdc));
        assertEq(still, owed, "the lender's pool is untouched");

        vm.prank(stranger);
        vm.expectRevert(NotTheLender.selector);
        ace.withdraw(mid, type(uint256).max, stranger, 0);
    }

    /// @notice A stranger's `withdraw` is refused as `NotTheLender` BEFORE any recipient rule, whatever `to` it names.
    /// @dev Pins the order: authority first, so a caller probing with a bad `to` learns nothing about the recipient rule.
    function test_381_AStrangersWithdrawIsNotTheLenderBeforeAnyRecipientCheck() public {
        _lendAndRepay();

        vm.prank(stranger);
        vm.expectRevert(NotTheLender.selector);
        ace.withdraw(mid, 0, address(ace), 0);

        vm.prank(stranger);
        vm.expectRevert(NotTheLender.selector);
        ace.withdraw(mid, 0, address(0), 0);
    }

    /// @notice THE SAME-SELECTOR TRAP, ACCEPTED BY RULING AND PINNED: old-order `collect(lender, quote)` calldata still lands.
    /// @notice It decodes as `collect(quote = lender, to = quote)`, reads the CALLER's pool in a "token" that is an address, and returns 0.
    /// @dev No revert, no log, no movement, from a stranger and from the lender alike; the lender's real pool is untouched.
    /// @dev `abi.encodeWithSignature` on purpose: a typed `abi.encodeCall` would refuse the old order, which is the whole trap.
    function test_381_ALegacyOrderCollectPaysNothingLogsNothingAndMovesNothing() public {
        usdc.setBlocked(alice, true); // the refused close push keeps the credit pooled, so there is a pool to protect
        _lendAndRepay();
        uint256 owed = ace.lenderOwed(alice, address(usdc));
        assertGt(owed, 0, "premise: the lender has pooled credit the old call used to fetch");
        bytes memory legacy = abi.encodeWithSignature("collect(address,address)", alice, address(usdc));
        uint256 hubBal = usdc.balanceOf(address(ace));

        address[2] memory callers = [stranger, alice];
        for (uint256 i; i < 2; i++) {
            vm.recordLogs();
            vm.prank(callers[i]);
            (bool ok, bytes memory ret) = address(ace).call(legacy);
            assertTrue(ok, "the old calldata does NOT revert: the selector survived the argument swap");
            assertEq(abi.decode(ret, (uint256)), 0, "it pays nothing");
            assertEq(vm.getRecordedLogs().length, 0, "and logs nothing: no `Collected`, no transfer");
            assertEq(ace.lenderOwed(alice, address(usdc)), owed, "the lender's pool is untouched");
            assertEq(usdc.balanceOf(address(ace)), hubBal, "and no quote left the hub");
        }
    }

    /// @notice `collect` applies the recipient rule BEFORE its empty-pool return, so a bad `to` refuses even owed nothing.
    function test_381_CollectRefusesABadRecipientOnAnEmptyPool() public {
        assertEq(ace.lenderOwed(alice, address(usdc)), 0, "premise: nothing is pooled, so the early return would fire");

        vm.prank(alice);
        vm.expectRevert(ExitToHub.selector);
        ace.collect(address(usdc), address(ace));

        vm.prank(alice);
        vm.expectRevert(ZeroWithdrawTo.selector);
        ace.collect(address(usdc), address(0));

        vm.prank(stranger);
        vm.expectRevert(ExitToHub.selector);
        ace.collect(address(usdc), address(ace));
    }

    /// @notice A zero destination is refused by name on both legs; the quote here would happily burn it.
    function test_381_AZeroDestinationIsRefusedOnBothLegs() public {
        usdc.setBlocked(alice, true);
        _lendAndRepay();

        vm.prank(alice);
        vm.expectRevert(ZeroWithdrawTo.selector);
        ace.withdraw(mid, type(uint256).max, address(0), 0);

        vm.prank(alice);
        vm.expectRevert(ZeroWithdrawTo.selector);
        ace.collect(address(usdc), address(0));
    }

    /// @notice The hub as destination is refused by name on both legs, and neither ledger moves.
    /// @dev A plain quote would transfer to itself and keep the cash with its ledger entry already debited.
    function test_381_TheHubAsDestinationIsRefusedOnBothLegs() public {
        usdc.setBlocked(alice, true);
        _lendAndRepay();
        uint256 resting = ace.restingOf(mid);
        (,, uint256 owed) = read.lenderPools(alice, address(usdc));
        assertGt(resting, 0, "premise: resting cash a hub-bound withdraw would debit");
        assertGt(owed, 0, "premise: pooled credit a hub-bound collect would zero");
        uint256 hubBal = usdc.balanceOf(address(ace));

        vm.prank(alice);
        vm.expectRevert(ExitToHub.selector);
        ace.withdraw(mid, type(uint256).max, address(ace), 0);

        vm.prank(alice);
        vm.expectRevert(ExitToHub.selector);
        ace.collect(address(usdc), address(ace));

        assertEq(ace.restingOf(mid), resting, "the resting cash is untouched");
        (,, uint256 still) = read.lenderPools(alice, address(usdc));
        assertEq(still, owed, "and so is the pooled credit");
        assertEq(usdc.balanceOf(address(ace)), hubBal, "and the hub's balance");
    }

    /// @dev A second loan against the same resting cash, standing in for a draw that lands before the lender's exit.
    function _draw(uint256 principal) internal {
        coll.mint(borrower, COLL);
        vm.startPrank(borrower);
        coll.approve(address(pm), COLL);
        ace.open(mid, COLL, principal, 0, borrower, OpenBounds(0, 0, 0));
        vm.stopPrank();
    }
}

/// @title AceP2DrawDust
/// @notice Audit run 2026-09-13-670568 phase 2, F3: a draw leaves resting cash strictly under `minDebt`.
/// @notice `AceInvariants._invariant_theDustWallIsUnreachable` says that state is unreachable through either door.
/// @dev The deposit and withdraw doors both refuse it; the draw is the third door that lowers cash, and it does not.
contract AceP2DrawDustTest is WarpClock {
    Ace internal ace;
    AceReader internal read;
    PositionManager internal pm;
    MockERC20 internal usdc;
    MockERC20 internal coll;
    bytes32 internal mid;

    address internal alice = address(0xA11CE);
    address internal borrower = address(0xB0B);
    address internal borrower2 = address(0xB0B3);

    uint256 internal constant COLL = 10_000e18;
    uint256 internal FLOOR; // the market's minDebt, read back from the fixture

    function setUp() public {
        _warpTo(1_000_000);
        usdc = new MockERC20("USD Coin", "USDC", 6);
        coll = new MockERC20("Collateral", "COLL", 18);
        MarketParams memory p = AceFixtures.marketParams(address(usdc), address(coll));
        p.lender = alice;
        AceFixtures.Deployment memory d = AceFixtures.deploy(p);
        (ace, pm, read, mid) = (d.ace, d.positionManager, d.read, d.id);
        FLOOR = p.minDebt;
    }

    function _rest(uint256 amt) internal {
        usdc.mint(alice, amt);
        vm.startPrank(alice);
        usdc.approve(address(ace), amt);
        ace.deposit(mid, amt);
        vm.stopPrank();
    }

    function _draw(address who, uint256 principal) internal returns (uint256 loanId) {
        coll.mint(who, COLL);
        vm.startPrank(who);
        coll.approve(address(pm), COLL);
        loanId = ace.open(mid, COLL, principal, 0, who, OpenBounds(0, 0, 0));
        vm.stopPrank();
    }

    /// @notice CONTROL: the two lender doors refuse the band, so the band is a property the code means to hold.
    function test_Control_BothLenderDoorsRefuseTheBand() public {
        _rest(2 * FLOOR);
        vm.prank(alice);
        vm.expectRevert(WouldLeaveDust.selector);
        ace.withdraw(mid, FLOOR + 1, alice, 0);
        usdc.mint(alice, FLOOR);
        vm.startPrank(alice);
        usdc.approve(address(ace), FLOOR);
        vm.expectRevert(BelowMinLot.selector);
        ace.deposit(mid, FLOOR - 1);
        vm.stopPrank();
    }

    /// @notice PREMISE: a minimum draw against one and a half floors leaves half a floor resting, which no draw can take.
    function test_Premise_AMinimumDrawLeavesHalfAFloor_AndNoDrawCanConsumeIt() public {
        _rest(FLOOR + FLOOR / 2);
        _draw(borrower, FLOOR);
        uint256 cash = ace.restingOf(mid);
        assertEq(cash, FLOOR / 2, "the draw left half a floor resting");
        coll.mint(borrower2, COLL);
        vm.startPrank(borrower2);
        coll.approve(address(pm), COLL);
        vm.expectRevert(InsufficientCash.selector);
        ace.open(mid, COLL, FLOOR, 0, borrower2, OpenBounds(0, 0, 0));
        vm.stopPrank();
        vm.prank(alice);
        assertEq(ace.withdraw(mid, type(uint256).max, alice, 0), FLOOR / 2, "the lender is not trapped: emptying still works");
    }

    /// @dev DELETED: `test_RED_ADrawNeverLeavesCashUnderMinDebt`, which asserted that resting cash is never
    /// @dev strictly between zero and `minDebt` whichever door moved it last. THE REMEDY WAS REJECTED, so the
    /// @dev row asserted a design nobody chose: C-18 was ACCEPTED, the draw is deliberately the unfloored third
    /// @dev door, and flooring it would refuse an otherwise-good draw to tidy a band in which nothing is trapped.
    /// @dev The two lender doors ARE floored and the rows above still pin that; `Types.sol` states the asymmetry.
}
