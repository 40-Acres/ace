// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.36;

import {InsufficientCash, PolicyGasShort, PolicyRefused} from "../../src/ace/hub/Borrower.sol";
import {Loan, MigrateArgs, OpenBounds} from "../../src/ace/hub/Types.sol";
import {Extension, IRollPolicy} from "../../src/interfaces/IRollPolicy.sol";
import {ExtendRig} from "../utils/ExtendRig.sol";
import {GasFloorPolicy, YesPolicy} from "../utils/RollPolicyMocks.sol";

/// @notice A fixed, data-blind check that costs most of a hundred thousand gas and answers no.
contract CostlyNoCheck {
    function costlyNo() external pure returns (bool) {
        uint256 h;
        for (uint256 i; i < 1000; i++) {
            assembly ("memory-safe") {
                mstore(0, h)
                mstore(32, i)
                h := keccak256(0, 64)
            }
        }
        return h == 0;
    }
}

/// @notice A FAIL-OPEN policy, the shape `IRollPolicy` forbids: it answers yes whenever its inner check fails, out of gas included.
/// @dev Its work is bounded and blind to `data`, so the hub's floor alone decides whether its inner check can be starved.
contract FailOpenPolicy is IRollPolicy {
    CostlyNoCheck internal immutable INNER;

    constructor() {
        INNER = new CostlyNoCheck();
    }

    function admitsExtension(Extension calldata, bytes calldata) external view returns (bytes4) {
        try INNER.costlyNo() returns (bool yes) {
            return yes ? IRollPolicy.admitsExtension.selector : bytes4(0);
        } catch {
            return IRollPolicy.admitsExtension.selector;
        }
    }
}

/// @notice Consents only when handed at most `CEILING` gas, so a hub forwarding more than its cap reads as a no.
contract GasCeilingPolicy is IRollPolicy {
    uint256 public immutable CEILING; // the most `gasleft()` at entry may read for a yes

    constructor(uint256 ceiling) {
        CEILING = ceiling;
    }

    function admitsExtension(Extension calldata, bytes calldata) external view returns (bytes4) {
        return gasleft() <= CEILING ? IRollPolicy.admitsExtension.selector : bytes4(0);
    }
}

