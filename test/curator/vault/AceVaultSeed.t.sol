// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.36;

import {stdError} from "forge-std/StdError.sol";
import {MarketParams} from "../../../src/ace/hub/Types.sol";
import {AceVault} from "../../../src/curator/AceVault.sol";
import {AceVaultFactory} from "../../../src/curator/AceVaultFactory.sol";
import {AceVaultFlows, Terms, VaultConfig} from "../../../src/curator/AceVaultFlows.sol";
import {CapListing, ProductConfig} from "../../../src/curator/AceVaultCaps.sol";
import {CuratedVaults} from "../../utils/CuratedVaults.sol";
import {VaultSeed} from "../../utils/VaultSeed.sol";
import {AceVaultBaseRig} from "./AceVaultBaseRig.sol";
import {MockTerms} from "./MockTerms.sol";

/// @title AceVaultSeed
/// @notice The genesis seed: a config floor of `MIN_SEED` atoms, every unit found at the vault's address booked at par to the vault itself.
/// @notice The seed's shares never leave, every zero-supply branch reads live supply past them, and the factory pre-funds the address it deploys to.
contract AceVaultSeedTest is AceVaultBaseRig {
    uint256 internal constant SEED = 1e4;

    function _navMark(AceVault v) internal view returns (uint256) {
        bytes32[] memory s = new bytes32[](1);
        s[0] = bytes32(uint256(AceVaultFlows.ROOT) + 1);
        return uint256(v.extsload(s)[0]);
    }

    /// @dev A MockTerms at the next create, then the vault at the one after, `fund` atoms minted there first; the deploy runs as an external call.
    function _fresh(VaultConfig memory cfg, uint256 fund) internal returns (AceVault v, MockTerms t) {
        address predicted = vm.computeCreateAddress(address(this), vm.getNonce(address(this)) + 1);
        t = new MockTerms(predicted, address(ace));
        ProductConfig memory pc = _pc();
        pc.terms = address(t);
        if (fund != 0) usdc.mint(predicted, fund);
        v = new AceVault(cfg, pc, _listing(predicted, _caps(UNCAPPED, 0, UNCAPPED)), "Seed", "sVLT");
        assertEq(address(v), predicted, "rig: the vault landed off its predicted address");
    }

    /// @dev `_fresh` with its revert expected, armed after the terms deploy so the vault's own constructor is what refuses.
    function _freshRefuses(VaultConfig memory cfg, uint256 fund, bytes4 err) internal {
        address predicted = vm.computeCreateAddress(address(this), vm.getNonce(address(this)) + 1);
        MockTerms t = new MockTerms(predicted, address(ace));
        ProductConfig memory pc = _pc();
        pc.terms = address(t);
        if (fund != 0) usdc.mint(predicted, fund);
        CapListing[] memory c = _listing(predicted, _caps(UNCAPPED, 0, UNCAPPED));
        vm.expectRevert(err);
        new AceVault(cfg, pc, c, "Seed", "sVLT");
    }

    function _enter(AceVault v, address who, uint256 amt) internal returns (uint256 shares) {
        usdc.mint(who, amt);
        vm.startPrank(who);
        usdc.approve(address(v), amt);
        shares = v.deposit(amt, who);
        vm.stopPrank();
    }

    // ---- the floor and the funding ----

    /// @notice A config naming a seed under `MIN_SEED` atoms refuses, however much the address holds.
    function test_Seed_ASeedUnderTheFloorRefuses() public {
        VaultConfig memory cfg = _cfg();
        cfg.seed = SEED - 1;
        _freshRefuses(cfg, 1e12, AceVault.SeedTooSmall.selector);
    }

    /// @notice An address holding one atom less than the config's seed refuses.
    function test_Seed_AnUnfundedSeedRefuses() public {
        VaultConfig memory cfg = _cfg();
        cfg.seed = 5 * SEED;
        _freshRefuses(cfg, 5 * SEED - 1, AceVault.SeedUnfunded.selector);
    }

    /// @notice The floor is `MIN_SEED`, 1e4 atoms, as the vault and the library both name it.
    function test_Seed_TheFloorIsTenThousandAtoms() public view {
        assertEq(vault.MIN_SEED(), SEED, "the vault's floor is not 1e4 atoms");
        assertEq(AceVaultFlows.MIN_SEED, SEED, "the library's floor is not 1e4 atoms");
    }

    // ---- the booking ----

    /// @notice A fresh vault holds exactly the seed at par: its shares at the vault, the mark, the high-water and NAV all the seed.
    function test_Seed_TheSeedIsMintedAtParToTheVaultItself() public {
        (AceVault v,) = _fresh(_cfg(), SEED);
        assertEq(v.SEED_SHARES(), SEED * 1e6, "the seed's shares are not at par");
        assertEq(v.balanceOf(address(v)), SEED * 1e6, "the seed's shares are not the vault's own");
        assertEq(v.totalSupply(), SEED * 1e6, "the supply is not the seed's");
        assertEq(v.totalAssets(), SEED, "NAV is not the seed");
        assertEq(_navMark(v), SEED, "the mark is not the seed");
        assertEq(vlens.navHigh(address(v)), SEED, "the high-water is not the seed");
        assertEq(v.unvested(), 0, "the seed vests");
        assertEq(v.previewDeposit(1e6), 1e12, "a deposit after the seed is not at par");
        assertEq(_enter(v, alice, 1_000e6), 1_000e12, "a deposit after the seed did not mint today's count");
    }

    /// @notice A fee vault's seed stamps the fee high-water at the seed, and no fee is pending on it.
    function test_Seed_TheSeedStampsTheFeeHighWater() public {
        VaultConfig memory cfg = _cfg();
        cfg.perfFeeBps = 1000;
        (AceVault v,) = _fresh(cfg, SEED);
        assertEq(v.feeHighWater(), SEED, "the seed did not stamp the high-water");
        assertEq(v.pendingFeeShares(), 0, "a fee is pending on the seed");
    }

    /// @notice The seed books under a product whose entry cap is zero: the constructor asks the product nothing.
    function test_Seed_TheSeedLandsUnderAZeroEntryCap() public {
        address predicted = vm.computeCreateAddress(address(this), vm.getNonce(address(this)) + 1);
        MockTerms t = new MockTerms(predicted, address(ace));
        t.setEntryCap(MockTerms.Mode.Answer, 0);
        ProductConfig memory pc = _pc();
        pc.terms = address(t);
        usdc.mint(predicted, SEED);
        AceVault v = new AceVault(_cfg(), pc, _listing(predicted, _caps(UNCAPPED, 0, UNCAPPED)), "Seed", "sVLT");
        assertEq(v.totalAssets(), SEED, "the seed did not book under a zero entry cap");
        assertEq(v.maxDeposit(alice), 0, "premise: the product's cap shuts entry");
    }

    /// @notice Everything at the address is booked as seed: a donation before the deploy becomes dead seed, not a stamped gain.
    function test_Seed_TheWholeGenesisBalanceIsBooked() public {
        uint256 held = 3 * SEED + 7;
        (AceVault v,) = _fresh(_cfg(), held);
        assertEq(v.SEED_SHARES(), held * 1e6, "the seed did not take the whole balance");
        assertEq(v.totalAssets(), held, "NAV is not the whole balance");
        assertEq(_navMark(v), held, "the mark is not the whole balance");
        assertEq(v.unvested(), 0, "the pre-deploy donation vests as a gain");
        assertGt(v.maxDeposit(alice), 0, "a pre-deploy donation shut entry");
        assertEq(_enter(v, alice, 1_000e6), 1_000e12, "the first deposit is not at par");
    }

    // ---- the seed's shares never leave ----

    /// @dev The vault's own balance covers the requests' escrow and the seed.
    function _assertSeedHeld(AceVault v) internal view {
        assertGe(v.balanceOf(address(v)), vlens.requestedShares(address(v)) + v.SEED_SHARES(), "the seed's shares left the vault");
    }

    /// @notice Through a request, a claim, a cancel, a lapse and a full exit, the vault keeps the seed's shares; no view offers them.
    function test_Seed_TheSeedSharesNeverLeave() public {
        uint256 s = vault.balanceOf(alice);
        vm.startPrank(alice);
        vault.requestExit(s / 4);
        _assertSeedHeld(vault);
        vault.claimExit(s / 8, alice, 0);
        _assertSeedHeld(vault);
        vault.cancelExit(s / 16);
        _assertSeedHeld(vault);
        vm.stopPrank();
        _warpBy(31 days);
        vault.lapseExit(alice);
        _assertSeedHeld(vault);
        vm.expectRevert(AceVault.NoRequest.selector);
        vault.lapseExit(address(vault));
        assertEq(vault.maxRedeem(address(vault)), 0, "the vault's own shares are offered to redeem");
        assertEq(vault.maxWithdraw(address(vault)), 0, "the vault's own shares are offered to withdraw");
        uint256 all = vault.balanceOf(alice);
        vm.prank(alice);
        vault.redeem(all, alice, alice);
        assertEq(vault.totalSupply(), vault.SEED_SHARES(), "a full exit left more or less than the seed");
        assertEq(vault.balanceOf(address(vault)), vault.SEED_SHARES(), "a full exit moved the seed");
        assertEq(vault.totalAssets(), SEED, "a full exit left NAV other than the seed");
    }

    /// @notice The seed is no free holder: while a gain vests the one LP's full exit still refuses, and its last claim releases the pile.
    function test_Seed_LastOutVestingAndTheReleaseStillWork() public {
        usdc.mint(address(vault), 10_000e6);
        vault.crank();
        assertGt(vault.unvested(), 0, "premise: a gain vests");
        uint256 all = vault.balanceOf(alice);
        vm.prank(alice);
        vm.expectRevert(AceVault.LastOutVesting.selector);
        vault.redeem(all, alice, alice);
        vm.startPrank(alice);
        vault.requestExit(all);
        uint256 paid = vault.claimExit(all, alice, 0);
        vm.stopPrank();
        assertEq(vault.unvested(), 0, "the last claim did not release the pile");
        assertGt(paid, LP_CASH + 9_999e6, "the last claim did not take the released gain");
    }

    // ---- live supply ----

    /// @notice A donation to a vault holding only the seed does not shut entry: with no live shares the gain gate does not bind.
    function test_LiveSupply_ADonationToASeedOnlyVaultDoesNotShutEntry() public {
        (AceVault v,) = _fresh(_cfg(), SEED);
        usdc.mint(address(v), 10e6);
        v.crank();
        assertGt(v.unvested(), v.VEST_FLOOR(), "premise: the donation vests over one unit");
        assertGt(v.unvested() * 10_000, v.totalAssets() * v.GATE_BPS(), "premise: far over the gain band");
        assertGt(v.maxDeposit(alice), 0, "a donation shut a seed-only vault's entry");
        assertGt(_enter(v, alice, 1_000e6), 0, "a deposit refused on a seed-only vault");
    }

    /// @notice When the last live share leaves, the fee high-water re-stamps at NAV, as an empty vault's does.
    function test_LiveSupply_TheFeeHighWaterReStampsAtLiveSupplyZero() public {
        VaultConfig memory cfg = _cfg();
        cfg.perfFeeBps = 1000;
        (AceVault v, MockTerms t) = _fresh(cfg, SEED);
        _pointAt(t, v);
        _enter(v, alice, LP_CASH);
        uint256 loanId = _borrowOn(v);
        _warpTo(read.loan(loanId).expiry + 1);
        ace.forceClose(loanId);
        v.crank();
        (, uint256 settled) = ace.lenderUnresolved(address(v), address(usdc));
        vm.prank(guardian);
        v.exemptDeadPots(settled);
        _warpBy(VEST_W + 1);
        v.crank();
        assertEq(v.unvested(), 0, "premise: no pile stands");
        assertGt(v.feeHighWater(), v.totalAssets(), "premise: the loss left the high-water over NAV");
        uint256 all = v.balanceOf(alice);
        vm.prank(alice);
        v.redeem(all, alice, alice);
        assertEq(v.totalSupply(), v.SEED_SHARES(), "premise: no live share is out");
        v.collectFee();
        assertEq(v.feeHighWater(), v.totalAssets(), "with no live supply the high-water did not re-stamp at NAV");
    }

    // ---- the factory ----

    /// @notice The factory pulls exactly the config's seed from its caller to the predicted address, and `predict` is where the vault lands.
    function test_Seed_TheFactoryPullsExactlyTheSeed() public {
        AceVaultFactory f = CuratedVaults.factory(address(ace));
        bytes32 salt = keccak256("seed");
        address predicted = f.predict(address(this), salt);
        MockTerms t = new MockTerms(predicted, address(ace));
        ProductConfig memory pc = _pc();
        pc.terms = address(t);
        VaultConfig memory cfg = _cfg();
        cfg.seed = 2 * SEED;
        usdc.mint(address(this), 5 * SEED);
        usdc.approve(address(f), 2 * SEED);
        uint256 before = usdc.balanceOf(address(this));
        AceVault v = AceVault(f.deploy(type(AceVault).creationCode, cfg, pc, _listing(predicted, _caps(UNCAPPED, 0, UNCAPPED)), "F", "fV", salt));
        assertEq(address(v), predicted, "the vault landed off the prediction");
        assertEq(before - usdc.balanceOf(address(this)), 2 * SEED, "the factory pulled other than the seed");
        assertEq(v.totalAssets(), 2 * SEED, "the vault did not book the pulled seed");
        assertEq(usdc.allowance(address(this), address(f)), 0, "the factory left an allowance standing");
    }

    /// @notice Without the caller's approval the factory deploys nothing.
    function test_Seed_AFactoryDeployWithoutApprovalDeploysNothing() public {
        AceVaultFactory f = CuratedVaults.factory(address(ace));
        bytes32 salt = keccak256("unapproved");
        address predicted = f.predict(address(this), salt);
        MockTerms t = new MockTerms(predicted, address(ace));
        ProductConfig memory pc = _pc();
        pc.terms = address(t);
        usdc.mint(address(this), SEED);
        CapListing[] memory c = _listing(predicted, _caps(UNCAPPED, 0, UNCAPPED));
        bytes memory code = type(AceVault).creationCode;
        VaultConfig memory cfg = _cfg();
        assertEq(usdc.allowance(address(this), address(f)), 0, "PREMISE: the factory holds no allowance; the balance covers the seed");
        vm.expectRevert(stdError.arithmeticError); // the mock's insufficient-allowance error: its allowance underflows at the pull
        f.deploy(code, cfg, pc, c, "F", "fV", salt);
        assertEq(predicted.code.length, 0, "a vault landed with no seed pulled");
        assertFalse(f.isAceVault(predicted), "and was registered");
    }

    // ---- helpers for the fee row ----

    /// @dev Point `t` at `v`'s own market on the rig collateral, drawing the rig's ask.
    function _pointAt(MockTerms t, AceVault v) internal {
        MarketParams memory p = _market(address(coll), record);
        p.lender = address(v);
        t.setTerms(p, Terms({units: UNITS, principal: PRINCIPAL, tenor: 0, minBufferWad: 0}));
    }

    function _borrowOn(AceVault v) internal returns (uint256 loanId) {
        coll.mint(borrower, UNITS);
        vm.startPrank(borrower);
        coll.approve(address(v), UNITS);
        loanId = v.borrow(_req(address(coll), UNITS, PRINCIPAL, 0), "", "");
        vm.stopPrank();
    }
}
