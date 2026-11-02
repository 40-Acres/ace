// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.36;

import {WarpClock} from "../utils/WarpClock.sol";
import {Ace} from "../../src/ace/hub/Ace.sol";
import {MarketParams, OpenBounds} from "../../src/ace/hub/Types.sol";
import {PositionManager} from "../../src/ace/positions/PositionManager.sol";
import {MockERC20} from "../mocks/MockERC20.sol";
import {MockPersistenceRecord} from "../mocks/MockPersistenceRecord.sol";
import {AceFixtures} from "../utils/AceFixtures.sol";
import {AceReader} from "../utils/AceReader.sol";

/// @title AceWithdrawStatedAmount
/// @notice A lender's withdraw may take every resting atom beside a live loan: nothing holds cash for a continuation.
/// @notice An extension draws none, so emptying the market changes nothing for the loan; at expiry `forceClose` settles it.
/// @dev At the SHIPPED `minPrincipal`, 5,000 USDC.
contract AceWithdrawStatedAmountTest is WarpClock {
    Ace internal ace;
    AceReader internal read;
    PositionManager internal pm;
    MockERC20 internal usdc;
    MockERC20 internal coll;
    bytes32 internal id;

    address internal alice = address(0xA11CE);
    address internal borrower = address(0xB0B);
    address internal keeper = address(0xCAFE);

    uint64 internal constant TEN7 = 7 days;
    uint256 internal constant MIN_PRINCIPAL = 5_000e6;
    uint256 internal constant P = 50_000e6;
    uint256 internal constant UNITS = 100_000e18;
    uint256 internal constant SPARE = 10_000e6; // the cash resting beside the live loan, two floors of it

    uint256 internal loanId;

    function setUp() public {
        _warpTo(1_000_000);
        usdc = new MockERC20("USD Coin", "USDC", 6);
        coll = new MockERC20("Collateral", "COLL", 18);
        MockPersistenceRecord rec = new MockPersistenceRecord(address(usdc), address(coll));
        rec.setMinPrice(AceFixtures.px(1.1e18, address(usdc), address(coll)));
        MarketParams memory p = AceFixtures.marketParams(address(usdc), address(coll));
        p.record = address(rec);
        p.lender = alice;
        p.baseBps = 40;
        p.minTenor = TEN7;
        p.maxTenor = TEN7;
        p.minCoverageWad = 1.4e18;
        p.minPrincipal = MIN_PRINCIPAL;
        AceFixtures.Deployment memory d = AceFixtures.deploy(p);
        (ace, pm, read, id) = (d.ace, d.positionManager, d.read, d.id);

        usdc.mint(alice, 4 * P);
        vm.startPrank(alice);
        usdc.approve(address(ace), type(uint256).max);
        ace.deposit(id, 2 * P);
        vm.stopPrank();
        loanId = _open(borrower, P);
        uint256 trim = ace.restingOf(id) - SPARE;
        vm.prank(alice);
        ace.withdraw(id, trim, alice, 0);
        assertEq(ace.restingOf(id), SPARE, "PREMISE: the spare is exactly what a fresh draw may take");
    }

    function _open(address who, uint256 principal) internal returns (uint256 id_) {
        coll.mint(who, UNITS);
        vm.startPrank(who);
        coll.approve(address(pm), UNITS);
        id_ = ace.open(id, UNITS, principal, TEN7, who, OpenBounds(0, 0, 0));
        vm.stopPrank();
    }

    function _withdraw(uint256 assets, uint256 minPaid) internal returns (uint256) {
        vm.prank(alice);
        return ace.withdraw(id, assets, alice, minPaid);
    }

    function _settledAtExpiry() internal returns (bool) {
        _warpTo(read.loan(loanId).expiry);
        vm.prank(keeper);
        ace.forceClose(loanId);
        return read.invPotOf(id, loanId) != 0;
    }

    /// @notice The max sentinel empties the market beside a live loan, and a third party's `forceClose` at expiry then settles it.
    /// @dev A CuratorVault does exactly this after every call; an extension draws no resting cash, so its loans lose nothing by it.
    function test_TheMaxSentinelEmptiesTheMarketBesideALiveLoanWhichThenSettles() public {
        uint256 resting = ace.restingOf(id);
        assertEq(_withdraw(type(uint256).max, 0), resting, "max takes everything resting");
        assertEq(ace.restingOf(id), 0, "nothing rests beside the live loan");
        assertTrue(_settledAtExpiry(), "and the loan settles at expiry");
    }
}
