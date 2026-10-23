// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.36;

import {Test} from "forge-std/Test.sol";
import {StdInvariant} from "forge-std/StdInvariant.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {Ace} from "../../src/ace/hub/Ace.sol";
import {Loan} from "../../src/ace/hub/Types.sol";
import {PositionManager} from "../../src/ace/positions/PositionManager.sol";
import {AceReader} from "../utils/AceReader.sol";
import {AceHandler} from "./AceHandler.sol";

/// @title AceP10CustodyIdentity
/// @notice The COLLATERAL-side solvency identity, which `AceInvariants` does not state: the custodian's three ledgers
/// @notice against the hub's four (live units, class pots, per-claimant credits, order escrow), per collateral token.
/// @dev The quote side has `_invariant_solvency`; the collateral side had only `balance >= custodiedOf`, one inequality.
/// @dev Three equalities, one per ledger hand-off, so a leak names the hand-off it crossed:
/// @dev   (A) live:    collateralOf[id] == Loan.collateralUnits while the loan is live, and 0 once closed
/// @dev   (B) retired: retiredOf[id]    == sum(invPot[id][t]) + sum(unitsOwed[id][who])
/// @dev   (C) pot:     custodiedOf[T]   == sum over ids on T of (collateralOf + retiredOf), and <= T.balanceOf(custodian)
/// @dev Same handler, same selectors as `AceInvariants`, so the same sequences drive it; a separate campaign so the two
/// @dev never share a first failure. Config mirrors foundry.toml [invariant] (256 x 32) at the gate; iterate smaller.
contract AceP10CustodyIdentityTest is StdInvariant, Test {
    AceHandler internal handler;
    Ace internal ace;
    AceReader internal read;
    PositionManager internal pm;

    function setUp() public {
        handler = new AceHandler();
        handler.baselineSkim();
        ace = handler.ace();
        read = handler.read();
        pm = handler.positionManager();

        bytes4[] memory sel = new bytes4[](25);
        sel[0] = AceHandler.deposit.selector;
        sel[1] = AceHandler.withdraw.selector;
        /// @dev The three receipt verbs are gone and `collect` is the one credit door that replaced them.
        sel[2] = AceHandler.collect.selector;
        sel[3] = AceHandler.redeemInKind.selector;
        sel[4] = AceHandler.depositThenExit.selector;
        sel[5] = AceHandler.open.selector;
        sel[6] = AceHandler.repay.selector;
        sel[7] = AceHandler.withdrawCollateral.selector;
        sel[8] = AceHandler.refinance.selector;
        sel[9] = AceHandler.deleverage.selector;
        sel[10] = AceHandler.setRate.selector;
        sel[11] = AceHandler.buyInventory.selector;
        sel[12] = AceHandler.crashBelow.selector;
        sel[13] = AceHandler.heal.selector;
        sel[14] = AceHandler.forceClose.selector;
        sel[15] = AceHandler.warp.selector;
        sel[16] = AceHandler.sweepRevenue.selector;
        sel[17] = AceHandler.finalize.selector;
        sel[18] = AceHandler.claimOwed.selector;
        sel[19] = AceHandler.transferTitle.selector;
        sel[20] = AceHandler.migrate.selector;
        sel[21] = AceHandler.armPolicy.selector;
        sel[22] = AceHandler.refinanceByPolicy.selector;
        sel[23] = AceHandler.refinanceByPolicies.selector;
        sel[24] = AceHandler.createMarket.selector;
        targetSelector(FuzzSelector({addr: address(handler), selectors: sel}));
        targetContract(address(handler));
    }

    /// @dev Every address the handler ever lets a close or a settlement credit units to.
    /// @dev Borrowers take the residual and the clean-close return; the keeper takes the settle sliver.
    /// @dev The handler itself cranks the ctor's baseline fold unpranked, so it holds that one sliver.
    function _claimants() internal view returns (address[4] memory) {
        return [handler.borrowers(0), handler.borrowers(1), handler.keeper(), address(handler)];
    }

    /// @notice The three custody equalities, per collateral token, over every loan id the hub has issued.
    function invariant_custodyLedgerIdentity() public view {
        address[2] memory toks = [address(handler.vault()), address(handler.vault2())];
        for (uint256 t; t < 2; t++) {
            _checkToken(toks[t]);
        }
    }

    function _checkToken(address tok) internal view {
        uint256 live;
        uint256 retired;
        uint256 n = read.loanCount();
        for (uint256 id = 1; id <= n; id++) {
            Loan memory l = read.loan(id);
            if (l.market == bytes32(0)) continue; // an order id; the handler posts none, so nothing to reconcile
            if (ace.idToMarketParams(l.market).collateral != tok) continue;
            uint256 c = pm.collateralOf(id);
            uint256 r = pm.retiredOf(id);
            if (l.closedAt == 0) {
                assertEq(c, l.collateralUnits, "A: a live loan's custodian ledger != its collateralUnits");
            } else {
                assertEq(c, 0, "A: a closed loan still holds live custody");
                assertEq(l.collateralUnits, 0, "A: a closed loan still carries collateralUnits");
            }
            assertEq(r, _pots(l.market, id) + _owed(id), "B: retiredOf != class pots + claimant credits");
            live += c;
            retired += r;
        }
        assertEq(pm.custodiedOf(tok), live + retired, "C: custodiedOf != sum(collateralOf + retiredOf)");
        assertGe(IERC20(tok).balanceOf(address(pm)), pm.custodiedOf(tok), "C: the pot is under its ledger");
    }

    /// @dev ONE POT PER LOAN, so the per-tick walk is deleted rather than re-pointed: it added the
    /// @dev same number once per funded rung, and the custody identity would have inherited the multiple.
    function _pots(bytes32 m, uint256 id) internal view returns (uint256) {
        return read.invPotOf(m, id);
    }

    /// @dev The per-claimant units-owed ledger SURVIVES: a close or a settlement credits collateral units
    /// @dev to a named address, and `redeemInKind` is a different door taking the loan's pot whole.
    /// @dev So this term is NOT dead by typing the way the quote-side attribution was -- zeroing it here
    /// @dev broke the custody identity by 39750000000499999999705 against 749997356676039159863.
    function _owed(uint256 id) internal view returns (uint256 s) {
        address[4] memory who = _claimants();
        for (uint256 k; k < 4; k++) {
            s += read.unitsOwedOf(id, who[k]);
        }
    }
}
