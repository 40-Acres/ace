// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.36;

import {Ace, SelfCallOnly, BelowCallerFloor} from "../../src/ace/hub/Ace.sol";
import {MarketParams, MigrateArgs, OpenBounds} from "../../src/ace/hub/Types.sol";
import {IERC721} from "@openzeppelin/contracts/token/ERC721/IERC721.sol";
import {PositionManager} from "../../src/ace/positions/PositionManager.sol";
import {PositionTitleNFT} from "../../src/ace/positions/PositionTitleNFT.sol";
import {GUARD_TRIP} from "../utils/GuardTrip.sol";
import {AceGuardProbeRig} from "./AceGuardProbeRig.sol";
import {FullMath} from "@uniswap/v4-core/src/libraries/FullMath.sol";

/// @notice The 3-arg `safeTransferFrom` alone: `abi.encodeCall` cannot resolve an overloaded member.
/// @dev Nothing drifts behind it -- ERC-721 freezes this signature, and the 4-arg form reaches `_update` identically.
interface ISafeTitleTransfer {
    function safeTransferFrom(address from, address to, uint256 tokenId) external;
}

/// @notice One arity each, for the same reason: `abi.encodeCall(Ace.claimOwed, ...)` is ambiguous once overloaded.
/// @dev Typed rather than `encodeWithSignature`, so a re-signature breaks the BUILD instead of the assertion.
interface IClaimOwedBoth {
    function claimOwed(uint256 loanId, address to) external returns (uint256, uint256);
}

interface IClaimOwedPerLeg {
    function claimOwed(uint256 loanId, address toUnits, address toQuote) external returns (uint256, uint256);
}

