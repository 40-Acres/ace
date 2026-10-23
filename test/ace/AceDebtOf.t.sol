// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.36;

import {Vm} from "forge-std/Test.sol";
import {WarpClock} from "../utils/WarpClock.sol";
import {Ace} from "../../src/ace/hub/Ace.sol";
import {MarketInit} from "../../src/ace/hub/MarketInit.sol";
import {MarketParams, MigrateArgs, OpenBounds, Order} from "../../src/ace/hub/Types.sol";
import {PositionManager} from "../../src/ace/positions/PositionManager.sol";
import {IPersistenceRecord} from "../../src/interfaces/IPersistenceRecord.sol";
import {ProtocolPolicy} from "../../src/config/Defaults.sol";
import {MockERC20} from "../mocks/MockERC20.sol";
import {MockPersistenceRecord} from "../mocks/MockPersistenceRecord.sol";
import {MockStakeVault} from "../mocks/MockStakeVault.sol";
import {AceFixtures} from "../utils/AceFixtures.sol";
import {AceReader} from "../utils/AceReader.sol";
import {DeleverageCrank} from "../utils/DeleverageCrank.sol";
import {GUARD_TRIP} from "../utils/GuardTrip.sol";
import {FullMath} from "@uniswap/v4-core/src/libraries/FullMath.sol";

/// @notice A price record that reports what it sees from INSIDE an open body, through the only channel a view has: its answer.
/// @dev The hub reads the record in the draw, after the new loan's debt is written and before the draw debits cash.
/// @dev Armed, it answers the real price only when its check passes; zero refuses the open with `NoRecordPrice`.
/// @dev Witness mode checks the unguarded raw word and the market's cash; view mode checks that `Ace.debtOf` refuses as the guard.
contract DebtProbeRecord is IPersistenceRecord {
    Ace public immutable ACE;
    AceReader public immutable RAW; // the test reader: an unguarded slot read of the same word, through `extsload`
    address public immutable QUOTE;
    address public immutable COLLATERAL;
    uint256 public immutable CAP;

    uint256 public target; // the loan id the next open mints; zero answers plainly, which is what market creation sees
    bool public askView; // true: the guarded view must refuse; false: the raw word and the cash must show the tear
    bytes32 public market;
    uint256 public wantDebt;
    uint256 public wantResting;

    constructor(Ace ace_, AceReader raw_, address quote_, address collateral_, uint256 cap_) {
        ACE = ace_;
        RAW = raw_;
        QUOTE = quote_;
        COLLATERAL = collateral_;
        CAP = cap_;
    }

    function arm(uint256 id, bool viaView, bytes32 mid, uint256 debt, uint256 resting) external {
        (target, askView, market, wantDebt, wantResting) = (id, viaView, mid, debt, resting);
    }

    function supportsPair(address quote, address collateral) external view returns (bool) {
        return quote == QUOTE && collateral == COLLATERAL;
    }

    function persistedBelowDistress(address, address, uint256) external pure returns (bool) {
        return false;
    }

    function persistedBelowSettle(address, address, uint256) external pure returns (bool) {
        return false;
    }

    function lastObserved(address, address) external view returns (uint256) {
        return CAP;
    }

    function minPrice(address, address) external view returns (uint256) {
        if (target == 0) return CAP;
        if (!askView) return RAW.debtOf(target) == wantDebt && ACE.restingOf(market) == wantResting ? CAP : 0;
        try ACE.debtOf(target) returns (uint256) {
            return 0; // the view answered mid-body
        } catch (bytes memory e) {
            return bytes4(e) == GUARD_TRIP ? CAP : 0;
        }
    }

    function DEPTH_WINDOW() external pure returns (uint256) {
        return 0;
    }
}

