// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.36;

import {FullMath} from "@uniswap/v4-core/src/libraries/FullMath.sol";
import {FairnessHarness} from "./FairnessHarness.sol";
import {MockDeleverageKeeper} from "../mocks/MockDeleverageKeeper.sol";
import {YesPolicy} from "../utils/RollPolicyMocks.sol";
import {LoanMath} from "../../src/ace/hub/libraries/LoanMath.sol";
import {OpenBounds} from "../../src/ace/hub/Types.sol";

/// @title FairnessPathOrder
/// @notice Family F4, path and order independence: two doors open at one instant take the same, and the caller never changes the take.
/// @notice The caller keeps only the keeper sliver; the pot and the borrower's residual are the same whoever sends the settlement.
/// @notice A top-up re-anchors one fee schedule, and the refund at a close is still the tranches' sum whatever order they land in.
contract FairnessPathOrderTest is FairnessHarness {
    struct Take {
        uint256 pot;
        uint256 borrowerUnits;
        uint256 callerUnits;
        uint256 borrowerQuote;
        uint256 lenderQuote;
    }

    /// @dev Open at `thetaBps` in class `k`, print `bps` in the next step, and stand at `atExpiry` or one step later.
    function _standing(Kind k, uint256 thetaBps, uint256 bps, bool atExpiry) internal returns (bytes32 mid, uint256 loanId) {
        mid = _mid(k);
        _deposit(mid, alice, 2 * D);
        _budget();
        loanId = _openRun(mid, _baseRun(k, thetaBps, _flatAt(10000, 1)));
        _warpBy(STEP);
        _printBps(bps);
        if (atExpiry) _warpAtLeastTo(read.loan(loanId).expiry);
    }

    function _settleAs(address caller, bytes32 mid, uint256 loanId, bool forced) internal returns (Take memory t) {
        vm.prank(caller);
        if (forced) ace.forceClose(loanId);
        else ace.finalize(loanId);
        t.pot = read.invPotOf(mid, loanId);
        t.borrowerUnits = read.unitsOwedOf(loanId, borrower);
        t.callerUnits = read.unitsOwedOf(loanId, caller);
        t.borrowerQuote = read.quoteOwedOf(loanId, borrower);
        (uint256 resting, uint256 lent, uint256 owed) = read.lenderPools(alice, address(usdc));
        t.lenderQuote = usdc.balanceOf(alice) + resting + lent + owed;
    }

    function _assertSameTake(Take memory x, Take memory y, string memory what) internal pure {
        assertEq(x.pot, y.pot, string.concat(what, ": the pot differs"));
        assertEq(x.borrowerUnits, y.borrowerUnits, string.concat(what, ": the borrower's residual differs"));
        assertEq(x.callerUnits, y.callerUnits, string.concat(what, ": the sliver differs"));
        assertEq(x.borrowerQuote, y.borrowerQuote, string.concat(what, ": the borrower's quote differs"));
        assertEq(x.lenderQuote, y.lenderQuote, string.concat(what, ": the lender's quote differs"));
    }

    /* ================================ F4.1 two doors at one instant ================================ */

    /// @notice F4.1: from the expiry second a distressed loan can be finalized or force-closed, and the two doors take the same.
    function test_F4_1_FinalizeAndForceCloseAtOneInstantTakeTheSame() public {
        for (uint256 k; k < 2; ++k) {
            Kind kind = k == 0 ? Kind.BandOff : Kind.BandOn;
            uint256 snap0 = vm.snapshotState();
            (bytes32 mid, uint256 loanId) = _standing(kind, kind == Kind.BandOn ? 6500 : 9000, 6000, true);
            uint256 snap = vm.snapshotState();
            Take memory f = _settleAs(keeper, mid, loanId, false);
            vm.revertToState(snap);
            Take memory c = _settleAs(keeper, mid, loanId, true);
            assertGt(f.pot, 0, "fixture: the finalize door is open at expiry");
            _assertSameTake(f, c, "F4.1");
            vm.revertToState(snap0);
        }
    }

    /* ================================ F4.2 the caller's identity ================================ */

    function _caller(uint256 i) internal view returns (address) {
        if (i == 0) return alice;
        if (i == 1) return stranger;
        if (i == 2) return bob;
        return borrower;
    }

    /// @notice F4.2 for `finalize` and `forceClose`: whoever sends the settlement, the pot, the residual and the sliver are the keeper's own run's.
    function test_F4_2_TheCallerNeverChangesTheTake() public {
        for (uint256 d; d < 3; ++d) {
            Kind kind = d == 2 ? Kind.Recordless : Kind.BandOff;
            bool forced = d != 0;
            uint256 snap0 = vm.snapshotState();
            (bytes32 mid, uint256 loanId) = _standing(kind, 9000, forced ? 9500 : 6000, forced);
            uint256 snap = vm.snapshotState();
            Take memory base = _settleAs(keeper, mid, loanId, forced);
            for (uint256 i; i < 4; ++i) {
                vm.revertToState(snap);
                address caller = _caller(i);
                Take memory t = _settleAs(caller, mid, loanId, forced);
                if (caller == borrower) (t.borrowerUnits, t.callerUnits) = (t.borrowerUnits - base.callerUnits, base.callerUnits);
                _assertSameTake(base, t, "F4.2");
            }
            vm.revertToState(snap0);
        }
    }

    /// forge-config: default.fuzz.runs = 64
    /// @notice F4.2 over any caller and any distress print: a finalize by anyone takes what the keeper's would.
    function testFuzz_F4_2_AnyCallerTakesTheSame(address caller, uint256 bps) public {
        vm.assume(caller != address(0) && caller != borrower && caller != alice && caller != keeper);
        vm.assume(caller.code.length == 0 && uint160(caller) > 0x10000);
        (bytes32 mid, uint256 loanId) = _standing(Kind.BandOff, 9000, bound(bps, 500, 8900), false);
        uint256 snap = vm.snapshotState();
        Take memory base = _settleAs(keeper, mid, loanId, false);
        vm.revertToState(snap);
        _assertSameTake(base, _settleAs(caller, mid, loanId, false), "F4.2");
    }

    /* ================================ F4.3 the cranker's identity ================================ */

    /// @notice F4.3: whoever cranks, the sale is the same: units sold, quote realized, debt left and the protocol's cut.
    function test_F4_3_TheCrankerNeverChangesTheSale() public {
        (, uint256 loanId) = _standing(Kind.BandOn, 6500, 8500, false);
        MockDeleverageKeeper other = new MockDeleverageKeeper(ace, address(usdc), address(coll), S);
        uint256 snap = vm.snapshotState();
        (uint256 u1, uint256 s1) = ace.deleverage(loanId, 0, "");
        (uint256 debt1, uint256 units1, uint256 cut1) = (read.loan(loanId).debt, read.loan(loanId).collateralUnits, read.revenuePot(address(usdc)));
        vm.revertToState(snap);
        (uint256 u2, uint256 s2) = other.crankDeleverage(loanId);
        assertGt(u1, 0, "fixture: the crank sells");
        assertEq(u2, u1, "F4.3: the units sold differ by cranker");
        assertEq(s2, s1, "F4.3: the quote realized differs by cranker");
        assertEq(read.loan(loanId).debt, debt1, "F4.3: the debt left differs by cranker");
        assertEq(read.loan(loanId).collateralUnits, units1, "F4.3: the lot left differs by cranker");
        assertEq(read.revenuePot(address(usdc)), cut1, "F4.3: the protocol's cut differs by cranker");
    }

    /* ================================ F4.5 the order of top-ups and an extension ================================ */

    uint256[] internal trLo; // each tranche's escrow, every carry floored
    uint256[] internal trHi; // each tranche's escrow, every carry ceiled
    uint64[] internal trStart; // each tranche's own start
    uint64 internal trEnd; // the one end every tranche earns to
    uint256 internal trN; // re-anchors so far: each is one floor in the hub

    /// @dev A tranche's share still unearned now, floored or ceiled: linear from its own start to the shared end.
    function _trShare(uint256 e, uint64 t0, bool up) internal view returns (uint256) {
        uint64 t = uint64(_now());
        if (t >= trEnd) return 0;
        return up ? FullMath.mulDivRoundingUp(e, trEnd - t, trEnd - t0) : FullMath.mulDiv(e, trEnd - t, trEnd - t0);
    }

    function _trOracle() internal view returns (uint256 down, uint256 up) {
        for (uint256 i; i < trLo.length; ++i) {
            down += _trShare(trLo[i], trStart[i], false);
            up += _trShare(trHi[i], trStart[i], true);
        }
    }

    function _trPush(uint256 lo, uint256 hi) internal {
        trLo.push(lo);
        trHi.push(hi);
        trStart.push(uint64(_now()));
    }

    /// @dev A loan of `D` at 30% of par for the longest term, its lender's yes installed; its open escrow is the first tranche.
    function _trOpen() internal returns (uint256 loanId) {
        _deposit(bandOff, alice, 4 * D);
        _budget();
        _setPolicy(alice, address(new YesPolicy()));
        loanId = _openLong(bandOff, D, 3000);
        _trPush(read.feeEscrowOf(loanId), read.feeEscrowOf(loanId));
        trEnd = read.loan(loanId).expiry;
    }

    /// @dev A top-up opens a tranche of its escrow cut from now; every other tranche keeps its start and the end.
    function _trTop(uint256 loanId, uint256 amount) internal {
        vm.prank(borrower);
        uint256 cut = LoanMath.escrowCut(ace.drawMore(loanId, amount, OpenBounds(0, 0, 0)));
        _trPush(cut, cut);
        trN++;
    }

    /// @dev A stranger's extension at the start of the last quarter carries every tranche's unearned part into one, adds its cut, and moves the end.
    function _trExtend(uint256 loanId) internal {
        _warpAtLeastTo(uint256(trEnd) - MAX_T / 4);
        (uint256 down, uint256 up) = _trOracle();
        _fund(stranger, _ceiling(loanId));
        vm.prank(stranger);
        uint256 cut = LoanMath.escrowCut(ace.extend(loanId, 0, ""));
        delete trLo;
        delete trHi;
        delete trStart;
        _trPush(down + cut, up + cut);
        trEnd = read.loan(loanId).expiry;
        trN++;
    }

    /// @dev One order: the extension first or last, the two top-ups between in the order given; then a closing repay a day on.
    function _trRoute(uint256 first, uint256 second, uint256 d1, uint256 d2, bool extensionFirst) internal returns (uint256 refund, uint256 down, uint256 up) {
        uint256 loanId = _trOpen();
        if (extensionFirst) _trExtend(loanId);
        _warpBy(d1);
        _trTop(loanId, first);
        _warpBy(d2);
        _trTop(loanId, second);
        if (!extensionFirst) _trExtend(loanId);
        _warpBy(1 days);
        (down, up) = _trOracle();
        uint256 debt = read.debtOf(loanId);
        _fund(borrower, debt);
        vm.prank(borrower);
        ace.repay(loanId, debt);
        refund = read.quoteOwedOf(loanId, borrower);
    }

    /// forge-config: default.fuzz.runs = 64
    /// @notice F4.5, B-6: whichever order two top-ups and a stranger's extension land in, the refund at a close is that order's tranches' sum.
    /// @notice Each tranche earns from its own draw to the one end, so the re-anchor moves no value: N + 1 atoms short at most, never over.
    function testFuzz_F4_5_TheRefundIsTheTranchesSumInAnyOrder(uint256 a1, uint256 a2, uint256 d1, uint256 d2, bool extensionFirst) public {
        (a1, a2) = (bound(a1, MIN_PRINCIPAL, D / 8), bound(a2, MIN_PRINCIPAL, D / 8));
        (d1, d2) = (bound(d1, 1, 10 days), bound(d2, 1, 10 days));
        for (uint256 i; i < 2; ++i) {
            uint256 snap = vm.snapshotState();
            (uint256 refund, uint256 down, uint256 up) = i == 0 ? _trRoute(a1, a2, d1, d2, extensionFirst) : _trRoute(a2, a1, d1, d2, extensionFirst);
            assertLe(refund, up, "F4.5: the refund exceeds the tranches' sum");
            assertGe(refund + trN + 1, down, "F4.5: the refund is more than N + 1 atoms short of the tranches' sum");
            vm.revertToState(snap);
        }
    }
}
