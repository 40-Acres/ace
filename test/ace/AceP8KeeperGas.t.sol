// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.36;

import {WarpClock} from "../utils/WarpClock.sol";
import {Ace} from "../../src/ace/hub/Ace.sol";
import {MarketParams, OpenBounds} from "../../src/ace/hub/Types.sol";
import {PositionManager} from "../../src/ace/positions/PositionManager.sol";
import {MockERC20} from "../mocks/MockERC20.sol";
import {MockPersistenceRecord} from "../mocks/MockPersistenceRecord.sol";
import {MockStakeVault} from "../mocks/MockStakeVault.sol";
import {MockDeleverageKeeper} from "../mocks/MockDeleverageKeeper.sol";
import {AceFixtures} from "../utils/AceFixtures.sol";
import {AceReader} from "../utils/AceReader.sol";

/// @title AceP8KeeperGas
/// @notice MEASUREMENT: the execution cost of every cranked verb, so a bounty break-even is arithmetic and not a guess.
/// @dev Gas is read around the call from inside the test, so it excludes the outer transaction's 21k base and calldata.
contract AceP8KeeperGasTest is WarpClock {
    Ace internal ace;
    AceReader internal read;
    PositionManager internal pm;
    MockERC20 internal usdc;
    MockStakeVault internal coll;
    MockPersistenceRecord internal record;
    bytes32 internal id;

    address internal alice = address(0xA11CE);
    address internal borrower = address(0xB0B);
    address internal keeper = address(0xCAFE);

    uint64 internal constant TEN7 = 7 days;
    uint256 internal constant P = 70_000e6;
    uint256 internal constant COLL = 100_000e18;
    uint256 internal constant UNIT_SCALE = 1 << 96;
    uint256 internal T;

    function _price(int24 offset) internal view returns (uint256) {
        return AceFixtures.priceAt(address(usdc), address(coll), offset);
    }

    function _px(uint256 humanWad) internal view returns (uint256) {
        return AceFixtures.px(humanWad, address(usdc), address(coll));
    }

    function setUp() public {
        _warpTo(1_000_000);
        usdc = new MockERC20("USD Coin", "USDC", 6);
        coll = new MockStakeVault(42);
        T = _price(0);
        record = new MockPersistenceRecord(address(usdc), address(coll));
        record.setMinPrice(_px(1.1e18));
        MarketParams memory p = AceFixtures.marketParams(address(usdc), address(coll));
        p.record = address(record);
        p.baseBps = 40;
        p.minTenor = TEN7;
        p.maxTenor = TEN7;
        p.settleBountyBps = 50;
        p.minCoverageWad = 1.4e18;
        p.deleverageBandBps = 3000;
        p.deleverageTargetBps = 4000;
        p.deleverageStopBps = 1;
        p.deleverageFloorEpsBps = 100;
        AceFixtures.Deployment memory d = AceFixtures.deploy(p);
        (ace, pm, read, id) = (d.ace, d.positionManager, d.read, d.id);
        usdc.mint(borrower, 1_000_000e6);
    }

    function _deposit(uint256 amt) internal {
        usdc.mint(alice, amt);
        vm.startPrank(alice);
        usdc.approve(address(ace), amt);
        ace.deposit(id, amt);
        vm.stopPrank();
    }

    function _open(uint256 units, uint256 principal) internal returns (uint256 loanId) {
        coll.mint(borrower, units);
        vm.startPrank(borrower);
        coll.approve(address(pm), units);
        usdc.approve(address(ace), type(uint256).max);
        loanId = ace.open(id, units, principal, TEN7, borrower, OpenBounds(0, 0, 0));
        vm.stopPrank();
    }

    /// @notice One table: the gas each permissionless verb costs its caller, on a one-tick loan.
    function test_G1_KeeperVerbs_GasTable() public {
        _deposit(1_000_000e6);
        uint256 loanId = _open(COLL, P);
        vm.prank(borrower);
        ace.setAutoRefinance(loanId, TEN7, 0, 0);

        uint256 root = vm.snapshotState();
        uint256 g;

        // refinanceByPolicy, inside the window: unpaid
        _warpTo(uint256(read.loan(loanId).expiry) - 1 hours);
        vm.prank(keeper);
        g = gasleft();
        ace.refinanceByPolicy(loanId);
        emit log_named_uint("refinanceByPolicy (roll, unpaid)      gas", g - gasleft());
        vm.revertToState(root);

        // forceClose, roll branch: paid the sliver
        _warpTo(uint256(read.loan(loanId).expiry));
        vm.prank(keeper);
        g = gasleft();
        ace.forceClose(loanId);
        emit log_named_uint("forceClose (roll branch, paid)        gas", g - gasleft());
        vm.revertToState(root);

        // forceClose, settle branch: paid the sliver
        _warpTo(uint256(read.loan(loanId).expiry));
        vm.prank(alice);
        ace.withdraw(id, type(uint256).max, alice, 0);
        vm.prank(keeper);
        g = gasleft();
        ace.forceClose(loanId);
        emit log_named_uint("forceClose (settle branch, paid)      gas", g - gasleft());
        uint256 sliver = read.unitsOwedOf(loanId, keeper);
        emit log_named_decimal_uint("  sliver on that settle, atoms", sliver, 18);
        emit log_named_decimal_uint("  sliver at the record floor (USDC)", (sliver * _px(1.1e18)) / UNIT_SCALE, 6);
        vm.revertToState(root);

        // settleExpired, after the window: unpaid
        _warpTo(uint256(read.loan(loanId).expiry) + 2 hours);
        vm.prank(alice);
        ace.withdraw(id, type(uint256).max, alice, 0);
        vm.prank(keeper);
        g = gasleft();
        ace.settleExpired(loanId);
        emit log_named_uint("settleExpired (unpaid)                gas", g - gasleft());
        vm.revertToState(root);

        // finalize, on persistent distress: paid the sliver
        record.setBelow(true);
        vm.prank(keeper);
        g = gasleft();
        ace.finalize(loanId);
        emit log_named_uint("finalize (paid)                       gas", g - gasleft());
        record.setBelow(false);
        vm.revertToState(root);

        // deleverage, in band: paid eps of the sale
        record.setBandPrice(_px(1.1e18));
        MockDeleverageKeeper k = new MockDeleverageKeeper(ace, address(usdc), address(coll), UNIT_SCALE);
        g = gasleft();
        (uint256 sold, uint256 stable) = k.crankDeleverage(loanId);
        emit log_named_uint("deleverage (paid eps, mock route)     gas", g - gasleft());
        emit log_named_decimal_uint("  keeper margin on that crank (USDC)", (sold * _px(1.1e18)) / UNIT_SCALE - stable, 6);
        vm.revertToState(root);

        // collect, the lender's own collection: unpaid, and now ONE call where it used to be two
        _warpTo(uint256(read.loan(loanId).expiry));
        vm.prank(keeper);
        ace.forceClose(loanId);
        vm.prank(alice);
        g = gasleft();
        ace.collect(address(usdc), alice);
        emit log_named_uint("collect (the lender's own, unpaid)    gas", g - gasleft());
        vm.revertToState(root);

        // collect fired by a STRANGER: lender-only by its ledger key, so it spends the stranger's own empty pool
        _warpTo(uint256(read.loan(loanId).expiry));
        vm.prank(keeper);
        ace.forceClose(loanId);
        vm.prank(keeper);
        g = gasleft();
        ace.collect(address(usdc), keeper);
        emit log_named_uint("collect (stranger's, own empty pool)  gas", g - gasleft());
        vm.revertToState(root);

        // sweepRevenue, standalone: unpaid
        vm.prank(keeper);
        g = gasleft();
        ace.sweepRevenue(id);
        emit log_named_uint("sweepRevenue (unpaid)                 gas", g - gasleft());
    }
}
