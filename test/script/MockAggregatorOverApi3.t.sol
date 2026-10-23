// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.36;

import {WarpClock} from "../utils/WarpClock.sol";
import {OracleRecord} from "../../src/oracle/OracleRecord.sol";
import {PocDeployConfig} from "../../src/config/Defaults.sol";
import {MockERC20} from "../mocks/MockERC20.sol";
import {MockApi3ReaderProxy} from "../mocks/MockApi3ReaderProxy.sol";
import {MockAggregatorOverApi3} from "../mocks/MockAggregatorOverApi3.sol";
import {PriceFrame} from "../utils/PriceFrame.sol";

/// @title MockAggregatorOverApi3
/// @notice The playground twins' feed: a Chainlink-shape round read off the BTC dAPI, one price behind two classes.
/// @dev Driven at every width the constructor admits, because the deploy only ever builds it at eight.
contract MockAggregatorOverApi3Test is WarpClock {
    int224 internal constant BTC = 100_000e18; // the deploy's BTC print, in the dAPI's 18 decimals
    uint256 internal constant BTC_FRAME = uint256(1000) << 96; // $100,000 a cbBTC in the hub frame: 1e11 atoms over 1e8

    MockApi3ReaderProxy internal dapi;
    MockERC20 internal usdc;
    MockERC20 internal cbbtc;

    function setUp() public {
        _warpTo(1_700_000_000); // a real clock: the record gates on staleness
        dapi = new MockApi3ReaderProxy();
        dapi.set(BTC);
        usdc = new MockERC20("USD Coin", "USDC", 6);
        cbbtc = new MockERC20("Coinbase Wrapped BTC", "cbBTC", 8);
    }

    function _feed(uint8 width) internal returns (MockAggregatorOverApi3) {
        return new MockAggregatorOverApi3(address(dapi), width);
    }

    function _answer(uint8 width) internal returns (int256 answer) {
        (, answer,,,) = _feed(width).latestRoundData();
    }

    /// @dev The record the twins read, built over a feed of `width`, exactly as `recordMarkets` builds it at eight.
    function _record(uint8 width) internal returns (OracleRecord) {
        return new OracleRecord(address(_feed(width)), address(usdc), address(cbbtc), PocDeployConfig.ORACLE_MAX_STALENESS);
    }

    function _observed(OracleRecord r) internal view returns (uint256) {
        return r.lastObserved(address(usdc), address(cbbtc));
    }

    // ---- scale and width ----

    /// @notice The dAPI's 18 decimals land in the feed's own, at every width the deploy could pick.
    /// @dev Only eight is ever built on the playground, so a scale hardwired to 1e10 passed everything else.
    function test_ItAnswersTheDapiInItsOwnDecimals() public {
        assertEq(_answer(18), 100_000e18, "eighteen: the dAPI's own frame, untouched");
        assertEq(_answer(8), 100_000e8, "eight: Chainlink's BTC/USD frame");
        assertEq(_answer(6), 100_000e6, "six");
        assertEq(_answer(0), 100_000, "zero: whole dollars");
    }

    /// @notice `decimals` reports the width it was built with, which is what the record divides the answer by.
    function test_DecimalsIsTheConstructorsWidth() public {
        assertEq(_feed(0).decimals(), 0, "zero");
        assertEq(_feed(6).decimals(), 6, "six");
        assertEq(_feed(8).decimals(), 8, "eight");
        assertEq(_feed(18).decimals(), 18, "eighteen");
    }

    /// @notice THE PROPERTY THE TWINS REST ON: a record over any width prices the same $100,000 cbBTC.
    /// @dev An answer and a `decimals` that disagree misprice by the gap, silently, at a plausible-looking number.
    function test_ARecordOverAnyWidthPricesTheSameBtc() public {
        uint8[4] memory widths = [uint8(0), 6, 8, 18];
        for (uint256 i; i < widths.length; i++) {
            OracleRecord r = _record(widths[i]);
            assertEq(_observed(r), BTC_FRAME, "one BTC price whatever the feed's width");
            assertEq(PriceFrame.humanWad(_observed(r), address(usdc), address(cbbtc)), 100_000e18, "which reads $100,000 a coin");
        }
    }

    /// @notice Digits past the width are CUT, never rounded, as a Chainlink feed never reports a digit it lacks.
    function test_DigitsPastTheWidthAreTruncatedNotRounded() public {
        dapi.set(123_456.789012345678901234e18);
        assertEq(_answer(8), 12_345_678_901_234, "eight places kept, the ...5678901234 tail dropped");
        assertEq(_answer(6), 123_456_789_012, "six places kept, the ...345678901234 tail dropped");
        assertEq(_answer(0), 123_456, "whole dollars, the .789 dropped");
        dapi.set(1e10 - 1);
        assertEq(_answer(8), 0, "a print under one feed unit answers zero, not one");
    }

    /// @notice Any non-negative print at any admitted width: the answer is the print FLOORED to that width.
    /// @dev Stated as a bracket around the print, not as the division, so it does not restate the body.
    function testFuzz_TheAnswerIsThePrintFlooredToTheWidth(int224 v, uint8 width) public {
        v = int224(bound(int256(v), 0, int256(type(int224).max)));
        width = uint8(bound(uint256(width), 0, 18));
        dapi.set(v);
        MockAggregatorOverApi3 f = _feed(width);
        (, int256 a,,,) = f.latestRoundData();
        uint256 unit = 10 ** (18 - width);
        uint256 print = uint256(int256(v));
        assertEq(f.decimals(), width, "the width it was built with");
        assertGe(a, 0, "a non-negative print answers non-negative");
        assertLe(uint256(a) * unit, print, "never above the print");
        assertLt(print - uint256(a) * unit, unit, "and under one feed unit below it");
    }

    /// @notice A zero or negative print keeps its sign, so the record over it answers CLOSED rather than a price.
    function test_ANonPositivePrintClosesTheRecord() public {
        OracleRecord r = _record(8);
        dapi.set(0);
        assertEq(_observed(r), 0, "zero is closed");
        dapi.set(-1e18);
        (, int256 a,,,) = MockAggregatorOverApi3(address(r.FEED())).latestRoundData();
        assertEq(a, -1e8, "a negative print answers negative, not its absolute value");
        assertEq(_observed(r), 0, "and closes the record too");
    }

    // ---- the round's stamps ----

    /// @notice ALL FOUR round fields are the dAPI's stamp, not the block's, so an old print reads old.
    /// @dev Stamped three hours back: the block's time in any slot would pass for a fresher round.
    function test_EveryRoundFieldCarriesTheDapisStamp() public {
        uint32 ts = uint32(_now() - 3 hours);
        dapi.setStamped(BTC, ts);
        (uint80 roundId, int256 answer, uint256 startedAt, uint256 updatedAt, uint80 answeredInRound) = _feed(8).latestRoundData();
        assertEq(roundId, ts, "the round id is the stamp");
        assertEq(answer, 100_000e8, "the print, at eight");
        assertEq(startedAt, ts, "the round started at the stamp");
        assertEq(updatedAt, ts, "and was updated at it");
        assertEq(answeredInRound, ts, "answered in the round asked, so the record reads it as complete");
    }

    /// @notice STALENESS FOLLOWS THE DAPI: a print older than the record's bound closes the record over this feed.
    /// @dev The record's bound is inclusive, so a stamp exactly at it still prices and one second more does not.
    function test_ARecordOverItGoesStaleWithTheDapiAndARestampReopensIt() public {
        OracleRecord r = _record(8);
        uint256 bound = PocDeployConfig.ORACLE_MAX_STALENESS;
        dapi.setStamped(BTC, uint32(_now() - bound));
        assertEq(_observed(r), BTC_FRAME, "a stamp exactly at the bound still prices");
        dapi.setStamped(BTC, uint32(_now() - bound - 1));
        assertEq(_observed(r), 0, "one second older closes it");
        dapi.set(BTC);
        assertEq(_observed(r), BTC_FRAME, "and a dAPI re-stamp reopens it, with no write to the feed at all");
    }

    // ---- a sick dAPI, and the constructor's one rail ----

    /// @notice A reverting dAPI reverts the round, never a zero round that reads like an answer.
    function testRevert_ASickDapiRevertsTheRound() public {
        MockAggregatorOverApi3 f = _feed(8);
        dapi.setReverting(true);
        vm.expectRevert(bytes("dapi down"));
        f.latestRoundData();
    }

    /// @notice And the record over it answers CLOSED rather than bubbling the revert, the ORACLE class's posture.
    function test_ARecordOverASickDapiAnswersClosed() public {
        OracleRecord r = _record(8);
        dapi.setReverting(true);
        assertEq(_observed(r), 0, "closed, not reverted");
        dapi.setReverting(false);
        assertEq(_observed(r), BTC_FRAME, "and it prices again the moment the dAPI answers");
    }

    /// @notice The feed reads the dAPI it was built over, which is the whole of the one-write coupling.
    function test_ItReadsTheProxyItWasBuiltOver() public {
        MockApi3ReaderProxy other = new MockApi3ReaderProxy();
        other.set(2.5e18);
        MockAggregatorOverApi3 f = new MockAggregatorOverApi3(address(other), 8);
        (, int256 a,,,) = f.latestRoundData();
        assertEq(address(f.PROXY()), address(other), "the proxy it names");
        assertEq(a, 2.5e8, "and the print it answers is that proxy's, not the BTC dAPI's");
    }

    /// @notice Eighteen is admitted and nineteen refused BY NAME: a dAPI has eighteen, so a feed can only drop digits.
    /// @dev Without the check nineteen still reverts, as an underflow panic that names nothing.
    function testRevert_MoreDecimalsThanTheDapiIsRefusedByName() public {
        assertEq(_feed(18).decimals(), 18, "eighteen, the dAPI's own width, is the ceiling and is admitted");
        vm.expectRevert(bytes("a dAPI answers in 18 decimals, so a feed can only drop digits"));
        new MockAggregatorOverApi3(address(dapi), 19);
    }
}
