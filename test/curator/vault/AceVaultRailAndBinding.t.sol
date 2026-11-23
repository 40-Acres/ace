// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.36;

import {PolicyRefused} from "../../../src/ace/hub/Borrower.sol";
import {Loan, MarketParams} from "../../../src/ace/hub/Types.sol";
import {AceVaultCaps, ProductConfig} from "../../../src/vault/libraries/AceVaultCaps.sol";
import {BorrowRequest, Terms} from "../../../src/vault/libraries/AceVaultFlows.sol";
import {Extension, IRollPolicy} from "../../../src/interfaces/IRollPolicy.sol";
import {IAceVaultLens, VaultLens} from "../../utils/VaultLens.sol";
import {AceVaultBaseRig} from "./AceVaultBaseRig.sol";

/// @title AceVaultRailAndBindingTest
/// @notice F2 and F6 hardening at their boundaries: each end of the tenor rail admits and one past refuses, for the market, the draw and the extension.
/// @notice The draw is bound to the ask: under it lands at the product's figures, an asked term must be named back, and the exit gate admits at exact cover.
contract AceVaultRailAndBindingTest is AceVaultBaseRig {
    bytes4 internal constant YES = IRollPolicy.admitsExtension.selector;

    /// @dev The rig market widened to the whole rail, so a draw may sit at either end.
    function _railMarket() internal view returns (MarketParams memory p) {
        p = _market(address(coll), record);
        (p.minTenor, p.maxTenor) = (RAIL_MIN, RAIL_MAX);
    }

    /// @dev Borrow the rig's ask with term `askTenor`, the product answering `t` on market `p`.
    function _borrowWith(MarketParams memory p, Terms memory t, uint64 askTenor) internal returns (uint256 loanId) {
        terms.setTerms(p, t);
        coll.mint(borrower, UNITS);
        vm.startPrank(borrower);
        coll.approve(address(vault), UNITS);
        loanId = vault.borrow(_req(address(coll), UNITS, PRINCIPAL, askTenor), "", "");
        vm.stopPrank();
    }

    function _t(uint64 tenor) internal pure returns (Terms memory) {
        return Terms({units: UNITS, principal: PRINCIPAL, tenor: tenor, minBufferWad: 0});
    }

    // ---- the rail's two ends, for the market and the draw ----

    /// @notice A market spanning exactly the rail, drawn at its floor, lands with that term.
    function test_rail_ADrawAtTheRailsFloorLands() public {
        uint256 loanId = _borrowWith(_railMarket(), _t(RAIL_MIN), 0);
        assertEq(read.loan(loanId).tenor, RAIL_MIN, "the draw at the rail's floor did not land at it");
    }

    /// @notice A market spanning exactly the rail, drawn at its ceiling, lands with that term.
    function test_rail_ADrawAtTheRailsCeilingLands() public {
        uint256 loanId = _borrowWith(_railMarket(), _t(RAIL_MAX), 0);
        assertEq(read.loan(loanId).tenor, RAIL_MAX, "the draw at the rail's ceiling did not land at it");
    }

    /// @notice A zero term draws the market's shortest, and the rail judges that term.
    function test_rail_AZeroTermDrawsTheMarketsShortest() public {
        MarketParams memory p = _railMarket();
        p.minTenor = 3 days;
        uint256 loanId = _borrowWith(p, _t(0), 0);
        assertEq(read.loan(loanId).tenor, 3 days, "a zero term did not draw the market's shortest");
    }

    /// @notice A rail whose two ends meet is not crossed: a vault on a single-term rail deploys and lends at that term.
    function test_rail_AVaultOnASingleTermRailDeploysAndLends() public {
        ProductConfig memory pc = _pc();
        (pc.minTenor, pc.maxTenor) = (TENOR, TENOR);
        (vault, terms) = _deploy(_cfg(), pc, _caps(UNCAPPED, 0, UNCAPPED));
        _lp(alice, LP_CASH);
        assertEq(vault.MIN_TENOR(), vault.MAX_TENOR(), "the single-term rail did not stand");
        uint256 loanId = _borrowWith(_market(address(coll), record), _t(TENOR), 0);
        assertEq(read.loan(loanId).tenor, TENOR, "the single-term vault did not lend at its term");
    }

    /// @notice `previewTerms` refuses a market past the rail as the door would.
    function test_rail_PreviewTermsRefusesAMarketPastTheRail() public {
        MarketParams memory p = _railMarket();
        p.maxTenor = RAIL_MAX + 1;
        terms.setTerms(p, _t(RAIL_MIN));
        IAceVaultLens lens = VaultLens.deploy();
        vm.expectRevert(AceVaultCaps.TenorOutOfRail.selector);
        lens.previewTerms(address(vault), borrower, _req(address(coll), UNITS, PRINCIPAL, 0), "");
    }

    // ---- the binding to the ask ----

    /// @notice An asked term the product names back lands at that term.
    function test_bind_AnAskedTermNamedBackLands() public {
        uint256 loanId = _borrowWith(_railMarket(), _t(2 * TENOR), 2 * TENOR);
        assertEq(read.loan(loanId).tenor, 2 * TENOR, "the asked term did not land");
    }

    /// @notice An asked term must be NAMED BACK: a product answering zero is refused, even where zero would draw the same term.
    function test_bind_AnAskedTermLeftAtZeroIsRefused() public {
        MarketParams memory p = _market(address(coll), record);
        terms.setTerms(p, _t(0));
        coll.mint(borrower, UNITS);
        vm.startPrank(borrower);
        coll.approve(address(vault), UNITS);
        BorrowRequest memory r = _req(address(coll), UNITS, PRINCIPAL, TENOR);
        vm.expectRevert(AceVaultCaps.TenorNotAsked.selector);
        vault.borrow(r, "", "");
        vm.stopPrank();
    }

    /// @notice A draw under the ask lands at the PRODUCT'S figures: only its units are pulled, and the loan carries its principal.
    function test_bind_ADrawUnderTheAskLandsAtTheProductsFigures() public {
        terms.setTerms(_market(address(coll), record), Terms({units: UNITS / 2, principal: PRINCIPAL / 2, tenor: 0, minBufferWad: 0}));
        coll.mint(borrower, UNITS);
        vm.startPrank(borrower);
        coll.approve(address(vault), UNITS);
        uint256 cash0 = usdc.balanceOf(borrower);
        uint256 loanId = vault.borrow(_req(address(coll), UNITS, PRINCIPAL, 0), "", "");
        vm.stopPrank();
        Loan memory l = read.loan(loanId);
        assertEq(l.collateralUnits, UNITS / 2, "the loan pledged other than the product's units");
        assertEq(coll.balanceOf(borrower), UNITS - UNITS / 2, "the door pulled more than the product's units");
        assertEq(coll.allowance(borrower, address(vault)), UNITS - UNITS / 2, "the door spent more allowance than the product's units");
        assertLe(usdc.balanceOf(borrower) - cash0, PRINCIPAL / 2, "the borrower was paid more than the product's principal");
        assertGt(usdc.balanceOf(borrower) - cash0, 0, "the borrower was paid nothing");
    }

    // ---- the extension's rail ----

    /// @notice An extension whose new term ends exactly at the rail's ceiling from now is a yes; a second past is a no.
    function test_consent_ANewTermExactlyAtTheRailIsAYes() public {
        Extension memory e = _ext(_borrow());
        e.newExpiry = uint64(_now()) + RAIL_MAX;
        assertEq(vault.admitsExtension(e, ""), YES, "a new term exactly at the rail was refused");
        e.newExpiry += 1;
        assertEq(vault.admitsExtension(e, ""), bytes4(0), "a new term a second past the rail was consented to");
    }

    /// @notice A market spanning exactly the rail is a yes; one past at either end is a no.
    function test_consent_AMarketExactlyOnTheRailIsAYes() public {
        Extension memory e = _ext(_borrow());
        (e.dst.minTenor, e.dst.maxTenor) = (RAIL_MIN, RAIL_MAX);
        assertEq(vault.admitsExtension(e, ""), YES, "a market exactly on the rail was refused");
        e.dst.minTenor = RAIL_MIN - 1;
        assertEq(vault.admitsExtension(e, ""), bytes4(0), "a market a second under the rail was consented to");
        (e.dst.minTenor, e.dst.maxTenor) = (RAIL_MIN, RAIL_MAX + 1);
        assertEq(vault.admitsExtension(e, ""), bytes4(0), "a market a second over the rail was consented to");
    }

    /// @notice An extension naming another lender, or asked of a draining vault, is a no.
    function test_consent_AForeignLenderOrADrainIsANo() public {
        Extension memory e = _ext(_borrow());
        assertEq(vault.admitsExtension(e, ""), YES, "premise: the extension as built is a yes");
        e.dst.lender = stranger;
        assertEq(vault.admitsExtension(e, ""), bytes4(0), "an extension into another lender's market was consented to");
        e.dst.lender = address(vault);
        vm.prank(guardian);
        vault.setDrain(true);
        assertEq(vault.admitsExtension(e, ""), bytes4(0), "a draining vault consented to an extension");
    }

    // ---- the exit gate ----

    /// @notice AN UNCOVERED REQUEST refuses a lengthening, and never an extension that adds no time: the gate guards only a longer wait.
    function test_gate_AnUncoveredRequestRefusesOnlyALengthening() public {
        uint256 loanId = _borrow();
        uint256 shares = vault.balanceOf(alice);
        vm.prank(alice);
        vault.requestExit(shares);
        _warpBy(1 days);
        Extension memory e = _ext(loanId);
        assertGt(e.newExpiry, e.expiry, "premise: the extension lengthens");
        assertGt(vault.previewRedeem(vlens.requestedShares(address(vault))), vault.idle(), "premise: the request outweighs idle");
        assertEq(vault.admitsExtension(e, ""), bytes4(0), "an uncovered request let a lengthening through");
        e.newExpiry = e.expiry;
        assertEq(vault.admitsExtension(e, ""), YES, "an extension adding no time was refused by the exit gate");
        e.newExpiry = e.expiry - 1;
        assertEq(vault.admitsExtension(e, ""), YES, "a shortening was refused by the exit gate");
        _fundFee(borrower);
        vm.prank(borrower);
        vm.expectRevert(PolicyRefused.selector);
        ace.extend(loanId, 0, "");
    }

    /// @notice THE GATE ADMITS AT EXACT COVER: idle one unit short of the requests' worth refuses, idle equal to it admits.
    /// @dev The worth is the claim price at the last sync, read as `previewRedeem` just after the request's own sync; a raw transfer moves idle alone.
    function test_gate_IdleExactlyCoveringTheRequestsAdmits() public {
        uint256 loanId = _borrow();
        _warpBy(1 days);
        uint256 shares = vault.balanceOf(alice);
        vm.prank(alice);
        vault.requestExit(shares);
        uint256 worth = vault.previewRedeem(vlens.requestedShares(address(vault)));
        uint256 idle = vault.idle();
        assertGt(worth, idle, "premise: the request outweighs idle");
        Extension memory e = _ext(loanId);
        usdc.mint(address(vault), worth - idle - 1);
        assertEq(vault.admitsExtension(e, ""), bytes4(0), "idle a unit short of the requests' worth admitted a lengthening");
        usdc.mint(address(vault), 1);
        assertEq(vault.admitsExtension(e, ""), YES, "idle exactly covering the requests' worth refused a lengthening");
    }

    /// @notice A REPAY AND A CRANK lift the gate: the veto is revocable by paying down the shortfall.
    function test_gate_ARepayAndACrankLiftTheGate() public {
        uint256 first = _borrow();
        uint256 second = _borrow();
        _warpBy(1 days);
        uint256 shares = vault.previewWithdraw(vault.idle() + PRINCIPAL / 2);
        vm.prank(alice);
        vault.requestExit(shares);
        uint256 worth = vault.previewRedeem(vlens.requestedShares(address(vault)));
        assertGt(worth, vault.idle(), "premise: the request outweighs idle");
        assertLe(worth, vault.idle() + PRINCIPAL, "premise: one repay covers it");
        assertEq(vault.admitsExtension(_ext(second), ""), bytes4(0), "premise: the gate refuses");
        uint256 debt = read.loan(first).debt;
        usdc.mint(borrower, debt);
        vm.startPrank(borrower);
        usdc.approve(address(ace), debt);
        ace.repay(first, debt);
        vm.stopPrank();
        vault.crank();
        assertEq(vault.admitsExtension(_ext(second), ""), YES, "a repay and a crank did not lift the gate");
    }
}
