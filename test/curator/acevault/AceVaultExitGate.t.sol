// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.36;

import {Math} from "@openzeppelin/contracts/utils/math/Math.sol";
import {InsufficientCash, LoanMatured, PolicyRefused} from "../../../src/ace/hub/Borrower.sol";
import {LoanMath} from "../../../src/ace/hub/libraries/LoanMath.sol";
import {Loan, MarketParams, MigrateArgs, OpenBounds} from "../../../src/ace/hub/Types.sol";
import {AceVault} from "../../../src/curator/AceVault.sol";
import {Extension, IRollPolicy} from "../../../src/interfaces/IRollPolicy.sol";
import {PolicyGasMeter} from "../../utils/PolicyGasMeter.sol";
import {POLICY_YES} from "../../utils/RollPolicyMocks.sol";
import {AceVaultRig} from "./AceVaultRig.sol";

/// @notice The exit gate's shared helpers over the CuratorVault rig: the real hub verb, and request worth priced as the gate prices it.
abstract contract AceVaultExitGateBase is AceVaultRig {
    /// @dev A loan of `tenor` through the rig, a day old: in its open second an extension adds no time, so every gate row starts here.
    function _borrowAged(uint64 tenor) internal returns (uint256 loanId) {
        loanId = _borrow(tenor);
        _warpBy(1 days);
    }

    /// @dev Mint `who` exactly the fee an extension of `loanId` costs now, on the time it adds, and approve the hub for it.
    function _fundFee(address who, uint256 loanId) internal {
        Loan memory l = read.loan(loanId);
        MarketParams memory mp = ace.idToMarketParams(l.market);
        uint256 fee = LoanMath.originationFee(l.debt, uint64(_now()) + l.tenor - l.expiry, mp.baseBps, mp.minTenor);
        usdc.mint(who, fee);
        vm.prank(who);
        usdc.approve(address(ace), fee);
    }

    /// @dev The holder extends `loanId` through the real hub verb, fee funded first.
    function _extendAs(address who, uint256 loanId) internal {
        _fundFee(who, loanId);
        vm.prank(who);
        ace.extend(loanId, 0, "");
    }

    /// @dev The unlocked preview refuses `PolicyRefused`, the locked verb reverts the same, and the expiry is unmoved.
    function _assertRefused(uint256 loanId) internal {
        uint256 x = _expiry(loanId);
        (bool ok, bytes4 reason,) = ace.tryExtend(loanId, 0, "", borrower);
        assertFalse(ok, "the preview consented");
        assertEq(reason, PolicyRefused.selector, "the preview names the vault's policy");
        _fundFee(borrower, loanId);
        vm.prank(borrower);
        vm.expectRevert(PolicyRefused.selector);
        ace.extend(loanId, 0, "");
        assertEq(_expiry(loanId), x, "the loan did not extend");
    }

    /// @dev The unlocked preview consents and the locked verb lands the extension in place, re-anchored at now plus the loan's tenor.
    function _assertLands(uint256 loanId) internal {
        (bool ok, bytes4 reason,) = ace.tryExtend(loanId, 0, "", borrower);
        assertTrue(ok, "the preview refused");
        assertEq(reason, bytes4(0), "the preview named no reason");
        _extendAs(borrower, loanId);
        assertEq(_expiry(loanId), _now() + read.loan(loanId).tenor, "the loan extended in place");
    }

    /// @dev The vault's virtual share offset, read off its decimals rather than restated.
    function _virtualShares() internal view returns (uint256) {
        return 10 ** (vault.decimals() - usdc.decimals());
    }

    /// @dev The supply a request is priced over at the vault's NAV now: the pending fee and the virtual offset included.
    function _quoteSupply() internal view returns (uint256) {
        return vault.totalSupply() + vault.pendingFeeShares() + _virtualShares();
    }

    /// @dev What `shares` of a request are worth at the vault's NAV now, rounded down, as the gate prices a synced vault.
    function _worth(uint256 shares) internal view returns (uint256) {
        return Math.mulDiv(shares, vault.totalAssets() + 1, _quoteSupply());
    }

    /// @dev The fewest shares a request worth `target` takes at the vault's NAV now; a share is a millionth of an atom, so it is worth exactly `target`.
    function _sharesWorth(uint256 target) internal view returns (uint256) {
        return Math.mulDiv(target, _quoteSupply(), vault.totalAssets() + 1, Math.Rounding.Ceil);
    }

    function _requestAll(address who) internal returns (uint256 shares) {
        shares = vault.balanceOf(who);
        vm.prank(who);
        vault.requestExit(shares);
    }
}

