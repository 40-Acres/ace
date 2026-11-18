// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.36;

import {Ace} from "../../../src/ace/hub/Ace.sol";
import {LoanMath} from "../../../src/ace/hub/libraries/LoanMath.sol";
import {MarketParams} from "../../../src/ace/hub/Types.sol";
import {AceVaultFlows} from "../../../src/curator/AceVaultFlows.sol";
import {MockTerms} from "./MockTerms.sol";
import {AceVaultDoorRig} from "./AceVaultDoorRig.sol";

/// @notice Phase 5 probes of run 2026-11-08-e8017a over the AceVault base in door mode: what a door, a product's write call and a stranger's settle can do.
contract AceVaultAuditE8017aTest is AceVaultDoorRig {
    uint256 internal constant VEST_WORD = 2; // slot 2: uint128 vestBasis | uint64 vestMaturity << 128 | bool draining << 192 | uint48 troughHold << 200

    function _vestMaturity() internal view returns (uint64) {
        bytes32[] memory s = new bytes32[](1);
        s[0] = bytes32(uint256(AceVaultFlows.ROOT) + VEST_WORD);
        return uint64(uint256(vault.extsload(s)[0]) >> 128);
    }

    /// @notice MEASURE, door trust: the door closes a key with no cash while every unit of the goods is still at the door, and entry reopens at once.
    /// @notice An entrant who lands then shares the booked value the door returns later, after one vest window.
    /// @dev The door is trusted: the trough hold reads the pile standing at the clear, and a cashless close before a return leaves none to hold.
    function test_Measure_E8017a_ADoorsCashlessCloseLetsAnEntrantShareALaterReturn() public {
        uint256 loanId = _defaulted();
        uint256 pot = _collect(loanId);
        assertGt(pot, 0, "premise: the door holds the goods");
        (uint256 booked, bool open,) = _seized(address(coll));
        assertTrue(open, "premise: the key shuts entry");
        assertEq(vault.maxDeposit(bob), 0, "premise: entry is shut while the key is open");
        uint256 navBefore = vault.totalAssets();

        // the door's word alone: no cash, `closes = true`, every unit still at the door
        _give(address(coll), 0, true);
        (, bool stillOpen,) = _seized(address(coll));
        assertFalse(stillOpen, "the door closed the key with no timelock and no cash");
        assertEq(coll.balanceOf(address(door)), pot, "the goods never moved");
        assertGt(vault.maxDeposit(bob), 0, "entry reopened on the door's word");

        uint256 entry = LP_CASH;
        uint256 bobShares = _lp(bob, entry);
        assertGt(bobShares, 0, "the entrant landed over goods at the door");

        // the door now returns the whole booked value: a gain that vests
        _give(address(coll), booked, false);
        _warpBy(VEST_W + 1);
        vault.collectFee();
        uint256 bobWorth = vault.previewRedeem(vault.balanceOf(bob));
        uint256 aliceWorth = vault.previewRedeem(vault.balanceOf(alice));
        emit log_named_uint("NAV before the early close", navBefore);
        emit log_named_uint("booked value the door later returned", booked);
        emit log_named_uint("entrant deposited", entry);
        emit log_named_uint("entrant worth after the vest", bobWorth);
        emit log_named_uint("entrant gain", bobWorth - entry);
        emit log_named_uint("incumbent worth after the vest", aliceWorth);
        assertGt(bobWorth, entry, "the entrant took a share of a recovery whose loss it never carried");
    }

    /// @notice A stranger settles at the hub, the guardian exempts that count, then the door collects the already-settled pot: the key opens with
    /// @notice no new settlement, so the exemption still covers it and entry stays open with the goods at the door.
    function test_E8017a_AnExemptionCoversAPotTheDoorCollectsAfterIt() public {
        uint256 loanId = _defaulted();
        ace.forceClose(loanId);
        (uint256 u, uint256 s) = ace.lenderUnresolved(address(vault), address(usdc));
        assertEq(u, 1, "premise: one unsold pot");
        assertEq(vault.maxDeposit(bob), 0, "premise: the hub pot shuts entry");
        vm.prank(guardian);
        vault.exemptDeadPots(s);
        assertGt(vault.maxDeposit(bob), 0, "the exemption lifts the hub leg");
        _collect(loanId);
        (, bool open,) = _seized(address(coll));
        assertTrue(open, "the collect opened the door key");
        (uint256 u2, uint256 s2) = ace.lenderUnresolved(address(vault), address(usdc));
        assertEq(u2, 0, "the pot left the hub");
        assertEq(s2, s, "no new settlement: the snapshot still matches");
        assertGt(vault.maxDeposit(bob), 0, "the exemption covers the key the collect opened after it");
        uint256 shares = _lp(bob, 1_000e6);
        assertGt(shares, 0, "an entrant lands over goods at the door under the exemption");
    }

    /// @notice A product's `beforeLend` on `borrow` settles another expired loan of the vault's at the hub, which pushes the vault's whole pool credit
    /// @notice into idle mid-door: the borrow still lands, pays exactly the hub's payout, and leaves nothing resting.
    function test_E8017a_ABeforeLendForceCloseMidBorrowLeavesThePayoutAndTheRestExact() public {
        uint256 loanY = _borrow();
        _warpTo(read.loan(loanY).expiry + 1);
        uint256 owedBefore = ace.lenderOwed(address(vault), address(usdc));
        assertGt(owedBefore, 0, "premise: the vault has uncollected credit the push will land");
        terms.setReentry(address(ace), abi.encodeCall(Ace.forceClose, (loanY)), true, false);
        MarketParams memory mp = ace.idToMarketParams(ace.loanMarket(loanY));
        uint256 fee = LoanMath.originationFee(PRINCIPAL, TENOR, mp.lenderAprBps);
        uint256 idleBefore = vault.idle();
        uint256 borrowerBefore = usdc.balanceOf(borrower);

        uint256 loanZ = _borrowAs(borrower, address(coll), UNITS, PRINCIPAL);

        assertTrue(terms.reentered(), "the write call ran");
        assertTrue(terms.reentryOk(), "the forceClose landed from inside the door");
        assertEq(usdc.balanceOf(borrower) - borrowerBefore, PRINCIPAL - fee, "the payout is the hub's alone, not the pushed credit");
        assertEq(ace.restingOf(ace.loanMarket(loanZ)), 0, "nothing rests after the door");
        uint256 pushed = owedBefore + LoanMath.escrowCut(fee); // the settle earns the whole escrow, then the close pushes the whole pool
        assertEq(vault.idle(), idleBefore + pushed - PRINCIPAL, "the pushed credit stayed in idle, the principal left");
        (uint256 lent,) = ace.lenderByCollateral(address(vault), address(usdc), address(coll));
        assertEq(lent, PRINCIPAL, "only the new claim is lent; the settled one left lent");
        assertGt(lens.drawdown(address(vault)), 0, "the settled claim's loss sits in the drawdown");
    }

    /// @notice The vest maturity never moves earlier and never sits past now plus the window, over any sequence of the value verbs.
    function testFuzz_E8017a_VestMaturityNeverEarlierAndWithinOneWindow(uint8[12] memory ops, uint24[12] memory warps, uint64 amtSeed) public {
        uint64 m0 = _vestMaturity();
        assertLe(m0, _now() + VEST_W, "base: within one window");
        uint256 loanId;
        for (uint256 i; i < ops.length; ++i) {
            _warpBy(uint256(warps[i]) % (2 * VEST_W));
            uint256 amt = (uint256(amtSeed) % 50_000e6) + 1e6;
            uint8 op = ops[i] % 8;
            if (op == 0) {
                if (vault.maxDeposit(alice) >= amt) _lp(alice, amt);
            } else if (op == 1) {
                uint256 maxW = vault.maxWithdraw(alice);
                if (maxW > 1) {
                    vm.prank(alice);
                    vault.withdraw(maxW / 2, alice, alice);
                }
            } else if (op == 2) {
                usdc.mint(address(vault), amt);
            } else if (op == 3) {
                if (vault.lendable() >= PRINCIPAL) loanId = _borrowAs(borrower, address(coll), UNITS, PRINCIPAL);
            } else if (op == 4) {
                if (loanId != 0 && read.loan(loanId).closedAt == 0 && _now() < read.loan(loanId).expiry) {
                    uint256 debt = read.loan(loanId).debt;
                    usdc.mint(borrower, debt);
                    vm.startPrank(borrower);
                    usdc.approve(address(ace), debt);
                    ace.repay(loanId, debt);
                    vm.stopPrank();
                    loanId = 0;
                }
            } else if (op == 5) {
                vault.collectFee();
            } else if (op == 6) {
                vault.crank();
            } else {
                if (loanId != 0 && read.loan(loanId).closedAt == 0 && _now() >= read.loan(loanId).expiry) {
                    ace.forceClose(loanId);
                    loanId = 0;
                }
            }
            uint64 m1 = _vestMaturity();
            assertGe(m1, m0, "the maturity moved earlier");
            assertLe(m1, _now() + VEST_W, "the maturity sits past one window from now");
            m0 = m1;
        }
    }
}
