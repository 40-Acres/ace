// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.36;

import {IERC165} from "@openzeppelin/contracts/utils/introspection/IERC165.sol";
import {IValidationHook} from "../../interfaces/ILaunchAuction.sol";
import {Schedule, ScheduleLock} from "../vesting/ScheduleLock.sol";

/// @notice One team allocation: `amount` into `beneficiary`'s account on its own curve, which starts at the lock's start.
struct Leg {
    address beneficiary;
    uint256 amount;
    uint64 cliff;
    uint64 duration;
}

/// @title LaunchLock
/// @notice One launch's lock: the team's and every auction buyer's allocation sits in a clone account per beneficiary and schedule.
/// @notice It is also the auction's bid gate: a bid is accepted only when its owner is the BUYER account of the beneficiary its hook data names.
/// @notice So every token the auction sells is paid into an account that can only vest it, release it, or pledge it to ACE.
/// @dev THE BUYER SCHEDULE IS ID 0; leg i's schedule is id i + 1, and the gate never accepts one, so team accounts are funded directly.
/// @dev No schedule here is revocable, so no account of a launch can ever be revoked.
/// @dev A bid names its account as owner before it exists; get-or-create means a stranger deploying it first cannot revert the bid.
/// @dev NOT ONE SHARED LOCK: the auction's exit and claim are permissionless and pay the bid's owner, so each owner is one beneficiary's account.
contract LaunchLock is ScheduleLock, IValidationHook, IERC165 {
    error BadHookData(); // the hook data is not exactly one clean address word
    error NotBuyerAccount(); // the bid's owner is not the buyer account of the beneficiary the hook data names

    uint256 public constant BUYER = 0; // the auction buyers' schedule id

    /// @param token The launch token.
    /// @param hub The ACE hub.
    /// @param start Where every schedule starts.
    /// @param buyerDuration The buyer schedule's linear vest, with no cliff.
    /// @param legs The team allocations; leg i's curve is schedule i + 1.
    constructor(address token, address hub, uint64 start, uint64 buyerDuration, Leg[] memory legs) ScheduleLock(token, hub) {
        _push(Schedule(start, 0, buyerDuration));
        for (uint256 i; i < legs.length; ++i) {
            _push(Schedule(start, legs[i].cliff, legs[i].duration));
        }
    }

    /// @notice The auction's bid gate: the bid's owner must be the BUYER account of the beneficiary the hook data names.
    /// @notice It deploys that account if it is not yet, so the account exists before any token or refund is paid to it.
    /// @dev The hook data is exactly one ABI word holding a clean address; anything else is refused rather than decoded.
    /// @dev Price, amount and sender are not judged: who pays for a bid is free, only who owns it is gated.
    /// @param owner The bid's owner, who the auction pays tokens and refunds to.
    /// @param hookData `abi.encode(beneficiary)`.
    function validate(uint256, uint128, address owner, address, bytes calldata hookData) external {
        if (hookData.length != 32) revert BadHookData();
        uint256 word = uint256(bytes32(hookData));
        if (word >> 160 != 0) revert BadHookData();
        if (owner != account(address(uint160(word)), BUYER)) revert NotBuyerAccount();
    }

    /// @notice ERC-165: the auction's validation hook, and ERC-165 itself.
    function supportsInterface(bytes4 id) external pure returns (bool) {
        return id == type(IValidationHook).interfaceId || id == type(IERC165).interfaceId;
    }

    /// @dev A launch revokes nothing.
    function _revocable(uint256) internal pure override returns (bool) {
        return false;
    }
}