/// @title AceVaultExitGateTest
/// @notice THE EXIT GATE: a vault refuses any lengthening while its standing exit requests are worth more than its idle cash.
/// @notice Every row goes through the real hub `extend` or `refinanceTo`, under the hub's lock, beside the unlocked preview.
/// @dev Boundary rows request inside the block they extend in, so the mark the gate prices at is the synced one.
/// @dev Reasoning: the design record,,.
contract AceVaultExitGateTest is AceVaultExitGateBase {
    /// @notice Requests worth more than idle refuse an extension at the hub, and the unlocked preview gives the same answer.
    function test_RequestsOutweighingIdleRefuseAndThePreviewAgrees() public {
        uint256 loanId = _borrowAged(MIN_TENOR);
        (bool ok,,) = ace.tryExtend(loanId, 0, "", borrower);
        assertTrue(ok, "PREMISE: with no request standing the vault consents");
        _requestAll(alice);
        assertGt(_worth(vault.requestedShares()), vault.idle(), "PREMISE: the requests outweigh idle");
        _assertRefused(loanId);
    }

    /// @notice A request worth exactly idle lets the extension land; one atom more of worth refuses it.
    function test_AtWorthEqualToIdleItLandsAndOneAtomPastRefuses() public {
        uint256 loanId = _borrowAged(MIN_TENOR);
        uint256 idle = vault.idle();
        uint256 atIdle = _sharesWorth(idle);
        uint256 onePast = _sharesWorth(idle + 1);
        assertEq(_worth(atIdle), idle, "PREMISE: the request is worth exactly idle");
        assertEq(_worth(onePast), idle + 1, "PREMISE: one atom more of worth");
        uint256 snap = vm.snapshotState();
        vm.prank(alice);
        vault.requestExit(onePast);
        _assertRefused(loanId);
        vm.revertToState(snap);
        vm.prank(alice);
        vault.requestExit(atIdle);
        assertEq(vault.idle(), idle, "PREMISE: a request moves no cash");
        _assertLands(loanId);
    }

    /// @notice The gate binds a same-vault `refinanceTo` that lengthens, and lets one that shortens reuse the claim.
    /// @dev The vault rests no cash, so a refused reuse draws its principal fresh and finds none: `InsufficientCash`.
    function test_ALengtheningReuseIsGatedAndAShorteningOnePasses() public {
        uint256 loanId = _borrow(MAX_TENOR);
        bytes32 mid = _mid(loanId);
        uint256 x = _expiry(loanId);
        uint256 all = _requestAll(alice);
        assertGt(_worth(vault.requestedShares()), vault.idle(), "PREMISE: the requests outweigh idle");
        uint256 snap = vm.snapshotState();
        uint256 debt = read.debtOf(loanId);
        vm.prank(borrower);
        uint256 shorter = ace.refinanceTo(MigrateArgs(loanId, mid, debt, MIN_TENOR, OpenBounds(0, 0, 0), 0, address(0)));
        assertTrue(ace.isLiveLoan(shorter), "a shortening re-term reused the claim while the requests stood");
        assertLt(_expiry(shorter), x, "PREMISE: it ends sooner than the loan it replaced");
        vm.revertToState(snap);
        _warpTo(x - 10 days);
        uint256 keep = 100e6;
        _repayAs(borrower, loanId, read.debtOf(loanId) - keep);
        MigrateArgs memory m = MigrateArgs(loanId, mid, keep, MAX_TENOR, OpenBounds(0, 0, 0), 0, address(0));
        uint256 snap2 = vm.snapshotState();
        vm.prank(borrower);
        vm.expectRevert(InsufficientCash.selector);
        ace.refinanceTo(m);
        vm.revertToState(snap2);
        vm.prank(alice);
        vault.cancelExit(all);
        vm.prank(borrower);
        uint256 longer = ace.refinanceTo(m);
        assertGt(_expiry(longer), x, "CONTROL: with no request standing the lengthening re-term reused the claim");
    }

    /// @notice A covered request lands an extension under the hub's lock: the gate prices from storage, where a hub view would revert into a no.
    function test_ACoveredRequestLandsUnderTheHubsLock() public {
        uint256 loanId = _borrowAged(MIN_TENOR);
        uint256 half = _sharesWorth(vault.idle() / 2);
        vm.prank(alice);
        vault.requestExit(half);
        assertGt(vault.requestedShares(), 0, "PREMISE: a request stands, so the gate prices it");
        assertLe(_worth(vault.requestedShares()), vault.idle(), "PREMISE: idle covers it");
        _assertLands(loanId);
    }

    /// @notice A request worth one atom blocks every extension of a fully lent vault, and a hub push covers it with no vault verb between.
    function test_ADustRequestBlocksAFullyLentVaultUntilAHubPushCoversIt() public {
        vault = _newVault(_row(address(record), type(uint192).max));
        _lp(bob, 2 * PRINCIPAL);
        uint256 a = _borrow(MIN_TENOR);
        uint256 b = _borrowAs(stranger, UNITS, PRINCIPAL, MIN_TENOR);
        _warpBy(1 days);
        assertEq(vault.idle(), 0, "PREMISE: the vault is fully lent");
        uint256 dust = _sharesWorth(1);
        vm.prank(bob);
        vault.requestExit(dust);
        assertEq(_worth(dust), 1, "PREMISE: the request is worth one atom");
        _assertRefused(a);
        _repayAs(stranger, b, read.debtOf(b));
        assertGe(vault.idle(), PRINCIPAL, "PREMISE: the terminal close pushed the vault's credit home");
        _assertLands(a);
    }

    /// @notice B-2's remedy: the borrower pays down the shortfall, anyone cranks, and the extension lands.
    /// @dev Before the crank the paydown waits at the hub as credit, which idle does not count.
    function test_APaydownOfTheShortfallPlusACrankLandsTheExtension() public {
        uint256 loanId = _borrowAged(MIN_TENOR);
        uint256 idle = vault.idle();
        uint256 shortfall = 100e6;
        uint256 shares = _sharesWorth(idle + shortfall);
        vm.prank(alice);
        vault.requestExit(shares);
        _assertRefused(loanId);
        _repayAs(borrower, loanId, shortfall);
        _assertRefused(loanId);
        vm.prank(stranger);
        vault.crank();
        assertGe(vault.idle(), idle + shortfall, "PREMISE: the crank brought the paydown into idle");
        _assertLands(loanId);
    }

    /// @notice B-2's veto: a holder's request sent in front of a pending `extend` refuses it.
    function test_AFrontRunRequestRefusesAPendingExtension() public {
        uint256 loanId = _borrowAged(MIN_TENOR);
        _fundFee(borrower, loanId);
        (bool ok,,) = ace.tryExtend(loanId, 0, "", borrower);
        assertTrue(ok, "PREMISE: the borrower's preview consents");
        _requestAll(alice);
        vm.prank(borrower);
        vm.expectRevert(PolicyRefused.selector);
        ace.extend(loanId, 0, "");
    }

    /// @notice B-2: a request filed before the loan, uncovered later by another holder's claim, is cleared by anyone's `lapseExit` inside the term.
    /// @notice The extension it vetoed then lands.
    /// @dev Only such a request lapses in time here: the rig's tenors are at most `REQUEST_LEASE`, so one filed after the loan opens outlasts it.
    function test_ALapsedRequestIsClearedByLapseExitAndTheExtensionLands() public {
        uint256 bobShares = _lp(bob, 2 * PRINCIPAL);
        uint256 aliceShares = _sharesWorth(LP_CASH - PRINCIPAL / 2);
        assertLt(aliceShares, vault.balanceOf(alice), "PREMISE: alice's request is partial");
        vm.prank(alice);
        vault.requestExit(aliceShares);
        (, uint64 expiresAt) = vault.requestOf(alice);

        _warpBy(1 days);
        assertEq(vault.requestedShares(), aliceShares, "PREMISE: alice's request stands");
        assertGe(vault.lendable(), PRINCIPAL, "the vault still lends past a standing request");
        uint256 loanId = _borrowAged(MAX_TENOR);
        assertTrue(ace.isLiveLoan(loanId), "the loan opened from the unheld cash");
        assertEq(vault.requestedShares(), aliceShares, "PREMISE: the request still stands");
        (bool ok,,) = ace.tryExtend(loanId, 0, "", borrower);
        assertTrue(ok, "CONTROL: idle still covers alice's request, so the extension would land");

        vm.startPrank(bob);
        vault.requestExit(bobShares);
        vault.claimExit(bobShares, bob, 0);
        vm.stopPrank();
        assertGt(_worth(vault.requestedShares()), vault.idle(), "PREMISE: bob's claim left alice's request outweighing idle");
        _assertRefused(loanId);

        _warpTo(expiresAt);
        assertLt(_now(), _expiry(loanId), "PREMISE: the request lapses inside the term");
        vm.prank(stranger);
        vault.lapseExit(alice);
        assertEq(vault.requestedShares(), 0, "PREMISE: the lapse cleared the request");
        _assertLands(loanId);
    }

    /// @notice A request filed inside a 30-day loan outlasts it: by the time `lapseExit` can clear it the loan has matured, and refuses `LoanMatured`.
    /// @notice The borrower's counter still stands inside the term: paying down the shortfall and `crank()` land the extension before expiry.
    /// @dev Accepted, `REQUEST_LEASE` unchanged: an extension lands only before expiry, and a request lapses one lease after it is made.
    function test_ARequestInsideTheLoansLastLeaseOutlastsItButAPaydownStillExtends() public {
        uint256 loanId = _borrowAged(MAX_TENOR);
        uint256 x = _expiry(loanId);
        uint256 idle = vault.idle();
        uint256 shortfall = 100e6;
        uint256 shares = _sharesWorth(idle + shortfall);
        vm.prank(alice);
        vault.requestExit(shares);
        (, uint64 expiresAt) = vault.requestOf(alice);
        assertGe(expiresAt, x, "PREMISE: the request lapses no earlier than the loan matures");
        _assertRefused(loanId);

        uint256 snap = vm.snapshotState();
        _warpTo(expiresAt);
        vm.prank(stranger);
        vault.lapseExit(alice);
        assertEq(vault.requestedShares(), 0, "PREMISE: the lapse cleared the request");
        (bool ok, bytes4 why,) = ace.tryExtend(loanId, 0, "", borrower);
        assertFalse(ok, "the lapse came too late: the loan cannot extend");
        assertEq(why, LoanMatured.selector, "it has matured");
        _fundFee(borrower, loanId);
        vm.prank(borrower);
        vm.expectRevert(LoanMatured.selector);
        ace.extend(loanId, 0, "");
        vm.revertToState(snap);

        _repayAs(borrower, loanId, shortfall);
        vm.prank(stranger);
        vault.crank();
        assertGe(vault.idle(), idle + shortfall, "PREMISE: the crank brought the paydown into idle");
        assertLt(_now(), x, "PREMISE: still inside the term");
        _assertLands(loanId);
    }

    /// @notice B-1, KNOWN: while entry is open a borrower deposits the shortfall, extends, requests and claims it back, all at once.
    /// @dev The gate is a check at the moment of asking, not a reservation: the older requests are as uncovered after as before.
    function test_KNOWN_TheRoundTripLandsWhileEntryIsOpen() public {
        uint256 loanId = _borrowAged(MIN_TENOR);
        _requestAll(alice);
        uint256 shortfall = _worth(vault.requestedShares()) - vault.idle() + 1;
        usdc.mint(borrower, shortfall);
        vm.startPrank(borrower);
        usdc.approve(address(vault), shortfall);
        uint256 got = vault.deposit(shortfall, borrower);
        vm.stopPrank();
        _extendAs(borrower, loanId);
        vm.startPrank(borrower);
        vault.requestExit(got);
        uint256 back = vault.claimExit(got, borrower, 0);
        vm.stopPrank();
        assertEq(_expiry(loanId), _now() + MIN_TENOR, "the extension landed");
        assertApproxEqAbs(back, shortfall, 2, "the borrower took its deposit back, first come");
        assertGt(_worth(vault.requestedShares()), vault.idle(), "and the older requests are as uncovered as before");
    }

    /// @notice B-1: an unsold pot shuts entry, so the round trip cannot start and the gate binds.
    function test_TheRoundTripRefusesWhileAnUnsoldPotShutsEntry() public {
        uint256 loanId = _borrow(MAX_TENOR);
        uint256 c = _borrowAs(stranger, UNITS, PRINCIPAL, MIN_TENOR);
        _requestAll(alice);
        _warpTo(_expiry(c));
        ace.forceClose(c);
        (uint256 unsold,) = ace.lenderUnresolved(address(vault), address(usdc));
        assertGt(unsold, 0, "PREMISE: a settled pot of the vault's sits unsold");
        usdc.mint(borrower, PRINCIPAL);
        vm.startPrank(borrower);
        usdc.approve(address(vault), PRINCIPAL);
        vm.expectRevert(AceVault.InventoryUnsold.selector);
        vault.deposit(PRINCIPAL, borrower);
        vm.stopPrank();
        _assertRefused(loanId);
    }

    /// @notice A loss since the last sync leaves the mark high, so the gate over-states the requests and refuses; a sync lands it.
    /// @dev The request is sized in a replay of the loss so that idle covers it at the synced NAV and not at the stale one.
    function test_AStaleMarkAfterALossErrsStrict() public {
        uint256 loanId = _borrow(MAX_TENOR);
        uint256 c = _borrowAs(stranger, UNITS, 2 * PRINCIPAL, MIN_TENOR);
        uint256 snap = vm.snapshotState();
        _warpTo(_expiry(c));
        ace.forceClose(c);
        uint256 idleAfter = vault.idle();
        uint256 navAfter = vault.totalAssets();
        uint256 q = _quoteSupply();
        vm.revertToState(snap);
        uint256 shares = Math.mulDiv(idleAfter, q, navAfter + 1);
        assertGt(Math.mulDiv(shares, vault.totalAssets() + 1, q), idleAfter, "PREMISE: at the pre-loss NAV the request outweighs idle");
        vm.prank(alice);
        vault.requestExit(shares);
        _warpTo(_expiry(c));
        ace.forceClose(c);
        assertEq(vault.idle(), idleAfter, "PREMISE: the loss replayed");
        assertLe(_worth(shares), idleAfter, "PREMISE: at the synced NAV idle covers the request");
        _assertRefused(loanId);
        vm.prank(alice);
        vault.requestExit(0);
        _assertLands(loanId);
    }

    /// @notice The drain refuses on its own: with no request standing and with one outweighing idle alike.
    function test_TheDrainRefusesWhateverTheRequests() public {
        uint256 loanId = _borrowAged(MIN_TENOR);
        vm.prank(curator);
        vault.setDrain(true);
        assertEq(vault.requestedShares(), 0, "PREMISE: no request stands");
        _assertRefused(loanId);
        _requestAll(alice);
        _assertRefused(loanId);
    }

    /// @notice The vault's policy, asked directly, is blind to which call asks: a covered request says yes, an uncovered one no.
    function test_ThePolicyAnswersTheGateOnTheExtensionAlone() public {
        uint256 loanId = _borrow(MIN_TENOR);
        Loan memory l = read.loan(loanId);
        MarketParams memory mp = _mp(loanId);
        Extension memory e = Extension(borrower, loanId, l.borrower, l.collateralUnits, l.debt, l.debt, l.expiry, l.expiry + MIN_TENOR, mp, mp);
        assertEq(vault.admitsExtension(e, ""), POLICY_YES, "PREMISE: a yes with no request standing");
        _requestAll(alice);
        assertEq(vault.admitsExtension(e, ""), bytes4(0), "a lengthening is refused while requests outweigh idle");
        e.newExpiry = l.expiry;
        assertEq(vault.admitsExtension(e, ""), POLICY_YES, "an ask that does not lengthen passes the gate");
    }
}