/// @title AcePolicyGasFloorExtendTest
/// @notice THE POLICY GAS FLOOR ON THE TWO ASKS LEFT: a caller's `extend` and an own-market `refinanceTo`'s claim-reuse ask.
/// @notice Before the STATICCALL the hub demands the cap plus EIP-150's 1/64 and a tail, so a short limit reverts `PolicyGasShort`.
/// @notice So a policy's answer is a function of state, never of the caller's gas: a fail-open policy cannot be sold a yes.
/// @dev COLD: each probe names a FRESH policy copy deployed in `setUp`, as the fold-era floor suite did.
/// @dev Reasoning: the design record Q6, R-5.
contract AcePolicyGasFloorExtendTest is ExtendRig {
    uint256 internal constant ENTRY_COST = 1_000; // the most the policy's own dispatch and decode may spend before it reads gasleft
    uint256 internal constant COPIES = 96; // one cold copy per probe: two bisections over three million gas take about fifty
    uint8 internal constant SHORT = 1;
    uint8 internal constant LANDED = 2;
    uint8 internal constant REFUSED = 3;
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

    /* ============================== extend ============================== */

    /// @dev One `extend` at gas `g` against `policy`, in a snapshot.
    function _extendOutcome(address policy, uint256 g, bytes memory data) internal returns (uint8 o) {
        uint256 snap = vm.snapshotState();
        _setPolicy(alice, policy);
        vm.prank(borrower);
        try ace.extend{gas: g}(loanId, 0, data) {
            o = LANDED;
        } catch (bytes memory err) {
            o = _classify(err, PolicyRefused.selector);
        }
        vm.revertToStateAndDelete(snap);
    }

    function _classify(bytes memory err, bytes4 refusal) internal pure returns (uint8) {
        if (err.length != 4) return OTHER;
        if (bytes4(err) == PolicyGasShort.selector) return SHORT;
        return bytes4(err) == refusal ? REFUSED : OTHER;
    }

    /// @dev The least `extend` gas that is not `PolicyGasShort`, by bisection over fresh cold copies.
    function _leastExtending() internal returns (uint256 hi) {
        uint256 lo = ace.POLICY_GAS();
        hi = 3_000_000;
        assertEq(_extendOutcome(address(copies[next++]), lo, ""), SHORT, "PREMISE: a call handed only the cap is short of the floor");
        assertEq(_extendOutcome(address(copies[next++]), hi, ""), LANDED, "PREMISE: a well-funded extend lands");
        while (hi - lo > 1) {
            uint256 mid = (lo + hi) / 2;
            if (_extendOutcome(address(copies[next++]), mid, "") == SHORT) lo = mid;
            else hi = mid;
        }
    }

    /// @notice At the least limit the floor admits, the cold policy received the whole cap and consented, so the extension landed.
    function test_Extend_AtTheFloorThePolicyReceivesTheWholeCap() public {
        uint256 least = _leastExtending();
        assertEq(_extendOutcome(address(copies[next++]), least, ""), LANDED, "at the floor the cold policy received the whole cap");
    }

    /// @notice One gas under that floor reverts `PolicyGasShort`, a bare selector, and the loan, the escrow and the payer are untouched.
    /// @dev The books are read BEFORE the bisection, so the probes and the final call run on the same warm slots.
    function test_Extend_OneUnderTheFloorRevertsPolicyGasShortAndMovesNothing() public {
        Loan memory l = read.loan(loanId);
        uint256 escrow = read.feeEscrowOf(loanId);
        uint256 bal = usdc.balanceOf(borrower);
        uint256 least = _leastExtending();
        _setPolicy(alice, address(copies[next++]));
        vm.prank(borrower);
        try ace.extend{gas: least - 1}(loanId, 0, "") {
            fail("one gas under the floor the extend did not revert");
        } catch (bytes memory err) {
            assertEq(err.length, 4, "a bare selector");
            assertEq(bytes4(err), PolicyGasShort.selector, "the refusal is PolicyGasShort");
        }
        Loan memory l1 = read.loan(loanId);
        assertEq(l1.expiry, l.expiry, "the loan did not extend");
        assertEq(l1.debt, l.debt, "its debt is unmoved");
        assertEq(read.feeEscrowOf(loanId), escrow, "its escrow is unmoved");
        assertEq(usdc.balanceOf(borrower), bal, "and the caller paid nothing");
    }

    /// @notice The cap is a ceiling as well as a floor: under a fat limit the policy is handed no more than `POLICY_GAS`, at the verb and the preview.
    /// @dev The control's ceiling sits under the cap, so the mock is shown to tell the two apart before its yes is read.
    function test_Extend_UnderAFatLimitThePolicyIsHandedNoMoreThanTheCap() public {
        address tight = address(new GasCeilingPolicy(ace.POLICY_GAS() / 2));
        assertEq(_extendOutcome(tight, 3_000_000, ""), REFUSED, "CONTROL: a ceiling under the cap reads the cap and refuses");
        address capped = address(new GasCeilingPolicy(ace.POLICY_GAS()));
        assertEq(_extendOutcome(capped, 3_000_000, ""), LANDED, "under a fat limit the policy was handed at most the cap");
        _setPolicy(alice, capped);
        (bool ok,,) = ace.tryExtend{gas: 3_000_000}(loanId, 0, "", borrower);
        assertTrue(ok, "and the preview hands it no more either");
    }

    /// @notice The preview never answers `PolicyGasShort` as a refusal; a short preview reverts it instead.
    function test_TryExtend_NeverReturnsPolicyGasShort() public {
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

    /* ============================== refinanceTo's claim-reuse ask ============================== */

    /// @dev A re-term in the loan's own market whose fresh cash is exactly what rests: a yes reuses the claim and lands, a no refuses `InsufficientCash`.
    function _reterm() internal returns (MigrateArgs memory m) {
        _drain(id, alice);
        uint256 fresh = P / 100;
        _deposit(id, alice, fresh);
        m = MigrateArgs(loanId, id, P + fresh, TEN7, OpenBounds(0, 0, 0), 0, address(0));
    }

    function _refiOutcome(address policy, uint256 g, MigrateArgs memory m) internal returns (uint8 o) {
        uint256 snap = vm.snapshotState();
        _setPolicy(alice, policy);
        vm.prank(borrower);
        try ace.refinanceTo{gas: g}(m) {
            o = LANDED;
        } catch (bytes memory err) {
            o = _classify(err, InsufficientCash.selector);
        }
        vm.revertToStateAndDelete(snap);
    }

    /// @notice One gas under the reuse ask's floor reverts `PolicyGasShort`, and no limit from there up turns the ask's yes into a no.
    /// @dev The re-term's work after the ask is heavy, so a limit just over the floor can still run out later; that is `OTHER`, never `REFUSED`.
    function test_Refinance_AShortLimitNeverBuysTheReuseAskANo() public {
        MigrateArgs memory m = _reterm();
        assertEq(_refiOutcome(address(copies[next++]), 3_000_000, m), LANDED, "PREMISE: a well-funded re-term reuses the claim");
        uint256 lo = ace.POLICY_GAS();
        uint256 hi = 3_000_000;
        assertEq(_refiOutcome(address(copies[next++]), lo, m), SHORT, "PREMISE: a call handed only the cap is short of the floor");
        while (hi - lo > 1) {
            uint256 mid = (lo + hi) / 2;
            if (_refiOutcome(address(copies[next++]), mid, m) == SHORT) lo = mid;
            else hi = mid;
        }
        assertEq(_refiOutcome(address(copies[next++]), hi - 1, m), SHORT, "one under the least admitting limit is PolicyGasShort");
        for (uint256 g = hi; g < hi + 600_000; g += 20_000) {
            assertTrue(_refiOutcome(address(copies[next % COPIES]), g, m) != REFUSED, "a short limit sold the reuse ask a no");
            next++;
        }
    }

    /* ============================== a fail-open policy (review R-5) ============================== */

    /// @notice CONTROL: the mock really is fail-open: starved directly, it answers yes; handed its whole budget, no.
    function test_FailOpen_TheMockAnswersYesWhenStarved() public {
        FailOpenPolicy f = new FailOpenPolicy();
        Extension memory e;
        assertEq(f.admitsExtension{gas: 40_000}(e, ""), IRollPolicy.admitsExtension.selector, "starved, the inner check fails and it says yes");
        assertEq(f.admitsExtension{gas: ace.POLICY_GAS()}(e, ""), bytes4(0), "with the whole budget it says no");
    }

    /// @notice No caller limit sells a fail-open policy's yes on `extend`: every limit is short, out of gas, or the policy's own no.
    function test_FailOpen_ExtendNeverBuysAYesAtAnyLimit() public {
        _assertNoExtendYes(address(new FailOpenPolicy()), "", 150_000, 1_200_000, 15_000);
    }

    /// @notice A large caller payload sells no yes either: the floor fixes the policy's gas whatever `data` costs the caller.
    function test_FailOpen_ALargePayloadBuysNoYes() public {
        _assertNoExtendYes(address(new FailOpenPolicy()), new bytes(64 * 1024), 150_000, 1_500_000, 30_000);
    }

    function _assertNoExtendYes(address f, bytes memory data, uint256 from, uint256 to, uint256 step) internal {
        uint256 refusals;
        for (uint256 g = from; g < to; g += step) {
            uint8 o = _extendOutcome(f, g, data);
            assertTrue(o != LANDED, "a caller limit sold the fail-open policy's yes");
            if (o == REFUSED) refusals++;
        }
        assertGt(refusals, 0, "the policy was reached with its budget and said no");
    }

    /// @notice No limit sells a fail-open policy's yes on the reuse ask: the re-term never reuses the claim, and a fresh draw refuses.
    function test_FailOpen_RefinanceNeverReusesAtAnyLimit() public {
        MigrateArgs memory m = _reterm();
        address f = address(new FailOpenPolicy());
        uint256 refusals;
        for (uint256 g = 150_000; g < 2_000_000; g += 25_000) {
            uint8 o = _refiOutcome(f, g, m);
            assertTrue(o != LANDED, "a caller limit sold the fail-open policy's reuse yes");
            if (o == REFUSED) refusals++;
        }
        assertGt(refusals, 0, "the policy was reached with its budget and said no");
    }
}
