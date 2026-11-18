// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.36;

import {InKindRig} from "../../inkind/InKindRig.sol";
import {Quote} from "../../inkind/InKindSurface.sol";

/// @title Review_HourGrainFunder
/// @notice Krait review of ACV-1, flipped to assert the fix: with no vesting clock, a MIN_TENOR loan's funder from its own hour shares the pot at expiry.
/// @notice carol deposits in the loan's clock hour, before it opens; a collect at the expiry second credits her pro rata, as one an hour later does.
contract Review_HourGrainFunder is InKindRig {
    uint256 internal constant P = 100_000e6;
    uint256 internal constant BIG_UNITS = 400_000e18;

    struct Seen {
        uint256 pot;
        uint256 fall;
        uint256 supply;
        uint256 carolLoss;
        uint256 carolCredit;
    }

    function _worth(address who) internal view returns (uint256) {
        return vault.previewRedeem(vault.balanceOf(who));
    }

    /// @dev alice deposits; carol deposits ten minutes into an hour; the loan opens thirty minutes later in that same hour, for one MIN_TENOR.
    function _stage() internal returns (uint256 loanId, uint256 sa, uint256 sc) {
        sa = _lp(alice, LP_CASH);
        _warpBy(MIN_TENOR);
        _nextBlock();
        _warpBy(10 minutes);
        _nextBlock();
        sc = _lp(carol, LP_CASH);
        _warpBy(30 minutes);
        _nextBlock();
        Quote memory q = _quote(address(tokA), PRICE);
        q.maxPrincipal = P;
        loanId = _borrowWith(q, _data(q), BIG_UNITS, P, MIN_TENOR);
    }

    /// @dev Collect `loanId` now and read what carol carried and was credited.
    function _collectAndRead(uint256 loanId) internal returns (Seen memory z) {
        z.supply = vault.totalSupply();
        uint256 carolBefore = _worth(carol);
        uint256 navBefore = vault.totalAssets();
        z.pot = _collect(loanId);
        _nextBlock();
        z.fall = navBefore - vault.totalAssets();
        z.carolLoss = carolBefore - _worth(carol);
        z.carolCredit = _claimable(carol, address(tokA));
    }

    uint256 internal constant SEED = 10_000e6; // the attacker's whole stake
    uint256 internal constant BIG = 400_000e6;
    uint256 internal constant BIG_LOT = 1_200_000e18; // fully collateralised at the appraised 0.5 USDC

    /// @notice The manufactured form no longer pays: a small holder borrows a fresh LP's deposit in the same clock hour and defaults on it.
    /// @notice carol funds the loan and is credited her pro-rata slice of the pot at its expiry second; the attacker ends below its start.
    function test_Review_aSmallHolderCannotTakeAFreshDepositsPrincipal() public {
        uint256 sa = _lp(alice, SEED);
        _warpBy(MIN_TENOR);
        _nextBlock();
        _warpBy(10 minutes);
        _nextBlock();
        uint256 sc = _lp(carol, LP_CASH);
        _warpBy(30 minutes);
        _nextBlock();
        Quote memory q = _quote(address(tokA), PRICE);
        q.maxPrincipal = BIG;
        uint256 loanId = _borrowWith(q, _data(q), BIG_LOT, BIG, MIN_TENOR);
        uint256 payout = usdc.balanceOf(borrower);
        _toExpiry(loanId);
        _nextBlock();
        uint256 pot = _collect(loanId);
        _nextBlock();
        uint256 aliceTok = _claim(alice, address(tokA));
        vm.prank(borrower);
        (uint256 excess,) = ace.claimOwed(loanId, borrower);

        uint256 attackerStart = SEED + BIG_LOT / 2e12;
        uint256 attackerEnd = _worth(alice) + payout + (aliceTok + excess) / 2e12;
        uint256 carolEnd = vault.previewRedeem(sc) + _claimable(carol, address(tokA)) / 2e12;
        emit log_named_uint("pot units", pot);
        emit log_named_uint("payout kept by the borrowing address", payout);
        emit log_named_uint("carol's deposit", LP_CASH);
        emit log_named_uint("carol's share value after", vault.previewRedeem(sc));
        emit log_named_uint("carol's tokA credit", _claimable(carol, address(tokA)));
        emit log_named_uint("carol's end (USDC terms)", carolEnd);
        emit log_named_uint("attacker start (USDC terms)", attackerStart);
        emit log_named_uint("attacker end (USDC terms)", attackerEnd);

        assertApproxEqAbs(aliceTok, pot * sa / (sa + sc), 2, "the attacker takes only its pro-rata slice of the pot");
        assertApproxEqAbs(_claimable(carol, address(tokA)), pot * sc / (sa + sc), 2, "carol, who funded the loan, is credited hers");
        assertLt(attackerEnd, attackerStart, "the attacker ends below its start");
        assertGt(carolEnd, LP_CASH, "carol ends above her deposit: the pot pays back more than the loss she carried");
    }

    /// @notice A funder in the loan's own clock hour is credited pro rata at the expiry second, the same as a collect an hour later.
    function test_Review_aFunderInTheLoansOwnHourSharesThePotAtItsExpiry() public {
        (uint256 loanId, uint256 sa, uint256 sc) = _stage();
        _toExpiry(loanId);
        _nextBlock();
        uint256 snap = vm.snapshotState();
        Seen memory prompt = _collectAndRead(loanId); // at the expiry second, the curator's stated duty
        vm.revertToState(snap);
        _warpBy(1 hours);
        _nextBlock();
        Seen memory late = _collectAndRead(loanId); // the same collect after the next hour boundary

        emit log_named_uint("pot units", prompt.pot);
        emit log_named_uint("NAV fall at the collect", prompt.fall);
        emit log_named_uint("carol's NAV loss, prompt collect", prompt.carolLoss);
        emit log_named_uint("carol's credit, prompt collect", prompt.carolCredit);
        emit log_named_uint("carol's NAV loss, collect an hour later", late.carolLoss);
        emit log_named_uint("carol's credit, collect an hour later", late.carolCredit);

        assertApproxEqAbs(prompt.carolLoss, prompt.fall * sc / prompt.supply, 2, "carol carries her pro-rata part of the loss");
        uint256 held = sa + sc; // the tracked supply: the genesis seed is untracked, so its slice of the pot goes to the holders
        assertApproxEqAbs(prompt.carolCredit, prompt.pot * sc / held, 2, "and is credited her pro-rata part of the pot at the expiry second");
        assertEq(late.pot, prompt.pot, "premise: the same pot either way");
        assertApproxEqAbs(prompt.carolCredit, late.carolCredit, 2, "the same as a collect an hour later");
        assertEq(_trackedSupply(), sa + sc, "the batch closed on every share");
    }
}
