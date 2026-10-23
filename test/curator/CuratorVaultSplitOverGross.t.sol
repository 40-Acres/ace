// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.36;

import {CuratorVaultBase} from "./CuratorVaultBase.sol";
import {CuratorVault} from "../../src/curator/CuratorVault.sol";
import {AceVault} from "../../src/curator/AceVault.sol";
import {MarketParams} from "../../src/ace/hub/Types.sol";
import {AceFixtures} from "../utils/AceFixtures.sol";

/// @title CuratorVaultSplitOverGross
/// @notice The Certora `VaultSplit` counterexamples (#790, run emv-8), replayed on a deployed vault as the property they broke.
/// @notice Their start was a vest pile past gross at zero supply: both vest roundings ceil, so a stamp inside a window reads a wei above its rise.
/// @notice `totalAssets` floored that at zero, so the first deposit's cash covered the overshoot and a second entrant bought at that discount.
/// @dev THE LAW: a sync never leaves the pile above the gross it observed, so a split entry never beats the whole, at any supply.
/// @dev At zero supply, counted payouts a second apart, each cranked, build the state; nothing but the vault's own rounding is needed.
/// @dev With shares out, a trough exit first takes the whole gross; two rows then pin each half of the cap, the sync's and the view's.
/// @dev The start-state pin is `CuratorVaultForeignPayout.test_TwoDustDonationsBeforeTheFirstDepositCannotBrickEntry`.
contract CuratorVaultSplitOverGrossTest is CuratorVaultBase {
    uint256 internal constant GIFT = 1_000e6; // what the donor rests in its own market in the vault's asset
    uint256 internal constant DUST = 1_000; // each counted payout, the size the start-state pin uses
    uint256 internal constant X = 1_000e6; // a first depositor's seed
    uint256 internal constant Y = 10_000e6; // the second entrant's stake
    uint256 internal constant KEPT = 400_000; // the shares bob keeps: under a wei's worth at a two-wei gross, over one at three

    address internal donor = address(0xD0D0);

    CuratorVault internal w;
    bytes32 internal gift; // the donor's market in the vault's asset, naming the donor its one lender

    function setUp() public override {
        super.setUp();
        w = _newVault(0);
        MarketParams memory p = AceFixtures.marketParams(w.asset(), address(collateral));
        p.lender = donor;
        gift = ace.createMarket(p);
        _lendDirectIn(donor, gift, GIFT);
    }

    /// @notice THE PILE IS CAPPED AT THE GROSS: two dust payouts a second apart leave it reading exactly the gross, not a wei past it.
    function test_ThePileNeverReadsPastTheGrossAtZeroSupply() public {
        _overGross(1);
        assertEq(w.totalSupply(), 0, "PREMISE: no share was ever minted");
        assertEq(w.grossNav(), 2 * DUST, "PREMISE: gross is the two payouts");
        assertEq(w.unvested(), w.grossNav(), "the second stamp read back past the gross: both vest roundings ceil");
        assertEq(w.totalAssets(), 0, "and NAV is the gross less a pile that is all of it");
        assertEq(w.maxDeposit(alice), type(uint256).max, "an empty vault admits, with no pile gate at zero supply");
    }

    /// @notice THE PROVER'S DEPOSIT COUNTEREXAMPLE ON THE SHIPPED VAULT: 2 then 2 mint no more than 4 at once.
    function test_SplitDepositNeverMintsMoreThanTheWhole_AtTheProversNumbers() public {
        _overGross(1);
        (uint256 sx, uint256 sy, uint256 sxy) = _splitDeposit(2, 2);
        assertEq(sxy, 4e6, "the whole enters at the virtual price");
        assertLe(sx + sy, sxy, "two deposits minted more than one deposit of their sum");
    }

    /// @notice AT REAL SIZES: a 1,000 seed then a 10,000 stake mint no more than the 11,000 at once.
    function test_SplitDepositNeverMintsMoreThanTheWhole_AtRealSizes() public {
        _overGross(1);
        (uint256 sx, uint256 sy, uint256 sxy) = _splitDeposit(X, Y);
        assertEq(sxy, (X + Y) * 1e6, "the whole enters at the virtual price");
        assertLe(sx + sy, sxy, "the split minted past the whole");
    }

    /// @notice THE PROVER'S MINT COUNTEREXAMPLE ON THE SHIPPED VAULT: 2e6 then 3e6 shares cost no less than 5e6 at once.
    function test_SplitMintNeverChargesLessThanTheWhole() public {
        _overGross(1);
        uint256 snap = vm.snapshotState();
        uint256 a1 = _lpMint(alice, 2e6);
        uint256 a2 = _lpMint(alice, 3e6);
        vm.revertToState(snap);
        uint256 a12 = _lpMint(alice, 5e6);
        assertEq(a12, 5, "the whole charges at the virtual price");
        assertGe(a1 + a2, a12, "two mints charged less than one mint of their sum");
    }

    /// @notice NOBODY PAYS: against a world with the same gross stamped exactly, neither entrant gains or loses a wei.
    function test_TheFirstDepositorLosesNothingToTheRounding() public {
        (uint256 aliceLoss, uint256 bobGain) = _leak(1);
        assertEq(aliceLoss, 0, "the first depositor paid for a wei the pile overstated");
        assertEq(bobGain, 0, "and the second entrant was handed it");
    }

    /// @notice SAME-SECOND STAMPS DO NOT ACCUMULATE AN OVERSHOOT: forty of them leave the pile at the gross, and no entry leaks.
    function test_ManySameSecondStampsNeverOvershoot() public {
        uint256 snap = vm.snapshotState();
        _overGross(40);
        assertEq(w.totalSupply(), 0, "PREMISE: still no share");
        assertEq(w.unvested(), w.grossNav(), "the overshoot grew a wei per stamp");
        (uint256 sx, uint256 sy, uint256 sxy) = _splitDeposit(X, Y);
        assertLe(sx + sy, sxy, "the split minted past the whole");
        vm.revertToState(snap);
        (uint256 aliceLoss, uint256 bobGain) = _leak(40);
        assertEq(aliceLoss, 0, "the first depositor paid for the overshoot");
        assertEq(bobGain, 0, "and the second entrant was handed it");
    }

    /// @notice WITH SHARES OUT ENTRY STAYS OPEN: a one-wei first deposit buys a wei of NAV, so the next entrant is not refused.
    function test_AOneWeiFirstDepositLeavesEntryOpen() public {
        _overGross(1);
        _lpDeposit(w, alice, 1); // gross 2,001 against a pile capped at 2,000
        assertEq(w.totalAssets(), 1, "the wei deposited is NAV, not swallowed by an overstated pile");
        assertGt(w.maxDeposit(bob), 0, "so the view admits");
        assertGt(_lpDeposit(w, bob, Y), 0, "and the next entrant mints");
    }

    /// @notice WHAT A STAMP COSTS: a hub withdraw naming the vault, then a crank; logged, loosely bounded, and it never overshoots.
    function test_OneStampCostsAHubWithdrawAndACrank() public {
        _payAndStamp(DUST);
        _warpBy(1);
        uint256 g0 = gasleft();
        _payAndStamp(DUST);
        uint256 used = g0 - gasleft();
        emit log_named_uint("gas per stamp", used);
        assertEq(w.unvested(), w.grossNav(), "the stamp left the pile past the gross");
        assertGt(used, 10_000, "a stamp is two hub-touching calls");
        assertLt(used, 1_000_000, "and stays under this bound");
    }

    // ---- with shares out: the cap binds only at NAV zero at the mark, so a trough builds that state ----

    /// @notice THE VIEW'S CAP: the last requester's quote prices at the gross his claim releases, never a wei above it.
    /// @notice His 400,000 shares are worth under a wei at a two-wei gross, so the quote is zero and the claim refuses in step.
    function test_TheLastRequestersQuoteAgreesWithTheClaimOverAnUnsyncedRise() public {
        _spentWithSharesOut();
        assertEq(w.maxClaim(bob), 0, "the quote replayed the release a wei past gross, offering a claim the verb refuses");
        vm.prank(bob);
        vm.expectRevert(AceVault.ZeroAssets.selector);
        w.claimExit(KEPT, bob, 0);
    }

    /// @notice THE SYNC'S CAP: a stamp onto a pile that is the whole mark leaves it at the gross, so NAV recovers on the gross's own schedule.
    /// @notice An uncut pile reads a wei past gross, and four tenths of a window from maturity it still swallows all of a two-wei gross.
    function test_WithSharesOutAStampLeavesThePileAtTheGross() public {
        _spentWithSharesOut();
        w.crank();
        assertEq(w.totalSupply(), KEPT, "PREMISE: shares are out");
        assertEq(w.grossNav(), 2, "PREMISE: the crank moved no gross");
        assertEq(w.unvested(), w.grossNav(), "the stamp left the pile a wei past the gross it observed");
        _waivePots(w); // the settled pot never sells here, so the guardian takes it out of the entry gate
        _warpBy(VEST_W * 3 / 5 - 1); // four tenths of the window left: a cut basis of 2 reads 1, an uncut one of 3 reads 2
        assertEq(w.totalAssets(), 1, "the pile still swallowed the whole gross");
        assertEq(w.maxDeposit(alice), type(uint256).max, "so the view kept a recovering vault spent");
        assertGt(_lpDeposit(w, alice, X), 0, "and the entry did not mint");
    }

    /// @dev NAV zero at the mark with shares out: bob's trough exit takes the whole gross, a one-wei stamp, his whole request, a one-wei rise unsynced.
    function _spentWithSharesOut() internal {
        uint256 shares = _lpDeposit(w, bob, X);
        uint256 loanId = _open(850e6);
        w.crank();
        _warpBy(VEST_W + 1); // the open's own gain matures, so the next stamp starts a fresh window
        _finalize(loanId);
        w.crank();
        vm.prank(bob);
        w.redeem(shares - KEPT, bob, bob); // below par his floor takes the whole NAV, and he keeps KEPT shares
        assertEq(w.grossNav(), 0, "PREMISE: the trough exit took the whole gross");
        assertEq(w.totalSupply(), KEPT, "PREMISE: bob kept his shares");
        _payAndStamp(1); // an exact first stamp: the pile is the whole gross and the whole mark
        assertEq(w.unvested(), 1, "PREMISE: the pile is the one wei");
        vm.prank(bob);
        w.requestExit(KEPT);
        _warpBy(1);
        vm.prank(donor);
        ace.withdraw(gift, 1, address(w), 0); // a counted rise a second later, NOT synced
        assertEq(w.grossNav(), 2, "PREMISE: the rise is counted");
        assertEq(w.unvested(), 1, "PREMISE: a second on, the pile still reads the whole mark");
    }

    /// @dev One counted payout of `amount` from the donor's market to the vault, stamped by a crank.
    function _payAndStamp(uint256 amount) internal {
        vm.prank(donor);
        ace.withdraw(gift, amount, address(w), 0);
        w.crank();
    }

    /// @dev The counterexample's start: supply zero and a dust gross, `k` same-second stamps after an exact one.
    function _overGross(uint256 k) internal {
        _payAndStamp(DUST); // the first stamp is exact: the pile IS the whole gross
        _warpBy(1);
        for (uint256 i; i < k; i++) {
            _payAndStamp(DUST); // a stamp inside a running window rounds up past its rise
        }
    }

    /// @dev Two deposits by one receiver, then the same sum at once from the state before them.
    function _splitDeposit(uint256 x, uint256 y) internal returns (uint256 sx, uint256 sy, uint256 sxy) {
        uint256 snap = vm.snapshotState();
        sx = _lpDeposit(w, alice, x);
        sy = _lpDeposit(w, alice, y);
        vm.revertToState(snap);
        sxy = _lpDeposit(w, alice, x + y);
    }

    /// @dev Mint `shares` for `who`, funded generously, returning the assets the verb pulled.
    function _lpMint(address who, uint256 shares) internal returns (uint256 assets) {
        usdc.mint(who, Y);
        vm.startPrank(who);
        usdc.approve(address(w), type(uint256).max);
        assets = w.mint(shares, who);
        vm.stopPrank();
    }

    /// @dev Alice enters with X, Bob with Y, and both values are read once the window has run.
    function _twoEntrantsAfterTheVest() internal returns (uint256 aliceValue, uint256 bobValue) {
        _lpDeposit(w, alice, X);
        _lpDeposit(w, bob, Y);
        _warpBy(VEST_W + 1);
        aliceValue = w.previewRedeem(w.balanceOf(alice));
        bobValue = w.previewRedeem(w.balanceOf(bob));
    }

    /// @dev The value moved by `k` rounding stamps, against a world whose same gross was stamped in one exact payout.
    function _leak(uint256 k) internal returns (uint256 aliceLoss, uint256 bobGain) {
        uint256 snap = vm.snapshotState();
        _overGross(k);
        uint256 g = w.grossNav();
        (uint256 alice1, uint256 bob1) = _twoEntrantsAfterTheVest();
        vm.revertToState(snap);
        _payAndStamp(g); // the same gross, one exact stamp: the pile is the gross and not a wei past it
        assertEq(w.unvested(), w.grossNav(), "PREMISE: the counterfactual pile is exact");
        (uint256 alice0, uint256 bob0) = _twoEntrantsAfterTheVest();
        assertLe(alice1, alice0, "the rounding never helps the first depositor");
        assertGe(bob1, bob0, "nor hurts the second");
        (aliceLoss, bobGain) = (alice0 - alice1, bob1 - bob0);
    }
}
