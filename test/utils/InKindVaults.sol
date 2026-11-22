// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.36;

import {Vm} from "forge-std/Vm.sol";
import {AceVault} from "../../src/curator/AceVault.sol";
import {CapListing, ProductConfig} from "../../src/curator/libraries/AceVaultCaps.sol";
import {VaultConfig} from "../../src/curator/libraries/AceVaultFlows.sol";
import {VaultSeed} from "./VaultSeed.sol";

/// @notice The terms' row, as `InKindTerms` stores it: a rate, tenors and a largest loan; the vault holds the cap.
struct Row {
    uint16 lenderAprBps;
    uint64 minTenor;
    uint64 maxTenor; // zero is no row
    uint128 maxPrincipal;
}

/// @notice A token as `InKindTerms` lists it at deploy.
struct TermsListing {
    address collateral;
    Row row;
}

/// @notice `InKindTerms`' write-once config.
struct InKindTermsConfig {
    address vault;
    address asset;
    address appraiser;
    uint256 minPrincipal;
    uint256 coverageWad;
    uint64 minTenor;
    uint64 maxTenor;
}

/// @notice A token an in-kind pair lists at deploy: its terms row, and the cap the vault holds for it.
struct Listing {
    address collateral;
    Row row;
    uint192 cap;
}

/// @notice An in-kind pair's own write-once figures: the terms' appraiser, floor and coverage, the vault's cap timelock, and the rail both take.
struct InKindConfig {
    address appraiser;
    uint256 minPrincipal;
    uint256 coverageWad;
    uint64 timelock; // the vault's cap timelock, which the terms read for rows and appointments
    uint64 minTenor; // the rail's floor
    uint64 maxTenor;
}

/// @notice An in-kind AceVault deployed the way a curator deploys one: InKindTerms at the vault's address-to-be, then the vault naming them.
/// @dev The terms are built from their artifact, so a suite compiles before their source exists and turns red at deploy.
/// @dev A deploy refused by either constructor reverts with that constructor's own error, bubbled whole.
library InKindVaults {
    Vm private constant vm = Vm(address(uint160(uint256(keccak256("hevm cheat code")))));

    uint192 internal constant UNCAPPED = type(uint192).max;
    string internal constant TERMS_ARTIFACT = "InKindTerms.sol:InKindTerms";

    /// @notice The product config of an in-kind vault naming `terms`: no door, drainable, the pair's timelock and rail.
    function product(address terms, InKindConfig memory ik) internal pure returns (ProductConfig memory) {
        return
            ProductConfig({
                terms: terms, door: address(0), inKind: true, drainable: true, capTimelock: ik.timelock, minTenor: ik.minTenor, maxTenor: ik.maxTenor
            });
    }

    /// @notice The terms' config for a vault at `vault` in `asset`, carrying the pair's rail.
    function termsConfig(address vault, address asset, InKindConfig memory ik) internal pure returns (InKindTermsConfig memory) {
        return InKindTermsConfig(vault, asset, ik.appraiser, ik.minPrincipal, ik.coverageWad, ik.minTenor, ik.maxTenor);
    }

    /// @notice The terms' half of each listing: its row, without the cap.
    function termsListings(Listing[] memory l) internal pure returns (TermsListing[] memory t) {
        t = new TermsListing[](l.length);
        for (uint256 i; i < l.length; i++) {
            t[i] = TermsListing(l[i].collateral, l[i].row);
        }
    }

    /// @notice The vault's deploy caps: every listing at its own cap, then the total at the vault's own address; the wildcard stays zero.
    function caps(address vault, Listing[] memory l, uint192 total) internal pure returns (CapListing[] memory c) {
        c = new CapListing[](l.length + 1);
        for (uint256 i; i < l.length; i++) {
            c[i] = CapListing(l[i].collateral, l[i].cap);
        }
        c[l.length] = CapListing(vault, total);
    }

    /// @notice The terms, at the address the caller's next create takes after them.
    /// @dev For a row whose subject is the vault constructor's own refusal: deploy these, arm the expectation, then `new AceVault`.
    function prepare(VaultConfig memory cfg, InKindConfig memory ik, Listing[] memory l, string memory name)
        internal
        returns (address terms, address predicted)
    {
        predicted = vm.computeCreateAddress(address(this), vm.getNonce(address(this)) + 1);
        terms = create(TERMS_ARTIFACT, abi.encode(termsConfig(predicted, cfg.asset, ik), termsListings(l), name));
        VaultSeed.fund(cfg, predicted);
    }

    /// @notice Deploy the pair by plain creates from the caller: the terms, then the vault at the address they name.
    function deploy(VaultConfig memory cfg, InKindConfig memory ik, Listing[] memory l, uint192 total, string memory name, string memory symbol)
        internal
        returns (AceVault v)
    {
        (address terms, address predicted) = prepare(cfg, ik, l, name);
        VaultSeed.fund(cfg, predicted);
        v = new AceVault(cfg, product(terms, ik), caps(predicted, l, total), name, symbol);
        require(address(v) == predicted, "InKindVaults: the vault landed off its predicted address");
    }

    /// @notice CREATE `artifact`'s creation code with `args` appended, from the caller; a constructor's revert is bubbled whole.
    function create(string memory artifact, bytes memory args) internal returns (address a) {
        bytes memory code = abi.encodePacked(vm.getCode(artifact), args);
        assembly ("memory-safe") {
            a := create(0, add(code, 0x20), mload(code))
            if iszero(a) {
                let p := mload(0x40)
                returndatacopy(p, 0, returndatasize())
                revert(p, returndatasize())
            }
        }
    }
}
