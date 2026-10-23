// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.36;

import {stdError} from "forge-std/StdError.sol";
import {Clones} from "@openzeppelin/contracts/proxy/Clones.sol";
import {IERC165} from "@openzeppelin/contracts/utils/introspection/IERC165.sol";
import {LaunchFixture} from "./LaunchFixture.sol";
import {IValidationHook} from "../../src/interfaces/ILaunchAuction.sol";
import {LaunchLock, Leg} from "../../src/entities/launch/LaunchLock.sol";
import {LockAccount} from "../../src/entities/launch/LockAccount.sol";
import {ScheduleLock} from "../../src/entities/vesting/ScheduleLock.sol";

/// @title LaunchLockTest
/// @notice The clone factory and the auction's bid gate: B5's local half, and L4.
/// @dev The real auction calls `validate` through try/catch and refuses the bid on ANY revert; these rows drive the hook directly.
contract LaunchLockTest is LaunchFixture {
    address internal carol = address(0xCA401);

    // ---- the bid gate ----

    /// @notice A bid owned by the bidder's predicted BUYER account passes, and the account exists afterwards.
    function test_B5_ValidateAcceptsTheBuyerAccount() public {
        address owner = lock.predict(carol, lock.BUYER());
        assertEq(owner.code.length, 0, "fixture: not deployed yet");
        lock.validate(1, 1, owner, stranger, abi.encode(carol));
        assertGt(owner.code.length, 0, "the gate deployed the account it accepted");
        assertTrue(lock.isAccount(owner), "and registered it");
    }

    /// @notice A bid owned by anyone else is refused: the beneficiary's own wallet, or a stranger's.
    function test_B5_ValidateRefusesWrongOwner() public {
        address strangers = lock.predict(stranger, 0);
        vm.expectRevert(LaunchLock.NotBuyerAccount.selector);
        lock.validate(1, 1, carol, carol, abi.encode(carol));
        vm.expectRevert(LaunchLock.NotBuyerAccount.selector);
        lock.validate(1, 1, strangers, carol, abi.encode(carol));
    }

    /// @notice A bid owned by a TEAM account is refused: team schedules are reachable only by direct funding.
    function test_B5_ValidateRefusesTeamSchedule() public {
        address cliffAcct = lock.predict(carol, TEAM_CLIFF);
        address linearAcct = lock.predict(carol, TEAM_LINEAR);
        vm.expectRevert(LaunchLock.NotBuyerAccount.selector);
        lock.validate(1, 1, cliffAcct, carol, abi.encode(carol));
        vm.expectRevert(LaunchLock.NotBuyerAccount.selector);
        lock.validate(1, 1, linearAcct, carol, abi.encode(carol));
    }

    /// @notice Empty or garbage hook data is refused by name, never decoded into some beneficiary.
    function test_B5_ValidateRefusesBadHookData() public {
        address owner = lock.predict(carol, lock.BUYER());
        vm.expectRevert(LaunchLock.BadHookData.selector);
        lock.validate(1, 1, owner, carol, "");
        vm.expectRevert(LaunchLock.BadHookData.selector);
        lock.validate(1, 1, owner, carol, abi.encodePacked(carol)); // 20 bytes, not a word
        vm.expectRevert(LaunchLock.BadHookData.selector);
        lock.validate(1, 1, owner, carol, abi.encode(carol, uint256(1))); // two words
        vm.expectRevert(LaunchLock.BadHookData.selector);
        lock.validate(1, 1, owner, carol, abi.encode(uint256(uint160(carol)) | (uint256(1) << 200))); // dirty upper bits
    }

    /// @notice A bid naming a beneficiary the lock refuses fails at the gate, before any token can land.
    function test_B5_ValidateRefusesBadBeneficiary() public {
        address zeros = lock.predict(address(0), 0);
        vm.expectRevert(ScheduleLock.BadBeneficiary.selector);
        lock.validate(1, 1, zeros, carol, abi.encode(address(0)));
    }

    // ---- L4 and the factory ----

    /// @notice A stranger deploying the account first cannot block the bid: creation is get-or-create.
    function test_L4_FrontRunCloneDeployStillLetsTheBidThrough() public {
        uint256 buyerId = lock.BUYER();
        vm.prank(stranger);
        address early = lock.account(carol, buyerId);
        lock.validate(1, 1, early, carol, abi.encode(carol));
        assertEq(lock.account(carol, buyerId), early, "the second create returned the same account");
    }

    /// @notice The account sits at the predicted address and carries its beneficiary and schedule in its own code.
    function test_AccountIsPredictableAndCarriesItsArgs() public {
        address a = lock.account(carol, TEAM_LINEAR);
        assertEq(a, lock.predict(carol, TEAM_LINEAR), "predicted");
        LockAccount la = LockAccount(a);
        assertEq(la.beneficiary(), carol, "beneficiary");
        (address bene, uint256 sid, uint64 start, uint64 cliff, uint64 duration) =
            abi.decode(Clones.fetchCloneArgs(a), (address, uint256, uint64, uint64, uint64));
        assertEq(bene, carol, "the args' beneficiary");
        assertEq(sid, TEAM_LINEAR, "schedule id");
        (uint64 s0, uint64 c0, uint64 d0) = lock.schedules(TEAM_LINEAR);
        assertEq(start, s0, "start");
        assertEq(cliff, c0, "cliff");
        assertEq(duration, d0, "duration");
        assertEq(la.TOKEN(), address(token), "token");
        assertEq(la.HUB(), address(ace), "hub");
        assertEq(la.LAUNCH(), address(lock), "launch");
    }

    /// @notice One account per beneficiary and schedule: the same beneficiary on two schedules has two accounts.
    function test_OneAccountPerBeneficiaryAndSchedule() public {
        assertTrue(lock.predict(carol, lock.BUYER()) != lock.predict(carol, TEAM_CLIFF), "two schedules, one address");
    }

    /// @notice The beneficiaries that would strand or recycle a release are refused at creation.
    function test_BadBeneficiariesRefused() public {
        address[7] memory bad = [address(0), address(token), address(ace), address(pm), ace.POSITION_TITLE(), address(lock), address(acct)];
        for (uint256 i; i < bad.length; ++i) {
            vm.expectRevert(ScheduleLock.BadBeneficiary.selector);
            lock.account(bad[i], 0);
        }
    }

    /// @notice The refusal `account` applies is the public view a caller reads, so the two cannot disagree.
    function test_BeneficiaryRefusedViewMatchesAccount() public {
        address[8] memory bad =
            [address(0), address(token), address(ace), address(pm), ace.POSITION_TITLE(), address(lock), address(acct), lock.IMPLEMENTATION()];
        for (uint256 i; i < bad.length; ++i) {
            assertTrue(lock.beneficiaryRefused(bad[i]), string.concat("the view admits bad #", vm.toString(i)));
        }
        assertFalse(lock.beneficiaryRefused(carol), "the view refuses a plain wallet");
        assertEq(lock.POSITION_MANAGER(), address(pm), "the custodian is the lock's own immutable");
        assertEq(lock.POSITION_TITLE(), ace.POSITION_TITLE(), "and the title collection");
    }

    /// @notice The account implementation is refused as a beneficiary: a release into it would sit in code no clone reaches.
    function test_ImplementationRefusedAsBeneficiary() public {
        address impl = lock.IMPLEMENTATION();
        vm.expectRevert(ScheduleLock.BadBeneficiary.selector);
        lock.account(impl, 0);
    }

    /// @notice Creating an account reads no getter off the implementation: the custodian and title are the lock's own immutables.
    function test_AccountCreationReadsNoImplementationGetter() public {
        address impl = lock.IMPLEMENTATION();
        vm.expectCall(impl, abi.encodeWithSignature("POSITION_MANAGER()"), 0);
        vm.expectCall(impl, abi.encodeWithSignature("POSITION_TITLE()"), 0);
        lock.account(carol, 0);
    }

    /// @notice An undeployed account of this lock as a beneficiary is NOT recognisable; a RELEASE into one is benign.
    /// @notice A release into it lands as a donation to that account and stays locked there, on its own schedule, for its own beneficiary.
    function test_PredictedAccountAsBeneficiaryIsLockedNotStranded() public {
        address inner = lock.predict(carol, TEAM_LINEAR);
        LockAccount outer = LockAccount(lock.account(inner, 0));
        _land(address(outer), ALLOC);
        _warpTo(T0 + 31 days);
        vm.prank(inner);
        outer.release(ALLOC);
        assertEq(token.balanceOf(inner), ALLOC, "the release reached the predicted account");
        LockAccount innerAcct = LockAccount(lock.account(carol, TEAM_LINEAR));
        assertEq(innerAcct.totalAllocation(), ALLOC, "and counts there as its allocation");
        assertLt(innerAcct.releasable(), ALLOC, "where it vests again rather than leaving");
    }

    /// @notice A schedule id the lock does not hold, the first past the last, panics on both the create and the prediction.
    function test_NoSuchSchedule() public {
        vm.expectRevert(stdError.indexOOBError);
        lock.account(carol, 3);
        vm.expectRevert(stdError.indexOOBError);
        lock.predict(carol, 3);
    }

    /// @notice A schedule id past the last panics on the array read, whether it is just past or far past, on the create and the prediction.
    function test_AnOutOfRangeScheduleIdPanics() public {
        vm.expectRevert(stdError.indexOOBError);
        lock.account(carol, type(uint256).max);
        vm.expectRevert(stdError.indexOOBError);
        lock.predict(carol, TEAM_LINEAR + 1);
    }

    /// @notice Each leg is its own schedule: leg i's curve is schedule i + 1, every one from the lock's start, after the buyer's at id 0.
    function test_EachLegIsItsOwnSchedule() public {
        Leg[] memory l = new Leg[](3);
        l[0] = Leg({beneficiary: carol, amount: 1, cliff: 30 days, duration: 90 days});
        l[1] = Leg({beneficiary: carol, amount: 1, cliff: 60 days, duration: 365 days});
        l[2] = Leg({beneficiary: stranger, amount: 1, cliff: 90 days, duration: 90 days});
        uint64 start = uint64(T0 + 7 days);
        LaunchLock ll = new LaunchLock(address(token), address(ace), start, 45 days, l);
        (uint64 s, uint64 c, uint64 d) = ll.schedules(0);
        assertEq(abi.encode(s, c, d), abi.encode(start, 0, 45 days), "the buyer schedule");
        for (uint256 i; i < l.length; ++i) {
            (s, c, d) = ll.schedules(i + 1);
            assertEq(abi.encode(s, c, d), abi.encode(start, l[i].cliff, l[i].duration), "a leg's schedule");
        }
        assertTrue(ll.predict(carol, 1) != ll.predict(carol, 2), "two legs of one beneficiary share an account");
        vm.expectRevert(stdError.indexOOBError);
        ll.predict(carol, 4);
    }

    /// @notice ERC-165: the auction's hook interface and ERC-165 itself, nothing else.
    function test_SupportsTheHookInterface() public view {
        assertEq(type(IValidationHook).interfaceId, bytes4(keccak256("validate(uint256,uint128,address,address,bytes)")), "the id is the one selector");
        assertTrue(lock.supportsInterface(type(IValidationHook).interfaceId), "hook");
        assertTrue(lock.supportsInterface(type(IERC165).interfaceId), "erc165");
        assertFalse(lock.supportsInterface(0xffffffff), "the invalid id");
    }

    // ---- the lock's construction rails ----

    /// @notice A leg's cliff past its duration, or a curve ending past uint64, is refused at construction.
    function test_ScheduleRails() public {
        Leg[] memory bad = new Leg[](1);
        bad[0] = Leg({beneficiary: carol, amount: 1, cliff: 31 days, duration: 30 days});
        vm.expectRevert(ScheduleLock.BadSchedule.selector);
        new LaunchLock(address(token), address(ace), uint64(T0), 30 days, bad);
        vm.expectRevert(ScheduleLock.BadSchedule.selector);
        new LaunchLock(address(token), address(ace), type(uint64).max, 1, new Leg[](0));
    }
}
