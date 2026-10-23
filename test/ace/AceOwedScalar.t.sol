// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.36;

import {WarpClock} from "../utils/WarpClock.sol";
import {Ace} from "../../src/ace/hub/Ace.sol";
import {MarketParams, OpenBounds} from "../../src/ace/hub/Types.sol";
import {PositionManager} from "../../src/ace/positions/PositionManager.sol";
import {MockERC20} from "../mocks/MockERC20.sol";
import {MockPersistenceRecord} from "../mocks/MockPersistenceRecord.sol";
import {MockStakeVault} from "../mocks/MockStakeVault.sol";
import {AceFixtures} from "../utils/AceFixtures.sol";
import {AceReader} from "../utils/AceReader.sol";

/// @title AceOwedScalar
/// @notice A lender CLAIMS AND IS PAID. No mint stands between a credit and its only possible claimant.
/// @notice THE PROPERTY UNDER TEST IS THE DELETED CRANK, not arithmetic exactness.
/// @dev closed the funded-crank question as unsolvable after three routes failed.
/// @dev Sole tenancy dissolves it instead: with one claimant there is no share to compute, so nothing has
/// @dev to run before a claim can pay. `materialize` is not made cheaper, it stops existing.
/// @dev WHAT THIS DELIBERATELY DOES NOT CLAIM: that it fixes a rounding leak. `AceLens` documents a
/// @dev per-unit residue ("a FURTHER residue no view sees"), but that is a MULTI-LOT defect -- each
/// @dev holder's share floors independently -- and slices 1-2 already made it unreachable. Deleting
/// @dev `qIndex` removes the DIVISION and its divisor-cannot-be-zero argument; it does not recover wei.
/// @dev WRITTEN FAILING-FIRST against a tree that still had `materialize`; it now stands as the REGRESSION
/// @dev that the crank stayed deleted. Both rows would go red the day anything has to run before a payout.
/// @dev THE PAYING DOOR IS `collect`, keyed by (lender, quote) rather than by loan and tick: with one
/// @dev claimant per market and one pool per pair, a per-tick claim had nothing left to distinguish.
/// @dev Reasoning: the design record.
contract AceOwedScalarTest is WarpClock {
    Ace internal ace;
    AceReader internal read;
    PositionManager internal pm;
    MockERC20 internal usdc;
    MockStakeVault internal vault;
    MockPersistenceRecord internal record;
    bytes32 internal id;

    address internal alice = address(0xA11CE); // the market's one lender, and so its only claimant
    address internal borrower = address(0xB0B);

    uint64 internal constant TEN7 = 7 days;
    uint256 internal constant TOP = 500_000e6;
    uint256 internal constant P = 70_000e6;
    uint256 internal constant COLL = 400_000e18;
    uint256 internal T;

    function setUp() public {
        _warpTo(1_000_000);
        usdc = new MockERC20("USD Coin", "USDC", 6);
        vault = new MockStakeVault(42);
        T = AceFixtures.priceAt(address(usdc), address(vault), 0);
        record = new MockPersistenceRecord(address(usdc), address(vault));

        MarketParams memory p = AceFixtures.marketParams(address(usdc), address(vault));
        p.record = address(record);
        p.minTenor = TEN7;
        p.maxTenor = TEN7;
        p.lender = alice;
        AceFixtures.Deployment memory d = AceFixtures.deploy(p);
        (ace, pm, read, id) = (d.ace, d.positionManager, d.read, d.id);

        usdc.mint(alice, TOP);
        vm.startPrank(alice);
        usdc.approve(address(ace), TOP);
        ace.deposit(id, TOP);
        vm.stopPrank();
        usdc.mint(borrower, 1_000_000e6);
    }

    function _open() internal returns (uint256 loanId) {
        vault.mint(borrower, COLL);
        vm.startPrank(borrower);
        vault.approve(address(pm), COLL);
        usdc.approve(address(ace), type(uint256).max);
        loanId = ace.open(id, COLL, P, TEN7, borrower, OpenBounds(0, 0, 0));
        vm.stopPrank();
    }

    /// @notice The lender is paid the draw fee with NO mint first, and the solvency pot empties.
    /// @dev NOT PRANKED, deliberately: `collect` names its own destination, so this test doubles as the
    /// @dev witness that a stranger firing it still pays the lender and nobody else.
    function test_Owed_ClaimPaysWithoutAMintFirst() public {
        _open();
        uint256 credited = read.poolOwed(id);
        assertGt(credited, 0, "fixture: the draw credited the origination fee to the lender");

        uint256 before = usdc.balanceOf(alice);
        vm.prank(alice);
        ace.collect(address(usdc), alice);

        assertEq(usdc.balanceOf(alice) - before, credited, "paid on the claim alone, with no crank in front of it");
        assertEq(read.poolOwed(id), 0, "and the solvency pot empties");
    }

    /// @notice The same across a repay, which credits again on a class that has already paid once.
    /// @dev A second credit is where an index-based residue compounds: each leg floors independently.
    function test_Owed_ASecondCreditIsAlsoWhole() public {
        uint256 loanId = _open();
        vm.prank(alice);
        ace.collect(address(usdc), alice);

        _warpBy(1 days);
        uint256 debt = read.debtOf(loanId);
        uint256 before = usdc.balanceOf(alice);
        vm.startPrank(borrower);
        usdc.approve(address(ace), type(uint256).max);
        ace.repay(loanId, debt);
        vm.stopPrank();

        /// @dev MEASURED AT THE LENDER'S WALLET, because the closing repay is a terminal door and the hub
        /// @dev pushes the pool there rather than leaving it to be collected. The row's claim is unchanged --
        /// @dev a second credit pays out WHOLE -- only the route it travels is.
        uint256 credited = usdc.balanceOf(alice) - before;
        assertGt(credited, 0, "fixture: the repay credited the lender again");
        assertEq(read.poolOwed(id), 0, "nothing accumulates in the pot across legs");
        vm.prank(alice);
        assertEq(ace.collect(address(usdc), alice), 0, "and the recovery door finds nothing left to do");
    }
}
