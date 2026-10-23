// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.36;

import {FullMath} from "@uniswap/v4-core/src/libraries/FullMath.sol";
import {CuratorVaultBase} from "./CuratorVaultBase.sol";
import {CuratorVault} from "../../src/curator/CuratorVault.sol";
import {PriceGrid} from "../../src/curator/PriceGrid.sol";
import {Storage} from "../../src/ace/hub/Types.sol";
import {PriceFrame} from "../utils/PriceFrame.sol";
import {PocDeployConfig} from "../../src/config/Defaults.sol";
import {AceFixtures} from "../utils/AceFixtures.sol";

/// @title CuratorVaultPartialRecovery
/// @notice A PARTIAL recovery: the pot the settlement left cannot cover what the class was owed.
/// @notice The vault's half of it -- the NAV legs, the write-off, the fee path, and a later top-up.
/// @notice `CuratorVaultFee`'s recovery row is the FULL-cover twin; the contrast row here is the control.
/// @dev WHY A PRICE CRASH CANNOT STAGE THIS, which is why the rig was owed rather than written.
/// @dev `Settlement._convertClaim` converts at the tick's OWN pre-committed price, never at a market price.
/// @dev So a crashed market price changes not one number on this path, and the pot still covers in full.
/// @dev The pot is short only when the ESCROW holds fewer units than the claims need, in units.
/// @dev NO IN-PROTOCOL ROUTE REACHES THAT: `AceCoverageGuarantee.t.sol` proves an admitted loan is covered.
/// @dev The margin is `1 - 1/k` at every point, and `MAX_SETTLE_BOUNTY_BPS` is derived to sit inside it.
/// @dev So the short pot is DEFENSIVE code, staged the way `AceSettlement.t.sol` stages its own twin.
/// @dev That staging writes ONE word, `Loan.collateralUnits`, and the escrow keeps its real tokens.
contract CuratorVaultPartialRecoveryTest is CuratorVaultBase {
    event Finalized(uint256 indexed id, uint256 collateralUnits, uint256 badDebt, address indexed executor);

    uint256 internal TICK; // the market's own price, the row's gridded buffered minimum; assigned in `_rig`
    uint256 internal constant UNIT_SCALE = 1 << 96; // every market's scale under the atom frame
    uint256 internal constant SEED = 1_000e6; // the LP's stake, struck before anything goes wrong
    uint256 internal constant DOOMED = 100e6; // the loan taken to settlement; one market funds all of it
    uint256 internal NEED; // DOOMED * UNIT_SCALE / TICK: units a full cover consumes, off the market's own price
    uint256 internal SLIVER; // the keeper's in-kind settle bounty: zero, as every vault market pays none
    uint256 internal POT; // half of NEED, which is what the staged short settlement leaves
    uint256 internal RECOVERED; // POT priced back at TICK: what that pot sells for
    uint256 internal SHORTFALL; // DOOMED - RECOVERED, borne by this funding class alone
    uint256 internal constant BUDGET = 500e6; // a buyer's budget, deliberately past the whole pot
    uint256 internal constant TOPUP = 400e6; // the later LP entry, struck at the impaired share price

    // ---- fixture ----

    /// @dev Every closed form, off THE MARKET'S OWN PRICE, the price the claim was actually funded at.
    function _derive(uint256 px) internal {
        TICK = px;
        NEED = FullMath.mulDivRoundingUp(DOOMED, UNIT_SCALE, px); // UP: a full cover may never come up an atom short
        SLIVER = (DOOMED * ace.idToMarketParams(mid).settleBountyBps * UNIT_SCALE) / (10000 * px);
        POT = NEED / 2;
        RECOVERED = (POT * px) / UNIT_SCALE;
        SHORTFALL = DOOMED - RECOVERED;
    }

    /// @dev One vault, one market, one doomed loan, and the pre-loss mark already stamped.
    /// @dev The ask floor is pinned TO book after the door priced its market, so the pot prices at the claim's own price and the legs stay exact.
    /// @dev The wait is load-bearing: the origination fee is a deferred rise, and the mark must see it.
    function _rig(uint16 bps) internal returns (CuratorVault v, uint256 loanId) {
        v = _newVault(bps);
        _derive(ace.idToMarketParams(mid).price);
        _lpDeposit(v, alice, SEED);
        loanId = _open(DOOMED);
        record.setMinPrice(TICK);
        _crankAllTicks(v, loanId, 0);
        _warpBy(VEST_W);
        v.collectFee();
    }

    /// @dev The staging, one word: the loan record's third field is `collateralUnits`.
    /// @dev `loans` is member 1 of `LoanBook`, so its mapping sits at the book root plus one.
    function _stageShortEscrow(uint256 loanId, uint256 units) internal {
        uint256 loanSlot = uint256(keccak256(abi.encode(loanId, uint256(Storage.BOOK) + 1)));
        vm.store(address(ace), bytes32(loanSlot + 2), bytes32(units));
    }

    /// @dev Settle the loan with an escrow that cannot cover its claim, and check the reported write-off.
    function _finalizeShort(uint256 loanId) internal {
        _stageShortEscrow(loanId, POT + SLIVER);
        record.setBelow(true);
        vm.expectEmit(true, false, false, true, address(ace));
        emit Finalized(loanId, POT, SHORTFALL, keeper);
        vm.prank(keeper);
        ace.finalize(loanId);
        record.setBelow(false);
    }

    // ============ the premises the arithmetic stands on ============

    /// @notice Every derived constant above, checked against the market the rig actually creates.
    /// @notice A drifted decimal frame or bounty would otherwise make each leg below assert the wrong number.
    function test_Premise_TheRigsClosedFormsMatchTheMarket() public {
        (, uint256 loanId) = _rig(2000);
        /// @dev The door's price is the row's buffered windowed minimum gridded down: the rig's 2x-par minimum at a 50% buffer, so just under par.
        uint256 par = AceFixtures.px(1e18, address(usdc), address(collateral));
        uint256 minimum = AceFixtures.px(2e18, address(usdc), address(collateral));
        assertEq(TICK, PriceGrid.down((minimum * (10_000 - RIG_BUFFER_BPS)) / 10_000), "the market bids at the gridded buffered minimum");
        assertLe(TICK, par, "which sits at or under par");
        assertApproxEqRel(TICK, par, 6e15, "within one grid step of it");
        assertGt(par * 2, TICK, "guard: and nowhere near a doubling, which is what the closed forms assume");
        assertEq(lens.marketState(mid).unitScale, UNIT_SCALE, "every market carries the atom frame's scale");
        assertEq(ace.idToMarketParams(mid).settleBountyBps, 0, "a vault market pays no keeper bounty");
        assertEq(ace.idToMarketParams(mid).fillFeeBps, 0, "and no fill fee, so the ask is the market price flat");
        assertEq(read.claimOf(mid, loanId), DOOMED, "the market funded the whole loan");
        assertEq((NEED * TICK) / UNIT_SCALE, DOOMED, "NEED prices back at TICK to the whole claim");
        assertEq(SLIVER, 0, "so the keeper takes no sliver of the escrow");
        assertApproxEqAbs(RECOVERED, DOOMED / 2, 1, "the half-pot recovers half the claim, which is this rig's whole shape");
        assertApproxEqAbs(SHORTFALL, DOOMED / 2, 1, "and the other half is the write-off the suite measures");
    }

    // ============ the pot, which is where a partial recovery becomes possible at all ============

    /// @notice THE SUBJECT: after a short settlement the pot is worth strictly less than the class was owed.
    /// @notice With an intact escrow it is worth exactly the claim, which is why every ordinary recovery is full.
    function test_PartialRecovery_ThePotCannotCoverWhatTheClassIsOwed() public {
        (, uint256 loanId) = _rig(2000);
        _finalizeShort(loanId);

        uint256 invPot = lens.invPotOf(mid, loanId);
        assertEq(invPot, POT, "the escrow delivered only what it held, with no keeper sliver taken");
        assertEq(lens.inventoryMark(mid, loanId), RECOVERED, "so the pot marks at half the claim");
        assertLt(lens.inventoryMark(mid, loanId), DOOMED, "which is the whole point: it cannot cover");
        assertEq(read.claimOf(mid, loanId), 0, "and the claim itself is settled by title transfer");
    }

    /// @notice THE CONTROL, and the reason the rig needs staging at all: an intact escrow recovers in FULL.
    /// @notice Same vault, same loan, same buyer -- only the escrow differs, and the pot covers the claim exactly.
    function test_FullRecovery_ThePotCoversTheWholeClaim() public {
        (CuratorVault v, uint256 loanId) = _rig(2000);
        _finalize(loanId);

        uint256 invPot = lens.invPotOf(mid, loanId);
        assertEq(invPot, NEED, "an intact escrow delivers every unit the claim asks for");
        assertEq(lens.inventoryMark(mid, loanId), DOOMED, "so the pot marks at the whole claim");

        uint256 nav = v.grossNav();
        uint256 sale = FullMath.mulDivRoundingUp(invPot, TICK, UNIT_SCALE); // a whole-pot buy ceils its charge, toward the lender
        assertGe(sale, DOOMED, "PREMISE: the ceiled whole-pot charge is never under the claim");
        assertEq(_buyPot(keeper, loanId, BUDGET), sale, "and the sale returns the whole claim, at most an atom over");
        assertEq(v.grossNav() - nav, sale, "which is what makes the vault whole again");
    }

    // ============ NAV: the write-off, then what the sale brings back ============

    /// @notice NAV falls by the WHOLE claim at settlement, and the sale returns only the pot's worth.
    /// @notice The gap between the two is the shortfall, and it never comes back from anywhere.
    /// @dev The escrowed fee is EARNED IN FULL at settlement, so the drop is the claim net of that credit.
    function test_PartialRecovery_NavDropsByTheClaimAndReturnsOnlyTheProceeds() public {
        (CuratorVault v, uint256 loanId) = _rig(2000);
        uint256 nav0 = v.grossNav();
        uint256 escrow = read.feeEscrowOf(loanId);
        assertGt(escrow, 0, "PREMISE: there is a withheld fee for settlement to earn");

        _finalizeShort(loanId);
        uint256 nav1 = v.grossNav();
        assertEq(nav1, nav0 + escrow - DOOMED, "the write-off is the whole claim, less the fee it earned");

        uint256 sale = FullMath.mulDivRoundingUp(POT, TICK, UNIT_SCALE); // the whole short pot, its charge ceiled toward the lender
        assertApproxEqAbs(sale, RECOVERED, 1, "PREMISE: the ceiled charge is the pot's floored worth, at most an atom over");
        assertEq(_buyPot(keeper, loanId, BUDGET), sale, "the buyer pays what the short pot is worth");
        assertEq(v.grossNav(), nav1 + sale, "and NAV comes back by exactly that, never by the claim");
        assertEq(nav0 + escrow - v.grossNav(), DOOMED - sale, "so the vault is permanently out the claim less the proceeds");
    }

    /// @notice The recovery reaches the LPs as cash, not as a paper mark: the sale raises what the hub owes the vault, and the crank brings it home.
    /// @dev The vault reads no price anywhere, so an unsold pot is worth zero to it until someone buys.
    /// @dev The buyer pays the hub in the asset; the proceeds join the vault's owed pool at the sale, NAV up, and reach its balance at the crank.
    function test_PartialRecovery_ReachesTheVaultAsIdleCashOnTheNextCrank() public {
        (CuratorVault v, uint256 loanId) = _rig(2000);
        _finalizeShort(loanId);
        _crankAll(v);
        uint256 idle0 = v.idle();
        uint256 owed0 = ace.lenderOwed(address(v), address(usdc));
        uint256 gross0 = v.grossNav();

        _buyPot(keeper, loanId, BUDGET);
        uint256 owed1 = ace.lenderOwed(address(v), address(usdc));
        assertEq(v.idle(), idle0, "the sale moves no cash into the vault's balance");
        assertApproxEqAbs(owed1 - owed0, RECOVERED, 1, "it raises what the hub owes the vault by the proceeds, to the wei");
        assertEq(v.grossNav() - gross0, owed1 - owed0, "and NAV with it, at the sale");

        _crankAll(v);
        assertEq(v.idle() - idle0, owed1, "the crank brings every owed wei home as cash");
        assertEq(ace.lenderOwed(address(v), address(usdc)), 0, "and leaves nothing owed at the hub");
        assertEq(v.grossNav(), gross0 + owed1 - owed0, "the crank values nothing: it moves cash");
        assertEq(v.grossNav(), _hubTruthNav(v), "and the vault's own NAV still agrees with hub truth");
    }

    /// @notice UNLENT CASH bears NOTHING: the shortfall is the funding claim's own write-down.
    /// @dev The vault holds both the drawn position and the spare cash, so this is the one place the loss
    /// @dev model is visible from inside a vault: the spare cash is the vault's own balance, which nothing rests away.
    function test_PartialRecovery_TheWriteDownReachesNoUnlentCashTheVaultHolds() public {
        (CuratorVault v, uint256 loanId) = _rig(2000);
        uint256 spare = v.idle();
        assertGt(spare, SEED - DOOMED - 1, "PREMISE: the cash the draw left behind is the vault's own balance");
        assertEq(ace.restingOf(mid), 0, "PREMISE: and none of it rests at the hub");

        _finalizeShort(loanId);
        assertGe(v.idle(), spare, "the short settlement takes none of the uninvolved cash; its terminal push only adds");
        _buyPot(keeper, loanId, BUDGET);
        assertGe(v.idle(), spare, "nor does the sale");
        _crankAll(v);
        assertGe(v.idle(), spare, "and the crank only adds the proceeds to it");
    }

    // ============ the fee path ============

    /// @notice A PARTIAL recovery leaves the vault under its mark, so the curator is paid nothing for it.
    /// @notice `CuratorVaultFee`'s `test_Fee_ARecoveryUnderTheOldMarkPaysTheCuratorNothing` is the full-cover twin.
    /// @dev The premise is asserted rather than assumed: a recovery big enough to clear the mark would pay.
    function test_PartialRecovery_PaysTheCuratorNothingAndNeverLowersTheMark() public {
        (CuratorVault v, uint256 loanId) = _rig(2000);
        uint256 mark = v.feeHighWater();
        assertGt(mark, 0, "the pre-loss mark stands");
        uint256 held = v.balanceOf(curator);

        _finalizeShort(loanId);
        _crankAll(v);
        assertEq(v.feeHighWater(), mark, "a write-off leaves the mark exactly where it was");

        _buyPot(keeper, loanId, BUDGET);
        _crankAndRecognize(v);
        assertLt(v.totalAssets(), mark, "PREMISE: half the claim back is not enough to clear the mark");
        v.collectFee();
        assertEq(v.balanceOf(curator), held, "so a partial recovery mints the curator nothing at all");
        assertEq(v.feeHighWater(), mark, "and the mark never ratchets down to meet the impaired price");
    }

    /// @notice A zero-fee vault is inert across the whole sequence, mark included.
    function test_PartialRecovery_ZeroBpsVaultStaysInert() public {
        (CuratorVault v, uint256 loanId) = _rig(0);
        uint256 supply = v.totalSupply();

        _finalizeShort(loanId);
        _buyPot(keeper, loanId, BUDGET);
        _crankAndRecognize(v);
        v.collectFee();

        assertEq(v.totalSupply(), supply, "nothing was minted through the loss or the recovery");
        assertEq(v.balanceOf(curator), 0, "the curator holds nothing");
        assertEq(v.feeHighWater(), 0, "and no mark was ever stamped");
    }

    // ============ the later top-up ============

    /// @notice A newcomer entering AFTER a partial recovery buys at the impaired price and eats none of the loss.
    /// @notice And the stayer is not lifted by the newcomer's money: her share count and her value both hold.
    /// @dev The entry is pro-rata against an already-written-down NAV, which is what makes both halves true.
    function test_PartialRecovery_ALaterTopUpEntersAtTheImpairedPriceAndIsWhole() public {
        (CuratorVault v, uint256 loanId) = _rig(2000);
        _finalizeShort(loanId);
        _buyPot(keeper, loanId, BUDGET);
        _crankAndRecognize(v);

        uint256 nav = v.grossNav();
        uint256 aliceShares = v.balanceOf(alice);
        uint256 aliceValue = v.convertToAssets(aliceShares);

        uint256 fresh = _lpDeposit(v, bob, TOPUP);
        assertEq(v.grossNav(), nav + TOPUP, "NAV rises by the deposit and by nothing else");
        assertApproxEqAbs(v.convertToAssets(fresh), TOPUP, 2, "the newcomer's shares are worth what he paid in");
        assertEq(v.balanceOf(alice), aliceShares, "the stayer is not diluted by the entry");
        assertApproxEqAbs(v.convertToAssets(aliceShares), aliceValue, 2, "nor is she lifted by the newcomer's money");
    }

    /// @notice The top-up keeps the fee-free gap in assets and pays the curator nothing: entry is pro-rata, so it is not growth.
    /// @dev Recruiting cannot clear the mark: the entry adds its own cash to the high-water, and the curator must still earn the whole gap.
    function test_PartialRecovery_ALaterTopUpKeepsTheGapAndPaysTheCuratorNothing() public {
        (CuratorVault v, uint256 loanId) = _rig(2000);
        _finalizeShort(loanId);
        _buyPot(keeper, loanId, BUDGET);
        _crankAndRecognize(v);
        uint256 gap = v.feeHighWater() - v.totalAssets();
        uint256 held = v.balanceOf(curator);

        _lpDeposit(v, bob, TOPUP);
        v.collectFee();
        assertLt(v.totalAssets(), v.feeHighWater(), "the vault is still under water after the top-up, exactly as before it");
        assertEq(v.feeHighWater() - v.totalAssets(), gap, "fresh capital moved the fee-free gap the curator must earn back");
        assertEq(v.balanceOf(curator), held, "and it pays the curator nothing");
    }

    /// @notice A newcomer can leave again at his entry price: the IMPAIRMENT costs him nothing on the way out.
    /// @notice What bounds the SIZE of that exit is exitable cash, never the write-off.
    /// @dev So the subject here is the PRICE he leaves at, with exitable cash asserted as the premise, not the bug.
    function test_PartialRecovery_ALaterTopUpLeavesAtItsEntryPrice() public {
        (CuratorVault v, uint256 loanId) = _rig(2000);
        _finalizeShort(loanId);
        _buyPot(keeper, loanId, BUDGET);
        _crankAndRecognize(v);

        uint256 fresh = _lpDeposit(v, bob, TOPUP);
        /// @dev The vault sits under its own high-water mark throughout, so no fee is pending and the preview is the exact quote.
        uint256 quoted = v.previewRedeem(fresh); // the price his instant exit is about to pay
        assertEq(v.maxRedeem(bob), fresh, "PREMISE: exitable cash covers his whole holding");

        vm.prank(bob);
        uint256 out = v.redeem(fresh, bob, bob);
        assertLe(out, quoted, "he is paid at the price the quote named");
        assertGe(out + 1, quoted, "short of it by no more than the exit's own floor");
        assertApproxEqAbs(out, TOPUP, 4, "which is his own entry price, with no cut for the loss");
    }
}