/// @title AceDebtOf
/// @notice `Ace.debtOf` is a LIVE loan's `debt` word exactly, and zero for every id that is not a live loan.
/// @notice It refuses with the guard's own error from inside any hub body, where debt and cash are torn.
/// @dev Record-backed market with the deleverage band on and no protocol cut, so a crank melts exactly what it realizes.
/// @dev The test contract is its own deleverage keeper, so the callback can read the hub from inside the sale.
/// @dev Every row but the selector pin ends on the property sweep: across every id the hub has issued, `debtOf != 0` exactly when `isLiveLoan`.
/// @dev `AceReader.debtOf` is the RAW word through the test reader's own slot math; where it appears it pins a premise, never the view.
contract AceDebtOfTest is WarpClock, DeleverageCrank {
    Ace internal ace;
    AceReader internal read;
    PositionManager internal pm;
    MockERC20 internal usdc;
    MockStakeVault internal vault;
    MockPersistenceRecord internal record;
    bytes32 internal id;

    address internal alice = address(0xA11CE); // the market's lender
    address internal borrower = address(0xB0BA);
    address internal keeper = address(0xCAFE);
    address internal maker = address(0x3A4E);

    uint256 internal constant COLL = 10_000e18; // the guard-probe loan: the deleverage row's sizing is known to fire on it
    uint256 internal constant BIG = 20_000e18; // room for a refinance to a larger principal
    uint256 internal constant P = 6_000e6;
    uint256 internal constant BAND_BPS = 3000;
    uint64 internal constant TEN7 = 7 days;
    uint64 internal constant TEN30 = 30 days;
    bytes32 internal constant REFINANCED = keccak256("Refinanced(uint256,uint256,uint256,uint64,uint256,address)");
    bytes32 internal constant DELEVERAGED = keccak256("Deleveraged(uint256,uint256,uint256,uint256,address)");

    uint256 internal probeLoan; // the loan the deleverage callback reads; zero skips the reads
    bool internal probed;
    bool internal viewAnsweredMidBody;
    bytes4 internal viewRefusalMidBody;
    uint256 internal rawDebtMidBody;
    uint256 internal unitsMidBody;

    function _deleverageQuote() internal view override returns (address) {
        return address(usdc);
    }

    function setUp() public {
        _warpTo(1_000_000);
        usdc = new MockERC20("USD Coin", "USDC", 6);
        vault = new MockStakeVault(42);
        record = new MockPersistenceRecord(address(usdc), address(vault));
        record.setMinPrice(AceFixtures.px(2e18, address(usdc), address(vault)));

        MarketParams memory p = AceFixtures.marketParams(address(usdc), address(vault));
        p.record = address(record);
        p.maxTenor = TEN30;
        p.deleverageFloorEpsBps = ProtocolPolicy.DELEVERAGE_FLOOR_EPS_BPS;
        p.deleverageBandBps = BAND_BPS;
        p.deleverageTargetBps = 4000;
        p.deleverageStopBps = 1;
        p.deleverageProtocolBps = 0;
        AceFixtures.Deployment memory d = AceFixtures.deploy(p);
        (ace, pm, read, id) = (d.ace, d.positionManager, d.read, d.id);

        _deposit(id, 60_000e6);
        usdc.mint(borrower, 1_000_000e6);
        vm.prank(borrower);
        usdc.approve(address(ace), type(uint256).max);
    }

    // ---- helpers ----

    function _deposit(bytes32 mid, uint256 amt) internal {
        usdc.mint(alice, amt);
        vm.startPrank(alice);
        usdc.approve(address(ace), amt);
        ace.deposit(mid, amt);
        vm.stopPrank();
    }

    function _openOn(bytes32 mid, uint256 units, uint256 principal, uint64 tenor) internal returns (uint256 loanId) {
        vault.mint(borrower, units);
        vm.startPrank(borrower);
        vault.approve(address(pm), units);
        loanId = ace.open(mid, units, principal, tenor, borrower, OpenBounds(0, 0, 0));
        vm.stopPrank();
    }

    function _open(uint256 units, uint64 tenor) internal returns (uint256) {
        return _openOn(id, units, P, tenor);
    }

    /// @dev Drives the record under the band so one disposal is admissible, then cranks with the callback reads armed.
    function _crank(uint256 loanId) internal returns (uint256 sold, uint256 stableOut) {
        uint256 trig = read.triggerPrice(loanId);
        record.setBelowBand(FullMath.mulDivRoundingUp(trig, 1e18, 1e18 - BAND_BPS * 1e14));
        record.setMinPrice(trig + trig / 20);
        probeLoan = loanId;
        (sold, stableOut) = ace.deleverage(loanId, 0, "");
        probeLoan = 0;
    }

    /// @dev Inside the sale: collateral is debited and handed out, the debt not yet melted, and the hub holds its guard.
    function _deleverageCallback(uint256 unitsSold, uint256 quoteOwed, bytes calldata data) internal override {
        super._deleverageCallback(unitsSold, quoteOwed, data);
        if (probeLoan == 0) return;
        probed = true;
        rawDebtMidBody = read.debtOf(probeLoan);
        unitsMidBody = read.loan(probeLoan).collateralUnits;
        try ace.debtOf(probeLoan) returns (uint256) {
            viewAnsweredMidBody = true;
        } catch (bytes memory e) {
            viewRefusalMidBody = bytes4(e);
        }
    }

    /// @dev THE PROPERTY: across every id the hub has issued, and the first unissued one, a nonzero answer means a live loan.
    /// @dev It holds because a repay to zero closes the loan and `minDebt` is railed above zero, so a live loan never owes nothing.
    function _assertNonzeroExactlyWhenLive() internal view {
        uint256 n = read.loanCount() + 1;
        for (uint256 i; i <= n; i++) {
            assertEq(ace.debtOf(i) != 0, ace.isLiveLoan(i), string.concat("debtOf nonzero disagrees with isLiveLoan at id ", vm.toString(i)));
        }
        assertEq(ace.debtOf(type(uint256).max), 0, "the largest id reads zero");
    }

    // ---- the live answer ----

    /// @notice A fresh loan reads its principal, absolutely, and the neighbouring word holds another number.
    function test_DebtOf_AnOpenLoanReadsItsPrincipal() public {
        uint256 loanId = _open(COLL, 0);
        assertTrue(read.loan(loanId).collateralUnits != P, "premise: the word below the debt holds another number");
        assertEq(ace.debtOf(loanId), P, "a fresh loan owes its principal");
        _assertNonzeroExactlyWhenLive();
    }

    /// @notice A partial repay lowers it by exactly what was paid.
    function test_DebtOf_APartialRepayLowersItByThePayment() public {
        uint256 loanId = _open(COLL, 0);
        vm.prank(borrower);
        ace.repay(loanId, P / 5);
        assertEq(ace.debtOf(loanId), P - P / 5, "the debt left after the payment");
        _assertNonzeroExactlyWhenLive();
    }

    /// @notice A full repay closes the loan, which then reads zero.
    function test_DebtOf_AFullRepayReadsZero() public {
        uint256 loanId = _open(COLL, 0);
        vm.prank(borrower);
        ace.repay(loanId, type(uint256).max);
        assertTrue(ace.isClosed(loanId), "premise: the full repay closed the loan");
        assertEq(ace.debtOf(loanId), 0, "a repaid loan owes nothing");
        _assertNonzeroExactlyWhenLive();
    }

    /// @notice THE CONSUMER'S EQUATION: a home refinance takes from the market's cash exactly the new principal less `debtOf(old)`.
    /// @dev The oracle is the hub's own cash ledger, never the word, so a view that under-reports the recycle is caught here.
    function test_DebtOf_AHomeRefinanceDrawsExactlyTheNewPrincipalLessIt() public {
        uint256 oldId = _openOn(id, BIG, P, 0);
        uint256 d = ace.debtOf(oldId);
        uint256 r0 = ace.restingOf(id);
        uint256 n = P + 3_000e6;
        vm.prank(borrower);
        uint256 newId = ace.refinance(oldId, n, 0, OpenBounds(0, 0, 0));

        assertEq(r0 - ace.restingOf(id), n - d, "the draw took the new principal less the old debt, to the wei");
        assertEq(ace.debtOf(newId), n, "the successor owes its principal");
        assertEq(ace.debtOf(oldId), 0, "the retired loan owes nothing");
        _assertNonzeroExactlyWhenLive();
    }

    /// @notice A zero-fresh re-term, the new principal equal to the old debt, takes nothing from the market's cash.
    /// @dev Opened at the longest term and re-termed at once to the shortest, so the unearned escrow covers the new fee.
    function test_DebtOf_AZeroFreshRetermDrawsNothing() public {
        uint256 oldId = _openOn(id, BIG, P, TEN30);
        uint256 d = ace.debtOf(oldId);
        uint256 r0 = ace.restingOf(id);
        vm.prank(borrower);
        uint256 newId = ace.refinance(oldId, d, TEN7, OpenBounds(0, 0, 0));

        assertEq(ace.restingOf(id), r0, "a re-term at the old debt draws nothing fresh");
        assertEq(ace.debtOf(newId), d, "the successor owes the old debt");
        assertEq(ace.debtOf(oldId), 0, "the retired loan owes nothing");
        _assertNonzeroExactlyWhenLive();
    }

    // ---- the guard ----

    /// @notice THE REAL TEAR: inside the deleverage callback the collateral is gone and the debt is not yet melted.
    /// @notice `debtOf` refuses there with the guard's own error; the unguarded raw word at the same instant reads the pre-sale debt.
    /// @notice After the crank it answers, lowered by exactly the quote the sale realized.
    function test_DebtOf_RefusesInsideTheDeleverageCallback() public {
        uint256 loanId = _open(COLL, 0);
        uint256 debtBefore = ace.debtOf(loanId);
        uint256 unitsBefore = read.loan(loanId).collateralUnits;

        (, uint256 stableOut) = _crank(loanId);

        assertTrue(probed, "fixture: the callback ran its reads");
        assertFalse(viewAnsweredMidBody, "debtOf answered from inside the sale");
        assertEq(viewRefusalMidBody, GUARD_TRIP, "debtOf refused mid-body, but not as the guard");
        assertEq(unitsMidBody, unitsBefore - lastUnitsSold, "premise: the collateral was debited before the hand-off");
        assertEq(rawDebtMidBody, debtBefore, "premise: the raw word still read the pre-sale debt, high against the debited collateral");
        assertGt(stableOut, 0, "premise: the sale realized quote");
        assertEq(ace.debtOf(loanId), debtBefore - stableOut, "every unit of proceeds melted debt");
        _assertNonzeroExactlyWhenLive();
    }

    /// @notice THE OPEN PATH TEARS TOO: its record read runs after the debt is written and before the draw debits cash.
    /// @notice Witnessed first through the unguarded raw word, then `debtOf` is shown refusing at that same read.
    /// @dev Each open lands only if the probe record's check passed inside it; a failed check refuses with `NoRecordPrice`.
    /// @dev `expectCall` pins that the record read happened, so a missing read fails by name rather than by a silent pass.
    function test_DebtOf_RefusesInsideTheOpensRecordRead() public {
        DebtProbeRecord probe = new DebtProbeRecord(ace, read, address(usdc), address(vault), AceFixtures.px(2e18, address(usdc), address(vault)));
        MarketParams memory q = ace.idToMarketParams(id);
        q.record = address(probe);
        bytes32 pmid = ace.createMarket(q);
        _deposit(pmid, 20_000e6);

        uint256 r0 = ace.restingOf(pmid);
        probe.arm(read.loanCount() + 1, false, pmid, P, r0);
        vm.expectCall(address(probe), abi.encodeWithSelector(DebtProbeRecord.minPrice.selector)); // the open must reach the record read
        uint256 first = _openOn(pmid, COLL, P, 0);
        assertEq(ace.restingOf(pmid), r0 - P, "premise: the record saw the debt written and the cash undebited, then the draw debited it");

        probe.arm(read.loanCount() + 1, true, pmid, 0, 0);
        vm.expectCall(address(probe), abi.encodeWithSelector(DebtProbeRecord.minPrice.selector)); // and again, now asking the view
        uint256 second = _openOn(pmid, COLL, P, 0);
        assertEq(ace.debtOf(first), P, "outside the body both loans answer");
        assertEq(ace.debtOf(second), P, "including the one whose own record read was refused the view");
        _assertNonzeroExactlyWhenLive();
    }

    // ---- the closed answer ----

    /// @notice `finalize` leaves the stored word unpaid, and the view reads zero.
    function test_DebtOf_AFinalizedLoanReadsZero() public {
        uint256 loanId = _open(COLL, 0);
        record.setBelow(true);
        vm.prank(keeper);
        ace.finalize(loanId);

        assertTrue(ace.isClosed(loanId), "premise: finalize settled the loan");
        assertEq(read.debtOf(loanId), P, "premise: the stored word still holds the unpaid debt");
        assertEq(ace.debtOf(loanId), 0, "a settled loan owes nothing");
        _assertNonzeroExactlyWhenLive();
    }

    /// @notice `forceClose`'s settle branch leaves the stored word unpaid, and the view reads zero.
    function test_DebtOf_AForceClosedLoanReadsZero() public {
        uint256 loanId = _open(COLL, 0);
        _warpTo(uint256(read.loan(loanId).expiry) + 1);
        vm.prank(keeper);
        ace.forceClose(loanId);

        assertTrue(ace.isClosed(loanId), "premise: forceClose settled the loan");
        assertEq(read.debtOf(loanId), P, "premise: the stored word still holds the unpaid debt");
        assertEq(ace.debtOf(loanId), 0, "a settled loan owes nothing");
        _assertNonzeroExactlyWhenLive();
    }

    /// @notice `settleExpired` leaves the stored word unpaid, and the view reads zero.
    function test_DebtOf_ASettledExpiredLoanReadsZero() public {
        uint256 loanId = _open(COLL, 0);
        _warpTo(uint256(read.loan(loanId).expiry) + MarketInit.autoRefinanceWindow(read.loan(loanId).tenor));
        vm.prank(keeper);
        ace.settleExpired(loanId);

        assertTrue(ace.isClosed(loanId), "premise: settleExpired settled the loan");
        assertEq(read.debtOf(loanId), P, "premise: the stored word still holds the unpaid debt");
        assertEq(ace.debtOf(loanId), 0, "a settled loan owes nothing");
        _assertNonzeroExactlyWhenLive();
    }

    /// @notice `forceClose`'s ROLL branch retires the old loan and the successor owes the principal the roll logged.
    /// @dev The successor's figure comes from the `Refinanced` log, not from storage.
    function test_DebtOf_AForceCloseRollMovesTheDebtToTheSuccessor() public {
        uint256 oldId = _open(COLL, TEN7);
        vm.prank(borrower);
        ace.setAutoRefinance(oldId, TEN7, 0, 0);
        _warpTo(uint256(read.loan(oldId).expiry) + 1);

        vm.recordLogs();
        vm.prank(keeper);
        ace.forceClose(oldId);
        (uint256 newId, uint256 logged) = _refinancedFrom(vm.getRecordedLogs(), oldId);

        assertTrue(ace.isClosed(oldId), "premise: the roll closed the old loan");
        assertTrue(ace.isLiveLoan(newId), "premise: the roll opened a live successor");
        assertGt(logged, P, "premise: the roll drew past the old debt, so the successor's figure is its own");
        assertEq(ace.debtOf(oldId), 0, "the rolled loan owes nothing");
        assertEq(ace.debtOf(newId), logged, "the successor owes the principal the roll logged");
        _assertNonzeroExactlyWhenLive();
    }

    /// @dev The one `Refinanced` the hub logged for `oldId`: the successor's id and its logged principal.
    function _refinancedFrom(Vm.Log[] memory logs, uint256 oldId) internal view returns (uint256 newId, uint256 principal) {
        uint256 hits;
        for (uint256 i; i < logs.length; i++) {
            if (logs[i].emitter != address(ace) || logs[i].topics[0] != REFINANCED) continue;
            if (uint256(logs[i].topics[1]) != oldId) continue;
            newId = uint256(logs[i].topics[2]);
            (principal,,) = abi.decode(logs[i].data, (uint256, uint64, uint256));
            hits++;
        }
        assertEq(hits, 1, "fixture: exactly one Refinanced for the rolled loan");
    }

    // ---- ids that are not live loans ----

    /// @notice Zero for an id never issued, the zero id, the largest id and an order's id, before and after loans exist.
    function test_DebtOf_ZeroForEveryIdThatIsNotALiveLoan() public {
        assertEq(read.loanCount(), 0, "premise: a fresh hub has issued nothing");
        assertEq(ace.debtOf(0), 0, "id zero on a fresh hub");
        assertEq(ace.debtOf(1), 0, "the first id, not yet issued");
        assertEq(ace.debtOf(type(uint256).max), 0, "the largest id on a fresh hub");

        uint256 loanId = _open(COLL, 0);
        uint256 price = ace.idToMarketParams(id).price;
        vault.mint(maker, COLL);
        vm.startPrank(maker);
        vault.approve(address(pm), COLL);
        uint256 orderId = ace.postOrder(id, 1_000e6, price / 2, price, 0, TEN7, 0);
        vm.stopPrank();

        assertEq(ace.orderOf(orderId).market, id, "premise: this id names a resting order");
        assertFalse(ace.isLiveLoan(orderId), "premise: and no loan");
        assertEq(ace.debtOf(orderId), 0, "an order's id reads zero");
        assertEq(ace.debtOf(0), 0, "id zero once loans exist");
        assertEq(ace.debtOf(read.loanCount() + 1), 0, "the next unissued id");
        assertEq(ace.debtOf(loanId), P, "beside a live loan that reads its debt");
        _assertNonzeroExactlyWhenLive();
    }

    // ---- the interface a consumer probes ----

    /// @notice The selector is pinned, the hub answers it with one word, and a contract without the view refuses with no data.
    /// @dev No mock: the raw calls go to the real hub and to the real custodian, which declares neither the view nor a fallback.
    function test_DebtOf_SelectorIsPinnedAndAMissingViewRefusesEmpty() public view {
        assertEq(Ace.debtOf.selector, bytes4(keccak256("debtOf(uint256)")), "the selector is the bare signature's");
        assertEq(Ace.debtOf.selector, bytes4(0xbd7be5a4), "and its literal");

        (bool ok, bytes memory ret) = address(ace).staticcall(abi.encodeWithSelector(bytes4(0xbd7be5a4), uint256(0)));
        assertTrue(ok, "the hub answers id zero");
        assertEq(ret.length, 32, "with one word");
        assertEq(abi.decode(ret, (uint256)), 0, "and the word is zero");

        (ok, ret) = address(pm).staticcall(abi.encodeWithSelector(bytes4(0xbd7be5a4), uint256(0)));
        assertFalse(ok, "a contract without the view refuses");
        assertEq(ret.length, 0, "with empty data, which is what tells it apart from the hub");
    }

    // ---- the ledger and the consumer's safety ----

    /// @dev THE LEDGER ORACLE: a live loan reads its lender claim, and the answers over every issued id sum to the pool's `lent`.
    /// @dev Every market in this suite lends from one pool, alice's in USDC, so `poolLent` of the home id spans all of them.
    function _assertTheLedgerAgrees() internal view {
        uint256 n = read.loanCount();
        uint256 sum;
        for (uint256 i = 1; i <= n; i++) {
            uint256 d = ace.debtOf(i);
            if (ace.isLiveLoan(i)) assertEq(d, read.claimOf(ace.loanMarket(i), i), string.concat("debtOf is not the lender claim at id ", vm.toString(i)));
            sum += d;
        }
        assertEq(sum, read.poolLent(id), "the answers over every id do not sum to the pool's lent");
    }

    /// @dev THE UNDER-REPORT PROPERTY, per live loan: a repay of exactly `debtOf` pulls exactly that and closes it.
    /// @dev And one atom less leaves the loan live owing one atom, so the answer is the sharp threshold, neither under nor over.
    /// @dev Each leg runs from a snapshot and is reverted; the payer is the loan's holder, the one party who may leave dust.
    function _assertPayingItClosesEveryLiveLoan() internal {
        uint256 n = read.loanCount();
        for (uint256 i = 1; i <= n; i++) {
            if (!ace.isLiveLoan(i)) continue;
            uint256 d = ace.debtOf(i);
            address b = ace.borrowerOf(i);
            usdc.mint(b, d);
            vm.prank(b);
            usdc.approve(address(ace), type(uint256).max);
            uint256 snap = vm.snapshotState();
            uint256 bal = usdc.balanceOf(b);

            vm.prank(b);
            ace.repay(i, d);
            assertEq(bal - usdc.balanceOf(b), d, string.concat("a repay of debtOf did not pull exactly it at id ", vm.toString(i)));
            assertTrue(ace.isClosed(i), string.concat("a repay of debtOf left the loan open at id ", vm.toString(i)));
            vm.revertToState(snap);

            vm.prank(b);
            ace.repay(i, d - 1);
            assertTrue(ace.isLiveLoan(i), string.concat("a repay one atom under debtOf closed the loan at id ", vm.toString(i)));
            assertEq(ace.debtOf(i), 1, string.concat("one atom under debtOf did not leave one atom owed at id ", vm.toString(i)));
            vm.revertToState(snap);
        }
    }

    /// @notice Over a mixed book, settled, repaid and rolled ids add nothing, and the live ones add exactly their claims.
    /// @dev The pool's `lent` is checked against a hand sum first, so the ledger oracle is itself pinned, not assumed.
    function test_DebtOf_SumsToThePoolsLentAcrossAMixedBook() public {
        uint256 settled = _open(COLL, 0);
        uint256 repaid = _open(COLL, 0);
        uint256 partly = _open(COLL, 0);
        uint256 rolled = _openOn(id, BIG, P, 0);
        vm.startPrank(borrower);
        ace.repay(repaid, type(uint256).max);
        ace.repay(partly, P / 3);
        uint256 succ = ace.refinance(rolled, P + 1_000e6, 0, OpenBounds(0, 0, 0));
        vm.stopPrank();
        record.setBelow(true);
        vm.prank(keeper);
        ace.finalize(settled);
        record.setBelow(false);

        assertEq(read.debtOf(settled), P, "premise: the settled loan keeps its stored word");
        assertEq(read.poolLent(id), (P - P / 3) + (P + 1_000e6), "premise: the pool lends exactly the two live loans");
        assertEq(ace.debtOf(partly), P - P / 3, "the partly repaid loan owes the rest");
        assertEq(ace.debtOf(succ), P + 1_000e6, "the successor owes its principal");
        _assertTheLedgerAgrees();
        _assertPayingItClosesEveryLiveLoan();
        _assertNonzeroExactlyWhenLive();
    }

    /// @notice Over any repay ask: the repay takes `min(r, P)`, `debtOf` is the principal less what it took, and it closes at `P`.
    /// @dev What it took is the borrower's balance delta, never the hub's own figure.
    function testFuzz_DebtOf_ARepayLowersItByExactlyWhatItTook(uint256 r) public {
        r = bound(r, 0, 2 * P);
        uint256 loanId = _open(COLL, 0);
        uint256 bal = usdc.balanceOf(borrower);
        vm.prank(borrower);
        ace.repay(loanId, r);
        uint256 took = bal - usdc.balanceOf(borrower);

        assertEq(took, r < P ? r : P, "the repay took the ask, capped at the debt");
        assertEq(ace.debtOf(loanId), P - took, "debtOf is the principal less exactly what was taken");
        assertEq(ace.isLiveLoan(loanId), r < P, "the loan closes exactly when the repay reaches the principal");
        _assertTheLedgerAgrees();
        _assertNonzeroExactlyWhenLive();
    }

    /// @notice THE UNDER-REPORT PROPERTY over any principal and any prior partial repay: paying exactly `debtOf` closes the loan.
    function testFuzz_DebtOf_PayingExactlyItClosesTheLoan(uint256 principal, uint256 r) public {
        principal = bound(principal, 10e6, 7_000e6); // minDebt up to what COLL carries at the market's price
        uint256 loanId = _openOn(id, COLL, principal, 0);
        r = bound(r, 0, principal - 1);
        vm.prank(borrower);
        ace.repay(loanId, r);

        assertEq(ace.debtOf(loanId), principal - r, "debtOf is the principal less the partial repay");
        _assertTheLedgerAgrees();
        _assertPayingItClosesEveryLiveLoan();
        _assertNonzeroExactlyWhenLive();
    }

    // ---- the open paths: an order fill ----

    /// @notice Each fill of a credit order opens a loan titled to the maker that reads exactly that fill's principal.
    /// @dev The oracle is the market's cash, never the word: each fill takes exactly its principal from resting.
    function test_DebtOf_EachOrderFillReadsItsPrincipal() public {
        uint256 price = ace.idToMarketParams(id).price;
        vault.mint(maker, COLL);
        vm.startPrank(maker);
        vault.approve(address(pm), COLL);
        uint256 orderId = ace.postOrder(id, 1_000e6, price / 2, price, 250e6, TEN7, 0);
        vm.stopPrank();

        uint256 r0 = ace.restingOf(id);
        uint256 l1 = _fill(orderId, 500e6);
        assertEq(r0 - ace.restingOf(id), 500e6, "premise: the first fill drew its principal");
        uint256 l2 = _fill(orderId, 250e6);
        assertEq(r0 - ace.restingOf(id), 750e6, "premise: the second fill drew its principal");

        assertEq(ace.borrowerOf(l1), maker, "premise: a fill is titled to the maker");
        assertEq(ace.debtOf(l1), 500e6, "the first fill owes its principal");
        assertEq(ace.debtOf(l2), 250e6, "the second fill owes its principal");
        assertEq(ace.debtOf(orderId), 0, "the order's own id still reads zero beside its loans");
        _assertTheLedgerAgrees();
        _assertPayingItClosesEveryLiveLoan();
        _assertNonzeroExactlyWhenLive();
    }

    /// @dev A pro-rata fill by the market's lender, the permissionless filler in practice.
    function _fill(uint256 orderId, uint256 principalOut) internal returns (uint256) {
        Order memory o = ace.orderOf(orderId);
        vm.prank(alice);
        return ace.fillOrder(orderId, principalOut, (o.collateralUnits * principalOut) / o.principal);
    }

    // ---- the continuation paths ----

    /// @dev A market on every home term but `baseBps`, so a keeper may route between the two; alice lends it.
    function _sibling(uint256 baseBps) internal returns (bytes32 mid) {
        MarketParams memory q = ace.idToMarketParams(id);
        q.baseBps = baseBps;
        mid = ace.createMarket(q);
        _deposit(mid, 60_000e6);
    }

    /// @dev Opens a one-term loan, arms it, and lands past the incumbent's hold inside its roll window.
    function _armedInWindow(uint16 buf, uint16 feeCap) internal returns (uint256 loanId) {
        loanId = _open(COLL, TEN7);
        vm.prank(borrower);
        ace.setAutoRefinance(loanId, TEN7, buf, feeCap);
        _warpTo(uint256(read.loan(loanId).expiry) - MarketInit.homeRollHold(TEN7) / 2);
    }

    /// @notice `refinanceTo` another market: the old id reads zero and the successor its principal.
    /// @notice A routed draw recycles nothing, so the destination pays the WHOLE principal though `debtOf(old)` was live.
    /// @dev Which is why a consumer's `P - debtOf(old)` holds for a home refinance only, and gates on the loan's market.
    function test_DebtOf_ARoutedRefinanceToMovesItAndRecyclesNone() public {
        bytes32 dst = _sibling(30);
        uint256 oldId = _openOn(id, BIG, P, 0);
        uint256 n = P + 3_000e6;
        (uint256 rs, uint256 rd) = (ace.restingOf(id), ace.restingOf(dst));
        assertEq(ace.debtOf(oldId), P, "premise: the retiring loan was live");
        vm.prank(borrower);
        uint256 newId = ace.refinanceTo(MigrateArgs(oldId, dst, n, 0, OpenBounds(0, 0, 0), 0, address(0)));

        assertEq(ace.loanMarket(newId), dst, "premise: the successor sits in the destination");
        assertEq(rd - ace.restingOf(dst), n, "the destination drew the whole principal, recycling none of debtOf(old)");
        assertEq(ace.restingOf(id), rs, "and the source's resting cash is unmoved");
        assertEq(ace.debtOf(oldId), 0, "the retired loan owes nothing");
        assertEq(ace.debtOf(newId), n, "the successor owes its principal");
        _assertTheLedgerAgrees();
        _assertPayingItClosesEveryLiveLoan();
        _assertNonzeroExactlyWhenLive();
    }

    /// @notice `refinanceByPolicy`: the successor owes exactly what `tryContinue` quoted, and the old id reads zero.
    /// @notice The home roll draws that quote less `debtOf(old)`: the consumer's equation holds on the keeper's door too.
    function test_DebtOf_APolicyRollOwesWhatTryContinueQuoted() public {
        uint256 oldId = _armedInWindow(0, 0);
        uint256 d = ace.debtOf(oldId);
        (bool ok,, uint256 quoted) = ace.tryContinue(oldId);
        assertTrue(ok, "premise: the roll is admissible");
        assertGt(quoted, d, "premise: the roll draws past the old debt, so the successor's figure is its own");
        uint256 r0 = ace.restingOf(id);
        vm.prank(keeper);
        uint256 newId = ace.refinanceByPolicy(oldId);

        assertEq(ace.debtOf(newId), quoted, "the successor owes what tryContinue quoted");
        assertEq(ace.debtOf(oldId), 0, "the rolled loan owes nothing");
        assertEq(r0 - ace.restingOf(id), quoted - d, "the home roll drew its quote less debtOf(old), to the wei");
        (ok,, quoted) = ace.tryContinue(oldId);
        assertFalse(ok, "the closed loan quotes no continuation");
        assertEq(quoted, 0, "and no successor debt, agreeing with its zero");
        _assertTheLedgerAgrees();
        _assertPayingItClosesEveryLiveLoan();
        _assertNonzeroExactlyWhenLive();
    }

    /// @notice `refinanceByPolicyTo` a sibling: the successor owes what `tryContinueTo` quoted, and draws all of it there.
    function test_DebtOf_ARoutedPolicyRollOwesWhatTryContinueToQuoted() public {
        bytes32 dst = _sibling(30);
        uint256 oldId = _armedInWindow(500, 200);
        (bool ok, bytes4 why, uint256 quoted) = ace.tryContinueTo(oldId, dst);
        assertTrue(ok, string.concat("premise: the routed roll is admissible; refused with ", vm.toString(bytes32(why))));
        uint256 rd = ace.restingOf(dst);
        vm.prank(keeper);
        uint256 newId = ace.refinanceByPolicyTo(oldId, dst);

        assertEq(ace.loanMarket(newId), dst, "premise: the successor sits in the destination");
        assertEq(ace.debtOf(newId), quoted, "the successor owes what tryContinueTo quoted");
        assertEq(ace.debtOf(oldId), 0, "the rolled loan owes nothing");
        assertEq(rd - ace.restingOf(dst), quoted, "a routed roll drew its whole quote in the destination");
        _assertTheLedgerAgrees();
        _assertPayingItClosesEveryLiveLoan();
        _assertNonzeroExactlyWhenLive();
    }

    /// @notice `refinanceByPolicies` over two armed loans, passed in reverse: each successor owes its own loan's quote, in input order.
    function test_DebtOf_ABatchedPolicyRollOwesEachQuote() public {
        uint256 a = _open(COLL, TEN7);
        uint256 b = _openOn(id, BIG, P + 2_000e6, TEN7);
        vm.startPrank(borrower);
        ace.setAutoRefinance(a, TEN7, 0, 0);
        ace.setAutoRefinance(b, TEN7, 0, 0);
        vm.stopPrank();
        _warpTo(uint256(read.loan(a).expiry) - MarketInit.homeRollHold(TEN7) / 2);
        (,, uint256 qa) = ace.tryContinue(a);
        (,, uint256 qb) = ace.tryContinue(b);
        assertTrue(qa != qb && qa != 0 && qb != 0, "premise: two distinct live quotes, so a swapped pairing would show");

        uint256[] memory ids = new uint256[](2);
        (ids[0], ids[1]) = (b, a);
        vm.prank(keeper);
        uint256[] memory newIds = ace.refinanceByPolicies(ids);

        assertEq(ace.debtOf(newIds[0]), qb, "the first successor owes the first input's quote");
        assertEq(ace.debtOf(newIds[1]), qa, "the second successor owes the second input's quote");
        assertEq(ace.debtOf(a) + ace.debtOf(b), 0, "both rolled loans owe nothing");
        _assertTheLedgerAgrees();
        _assertPayingItClosesEveryLiveLoan();
        _assertNonzeroExactlyWhenLive();
    }

    // ---- a melt that leaves the loan live ----

    /// @notice A deleverage that charges the protocol cut melts only the NET: the loan stays live, owing its debt less what the crank paid.
    /// @dev The net is the `Deleveraged` log's `debtPaid`, under the realized quote by the cut; the home market's zero cut cannot tell them apart.
    /// @dev The record price sits 30% over the trigger, so the cut-charging restore fits the secured base and the cut is taken.
    function test_DebtOf_ACutChargingDeleverageLowersItByTheNetOnly() public {
        MarketParams memory q = ace.idToMarketParams(id);
        q.deleverageProtocolBps = 500;
        bytes32 cut = ace.createMarket(q);
        _deposit(cut, 20_000e6);
        uint256 loanId = _openOn(cut, COLL, P, 0);
        uint256 before = ace.debtOf(loanId);

        uint256 trig = read.triggerPrice(loanId);
        record.setBelowBand(FullMath.mulDivRoundingUp(trig, 1e18, 1e18 - BAND_BPS * 1e14));
        record.setMinPrice(trig + (trig * 3) / 10);
        vm.recordLogs();
        (, uint256 stableOut) = ace.deleverage(loanId, 0, "");
        uint256 paid = _debtPaid(vm.getRecordedLogs(), loanId);

        assertGt(paid, 0, "premise: the crank melted debt");
        assertLt(paid, stableOut, "premise: the crank charged the cut, so the net sits under the quote realized");
        assertTrue(ace.isLiveLoan(loanId), "the melt did not close the loan");
        assertEq(ace.debtOf(loanId), before - paid, "debt fell by the net the crank paid, not the quote it realized");
        _assertTheLedgerAgrees();
        _assertPayingItClosesEveryLiveLoan();
        _assertNonzeroExactlyWhenLive();
    }

    /// @dev The one `Deleveraged` the hub logged for `loanId`: the debt the crank paid.
    function _debtPaid(Vm.Log[] memory logs, uint256 loanId) internal view returns (uint256 paid) {
        uint256 hits;
        for (uint256 i; i < logs.length; i++) {
            if (logs[i].emitter != address(ace) || logs[i].topics[0] != DELEVERAGED) continue;
            if (uint256(logs[i].topics[1]) != loanId) continue;
            (,, paid) = abi.decode(logs[i].data, (uint256, uint256, uint256));
            hits++;
        }
        assertEq(hits, 1, "fixture: exactly one Deleveraged for the cranked loan");
    }

    // ---- multicall ----

    /// @notice Between multicall legs the guard is down and `debtOf` answers: an open, two repays, and a read after each.
    /// @dev Each leg is a DELEGATECALL into the hub as the caller, so a view leg reads what the legs before it committed.
    function test_DebtOf_AnswersBetweenMulticallLegs() public {
        uint256 next = read.loanCount() + 1;
        vault.mint(borrower, COLL);
        vm.prank(borrower);
        vault.approve(address(pm), COLL);
        bytes[] memory legs = new bytes[](6);
        legs[0] = abi.encodeCall(Ace.open, (id, COLL, P, 0, borrower, OpenBounds(0, 0, 0)));
        legs[1] = abi.encodeCall(Ace.debtOf, (next));
        legs[2] = abi.encodeCall(Ace.repay, (next, P / 5));
        legs[3] = abi.encodeCall(Ace.debtOf, (next));
        legs[4] = abi.encodeCall(Ace.repay, (next, type(uint256).max));
        legs[5] = abi.encodeCall(Ace.debtOf, (next));
        vm.prank(borrower);
        bytes[] memory out = ace.multicall(legs);

        assertEq(abi.decode(out[0], (uint256)), next, "premise: the open leg minted the id the reads name");
        assertEq(abi.decode(out[1], (uint256)), P, "read after the open: the principal");
        assertEq(abi.decode(out[3], (uint256)), P - P / 5, "read after the partial repay: the principal less the payment");
        assertEq(abi.decode(out[5], (uint256)), 0, "read after the closing repay: zero");
        assertTrue(ace.isClosed(next), "premise: the closing leg closed it");
        _assertNonzeroExactlyWhenLive();
    }
}
