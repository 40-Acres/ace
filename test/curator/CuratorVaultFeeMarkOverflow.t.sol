// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.36;

import {CuratorVaultBase} from "./CuratorVaultBase.sol";
import {CuratorVault} from "../../src/curator/CuratorVault.sol";
import {Math} from "@openzeppelin/contracts/utils/math/Math.sol";

/// @title CuratorVaultFeeMarkOverflow
/// @notice Repeated near-total exits under the fee mark, with a small holder staying, must never brick the exit.
/// @notice A per-share mark raised at each such exit by `b' = b + (b - r) q / (s - q)` grew about `s / (s - q)` times over.
/// @notice An entry that left that mark where it stood let the factor compound across exits until the arithmetic overflowed.
/// @notice The high-water is in assets now: an entry adds its cash and a burn takes its pay, so the gap `H - NAV` moves only by real loss.
/// @dev Under the compounding per-share mark each overflow row panicked an exit, and every later exit, request and claim, at the cycle it names.
/// @dev The first cycle's exit is a claim at the trough under the mark, after a loss; each later cycle is a fresh deposit asked out whole.
contract CuratorVaultFeeMarkOverflowTest is CuratorVaultBase {
    uint16 internal constant FEE = 1000;
    uint256 internal constant LOSS = 100e6; // the loss that puts the price under the mark
    uint256 internal constant DIP_LOSS = 20e6; // a dip cycle's own loss, half of which comes back after the trough fill: each half a whole lot
    uint256 internal constant CYCLES = 24;
    address internal stayer = address(0x57A7);
    address internal lp = address(0x1F);
    address internal lp2 = address(0x2F);
    uint256 internal exit; // what each cycle's LP brings and asks back out

    /// @dev `who` claims `shares` of its request, the cycle named if the claim reverts; returns the cash paid.
    function _claimOrFail(CuratorVault v, address who, uint256 shares, uint256 cycle) internal returns (uint256 paid) {
        vm.prank(who);
        try v.claimExit(shares, who, 0) returns (uint256 got) {
            paid = got;
        } catch (bytes memory err) {
            emit log_named_uint("the cycle whose claim reverted", cycle);
            emit log_named_uint("the mark it reverted at", v.feeHighWater());
            assertTrue(false, string.concat("a claim reverted in cycle ", vm.toString(cycle), ": ", vm.toString(err)));
        }
    }

    function _request(CuratorVault v, address who, uint256 shares) internal {
        vm.prank(who);
        v.requestExit(shares);
    }

    /// @dev The stayer's shares in, the mark stamped at the entry price, then a loss under it and the first exit claimed at the trough.
    function _firstCycle(uint256 stayerShares) internal returns (CuratorVault v) {
        v = _newVault(FEE);
        uint256 cost = v.previewMint(stayerShares);
        usdc.mint(stayer, cost);
        vm.startPrank(stayer);
        usdc.approve(address(v), cost);
        v.mint(stayerShares, stayer);
        vm.stopPrank();
        uint256 shares = _lpDeposit(v, lp, exit);
        uint256 doomed = _open(LOSS);
        _crank(v, doomed, T2, 0);
        _warpBy(VEST_W); // the open's own gain vests now, so its fee is paid here and not inside a cycle
        v.crank();
        v.collectFee(); // the LP's entry stamped the mark; this pays the curator the open's fee, a stake of cents
        assertGt(v.feeHighWater(), 0, "PREMISE: a mark stands");
        _request(v, lp, shares);
        _finalize(doomed);
        _waivePots(v); // the loss stays standing under the mark, and each later cycle may still enter
        _crankAll(v);
        _claimOrFail(v, lp, shares, 1); // the claim at the trough, under the mark
        assertEq(v.balanceOf(address(v)), 0, "PREMISE: the LP left whole, and only the stayer holds shares");
    }

    /// @dev One later cycle: the LP deposits and asks it all straight back; its claim is under the mark.
    function _cycle(CuratorVault v, uint256 cycle) internal returns (uint256 paid) {
        uint256 shares = _lpDeposit(v, lp, exit);
        _request(v, lp, shares);
        paid = _claimOrFail(v, lp, shares, cycle);
    }

    /// @dev Run the cycles, each asserted live and paid its deposit back, the mark emitted as it climbs; then the fee must be alive.
    function _cycles(uint256 stayerShares, uint256 exitAssets, uint256 cycles) internal {
        exit = exitAssets;
        CuratorVault v = _firstCycle(stayerShares);
        emit log_named_uint("the mark after cycle 1", v.feeHighWater());
        for (uint256 i = 2; i <= cycles; i++) {
            uint256 paid = _cycle(v, i);
            emit log_named_uint("the mark after the next cycle", v.feeHighWater());
            assertApproxEqRel(paid, exit, 1e15, "an LP who entered and left at one price was not paid its deposit back");
        }
        _assertTheFeeIsAlive(v);
    }

    /// @dev A fresh cohort comes in and the book gains a tenth of it: the curator must be paid on the gain past the loss's gap.
    /// @dev The gap is about `LOSS` in assets, so the fee on `gain - LOSS` is the floor, and the fee on the whole gain the ceiling.
    function _assertTheFeeIsAlive(CuratorVault v) internal {
        _lpDeposit(v, lp, exit);
        uint256 gain = exit / 10;
        _gift(v, gain);
        v.crank();
        _warpBy(VEST_W);
        uint256 held = v.balanceOf(curator);
        v.collectFee();
        uint256 minted = v.convertToAssets(v.balanceOf(curator) - held);
        emit log_named_uint("the fee minted on a gain of a tenth of the book", minted);
        assertGe(minted * 2, Math.mulDiv(gain - LOSS, FEE, 10_000), "the fee is dead: a real gain past the gap paid the curator nothing like its fee");
        assertLe(minted, Math.mulDiv(gain, FEE, 10_000) + 1, "or it paid the curator past its fee on the whole gain");
    }

    /// @notice REALISTIC: a 1 USDC holder stays while a 10,000 USDC LP comes in and asks out, cycle after cycle.
    /// @dev A per-share mark an entry left standing multiplied by about 10^4 a cycle and overflowed at cycle 17.
    function test_FeeMark_RepeatedExitsUnderTheMarkNeverBrickTheExit() public {
        _cycles(1e12, 10_000e6, CYCLES); // 1 USDC of shares at par
    }

    /// @notice THE SAME AT 2 USDC, over the one-unit floor, so a fix that only clears a dust remainder cannot pass the gate.
    function test_FeeMark_RepeatedExitsUnderTheMarkNeverBrickTheExitWithATwoUsdcStayer() public {
        _cycles(2e12, 10_000e6, CYCLES);
    }

    /// @notice THE DUST CASE: a holder of three share-wei, which costs a wei; that per-share mark overflowed at cycle 4.
    function test_FeeMark_RepeatedExitsUnderTheMarkNeverBrickTheExitWithADustStayer() public {
        _cycles(3, 10_000e6, CYCLES);
    }

    /// @notice A MILLION-USDC BOOK WITH A FEW SHARE-WEI STAYING: the larger the exit against the stayer, the fewer the cycles to overflow.
    function test_FeeMark_RepeatedExitsUnderTheMarkNeverBrickTheExitAtAMillionUsdc() public {
        _cycles(3, 1_000_000e6, CYCLES);
    }

    /// @notice THE FEE DIED LONG BEFORE THE BRICK under that per-share mark: two dust cycles left it far past any price.
    function test_FeeMark_TwoExitsUnderTheMarkLeaveTheFeeAlive() public {
        _cycles(3, 10_000e6, 2);
    }

    // ---- the same cycles driven through a dip ----

    /// @dev One cycle through a dip: a small loan defaults under the LP's standing request, which it claims at the trough.
    /// @dev A second LP asks after that claim, half the loss comes back, and its claim is priced net of what still vests.
    function _dipCycle(CuratorVault v, uint256 cycle) internal {
        uint256 shares = _lpDeposit(v, lp, exit);
        uint256 shares2 = _lpDeposit(v, lp2, exit / 10);
        uint256 doomed = _open(DIP_LOSS);
        _crank(v, doomed, T2, 0);
        _request(v, lp, shares);
        _finalize(doomed);
        _waivePots(v); // each cycle's loss stays standing, and the next cycle may still enter
        _crankAll(v);
        _claimOrFail(v, lp, shares, cycle); // the LP's claim at the trough
        _request(v, lp2, shares2);
        _gift(v, DIP_LOSS / 2);
        v.crank(); // half the loss comes back, vesting
        _claimOrFail(v, lp2, shares2, cycle); // the second LP's claim, net of the pile
        assertEq(v.balanceOf(address(v)), 0, "PREMISE: both LPs left whole");
        _warpBy(VEST_W); // the returned half vests to the stayer, else the next cycle's entry meets the pile gate
    }

    /// @notice CYCLES THROUGH A DIP never brick the exit either: a trough claim, a later cohort and its claim under a vesting pile.
    /// @dev A 1 USDC holder stays; each cycle's own loss is real, so the gap grows by about half of `DIP_LOSS` a cycle, additively.
    /// @dev The per-share mark an entry left standing overflowed here at cycle 17, as in the plain cycles.
    function test_FeeMark_RepeatedDipCyclesUnderTheMarkNeverBrickTheExit() public {
        exit = 10_000e6;
        CuratorVault v = _firstCycle(1e12);
        for (uint256 i = 2; i <= CYCLES; i++) {
            _dipCycle(v, i);
            emit log_named_uint("the mark after the next dip cycle", v.feeHighWater());
        }
        _assertTheFeeIsAlive(v);
    }

    // ---- the review's F1, recorded ----

    /// @notice MEASURE, F1: a FREE dust holder carries a real loss's gap into the vault's next life; the fee waits for that life to earn it.
    /// @notice One share-wei held by an account, not donated, keeps the supply off zero at the last out, so the gap rides on it.
    /// @dev Recorded, not fixed: curator-adverse and bounded by the fee on that gap; no funds at risk and no brick.
    /// @dev Under the per-share mark the dust holder's own entry price killed the fee outright, so nothing was paid even past the gap.
    function test_FeeMark_AFreeDustHolderCarriesTheGapIntoANewLife() public {
        exit = 10_000e6;
        CuratorVault v = _firstCycle(1);
        uint256 gap = Math.saturatingSub(v.feeHighWater(), v.totalAssets());
        emit log_named_uint("the gap the dust holder carries, in assets", gap);
        assertGt(gap, LOSS / 2, "PREMISE: the old life's loss is the gap");
        _lpDeposit(v, lp, 50_000e6); // the new life
        uint256 held = v.balanceOf(curator);
        _gift(v, gap / 2);
        v.crank();
        _warpBy(VEST_W);
        v.collectFee();
        assertEq(v.balanceOf(curator), held, "a gain under the carried gap paid the curator a fee");
        _gift(v, gap);
        v.crank();
        _warpBy(VEST_W);
        v.collectFee();
        uint256 minted = v.convertToAssets(v.balanceOf(curator) - held);
        emit log_named_uint("the fee on the half-gap earned past it", minted);
        assertApproxEqRel(minted, Math.mulDiv(gap / 2, FEE, 10_000), 0.1e18, "once the new life earned the gap, the fee did not resume on the rest");
    }
}
