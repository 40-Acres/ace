// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.36;

import {console2} from "forge-std/Test.sol";
import {StdInvariant} from "forge-std/StdInvariant.sol";
import {LockAccount} from "../../src/entities/launch/LockAccount.sol";
import {LockAccountChecks} from "./LockAccountInvariants.t.sol";
import {LockAccountHandler} from "./LockAccountHandler.sol";

/// @title LockAccountTinyReleaseHandler
/// @notice The existing lock-account surface plus TINY releases: 1 to 1e6 wei, seconds apart, so the vesting floor is met at every step.
/// @notice A release of exactly what is releasable lands on `floor(total * elapsed / duration)` itself, the boundary a ceil would cross.
/// @dev Additive only: every inherited action is unchanged, and an over-release that LANDS is recorded in `breached`.
contract LockAccountTinyReleaseHandler is LockAccountHandler {
    constructor(uint256 scheduleId) LockAccountHandler(scheduleId) {}

    /// @dev Releases `w`, after probing one wei past what is releasable; a landed probe is a breach.
    function _releaseExactly(uint256 w) internal {
        uint256 r = acct.releasable();
        vm.prank(alice);
        try acct.release(r + 1) {
            breached = true;
        } catch {}
        if (w == 0 || w > r) return;
        vm.prank(alice);
        try acct.release(w) {
            hits["releaseTiny"]++;
        } catch {}
    }

    /// @notice A few seconds pass, then a 1 to 1e6 wei release, capped at what is releasable.
    function releaseTiny(uint256 seed, uint256 dtSeed) external {
        _warpBy(bound(dtSeed, 1, 600));
        uint256 r = acct.releasable();
        uint256 w = bound(seed, 1, 1e6);
        _releaseExactly(w < r ? w : r);
    }

    /// @notice A chain of up to forty tiny releases a minute apart, every fourth one taking exactly what is releasable.
    function releaseTinyChain(uint256 seed, uint256 countSeed) external {
        uint256 k = bound(countSeed, 1, 40);
        for (uint256 i; i < k; ++i) {
            uint256 rnd = uint256(keccak256(abi.encode(seed, i)));
            _warpBy(1 + (rnd % 60));
            uint256 r = acct.releasable();
            uint256 w = i % 4 == 3 ? r : 1 + ((rnd >> 16) % 1e6);
            _releaseExactly(w < r ? w : r);
        }
    }
}

/// @title LockAccountTinyReleaseInvariants
/// @notice The existing induction, `spent + pledges expiring by tau <= V(tau)` and `out <= V(now)`, under campaigns that add tiny releases.
/// @dev Every inherited verb stays targeted, so tiny releases interleave with pledges, defaults, reclaims, donations and warps.
abstract contract LockAccountTinyReleaseInvariantsBase is StdInvariant, LockAccountChecks {
    LockAccountTinyReleaseHandler internal tiny;

    function _schedule() internal pure virtual returns (uint256);

    /// @dev Five-day warps run before the campaign, so the schedule is already vesting when the first tiny release lands.
    function _leadSteps() internal pure virtual returns (uint256);

    function setUp() public {
        tiny = new LockAccountTinyReleaseHandler(_schedule());
        handler = tiny;
        acct = tiny.acct();
        read = tiny.read();
        for (uint256 i; i < _leadSteps(); ++i) {
            tiny.warp(type(uint256).max);
        }
        bytes4[] memory sel = new bytes4[](10);
        sel[0] = LockAccountHandler.pledge.selector;
        sel[1] = LockAccountHandler.release.selector;
        sel[2] = LockAccountHandler.repay.selector;
        sel[3] = LockAccountHandler.defaultLoan.selector;
        sel[4] = LockAccountHandler.reclaim.selector;
        sel[5] = LockAccountHandler.warp.selector;
        sel[6] = LockAccountHandler.donate.selector;
        sel[7] = LockAccountHandler.pledgeAtCapacity.selector;
        sel[8] = LockAccountTinyReleaseHandler.releaseTiny.selector;
        sel[9] = LockAccountTinyReleaseHandler.releaseTinyChain.selector;
        targetSelector(FuzzSelector({addr: address(tiny), selectors: sel}));
        targetContract(address(tiny));
    }

    function invariant_allUnderTinyReleases() public view {
        _checkAll();
    }

    /// @notice The reach tallies, LAST sequence only: logged, never asserted, as the parent campaign does.
    function afterInvariant() external view {
        console2.log("=== LockAccountTinyReleaseHandler verb hits (LAST sequence only) ===");
        console2.log("releaseTiny       ", tiny.hits("releaseTiny"));
        console2.log("release           ", tiny.hits("release"));
        console2.log("pledge            ", tiny.hits("pledge"));
        console2.log("forceClose        ", tiny.hits("forceClose"));
        console2.log("reclaim           ", tiny.hits("reclaim"));
    }
}

