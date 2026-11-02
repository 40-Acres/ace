// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.36;

import {FullMath} from "@uniswap/v4-core/src/libraries/FullMath.sol";
import {Ace} from "../../src/ace/hub/Ace.sol";
import {AceLens} from "../../src/ace/lens/AceLens.sol";
import {LoanClosed, NotExpired} from "../../src/ace/hub/Settlement.sol";
import {MarketParams, OpenBounds} from "../../src/ace/hub/Types.sol";
import {PositionManager} from "../../src/ace/positions/PositionManager.sol";
import {IPersistenceRecord} from "../../src/interfaces/IPersistenceRecord.sol";
import {IRollPolicy} from "../../src/interfaces/IRollPolicy.sol";
import {MockBlacklistERC20} from "../mocks/MockBlacklistERC20.sol";
import {MockBlockableERC20} from "../mocks/MockBlockableERC20.sol";
import {MockBlockableStakeVault} from "../mocks/MockBlockableStakeVault.sol";
import {MockERC20} from "../mocks/MockERC20.sol";
import {MockHostileGasERC20} from "../mocks/MockHostileGasERC20.sol";
import {MockPersistenceRecord} from "../mocks/MockPersistenceRecord.sol";
import {MockStakeVault} from "../mocks/MockStakeVault.sol";
import {ReenterOnRetireManager} from "../mocks/ReenterOnRetireManager.sol";
import {AceFixtures} from "../utils/AceFixtures.sol";
import {AceReader} from "../utils/AceReader.sol";
import {BookedQuote} from "../utils/BookedQuote.sol";
import {GUARD_TRIP} from "../utils/GuardTrip.sol";
import {GasBurnerPolicy, NoPolicy, RevertingPolicy, YesPolicy} from "../utils/RollPolicyMocks.sol";
import {WarpClock} from "../utils/WarpClock.sol";

/// @notice The two calls every quote mock here answers, so one helper funds a market whatever its token.
interface IFundable {
    function mint(address to, uint256 amount) external;
    function approve(address spender, uint256 amount) external returns (bool);
    function balanceOf(address who) external view returns (uint256);
}

