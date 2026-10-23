// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.36;

import {Test, Vm, console2} from "forge-std/Test.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {FullMath} from "@uniswap/v4-core/src/libraries/FullMath.sol";
import {Ace, NotAuthorized} from "../../src/ace/hub/Ace.sol";
import {Borrower, TriggerAboveFloor} from "../../src/ace/hub/Borrower.sol";
import {PriceFrame} from "../utils/PriceFrame.sol";
import {LoanMath} from "../../src/ace/hub/libraries/LoanMath.sol";
import {MarketParams, MarketState, OpenBounds} from "../../src/ace/hub/Types.sol";
import {PositionManager} from "../../src/ace/positions/PositionManager.sol";
import {PositionTitleNFT} from "../../src/ace/positions/PositionTitleNFT.sol";
import {MockERC20} from "../mocks/MockERC20.sol";
import {MockPersistenceRecord} from "../mocks/MockPersistenceRecord.sol";
import {AceFixtures} from "../utils/AceFixtures.sol";
import {AceReader} from "../utils/AceReader.sol";

/// @notice A flat-rate venue stand-in, there only so a single-market loop has somewhere to turn quote back into collateral.
/// @dev It prices the pair at par across the 18/6 decimal gap, which is what this fixture's tick 0 says too.
/// @dev Nothing about ACE is modelled here: it stands for the swap leg a hub batch cannot reach.
contract ParSwap {
    IERC20 internal immutable COLL;
    IERC20 internal immutable QUOTE;

    constructor(IERC20 coll, IERC20 quote) {
        COLL = coll;
        QUOTE = quote;
    }

    /// @notice Trade one side for the other at par; the caller must have approved this contract.
    /// @param tokenIn Which side is being sold.
    /// @param amountIn How much of it.
    /// @return out What came back.
    function swap(address tokenIn, uint256 amountIn) external returns (uint256 out) {
        if (tokenIn == address(QUOTE)) {
            out = amountIn * 1e12;
            QUOTE.transferFrom(msg.sender, address(this), amountIn);
            COLL.transfer(msg.sender, out);
        } else {
            out = amountIn / 1e12;
            COLL.transferFrom(msg.sender, address(this), amountIn);
            QUOTE.transfer(msg.sender, out);
        }
    }
}

/// @notice The periphery a SINGLE-market loop needs, because a swap leg is not a hub selector.
/// @notice It borrows in the user's name on the hub's own credit-delegation grant, so the user keeps title.
/// @dev The three roles in `Borrower.OpenArgs` are what make this work: payer and payee are the router,
/// @dev borrower is the user. The router never holds a position, only the tokens in flight.
contract LoopRouter {
    Ace internal immutable ACE;
    IERC20 internal immutable COLL;
    IERC20 internal immutable QUOTE;
    ParSwap internal immutable VENUE;

    constructor(Ace ace, IERC20 coll, IERC20 quote, ParSwap venue) {
        (ACE, COLL, QUOTE, VENUE) = (ace, coll, quote, venue);
        quote.approve(address(venue), type(uint256).max);
    }

    /// @notice Post `seed`, draw, swap the draw back into collateral, and repeat; one transaction throughout.
    /// @param mid The market every hop draws from.
    /// @param seed The collateral the caller posts to start.
    /// @param principals The per-hop draw, quoted off-chain exactly as a front end would quote it.
    /// @param onBehalf Who holds title and the debt; must have granted this router credit.
    /// @return ids The loan each hop opened.
    function loop(bytes32 mid, uint256 seed, uint256[] calldata principals, address onBehalf) external returns (uint256[] memory ids) {
        COLL.transferFrom(msg.sender, address(this), seed);
        ids = new uint256[](principals.length);
        uint256 held = seed;
        for (uint256 i; i < principals.length; i++) {
            COLL.approve(ACE.POSITION_MANAGER(), held);
            ids[i] = ACE.open(mid, held, principals[i], 0, onBehalf, OpenBounds(0, 0, 0));
            if (i + 1 < principals.length) held = VENUE.swap(address(QUOTE), QUOTE.balanceOf(address(this)));
        }
        QUOTE.transfer(msg.sender, QUOTE.balanceOf(address(this))); // the last hop's payout is the user's
    }
}