/// @title AceVaultExitGateGasTest
/// @notice The vault's policy with a standing request, asked by the hub in the real order, costs under 150k of the 200k budget.
/// @dev Every setup write lands in `setUp`, so the extension the row sends meets the vault's state cold, as a borrower's own transaction does.
contract AceVaultExitGateGasTest is AceVaultExitGateBase {
    uint256 internal constant BOUND = 150_000;
    uint256 internal loanId;

    function setUp() public override {
        super.setUp();
        loanId = _borrowAged(MIN_TENOR);
        uint256 shares = _sharesWorth(vault.idle() / 2);
        vm.prank(alice);
        vault.requestExit(shares);
        assertGt(vault.requestedShares(), 0, "PREMISE: a request stands, so the gate prices it");
        PolicyGasMeter meter = new PolicyGasMeter(IRollPolicy(address(vault)), BOUND);
        vm.prank(address(vault));
        ace.setRollPolicy(address(meter));
        _fundFee(borrower, loanId);
    }

    /// @notice Through the real `extend`, the vault's policy answered yes for under 150k gas.
    function test_Gas_ThePolicyWithAStandingRequestFitsUnder150k() public {
        vm.prank(borrower);
        ace.extend(loanId, 0, "");
        assertEq(_expiry(loanId), _now() + MIN_TENOR, "the metered policy answered yes inside the bound");
    }
}