/// @title AceUnitGuardProbe
/// @notice The behavioural half of the guard-by-default rule: `guard-check.sh` proves the MODIFIER is
/// @notice present, and this proves it WORKS -- re-entering each guarded hub verb really does revert.
/// @dev A gate that reads source text cannot tell a working guard from a renamed modifier or a body
/// @dev moved into a library; only a re-entrant call can. The two are blind in opposite directions.
/// @dev `nonReentrant` is a MODIFIER, so it runs BEFORE the body: arguments need not be meaningful and
/// @dev preconditions need not be met, which is what makes one probe per verb cheap enough to enumerate.
/// @dev The re-entrant context is the deleverage callback, which the hub invokes while holding its lock; the rig is `AceGuardProbeRig`.
/// @dev A vehicle's NAV views refusing mid-hub-body are pinned beside each vehicle's own suite, on this same rig.
contract AceUnitGuardProbeTest is AceGuardProbeRig {
    // ---- the guarded surface ----

    /// @notice Every guarded `Ace` mutator reverts `ReentrancyGuardReentrantCall()` when called from inside a hub callback.
    /// @dev `abi.encodeCall` is type-checked, so a re-signatured verb breaks the BUILD rather than
    /// @dev silently probing a selector that no longer exists and passing on the empty-revert path.
    function test_GuardProbe_EveryGuardedAceMutatorRefusesReentry() public {
        uint256 loanId = _open();
        OpenBounds memory nb = OpenBounds(0, 0, 0);

        _probe("open", address(ace), abi.encodeCall(Ace.open, (id, 0, 0, 0, borrower, nb)));
        _probe("openWithPermit2", address(ace), abi.encodeCall(Ace.openWithPermit2, (id, 0, 0, 0, borrower, nb, "")));
        _probe("withdrawCollateral", address(ace), abi.encodeCall(Ace.withdrawCollateral, (loanId, 0, borrower)));
        _probe("repay", address(ace), abi.encodeCall(Ace.repay, (loanId, 0)));
        _probe("repayWithPermit2", address(ace), abi.encodeCall(Ace.repayWithPermit2, (loanId, 0, "")));
        _probe("deposit", address(ace), abi.encodeCall(Ace.deposit, (id, 0)));
        _probe("depositWithPermit2", address(ace), abi.encodeCall(Ace.depositWithPermit2, (id, 0, "")));
        _probe("withdraw", address(ace), abi.encodeCall(Ace.withdraw, (id, 0, alice, 0)));
        _probe("collect", address(ace), abi.encodeCall(Ace.collect, (address(usdc), alice)));
        _probe("redeemInKind", address(ace), abi.encodeCall(Ace.redeemInKind, (loanId, borrower)));
        _probe("claimOwed", address(ace), abi.encodeCall(IClaimOwedBoth.claimOwed, (loanId, borrower)));
        _probe("claimOwedPerLeg", address(ace), abi.encodeCall(IClaimOwedPerLeg.claimOwed, (loanId, borrower, borrower)));
        _probe("deleverage", address(ace), abi.encodeCall(Ace.deleverage, (loanId, 0, "")));
        _probe("refinanceTo", address(ace), abi.encodeCall(Ace.refinanceTo, (_emptyMigrateArgs())));
        _probe("extend", address(ace), abi.encodeCall(Ace.extend, (loanId, 0, "")));
        _probe("extendWithPermit2", address(ace), abi.encodeCall(Ace.extendWithPermit2, (loanId, 0, "", "")));
        _probe("drawMore", address(ace), abi.encodeCall(Ace.drawMore, (loanId, 0, nb)));
        _probe("addCollateral", address(ace), abi.encodeCall(Ace.addCollateral, (loanId, 0, "")));
        _probe("setRollPolicy", address(ace), abi.encodeCall(Ace.setRollPolicy, (address(0))));
        _probe("finalize", address(ace), abi.encodeCall(Ace.finalize, (loanId)));
        _probe("forceClose", address(ace), abi.encodeCall(Ace.forceClose, (loanId)));
        _probe("sweepRevenue", address(ace), abi.encodeCall(Ace.sweepRevenue, (id)));
        _probe("buyInventory", address(ace), abi.encodeCall(Ace.buyInventory, (loanId, 0, 0, borrower)));
        _probe("retitle", address(ace), abi.encodeCall(Ace.retitle, (loanId, borrower, alice)));
        _probe("setCreditOperatorWithSig", address(ace), abi.encodeCall(Ace.setCreditOperatorWithSig, (borrower, alice, true, 0, type(uint256).max, "")));
        /// @dev THE ORDER LAYER, which this list once missed: all three are `nonReentrant` on the hub.
        /// @dev A count asserted over a list that skips a guarded verb is a claim about the list, not the surface.
        _probe("postOrder", address(ace), abi.encodeCall(Ace.postOrder, (id, 0, 0, 0, 0, 0, 0)));
        _probe("fillOrder", address(ace), abi.encodeCall(Ace.fillOrder, (0, 0, 0)));
        _probe("closeOrder", address(ace), abi.encodeCall(Ace.closeOrder, (0, borrower)));

        _crankWithProbes(loanId);

        assertTrue(hubEnteredDuringCallback, "the callback did not run inside the hub's guard");
        assertEq(probes.length, GUARDED_ACE_VERBS, "the guarded Ace surface and this probe list disagree");
        _assertAllReentrant();
    }

    /// @notice A title transfer nested inside a hub call reverts, which is why the ERC-721 surface needs no guard.
    /// @dev THE ONE CROSS-CONTRACT LEG. `PositionTitleNFT` carries no guard of its own; `_update` routes
    /// @dev every real move into the hub's `retitle`, and it is the HUB's lock that refuses the move.
    /// @dev This is the assertion behind the inherited-surface entries on the exception list.
    function test_GuardProbe_TitleTransferNestedInAHubCallRefuses() public {
        uint256 loanId = _open();
        vm.prank(borrower);
        title.approve(address(this), loanId);

        _probe("PositionTitleNFT.transferFrom", address(title), abi.encodeCall(IERC721.transferFrom, (borrower, alice, loanId)));
        _probe("PositionTitleNFT.safeTransferFrom", address(title), abi.encodeCall(ISafeTitleTransfer.safeTransferFrom, (borrower, alice, loanId)));

        _crankWithProbes(loanId);

        assertTrue(hubEnteredDuringCallback, "the callback did not run inside the hub's guard");
        assertEq(probes.length, 2, "both moving title verbs on the exception list must be probed");
        _assertAllReentrant();
        assertEq(title.ownerOf(loanId), borrower, "title moved despite the nested transfer reverting");
    }

    /// @notice The custodian's lock is its OWN, and access control -- not the hub's lock -- is its door.
    /// @dev EIP-1153 transient storage is scoped per ADDRESS, so `Ace` and `PositionManager` hold
    /// @dev SEPARATE locks at the same named slot. That is why guarded `open` can call guarded `pull`.
    /// @dev "One shared slot" is true WITHIN an address, which is what `multicall`'s delegatecall legs share.
    /// @dev An outside caller is refused by `NotLoanManager` mid-crank; `onlyLoanManager` runs first, so the lock is never read.
    /// @dev The custodian's own guard is re-entered as its loan manager in `PositionManagerGuardProbe`, which this row cannot do.
    function test_GuardProbe_CustodianLockIsPerAddressNotSharedWithTheHub() public {
        uint256 loanId = _open();

        _probe("PositionManager.pull", address(positionManager), abi.encodeCall(PositionManager.pull, (loanId, borrower, 0)));

        _crankWithProbes(loanId);

        assertTrue(hubEnteredDuringCallback, "the callback did not run inside the hub's guard");
        assertEq(results.length, 1, "the probe did not run");
        assertEq(
            results[0],
            PositionManager.NotLoanManager.selector,
            "the custodian refused for the wrong reason: its lock is per-address, so access control is the door"
        );
    }

    /// @notice The unguarded-by-choice verbs really are re-enterable, which is what the exception list claims.
    /// @dev The counterpart assertion: guarding one of these later turns this test RED, so the exception
    /// @dev list and the code cannot drift apart silently in EITHER direction.
    function test_GuardProbe_UnguardedByChoiceVerbsAreReachableUnderReentry() public {
        uint256 loanId = _open();

        /// @dev THE ERC-6909 VERBS ARE GONE -- `transfer`, `transferFrom`, `approve` and `setOperator` were the
        /// @dev receipt ledger's surface, and a lender's position is the pooled (lender, quote) balance now.
        /// @dev They took four entries off the exception list with them, so one verb is what this list holds.
        _probe("setCreditOperator", address(ace), abi.encodeCall(Ace.setCreditOperator, (alice, true)));

        _crankWithProbes(loanId);

        assertTrue(hubEnteredDuringCallback, "the callback did not run inside the hub's guard");
        assertEq(probes.length, 1, "the unguarded-by-choice probe list emptied out");
        assertEq(results.length, probes.length, "a probe did not run");
        for (uint256 i; i < probes.length; i++) {
            assertEq(results[i], bytes4(0), string.concat("now guarded, so its exception entry is stale: ", probes[i].label));
        }
    }

    /// @notice Every verb on the Ace exception list answers from its own body, never from the guard.
    /// @dev The counterpart at FULL WIDTH to the row above, which pins only the ones that succeed outright.
    /// @dev Pins the WHOLE exception list, each verb by the selector its own body produces.
    /// @dev A guard added to any of them answers `ReentrancyGuardReentrantCall()` before the body runs, which no expectation allows.
    /// @dev The multicall leg is `setCreditOperator` now: it was `setOperator`, which went with the ERC-6909 surface.
    function test_GuardProbe_EveryUnguardedAceVerbAnswersFromItsOwnBody() public {
        uint256 loanId = _open();
        MarketParams memory blank;
        bytes[] memory leg = new bytes[](1);
        leg[0] = abi.encodeCall(Ace.setCreditOperator, (alice, true));

        _expect("setCreditOperator", address(ace), abi.encodeCall(Ace.setCreditOperator, (alice, true)), bytes4(0));
        _expect("multicall", address(ace), abi.encodeCall(Ace.multicall, (leg)), bytes4(0));
        _expect("pushToken", address(ace), abi.encodeCall(Ace.pushToken, (address(usdc), alice, 0)), SelfCallOnly.selector);
        _expect("createMarket", address(ace), abi.encodeCall(Ace.createMarket, (blank)), ERROR_STRING);

        _crankWithProbes(loanId);

        assertTrue(hubEnteredDuringCallback, "the callback did not run inside the hub's guard");
        assertEq(probes.length, UNGUARDED_ACE_VERBS, "the Ace exception list and this probe list disagree");
        _assertAllExpected();
    }

    /// @notice The title collection's allowance surface stays reachable mid-crank; only a real move is refused.
    /// @dev The other half of the inherited-surface entries, which claim an allowance write calls nothing out.
    /// @dev `mint` rides along: hub-only, so an outside caller is refused by NAME even inside a hub call.
    function test_GuardProbe_TitleAllowanceSurfaceIsReachableUnderReentry() public {
        uint256 loanId = _open();
        vm.prank(borrower);
        title.setApprovalForAll(address(this), true);

        _expect("PositionTitleNFT.approve", address(title), abi.encodeCall(IERC721.approve, (alice, loanId)), bytes4(0));
        _expect("PositionTitleNFT.setApprovalForAll", address(title), abi.encodeCall(IERC721.setApprovalForAll, (alice, true)), bytes4(0));
        _expect("PositionTitleNFT.mint", address(title), abi.encodeCall(PositionTitleNFT.mint, (loanId + 1, alice)), PositionTitleNFT.NotHubTitle.selector);

        _crankWithProbes(loanId);

        assertTrue(hubEnteredDuringCallback, "the callback did not run inside the hub's guard");
        assertEq(probes.length, 3, "the title allowance probe list emptied out");
        _assertAllExpected();
        assertEq(title.ownerOf(loanId), borrower, "an allowance write moved title");
    }

    /// @notice Every custody verb refuses an outside caller BY NAME mid-crank, never by the hub's lock.
    /// @dev The enumeration behind the single `pull` probe: six guarded verbs, and access control is the door.
    /// @dev It cannot see either lock: `onlyLoanManager` runs before `nonReentrant`, so the guard's error is unreachable here.
    function test_GuardProbe_EveryCustodyVerbRefusesAnOutsideCallerMidCrank() public {
        uint256 loanId = _open();
        bytes4 want = PositionManager.NotLoanManager.selector;

        _expect("pull", address(positionManager), abi.encodeCall(PositionManager.pull, (loanId, borrower, 0)), want);
        _expect("release", address(positionManager), abi.encodeCall(PositionManager.release, (loanId, borrower, 0)), want);
        _expect("retireCustody", address(positionManager), abi.encodeCall(PositionManager.retireCustody, (loanId, 0)), want);
        _expect("releaseRetired", address(positionManager), abi.encodeCall(PositionManager.releaseRetired, (loanId, borrower, 0)), want);
        _expect("carryOut", address(positionManager), abi.encodeCall(PositionManager.carryOut, (loanId, 0)), want);
        _expect("carryIn", address(positionManager), abi.encodeCall(PositionManager.carryIn, (loanId, loanId, 0)), want);

        _crankWithProbes(loanId);

        assertTrue(hubEnteredDuringCallback, "the callback did not run inside the hub's guard");
        assertEq(probes.length, GUARDED_CUSTODY_VERBS, "the custodian's guarded surface and this probe list disagree");
        _assertAllExpected();
    }

    /// @notice THE GUARDED READ-ONLY DOORS refuse a mid-body call, and none of them is part of the guarded set.
    /// @notice Eight hub views carry `nonReentrantView`, never `nonReentrant`, which writes; every one is probed here.
    /// @dev So they are deliberately absent from `GUARDED_ACE_VERBS` above; `GUARDED_ACE_VIEWS` counts them instead.
    /// @dev What is asserted is still the guard's own error: `nonReentrantView` raises `ReentrancyGuardReentrantCall()` too.
    /// @dev A SHARE PRICE IS BUILT ON `lenderAssets`, so an answer from inside a hub body would be torn and mint wrong.
    /// @dev `previewOpen`, `tryExtend` and `tryDrawMore` answer from a loan and market aggregates that are torn the same way.
    /// @dev `lenderUnresolved` gates vault entry on a count that a settlement or an emptying buy moves mid-body.
    /// @dev `lenderByCollateral` feeds a per-collateral cap that every draw, melt, settlement and sale moves mid-body.
    /// @dev Only a re-entrant call can show each check is wired: deleting any ONE of the eight modifiers turns this red.
    /// @dev WAS PROBED THROUGH `rearmRefusal`, a guarded view that went with the rearm policy.
    function test_GuardProbe_TheGuardedViewRefusesAMidBodyRead() public {
        uint256 loanId = _open();

        _probe("lenderAssets", address(ace), abi.encodeCall(Ace.lenderAssets, (alice, address(usdc))));
        /// @dev `lenderOwed` IS PROBED HERE AND NOWHERE ELSE, and that is not a convenience.
        /// @dev The shop-level row below cannot reach it: `_serveAt` hits `lenderAssets` through `_navShare`
        /// @dev BEFORE the cash read, so that probe always trips on the first door and never on this one.
        /// @dev Without this line the new view's guard would be present rather than checked.
        _probe("lenderOwed", address(ace), abi.encodeCall(Ace.lenderOwed, (alice, address(usdc))));
        _probe("previewOpen", address(ace), abi.encodeCall(Ace.previewOpen, (id, COLL, DRAW, 0, borrower, OpenBounds(0, 0, 0))));
        _probe("tryExtend", address(ace), abi.encodeCall(Ace.tryExtend, (loanId, 0, "", address(0))));
        _probe("tryDrawMore", address(ace), abi.encodeCall(Ace.tryDrawMore, (loanId, 0, OpenBounds(0, 0, 0), address(0))));
        _probe("debtOf", address(ace), abi.encodeCall(Ace.debtOf, (loanId)));
        _probe("lenderUnresolved", address(ace), abi.encodeCall(Ace.lenderUnresolved, (alice, address(usdc))));
        _probe("lenderByCollateral", address(ace), abi.encodeCall(Ace.lenderByCollateral, (alice, address(usdc), address(vault))));

        _crankWithProbes(loanId);

        assertTrue(hubEnteredDuringCallback, "the callback did not run inside the hub's guard");
        assertEq(probes.length, GUARDED_ACE_VIEWS, "the guarded Ace views and this probe list disagree");
        _assertAllReentrant();
        /// @dev And once the body has returned none of them refuses as the guard, so each row above pins the GUARD.
        /// @dev `previewOpen` still refuses here, but from its own body: at the crank's record price it answers `InsufficientCash`.
        for (uint256 i; i < probes.length; i++) {
            (bool ok, bytes memory ret) = probes[i].target.call(probes[i].data);
            assertTrue(ok || bytes4(ret) != GUARD_TRIP, string.concat("the view trips the guard even outside a hub body: ", probes[i].label));
        }
        assertGt(ace.lenderAssets(alice, address(usdc)), 0, "and the same view answers freely once the body has returned");
        assertGt(ace.lenderOwed(alice, address(usdc)), 0, "as does the leg the redemption rail prices on");
    }

    /// @notice A `multicall` sent mid-body is no way round the lock: its legs run at the hub's own address, so a guarded one trips.
    /// @dev The batch itself is unguarded, and in the second probe its unguarded first leg goes through before the guarded one.
    /// @dev The refusal bubbles verbatim, so the whole batch answers the guard's selector and the first leg unwinds with it.
    /// @dev And the same batch runs once the body has returned, so each row pins the lock rather than a broken batch.
    function test_GuardProbe_AMulticallSentMidBodyTripsOnItsGuardedLeg() public {
        uint256 loanId = _open();
        bytes[] memory alone = new bytes[](1);
        alone[0] = abi.encodeCall(Ace.collect, (address(usdc), alice));
        bytes[] memory behind = new bytes[](2);
        behind[0] = abi.encodeCall(Ace.setCreditOperator, (alice, true));
        behind[1] = abi.encodeCall(Ace.collect, (address(usdc), alice));

        _probe("multicall[collect]", address(ace), abi.encodeCall(Ace.multicall, (alone)));
        _probe("multicall[setCreditOperator, collect]", address(ace), abi.encodeCall(Ace.multicall, (behind)));

        _crankWithProbes(loanId);

        assertTrue(hubEnteredDuringCallback, "the callback did not run inside the hub's guard");
        _assertAllReentrant();
        vm.prank(alice); // collect is lender-only: the pool it pays is the caller's, so the lender sends the batch
        bytes[] memory outs = ace.multicall(behind);
        assertGt(abi.decode(outs[1], (uint256)), 0, "outside a body the same batch runs both legs, and its collect pays");
    }

    /// @notice A REVERT DEEP IN A GUARDED BODY TAKES THE LOCK DOWN WITH IT, so a caller that catches it may go again at once.
    /// @dev The lock is transient and outlives a call inside one transaction, so only the revert's unwind can clear it here.
    /// @dev `BelowCallerFloor` is raised after the sale returns: units released, the callback run and the quote pulled.
    /// @dev A keeper batch that catches that refusal and re-cranks in the same transaction rests on exactly this.
    function test_GuardProbe_ARevertDeepInAGuardedBodyReleasesTheLock() public {
        uint256 loanId = _open();
        uint256 trig = read.triggerPrice(loanId);
        record.setBelowBand(FullMath.mulDivRoundingUp(trig, 1e18, 1e18 - BAND_BPS * 1e14));
        record.setMinPrice(trig + trig / 20);
        uint256 units = read.loan(loanId).collateralUnits;
        assertTrue(ace.notEntered(), "fixture: nothing is in flight before the crank");

        try ace.deleverage(loanId, type(uint256).max, "") {
            fail();
        } catch (bytes memory err) {
            assertEq(bytes4(err), BelowCallerFloor.selector, "refused by the caller's floor, after the sale had run");
        }

        assertTrue(ace.notEntered(), "the revert unwound the lock with everything else");
        assertEq(read.loan(loanId).collateralUnits, units, "and nothing of the refused sale survived it");
        (uint256 sold,) = ace.deleverage(loanId, 0, "");
        assertGt(sold, 0, "the same crank, in the same transaction, lands");
        assertLt(read.loan(loanId).collateralUnits, units, "and really sold");
    }

    /// @notice A call that dispatches to nothing records selector zero, which the guard assertion rejects.
    /// @dev The harness's OWN failure mode, asserted rather than assumed: every probe is a low-level call,
    /// @dev so a wrong selector or a wrong target reverts too and must never read as a guard trip.
    /// @dev `encodeWithSelector` is deliberate here and nowhere else: the point is a selector the hub lacks.
    /// @dev The hub declares no fallback and no receive, so an unknown selector returns empty revert data.
    function test_GuardProbe_ANonDispatchingCallRecordsZeroNotAGuardTrip() public {
        uint256 loanId = _open();

        _probe("no such selector", address(ace), abi.encodeWithSelector(bytes4(0xdeadbeef)));

        _crankWithProbes(loanId);

        assertTrue(hubEnteredDuringCallback, "the callback did not run inside the hub's guard");
        assertEq(results.length, 1, "the probe did not run");
        assertTrue(reverted[0], "a selector the hub does not declare was answered rather than refused");
        assertEq(results[0], bytes4(0), "empty revert data must record as zero, never as a selector");
        assertTrue(results[0] != GUARD_TRIP, "an empty revert must not read as a guard trip");
    }
}