/// @title AceLoopingShowcase
/// @notice Chaining hub verbs inside ONE `Ace.multicall`, and the two verdicts that come out of it.
/// @notice IT WORKS MECHANICALLY: post TOK1, borrow USDC, post that USDC, borrow WETH, and on, in one batch.
/// @notice No hop needs a swap, because market N's quote token IS market N+1's collateral token.
/// @notice That composes only on a singleton: a market is a storage write, so every hop is one more entry.
/// @notice IT IS NOT LEVERAGE, and that is the result worth having. A swap-free cycle pledges what it just
/// @notice borrowed, so every leg nets to zero and the borrower ends with the position they started with,
/// @notice minus one origination fee per hop. Real leverage lives in the SWAP, never in the borrow.
/// @dev `open` sets payer == payee == msg.sender, and delegatecall preserves it, so leg N's payout
/// @dev lands in the borrower's own wallet and leg N+1 pulls it straight back out. Nothing custodies.
/// @dev Every market here rests its whole ladder on ONE tick, so the funding floor is a fixture constant
/// @dev and a leg's size can be planned before the batch runs.
contract AceLoopingShowcaseTest is Test {
    Ace internal ace;
    AceReader internal read;
    PositionManager internal pm;
    PositionTitleNFT internal title;

    MockERC20 internal tok1; // the 18dp collateral the borrower already holds, whatever it is
    MockERC20 internal usdc;
    MockERC20 internal weth;

    MockPersistenceRecord internal recUsdc;
    MockPersistenceRecord internal recWeth;
    MockPersistenceRecord internal recBack;

    bytes32 internal mUSDC; // TOK1 in, USDC out
    bytes32 internal mWETH; // USDC in, WETH out
    bytes32 internal mBACK; // WETH in, USDC out, which closes the cycle so the loop can run forever

    address internal alice = address(0xA11CE); // the lender behind all three ladders
    address internal borrower = address(0xB0BB1E);

    uint256 internal T_PAR; // 1 TOK1 == 1.00 USDC, this pair's par; assigned in setUp, since par is not a constant
    uint256 internal T_WETH; // 1 USDC == 1/3010 WETH, that pair's par less 80040 on the spacing-60 grid
    uint256 internal T_BACK; // 1 WETH == 3010 USDC, the EXACT reciprocal: `priceAt(t) * priceAt(-t)` is the frame squared

    uint64 internal constant TENOR = 7 days;
    uint256 internal constant BASE_BPS = 40; // every market prices at the same rate, so the decay is legible
    uint256 internal constant START_TOK1 = 100_000e18;
    uint256 internal constant USDC_FLOAT = 2_000_000e6;
    uint256 internal constant WETH_FLOAT = 1_000e18;
    uint256 internal constant BACK_MIN_DEBT = 1e12; // 1e-6 WETH: the dust floor follows the 18dp quote

    OpenBounds internal OFF = OpenBounds(0, 0, 0);

    /// @notice One hop of the loop: what it posts, what it draws, and what it hands the next hop.
    struct Leg {
        bytes32 market;
        uint256 price;
        uint256 collateral;
        uint256 principal;
        uint256 payout;
    }

    function setUp() public {
        vm.warp(1_000_000);
        tok1 = new MockERC20("Token One", "TOK1", 18);
        usdc = new MockERC20("USD Coin", "USDC", 6);
        weth = new MockERC20("Wrapped Ether", "WETH", 18);
        T_PAR = AceFixtures.priceAt(address(usdc), address(tok1), 0);
        /// @dev Held as a STEP, not only as a price, because the reciprocal below is exact in step space and
        /// @dev only approximate in price space: `priceAtStep(-s)` is the inverse of `priceAtStep(s)` by the
        /// @dev `1.0001^t` law, while dividing the frame squared by a price would round.
        int24 sWeth = PriceFrame.parStep(18, 6) - 80040; // WETH-quoted, USDC collateral
        T_WETH = PriceFrame.priceAtStep(sWeth);
        /// @dev NEGATED, not framed off its own par: the round trip through WETH must preserve value to the
        /// @dev wei, and the two pairs' par steps are not symmetric, so par-relative twins are not reciprocal.
        T_BACK = PriceFrame.priceAtStep(-sWeth);

        recUsdc = new MockPersistenceRecord(address(usdc), address(tok1));
        recWeth = new MockPersistenceRecord(address(weth), address(usdc));
        recBack = new MockPersistenceRecord(address(usdc), address(weth));
        recBack.setMinPrice(AceFixtures.px(10_000e18, address(usdc), address(weth))); // anchors ABOVE T_BACK

        AceFixtures.Deployment memory d = AceFixtures.deploy(_paramsUsdc());
        (ace, pm, read, mUSDC) = (d.ace, d.positionManager, d.read, d.id);
        title = PositionTitleNFT(ace.POSITION_TITLE());
        mWETH = ace.createMarket(_paramsWeth());
        mBACK = ace.createMarket(_paramsBack());

        _fundLadder(mUSDC, address(usdc), T_PAR, USDC_FLOAT);
        _fundLadder(mWETH, address(weth), T_WETH, WETH_FLOAT);
        _fundLadder(mBACK, address(usdc), T_BACK, USDC_FLOAT);

        tok1.mint(borrower, START_TOK1);
        vm.startPrank(borrower);
        tok1.approve(address(pm), type(uint256).max);
        usdc.approve(address(pm), type(uint256).max);
        weth.approve(address(pm), type(uint256).max);
        vm.stopPrank();

        vm.label(address(ace), "Ace");
        vm.label(address(tok1), "TOK1");
        vm.label(address(usdc), "USDC");
        vm.label(address(weth), "WETH");
    }

    // ---------------------------- fixture ----------------------------

    /// @dev The band is off throughout: looping is a draw-path property and no test here sells collateral.
    /// @dev The record stays wired, because the DRAW CAP reads it whether or not a sale channel is live.
    function _paramsUsdc() internal view returns (MarketParams memory p) {
        p = AceFixtures.marketParams(address(usdc), address(tok1));
        p.record = address(recUsdc);
        p.price = T_PAR;
        p.baseBps = BASE_BPS;
    }

    function _paramsWeth() internal view returns (MarketParams memory p) {
        p = AceFixtures.marketParams(address(weth), address(usdc));
        p.record = address(recWeth);
        p.price = T_WETH;
        p.baseBps = BASE_BPS;
        p.minDebt = BACK_MIN_DEBT;
    }

    function _paramsBack() internal view returns (MarketParams memory p) {
        p = AceFixtures.marketParams(address(usdc), address(weth));
        p.record = address(recBack);
        p.price = T_BACK;
        p.baseBps = BASE_BPS;
    }

    /// @dev One deposit, deep enough that no leg ever exhausts it. The `price` argument is the market's own,
    /// @dev carried at genesis rather than chosen per deposit; it is kept so a call site still reads as a pair.
    function _fundLadder(bytes32 mid, address quote, uint256 price, uint256 amount) internal {
        MockERC20(quote).mint(alice, amount);
        vm.startPrank(alice);
        MockERC20(quote).approve(address(ace), amount);
        ace.deposit(mid, amount);
        vm.stopPrank();
    }

    // ------------------------- the loop planner -------------------------

    /// @notice Which market a hop draws from: TOK1 opens the chain, then USDC and WETH alternate.
    function _hop(uint256 i) internal view returns (bytes32 mid, uint256 price) {
        if (i == 0) return (mUSDC, T_PAR);
        return i % 2 == 1 ? (mWETH, T_WETH) : (mBACK, T_BACK);
    }

    /// @notice The largest draw this market admits against `units`, derived from the coverage law alone.
    /// @notice `trigger <= floor` collapses to `k * debtWhole <= collateralWhole * price`, so LTV caps at 1/k.
    /// @dev ONE floored division, which is exactly the inverse of the trigger's single ceiling: the
    /// @dev result is the largest admissible draw to the wei, and `test_TheLeverageCeiling` pins it there.
    /// @dev The COVERAGE LINE binds too and is the tighter leg: `units >= requiredAt + maxClaimTicks`.
    /// @dev The tick cap comes off the units first, so the LTV bound is taken on the backing that remains.
    function _maxDraw(bytes32 mid, uint256 price, uint256 units) internal view returns (uint256) {
        uint256 us = read.marketState(mid).unitScale;
        MarketParams memory p = ace.idToMarketParams(mid);
        uint256 backing = units - 1; // the slack settlement's per-tick ceilings will spend
        return FullMath.mulDiv(price * backing, 1e18, p.minCoverageWad * us);
    }

    /// @notice Plan `n` hops: each posts the whole payout of the one before it and draws the market's max.
    function _plan(uint256 n) internal view returns (Leg[] memory legs) {
        legs = new Leg[](n);
        uint256 held = START_TOK1;
        for (uint256 i; i < n; i++) {
            (bytes32 mid, uint256 price) = _hop(i);
            uint256 principal = _maxDraw(mid, price, held);
            uint256 fee = LoanMath.originationFee(principal, TENOR, ace.idToMarketParams(mid).baseBps, TENOR);
            legs[i] = Leg(mid, price, held, principal, principal - fee);
            held = principal - fee;
        }
    }

    /// @dev The batch itself: one `open` per hop, in order, addressed to the same singleton.
    function _calls(Leg[] memory legs) internal view returns (bytes[] memory calls) {
        calls = new bytes[](legs.length);
        for (uint256 i; i < legs.length; i++) {
            calls[i] = abi.encodeCall(Ace.open, (legs[i].market, legs[i].collateral, legs[i].principal, 0, borrower, OFF));
        }
    }

    function _loop(Leg[] memory legs) internal returns (uint256[] memory ids) {
        vm.prank(borrower);
        bytes[] memory out = ace.multicall(_calls(legs));
        ids = new uint256[](out.length);
        for (uint256 i; i < out.length; i++) {
            ids[i] = abi.decode(out[i], (uint256));
        }
    }

    /// @notice A leg's posted collateral, valued in USDC at its own market's funding floor.
    /// @dev `value = units * price / unitScale` is the price law rearranged; it lands in quote raw units.
    /// @dev A WETH-collateral hop is converted at T_BACK, so every leg is comparable on one axis.
    function _usdcValue(Leg memory leg) internal view returns (uint256) {
        if (leg.market == mWETH) return leg.collateral; // already USDC
        uint256 us = read.marketState(leg.market).unitScale;
        return FullMath.mulDiv(leg.collateral, leg.price, us);
    }

    /// @dev The per-hop value ratio the fixture implies: the payout share of a draw, over the coverage k.
    function _legRatioWad() internal view returns (uint256) {
        uint256 p = _maxDraw(mUSDC, T_PAR, START_TOK1);
        uint256 fee = LoanMath.originationFee(p, TENOR, BASE_BPS, TENOR);
        return FullMath.mulDiv((p - fee) * 1e18, 1e18, p * ace.idToMarketParams(mUSDC).minCoverageWad);
    }

    // ============ 1. the chain the issue asks for ============

    /// @notice TOK1 -> borrow USDC -> borrow WETH -> borrow USDC, three markets, ONE multicall.
    /// @notice The recursion identity is the assertion: hop N posts EXACTLY what hop N-1 paid out.
    function test_ThreeMarketChain_InOneMulticall() public {
        Leg[] memory legs = _plan(3);
        uint256 idsBefore = read.loanCount();
        uint256[] memory quoted = new uint256[](3); // the three markets are distinct, so all three quotes stand
        for (uint256 i; i < 3; i++) {
            quoted[i] = ace.previewOpen(legs[i].market, legs[i].collateral, legs[i].principal, 0, borrower, OFF).payout;
        }

        uint256[] memory ids = _loop(legs);

        assertEq(ids.length, 3, "one loan per hop");
        assertEq(read.loanCount(), idsBefore + 3, "and three fresh ids, all from one transaction");
        assertEq(read.loan(ids[0]).market, mUSDC, "hop 1 draws USDC against TOK1");
        assertEq(read.loan(ids[1]).market, mWETH, "hop 2 draws WETH against that USDC");
        assertEq(read.loan(ids[2]).market, mBACK, "hop 3 draws USDC against that WETH");

        for (uint256 i; i < 3; i++) {
            assertEq(read.loan(ids[i]).borrower, borrower, "the borrower holds every hop");
            assertEq(title.ownerOf(ids[i]), borrower, "and the title collection agrees");
            assertEq(read.loan(ids[i]).collateralUnits, legs[i].collateral, "the hop posted what it planned");
            assertEq(pm.collateralOf(ids[i]), legs[i].collateral, "custody agrees with the loan record");
            assertEq(read.debtOf(ids[i]), legs[i].principal, "and owes what it drew");
            assertFalse(read.loan(ids[i]).closedAt != 0, "every hop is live");
            assertEq(read.claimCount(legs[i].market, ids[i]), 1, "PREMISE for the gas curve: one rung funds each hop");
        }

        assertEq(read.loan(ids[1]).collateralUnits, quoted[0], "hop 2 posts what the hub quoted hop 1 would pay out");
        assertEq(read.loan(ids[2]).collateralUnits, quoted[1], "and hop 3 posts hop 2's quote, to the wei");
    }

    /// @notice The recursion identity measured at the TOKEN: hop N+1 posts exactly what hop N put in the wallet.
    /// @notice Run unbatched, because that is the only way an intermediate balance is observable at all.
    /// @dev The batched form is proven identical by `test_TheLoopIsTheSameOutcomeUnbatched`, so this carries over.
    function test_EachHopPostsThePriorHopsMeasuredReceipt() public {
        Leg[] memory legs = _plan(4);
        for (uint256 i; i < 4; i++) {
            MockERC20 quote = MockERC20(ace.idToMarketParams(legs[i].market).quote);
            uint256 held = quote.balanceOf(borrower);
            vm.prank(borrower);
            ace.open(legs[i].market, legs[i].collateral, legs[i].principal, 0, borrower, OFF);
            uint256 received = quote.balanceOf(borrower) - held;
            assertEq(received, legs[i].payout, "the hop paid the draw less its own market's origination, and nothing else");
            if (i + 1 < 4) assertEq(legs[i + 1].collateral, received, "and the next hop posts that receipt whole");
        }
        assertEq(usdc.balanceOf(borrower), 0, "hop 4 consumed the USDC hop 3 paid, so the wallet is empty of it");
    }

    /// @notice Nothing is left in the borrower's hands but the last hop's payout, and the hub keeps no dust.
    /// @dev This is what says no router or intermediate custody is involved: the wallet IS the conveyor.
    function test_ThreeMarketChain_LeavesOnlyTheLastPayout() public {
        Leg[] memory legs = _plan(3);
        uint256 hubUsdc = usdc.balanceOf(address(ace));
        uint256 hubWeth = weth.balanceOf(address(ace));

        _loop(legs);

        assertEq(tok1.balanceOf(borrower), 0, "every TOK1 went into hop 1");
        assertEq(weth.balanceOf(borrower), 0, "and every borrowed WETH went into hop 3");
        assertEq(usdc.balanceOf(borrower), legs[2].payout, "what is left is the last hop's payout, exactly");
        assertEq(usdc.balanceOf(address(ace)), hubUsdc - legs[0].payout - legs[2].payout, "the hub paid out the two USDC hops and kept both fees");
        assertEq(weth.balanceOf(address(ace)), hubWeth - legs[1].payout, "and paid out the one WETH hop");
        /// @dev Hop 2 posts USDC, so the custodian holds it: the claim is that it holds EXACTLY that and no dust
        assertEq(usdc.balanceOf(address(pm)), legs[1].collateral, "the custodian holds the one hop that posted USDC");
        assertEq(pm.custodiedOf(address(usdc)), legs[1].collateral, "and every unit of it is credited to a loan");
    }

    /// @notice Three `Opened` logs, in hop order, naming the three markets: the batch is not one fused verb.
    function test_ThreeMarketChain_EmitsOneOpenPerHop() public {
        Leg[] memory legs = _plan(3);
        vm.recordLogs();

        _loop(legs);

        Vm.Log[] memory logs = vm.getRecordedLogs();
        bytes32 opened = keccak256("Opened(uint256,bytes32,address,uint256,uint256,uint256,uint64)");
        bytes32[] memory seen = new bytes32[](logs.length);
        uint256 n;
        for (uint256 i; i < logs.length; i++) {
            if (logs[i].topics[0] == opened) seen[n++] = logs[i].topics[2];
        }
        assertEq(n, 3, "one Opened per hop, no more and no fewer");
        assertEq(seen[0], mUSDC, "in hop order: the TOK1 market first");
        assertEq(seen[1], mWETH, "then the USDC market");
        assertEq(seen[2], mBACK, "then the WETH market");
    }

    // ============ 2. what the batch does and does not buy ============

    /// @notice One refused hop takes the WHOLE loop down: a half-built levered position is not reachable.
    /// @dev The last hop asks for one wei over its market's ceiling, so the refusal is the coverage gate's.
    function test_TheLoopIsAllOrNothing() public {
        Leg[] memory legs = _plan(3);
        legs[2].principal += 1;
        uint256 countBefore = read.loanCount();
        uint256 tok1Before = tok1.balanceOf(borrower);
        (uint256 restBefore, uint256 lentBefore,) = read.poolOf(mUSDC);

        vm.prank(borrower);
        vm.expectRevert(TriggerAboveFloor.selector);
        ace.multicall(_calls(legs));

        assertEq(read.loanCount(), countBefore, "no loan survived the failed batch");
        assertEq(tok1.balanceOf(borrower), tok1Before, "the first hop's collateral came back");
        assertEq(usdc.balanceOf(borrower), 0, "and its payout was rolled back with it");
        (uint256 restAfter, uint256 lentAfter,) = read.poolOf(mUSDC);
        assertEq(lentAfter, lentBefore, "the first market lent nothing");
        assertEq(restAfter, restBefore, "and its cash is untouched");
    }

    /// @notice The batch is pure sequencing: the same three opens sent one at a time land the same state.
    /// @dev Run from ONE root snapshot, because a second pass over a thinned ladder is not a control.
    function test_TheLoopIsTheSameOutcomeUnbatched() public {
        Leg[] memory legs = _plan(3);
        uint256 root = vm.snapshotState();

        uint256[] memory batched = _loop(legs);
        uint256 batchedDebt = read.debtOf(batched[2]);
        uint256 batchedFloor = read.fundingFloor(mBACK, batched[2]);
        uint256 batchedLeft = usdc.balanceOf(borrower);
        (, uint256 batchedBackLent,) = read.poolOf(mBACK);

        vm.revertToState(root);
        uint256 last;
        for (uint256 i; i < 3; i++) {
            vm.prank(borrower);
            last = ace.open(legs[i].market, legs[i].collateral, legs[i].principal, 0, borrower, OFF);
        }

        assertEq(last, batched[2], "the same loan ids");
        assertEq(read.debtOf(last), batchedDebt, "the same debt");
        assertEq(read.fundingFloor(mBACK, last), batchedFloor, "the same funding floor");
        assertEq(usdc.balanceOf(borrower), batchedLeft, "the same money left over");
        (, uint256 unbatchedBackLent,) = read.poolOf(mBACK);
        assertEq(unbatchedBackLent, batchedBackLent, "and the same lender state behind it");
    }

    /// @notice `multicall` reaches HUB SELECTORS ONLY, so a swap can never ride between two hops.
    /// @notice That is why the loop is built as a CHAIN of markets rather than a single market re-entered.
    /// @dev The hub has no fallback, so an unknown selector reverts with empty data and the batch bubbles it.
    function test_AMulticallLegCannotReachAnythingButTheHub() public {
        bytes[] memory calls = new bytes[](1);
        calls[0] = abi.encodeWithSignature("swap(address,address,uint256)", address(usdc), address(tok1), 1e6);

        vm.prank(borrower);
        (bool ok, bytes memory ret) = address(ace).call(abi.encodeCall(Ace.multicall, (calls)));

        assertFalse(ok, "a non-hub selector is not callable from a batch leg");
        assertEq(ret.length, 0, "and it fails with empty data: there is no fallback to route it");
    }

    /// @notice THE REAL LEVERAGE LOOP, and the contrast the negative result above needs: it has a SWAP.
    /// @notice Net TOK1 ends STRICTLY ABOVE the starting stack, funded by a USDC short. That is leverage.
    /// @notice The swap-free cycle cannot do this at any depth, because it never converts anything.
    /// @notice The batch cannot express it either, so it runs through a router on a `setCreditOperator` grant.
    /// @dev What the hub supplies is the three-role split at `Borrower.OpenArgs` plus that grant.
    /// @dev No hub verb changes; the swap the loop needs lives entirely outside the singleton.
    function test_SameMarketLoop_RunsOffHubOnTheCreditGrant() public {
        (LoopRouter router, uint256[] memory principals, uint256[] memory posted) = _routerLoop(3);

        vm.startPrank(borrower);
        ace.setCreditOperator(address(router), true);
        tok1.approve(address(router), START_TOK1);
        uint256[] memory ids = router.loop(mUSDC, START_TOK1, principals, borrower);
        vm.stopPrank();

        for (uint256 i; i < 3; i++) {
            assertEq(read.loan(ids[i]).market, mUSDC, "every hop is the SAME market this time");
            assertEq(read.loan(ids[i]).borrower, borrower, "the debt is the user's, never the router's");
            assertEq(title.ownerOf(ids[i]), borrower, "and so is the title");
            assertEq(read.loan(ids[i]).collateralUnits, posted[i], "each hop posted the swap output of the one before");
            assertEq(read.debtOf(ids[i]), principals[i], "and drew what was quoted for it");
        }
        assertEq(tok1.balanceOf(address(router)), 0, "the router ends holding no collateral");
        assertEq(usdc.balanceOf(address(router)), 0, "and no quote: the last hop's payout went to the user");
        assertGt(usdc.balanceOf(borrower), 0, "who is left with it");
        assertLt(posted[2], posted[1], "and the same geometric decay bounds this loop too");

        (uint256 tok1Held,) = _netOf(ids, address(tok1));
        (uint256 usdcHeld, uint256 usdcOwed) = _netOf(ids, address(usdc));
        assertGt(tok1Held, START_TOK1, "THE DIFFERENCE: net TOK1 grew, because the swap converted the borrowed USDC");
        assertGt(usdcOwed, usdcHeld, "and the long is funded by a genuine USDC short, not by a pass-through pledge");
        console2.log("net TOK1 multiple wad", FullMath.mulDiv(tok1Held, 1e18, START_TOK1));
    }

    /// @notice Without the grant the router cannot borrow in anyone's name: delegation is opt-in, per user.
    function test_ARouterWithoutTheCreditGrantIsRefused() public {
        (LoopRouter router, uint256[] memory principals,) = _routerLoop(2);

        vm.startPrank(borrower);
        tok1.approve(address(router), START_TOK1);
        vm.expectRevert(NotAuthorized.selector);
        router.loop(mUSDC, START_TOK1, principals, borrower);
        vm.stopPrank();
    }

    /// @dev Deploys the venue and router and quotes the hops off-chain, exactly as a front end would.
    function _routerLoop(uint256 n) private returns (LoopRouter router, uint256[] memory principals, uint256[] memory posted) {
        ParSwap venue = new ParSwap(IERC20(address(tok1)), IERC20(address(usdc)));
        tok1.mint(address(venue), 1_000_000e18);
        usdc.mint(address(venue), 1_000_000e6);
        router = new LoopRouter(ace, IERC20(address(tok1)), IERC20(address(usdc)), venue);

        principals = new uint256[](n);
        posted = new uint256[](n);
        uint256 held = START_TOK1;
        for (uint256 i; i < n; i++) {
            posted[i] = held;
            principals[i] = _maxDraw(mUSDC, T_PAR, held);
            uint256 fee = LoanMath.originationFee(principals[i], TENOR, BASE_BPS, TENOR);
            held = (principals[i] - fee) * 1e12; // the venue's par rate across the 18/6 decimal gap
        }
    }

    // ============ 3. what the coverage factor lets a loop reach ============

    /// @notice The per-hop draw ceiling is 1/k of the funding floor, and the hub is pinned to the wei there.
    /// @notice It is what bounds a REAL loop's leverage; a swap-free cycle has no leverage for it to bound.
    /// @dev The planner's closed form is asserted against `previewOpen` on BOTH sides of the boundary.
    function test_ThePerHopDrawCeilingIsOneOverK() public view {
        uint256 max = _maxDraw(mUSDC, T_PAR, START_TOK1);
        uint256 k = ace.idToMarketParams(mUSDC).minCoverageWad;

        assertTrue(_previewOk(mUSDC, START_TOK1, max), "the hub admits the planner's maximum");
        (bool ok, bytes memory ret) = _preview(mUSDC, START_TOK1, max + 1);
        assertFalse(ok, "and refuses one wei over it");
        assertEq(bytes32(bytes4(ret)), bytes32(TriggerAboveFloor.selector), "by the coverage gate's own name");

        uint256 collateralValue = FullMath.mulDiv(START_TOK1, T_PAR, read.marketState(mUSDC).unitScale);
        assertEq(max, FullMath.mulDiv(collateralValue, 1e18, k), "the ceiling IS collateral value over k");
        assertApproxEqRel(FullMath.mulDiv(max, 1e18, collateralValue), 0.714285714285714285e18, 1e12, "which is a 71.43 percent LTV");
    }

    /// @notice THE NEGATIVE RESULT, and the most useful thing in this file: a SWAP-FREE cycle is NOT leverage.
    /// @notice Borrowing is exposure-neutral. You hold X and you owe X, so a hop that borrows the next hop's
    /// @notice collateral adds a pledge and a debt of the SAME asset, and the two net to nothing.
    /// @notice Ten hops later the borrower's net TOK1 is exactly the TOK1 they started with, to the wei.
    /// @notice What ten hops bought is ten origination fees and ten independent liquidation surfaces.
    /// @dev Every term is read off the HUB, never off the planner: custody for the pledges, `debt` for the owings.
    function test_TheSwapFreeCycleIsNotLeverage_NetExposureIsFlat() public {
        uint256 n = 10;
        uint256[] memory ids = _loop(_plan(n));

        (uint256 tok1Held, uint256 tok1Owed) = _netOf(ids, address(tok1));
        assertEq(tok1Held, START_TOK1, "every TOK1 the borrower started with is still theirs, pledged");
        assertEq(tok1Owed, 0, "and no market here quotes TOK1, so none is owed");

        (uint256 usdcHeld, uint256 usdcOwed) = _netOf(ids, address(usdc));
        (uint256 wethHeld, uint256 wethOwed) = _netOf(ids, address(weth));
        assertEq(usdcOwed - usdcHeld, _feesIn(ids, address(usdc)), "net USDC is short by the USDC origination and NOTHING else");
        assertEq(wethOwed - wethHeld, _feesIn(ids, address(weth)), "net WETH short by the WETH origination, the same identity");

        assertGt(usdcOwed, 0, "meanwhile gross debt across the markets is large and real");
        assertGt(wethOwed, 0, "on both quote tokens");
        assertEq(ids.length, n, "ten loans, ten tenors, ten funding floors, for a position that did not move");
    }

    /// @notice The GROSS pledged value does follow `(1 - r^n)/(1 - r)`, and that number is NOT leverage.
    /// @notice It is the sum of what was pledged, and everything after the first hop was borrowed first.
    /// @dev Pinned because reading this series AS leverage is exactly the mistake this file exists to stop.
    /// @dev Real leverage needs the swap leg; `test_SameMarketLoop_RunsOffHubOnTheCreditGrant` is what that looks like.
    function test_TheCyclesGrossPledgedValueIsAGeometricSeries() public view {
        uint256 n = 10;
        Leg[] memory legs = _plan(n);

        uint256 equity = _usdcValue(legs[0]);
        uint256 gross;
        for (uint256 i; i < n; i++) {
            gross += _usdcValue(legs[i]);
        }

        uint256 r = _legRatioWad();
        uint256 term = 1e18;
        for (uint256 i; i < n; i++) {
            term = FullMath.mulDiv(term, r, 1e18);
        }

        console2.log("equity USDC        ", equity);
        console2.log("gross pledged USDC ", gross);
        console2.log("gross multiple wad ", FullMath.mulDiv(gross, 1e18, equity));
        assertApproxEqRel(gross, FullMath.mulDiv(equity, 1e18 - term, 1e18 - r), 1e15, "gross pledging tracks the series to a tenth of a percent");
        assertLt(FullMath.mulDiv(gross, 1e18, equity), FullMath.mulDiv(1e18, 1e18, 1e18 - r), "and never reaches the limit 1/(1-r)");
    }

    /// @notice Each turn pledges strictly less than the one before, which is why the cycle terminates at all.
    /// @dev Compared two apart because the odd hops are USDC-collateral and the even ones WETH-collateral.
    function test_TheCycleShrinksEveryTurn() public view {
        Leg[] memory legs = _plan(8);
        for (uint256 i = 1; i + 2 < 8; i++) {
            assertLt(legs[i + 2].collateral, legs[i].collateral, "a turn of the cycle shrinks, never grows");
        }
        assertGt(legs[7].principal, ace.idToMarketParams(legs[7].market).minDebt, "and eight hops still clear the dust floor");
    }

    /// @dev What the borrower HOLDS of a token (wallet plus every pledge) and what they OWE of it, hub-sourced.
    function _netOf(uint256[] memory ids, address token) internal view returns (uint256 held, uint256 owed) {
        held = MockERC20(token).balanceOf(borrower);
        for (uint256 i; i < ids.length; i++) {
            MarketParams memory p = ace.idToMarketParams(read.loan(ids[i]).market);
            if (p.collateral == token) held += pm.collateralOf(ids[i]);
            if (p.quote == token) owed += read.debtOf(ids[i]);
        }
    }

    /// @dev The origination each loan actually recorded, summed over the loans quoting `token`.
    function _feesIn(uint256[] memory ids, address token) internal view returns (uint256 fees) {
        for (uint256 i; i < ids.length; i++) {
            if (ace.idToMarketParams(read.loan(ids[i]).market).quote == token) fees += read.loan(ids[i]).lastFee;
        }
    }

    // ============ 4. the practical limit ============

    /// @notice The gas curve of one batched loop at 1, 3, 5, 10, 16 and 24 hops.
    /// @notice A MEASUREMENT, logged; the assertion is the operational one, that it fits a mainnet block.
    /// @dev Read it against the premise pinned above: each ladder rests on ONE tick, so a hop funds from
    /// @dev one claim tick. A fragmented ladder can put up to `maxClaimTicks` behind a single draw, and
    /// @dev the per-hop cost rises with the count, so this curve is the cheap end of the range.
    function test_LoopGasCurve() public {
        _gasAt(1);
        _gasAt(3);
        _gasAt(5);
        _gasAt(10);
        _gasAt(16);
        _gasAt(24);
    }

    /// @dev Each point runs from a fresh root, so no measurement inherits the ladder the last one thinned.
    function _gasAt(uint256 n) private {
        uint256 root = vm.snapshotState();
        bytes memory cd = abi.encodeCall(Ace.multicall, (_calls(_plan(n))));
        vm.prank(borrower);
        uint256 g = gasleft();
        (bool ok,) = address(ace).call(cd);
        uint256 used = g - gasleft();
        assertTrue(ok, "the loop went through at this depth");
        console2.log(n, used);
        assertLt(used, 30_000_000, "a levered loop must fit inside a mainnet block");
        vm.revertToState(root);
    }

    /// @notice What ends a loop is the DUST FLOOR, not gas: the hops shrink geometrically, the cost does not.
    /// @dev The first hop under `minDebt` is refused, so the ceiling on depth is economic and per market.
    function test_TheLoopEndsAtTheDustFloor() public view {
        uint256 depth;
        Leg[] memory legs = _plan(40);
        for (uint256 i; i < 40; i++) {
            if (legs[i].principal < ace.idToMarketParams(legs[i].market).minDebt) break;
            depth++;
        }
        console2.log("hops before the dust floor bites", depth);
        assertGt(depth, 20, "this equity supports a deep loop before any market calls the draw dust");
        assertLt(depth, 40, "and the geometric decay does end it, so the loop is not unbounded");
    }

    // ---------------------------- helpers ----------------------------

    function _preview(bytes32 mid, uint256 units, uint256 principal) internal view returns (bool ok, bytes memory ret) {
        (ok, ret) = address(ace).staticcall(abi.encodeCall(Ace.previewOpen, (mid, units, principal, 0, borrower, OFF)));
    }

    function _previewOk(bytes32 mid, uint256 units, uint256 principal) internal view returns (bool ok) {
        (ok,) = _preview(mid, units, principal);
    }
}
