// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.36;

import {PositionManager} from "../../src/ace/positions/PositionManager.sol";
import {MockHookERC20, ITokenReceiveHook} from "../mocks/MockHookERC20.sol";
import {LoanManagerStub} from "../utils/LoanManagerStub.sol";
import {GuardProbeList} from "../utils/GuardProbeList.sol";

/// @title PositionManagerGuardProbe
/// @notice The custodian's OWN lock, re-entered by the one caller its access control admits: its loan manager.
/// @notice `AceUnitGuardProbe` cannot show this: `onlyLoanManager` runs BEFORE `nonReentrant` on every custody verb.
/// @notice An outside caller is refused by name whatever the lock holds, and the hub itself never re-enters its custodian.
/// @dev Here the test stands in as the loan manager, with a collateral that calls it back mid-body.
/// @dev The seam is `release`'s token transfer: the collateral pays the test, and the test re-enters every custody verb.
/// @dev Deleting any ONE of the six modifiers turns the enumeration red, and so does deleting the outer `release`'s.
contract PositionManagerGuardProbeTest is GuardProbeList, LoanManagerStub, ITokenReceiveHook {
    PositionManager internal pm;
    MockHookERC20 internal coll;

    uint256 internal constant LOAN = 7;
    uint256 internal constant OTHER = 8;
    uint256 internal constant HELD = 1_000e18;
    uint256 internal constant GUARDED_CUSTODY_VERBS = 6; // every nonReentrant PositionManager verb

    function setUp() public {
        pm = new PositionManager(address(this));
        coll = new MockHookERC20("Collateral", "COLL", 18);
        _stubLoanConfig(address(coll), address(0xC0FFEE));
        coll.mint(address(this), HELD);
        coll.approve(address(pm), type(uint256).max);
        coll.setHookTarget(address(this)); // fires only on a transfer TO this contract, so the pull below is plain
        pm.pull(LOAN, address(this), HELD);
    }

    /// @dev The collateral's receive hook: the re-entrant probes run here, inside the custodian's guarded body.
    function onTokenReceived(address, uint256) external override {
        _runProbes();
    }

    /// @notice Every custody verb, called by the loan manager itself from inside `release`, refuses as the guard.
    /// @dev Zero amounts throughout: the guard runs before the body, so nothing below has to be a real movement.
    /// @dev An unguarded verb would answer from its body instead: a zero pull or carry goes through, a carry-in refuses by name.
    function test_EveryCustodyVerbRefusesTheLoanManagerMidBody() public {
        _probe("pull", address(pm), abi.encodeCall(PositionManager.pull, (LOAN, address(this), 0)));
        _probe("release", address(pm), abi.encodeCall(PositionManager.release, (LOAN, address(this), 0)));
        _probe("retireCustody", address(pm), abi.encodeCall(PositionManager.retireCustody, (LOAN, 0)));
        _probe("releaseRetired", address(pm), abi.encodeCall(PositionManager.releaseRetired, (LOAN, address(this), 0)));
        _probe("carryOut", address(pm), abi.encodeCall(PositionManager.carryOut, (LOAN, 0)));
        _probe("carryIn", address(pm), abi.encodeCall(PositionManager.carryIn, (OTHER, LOAN, 0)));

        probesArmed = true;
        pm.release(LOAN, address(this), 1);

        _assertEveryProbeTripped(GUARDED_CUSTODY_VERBS);
        assertEq(pm.collateralOf(LOAN), HELD - 1, "the outer release completed, and no probe moved the live ledger");
        assertEq(pm.retiredOf(LOAN), 0, "nor the retired one");
        assertEq(pm.custodiedOf(address(coll)), HELD - 1, "and the pot-level count moved by the outer release alone");
    }

    /// @notice The lock comes off when the guarded body returns: the next custody call in the same transaction lands.
    /// @dev Transient storage outlives a call inside one transaction, so a lock the body failed to clear would refuse this.
    function test_TheCustodianLockClearsWhenTheBodyReturns() public {
        _probe("carryOut", address(pm), abi.encodeCall(PositionManager.carryOut, (LOAN, 0)));
        probesArmed = true;
        pm.release(LOAN, address(this), 1);
        _assertEveryProbeTripped(1);

        pm.release(LOAN, address(this), 1);
        pm.retireCustody(LOAN, 10);
        assertEq(pm.collateralOf(LOAN), HELD - 12, "both follow-up verbs ran with the lock clear");
        assertEq(pm.retiredOf(LOAN), 10, "and the retire landed on the retired ledger");
    }
}
