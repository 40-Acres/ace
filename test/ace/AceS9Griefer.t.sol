// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.36;

import {WarpClock} from "../utils/WarpClock.sol";
import {Ace} from "../../src/ace/hub/Ace.sol";
import {NotBorrower} from "../../src/ace/hub/Borrower.sol";
import {MarketParams, OpenBounds} from "../../src/ace/hub/Types.sol";
import {PositionManager} from "../../src/ace/positions/PositionManager.sol";
import {MockERC20} from "../mocks/MockERC20.sol";
import {MockPersistenceRecord} from "../mocks/MockPersistenceRecord.sol";
import {AceFixtures} from "../utils/AceFixtures.sol";
import {AceReader} from "../utils/AceReader.sol";

/// @title AceS9OpenThenArmIdRace
/// @notice Phase 9 (the griefer), run 2026-10-03-251533, finding F1.
/// @notice `setAutoRefinance` told a borrower to arm in the SAME multicall as the open, and a multicall leg is pre-encoded.
/// @notice The hub now says to arm from a contract reading `open`'s returned id; the Known row below pins the residual.
/// @notice So the arm leg names a PREDICTED id, `loanCount() + 1`, off a counter every market, order and roll on the hub shares.
/// @dev Form A: any id allocated first makes the batch revert. A griefer's cheapest bump is one order in a market of their own.
/// @dev Form B: if the id allocated first is ANOTHER loan of the same borrower, the batch LANDS and arms that loan instead.
/// @dev A keeper's free `refinanceByPolicy` of the borrower's other armed loan is such an allocation, so Form B also happens organically.
contract AceS9OpenThenArmIdRace is WarpClock {
    Ace internal ace;
    AceReader internal read;
    PositionManager internal pm;
    MockERC20 internal usdc;
    MockERC20 internal coll;
    MockPersistenceRecord internal rec;
    bytes32 internal id;

    MockERC20 internal gq; // the griefer's own quote
    MockERC20 internal gc; // the griefer's own collateral
    bytes32 internal gid; // the griefer's own market, created once

    address internal alice = address(0xA11CE); // the victim market's sole, honest lender
    address internal borrower = address(0xB0B); // opens and arms exactly as the hub's NatSpec says
    address internal keeper = address(0xCAFE); // an honest keeper rolling armed loans in their window
    address internal griefer = address(0x6E1EF); // holds nothing in the victim market

    uint64 internal constant TEN7 = 7 days;
    uint256 internal constant P = 50_000e6;
    uint256 internal constant UNITS = 100_000e18; // trigger at 0.7 of the price: a 30% cushion at the draw
    uint16 internal constant BUF = 1000; // the borrower's 10% risk distance

    function setUp() public {
        _warpTo(1_000_000);
        usdc = new MockERC20("USD Coin", "USDC", 6);
        coll = new MockERC20("Collateral", "COLL", 18);
        rec = new MockPersistenceRecord(address(usdc), address(coll));
        rec.setMinPrice(_px(1.1e18));
        AceFixtures.Deployment memory d = AceFixtures.deploy(_params());
        (ace, pm, read, id) = (d.ace, d.positionManager, d.read, d.id);
        _deposit(alice, 4 * P);

        gq = new MockERC20("Griefer Quote", "GQ", 18);
        gc = new MockERC20("Griefer Coll", "GC", 18);
        MarketParams memory g = AceFixtures.marketParams(address(gq), address(gc));
        g.lender = griefer;
        g.baseBps = 1;
        g.minTenor = 1 days;
        g.maxTenor = 1 days;
        g.minDebt = 2; // the smallest floor whose ceiled fee still sits under it
        gid = ace.createMarket(g);
        gc.mint(griefer, 1e30);
        vm.prank(griefer);
        gc.approve(address(pm), type(uint256).max);
    }

    function _px(uint256 human) internal view returns (uint256) {
        return AceFixtures.px(human, address(usdc), address(coll));
    }

    function _params() internal view returns (MarketParams memory p) {
        p = AceFixtures.marketParams(address(usdc), address(coll));
        p.record = address(rec);
        p.lender = alice;
        p.baseBps = 40;
        p.minTenor = TEN7;
        p.maxTenor = TEN7;
        p.settleBountyBps = 50;
        p.minCoverageWad = 1.4e18;
    }

    function _deposit(address who, uint256 amt) internal {
        usdc.mint(who, amt);
        vm.startPrank(who);
        usdc.approve(address(ace), amt);
        ace.deposit(id, amt);
        vm.stopPrank();
    }

    function _armed(uint256 loanId) internal view returns (bool) {
        (uint64 tenor,,) = read.autoPolicyOf(loanId);
        return tenor != 0;
    }

    /// @dev The batch the hub's NatSpec asks for: open, then arm the loan the open will create, in ONE multicall.
    /// @dev Built off the live counter, exactly as every in-tree caller of this pattern builds it.
    function _openAndArmBatch() internal returns (bytes[] memory calls, uint256 predicted) {
        coll.mint(borrower, UNITS);
        vm.prank(borrower);
        coll.approve(address(pm), UNITS);
        predicted = read.loanCount() + 1;
        calls = new bytes[](2);
        calls[0] = abi.encodeCall(Ace.open, (id, UNITS, P, TEN7, borrower, OpenBounds(0, 0, 0)));
        calls[1] = abi.encodeCall(Ace.setAutoRefinance, (predicted, TEN7, BUF, 0));
    }

    /// @dev The cheapest id allocation a stranger can buy: one minimum order in a market whose tokens they mint.
    function _bump() internal returns (uint256 gasUsed) {
        uint256 liq = ace.idToMarketParams(gid).price;
        vm.prank(griefer);
        uint256 g0 = gasleft();
        ace.postOrder(gid, 2, liq, liq, 0, 1 days, 0);
        gasUsed = g0 - gasleft();
    }

    /// @dev A first armed loan of the same borrower, now inside its roll window: the case Form B needs.
    function _secondArmedLoanInWindow() internal returns (uint256 first) {
        coll.mint(borrower, UNITS);
        vm.startPrank(borrower);
        coll.approve(address(pm), UNITS);
        first = ace.open(id, UNITS, P, TEN7, borrower, OpenBounds(0, 0, 0));
        ace.setAutoRefinance(first, TEN7, BUF, 0);
        vm.stopPrank();
        _warpTo(uint256(read.loan(first).expiry) - 1 hours);
        (bool ok,,) = ace.tryContinue(first);
        assertTrue(ok, "PREMISE: the first loan's roll is admissible and funded inside its window");
    }

    /// @notice CONTROL: with nothing allocated in between, the documented batch opens and arms the loan it opened.
    function test_Control_TheDocumentedBatchArmsTheLoanItOpens() public {
        (bytes[] memory calls, uint256 predicted) = _openAndArmBatch();
        vm.prank(borrower);
        ace.multicall(calls);
        assertEq(read.loan(predicted).borrower, borrower, "the open landed at the predicted id");
        assertTrue(_armed(predicted), "and the arm leg armed it");
        assertGt(read.reservedOf(predicted), 0, "holding its reservation");
    }

    /// @notice MEASURE, Form A: one stranger order in a market of their own, anywhere on the hub, reverts the borrower's batch.
    function test_Measure_FormA_AStrangerOrderInAnotherMarketRevertsTheBatch() public {
        (bytes[] memory calls,) = _openAndArmBatch();
        uint256 cost = _bump();
        emit log_named_uint("griefer's gas for one id bump (postOrder, own market)", cost);
        vm.prank(borrower);
        vm.expectRevert(NotBorrower.selector);
        ace.multicall(calls);
    }

    /// @notice MEASURE, Form B: a keeper's free roll of the borrower's OTHER armed loan lands first, and the batch then SUCCEEDS.
    /// @notice It arms the rolled successor a second time and leaves the loan it opened unarmed, with no revert to say so.
    function test_Measure_FormB_ARollOfAnotherLoanSilentlyRedirectsTheArm() public {
        uint256 first = _secondArmedLoanInWindow();
        (bytes[] memory calls, uint256 predicted) = _openAndArmBatch();

        vm.prank(keeper);
        uint256 successor = ace.refinanceByPolicy(first); // permissionless, pays nothing; honest or hostile alike
        assertEq(successor, predicted, "PREMISE: the roll took the id the batch predicted");

        vm.prank(borrower);
        ace.multicall(calls); // NO REVERT
        uint256 opened = predicted + 1;
        assertEq(read.loan(opened).borrower, borrower, "the open landed one id later");
        assertFalse(_armed(opened), "the loan the borrower opened is UNARMED");
        assertEq(read.reservedOf(opened), 0, "and reserves nothing");
        assertTrue(_armed(successor), "the arm leg landed on the rolled successor instead");

        _warpTo(read.loan(opened).expiry);
        vm.prank(keeper);
        ace.forceClose(opened);
        assertTrue(ace.isClosed(opened), "at its expiry the opened loan SETTLES, it does not roll");
        assertGt(read.invPotOf(id, opened), 0, "the lender's pot took the claim's collateral");
        emit log_named_uint("collateral the settlement took for the lender (units)", read.invPotOf(id, opened));
    }

    /// @notice KNOWN, disclosed rather than closed: a pre-encoded open-and-arm batch can land and arm ANOTHER loan of the borrower.
    /// @dev The hub's arming notice now says to arm from a contract that reads `open`'s returned id, never a predicted one.
    /// @dev Was the run's RED row; no hub verb was added to bind an arm to the open that precedes it.
    function test_Known_APredictedIdBatchCanArmALoanOtherThanTheOneItOpened() public {
        uint256 first = _secondArmedLoanInWindow();
        (bytes[] memory calls, uint256 predicted) = _openAndArmBatch();
        vm.prank(keeper);
        ace.refinanceByPolicy(first);

        vm.prank(borrower);
        ace.multicall(calls);
        uint256 opened = predicted + 1;
        assertFalse(_armed(opened), "the batch landed and left the loan it opened unarmed");
        assertTrue(_armed(predicted), "having armed the roll that took the predicted id");
    }
}

