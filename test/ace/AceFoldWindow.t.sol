// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.36;

import {WarpClock} from "../utils/WarpClock.sol";
import {Ace} from "../../src/ace/hub/Ace.sol";
import {AceLens} from "../../src/ace/lens/AceLens.sol";
import {MarketInit} from "../../src/ace/hub/MarketInit.sol";
import {MarketParams, OpenBounds} from "../../src/ace/hub/Types.sol";
import {PositionManager} from "../../src/ace/positions/PositionManager.sol";
import {MockERC20} from "../mocks/MockERC20.sol";
import {MockPersistenceRecord} from "../mocks/MockPersistenceRecord.sol";
import {RetireProbeManager} from "../mocks/RetireProbeManager.sol";
import {BurnAllRecord, CostlyRecord} from "../mocks/UntrustedDependencyMocks.sol";
import {AceFixtures} from "../utils/AceFixtures.sol";
import {AceReader} from "../utils/AceReader.sol";

/// @notice The backstop verb this change adds, declared test-side so the suite compiles before it exists.
/// @dev RED TODAY BY DISPATCH, not by compiler: `Ace` carries no fallback, so an absent selector reverts empty.
interface IAceSettleExpired {
    function settleExpired(uint256 id) external;
}

/// @notice The continuation doors, declared test-side exactly as the neighbouring fold suites declare them.
interface IAceAuto {
    function setAutoRefinance(uint256 id, uint64 tenor, uint16 minBufferBps, uint16 maxFeeBps) external;
    function tryContinue(uint256 id) external view returns (bool ok, bytes4 reason, uint256 principal);
}

