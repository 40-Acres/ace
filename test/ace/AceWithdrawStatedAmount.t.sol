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
/// @notice A lender's withdraw IGNORES the roll reserve: any amount, stated or the max sentinel, may take reserved cash.
/// @notice Going under the reserve is the lender's consent, so the next armed fold may settle; the hold binds only other draws.
/// @dev At the SHIPPED `minDebt`, 5,000 USDC, where a reservation sits far under the floor.
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
    uint256 internal constant MIN_DEBT = 5_000e6;
    uint256 internal constant P = 50_000e6;
    uint256 internal constant UNITS = 100_000e18;
    uint256 internal constant SPARE = 10_000e6; // the unreserved cash beside the reserve, two floors of it

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
        p.minDebt = MIN_DEBT;
        AceFixtures.Deployment memory d = AceFixtures.deploy(p);
        (ace, pm, read, id) = (d.ace, d.positionManager, d.read, d.id);

        usdc.mint(alice, 4 * P);
        vm.startPrank(alice);
        usdc.approve(address(ace), type(uint256).max);
        ace.deposit(id, 2 * P);
        vm.stopPrank();
        loanId = _openArmed(borrower, P);
        uint256 trim = ace.restingOf(id) - (read.rollReserve(id) + SPARE);
        vm.prank(alice);
        ace.withdraw(id, trim, alice, 0);
        assertEq(ace.drawableOf(id), SPARE, "PREMISE: the spare is exactly what a fresh draw may take");
    }

    function _openArmed(address who, uint256 principal) internal returns (uint256 id_) {
        coll.mint(who, UNITS);
        vm.startPrank(who);
        coll.approve(address(pm), UNITS);
        id_ = ace.open(id, UNITS, principal, TEN7, who, OpenBounds(0, 0, 0));
        ace.setAutoRefinance(id_, TEN7, 0, 0);
        vm.stopPrank();
    }

    function _withdraw(uint256 assets, uint256 minPaid) internal returns (uint256) {
        vm.prank(alice);
        return ace.withdraw(id, assets, alice, minPaid);
    }

    function _foldRolled() internal returns (bool) {
        _warpTo(read.loan(loanId).expiry);
        vm.prank(keeper);
        ace.forceClose(loanId);
        return read.invPotOf(id, loanId) == 0;
    }

    /// @notice THE RULING: a stated amount past the unreserved cash is paid in full, and the next armed fold settles.
    function test_AStatedWithdrawMayGoUnderTheReserveAndTheNextArmedFoldSettles() public {
        uint256 rr = read.rollReserve(id);
        uint256 ask = SPARE + rr / 2; // past the unreserved cash, half into the reserve
        assertEq(_withdraw(ask, ask), ask, "the stated amount is paid in full, reserve or not");
        assertLt(ace.restingOf(id), rr, "so the market now rests under its roll reserve");
        assertFalse(_foldRolled(), "and the armed loan settles at its fold: the lender's withdraw is its consent");
    }

    /// @notice The max sentinel empties the market, reserve included, and the armed fold then settles.
    /// @dev A CuratorVault does exactly this after every call, by its own consent, and holds its rolls' cover in idle instead.
    function test_TheMaxSentinelEmptiesTheMarketReserveIncluded() public {
        uint256 resting = ace.restingOf(id);
        assertEq(_withdraw(type(uint256).max, 0), resting, "max takes everything resting");
        assertEq(ace.restingOf(id), 0, "the reserve went with it");
        assertFalse(_foldRolled(), "and the armed loan settles at its fold");
    }
}
