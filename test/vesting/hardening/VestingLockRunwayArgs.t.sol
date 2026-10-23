// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.36;

import {Clones} from "@openzeppelin/contracts/proxy/Clones.sol";
import {LaunchLock, Leg} from "../../../src/entities/launch/LaunchLock.sol";
import {LockAccount} from "../../../src/entities/launch/LockAccount.sol";
import {LaunchFixture} from "../../launch/LaunchFixture.sol";

/// @title VestingLockRunwayArgs
/// @notice Every Runway account, for any beneficiary, schedule and launch curve: six args words, the sixth false, where predicted.
/// @dev The launch decoders read five words, and `abi.decode` ignores a trailing word, so they pass with any sixth word.
contract VestingLockRunwayArgsTest is LaunchFixture {
    /// @dev A lock of up to three legs on fuzzed curves, each inside the uint64 rail.
    function _fuzzLock(uint64 startSeed, uint64 buyerSeed, uint64[3] memory cliffs, uint64[3] memory durs, uint256 nSeed)
        internal
        returns (LaunchLock l, uint256 nLegs)
    {
        uint64 start = uint64(bound(startSeed, 0, type(uint64).max / 2));
        uint64 room = type(uint64).max - start;
        nLegs = nSeed % 4;
        Leg[] memory legs = new Leg[](nLegs);
        for (uint256 i; i < nLegs; ++i) {
            uint64 d = uint64(bound(durs[i], 0, room));
            legs[i] = Leg({beneficiary: alice, amount: 1, cliff: uint64(bound(cliffs[i], 0, d)), duration: d});
        }
        l = new LaunchLock(address(token), address(ace), start, uint64(bound(buyerSeed, 0, room)), legs);
    }

    /// @notice Arbitrary beneficiary and schedule: the account carries exactly the six-word layout with `false`, and lands where predicted.
    function testFuzz_EveryLaunchAccountCarriesSixWordsTheSixthFalse(
        address bene,
        uint256 sidSeed,
        uint64 startSeed,
        uint64 buyerSeed,
        uint64[3] memory cliffs,
        uint64[3] memory durs,
        uint256 nSeed
    ) public {
        (LaunchLock l, uint256 nLegs) = _fuzzLock(startSeed, buyerSeed, cliffs, durs, nSeed);
        vm.assume(!l.beneficiaryRefused(bene));
        _checkArgs(l, bene, sidSeed % (nLegs + 1));
    }

    /// @dev `bene`'s account on `sid` of `l`: deployed where predicted, its args exactly the six-word layout with `false`.
    function _checkArgs(LaunchLock l, address bene, uint256 sid) internal {
        address p = l.predict(bene, sid);
        assertEq(l.account(bene, sid), p, "predict != account");
        bytes memory args = Clones.fetchCloneArgs(p);
        assertEq(args.length, 6 * 32, "a launch account's args are not six words");
        (address b, uint256 s,,,, bool rev) = abi.decode(args, (address, uint256, uint64, uint64, uint64, bool));
        assertFalse(rev, "a launch account's sixth word is true");
        assertEq(abi.encode(b, s), abi.encode(bene, sid), "the args are another account's");
        (uint64 st0, uint64 c0, uint64 d0) = l.schedules(sid);
        assertEq(args, abi.encode(bene, sid, st0, c0, d0, false), "the args are not the six-word layout, word for word");
        address off = Clones.predictDeterministicAddressWithImmutableArgs(l.IMPLEMENTATION(), args, keccak256(abi.encode(bene, sid)), address(l));
        assertEq(off, p, "an off-chain predictor on the six-word layout misses the account");
        assertFalse(LockAccount(p).revoked(), "a launch account reads as revoked");
        vm.prank(address(l));
        vm.expectRevert(LockAccount.NotRevocable.selector);
        LockAccount(p).book(1);
    }
}
