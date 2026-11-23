// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.36;

import {AceVault} from "../../../src/vault/AceVault.sol";
import {AceVaultFlows} from "../../../src/vault/libraries/AceVaultFlows.sol";
import {AceVaultBaseRig} from "./AceVaultBaseRig.sol";
import {MockTerms} from "./MockTerms.sol";

/// @title AceVaultAskGateTest
/// @notice The shared product read asks nothing on a budget that cannot keep its reserve back, and keeps back the reserve the vault advertises.
/// @notice Sweeps fine enough to land inside the reserve: an honest cap's full answer is monotone in the budget, and a cold burn reads zero.
/// @dev The starved-entry rows' coarse budgets never land between the reserve and the reserve plus an honest read's cost, so they cannot see the gate.
/// @dev `vm.cool` cools storage but not the account, so the cold sweep reverts to a state snapshot taken cold, where every account is cold again.
contract AceVaultAskGateTest is AceVaultBaseRig {
    uint256 internal constant CAP = 5_000e6;
    uint256 internal constant LO = 5_000;
    uint256 internal constant HI = 120_000;
    uint256 internal constant STEP = 50; // well under an honest warm read's cost, so the sweep lands inside every gas window the gate opens

    AceVault internal burnVault; // a twin of the rig vault whose product burns its entry cap's gas
    MockTerms internal burnTerms;

    function setUp() public override {
        super.setUp();
        terms.setEntryCap(MockTerms.Mode.Answer, CAP);
        (AceVault rig, MockTerms rigTerms) = (vault, terms);
        (burnVault, burnTerms) = _deploy(_cfg(), _pc(), _caps(UNCAPPED, 0, UNCAPPED));
        vault = burnVault;
        _lp(alice, LP_CASH);
        burnTerms.setEntryCap(MockTerms.Mode.BurnGas, CAP);
        (vault, terms) = (rig, rigTerms);
    }

    function _max(AceVault v, bool dep, uint256 b) internal view returns (bool ok, uint256 x) {
        if (dep) {
            try v.maxDeposit{gas: b}(bob) returns (uint256 y) {
                (ok, x) = (true, y);
            } catch {}
        } else {
            try v.maxMint{gas: b}(bob) returns (uint256 y) {
                (ok, x) = (true, y);
            } catch {}
        }
    }

    /// @notice The reserve `ASK_RESERVE` advertises is the one the read keeps, so an integrator sizing a budget off it is told the truth.
    function test_TheVaultAdvertisesTheReserveItsReadKeeps() public view {
        assertEq(vault.ASK_RESERVE(), AceVaultFlows.ASK_RESERVE, "the vault advertises another reserve than its read keeps");
    }

    /// @notice WARM SWEEP: once an honest cap answers in full on a budget, it answers in full on every larger one; a read under the reserve asks nothing.
    /// @dev A read that asked with all gas below the reserve would answer in full there, then read zero just past it, where it hands the product too little.
    function test_AnHonestCapsFullAnswerIsMonotoneInTheBudget() public view {
        uint256 fullDep = vault.maxDeposit(bob); // warms every slot either maximum touches, so each budget meets the same costs
        uint256 fullMint = vault.maxMint(bob);
        assertEq(fullDep, CAP, "premise: on a full budget maxDeposit answers the cap");
        (uint256 starvedDep, uint256 regressDep) = _sweep(true, fullDep);
        (uint256 starvedMint, uint256 regressMint) = _sweep(false, fullMint);
        assertEq(regressDep, 0, "maxDeposit answered the cap on a budget, then less on a larger one");
        assertEq(regressMint, 0, "maxMint answered in full on a budget, then less on a larger one");
        assertGt(starvedDep, 0, "premise: the sweep starts where maxDeposit answers but the reserve leaves the cap unasked");
        assertGt(starvedMint, 0, "premise: the sweep starts where maxMint answers but the reserve leaves the cap unasked");
    }

    /// @dev Ascending budgets: how many answered under `full` before the first full answer, and how many answered less after it.
    function _sweep(bool dep, uint256 full) internal view returns (uint256 starved, uint256 regressed) {
        bool seen;
        for (uint256 b = LO; b <= HI; b += STEP) {
            (bool ok, uint256 v) = _max(vault, dep, b);
            if (ok && v == full) seen = true;
            else if (seen) regressed++;
            else if (ok) starved++;
        }
        assertTrue(seen, "premise: the sweep reaches a budget the honest cap answers in full on");
    }

    /// @notice COLD SWEEP: on every budget a cold honest cap lets an entry maximum answer, a cold cap that burns its gas leaves it a zero.
    /// @dev The reserve must cover the read's cold-access charge as well as the caller's tail; a reserve under that charge leaves only EIP-150's 1/64.
    function test_AColdBurningCapIsZeroWhereverAColdHonestCapAnswers() public {
        uint256 cold = vm.snapshotState();
        (uint256 answeredDep, uint256 brokenDep) = _coldSweep(cold, true);
        (uint256 answeredMint, uint256 brokenMint) = _coldSweep(cold, false);
        assertEq(brokenDep, 0, "a cold burning cap reverted maxDeposit, or answered past zero, where an honest cap answers");
        assertEq(brokenMint, 0, "a cold burning cap reverted maxMint, or answered past zero, where an honest cap answers");
        assertGt(answeredDep, 0, "premise: an honest cold cap lets maxDeposit answer somewhere in the sweep");
        assertGt(answeredMint, 0, "premise: an honest cold cap lets maxMint answer somewhere in the sweep");
    }

    /// @dev Per budget, the honest vault then the burning twin, each read from the cold snapshot: honest reads that answered, and burns that broke there.
    function _coldSweep(uint256 cold, bool dep) internal returns (uint256 answered, uint256 broken) {
        for (uint256 b = LO; b <= HI; b += STEP) {
            vm.revertToState(cold);
            (bool honestOk,) = _max(vault, dep, b);
            vm.revertToState(cold);
            (bool ok, uint256 v) = _max(burnVault, dep, b);
            if (!honestOk) continue;
            answered++;
            if (!(ok && v == 0)) {
                emit log_named_uint(dep ? "a cold burn broke maxDeposit at budget" : "a cold burn broke maxMint at budget", b);
                broken++;
            }
        }
    }
}
