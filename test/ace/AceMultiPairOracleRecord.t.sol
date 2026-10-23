// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.36;

import {WarpClock} from "../utils/WarpClock.sol";
import {Ace} from "../../src/ace/hub/Ace.sol";
import {Loan, MarketParams, OpenBounds} from "../../src/ace/hub/Types.sol";
import {NoRecordPrice} from "../../src/ace/hub/Borrower.sol";
import {NotSettleable} from "../../src/ace/hub/Settlement.sol";
import {PositionManager} from "../../src/ace/positions/PositionManager.sol";
import {MultiPairOracleRecord} from "../../src/oracle/MultiPairOracleRecord.sol";
import {MockAggregatorV3} from "../mocks/MockAggregatorV3.sol";
import {MockERC20} from "../mocks/MockERC20.sol";
import {AceFixtures} from "../utils/AceFixtures.sol";
import {AceReader} from "../utils/AceReader.sol";

/// @title AceMultiPairOracleRecord
/// @notice `AceMultiPairRecord`'s capability, on the PRODUCTION record through the real `createMarket`: one address, three pairs.
/// @notice The three pairs carry three decimal gaps (+12, +2, -12), each framed per pair into the one Q96 frame every market shares.
/// @notice Distress and settlement on one pair leave the other two byte-identical; feed death on one leaves the others lending.
/// @notice An inverse pair's market and an unregistered pair's market are refused at genesis, by its own message.
contract AceMultiPairOracleRecordTest is WarpClock {
    Ace internal ace;
    AceReader internal read;
    PositionManager internal positionManager;
    MultiPairOracleRecord internal record;
    MockERC20 internal usdc; // 6
    MockERC20 internal weth; // 18
    MockERC20 internal cbbtc; // 8
    MockERC20 internal dai; // 18, the quote of the negative-gap market
    MockAggregatorV3 internal ethUsd;
    MockAggregatorV3 internal btcUsd;
    MockAggregatorV3 internal usdcDai;
    bytes32 internal idA; // USDC per WETH
    bytes32 internal idB; // USDC per cbBTC
    bytes32 internal idC; // DAI per USDC

    address internal alice = AceFixtures.LENDER;
    address internal borrower = address(0xB0B);

    uint256 internal constant STALENESS = 25 hours;

    function setUp() public {
        _warpTo(365 days);
        usdc = new MockERC20("USD Coin", "USDC", 6);
        weth = new MockERC20("Wrapped Ether", "WETH", 18);
        cbbtc = new MockERC20("Coinbase BTC", "cbBTC", 8);
        dai = new MockERC20("Dai", "DAI", 18);
        ethUsd = new MockAggregatorV3(8);
        btcUsd = new MockAggregatorV3(8);
        usdcDai = new MockAggregatorV3(18);
        ethUsd.push(2000e8);
        btcUsd.push(60_000e8);
        usdcDai.push(1e18);

        record = new MultiPairOracleRecord(address(this));
        _registerAll(record);
        (ace, positionManager) = AceFixtures.newAceWithEscrow(AceFixtures.TREASURY);
        read = new AceReader(address(ace));

        idA = ace.createMarket(_params(record, usdc, weth, 1500e18));
        idB = ace.createMarket(_params(record, usdc, cbbtc, 50_000e18));
        idC = ace.createMarket(_params(record, dai, usdc, 0.9e18));
        _deposit(idA, usdc, 15_000e6);
        _deposit(idB, usdc, 15_000e6);
        _deposit(idC, dai, 15_000e18);
    }

    function _registerAll(MultiPairOracleRecord r) internal {
        r.registerPair(address(usdc), address(weth), address(ethUsd), STALENESS);
        r.registerPair(address(usdc), address(cbbtc), address(btcUsd), STALENESS);
        r.registerPair(address(dai), address(usdc), address(usdcDai), STALENESS);
    }

    /// @dev The fixture market on `q`/`c`, bidding `humanWad` quote per whole collateral, naming `r`.
    function _params(MultiPairOracleRecord r, MockERC20 q, MockERC20 c, uint256 humanWad) internal view returns (MarketParams memory p) {
        p = AceFixtures.marketParams(address(q), address(c));
        p.price = AceFixtures.px(humanWad, address(q), address(c));
        p.record = address(r);
    }

    function _deposit(bytes32 id, MockERC20 q, uint256 amt) internal {
        q.mint(alice, amt);
        vm.startPrank(alice);
        q.approve(address(ace), amt);
        ace.deposit(id, amt);
        vm.stopPrank();
    }

    function _open(bytes32 id, MockERC20 c, uint256 units, uint256 principal) internal returns (uint256 loanId) {
        c.mint(borrower, units);
        vm.startPrank(borrower);
        c.approve(address(positionManager), units);
        loanId = ace.open(id, units, principal, 0, borrower, OpenBounds(0, 0, 0));
        vm.stopPrank();
    }

    /// @dev Three loans, one per market, each well inside its own coverage line at its own price.
    function _openAll() internal returns (uint256 a, uint256 b, uint256 c) {
        a = _open(idA, weth, 10e18, 4_500e6); // $15k of ETH at the bid
        b = _open(idB, cbbtc, 0.2e8, 4_500e6); // $10k of cbBTC
        c = _open(idC, usdc, 10_000e6, 4_500e18); // 9k DAI of USDC
    }

    /// @dev Everything one market shows: its loan, its resting cash, its state words and what the record says about its pair.
    function _snapshot(bytes32 id, uint256 loanId) internal view returns (bytes memory) {
        MarketParams memory p = ace.idToMarketParams(id);
        uint256 trig = read.triggerPrice(loanId);
        return abi.encode(
            read.loan(loanId),
            read.restingOf(id),
            read.marketState(id),
            record.minPrice(p.quote, p.collateral),
            record.persistedBelowDistress(p.quote, p.collateral, trig),
            read.inDistress(loanId)
        );
    }

    // ============ genesis: one record, three pairs, three gaps ============

    function test_Genesis_ThreePairsWithThreeGapsShareOneRecord() public view {
        bytes32[3] memory ids = [idA, idB, idC];
        for (uint256 i; i < 3; i++) {
            assertEq(ace.idToMarketParams(ids[i]).record, address(record), "every market names the one record");
            assertEq(read.marketState(ids[i]).unitScale, uint256(1) << 96, "and the one frame");
        }
        assertEq(record.minPrice(address(usdc), address(weth)), AceFixtures.px(2000e18, address(usdc), address(weth)), "gap +12 framed");
        assertEq(record.minPrice(address(usdc), address(cbbtc)), AceFixtures.px(60_000e18, address(usdc), address(cbbtc)), "gap +2 framed");
        assertEq(record.minPrice(address(dai), address(usdc)), AceFixtures.px(1e18, address(dai), address(usdc)), "gap -12 framed");
    }

    /// @notice Each market draws against its own pair's price: the three opens land where their own coverage puts them.
    function test_EachMarketDrawsOffItsOwnPair() public {
        (uint256 a, uint256 b, uint256 c) = _openAll();
        assertEq(read.loan(a).market, idA, "A");
        assertEq(read.loan(b).market, idB, "B");
        assertEq(read.loan(c).market, idC, "C");
        assertFalse(read.inDistress(a) || read.inDistress(b) || read.inDistress(c), "all healthy at the feeds' prices");
    }

    // ============ the load-bearing case ============

    function test_SharedRecord_DistressOnPairA_LeavesBAndCByteIdentical() public {
        (uint256 a, uint256 b, uint256 c) = _openAll();
        bytes memory beforeB = _snapshot(idB, b);
        bytes memory beforeC = _snapshot(idC, c);

        ethUsd.push(500e8); // only ETH crashes: A's trigger is ~630 USDC per ETH
        assertTrue(read.inDistress(a), "pair A's loan is distressed");
        assertTrue(read.settleable(a), "and settleable: the oracle class holds no window");
        assertFalse(read.inDistress(b), "pair B untouched by A's print");
        assertFalse(read.inDistress(c), "pair C untouched by A's print");
        vm.expectRevert(NotSettleable.selector);
        ace.finalize(b);
        vm.expectRevert(NotSettleable.selector);
        ace.finalize(c);

        ace.finalize(a);
        assertTrue(read.loan(a).closedAt != 0, "pair A's title moved");
        assertEq(_snapshot(idB, b), beforeB, "market B is byte-identical through A's settlement");
        assertEq(_snapshot(idC, c), beforeC, "market C is byte-identical through A's settlement");
    }

    /// @notice A dead feed on one pair fails that pair closed; the others keep lending, and A still settles at maturity.
    function test_FeedDeathOnPairA_FailsClosed_OthersLend_MaturityStillSettles() public {
        uint256 a = _open(idA, weth, 10e18, 4_500e6);
        ethUsd.setReverting(true);

        assertFalse(read.inDistress(a), "a dead feed proves nothing: no distress");
        vm.expectRevert(NotSettleable.selector);
        ace.finalize(a);
        weth.mint(borrower, 10e18);
        vm.startPrank(borrower);
        weth.approve(address(positionManager), 10e18);
        vm.expectRevert(NoRecordPrice.selector);
        ace.open(idA, 10e18, 4_500e6, 0, borrower, OpenBounds(0, 0, 0));
        vm.stopPrank();

        uint256 b = _open(idB, cbbtc, 0.2e8, 4_500e6);
        uint256 c = _open(idC, usdc, 10_000e6, 4_500e18);
        assertEq(read.loan(b).debt, 4_500e6, "pair B lends through A's outage");
        assertEq(read.loan(c).debt, 4_500e18, "pair C too");

        Loan memory l = read.loan(a);
        _warpTo(uint256(l.expiry) + 1);
        ace.forceClose(a); // maturity reads no price: tenor bounds the outage
        assertTrue(read.loan(a).closedAt != 0, "expiry settles regardless of the record");
    }

    // ============ genesis refusals ============

    /// @notice The inverse pair's market is refused, and the record refuses to register the inverse, so no order admits it.
    function test_Genesis_RefusesTheInversePair() public {
        MarketParams memory p = _params(record, weth, usdc, 0.0005e18);
        vm.expectRevert("record orientation");
        ace.createMarket(p);

        vm.expectRevert(MultiPairOracleRecord.InversePairExists.selector);
        record.registerPair(address(weth), address(usdc), address(ethUsd), STALENESS);
        vm.expectRevert("record orientation");
        ace.createMarket(p);
    }

    /// @notice An unregistered pair's market reverts as genesis does; the same params pass once the owner registers the pair.
    function test_Genesis_RefusesAnUnregisteredPair_UntilRegistered() public {
        MockERC20 wsteth = new MockERC20("Wrapped stETH", "wstETH", 18);
        MarketParams memory p = _params(record, usdc, wsteth, 2000e18);
        vm.expectRevert("record orientation");
        ace.createMarket(p);

        record.registerPair(address(usdc), address(wsteth), address(ethUsd), STALENESS);
        assertEq(ace.idToMarketParams(ace.createMarket(p)).record, address(record), "registered on the record: admitted");
    }

    /// @notice Creation never depends on feed uptime: a registered pair on a dead feed passes genesis and then refuses every draw.
    function test_Genesis_ASickPairPasses_AndRefusesTheDraw() public {
        MockERC20 wsteth = new MockERC20("Wrapped stETH", "wstETH", 18);
        MockAggregatorV3 dead = new MockAggregatorV3(8);
        dead.setReverting(true);
        record.registerPair(address(usdc), address(wsteth), address(dead), STALENESS);
        bytes32 id = ace.createMarket(_params(record, usdc, wsteth, 2000e18));
        _deposit(id, usdc, 15_000e6);

        wsteth.mint(borrower, 10e18);
        vm.startPrank(borrower);
        wsteth.approve(address(positionManager), 10e18);
        vm.expectRevert(NoRecordPrice.selector);
        ace.open(id, 10e18, 4_500e6, 0, borrower, OpenBounds(0, 0, 0));
        vm.stopPrank();
    }
}
