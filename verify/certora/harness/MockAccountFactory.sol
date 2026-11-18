// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.36;

/// @title MockAccountFactory
/// @notice The two reads `NftAccountRecord` makes on a factory, answered from storage the prover sets.
/// @dev REC-6 is about which pairs the record accepts, so the registry answer has to be free rather than fixed.
/// @dev `TERMS` is free too, so the record's dial writer is reachable and its gate is tested rather than always closed.
contract MockAccountFactory {
    mapping(address => bool) internal made; // whether this factory made that account
    address public TERMS; // the terms the record lets set its dials

    /// @notice Whether this factory made `account`.
    /// @param account The address asked about.
    /// @return True when the factory made it.
    function isAccount(address account) external view returns (bool) {
        return made[account];
    }
}
