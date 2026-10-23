// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.36;

import {LaunchFixture, LaunchMarketParams} from "./LaunchFixture.sol";
import {MarketParams} from "../../src/ace/hub/Types.sol";
import {NoInventoryAsk} from "../../src/ace/hub/Ace.sol";
import {DeleverageDisabled} from "../../src/ace/hub/Deleverage.sol";
import {NoRecord, NotExpired, RollWindowOpen} from "../../src/ace/hub/Settlement.sol";
import {LockAccount} from "../../src/entities/launch/LockAccount.sol";
import {MockERC20} from "../mocks/MockERC20.sol";
import {MockPersistenceRecord} from "../mocks/MockPersistenceRecord.sol";

/// @title LockAccountMarkets
/// @notice B2: the market predicate refuses every market but a recordless, band-off market on the launch token.
/// @notice B3: on the market it does accept, no hub verb moves a pledged unit before expiry, whatever the price did.
contract LockAccountMarketsTest is LaunchFixture {
    // ---- B2: refused markets ----

    /// @notice A market with a record is refused: a recorded default returns the residual and has early seizure.
    function test_B2_RecordMarketRefused() public {
        MarketParams memory p = LaunchMarketParams.launchParams(_ctx(address(usdc), alt));
        p.record = address(new MockPersistenceRecord(address(usdc), address(token)));
        bytes32 recorded = ace.createMarket(p);
        vm.prank(alice);
        vm.expectRevert(LockAccount.NotALaunchMarket.selector);
        acct.borrow(recorded, 1_000e18, _maxPrincipal(1_000e18), WEEK, _noBounds());
    }

    /// @notice A market on another collateral is refused, even recordless: the lock pledges its own token or nothing.
    function test_B2_WrongCollateralRefused() public {
        MockERC20 other = new MockERC20("Other", "OTH", 18);
        LaunchMarketParams.Ctx memory c = _ctx(address(usdc), alt);
        c.token = address(other);
        bytes32 foreign = ace.createMarket(LaunchMarketParams.launchParams(c));
        vm.prank(alice);
        vm.expectRevert(LockAccount.NotALaunchMarket.selector);
        acct.borrow(foreign, 1_000e18, _maxPrincipal(1_000e18), WEEK, _noBounds());
    }

    /// @notice A band-on market is refused. Genesis forces a record on any band, so the no-record test is what refuses it.
    /// @dev There is no separate band test to reach: a recordless market with a band does not pass genesis.
    function test_B2_BandMarketRefused() public {
        MarketParams memory p = LaunchMarketParams.launchParams(_ctx(address(usdc), alt));
        p.record = address(new MockPersistenceRecord(address(usdc), address(token)));
        p.deleverageBandBps = 3000;
        p.deleverageTargetBps = 4000;
        p.deleverageStopBps = 1000;
        p.deleverageFloorEpsBps = 50;
        bytes32 banded = ace.createMarket(p);
        vm.prank(alice);
        vm.expectRevert(LockAccount.NotALaunchMarket.selector);
        acct.borrow(banded, 1_000e18, _maxPrincipal(1_000e18), WEEK, _noBounds());
    }

    /// @notice The genesis rail the band check leans on: a recordless market cannot carry a band at all.
    function test_B2_RecordlessBandIsUncreatable() public {
        MarketParams memory p = LaunchMarketParams.launchParams(_ctx(address(usdc), alt));
        p.deleverageBandBps = 3000;
        p.deleverageTargetBps = 4000;
        p.deleverageStopBps = 1000;
        p.deleverageFloorEpsBps = 50;
        vm.expectRevert(bytes("record required"));
        ace.createMarket(p);
    }

    /// @notice An id no market sits at is refused before the hub is asked to open anything.
    function test_B2_UnknownMarketRefused() public {
        vm.prank(alice);
        vm.expectRevert(LockAccount.NotALaunchMarket.selector);
        acct.borrow(keccak256("no such market"), 1_000e18, _maxPrincipal(1_000e18), WEEK, _noBounds());
    }

    // ---- B3: nothing leaves custody before expiry ----

    /// @notice Every hub verb that could move a pledged unit refuses before expiry, and the units stay put.
    function test_B3_NothingLeavesCustodyBeforeExpiry() public {
        uint256 u = 2_000e18;
        uint256 loanId = _borrow(u, _maxPrincipal(u), WEEK);
        _tryEverything(loanId, u);
        _warpTo(read.loan(loanId).expiry - 1);
        _tryEverything(loanId, u);
    }

    /// @notice `finalize` is closed for good on a recordless market: there is no distress to persist.
    function test_B3_FinalizeIsNoRecord() public {
        uint256 u = 1_000e18;
        uint256 loanId = _borrow(u, _maxPrincipal(u), WEEK);
        _warpTo(read.loan(loanId).expiry + 365 days);
        vm.expectRevert(NoRecord.selector);
        ace.finalize(loanId);
    }

    function _tryEverything(uint256 loanId, uint256 u) internal {
        vm.startPrank(alt);
        vm.expectRevert(NoRecord.selector);
        ace.finalize(loanId);
        vm.expectRevert(NotExpired.selector);
        ace.forceClose(loanId);
        vm.expectRevert(RollWindowOpen.selector);
        ace.settleExpired(loanId);
        vm.expectRevert(DeleverageDisabled.selector);
        ace.deleverage(loanId, 0, "");
        vm.expectRevert(NoInventoryAsk.selector);
        ace.buyInventory(loanId, 1e6, 0, alt);
        vm.stopPrank();
        assertEq(read.loan(loanId).collateralUnits, u, "the loan's units moved");
        assertEq(pm.collateralOf(loanId), u, "custody moved");
        assertEq(token.balanceOf(alt), 0, "a unit reached the lender");
        assertFalse(ace.isClosed(loanId), "the loan closed");
    }
}
