// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.36;

import {Test} from "forge-std/Test.sol";
import {WarpClock} from "../utils/WarpClock.sol";
import {Ace} from "../../src/ace/hub/Ace.sol";
import {Storage, MarketParams, MarketState, OpenBounds} from "../../src/ace/hub/Types.sol";
import {LoanClosed, NotExpired, NotSettleable} from "../../src/ace/hub/Settlement.sol";
import {PositionManager} from "../../src/ace/positions/PositionManager.sol";
import {PriceFrame} from "../utils/PriceFrame.sol";
import {Constants} from "../../src/ace/hub/Constants.sol";
import {LoanMath} from "../../src/ace/hub/libraries/LoanMath.sol";
import {PocDeployConfig, ProtocolPolicy} from "../../src/config/Defaults.sol";
import {MockERC20} from "../mocks/MockERC20.sol";
import {MockPersistenceRecord} from "../mocks/MockPersistenceRecord.sol";
import {MockStakeVault} from "../mocks/MockStakeVault.sol";
import {AceFixtures} from "../utils/AceFixtures.sol";
import {AceReader} from "../utils/AceReader.sol";

/// @title AceSettlement
/// @notice The singleton twin of derived-pending settlement: `settleable` is the only precondition on finalize.
/// @notice A recovery print dissolves it for free, expiry closes unconditionally, and both paths are terminal.
/// @notice The title transfer fills claims at their own pre-committed tick prices.
/// @dev `SettlementWindowsTest` and the market's finalize suite are the spec.
/// @dev The legacy bad-debt tests drove `finalizeLoanFor` straight off the market; the singleton has no such door.
/// @dev An admitted loan is over-covered at its claims' own tick prices, so scarcity has to be EARNED after open.
/// @dev It is produced here by repeated DELEVERAGE cranks in a falling market, which is the production route.
contract AceSettlementTest is WarpClock {
    /// @dev Mirrors `Settlement`'s own declaration; the same figure is also recorded per loan and per market.
    event Finalized(uint256 indexed id, uint256 collateralUnits, uint256 badDebt, address indexed executor);

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
    uint256 internal constant UNIT_SCALE = 1 << 96; // every market's scale under the atom frame
    uint256 internal T0; // ticks above this pair's par; assigned in setUp, since par is not a compile-time value
    uint256 internal T2;
    uint256 internal T3;
    uint256 internal T4;

    uint256 internal constant DEFAULT_DISTRESS = 30 minutes; // persistenceWindow
    uint256 internal constant DEFAULT_SETTLE = 30 minutes + 4 hours; // persistence + pending

    /// @dev This suite's pair, so a tick reads as its distance from par rather than as a grid coordinate.
    /// @param offset Ticks above par.
    /// @return The absolute grid tick.
    function _price(int24 offset) internal view returns (uint256) {
        return AceFixtures.priceAt(address(usdc), address(vault), offset);
    }

    function setUp() public {
        usdc = new MockERC20("USD Coin", "USDC", 6);
        vault = new MockStakeVault(42);
        (T0, T2, T3, T4) = (_price(-1080), _price(0), _price(480), _price(960));
        record = new MockPersistenceRecord(address(usdc), address(vault));
        record.setWindows(DEFAULT_DISTRESS, DEFAULT_SETTLE - DEFAULT_DISTRESS); // the record owns them now

        AceFixtures.Deployment memory d = AceFixtures.deploy(_params());
        (ace, positionManager, read, id) = (d.ace, d.positionManager, d.read, d.id);

        _deposit(T4, 15_000e6); // WAS three rungs of 5_000; one market, one resting balance
    }

    // ---- helpers ----

    function _params() internal view returns (MarketParams memory p) {
        p = AceFixtures.marketParams(address(usdc), address(vault));
        p.record = address(record);
        p.price = T4; // WAS the ladder's top rung, which every row here names as the funding floor
    }

    function _deposit(uint256 price, uint256 amt) internal {
        usdc.mint(alice, amt);
        vm.startPrank(alice);
        usdc.approve(address(ace), amt);
        ace.deposit(id, amt);
        vm.stopPrank();
    }

    function _openStd() internal returns (uint256 loanId) {
        return _open(id, COLL, 4_500e6);
    }

    function _open(bytes32 mid, uint256 units, uint256 principal) internal returns (uint256 loanId) {
        vault.mint(borrower, units);
        vm.startPrank(borrower);
        vault.approve(address(positionManager), units);
        loanId = ace.open(mid, units, principal, 0, borrower, OpenBounds(0, 0, 0));
        vm.stopPrank();
    }

    /// @dev Units the market needs to cover one claim at its own tick price, ceiled as settlement does.
    function _need(uint256 claim, uint256 price) internal pure returns (uint256) {
        return (claim * UNIT_SCALE + price - 1) / price;
    }

    // ============ the windows are the RECORD's, and it carries its own bounds ============

    /// @dev They were `MarketParams` fields bounded at `createMarket`; both moved onto the record.
    /// @dev The hub holds neither, so what a market settles over is whatever its record answers.
    function test_Windows_AreTheRecords_DefaultsMatchPoC() public view {
        MarketParams memory p = ace.idToMarketParams(id);
        MockPersistenceRecord rec = MockPersistenceRecord(p.record);
        assertEq(rec.PERSISTENCE_WINDOW(), DEFAULT_DISTRESS, "distress window = the record's persistence window");
        assertEq(rec.SETTLE_WINDOW(), DEFAULT_SETTLE, "settle window = persistence + grace, summed by the record");
    }

    // ============ settleable() is the finalize precondition ============

    function test_Finalize_RefusedUntilSettleable() public {
        uint256 loanId = _openStd();
        record.setBelow(false);
        vm.expectRevert(NotSettleable.selector);
        ace.finalize(loanId);

        record.setBelow(true);
        assertTrue(read.settleable(loanId), "settleable off the record");
        vm.prank(keeper);
        ace.finalize(loanId);
        assertTrue(read.loan(loanId).closedAt != 0, "settled once settleable");
    }

    function test_RecoveryPrint_BlocksSettlementForFree() public {
        uint256 loanId = _openStd();
        record.setBelow(true);
        assertTrue(read.settleable(loanId));
        record.setBelow(false); // recovery: no verb, no fee -- settleable just goes false
        assertFalse(read.settleable(loanId));
        vm.expectRevert(NotSettleable.selector);
        ace.finalize(loanId);
    }

    // ============ tenor is the CEILING, not the target ============

    function test_ForceClose_SettlesAtTenorRegardlessOfRecord() public {
        uint256 loanId = _openStd();
        record.setBelow(false); // record says HEALTHY -- forceClose does not care

        _warpBy(ProtocolPolicy.MIN_TENOR + 1);
        vm.prank(keeper);
        ace.forceClose(loanId);
        assertTrue(read.loan(loanId).closedAt != 0, "expiry settles unconditionally: tenor is the ceiling");
    }

    function test_ForceClose_RefusedBeforeExpiry() public {
        uint256 loanId = _openStd();
        vm.expectRevert(NotExpired.selector);
        ace.forceClose(loanId);
    }

    function test_Settlement_IsTerminal() public {
        uint256 loanId = _openStd();
        record.setBelow(true);
        vm.prank(keeper);
        ace.finalize(loanId);
        assertTrue(read.loan(loanId).closedAt != 0);

        vm.expectRevert(LoanClosed.selector);
        ace.finalize(loanId);
        vm.expectRevert(LoanClosed.selector);
        ace.forceClose(loanId);
    }

    // ============ the title transfer itself ============

    /// @dev The two roundings AGREE: custody takes the ceiled requirement and the tick books that same figure.
    /// @dev A claim needs `ceil(amount * unitScale / price)` units, so anything less cannot pay it.
    /// @dev So a covered settlement leaves NO sub-unit resting on the hub outside a class's pot.
    function test_Finalize_ConvertsClaimsToInventoryAtTheirOwnTickPrices() public {
        uint256 loanId = _openStd(); // one claim, 4,500 at T4
        uint256 taken = _need(4_500e6, T4); // ceiled: what leaves the positionManager, and what the tick books
        /// @dev DEBT-based and converted at the loan's funding floor, so pay tracks the obligation.
        /// @dev The keeper supplies no capital to a title transfer, so it is not paid off the over-collateralization.
        /// @dev Mirrors `LoanAccounting.sliverUnits` exactly.
        uint256 sliver = (read.loan(loanId).debt * PocDeployConfig.SETTLE_BOUNTY_BPS * UNIT_SCALE) / (10000 * read.fundingFloor(id, loanId));

        record.setBelow(true);
        vm.prank(keeper);
        ace.finalize(loanId);

        assertEq(read.invPotOf(id, loanId), taken, "the claim fills at its own pre-committed tick price");
        assertEq(read.claimOf(id, loanId), 0, "the claim is gone: title moved instead of cash");
        assertEq(read.unitsOwedOf(loanId, keeper), sliver, "the keeper's in-kind sliver comes off the top");
        vm.prank(keeper);
        ace.claimOwed(loanId, keeper);
        assertEq(vault.balanceOf(keeper), sliver, "and it pays out in full on the pull");
        vm.prank(borrower);
        ace.claimOwed(loanId, borrower);
        assertEq(vault.balanceOf(borrower), COLL - sliver - taken, "residual equity returns in kind");
        assertEq(vault.balanceOf(address(ace)), 0, "the hub takes title to nothing: settlement moves no token");
        assertEq(positionManager.retiredOf(loanId), taken, "the market's leg rests in the loan's own vault");
        assertEq(
            positionManager.retiredOf(loanId) - read.invPotOf(id, loanId), 0, "the agreeing roundings strand nothing in the vault, outside any class's pot"
        );
    }

    /// @notice A matured, fully covered force-close is terminal for the loan's floor and tick list.
    function test_ForceClose_FullCoverage_SettlesWhole() public {
        uint256 loanId = _openStd();
        _warpBy(ProtocolPolicy.MIN_TENOR + 1);

        vm.prank(keeper);
        ace.forceClose(loanId);

        assertEq(read.fundingFloor(id, loanId), 0, "a closed loan has no floor");
        assertEq(read.claimOf(id, loanId), 0, "settlement zeroes every claim");
        /// @dev WAS "the funded-tick LIST deliberately survives, because redeem and the ask walk it for the
        /// @dev pots". There is no list: the count IS the claim's funded flag, so it retires with the claim,
        /// @dev and what redeem and the ask reach for is the loan's POT, keyed by the loan alone.
        assertEq(read.claimCount(id, loanId), 0, "the count retires with the claim it is a flag for");
        assertGt(read.invPotOf(id, loanId), 0, "while the pot those verbs discover is what survives");
    }

    // ============ scarcity: delivery order, and who eats the shortfall ============

    /// @dev DELETED: `test_Finalize_DeliversHighestBucketsFirst_AndShortsThePublicTail`. A loan could fund several
    /// @dev ticks, so a SHORT settlement had to choose an order, and the rule was highest-tick-first in full with
    /// @dev the tail getting nothing. A loan holds ONE claim: there is no queue to order and no tail to short.
    /// @dev What survives is the conservation below -- everything left goes to that claim, and the borrower keeps
    /// @dev nothing -- which is what the delivery order was really protecting.

    /// @dev THE LOSS MODEL, with no absorber left: a shortfall is the FUNDING LENDER'S OWN write-down and reaches
    /// @dev nothing else. The market's other resting cash is untouched, and the whole remainder fills the claim.
    /// @dev WAS "an uninvolved TICK in the same market is untouched"; sole tenancy makes it the same lender's
    /// @dev own resting balance, which is a stronger statement: not even their own idle cash is reached.
    function test_Shortfall_LandsOnTheFundingClaimAlone() public {
        (bytes32 mid, uint256 loanId, uint256 left) = _openIntoScarcity();
        uint256 claim = read.claimOf(mid, loanId);
        uint256 resting = read.restingOf(mid);
        uint256 loss = claim - (left * T4) / UNIT_SCALE;

        record.setBelow(true);
        vm.expectEmit(true, false, false, true, address(ace));
        emit Finalized(loanId, left, loss, keeper); // the short reported in full
        vm.prank(keeper);
        ace.finalize(loanId);

        assertEq(read.restingOf(mid), resting, "cash that funded nothing bears nothing");
        assertEq(read.claimOf(mid, loanId), 0, "the shorted claim settled by title transfer");
        assertEq(read.invPotOf(mid, loanId), left, "and every remaining unit reached it");
        assertEq(vault.balanceOf(borrower), 0, "a short settlement leaves the borrower no residual");
    }

    /// @dev THE RECORD, not the announcement: an event is unreadable to a contract, so a stored figure is the point.
    /// @dev Both halves are kept because neither derives the other once the claim is zeroed.
    function test_Shortfall_IsPersistedOnTheLoan_UnitsAndQuote() public {
        (bytes32 mid, uint256 loanId, uint256 left) = _openIntoScarcity();
        uint256 need = _needNow(mid, loanId); // read BEFORE settlement zeroes the claim
        uint256 loss = read.claimOf(mid, loanId) - (left * T4) / UNIT_SCALE;

        record.setBelow(true);
        vm.expectEmit(true, false, false, true, address(ace));
        emit Finalized(loanId, left, loss, keeper);
        vm.prank(keeper);
        ace.finalize(loanId);

        (uint256 units, uint256 quoteAtBook) = read.shortfallOf(loanId);
        assertEq(units, need - left, "atoms the claim did not get, keeper sliver already taken");
        assertEq(quoteAtBook, loss, "the stored figure and the emitted one must never disagree");
        assertEq(read.marketState(mid).realizedLossAtBook, loss, "and the market's running total carries it");
    }

    /// @dev The sparse property IS the gas argument, so it is asserted rather than assumed.
    /// @dev A covered settlement runs the same write site and must leave the slot untouched.
    function test_Shortfall_CoveredSettlementWritesNothing() public {
        uint256 loanId = _openStd();

        record.setBelow(true);
        vm.prank(keeper);
        ace.finalize(loanId);

        (uint256 units, uint256 quoteAtBook) = read.shortfallOf(loanId);
        assertEq(units, 0, "a covered settlement is short of nothing");
        assertEq(quoteAtBook, 0, "and pays no SSTORE to say so");
        assertEq(read.marketState(id).realizedLossAtBook, 0, "a market that lost nothing reports nothing");
    }

    /// @dev Sparseness is a claim about a WRITE: an unwritten mapping reads zero too, so `vm.record` witnesses it.
    /// @dev Both arms live here so the covered arm cannot pass by never reaching the write site.
    function test_Shortfall_TheWriteItselfIsSparse() public {
        uint256 covered = _openStd();
        record.setBelow(true);
        vm.record();
        vm.prank(keeper);
        ace.finalize(covered);
        (, bytes32[] memory coveredWrites) = vm.accesses(address(ace));
        assertTrue(read.loan(covered).closedAt != 0, "the covered close really ran");
        assertFalse(_touched(coveredWrites, covered), "and stored no shortfall: the slot was never written");

        (, uint256 short,) = _openIntoScarcity();
        record.setBelow(true);
        vm.record();
        vm.prank(keeper);
        ace.finalize(short);
        (, bytes32[] memory shortWrites) = vm.accesses(address(ace));
        assertTrue(_touched(shortWrites, short), "a short close does write it, so the witness is live");
    }

    /// @dev Did this settlement store either word of the loan's shortfall record?
    function _touched(bytes32[] memory writes, uint256 loanId) internal pure returns (bool) {
        uint256 base = uint256(keccak256(abi.encode(loanId, uint256(Storage.BOOK) + 9))); // shortfallOf
        for (uint256 i; i < writes.length; i++) {
            if (uint256(writes[i]) == base || uint256(writes[i]) == base + 1) return true;
        }
        return false;
    }

    /// @dev SLOT TRIPWIRE: `Market`'s regions shift by DIFFERENT offsets, so one known value PER REGION is the minimum coverage.
    /// @dev A wrong slot reads a plausible number and reverts nothing, so the arithmetic assertions elsewhere cannot catch it.
    function test_ReaderSlots_AgreeWithKnownValues() public {
        uint256 loanId = _openStd(); // 4,500 funded entirely out of T4

        /// @dev the fee is unit-holder money now, never bucket cash, so totalCash is cash-only
        assertEq(read.marketState(id).cash, 15_000e6 - 4_500e6, "M_STATE");
        /// @dev WAS `M_BUCKETS`, the per-tick cash word, and 500e6 was what the draw left at T4 alone.
        /// @dev `restingOf` reads the SAME word `marketState().cash` does now, so pinning both is what says
        /// @dev the two reader paths have not drifted apart rather than restating one figure twice.
        assertEq(read.restingOf(id), read.marketState(id).cash, "M_CASH agrees with M_STATE");
        assertEq(read.claimOf(id, loanId), 4_500e6, "M_CLAIM");
        assertEq(read.claimCount(id, loanId), 1, "M_CLAIM_TICKS");
        assertEq(read.fundingFloor(id, loanId), T4, "M_FLOOR_PRICE");
        assertEq(read.claimOf(id, loanId), 4_500e6, "M_CLASS");
        assertEq(read.loan(loanId).debt, 4_500e6, "B_LOANS");
    }

    /// @dev What reaches `totalCash` at open: the lender cut NET of the withheld early-exit escrow.
    /// @dev The escrow sits on the hub outside `totalCash`, so it is not part of this figure.
    function _lenderFee() internal pure returns (uint256) {
        uint256 fee = LoanMath.originationFee(4_500e6, ProtocolPolicy.MIN_TENOR, PocDeployConfig.BASE_BPS, ProtocolPolicy.MIN_TENOR);
        uint256 lender = fee - (fee * Constants.PROTOCOL_SHARE_BPS) / (10000 + Constants.PROTOCOL_SHARE_BPS);
        return lender - (lender * Constants.REBATE_PHI_BPS) / 10000;
    }

    /// @dev A market driven into COLLATERAL SCARCITY the way production reaches it: repeated DELEVERAGE cranks in a falling market.
    /// @dev `need` is fixed at the claims' PRE-COMMITTED tick prices while a deleverage sells at the CRASHED market price.
    /// @dev So each crank removes many units and retires little debt, which is the asymmetry `deleverageStopBps` exists to bound.
    /// @dev Each crank restores margin to target and leaves the band, so the loop below is a real distress sequence, not a no-op.
    function _openIntoScarcity() internal returns (bytes32 mid, uint256 loanId, uint256 left) {
        MarketParams memory p = _params();
        p.settleBountyBps = 200; // the shipped CEILING, and it differentiates this market's id from setUp's
        mid = ace.createMarket(p);

        /// @dev WAS two rungs of 5,000 funding one draw across T4 and T3; the market bids at one price, so the
        /// @dev same draw is one claim of 7,000 against one balance. The SCARCITY the rows measure is unchanged.
        usdc.mint(alice, 11_000e6);
        vm.startPrank(alice);
        usdc.approve(address(ace), 11_000e6);
        ace.deposit(mid, 10_000e6);
        vm.stopPrank();

        loanId = _open(mid, COLL, 7_000e6); // one claim of 7,000 at the market's price
        usdc.mint(alice, 1_000e6);
        vm.startPrank(alice);
        ace.deposit(mid, 1_000e6); // a bystander balance that funded nothing, for the loss-model row
        vm.stopPrank();

        /// @dev DIRECT STATE STAGING, and the comment is the finding: deleverage was tried first and cannot get here.
        /// @dev A single crank haircuts only ~6% OF THE SALE and melts debt as it goes, so it de-risks faster than it erodes.
        /// @dev What a SEQUENCE of cranks could once walk under is the per-tick ceiling floor, which is a claim-count term.
        /// @dev `LoanAccounting.securedBase` now keeps `collateralNeeded + sliverUnits` back, so no sale leaves an admitted loan short.
        /// @dev These two tests therefore cover DEFENSIVE code, and staging its precondition directly is how to keep covering it.
        /// @dev Writing `collateralUnits` is the minimum intervention: it touches no other field.
        /// @dev The positionManager keeps its real tokens, so the release path is exercised for real.
        uint256 loanSlot = uint256(keccak256(abi.encode(loanId, uint256(Storage.BOOK) + 1)));
        uint256 shortUnits = (_needNow(mid, loanId) * 60) / 100; // decisively under what the claims need
        vm.store(address(ace), bytes32(loanSlot + 2), bytes32(shortUnits)); // word 2 == collateralUnits

        left = read.loan(loanId).collateralUnits - _settleSliver(mid, loanId);
        assertLt(left, _needNow(mid, loanId), "the fixture must actually be short against its LIVE claims");
    }

    /// @dev Units this loan's LIVE claim needs at its own pre-committed price.
    /// @dev The mirror of `LoanAccounting.collateralNeeded`, read from state rather than from the opening figures.
    /// @dev WAS a per-tick sum with a ceiling each; one claim at one price leaves one ceiling.
    function _needNow(bytes32 mid, uint256 loanId) internal view returns (uint256) {
        uint256 amt = read.claimOf(mid, loanId);
        if (amt == 0) return 0;
        uint256 price = read.fundingFloor(mid, loanId);
        return (amt * UNIT_SCALE + price - 1) / price;
    }

    /// @dev The debt-based in-kind sliver, mirroring `LoanAccounting.sliverUnits`.
    function _settleSliver(bytes32 mid, uint256 loanId) internal view returns (uint256) {
        uint256 floorPrice = read.fundingFloor(mid, loanId);
        if (floorPrice == 0) return 0;
        return (read.loan(loanId).debt * ace.idToMarketParams(mid).settleBountyBps * UNIT_SCALE) / (10000 * floorPrice);
    }
}