/// @title AceFoldWindow
/// @notice The EIP-150 brick, and the unpaid backstop that opens at `expiry + W` to clear it.
/// @notice A gate or a record that consumes its whole allowance inside the fold's predicate starves the
/// @notice settle branch that runs next, so an expired loan reaches no terminal state at any block budget.
/// @notice The paid path keeps its semantics; the whole of the new capability is `settleExpired`.
/// @dev The mocks burn with `invalid()`, which is the EIP-150 shape: the callee eats its 63/64 and answers nothing.
/// @dev An HONEST record over a long window and a short interval lands in the same place, so this models cost.
contract AceFoldWindowTest is WarpClock {
    Ace internal ace;
    AceReader internal read;
    PositionManager internal pm;

    MockERC20 internal usdc; // quote, 6 decimals
    MockERC20 internal coll; // collateral, 18 decimals

    MockPersistenceRecord internal record; // the healthy record beside the burning gate
    BurnAllRecord internal burnRecord;

    bytes32 internal mainMid; // healthy record; the burning-gate twin went with the gate interface
    bytes32 internal recMid; // NO gate, burning record

    address internal alice = address(0xA11CE); // the lender
    address internal borrower = address(0xB0B);
    address internal keeper = address(0xCA11E5); // any third party running the crank

    uint256 internal TOP; // par for this pair; assigned in setUp, since par is not a compile-time value
    int24 internal constant SPACING = 60; // the ladder stride, a distance rather than a coordinate
    uint256 internal constant TICKS = 32; // the fixture's maxClaimTicks: a fat settle is what the burn must starve
    uint256 internal constant PER_TICK = 400_000; // the old per-rung lot; the rig rests TICKS of these as one balance
    uint256 internal constant PRINCIPAL = 11_000_000; // draws across most of the ladder, so the settle walks many claims
    uint256 internal constant COLL = 10_000e18;
    uint64 internal constant TEN7 = 7 days;

    /// @dev A whole Ethereum block. The brick has to survive the most gas anyone can put behind one call.
    uint256 internal constant BLOCK_GAS = 30_000_000;

    OpenBounds internal OFF = OpenBounds(0, 0, 0);

    /// @dev This suite's pair, so a tick reads as its distance from par rather than as a grid coordinate.
    /// @param offset Ticks above par.
    /// @return The absolute grid tick.
    function _price(int24 offset) internal view returns (uint256) {
        return AceFixtures.priceAt(address(usdc), address(coll), offset);
    }

    function setUp() public {
        _warpTo(1_000_000);
        usdc = new MockERC20("USD Coin", "USDC", 6);
        coll = new MockERC20("Collateral", "COLL", 18);
        TOP = _price(0);
        record = new MockPersistenceRecord(address(usdc), address(coll));
        record.setMinPrice(AceFixtures.px(2e18, address(usdc), address(coll)));
        MarketParams memory p = AceFixtures.marketParams(address(usdc), address(coll));
        p.record = address(record);
        AceFixtures.Deployment memory d = AceFixtures.deploy(p);
        (ace, pm, read, mainMid) = (d.ace, d.positionManager, d.read, d.id);

        burnRecord = new BurnAllRecord(address(usdc), address(coll));
        MarketParams memory q = AceFixtures.marketParams(address(usdc), address(coll));
        q.record = address(burnRecord);
        recMid = ace.createMarket(q);
    }

    /* ========================= A: the brick, reproduced ========================= */

    /// @notice THE BRICK IS GONE AT THIS SHAPE, and the row is kept INVERTED as the witness that it is.
    /// @dev It reproduced the EIP-150 starve through the RECORD leg: the fold's predicate ate 63/64 of the
    /// @dev call's gas, and the SETTLE branch that ran next had to walk one claim PER FUNDED TICK, which the
    /// @dev remaining 1/64 could not pay for -- so an expired loan reached no terminal state at any block
    /// @dev budget. A loan holds ONE claim now, so settlement is O(1) and the remainder covers it easily.
    /// @dev `settleExpired` SURVIVES and is still pinned below: a costlier dependency puts the brick back,
    /// @dev and the backstop is what keeps that recoverable rather than fatal.
    function test_A2_ABurningRecord_NoLongerBricksTheArmedFold() public {
        uint256 loanId = _armedLadderLoan(recMid);
        uint256 expiry = read.loan(loanId).expiry;
        _warpTo(expiry + 1);
        assertEq(ace.idToMarketParams(recMid).borrower, address(0), "fixture: this leg must reach the record with no gate in front");

        burnRecord.setBurning(true);
        vm.prank(keeper);
        (bool ok,) = address(ace).call{gas: BLOCK_GAS}(abi.encodeCall(Ace.forceClose, (loanId)));
        assertTrue(ok, "the settle branch survives the burn: ONE claim to walk, not one per funded tick");
        assertTrue(ace.isClosed(loanId), "and the expired loan really did reach a terminal state");
    }

    /// @notice The contrast that makes the brick specifically about GAS: a predicate that merely cannot answer settles.
    /// @dev A record answering zero is unusable, not expensive, and the fold resolves the loan on the spot.
    function test_A3_AnUnanswerablePredicate_StillSettles() public {
        uint256 loanId = _armedLadderLoan(mainMid);
        _warpTo(read.loan(loanId).expiry + 1);
        record.setMinPrice(0); // usable price gone: `tryPersistedPrice` reports not-ok and the fold settles

        vm.prank(keeper);
        ace.forceClose(loanId);
        assertTrue(ace.isClosed(loanId), "an unanswerable predicate must route to settlement, not to a brick");
    }

    /// @notice The record leg of the same fix, on the gate-less market.
    function test_A5_SettleExpired_ClearsTheBurningRecordBrick() public {
        uint256 loanId = _armedLadderLoan(recMid);
        _warpTo(read.loan(loanId).expiry + _window(loanId));
        burnRecord.setBurning(true);

        vm.prank(keeper);
        IAceSettleExpired(address(ace)).settleExpired{gas: BLOCK_GAS}(loanId);
        assertTrue(ace.isClosed(loanId), "the backstop must settle the loan the burning record stranded");
    }

    /* ==================== B: the three pieces of the backstop ==================== */

    /// @notice PIECE 2: the backstop pays the caller nothing, and the borrower's residual is larger by exactly that.
    /// @dev Measured against the SAME loan settled by the paid verb under a snapshot, so the delta is only the sliver.
    /// @dev RED until `settleExpired` exists.
    function test_B1_SettleExpired_CreditsNoSliver_AndTheBorrowerKeepsIt() public {
        uint256 loanId = _plainLadderLoan(mainMid);
        _warpTo(read.loan(loanId).expiry + _window(loanId));

        uint256 snap = vm.snapshotState();
        vm.prank(keeper);
        ace.forceClose(loanId);
        uint256 paidSliver = read.unitsOwedOf(loanId, keeper);
        uint256 paidResidual = read.unitsOwedOf(loanId, borrower);
        vm.revertToState(snap);
        _warpTo(read.loan(loanId).expiry + _window(loanId));
        assertGt(paidSliver, 0, "fixture: the paid verb must credit a real sliver, or there is nothing to suppress");

        vm.prank(keeper);
        IAceSettleExpired(address(ace)).settleExpired(loanId);
        assertEq(read.unitsOwedOf(loanId, keeper), 0, "STEERING: the backstop credited the caller a sliver");
        assertEq(read.unitsOwedOf(loanId, borrower), paidResidual + paidSliver, "the suppressed sliver must reach the borrower");
    }

    /// @notice PIECE 3: the borrower's roll is protected -- the backstop does not open the instant a loan expires.
    /// @dev The success leg is what makes this non-vacuous; without it every assertion here passes on an absent verb.
    /// @dev RED until `settleExpired` exists.
    function test_B2_SettleExpired_RevertsBeforeTheWindow_AndOpensAtIt() public {
        uint256 loanId = _plainLadderLoan(mainMid);
        uint256 expiry = read.loan(loanId).expiry;
        uint64 w = _window(loanId);
        assertGt(w, 1, "fixture: a window of one second cannot separate the two legs below");

        _warpTo(expiry);
        vm.prank(keeper);
        (bool atExpiry,) = address(ace).call(abi.encodeCall(IAceSettleExpired.settleExpired, (loanId)));
        assertFalse(atExpiry, "GRIEF: the backstop opened the instant the loan expired");

        _warpTo(expiry + w - 1);
        vm.prank(keeper);
        (bool justBefore,) = address(ace).call(abi.encodeCall(IAceSettleExpired.settleExpired, (loanId)));
        assertFalse(justBefore, "GRIEF: the backstop opened one second early");

        _warpTo(expiry + w);
        vm.prank(keeper);
        IAceSettleExpired(address(ace)).settleExpired(loanId);
        assertTrue(ace.isClosed(loanId), "the backstop must open exactly at expiry + W");
    }

    /// @notice NOT A CUTOVER: the paid path still rolls an admissible loan long after the window opened.
    /// @dev The property rev 3 broke. It is green today and must stay green -- nothing about `W` gates the roll.
    function test_B3_ThePaidPath_StillRolls_LongAfterTheWindow() public {
        uint256 loanId = _armedLadderLoan(mainMid);
        _lendLadder(mainMid); // the successor draws afresh, so the ladder must still fund it
        _warpTo(read.loan(loanId).expiry + _window(loanId) + 1 days);

        (bool okNow,,) = IAceAuto(address(ace)).tryContinue(loanId);
        assertTrue(okNow, "fixture: the roll must still be admissible, or this measures the settle branch");

        uint256 before = read.loanCount();
        vm.prank(keeper);
        ace.forceClose(loanId);
        assertEq(read.loanCount(), before + 1, "a late crank must still roll: the backstop is a second door, not a deadline");
    }

    /// @notice Both paid branches still credit the sliver, and on the same formula.
    /// @dev Green today; it is the control the no-sliver assertion above is read against.
    function test_B4_BothPaidBranches_StillPayTheSliver() public {
        uint256 rollId = _armedLadderLoan(mainMid);
        _warpTo(read.loan(rollId).expiry + 1);
        vm.prank(keeper);
        ace.forceClose(rollId);
        assertGt(read.unitsOwedOf(rollId, keeper), 0, "the ROLL branch stopped paying the crank");

        uint256 settleId = _armedLadderLoan(mainMid);
        _warpTo(read.loan(settleId).expiry + 1);
        record.setMinPrice(0); // routes the same fold to its settle branch
        vm.prank(keeper);
        ace.forceClose(settleId);
        assertGt(read.unitsOwedOf(settleId, keeper), 0, "the SETTLE branch stopped paying the crank");
    }

    /* ============ C: the decider is CONDITIONAL, and the condition is S(1-f) > P ============ */

    /// @notice The paid path runs the predicate on BOTH branches; the backstop skips it. That is `P`, and it is not zero.
    /// @notice Pinned as a measurement so a retune of `settleBountyBps` or of an admissible record surfaces here.
    /// @dev The assumed gas price and ETH quote are stated as constants: the crossover is a claim ABOUT them.
    /// @dev RED on the last assertion until `settleExpired` exists; the measured `P` half is live today.
    function test_C_TheCrossover_ThePaidPathDominatesOnlyWhileTheSliverExceedsThePredicate() public {
        (bytes32 mid, CostlyRecord costly) = _costlyMarket();
        uint256 loanId = _armedLadderLoan(mid);
        uint256 expiry = read.loan(loanId).expiry;
        _warpTo(expiry + _window(loanId));

        uint256 cheap = _measurePaidFold(loanId, expiry, costly, 0);
        uint256 dear = _measurePaidFold(loanId, expiry, costly, 4_000);
        assertGt(dear, cheap, "fixture: the costly record must actually cost the paid path something");

        uint256 predicateGas = dear - cheap;
        uint256 predicateQuote = (predicateGas * GAS_PRICE_WEI * ETH_QUOTE) / 1e18;
        uint256 bountyBps = ace.idToMarketParams(mid).settleBountyBps;
        uint256 crossoverDebt = (predicateQuote * 10000) / bountyBps;
        emit log_named_uint("P, the predicate's marginal gas", predicateGas);
        emit log_named_uint("the crossover debt in quote atoms", crossoverDebt);

        assertLt((crossoverDebt / 2) * bountyBps / 10000, predicateQuote, "under the crossover the sliver does not pay for the predicate");
        assertGt((crossoverDebt * 2) * bountyBps / 10000, predicateQuote, "over it, it does");

        uint256 backstop = _measureBackstop(loanId, expiry);
        assertLt(backstop + predicateGas, dear, "F-A: the backstop must skip the whole predicate the paid path pays for");
    }

    uint256 internal constant GAS_PRICE_WEI = 20 gwei; // the plan's stated assumption; the crossover is a claim about it
    uint256 internal constant ETH_QUOTE = 3000e6; // and its stated ETH price, in this market's 6-decimal quote

    /* ============ E: the window derives from the LOAN's tenor, not the market floor ============ */

    /// @notice A long loan in a short-`minTenor` market gets a window derived from ITS OWN tenor.
    /// @notice Rev 4 read the market floor, which gave a one-year loan the two-minute window of a ten-minute market.
    /// @dev RED until `settleExpired` exists; both legs are asserted, so the revert leg is not vacuous.
    function test_E_TheBackstopWindow_ComesFromTheLoansTenor_NotTheMarketFloor() public {
        (bytes32 mid,) = _shortFloorMarket();
        uint256 loanId = _plainLoanOn(mid, TEN7);
        uint256 expiry = read.loan(loanId).expiry;

        uint64 floorWindow = MarketInit.autoRefinanceWindow(ace.idToMarketParams(mid).minTenor);
        uint64 loanWindow = MarketInit.autoRefinanceWindow(read.loan(loanId).tenor);
        assertLt(floorWindow, loanWindow, "fixture: the two windows must differ, or this test proves nothing");

        _warpTo(expiry + floorWindow);
        vm.prank(keeper);
        (bool atFloorWindow,) = address(ace).call(abi.encodeCall(IAceSettleExpired.settleExpired, (loanId)));
        assertFalse(atFloorWindow, "the market floor's window opened the backstop on a loan that never took that term");

        _warpTo(expiry + loanWindow);
        vm.prank(keeper);
        IAceSettleExpired(address(ace)).settleExpired(loanId);
        assertTrue(ace.isClosed(loanId), "the loan's own tenor must be what opens its backstop");
    }

    /* ============ I: the backstop is minimal -- it settles, and it sweeps nothing ============ */

    /// @notice `forceClose` piggybacks the revenue sweep; the backstop exists to be dependency-free and must not.
    /// @dev The control proves the sweep really was due, so a green here cannot come from an inert sweep.
    /// @dev RED until `settleExpired` exists.
    function test_I_SettleExpired_DoesNotSweep() public {
        uint256 loanId = _plainLadderLoan(mainMid);
        _warpTo(read.loan(loanId).expiry + _window(loanId));
        assertGt(read.protocolRevenue(mainMid), 0, "fixture: there must be revenue for a sweep to move");

        uint256 snap = vm.snapshotState();
        vm.prank(keeper);
        ace.forceClose(loanId);
        assertEq(usdc.balanceOf(AceFixtures.TREASURY) > 0, true, "control: the paid verb's piggyback sweep was due and ran");
        vm.revertToState(snap);
        _warpTo(read.loan(loanId).expiry + _window(loanId));

        vm.prank(keeper);
        IAceSettleExpired(address(ace)).settleExpired(loanId);
        assertTrue(ace.isClosed(loanId), "the backstop settled");
        assertEq(usdc.balanceOf(AceFixtures.TREASURY), 0, "the backstop must reach no ERC-20 transfer of its own");
    }

    /* ================================= fixture ================================= */

    /// @dev The settle branch measured with nothing burning: the honest cost the burn is starving.
    function _measureUnburnedSettle(uint256 loanId, uint256 expiry) internal returns (uint256 cost) {
        uint256 snap = vm.snapshotState();
        record.setMinPrice(0); // the same fold, routed to settle without spending a block
        uint256 g0 = gasleft();
        vm.prank(keeper);
        ace.forceClose(loanId);
        cost = g0 - gasleft();
        assertTrue(ace.isClosed(loanId), "control: the settle branch resolves the loan when nothing burns");
        vm.revertToState(snap);
        _warpTo(expiry + 1);
    }

    /// @dev One paid fold at a chosen predicate cost, measured under a snapshot so the loan survives it.
    function _measurePaidFold(uint256 loanId, uint256 expiry, CostlyRecord costly, uint256 rounds) internal returns (uint256 cost) {
        uint256 snap = vm.snapshotState();
        costly.setRounds(rounds);
        uint256 g0 = gasleft();
        vm.prank(keeper);
        ace.forceClose(loanId);
        cost = g0 - gasleft();
        vm.revertToState(snap);
        _warpTo(expiry + _window(loanId));
    }

    /// @dev The backstop's own cost, measured the same way; zero if the verb does not answer yet.
    function _measureBackstop(uint256 loanId, uint256 expiry) internal returns (uint256 cost) {
        uint256 snap = vm.snapshotState();
        uint256 g0 = gasleft();
        vm.prank(keeper);
        IAceSettleExpired(address(ace)).settleExpired(loanId);
        cost = g0 - gasleft();
        vm.revertToState(snap);
        _warpTo(expiry + _window(loanId));
    }

    /// @dev The loan's own backstop window, which is what F-E rules it must be.
    function _window(uint256 loanId) internal view returns (uint64) {
        return MarketInit.autoRefinanceWindow(read.loan(loanId).tenor);
    }

    /// @dev A market whose record answers truthfully but charges for it; the F-A fixture.
    function _costlyMarket() internal returns (bytes32 mid, CostlyRecord costly) {
        costly = new CostlyRecord(address(usdc), address(coll));
        MarketParams memory p = AceFixtures.marketParams(address(usdc), address(coll));
        p.record = address(costly);
        mid = ace.createMarket(p);
    }

    /// @dev A market whose FLOOR tenor is far under the term a loan in it may take; the F-E fixture.
    function _shortFloorMarket() internal returns (bytes32 mid, MarketParams memory p) {
        p = AceFixtures.marketParams(address(usdc), address(coll));
        p.record = address(record);
        p.minTenor = 4 hours;
        p.maxTenor = TEN7;
        mid = ace.createMarket(p);
    }

    /// @dev Rests what the `TICKS`-rung ladder held IN TOTAL, in the one balance a market now keeps.
    /// @dev IT SEEDED `TICKS` LOTS OF `PER_TICK` down the ladder so a draw funded many claims. A draw funds
    /// @dev one, and the deposit floor is `minDebt` ITSELF rather than `ceil(minDebt / maxClaimTicks)` --
    /// @dev which `PER_TICK` sits far under, so each per-rung leg would now be refused `BelowMinLot`.
    function _lendLadder(bytes32 m) internal {
        uint256 total = PER_TICK * TICKS;
        usdc.mint(alice, total);
        vm.startPrank(alice);
        usdc.approve(address(ace), total);
        ace.deposit(m, total);
        vm.stopPrank();
    }

    function _armedLadderLoan(bytes32 m) internal returns (uint256 loanId) {
        loanId = _plainLadderLoan(m);
        vm.prank(borrower);
        IAceAuto(address(ace)).setAutoRefinance(loanId, TEN7, 0, 0);
    }

    function _plainLadderLoan(bytes32 m) internal returns (uint256 loanId) {
        _lendLadder(m);
        coll.mint(borrower, COLL);
        vm.startPrank(borrower);
        coll.approve(address(pm), COLL);
        loanId = ace.open(m, COLL, PRINCIPAL, TEN7, borrower, OFF);
        vm.stopPrank();
    }

    /// @dev One tick, one loan: the cheap fixture for the tests that never need a fat settlement.
    /// @dev The lot is stamped with the loan's OWN tenor, or a market whose floor is shorter lends it nothing.
    function _plainLoanOn(bytes32 m, uint64 tenor) internal returns (uint256 loanId) {
        usdc.mint(alice, 20_000_000);
        vm.startPrank(alice);
        usdc.approve(address(ace), 20_000_000);
        ace.deposit(m, 20_000_000);
        vm.stopPrank();
        coll.mint(borrower, COLL);
        vm.startPrank(borrower);
        coll.approve(address(pm), COLL);
        loanId = ace.open(m, COLL, PRINCIPAL, tenor, borrower, OFF);
        vm.stopPrank();
    }
}

