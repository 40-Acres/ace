// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.36;

import {MarketParams} from "../../../src/ace/hub/Types.sol";
import {AceVaultFlows, BorrowRequest, Terms} from "../../../src/vault/libraries/AceVaultFlows.sol";
import {MockERC20} from "../../mocks/MockERC20.sol";
import {IAceVaultLens, VaultLens} from "../../utils/VaultLens.sol";
import {MockTerms} from "./MockTerms.sol";
import {AceVaultBaseRig} from "./AceVaultBaseRig.sol";

/// @title AceVaultPreviewTermsTest
/// @notice `previewTerms` refuses as the door's checks on the product's answer and on its market would, and leaves the room and the cash to `borrow`.
/// @dev The preview lives on `AceVaultLens`, which runs the door's own library checks on the vault's figures.
contract AceVaultPreviewTermsTest is AceVaultBaseRig {
    IAceVaultLens internal lens;

    function setUp() public override {
        super.setUp();
        lens = VaultLens.deploy();
    }

    function _draw() internal pure returns (Terms memory) {
        return Terms({units: UNITS, principal: PRINCIPAL, tenor: 0, minBufferWad: 0});
    }

    /// @dev Point the product at `p` and expect the preview of the rig's ask on `c` to refuse with `sel`.
    function _expectPreviewRevert(MarketParams memory p, address c, bytes4 sel) internal {
        terms.setTerms(p, _draw());
        BorrowRequest memory r = _req(c, UNITS, PRINCIPAL, 0);
        vm.expectRevert(sel);
        lens.previewTerms(address(vault), borrower, r, "");
    }

    /// @notice THE MARKET CHECKS: another lender, another quote, the vault's own share or a settle bounty is refused by name.
    function test_PreviewTermsRunsTheDoorsMarketChecks() public {
        MarketParams memory p = _market(address(coll), record);
        p.lender = stranger;
        _expectPreviewRevert(p, address(coll), AceVaultFlows.NotOurLender.selector);
        p = _market(address(coll), record);
        p.quote = address(new MockERC20("Other Cash", "OTH", 6));
        _expectPreviewRevert(p, address(coll), AceVaultFlows.OutsideEnvelope.selector);
        p = _market(address(vault), record);
        _expectPreviewRevert(p, address(vault), AceVaultFlows.SharesAreNotCollateral.selector);
        p = _market(address(coll), record);
        p.settleBountyBps = 50;
        _expectPreviewRevert(p, address(coll), AceVaultFlows.PaysSettleBounty.selector);
    }

    /// @notice CASH IS NOT COLLATERAL: a market on the vault's own asset is refused by name, as the door's check would refuse it.
    function test_PreviewTermsRefusesCashAsCollateral() public {
        MarketParams memory p = _market(address(usdc), record);
        _expectPreviewRevert(p, address(usdc), AceVaultFlows.CashIsNotCollateral.selector);
    }

    /// @notice THE ROOM AND THE CASH ARE NOT PREVIEWED: a market the room refuses still previews, and the borrow refuses it.
    function test_PreviewTermsLeavesTheRoomToBorrow() public {
        MarketParams memory p = _market(address(coll), record);
        terms.setTerms(p, _draw());
        terms.setRoom(MockTerms.Mode.Answer, 0);
        (bytes32 id,,) = lens.previewTerms(address(vault), borrower, _req(address(coll), UNITS, PRINCIPAL, 0), "");
        assertEq(id, keccak256(abi.encode(p)), "the preview did not answer the product's market");
        _expectBorrowRevert(address(coll), AceVaultFlows.OverCap.selector);
    }
}
