// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.36;

import {Test} from "forge-std/Test.sol";
import {FullMath} from "@uniswap/v4-core/src/libraries/FullMath.sol";
import {Ace} from "../../src/ace/hub/Ace.sol";
import {AceLens} from "../../src/ace/lens/AceLens.sol";
import {LoanMath} from "../../src/ace/hub/libraries/LoanMath.sol";
import {Borrower} from "../../src/ace/hub/Borrower.sol";
import {MarketParams, OpenBounds} from "../../src/ace/hub/Types.sol";
import {BufferBelowMin, PayoutBelowMin, TenorOutOfRange, ZeroCollateral} from "../../src/ace/hub/Borrower.sol";
import {InsufficientCash} from "../../src/ace/hub/Borrower.sol";
import {NoMarket} from "../../src/ace/hub/Ace.sol";
import {PositionManager} from "../../src/ace/positions/PositionManager.sol";
import {Constants} from "../../src/ace/hub/Constants.sol";
import {PriceFrame} from "../utils/PriceFrame.sol";
import {GUARD_TRIP} from "../utils/GuardTrip.sol";
import {IAceDeleverageCallback} from "../../src/interfaces/IAceDeleverageCallback.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {PocDeployConfig, ProtocolPolicy} from "../../src/config/Defaults.sol";
import {MockERC20} from "../mocks/MockERC20.sol";
import {MockPersistenceRecord} from "../mocks/MockPersistenceRecord.sol";
import {MockStakeVault} from "../mocks/MockStakeVault.sol";
import {AceFixtures} from "../utils/AceFixtures.sol";
import {AceReader} from "../utils/AceReader.sol";

interface IQuoteMintable {
    function mint(address to, uint256 amount) external;
}

/// @notice A deleverage keeper that quotes the hub from inside its routing callback, to prove a view cannot.
/// @dev The target is SET after construction: the market it quotes is the one it cranks, so the two cannot know each other at build.
/// @dev An empty placeholder market made the first version pass for the wrong reason -- `InsufficientCash` with or without the guard.
/// @dev The recorded SELECTOR is the assertion, not the bare fact of a revert; the quote's arguments are deliberately admissible.
/// @dev It pays the floor honestly so the crank COMPLETES: a reverted crank would unwind the mid-interaction state under test.
contract ReentrantQuoter is IAceDeleverageCallback {
    Ace public immutable ACE;
    address public immutable QUOTE;
    bytes32 public target;
    bool public quoteAnswered;
    bytes4 public quoteReason;

    constructor(Ace ace, address quote) {
        ACE = ace;
        QUOTE = quote;
    }

    function setTarget(bytes32 mid) external {
        target = mid;
    }

    function crank(uint256 loanId) external {
        ACE.deleverage(loanId, 0, "");
    }

    function onAceDeleverage(uint256, uint256 quoteOwed, bytes calldata) external {
        try ACE.previewOpen(target, 200_000e18, 100e6, ProtocolPolicy.MIN_TENOR, address(this), OpenBounds(0, 0, 0)) {
            quoteAnswered = true;
        } catch (bytes memory err) {
            quoteAnswered = false;
            if (err.length >= 4) {
                quoteReason = bytes4(err[0]) | (bytes4(err[1]) >> 8) | (bytes4(err[2]) >> 16) | (bytes4(err[3]) >> 24);
            }
        }
        IQuoteMintable(QUOTE).mint(address(this), quoteOwed);
        IERC20(QUOTE).approve(address(ACE), quoteOwed);
    }
}

