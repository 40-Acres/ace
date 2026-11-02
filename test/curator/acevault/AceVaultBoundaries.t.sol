// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.36;

import {LoanClosed} from "../../../src/ace/hub/Borrower.sol";
import {LoanMath} from "../../../src/ace/hub/libraries/LoanMath.sol";
import {MarketParams} from "../../../src/ace/hub/Types.sol";
import {AceVaultFlows} from "../../../src/curator/AceVaultFlows.sol";
import {CuratorVault} from "../../../src/curator/CuratorVault.sol";
import {_extended} from "../../utils/Extended.sol";
import {AceVaultRig} from "./AceVaultRig.sol";

/// @notice The core's edges on the shipped CuratorVault: a placement exactly at lendable, the market's cash cap, a closed loan's extension.
/// @dev Each row sits on the boundary a comparison draws, so a strict test turned non-strict, or a dropped leg, fails here.
contract AceVaultBoundariesTest is AceVaultRig {
    address internal lp2 = address(0x1F2);

    /// @dev A fresh vault on the rig's row, holding exactly `cash` of one LP's deposit and nothing else.
    function _seeded(uint256 cash) internal returns (CuratorVault v) {
        v = _newVault(_row(address(record), type(uint192).max));
        usdc.mint(lp2, cash);
        vm.startPrank(lp2);
        usdc.approve(address(v), cash);
        v.deposit(cash, lp2);
        vm.stopPrank();
    }

    /// @dev Borrow on `v` as `who`, minted and approving exactly the units.
    function _borrowOn(CuratorVault v, address who, uint256 principal) internal returns (uint256 loanId) {
        coll.mint(who, UNITS);
        vm.startPrank(who);
        coll.approve(address(v), UNITS);
        loanId = v.borrow(_req(UNITS, principal, MAX_TENOR), "", "");
        vm.stopPrank();
    }

    // ---- the placement against lendable ----

    /// @notice A draw of exactly lendable is admitted and leaves idle at zero: the door books nothing beside the principal.
    function test_ADrawExactlyAtLendableLeavesIdleAtZero() public {
        CuratorVault v = _seeded(PRINCIPAL);
        assertEq(v.lendable(), PRINCIPAL, "premise: every unit of the fresh vault is lendable");
        uint256 loanId = _borrowOn(v, borrower, PRINCIPAL);
        assertEq(v.idle(), 0, "the door lent every idle unit");
        assertEq(v.lendable(), 0, "and nothing is left to place");
        assertEq(ace.restingOf(ace.loanMarket(loanId)), 0, "nothing rests");
    }

    /// @notice One unit past lendable the draw is refused, pulling nothing; exactly lendable fits.
    function test_ADrawOneUnitPastLendableIsRefused() public {
        CuratorVault v = _seeded(PRINCIPAL - 1);
        coll.mint(borrower, UNITS);
        vm.startPrank(borrower);
        coll.approve(address(v), UNITS);
        vm.expectRevert(AceVaultFlows.OverLendable.selector);
        v.borrow(_req(UNITS, PRINCIPAL, MAX_TENOR), "", "");
        vm.stopPrank();
        assertEq(coll.balanceOf(address(v)), 0, "the refusal pulled nothing");
        uint256 loanId = _borrowOn(v, borrower, PRINCIPAL - 1);
        assertTrue(ace.isLiveLoan(loanId), "CONTROL: the draw of exactly lendable fits");
    }

    // ---- the market's cash cap ----

    /// @notice A vault holding more than a market can rest still lends: the rest stops at the market's cash cap, and every unit comes home.
    function test_AVaultPastTheMarketsCashCapStillLends() public {
        deal(address(usdc), address(vault), uint256(type(uint128).max) + LP_CASH);
        uint256 idle0 = vault.idle();
        uint256 loanId = _borrow(MIN_TENOR);
        assertEq(vault.idle(), idle0 - PRINCIPAL, "idle fell by the principal alone: the unrested tail and the rest both came home");
        _assertNothingRests(_mid(loanId));
        _assertNoAllowances();
    }

    // ---- a closed loan's extension ----

    /// @notice A loan repaid in full refuses its holder's extension `LoanClosed`, with no cash rested.
    function test_ARepaidLoanIsRefusedBeforeAnyRest() public {
        uint256 loanId = _borrow(MIN_TENOR);
        _repayAs(borrower, loanId, ace.debtOf(loanId));
        _toWindow(loanId);
        uint256 idle0 = vault.idle();
        vm.expectCall(address(ace), abi.encodeWithSelector(ace.deposit.selector), 0);
        vm.prank(borrower);
        vm.expectRevert(LoanClosed.selector);
        ace.extend(loanId, 0, "");
        assertEq(vault.idle(), idle0, "and no cash moved");
    }

    // ---- CuratorVault's own legs at their edges ----

    /// @notice The price leg admits a record exactly at the market's price: the extension lands, and the hub's preview agrees on both sides of it.
    function test_ARecordExactlyAtThePriceStillExtends() public {
        uint256 loanId = _borrow(MIN_TENOR);
        MarketParams memory mp = _mp(loanId);
        _toWindow(loanId);
        record.setMinPrice(mp.price - 1);
        (bool price,,) = ace.tryExtend(loanId, 0, "", borrower);
        assertFalse(price, "CONTROL: one atom under, the vault would not lend");
        record.setMinPrice(mp.price);
        (bool p2,,) = ace.tryExtend(loanId, 0, "", borrower);
        assertTrue(p2, "at the price both legs answer yes");
        uint64 expiry = read.loan(loanId).expiry;
        uint256 fee = LoanMath.originationFee(ace.debtOf(loanId), MIN_TENOR, mp.baseBps, mp.minTenor);
        usdc.mint(borrower, fee);
        vm.startPrank(borrower);
        usdc.approve(address(ace), fee);
        ace.extend(loanId, 0, "");
        vm.stopPrank();
        assertTrue(_extended(read, loanId, expiry), "and the extension lands");
    }

    /// @notice A request naming no tenor opens at the row's shortest.
    function test_AZeroTenorTakesTheRowsShortest() public {
        uint256 loanId = _borrowAs(borrower, UNITS, PRINCIPAL, 0);
        assertEq(read.loan(loanId).tenor, MIN_TENOR, "the loan runs the row's shortest term");
    }

    /// @notice A record answering nothing, or a price the buffer drops under the grid, is refused `PriceZero` before anything moves.
    function test_NoPriceIsRefusedByName() public {
        uint256[2] memory mins = [uint256(0), 1];
        for (uint256 i; i < 2; i++) {
            record.setMinPrice(mins[i]);
            coll.mint(bob, UNITS);
            vm.startPrank(bob);
            coll.approve(address(vault), UNITS);
            vm.expectRevert(CuratorVault.PriceZero.selector);
            vault.borrow(_req(UNITS, PRINCIPAL, MIN_TENOR), "", "");
            vm.stopPrank();
        }
        assertEq(coll.balanceOf(address(vault)), 0, "nothing was pulled");
    }
}
