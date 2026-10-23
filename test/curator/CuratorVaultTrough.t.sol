// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.36;

import {CuratorVaultBase} from "./CuratorVaultBase.sol";
import {AceVault} from "../../src/curator/AceVault.sol";
import {CuratorVault} from "../../src/curator/CuratorVault.sol";
import {AceInventoryLens} from "../../src/ace/lens/AceInventoryLens.sol";
import {Math} from "@openzeppelin/contracts/utils/math/Math.sol";

/// @title CuratorVaultTrough
/// @notice A settled loan steps NAV down at once, and a claim in the trough pays the trough: no window, no recovery claim.
/// @notice No trough gate stands: entry waits on the settled pot's sale and on the pile gate while a gain over GATE_BPS vests.
/// @notice The MEASURE rows pin who takes a recovery, so any later change to that turns one of them red.
/// @dev Fee-zero unless a row says otherwise, so `_price` is exactly the price a claim computes.
contract CuratorVaultTroughTest is CuratorVaultBase {
    uint256 internal constant V_OFF = 1e6; // the vault's virtual-share offset
    uint256 internal constant DUST = 1e4; // asset-wei: rounding across a few prices and claims
    uint256 internal constant SEED = 10_000e6;
    uint256 internal constant DEEP = 1_200e6; // about six percent of a 20,000 book
    uint256 internal constant ALICE_IN = 9_900e6;
    uint256 internal constant MALLORY_IN = 100e6;
    uint256 internal constant LOAN = 6_000e6;
    address internal carol = address(0xCA201);
    address internal mallory = address(0xBAD);
    address internal entrant = address(0xE17);
    mapping(address => uint256) internal paidTo; // cash claimed so far, per holder

    // ---- helpers ----

    function _request(CuratorVault v, address who, uint256 shares) internal {
        vm.prank(who);
        v.requestExit(shares);
    }

    /// @dev Claim all of `who`'s request exitable cash covers now; nothing when it covers none of it.
    function _claim(CuratorVault v, address who) internal returns (uint256 got) {
        uint256 m = v.maxClaim(who); // BEFORE the prank: a read is a call, and a call would eat it
        if (m == 0 || v.previewRedeem(m) == 0) return 0;
        vm.prank(who);
        got = v.claimExit(m, who, 0);
        paidTo[who] += got;
    }

    /// @dev Claim the whole of `who`'s request, which a holder may always ask for when exitable cash covers its floored worth.
    function _claimWhole(CuratorVault v, address who) internal returns (uint256 got) {
        uint256 esc = _escrow(v, who); // BEFORE the prank: a read is a call, and a call would eat it
        vm.prank(who);
        got = v.claimExit(esc, who, 0);
        paidTo[who] += got;
    }

    function _escrow(CuratorVault v, address who) internal view returns (uint256 shares) {
        (shares,) = v.requestOf(who);
    }

    /// @dev The price a claim at this instant computes, at the vault's own rounding.
    function _price(CuratorVault v) internal view returns (uint256) {
        return Math.mulDiv(v.totalAssets() + 1, 1e18, v.totalSupply() + V_OFF);
    }

    /// @dev Settle the loan and sweep, returning the fall in gross NAV.
    function _settle(CuratorVault v, uint256 loanId) internal returns (uint256 drop) {
        uint256 g = v.grossNav();
        _finalize(loanId);
        _crankAll(v);
        drop = g - v.grossNav();
    }

    /// @dev Two equal LPs and no loans: every cent idle, nothing deferred.
    function _flat() internal returns (CuratorVault v) {
        v = _newVault(0);
        _lpDeposit(v, alice, SEED);
        _lpDeposit(v, bob, SEED);
    }

    /// @dev Two equal LPs, the given loans out, NAV flat once the opens' own gain has vested.
    function _book(uint256 a, uint256 b) internal returns (CuratorVault v, uint256 first, uint256 second) {
        v = _newVault(0);
        _lpDeposit(v, alice, SEED);
        _lpDeposit(v, bob, SEED);
        first = _open(a);
        _crank(v, first, T2, 0);
        if (b != 0) {
            second = _open(b);
            _crank(v, second, T2, 0);
        }
        _warpBy(VEST_W);
        v.crank();
    }

    /// @dev Entry is shut by the pile gate: both max views read zero and both verbs refuse with `GainVesting`.
    function _assertEntryShut(CuratorVault v) internal {
        assertEq(v.maxDeposit(entrant), 0, "maxDeposit advertised an entry the gate refuses");
        assertEq(v.maxMint(entrant), 0, "and so did maxMint");
        usdc.mint(entrant, 1e6);
        vm.startPrank(entrant);
        usdc.approve(address(v), 1e6);
        vm.expectRevert(AceVault.GainVesting.selector);
        v.deposit(1e6, entrant);
        vm.expectRevert(AceVault.GainVesting.selector);
        v.mint(1e6, entrant);
        vm.stopPrank();
    }

    /// @dev alice requests whole, mallory does not, `LOAN` drawn; nothing deferred.
    function _rig41() internal returns (CuratorVault v, uint256 loanId) {
        v = _newVault(0);
        _lpDeposit(v, alice, ALICE_IN);
        _lpDeposit(v, mallory, MALLORY_IN);
        loanId = _open(LOAN);
        _crank(v, loanId, T2, 0);
        _warpBy(VEST_W);
        v.crank();
        _request(v, alice, v.balanceOf(alice));
        assertEq(_escrow(v, alice), v.balanceOf(address(v)), "PREMISE: alice's whole holding is requested");
    }

    // ---- a claim in a dip pays the dip ----

    /// @notice A DIP CLAIM PAYS THE DIP PRICE, AND THE REQUEST KEEPS NO RECOVERY CLAIM: the later sale vests to whoever still holds.
    /// @notice The same rig that once advanced alice and burned her at the window's end: she now sells at the trough, about 3,960.
    function test_Claim_ADipClaimPaysTheDipPriceAndKeepsNoRecoveryClaim() public {
        (CuratorVault v, uint256 loanId) = _rig41();
        _settle(v, loanId);
        uint256 sh = _escrow(v, alice);
        uint256 worth = v.convertToAssets(sh);
        uint256 supply = v.totalSupply();
        _claim(v, alice); // the dip claim
        assertEq(_escrow(v, alice), 0, "the dip claim did not pay alice whole");
        assertEq(v.totalSupply(), supply - sh, "or it burned other than her request");
        assertApproxEqAbs(paidTo[alice], worth, 2, "or paid her at other than the dip price");
        uint256 g = v.grossNav();
        assertGt(_buyPot(keeper, loanId, LOAN), 0, "PREMISE: the inventory sold");
        _crankAll(v);
        uint256 recovered = v.grossNav() - g;
        _warpBy(VEST_W);
        assertApproxEqRel(paidTo[alice], 3_960e6, 1e16, "and alice did not sell near the trough's 3,960");
        assertGe(v.convertToAssets(v.balanceOf(mallory)) + 2, recovered, "the stayer did not take the whole recovery");
    }

    // ---- entry in a trough ----

    /// @notice A DIP DEEPER THAN THE OLD BAND SHUTS ENTRY UNTIL ITS POT SELLS: there is no trough gate, but the settled pot is unsold.
    function test_Gate_ADeepDipRefusesEntryUntilTheSale() public {
        (CuratorVault v, uint256 doomed,) = _book(DEEP, 0);
        uint256 p0 = _price(v);
        _settle(v, doomed);
        assertLt(_price(v) * 10_000, p0 * (10_000 - v.GATE_BPS()), "PREMISE: the dip sits deeper than GATE_BPS");
        _assertEntryWaitsForTheSale(v, entrant);
    }

    /// @notice MEASURE, the exemption's disclosed cost: UNDER A GUARDIAN'S EXEMPTION A TROUGH ENTRANT TAKES `R * X / (X + F)` OF A LATE SALE.
    /// @notice An exempted pot that later sells is shared with whoever entered over it; the stayers lose exactly what the entrant gains.
    function test_Measure_ATroughEntrantSharesTheRecovery() public {
        (CuratorVault v, uint256 doomed,) = _book(DEEP, 0);
        _settle(v, doomed);
        _waivePots(v); // the guardian exempts the pot, which then sells after all
        uint256 x = v.totalAssets(); // the entrant matches the stayers' NAV, so f is about one half
        uint256 shares = _lpDeposit(v, entrant, x);
        uint256 supply = v.totalSupply();
        uint256 g = v.grossNav();
        assertGt(_buyPot(keeper, doomed, DEEP), 0, "PREMISE: a third party bought the inventory");
        _crankAll(v);
        uint256 recovered = v.grossNav() - g;
        _warpBy(VEST_W);
        uint256 capture = v.convertToAssets(shares) - x;
        uint256 expected = Math.mulDiv(recovered, shares, supply + V_OFF);
        emit log_named_uint("the recovery a third party's purchase brought in", recovered);
        emit log_named_uint("the trough entrant's capture of it", capture);
        emit log_named_uint("the stayers' loss to the entrant", expected);
        assertApproxEqAbs(capture, expected, DUST, "the entrant took other than its pro-rata share of the recovery");
        assertApproxEqRel(capture * 2, recovered, 1e16, "PREMISE: at f of one half the entrant takes about half");
    }

    /// @notice E3, CLOSED: TROUGH CLAIMS CAN EMPTY THE VAULT, AND THE NEXT ENTRANT IS REFUSED UNTIL THE POT SELLS.
    /// @notice Every LP requests whole; the book is lent but for two USDC of change; the loan settles; both claim the change, voluntarily.
    /// @notice At supply zero the pile gate is skipped, but the unsold-pot gate holds at any supply, so no entrant buys the recovery.
    function test_Gate_ADustClaimEmptiesTheVaultAndTheNextEntrantWaitsForTheSale() public {
        CuratorVault v = _newVault(0);
        _lpDeposit(v, alice, SEED);
        _lpDeposit(v, bob, SEED);
        uint256 last = _open(2 * SEED - 2e6); // the change and the open's fee are all the idle there is
        v.crank();
        _warpBy(VEST_W);
        v.crank();
        _request(v, alice, v.balanceOf(alice));
        _request(v, bob, v.balanceOf(bob));
        _settle(v, last);
        uint256 dust = _claimWhole(v, alice) + _claimWhole(v, bob); // the trough claims, the holders' own choice
        emit log_named_uint("what the trough claims paid the whole supply", dust);
        assertEq(v.totalSupply(), 0, "the trough claims left supply standing");
        assertLt(dust * 20, 2 * SEED, "PREMISE: the claims paid under a twentieth of what was put in");
        _assertEntryWaitsForTheSale(v, entrant);
    }

    /// @notice MEASURE, E3's curator variant: A FEE SHARE NOBODY REQUESTED NO LONGER TAKES THE REQUESTERS' RECOVERY.
    /// @notice Two LPs request whole and claim out while the sale's cash vests; the last requester's claim releases the pile beside the fee shares.
    function test_Measure_ACuratorFeeShareNoLongerTakesTheRecoveryRequestersClaimDuringItsVest() public {
        CuratorVault v = _newVault(2000);
        _lpDeposit(v, alice, SEED);
        _lpDeposit(v, bob, SEED);
        uint256 growth = _open(2_000e6);
        uint256 tail = _open(100e6); // a small loan left out, so the trough's NAV is near zero and never zero
        uint256 last = _open(15_000e6);
        _crank(v, growth, T2, 0);
        _repay(growth, read.debtOf(growth));
        _crankAll(v);
        _warpBy(VEST_W);
        v.collectFee();
        uint256 fee = v.balanceOf(curator);
        assertGt(fee, 0, "PREMISE: the curator holds fee shares and requested none");
        _request(v, alice, v.balanceOf(alice));
        _request(v, bob, v.balanceOf(bob));
        _claim(v, alice); // all the cash there is, first come
        _claim(v, bob);
        _settle(v, last);
        uint256 supply = v.totalSupply();
        uint256 queued = v.requestedShares();
        uint256 nav = v.totalAssets();
        uint256 g = v.grossNav();
        uint256 hw = v.feeHighWater();
        _warpAtLeastTo(read.inventoryAskOpensAt(last));
        assertGt(_buyPot(keeper, last, 15_000e6), 0, "PREMISE: the inventory sold");
        _crankAll(v);
        uint256 recovered = v.grossNav() - g;
        _repay(tail, read.debtOf(tail)); // before the claims, so exitable cash covers a claim the release prices at gross
        _crankAll(v);
        for (uint256 i; i < 32 && v.requestedShares() != 0; i++) {
            if (_claim(v, alice) + _claim(v, bob) == 0) break;
        }
        assertEq(v.requestedShares(), 0, "PREMISE: the requests were claimed out");
        _warpBy(VEST_W);
        uint256 fair = Math.mulDiv(fee, nav + recovered, supply);
        uint256 after_ = v.convertToAssets(fee);
        uint256 feeOnRecovery = Math.mulDiv(Math.saturatingSub(nav + recovered, hw), 2000, 10_000);
        emit log_named_uint("the recovery the sale brought in", recovered);
        emit log_named_uint("the requesters' share of it", Math.mulDiv(recovered, queued, supply));
        emit log_named_uint("the fee shares' fair share of the trough and the recovery", fair);
        emit log_named_uint("the fee shares' worth after the vest", after_);
        emit log_named_uint("the fee on the recovery past the high-water", feeOnRecovery);
        assertLt(
            Math.saturatingSub(after_, fair) * 100, Math.mulDiv(recovered, queued, supply), "the fee shares took a material share of the requesters' recovery"
        );
    }

    // ---- the pile gate: entry waits while a large gain vests ----

    /// @notice A WHALE IS REFUSED WHILE A RECOVERY VESTS: a pile over GATE_BPS of NAV and one unit shuts entry.
    /// @notice It holds no exit: a request, an instant withdraw and a claim all land; entry reopens once the pile has vested under the line.
    function test_Gate_AWhaleIsRefusedWhileARecoveryVests() public {
        (CuratorVault v, uint256 doomed,) = _book(DEEP, 0);
        _request(v, bob, v.balanceOf(bob));
        _settle(v, doomed);
        AceInventoryLens inv = new AceInventoryLens(address(ace), address(lens));
        _warpAtLeastTo(read.inventoryAskOpensAt(doomed));
        _buyPot(keeper, doomed, inv.clearingBudget(mid, doomed)); // the recovery is the pot's whole sale, so no pot is left to shut entry
        v.crank();
        _warpBy(VEST_W / 2); // half has vested; the other half still vests
        assertGt(v.unvested() * 10_000, v.totalAssets() * v.GATE_BPS(), "PREMISE: the pile sits over GATE_BPS of NAV");
        _assertEntryShut(v);
        _request(v, alice, v.balanceOf(alice) / 2);
        assertGt(_escrow(v, alice), 0, "the pile held a request");
        vm.prank(alice);
        v.withdraw(1e6, alice, alice);
        assertGt(_claim(v, bob), 0, "or a claim");
        _warpBy(VEST_W);
        assertEq(v.maxDeposit(entrant), type(uint256).max, "entry did not reopen once the pile had vested");
        assertGt(_lpDeposit(v, entrant, 1_000e6), 0, "and the deposit was refused");
    }

    /// @notice A SMALL PILE ADMITS ENTRY: a pile at 4% of NAV takes a full-size deposit, and so does a near-empty vault's sub-unit pile.
    /// @dev Killed by M78, on the second leg: without the one-unit floor a pile of half a unit would shut a five-unit vault.
    function test_Gate_ASmallPileAdmitsEntry() public {
        CuratorVault v = _flat();
        _gift(v, 800e6); // 4% of the book
        v.crank();
        assertGt(v.unvested(), v.VEST_FLOOR(), "PREMISE: a pile over one unit stands");
        assertEq(v.maxDeposit(entrant), type(uint256).max, "a pile under GATE_BPS of NAV shut entry");
        assertGt(_lpDeposit(v, entrant, SEED), 0, "and the full-size deposit was refused");
        CuratorVault w = _newVault(0);
        _lpDeposit(w, alice, 5e6);
        _giftPart(w, 20e6, 5e5); // half a unit on a five-unit vault
        w.crank();
        assertGt(w.unvested() * 10_000, w.totalAssets() * w.GATE_BPS(), "PREMISE: the pile sits over GATE_BPS of NAV");
        assertLe(w.unvested(), w.VEST_FLOOR(), "PREMISE: and at most one asset unit");
        assertEq(w.maxDeposit(entrant), type(uint256).max, "a sub-unit pile shut a near-empty vault");
        assertGt(_lpDeposit(w, entrant, 1_000e6), 0, "and the deposit was refused");
    }

    /// @notice MAXDEPOSIT AGREES WITH DEPOSIT UNDER AN UNSYNCED GAIN: the view reads the pile the verb's own sync would leave.
    /// @dev Killed by M76: a view reading the stored pile advertises the entry the verb then refuses.
    function test_Gate_MaxDepositAgreesWithDepositUnderAnUnsyncedGain() public {
        CuratorVault v = _flat();
        _gift(v, 2_000e6); // 10% of the book, and nothing has synced it
        assertEq(v.unvested(), 0, "PREMISE: no sync has stamped the gain");
        assertEq(v.maxDeposit(entrant), 0, "maxDeposit advertised an entry the verb refuses");
        assertEq(v.maxMint(entrant), 0, "and so did maxMint");
        usdc.mint(entrant, 1e6);
        vm.startPrank(entrant);
        usdc.approve(address(v), 1e6);
        vm.expectRevert(AceVault.GainVesting.selector);
        v.deposit(1e6, entrant);
        vm.stopPrank();
        v.crank(); // the pile stamps
        _warpBy((VEST_W * 9) / 10); // a tenth left, under the line, and no sync since
        assertLt(v.unvested() * 10_000, v.totalAssets() * v.GATE_BPS(), "PREMISE: the pile has vested under the line");
        assertEq(v.maxDeposit(entrant), type(uint256).max, "maxDeposit shut an entry the verb takes");
        assertGt(_lpDeposit(v, entrant, 1_000e6), 0, "and the deposit was refused");
    }

    /// @notice A VAULT EVERY LP LEFT STAYS OPEN TO A NEW LIFE: the full exit was a claim, and the next two entrants are admitted.
    function test_Gate_AVaultEveryLpLeftAdmitsANewLife() public {
        CuratorVault v = _newVault(0);
        _lpDeposit(v, alice, SEED);
        _gift(v, 2_000e6); // the old life ends well above genesis
        v.crank();
        _warpBy(VEST_W);
        _request(v, alice, v.balanceOf(alice));
        _claimWhole(v, alice);
        assertEq(v.totalSupply(), 0, "PREMISE: the old life ended");
        assertEq(v.maxDeposit(bob), type(uint256).max, "a vault every LP left shut its first entrant out");
        assertGt(_lpDeposit(v, bob, SEED), 0, "and the first entrant was refused");
        assertGt(_lpDeposit(v, carol, SEED), 0, "and the second entrant was shut out");
    }

    // ---- the vest: a claim under a pile pays at once at the net price ----

    /// @notice A CLAIM UNDER A PILE FORFEITS ITS SHARE TO THE STAYERS: it pays at once at the net price, and the pile vests to whoever stays.
    /// @notice ACCEPTANCE of a recorded residual: at most one `VEST_WINDOW` of gains per claimed share, as any vault that unlocks profit.
    function test_Vest_AClaimUnderAPileForfeitsItsShareToTheStayers() public {
        CuratorVault v = _newVault(0);
        _lpDeposit(v, alice, 10_000e6);
        _lpDeposit(v, bob, 10_000e6);
        _request(v, bob, v.balanceOf(bob) / 2);
        _gift(v, 400e6);
        v.crank();
        (uint256 a, uint256 s, uint256 u) = (v.totalAssets(), v.totalSupply(), v.unvested());
        assertGt(u, 0, "PREMISE: a pile stands");
        uint256 got = _claim(v, bob);
        uint256 q = s - v.totalSupply();
        assertGt(q, 0, "the claim did not burn at once under the pile");
        assertApproxEqAbs(got, Math.mulDiv(q, a + 1, s + V_OFF), 2, "the claim was not at the net price");
        _warpBy(VEST_W);
        uint256 forfeit = Math.mulDiv(u, q, s + V_OFF);
        uint256 fair = Math.mulDiv(v.totalSupply(), a + u, s);
        emit log_named_uint("the claimed shares' part of the pile, handed to the stayers", forfeit);
        assertApproxEqAbs(v.totalAssets(), fair + forfeit, 10, "the stayers did not take exactly the claimed shares' part of the pile");
    }
}
