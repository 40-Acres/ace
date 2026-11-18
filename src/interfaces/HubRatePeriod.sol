// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.36;

import {Constants} from "../ace/hub/Constants.sol";
import {Probe} from "../ace/hub/libraries/Probe.sol";

error HubHasNoCode(); // the hub is write-once, so a product pointed at nothing could never be repaired
error HubRateNotPerYear(); // the hub names no RATE_PERIOD, or one other than 365 days, so its markets quote their rate in another unit

/// @title HubRatePeriod
/// @notice The unit check a product runs on the hub it binds for life: every rate the product quotes is bps per the hub's `RATE_PERIOD()`.
/// @notice A hub that answers nothing there prices each market per its own `minTenor`, so a product written for a year refuses it.
library HubRatePeriod {
    /// @notice Revert `HubHasNoCode` at an address with no code, else `HubRateNotPerYear` unless `hub` answers `RATE_PERIOD()` with one 365-day year.
    /// @dev A revert and a short answer are both refusals: `Probe.askWord`'s failure is never folded into an answer.
    /// @param hub The hub the product is about to bind.
    function requirePerYear(address hub) internal view {
        if (hub.code.length == 0) revert HubHasNoCode();
        (bool ok, uint256 period) = Probe.askWord(hub, abi.encodeWithSignature("RATE_PERIOD()"));
        if (!ok || period != Constants.SECONDS_PER_YEAR) revert HubRateNotPerYear();
    }
}