/// @title AceQuoteOpen
/// @notice The HUB-LEVEL binding: `Ace.previewOpen` reports what a real `open` does.
/// @notice And refuses what a real `open` refuses, on the same state and in the same order.
/// @dev IT IS NOW THE WHOLE OF THAT BINDING. Its library-level half harnessed the walk's `preview` against
/// @dev its `consume`, and both went with the walk -- `Borrower._fund` CALLS the same `_previewFloor` the
/// @dev quote calls, so the two cannot diverge and a test of it would assert a function equals itself.
/// @dev This one pins that the quote passes the same `drawCap` and `tenor` a draw does.
/// @dev It also pins that the same fee, trigger and buffer gates apply, in the same order.
/// @dev Recovers eight legacy `quoteOpen`/`previewDrawFloor` tests that died with the per-market pair.
/// @dev NON-VACUITY RULE: expected values come from a balance delta, a hub-written slot, or a real revert.
/// @dev Asserting the lens against the lens is how two mutations survived a green suite earlier in this arc.
contract AceQuoteOpenTest is Test {
    Ace internal ace;
    AceLens internal lens;
    AceReader internal read;
    PositionManager internal positionManager;
    MockERC20 internal usdc;
    MockStakeVault internal vault;
    MockPersistenceRecord internal record;
    bytes32 internal id;

    address internal alice = address(0xA11CE);
    address internal bob = address(0xB0B);
    address internal carol = address(0xCA11);

    uint256 internal T2; // ticks above this pair's par; assigned in setUp, since par is not a compile-time value
    uint256 internal T3;
    uint256 internal T4;

    uint256 internal constant COLL = 200_000e18;
    uint256 internal constant PRINCIPAL = 4_500e6;
    uint64 internal constant TENOR = ProtocolPolicy.MIN_TENOR;
    uint64 internal constant SHORT = 7 days; // the grid market's minTenor rung, == the shipped one
    uint64 internal constant LONG = 30 days; // its maxTenor rung; 40 bps * 30d * 11000 < 10000 * 10000 * 7d clears the fee ceiling

    /// @dev This suite's pair, so a tick reads as its distance from par rather than as a grid coordinate.
    /// @param offset Ticks above par.
    /// @return The absolute grid tick.
    function _price(int24 offset) internal view returns (uint256) {
        return AceFixtures.priceAt(address(usdc), address(vault), offset);
    }

    function setUp() public {
        vm.warp(1_000_000);
        usdc = new MockERC20("USD Coin", "USDC", 6);
        vault = new MockStakeVault(42);
        (T2, T3, T4) = (_price(0), _price(480), _price(960));
        record = new MockPersistenceRecord(address(usdc), address(vault));

        AceFixtures.Deployment memory d = AceFixtures.deploy(_params());
        (ace, positionManager, read, id) = (d.ace, d.positionManager, d.read, d.id);
        lens = new AceLens(address(ace));

        _lend(id, 5_000e6);
        _lend(id, 5_000e6);
        _lend(id, 5_000e6);
    }

    // ---- fixture ----

    function _params() internal returns (MarketParams memory p) {
        p = AceFixtures.marketParams(address(usdc), address(vault));
        p.record = address(record);
    }

    /// @dev Its own record, so two variants of the baseline shape still get distinct ids.
    /// @dev It took a claim cap, which is gone; the fresh record is what makes the id distinct now.
    function _market() internal returns (bytes32) {
        MarketParams memory p = _params();
        p.record = address(new MockPersistenceRecord(address(usdc), address(vault)));
        return ace.createMarket(p);
    }

    /// @notice A market with a REAL tenor grid: two rungs, so `0` and `maxTenor` are different terms.
    /// @dev The shipped fixture is single-rung (`MIN_TENOR == MAX_TENOR`), which is what let a quote
    /// @dev that never resolved `tenor == 0` look identical to one that did.
    function _gridMarket() internal returns (bytes32) {
        MarketParams memory p = _params();
        p.minTenor = SHORT;
        p.maxTenor = LONG;
        return ace.createMarket(p);
    }

    /// @dev The TICK and the HORIZON are both gone: a market names one price, and its `maxTenor` is the whole
    /// @dev of its maturity consent, so a deposit carries neither a coordinate nor a term of its own.
    function _lend(bytes32 mid, uint256 amt) internal {
        usdc.mint(alice, amt);
        vm.startPrank(alice);
        usdc.approve(address(ace), amt);
        ace.deposit(mid, amt);
        vm.stopPrank();
    }

    function _fund(address who) internal {
        vault.mint(who, COLL);
        vm.prank(who);
        vault.approve(address(positionManager), COLL);
    }

    function _bounds(uint256 minPayout, uint256 minBufferWad, uint64 deadline) internal pure returns (OpenBounds memory) {
        return OpenBounds(minPayout, minBufferWad, deadline);
    }

    /// @dev The term is an ARGUMENT, not a baked-in constant, so a parity test cannot quote one term
    /// @dev and open another. That mismatch is exactly how the quote's missing `tenor == 0` sentinel
    /// @dev survived this file green: every site handed `TENOR` here and a literal `0` to `open`, and
    /// @dev the shipped grid is single-rung, so the two happened to name the same term.
    function _quote(bytes32 mid, uint256 principal, uint64 term) internal view returns (Borrower.Quote memory) {
        return ace.previewOpen(mid, COLL, principal, term, bob, _bounds(0, 0, 0));
    }

    // ============ quote == execution ============

    /// @notice The tenor-range guard bites at BOTH ends; the shipped grid is single-rung (`MIN_TENOR == MAX_TENOR`).
    /// @dev Off-grid terms are refused by name, never clamped: terms fix at origination, so a clamp would fix one the borrower never asked for.
    function test_Open_TenorOutOfRange_BothEnds() public {
        _fund(bob);
        uint64 min = ace.idToMarketParams(id).minTenor;
        uint64 max = ace.idToMarketParams(id).maxTenor;

        vm.prank(bob);
        vm.expectRevert(TenorOutOfRange.selector);
        ace.open(id, COLL, PRINCIPAL, min - 1, bob, OpenBounds(0, 0, 0));

        vm.prank(bob);
        vm.expectRevert(TenorOutOfRange.selector);
        ace.open(id, COLL, PRINCIPAL, max + 1, bob, OpenBounds(0, 0, 0));

        vm.prank(bob); // and the exact rung still opens
        assertGt(ace.open(id, COLL, PRINCIPAL, min, bob, OpenBounds(0, 0, 0)), 0, "the on-grid term is admitted");
    }

    /// @notice Every field the quote reports is what the loan actually gets, at the term ASKED FOR.
    /// @dev ONE `term` variable reaches both doors, so no run of this body can compare two terms.
    function _quoteMatchesOpen(uint64 term) internal {
        Borrower.Quote memory q = _quote(id, PRINCIPAL, term);

        _fund(bob);
        uint256 balBefore = usdc.balanceOf(bob);
        vm.prank(bob);
        uint256 loanId = ace.open(id, COLL, PRINCIPAL, term, bob, OpenBounds(0, 0, 0));

        assertEq(usdc.balanceOf(bob) - balBefore, q.payout, "quoted payout == the tokens that moved");
        assertEq(read.loan(loanId).lastFee, q.fee, "quoted fee == the fee the hub stored");
        assertEq(read.fundingFloor(id, loanId), q.postDrawFloor, "quoted floor == the hub's stored floor");
        assertEq(read.triggerPrice(loanId), q.triggerAtOpen, "quoted trigger == the loan's trigger");

        uint256 floor = read.fundingFloor(id, loanId);
        uint256 expBuf = floor <= q.triggerAtOpen ? 0 : ((floor - q.triggerAtOpen) * 1e18) / floor;
        assertEq(q.bufferWad, expBuf, "quoted buffer == the buffer the stored floor implies");
    }

    function test_QuoteOpen_MatchesActualOpen() public {
        _quoteMatchesOpen(TENOR);
    }

    /// @notice The same parity at the SENTINEL term, which is the argument the two doors disagreed on.
    /// @dev Without the quote's sentinel this reverts `TenorOutOfRange` before it can assert anything.
    function test_QuoteOpen_MatchesActualOpen_TenorZero() public {
        _quoteMatchesOpen(0);
    }

    /// @notice A draw spanning two ticks quotes the floor it lands on, not the top one.
    /// @dev RENAMED from `..._MultiTick`. A draw that used to consume T4 whole and reach into T3 quoted the
    /// @dev SECOND rung's price as its floor; there are no rungs to reach past, so a big draw quotes the same
    /// @dev number a small one does. The row survives because THE QUOTE MATCHING THE STORED FLOOR is the
    /// @dev subject, and it is worth pinning at a size large enough to have moved the answer before.
    function test_QuoteOpen_MatchesStoredFloor_OnALargeDraw() public {
        uint256 big = 7_000e6;
        Borrower.Quote memory q = _quote(id, big, TENOR);
        assertEq(q.postDrawFloor, ace.idToMarketParams(id).price, "the quote is the market's own bid, at any size");

        _fund(bob);
        vm.prank(bob);
        uint256 loanId = ace.open(id, COLL, big, TENOR, bob, OpenBounds(0, 0, 0));
        assertEq(read.fundingFloor(id, loanId), q.postDrawFloor, "quote == stored floor");
    }

    /// @notice A pre-existing loan's floor does not leak into a later quote: each draw takes its own.
    function test_QuoteOpen_ReportsItsOwnFloor_DespiteAPreExistingLowerClaim() public {
        _fund(bob);
        vm.prank(bob);
        uint256 first = ace.open(id, COLL, 11_000e6, TENOR, bob, OpenBounds(0, 0, 0)); // spans down to T2
        assertEq(read.fundingFloor(id, first), T2, "the first loan floors low");

        Borrower.Quote memory q = _quote(id, 1_000e6, TENOR);
        _fund(carol);
        vm.prank(carol);
        uint256 second = ace.open(id, COLL, 1_000e6, TENOR, carol, OpenBounds(0, 0, 0));

        assertEq(read.fundingFloor(id, second), q.postDrawFloor, "the quote reported the NEW loan's floor");
        assertEq(read.fundingFloor(id, first), T2, "and the first loan's floor is untouched");
    }

    // ============ the quote refuses what execution refuses ============

    /// @notice THE FINDING, at the hub. A draw the market's cash cannot cover is refused by BOTH.
    /// @notice The two doors must name the SAME refusal on the same state, which is what this row is for.
    /// @dev IT ASKED `CapacityExceeded` -- a draw wanting more legs than `maxClaimTicks` allowed. A draw
    /// @dev fills from one price now, so there are no legs to count and that refusal does not exist.
    /// @dev `InsufficientCash` is its successor and the parallel is exact: the market cannot fund the draw,
    /// @dev the preview says so, and the open says the same thing rather than reverting some other way.
    function test_QuoteOpen_RefusesWhenTheMarketCannotFundTheDraw() public {
        bytes32 mid = _market();
        _lend(mid, 5_000e6);

        vm.expectRevert(InsufficientCash.selector);
        ace.previewOpen(mid, COLL, 12_000e6, TENOR, bob, _bounds(0, 0, 0));

        _fund(bob);
        vm.prank(bob);
        vm.expectRevert(InsufficientCash.selector);
        ace.open(mid, COLL, 12_000e6, TENOR, bob, OpenBounds(0, 0, 0));
    }

    /// @notice The legacy bug this surface was built for: a zero-collateral position quoted a PERFECT
    /// @notice buffer, the strongest health signal the system emits, for a loan that cannot exist.
    /// @dev ONE `term` variable reaches both doors, so the two cannot be refusing different positions.
    function _refusesWhatOpenRefuses(uint64 term) internal {
        vm.expectRevert(ZeroCollateral.selector);
        ace.previewOpen(id, 0, PRINCIPAL, term, bob, _bounds(0, 0, 0));

        vm.prank(bob);
        vm.expectRevert(ZeroCollateral.selector);
        ace.open(id, 0, PRINCIPAL, term, bob, OpenBounds(0, 0, 0));
    }

    function test_QuoteOpen_RefusesTheSamePositionOpenRefuses() public {
        _refusesWhatOpenRefuses(TENOR);
    }

    /// @notice And at the sentinel term, where a refusal must still name the COLLATERAL, not the tenor.
    /// @dev `_preChecks` refuses collateral before tenor, so this pins the ORDER rather than the sentinel.
    function test_QuoteOpen_RefusesTheSamePositionOpenRefuses_TenorZero() public {
        _refusesWhatOpenRefuses(0);
    }

    function test_QuoteOpen_RefusesUnknownMarket() public {
        vm.expectRevert(NoMarket.selector);
        ace.previewOpen(bytes32(uint256(1)), COLL, PRINCIPAL, TENOR, bob, _bounds(0, 0, 0));
    }

    /// @notice ONE argument through BOTH doors: `tenor == 0` reads as `minTenor` at the quote as at the open.
    /// @dev The comparison term is read off the HUB, not the file's `TENOR` constant, so the assertion
    /// @dev rests on the market's own `minTenor` rather than on the two happening to agree.
    function test_QuoteOpen_TenorZeroSentinel_QuotesWhatItOpens() public {
        Borrower.Quote memory q = ace.previewOpen(id, COLL, PRINCIPAL, 0, bob, _bounds(0, 0, 0));
        assertEq(q.fee, _quote(id, PRINCIPAL, ace.idToMarketParams(id).minTenor).fee, "0 prices the term minTenor prices");

        (bool ok,, Borrower.Quote memory viaLens) = lens.tryQuoteOpen(id, COLL, PRINCIPAL, 0, bob, _bounds(0, 0, 0));
        assertTrue(ok, "the lens' admissibility oracle admits what open admits");
        assertEq(viaLens.payout, q.payout, "and carries the hub's own number");

        _fund(bob);
        uint256 balBefore = usdc.balanceOf(bob);
        vm.prank(bob);
        uint256 loanId = ace.open(id, COLL, PRINCIPAL, 0, bob, OpenBounds(0, 0, 0));

        assertEq(usdc.balanceOf(bob) - balBefore, q.payout, "quoted payout == the tokens that moved");
        assertEq(read.loan(loanId).tenor, ace.idToMarketParams(id).minTenor, "and the loan took minTenor");
    }

    /// @notice On a TWO-RUNG grid the sentinel has teeth: `0` must price the SHORT rung, not the long.
    /// @notice The single-rung fixture cannot tell the two apart, which is why it hid the defect.
    /// @dev The origination fee is linear in tenor, so the rungs are separated by a real number here.
    function test_QuoteOpen_TenorZero_PricesTheShortRung_OnAMultiRungGrid() public {
        bytes32 mid = _gridMarket();
        _lend(mid, 5_000e6); // consent to the long rung, so all three quotes are fundable
        _lend(mid, 5_000e6);

        Borrower.Quote memory atZero = ace.previewOpen(mid, COLL, PRINCIPAL, 0, bob, _bounds(0, 0, 0));
        Borrower.Quote memory atShort = ace.previewOpen(mid, COLL, PRINCIPAL, SHORT, bob, _bounds(0, 0, 0));
        Borrower.Quote memory atLong = ace.previewOpen(mid, COLL, PRINCIPAL, LONG, bob, _bounds(0, 0, 0));
        assertEq(atZero.fee, atShort.fee, "0 quotes the short rung");
        assertGt(atLong.fee, atShort.fee, "fixture: the two rungs really do price differently");

        _fund(bob);
        vm.prank(bob);
        uint256 loanId = ace.open(mid, COLL, PRINCIPAL, 0, bob, OpenBounds(0, 0, 0));
        assertEq(read.loan(loanId).tenor, SHORT, "and the open took the rung the quote priced");
        assertEq(read.loan(loanId).lastFee, atZero.fee, "at the fee the quote named");
    }

    /// @notice A payout bound one unit tighter than achievable is refused by BOTH the quote and the open.
    /// @dev The refusal costs the borrower nothing: no collateral is pulled and no reserve moves.
    function test_MinPayout_RefusedByBoth_AndNothingIsPulledOnTheRevert() public {
        uint256 exact = _quote(id, PRINCIPAL, TENOR).payout;

        vm.expectRevert(PayoutBelowMin.selector);
        ace.previewOpen(id, COLL, PRINCIPAL, TENOR, bob, _bounds(exact + 1, 0, 0));

        _fund(bob);
        uint256 collBefore = vault.balanceOf(bob);
        vm.prank(bob);
        vm.expectRevert(PayoutBelowMin.selector);
        ace.open(id, COLL, PRINCIPAL, TENOR, bob, _bounds(exact + 1, 0, 0));
        assertEq(vault.balanceOf(bob), collBefore, "a refused open pulls no collateral");
        assertEq(positionManager.collateralOf(1), 0, "and escrows nothing under a loan that was never made");
    }

    /// @notice Monotone: if a tighter payout bound admits, a looser one must too -- on both paths.
    function testFuzz_MinPayout_Monotone(uint256 bound_) public {
        uint256 exact = _quote(id, PRINCIPAL, TENOR).payout;
        uint256 tight = bound(bound_, 1, exact);

        ace.previewOpen(id, COLL, PRINCIPAL, TENOR, bob, _bounds(tight, 0, 0)); // admits at or under exact
        _fund(bob);
        vm.prank(bob);
        assertGt(ace.open(id, COLL, PRINCIPAL, TENOR, bob, _bounds(tight, 0, 0)), 0, "execution admits it too");
    }

    // ============ the min-buffer bound ============

    /// @notice The quote reports the loan's own funding floor, and prices the buffer against it.
    /// @dev The floor the quote shows is the floor the hub stores: one number, no scaling in between.
    function test_QuoteOpen_ReportsTheFundingFloorAndBuffer() public {
        bytes32 mid = _market();
        _lend(mid, 5_000e6);

        Borrower.Quote memory q = ace.previewOpen(mid, COLL, 1_000e6, TENOR, bob, _bounds(0, 0, 0));
        assertEq(q.postDrawFloor, T2, "the quote reports the market own raw price");

        _fund(bob);
        vm.prank(bob);
        uint256 loanId = ace.open(mid, COLL, 1_000e6, TENOR, bob, OpenBounds(0, 0, 0));
        assertEq(read.fundingFloor(mid, loanId), q.postDrawFloor, "and the hub stores exactly that");
        uint256 buf = ((q.postDrawFloor - q.triggerAtOpen) * 1e18) / q.postDrawFloor;
        assertEq(q.bufferWad, buf, "the buffer is priced against the floor the gate uses");
    }

    /// @notice A bound above the loan's actual buffer is refused by the quote AND by the open.
    /// @dev Both legs matter: a quote that admitted what `open` refuses would be worse than no quote.
    function test_MinBuffer_UsesTheFundingFloor() public {
        bytes32 mid = _market();
        _lend(mid, 5_000e6);

        Borrower.Quote memory q = ace.previewOpen(mid, COLL, 1_000e6, TENOR, bob, _bounds(0, 0, 0));
        assertGt(q.bufferWad, 0, "fixture: the open really does carry a buffer");
        uint256 tooHigh = q.bufferWad + 1;

        vm.expectRevert(BufferBelowMin.selector);
        ace.previewOpen(mid, COLL, 1_000e6, TENOR, bob, _bounds(0, tooHigh, 0));

        _fund(bob);
        vm.prank(bob);
        vm.expectRevert(BufferBelowMin.selector);
        ace.open(mid, COLL, 1_000e6, TENOR, bob, _bounds(0, tooHigh, 0));
    }

    // ============ the properties the `view` keyword does not give ============

    /// @notice PURITY UNDER A NON-STATIC CALL: `view` is a COMPILER guarantee, not an EVM one, across the DELEGATECALL into `Borrower`.
    /// @dev In an ordinary transaction the EVM enforces nothing, so the only way to know the quote writes no state is to call it that way.
    /// @dev This is the one test that catches an inline-assembly SSTORE on the quote path; solc's view-chain check cannot see through assembly.
    function test_PreviewOpen_IsPure_EvenAsATransaction() public {
        /// @dev The LENT leg moved to the lender's pool with the other two aggregates, so it is read from there
        /// @dev rather than off `MarketState`. It is still read: a quote that lent would move exactly this word.
        uint256 cashBefore = read.marketState(id).cash;
        (, uint256 lentBefore,) = read.lenderPools(alice, address(usdc));
        uint256 loansBefore = read.loanCount();
        uint256 restingBefore = read.restingOf(id);

        (bool ok,) = address(ace).call(abi.encodeWithSelector(Ace.previewOpen.selector, id, COLL, PRINCIPAL, TENOR, bob, _bounds(0, 0, 0)));
        assertTrue(ok, "the quote answers in a normal transaction too");

        assertEq(read.marketState(id).cash, cashBefore, "the market's cash is unmoved");
        (, uint256 lentAfter,) = read.lenderPools(alice, address(usdc));
        assertEq(lentAfter, lentBefore, "and so is the lender's lent principal");
        assertEq(read.loanCount(), loansBefore, "no loan id was allocated");
        assertEq(read.restingOf(id), restingBefore, "the resting balance is untouched");
        assertEq(read.fundingFloor(id, loansBefore + 1), 0, "and no floor was written for a phantom loan");
    }

    /// @notice READ-ONLY REENTRANCY: a quote taken mid-interaction reads half-updated aggregates, and `nonReentrant` does not cover a view.
    /// @dev It must refuse rather than answer confidently wrong.
    function test_PreviewOpen_RefusesDuringAGuardedInteraction() public {
        ReentrantQuoter quoter = new ReentrantQuoter(ace, address(usdc));
        MarketParams memory q = _params();
        q.deleverageFloorEpsBps = ProtocolPolicy.DELEVERAGE_FLOOR_EPS_BPS;
        q.deleverageBandBps = 3000; // the one crank that hands control to the caller mid-body
        q.deleverageTargetBps = 4000;
        q.deleverageStopBps = 1;
        bytes32 hostile = ace.createMarket(q);
        quoter.setTarget(hostile); // quote a market that HAS liquidity, so the args are admissible
        _lend(hostile, 5_000e6);

        _fund(bob);
        vm.prank(bob);
        uint256 loanId = ace.open(hostile, COLL, 1_000e6, 0, bob, OpenBounds(0, 0, 0));

        // control: outside any interaction the same quote answers, so the refusal below is the guard, not the arguments
        ace.previewOpen(hostile, 200_000e18, 100e6, TENOR, bob, _bounds(0, 0, 0));

        uint256 trig = read.triggerPrice(loanId);
        record.setBelowBand(FullMath.mulDivRoundingUp(trig, 1e18, 1e18 - 3000 * 1e14));
        record.setMinPrice(trig + trig / 20);
        quoter.crank(loanId); // nonReentrant: the keeper quotes from inside the guarded body

        assertFalse(quoter.quoteAnswered(), "a quote taken mid-interaction must refuse, not answer");
        assertEq(quoter.quoteReason(), GUARD_TRIP, "and refuse AS a reentrancy, not incidentally on some other gate");
    }

    // ============ the lens ============

    /// @notice The lens reports exactly what the hub reports; it adds no arithmetic of its own.
    function test_Lens_QuoteOpen_MatchesTheHub() public view {
        Borrower.Quote memory q = _quote(id, PRINCIPAL, TENOR);
        (uint256 fee, uint256 payout, uint256 floor, uint256 trig, uint256 buf, uint256 protoFee) = lens.quoteOpen(id, COLL, PRINCIPAL, TENOR, bob);
        assertEq(fee, q.fee, "fee");
        assertEq(payout, q.payout, "payout");
        assertEq(floor, q.postDrawFloor, "floor");
        assertEq(trig, q.triggerAtOpen, "trigger");
        assertEq(buf, q.bufferWad, "buffer");
        assertEq(protoFee, q.protocolFee, "protocol fee");
    }

    /// @notice The non-reverting form carries the refusal's selector instead of taking a batched read down with it.
    /// @dev It still reports the SAME refusal the reverting form gives.
    function test_Lens_TryQuoteOpen_ReportsTheRefusalInsteadOfThrowing() public view {
        (bool ok, bytes4 reason,) = lens.tryQuoteOpen(id, 0, PRINCIPAL, TENOR, bob, _bounds(0, 0, 0));
        assertFalse(ok, "a zero-collateral quote is refused");
        assertEq(reason, ZeroCollateral.selector, "and the reason is the selector open would give");

        (bool ok2,, Borrower.Quote memory good) = lens.tryQuoteOpen(id, COLL, PRINCIPAL, TENOR, bob, _bounds(0, 0, 0));
        assertTrue(ok2, "an admissible quote answers");
        assertGt(good.payout, 0, "with a real payout");
    }
}
