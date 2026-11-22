// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.36;

import {Constants} from "../ace/hub/Constants.sol";
import {Probe} from "../ace/hub/libraries/Probe.sol";
import {IAceProtocolShare} from "./IAceProtocolShare.sol";

/// @title HubProtocolShare
/// @notice The origination share an off-hub product prices a hub's fee at: the hub's own answer, or the ceiling where it gives none.
/// @notice A hub with no share view charged the ceiling as a constant, so the ceiling is its true share.
/// @dev `Probe.askWord`'s failure IS folded, deliberately: to the ceiling, a pre-view hub's true share, never to zero, which would under-quote.
library HubProtocolShare {
    /// @notice `hub`'s live share: one whole word at or under the ceiling, else the ceiling.
    /// @param hub The hub whose fee is being priced.
    /// @return The share, in bps of the lender fee.
    function shareOf(address hub) internal view returns (uint256) {
        (bool ok, uint256 s) = Probe.askWord(hub, abi.encodeCall(IAceProtocolShare.protocolShareBps, ()));
        return ok && s <= Constants.MAX_PROTOCOL_SHARE_BPS ? s : Constants.MAX_PROTOCOL_SHARE_BPS;
    }
}
