// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.36;

import {Test} from "forge-std/Test.sol";
import {IPersistenceRecord} from "../../src/interfaces/IPersistenceRecord.sol";
import {OracleRecord} from "../../src/oracle/OracleRecord.sol";
import {MultiPairOracleRecord} from "../../src/oracle/MultiPairOracleRecord.sol";
import {Api3OracleRecord} from "../../src/oracle/Api3OracleRecord.sol";
import {HUB_POLICY_GAS} from "../../src/config/Defaults.sol";
import {MockAggregatorV3} from "../mocks/MockAggregatorV3.sol";
import {MockApi3ReaderProxy} from "../mocks/MockApi3ReaderProxy.sol";
import {MockERC20} from "../mocks/MockERC20.sol";

/// @title RecordAskBudget
/// @notice A band-on settlement reads `minPrice` under the hub's policy budget; every in-tree oracle record answers in under half of it.
/// @dev Measured cold here with `vm.cool` on the record and its feed, which UNDER-measures a real isolated transaction: the fork figure is owed.
/// @dev `PawnAppraisalRecord` prices only inside its shop's call and backs bullet markets, never read at settlement; `NftAccountRecord` is owed on a fork.
contract RecordAskBudgetTest is Test {
    MockERC20 internal usdc;
    MockERC20 internal weth;

    function setUp() public {
        vm.warp(365 days);
        usdc = new MockERC20("USD Coin", "USDC", 6);
        weth = new MockERC20("Wrapped Ether", "WETH", 18);
    }

    /// @dev The gas one cold `minPrice` takes, `feed` cooled with the record; asserts it answered a live price.
    function _cold(address record, address feed) internal returns (uint256 used) {
        vm.cool(record);
        vm.cool(feed);
        bytes memory data = abi.encodeCall(IPersistenceRecord.minPrice, (address(usdc), address(weth)));
        uint256 g = gasleft();
        (bool ok, bytes memory ret) = record.staticcall(data);
        used = g - gasleft();
        assertTrue(ok && abi.decode(ret, (uint256)) != 0, "PREMISE: the record answered a live price");
    }

    function _assertUnderHalf(string memory name, uint256 used) internal {
        emit log_named_uint(string.concat(name, ": cold minPrice gas"), used);
        assertLt(used, HUB_POLICY_GAS / 2, string.concat(name, ": minPrice is not under half the hub's policy budget"));
    }

    function test_OracleRecord_MinPriceIsUnderHalfTheBudget() public {
        MockAggregatorV3 feed = new MockAggregatorV3(8);
        feed.push(2000e8);
        OracleRecord r = new OracleRecord(address(feed), address(usdc), address(weth), 1 hours);
        _assertUnderHalf("OracleRecord", _cold(address(r), address(feed)));
    }

    function test_MultiPairOracleRecord_MinPriceIsUnderHalfTheBudget() public {
        MockAggregatorV3 feed = new MockAggregatorV3(8);
        feed.push(2000e8);
        MultiPairOracleRecord r = new MultiPairOracleRecord(address(this));
        r.registerPair(address(usdc), address(weth), address(feed), 1 hours);
        _assertUnderHalf("MultiPairOracleRecord", _cold(address(r), address(feed)));
    }

    function test_Api3OracleRecord_MinPriceIsUnderHalfTheBudget() public {
        MockApi3ReaderProxy dapi = new MockApi3ReaderProxy();
        dapi.set(2000e18);
        Api3OracleRecord r = new Api3OracleRecord(address(dapi), address(usdc), address(weth), 1 hours);
        _assertUnderHalf("Api3OracleRecord", _cold(address(r), address(dapi)));
    }
}
