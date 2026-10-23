// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.36;

import {ERC4626} from "@openzeppelin/contracts/token/ERC20/extensions/ERC4626.sol";
import {CuratorVaultBase} from "./CuratorVaultBase.sol";
import {CuratorVaultCapHarness} from "./harness/CuratorVaultCapHarness.sol";

/// @title CuratorVaultEntryCapFee
/// @notice The entry cap on a FEE-BEARING vault, with a fee pending that each entry verb mints before it prices.
/// @dev The fee-free rows in `CuratorVaultEntryCap` cannot see the pending-fee term in `maxMint`'s quote supply: at fee 0 it is zero.
contract CuratorVaultEntryCapFeeTest is CuratorVaultBase {
    uint256 internal constant SEED = 10_000e6;
    uint256 internal constant GAIN = 1_000e6;
    uint256 internal constant CAP = 1_234e6;

    CuratorVaultCapHarness internal v;

    function setUp() public override {
        super.setUp();
        v = new CuratorVaultCapHarness(_cfg(2000), _listing());
        mid = _doorMarket(v, address(collateral));
        _lpDeposit(v, alice, SEED);
        _giftPart(v, GAIN + 10e6, GAIN); // a counted rise; the donor keeps its market's minimum resting
        _crankAndRecognize(v);
        assertGt(v.pendingFeeShares(), 0, "PREMISE: a fee is pending, so each entry verb mints it before it prices");
        assertGt(v.maxDeposit(bob), 0, "PREMISE: and entry is open");
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

    /// @notice `mint(maxMint)` LANDS WITH THE FEE MINTED IN THE SAME CALL: it mints exactly the view, costs its preview, and fits the cap.
    /// @notice One share more is refused in assets, naming the cap.
    function test_EntryCapFee_MintAtMaxMintLandsWithTheFeeMintedFirst() public {
        v.setCap(CAP);
        uint256 room = v.maxMint(bob);
        uint256 cost = v.previewMint(room);
        uint256 fee = v.pendingFeeShares();
        _fund(bob, 2 * CAP);

        uint256 snap = vm.snapshotState();
        uint256 c0 = v.balanceOf(curator);
        vm.prank(bob);
        uint256 paid = v.mint(room, bob);
        assertEq(v.balanceOf(curator) - c0, fee, "the verb minted the pending fee in the same call");
        assertEq(paid, cost, "and charged exactly the mint preview, the fee's shares counted");
        assertLe(paid, CAP, "mint(maxMint) never pays past the cap");
        assertEq(v.balanceOf(bob), room, "and mints exactly what the view promised");
        vm.revertToState(snap);

        uint256 over = v.previewMint(room + 1);
        assertGt(over, CAP, "one share past the view costs past the cap: the view is the maximum");
        vm.prank(bob);
        vm.expectRevert(_exceeded(bob, over, CAP));
        v.mint(room + 1, bob);
    }

    /// @notice `deposit(maxDeposit)` LANDS WITH THE FEE MINTED IN THE SAME CALL and mints its preview exactly; one asset more is refused.
    function test_EntryCapFee_DepositAtMaxDepositLandsWithTheFeeMintedFirst() public {
        v.setCap(CAP);
        assertEq(v.maxDeposit(bob), CAP, "PREMISE: the deposit view is the cap");
        uint256 promised = v.previewDeposit(CAP);
        uint256 fee = v.pendingFeeShares();
        _fund(bob, CAP + 1);
        vm.prank(bob);
        vm.expectRevert(_exceeded(bob, CAP + 1, CAP));
        v.deposit(CAP + 1, bob);
        uint256 c0 = v.balanceOf(curator);
        vm.prank(bob);
        uint256 shares = v.deposit(CAP, bob);
        assertEq(v.balanceOf(curator) - c0, fee, "the verb minted the pending fee in the same call");
        assertEq(shares, promised, "and minted exactly the deposit preview");
    }

    /// @notice FOR ANY CAP, WITH A FEE PENDING, a finite `maxMint` is EXACT: its preview fits the cap and one share more does not.
    /// @dev Where the view is finite and fundable, the verb agrees with it: `mint(maxMint)` lands at the previewed cost.
    function testFuzz_EntryCapFee_MaxMintIsExactWithAFeePending(uint256 cap) public {
        v.setCap(cap);
        uint256 room = v.maxMint(bob);
        if (room == type(uint256).max) return;
        assertLe(v.previewMint(room), cap, "the mint view's shares never cost past the cap");
        assertGt(v.previewMint(room + 1), cap, "and one share more always would: the view never under-quotes");
        if (cap > 100_000_000e6) return;
        uint256 cost = v.previewMint(room);
        _fund(bob, cost);
        vm.prank(bob);
        assertEq(v.mint(room, bob), cost, "the verb charges what the view's preview said");
    }
}
