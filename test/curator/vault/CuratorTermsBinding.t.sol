// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.36;

import {Ace} from "../../../src/ace/hub/Ace.sol";
import {AceVault} from "../../../src/curator/AceVault.sol";
import {ProductConfig} from "../../../src/curator/libraries/AceVaultCaps.sol";
import {CuratorTerms, CuratorTermsConfig, Listing, Row} from "../../../src/entities/curated/CuratorTerms.sol";
import {AceFixtures} from "../../utils/AceFixtures.sol";
import {AceVaultBaseRig} from "./AceVaultBaseRig.sol";
import {VaultSeed} from "../../utils/VaultSeed.sol";

/// @title CuratorTermsBindingTest
/// @notice CuratorTerms copies its vault's hub, asset and tenor rail before the vault exists; terms whose copy disagrees lend nothing.
/// @notice A wrong hub would read no unsold pot and switch the row's hold off; a wrong rail would list rows the vault never lends on.
/// @dev The refusal is named by selector, so these rows compile against terms that do not yet refuse.
contract CuratorTermsBindingTest is AceVaultBaseRig {
    bytes4 internal constant MISMATCH = bytes4(keccak256("VaultMismatch()")); // the terms' refusal when they disagree with their vault
    uint256 internal constant MIN_P = 10e6;
    uint256 internal constant COVERAGE = 1.4e18;
    uint64 internal constant ROW_LOCK = 3 days;

    function _row() internal view returns (Row memory) {
        return Row({record: address(record), bufferBps: 1000, lenderAprBps: 40, minTenor: TENOR, maxTenor: RAIL_MAX});
    }

    /// @dev Terms for a vault at `v` on hub `hub` and the rail `[minT, maxT]`, the asset always the rig's.
    function _termsCfg(address v, address hub, uint64 minT, uint64 maxT) internal view returns (CuratorTermsConfig memory) {
        return CuratorTermsConfig({
            vault: v, ace: hub, asset: address(usdc), minPrincipal: MIN_P, coverageWad: COVERAGE, timelock: ROW_LOCK, minTenor: minT, maxTenor: maxT
        });
    }

    /// @dev Terms built with `hub` and `[minT, maxT]`, then the rig's vault naming them on the rig's own hub and rail, seeded by alice.
    function _curatedWith(address hub, uint64 minT, uint64 maxT) internal returns (CuratorTerms t) {
        address predicted = vm.computeCreateAddress(address(this), vm.getNonce(address(this)) + 1);
        Listing[] memory l = new Listing[](1);
        l[0] = Listing({collateral: address(coll), row: _row()});
        t = new CuratorTerms(_termsCfg(predicted, hub, minT, maxT), l);
        ProductConfig memory pc = _pc();
        pc.terms = address(t);
        VaultSeed.fund(_cfg(), predicted);
        vault = new AceVault(_cfg(), pc, _listing(predicted, _caps(UNCAPPED, 0, UNCAPPED)), "Curated", "cVLT");
        assertEq(address(vault), predicted, "rig: the vault landed off its predicted address");
        _lp(alice, LP_CASH);
    }

    /// @notice TERMS BUILT ON ANOTHER HUB LEND NOTHING: the hub has code and answers, so only the binding can refuse.
    function test_TermsOnAnotherHubRefuseEveryBorrow() public {
        (Ace other,) = AceFixtures.newAceWithEscrow(AceFixtures.TREASURY);
        assertGt(address(other).code.length, 0, "PREMISE: the other hub is a live contract");
        CuratorTerms t = _curatedWith(address(other), RAIL_MIN, RAIL_MAX);
        assertEq(t.ACE(), address(other), "PREMISE: the terms copied another hub than the vault's");
        _expectBorrowRevert(address(coll), MISMATCH);
    }

    /// @notice TERMS ON ANOTHER RAIL LEND NOTHING, wider at the top or narrower at the bottom alike.
    function test_TermsOnAnotherRailRefuseEveryBorrow() public {
        _curatedWith(address(ace), RAIL_MIN, 365 days);
        assertTrue(vault.MAX_TENOR() != 365 days, "PREMISE: the vault's rail ends elsewhere");
        _expectBorrowRevert(address(coll), MISMATCH);
        _curatedWith(address(ace), RAIL_MIN + 1 days, RAIL_MAX);
        _expectBorrowRevert(address(coll), MISMATCH);
    }

    /// @notice CONTROL: terms whose hub, asset and rail are their vault's lend as built.
    function test_TheHonestPairLends() public {
        _curatedWith(address(ace), RAIL_MIN, RAIL_MAX);
        uint256 loanId = _borrow();
        assertTrue(ace.isLiveLoan(loanId), "the honest pair did not lend");
    }

    /// @notice THE TERMS' RAIL IS THE VAULT'S RAIL'S RANGE: a day to a year, its ends uncrossed, refused at construction otherwise.
    function test_ARailOutsideADayToAYearRefusesConstruction() public {
        Listing[] memory none = new Listing[](0);
        vm.expectRevert(AceVault.TenorRailOutOfBounds.selector);
        new CuratorTerms(_termsCfg(address(0xBEEF), address(ace), 1 days - 1, 30 days), none);
        vm.expectRevert(AceVault.TenorRailOutOfBounds.selector);
        new CuratorTerms(_termsCfg(address(0xBEEF), address(ace), 1 days, 365 days + 1), none);
        vm.expectRevert(AceVault.TenorRailOutOfBounds.selector);
        new CuratorTerms(_termsCfg(address(0xBEEF), address(ace), 30 days, 30 days - 1), none);
        CuratorTerms ok = new CuratorTerms(_termsCfg(address(0xBEEF), address(ace), 1 days, 365 days), none);
        assertEq(ok.MAX_TENOR(), 365 days, "CONTROL: the widest rail is admitted");
    }
}
