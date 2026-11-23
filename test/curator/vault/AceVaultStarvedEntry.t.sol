// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.36;

import {VaultConfig} from "../../../src/vault/libraries/AceVaultFlows.sol";
import {AceVaultBaseRig} from "./AceVaultBaseRig.sol";
import {MockTerms} from "./MockTerms.sol";

/// @title AceVaultStarvedEntryTest
/// @notice `maxMint` answers zero, never reverts, on a gas budget an honest product answers on, when the product's entry cap burns or bombs its gas.
/// @notice A burn leaves the caller only what the read holds back; `maxMint` reads the quote supply before it, so only arithmetic follows.
/// @notice Read by a static call forwarding all gas, these rows were red at 40k, 60k and 80k and green from 120k.
/// @dev On the tightest budget the reserve can leave an honest cap unasked, so `maxDeposit` may read under the cap there, as ERC-4626 permits.
contract AceVaultStarvedEntryTest is AceVaultBaseRig {
    function setUp() public override {
        super.setUp();
        VaultConfig memory cfg = _cfg();
        cfg.perfFeeBps = 1000;
        (vault, terms) = _deploy(cfg, _pc(), _caps(UNCAPPED, 0, UNCAPPED));
        _lp(alice, LP_CASH);
    }

    function _maxDeposit(uint256 gasBudget) internal view returns (bool ok, uint256 v) {
        try vault.maxDeposit{gas: gasBudget}(bob) returns (uint256 x) {
            (ok, v) = (true, x);
        } catch {}
    }

    function _maxMint(uint256 gasBudget) internal view returns (bool ok, uint256 v) {
        try vault.maxMint{gas: gasBudget}(bob) returns (uint256 x) {
            (ok, v) = (true, x);
        } catch {}
    }

    /// @notice THE REPRO: on an 80k budget an honest cap lets `maxMint` answer, and a cap that burns its gas must leave it a zero, not a revert.
    function test_MaxMintAnswersZeroOnAStarvedBudgetUnderAGasBurningCap() public {
        terms.setEntryCap(MockTerms.Mode.Answer, 5_000e6);
        (bool honestOk, uint256 honest) = _maxMint(80_000);
        assertTrue(honestOk && honest > 0, "premise: on this budget an honest cap lets maxMint answer");
        terms.setEntryCap(MockTerms.Mode.BurnGas, 5_000e6);
        (bool ok, uint256 v) = _maxMint(80_000);
        assertTrue(ok, "maxMint reverted on a budget an honest cap answers on, because the cap burnt its gas");
        assertEq(v, 0, "maxMint answered past a cap that burnt its gas");
    }

    /// @notice THE PROPERTY: wherever an honest cap lets either entry maximum answer on a budget, every hostile cap leaves it a zero there.
    function test_TheEntryMaximaAnswerOnAnyBudgetAnHonestProductAnswersOn() public {
        uint32[9] memory budgets = [uint32(40_000), 60_000, 80_000, 120_000, 160_000, 240_000, 400_000, 1_000_000, 5_000_000];
        MockTerms.Mode[5] memory hostile =
            [MockTerms.Mode.Revert, MockTerms.Mode.BurnGas, MockTerms.Mode.ReturnBomb, MockTerms.Mode.ShortWord, MockTerms.Mode.LongWord];
        uint256 broken;
        for (uint256 b; b < budgets.length; b++) {
            terms.setEntryCap(MockTerms.Mode.Answer, 5_000e6);
            (bool depOk,) = _maxDeposit(budgets[b]);
            (bool mintOk,) = _maxMint(budgets[b]);
            for (uint256 m; m < hostile.length; m++) {
                terms.setEntryCap(hostile[m], 5_000e6);
                (bool hDep, uint256 vDep) = _maxDeposit(budgets[b]);
                (bool hMint, uint256 vMint) = _maxMint(budgets[b]);
                if (depOk && !(hDep && vDep == 0)) {
                    emit log_named_uint(string.concat("maxDeposit FAILED, mode ", vm.toString(m), ", budget"), budgets[b]);
                    broken++;
                }
                if (mintOk && !(hMint && vMint == 0)) {
                    emit log_named_uint(string.concat("maxMint FAILED, mode ", vm.toString(m), ", budget"), budgets[b]);
                    broken++;
                }
            }
        }
        assertEq(broken, 0, "an entry maximum failed on a hostile cap at a budget an honest one answers on");
    }

    /// @notice CONTROL: `maxDeposit` holds at every starved budget, a burning cap reading zero; an honest cap answers in full from 60k, at most it at 40k.
    function test_MaxDepositHoldsAtTheStarvedBudgets() public {
        uint32[3] memory budgets = [uint32(40_000), 60_000, 80_000];
        for (uint256 b; b < budgets.length; b++) {
            terms.setEntryCap(MockTerms.Mode.Answer, 5_000e6);
            (bool honestOk, uint256 honest) = _maxDeposit(budgets[b]);
            if (budgets[b] == 40_000) {
                assertTrue(honestOk && honest <= 5_000e6, "premise: on the tightest budget an honest cap leaves maxDeposit answering at most the cap");
            } else {
                assertTrue(honestOk && honest == 5_000e6, "premise: on this budget an honest cap lets maxDeposit answer");
            }
            terms.setEntryCap(MockTerms.Mode.BurnGas, 5_000e6);
            (bool ok, uint256 v) = _maxDeposit(budgets[b]);
            assertTrue(ok && v == 0, "maxDeposit reverted or answered past a burning cap on a starved budget");
        }
    }
}
