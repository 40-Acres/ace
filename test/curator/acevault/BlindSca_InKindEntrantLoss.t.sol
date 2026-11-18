// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.36;

import {InKindRig} from "../../inkind/InKindRig.sol";
import {Quote} from "../../inkind/InKindSurface.sol";

/// @title BlindSca_InKindEntrantLoss
/// @notice RSCA-1 PoC, flipped to assert the fix: in kind a share bears a default's NAV loss and earns its pot over the same supply, whatever its age.
/// @notice The collect is permissionless, so ordering it after a fresh deposit no longer moves the depositor's loss to the holder who collects.
contract BlindSca_InKindEntrantLoss is InKindRig {
    uint256 internal constant P = 100_000e6; // a 10% of NAV loan
    uint256 internal constant BIG_UNITS = 400_000e18; // the recordless line is about 280,000 units at 0.5 USDC

    /// @dev Alice deposits, a loan opens and runs to expiry without being settled; returns the loan and alice's shares.
    function _stage() internal returns (uint256 loanId, uint256 sa) {
        sa = _lp(alice, LP_CASH);
        _warpBy(MIN_TENOR);
        _nextBlock();
        Quote memory q = _quote(address(tokA), PRICE);
        q.maxPrincipal = P;
        loanId = _borrowWith(q, _data(q), BIG_UNITS, P, MIN_TENOR);
        _toExpiry(loanId);
        _nextBlock();
    }

    /// @dev One ordering's outcome: the pot, bob's shares, and each holder's cash and claimable tokA.
    struct Seen {
        uint256 pot;
        uint256 sb;
        uint256 aliceCash;
        uint256 alicePot;
        uint256 bobCash;
        uint256 bobPot;
    }

    /// @dev Read both holders a block after the collect that brought `pot` home, bob holding `sb`.
    function _read(uint256 pot, uint256 sb) internal view returns (Seen memory z) {
        (z.pot, z.sb) = (pot, sb);
        (z.aliceCash, z.alicePot) = _worth(alice);
        (z.bobCash, z.bobPot) = _worth(bob);
    }

    /// @dev The asset value of `who`'s shares plus the tokA it can claim valued at the loan's own market price.
    function _worth(address who) internal view returns (uint256 cash, uint256 pot) {
        cash = vault.previewRedeem(vault.balanceOf(who));
        pot = _claimable(who, address(tokA));
    }

    /// @notice Bob deposits after expiry and before the settle: he funds his share of the loss and is credited his share of the pot.
    function test_RSCA1_aFreshDepositBeforeTheSettleSharesTheLossAndThePot() public {
        (uint256 loanId, uint256 sa) = _stage();

        // ---- counterfactual: the pot is collected BEFORE bob enters ----
        uint256 snap = vm.snapshotState();
        uint256 pot = _collect(loanId);
        _nextBlock();
        uint256 sb = _lp(bob, LP_CASH);
        _nextBlock();
        Seen memory a = _read(pot, sb);
        vm.revertToState(snap);

        // ---- the actual ordering: bob deposits, then anyone (here alice's own keeper) collects in the next tx ----
        sb = _lp(bob, LP_CASH);
        pot = _collect(loanId);
        _nextBlock();
        Seen memory b = _read(pot, sb);

        emit log_named_uint("pot units (both orderings)", b.pot);
        emit log_named_uint("alice shares", sa);
        emit log_named_uint("bob shares, collect first", a.sb);
        emit log_named_uint("bob shares, deposit first", b.sb);
        emit log_named_uint("A alice cash", a.aliceCash);
        emit log_named_uint("A alice tokA", a.alicePot);
        emit log_named_uint("A bob cash", a.bobCash);
        emit log_named_uint("A bob tokA", a.bobPot);
        emit log_named_uint("B alice cash", b.aliceCash);
        emit log_named_uint("B alice tokA", b.alicePot);
        emit log_named_uint("B bob cash", b.bobCash);
        emit log_named_uint("B bob tokA", b.bobPot);

        assertEq(a.pot, b.pot, "premise: the same pot comes home either way");
        assertApproxEqAbs(b.bobPot, b.pot * b.sb / (sa + b.sb), 2, "bob earns his pro-rata slice of the pot");
        assertApproxEqAbs(b.alicePot, b.pot * sa / (sa + b.sb), 2, "and alice hers");
        assertLt(b.bobCash, LP_CASH - P / 2 + P / 50, "bob still carries about half the loss in cash");
        assertGt(a.bobCash, LP_CASH - P / 100, "had the collect come first bob would have lost nothing");
        // tokA at the loan's 0.5 USDC: half its 18-decimal units, scaled to 6 decimals
        assertGe(b.bobCash + b.bobPot / 2e12, a.bobCash, "bob's slice of the pot pays back at least the loss he carried");
        assertLe(b.aliceCash + b.alicePot / 2e12, a.aliceCash + a.alicePot / 2e12, "and ordering the collect after bob no longer pays alice");
    }

    uint256 internal constant BIG = 400_000e6; // under the row's 500,000 cap and the lendable 1,000,000
    uint256 internal constant BIG_LOT = 1_200_000e18; // the line is about 1,120,000 units at 0.5 USDC

    /// @dev Alice deposits alone; her second address borrows BIG at a fair appraisal; bob enters an hour in.
    /// @return loanId The loan.
    /// @return sa Alice's shares.
    /// @return sb Bob's shares.
    /// @return payout What the borrowing address received.
    function _stageSelfDefault() internal returns (uint256 loanId, uint256 sa, uint256 sb, uint256 payout) {
        sa = _lp(alice, LP_CASH);
        _warpBy(MIN_TENOR);
        _nextBlock();
        Quote memory q = _quote(address(tokA), PRICE);
        q.maxPrincipal = BIG;
        loanId = _borrowWith(q, _data(q), BIG_LOT, BIG, MIN_TENOR);
        payout = usdc.balanceOf(borrower);
        _warpBy(1 hours);
        _nextBlock();
        sb = _lp(bob, LP_CASH);
    }

    /// @notice The manufactured form no longer pays: a holder defaulting on purpose via a second address shares the pot with bob and ends below its start.
    function test_RSCA1b_aHolderWhoDefaultsOnPurposeEndsBelowItsStart() public {
        (uint256 loanId, uint256 sa, uint256 sb, uint256 payout) = _stageSelfDefault();

        // the loan lapses; alice collects in the expiry block, and claims her slice the next
        _toExpiry(loanId);
        _nextBlock();
        uint256 pot = _collect(loanId);
        _nextBlock();
        uint256 aliceTok = _claim(alice, address(tokA));
        vm.prank(borrower);
        (uint256 excess,) = ace.claimOwed(loanId, borrower);
        assertApproxEqAbs(aliceTok, pot * sa / (sa + sb), 2, "the defaulting holder takes only its pro-rata slice");
        assertApproxEqAbs(_claimable(bob, address(tokA)), pot * sb / (sa + sb), 2, "bob takes his");

        uint256 bobCash = vault.previewRedeem(sb);
        // tokA valued at the appraised 0.5 USDC: half its 18-decimal units, scaled to 6 decimals
        uint256 attackerEnd = vault.previewRedeem(vault.balanceOf(alice)) + payout + (aliceTok + excess) / 2e12;
        uint256 attackerStart = LP_CASH + BIG_LOT / 2e12;

        emit log_named_uint("pot units", pot);
        emit log_named_uint("payout kept by the borrowing address", payout);
        emit log_named_uint("principal less the payout", BIG - payout);
        emit log_named_uint("bob share value after", bobCash);
        emit log_named_uint("bob tokA worth", _claimable(bob, address(tokA)) / 2e12);
        emit log_named_uint("attacker start (USDC terms)", attackerStart);
        emit log_named_uint("attacker end (USDC terms)", attackerEnd);

        assertLt(attackerEnd, attackerStart, "the attacker ends below its start: it pays the fee and bob's slice of the pot");
        assertGe(bobCash + _claimable(bob, address(tokA)) / 2e12, LP_CASH, "and bob ends at or above his deposit");
    }
}
