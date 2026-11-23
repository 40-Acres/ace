// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.36;

import {Constants} from "../../../src/ace/hub/Constants.sol";
import {Loan} from "../../../src/ace/hub/Types.sol";
import {AceVault} from "../../../src/vault/AceVault.sol";
import {ProductConfig} from "../../../src/vault/libraries/AceVaultCaps.sol";
import {VaultConfig} from "../../../src/vault/libraries/AceVaultFlows.sol";
import {CuratorTerms, CuratorTermsConfig, Listing, Row} from "../../../src/vault/curated/CuratorTerms.sol";
import {AceFixtures} from "../../utils/AceFixtures.sol";
import {AceReader} from "../../utils/AceReader.sol";
import {AceVaultBaseRig} from "./AceVaultBaseRig.sol";
import {VaultSeed} from "../../utils/VaultSeed.sol";
import {MockTerms} from "./MockTerms.sol";

/// @title AceVaultAskReserveTest
/// @notice The product read keeps gas back for its caller: a product that burns what it is handed leaves `maxMint` enough to answer.
/// @dev The burn is armed in `setUp`, so the row's own call meets the terms and the fee high-water COLD, as a caller's first read does.
contract AceVaultAskReserveTest is AceVaultBaseRig {
    function setUp() public override {
        super.setUp();
        VaultConfig memory cfg = _cfg();
        cfg.perfFeeBps = 1000; // a fee vault: maxMint's quote supply reads the fee high-water, before the product read
        (vault, terms) = _deploy(cfg, _pc(), _caps(UNCAPPED, 0, UNCAPPED));
        _lp(alice, LP_CASH);
        terms.setEntryCap(MockTerms.Mode.BurnGas, 5_000e6);
    }

    function _maxMint(uint256 gasBudget) internal view returns (bool ok, uint256 v) {
        try vault.maxMint{gas: gasBudget}(bob) returns (uint256 x) {
            (ok, v) = (true, x);
        } catch {}
    }

    /// @notice COLD: on a budget an honest cap answers on, a cap that burns its gas leaves `maxMint` a zero, never a revert.
    function test_AColdBurningCapLeavesMaxMintAZero() public view {
        (bool ok, uint256 v) = _maxMint(COLD_BUDGET);
        // the control twin below answers on this budget with an honest cap, read just as cold
        assertTrue(ok, "maxMint ran out of gas after a cold product read that burnt its allowance");
        assertEq(v, 0, "maxMint answered past a cap that burnt its gas");
    }
}

uint256 constant COLD_BUDGET = 80_000; // the cold budget both rows read on: an honest cap answers inside it

/// @title AceVaultAskReserveHonestTest
/// @notice CONTROL for the cold row: the same vault and budget with an honest cap, cold, answers the cap in shares.
contract AceVaultAskReserveHonestTest is AceVaultBaseRig {
    function setUp() public override {
        super.setUp();
        VaultConfig memory cfg = _cfg();
        cfg.perfFeeBps = 1000;
        (vault, terms) = _deploy(cfg, _pc(), _caps(UNCAPPED, 0, UNCAPPED));
        _lp(alice, LP_CASH);
        terms.setEntryCap(MockTerms.Mode.Answer, 5_000e6);
    }

    /// @notice An honest cap, read cold on the budget the burning row uses, answers a nonzero `maxMint`.
    function test_AColdHonestCapAnswersOnTheSameBudget() public view {
        uint256 v = vault.maxMint{gas: COLD_BUDGET}(bob);
        assertGt(v, 0, "an honest cap answered nothing on the cold budget");
    }

    /// @notice THE RESERVE'S PRICE: on its own cost plus the reserve, an honest cap answers exactly what it answers on any budget.
    function test_AnHonestCapAnswersOnItsOwnCostPlusTheReserve() public view {
        uint256 full = vault.maxMint(bob); // warms every slot the read touches, so the measure below is the warm cost
        uint256 g0 = gasleft();
        vault.maxMint(bob);
        uint256 used = g0 - gasleft();
        uint256 v = vault.maxMint{gas: used + vault.ASK_RESERVE()}(bob);
        assertEq(v, full, "an honest cap answered short on its own cost plus the reserve");
    }
}

/// @title AceVaultAskReserveHubTest
/// @notice THE HUB SIDE: an honest CuratorTerms consents to an extension inside the smallest policy budget a hub may carry, reserve and all.
contract AceVaultAskReserveHubTest is AceVaultBaseRig {
    function setUp() public override {
        super.setUp();
        (ace, pm) = AceFixtures.newAceWithBudgets(AceFixtures.TREASURY, AceFixtures.PUSH_GAS, Constants.MIN_POLICY_GAS);
        read = new AceReader(address(ace));
        address predicted = vm.computeCreateAddress(address(this), vm.getNonce(address(this)) + 1);
        Listing[] memory l = new Listing[](1);
        l[0] = Listing({collateral: address(coll), row: Row({record: address(record), bufferBps: 1000, lenderAprBps: 40, minTenor: TENOR, maxTenor: RAIL_MAX})});
        CuratorTerms t = new CuratorTerms(
            CuratorTermsConfig({
                vault: predicted,
                ace: address(ace),
                asset: address(usdc),
                minPrincipal: 10e6,
                coverageWad: 1.4e18,
                timelock: 3 days,
                minTenor: RAIL_MIN,
                maxTenor: RAIL_MAX
            }),
            l
        );
        ProductConfig memory pc = _pc();
        pc.terms = address(t);
        VaultSeed.fund(_cfg(), predicted);
        vault = new AceVault(_cfg(), pc, _listing(predicted, _caps(UNCAPPED, 0, UNCAPPED)), "Curated", "cVLT");
        _lp(alice, LP_CASH);
    }

    /// @notice The holder's extension through the real hub lands, so the vault's consent, the product's included, fit the hub's 50k budget.
    function test_AnHonestConsentFitsTheSmallestHubBudget() public {
        assertEq(ace.POLICY_GAS(), Constants.MIN_POLICY_GAS, "PREMISE: the hub carries the smallest policy budget the rail admits");
        uint256 loanId = _borrow();
        _warpBy(1 days);
        _fundFee(borrower);
        vm.prank(borrower);
        ace.extend(loanId, 0, "");
        Loan memory ln = read.loan(loanId);
        assertEq(ln.expiry, _now() + ln.tenor, "the honest consent did not land inside the hub's budget");
    }
}
