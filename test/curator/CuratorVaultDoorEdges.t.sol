// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.36;

import {Address} from "@openzeppelin/contracts/utils/Address.sol";
import {AceVault} from "../../src/curator/AceVault.sol";
import {CuratorVaultBase} from "./CuratorVaultBase.sol";
import {CuratorVaultDoorProbe} from "./harness/CuratorVaultDoorProbe.sol";

/// @title CuratorVaultDoorEdges
/// @notice The door bracket at its edges: what the open books before the body, and what the close runs after it.
/// @dev Each row is written in the order the hostile or careless act happens, and each names the mutation it kills in the report.
contract CuratorVaultDoorEdgesTest is CuratorVaultBase {
    uint256 internal constant SEED = 10_000e6;

    CuratorVaultDoorProbe internal h;
    address internal payer = address(0xFA7E5);

    function setUp() public override {
        super.setUp();
        h = _probe(0); // fee-free: no leg these rows measure reads the fee; the fee twin below builds its own
    }

    /// @dev A probe vault listing the rig collateral, seeded by alice.
    function _probe(uint16 fee) internal returns (CuratorVaultDoorProbe p) {
        p = new CuratorVaultDoorProbe(_cfg(fee), _listing());
        mid = _doorMarket(p, address(collateral));
        _lpDeposit(p, alice, SEED);
    }

    /// @dev Alice requests half her shares on `p`; returns what the request holds of exitable cash.
    function _requested(CuratorVaultDoorProbe p) internal returns (uint256 held) {
        uint256 half = p.balanceOf(alice) / 2;
        vm.prank(alice);
        p.requestExit(half);
        (, held) = p.holds();
        assertGt(held, 0, "PREMISE: the request holds exitable cash");
    }

    /// @dev A door body paid `amt` mid-body by `payer`, as a buyer pays, and paying nothing on.
    function _landInside(uint256 amt) internal {
        usdc.mint(payer, amt);
        vm.prank(payer);
        usdc.approve(address(h), amt);
        h.inAndOut(false, payer, amt, bob, 0);
    }

    /// @notice ON A FEE VAULT, A REALIZING SWEEP THAT MINTS THE FEE LEAVES THE REQUESTS' HOLD WHERE IT WAS.
    /// @dev The fee is already in the quote supply the hold prices against, so minting it moves neither the price nor the hold.
    function test_DoorEdge_AFeeVaultsRealizingSweepMintsTheFee() public {
        CuratorVaultDoorProbe f = _probe(2000);
        _requested(f);
        _giftPart(f, 1_010e6, 1_000e6); // a counted rise; the donor keeps its market's minimum resting
        f.crank(); // stamps the rise, which vests by the door
        _warpBy(VEST_W);
        uint256 fee = f.pendingFeeShares();
        assertGt(fee, 0, "PREMISE: the vested rise owes the curator a fee");
        (, uint256 h0) = f.holds();
        uint256 c0 = f.balanceOf(curator);
        f.step(true);
        assertEq(f.balanceOf(curator) - c0, fee, "the sweep minted the pending fee");
        (, uint256 h1) = f.holds();
        assertEq(h1, h0, "and the requests' hold did not move");
    }

    // ---- what each close runs ----

    /// @notice EVERY CLOSE SWEEPS THE HUB'S POOL FOR THIS VAULT: whatever flag a product body carries, its door realizes.
    function test_DoorEdge_EveryCloseSweepsTheHubPool() public {
        uint256 loanId = _open(500e6);
        _repay(loanId, 200e6);
        (,, uint256 owed) = read.lenderPools(address(h), h.asset());
        assertGt(owed, 0, "PREMISE: the hub owes this vault a pooled credit");
        vm.expectEmit(address(h));
        emit AceVault.Collected(owed);
        h.step(false);
        (,, uint256 owed1) = read.lenderPools(address(h), h.asset());
        assertEq(owed1, 0, "the close swept it");
    }

    /// @notice A DOOR'S CLOSE BOOKS WHAT ITS BODY LANDED: the rise is deferred from this door, not left for the next verb to find.
    function test_DoorEdge_TheCloseDefersTheRiseItsBodyLanded() public {
        assertEq(h.unvested(), 0, "PREMISE: nothing vests before the door");
        _landInside(7e6);
        assertApproxEqAbs(h.unvested(), 7e6, 1, "the close synced: the landed gift vests from this door");
    }

    /// @notice A DOOR'S OPEN BOOKS AN UNSYNCED FALL BEFORE ITS BODY RUNS, so a gain the body lands vests whole, never netted against it.
    function test_DoorEdge_TheOpenBooksAnUnsyncedFallBeforeTheBody() public {
        h.bleed(bob, 3e6);
        assertEq(h.unvested(), 0, "PREMISE: nothing vests, and the fall is unsynced");
        _landInside(7e6);
        assertApproxEqAbs(h.unvested(), 7e6, 1, "the whole landed gain vests; netted against the fall it would read 4 USDC");
    }

    /// @notice THE DELEGATE HOOK REFUSES A LIBRARY WITH NO CODE, so a void door body never "succeeds" against an empty address.
    function test_DoorEdge_TheDelegateHookRefusesACodelessLibrary() public {
        address none = address(0xC0DE1E55);
        assertEq(none.code.length, 0, "PREMISE: nothing is deployed there");
        vm.expectRevert(abi.encodeWithSelector(Address.AddressEmptyCode.selector, none));
        h.delegateTo(none, abi.encodeWithSignature("halt()"));
    }
}
