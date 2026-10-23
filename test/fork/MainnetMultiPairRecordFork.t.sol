// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.36;

import {Test} from "forge-std/Test.sol";
import {Ace} from "../../src/ace/hub/Ace.sol";
import {MarketParams} from "../../src/ace/hub/Types.sol";
import {MultiPairOracleRecord} from "../../src/oracle/MultiPairOracleRecord.sol";
import {OracleRecord} from "../../src/oracle/OracleRecord.sol";
import {PocDeployConfig} from "../../src/config/Defaults.sol";
import {AceFixtures} from "../utils/AceFixtures.sol";
import {PriceFrame} from "../utils/PriceFrame.sol";

/// @title MainnetMultiPairRecordFork
/// @notice One `MultiPairOracleRecord` on a mainnet fork, two REAL Chainlink feeds: cbBTC/USD and ETH/USD, quoted in real USDC.
/// @notice Both pairs read, each equals a single-pair `OracleRecord` on the same feed, and both markets pass genesis against the one address.
/// @dev Skipped cleanly when ALCHEMY_API_KEY is absent, so CI without secrets stays green and honest.
contract MainnetMultiPairRecordForkTest is Test {
    address internal constant USDC = PocDeployConfig.MAINNET_USDC; // 6 decimals
    address internal constant CBBTC = PocDeployConfig.MAINNET_CBBTC; // 8 decimals
    address internal constant WETH = 0xC02aaA39b223FE8D0A0e5C4F27eAD9083C756Cc2; // 18 decimals
    address internal constant CBBTC_USD = PocDeployConfig.CBBTC_USD_FEED; // Chainlink, 8 decimals
    address internal constant ETH_USD = 0x5f4eC3Df9cbd43714FE2740f5E3616155c5b8419; // Chainlink ETH / USD, 8 decimals

    bool internal live;
    MultiPairOracleRecord internal record;

    function setUp() public {
        string memory key = vm.envOr("ALCHEMY_API_KEY", string(""));
        if (bytes(key).length == 0) return; // every test vm.skips on !live
        live = true;
        uint256 blockNum = vm.envOr("ACE_FORK_BLOCK", uint256(25_717_936)); // the yb lifecycle's pin, so the RPC cache is shared
        string memory url = string.concat("https://eth-mainnet.g.alchemy.com/v2/", key);
        if (blockNum == 0) vm.createSelectFork(url);
        else vm.createSelectFork(url, blockNum);

        record = new MultiPairOracleRecord(address(this));
        record.registerPair(USDC, CBBTC, CBBTC_USD, PocDeployConfig.ORACLE_MAX_STALENESS);
        record.registerPair(USDC, WETH, ETH_USD, PocDeployConfig.ORACLE_MAX_STALENESS);
    }

    /// @notice Both real pairs read live off one record, each in its own frame, at prices a person would recognise.
    function test_Fork_OneRecordReadsBothRealFeeds() public {
        if (!live) return vm.skip(true);
        uint256 pb = record.minPrice(USDC, CBBTC);
        uint256 pe = record.minPrice(USDC, WETH);
        assertGt(pb, 0, "cbBTC/USDC reads live");
        assertGt(pe, 0, "WETH/USDC reads live");
        uint256 btcUsd = PriceFrame.humanWad(pb, USDC, CBBTC);
        uint256 ethUsd = PriceFrame.humanWad(pe, USDC, WETH);
        assertGt(btcUsd, 10_000e18, "cbBTC above $10k");
        assertLt(btcUsd, 1_000_000e18, "cbBTC below $1m");
        assertGt(ethUsd, 100e18, "ETH above $100");
        assertLt(ethUsd, 100_000e18, "ETH below $100k");
        assertGt(btcUsd, ethUsd * 5, "the two pairs read two different feeds");
        assertEq(record.lastObserved(USDC, CBBTC), pb, "lastObserved is the same read");
        assertEq(record.lastObserved(USDC, WETH), pe, "on both pairs");
    }

    /// @notice Each real pair equals a single-pair OracleRecord on the same feed: the multi-pair frame is OracleRecord's.
    function test_Fork_EachPairEqualsASinglePairOracleRecord() public {
        if (!live) return vm.skip(true);
        OracleRecord btc = new OracleRecord(CBBTC_USD, USDC, CBBTC, PocDeployConfig.ORACLE_MAX_STALENESS);
        OracleRecord eth = new OracleRecord(ETH_USD, USDC, WETH, PocDeployConfig.ORACLE_MAX_STALENESS);
        assertEq(record.minPrice(USDC, CBBTC), btc.minPrice(USDC, CBBTC), "cbBTC");
        assertEq(record.minPrice(USDC, WETH), eth.minPrice(USDC, WETH), "WETH");
    }

    /// @notice Two markets on two real pairs pass the real genesis against ONE record; the inverse pair is refused twice over.
    function test_Fork_BothMarketsPassGenesisOnOneRecord() public {
        if (!live) return vm.skip(true);
        Ace ace = AceFixtures.newAce();
        MarketParams memory pb = AceFixtures.marketParams(USDC, CBBTC);
        pb.record = address(record);
        MarketParams memory pe = AceFixtures.marketParams(USDC, WETH);
        pe.record = address(record);
        assertEq(ace.idToMarketParams(ace.createMarket(pb)).record, address(record), "the cbBTC market names the record");
        assertEq(ace.idToMarketParams(ace.createMarket(pe)).record, address(record), "and so does the WETH market");

        vm.expectRevert(MultiPairOracleRecord.InversePairExists.selector);
        record.registerPair(WETH, USDC, ETH_USD, PocDeployConfig.ORACLE_MAX_STALENESS);
        MarketParams memory inv = AceFixtures.marketParams(WETH, USDC);
        inv.record = address(record);
        vm.expectRevert("record orientation");
        ace.createMarket(inv);
    }
}
