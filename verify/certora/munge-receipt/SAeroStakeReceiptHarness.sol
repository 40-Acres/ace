// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.36;

import {SAeroStakeReceipt} from "../src/entities/saero/SAeroStakeReceipt.sol";

/// @title SAeroStakeReceiptHarness
/// @notice SAeroStakeReceipt, its clone args answered from three storage words no function writes in place of its own code.
/// @dev A TEMPLATE: scripts/certora-munge-receipt.sh copies it into verify/certora/munged-receipt/harness/, where `_args` is virtual.
/// @dev The prover cannot model a clone's EXTCODECOPY of itself, so this is the one stand-in; the script's header argues it.
contract SAeroStakeReceiptHarness is SAeroStakeReceipt {
    address internal argPortfolio; // stands in for the clone's PORTFOLIO arg
    uint256 internal argStakeId; // stands in for the clone's STAKE_ID arg
    uint256 internal argUnits; // stands in for the clone's UNITS arg

    /// @param factory The receipt factory.
    /// @param vault The lender.
    /// @param door The vault's door.
    /// @param ace The hub.
    /// @param escrow The staking escrow.
    /// @param cash The vault's asset.
    /// @param custody The door's custody portfolio.
    /// @param portfolioFactory The 40 Acres saero-fixed factory.
    /// @param marketplace The 40 Acres marketplace.
    /// @dev It writes none of the three words: every rule starts from free storage, and no invariant's base clause reads them.
    constructor(
        address factory,
        address vault,
        address door,
        address ace,
        address escrow,
        address cash,
        address custody,
        address portfolioFactory,
        address marketplace
    ) SAeroStakeReceipt(factory, vault, door, ace, escrow, cash, custody, portfolioFactory, marketplace) {}

    /// @dev The clone's args, from the three words.
    function _args() internal view override returns (address, uint256, uint256) {
        return (argPortfolio, argStakeId, argUnits);
    }

    /// @notice Whether the reentrancy guard is clear, as a transaction finds it: a getter, so a liveness rule can start from it.
    /// @return True while no guarded call is running.
    function notEntered() external view returns (bool) {
        return !_reentrancyGuardEntered();
    }
}