/// @title AceS9WithdrawRaceDeficit
/// @notice Phase 9 (the griefer), run 2026-10-03-251533, finding F2.
/// @notice `withdraw` takes a pre-encoded amount and may go under the roll reserve; nothing lets a lender say "never under".
/// @notice So a stranger's action landing between the lender's read of `drawableOf` and the withdraw turns it into a DEFICIT.
/// @notice At expiry an UNREPAID armed loan's fresh need equals its reservation exactly, so ANY deficit fails every such fold.
/// @notice A repaid loan's share can sit over its need (the shrink is floored at `minDebt - 1`), and that slack spares it a smaller deficit.
/// @notice ACCEPTED by user ruling (2026-10-04): a lender's withdraw ignores the reserve, so going under it is the lender's consent.
/// @dev Lever 1: the stranger ARMS a loan of their own (gas only), raising the reserve under the lender's stale amount.
/// @dev Lever 2: the stranger DRAINS `minDebt` (open then repay: the repaid principal goes to `owed`, never back to cash).
contract AceS9WithdrawRaceDeficit is WarpClock {
    Ace internal ace;
    AceReader internal read;
    PositionManager internal pm;
    MockERC20 internal usdc;
    MockERC20 internal coll;
    MockPersistenceRecord internal rec;
    bytes32 internal id;

    address internal alice = address(0xA11CE); // a direct lender who keeps backing armed rolls and takes only what is unreserved
    address internal borrower = address(0xB0B); // armed, set-and-forget
    address internal keeper = address(0xCAFE);
    address internal griefer = address(0x6E1EF); // no claim on anything alice or the borrower holds

    uint64 internal constant TEN7 = 7 days;
    uint256 internal constant P = 50_000e6;
    uint256 internal constant UNITS = 100_000e18;
    uint256 internal constant SPARE = 10_000e6; // alice's unreserved cash, which she means to take home

    uint256 internal loanId; // the honest armed loan
    uint256 internal gLoan; // the griefer's own small loan, opened unarmed

    function setUp() public {
        _warpTo(1_000_000);
        usdc = new MockERC20("USD Coin", "USDC", 6);
        coll = new MockERC20("Collateral", "COLL", 18);
        rec = new MockPersistenceRecord(address(usdc), address(coll));
        rec.setMinPrice(AceFixtures.px(1.1e18, address(usdc), address(coll)));
        MarketParams memory p = AceFixtures.marketParams(address(usdc), address(coll));
        p.record = address(rec);
        p.lender = alice;
        p.baseBps = 40;
        p.minTenor = TEN7;
        p.maxTenor = TEN7;
        p.settleBountyBps = 50;
        p.minCoverageWad = 1.4e18;
        AceFixtures.Deployment memory d = AceFixtures.deploy(p);
        (ace, pm, read, id) = (d.ace, d.positionManager, d.read, d.id);

        _deposit(3 * P);
        coll.mint(borrower, UNITS);
        vm.startPrank(borrower);
        coll.approve(address(pm), UNITS);
        loanId = ace.open(id, UNITS, P, TEN7, borrower, OpenBounds(0, 0, 0));
        ace.setAutoRefinance(loanId, TEN7, 0, 0);
        vm.stopPrank();

        uint256 md = ace.idToMarketParams(id).minDebt;
        coll.mint(griefer, 10 * UNITS);
        usdc.mint(griefer, 10 * P);
        vm.startPrank(griefer);
        coll.approve(address(pm), type(uint256).max);
        usdc.approve(address(ace), type(uint256).max);
        gLoan = ace.open(id, md * 4e12, md, TEN7, griefer, OpenBounds(0, 0, 0)); // a dust loan, kept UNARMED until needed
        vm.stopPrank();

        // alice trims to exactly the borrower's reservation plus her spare: she backs the roll and nothing more
        uint256 trim = ace.restingOf(id) - (read.rollReserve(id) + SPARE);
        vm.prank(alice);
        ace.withdraw(id, trim, alice, 0);
        assertEq(ace.drawableOf(id), SPARE, "PREMISE: the spare is exactly what a fresh draw may take");
    }

    function _deposit(uint256 amt) internal {
        usdc.mint(alice, amt);
        vm.startPrank(alice);
        usdc.approve(address(ace), type(uint256).max);
        ace.deposit(id, amt);
        vm.stopPrank();
    }

    /// @dev Alice's transaction, built off the block before: take what `drawableOf` said, and refuse to be paid less.
    function _aliceTakesHerSpare(uint256 seen) internal returns (bool landed) {
        vm.prank(alice);
        try ace.withdraw(id, seen, alice, seen) returns (uint256) {
            landed = true;
        } catch {
            landed = false;
        }
    }

    function _foldRolled() internal returns (bool) {
        _warpTo(read.loan(loanId).expiry);
        vm.prank(keeper);
        ace.forceClose(loanId);
        return read.invPotOf(id, loanId) == 0;
    }

    /// @notice CONTROL: with nothing in between, alice takes her spare, leaves exactly the reserve, and the fold rolls.
    function test_Control_TakingExactlyTheSpareKeepsTheRoll() public {
        uint256 seen = ace.drawableOf(id);
        assertTrue(_aliceTakesHerSpare(seen), "the withdraw lands");
        assertEq(ace.restingOf(id), read.rollReserve(id), "it leaves exactly the reserve");
        assertTrue(_foldRolled(), "and the armed loan rolls at its expiry fold");
    }

    /// @notice MEASURE, lever 1: the griefer arms their own dust loan in front of alice; gas only, nothing drawn.
    /// @notice Alice's withdraw still lands, paid in full, and the market is left under its reserve by the griefer's share.
    function test_Measure_Lever1_AStrangersArmTurnsTheLendersWithdrawIntoADeficit() public {
        uint256 seen = ace.drawableOf(id);
        vm.prank(griefer);
        uint256 g0 = gasleft();
        ace.setAutoRefinance(gLoan, TEN7, 0, 0);
        emit log_named_uint("griefer's gas for the arm", g0 - gasleft());
        uint256 share = read.reservedOf(gLoan);
        emit log_named_uint("griefer's reservation (quote atoms)", share);
        assertGt(share, 0, "PREMISE: the arm reserved something");

        assertTrue(_aliceTakesHerSpare(seen), "alice's withdraw lands and pays her floor in full");
        assertLt(ace.restingOf(id), read.rollReserve(id), "the market now rests UNDER its roll reserve");
        emit log_named_uint("deficit (quote atoms)", read.rollReserve(id) - ace.restingOf(id));
        assertFalse(_foldRolled(), "and the honest armed loan SETTLES at its expiry fold");
        emit log_named_uint("units the settlement took for the lender", read.invPotOf(id, loanId));
    }

    /// @notice MEASURE, lever 2: the griefer drains `minDebt` (open, repay, claim) in front of alice; one fee's worth.
    function test_Measure_Lever2_AStrangersMinDebtDrainTurnsTheLendersWithdrawIntoADeficit() public {
        uint256 seen = ace.drawableOf(id);
        uint256 md = ace.idToMarketParams(id).minDebt;
        uint256 bal0 = usdc.balanceOf(griefer);
        uint256 next = read.loanCount() + 1; // the griefer's OWN batch, so the prediction is theirs to get right
        bytes[] memory calls = new bytes[](3);
        calls[0] = abi.encodeCall(Ace.open, (id, md * 4e12, md, TEN7, griefer, OpenBounds(0, 0, 0)));
        calls[1] = abi.encodeCall(Ace.repay, (next, md));
        calls[2] = abi.encodeWithSignature("claimOwed(uint256,address)", next, griefer);
        vm.prank(griefer);
        ace.multicall(calls);
        emit log_named_uint("griefer's quote cost of the drain (atoms)", bal0 - usdc.balanceOf(griefer));

        assertTrue(_aliceTakesHerSpare(seen), "alice's withdraw lands and pays her floor in full");
        assertLt(ace.restingOf(id), read.rollReserve(id), "the market now rests UNDER its roll reserve");
        assertFalse(_foldRolled(), "and the honest armed loan SETTLES at its expiry fold");
    }

    /// @notice MEASURE, lever 2 at zero cost: the griefer FILLS an honest maker's standing order; the maker pays the fee.
    function test_Measure_Lever2Free_AStrangersFillOfSomeoneElsesOrderTurnsTheWithdrawIntoADeficit() public {
        address maker = address(0x3A4E);
        uint256 amount = 100e6; // a small honest ask, all-or-nothing
        uint256 liq = ace.idToMarketParams(id).price / 2;
        coll.mint(maker, amount * 4e12);
        vm.startPrank(maker);
        coll.approve(address(pm), amount * 4e12);
        uint256 orderId = ace.postOrder(id, amount, liq, liq, amount, TEN7, 0);
        vm.stopPrank();
        uint256 escrow = ace.orderOf(orderId).collateralUnits;

        uint256 seen = ace.drawableOf(id);
        uint256 bal0 = usdc.balanceOf(griefer);
        vm.prank(griefer);
        ace.fillOrder(orderId, amount, escrow);
        assertEq(usdc.balanceOf(griefer), bal0, "the griefer spent no quote at all");

        assertTrue(_aliceTakesHerSpare(seen), "alice's withdraw lands and pays her floor in full");
        assertLt(ace.restingOf(id), read.rollReserve(id), "the market now rests UNDER its roll reserve");
        assertFalse(_foldRolled(), "and the honest armed loan SETTLES at its expiry fold");
    }

    /// @notice CONTROL, self-healing: a deficit smaller than one loan's reservation settles ONE fold, whose release cures it.
    function test_Control_ASmallDeficitSettlesOnlyTheNextFold() public {
        uint256 second = _secondArmedLoan();
        uint256 seen = ace.drawableOf(id);
        vm.prank(griefer);
        ace.setAutoRefinance(gLoan, TEN7, 0, 0); // the 44,195-atom arm
        assertTrue(_aliceTakesHerSpare(seen), "alice's withdraw lands");
        _warpTo(read.loan(second).expiry);
        vm.startPrank(keeper);
        ace.forceClose(loanId);
        ace.forceClose(second);
        vm.stopPrank();
        assertGt(read.invPotOf(id, loanId), 0, "the fold cranked first settled");
        assertEq(read.invPotOf(id, second), 0, "its released reservation cured the deficit, so the next fold rolled");
    }

    /// @notice MEASURE, fan-out: a drain sized at the WHOLE roll reserve settles every armed fold in the market.
    /// @notice Each settlement frees only its own share, so the deficit stands until the last armed loan has settled.
    function test_Measure_AReserveSizedDrainSettlesEveryArmedFoldInTheMarket() public {
        uint256 second = _secondArmedLoan();
        uint256 seen = ace.drawableOf(id);
        uint256 x = read.rollReserve(id); // all alice left behind for the rolls she meant to back
        emit log_named_uint("drain size = the market's whole roll reserve (quote atoms)", x);
        uint256 bal0 = usdc.balanceOf(griefer);
        uint256 next = read.loanCount() + 1;
        bytes[] memory calls = new bytes[](3);
        calls[0] = abi.encodeCall(Ace.open, (id, x * 4e12, x, TEN7, griefer, OpenBounds(0, 0, 0)));
        calls[1] = abi.encodeCall(Ace.repay, (next, x));
        calls[2] = abi.encodeWithSignature("claimOwed(uint256,address)", next, griefer);
        vm.prank(griefer);
        ace.multicall(calls);
        emit log_named_uint("griefer's quote cost of the drain (atoms)", bal0 - usdc.balanceOf(griefer));
        assertTrue(_aliceTakesHerSpare(seen), "alice's withdraw lands, paid her floor in full");
        assertEq(ace.restingOf(id), 0, "and leaves the market with nothing resting behind its reservations");

        _warpTo(read.loan(second).expiry);
        vm.startPrank(keeper);
        ace.forceClose(loanId);
        ace.forceClose(second);
        vm.stopPrank();
        assertGt(read.invPotOf(id, loanId), 0, "the first honest armed loan settled");
        assertGt(read.invPotOf(id, second), 0, "and so did the second: no settlement freed enough to cure the deficit");
    }

    /// @dev A second honest borrower, armed at the same tenor, opened before alice reads `drawableOf`.
    function _secondArmedLoan() internal returns (uint256 second) {
        address other = address(0xB0B2);
        coll.mint(other, UNITS / 10);
        vm.startPrank(other);
        coll.approve(address(pm), UNITS / 10);
        second = ace.open(id, UNITS / 10, P / 10, TEN7, other, OpenBounds(0, 0, 0));
        ace.setAutoRefinance(second, TEN7, 0, 0);
        vm.stopPrank();
    }

    /// @notice KNOWN, ACCEPTED: a stranger's arm ahead of a stale `drawableOf` amount turns it into a deficit.
    /// @dev A lender's withdraw ignores the reserve by ruling, so going under is its consent; the armed promise is "funded unless your lender withdraws".
    /// @dev Was the run's RED row. A contract lender closes it by capping at `drawableOf` in the same call; a CuratorVault holds roll cover in idle.
    function test_Known_AStaleSpareWithdrawAfterAStrangersArmSettlesAnArmedFold() public {
        uint256 seen = ace.drawableOf(id);
        vm.prank(griefer);
        ace.setAutoRefinance(gLoan, TEN7, 0, 0);
        assertTrue(_aliceTakesHerSpare(seen), "alice's stale amount lands in full");
        assertLt(ace.restingOf(id), read.rollReserve(id), "the market rests under its roll reserve");
        assertFalse(_foldRolled(), "and the honest armed loan settles at its fold: the accepted race");
    }
}
