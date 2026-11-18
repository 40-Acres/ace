// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.36;

import {Vm} from "forge-std/Vm.sol";
import {AceVault} from "../../src/curator/AceVault.sol";
import {CapListing, ProductConfig} from "../../src/curator/AceVaultCaps.sol";
import {AceVaultFactory} from "../../src/curator/AceVaultFactory.sol";
import {VaultConfig} from "../../src/curator/AceVaultFlows.sol";
import {CuratorTerms, CuratorTermsConfig, Listing} from "../../src/entities/curated/CuratorTerms.sol";
import {VaultSeed} from "./VaultSeed.sol";

/// @notice A curated AceVault deployed the way a curator deploys one: CuratorTerms at the vault's address-to-be, then the vault naming them.
/// @notice The rail is the widest a vault admits, one day to a year, so no row a suite lists is refused by it; the total is uncapped.
/// @dev Each listed collateral is capped at `rowCap` on the vault; the wildcard stays zero, so an unlisted collateral lends nothing.
/// @dev `direct` deploys by plain `new` from the caller, so a constructor refusal surfaces by its own name; `viaFactory` runs the production path.
library CuratedVaults {
    Vm private constant vm = Vm(address(uint160(uint256(keccak256("hevm cheat code")))));

    uint64 internal constant RAIL_MIN = 1 days;
    uint64 internal constant RAIL_MAX = 365 days;
    uint192 internal constant UNCAPPED = type(uint192).max;

    /// @notice Everything a curated deploy fixes beyond the base's config.
    struct Terms {
        uint256 minPrincipal;
        uint256 coverageWad;
        uint64 timelock; // the row timelock and the cap timelock alike
        uint192 rowCap; // each listed collateral's cap on the vault
    }

    /// @notice The product config of a curated vault naming `terms`: hub-ask mode, drainable, the widest rail.
    function product(address terms, uint64 timelock) internal pure returns (ProductConfig memory) {
        return ProductConfig({terms: terms, door: address(0), inKind: false, drainable: true, capTimelock: timelock, minTenor: RAIL_MIN, maxTenor: RAIL_MAX});
    }

    /// @notice The product config of a door-mode curated vault: `product`'s, with the terms as the vault's door as well.
    function doorProduct(address terms, uint64 timelock) internal pure returns (ProductConfig memory pc) {
        pc = product(terms, timelock);
        pc.door = terms;
    }

    /// @notice `direct` in door mode: the terms at the address the caller's next create but one takes, then the vault naming them as terms and door.
    function directDoor(VaultConfig memory cfg, Terms memory t, Listing[] memory l, string memory name, string memory symbol) internal returns (AceVault v) {
        (CuratorTerms ct, address predicted) = prepare(cfg, t, l);
        ProductConfig memory pc = doorProduct(address(ct), t.timelock);
        require(ct.MIN_TENOR() == pc.minTenor && ct.MAX_TENOR() == pc.maxTenor, "CuratedVaults: the terms' rail is not the vault's");
        v = new AceVault(cfg, pc, caps(predicted, l, t.rowCap), name, symbol);
        require(address(v) == predicted, "CuratedVaults: the door vault landed off its predicted address");
    }

    /// @notice The terms' config for a vault at `vault`, carrying the vault's rail.
    function termsConfig(address vault, VaultConfig memory cfg, Terms memory t) internal pure returns (CuratorTermsConfig memory) {
        return CuratorTermsConfig({
            vault: vault,
            ace: cfg.ace,
            asset: cfg.asset,
            minPrincipal: t.minPrincipal,
            coverageWad: t.coverageWad,
            timelock: t.timelock,
            minTenor: RAIL_MIN,
            maxTenor: RAIL_MAX
        });
    }

    /// @notice The vault's deploy caps: every listed collateral at `rowCap`, and the total at the vault's own address uncapped.
    function caps(address vault, Listing[] memory l, uint192 rowCap) internal pure returns (CapListing[] memory c) {
        c = new CapListing[](l.length + 1);
        for (uint256 i; i < l.length; i++) {
            c[i] = CapListing(l[i].collateral, rowCap);
        }
        c[l.length] = CapListing(vault, UNCAPPED);
    }

    /// @notice Deploy by plain `new`: the terms at the address the caller's next create but one takes, then the vault there.
    function direct(VaultConfig memory cfg, Terms memory t, Listing[] memory l, string memory name, string memory symbol) internal returns (AceVault v) {
        (CuratorTerms ct, address predicted) = prepare(cfg, t, l);
        VaultSeed.fund(cfg, predicted);
        v = new AceVault(cfg, _productFor(ct, t.timelock), caps(predicted, l, t.rowCap), name, symbol);
        require(address(v) == predicted, "CuratedVaults: the vault landed off its predicted address");
    }

    /// @dev The product naming `ct`, its rail asserted equal to the terms' before any vault deploys against it: a mismatch lends nothing.
    function _productFor(CuratorTerms ct, uint64 timelock) private view returns (ProductConfig memory pc) {
        pc = product(address(ct), timelock);
        require(ct.MIN_TENOR() == pc.minTenor && ct.MAX_TENOR() == pc.maxTenor, "CuratedVaults: the terms' rail is not the vault's");
    }

    /// @notice The retired `new CuratorVault(cfg, minPrincipal, coverage, timelock, listings, name, symbol)`, every listed row uncapped.
    function make(
        VaultConfig memory cfg,
        uint256 minPrincipal,
        uint256 coverageWad,
        uint64 timelock,
        Listing[] memory l,
        string memory name,
        string memory symbol
    ) internal returns (AceVault) {
        return direct(cfg, Terms(minPrincipal, coverageWad, timelock, UNCAPPED), l, name, symbol);
    }

    /// @notice The first half of `direct`: the terms, at the address the caller's next create takes after them.
    /// @dev For a row whose subject is the vault constructor's own refusal: deploy these, arm the expectation, then `new AceVault`.
    function prepare(VaultConfig memory cfg, Terms memory t, Listing[] memory l) internal returns (CuratorTerms ct, address predicted) {
        predicted = vm.computeCreateAddress(address(this), vm.getNonce(address(this)) + 1);
        ct = new CuratorTerms(termsConfig(predicted, cfg, t), l);
        VaultSeed.fund(cfg, predicted);
    }

    /// @notice `prepare`, then the product and caps a bare `new AceVault` takes against those terms, for a row arming its own expectation.
    function prepared(VaultConfig memory cfg, Terms memory t, Listing[] memory l) internal returns (ProductConfig memory pc, CapListing[] memory c) {
        (CuratorTerms ct, address predicted) = prepare(cfg, t, l);
        pc = _productFor(ct, t.timelock);
        c = caps(predicted, l, t.rowCap);
    }

    /// @notice Deploy through `f` at the caller's `salt`: the terms against the factory's prediction, then the vault from this build's code.
    function viaFactory(AceVaultFactory f, bytes32 salt, VaultConfig memory cfg, Terms memory t, Listing[] memory l, string memory name, string memory symbol)
        internal
        returns (AceVault)
    {
        (ProductConfig memory pc, CapListing[] memory c) = _termsFor(f, salt, cfg, t, l);
        return _deployVia(f, salt, cfg, pc, c, name, symbol);
    }

    /// @notice `viaFactory` in door mode: the terms against the factory's prediction as the vault's terms and door, then the vault through `f`.
    function viaFactoryDoor(
        AceVaultFactory f,
        bytes32 salt,
        VaultConfig memory cfg,
        Terms memory t,
        Listing[] memory l,
        string memory name,
        string memory symbol
    ) internal returns (AceVault) {
        (ProductConfig memory pc, CapListing[] memory c) = _termsFor(f, salt, cfg, t, l);
        pc.door = pc.terms;
        return _deployVia(f, salt, cfg, pc, c, name, symbol);
    }

    /// @dev The terms against the factory's prediction for the caller's `salt`, and the product and caps naming them.
    function _termsFor(AceVaultFactory f, bytes32 salt, VaultConfig memory cfg, Terms memory t, Listing[] memory l)
        private
        returns (ProductConfig memory pc, CapListing[] memory c)
    {
        address predicted = f.predict(address(this), salt);
        CuratorTerms terms = new CuratorTerms(termsConfig(predicted, cfg, t), l);
        (pc, c) = (_productFor(terms, t.timelock), caps(predicted, l, t.rowCap));
    }

    /// @dev The factory deploy alone, in its own frame: seven arguments and the creation code run a legacy build's stack out beside the terms.
    function _deployVia(
        AceVaultFactory f,
        bytes32 salt,
        VaultConfig memory cfg,
        ProductConfig memory pc,
        CapListing[] memory c,
        string memory name,
        string memory symbol
    ) private returns (AceVault) {
        VaultSeed.approve(cfg, address(f));
        return AceVault(f.deploy(type(AceVault).creationCode, cfg, pc, c, name, symbol, salt));
    }

    /// @notice A factory for `hub` pinning this build's vault code.
    function factory(address hub) internal returns (AceVaultFactory) {
        return new AceVaultFactory(keccak256(type(AceVault).creationCode), hub);
    }

    /// @notice The curated terms a vault names.
    function terms(AceVault v) internal view returns (CuratorTerms) {
        return CuratorTerms(v.TERMS());
    }
}