/// @title AceExpirySettlesOnlyTest
/// @notice MANUAL RENEWAL'S EXPIRY: `forceClose` is the one settle verb, from the expiry second, and it only settles.
/// @notice It asks no roll policy and calls no record; a dying record, any policy and a hostile quote leave it able to settle.
/// @notice The rows `AceSettleExpiredHardening` and the two pause suites held with no `forceClose` twin are ported here (review R-3).
/// @dev Reasoning: the design record, Q1,.
contract AceExpirySettlesOnlyTest is WarpClock {
    Ace internal ace;
    AceReader internal read;
    AceLens internal lens;
    PositionManager internal pm;
    MockERC20 internal usdc;
    MockStakeVault internal coll;
    MockPersistenceRecord internal rec;
    bytes32 internal id;
    address internal policy;
    uint256 internal par;

    address internal alice = address(0xA11CE); // every market's one lender
    address internal borrower = address(0xB0B);
    address internal keeper = address(0xCAFE);

    uint64 internal constant TEN7 = 7 days;
    uint64 internal constant MAX_T = 28 days;
    uint256 internal constant P = 10_000e6;
    uint256 internal constant BOUNTY = 50; // a settle bounty, so every close credits a real sliver
    uint256 internal constant S = 1 << 96;

    function setUp() public {
        _warpTo(1_000_000);
        usdc = new MockERC20("USD Coin", "USDC", 6);
        coll = new MockStakeVault(42);
        par = AceFixtures.priceAt(address(usdc), address(coll), 0);
        rec = _record(address(usdc), address(coll));
        AceFixtures.Deployment memory d = AceFixtures.deploy(_params(address(usdc), address(coll), address(rec)));
        (ace, pm, read, id) = (d.ace, d.positionManager, d.read, d.id);
        lens = new AceLens(address(ace));
        policy = AceFixtures.installYesPolicy(ace, alice);
    }

    /* ============================== fixture ============================== */

    function _record(address quote, address collateral) internal returns (MockPersistenceRecord r) {
        r = new MockPersistenceRecord(quote, collateral);
        r.setMinPrice(AceFixtures.priceAt(quote, collateral, 0));
    }

    function _params(address quote, address collateral, address record) internal view returns (MarketParams memory p) {
        p = AceFixtures.marketParams(quote, collateral);
        p.record = record;
        p.lender = alice;
        p.minTenor = TEN7;
        p.maxTenor = MAX_T;
        p.settleBountyBps = BOUNTY;
    }

    /// @dev Another market of alice's on this hub, at a fresh quote or collateral, with its own record unless `recordless`.
    function _market(address quote, address collateral, bool recordless) internal returns (bytes32) {
        address r = recordless ? address(0) : address(_record(quote, collateral));
        return ace.createMarket(_params(quote, collateral, r));
    }

    /// @dev Units that put `debt`'s trigger at half the market's price.
    function _units(bytes32 mid, uint256 debt) internal view returns (uint256) {
        return FullMath.mulDiv(ace.idToMarketParams(mid).minCoverageWad * debt, S * 10000, 5000 * par * 1e18);
    }

    /// @dev Alice rests three loans' worth in `mid`; the borrower opens `P` for `TEN7` against a lot at half the price.
    function _loanIn(bytes32 mid) internal returns (uint256 loanId) {
        MarketParams memory p = ace.idToMarketParams(mid);
        IFundable q = IFundable(p.quote);
        q.mint(alice, 3 * P);
        vm.startPrank(alice);
        q.approve(address(ace), type(uint256).max);
        ace.deposit(mid, 3 * P);
        vm.stopPrank();
        uint256 units = _units(mid, P);
        IFundable(p.collateral).mint(borrower, units);
        vm.startPrank(borrower);
        IFundable(p.collateral).approve(address(pm), units);
        q.approve(address(ace), type(uint256).max);
        loanId = ace.open(mid, units, P, TEN7, borrower, OpenBounds(0, 0, 0));
        vm.stopPrank();
    }

    function _loan() internal returns (uint256) {
        return _loanIn(id);
    }

    /// @dev The keeper settles at its expiry second.
    function _settleAtExpiry(uint256 loanId) internal {
        _warpTo(read.loan(loanId).expiry);
        vm.prank(keeper);
        ace.forceClose(loanId);
    }

    /// @dev O1 over one market of alice's: the hub's quote balance is exactly its booked pots.
    function _assertSolvent(bytes32 mid) internal view {
        bytes32[] memory markets = new bytes32[](1);
        markets[0] = mid;
        address[] memory lenders = new address[](1);
        lenders[0] = alice;
        address quote = ace.idToMarketParams(mid).quote;
        assertEq(IFundable(quote).balanceOf(address(ace)), BookedQuote.total(ace, read, markets, lenders, quote), "O1: hub balance != booked pots");
    }

    /// @notice What one settlement credited, captured so two runs can be compared.
    struct Settled {
        uint256 keeperUnits;
        uint256 borrowerUnits;
        uint256 potUnits;
        uint256 owed;
        uint256 badDebt;
    }

    function _capture(uint256 loanId) internal view returns (Settled memory s) {
        s.keeperUnits = read.unitsOwedOf(loanId, keeper);
        s.borrowerUnits = read.unitsOwedOf(loanId, borrower);
        s.potUnits = read.invPotOf(id, loanId);
        (,, s.owed) = read.poolOf(id);
        (, s.badDebt) = read.shortfallOf(loanId);
    }

    /* ============================== the one settle verb ============================== */

    /// @notice `forceClose` refuses `NotExpired` a second before expiry and settles at the expiry second itself.
    function test_SettlesFromTheExpirySecondAndNotBefore() public {
        uint256 loanId = _loan();
        uint64 x = read.loan(loanId).expiry;
        _warpTo(uint256(x) - 1);
        vm.prank(keeper);
        vm.expectRevert(NotExpired.selector);
        ace.forceClose(loanId);
        _warpTo(x);
        vm.prank(keeper);
        ace.forceClose(loanId);
        assertTrue(ace.isClosed(loanId), "the loan settled at the expiry second");
        assertEq(read.claimOf(id, loanId), 0, "its claim converted");
        assertGt(read.invPotOf(id, loanId), 0, "into the lender's pot");
    }

    /// @notice The keeper is always credited the sliver, priced at the loan's funding floor: there is no unpaid door left.
    function test_TheKeeperIsCreditedTheSliverAtTheFundingFloor() public {
        uint256 loanId = _loan();
        uint256 debt = read.debtOf(loanId);
        uint256 sliver = FullMath.mulDiv(debt * BOUNTY, S, 10000 * par);
        assertGt(sliver, 0, "PREMISE: a real sliver");
        _settleAtExpiry(loanId);
        assertEq(read.unitsOwedOf(loanId, keeper), sliver, "the keeper is credited the sliver at the funding floor");
    }

    /// @notice A sick, a dark and a silent record each leave the loan settleable: `forceClose` reads none of them.
    function test_ASickDarkOrSilentRecordCannotStopIt() public {
        uint256 loanId = _loan();
        _warpTo(read.loan(loanId).expiry);
        for (uint256 mode; mode < 3; mode++) {
            uint256 snap = vm.snapshotState();
            if (mode == 0) rec.setSick(true);
            if (mode == 1) rec.setMinPrice(0);
            if (mode == 2) rec.setShortAnswer(true);
            vm.prank(keeper);
            ace.forceClose(loanId);
            assertTrue(ace.isClosed(loanId), "the loan settled whatever the record answered");
            assertEq(read.claimOf(id, loanId), 0, "and its claim converted");
            vm.revertToStateAndDelete(snap);
        }
    }

    /// @notice It asks no roll policy and calls no record: a consenting policy is named, and neither is reached.
    function test_ItAsksNoPolicyAndCallsNoRecord() public {
        uint256 loanId = _loan();
        _warpTo(read.loan(loanId).expiry);
        vm.expectCall(policy, abi.encodeWithSelector(IRollPolicy.admitsExtension.selector), 0);
        vm.expectCall(address(rec), abi.encodeWithSelector(IPersistenceRecord.minPrice.selector), 0);
        vm.expectCall(address(rec), abi.encodeWithSelector(IPersistenceRecord.persistedBelowSettle.selector), 0);
        vm.expectCall(address(rec), abi.encodeWithSelector(IPersistenceRecord.persistedBelowDistress.selector), 0);
        vm.prank(keeper);
        ace.forceClose(loanId);
        assertTrue(ace.isClosed(loanId), "the loan settled");
    }

    /// @notice Whatever the lender's policy answers, or burns, the same loan settles into the same credits.
    function testFuzz_EveryPolicySettlesTheSameLot(uint8 which) public {
        uint256 loanId = _loan();
        _warpTo(read.loan(loanId).expiry);
        uint256 snap = vm.snapshotState();
        vm.prank(alice);
        ace.setRollPolicy(address(0));
        vm.prank(keeper);
        ace.forceClose(loanId);
        Settled memory base = _capture(loanId);
        vm.revertToStateAndDelete(snap);
        address[4] memory policies = [policy, address(new NoPolicy()), address(new RevertingPolicy()), address(new GasBurnerPolicy())];
        vm.prank(alice);
        ace.setRollPolicy(policies[which % 4]);
        vm.prank(keeper);
        ace.forceClose(loanId);
        Settled memory got = _capture(loanId);
        assertTrue(ace.isClosed(loanId), "the loan settled under the named policy");
        assertEq(got.keeperUnits, base.keeperUnits, "the same sliver");
        assertEq(got.borrowerUnits, base.borrowerUnits, "the same equity to the borrower");
        assertEq(got.potUnits, base.potUnits, "the same pot to the lender");
        assertEq(got.owed, base.owed, "the same quote to the lender");
        assertEq(got.badDebt, base.badDebt, "and the same loss");
    }

    /// @notice The deleted doors are gone: the hub answers no `settleExpired` or `setAutoExtend`, and the lens no `armable` or `autoPolicyOf`.
    function test_TheDeletedSelectorsAreGone() public {
        uint256 loanId = _loan();
        _warpTo(uint256(read.loan(loanId).expiry) + 1 days);
        _assertGone(address(ace), abi.encodeWithSignature("settleExpired(uint256)", loanId), "settleExpired");
        _assertGone(address(ace), abi.encodeWithSignature("setAutoExtend(uint256,uint64,uint16)", loanId, TEN7, uint16(0)), "setAutoExtend");
        _assertGone(address(lens), abi.encodeWithSignature("armable(uint256,uint64)", loanId, TEN7), "armable");
        _assertGone(address(lens), abi.encodeWithSignature("autoPolicyOf(uint256)", loanId), "autoPolicyOf");
        assertTrue(ace.isLiveLoan(loanId), "and none of the calls touched the loan");
    }

    function _assertGone(address target, bytes memory call, string memory name) internal {
        (bool ok, bytes memory ret) = target.call(call);
        assertFalse(ok, string.concat(name, " still answers"));
        assertEq(ret.length, 0, string.concat(name, " reverted with data: the selector still dispatches"));
    }

    /* ============================== a hostile quote on the push and the sweep (review R-3) ============================== */

    /// @dev A loan in a market whose quote is the hostile mock, armed AFTER funding so only the closing push meets it.
    function _hostileLoan() internal returns (MockHostileGasERC20 hq, bytes32 mid, uint256 loanId) {
        hq = new MockHostileGasERC20("Hostile USD", "HUSD", 6);
        mid = _market(address(hq), address(coll), false);
        loanId = _loanIn(mid);
        hq.setBurnOnlyTo(alice);
    }

    function _settleHostile(bytes32 mid, uint256 loanId) internal {
        _warpTo(read.loan(loanId).expiry);
        vm.prank(keeper);
        ace.forceClose{gas: 5_000_000}(loanId);
        assertTrue(ace.isClosed(loanId), "the hostile quote did not stop the settlement");
        _assertSolvent(mid);
    }

    /// @notice A quote that refuses the lender's push leaves the loan settled and the lender's credit whole for `collect`.
    function test_ARefusingQuoteOnThePushCannotStopIt() public {
        (MockHostileGasERC20 hq, bytes32 mid, uint256 loanId) = _hostileLoan();
        hq.setReverting(true);
        _settleHostile(mid, loanId);
        (,, uint256 owed) = read.poolOf(mid);
        assertGt(owed, 0, "the refused push restored the lender's credit");
        assertEq(hq.balanceOf(alice), 0, "and paid the lender nothing");
    }

    /// @notice A quote that burns its whole budget on the push leaves the loan settled and the lender's credit whole.
    function test_AGasBurningQuoteOnThePushCannotStopIt() public {
        (MockHostileGasERC20 hq, bytes32 mid, uint256 loanId) = _hostileLoan();
        hq.setBurnAll(true);
        _settleHostile(mid, loanId);
        (,, uint256 owed) = read.poolOf(mid);
        assertGt(owed, 0, "the burned push restored the lender's credit");
    }

    /// @notice A quote that answers the push with a mebibyte of returndata leaves the loan settled and the books whole.
    function test_AReturnBombOnThePushCannotStopIt() public {
        (MockHostileGasERC20 hq, bytes32 mid, uint256 loanId) = _hostileLoan();
        hq.setBombWords(32768);
        _settleHostile(mid, loanId);
    }

    /// @notice A quote that refuses the treasury leaves the loan settled; the best-effort sweep keeps the revenue it could not send.
    function test_ARefusingTreasuryOnTheSweepCannotStopIt() public {
        MockBlacklistERC20 bq = new MockBlacklistERC20("Blacklist USD", "BUSD", 6);
        bytes32 mid = _market(address(bq), address(coll), false);
        uint256 loanId = _loanIn(mid);
        bq.setBlacklisted(AceFixtures.TREASURY, true);
        uint256 rev0 = read.protocolRevenue(mid);
        assertGt(rev0, 0, "PREMISE: revenue is due");
        _warpTo(read.loan(loanId).expiry);
        vm.expectEmit(true, true, false, false, address(ace));
        emit Ace.RevenueSweepFailed(mid, AceFixtures.TREASURY, rev0, 0);
        vm.prank(keeper);
        ace.forceClose(loanId);
        assertTrue(ace.isClosed(loanId), "the refused sweep did not stop the settlement");
        assertEq(read.protocolRevenue(mid), rev0, "and the revenue stays counted");
        _assertSolvent(mid);
    }

    /// @notice The least limit that clears the push's floor settles and pushes the lender, and the sweep behind it skips.
    /// @notice A fat limit settles the same loan and sweeps too: the sweep rides the close, after the push.
    function test_TheLeastLimitClearsThePushAndSkipsTheSweep() public {
        uint256 loanId = _loan();
        _warpTo(read.loan(loanId).expiry);
        uint256 rev0 = read.protocolRevenue(id);
        uint64 stamp0 = read.marketState(id).lastSweptAt;
        assertGt(rev0, 0, "PREMISE: revenue is due");
        uint256 g = _leastSettling(loanId);
        assertGe(g, ace.PUSH_FLOOR(), "no settling limit sits under the push's published floor");

        uint256 snap = vm.snapshotState();
        uint256 bal0 = usdc.balanceOf(alice);
        vm.prank(keeper);
        ace.forceClose{gas: g}(loanId);
        assertTrue(ace.isClosed(loanId), "the least limit settled");
        (,, uint256 owed) = read.poolOf(id);
        assertEq(owed, 0, "and pushed the lender");
        assertGt(usdc.balanceOf(alice), bal0, "who was paid");
        assertEq(read.protocolRevenue(id), rev0, "while the sweep skipped");
        assertEq(read.marketState(id).lastSweptAt, stamp0, "and stamped nothing");
        vm.revertToStateAndDelete(snap);

        vm.prank(keeper);
        ace.forceClose{gas: 3_000_000}(loanId);
        assertTrue(ace.isClosed(loanId), "the fat limit settled");
        assertEq(read.protocolRevenue(id), 0, "and swept the revenue after the push");
    }

    /// @dev The least gas at which `forceClose` lands, by bisection; every probe runs in a snapshot.
    function _leastSettling(uint256 loanId) internal returns (uint256 hi) {
        uint256 lo = 50_000;
        hi = 3_000_000;
        assertFalse(_settles(loanId, lo), "PREMISE: a starved limit does not settle");
        assertTrue(_settles(loanId, hi), "PREMISE: a fat limit settles");
        while (hi - lo > 1) {
            uint256 mid = (lo + hi) / 2;
            if (_settles(loanId, mid)) hi = mid;
            else lo = mid;
        }
    }

    function _settles(uint256 loanId, uint256 g) internal returns (bool ok) {
        uint256 snap = vm.snapshotState();
        vm.prank(keeper);
        try ace.forceClose{gas: g}(loanId) {
            ok = true;
        } catch {
            ok = false;
        }
        vm.revertToStateAndDelete(snap);
    }

    /* ============================== a recordless market (ported) ============================== */

    /// @notice A recordless market settles whole at tenor: the claim converts, the pot holds it, the floor retires.
    function test_ARecordlessMarket_SettlesWhole() public {
        bytes32 mid = _market(address(usdc), address(coll), true);
        assertEq(ace.idToMarketParams(mid).record, address(0), "PREMISE: no record");
        uint256 loanId = _loanIn(mid);
        uint256 lentBefore = read.poolLent(mid);
        _settleAtExpiry(loanId);
        assertTrue(ace.isClosed(loanId), "the loan must close");
        assertEq(read.loan(loanId).collateralUnits, 0, "and leave the live ledger");
        assertLt(read.poolLent(mid), lentBefore, "the claim must have converted, not merely been abandoned");
        assertEq(read.claimOf(mid, loanId), 0, "the claim must be zeroed");
        assertGt(read.invPotOf(mid, loanId), 0, "and the pot must hold the units it converted into");
        assertEq(read.fundingFloor(mid, loanId), 0, "a closed loan carries no funding floor");
        _assertSolvent(mid);
    }

    /* ============================== the reentrancy guard (ported) ============================== */

    /// @notice The hub's guard is HELD across the custody hop, settlement's one external call: a re-entrant `forceClose` is refused.
    function test_HoldsTheGuardAcrossTheCustodyHop() public {
        (Ace hub, ReenterOnRetireManager manager, AceLens l, uint256 loanId) = _reentrantFixture();
        manager.arm(loanId, abi.encodeCall(Ace.forceClose, (loanId)));
        _warpTo(l.loan(loanId).expiry);
        vm.prank(keeper);
        hub.forceClose(loanId);
        assertEq(manager.attempts(), 1, "the custody hop must actually have fired");
        assertFalse(manager.lastOk(), "GUARD: a re-entrant forceClose got through the custody hop");
        assertEq(manager.lastSelector(), GUARD_TRIP, "and the guard must be what refused it");
        assertTrue(hub.isClosed(loanId), "while the outer settlement still completed");
    }

    /// @notice The lock is the HUB's, not this verb's: an unrelated hub call re-entered from the hop is refused too.
    function test_TheGuardCoversTheWholeHubSurface() public {
        (Ace hub, ReenterOnRetireManager manager, AceLens l, uint256 loanId) = _reentrantFixture();
        bytes32 m = l.loan(loanId).market;
        manager.arm(loanId, abi.encodeCall(Ace.sweepRevenue, (m)));
        _warpTo(l.loan(loanId).expiry);
        vm.prank(keeper);
        hub.forceClose(loanId);
        assertEq(manager.attempts(), 1, "the custody hop must actually have fired");
        assertFalse(manager.lastOk(), "GUARD: an unrelated hub verb ran from inside the custody hop");
        assertEq(manager.lastSelector(), GUARD_TRIP, "and the guard must be what refused it");
        vm.prank(keeper);
        hub.sweepRevenue(m); // control: the same call succeeds from outside, so the refusal above is the guard
    }

    /// @dev A hub whose custodian re-enters it from inside `retireCustody`; the manager comes first, at the predicted hub.
    function _reentrantFixture() internal returns (Ace hub, ReenterOnRetireManager manager, AceLens l, uint256 loanId) {
        address predictedHub = vm.computeCreateAddress(address(this), vm.getNonce(address(this)) + 1);
        manager = new ReenterOnRetireManager(predictedHub);
        hub = new Ace(AceFixtures.TREASURY, address(manager), AceFixtures.PUSH_GAS, AceFixtures.POLICY_GAS);
        MarketParams memory p = AceFixtures.marketParams(address(usdc), address(coll));
        p.record = address(0);
        bytes32 m = hub.createMarket(p);
        l = new AceLens(address(hub));
        usdc.mint(alice, 20_000e6);
        vm.startPrank(alice);
        usdc.approve(address(hub), 20_000e6);
        hub.deposit(m, 20_000e6);
        vm.stopPrank();
        uint256 units = 10_000e18;
        coll.mint(borrower, units);
        vm.startPrank(borrower);
        coll.approve(address(manager), units);
        loanId = hub.open(m, units, 4_500e6, TEN7, borrower, OpenBounds(0, 0, 0));
        vm.stopPrank();
    }

    /* ============================== a closed loan (ported) ============================== */

    /// @notice Settling twice refuses by name, never settling a second time into an empty ledger.
    function test_LoanClosed_ADoubleSettleRefusesByName() public {
        uint256 loanId = _loan();
        _settleAtExpiry(loanId);
        uint256 owed = read.unitsOwedOf(loanId, borrower);
        vm.prank(keeper);
        vm.expectRevert(LoanClosed.selector);
        ace.forceClose(loanId);
        assertEq(read.unitsOwedOf(loanId, borrower), owed, "and nothing was credited a second time");
    }

    /// @notice A REPAID loan is retired without settling, and `forceClose` must not reopen it.
    function test_LoanClosed_AfterAFullRepayRefusesByName() public {
        uint256 loanId = _loan();
        uint256 debt = read.debtOf(loanId);
        usdc.mint(borrower, debt);
        vm.prank(borrower);
        ace.repay(loanId, debt);
        assertTrue(ace.isClosed(loanId), "PREMISE: a full repay retires the loan");
        uint256 owed = read.unitsOwedOf(loanId, borrower);
        assertGt(owed, 0, "PREMISE: the repay credited the borrower their whole lot");
        _warpTo(read.loan(loanId).expiry);
        vm.prank(keeper);
        vm.expectRevert(LoanClosed.selector);
        ace.forceClose(loanId);
        assertEq(read.unitsOwedOf(loanId, borrower), owed, "and the borrower's credit is untouched");
    }

    /* ============================== a pause across expiry (ported, review R-2) ============================== */

    /// @notice A transfer-paused COLLATERAL leaves the loan settleable: settlement moves no collateral token.
    function test_PausedCollateral_ItSettles() public {
        MockBlockableStakeVault bc = new MockBlockableStakeVault();
        bytes32 mid = _market(address(usdc), address(bc), false);
        uint256 loanId = _loanIn(mid);
        bc.setPaused(true);
        _settleAtExpiry(loanId);
        assertTrue(ace.isClosed(loanId), "settlement is accounting-only and survives the pause");
        assertGt(read.invPotOf(mid, loanId), 0, "the claim converted into a pot");
    }

    /// @notice A transfer-paused QUOTE leaves the loan settleable: the push and the sweep swallow the refusal.
    function test_PausedQuote_ItSettles() public {
        MockBlockableERC20 pq = new MockBlockableERC20("USD Coin", "USDC", 6);
        bytes32 mid = _market(address(pq), address(coll), false);
        uint256 loanId = _loanIn(mid);
        pq.setPaused(true);
        _settleAtExpiry(loanId);
        assertTrue(ace.isClosed(loanId), "settlement survives the quote pause");
        (,, uint256 owed) = read.poolOf(mid);
        assertGt(owed, 0, "and the refused push left the lender's credit whole");
        _assertSolvent(mid);
    }

    /// @notice R-2: under a paused quote a cash `extend` refuses, since it pulls quote, and `forceClose` settles the loan.
    /// @dev The unpaused control lands the same extension first, so the refusal is the pause talking.
    function test_PausedQuote_ExtendRefusesAndForceCloseSettles() public {
        MockBlockableERC20 pq = new MockBlockableERC20("USD Coin", "USDC", 6);
        bytes32 mid = _market(address(pq), address(coll), false);
        uint256 loanId = _loanIn(mid);
        pq.mint(borrower, P);
        _warpBy(1 days);
        uint256 snap = vm.snapshotState();
        vm.prank(borrower);
        ace.extend(loanId, 0, "");
        assertEq(read.loan(loanId).expiry, _now() + TEN7, "CONTROL: unpaused, the extension lands");
        vm.revertToStateAndDelete(snap);
        pq.setPaused(true);
        vm.prank(borrower);
        vm.expectRevert();
        ace.extend(loanId, 0, "");
        _settleAtExpiry(loanId);
        assertTrue(ace.isClosed(loanId), "the loan settles at expiry under the pause");
    }
}
