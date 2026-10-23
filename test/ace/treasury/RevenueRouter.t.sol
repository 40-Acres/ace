// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.36;

import {Test} from "forge-std/Test.sol";
import {Vm} from "forge-std/Vm.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {Ownable} from "@openzeppelin/contracts/access/Ownable.sol";
import {RevenueRouter} from "../../../src/ace/treasury/RevenueRouter.sol";
import {GUARD_TRIP} from "../../utils/GuardTrip.sol";
import {MockERC20} from "../../mocks/MockERC20.sol";
import {MockBlockableERC20} from "../../mocks/MockBlockableERC20.sol";
import {MockBlacklistERC20} from "../../mocks/MockBlacklistERC20.sol";
import {MockNoReturnERC20} from "../../mocks/MockNoReturnERC20.sol";
import {MockFeeOnTransferERC20} from "../../mocks/MockFeeOnTransferERC20.sol";
import {MockHostileGasERC20} from "../../mocks/MockHostileGasERC20.sol";

/// @notice Answers `transfer` with `false` and moves nothing: the non-reverting refusal `trySafeTransfer` must catch.
contract ReturnsFalseToken {
    mapping(address => uint256) public balanceOf;

    function mint(address to, uint256 amount) external {
        balanceOf[to] += amount;
    }

    function transfer(address, uint256) external pure returns (bool) {
        return false;
    }
}

/// @notice Calls back into the router from inside `transfer`, keeps what the router answered, then pays normally.
/// @dev One shot: it disarms before calling, so a missing guard shows up as an empty answer rather than a recursion.
contract ReenteringToken {
    mapping(address => uint256) public balanceOf;
    RevenueRouter public router; // armed while non-zero
    bool public viaSetSink; // re-enter through `setSink` instead of `sweep`
    bytes public answer; // revert data from the inner call; empty means the inner call went through

    function arm(RevenueRouter r, bool setSinkPath) external {
        (router, viaSetSink) = (r, setSinkPath);
    }

    function mint(address to, uint256 amount) external {
        balanceOf[to] += amount;
    }

    function transfer(address to, uint256 amount) external returns (bool) {
        RevenueRouter r = router;
        if (address(r) != address(0)) {
            router = RevenueRouter(address(0));
            if (viaSetSink) {
                try r.setSink(address(0xE71)) {}
                catch (bytes memory e) {
                    answer = e;
                }
            } else {
                address[] memory list = new address[](1);
                list[0] = address(this);
                try r.sweep(list) {}
                catch (bytes memory e) {
                    answer = e;
                }
            }
        }
        balanceOf[msg.sender] -= amount;
        balanceOf[to] += amount;
        return true;
    }
}

