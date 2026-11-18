// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.36;

import {CREATE3} from "../../../vendor/solady/CREATE3.sol";
import {Ace} from "../../../src/ace/hub/Ace.sol";
import {AceVault} from "../../../src/curator/AceVault.sol";
import {ProductConfig} from "../../../src/curator/AceVaultCaps.sol";
import {AceVaultFactory} from "../../../src/curator/AceVaultFactory.sol";
import {VaultConfig} from "../../../src/curator/AceVaultFlows.sol";
import {AceFixtures} from "../../utils/AceFixtures.sol";
import {AceVaultBaseRig} from "./AceVaultBaseRig.sol";
import {VaultSeed} from "../../utils/VaultSeed.sol";
import {MockTerms} from "./MockTerms.sol";

/// @title AceVaultFactoryTest
/// @notice The factory deploys vaults from one pinned creation code against one hub, at CREATE3 addresses bound to the deployer, and registers each.
/// @notice A SQUAT is impossible: a second sender with the same salt lands elsewhere, so the first's predicted address stays free for it.
/// @notice A vault is bound to its product: one naming terms built for another address refuses, so a lookalike cannot borrow a victim's product.
contract AceVaultFactoryTest is AceVaultBaseRig {
    AceVaultFactory internal factory;
    bytes internal code;

    function setUp() public override {
        super.setUp();
        code = type(AceVault).creationCode;
        factory = new AceVaultFactory(keccak256(code), address(ace));
    }

    /// @dev Products first, against the factory's prediction, then the vault through the factory as `deployer`.
    function _via(address deployer, bytes32 salt) internal returns (AceVault v, MockTerms t) {
        address predicted = factory.predict(deployer, salt);
        t = new MockTerms(predicted, address(ace));
        v = _deployNaming(deployer, salt, address(t));
        assertEq(address(v), predicted, "the vault landed off the factory's prediction");
    }

    /// @dev The deployer's seed, minted to it and approved to the factory, which the deploy pulls to the vault's address.
    function _seedFor(address deployer) internal {
        usdc.mint(deployer, VaultSeed.SEED);
        vm.prank(deployer);
        usdc.approve(address(factory), VaultSeed.SEED);
    }

    function _deployNaming(address deployer, bytes32 salt, address t) internal returns (AceVault) {
        ProductConfig memory pc = _pc();
        pc.terms = t;
        address predicted = factory.predict(deployer, salt);
        _seedFor(deployer);
        vm.prank(deployer);
        return AceVault(factory.deploy(code, _cfg(), pc, _listing(predicted, _caps(UNCAPPED, 0, UNCAPPED)), "Fac", "fV", salt));
    }

    /// @notice SQUAT: a second sender with the first's salt lands at its own address, and the first's predicted address stays free for the first.
    function test_ASecondSenderWithTheSameSaltLandsElsewhere() public {
        bytes32 salt = keccak256("shared");
        address alicePredicted = factory.predict(alice, salt);
        (AceVault byBob,) = _via(bob, salt);
        assertTrue(address(byBob) != alicePredicted, "the second sender landed on the first's address");
        assertEq(alicePredicted.code.length, 0, "the first sender's address was taken");
        (AceVault byAlice,) = _via(alice, salt);
        assertEq(address(byAlice), alicePredicted, "the first sender could not take its own address");
    }

    /// @notice A sender naming terms built for another sender's address is refused: a lookalike cannot take the victim's product.
    function test_AVaultNamingAnotherVaultsTermsRefuses() public {
        bytes32 salt = keccak256("victim");
        MockTerms victims = new MockTerms(factory.predict(alice, salt), address(ace));
        ProductConfig memory pc = _pc();
        pc.terms = address(victims);
        address squat = factory.predict(bob, salt);
        _seedFor(bob);
        vm.prank(bob);
        vm.expectRevert(CREATE3.DeploymentFailed.selector);
        factory.deploy(code, _cfg(), pc, _listing(squat, _caps(UNCAPPED, 0, UNCAPPED)), "Fac", "fV", salt);
        assertEq(squat.code.length, 0, "the lookalike landed");
        address predicted = vm.computeCreateAddress(address(this), vm.getNonce(address(this)));
        vm.expectRevert(AceVault.TermsNotBound.selector);
        new AceVault(_cfg(), pc, _listing(predicted, _caps(UNCAPPED, 0, UNCAPPED)), "Direct", "dV");
    }

    /// @notice A reverted deploy reverts its proxy too, so the salt stays free: the same sender lands there once it names its own product.
    function test_ARevertedDeployFreesTheSalt() public {
        bytes32 salt = keccak256("retry");
        address predicted = factory.predict(alice, salt);
        ProductConfig memory pc = _pc();
        pc.terms = address(new MockTerms(stranger, address(ace)));
        _seedFor(alice);
        vm.prank(alice);
        vm.expectRevert(CREATE3.DeploymentFailed.selector);
        factory.deploy(code, _cfg(), pc, _listing(predicted, _caps(UNCAPPED, 0, UNCAPPED)), "Fac", "fV", salt);
        (AceVault v,) = _via(alice, salt);
        assertTrue(factory.isAceVault(address(v)), "the retried salt did not deploy");
    }

    /// @notice Creation code other than the pinned code is refused, a byte appended or one flipped.
    function test_TheWrongCodeRefuses() public {
        bytes32 salt = keccak256("code");
        address predicted = factory.predict(alice, salt);
        ProductConfig memory pc = _pc();
        pc.terms = address(new MockTerms(predicted, address(ace)));
        bytes memory longer = bytes.concat(code, hex"00");
        vm.prank(alice);
        vm.expectRevert(AceVaultFactory.WrongCode.selector);
        factory.deploy(longer, _cfg(), pc, _listing(predicted, _caps(UNCAPPED, 0, UNCAPPED)), "Fac", "fV", salt);
        bytes memory flipped = bytes.concat(code);
        flipped[flipped.length - 1] ^= 0x01;
        vm.prank(alice);
        vm.expectRevert(AceVaultFactory.WrongCode.selector);
        factory.deploy(flipped, _cfg(), pc, _listing(predicted, _caps(UNCAPPED, 0, UNCAPPED)), "Fac", "fV", salt);
    }

    /// @notice A vault naming another hub than the factory's is refused, so a registered vault never reads a fake NAV.
    function test_TheWrongHubRefuses() public {
        (Ace other,) = AceFixtures.newAceWithEscrow(AceFixtures.TREASURY);
        bytes32 salt = keccak256("hub");
        address predicted = factory.predict(alice, salt);
        ProductConfig memory pc = _pc();
        pc.terms = address(new MockTerms(predicted, address(other)));
        VaultConfig memory cfg = _cfg();
        cfg.ace = address(other);
        vm.prank(alice);
        vm.expectRevert(AceVaultFactory.WrongHub.selector);
        factory.deploy(code, cfg, pc, _listing(predicted, _caps(UNCAPPED, 0, UNCAPPED)), "Fac", "fV", salt);
    }

    /// @notice Only the factory's own deploys read as AceVaults: a direct deploy of the same code, and any other address, do not.
    function test_OnlyFactoryDeploysReadAsAceVaults() public {
        (AceVault v,) = _via(alice, keccak256("registered"));
        assertTrue(factory.isAceVault(address(v)), "the factory's own deploy is not registered");
        assertFalse(factory.isAceVault(address(vault)), "a direct deploy of the same code is registered");
        assertFalse(factory.isAceVault(alice), "an account is registered");
    }

    /// @notice The factory pins its code and hub, and refuses a hub with no code.
    function test_TheFactoryPinsItsCodeAndHub() public {
        assertEq(factory.CODE_HASH(), keccak256(code), "the pinned hash");
        assertEq(factory.HUB(), address(ace), "the pinned hub");
        vm.expectRevert(AceVaultFactory.HubHasNoCode.selector);
        new AceVaultFactory(keccak256(code), stranger);
    }
}
