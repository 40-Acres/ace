// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.36;

import {ERC4626} from "@openzeppelin/contracts/token/ERC20/extensions/ERC4626.sol";
import {CuratorVault} from "../../src/curator/CuratorVault.sol";
import {AceVault} from "../../src/curator/AceVault.sol";
import {CuratorVaultBase} from "./CuratorVaultBase.sol";
import {CuratorVaultCapHarness} from "./harness/CuratorVaultCapHarness.sol";

/// @title CuratorVaultEntryCap
/// @notice The entry-cap hook: a product tightens entry by one view, and the base turns it into both max views and the verb's refusal.
/// @dev The cap is asked INSIDE the verb, after the base's own gates, so the view and the verb cannot answer apart.
contract CuratorVaultEntryCapTest is CuratorVaultBase {
    uint256 internal constant SEED = 10_000e6;
    uint256 internal constant CAP = 1_234e6;
    address internal carol = address(0xCA401);

    CuratorVaultCapHarness internal v;

    function setUp() public override {
        super.setUp();
        v = new CuratorVaultCapHarness(_cfg(0), _listing());
        mid = _doorMarket(v, address(collateral));
        _lpDeposit(v, alice, SEED);
    }

    /// @dev `who` holds `amt` of cash and has approved the vault for all of it.
    function _fund(address who, uint256 amt) internal {
        usdc.mint(who, amt);
        vm.prank(who);
        usdc.approve(address(v), amt);
    }

    function _exceeded(address r, uint256 assets, uint256 cap) internal pure returns (bytes memory) {
        return abi.encodeWithSelector(ERC4626.ERC4626ExceededMaxDeposit.selector, r, assets, cap);
    }

    // ---- the views read the cap ----

    /// @notice `maxDeposit` IS the cap, and `maxMint` is the cap in shares at the previews' own price.
    function test_EntryCap_MaxDepositIsTheCap_MaxMintIsItsPreview() public {
        v.setCap(CAP);
        assertEq(v.maxDeposit(bob), CAP, "the deposit view reads the product's cap");
        assertEq(v.maxMint(bob), v.previewDeposit(CAP), "and the mint view is that cap at the deposit preview's price");
        assertGt(v.maxMint(bob), 0, "PREMISE: a cap worth some shares");
    }

    /// @notice AT THE DEFAULT CAP BOTH VIEWS ADVERTISE NO CEILING, on the plain base and on a product that sets none.
    function test_EntryCap_TheDefaultCapAdvertisesNoCeiling() public {
        CuratorVault plain = _newVault(0);
        _lpDeposit(plain, alice, SEED);
        assertGt(plain.totalSupply(), 0, "PREMISE: a live vault, so the gates are really asked");
        assertEq(plain.maxDeposit(bob), type(uint256).max, "the plain base caps nothing");
        assertEq(plain.maxMint(bob), type(uint256).max, "in either unit");
        assertEq(v.maxDeposit(bob), type(uint256).max, "a product at the default cap caps nothing");
        assertEq(v.maxMint(bob), type(uint256).max, "and its mint view says the same");
    }

    // ---- the verbs refuse past it ----

    /// @notice A DEPOSIT PAST THE CAP IS REFUSED NAMING THE RECEIVER, THE ASK AND THE CAP; one at the cap lands.
    function test_EntryCap_ADepositPastTheCapIsRefusedByTheStandardError() public {
        v.setCap(CAP);
        _fund(bob, CAP + 1);
        vm.prank(bob);
        vm.expectRevert(_exceeded(bob, CAP + 1, CAP));
        v.deposit(CAP + 1, bob);
        vm.prank(bob);
        assertGt(v.deposit(CAP, bob), 0, "a deposit at the cap lands");
    }

    /// @notice A MINT PAST THE CAP IS REFUSED IN ASSETS, and a mint of exactly `maxMint` lands at or under the cap.
    function test_EntryCap_AMintPastTheCapIsRefusedInAssets() public {
        v.setCap(CAP);
        uint256 room = v.maxMint(bob);
        uint256 past = v.previewMint(room + 1);
        assertGt(past, CAP, "PREMISE: one share past the mint view costs more than the cap");
        _fund(bob, past);
        vm.prank(bob);
        vm.expectRevert(_exceeded(bob, past, CAP));
        v.mint(room + 1, bob);
        vm.prank(bob);
        uint256 paid = v.mint(room, bob);
        assertLe(paid, CAP, "mint(maxMint) never pays past the cap");
        assertEq(v.balanceOf(bob), room, "and mints exactly what the view promised");
    }

    /// @notice THE CAP IS ASKED OF THE RECEIVER, NOT THE CALLER: bob depositing for a shut receiver is refused, for himself admitted.
    function test_EntryCap_TheCapIsTheReceiversNotTheCallers() public {
        v.setShut(carol);
        assertEq(v.maxDeposit(carol), 0, "the shut receiver reads no room");
        assertEq(v.maxMint(carol), 0, "in either unit");
        _fund(bob, 2e6);
        vm.prank(bob);
        vm.expectRevert(_exceeded(carol, 1e6, 0));
        v.deposit(1e6, carol);
        vm.prank(bob);
        assertGt(v.deposit(1e6, bob), 0, "the same caller entering for himself is admitted");
    }

    /// @notice A CAP OF ZERO SHUTS BOTH DOORS, and both views say so.
    function test_EntryCap_ACapOfZeroShutsBothDoors() public {
        v.setCap(0);
        assertEq(v.maxDeposit(bob), 0, "no deposit room");
        assertEq(v.maxMint(bob), 0, "and no mint room");
        uint256 cost = v.previewMint(1e6);
        _fund(bob, cost + 1e6);
        vm.prank(bob);
        vm.expectRevert(_exceeded(bob, 1e6, 0));
        v.deposit(1e6, bob);
        vm.prank(bob);
        vm.expectRevert(_exceeded(bob, cost, 0));
        v.mint(1e6, bob);
    }

    // ---- the base's gates still answer first ----

    /// @notice THE CAP ONLY TIGHTENS: under a max cap and under a finite one, a vesting pile shuts entry by the base's own gate.
    function test_EntryCap_TheBaseGatesStillShutEntryUnderAnyCap() public {
        _gift(v, SEED / 10); // a counted rise past GATE_BPS of NAV, so the pile gate shuts entry
        uint256[2] memory caps = [type(uint256).max, CAP];
        for (uint256 i; i < 2; ++i) {
            v.setCap(caps[i]);
            assertEq(v.maxDeposit(bob), 0, "the base's gate shuts the deposit view whatever the cap");
            assertEq(v.maxMint(bob), 0, "and the mint view");
        }
        _fund(bob, 1e6);
        vm.prank(bob);
        vm.expectRevert(AceVault.GainVesting.selector);
        v.deposit(1e6, bob);
    }

    // ---- maxMint never reverts ----

    /// @notice `maxMint` SATURATES AT A HUGE FINITE CAP rather than overflowing the preview it prices through.
    function test_EntryCap_MaxMintSaturatesAtAHugeFiniteCap() public {
        uint256[3] memory caps = [type(uint256).max - 1, uint256(1) << 255, uint256(1) << 240];
        for (uint256 i; i < 3; ++i) {
            v.setCap(caps[i]);
            assertEq(v.maxMint(bob), type(uint256).max, "a cap past what a preview can price reads as no ceiling");
        }
    }

    /// @notice FOR ANY CAP AND PRICE `maxMint` ANSWERS, and where it is finite it is EXACT: a mint of it fits the cap, one share more does not.
    function testFuzz_EntryCap_MaxMintNeverRevertsNorOverpays(uint256 cap, uint256 gain) public {
        gain = bound(gain, 0, SEED);
        if (gain != 0) {
            _giftPart(v, gain + 10e6, gain); // a counted rise, synced and vested below; the donor keeps its market's minimum resting
            _crankAndRecognize(v);
        }
        v.setCap(cap);
        uint256 room = v.maxMint(bob);
        if (room == type(uint256).max) return;
        assertLe(v.previewMint(room), cap, "the mint view's shares never cost past the cap");
        assertGt(v.previewMint(room + 1), cap, "and one share more always would: the mint view never under-quotes");
    }
}
