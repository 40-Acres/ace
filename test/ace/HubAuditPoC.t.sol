// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.36;

import {WarpClock} from "../utils/WarpClock.sol";
import {Ace} from "../../src/ace/hub/Ace.sol";
import {BelowDebtFloor, InsufficientCash, LoanClosed} from "../../src/ace/hub/Borrower.sol";
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
import {_extended} from "../utils/Extended.sol";

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
    uint256 internal constant MIN_PRINCIPAL = 10e6;

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
        p.minPrincipal = MIN_PRINCIPAL;
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

    /// @dev The holder's own extension, its fee funded at the quote.
    function _extendAsHolder(uint256 loanId) internal {
        address holder = read.loan(loanId).borrower;
        (,, uint256 fee) = ace.tryExtend(loanId, 0, "", holder);
        usdc.mint(holder, fee);
        vm.startPrank(holder);
        usdc.approve(address(ace), fee);
        ace.extend(loanId, 0, "");
        vm.stopPrank();
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
    /*  Row B: a stranger's fill of a third party's order refuses no extension */
    /* ================================================================== */

    /// @dev A maker's order for exactly the market's resting cash, beside the loan.
    function _orderForTheSpare() internal returns (uint256 oid, uint256 spare) {
        spare = ace.restingOf(id);
        uint256 par = ace.idToMarketParams(id).price;
        vm.prank(maker);
        oid = ace.postOrder(id, spare, par, par, 0, TEN7, 0);
    }

    /// @notice CONTROL: with the resting cash untouched, the borrower's extension lands in place on the lender's yes.
    function test_B1_Control_TheExtensionLandsWhenSpareCashRests() public {
        AceFixtures.installYesPolicy(ace, alice);
        uint256 loanId = _open(id, borrower, P);
        _orderForTheSpare(); // posted, never filled
        uint64 x = read.loan(loanId).expiry;
        _warpTo(uint256(x) - 1);
        _extendAsHolder(loanId);
        assertTrue(_extended(read, loanId, x), "the loan extended in place");
    }

    /// @notice A stranger fills the maker's order for every resting atom in the extension's block: the MAKER pays the fee, the stranger gas.
    /// @notice Resting cash never enters an extension, so the drain changes nothing: the loan still extends on the lender's yes.
    function test_B2_AStrangersFillOfAnotherMakersOrderCannotRefuseTheExtension() public {
        AceFixtures.installYesPolicy(ace, alice);
        uint256 loanId = _open(id, borrower, P);
        (uint256 oid, uint256 spare) = _orderForTheSpare();
        assertGt(spare, 0, "PREMISE: cash rests beside the loan");

        uint64 x = read.loan(loanId).expiry;
        _warpTo(uint256(x) - 1);
        Order memory o = ace.orderOf(oid);
        uint256 before = usdc.balanceOf(stranger);
        vm.prank(stranger);
        uint256 g0 = gasleft();
        ace.fillOrder(oid, spare, o.collateralUnits);
        uint256 gasUsed = g0 - gasleft();
        assertEq(usdc.balanceOf(stranger), before, "the stranger paid no quote: the maker's loan paid the fee");
        assertEq(ace.restingOf(id), 0, "the resting cash is gone");
        (bool ok, bytes4 why,) = ace.tryExtend(loanId, 0, "", borrower);
        assertTrue(ok, "the borrower's extension is still admissible");
        assertEq(why, bytes4(0), "the drain gave it no reason to refuse");

        uint256 n = read.loanCount();
        _extendAsHolder(loanId);
        assertTrue(_extended(read, loanId, x), "the borrower extended the loan in place");
        assertEq(read.loanCount(), n, "and wrote no successor");
        assertEq(read.invPotOf(id, loanId), 0, "nor any pot: the stranger's drain bought no settlement");
        emit log_named_uint("stranger's fill gas", gasUsed);
    }

    /* ================================================================== */
    /*  Row C is DELETED: it pinned the lens's raw read of a retired       */
    /*  loan's auto-extend policy, and no such policy exists               */
    /* ================================================================== */

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

    /// @notice `repay(id, 0)` from any address lands on a loan at or over `minPrincipal`: a zero pull, a zero melt, two events, and no field moves.
    function test_G1_AStrangersZeroRepayLandsAndMovesNothing() public {
        uint256 loanId = _open(id, borrower, P);
        uint256 debt0 = read.debtOf(loanId);
        (uint256 resting0, uint256 lent0, uint256 owed0) = read.poolOf(id);

        vm.prank(stranger);
        ace.repay(loanId, 0);

        assertEq(read.debtOf(loanId), debt0, "debt unchanged");
        (uint256 resting1, uint256 lent1, uint256 owed1) = read.poolOf(id);
        assertEq(resting1, resting0, "resting unchanged");
        assertEq(lent1, lent0, "lent unchanged");
        assertEq(owed1, owed0, "owed unchanged");
        assertFalse(ace.isClosed(loanId), "the loan is live");
    }

    /* ================================================================== */
    /*  Row F is DELETED: it pinned the reserve-keeping lender posture,    */
    /*  and there is no reserve to keep                                    */
    /* ================================================================== */

    /* ================================================================== */
    /*  Row H is DELETED: it pinned that a one-transaction drain could not */
    /*  settle a victim's armed fold, and `forceClose` now always settles  */
    /* ================================================================== */

    /* ================================================================== */
    /*  Row I: a minimum ticket cannot be repaid to one atom               */
    /* ================================================================== */

    /// @notice The one-atom repay that once made a one-atom unsold pot for the cost of a minimum ticket is refused.
    /// @notice No live loan sits under `minPrincipal`, the borrower's own repay included, so the pot can no longer be made small.
    function test_I1_TheOneAtomRepayIsRefused_SoAMinimumTicketMakesNoDustPot() public {
        uint256 loanId = _open(id, borrower, MIN_PRINCIPAL);
        (uint256 resting0, uint256 lent0, uint256 owed0) = read.poolOf(id);
        usdc.mint(borrower, MIN_PRINCIPAL);
        uint256 bal0 = usdc.balanceOf(borrower);
        vm.startPrank(borrower);
        usdc.approve(address(ace), MIN_PRINCIPAL);
        vm.expectRevert(BelowDebtFloor.selector);
        ace.repay(loanId, MIN_PRINCIPAL - 1);
        vm.stopPrank();
        assertEq(read.debtOf(loanId), MIN_PRINCIPAL, "the debt is unchanged");
        (uint256 resting1, uint256 lent1, uint256 owed1) = read.poolOf(id);
        assertEq(resting1, resting0, "resting unchanged");
        assertEq(lent1, lent0, "lent unchanged");
        assertEq(owed1, owed0, "owed unchanged");
        assertEq(usdc.balanceOf(borrower), bal0, "and no quote left the borrower");
    }

    /* ================================================================== */
    /*  Row J is DELETED: it priced dust-armed loans holding a market's    */
    /*  cash reserved, and nothing holds cash for a loan                   */
    /* ================================================================== */

    /* ================================================================== */
    /*  Row K is DELETED: it countered the one-atom dust loan with a       */
    /*  stranger's payoff, and no repay can make that loan any more        */
    /* ================================================================== */
}
