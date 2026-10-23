// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.36;

import {ReentrancyGuardTransient} from "@openzeppelin/contracts/utils/ReentrancyGuardTransient.sol";

bytes4 constant GUARD_TRIP = ReentrancyGuardTransient.ReentrancyGuardReentrantCall.selector; // the guard's refusal, named once for every test asserting it
