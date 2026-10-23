// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.36;

import {Test, Vm} from "forge-std/Test.sol";
import {WarpClock} from "../utils/WarpClock.sol";
import {Ace} from "../../src/ace/hub/Ace.sol";
import {MarketParams, OpenBounds} from "../../src/ace/hub/Types.sol";
import {LoanMath} from "../../src/ace/hub/libraries/LoanMath.sol";
import {PositionManager} from "../../src/ace/positions/PositionManager.sol";
import {MockBlockableStakeVault} from "../mocks/MockBlockableStakeVault.sol";
import {MockERC20} from "../mocks/MockERC20.sol";
import {MockPersistenceRecord} from "../mocks/MockPersistenceRecord.sol";
import {AceFixtures} from "../utils/AceFixtures.sol";
import {AceReader} from "../utils/AceReader.sol";

/// @title AceRefinanceBlockedCollateral
/// @notice The migration hop must not depend on the HUB being an address the collateral will pay.
/// @notice A hub-refusing collateral otherwise bricks every refinance entry AND the continue branch.
/// @dev Continuation is the borrower's only alternative to settlement at expiry, so it must be total.
/// @dev The custody hop is two ledger writes on one pot, so no address is a payer or a payee of it.
contract AceRefinanceBlockedCollateralTest is WarpClock {
    Ace internal ace;
    AceReader internal read;
    PositionManager internal positionManager;
    MockERC20 internal usdc;
    MockBlockableStakeVault internal coll;
    MockPersistenceRecord internal record;
    bytes32 internal id;

    address internal alice = address(0xA11CE);
    address internal borrower = address(0xB0B);
    address internal keeper = address(0xCAFE);

    uint64 internal constant TEN7 = 7 days;
    uint64 internal constant TEN30 = 30 days;
    uint64 internal constant SPACING = 23 days;

    uint256 internal constant P = 70_000e6;
    uint256 internal constant P_CONT = 40_000e6; // leaves the derived continuation principal inside the gate
    uint256 internal constant COLL = 100_000e18;
    uint256 internal constant FLOAT = 1_000_000e6;

    uint256 internal T; // ticks above this pair's par; assigned in setUp, since par is not a compile-time value
    uint256 internal DEEP;
    uint256 internal constant TOP = 400_000e6;
    uint256 internal constant DEEP_CASH = 200_000e6;

    OpenBounds internal OFF = OpenBounds(0, 0, 0);
    uint256 internal t0;

    /// @dev This suite's pair, so a tick reads as its distance from par rather than as a grid coordinate.
    /// @param offset Ticks above par.
    /// @return The absolute grid tick.
    function _price(int24 offset) internal view returns (uint256) {
        return AceFixtures.priceAt(address(usdc), address(coll), offset);
    }

    function setUp() public {
        _warpTo(1_000_000);
        t0 = _now();
        usdc = new MockERC20("USD Coin", "USDC", 6);
        coll = new MockBlockableStakeVault();
        (T, DEEP) = (_price(0), _price(-6000));
        record = new MockPersistenceRecord(address(usdc), address(coll));

        MarketParams memory p = AceFixtures.marketParams(address(usdc), address(coll));
        p.record = address(record);
        p.minTenor = TEN7;
        p.maxTenor = TEN30;

        AceFixtures.Deployment memory d = AceFixtures.deploy(p);
        (ace, positionManager, read, id) = (d.ace, d.positionManager, d.read, d.id);

        _deposit(TOP);
        _deposit(DEEP_CASH);
        usdc.mint(borrower, FLOAT);
    }

    // ---- helpers ----

    function _deposit(uint256 amt) internal {
        usdc.mint(alice, amt);
        vm.startPrank(alice);
        usdc.approve(address(ace), amt);
        ace.deposit(id, amt);
        vm.stopPrank();
    }

    function _open(uint256 principal, uint64 tenor) internal returns (uint256 loanId) {
        coll.mint(borrower, COLL);
        vm.startPrank(borrower);
        coll.approve(address(positionManager), COLL);
        usdc.approve(address(ace), type(uint256).max);
        loanId = ace.open(id, COLL, principal, tenor, borrower, OFF);
        vm.stopPrank();
    }

    /// @dev A roll at an unchanged principal is always short, so it rides the repay-then-refinance composition.
    /// @dev The subject of these rows is COLLATERAL CUSTODY, which the netting shape does not touch.
    function _refiComposed(uint256 oldId) internal returns (uint256) {
        MarketParams memory p = ace.idToMarketParams(id);
        uint256 credit = P - LoanMath.originationFee(P, TEN30, p.baseBps, p.minTenor) + read.earlyExitRefund(oldId);
        uint256 debtOld = read.loan(oldId).debt;
        bytes[] memory calls = new bytes[](2);
        calls[0] = abi.encodeCall(Ace.repay, (oldId, credit >= debtOld ? 0 : debtOld - credit));
        calls[1] = abi.encodeCall(Ace.refinance, (oldId, P, TEN30, OFF));
        vm.prank(borrower);
        return abi.decode(ace.multicall(calls)[1], (uint256));
    }

    // ============ site 7: the hub is the fixed destination of the migration's first leg ============

    /// @notice `refinance` must complete while the collateral refuses the HUB's own address.
    /// @dev The hub takes no title here; it was only ever a waypoint between two vaults.
    function test_Refinance_MustNotRevertWhenTheCollateralRefusesTheHub() public {
        uint256 oldId = _open(P, TEN30);
        _warpTo(t0 + 15 days);
        coll.setBlocked(address(ace), true);

        uint256 newId = _refiComposed(oldId);

        assertTrue(read.loan(oldId).closedAt != 0, "the old loan retires");
        assertEq(read.debtOf(newId), P, "and the successor is live at the requested principal");
    }

    /// @notice The A3 finding restated: a blocked hub must brick neither the debit nor the credit.
    /// @dev The two legs are ledger writes now, so a blocked address cannot be on either of them.
    /// @dev The pot assertion is what proves that: a transfer of any kind would have moved it.
    function test_Refinance_SurvivesAHubBlockedCollateralOnBOTHLegs() public {
        uint256 oldId = _open(P, TEN30);
        _warpTo(t0 + 15 days);
        uint256 potBefore = coll.balanceOf(address(positionManager));
        coll.setBlocked(address(ace), true);

        uint256 newId = _refiComposed(oldId);

        assertEq(coll.balanceOf(address(positionManager)), potBefore, "the carry moved no token at all");
        assertEq(positionManager.collateralOf(newId), COLL, "the custody ledger credits the new id");
        assertEq(positionManager.collateralOf(oldId), 0, "and clears the old one");
    }

    /// @notice The continue branch of the expiry fold must survive it too, on the same leg.
    /// @dev Continuation is the borrower's only alternative to settlement, so a brick here forces a default.
    /// @dev The principal is smaller than `P`: the carry's derived principal must still clear the gate.
    function test_ForceCloseOrContinue_ContinueBranchSurvivesAHubBlockedCollateral() public {
        uint256 oldId = _open(P_CONT, TEN30);
        vm.prank(borrower);
        ace.setAutoRefinance(oldId, TEN30, 0, 0);

        _warpTo(t0 + TEN30 + 1);
        coll.setBlocked(address(ace), true);

        vm.prank(keeper);
        ace.forceClose(oldId);

        assertTrue(read.loan(oldId).closedAt != 0, "the armed loan retires");
        assertGt(read.debtOf(oldId + 1), 0, "into a live continuation rather than a settlement");
    }

    /// @notice With nothing blocked at all, a refinance emits NO collateral transfer whatsoever.
    /// @dev Stronger than the hub-leg count it replaces: zero legs of any kind, not zero hub legs.
    /// @dev A balance comparison alone could not say this, since a round trip nets to the same number.
    function test_RefinanceMovesNoCollateralAtAll_TheHubIncluded() public {
        uint256 oldId = _open(P, TEN30);
        _warpTo(t0 + 15 days);

        vm.recordLogs();
        uint256 newId = _refiComposed(oldId);
        Vm.Log[] memory logs = vm.getRecordedLogs();

        uint256 legs;
        bytes32 sig = keccak256("Transfer(address,address,uint256)");
        for (uint256 i; i < logs.length; i++) {
            if (logs[i].emitter == address(coll) && logs[i].topics[0] == sig) legs++;
        }
        assertEq(legs, 0, "a refinance moves zero collateral, so there is no leg for a blocked address to sit on");
        assertEq(positionManager.collateralOf(newId), COLL, "and the successor carries every unit on the ledger");
    }

    /// @notice The carry needs no allowance at all, so none is granted and none can outlive the call.
    /// @dev The staged approval this replaces was the whole reason a retiring vault could hold one.
    function test_Refinance_GrantsNoCollateralAllowanceAnywhere() public {
        uint256 oldId = _open(P, TEN30);
        _warpTo(t0 + 15 days);

        _refiComposed(oldId);

        assertEq(coll.allowance(address(positionManager), address(positionManager)), 0, "the custodian approves nobody");
        assertEq(coll.allowance(address(ace), address(positionManager)), 0, "and the hub grants the custodian nothing");
    }

    // ============ the settlement branch of the same fold, for contrast ============

    /// @notice An UNARMED expired loan settles, and that path must survive a hub-blocked collateral too.
    /// @dev The hub leg here is `_settle`'s title transfer, which takes no custody after the fix.
    function test_ForceClose_SettleBranchSurvivesAHubBlockedCollateral() public {
        uint256 oldId = _open(P, TEN30);
        _warpTo(t0 + TEN30 + 1);
        coll.setBlocked(address(ace), true);

        vm.prank(keeper);
        ace.forceClose(oldId);
        assertTrue(read.loan(oldId).closedAt != 0, "the must-execute backstop must execute");
    }
}
