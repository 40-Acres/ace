// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.36;

import {Clones} from "@openzeppelin/contracts/proxy/Clones.sol";
import {LaunchFixture} from "./LaunchFixture.sol";
import {MarketParams} from "../../src/ace/hub/Types.sol";
import {LaunchLock, Leg, Schedule} from "../../src/entities/launch/LaunchLock.sol";
import {LockAccount} from "../../src/entities/launch/LockAccount.sol";
import {ScheduleLock} from "../../src/entities/vesting/ScheduleLock.sol";

/// @title LaunchLockHardening
/// @notice The lock's rails at their own edges, the bid gate's word check at its lowest dirty bit, and the clone factory fuzzed.
/// @notice And the account's admission predicate, row by row.
contract LaunchLockHardeningTest is LaunchFixture {
    address internal carol = address(0xCA401);
    address internal team = address(0x7EA4);

    // ---- construction rails at their boundaries ----

    /// @dev Schedule `id` of `l`, as one struct.
    function _sched(LaunchLock l, uint256 id) internal view returns (Schedule memory s) {
        (s.start, s.cliff, s.duration) = l.schedules(id);
    }

    /// @notice The schedule rails accept their own edges: a leg's cliff equal to its duration, and a curve ending exactly at uint64's max.
    function test_ScheduleRailEdgesAreAccepted() public {
        Leg[] memory one = new Leg[](1);
        one[0] = Leg({beneficiary: carol, amount: 1, cliff: 30 days, duration: 30 days});
        LaunchLock l = new LaunchLock(address(token), address(ace), uint64(T0), 30 days, one);
        assertEq(_sched(l, 1).cliff, 30 days, "a cliff equal to the duration was refused");

        uint64 start = type(uint64).max - 1 days;
        LaunchLock edge = new LaunchLock(address(token), address(ace), start, 1 days, new Leg[](0));
        LockAccount a = LockAccount(edge.account(carol, 0));
        _land(address(a), ALLOC);
        assertEq(a.vestedAmount(type(uint64).max), ALLOC, "a curve ending at uint64's max is not whole there");
        assertEq(a.vestedAmount(start + 12 hours), ALLOC / 2, "and is not linear before it");
    }

    /// @notice A bad leg's curve is refused like a bad buyer schedule, wherever the leg sits in the list.
    function test_BadTeamScheduleIsRefused() public {
        Leg[] memory l = new Leg[](3);
        (l[0], l[1]) = (_legs()[0], _legs()[1]);
        l[2] = Leg({beneficiary: carol, amount: 1, cliff: 2 days, duration: 1 days});
        vm.expectRevert(ScheduleLock.BadSchedule.selector);
        new LaunchLock(address(token), address(ace), _start(), 30 days, l);
        l[2] = Leg({beneficiary: carol, amount: 1, cliff: 0, duration: type(uint64).max});
        vm.expectRevert(ScheduleLock.BadSchedule.selector);
        new LaunchLock(address(token), address(ace), _start(), 30 days, l);
    }

    /// @notice `schedules` answers every id below the count with what the lock was built with, and panics at the count itself.
    function test_SchedulesAnswersBelowTheCountOnly() public {
        Schedule[] memory t = _team();
        for (uint256 i; i < t.length; ++i) {
            assertEq(abi.encode(_sched(lock, i + 1)), abi.encode(t[i]), "a team schedule was stored as another");
        }
        assertEq(abi.encode(_sched(lock, 0)), abi.encode(_buyer()), "the buyer schedule was stored as another");
        vm.expectRevert();
        lock.schedules(t.length + 1);
    }

    // ---- the bid gate ----

    /// @notice The first bit past an address is enough to refuse the word, and so is the last.
    function test_ValidateRefusesTheLowestAndHighestDirtyBits() public {
        address owner = lock.predict(carol, lock.BUYER());
        vm.expectRevert(LaunchLock.BadHookData.selector);
        lock.validate(1, 1, owner, carol, abi.encode(uint256(uint160(carol)) | (uint256(1) << 160)));
        vm.expectRevert(LaunchLock.BadHookData.selector);
        lock.validate(1, 1, owner, carol, abi.encode(uint256(uint160(carol)) | (uint256(1) << 255)));
        lock.validate(1, 1, owner, carol, abi.encode(carol));
        assertTrue(lock.isAccount(owner), "fixture: the clean word passes");
    }

    /// @notice Any dirt in the word's upper 96 bits is refused, whichever bits it sets.
    function testFuzz_ValidateRefusesAnyDirtyUpperWord(uint96 dirt) public {
        dirt = uint96(bound(dirt, 1, type(uint96).max));
        address owner = lock.predict(carol, lock.BUYER());
        vm.expectRevert(LaunchLock.BadHookData.selector);
        lock.validate(1, 1, owner, carol, abi.encode(uint256(uint160(carol)) | (uint256(dirt) << 160)));
    }

    /// @notice Price, amount and sender never decide a bid: for any of them, the beneficiary's buyer account passes and is deployed.
    function testFuzz_ValidateJudgesTheOwnerAlone(uint256 maxPrice, uint128 amount, address sender, address bene) public {
        vm.assume(!lock.beneficiaryRefused(bene));
        address owner = lock.predict(bene, lock.BUYER());
        lock.validate(maxPrice, amount, owner, sender, abi.encode(bene));
        assertTrue(lock.isAccount(owner), "the accepted owner is not a registered account");
        assertEq(LockAccount(owner).beneficiary(), bene, "the accepted owner is another beneficiary's");
        (, uint256 sid,,,) = abi.decode(Clones.fetchCloneArgs(owner), (address, uint256, uint64, uint64, uint64));
        assertEq(sid, lock.BUYER(), "the accepted owner is on another schedule");
    }

    // ---- account ----

    /// @notice The first create announces itself; a second is silent, deploys nothing, and returns the same account.
    function test_AccountAnnouncesOnceOnly() public {
        address a = lock.predict(carol, TEAM_LINEAR);
        vm.expectEmit(address(lock));
        emit ScheduleLock.AccountCreated(a, carol, TEAM_LINEAR);
        assertEq(lock.account(carol, TEAM_LINEAR), a, "the first create landed off the prediction");
        vm.recordLogs();
        assertEq(lock.account(carol, TEAM_LINEAR), a, "the second create returned another account");
        assertEq(vm.getRecordedLogs().length, 0, "the second create announced something");
    }

    /// @notice For any admitted beneficiary and any schedule, the account lands where predicted, carries its args, and is refused thereafter.
    function testFuzz_AccountLandsWherePredicted(address bene, uint256 sidSeed) public {
        vm.assume(!lock.beneficiaryRefused(bene));
        uint256 sid = sidSeed % (_legs().length + 1);
        address p = lock.predict(bene, sid);
        assertEq(lock.account(bene, sid), p, "the account landed off its prediction");
        LockAccount a = LockAccount(p);
        assertEq(a.beneficiary(), bene, "beneficiary");
        (address b, uint256 id, uint64 start, uint64 cliff, uint64 duration) = abi.decode(Clones.fetchCloneArgs(p), (address, uint256, uint64, uint64, uint64));
        assertEq(abi.encode(b, id), abi.encode(bene, sid), "the args' beneficiary and schedule id");
        assertEq(abi.encode(start, cliff, duration), abi.encode(_sched(lock, sid)), "the account runs another curve");
        assertTrue(lock.beneficiaryRefused(p), "a deployed account is not refused as a beneficiary");
    }

    // ---- the admission predicate ----

    /// @dev Alice's borrow on market `m`, whose params the hub is made to report as `p`.
    function _borrowOn(bytes32 m, MarketParams memory p) internal {
        vm.mockCall(address(ace), abi.encodeCall(ace.idToMarketParams, (m)), abi.encode(p));
        vm.prank(alice);
        acct.borrow(m, 1_000e18, _maxPrincipal(1_000e18), WEEK, _noBounds());
    }

    /// @notice The predicate, row by row through `borrow`: the token's recordless market opens; another collateral or a record is refused.
    function test_AdmitsTruthTable() public {
        MarketParams memory p = ace.idToMarketParams(id);
        assertEq(abi.encode(p.collateral, p.record), abi.encode(address(token), address(0)), "fixture: the token's recordless market");
        vm.prank(alice);
        acct.borrow(id, 1_000e18, _maxPrincipal(1_000e18), WEEK, _noBounds());
        assertEq(acct.pledged(), 1_000e18, "the token's recordless market did not open");

        bytes32 fake = keccak256("a reported market");
        p.collateral = address(usdc);
        vm.expectRevert(LockAccount.NotALaunchMarket.selector);
        _borrowOn(fake, p);
        p.collateral = address(token);
        p.record = address(0xEC0);
        vm.expectRevert(LockAccount.NotALaunchMarket.selector);
        _borrowOn(fake, p);
    }
}
