// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.36;

import {InKindRig} from "../../inkind/InKindRig.sol";
import {Quote} from "../../inkind/InKindSurface.sol";

/// @title Suite_InKindTwoDenominators
/// @notice RS-1 PoC, flipped to assert the fix: in kind one default is booked over ONE supply, its NAV loss and its pot both over every tracked share.
/// @notice A share that entered within one MIN_TENOR of the collect pays its pro-rata part of the loss and is credited its pro-rata part of the pot.
contract Suite_InKindTwoDenominators is InKindRig {
    uint256 internal constant P = 100_000e6; // a loan of a tenth or less of the vault
    uint256 internal constant BIG_UNITS = 400_000e18; // the recordless line is about 280,000 units at 0.5 USDC

    /// @dev A loan of P against tokA on a fresh appraiser quote, for `tenor`.
    function _loan(uint64 tenor) internal returns (uint256) {
        Quote memory q = _quote(address(tokA), PRICE);
        q.maxPrincipal = P;
        return _borrowWith(q, _data(q), BIG_UNITS, P, tenor);
    }

    /// @dev What `who`'s shares are worth now.
    function _worth(address who) internal view returns (uint256) {
        return vault.previewRedeem(vault.balanceOf(who));
    }

    /// @dev The pot units' worth at the loan's own 0.5 USDC: half the 18-decimal units, scaled to 6 decimals.
    function _atLoanPrice(uint256 units) internal pure returns (uint256) {
        return units / 2e12;
    }

    /// @notice (a) One default, one denominator: bob, in for the loan's last MIN_TENOR, loses the fall times sb / S and is credited the pot times sb / S.
    function test_RS1a_oneDefaultIsBookedOverOneSupply() public {
        uint256 sa = _lp(alice, LP_CASH);
        uint256 sc = _lp(carol, LP_CASH);
        _warpBy(MIN_TENOR);
        _nextBlock();
        uint256 loanId = _loan(MIN_TENOR);
        _warpBy(1 hours);
        _nextBlock();
        uint256 sb = _lp(bob, LP_CASH);
        _toExpiry(loanId);
        _nextBlock();

        uint256 supply = vault.totalSupply();
        uint256 navBefore = vault.totalAssets();
        uint256 bobBefore = _worth(bob);
        uint256 pot = _collect(loanId);
        _nextBlock();
        uint256 fall = navBefore - vault.totalAssets();
        uint256 bobLoss = bobBefore - _worth(bob);

        emit log_named_uint("claim P", P);
        emit log_named_uint("NAV fall at the collect", fall);
        emit log_named_uint("supply S at the collect", supply);
        emit log_named_uint("pot units", pot);
        emit log_named_uint("pot worth at the loan's price", _atLoanPrice(pot));
        emit log_named_uint("bob's NAV loss", bobLoss);
        emit log_named_uint("bob's credit", _claimable(bob, address(tokA)));
        emit log_named_uint("bob's credit at the loan's price", _atLoanPrice(_claimable(bob, address(tokA))));

        uint256 held = supply - vault.SEED_SHARES(); // the seed sits on the vault, untracked like a gift: its slice of the pot goes to the holders
        assertApproxEqRel(fall, P, 0.01e18, "the NAV falls by about the claim");
        assertApproxEqAbs(bobLoss, fall * sb / supply, 2, "the loss reaches bob over every share");
        assertApproxEqAbs(_claimable(bob, address(tokA)), pot * sb / held, 2, "and so does the pot");
        assertApproxEqAbs(_claimable(alice, address(tokA)), pot * sa / held, 2, "alice takes units * s_a / S");
        assertApproxEqAbs(_claimable(carol, address(tokA)), pot * sc / held, 2, "carol takes units * s_c / S");
        assertEq(_trackedSupply(), held, "the batch closed on every share but the seed's");
    }

    /// @notice (b) On a loan longer than MIN_TENOR, dave in its first hour and bob inside its last MIN_TENOR both pay and are credited pro rata.
    function test_RS1b_aShareEnteringInsideTheLastMinTenorSharesThePot() public {
        uint256 sa = _lp(alice, LP_CASH);
        _warpBy(MIN_TENOR);
        _nextBlock();
        uint256 loanId = _loan(ROW_MAX_TENOR);
        _warpBy(1 hours);
        _nextBlock();
        uint256 sd = _lp(dave, LP_CASH);
        _warpAtLeastTo(_expiry(loanId) - 3 days);
        _nextBlock();
        uint256 sb = _lp(bob, LP_CASH);
        _toExpiry(loanId);
        _nextBlock();

        uint256 supply = vault.totalSupply();
        uint256 navBefore = vault.totalAssets();
        uint256 daveBefore = _worth(dave);
        uint256 bobBefore = _worth(bob);
        uint256 pot = _collect(loanId);
        _nextBlock();
        uint256 fall = navBefore - vault.totalAssets();

        emit log_named_uint("loan tenor", ROW_MAX_TENOR);
        emit log_named_uint("MIN_TENOR", MIN_TENOR);
        emit log_named_uint("NAV fall at the collect", fall);
        emit log_named_uint("dave's NAV loss", daveBefore - _worth(dave));
        emit log_named_uint("bob's NAV loss", bobBefore - _worth(bob));
        emit log_named_uint("dave's credit", _claimable(dave, address(tokA)));
        emit log_named_uint("bob's credit", _claimable(bob, address(tokA)));

        uint256 held = supply - vault.SEED_SHARES(); // the seed sits on the vault, untracked like a gift: its slice of the pot goes to the holders
        assertApproxEqAbs(daveBefore - _worth(dave), fall * sd / supply, 2, "dave pays his pro-rata part of the loss");
        assertApproxEqAbs(bobBefore - _worth(bob), fall * sb / supply, 2, "bob pays his pro-rata part of the loss");
        assertApproxEqAbs(_claimable(dave, address(tokA)), pot * sd / held, 2, "dave shares the pot pro rata");
        assertApproxEqAbs(_claimable(bob, address(tokA)), pot * sb / held, 2, "and so does bob, inside the last MIN_TENOR");
        assertApproxEqAbs(_claimable(alice, address(tokA)), pot * sa / held, 2, "and alice");
        assertEq(_trackedSupply(), held, "the batch closed on every share but the seed's");
    }

    /// @notice (c) The control: carol, entering before the loan opened, shares the pot as alice does.
    function test_RS1c_controlAnEntrantBeforeTheLoanSharesThePot() public {
        uint256 sa = _lp(alice, LP_CASH);
        _warpBy(MIN_TENOR);
        _nextBlock();
        uint256 sc = _lp(carol, LP_CASH);
        _warpBy(1 hours);
        _nextBlock();
        uint256 loanId = _loan(MIN_TENOR);
        _toExpiry(loanId);
        _nextBlock();

        uint256 supply = vault.totalSupply();
        uint256 navBefore = vault.totalAssets();
        uint256 carolBefore = _worth(carol);
        uint256 pot = _collect(loanId);
        _nextBlock();
        uint256 fall = navBefore - vault.totalAssets();

        emit log_named_uint("NAV fall at the collect", fall);
        emit log_named_uint("carol's NAV loss", carolBefore - _worth(carol));
        emit log_named_uint("carol's credit", _claimable(carol, address(tokA)));

        assertEq(supply, sa + sc + vault.SEED_SHARES(), "premise: alice, carol and the seed are the whole supply");
        assertApproxEqAbs(carolBefore - _worth(carol), fall * sc / supply, 2, "carol pays her pro-rata part of the loss");
        assertApproxEqAbs(_claimable(carol, address(tokA)), pot * sc / (sa + sc), 2, "and is credited her pro-rata part of the pot");
    }
}
