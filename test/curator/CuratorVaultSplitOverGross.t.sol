// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.36;

import {CuratorVaultBase} from "./CuratorVaultBase.sol";
import {AceVault} from "../../src/curator/AceVault.sol";
import {AceVault} from "../../src/curator/AceVault.sol";
import {MarketParams} from "../../src/ace/hub/Types.sol";
import {AceFixtures} from "../utils/AceFixtures.sol";

/// @title CuratorVaultSplitOverGross
/// @notice The Certora `VaultSplit` counterexamples (#790, run emv-8), replayed on a deployed vault as the property they broke.
/// @notice Their start was a vest pile past gross with no live supply: a stamp inside a window once read a wei above its rise.
/// @notice A stamp's basis now floors, so it reads back exactly the pile plus the rise, and the replay pins that it never reads past it.
/// @dev THE LAW: a sync never leaves the pile above the rises it observed, so a split entry never beats the whole, at any supply.
/// @dev On a seed-only vault, counted payouts a second apart, each cranked, build the state; nothing but the vault's own rounding is needed.
/// @dev With shares out, a trough exit first takes all but the seed's part; two rows then pin the view's quote and the sync's stamp there.
/// @dev The start-state pin is `CuratorVaultForeignPayout.test_TwoDustDonationsBeforeTheFirstDepositCannotBrickEntry`.
contract CuratorVaultSplitOverGrossTest is CuratorVaultBase {
    uint256 internal constant GIFT = 1_000e6; // what the donor rests in its own market in the vault's asset
    uint256 internal constant DUST = 1_000; // each counted payout, the size the start-state pin uses
    uint256 internal constant X = 1_000e6; // a first depositor's seed
    uint256 internal constant Y = 10_000e6; // the second entrant's stake
    uint256 internal constant KEPT = 400_000; // the shares bob keeps: under a wei's worth at a two-wei gross, over one at three

    address internal donor = address(0xD0D0);

    AceVault internal w;
    bytes32 internal gift; // the donor's market in the vault's asset, naming the donor its one lender

    function setUp() public override {
        super.setUp();
        w = _newVault(0);
        MarketParams memory p = AceFixtures.marketParams(w.asset(), address(collateral));
        p.lender = donor;
        gift = ace.createMarket(p);
        _lendDirectIn(donor, gift, GIFT);
    }

    /// @notice THE PILE READS BACK EXACTLY: two dust payouts a second apart leave it reading exactly the two payouts, not a wei past them.
    function test_ThePileNeverReadsPastTheGrossAtZeroSupply() public {
        _overGross(1);
        assertEq(w.totalSupply(), w.SEED_SHARES(), "PREMISE: no live share was ever minted");
        assertEq(w.grossNav(), 2 * DUST + w.MIN_SEED(), "PREMISE: gross is the two payouts and the seed");
        assertEq(w.unvested(), 2 * DUST, "the second stamp read back past the payouts");
        assertEq(w.totalAssets(), w.MIN_SEED(), "and NAV is the gross less a pile that is exactly the payouts");
        assertEq(w.maxDeposit(alice), type(uint256).max, "a seed-only vault admits, with no pile gate at no live supply");
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
        assertEq(w.totalSupply(), w.SEED_SHARES(), "PREMISE: still no live share");
        assertEq(w.unvested(), w.grossNav() - w.MIN_SEED(), "the overshoot grew a wei per stamp");
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
        _lpDeposit(w, alice, 1); // gross 2,001 over the seed against a pile of exactly 2,000
        assertEq(w.totalAssets(), 1 + w.MIN_SEED(), "the wei deposited is NAV, not swallowed by an overstated pile");
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
        assertEq(w.unvested(), w.grossNav() - w.MIN_SEED(), "the stamp left the pile past the payouts");
        assertGt(used, 10_000, "a stamp is two hub-touching calls");
        assertLt(used, 1_000_000, "and stays under this bound");
    }

    // ---- with shares out: a trough leaves only the seed's part of gross, and dust stamps land on it ----

    /// @notice THE VIEW'S QUOTE: the last requester's quote prices at the gross his claim releases, never a wei above it.
    /// @notice His 400,000 shares are worth under a wei at the gross the seed leaves, so the quote is zero and the claim refuses in step.
    function test_TheLastRequestersQuoteAgreesWithTheClaimOverAnUnsyncedRise() public {
        _spentWithSharesOut();
        assertEq(w.maxClaim(bob), 0, "the quote replayed the release a wei past gross, offering a claim the verb refuses");
        vm.prank(bob);
        vm.expectRevert(AceVault.ZeroAssets.selector);
        w.claimExit(KEPT, bob, 0);
    }

    /// @notice THE SYNC'S STAMP: a stamp onto a dust pile with shares out reads back exactly the two rises, so NAV recovers as the pile vests.
    function test_WithSharesOutAStampLeavesThePileAtTheGross() public {
        uint256 g = _spentWithSharesOut();
        w.crank();
        assertEq(w.totalSupply(), KEPT + w.SEED_SHARES(), "PREMISE: shares are out");
        assertEq(w.grossNav(), g, "PREMISE: the crank moved no gross");
        assertEq(w.unvested(), 2, "the stamp left the pile past the two rises it observed");
        uint256 a0 = w.totalAssets();
        _waivePots(w); // the settled pot never sells here, so the guardian takes it out of the entry gate
        _warpBy(VEST_W * 3 / 5 - 1); // four tenths of the window left: the floored basis of 2 reads ceil(0.8), one wei
        assertEq(w.grossNav(), g, "PREMISE: nothing moved gross over the warp");
        assertEq(w.unvested(), 1, "PREMISE: four tenths of the window from maturity, the two-wei pile reads one wei");
        assertEq(w.totalAssets(), a0 + 1, "NAV did not recover by exactly the one wei of the pile that vested");
        assertEq(w.maxDeposit(alice), type(uint256).max, "so the view kept a recovering vault spent");
        assertGt(_lpDeposit(w, alice, X), 0, "and the entry did not mint");
    }

    /// @dev With shares out: bob's trough exit takes all but the seed's part, a one-wei stamp, his whole request, a one-wei rise unsynced.
    /// @return g The gross after the unsynced rise.
    function _spentWithSharesOut() internal returns (uint256 g) {
        uint256 shares = _lpDeposit(w, bob, X);
        uint256 loanId = _open(850e6);
        w.crank();
        _warpBy(VEST_W + 1); // the open's own gain matures, so the next stamp starts a fresh window
        _finalize(loanId);
        w.crank();
        vm.prank(bob);
        w.redeem(shares - KEPT, bob, bob); // below par his floor takes all of NAV but the seed's part, and he keeps KEPT shares
        assertLe(w.grossNav(), 2 * w.MIN_SEED(), "PREMISE: the trough exit took all of gross but the seed's part");
        assertEq(w.totalSupply(), KEPT + w.SEED_SHARES(), "PREMISE: bob kept his shares");
        _payAndStamp(1); // an exact stamp: the pile is the one wei
        assertEq(w.unvested(), 1, "PREMISE: the pile is the one wei");
        uint256 g0 = w.grossNav();
        vm.prank(bob);
        w.requestExit(KEPT);
        _warpBy(1);
        vm.prank(donor);
        ace.withdraw(gift, 1, address(w), 0); // a counted rise a second later, NOT synced
        g = w.grossNav();
        assertEq(g, g0 + 1, "PREMISE: the rise is counted");
        assertEq(w.unvested(), 1, "PREMISE: a second on, the pile still reads its one wei");
    }

    /// @dev One counted payout of `amount` from the donor's market to the vault, stamped by a crank.
    function _payAndStamp(uint256 amount) internal {
        vm.prank(donor);
        ace.withdraw(gift, amount, address(w), 0);
        w.crank();
    }

    /// @dev The counterexample's start: no live supply and a dust gross, `k` same-second stamps after a first one.
    function _overGross(uint256 k) internal {
        _payAndStamp(DUST); // the first stamp: the pile is exactly the payout
        _warpBy(1);
        for (uint256 i; i < k; i++) {
            _payAndStamp(DUST); // a stamp inside a running window, where the old ceil basis read a wei past its rise
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
        uint256 g = w.grossNav() - w.MIN_SEED();
        (uint256 alice1, uint256 bob1) = _twoEntrantsAfterTheVest();
        vm.revertToState(snap);
        _payAndStamp(g); // the same rises, one stamp: the pile is the payouts and not a wei past them
        assertEq(w.unvested(), w.grossNav() - w.MIN_SEED(), "PREMISE: the counterfactual pile is exact");
        (uint256 alice0, uint256 bob0) = _twoEntrantsAfterTheVest();
        assertLe(alice1, alice0, "the rounding never helps the first depositor");
        assertGe(bob1, bob0, "nor hurts the second");
        (aliceLoss, bobGain) = (alice0 - alice1, bob1 - bob0);
    }
}
