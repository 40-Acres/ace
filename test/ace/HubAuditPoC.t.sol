// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.36;

import {WarpClock} from "../utils/WarpClock.sol";
import {Ace} from "../../src/ace/hub/Ace.sol";
import {InsufficientCash, LoanClosed, RollUnbacked} from "../../src/ace/hub/Borrower.sol";
import {MarketParams, OpenBounds, Order} from "../../src/ace/hub/Types.sol";
import {PositionManager} from "../../src/ace/positions/PositionManager.sol";
import {PositionTitleNFT} from "../../src/ace/positions/PositionTitleNFT.sol";
import {AceLens} from "../../src/ace/lens/AceLens.sol";
import {AceInventoryLens} from "../../src/ace/lens/AceInventoryLens.sol";
import {MockERC20} from "../mocks/MockERC20.sol";
import {MockBlacklistERC20} from "../mocks/MockBlacklistERC20.sol";
import {MockPersistenceRecord} from "../mocks/MockPersistenceRecord.sol";
import {AceFixtures} from "../utils/AceFixtures.sol";
import {AceReader} from "../utils/AceReader.sol";

/// @title HubAuditPoC
/// @notice The PoC rows of the 2026-10-18 hub audit suite (`docs/ai/audit/findings/hub-audit-suite-2026-10-18.md`), main `58da8e3c`.
/// @notice Every row is a MEASUREMENT of a disclosed or newly-named mechanism, named `test_<Row>_*`; a row that would FAIL on current code is `test_RED_*`.
/// @dev One hub and one record-backed USDC/COLL market lent by alice at par; the record's minimum sits 10% over par, so the ask lifts to it.
/// @dev Row D stands up a second market on a blacklisting quote, since the shipped mock has no transfer hook a treasury can refuse by.
contract HubAuditPoC is WarpClock {
    Ace internal ace;
    PositionManager internal pm;
    AceReader internal read;
    AceLens internal lens;
    AceInventoryLens internal inv;
    PositionTitleNFT internal title;
    MockERC20 internal usdc;
    MockERC20 internal coll;
    MockPersistenceRecord internal rec;
    bytes32 internal id;

    address internal alice = address(0xA11CE); // the market's sole lender
    address internal borrower = address(0xB0B);
    address internal maker = address(0x4A6E); // posts a credit order the stranger fills
    address internal stranger = address(0x57A1); // holds nothing in the market
    address internal buyer = address(0xB04E5);
    address internal keeper = address(0xCAFE);

    uint64 internal constant TEN7 = 7 days;
    uint256 internal constant P = 50_000e6;
    uint256 internal constant UNITS = 100_000e18; // trigger at 0.7 of par: a 30% cushion at the draw
    uint256 internal constant MIN_DEBT = 10e6;

    function setUp() public {
        _warpTo(1_000_000);
        usdc = new MockERC20("USD Coin", "USDC", 6);
        coll = new MockERC20("Collateral", "COLL", 18);
        rec = new MockPersistenceRecord(address(usdc), address(coll));
        rec.setMinPrice(_px(1.1e18));
        AceFixtures.Deployment memory d = AceFixtures.deploy(_params(address(usdc), address(rec)));
        (ace, pm, read, id) = (d.ace, d.positionManager, d.read, d.id);
        lens = new AceLens(address(ace));
        inv = new AceInventoryLens(address(ace), address(lens));
        title = PositionTitleNFT(ace.POSITION_TITLE());
        _deposit(id, usdc, alice, 4 * P);
        coll.mint(maker, 100 * UNITS);
        vm.prank(maker);
        coll.approve(address(pm), type(uint256).max);
    }

    function _px(uint256 human) internal view returns (uint256) {
        return AceFixtures.px(human, address(usdc), address(coll));
    }

    function _params(address quote, address record) internal view returns (MarketParams memory p) {
        p = AceFixtures.marketParams(quote, address(coll));
        p.record = record;
        p.lender = alice;
        p.baseBps = 40;
        p.minTenor = TEN7;
        p.maxTenor = TEN7;
        p.settleBountyBps = 50;
        p.minCoverageWad = 1.4e18;
        p.minDebt = MIN_DEBT;
        p.inventoryAsk = true;
        p.fillFeeBps = 25;
    }

    function _deposit(bytes32 mid, MockERC20 q, address who, uint256 amt) internal {
        q.mint(who, amt);
        vm.startPrank(who);
        q.approve(address(ace), amt);
        ace.deposit(mid, amt);
        vm.stopPrank();
    }

    function _open(bytes32 mid, address who, uint256 principal) internal returns (uint256 loanId) {
        coll.mint(who, UNITS);
        vm.startPrank(who);
        coll.approve(address(pm), UNITS);
        loanId = ace.open(mid, UNITS, principal, TEN7, who, OpenBounds(0, 0, 0));
        vm.stopPrank();
    }

    function _arm(uint256 loanId) internal {
        vm.prank(read.loan(loanId).borrower);
        ace.setAutoRefinance(loanId, TEN7, 0, 0);
    }

    /// @dev Settle by persistent distress, then stand at the second the pot's ask opens.
    function _finalize(uint256 loanId) internal {
        rec.setBelow(true);
        vm.prank(keeper);
        ace.finalize(loanId);
        rec.setBelow(false);
        _warpAtLeastTo(read.inventoryAskOpensAt(loanId));
    }

    function _buy(address who, uint256 loanId, uint256 budget) internal returns (uint256 unitsOut, uint256 filled) {
        usdc.mint(who, budget);
        vm.startPrank(who);
        usdc.approve(address(ace), budget);
        (unitsOut, filled) = ace.buyInventory(loanId, budget, 0, who);
        vm.stopPrank();
    }

    function _unsold() internal view returns (uint256 n) {
        (n,) = ace.lenderUnresolved(alice, address(usdc));
    }

    /* ================================================================== */
    /*  Row A: a sub-quantum tail keeps a settled pot counted as unsold    */
    /* ================================================================== */

    /// @notice A buyer who pays one quote atom under the whole-pot charge takes everything but a tail worth ZERO quote atoms, and the tail stays an unsold pot.
    /// @notice Any CuratorVault lending in this pair reads `unsoldPots == 1` and shuts entry over a pot nobody can value above zero; two quote atoms clear it.
    /// @dev The counter does what `lenderUnresolved`'s NatSpec says ("a partial sale leaves it counted"); the row prices how little the partial can leave.
    function test_A1_ATailWorthZeroQuoteAtomsStaysAnUnsoldPot_TwoAtomsClearIt() public {
        uint256 loanId = _open(id, borrower, P);
        _finalize(loanId);
        uint256 pot = read.invPotOf(id, loanId);
        assertGt(pot, 0, "PREMISE: the settlement left a pot");
        assertEq(_unsold(), 1, "PREMISE: it counts as one unsold pot");
        uint256 whole = inv.clearingBudget(id, loanId);

        (uint256 got, uint256 paid) = _buy(stranger, loanId, whole - 1);
        uint256 tail = read.invPotOf(id, loanId);
        assertGt(tail, 0, "one atom under the whole charge takes the part leg and leaves a tail");
        assertLt(tail * 1_000_000, pot, "the tail is under a millionth of the pot");
        assertLe(paid, whole - 1, "the buyer paid at least one atom less than a whole buy");
        assertEq(got, pot - tail, "and holds everything but the tail");
        assertLe(lens.inventoryMark(id, loanId), 1, "the tail is worth at most one quote atom at the ask");
        assertEq(_unsold(), 1, "yet the pair still carries one UNSOLD pot");

        uint256 clear = inv.clearingBudget(id, loanId);
        assertLe(clear, 3, "the tail's whole-pot charge is a few quote atoms: the ceiled value plus the ceiled fee");
        emit log_named_uint("tail (collateral atoms)", tail);
        emit log_named_uint("tail's clearing charge (quote atoms)", clear);
        _buy(buyer, loanId, clear);
        assertEq(read.invPotOf(id, loanId), 0, "those atoms empty it");
        assertEq(_unsold(), 0, "and clear the count");
    }

    /* ================================================================== */
    /*  Row B: a stranger's fill of a third party's order disarms the fold  */
    /* ================================================================== */

    /// @dev A maker's order for exactly the market's spare cash, resting beside the armed loan.
    function _orderForTheSpare() internal returns (uint256 oid, uint256 spare) {
        spare = ace.drawableOf(id);
        uint256 par = ace.idToMarketParams(id).price;
        vm.prank(maker);
        oid = ace.postOrder(id, spare, par, par, 0, TEN7, 0);
    }

    /// @notice CONTROL: with the spare cash untouched, the fold rolls the armed loan and its successor is born ARMED.
    function test_B1_Control_TheFoldReArmsTheSuccessorWhenSpareCashRests() public {
        uint256 loanId = _open(id, borrower, P);
        _arm(loanId);
        _orderForTheSpare(); // posted, never filled
        _warpTo(read.loan(loanId).expiry);
        vm.prank(keeper);
        ace.forceClose(loanId);
        uint256 newId = read.loanCount();
        assertFalse(ace.isClosed(newId), "the loan rolled into a live successor");
        (uint64 t,,) = read.autoPolicyOf(newId);
        assertEq(t, TEN7, "the successor is armed");
        assertGt(read.reservedOf(newId), 0, "and holds its own reservation");
    }

    /// @notice A stranger fills the maker's order in the fold's block: the MAKER pays the fee, the stranger gas, and the successor is born DISARMED.
    /// @notice The roll itself lands (armed means reserved held), so the borrower's chain silently stops one term later.
    /// @dev The documented levers are the lender's withdraw and a stranger's own open or arm; a fill costs the stranger nothing but gas.
    function test_B2_AStrangersFillOfAnotherMakersOrderLeavesTheSuccessorDisarmed() public {
        uint256 loanId = _open(id, borrower, P);
        _arm(loanId);
        uint256 rr = read.rollReserve(id);
        (uint256 oid, uint256 spare) = _orderForTheSpare();
        assertGt(spare, 0, "PREMISE: spare cash rests past the reserve");

        _warpTo(read.loan(loanId).expiry);
        Order memory o = ace.orderOf(oid);
        uint256 before = usdc.balanceOf(stranger);
        vm.prank(stranger);
        uint256 g0 = gasleft();
        ace.fillOrder(oid, spare, o.collateralUnits);
        uint256 gasUsed = g0 - gasleft();
        assertEq(usdc.balanceOf(stranger), before, "the stranger paid no quote: the maker's loan paid the fee");
        assertEq(ace.drawableOf(id), 0, "the spare cash is gone");
        assertEq(read.rollReserve(id), rr, "and the reserve is intact");
        (bool ok,,) = ace.tryContinue(loanId);
        assertTrue(ok, "the roll is still admissible: the reservation did its job");

        vm.prank(keeper);
        ace.forceClose(loanId);
        uint256 newId = read.loanCount();
        assertFalse(ace.isClosed(newId), "the loan rolled");
        (uint64 t,,) = read.autoPolicyOf(newId);
        assertEq(t, 0, "but the successor is born DISARMED");
        assertEq(read.reservedOf(newId), 0, "holding no reservation");
        emit log_named_uint("stranger's fill gas", gasUsed);
    }

    /* ================================================================== */
    /*  Row C: the lens reports a retired loan as armed forever            */
    /* ================================================================== */

    /// @notice After the fold rolls an armed loan, `AceLens.autoPolicyOf(oldId)` still answers the old tenor: the stale entry is read raw.
    /// @notice The lens NatSpec says a sponsor enumerates the armed set from it; every HUB reader gates on `closedAt` first.
    function test_C1_TheLensReportsARolledLoanArmed() public {
        uint256 loanId = _open(id, borrower, P);
        _arm(loanId);
        _warpTo(read.loan(loanId).expiry);
        vm.prank(keeper);
        ace.forceClose(loanId);
        assertTrue(ace.isClosed(loanId), "PREMISE: the old loan is retired");

        (uint64 t,,) = lens.autoPolicyOf(loanId);
        assertEq(t, TEN7, "the lens still reports the retired loan armed");
        assertEq(lens.reservedOf(loanId), 0, "while its reservation is zero");
        (bool ok, bytes4 reason,) = ace.tryContinue(loanId);
        assertFalse(ok, "and the hub refuses to continue it");
        assertEq(reason, LoanClosed.selector, "because it is closed, which the lens's armed answer never says");
    }

    /* ================================================================== */
    /*  Row D: a refused piggyback sweep stamps the clock anyway           */
    /* ================================================================== */

    /// @notice A treasury the quote refuses makes the keeper piggyback restore the counter but keep the stamp, so the next crank waits a whole period.
    /// @notice The standalone `sweepRevenue` is not rate-limited, so nothing strands; the stamp means "last attempt", not "last delivery".
    function test_D1_ARefusedPiggybackSweepStampsTheClockAndDefersTheNextCrankForAPeriod() public {
        MockBlacklistERC20 blk = new MockBlacklistERC20("Blacklisting USD", "BUSD", 6);
        MockPersistenceRecord rec2 = new MockPersistenceRecord(address(blk), address(coll));
        rec2.setMinPrice(AceFixtures.px(1.1e18, address(blk), address(coll)));
        bytes32 bid = ace.createMarket(_params(address(blk), address(rec2)));
        blk.mint(alice, 4 * P);
        vm.startPrank(alice);
        blk.approve(address(ace), 4 * P);
        ace.deposit(bid, 4 * P);
        vm.stopPrank();

        uint256 a = _open(bid, borrower, P);
        _warpBy(1 hours);
        uint256 b = _open(bid, borrower, P);
        uint256 rev = read.protocolRevenue(bid);
        assertGt(rev, 0, "PREMISE: two draws banked origination revenue");

        address treasury = AceFixtures.TREASURY;
        blk.setBlacklisted(treasury, true);
        _warpTo(read.loan(a).expiry);
        vm.prank(keeper);
        ace.forceClose(a);
        assertEq(read.protocolRevenue(bid), rev, "the refused piggyback restored the counter");
        assertEq(read.marketState(bid).lastSweptAt, _now(), "but stamped the clock as if the revenue had left");

        blk.setBlacklisted(treasury, false);
        _warpTo(read.loan(b).expiry); // one hour later, the refusal lifted
        vm.prank(keeper);
        ace.forceClose(b);
        assertEq(read.protocolRevenue(bid), rev, "the next crank does not retry inside the period");
        assertEq(blk.balanceOf(treasury), 0, "so nothing has reached the treasury");

        ace.sweepRevenue(bid);
        assertEq(blk.balanceOf(treasury), rev, "the standalone door delivers at once");
    }

    /* ================================================================== */
    /*  Row E: a post-close title sale moves no credit                     */
    /* ================================================================== */

    /// @notice A loan's claim credits are keyed to the holder AT CLOSE: a title sold after settlement carries nothing to its buyer.
    /// @notice `retitle` says every loanId-keyed field rides along; the credits are loanId-keyed and do not. The hub pays whom it credited.
    function test_E1_APostCloseTitleSaleCarriesNoCreditToTheBuyer() public {
        uint256 loanId = _open(id, borrower, P);
        rec.setBelow(true);
        vm.prank(keeper);
        ace.finalize(loanId);
        (uint256 owedUnits,) = ace.owedOf(loanId, borrower);
        assertGt(owedUnits, 0, "PREMISE: the settlement credited the holder a residual");

        vm.prank(borrower);
        title.transferFrom(borrower, buyer, loanId);
        assertEq(ace.borrowerOf(loanId), buyer, "the title moved and the hub recorded the buyer");
        (uint256 buyerUnits,) = ace.owedOf(loanId, buyer);
        assertEq(buyerUnits, 0, "the buyer holds title to a loan that credits them nothing");
        (uint256 stillOwed,) = ace.owedOf(loanId, borrower);
        assertEq(stillOwed, owedUnits, "the seller keeps the whole credit");

        vm.prank(buyer);
        (uint256 got,) = ace.claimOwed(loanId, buyer);
        assertEq(got, 0, "the buyer's claim pays nothing");
        vm.prank(borrower);
        (got,) = ace.claimOwed(loanId, borrower);
        assertEq(got, owedUnits, "the seller's claim pays the residual");
    }

    /* ================================================================== */
    /*  Row G: a stranger's zero repay is admitted and moves nothing       */
    /* ================================================================== */

    /// @notice `repay(id, 0)` from any address lands on a loan at or over `minDebt`: a zero pull, a zero melt, two events, and no field moves.
    function test_G1_AStrangersZeroRepayLandsAndMovesNothing() public {
        uint256 loanId = _open(id, borrower, P);
        _arm(loanId);
        uint256 debt0 = read.debtOf(loanId);
        uint256 reserved0 = read.reservedOf(loanId);
        uint256 rr0 = read.rollReserve(id);
        (uint256 resting0, uint256 lent0, uint256 owed0) = read.poolOf(id);

        vm.prank(stranger);
        ace.repay(loanId, 0);

        assertEq(read.debtOf(loanId), debt0, "debt unchanged");
        assertEq(read.reservedOf(loanId), reserved0, "the loan's share unchanged");
        assertEq(read.rollReserve(id), rr0, "the market's reserve unchanged");
        (uint256 resting1, uint256 lent1, uint256 owed1) = read.poolOf(id);
        assertEq(resting1, resting0, "resting unchanged");
        assertEq(lent1, lent0, "lent unchanged");
        assertEq(owed1, owed0, "owed unchanged");
        assertFalse(ace.isClosed(loanId), "the loan is live");
    }

    /* ================================================================== */
    /*  Row F: the recommended lender posture disarms every successor      */
    /* ================================================================== */

    /// @notice `withdraw`'s NatSpec tells a lender to cap at `drawableOf`; at exactly that posture the fold ROLLS, then disarms the successor.
    /// @notice The successor needs `rollNeed(P) > rollNeed(D)` of UNRESERVED cash on top of the roll's draw, and there is none; the re-arm reverts.
    /// @dev "Armed means reserved" holds for ONE roll; the chain ends after it unless the lender leaves a cushion no NatSpec names.
    function test_F1_TheRecommendedLenderPostureDisarmsTheSuccessorAndRefusesTheReArm() public {
        uint256 loanId = _open(id, borrower, P);
        _arm(loanId);
        uint256 spare = ace.drawableOf(id);
        vm.prank(alice);
        ace.withdraw(id, spare, alice, 0); // the documented posture: keep exactly the reserve
        assertEq(ace.restingOf(id), read.rollReserve(id), "PREMISE: the lender rests exactly the roll reserve");
        assertEq(ace.drawableOf(id), 0, "PREMISE: nothing is drawable");

        _warpTo(read.loan(loanId).expiry);
        (bool ok,,) = ace.tryContinue(loanId);
        assertTrue(ok, "the armed roll is admissible: its reservation backs it");
        vm.prank(keeper);
        ace.forceClose(loanId);
        uint256 newId = read.loanCount();
        assertFalse(ace.isClosed(newId), "the loan rolled once");
        (uint64 t,,) = read.autoPolicyOf(newId);
        assertEq(t, 0, "and its successor is born DISARMED");
        assertEq(ace.restingOf(id), 0, "the roll drew the whole reserve: the market rests nothing");

        vm.prank(borrower);
        vm.expectRevert(RollUnbacked.selector);
        ace.setAutoRefinance(newId, TEN7, 0, 0);
    }

    /* ================================================================== */
    /*  Row H: a one-transaction drain disarms a victim's successor         */
    /* ================================================================== */

    /// @notice ONE multicall: open a loan for every unreserved atom, fold the victim, repay; the victim rolls DISARMED for ~0.24% of the free cash.
    /// @notice The escrow half of the origination fee refunds whole in the same block (`remaining == tenor`), so only the tick and protocol legs are spent.
    /// @dev Sharpens the disclosed `_carry` disarm: no lender, no maker, no second block, and a cost flat in the market's free cash.
    function test_H1_AOneTransactionDrainFoldAndRepayDisarmsTheVictimForAQuarterPercentOfFreeCash() public {
        uint256 victim = _open(id, borrower, P);
        _arm(victim);
        uint256 free = ace.drawableOf(id);
        assertGt(free, 0, "PREMISE: free cash rests past the reserve");
        _warpTo(read.loan(victim).expiry);

        coll.mint(stranger, 4 * UNITS); // the drain is ~3x the victim's loan, so it posts ~3x the collateral
        usdc.mint(stranger, free); // enough to repay the drain's whole debt
        vm.startPrank(stranger);
        coll.approve(address(pm), 4 * UNITS);
        usdc.approve(address(ace), type(uint256).max);
        uint256 drainId = read.loanCount() + 1;
        bytes[] memory legs = new bytes[](3);
        legs[0] = abi.encodeCall(Ace.open, (id, 4 * UNITS, free, TEN7, stranger, OpenBounds(0, 0, 0)));
        legs[1] = abi.encodeCall(Ace.forceClose, (victim));
        legs[2] = abi.encodeCall(Ace.repay, (drainId, free));
        uint256 quote0 = usdc.balanceOf(stranger);
        ace.multicall(legs);
        vm.stopPrank();

        assertTrue(ace.isClosed(drainId), "the drain loan is closed in the same transaction");
        uint256 successor = drainId + 1;
        assertFalse(ace.isClosed(successor), "the victim rolled into a live successor");
        (uint64 t,,) = read.autoPolicyOf(successor);
        assertEq(t, 0, "born DISARMED");

        // the griefer's net cost: what it paid in less the escrow refund credited back to it
        (, uint256 refund) = ace.owedOf(drainId, stranger);
        uint256 spent = quote0 - usdc.balanceOf(stranger) - refund;
        emit log_named_uint("griefer net cost (quote atoms)", spent);
        emit log_named_uint("free cash drained (quote atoms)", free);
        assertLt(spent * 10_000, free * 30, "the net cost is under 0.30% of the free cash it drained");
        // the control: the identical fold with the free cash untouched re-arms (row B1)
    }

    /* ================================================================== */
    /*  Row I: a one-atom-claim pot is a permanent unsold pot              */
    /* ================================================================== */

    /// @notice A minimum ticket repaid to one atom and left to expire settles into a pot worth ONE quote atom; `unsoldPots` rises by one for good.
    /// @notice The counter has no size floor, and the one party who can make a pot arbitrarily small is the one who pays almost nothing for it.
    /// @dev It costs the fee on `minDebt` (0.044 USDC at 40 bps/7d); the lender clears it by `redeemInKind`, or anyone for two quote atoms after the hold.
    function test_I1_AOneAtomClaimPotRaisesUnsoldPotsForTheCostOfAMinimumTicket() public {
        uint256 loanId = _open(id, borrower, MIN_DEBT);
        uint256 fee = read.loan(loanId).lastFee;
        usdc.mint(borrower, MIN_DEBT);
        vm.startPrank(borrower);
        usdc.approve(address(ace), MIN_DEBT);
        ace.repay(loanId, MIN_DEBT - 1); // only the borrower may leave (0, minDebt)
        vm.stopPrank();
        assertEq(read.debtOf(loanId), 1, "PREMISE: one atom of debt is left");

        _warpTo(read.loan(loanId).expiry + MarketInitWindow.rollWindow(TEN7) + 1);
        vm.prank(stranger);
        ace.settleExpired(loanId);
        uint256 pot = read.invPotOf(id, loanId);
        assertGt(pot, 0, "the one-atom claim converted into a pot");
        assertLe(lens.inventoryMark(id, loanId), 1, "worth at most one quote atom at the ask");
        assertEq(_unsold(), 1, "and it counts as an UNSOLD pot");
        emit log_named_uint("griefer cost: origination fee (quote atoms)", fee);
        emit log_named_uint("pot (collateral atoms)", pot);
    }

    /* ================================================================== */
    /*  Row J: dust-armed loans hold a market's cash reserved for a tenor  */
    /* ================================================================== */

    /// @dev One leg: open the minimum ticket, repay it to one atom, arm (reserving `minDebt - 1`), take the collateral back down to the one-atom line.
    function _dustArmLeg(address who) internal returns (uint256 loanId, bool armed) {
        coll.mint(who, UNITS);
        usdc.mint(who, MIN_DEBT);
        vm.startPrank(who);
        coll.approve(address(pm), UNITS);
        usdc.approve(address(ace), type(uint256).max);
        loanId = ace.open(id, UNITS, MIN_DEBT, TEN7, who, OpenBounds(0, 0, 0));
        ace.repay(loanId, MIN_DEBT - 1); // only the borrower may leave (0, minDebt)
        if (ace.drawableOf(id) >= MIN_DEBT - 1) {
            ace.setAutoRefinance(loanId, TEN7, 0, 0); // reserves rollNeed(1) == minDebt - 1
            armed = true;
        }
        uint256 spare = lens.withdrawableUnits(id, loanId);
        ace.withdrawCollateral(loanId, spare, who); // everything above the one-atom coverage line comes back
        vm.stopPrank();
    }

    /// @notice A griefer repeats the minimum-ticket leg until the market's whole resting cash is drawn or reserved: `drawableOf` reads zero for a tenor.
    /// @notice The drawn half lands in the lender's `owed`, recyclable; the RESERVED half nothing releases before the fold, the lender included.
    /// @notice A leg costs one fee on `minDebt` (the escrow is earned at the fold, never refunded) plus gas and a few atoms of collateral.
    /// @dev Y-10's floor accepted `minDebt - 1` idle per armed loan; this row prices the many-loan form against the market's lendable cash.
    function test_J1_DustArmedLoansHoldHalfTheMarketReservedForATenorAtTheCostOfTheirFees() public {
        // a small market: alice keeps 100 minimum tickets of cash resting
        uint256 keep = 100 * MIN_DEBT;
        uint256 out = ace.restingOf(id) - keep; // hoisted: a call in the argument list would eat the prank
        vm.prank(alice);
        ace.withdraw(id, out, alice, 0);
        assertEq(ace.restingOf(id), keep, "PREMISE: 100 minimum tickets rest");
        address griefer = address(0x6E1EF);

        uint256 legs;
        uint256 armedLegs;
        uint256 fees;
        while (ace.drawableOf(id) >= MIN_DEBT) {
            (uint256 loanId, bool armed) = _dustArmLeg(griefer);
            fees += read.loan(loanId).lastFee;
            legs++;
            if (armed) armedLegs++;
        }
        assertLt(ace.drawableOf(id), MIN_DEBT, "nothing a minimum ticket could draw is left");
        uint256 reserved = read.rollReserve(id);
        assertGe(reserved, (keep * 45) / 100, "close to half the cash is RESERVED behind one-atom loans");
        assertEq(reserved, armedLegs * (MIN_DEBT - 1), "each armed leg reserved exactly minDebt - 1");

        // an honest borrower is refused, and the lender cannot free the reserved half
        coll.mint(borrower, UNITS);
        vm.startPrank(borrower);
        coll.approve(address(pm), UNITS);
        vm.expectRevert(InsufficientCash.selector);
        ace.open(id, UNITS, MIN_DEBT, TEN7, borrower, OpenBounds(0, 0, 0));
        vm.stopPrank();
        (,, uint256 owed) = read.poolOf(id);
        assertGe(owed, legs * (MIN_DEBT - 1), "the drawn half sits in the lender's owed, recyclable by collect and deposit");
        emit log_named_uint("legs", legs);
        emit log_named_uint("armed legs", armedLegs);
        emit log_named_uint("reserved (quote atoms)", reserved);
        emit log_named_uint("griefer fees paid (quote atoms)", fees);

        // the lock lasts the tenor: at expiry the fold cannot roll a one-atom loan, and only the settlement releases the share
        _warpTo(read.loan(1).expiry); // the first leg's loan is id 1: nothing opened before it in this row
        vm.prank(keeper);
        ace.forceClose(1);
        assertEq(read.rollReserve(id), reserved - (MIN_DEBT - 1), "the fold settled the one-atom loan and released exactly its share");
    }

    /* ================================================================== */
    /*  Row K: the counter to both dust levers is a one-atom payoff         */
    /* ================================================================== */

    /// @notice Only the borrower may repay into `(0, minDebt)`, but a FULL payoff is open to anyone: a stranger pays the one atom a dust-armed loan still owes.
    /// @notice `closeClean` then frees the `minDebt - 1` reservation and credits the collateral to the borrower, so no pot is born and the count never moves.
    /// @dev The cheap, capital-free forms of rows I1 and J1 are therefore pre-emptable by any keeper for one quote atom plus a closing repay's gas.
    function test_K1_AStrangersOneAtomPayoffFreesTheDustArmedReserveAndLeavesNoPot() public {
        address griefer = address(0x6E1EF);
        (uint256 loanId, bool armed) = _dustArmLeg(griefer);
        assertTrue(armed, "PREMISE: the leg armed");
        assertEq(read.debtOf(loanId), 1, "PREMISE: one atom of debt");
        uint256 rr0 = read.rollReserve(id);
        assertEq(rr0, MIN_DEBT - 1, "PREMISE: minDebt - 1 is reserved behind it");
        assertEq(_unsold(), 0, "PREMISE: no pot yet");

        usdc.mint(stranger, 1);
        vm.startPrank(stranger);
        usdc.approve(address(ace), 1);
        ace.repay(loanId, 1); // a full payoff: the (0, minDebt) rail does not apply to a repay that leaves zero
        vm.stopPrank();

        assertTrue(ace.isClosed(loanId), "the loan closed clean");
        assertEq(read.rollReserve(id), 0, "and its reservation is released at once");
        assertEq(read.invPotOf(id, loanId), 0, "no pot: the collateral went to the borrower's credit");
        assertEq(_unsold(), 0, "so the unsold count never moved");
        (uint256 units,) = ace.owedOf(loanId, griefer);
        assertGt(units, 0, "the griefer's remaining atoms are credited to the griefer");
        assertEq(ace.drawableOf(id), ace.restingOf(id) - 0, "every atom of resting cash is drawable again");
    }
}

/// @dev `MarketInit.autoRefinanceWindow` is internal; the row re-spells `settleExpired`'s wait off the hub's own constants.
library MarketInitWindow {
    function rollWindow(uint64 tenor) internal pure returns (uint64) {
        uint64 w = tenor / 5;
        return w < 2 hours ? w : 2 hours;
    }
}
