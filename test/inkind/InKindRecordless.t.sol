// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.36;

import {AceFixtures} from "../utils/AceFixtures.sol";
import {NoRecord} from "../../src/ace/hub/Settlement.sol";
import {MarketParams, OpenBounds} from "../../src/ace/hub/Types.sol";
import {IInKindVault} from "./InKindSurface.sol";
import {InKindRig} from "./InKindRig.sol";

/// @title InKindRecordless
/// @notice Recordless loans settle only at tenor and forfeit the whole coverage line; the vault's collect ends the loan and takes the pot in kind.
/// @dev The collect syncs first and sweeps the hub's credit after, and tolerates a repaid or already-collected id in a batch.
contract InKindRecordlessTest is InKindRig {
    function setUp() public override {
        super.setUp();
        _lp(alice, LP_CASH);
    }

    /// @notice A recordless loan has no early seizure: the hub's `finalize` refuses it.
    function testRevert_finalize_refusesARecordlessLoan() public {
        uint256 loanId = _open(address(tokA));
        _warpBy(MIN_TENOR - 1);
        vm.expectRevert(NoRecord.selector);
        ace.finalize(loanId);
    }

    /// @notice Before expiry the vault's collect cannot end the loan either: the base's end falls back to `finalize`, which refuses.
    function testRevert_collectForfeited_beforeExpiryRefuses() public {
        uint256 loanId = _open(address(tokA));
        _warpTo(_expiry(loanId) - 1);
        vm.prank(keeper);
        vm.expectRevert(NoRecord.selector);
        vault.collectForfeited(_ids(loanId));
    }

    /// @notice At the expiry second the collect ends the loan and brings the WHOLE coverage line home, more than the claim's need.
    function test_collect_takesTheWholeCoverageLineAtTheExpirySecond() public {
        uint256 loanId = _open(address(tokA));
        _toExpiry(loanId);
        uint256 debt = read.loan(loanId).debt;
        uint256 need = (debt << 96) / _mp(loanId).price;
        uint256 pot = _expectedPot(loanId);
        assertGt(pot, need, "premise: a recordless default forfeits past the claim's need");
        uint256 bal0 = tokA.balanceOf(address(vault));
        uint256 out = _collect(loanId);
        assertEq(out, pot, "the collect reports the coverage line");
        assertEq(tokA.balanceOf(address(vault)) - bal0, pot, "and exactly that many units landed on the vault");
        assertTrue(ace.isClosed(loanId), "the loan ended at the expiry second");
        assertEq(read.unitsOwedOf(loanId, borrower), UNITS - pot, "the borrower is credited every unit above the line");
    }

    /// @notice The borrower takes the units above the line from the hub; the vault takes none of them.
    function test_borrower_claimsTheUnitsAboveTheLine() public {
        uint256 loanId = _open(address(tokA));
        uint256 pot = _defaultAndCollect(loanId);
        uint256 bal0 = tokA.balanceOf(borrower);
        vm.prank(borrower);
        (uint256 units,) = ace.claimOwed(loanId, borrower);
        assertEq(units, UNITS - pot, "the residual above the coverage line");
        assertEq(tokA.balanceOf(borrower) - bal0, UNITS - pot, "delivered to the borrower");
    }

    /// @notice The collect names the loan, the token and the units it brought home.
    function test_collect_emitsForfeited() public {
        uint256 loanId = _open(address(tokA));
        _toExpiry(loanId);
        uint256 pot = _expectedPot(loanId);
        vm.expectEmit(true, true, false, true, address(vault));
        emit IInKindVault.Forfeited(loanId, address(tokA), pot);
        _collect(loanId);
    }

    /// @notice The collect closes with the vault's own sweep: it lands exactly what a stranger's settle pushes the vault.
    function test_collect_runsInsideTheDoor() public {
        uint256 loanId = _open(address(tokA));
        _toExpiry(loanId);
        uint256 snap = vm.snapshotState();
        uint256 idleBefore = vault.idle();
        vm.prank(stranger);
        ace.forceClose(loanId);
        uint256 pushed = vault.idle() - idleBefore;
        assertGt(pushed, 0, "premise: the settle pushes the lender's credit to the vault");
        vm.revertToState(snap);
        uint256 idle0 = vault.idle();
        _collect(loanId);
        assertEq(ace.lenderOwed(address(vault), address(usdc)), 0, "nothing left owed at the hub");
        assertEq(vault.idle() - idle0, pushed, "the vault's own collect lands exactly the stranger's push");
    }

    /// @notice One batch survives a repaid id, an already-collected id and a third-party-settled id, and collects every live pot.
    function test_collect_batchToleratesClosedAndEmptyIds() public {
        uint256 repaid = _open(address(tokA));
        uint256 early = _open(address(tokA));
        uint256 fresh = _open(address(tokB));
        uint256 forced = _open(address(tokB));
        _repayAll(repaid);
        _toExpiry(early);
        _collect(early);
        uint256 potFresh = _expectedPot(fresh);
        uint256 potForced = _expectedPot(forced);
        vm.prank(stranger);
        ace.forceClose(forced);
        uint256[] memory ids = new uint256[](4);
        (ids[0], ids[1], ids[2], ids[3]) = (repaid, early, fresh, forced);
        vm.prank(keeper);
        uint256[] memory out = vault.collectForfeited(ids);
        assertEq(out[0], 0, "a repaid loan left no pot, and the batch went on");
        assertEq(out[1], 0, "an already-collected pot is empty, and the batch went on");
        assertEq(out[2], potFresh, "the live default came home");
        assertEq(out[3], potForced, "the third-party-settled pot came home too");
    }

    /// @notice A loan in a market this vault does not lend in is refused before the vault ends it.
    function testRevert_collect_aLoanOfAnotherLendersMarket() public {
        MarketParams memory p = AceFixtures.marketParams(address(usdc), address(tokA));
        (p.record, p.lender, p.inventoryAsk, p.settleBountyBps, p.fillFeeBps) = (address(0), address(this), false, 0, 0);
        bytes32 id = ace.createMarket(p);
        usdc.mint(address(this), 10_000e6);
        usdc.approve(address(ace), 10_000e6);
        ace.deposit(id, 10_000e6);
        tokA.mint(address(this), UNITS);
        tokA.approve(address(pm), UNITS);
        uint256 loanId = ace.open(id, UNITS, PRINCIPAL, p.minTenor, address(this), OpenBounds(0, 0, 0));
        _toExpiry(loanId);
        vm.prank(keeper);
        vm.expectRevert(IInKindVault.NotOurLoan.selector);
        vault.collectForfeited(_ids(loanId));
    }

    /// @notice Anyone may collect, since it only ever delivers to the vault.
    function test_collect_isPermissionless() public {
        uint256 loanId = _open(address(tokA));
        _toExpiry(loanId);
        uint256 pot = _expectedPot(loanId);
        vm.prank(stranger);
        uint256[] memory out = vault.collectForfeited(_ids(loanId));
        assertEq(out[0], pot, "a stranger's collect brings the pot to the vault");
        assertEq(tokA.balanceOf(stranger), 0, "and none of it to the stranger");
    }
}
