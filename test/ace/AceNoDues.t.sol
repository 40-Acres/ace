// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.36;

import {FullMath} from "@uniswap/v4-core/src/libraries/FullMath.sol";
import {Vm} from "forge-std/Vm.sol";
import {Loan, MigrateArgs, OpenBounds} from "../../src/ace/hub/Types.sol";
import {AceLens} from "../../src/ace/lens/AceLens.sol";
import {ExtendRig} from "../utils/ExtendRig.sol";
import {YesPolicy} from "../utils/RollPolicyMocks.sol";

/// @title AceNoDuesTest
/// @notice DUES MODE AND THE WHOLE DUES LAYER ARE GONE: after origination a loan's debt only falls, and it is always exactly its claim.
/// @notice An extension is paid in cash, so the debt equals the claim through every repay, deleverage, settlement and refinance after it.
/// @notice Settlement converts the claim alone: no escrow due joins it, and no protocol due is forfeited.
/// @dev Reasoning: the design record rulings 1 and 3, Q5.
contract AceNoDuesTest is ExtendRig {
    AceLens internal lens;

    function setUp() public override {
        super.setUp();
        lens = new AceLens(address(ace));
        _setPolicy(alice, address(new YesPolicy()));
        _deposit(id, alice, 4 * P);
    }

    /// @dev The borrower extends `loanId` now through the cash door, funded for the fee ceiling.
    function _ext(uint256 loanId) internal {
        _fund(borrower, _ceiling(loanId));
        vm.prank(borrower);
        ace.extend(loanId, 0, "");
    }

    /// @dev O10 on one live loan: its debt is exactly its claim.
    function _assertDebtIsClaim(uint256 loanId, string memory where) internal view {
        assertEq(read.debtOf(loanId), read.claimOf(id, loanId), string.concat("O10: debt != claim ", where));
    }

    /// @dev A loan a day in, extended once in cash: the subject every row starts from.
    function _extendedLoan(uint256 thetaBps) internal returns (uint256 loanId) {
        loanId = _open(P, TEN7, thetaBps);
        _warpBy(1 days);
        _ext(loanId);
        assertEq(read.loan(loanId).expiry, _now() + TEN7, "PREMISE: the extension landed");
        _assertDebtIsClaim(loanId, "after the extension");
    }

    /// @notice A repay melts the claim by exactly what it paid, and a closing one retires both to zero.
    function test_ThroughARepay() public {
        uint256 loanId = _extendedLoan(5000);
        uint256 c0 = read.claimOf(id, loanId);
        (,, uint256 owed0) = read.poolOf(id);
        _fund(borrower, P);
        vm.prank(borrower);
        ace.repay(loanId, 1_000e6);
        assertEq(read.claimOf(id, loanId), c0 - 1_000e6, "the claim melted by the whole payment");
        (,, uint256 owed1) = read.poolOf(id);
        assertEq(owed1, owed0 + 1_000e6, "and the lender is owed all of it");
        _assertDebtIsClaim(loanId, "after a partial repay");
        uint256 rest = read.debtOf(loanId);
        vm.prank(borrower);
        ace.repay(loanId, rest);
        assertTrue(ace.isClosed(loanId), "a full repay closes the loan");
        assertEq(read.claimOf(id, loanId), 0, "and retires the claim");
        _assertSolvent();
    }

    /// @notice A deleverage crank melts every unit of its net proceeds into the claim, and the debt falls with it, one for one.
    function test_ThroughADeleverage() public {
        uint256 loanId = _extendedLoan(8500);
        uint256 debt0 = read.debtOf(loanId);
        uint256 c0 = read.claimOf(id, loanId);
        rec.setBelowBand(FullMath.mulDivRoundingUp(read.triggerPrice(loanId), 1e18, 1e18 - 3000 * 1e14));
        (, uint256 stableOut) = ace.deleverage(loanId, 0, "");
        assertGt(stableOut, 0, "PREMISE: the crank sold");
        uint256 net = debt0 - read.debtOf(loanId);
        assertGt(net, 0, "PREMISE: the crank melted debt");
        assertEq(read.claimOf(id, loanId), c0 - net, "the claim fell by exactly the net melt");
        _assertDebtIsClaim(loanId, "after a deleverage");
        _assertSolvent();
    }

    /// @notice Settlement converts the claim alone: the pot is the claim's units at the funding floor, and revenue does not move.
    function test_ThroughASettlement() public {
        uint256 loanId = _extendedLoan(5000);
        uint256 c = read.claimOf(id, loanId);
        uint256 rev0 = read.protocolRevenue(id);
        _warpTo(read.loan(loanId).expiry);
        vm.recordLogs();
        vm.prank(keeper);
        ace.forceClose(loanId);
        assertTrue(ace.isClosed(loanId), "the loan settled");
        assertEq(read.invPotOf(id, loanId), FullMath.mulDivRoundingUp(c, S, par), "the pot covers the claim and nothing else");
        assertEq(read.protocolRevenue(id), rev0, "no protocol due exists to forfeit, and revenue does not move");
        assertEq(read.claimOf(id, loanId), 0, "the claim converted");
        bytes32 duesSettled = keccak256("DuesSettled(uint256,uint256,uint256)");
        Vm.Log[] memory logs = vm.getRecordedLogs();
        for (uint256 i; i < logs.length; i++) {
            assertTrue(logs[i].topics.length == 0 || logs[i].topics[0] != duesSettled, "a settlement logged DuesSettled");
        }
        _assertSolvent();
    }

    /// @notice A same-lender re-term retires the old debt at its claim and opens a successor whose debt is its claim.
    function test_ThroughARefinance() public {
        uint256 loanId = _extendedLoan(5000);
        uint256 debt = read.debtOf(loanId);
        uint256 np = debt + debt / 100;
        vm.prank(borrower);
        uint256 newId = ace.refinanceTo(MigrateArgs(loanId, id, np, TEN7, OpenBounds(0, 0, 0), 0, address(0)));
        assertTrue(ace.isClosed(loanId), "the old loan closed");
        assertEq(read.claimOf(id, loanId), 0, "with its claim retired");
        assertEq(read.debtOf(newId), np, "the successor owes its principal");
        assertEq(read.claimOf(id, newId), np, "and its claim is that principal");
        _assertSolvent();
    }

    /// @notice O10 across extensions, partial repays and time: the debt is the claim, it never rises, and O1 holds.
    /// @dev Every run lands an extension: its first step extends, one second into the loan.
    function testFuzz_DebtIsTheClaimAcrossExtensionsRepaysAndTime(uint256[8] memory seeds) public {
        uint256 loanId = _open(P, TEN7, 5000);
        uint256 landed;
        uint256 last = read.debtOf(loanId);
        for (uint256 i; i < seeds.length; i++) {
            uint256 s = seeds[i];
            uint256 kind = i == 0 ? 0 : s % 3;
            if (kind == 0) {
                landed += _tryFittedExtension(loanId);
            } else if (kind == 1) {
                uint256 debt = read.debtOf(loanId);
                if (debt > MIN_PRINCIPAL + 1) {
                    uint256 a = bound(s >> 8, 1, debt - MIN_PRINCIPAL);
                    _fund(borrower, a);
                    vm.prank(borrower);
                    ace.repay(loanId, a);
                }
            } else {
                _warpBy(bound(s >> 8, 1 hours, 3 days));
            }
            _assertDebtIsClaim(loanId, "in the run");
            assertLe(read.debtOf(loanId), last, "the debt rose");
            last = read.debtOf(loanId);
            _assertSolvent();
        }
        assertGt(landed, 0, "an extension landed in the run");
    }

    /// @dev One extension now while the loan is inside its term, a second past its open second; 1 when it ran the tenor from now.
    function _tryFittedExtension(uint256 loanId) internal returns (uint256) {
        Loan memory l = read.loan(loanId);
        if (_now() >= l.expiry) return 0;
        if (_now() == l.openTime) _warpBy(1);
        _ext(loanId);
        return read.loan(loanId).expiry == _now() + l.tenor ? 1 : 0;
    }

    /// @notice The dues surface is gone: no `fromDebt` door on the hub, and no `dueOf` on the lens.
    function test_TheDuesSurfaceIsGone() public {
        uint256 loanId = _open(P, TEN7, 5000);
        _fund(borrower, P);
        _assertGone(address(ace), abi.encodeWithSignature("extend(uint256,uint64,bool,uint256,bytes)", loanId, TEN7, true, 0, ""), "extend(fromDebt)");
        _assertGone(
            address(ace),
            abi.encodeWithSignature("tryExtend(uint256,uint64,bool,uint256,bytes,address)", loanId, TEN7, true, 0, "", borrower),
            "tryExtend(fromDebt)"
        );
        _assertGone(address(lens), abi.encodeWithSignature("dueOf(uint256)", loanId), "the lens's dueOf");
        _assertDebtIsClaim(loanId, "after the probes");
    }

    function _assertGone(address target, bytes memory call, string memory name) internal {
        vm.prank(borrower);
        (bool ok, bytes memory ret) = target.call(call);
        assertFalse(ok, string.concat(name, " still answers"));
        assertEq(ret.length, 0, string.concat(name, " reverted with data: the selector still dispatches"));
    }
}
