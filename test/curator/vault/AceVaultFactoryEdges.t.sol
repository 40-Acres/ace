// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.36;

import {CREATE3} from "../../../vendor/solady/CREATE3.sol";
import {AceVault} from "../../../src/curator/AceVault.sol";
import {ProductConfig} from "../../../src/curator/libraries/AceVaultCaps.sol";
import {AceVaultFactory} from "../../../src/curator/AceVaultFactory.sol";
import {AceVaultBaseRig} from "./AceVaultBaseRig.sol";
import {MockTerms} from "./MockTerms.sol";
import {VaultSeed} from "../../utils/VaultSeed.sol";

/// @title AceVaultFactoryEdgesTest
/// @notice F3 hardening: the address is CREATE3 over `keccak256(abi.encode(deployer, salt))` from the factory, so it binds both, and nothing else.
/// @notice A salt is spent once per deployer; the registry flips only on a landed deploy; the event names the vault, the deployer, the salt and the terms.
contract AceVaultFactoryEdgesTest is AceVaultBaseRig {
    AceVaultFactory internal factory;
    bytes internal code;

    event VaultCreated(address indexed vault, address indexed deployer, bytes32 indexed userSalt, address terms);

    function setUp() public override {
        super.setUp();
        code = type(AceVault).creationCode;
        factory = new AceVaultFactory(keccak256(code), address(ace));
    }

    function _pcFor(address t) internal pure returns (ProductConfig memory pc) {
        pc = _pc();
        pc.terms = t;
    }

    /// @dev The deployer's seed, minted to it and approved to the factory, which the deploy pulls to the vault's address.
    function _seedFor(address deployer) internal {
        usdc.mint(deployer, VaultSeed.SEED);
        vm.prank(deployer);
        usdc.approve(address(factory), VaultSeed.SEED);
    }

    /// @dev Deploy through the factory as `deployer`, its terms built first against the prediction.
    function _deployAs(address deployer, bytes32 salt) internal returns (address v, address t) {
        address predicted = factory.predict(deployer, salt);
        t = address(new MockTerms(predicted, address(ace)));
        _seedFor(deployer);
        vm.prank(deployer);
        v = factory.deploy(code, _cfg(), _pcFor(t), _listing(predicted, _caps(UNCAPPED, 0, UNCAPPED)), "Fac", "fV", salt);
    }

    /// @notice `predict` is CREATE3 from the factory over the deployer and the salt encoded together, independently recomputed here.
    function test_PredictIsCreate3OverTheDeployerAndTheSalt() public view {
        bytes32 salt = keccak256("s");
        address expected = CREATE3.predictDeterministicAddress(keccak256(abi.encode(alice, salt)), address(factory));
        assertEq(factory.predict(alice, salt), expected, "predict is not CREATE3 over the deployer and the salt");
        assertTrue(factory.predict(alice, salt) != factory.predict(bob, salt), "two deployers share an address");
        assertTrue(factory.predict(alice, salt) != factory.predict(alice, keccak256("t")), "two salts share an address");
        address bare = CREATE3.predictDeterministicAddress(salt, address(factory));
        assertTrue(factory.predict(alice, salt) != bare, "the bare salt, unbound to the deployer, predicts the same address");
    }

    /// @notice A deployer spends a salt once: a second deploy on it is refused, and the first vault stays registered and live.
    function test_ASaltIsSpentOncePerDeployer() public {
        bytes32 salt = keccak256("once");
        (address v,) = _deployAs(alice, salt);
        address predicted = factory.predict(alice, salt);
        assertEq(v, predicted, "premise: the first deploy landed at the prediction");
        address t2 = address(new MockTerms(predicted, address(ace)));
        _seedFor(alice);
        vm.prank(alice);
        vm.expectRevert(CREATE3.DeploymentFailed.selector);
        factory.deploy(code, _cfg(), _pcFor(t2), _listing(predicted, _caps(UNCAPPED, 0, UNCAPPED)), "Fac", "fV", salt);
        assertTrue(factory.isAceVault(v), "the refused second deploy unregistered the first");
        assertGt(v.code.length, 0, "the first vault's code is gone");
    }

    /// @notice The registry flips only on a landed deploy, and the event names the vault, its deployer, the salt and the terms.
    function test_TheRegistryFlipsOnlyOnALandedDeploy() public {
        bytes32 salt = keccak256("reg");
        address predicted = factory.predict(bob, salt);
        assertFalse(factory.isAceVault(predicted), "an address read as a vault before its deploy");
        address t = address(new MockTerms(predicted, address(ace)));
        _seedFor(bob);
        vm.expectEmit(true, true, true, true, address(factory));
        emit VaultCreated(predicted, bob, salt, t);
        vm.prank(bob);
        address v = factory.deploy(code, _cfg(), _pcFor(t), _listing(predicted, _caps(UNCAPPED, 0, UNCAPPED)), "Fac", "fV", salt);
        assertEq(v, predicted, "the vault landed off the prediction");
        assertTrue(factory.isAceVault(v), "the landed vault is not registered");
        assertEq(AceVault(v).TERMS(), t, "the registered vault names other terms");
        assertEq(AceVault(v).ACE(), factory.HUB(), "the registered vault names another hub than the factory's");
    }

    /// @notice A refused deploy leaves the predicted address unregistered and empty.
    function test_ARefusedDeployRegistersNothing() public {
        bytes32 salt = keccak256("refused");
        address predicted = factory.predict(alice, salt);
        address wrong = address(new MockTerms(stranger, address(ace)));
        _seedFor(alice);
        vm.prank(alice);
        vm.expectRevert(CREATE3.DeploymentFailed.selector);
        factory.deploy(code, _cfg(), _pcFor(wrong), _listing(predicted, _caps(UNCAPPED, 0, UNCAPPED)), "Fac", "fV", salt);
        assertFalse(factory.isAceVault(predicted), "a refused deploy registered its address");
        assertEq(predicted.code.length, 0, "a refused deploy left code at its address");
    }

    /// @notice A factory pinning another hash refuses this build's code, so a second factory cannot launder a vault onto the first's registry.
    function test_AFactoryPinningOtherCodeRefusesThisBuild() public {
        AceVaultFactory other = new AceVaultFactory(keccak256("not the vault"), address(ace));
        bytes32 salt = keccak256("other");
        address predicted = other.predict(alice, salt);
        address t = address(new MockTerms(predicted, address(ace)));
        vm.prank(alice);
        vm.expectRevert(AceVaultFactory.WrongCode.selector);
        other.deploy(code, _cfg(), _pcFor(t), _listing(predicted, _caps(UNCAPPED, 0, UNCAPPED)), "Fac", "fV", salt);
        assertFalse(factory.isAceVault(predicted), "another factory's address read as this factory's vault");
    }
}
