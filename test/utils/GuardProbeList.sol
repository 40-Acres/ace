// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.36;

import {Test} from "forge-std/Test.sol";
import {GUARD_TRIP} from "./GuardTrip.sol";

/// @notice A list of calls fired from inside some contract's guarded body, and what each one answered.
/// @dev The seam that fires `_runProbes` is each suite's own; this holds only the list and the verdict.
/// @dev Every probe is a low-level call, so a mis-aimed one records its own selector and never reads as a trip.
/// @dev The guard is the FIRST modifier on every verb probed through this, so no argument has to resolve.
abstract contract GuardProbeList is Test {
    /// @dev One probe: the label a failure prints, the address called, and the calldata it is called with.
    struct Probe {
        string label;
        address target;
        bytes data;
    }

    Probe[] internal probes;
    bytes4[] internal answers; // the revert selector each probe produced; zero when it went through
    bool internal probesArmed; // only the move the suite arms runs the list, and it runs it once

    function _probe(string memory label, address target, bytes memory data) internal {
        probes.push(Probe(label, target, data));
    }

    /// @dev Called from the suite's seam; a disarmed seam is a plain move, and the list never runs twice.
    function _runProbes() internal {
        if (!probesArmed) return;
        probesArmed = false;
        for (uint256 i; i < probes.length; i++) {
            (bool ok, bytes memory ret) = probes[i].target.call(probes[i].data);
            answers.push(ok ? bytes4(0) : bytes4(ret));
        }
    }

    /// @dev Every probe ran and every one was refused by the guard; the count pins the list to the surface.
    /// @param guarded How many guarded verbs the contract under test carries.
    function _assertEveryProbeTripped(uint256 guarded) internal view {
        assertEq(probes.length, guarded, "the guarded surface and this probe list disagree");
        assertEq(answers.length, probes.length, "a probe did not run: the seam never fired inside the body");
        for (uint256 i; i < probes.length; i++) {
            assertEq(answers[i], GUARD_TRIP, string.concat("re-entered without tripping the guard: ", probes[i].label));
        }
    }
}
