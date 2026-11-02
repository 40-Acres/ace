// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.36;

import {PolicyGasShort} from "../../src/ace/hub/Borrower.sol";
import {Extension, IRollPolicy} from "../../src/interfaces/IRollPolicy.sol";
import {ExtendRig} from "../utils/ExtendRig.sol";
import {GasFloorPolicy, POLICY_YES} from "../utils/RollPolicyMocks.sol";

// the three fold rows of AceExtendMutationKillsTest went with the fold; the policy-gas tail row stays below

/// @title AcePolicyGasTailTest
/// @notice At the least `extend` limit the gas floor admits, a COLD policy receives the ENTIRE cap, to the gas, not merely most of it.
/// @notice The tail is what buys that: it covers the gas between the floor check and the STATICCALL, so the 63/64 forward still reaches the cap.
/// @dev The policy's own entry cost is MEASURED in setUp by handing copies exactly the cap, so the strict threshold holds on either build profile.
/// @dev Kills `Probe.askBool` dropping `POLICY_TAIL`, which `AcePolicyGasFloor`'s 1_000-gas entry tolerance cannot see.
contract AcePolicyGasTailTest is ExtendRig {
    uint256 internal constant COPIES = 64; // one cold copy per probe, as `AcePolicyGasFloor` does
    uint8 internal constant SHORT = 1;
    uint8 internal constant EXTENDED = 2;
    uint8 internal constant OTHER = 4;

    GasFloorPolicy[] internal strict;
    uint256 internal next;
    uint256 internal loanId;
    uint256 internal entryCost;

    function setUp() public override {
        super.setUp();
        _deposit(id, alice, P + P / 10);
        uint256 cap = ace.POLICY_GAS();
        entryCost = _entryCost(cap);
        for (uint256 i; i < COPIES; i++) {
            strict.push(new GasFloorPolicy(cap - entryCost));
        }
        loanId = _open(P, TEN7, 5000);
        _fund(borrower, 10 * P);
        _warpBy(1 days);
    }

    /// @dev The gas a `GasFloorPolicy` spends from entry to its `gasleft()` read: the largest threshold a copy handed exactly `cap` still meets.
    function _entryCost(uint256 cap) internal returns (uint256) {
        Extension memory e;
        bytes memory ask = abi.encodeCall(IRollPolicy.admitsExtension, (e, ""));
        uint256 lo = cap - 5_000;
        uint256 hi = cap;
        while (hi - lo > 1) {
            uint256 mid = (lo + hi) / 2;
            (bool ok, bytes memory ret) = address(new GasFloorPolicy(mid)).staticcall{gas: cap}(ask);
            if (ok && ret.length == 32 && bytes4(ret) == POLICY_YES) lo = mid;
            else hi = mid;
        }
        return cap - lo;
    }

    /// @dev One borrower `extend` at gas `g` against a never-touched strict copy, in a snapshot.
    function _outcome(uint256 g) internal returns (uint8 o) {
        address policy = address(strict[next]);
        next++;
        uint256 snap = vm.snapshotState();
        vm.prank(alice);
        ace.setRollPolicy(policy);
        vm.prank(borrower);
        try ace.extend{gas: g}(loanId, 0, "") {
            o = EXTENDED;
        } catch (bytes memory err) {
            o = err.length == 4 && bytes4(err) == PolicyGasShort.selector ? SHORT : OTHER;
        }
        vm.revertToStateAndDelete(snap);
    }

    /// @notice At the least admitting `extend` limit, the strict policy, which consents only to the whole cap, consents: the loan extends.
    function test_AtTheFloorThePolicyReceivesTheCapToTheGas() public {
        assertGt(entryCost, 0, "PREMISE: the policy's entry cost was measured");
        assertLt(entryCost, 5_000, "PREMISE: measured inside the bisection's window, not clamped to its floor");
        uint256 lo = ace.POLICY_GAS();
        uint256 hi = 3_000_000;
        assertEq(_outcome(lo), SHORT, "PREMISE: a call handed only the cap is short of the floor");
        assertEq(_outcome(hi), EXTENDED, "PREMISE: a well-funded extend hands the strict policy its whole cap");
        while (hi - lo > 1) {
            uint256 mid = (lo + hi) / 2;
            if (_outcome(mid) == SHORT) lo = mid;
            else hi = mid;
        }
        assertEq(_outcome(hi), EXTENDED, "at the least admitting limit the policy received the cap to the gas and consented");
    }
}
