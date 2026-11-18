// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.36;

import {AceVault} from "../../../src/curator/AceVault.sol";
import {CapListing, ProductConfig} from "../../../src/curator/AceVaultCaps.sol";
import {AceVaultFlows, VaultConfig} from "../../../src/curator/AceVaultFlows.sol";
import {AceVaultTail} from "../../../src/curator/AceVaultTail.sol";

/// @title CuratorVaultHarness
/// @notice AceVault, the vault a curated product names its terms on, plus three views: the vest maturity, the NAV mark and the suffix's match.
/// @notice Under via-IR the prover cannot analyse this constructor's storage, and a raw-slot read in a spec needs that.
/// @notice It adds getters and no state, so the layout is AceVault's and every method under test is its own.
/// @dev The terms contract is outside the scene: its entry-cap read is a raw static call the spec's catch-all answers.
contract CuratorVaultHarness is AceVault {
    constructor(VaultConfig memory cfg, ProductConfig memory pc, CapListing[] memory caps, string memory name_, string memory symbol_)
        AceVault(cfg, pc, caps, name_, symbol_)
    {}

    /// @notice When the deferred pile finishes vesting.
    function vestMaturity() external view returns (uint64) {
        return AceVaultFlows.layout().vestMaturity;
    }

    /// @notice The gross NAV the last sync observed, which every stamp is capped at.
    function navMark() external view returns (uint256) {
        return AceVaultFlows.layout().navMark;
    }

    /// @notice Whether the five suffix words are the ones the constructor packs from the named immutables, as every deploy leaves them.
    /// @dev The prover cannot run this constructor under via-IR, so a spec states this as a precondition; a forge test pins it on the real deploy.
    function tailMatches() external view returns (bool) {
        (bytes32 w0, bytes32 w1, bytes32 w2, bytes32 w3) = AceVaultTail.pack(ACE, CURATOR, GUARDIAN, asset(), CAP_TIMELOCK, IN_KIND);
        (w2, w3) = AceVaultTail.withTerms(w2, w3, TERMS);
        if (DOOR != address(0)) w0 = AceVaultTail.withDoor(w0);
        bool four = w0 == TAIL0 && w1 == TAIL1 && w2 == TAIL2 && w3 == TAIL3;
        return four && AceVaultTail.word4(TITLE, MIN_TENOR, MAX_TENOR) == TAIL4;
    }
}
