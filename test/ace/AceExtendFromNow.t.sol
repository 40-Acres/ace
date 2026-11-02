// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.36;

import {Ace, LoanMatured} from "../../src/ace/hub/Ace.sol";
import {Borrower, ExtensionAddsNoTime, LoanClosed, NotBorrower} from "../../src/ace/hub/Borrower.sol";
import {LoanMath} from "../../src/ace/hub/libraries/LoanMath.sol";
import {Loan, MigrateArgs, OpenBounds} from "../../src/ace/hub/Types.sol";
import {AceLens} from "../../src/ace/lens/AceLens.sol";
import {Extension, IRollPolicy} from "../../src/interfaces/IRollPolicy.sol";
import {IPermit2} from "../../src/interfaces/IPermit2.sol";
import {MockPermit2} from "../mocks/MockPermit2.sol";
import {ExtendRig} from "../utils/ExtendRig.sol";
import {MatchingPolicy, NoPolicy, YesPolicy} from "../utils/RollPolicyMocks.sol";

/// @title AceExtendFromNowTest
/// @notice `extend` re-anchors a live loan at its own tenor from now, and charges the fee on exactly the time it adds.
/// @notice It lands only strictly inside `(openTime, expiry)`: the open second adds nothing and refuses, and from expiry it refuses `LoanMatured`.
/// @notice From the expiry second `refinanceTo` refuses `LoanMatured` too, so a matured loan leaves only by repay, forceClose or finalize.
/// @dev Reasoning: the design record.
contract AceExtendFromNowTest is ExtendRig {
    address internal constant PERMIT2 = 0x000000000022D473030F116dDEE9F6B43aC78BA3;
    uint256 internal constant PBOR_PK = 0xB0B0B; // a borrower with a key, for the row that signs a permit
    uint64 internal constant TEN14 = 14 days;

    AceLens internal lens;
    YesPolicy internal yes;
    address internal pbor;

    /// @dev What a refused call must leave exactly where it was.
    struct Snap {
        Loan loan;
        uint256 escrow;
        uint256 revenue;
        uint256 owed;
        uint256 drawCount;
        uint256 payer;
        uint256 hub;
    }

    /// @dev One extension's fee and its three legs, read off the books.
    struct Legs {
        uint256 fee;
        uint256 protocol;
        uint256 escrow;
        uint256 tick;
    }

    function setUp() public override {
        super.setUp();
        lens = new AceLens(address(ace));
        yes = new YesPolicy();
        _setPolicy(alice, address(yes));
        _deposit(id, alice, 4 * P);
        pbor = vm.addr(PBOR_PK);
        vm.etch(PERMIT2, address(new MockPermit2()).code);
    }

    /* ============================== helpers ============================== */

    /// @dev `who` extends `loanId` now, funded for the ceiling first.
    function _ext(address who, uint256 loanId) internal returns (uint256 fee) {
        _fund(who, _ceiling(loanId));
        vm.prank(who);
        fee = ace.extend(loanId, 0, "");
    }

    /// @dev The extension the hub asks now for `caller`: the loan as it stands, its end moved to now plus its own tenor.
    function _askedNow(uint256 loanId, address caller) internal view returns (Extension memory e) {
        e = _extensionOf(loanId, caller);
        e.newExpiry = uint64(_now()) + read.loan(loanId).tenor;
    }

    function _snap(uint256 loanId, address payer) internal view returns (Snap memory s) {
        s.loan = read.loan(loanId);
        s.escrow = read.feeEscrowOf(loanId);
        s.revenue = read.protocolRevenue(s.loan.market);
        (,, s.owed) = read.poolOf(s.loan.market);
        s.drawCount = read.marketState(s.loan.market).drawCount;
        s.payer = usdc.balanceOf(payer);
        s.hub = usdc.balanceOf(address(ace));
    }

    function _assertUnmoved(uint256 loanId, address payer, Snap memory s) internal view {
        Loan memory l = read.loan(loanId);
        assertEq(l.openTime, s.loan.openTime, "the open time did not move");
        assertEq(l.tenor, s.loan.tenor, "nor the tenor");
        assertEq(l.expiry, s.loan.expiry, "nor the expiry");
        assertEq(l.closedAt, s.loan.closedAt, "nor the close");
        assertEq(l.debt, s.loan.debt, "nor the debt");
        assertEq(l.collateralUnits, s.loan.collateralUnits, "nor the lot");
        assertEq(read.feeEscrowOf(loanId), s.escrow, "nor the escrow");
        assertEq(read.protocolRevenue(l.market), s.revenue, "nor revenue");
        (,, uint256 owed) = read.poolOf(l.market);
        assertEq(owed, s.owed, "nor owed");
        assertEq(read.marketState(l.market).drawCount, s.drawCount, "nor the draw counter");
        assertEq(usdc.balanceOf(payer), s.payer, "nothing was pulled from the caller");
        assertEq(usdc.balanceOf(address(ace)), s.hub, "and the hub holds what it held");
    }

    /// @dev `who`'s extension of `loanId` refuses `sel` at both previews and at the verb, leaving every book where it was.
    /// @dev The policy is a no, which is the ordering proof: a hub asking it first would answer `PolicyRefused` instead.
    function _assertRefusedWhole(uint256 loanId, address who, bytes4 sel) internal {
        NoPolicy no = new NoPolicy();
        _setPolicy(alice, address(no));
        (bool ok, bytes4 why, uint256 fee) = ace.tryExtend(loanId, 0, "", who);
        assertFalse(ok, "the hub preview refuses");
        assertEq(why, sel, "by the expected leg");
        assertEq(fee, 0, "with no fee");
        (ok, why, fee) = lens.tryExtend(loanId, 0, "", who);
        assertTrue(!ok && why == sel && fee == 0, "the lens forwards the same answer");
        _fund(who, _ceiling(loanId));
        Snap memory s0 = _snap(loanId, who);
        vm.expectCall(address(no), abi.encodePacked(IRollPolicy.admitsExtension.selector), 0);
        vm.prank(who);
        vm.expectRevert(sel);
        ace.extend(loanId, 0, "");
        _assertUnmoved(loanId, who, s0);
    }

    /// @dev A migration of `loanId` into `dst` at one and a half times P for TEN7, shedding `units` to the borrower when non-zero.
    function _mig(uint256 loanId, bytes32 dst, uint256 units) internal view returns (MigrateArgs memory) {
        return MigrateArgs(loanId, dst, P + P / 2, TEN7, OpenBounds(0, 0, 0), units, units == 0 ? address(0) : borrower);
    }

    /// @dev The matured migration `m` refuses `LoanMatured` with nothing moved and no successor minted, sent bare or as a multicall leg.
    function _assertRefinanceRefused(MigrateArgs memory m, bool viaMulticall) internal {
        Snap memory s0 = _snap(m.id, borrower);
        uint256 n = read.loanCount();
        uint256 dstCash = ace.restingOf(m.dst);
        vm.prank(borrower);
        vm.expectRevert(LoanMatured.selector);
        if (viaMulticall) {
            bytes[] memory legs = new bytes[](1);
            legs[0] = abi.encodeCall(Ace.refinanceTo, (m));
            ace.multicall(legs);
        } else {
            ace.refinanceTo(m);
        }
        _assertUnmoved(m.id, borrower, s0);
        assertEq(read.loanCount(), n, "no successor id was minted");
        assertEq(ace.restingOf(m.dst), dstCash, "and the destination lent nothing");
    }

    /// @dev What the market's lender holds of its credit here: its wallet plus its uncollected pool credit.
    function _lenderValue() internal view returns (uint256) {
        (,, uint256 owed) = read.poolOf(id);
        return usdc.balanceOf(alice) + owed;
    }

    /// @dev One extension of `loanId` now, its legs read off the books, the earned slice taken out of `owed` and put back in the escrow leg.
    function _extensionLegs(uint256 loanId) internal returns (Legs memory g) {
        uint256 e0 = read.feeEscrowOf(loanId);
        uint256 earned = e0 - _unearned(loanId, e0);
        uint256 rev0 = read.protocolRevenue(id);
        (,, uint256 owed0) = read.poolOf(id);
        _fund(borrower, _ceiling(loanId));
        uint256 bal0 = usdc.balanceOf(borrower);
        vm.prank(borrower);
        g.fee = ace.extend(loanId, 0, "");
        assertEq(bal0 - usdc.balanceOf(borrower), g.fee, "the caller paid the fee it was charged");
        (,, uint256 owed1) = read.poolOf(id);
        g.protocol = read.protocolRevenue(id) - rev0;
        g.tick = owed1 - owed0 - earned;
        g.escrow = read.feeEscrowOf(loanId) + earned - e0;
        assertEq(g.protocol + g.escrow + g.tick, g.fee, "this call's legs sum to its fee");
    }

    function _sign(uint256 pk, address token, uint256 amt, uint256 nonce, uint256 deadline) internal view returns (bytes memory) {
        MockPermit2 p2 = MockPermit2(PERMIT2);
        bytes32 structHash = keccak256(
            abi.encode(p2.PERMIT_TRANSFER_FROM_TYPEHASH(), keccak256(abi.encode(p2.TOKEN_PERMISSIONS_TYPEHASH(), token, amt)), address(ace), nonce, deadline)
        );
        (uint8 v, bytes32 r, bytes32 s) = vm.sign(pk, keccak256(abi.encodePacked("\x19\x01", p2.DOMAIN_SEPARATOR(), structHash)));
        return abi.encodePacked(r, s, v);
    }

    /// @dev A SignatureTransfer blob for `amt` of the quote; build it BEFORE a prank, since its reads are calls.
    function _blob(uint256 pk, uint256 amt, uint256 nonce) internal view returns (bytes memory) {
        uint256 deadline = _now() + 1 hours;
        IPermit2.PermitTransferFrom memory p = IPermit2.PermitTransferFrom(IPermit2.TokenPermissions(address(usdc), amt), nonce, deadline);
        return abi.encode(p, _sign(pk, address(usdc), amt, nonce, deadline));
    }

    /* ============================== 1. the term runs from now ============================== */

    /// @notice From open + 1 s to expiry - 1 s an extension runs the loan's own tenor from now: the term re-anchors, the tenor holds, I1 holds.
    /// @notice The new end is strictly later, at most `maxTenor` ahead, and strictly before the old additive `expiry + tenor`.
    function testFuzz_AnExtensionRunsTheLoansOwnTenorFromNow(uint256 tSeed, uint256 atSeed) public {
        uint64 t = uint64(bound(tSeed, TEN7, MAX_T));
        uint256 loanId = _open(P, t, 5000);
        Loan memory l0 = read.loan(loanId);
        _warpTo(bound(atSeed, uint256(l0.openTime) + 1, uint256(l0.expiry) - 1));
        _ext(borrower, loanId);
        Loan memory l1 = read.loan(loanId);
        assertEq(l1.expiry, _now() + t, "the new expiry is now plus the loan's own tenor");
        assertEq(l1.openTime, _now(), "the term re-anchors at now");
        assertEq(l1.tenor, t, "the tenor never moves");
        assertEq(uint256(l1.openTime) + l1.tenor, l1.expiry, "I1: openTime + tenor == expiry");
        assertGt(l1.expiry, l0.expiry, "the loan's end moves strictly later");
        assertLe(l1.expiry, _now() + MAX_T, "never more than maxTenor ahead of now");
        assertLt(l1.expiry, uint256(l0.expiry) + t, "and strictly before the old additive expiry + tenor");
    }

    /// @notice Both edges of the window land, each at now plus the tenor: one second after the open, and one second before expiry.
    function test_BothEdgesOfTheWindowLand() public {
        uint256 loanId = _open(P, TEN7, 5000);
        uint64 x = read.loan(loanId).expiry;
        uint256 snap = vm.snapshotState();
        _warpBy(1);
        _ext(borrower, loanId);
        assertEq(read.loan(loanId).expiry, _now() + TEN7, "open + 1 s lands at now plus the tenor");
        vm.revertToState(snap);
        _warpTo(uint256(x) - 1);
        _ext(borrower, loanId);
        assertEq(read.loan(loanId).expiry, _now() + TEN7, "expiry - 1 s lands at now plus the tenor");
    }

    /// @notice Across many extensions at varied seconds the stored tenor never moves, and each one leaves `openTime + tenor == expiry`.
    function test_TheTenorHoldsAcrossManyExtensions() public {
        uint256 loanId = _open(P, TEN14, 5000);
        uint64[6] memory steps = [uint64(1), 3 days, 1 hours, 13 days, 7 days, TEN14 - 1];
        for (uint256 i; i < steps.length; i++) {
            _warpBy(steps[i]);
            _ext(borrower, loanId);
            Loan memory l = read.loan(loanId);
            assertEq(l.tenor, TEN14, "the tenor holds");
            assertEq(l.expiry, _now() + TEN14, "each extension runs the tenor from now");
            assertEq(uint256(l.openTime) + l.tenor, l.expiry, "I1 after every extension");
        }
    }

    /// @notice `Extended` reports the time the extension added in place of a tenor, beside the new expiry and the fee.
    function test_ExtendedLogsTheTimeAdded() public {
        uint256 loanId = _open(P, TEN14, 5000);
        _warpBy(2 days);
        uint256 fee = _fee(read.debtOf(loanId), 2 days);
        _fund(borrower, _ceiling(loanId));
        vm.expectEmit(true, true, false, true, address(ace));
        emit Borrower.Extended(loanId, 2 days, uint64(_now()) + TEN14, fee, borrower);
        vm.prank(borrower);
        ace.extend(loanId, 0, "");
    }

    /// @notice The policy is asked the extension with `newExpiry` at now plus the tenor, so `newExpiry - expiry` is exactly the time added.
    function test_ThePolicyIsAskedNewExpiryAtNowPlusTheTenor() public {
        MatchingPolicy m = new MatchingPolicy();
        _setPolicy(alice, address(m));
        uint256 loanId = _open(P, TEN14, 5000);
        _warpBy(3 days);
        Extension memory e = _askedNow(loanId, borrower);
        m.expect(e, hex"c0ffee");
        _fund(borrower, _ceiling(loanId));
        vm.prank(borrower);
        ace.extend(loanId, 0, hex"c0ffee");
        assertEq(read.loan(loanId).expiry, e.newExpiry, "the matching ask consented, at the expiry it was shown");
        assertEq(e.newExpiry - e.expiry, 3 days, "and the policy's view of the time added is the time added");
    }

    /* ============================== 2. the open second adds nothing ============================== */

    /// @notice The open second adds no time: both previews and the verb refuse `ExtensionAddsNoTime`, before the policy, writing nothing.
    function test_TheOpenSecondRefusesExtensionAddsNoTime() public {
        uint256 loanId = _open(P, TEN7, 5000);
        _assertRefusedWhole(loanId, borrower, ExtensionAddsNoTime.selector);
    }

    /// @notice A second extension in the same second as the first adds no time either, and refuses the same way.
    function test_ASecondExtensionInTheSameSecondRefusesExtensionAddsNoTime() public {
        uint256 loanId = _open(P, TEN7, 5000);
        _warpBy(1 days);
        _ext(borrower, loanId);
        _assertRefusedWhole(loanId, borrower, ExtensionAddsNoTime.selector);
    }

    /* ============================== 3. no extension from expiry ============================== */

    /// @notice From the expiry second every extend door refuses `LoanMatured`, at expiry and a day later: nothing moves, nothing is pulled, no policy asked.
    function test_FromTheExpirySecondExtendRefusesLoanMatured() public {
        uint256 loanId = _open(P, TEN7, 5000);
        uint64 x = read.loan(loanId).expiry;
        _warpTo(x);
        _assertRefusedWhole(loanId, borrower, LoanMatured.selector);
        _warpTo(uint256(x) + 1 days);
        _assertRefusedWhole(loanId, borrower, LoanMatured.selector);
    }

    /// @notice The granted lender is refused `LoanMatured` from expiry too: the matured leg judges the loan, not the caller.
    function test_TheGrantedLenderIsRefusedLoanMaturedFromExpiry() public {
        uint256 loanId = _open(P, TEN7, 5000);
        vm.prank(borrower);
        ace.setCreditOperator(alice, true);
        _warpTo(read.loan(loanId).expiry);
        _assertRefusedWhole(loanId, alice, LoanMatured.selector);
    }

    /// @notice The caller leg still runs before the matured one: a stranger from expiry is refused `NotBorrower`.
    function test_AStrangerFromExpiryIsRefusedNotBorrowerFirst() public {
        uint256 loanId = _open(P, TEN7, 5000);
        _warpTo(read.loan(loanId).expiry);
        _assertRefusedWhole(loanId, stranger, NotBorrower.selector);
    }

    /// @notice From expiry the Permit2 door refuses `LoanMatured` before the pull: no quote moves and the signed nonce stays unspent.
    function test_FromExpiryThePermitDoorRefusesAndSpendsNoNonce() public {
        uint256 loanId = _openIn(id, pbor, P, TEN7, 5000);
        _warpTo(read.loan(loanId).expiry);
        uint256 fee = _ceiling(loanId);
        usdc.mint(pbor, fee);
        vm.startPrank(pbor);
        usdc.approve(address(ace), 0);
        usdc.approve(PERMIT2, type(uint256).max);
        vm.stopPrank();
        uint256 bal = usdc.balanceOf(pbor);
        bytes memory blob = _blob(PBOR_PK, fee, 0);
        vm.prank(pbor);
        vm.expectRevert(LoanMatured.selector);
        ace.extendWithPermit2(loanId, 0, "", blob);
        assertEq(usdc.balanceOf(pbor), bal, "nothing was pulled");
        assertEq(MockPermit2(PERMIT2).nonceBitmap(pbor, 0), 0, "and the nonce is unspent");
        assertTrue(ace.isLiveLoan(loanId), "the loan is still live, for settlement");
    }

    /// @notice A matured loan the extend doors refused still settles: `forceClose` lands in the same second.
    function test_AfterTheRefusedExtensionForceCloseSettles() public {
        uint256 loanId = _open(P, TEN7, 5000);
        _warpTo(read.loan(loanId).expiry);
        _fund(borrower, _ceiling(loanId));
        vm.prank(borrower);
        vm.expectRevert(LoanMatured.selector);
        ace.extend(loanId, 0, "");
        vm.prank(keeper);
        ace.forceClose(loanId);
        assertTrue(ace.isClosed(loanId), "forceClose settled the matured loan");
    }

    /* ============================== 4. no refinance from expiry ============================== */

    /// @notice From the expiry second `refinanceTo` refuses `LoanMatured`: own market or another, with or without a withdrawal leg, bare or in a multicall.
    /// @notice Nothing moves and no policy is asked; at `expiry - 1` the same four migrations land.
    function test_FromTheExpirySecondRefinanceRefusesLoanMatured() public {
        bytes32 other = _siblingOf(bob, 3 * P);
        uint256 loanId = _open(P, TEN7, 5000);
        uint256 shed = read.loan(loanId).collateralUnits / 10;
        MigrateArgs[4] memory ms;
        (ms[0], ms[1]) = (_mig(loanId, id, 0), _mig(loanId, id, shed));
        (ms[2], ms[3]) = (_mig(loanId, other, 0), _mig(loanId, other, shed));
        uint64 x = read.loan(loanId).expiry;
        _warpTo(uint256(x) - 1);
        for (uint256 i; i < ms.length; i++) {
            uint256 snap = vm.snapshotState();
            vm.prank(borrower);
            uint256 newId = ace.refinanceTo(ms[i]);
            assertTrue(ace.isLiveLoan(newId), "CONTROL: a second before expiry the migration lands");
            vm.revertToState(snap);
        }
        _warpTo(x);
        vm.expectCall(address(yes), abi.encodePacked(IRollPolicy.admitsExtension.selector), 0);
        for (uint256 i; i < ms.length; i++) {
            _assertRefinanceRefused(ms[i], false);
            _assertRefinanceRefused(ms[i], true);
        }
    }

    /// @notice After a matured refinance is refused, each exit still lands: a full repay, `forceClose`, and `finalize` on persisted distress.
    function test_AfterTheRefusedRefinanceEveryExitStillLands() public {
        uint256 loanId = _open(P, TEN7, 5000);
        _warpTo(read.loan(loanId).expiry);
        MigrateArgs memory m = _mig(loanId, id, 0);
        vm.prank(borrower);
        vm.expectRevert(LoanMatured.selector);
        ace.refinanceTo(m);
        uint256 snap = vm.snapshotState();
        uint256 debt = read.debtOf(loanId);
        _fund(borrower, debt);
        vm.prank(borrower);
        ace.repay(loanId, debt);
        assertTrue(ace.isClosed(loanId), "a full repay closes the matured loan");
        vm.revertToState(snap);
        vm.prank(keeper);
        ace.forceClose(loanId);
        assertTrue(ace.isClosed(loanId), "forceClose settles it");
        vm.revertToState(snap);
        rec.setBelow(true);
        vm.prank(keeper);
        ace.finalize(loanId);
        assertTrue(ace.isClosed(loanId), "and finalize settles it on persisted distress, reading no clock");
    }

    /// @notice The gate runs after the borrower leg and before the recipient rule; a closed loan still answers `LoanClosed`.
    function test_TheRefinanceGateRunsAfterTheCallerAndBeforeTheRecipient() public {
        uint256 loanId = _open(P, TEN7, 5000);
        _warpTo(read.loan(loanId).expiry);
        MigrateArgs memory m = _mig(loanId, id, 0);
        vm.prank(stranger);
        vm.expectRevert(NotBorrower.selector);
        ace.refinanceTo(m);
        MigrateArgs memory bad = _mig(loanId, id, 1);
        bad.withdrawTo = address(ace);
        vm.prank(borrower);
        vm.expectRevert(LoanMatured.selector);
        ace.refinanceTo(bad);
        vm.prank(keeper);
        ace.forceClose(loanId);
        vm.prank(borrower);
        vm.expectRevert(LoanClosed.selector);
        ace.refinanceTo(m);
    }

    /* ============================== 5. the fee is the time added ============================== */

    /// @notice The fee is the origination fee on the time added, `newExpiry - expiry`, which under I1 is the time since the term opened.
    /// @notice It never exceeds the fee on the loan's whole tenor, the ceiling a caller signs for, and the preview quotes it exactly.
    function testFuzz_TheFeeIsTheFeeOnTheTimeAdded(uint256 pSeed, uint256 tSeed, uint256 atSeed) public {
        uint256 principal = bound(pSeed, MIN_PRINCIPAL, 2 * P);
        uint64 t = uint64(bound(tSeed, TEN7, MAX_T));
        uint256 loanId = _open(principal, t, 5000);
        Loan memory l0 = read.loan(loanId);
        _warpTo(bound(atSeed, uint256(l0.openTime) + 1, uint256(l0.expiry) - 1));
        (bool ok,, uint256 quoted) = ace.tryExtend(loanId, 0, "", borrower);
        assertTrue(ok, "PREMISE: the preview admits");
        uint256 fee = _ext(borrower, loanId);
        Loan memory l1 = read.loan(loanId);
        assertEq(fee, _fee(principal, l1.expiry - l0.expiry), "the fee is the fee on the time added");
        assertEq(fee, _fee(principal, uint64(_now() - l0.openTime)), "which is the time since the term opened");
        assertEq(quoted, fee, "the preview quoted it exactly");
        assertLe(fee, _fee(principal, t), "never more than the fee on the loan's whole tenor");
    }

    /// @notice One second added on the smallest live debt, half `minPrincipal`, still costs an atom: no extension is free.
    function test_OneSecondOnTheDebtFloorCostsAnAtom() public {
        uint256 loanId = _open(P, TEN7, 5000);
        uint256 floor = LoanMath.debtFloor(MIN_PRINCIPAL);
        _fund(borrower, P - floor);
        vm.prank(borrower);
        ace.repay(loanId, P - floor);
        assertEq(read.debtOf(loanId), floor, "PREMISE: the debt sits on its floor");
        _warpBy(1);
        uint256 bal = usdc.balanceOf(borrower) + _ceiling(loanId);
        uint256 fee = _ext(borrower, loanId);
        assertEq(fee, _fee(floor, 1), "the fee on one second");
        assertGt(fee, 0, "is at least one atom");
        assertEq(bal - usdc.balanceOf(borrower), fee, "and the caller paid it");
    }

    /* ============================== 6. one second at a time ============================== */

    /// @notice N one-second extensions cost what one N-second extension costs, to an atom a call, and each call's legs close exactly.
    /// @notice The fees sit in `[F(N s), F(N s) + N]`; the protocol and escrow legs within `N + 1` of the one-shot split, the tick leg within `2N + 2`.
    function test_NOneSecondExtensionsCostOneNSecondExtensionToTheAtom() public {
        uint256 n = 24;
        uint256 loanId = _open(P, TEN7, 5000);
        uint256 debt = read.debtOf(loanId);
        Legs memory sum;
        for (uint256 i; i < n; i++) {
            _warpBy(1);
            Legs memory g = _extensionLegs(loanId);
            (sum.fee, sum.protocol) = (sum.fee + g.fee, sum.protocol + g.protocol);
            (sum.escrow, sum.tick) = (sum.escrow + g.escrow, sum.tick + g.tick);
        }
        uint256 one = _fee(debt, uint64(n));
        assertGe(sum.fee, one, "the calls together pay at least the one-shot fee");
        assertLe(sum.fee, one + n, "and at most an atom a call more");
        assertApproxEqAbs(sum.protocol, LoanMath.protocolCut(one), n + 1, "the protocol leg within N + 1 of the one-shot split");
        assertApproxEqAbs(sum.escrow, LoanMath.escrowCut(one), n + 1, "the escrow leg within N + 1");
        assertApproxEqAbs(sum.tick, LoanMath.tickCut(one), 2 * n + 2, "the tick leg within 2N + 2");
        assertEq(sum.protocol + sum.escrow + sum.tick, sum.fee, "the three legs sum to the fees paid");
    }

    /* ============================== 7. the escrow (R39) ============================== */

    /// @notice R39: earned plus refunded is every escrow atom, exactly, across an early extension, a partial repay, a later extension and the close.
    function test_R39_EarnedPlusRefundedIsEveryEscrowAtom() public {
        uint256 loanId = _open(P, TEN14, 5000);
        uint256 inflow = read.feeEscrowOf(loanId);
        uint256 lender0 = _lenderValue();
        uint256 ticks;
        _warpBy(1 days);
        uint256 fee = _ext(borrower, loanId);
        (inflow, ticks) = (inflow + LoanMath.escrowCut(fee), ticks + LoanMath.tickCut(fee));
        _warpBy(3 days);
        uint256 part = P / 3;
        _fund(borrower, part);
        vm.prank(borrower);
        ace.repay(loanId, part);
        _warpBy(5 days);
        fee = _ext(borrower, loanId);
        (inflow, ticks) = (inflow + LoanMath.escrowCut(fee), ticks + LoanMath.tickCut(fee));
        _warpBy(2 days);
        uint256 debt = read.debtOf(loanId);
        _fund(borrower, debt);
        vm.prank(borrower);
        ace.repay(loanId, debt);
        assertTrue(ace.isClosed(loanId), "PREMISE: the repay closed the loan");
        uint256 earned = _lenderValue() - lender0 - ticks - P;
        uint256 refunded = read.quoteOwedOf(loanId, borrower);
        assertGt(earned, 0, "PREMISE: the lender earned part of the escrow");
        assertGt(refunded, 0, "PREMISE: and part of it refunds");
        assertEq(earned + refunded, inflow, "earned plus refunded is every atom that entered the escrow");
    }

    /// @notice At constant debt the pot stays one tenor's escrow: after N extensions it is within 3N atoms of the whole-tenor fee's escrow cut.
    function test_AtConstantDebtThePotStaysOneTenorsEscrow() public {
        uint256 loanId = _open(P, TEN14, 5000);
        uint256 one = LoanMath.escrowCut(_fee(P, TEN14));
        uint64[5] memory steps = [uint64(1 days), 5 days, 1, 13 days, 2 hours];
        for (uint256 i; i < steps.length; i++) {
            _warpBy(steps[i]);
            _ext(borrower, loanId);
            assertApproxEqAbs(read.feeEscrowOf(loanId), one, 3 * (i + 1), "the pot stays one tenor's escrow, to three atoms an extension");
        }
    }

    /* ============================== 8. a successor's tenor is its own ============================== */

    /// @notice A `refinanceTo` successor is a new id with a tenor of its own, and its extensions run that tenor from now.
    function test_ARefinanceSuccessorExtendsOnItsOwnTenor() public {
        uint256 loanId = _open(P, TEN7, 5000);
        _warpBy(2 days);
        MigrateArgs memory m = _mig(loanId, id, 0);
        m.newTenor = 21 days;
        vm.prank(borrower);
        uint256 newId = ace.refinanceTo(m);
        assertEq(read.loan(newId).tenor, 21 days, "the successor carries its own tenor");
        _warpBy(4 days);
        _ext(borrower, newId);
        Loan memory l = read.loan(newId);
        assertEq(l.tenor, 21 days, "which an extension keeps");
        assertEq(l.expiry, _now() + 21 days, "and runs from now");
    }

    /// @notice A zero `newTenor` gives the successor the destination's `minTenor`, and its extensions run that.
    function test_AZeroTenorSuccessorExtendsOnTheDestinationsMinTenor() public {
        uint256 loanId = _open(P, TEN14, 5000);
        _warpBy(2 days);
        MigrateArgs memory m = _mig(loanId, id, 0);
        m.newTenor = 0;
        vm.prank(borrower);
        uint256 newId = ace.refinanceTo(m);
        assertEq(read.loan(newId).tenor, TEN7, "the successor takes the destination's minTenor");
        _warpBy(1 days);
        _ext(borrower, newId);
        Loan memory l = read.loan(newId);
        assertEq(l.tenor, TEN7, "which an extension keeps");
        assertEq(l.expiry, _now() + TEN7, "and runs from now");
    }
}
