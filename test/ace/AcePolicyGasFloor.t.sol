// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.36;

import {PolicyGasShort} from "../../src/ace/hub/Borrower.sol";
import {Loan} from "../../src/ace/hub/Types.sol";
import {ExtendRig} from "../utils/ExtendRig.sol";
import {GasFloorPolicy, YesPolicy} from "../utils/RollPolicyMocks.sol";

/// @title AcePolicyGasFloorTest
/// @notice THE POLICY GAS FLOOR (reviews E-4, D-5): before the roll-policy STATICCALL the hub demands the cap plus EIP-150's 1/64 and a tail.
/// @notice At the least admitting limit a COLD policy still receives the whole cap; one gas under it reverts `PolicyGasShort` and extends nothing.
/// @notice `PolicyGasShort` is only ever a revert: no preview answers it as a refusal reason.
/// @dev Asked of the borrower's cash `extend`, the verb that asks a policy.
/// @dev COLD, AND IN A TRANSACTION SHAPED LIKE THE REAL CALL: each probe names a FRESH policy copy deployed in `setUp`.
/// @dev `setUp` is its own transaction, so a copy's first touch is the hub's own call, and a cold-access charge after the check shows.
/// @dev `vm.cool` is not used: cooling the hub was measured to reset slot origins and under-measure a tail.
/// @dev Reasoning: the design record,, Q6.
contract AcePolicyGasFloorTest is ExtendRig {
    uint256 internal constant ENTRY_COST = 1_000; // the most the policy's own dispatch and decode may spend before it reads gasleft
    uint256 internal constant COPIES = 64; // one cold copy per probe: a search over three million gas takes about twenty-five
    uint8 internal constant SHORT = 1;
    uint8 internal constant EXTENDED = 2;
    uint8 internal constant OTHER = 4;

    GasFloorPolicy[] internal copies;
    uint256 internal next;
    uint256 internal loanId;

    function setUp() public override {
        super.setUp();
        _deposit(id, alice, P + P / 10);
        uint256 threshold = ace.POLICY_GAS() - ENTRY_COST;
        for (uint256 i; i < COPIES; i++) {
            copies.push(new GasFloorPolicy(threshold));
        }
        loanId = _open(P, TEN7, 5000);
        _fund(borrower, 10 * P);
        _warpBy(1 days);
    }

    /// @dev One borrower `extend` at gas `g` against a never-touched policy copy, in a snapshot; the copy index moves BEFORE the snapshot.
    function _outcome(uint256 g) internal returns (uint8 o) {
        address policy = address(copies[next]);
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

    /// @dev The least `extend` gas that is not `PolicyGasShort`, by bisection between a short limit and a generous one.
    function _leastAdmitting() internal returns (uint256 hi) {
        uint256 lo = ace.POLICY_GAS();
        hi = 3_000_000;
        assertEq(_outcome(lo), SHORT, "PREMISE: a call handed only the cap is short of the floor");
        assertEq(_outcome(hi), EXTENDED, "PREMISE: a well-funded extend lands");
        while (hi - lo > 1) {
            uint256 mid = (lo + hi) / 2;
            if (_outcome(mid) == SHORT) lo = mid;
            else hi = mid;
        }
    }

    /// @notice E-4 / D-5: at the least limit the floor admits, the cold policy received the whole cap and consented, so the extension landed.
    function test_AtTheFloorThePolicyReceivesTheWholeCap() public {
        uint256 least = _leastAdmitting();
        assertEq(_outcome(least), EXTENDED, "at the floor the cold policy received the whole cap and consented");
    }

    /// @notice E-4: one gas under that floor reverts `PolicyGasShort`, and the loan does not extend.
    function test_OneUnderTheFloorRevertsPolicyGasShortAndDoesNotExtend() public {
        Loan memory l = read.loan(loanId);
        uint256 least = _leastAdmitting();
        vm.prank(alice);
        ace.setRollPolicy(address(copies[next]));
        vm.prank(borrower);
        try ace.extend{gas: least - 1}(loanId, 0, "") {
            fail("one gas under the floor the extend did not revert");
        } catch (bytes memory err) {
            assertEq(err.length, 4, "a bare selector");
            assertEq(bytes4(err), PolicyGasShort.selector, "the refusal is PolicyGasShort");
        }
        Loan memory l1 = read.loan(loanId);
        assertTrue(ace.isLiveLoan(loanId), "the loan is still live");
        assertEq(l1.expiry, l.expiry, "and did not extend");
        assertEq(l1.collateralUnits, l.collateralUnits, "its lot is whole");
        assertEq(l1.debt, l.debt, "its debt unmoved");
    }

    /// @notice E-4: the preview never answers `PolicyGasShort` as a refusal; a short preview reverts it instead.
    function test_ThePredicateNeverReturnsPolicyGasShort() public {
        _setPolicy(alice, address(new YesPolicy()));
        (bool okWide,,) = ace.tryExtend(loanId, 0, "", borrower);
        assertTrue(okWide, "PREMISE: a well-funded preview consents");
        uint256 shorts;
        for (uint256 g = 100_000; g < 700_000; g += 2_500) {
            try ace.tryExtend{gas: g}(loanId, 0, "", borrower) returns (bool, bytes4 reason, uint256) {
                assertTrue(reason != PolicyGasShort.selector, "a short preview answered PolicyGasShort as a refusal");
            } catch (bytes memory err) {
                if (err.length == 4 && bytes4(err) == PolicyGasShort.selector) shorts++;
            }
        }
        assertGt(shorts, 0, "a short preview reverts PolicyGasShort rather than answering it");
    }
}