/// @title AceBackstopOrdering
/// @notice F-H, as a property rather than as an implementation note: the liveness effect lands BEFORE the hop.
/// @notice `_settle`'s one external call is `retireCustody`, and the backstop exists because external calls fail.
/// @notice So `closedAt` and `collateralUnits` must already be written when the custodian gets control.
/// @dev The probe custodian reads the hub back from inside that hop, which is where a hostile one would sit.
contract AceBackstopOrderingTest is WarpClock {
    Ace internal ace;
    AceLens internal lens;
    RetireProbeManager internal manager;
    MockERC20 internal usdc;
    MockERC20 internal coll;
    bytes32 internal mid;

    address internal alice = address(0xA11CE);
    address internal borrower = address(0xB0B);
    address internal keeper = address(0xCA11E5);

    uint256 internal T0; // par for this pair; assigned in setUp, since par is not a compile-time value
    uint256 internal constant LADDER = 20_000e6;
    uint256 internal constant COLL = 10_000e18;
    uint256 internal constant DRAW = 4_500e6;
    uint64 internal constant TEN7 = 7 days;

    /// @dev This suite's pair, so a tick reads as its distance from par rather than as a grid coordinate.
    /// @param offset Ticks above par.
    /// @return The absolute grid tick.
    function _price(int24 offset) internal view returns (uint256) {
        return AceFixtures.priceAt(address(usdc), address(coll), offset);
    }

    function setUp() public {
        _warpTo(1_000_000);
        usdc = new MockERC20("USD Coin", "USDC", 6);
        coll = new MockERC20("Collateral", "COLL", 18);
        T0 = _price(0);

        address predictedHub = vm.computeCreateAddress(address(this), vm.getNonce(address(this)) + 1);
        manager = new RetireProbeManager(predictedHub);
        ace = new Ace(AceFixtures.TREASURY, address(manager), AceFixtures.PUSH_GAS);

        MarketParams memory p = AceFixtures.marketParams(address(usdc), address(coll));
        p.record = address(0); // ordering is the subject, but this class settles to the coverage line rather than the claims' need
        mid = ace.createMarket(p);
        lens = new AceLens(address(ace));

        usdc.mint(alice, LADDER);
        vm.startPrank(alice);
        usdc.approve(address(ace), LADDER);
        ace.deposit(mid, LADDER);
        vm.stopPrank();
    }

    /// @notice The paid verb's ordering, as the control the backstop is required to mirror.
    function test_ForceClose_WritesClosedAtAndUnitsBeforeTheCustodyHop() public {
        uint256 loanId = _open();
        manager.arm(address(lens), mid, loanId);
        _warpTo(read(loanId) + 1);

        vm.prank(keeper);
        ace.forceClose(loanId);
        assertEq(manager.snaps(), 1, "the custody hop must actually have fired, or nothing was observed");
        assertTrue(manager.closedSeen(), "the paid verb reached its one external call before writing closedAt");
        assertEq(manager.unitsSeen(), 0, "and before zeroing the live lot");
    }

    /// @notice The same ordering on the backstop, where it matters most: it exists because external calls fail.
    /// @dev RED until `settleExpired` exists.
    function test_SettleExpired_WritesClosedAtAndUnitsBeforeTheCustodyHop() public {
        uint256 loanId = _open();
        manager.arm(address(lens), mid, loanId);
        _warpTo(read(loanId) + MarketInit.autoRefinanceWindow(TEN7));

        vm.prank(keeper);
        IAceSettleExpired(address(ace)).settleExpired(loanId);
        assertEq(manager.snaps(), 1, "the custody hop must actually have fired, or nothing was observed");
        assertTrue(manager.closedSeen(), "ORDER: the backstop reached its one external call before writing closedAt");
        assertEq(manager.unitsSeen(), 0, "and before zeroing the live lot");
    }

    /// @dev The loan's expiry, read through the lens this fixture already stands up.
    function read(uint256 loanId) internal view returns (uint256) {
        return lens.loan(loanId).expiry;
    }

    function _open() internal returns (uint256 loanId) {
        coll.mint(borrower, COLL);
        vm.startPrank(borrower);
        coll.approve(address(manager), COLL);
        loanId = ace.open(mid, COLL, DRAW, TEN7, borrower, OpenBounds(0, 0, 0));
        vm.stopPrank();
    }
}
