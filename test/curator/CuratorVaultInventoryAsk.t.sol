// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.36;

import {CuratorVault} from "../../src/curator/CuratorVault.sol";
import {AceVaultFlows, BorrowRequest, Terms} from "../../src/curator/AceVaultFlows.sol";
import {MarketParams} from "../../src/ace/hub/Types.sol";
import {AceFixtures} from "../utils/AceFixtures.sol";
import {CuratorVaultBase} from "./CuratorVaultBase.sol";
import {AceVaultHarness} from "./acevault/AceVaultHarness.sol";

/// @title CuratorVaultInventoryAsk
/// @notice A CuratorVault cannot take a settled pot in kind, so every market its door opens must sell its pots: the ask is on.
/// @dev The door builds the market from the row, so neither the ask nor the fill fee is anybody's to pass.
contract CuratorVaultInventoryAskTest is CuratorVaultBase {
    /// @notice The door's market sells its pots and charges no fill fee, and its id is that market's.
    function test_Door_ForcesTheAskOnWithNoFillFee() public {
        CuratorVault v = _newVault(1000);
        _lpDeposit(v, alice, 10_000e6);
        uint256 loanId = _open(1_000e6);
        bytes32 id = ace.loanMarket(loanId);
        MarketParams memory p = ace.idToMarketParams(id);

        assertTrue(p.inventoryAsk, "the door's market sells its pots");
        assertEq(p.fillFeeBps, 0, "and charges no fill fee");
        assertEq(p.lender, address(v), "PREMISE: the market is the vault's own");
        assertEq(id, keccak256(abi.encode(p)), "and the id is the ask-on market's, so no ask-off twin exists");
    }

    /// @notice THE OWN-TOKEN REFUSAL ANSWERS BEFORE THE BOUNTY: a product naming the vault's own cash as collateral, beside a settle bounty, names the cash.
    /// @dev The core checks run lender, quote, the two own tokens, then the bounty; no market is created and no collateral moves.
    function test_Door_AProductNamingItsOwnCashIsRefusedBeforeTheBounty() public {
        AceVaultHarness h = new AceVaultHarness(_cfg(1000));
        usdc.mint(alice, 10_000e6);
        vm.startPrank(alice);
        usdc.approve(address(h), 10_000e6);
        h.deposit(10_000e6, alice);
        vm.stopPrank();

        MarketParams memory p = AceFixtures.marketParams(address(usdc), address(usdc));
        p.lender = address(h);
        p.settleBountyBps = 50;
        h.setTerms(p, Terms({units: 1_000e6, principal: 100e6, tenor: 0, arm: false, minBufferWad: 0}));
        usdc.mint(borrower, 1_000e6);
        vm.startPrank(borrower);
        usdc.approve(address(h), 1_000e6);
        vm.expectRevert(AceVaultFlows.CashIsNotCollateral.selector);
        h.borrow(BorrowRequest(address(usdc), 1_000e6, 100e6, 0, false, 0, 0, 0), "", "");
        vm.stopPrank();

        assertEq(ace.idToMarketParams(keccak256(abi.encode(p))).lender, address(0), "no market was created");
        assertEq(usdc.balanceOf(borrower), 1_000e6, "and nothing was pulled");
    }
}