/// @title RevenueRouterTest
/// @notice The protocol's fee destination: an owned pointer to a sink, and a permissionless sweep to it.
/// @notice Every row reads the same property from a different side: a unit either reaches the sink or stays here.
contract RevenueRouterTest is Test {
    RevenueRouter internal router;
    address internal owner = makeAddr("owner");
    address internal sink = makeAddr("sink");
    address internal stranger = makeAddr("stranger");

    function setUp() public {
        router = new RevenueRouter(owner, sink);
    }

    function _list(address a) internal pure returns (address[] memory l) {
        l = new address[](1);
        l[0] = a;
    }

    function _list(address a, address b) internal pure returns (address[] memory l) {
        l = new address[](2);
        (l[0], l[1]) = (a, b);
    }

    /// @dev Logs the router itself emitted since `vm.recordLogs`, so a token's own events never pad the count.
    function _routerLogs() internal returns (uint256 n) {
        Vm.Log[] memory logs = vm.getRecordedLogs();
        for (uint256 i; i < logs.length; ++i) {
            if (logs[i].emitter == address(router)) ++n;
        }
    }

    // ============ U1: construction ============

    function test_Constructor_SetsOwnerAndSink_AndAnnouncesTheSink() public {
        address predicted = vm.computeCreateAddress(address(this), vm.getNonce(address(this)));
        vm.expectEmit(true, true, false, true, predicted);
        emit RevenueRouter.SinkSet(address(0), sink);
        RevenueRouter r = new RevenueRouter(owner, sink);
        assertEq(address(r), predicted, "guard: the prediction named the contract that emitted");
        assertEq(r.owner(), owner, "owner is the constructor's");
        assertEq(r.sink(), sink, "sink is the constructor's");
        assertEq(r.pendingOwner(), address(0), "no handover in flight");
    }

    function test_Constructor_RefusesAZeroOwner() public {
        vm.expectRevert(abi.encodeWithSelector(Ownable.OwnableInvalidOwner.selector, address(0)));
        new RevenueRouter(address(0), sink);
    }

    function test_Constructor_RefusesAZeroSink() public {
        vm.expectRevert(RevenueRouter.InvalidSink.selector);
        new RevenueRouter(owner, address(0));
    }

    /// @notice A sink equal to the router would make every sweep a self-transfer that never leaves.
    function test_Constructor_RefusesItselfAsTheSink() public {
        address predicted = vm.computeCreateAddress(address(this), vm.getNonce(address(this)));
        vm.expectRevert(RevenueRouter.InvalidSink.selector);
        new RevenueRouter(owner, predicted);
    }

    // ============ U2: setSink ============

    function test_SetSink_OwnerRepoints_AndAnnouncesBothEnds() public {
        address next = makeAddr("next");
        vm.expectEmit(true, true, false, true, address(router));
        emit RevenueRouter.SinkSet(sink, next);
        vm.prank(owner);
        router.setSink(next);
        assertEq(router.sink(), next, "the sink moved");
    }

    function test_SetSink_RefusesAStranger() public {
        vm.prank(stranger);
        vm.expectRevert(abi.encodeWithSelector(Ownable.OwnableUnauthorizedAccount.selector, stranger));
        router.setSink(makeAddr("next"));
        assertEq(router.sink(), sink, "unchanged");
    }

    function test_SetSink_RefusesZero() public {
        vm.prank(owner);
        vm.expectRevert(RevenueRouter.InvalidSink.selector);
        router.setSink(address(0));
        assertEq(router.sink(), sink, "unchanged");
    }

    function test_SetSink_RefusesTheRouterItself() public {
        vm.prank(owner);
        vm.expectRevert(RevenueRouter.InvalidSink.selector);
        router.setSink(address(router));
        assertEq(router.sink(), sink, "unchanged");
    }

    // ============ U3-U5: the sweep ============

    /// @notice Two quotes of different decimals leave in one call, each whole.
    function test_Sweep_DeliversEachListedTokenWhole() public {
        MockERC20 t6 = new MockERC20("USD Coin", "USDC", 6);
        MockERC20 t18 = new MockERC20("Wrapped Ether", "WETH", 18);
        t6.mint(address(router), 1_234e6);
        t18.mint(address(router), 5e18);

        vm.expectEmit(true, true, false, true, address(router));
        emit RevenueRouter.Swept(address(t6), sink, 1_234e6);
        vm.expectEmit(true, true, false, true, address(router));
        emit RevenueRouter.Swept(address(t18), sink, 5e18);
        router.sweep(_list(address(t6), address(t18)));

        assertEq(t6.balanceOf(sink), 1_234e6, "6-decimal quote delivered");
        assertEq(t18.balanceOf(sink), 5e18, "18-decimal quote delivered");
        assertEq(t6.balanceOf(address(router)), 0, "nothing left behind");
        assertEq(t18.balanceOf(address(router)), 0, "nothing left behind");
    }

    /// @notice The sweep is a crank: anyone may turn it, and it can only ever pay the sink.
    function test_Sweep_IsPermissionless() public {
        MockERC20 t = new MockERC20("USD Coin", "USDC", 6);
        t.mint(address(router), 7e6);
        vm.prank(stranger);
        router.sweep(_list(address(t)));
        assertEq(t.balanceOf(sink), 7e6, "a stranger's sweep pays the sink");
        assertEq(t.balanceOf(stranger), 0, "and never the caller");
    }

    /// @notice A token holding nothing here is skipped: no transfer, no event.
    /// @dev The call count is what makes this non-vacuous: a zero transfer to a healthy token also moves nothing.
    function test_Sweep_SkipsAZeroBalance_WithoutCallingTheToken() public {
        MockERC20 t = new MockERC20("USD Coin", "USDC", 6);
        vm.expectCall(address(t), abi.encodeWithSelector(IERC20.transfer.selector), 0);
        vm.recordLogs();
        router.sweep(_list(address(t)));
        assertEq(_routerLogs(), 0, "no Swept(0) noise for an empty token");
    }

    /// @notice A token listed twice pays once: the second pass finds the balance already gone.
    function test_Sweep_ADuplicatedTokenDeliversOnce() public {
        MockERC20 t = new MockERC20("USD Coin", "USDC", 6);
        t.mint(address(router), 9e6);
        vm.recordLogs();
        router.sweep(_list(address(t), address(t)));
        assertEq(_routerLogs(), 1, "one Swept, not a second one for zero");
        assertEq(t.balanceOf(sink), 9e6, "delivered once, whole");
    }

    /// @notice An empty list is a no-op, not a revert.
    function test_Sweep_AnEmptyListDoesNothing() public {
        vm.recordLogs();
        router.sweep(new address[](0));
        assertEq(_routerLogs(), 0, "nothing to announce");
    }

    // ============ U6-U7: a refusing token never blocks the others ============

    /// @notice A quote that refuses the sink keeps its balance here, and the next token still leaves.
    /// @notice Repointing the sink is the recovery: the parked balance goes out on the next sweep.
    function test_Sweep_ASinkTheTokenRefusesParksThatTokenOnly_AndARepointRecovers() public {
        MockBlockableERC20 blocked = new MockBlockableERC20("USD Coin", "USDC", 6);
        MockERC20 good = new MockERC20("Wrapped Ether", "WETH", 18);
        blocked.mint(address(router), 100e6);
        good.mint(address(router), 1e18);
        blocked.setBlocked(sink, true);

        vm.expectEmit(true, true, false, true, address(router));
        emit RevenueRouter.SweepFailed(address(blocked), sink, 100e6);
        vm.expectEmit(true, true, false, true, address(router));
        emit RevenueRouter.Swept(address(good), sink, 1e18);
        router.sweep(_list(address(blocked), address(good)));

        assertEq(blocked.balanceOf(address(router)), 100e6, "the refused balance stays here");
        assertEq(good.balanceOf(sink), 1e18, "the sibling was not held hostage");

        address next = makeAddr("next");
        vm.prank(owner);
        router.setSink(next);
        vm.expectEmit(true, true, false, true, address(router));
        emit RevenueRouter.Swept(address(blocked), next, 100e6);
        router.sweep(_list(address(blocked)));
        assertEq(blocked.balanceOf(next), 100e6, "the repointed sink receives what was parked");
    }

    function test_Sweep_ABlacklistingQuoteParksItsBalance() public {
        MockBlacklistERC20 t = new MockBlacklistERC20("USD Coin", "USDC", 6);
        t.mint(address(router), 50e6);
        t.setBlacklisted(sink, true);
        vm.expectEmit(true, true, false, true, address(router));
        emit RevenueRouter.SweepFailed(address(t), sink, 50e6);
        router.sweep(_list(address(t)));
        assertEq(t.balanceOf(address(router)), 50e6, "parked, not lost");
    }

    /// @notice A token that answers `false` without reverting is a refusal too, and nothing moved.
    function test_Sweep_AReturnsFalseTokenIsARefusal() public {
        ReturnsFalseToken t = new ReturnsFalseToken();
        t.mint(address(router), 3e18);
        vm.expectEmit(true, true, false, true, address(router));
        emit RevenueRouter.SweepFailed(address(t), sink, 3e18);
        router.sweep(_list(address(t)));
        assertEq(t.balanceOf(address(router)), 3e18, "the balance is still here");
    }

    /// @notice USDT's shape: `transfer` returns nothing at all, which is success.
    function test_Sweep_ANoReturnTokenDelivers() public {
        MockNoReturnERC20 t = new MockNoReturnERC20("Tether USD", "USDT", 6);
        t.mint(address(router), 20e6);
        vm.expectEmit(true, true, false, true, address(router));
        emit RevenueRouter.Swept(address(t), sink, 20e6);
        router.sweep(_list(address(t)));
        assertEq(t.balanceOf(sink), 20e6, "delivered");
    }

    /// @notice `Swept` reports what the router SENT; what the sink receives is the token's business.
    function test_Sweep_AFeeOnTransferTokenReportsTheAmountSent() public {
        MockFeeOnTransferERC20 t = new MockFeeOnTransferERC20("Fee Token", "FEE", 18, 100);
        t.mint(address(router), 1_000e18);
        vm.expectEmit(true, true, false, true, address(router));
        emit RevenueRouter.Swept(address(t), sink, 1_000e18);
        router.sweep(_list(address(t)));
        assertEq(t.balanceOf(sink), 990e18, "the sink receives net of the token's own fee");
        assertEq(t.balanceOf(address(router)), 0, "and the router holds nothing");
    }

    // ============ U8: hostile gas ============

    /// @notice A token that pays and then answers a 1 MiB return bomb is reported failed, and nothing is lost.
    /// @dev Only the first word is copied, so the bomb bills the token; the sibling after it still leaves.
    /// @dev The EVENT is wrong here and the BALANCE is right: the token paid, then answered something other than true.
    function test_Sweep_AReturnBombIsContained() public {
        MockHostileGasERC20 bomb = new MockHostileGasERC20("Bomb", "BOMB", 18);
        MockERC20 good = new MockERC20("USD Coin", "USDC", 6);
        bomb.mint(address(router), 4e18);
        good.mint(address(router), 4e6);
        bomb.setBombWords(32_768);

        vm.expectEmit(true, true, false, true, address(router));
        emit RevenueRouter.SweepFailed(address(bomb), sink, 4e18);
        router.sweep(_list(address(bomb), address(good)));

        assertEq(bomb.balanceOf(address(router)) + bomb.balanceOf(sink), 4e18, "every unit is somewhere it was sent");
        assertEq(bomb.balanceOf(sink), 4e18, "the token did pay before it answered garbage");
        assertEq(good.balanceOf(sink), 4e6, "the sibling still left");
    }

    /// @notice A token that burns every gas unit it is handed fails only its own entry: the router finishes on its 1/64.
    /// @dev The test caps its own call's gas, or the burner would spin through the whole test budget.
    /// @dev Paired with a sibling, the retained 1/64 may not cover the sibling: the caller picks the list, so leave it off.
    function test_Sweep_AGasBurnerFailsOnlyItsOwnEntry() public {
        MockHostileGasERC20 burner = new MockHostileGasERC20("Burner", "BURN", 18);
        MockERC20 good = new MockERC20("USD Coin", "USDC", 6);
        burner.mint(address(router), 6e18);
        good.mint(address(router), 6e6);
        burner.setBurnAll(true);

        vm.expectEmit(true, true, false, true, address(router));
        emit RevenueRouter.SweepFailed(address(burner), sink, 6e18);
        router.sweep{gas: 3_000_000}(_list(address(burner)));
        assertEq(burner.balanceOf(address(router)), 6e18, "the burner never moved a unit");

        router.sweep(_list(address(good)));
        assertEq(good.balanceOf(sink), 6e6, "a list without the burner delivers");
    }

    // ============ U9: re-entrance ============

    /// @notice A token that calls `sweep` from inside its own transfer is refused by the guard, and still pays.
    function test_Sweep_ReenteringSweepIsRefused() public {
        ReenteringToken t = new ReenteringToken();
        t.mint(address(router), 8e18);
        t.arm(router, false);
        router.sweep(_list(address(t)));
        assertEq(t.answer(), abi.encodeWithSelector(GUARD_TRIP), "the inner sweep hit the guard");
        assertEq(t.balanceOf(sink), 8e18, "the outer sweep completed");
    }

    /// @notice Even the OWNER cannot repoint mid-sweep: `setSink` shares the lock.
    /// @dev The token is made the owner so `onlyOwner` passes and the guard is the only thing left to refuse.
    function test_SetSink_ReenteringFromASweepIsRefused() public {
        ReenteringToken t = new ReenteringToken();
        RevenueRouter r = new RevenueRouter(address(t), sink);
        t.mint(address(r), 8e18);
        t.arm(r, true);
        address[] memory list = _list(address(t));
        r.sweep(list);
        assertEq(t.answer(), abi.encodeWithSelector(GUARD_TRIP), "the inner setSink hit the guard");
        assertEq(r.sink(), sink, "the sink did not move");
        assertEq(t.balanceOf(sink), 8e18, "the sweep paid the sink it read at entry");
    }

    // ============ U10: no ETH ============

    /// @notice The router holds ERC-20s only; a plain ETH send is refused rather than stranded.
    function test_RefusesETH() public {
        vm.deal(address(this), 1 ether);
        (bool ok,) = address(router).call{value: 1 ether}("");
        assertFalse(ok, "no receive");
        (ok,) = address(router).call{value: 1 ether}(hex"deadbeef");
        assertFalse(ok, "no fallback");
        assertEq(address(router).balance, 0, "nothing arrived");
    }

    // ============ U11-U12: ownership ============

    /// @notice Handover is two-step: the old owner keeps the pen until the new one accepts.
    function test_Ownership_HandoverIsTwoStep() public {
        address heir = makeAddr("heir");
        vm.prank(owner);
        router.transferOwnership(heir);
        assertEq(router.owner(), owner, "nothing moved on the offer");
        assertEq(router.pendingOwner(), heir, "the offer is recorded");

        vm.prank(heir);
        vm.expectRevert(abi.encodeWithSelector(Ownable.OwnableUnauthorizedAccount.selector, heir));
        router.setSink(makeAddr("x"));

        vm.prank(heir);
        router.acceptOwnership();
        assertEq(router.owner(), heir, "the heir holds it after accepting");

        vm.prank(owner);
        vm.expectRevert(abi.encodeWithSelector(Ownable.OwnableUnauthorizedAccount.selector, owner));
        router.setSink(makeAddr("x"));

        vm.prank(heir);
        router.setSink(makeAddr("y"));
        assertEq(router.sink(), makeAddr("y"), "and can repoint");
    }

    /// @notice Renouncing freezes the sink for good, and the sweep keeps running.
    function test_Ownership_RenounceFreezesTheSink_AndTheSweepSurvives() public {
        MockERC20 t = new MockERC20("USD Coin", "USDC", 6);
        vm.prank(owner);
        router.renounceOwnership();
        assertEq(router.owner(), address(0), "renounced");

        vm.prank(owner);
        vm.expectRevert(abi.encodeWithSelector(Ownable.OwnableUnauthorizedAccount.selector, owner));
        router.setSink(makeAddr("x"));
        assertEq(router.sink(), sink, "the sink is final");

        t.mint(address(router), 11e6);
        vm.prank(stranger);
        router.sweep(_list(address(t)));
        assertEq(t.balanceOf(sink), 11e6, "revenue still reaches the frozen sink");
    }

    /// @notice A renounce kills a pending handover: nobody can pick the key back up.
    function test_Ownership_RenounceCancelsAPendingHandover() public {
        address heir = makeAddr("heir");
        vm.startPrank(owner);
        router.transferOwnership(heir);
        router.renounceOwnership();
        vm.stopPrank();
        assertEq(router.pendingOwner(), address(0), "the offer died with the key");

        vm.prank(heir);
        vm.expectRevert(abi.encodeWithSelector(Ownable.OwnableUnauthorizedAccount.selector, heir));
        router.acceptOwnership();
    }

    // ============ U13: conservation ============

    /// @notice Whatever the amounts and whichever token refuses, every unit is either at the sink or still here.
    function testFuzz_Sweep_ConservesEveryUnit(uint256 a, uint256 b, bool blockA) public {
        a = bound(a, 0, 1e30);
        b = bound(b, 0, 1e30);
        MockBlockableERC20 ta = new MockBlockableERC20("A", "A", 18);
        MockERC20 tb = new MockERC20("B", "B", 6);
        ta.mint(address(router), a);
        tb.mint(address(router), b);
        if (blockA) ta.setBlocked(sink, true);

        router.sweep(_list(address(ta), address(tb)));

        assertEq(ta.balanceOf(address(router)) + ta.balanceOf(sink), a, "A conserved");
        assertEq(ta.balanceOf(sink), blockA ? 0 : a, "A is all-or-nothing");
        assertEq(tb.balanceOf(sink), b, "B always leaves");
        assertEq(tb.balanceOf(address(router)), 0, "B leaves nothing behind");
    }

    // ============ U14: every entry is judged alone, in order ============

    /// @notice Every outcome in one list: each entry is judged on its own, in order, and no outcome ends the loop.
    /// @dev The empty entry LEADS, so a skip that ended the loop instead of continuing it would deliver nothing at all.
    /// @dev The one-wei entry is the smallest balance that must leave rather than be skipped.
    function test_Sweep_EachEntryIsJudgedAlone_InAMixedList() public {
        MockERC20 empty = new MockERC20("Empty", "EMPTY", 18);
        MockERC20 dust = new MockERC20("Dust", "DUST", 18);
        MockBlockableERC20 blocked = new MockBlockableERC20("USD Coin", "USDC", 6);
        ReturnsFalseToken refuses = new ReturnsFalseToken();
        MockERC20 good = new MockERC20("Wrapped Ether", "WETH", 18);
        dust.mint(address(router), 1);
        blocked.mint(address(router), 70e6);
        refuses.mint(address(router), 2e18);
        good.mint(address(router), 3e18);
        blocked.setBlocked(sink, true);

        address[] memory list = new address[](6);
        (list[0], list[1], list[2]) = (address(empty), address(dust), address(blocked));
        (list[3], list[4], list[5]) = (address(refuses), address(good), address(empty));

        vm.recordLogs();
        vm.expectEmit(true, true, false, true, address(router));
        emit RevenueRouter.Swept(address(dust), sink, 1);
        vm.expectEmit(true, true, false, true, address(router));
        emit RevenueRouter.SweepFailed(address(blocked), sink, 70e6);
        vm.expectEmit(true, true, false, true, address(router));
        emit RevenueRouter.SweepFailed(address(refuses), sink, 2e18);
        vm.expectEmit(true, true, false, true, address(router));
        emit RevenueRouter.Swept(address(good), sink, 3e18);
        router.sweep(list);

        assertEq(_routerLogs(), 4, "four events: the two empty entries announce nothing");
        assertEq(dust.balanceOf(sink), 1, "one wei leaves");
        assertEq(blocked.balanceOf(address(router)), 70e6, "the blocked entry parks whole");
        assertEq(refuses.balanceOf(address(router)), 2e18, "the false-answering entry parks whole");
        assertEq(good.balanceOf(sink), 3e18, "the entry after two refusals still leaves");
        assertEq(good.balanceOf(address(router)), 0, "and leaves nothing behind");
    }

    /// @notice Any mix of empty, refusing and paying entries: each lands by its own outcome, and only non-empty ones announce.
    function testFuzz_Sweep_EveryEntryIsJudgedAlone(uint8 emptyMask, uint8 blockedMask, uint256 seed) public {
        uint256 n = 5;
        MockBlockableERC20[] memory ts = new MockBlockableERC20[](n);
        uint256[] memory amt = new uint256[](n);
        address[] memory list = new address[](n);
        uint256 announced;
        for (uint256 i; i < n; ++i) {
            ts[i] = new MockBlockableERC20("T", "T", 18);
            list[i] = address(ts[i]);
            if ((emptyMask >> i) & 1 == 0) amt[i] = bound(uint256(keccak256(abi.encode(seed, i))), 1, 1e30);
            ts[i].mint(address(router), amt[i]);
            if ((blockedMask >> i) & 1 == 1) ts[i].setBlocked(sink, true);
            if (amt[i] != 0) ++announced;
        }

        vm.recordLogs();
        router.sweep(list);

        assertEq(_routerLogs(), announced, "one event per non-empty entry, none for an empty one");
        for (uint256 i; i < n; ++i) {
            bool parks = (blockedMask >> i) & 1 == 1;
            assertEq(ts[i].balanceOf(sink), parks ? 0 : amt[i], "a paying entry leaves whole");
            assertEq(ts[i].balanceOf(address(router)), parks ? amt[i] : 0, "a refusing entry parks whole");
        }
    }

    /// @notice Given gas, a burner BESIDE a sibling still fails only itself: the kept 1/64 carries the sibling out.
    /// @dev The call is capped so the spin ends; 1/64 of ten million is ~150k, several sibling transfers' worth.
    /// @dev So a burner that fails a mixed call is a gas budget the caller chose, never a unit taken.
    function test_Sweep_AGasBurnerBesideASiblingFailsOnlyItself_GivenGas() public {
        MockHostileGasERC20 burner = new MockHostileGasERC20("Burner", "BURN", 18);
        MockERC20 good = new MockERC20("USD Coin", "USDC", 6);
        burner.mint(address(router), 6e18);
        good.mint(address(router), 6e6);
        burner.setBurnAll(true);

        vm.expectEmit(true, true, false, true, address(router));
        emit RevenueRouter.SweepFailed(address(burner), sink, 6e18);
        vm.expectEmit(true, true, false, true, address(router));
        emit RevenueRouter.Swept(address(good), sink, 6e6);
        router.sweep{gas: 10_000_000}(_list(address(burner), address(good)));

        assertEq(burner.balanceOf(address(router)), 6e18, "the burner never moved a unit");
        assertEq(good.balanceOf(sink), 6e6, "the sibling after it still left");
    }

    /// @notice An entry whose `balanceOf` cannot answer fails the whole call, and the call rolls back whole.
    /// @dev Pinned rather than fixed: the caller picks the list, so a codeless entry is simply left off it.
    function test_Sweep_AnEntryWhoseBalanceOfRevertsFailsTheWholeCall() public {
        MockERC20 good = new MockERC20("USD Coin", "USDC", 6);
        good.mint(address(router), 5e6);
        vm.expectRevert();
        router.sweep(_list(address(good), makeAddr("not-a-token")));
        assertEq(good.balanceOf(address(router)), 5e6, "the sibling's delivery rolled back with the call");
        assertEq(good.balanceOf(sink), 0, "nothing reached the sink");
    }
}
