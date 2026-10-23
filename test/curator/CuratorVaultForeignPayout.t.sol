// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.36;

import {CuratorVaultBase} from "./CuratorVaultBase.sol";
import {CuratorVault} from "../../src/curator/CuratorVault.sol";
import {MarketParams} from "../../src/ace/hub/Types.sol";
import {AceFixtures} from "../utils/AceFixtures.sol";

/// @title CuratorVaultForeignPayout
/// @notice Ruling (d) on #381: a third party naming the vault as a hub exit's recipient makes a COUNTED donation, accepted.
/// @notice The payout lands in the vault's own balance, which NAV counts: gross NAV rises by the amount.
/// @notice `totalAssets` does not rise with it: the vest defers the gain, and it is spendable only once the window runs.
/// @dev Three doors reach it: `withdraw` and `collect`, whose `to` is #381's, and `claimOwed`, which predates them.
/// @dev The defence is the one ERC-4626 vaults already rely on against a donation: the virtual offset, plus this vault's vest.
/// @dev Reasoning: the design record.
contract CuratorVaultForeignPayoutTest is CuratorVaultBase {
    uint256 internal constant EACH = 10_000e6; // the LP's stake, so the vault has a share price to defend
    uint256 internal constant GIFT = 1_000e6; // what the donor rests in its own market before paying it out
    uint256 internal constant P = 100e6; // a draw against the donor's market
    uint256 internal constant R = 40e6; // a partial repay, leaving the debt above the market's `minDebt`

    address internal donor = address(0xD0D0);

    CuratorVault internal v;
    bytes32 internal own; // a market the donor creates in the vault's asset, naming itself its one lender

    function setUp() public override {
        super.setUp();
        v = _newVault(0);
        _lpDeposit(v, alice, EACH);
        MarketParams memory p = AceFixtures.marketParams(address(usdc), address(collateral));
        p.lender = donor;
        own = ace.createMarket(p); // permissionless, and the vault never lends in it
        _lendDirectIn(donor, own, GIFT);
    }

    /// @notice PREMISE: the donor's own deposit moves no vault NAV.
    function test_Premise_AForeignDepositAloneMovesNoNav() public view {
        assertEq(ace.idToMarketParams(own).lender, donor, "PREMISE: the donor is its one lender");
        assertEq(v.grossNav(), EACH, "the vault's gross is its LP stake alone");
        assertEq(v.totalAssets(), EACH, "and nothing is deferred");
    }

    /// @notice `withdraw(own, max, vault, 0)`: the donor's resting cash joins the vault's counted NAV, and the vest defers it.
    function test_AForeignWithdrawToTheVaultIsACountedDonation_Deferred() public {
        (uint256 g0, uint256 t0, uint256 bal0) = (v.grossNav(), v.totalAssets(), usdc.balanceOf(address(v)));
        vm.prank(donor);
        uint256 paid = ace.withdraw(own, type(uint256).max, address(v), 0);
        assertEq(paid, GIFT, "the donor's whole resting balance paid out");
        assertEq(usdc.balanceOf(address(v)) - bal0, paid, "into the vault's own balance");
        _assertCountedAndDeferred(g0, t0, paid);
    }

    /// @notice `collect(asset, vault)`: the donor's pooled credit joins the vault's counted NAV, and the vest defers it.
    function test_AForeignCollectToTheVaultIsACountedDonation_Deferred() public {
        uint256 loanId = _openIn(own, P);
        _repay(loanId, R); // partial: the credit pools for the donor and nothing closes, so nothing is pushed
        uint256 owed = ace.lenderOwed(donor, address(usdc));
        (uint256 g0, uint256 t0, uint256 bal0) = (v.grossNav(), v.totalAssets(), usdc.balanceOf(address(v)));
        vm.prank(donor);
        uint256 paid = ace.collect(address(usdc), address(v));
        assertEq(paid, owed, "the donor's whole pool paid out");
        assertEq(usdc.balanceOf(address(v)) - bal0, paid, "into the vault's own balance");
        _assertCountedAndDeferred(g0, t0, paid);
    }

    /// @notice `claimOwed(loanId, vault)`: a borrower's close refund joins the vault's counted NAV. PREDATES #381.
    /// @dev The same row, less the two #381 doors, passes on the parent commit of the #381 branch.
    function test_ABorrowersClaimOwedToTheVaultIsACountedDonation_Deferred() public {
        uint256 loanId = _openIn(own, P);
        _repay(loanId, read.debtOf(loanId)); // an early close credits the unearned escrow back to the borrower
        (, uint256 refund) = ace.owedOf(loanId, borrower);
        (uint256 g0, uint256 t0, uint256 bal0) = (v.grossNav(), v.totalAssets(), usdc.balanceOf(address(v)));
        vm.prank(borrower);
        (, uint256 paid) = ace.claimOwed(loanId, address(v));
        assertEq(paid, refund, "the borrower's whole quote credit paid out");
        assertEq(usdc.balanceOf(address(v)) - bal0, paid, "into the vault's own balance");
        _assertCountedAndDeferred(g0, t0, paid);
    }

    /// @notice TWO DUST DONATIONS BEFORE THE FIRST DEPOSIT CANNOT BRICK ENTRY: the deferral is all of a dust gross, never past it.
    /// @dev Both vest roundings CEIL, so the second stamp would read a wei past the gross; the pending pile is capped at the gross.
    /// @dev `totalAssets` is then exactly zero; were the pile to pass the gross, the read would floor or underflow.
    /// @dev Any dust transfer is counted, so this cap is what keeps a stranger's dust from bricking the first entry.
    function test_TwoDustDonationsBeforeTheFirstDepositCannotBrickEntry() public {
        CuratorVault w = _newVault(0);

        vm.prank(donor);
        ace.withdraw(own, 1_000, address(w), 0); // the donor's market from setUp, in the same asset
        w.crank(); // the first dust stamps a pile that IS the whole gross
        _warpBy(1);
        vm.prank(donor);
        ace.withdraw(own, 1_000, address(w), 0);

        assertEq(w.grossNav(), 2_000, "PREMISE: two dust payouts are the vault's whole gross");
        assertEq(w.totalAssets(), 0, "the pending deferral is all of the dust gross, so NAV reads zero");
        uint256 shares = _lpDeposit(w, alice, EACH);
        assertEq(shares, EACH * 1e6, "and the first depositor entered at the virtual price, unbricked");
    }

    /// @dev Gross rises by the whole payout at once; `totalAssets` holds until a sync stamps the rise and the window runs.
    function _assertCountedAndDeferred(uint256 g0, uint256 t0, uint256 amount) internal {
        assertEq(t0, g0, "premise: nothing was deferred before the payout");
        assertGt(amount, 0, "premise: a payout to count");
        assertEq(v.grossNav(), g0 + amount, "COUNTED: gross NAV rose by exactly the payout");
        assertEq(v.totalAssets(), t0, "DEFERRED: the rise is not spendable in the block it landed");
        v.crank(); // any verb syncs; this one is permissionless and moves nothing of its own here
        assertEq(v.totalAssets(), t0, "still deferred once a sync has stamped it");
        _warpBy(VEST_W);
        assertEq(v.totalAssets(), t0 + amount, "and wholly recognized once the vest window has run");
    }
}
