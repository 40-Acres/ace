// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.36;

import {console2} from "forge-std/Test.sol";
import {FullMath} from "@uniswap/v4-core/src/libraries/FullMath.sol";
import {Ace, NoMarket} from "../../src/ace/hub/Ace.sol";
import {PriceFrame} from "../utils/PriceFrame.sol";
import {LoanMath} from "../../src/ace/hub/libraries/LoanMath.sol";
import {MarketParams, OpenBounds} from "../../src/ace/hub/Types.sol";
import {PositionManager} from "../../src/ace/positions/PositionManager.sol";
import {PositionTitleNFT} from "../../src/ace/positions/PositionTitleNFT.sol";
import {MockERC20} from "../mocks/MockERC20.sol";
import {MockPersistenceRecord} from "../mocks/MockPersistenceRecord.sol";
import {AceFixtures} from "../utils/AceFixtures.sol";
import {AceReader} from "../utils/AceReader.sol";
import {WarpClock} from "../utils/WarpClock.sol";

/// @title AceCreditRouting
/// @notice CREDIT ROUTING, the terminating chain: pledge ETH, draw BTC, pledge that BTC, draw USDC.
/// @notice It synthesizes an ETH/USDC loan out of two markets, NEITHER of which is ETH/USDC.
/// @notice There is no ETH/USDC market in this fixture at all, and the direct draw reverts `NoMarket`.
/// @notice The routing needs NO venue trade: the borrowed asset IS the next leg's collateral.
/// @notice ACCESS TO A MISSING PAIR is the benefit, not a cheaper rate. A chain reaches what no market quotes.
/// @notice THE SHARP EDGE, and half this file: the middle asset nets to zero ECONOMICALLY and not in ACE.
/// @notice Isolation is logical per market id, so a chain is two independent loans: two floors, two
/// @notice tenors, two liquidation surfaces, no cross-margin, and nothing in the hub linking them.
/// @dev Both markets ship with the band off, so this file touches no crank verb.
contract AceCreditRoutingTest is WarpClock {
    Ace internal ace;
    AceReader internal read;
    PositionManager internal pm;
    PositionTitleNFT internal title;

    MockERC20 internal weth;
    MockERC20 internal wbtc;
    MockERC20 internal usdc;

    MockPersistenceRecord internal recEB;
    MockPersistenceRecord internal recBU;

    bytes32 internal mEB; // WETH in, WBTC out
    bytes32 internal mBU; // WBTC in, USDC out

    address internal alice = address(0xA11CE); // the lender behind both ladders
    address internal borrower = address(0xB0BB1E);
    address internal keeper = address(0xCAFE);

    uint256 internal T_EB; // 1 WETH = 0.033318 WBTC: 34020 ticks UNDER that pair's par, on the spacing-60 grid
    uint256 internal T_BU; // 1 WBTC = 89,846 USDC: 114060 ticks OVER its own pair's par, same grid

    uint64 internal constant TEN7 = 7 days;
    uint64 internal constant TEN30 = 30 days;
    uint64 internal constant SPACING = 23 days; // one step, so the grid is exactly {7d, 30d}
    uint256 internal constant BASE_BPS = 40;
    uint256 internal constant START_WETH = 100e18;
    uint256 internal constant BTC_FLOAT = 100e8;
    uint256 internal constant USD_FLOAT = 2_000_000e6;

    OpenBounds internal OFF = OpenBounds(0, 0, 0);
    uint256 internal t0;

    function setUp() public {
        _warpTo(1_000_000);
        t0 = _now();
        weth = new MockERC20("Wrapped Ether", "WETH", 18);
        wbtc = new MockERC20("Wrapped Bitcoin", "WBTC", 8);
        usdc = new MockERC20("USD Coin", "USDC", 6);

        T_EB = AceFixtures.priceAt(address(wbtc), address(weth), -34020);
        T_BU = AceFixtures.priceAt(address(usdc), address(wbtc), 114060);

        recEB = new MockPersistenceRecord(address(wbtc), address(weth));
        recBU = new MockPersistenceRecord(address(usdc), address(wbtc));
        // the draw cap must anchor ABOVE T_BU or no rung is reachable
        recBU.setMinPrice(AceFixtures.px(200_000e18, address(usdc), address(wbtc)));

        (ace, pm) = AceFixtures.newAceWithEscrow(AceFixtures.TREASURY);
        read = new AceReader(address(ace));
        title = PositionTitleNFT(ace.POSITION_TITLE());
        mEB = ace.createMarket(_paramsEthBtc());
        mBU = ace.createMarket(_paramsBtcUsd());

        _fundLadder(mEB, wbtc, BTC_FLOAT);
        _fundLadder(mBU, usdc, USD_FLOAT);

        weth.mint(borrower, START_WETH);
        vm.startPrank(borrower);
        weth.approve(address(pm), type(uint256).max);
        wbtc.approve(address(pm), type(uint256).max);
        vm.stopPrank();

        vm.label(address(weth), "WETH");
        vm.label(address(wbtc), "WBTC");
        vm.label(address(usdc), "USDC");
    }

    // ---------------------------- fixture ----------------------------

    /// @dev A band-off market keeps a record legal but optional-by-rail, and needs no reference.
    function _paramsEthBtc() internal view returns (MarketParams memory p) {
        p = AceFixtures.marketParams(address(wbtc), address(weth));
        p.record = address(recEB);
        p.baseBps = BASE_BPS;
        p.minDebt = 1e4; // 0.0001 WBTC: the dust floor follows the 8dp quote
        p.price = T_EB; // the rung this market funded at is its own price now
        p.minTenor = TEN7;
        p.maxTenor = TEN30;
    }

    function _paramsBtcUsd() internal view returns (MarketParams memory p) {
        p = AceFixtures.marketParams(address(usdc), address(wbtc));
        p.record = address(recBU);
        p.price = T_BU;
        p.baseBps = BASE_BPS;
        p.minTenor = TEN7;
        p.maxTenor = TEN30;
    }

    /// @dev One lot at one tick, deep enough that no leg walks past it and moves the floor.
    /// @dev THE HORIZON ARGUMENT IS GONE with the field: a market's `maxTenor` is its whole maturity consent,
    /// @dev asked once at genesis. The thirty-day leg the tenor test writes is admitted or refused there.
    function _fundLadder(bytes32 mid, MockERC20 quote, uint256 amount) internal {
        quote.mint(alice, amount);
        vm.startPrank(alice);
        quote.approve(address(ace), amount);
        ace.deposit(mid, amount);
        vm.stopPrank();
    }

    /// @notice The largest draw a market admits against `units`: `trigger <= floor` is LTV <= 1/k.
    /// @dev The COVERAGE LINE binds too, and it is the tighter of the two: `units >= requiredAt + 1`.
    /// @dev So one atom comes off the units first, and the LTV bound is taken on what is left.
    function _maxDraw(bytes32 mid, uint256 units) internal view returns (uint256) {
        uint256 us = read.marketState(mid).unitScale;
        MarketParams memory p = ace.idToMarketParams(mid);
        uint256 backing = units - 1; // the one atom settlement's own ceiling will spend
        return FullMath.mulDiv(p.price * backing, 1e18, p.minCoverageWad * us);
    }

    function _payout(bytes32 mid, uint256 principal, uint64 tenor) internal view returns (uint256) {
        MarketParams memory p = ace.idToMarketParams(mid);
        return principal - LoanMath.originationFee(principal, tenor, p.baseBps, p.minTenor);
    }

    /// @notice The two-hop chain in ONE batch, at the two tenors given; returns both loan ids.
    function _route(uint64 tenorEB, uint64 tenorBU) internal returns (uint256 idEB, uint256 idBU, uint256 btcMid) {
        uint256 drawBtc = _maxDraw(mEB, START_WETH);
        btcMid = _payout(mEB, drawBtc, tenorEB);
        uint256 drawUsd = _maxDraw(mBU, btcMid);

        bytes[] memory calls = new bytes[](2);
        calls[0] = abi.encodeCall(Ace.open, (mEB, START_WETH, drawBtc, tenorEB, borrower, OFF));
        calls[1] = abi.encodeCall(Ace.open, (mBU, btcMid, drawUsd, tenorBU, borrower, OFF));
        vm.prank(borrower);
        bytes[] memory out = ace.multicall(calls);
        (idEB, idBU) = (abi.decode(out[0], (uint256)), abi.decode(out[1], (uint256)));
    }

    // ============ 1. the routing itself ============

    /// @notice ETH -> BTC -> USDC, two markets, one multicall, and the borrower ends holding USDC.
    /// @notice Neither market is ETH/USDC; the pair the borrower actually wanted is synthesized from two.
    function test_CreditRouting_EthToBtcToUsdc_InOneMulticall() public {
        uint256 usdBefore = usdc.balanceOf(borrower);
        (uint256 idEB, uint256 idBU, uint256 btcMid) = _route(TEN7, TEN7);

        assertEq(read.loan(idEB).market, mEB, "leg 1 draws BTC against ETH");
        assertEq(read.loan(idBU).market, mBU, "leg 2 draws USDC against that BTC");
        assertEq(read.loan(idEB).borrower, borrower, "both legs are the borrower's");
        assertEq(title.ownerOf(idBU), borrower, "and both titles are theirs");
        assertEq(read.loan(idEB).collateralUnits, START_WETH, "leg 1 pledged the whole ETH stack");
        assertEq(read.loan(idBU).collateralUnits, btcMid, "leg 2 pledged exactly the BTC leg 1 paid out");
        assertGt(usdc.balanceOf(borrower) - usdBefore, 0, "and the borrower is holding USDC against ETH collateral");

        MarketParams memory p1 = ace.idToMarketParams(mEB);
        MarketParams memory p2 = ace.idToMarketParams(mBU);
        assertTrue(p1.collateral == address(weth) && p1.quote == address(wbtc), "leg 1 is an ETH/BTC market");
        assertTrue(p2.collateral == address(wbtc) && p2.quote == address(usdc), "leg 2 is a BTC/USDC market");
        assertTrue(p1.quote != address(usdc) && p2.collateral != address(weth), "NEITHER of them is the ETH/USDC pair");
    }

    /// @notice The pair the borrower reached does not exist: a direct ETH-collateral USDC draw is `NoMarket`.
    /// @notice That is the benefit stated as a refusal. Routing buys ACCESS, not a better rate.
    /// @dev The id is the param hash, so this names the exact market a creator would have made for the pair.
    function test_CreditRouting_TheDirectPairDoesNotExist() public {
        MarketParams memory direct = AceFixtures.marketParams(address(usdc), address(weth));
        direct.record = address(recEB);
        bytes32 directId = keccak256(abi.encode(direct));

        assertEq(ace.idToMarketParams(directId).quote, address(0), "no market at those params: nobody created the pair");
        (bool ok, bytes memory ret) = address(ace).staticcall(abi.encodeCall(Ace.previewOpen, (directId, START_WETH, 1_000e6, TEN7, borrower, OFF)));
        assertFalse(ok, "so the direct draw is not merely expensive, it is unavailable");
        assertEq(bytes32(bytes4(ret)), bytes32(NoMarket.selector), "by name");

        (,, uint256 btcMid) = _route(TEN7, TEN7);
        assertGt(btcMid, 0, "while the two-hop route reached USDC in the same transaction");
    }

    /// @notice No venue trade anywhere: the middle asset is drawn and re-pledged, never sold.
    /// @dev The borrower's WBTC balance is zero on both sides, because the payout goes straight back in.
    /// @dev There is no swap contract in this file at all, which is the point rather than an omission.
    function test_CreditRouting_NeedsNoVenueTrade() public {
        assertEq(wbtc.balanceOf(borrower), 0, "the borrower starts with no BTC and never acquires any");
        (, uint256 idBU, uint256 btcMid) = _route(TEN7, TEN7);

        assertEq(wbtc.balanceOf(borrower), 0, "and ends with none: it passed straight from the payout into leg 2");
        assertEq(pm.collateralOf(idBU), btcMid, "every unit of it is pledged, not traded");
        assertEq(wbtc.balanceOf(address(ace)), BTC_FLOAT - btcMid, "the hub's BTC fell by the payout and nothing else: no venue took a cut");
    }

    // ============ 2. two loans, not one position ============

    /// @notice The chain's effective tenor is the MINIMUM of its legs, and the legs run on different clocks.
    /// @notice Nothing in the hub links them: at leg 2's expiry the borrower must act while leg 1 runs on.
    function test_TheChainsEffectiveTenorIsTheMinimumOfItsLegs() public {
        (uint256 idEB, uint256 idBU,) = _route(TEN30, TEN7);

        assertEq(read.loan(idEB).expiry, t0 + TEN30, "leg 1 was written for thirty days");
        assertEq(read.loan(idBU).expiry, t0 + TEN7, "leg 2 for seven");
        assertLt(read.loan(idBU).expiry, read.loan(idEB).expiry, "so the chain is done when the SHORTER leg is");

        _warpTo(t0 + TEN7 + 1);
        assertLe(read.loan(idBU).expiry, _now(), "leg 2 has matured");
        assertGt(read.loan(idEB).expiry, _now(), "while leg 1 has twenty-three days left and knows nothing about it");
        assertEq(read.loan(idEB).expiry - _now(), TEN30 - TEN7 - 1, "exactly the gap the borrower has to cover");
    }

    /// @notice Two markets means two funding floors and no cross-margin: neither market holds the other's loan.
    function test_TheChainsLegsShareNoState() public {
        (uint256 idEB, uint256 idBU,) = _route(TEN7, TEN7);

        assertGt(read.fundingFloor(mEB, idEB), 0, "leg 1 has a floor from the ETH/BTC ladder");
        assertGt(read.fundingFloor(mBU, idBU), 0, "leg 2 has its own from the BTC/USDC ladder");
        assertEq(read.fundingFloor(mBU, idEB), 0, "and neither market holds a floor for the other's loan");
        assertEq(read.fundingFloor(mEB, idBU), 0, "isolation is logical, per market id");
        assertTrue(read.fundingFloor(mEB, idEB) != read.fundingFloor(mBU, idBU), "the two numbers are not even in the same frame");
    }

    /// @notice Leg 1 can liquidate on an ETH/BTC move while leg 2 is untouched, and the reverse.
    /// @notice On a position the borrower is treating as a single flat ETH/USDC loan.
    function test_TheChainsLegsLiquidateIndependently() public {
        (uint256 idEB, uint256 idBU,) = _route(TEN7, TEN7);
        assertFalse(read.settleable(idEB), "both legs start out of reach of settlement");
        assertFalse(read.settleable(idBU), "on both records");

        recEB.setBelowBand(read.triggerPrice(idEB));
        assertTrue(read.settleable(idEB), "an ETH/BTC decline arms leg 1");
        assertFalse(read.settleable(idBU), "and leg 2 does not notice: a different pair, a different record");

        recEB.setBandPrice(0);
        recBU.setBelowBand(read.triggerPrice(idBU));
        assertTrue(read.settleable(idBU), "a BTC/USDC decline arms leg 2");
        assertFalse(read.settleable(idEB), "and leg 1 does not notice either");
    }

    // ============ 3. the hazard the chain hides ============

    /// @notice THE SHARP EDGE. Leg 2's liquidation transfers the pledged BTC away while BTC is still owed
    /// @notice on leg 1, leaving the borrower NAKED SHORT the middle asset they treated as a pass-through.
    /// @notice Before the liquidation the net BTC position is flat to within the origination fee.
    /// @notice After it, and after pulling everything settlement credits back, the borrower is short outright.
    /// @dev Measured net of `claimOwed`, so the residual equity settlement returns is already counted.
    /// @dev ACE liquidation is a reversible title transfer bounded by tenor, so this is recoverable, not terminal.
    /// @dev It is still real while it stands, and the multicall makes the position a one-transaction build.
    function test_IfTheMiddleLegLiquidates_TheBorrowerIsNakedShortTheMiddleAsset() public {
        (uint256 idEB, uint256 idBU, uint256 btcMid) = _route(TEN7, TEN7);

        uint256 owedBtc = read.debtOf(idEB); // leg 1 is quoted in BTC, so this is a BTC short
        uint256 heldBtc = wbtc.balanceOf(borrower) + pm.collateralOf(idBU);
        assertEq(heldBtc, btcMid, "PREMISE: every BTC the borrower holds is the pledge inside leg 2");
        assertLt(owedBtc - heldBtc, owedBtc / 100, "PREMISE: net BTC is flat to within the origination, a pass-through");

        recBU.setBelowBand(read.triggerPrice(idBU));
        vm.prank(keeper);
        ace.finalize(idBU);
        vm.prank(borrower);
        ace.claimOwed(idBU, borrower); // pull back everything settlement credited, before measuring

        assertEq(pm.collateralOf(idBU), 0, "the pledged BTC left the live ledger with leg 2's title");
        assertTrue(read.loan(idBU).closedAt != 0, "leg 2 is settled");
        assertFalse(read.loan(idEB).closedAt != 0, "leg 1 is untouched and still open");
        assertFalse(read.settleable(idEB), "and perfectly healthy on its own record");
        assertEq(read.debtOf(idEB), owedBtc, "still owing the same BTC it always did");

        uint256 heldAfter = wbtc.balanceOf(borrower) + pm.collateralOf(idBU);
        assertGt(owedBtc, heldAfter, "NAKED SHORT: the borrower owes BTC they no longer hold");
        console2.log("BTC owed on leg 1        ", owedBtc);
        console2.log("BTC still held after      ", heldAfter);
        console2.log("naked short, BTC raw      ", owedBtc - heldAfter);
        assertGt(owedBtc - heldAfter, (owedBtc * 50) / 100, "and the gap is most of the leg-1 debt, not a rounding sliver");
    }

    /// @notice The control: liquidating leg 1 instead leaves NO short, because leg 1's collateral is the ETH.
    /// @notice The hazard is specific to the MIDDLE asset of a chain, which is what makes it easy to miss.
    function test_LiquidatingTheFirstLegLeavesNoShort() public {
        (uint256 idEB, uint256 idBU,) = _route(TEN7, TEN7);

        recEB.setBelowBand(read.triggerPrice(idEB));
        vm.prank(keeper);
        ace.finalize(idEB);

        assertTrue(read.loan(idEB).closedAt != 0, "leg 1 settled: the ETH covered the BTC it owed");
        assertEq(pm.collateralOf(idEB), 0, "its ETH left the live ledger");
        assertGt(pm.retiredOf(idEB), 0, "and went to leg 1's own claimants");
        assertFalse(read.loan(idBU).closedAt != 0, "leg 2 is untouched");
        assertEq(ace.idToMarketParams(read.loan(idBU).market).quote, address(usdc), "and the ONE loan still open is quoted in USDC");
        assertGt(pm.collateralOf(idBU), 0, "so the BTC the borrower still holds now backs no BTC debt at all");
    }
}
