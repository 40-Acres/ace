// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.36;

import {FullMath} from "@uniswap/v4-core/src/libraries/FullMath.sol";
import {WarpClock} from "../utils/WarpClock.sol";
import {Ace} from "../../src/ace/hub/Ace.sol";
import {BelowMinLot} from "../../src/ace/hub/Lender.sol";
import {LoanMath} from "../../src/ace/hub/libraries/LoanMath.sol";
import {MarketParams, OpenBounds} from "../../src/ace/hub/Types.sol";
import {PositionManager} from "../../src/ace/positions/PositionManager.sol";
import {PocDeployConfig, ProtocolPolicy} from "../../src/config/Defaults.sol";
import {MockERC20} from "../mocks/MockERC20.sol";
import {AceFixtures} from "../utils/AceFixtures.sol";
import {AceReader} from "../utils/AceReader.sol";
import {PriceFrame} from "../utils/PriceFrame.sol";

/// @title AceWideDecimalGap
/// @notice The widest decimal gap the absolute bound leaves: 18-decimal collateral against a 0-decimal quote.
/// @notice Genesis admitting a layout proves nothing about the arithmetic downstream, so this drives it end to end.
/// @notice Everything here is stated in the layout's OWN coordinates: par comes from `PriceFrame`, never from a literal.
/// @dev THREE consequences of the gap are pinned: the ticket, the lot floor, and the ask quantum.
/// @dev The ticket and the quantum MOVE with the gap; the lot floor does not, and that asymmetry is the point.
contract AceWideDecimalGapTest is WarpClock {
    Ace internal ace;
    PositionManager internal positionManager;
    AceReader internal read;
    MockERC20 internal quote; // 0 decimals in the gap-18 rows: one atom IS one whole quote token
    MockERC20 internal coll; // 18 decimals throughout, so the gap is the quote's to move
    bytes32 internal id;
    uint256 internal par; // this pair's par PRICE, in the hub's frame; it was a grid rung

    address internal alice = address(0xA11CE);
    address internal borrower = address(0xB0B);
    address internal buyer = address(0xB0FF);
    address internal keeper = address(0xCAFE);

    uint256 internal constant DEPOSIT = 6000; // quote atoms, which at a 0-decimal quote are whole tokens
    uint256 internal constant PRINCIPAL = 5000; // likewise: five thousand WHOLE quote tokens of debt
    uint256 internal constant TICKET = 2; // the smallest `minDebt` the genesis fee rail admits at a 0-decimal quote

    function setUp() public {
        _warpTo(1_000_000);
        (ace, positionManager) = AceFixtures.newAceWithEscrow(AceFixtures.TREASURY);
        read = new AceReader(address(ace));
    }

    // ---- fixtures ----

    /// @dev Params for one decimal layout, record-less so no draw cap and no ask floor confound the gap.
    /// @dev That choice is load-bearing at settlement too: this class forfeits the coverage line rather than the claims' need.
    /// @dev SPLIT from creation: an armed `vm.expectRevert` must not be consumed by a token deploy.
    /// @param q The quote token.
    /// @param c The collateral token.
    /// @param minDebt The market's borrower-side quantum.
    /// @return p The params, ready to hand `createMarket`.
    function _params(MockERC20 q, MockERC20 c, uint256 minDebt) internal view returns (MarketParams memory p) {
        p = AceFixtures.marketParams(address(q), address(c));
        p.record = address(0);
        p.settleBountyBps = 0; // no in-kind sliver, so the coverage line reaches the class pot undiverted
        p.minDebt = minDebt;
    }

    /// @dev The gap-18 market itself: an 18-decimal collateral against a 0-decimal quote, at the smallest ticket.
    function _deployGap18() internal {
        quote = new MockERC20("Quote", "Q", 0);
        coll = new MockERC20("Collateral", "COLL", 18);
        id = ace.createMarket(_params(quote, coll, TICKET));
        par = AceFixtures.priceAt(address(quote), address(coll), 0);
    }

    /// @dev The units the hub's own coverage line demands for `debt` at par, re-spelled from this market's params.
    function _coverAt(uint256 debt) internal view returns (uint256) {
        MarketParams memory p = ace.idToMarketParams(id);
        uint256 scale = read.marketState(id).unitScale;
        return FullMath.mulDivRoundingUp(p.minCoverageWad * debt, scale, par * 1e18) + 1;
    }

    /// @dev Lend at par, then draw against collateral sized fifty percent over the line the hub will demand.
    function _openLoan() internal returns (uint256 loanId) {
        quote.mint(alice, DEPOSIT);
        vm.startPrank(alice);
        quote.approve(address(ace), DEPOSIT);
        ace.deposit(id, DEPOSIT);
        vm.stopPrank();

        uint256 units = _coverAt(PRINCIPAL) * 3 / 2;
        coll.mint(borrower, units);
        vm.startPrank(borrower);
        coll.approve(address(positionManager), units);
        loanId = ace.open(id, units, PRINCIPAL, 0, borrower, OpenBounds(0, 0, 0));
        vm.stopPrank();
    }

    /// @dev Settle by expiry and warp to the moment the settled pot's ask opens.
    function _settleAndOpenTheAsk(uint256 loanId) internal {
        _warpBy(ProtocolPolicy.MIN_TENOR + 1);
        vm.prank(keeper);
        ace.forceClose(loanId);
        _warpTo(read.inventoryAskOpensAt(loanId));
    }

    /// @dev The quote the hub's books say it holds: cash, revenue, and what it owes claimants.
    function _booked() internal view returns (uint256) {
        return read.poolResting(id) + read.protocolRevenue(id) + read.poolOwed(id) + read.quoteOwedTotal(id);
    }

    // ============ 1. the ticket: the sharpest practical consequence of a 0-decimal quote ============

    /// @notice At a 0-decimal quote the genesis fee rail puts the smallest ticket at TWO WHOLE quote tokens.
    /// @notice One is refused because its own origination fee ceils to the whole token, leaving nothing to lend.
    /// @dev `min debt under fee` sits ABOVE the decimals bound in `MarketInit`, so it is what names the refusal.
    function test_Ticket_GapEighteenAdmitsTwoWholeQuoteTokensAndRefusesOne() public {
        MockERC20 q = new MockERC20("Quote", "Q", 0);
        MockERC20 c = new MockERC20("Collateral", "COLL", 18);
        uint64 t = ProtocolPolicy.MIN_TENOR;
        assertEq(LoanMath.originationFee(1, t, PocDeployConfig.BASE_BPS, t), 1, "premise: a one-token ticket is consumed whole by its own fee");
        assertEq(LoanMath.originationFee(2, t, PocDeployConfig.BASE_BPS, t), 1, "premise: two leaves one over, so two is the first workable ticket");

        MarketParams memory one = _params(q, c, 1);
        vm.expectRevert("min debt under fee");
        ace.createMarket(one);

        MarketParams memory two = _params(q, c, TICKET);
        assertTrue(ace.createMarket(two) != bytes32(0), "two whole quote tokens is a workable ticket at the widest gap");
    }

    // ============ 2. the lot floor, which does NOT move with the gap ============

    /// @notice `minDebt` is pure quote atoms with no price term, so it floors a deposit identically at any gap.
    /// @notice Asserted at the DEPOSIT DOOR in both layouts, so it compares behaviour rather than a formula to itself.
    /// @dev The contrast with the ask quantum below is the point: only one of the two is gap-sensitive.
    /// @dev THE FLOOR USED TO BE DERIVED as `ceil(minDebt / maxClaimTicks)`; it is `minDebt` itself now, and the
    /// @dev gap-insensitivity this row pins is what survived -- the derivation never had a price term either.
    function test_MinLot_IsTheSameQuoteAtomsAtGapEighteenAndGapSixteen() public {
        _probeMinLotAt(0);
        _probeMinLotAt(2);
    }

    /// @dev Deposits one atom under the floor, then exactly on it, in a market priced at this layout's own par.
    /// @param qd The quote's decimals; the collateral is 18 in both, so this alone sets the gap.
    function _probeMinLotAt(uint8 qd) private {
        MockERC20 q = new MockERC20("Quote", "Q", qd);
        MockERC20 c = new MockERC20("Collateral", "COLL", 18);
        bytes32 mid = ace.createMarket(_params(q, c, 64));

        q.mint(alice, 66);
        vm.startPrank(alice);
        q.approve(address(ace), 66);
        vm.expectRevert(BelowMinLot.selector);
        ace.deposit(mid, 63);
        ace.deposit(mid, 64);
        vm.stopPrank();
        assertEq(ace.restingOf(mid), 64, "the floor itself is admitted, in the same quote atoms at either gap");
    }

    // ============ 3. the full cycle at the widest gap ============

    /// @notice Deposit, draw and settle on an 18-decimal collateral against a 0-decimal quote.
    /// @notice The draw funds from one tick at par, the borrower is paid, and settlement covers every claim.
    /// @dev Genesis admitting the layout is one fact; that the ladder, the fee chain and settlement all compute is another.
    function test_Lifecycle_GapEighteen_DepositDrawSettle() public {
        _deployGap18();
        assertEq(read.marketState(id).unitScale, 1 << 96, "fixture: the constant frame, the same as every other market");
        assertEq(par, PriceFrame.priceAtStep(PriceFrame.parStep(0, 18)), "fixture: the pair sits at its own par price");
        assertGt(par, 0, "fixture: gap-18 par is a live price, not one the frame floors to zero");

        uint256 loanId = _openLoan();
        uint256 fee = LoanMath.originationFee(PRINCIPAL, ProtocolPolicy.MIN_TENOR, PocDeployConfig.BASE_BPS, ProtocolPolicy.MIN_TENOR);
        assertEq(read.loan(loanId).debt, PRINCIPAL, "the draw booked five thousand whole quote tokens of debt");
        assertEq(quote.balanceOf(borrower), PRINCIPAL - fee, "and paid the borrower the draw less its origination fee");
        assertGt(read.claimOf(id, loanId), 0, "funded from the market's resting cash");
        assertEq(read.fundingFloor(id, loanId), par, "the funding floor is the market's price, set once at the draw");
        assertGt(read.triggerPrice(loanId), 0, "and the trigger computes at the widest gap");

        _settleAndOpenTheAsk(loanId);
        (uint256 shortUnits, uint256 shortQuote) = read.shortfallOf(loanId);
        assertTrue(read.loan(loanId).closedAt != 0, "title transferred and the loan closed");
        assertEq(shortUnits, 0, "settlement covered every claim in units");
        assertEq(shortQuote, 0, "and left nothing short at book either");
        assertGt(read.invPotOf(id, loanId), 0, "and pooled the converted collateral into the class pot");
    }

    // ============ 4. the ask quantum, which DOES move with the gap ============

    /// @notice One quote atom buys `10 ** (cd - qd)` collateral atoms at par, so the gap sets the ask's quantum.
    /// @notice At gap 18 that is ONE WHOLE collateral token; at gap 16 it is a hundredth of one.
    /// @dev Derived from `priceAt` at each layout's own par rung, never from a literal price the frame could move.
    function test_AskQuantum_TracksTheDecimalGap() public pure {
        uint256 scale = 1 << 96;
        uint256 q18 = scale / PriceFrame.priceAtStep(PriceFrame.parStep(0, 18));
        uint256 q16 = scale / PriceFrame.priceAtStep(PriceFrame.parStep(2, 18));

        assertApproxEqRel(q18, 1e18, 0.01e18, "gap 18: one quote atom buys a whole 18-decimal collateral token");
        assertApproxEqRel(q16, 1e16, 0.01e18, "gap 16: one quote atom buys a hundredth of one");
        /// @dev A TOLERANCE, matching the two rows above it. Par is reached through `1.0001 ** t` now, so each
        /// @dev quantum carries the tick law's own rounding and the integer quotient floors to 99 rather than 100.
        assertApproxEqRel(q18, q16 * 100, 0.01e18, "two decimals of gap move the quantum by two decades");
    }

    /// @notice A WHOLE-POT buy leaves NO sub-quantum residue: the last atoms sell with the pot, at its ceiled charge.
    /// @notice At gap 18 a floor-only leg would strand up to a whole collateral token that no budget could buy.
    /// @dev The budget is the pot's floored value plus one atom, which covers the ceiled whole-pot charge at no fill fee.
    function test_AskQuantum_GapEighteen_AWholeBuyLeavesNoSubQuantumResidue() public {
        _deployGap18();
        uint256 loanId = _openLoan();
        _settleAndOpenTheAsk(loanId);

        uint256 price = par;
        uint256 scale = read.marketState(id).unitScale;
        uint256 pot = read.invPotOf(id, loanId);
        assertGt(pot, scale / price, "fixture: the settled pot starts above one quantum, so the drain below has work to do");
        uint256 floorLeft = pot - FullMath.mulDiv(FullMath.mulDiv(pot, price, scale), scale, price);
        emit log_named_uint("the ask quantum in collateral atoms", scale / price);
        emit log_named_uint("what a floor-only leg would have stranded", floorLeft);
        assertGt(floorLeft, 0, "PREMISE: a floor-only leg would strand sub-quantum inventory here");

        uint256 budget = FullMath.mulDiv(pot, price, scale) + 1;
        (uint256 firstUnits, uint256 firstFilled) = _buy(loanId, budget);
        assertEq(firstUnits, pot, "the whole pot was delivered");
        assertEq(firstFilled, FullMath.mulDivRoundingUp(pot, price, scale), "at its ceiled value, within the budget");
        assertEq(read.invPotOf(id, loanId), 0, "so no residue stayed in the pot");

        uint256 bookedBefore = _booked();
        uint256 hubBefore = quote.balanceOf(address(ace));
        (uint256 unitsOut, uint256 filled) = _buy(loanId, budget);

        assertEq(unitsOut, 0, "a buy on the emptied pot delivers nothing");
        assertEq(filled, 0, "and is charged nothing");
        assertEq(quote.balanceOf(address(ace)), hubBefore, "the hub pulled no quote");
        assertEq(_booked(), bookedBefore, "so the books did not grow");
    }

    /// @notice Liveness, and the budget side of the same quantum: TWO whole quote tokens is the smallest ask that fills.
    /// @notice One buys nothing, because the budget floors to whole units first and their book value then floors to zero.
    /// @dev Without this row the sub-quantum result above could be a market that never fills at all.
    /// @dev The one-atom call is the free no-op path, not a loss: it delivers nothing and is charged nothing.
    function test_AskQuantum_GapEighteen_TwoWholeQuoteTokensIsTheSmallestFill() public {
        _deployGap18();
        uint256 loanId = _openLoan();
        _settleAndOpenTheAsk(loanId);

        uint256 price = par;
        uint256 scale = read.marketState(id).unitScale;
        uint256 hubBefore = quote.balanceOf(address(ace));
        (uint256 thinUnits, uint256 thinFilled) = _buy(loanId, 1);

        assertEq(thinUnits, 0, "one quote atom buys nothing at gap 18: the double floor takes it to zero");
        assertEq(thinFilled, 0, "and is charged nothing, so the thin budget is a free no-op rather than a loss");
        assertEq(quote.balanceOf(address(ace)), hubBefore, "the hub pulled no quote for it");

        (uint256 unitsOut, uint256 filled) = _buy(loanId, 2);
        assertEq(filled, 1, "two atoms of budget clear one atom of book, which is the smallest fill the gap admits");
        assertEq(unitsOut, scale / price, "and it delivered exactly the quantum: about one whole collateral token");
        assertEq(coll.balanceOf(buyer), unitsOut, "the buyer holds exactly what the hub reported");
    }

    /// @dev A funded buy from `buyer`, minting and approving the budget first.
    /// @param loanId The settled loan whose pots are on the ask.
    /// @param budget The quote atoms to spend.
    /// @return unitsOut Collateral atoms delivered.
    /// @return filled Quote atoms charged.
    function _buy(uint256 loanId, uint256 budget) private returns (uint256 unitsOut, uint256 filled) {
        quote.mint(buyer, budget);
        vm.startPrank(buyer);
        quote.approve(address(ace), budget);
        (unitsOut, filled) = ace.buyInventory(loanId, budget, 0, buyer);
        vm.stopPrank();
    }
}
