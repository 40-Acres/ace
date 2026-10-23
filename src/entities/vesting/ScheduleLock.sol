// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.36;

import {Clones} from "@openzeppelin/contracts/proxy/Clones.sol";
import {LockAccount} from "../launch/LockAccount.sol";

/// @notice One vesting curve, OpenZeppelin's VestingWalletCliff shape: nothing before `start + cliff`, linear from `start` to `start + duration`.
/// @dev A duration of zero is a single tranche at `start`; the cliff is in seconds after `start`, never after the duration.
struct Schedule {
    uint64 start;
    uint64 cliff;
    uint64 duration;
}

/// @title ScheduleLock
/// @notice A lock's shared half: a set of schedules, and one LockAccount clone per (beneficiary, schedule) over one token.
/// @dev ONE ACCOUNT PER (BENEFICIARY, SCHEDULE), at a CREATE2 address anyone can predict; its args are the six words `_argsAndSalt` writes.
/// @dev Creation is get-or-create, so a stranger deploying an account first changes nothing about it.
/// @dev The account code is deployed by this constructor, so every clone's LAUNCH is the lock; the derived lock says which schedules revoke.
abstract contract ScheduleLock {
    error BadSchedule(); // a cliff past the duration, or a curve ending past uint64
    error BadBeneficiary(); // an address a release would strand in, or recycle into, the protocol or this lock

    address public immutable TOKEN; // the token every account here locks
    address public immutable HUB; // the ACE hub every account here pledges into
    address public immutable IMPLEMENTATION; // the account code every clone runs, deployed here so a clone's code is this lock's choice
    address public immutable POSITION_MANAGER; // the hub's custodian, refused as a beneficiary
    address public immutable POSITION_TITLE; // the hub's title collection, refused as a beneficiary

    Schedule[] public schedules; // written once, at construction; an id past the last panics
    mapping(address => bool) public isAccount; // true for exactly the accounts this lock created

    /// @notice An account was created for `beneficiary` on schedule `scheduleId`.
    event AccountCreated(address indexed account, address indexed beneficiary, uint256 indexed scheduleId);

    /// @param token The token every account locks.
    /// @param hub The ACE hub.
    constructor(address token, address hub) {
        (TOKEN, HUB) = (token, hub);
        LockAccount impl = new LockAccount(token, hub);
        (IMPLEMENTATION, POSITION_MANAGER, POSITION_TITLE) = (address(impl), impl.POSITION_MANAGER(), impl.POSITION_TITLE());
    }

    /// @notice Where the account for `beneficiary` on schedule `scheduleId` lives, deployed or not.
    function predict(address beneficiary, uint256 scheduleId) public view returns (address) {
        (bytes memory args, bytes32 salt) = _argsAndSalt(beneficiary, scheduleId);
        return Clones.predictDeterministicAddressWithImmutableArgs(IMPLEMENTATION, args, salt);
    }

    /// @notice The account for `beneficiary` on schedule `scheduleId`, deployed now if it is not yet. Anyone may call it.
    /// @dev Refuses a beneficiary `beneficiaryRefused` names at creation only: a deployed account is returned whatever its beneficiary became.
    function account(address beneficiary, uint256 scheduleId) public returns (address a) {
        (bytes memory args, bytes32 salt) = _argsAndSalt(beneficiary, scheduleId);
        a = Clones.predictDeterministicAddressWithImmutableArgs(IMPLEMENTATION, args, salt);
        if (isAccount[a]) return a;
        if (beneficiaryRefused(beneficiary)) revert BadBeneficiary();
        isAccount[a] = true;
        Clones.cloneDeterministicWithImmutableArgs(IMPLEMENTATION, args, salt);
        emit AccountCreated(a, beneficiary, scheduleId);
    }

    /// @notice Whether `account` refuses `beneficiary`: an address a release would strand in, or recycle into, the protocol or this lock.
    /// @notice Zero, the token, the hub, its custodian and title, this lock, its account implementation, and any account it deployed.
    /// @dev An account it has only PREDICTED is not recognisable, since its address does not reveal its beneficiary.
    /// @dev A release into such an address is benign: a donation to that account, which vests it again for its own beneficiary.
    /// @dev The refusal can arrive LATE: once that account deploys, an account OF that beneficiary not yet deployed never can be.
    /// @dev Anyone can trigger it through get-or-create, so whoever relies on an account deploys it first.
    function beneficiaryRefused(address beneficiary) public view returns (bool) {
        return beneficiary == address(0) || beneficiary == TOKEN || beneficiary == HUB || beneficiary == POSITION_MANAGER || beneficiary == POSITION_TITLE
            || beneficiary == address(this) || beneficiary == IMPLEMENTATION || isAccount[beneficiary];
    }

    /// @dev A schedule is admitted only when its cliff sits inside it and its end fits uint64, so no account's curve can overflow.
    function _push(Schedule memory s) internal {
        if (s.cliff > s.duration || uint256(s.start) + s.duration > type(uint64).max) revert BadSchedule();
        schedules.push(s);
    }

    /// @dev Whether schedule `scheduleId`'s accounts may be revoked: the sixth args word of every account on it.
    function _revocable(uint256 scheduleId) internal view virtual returns (bool);

    /// @dev The clone's immutable args carry its whole identity; the salt makes one address per (beneficiary, schedule).
    function _argsAndSalt(address beneficiary, uint256 scheduleId) private view returns (bytes memory args, bytes32 salt) {
        Schedule memory s = schedules[scheduleId];
        args = abi.encode(beneficiary, scheduleId, s.start, s.cliff, s.duration, _revocable(scheduleId));
        salt = keccak256(abi.encode(beneficiary, scheduleId));
    }
}
