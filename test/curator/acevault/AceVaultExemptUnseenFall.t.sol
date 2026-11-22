// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.36;

import {Math} from "@openzeppelin/contracts/utils/math/Math.sol";
import {AceVault} from "../../../src/curator/AceVault.sol";
import {AceVaultFlows} from "../../../src/curator/libraries/AceVaultFlows.sol";
import {AceVaultRig} from "./AceVaultRig.sol";

/// @title AceVaultExemptUnseenFall
/// @notice `exemptDeadPots` promises a material fall over the pots it exempts still holds entry, the next sync waiting on the pile standing then.
/// @notice The promise holds whether or not a sync saw the fall before the exemption: the exemption weighs an unseen fall itself.
/// @notice The exemption only marks, never clears, so a hub sale no sync saw before it is still held by the sync that stamps it.
contract AceVaultExemptUnseenFall is AceVaultRig {
    uint48 internal constant MARKED = type(uint48).max;
    uint256 internal constant GIFT = 40_000e6; // a gain inside the band that a 20,000 USDC default burns only in part

    function _word(uint256 k) internal view returns (uint256) {
        bytes32[] memory s = new bytes32[](1);
        s[0] = bytes32(uint256(AceVaultFlows.ROOT) + k);
        return uint256(vault.extsload(s)[0]);
    }

    function _hold() internal view returns (uint48) {
        return uint48(_word(2) >> 200);
    }

    function _maturity() internal view returns (uint64) {
        return uint64(_word(2) >> 128);
    }

    function _assertHeld(address who) internal {
        assertEq(vault.maxDeposit(who), 0, "maxDeposit advertised an entry the hold shuts");
        usdc.mint(who, 1_000e6);
        vm.startPrank(who);
        usdc.approve(address(vault), 1_000e6);
        vm.expectRevert(AceVault.RecoveryVesting.selector);
        vault.deposit(1_000e6, who);
        vm.stopPrank();
    }

    /// @dev A gain vesting inside the band, then a material default settled at the hub with no sync after it; returns the mark and the fall.
    function _unseenFallUnderAPile() internal returns (uint256 mark, uint256 fell) {
        uint256 loanId = _borrowAs(borrower, 30_000e18, 20_000e6, MIN_TENOR);
        _warpAtLeastTo(_expiry(loanId));
        usdc.mint(address(vault), GIFT);
        vault.crank();
        assertLe(vault.unvested() * 10_000, vault.totalAssets() * vault.GATE_BPS(), "PREMISE: the gift vests inside the band");
        assertEq(_hold(), 0, "PREMISE: no hold before the default");
        mark = _word(1);
        vm.prank(keeper);
        ace.forceClose(loanId);
        fell = mark - vault.grossNav();
        assertGt(fell * 10_000, mark, "PREMISE: the settle's fall is material against the mark");
        assertLt(fell, vault.unvested(), "PREMISE: the fall burns the pile only in part");
        assertEq(_word(1), mark, "PREMISE: no sync has seen the fall");
    }

    /// @dev The guardian exempts the pots standing now, at the hub's settled count.
    function _exempt() internal {
        (, uint256 s) = ace.lenderUnresolved(address(vault), address(usdc));
        vm.prank(guardian);
        vault.exemptDeadPots(s);
    }

    /// @dev A stranger buys a settled pot at the hub; a hub sale moves no vault mark, so no sync sees it.
    function _buyPot(uint256 loanId) internal {
        usdc.mint(stranger, 10_000_000e6);
        vm.startPrank(stranger);
        usdc.approve(address(ace), 10_000_000e6);
        ace.buyInventory(loanId, 10_000_000e6, 0, stranger);
        vm.stopPrank();
    }

    /// @dev A material default a crank marks, its pot then bought at the hub an hour later with no sync after the sale.
    function _markedThenSoldUnseen() internal returns (uint256 mark) {
        uint256 loanId = _borrowAs(borrower, 30_000e18, 20_000e6, MIN_TENOR);
        _warpAtLeastTo(_expiry(loanId));
        vm.prank(keeper);
        ace.forceClose(loanId);
        vault.crank();
        assertEq(_hold(), MARKED, "PREMISE: the synced fall over the unsold pot marks the vault");
        _warpBy(1 hours);
        mark = _word(1);
        _buyPot(loanId);
        (uint256 u,) = ace.lenderUnresolved(address(vault), address(usdc));
        assertEq(u, 0, "PREMISE: the pot sold at the hub");
        assertEq(_word(1), mark, "PREMISE: no sync has seen the sale");
        assertEq(_hold(), MARKED, "PREMISE: the vault is still marked");
    }

    /// @notice REPRO (Run A DN-2): a hub sale no sync saw, then the exemption; the next sync still holds entry over the sale's pile.
    function test_Exempt_ASaleNoSyncSawBeforeTheExemptionStillHoldsEntry() public {
        _markedThenSoldUnseen();
        _exempt();
        vault.crank();
        assertGt(vault.unvested() * 10_000, vault.grossNav(), "PREMISE: the sale's pile is material");
        assertLe(vault.unvested() * 10_000, vault.totalAssets() * vault.GATE_BPS(), "PREMISE: the sale vests inside the band, so only the hold shuts entry");
        assertEq(_hold(), _maturity(), "the sync after the exemption stored no hold over the sale");
        assertEq(uint256(_hold()), _now() + VEST_W, "the hold is not the sale's whole window");
        _assertHeld(bob);
        _warpBy(VEST_W / 2);
        assertGt(vault.unvested() * 10_000, vault.grossNav(), "PREMISE: half the sale's pile is still material");
        _assertHeld(bob);
    }

    /// @notice A marked vault takes a further unseen fall before the exemption: it moves no mark or pile, and the next sync burns the fall and holds the rest.
    function test_Exempt_AFurtherUnseenFallUnderAStandingMarkIsHeldOverTheBurntPile() public {
        uint256 first = _borrowAs(borrower, 30_000e18, 20_000e6, MIN_TENOR);
        uint256 second = _borrowAs(borrower, 15_000e18, 10_000e6, MIN_TENOR);
        _warpAtLeastTo(Math.max(_expiry(first), _expiry(second)));
        usdc.mint(address(vault), GIFT);
        vault.crank();
        vm.prank(keeper);
        ace.forceClose(first);
        vault.crank();
        assertEq(_hold(), MARKED, "PREMISE: the first default marks the vault");
        uint256 mark = _word(1);
        vm.prank(keeper);
        ace.forceClose(second);
        assertGt((mark - vault.grossNav()) * 10_000, mark, "PREMISE: the second fall is material, and no sync has seen it");
        uint256 pile = vault.unvested();
        _exempt();
        assertEq(_hold(), MARKED, "the exemption moved a standing mark");
        assertEq(_word(1), mark, "the exemption synced the fall");
        assertEq(vault.unvested(), pile, "the exemption burnt the pile");
        vault.crank();
        assertLt(vault.unvested(), pile, "PREMISE: the sync after the exemption burnt the second fall");
        assertGt(vault.unvested() * 10_000, vault.grossNav(), "PREMISE: the pile both falls burnt is still material");
        assertEq(_hold(), _maturity(), "the sync after the exemption stored no hold over the burnt pile");
        assertGt(uint256(_hold()), _now(), "and no second to come");
        _assertHeld(bob);
    }

    /// @notice The exemption over a sale no sync saw leaves the standing mark, the mark and the pile as they were: it never clears.
    function test_Exempt_TheExemptionNeverClearsAStandingMark() public {
        uint256 mark = _markedThenSoldUnseen();
        uint256 pile = vault.unvested();
        _exempt();
        assertEq(_hold(), MARKED, "the exemption cleared a standing mark over a pile no sync had stamped");
        assertEq(_word(1), mark, "the exemption moved the mark");
        assertEq(vault.unvested(), pile, "the exemption moved the pile");
    }

    /// @notice REPRO (Run A DN-2): over an older material pile, the hold reaches the maturity the sale's stamp blends in, not the older pile's.
    function test_Exempt_OverAnOlderPileTheHoldReachesTheSalesMaturity() public {
        uint256 loanId = _borrowAs(borrower, 30_000e18, 20_000e6, MIN_TENOR);
        _warpAtLeastTo(_expiry(loanId));
        usdc.mint(address(vault), GIFT);
        vault.crank();
        uint64 older = _maturity();
        vm.prank(keeper);
        ace.forceClose(loanId);
        vault.crank();
        assertEq(_hold(), MARKED, "PREMISE: the synced fall over the unsold pot marks the vault");
        _warpBy(1 hours);
        _buyPot(loanId);
        assertGt(vault.unvested() * 10_000, vault.grossNav(), "PREMISE: the older pile, unstamped by the sale, is still material");
        _exempt();
        vault.crank();
        assertGt(_maturity(), older, "PREMISE: the sale's stamp blends the maturity later");
        assertEq(_hold(), _maturity(), "the hold stopped at the older pile's maturity, short of the sale's");
        _warpTo(uint256(older) + 1);
        assertGt(vault.unvested() * 10_000, vault.grossNav(), "PREMISE: the sale's tail is still material past the older maturity");
        assertLe(vault.unvested() * 10_000, vault.totalAssets() * vault.GATE_BPS(), "PREMISE: inside the band, so only the hold shuts entry");
        _assertHeld(bob);
    }

    /// @notice CONTROL: a dust fall no sync saw, under a material pile, then the exemption: it marks nothing, so the next sync stores no hold.
    function test_Exempt_Control_AnUnseenDustFallMarksNothing() public {
        uint256 loanId = _borrowAs(borrower, 30e18, MIN_PRINCIPAL, MIN_TENOR);
        _warpAtLeastTo(_expiry(loanId));
        usdc.mint(address(vault), GIFT);
        vault.crank();
        uint256 mark = _word(1);
        vm.prank(keeper);
        ace.forceClose(loanId);
        assertLe((mark - vault.grossNav()) * 10_000, mark, "PREMISE: the dust fall is under the floor");
        (uint256 u,) = ace.lenderUnresolved(address(vault), address(usdc));
        assertEq(u, 1, "PREMISE: its pot is unsold at the exemption");
        _exempt();
        assertEq(_hold(), 0, "the exemption marked a dust fall");
        vault.crank();
        assertGt(vault.unvested() * 10_000, vault.grossNav(), "PREMISE: the pile is material, so a mark would have held");
        assertEq(_hold(), 0, "the sync after the exemption stored a hold over a dust fall");
        assertGt(vault.maxDeposit(bob), 0, "and shut entry");
    }

    /// @notice CONTROL (Run A DN-2): a crank between the sale and the exemption, and the sale is held, as it always was.
    function test_Exempt_Control_ACrankBeforeTheExemptionHoldsTheSale() public {
        _markedThenSoldUnseen();
        vault.crank();
        uint48 held = _hold();
        assertEq(held, _maturity(), "CONTROL: the sync over the sale stored the pile's maturity");
        _exempt();
        assertEq(_hold(), held, "CONTROL: the exemption moved a stored second");
        vault.crank();
        assertEq(_hold(), held, "CONTROL: the next sync moved the stored second");
        _assertHeld(bob);
    }

    /// @notice REPRO: the guardian exempts the pot before any sync has seen its fall; the next sync still holds entry over the pile standing then.
    function test_Exempt_AFallNoSyncSawStillHoldsEntryOverThePileStanding() public {
        _unseenFallUnderAPile();
        _exempt();
        vault.crank();
        assertGt(vault.unvested() * 10_000, vault.grossNav(), "PREMISE: the pile left by the fall is material");
        assertEq(_hold(), _maturity(), "the sync after the exemption stored no hold over the pile standing then");
        assertGt(uint256(_hold()), _now(), "and no second to come");
        _assertHeld(bob);
    }

    /// @notice The exemption marks the unseen fall but syncs nothing: the mark and the pile stay as the last sync left them, for the next verb to see.
    function test_Exempt_TheExemptionMarksAnUnseenFallAndMovesNoMarkOrPile() public {
        (uint256 mark,) = _unseenFallUnderAPile();
        uint256 pile = vault.unvested();
        _exempt();
        assertEq(_hold(), MARKED, "the exemption did not mark the material fall over the pots it exempts");
        assertEq(_word(1), mark, "the exemption moved the mark: the fall is no longer unsynced for the next verb");
        assertEq(vault.unvested(), pile, "the exemption burnt the pile");
    }

    /// @notice CONTROL: a crank between the settle and the exemption, and the same sale is held, as it always was.
    function test_Exempt_Control_ACrankBeforeTheExemptionHolds() public {
        _unseenFallUnderAPile();
        vault.crank();
        assertEq(_hold(), MARKED, "CONTROL: the synced fall over the unsold pot marks the vault");
        _exempt();
        vault.crank();
        assertEq(_hold(), _maturity(), "CONTROL: the clear stored the pile's maturity");
        _assertHeld(bob);
    }

    /// @notice CONTROL: an exemption with no fall since the last sync marks nothing, so a quiet exemption leaves entry open.
    function test_Exempt_Control_AnExemptionWithNoFallMarksNothing() public {
        uint256 loanId = _borrowAs(borrower, 30_000e18, 20_000e6, MIN_TENOR);
        _warpAtLeastTo(_expiry(loanId));
        vm.prank(keeper);
        ace.forceClose(loanId);
        vault.crank();
        assertEq(_hold(), MARKED, "PREMISE: the fall marked the vault");
        _exempt();
        vault.crank();
        assertEq(_hold(), 0, "PREMISE: the clear over no pile stored nothing");
        _exempt();
        assertEq(_hold(), 0, "an exemption with no unseen fall marked the vault");
        assertGt(vault.maxDeposit(bob), 0, "and shut entry");
    }

    /// @dev A dead pot exempted and cleared, a small gain over the drawdown it left, a dust default no sync saw; returns what a sync-first order holds.
    function _dustUnderADrawdown() internal returns (uint48 viaSync) {
        uint256 dead = _borrowAs(borrower, 30_000e18, 20_000e6, MIN_TENOR);
        uint256 dust = _borrowAs(borrower, 30e18, MIN_PRINCIPAL, MIN_TENOR);
        _warpAtLeastTo(Math.max(_expiry(dead), _expiry(dust)));
        vm.prank(keeper);
        ace.forceClose(dead);
        vault.crank();
        assertEq(_hold(), MARKED, "PREMISE: the material default over its unsold pot marks the vault");
        _exempt();
        vault.crank();
        assertEq(_hold(), 0, "PREMISE: the clear over the exempted dead pot found no pile and stored no hold");
        usdc.mint(address(vault), 5_000e6);
        vault.crank();
        assertGt(vault.maxDeposit(bob), 0, "PREMISE: entry is open over the exempted pot and the small gain");
        _warpBy(1 hours);
        uint256 mark = _word(1);
        vm.prank(keeper);
        ace.forceClose(dust);
        assertLe((mark - vault.grossNav()) * 10_000, mark, "PREMISE: the dust fall alone is under the floor");
        assertGt(vlens.drawdown(address(vault)) * 10_000, mark, "PREMISE: the drawdown the dead pot left is material");
        assertEq(_word(1), mark, "PREMISE: no sync has seen the dust fall");
        uint256 snap = vm.snapshotState();
        vault.crank();
        _exempt();
        vault.crank();
        viaSync = _hold();
        vm.revertToState(snap);
    }

    /// @notice Under the drawdown an exempted dead pot left, a dust default no sync saw marks at the exemption, as a sync would: the loss carries the drawdown.
    function test_Exempt_AnUnseenDustFallUnderAStandingDrawdownMarksAsASyncWould() public {
        uint48 viaSync = _dustUnderADrawdown();
        assertGt(uint256(viaSync), _now(), "PREMISE: a sync before the exemption stores a second to come");
        _exempt();
        assertEq(_hold(), MARKED, "the exemption weighed the dust fall alone, not the drawdown a sync weighs with it");
        vault.crank();
        assertGt(vault.unvested() * 10_000, vault.grossNav(), "PREMISE: the gain's pile is material, so the clear stores its maturity");
        assertEq(_hold(), _maturity(), "the sync after the exemption stored no hold over the pile");
        assertEq(_hold(), viaSync, "the exemption-first order held other than a sync-first order");
        _assertHeld(bob);
    }
}