/// @notice The buyer schedule: linear over 30 days, entered five days in.
contract LockAccountTinyReleaseBuyerInvariants is LockAccountTinyReleaseInvariantsBase {
    function _schedule() internal pure override returns (uint256) {
        return 0;
    }

    function _leadSteps() internal pure override returns (uint256) {
        return 1;
    }
}

/// @notice The team's year-long linear vest behind a 30-day cliff, entered thirty-five days in.
contract LockAccountTinyReleaseTeamInvariants is LockAccountTinyReleaseInvariantsBase {
    function _schedule() internal pure override returns (uint256) {
        return 2;
    }

    function _leadSteps() internal pure override returns (uint256) {
        return 7;
    }
}

/// @title LockAccountTinyReleaseScripted
/// @notice Hundreds of tiny releases in order, the whole induction checked after EVERY one, so no step hides inside a chain.
/// @notice After each release that lands, its gate is restated independently: `spent + pledged <= floor(total * elapsed / duration)`.
/// @dev MUTANT: `LockAccount._vested`'s floor -> ceil; the first exact-releasable release then lands one wei over the floor.
contract LockAccountTinyReleaseScripted is LockAccountChecks {
    LockAccountTinyReleaseHandler internal tiny;

    function _buildTiny(uint256 scheduleId) internal {
        tiny = new LockAccountTinyReleaseHandler(scheduleId);
        handler = tiny;
        acct = tiny.acct();
        read = tiny.read();
    }

    /// @dev `n` tiny steps; every `exactEvery`-th takes exactly what is releasable.
    function _chain(uint256 n, uint256 exactEvery) internal returns (uint256 landed) {
        for (uint256 i; i < n; ++i) {
            uint256 before = acct.spent();
            if (i % exactEvery == exactEvery - 1) tiny.releaseTinyChain(i, 1);
            else tiny.releaseTiny(uint256(keccak256(abi.encode(i))), 1 + (i % 7));
            if (acct.spent() > before) {
                landed++;
                assertLe(acct.spent() + acct.pledged(), _vOracle(tiny.now_()), "a landed release left spent and pledged over the floored vest");
            }
            _checkAll();
        }
    }

    /// @notice Buyer schedule: a minimum pledge, then three hundred tiny releases a few seconds apart.
    function test_TinyReleaseChain_Buyer_HoldsTheInductionEveryStep() public {
        _buildTiny(0);
        tiny.warp(2 days); // past the buyer schedule's start
        tiny.pledge(0, 0); // the minimum pledge at the shortest tenor: the induction carries a live pledge
        assertGt(acct.pledged(), 0, "PREMISE: a pledge is live");
        _checkAll();
        uint256 landed = _chain(300, 4);
        assertGt(landed, 250, "PREMISE: the tiny releases landed, so the floor was met at almost every step");
        assertFalse(tiny.breached(), "no release one wei past the floor ever landed");
    }

    /// @notice Team schedule: past the 30-day cliff, then three hundred tiny releases, every second one exact.
    function test_TinyReleaseChain_Team_HoldsTheInductionEveryStep() public {
        _buildTiny(2);
        for (uint256 i; i < 7; ++i) {
            tiny.warp(type(uint256).max); // seven five-day steps: 35 days, past the cliff
        }
        tiny.pledge(0, 0);
        assertGt(acct.pledged(), 0, "PREMISE: a pledge is live");
        _checkAll();
        uint256 landed = _chain(300, 2);
        assertGt(landed, 250, "PREMISE: the tiny releases landed");
        assertFalse(tiny.breached(), "no release one wei past the floor ever landed");
    }

    /// @notice A release of exactly what is releasable lands ON the floor, and one wei more is refused, at every one of fifty seconds.
    function test_ExactReleaseLandsOnTheFloorAndOneMoreIsRefused() public {
        _buildTiny(0);
        tiny.warp(3 days);
        address ben = tiny.alice();
        for (uint256 i; i < 50; ++i) {
            tiny.warp(1 hours);
            uint256 r = acct.releasable();
            assertGt(r, 0, "PREMISE: something vested this hour");
            vm.prank(ben);
            vm.expectRevert(LockAccount.OverRelease.selector);
            acct.release(r + 1);
            vm.prank(ben);
            acct.release(r);
            assertEq(acct.spent() + acct.pledged(), _vOracle(tiny.now_()), "an exact release lands on the floored vest, to the wei");
            _checkAll();
        }
    }
}
