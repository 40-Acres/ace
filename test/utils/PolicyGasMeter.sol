// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.36;

import {Extension, IRollPolicy} from "../../src/interfaces/IRollPolicy.sol";

/// @notice Stands in as a lender's roll policy and forwards each ask to the real one, consenting only if that answer cost at most `BOUND` gas.
/// @dev The hub asks it in the real order, so the real policy's reads are warm or cold exactly as in a real extension.
/// @dev Conservative: the measured span also carries the forward's own call cost, so a yes means the real policy took less than `BOUND`.
contract PolicyGasMeter is IRollPolicy {
    IRollPolicy public immutable TARGET; // the policy whose cost is measured
    uint256 public immutable BOUND; // the most gas its answer may cost for the meter to pass it on

    constructor(IRollPolicy target, uint256 bound) {
        (TARGET, BOUND) = (target, bound);
    }

    /// @notice The target's answer when it cost at most `BOUND` gas, else a refusal.
    function admitsExtension(Extension calldata e, bytes calldata data) external view returns (bytes4) {
        uint256 g = gasleft();
        bytes4 a = TARGET.admitsExtension(e, data);
        return g - gasleft() <= BOUND ? a : bytes4(0);
    }
}
