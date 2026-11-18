// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.36;

import {Math} from "@openzeppelin/contracts/utils/math/Math.sol";
import {AceVault} from "../../src/curator/AceVault.sol";
import {CuratorVaultBase} from "./CuratorVaultBase.sol";
import {MockTerms} from "./vault/MockTerms.sol";

/// @title CuratorVaultMaxMintBand
/// @notice Pins the ACCEPTED over-report band of `maxMint`: it saturates whenever `cap * quoteSupply` overflows, even where the answer fits.
/// @dev Accepted by user ruling (decisions): the band is caps of about 1e59 to 1e71 asset units, which no product sets.
/// @dev If `maxMint` is ever made exact, this row turns red: update the ruling and the builder guide's section 5, then flip the final assertion.
contract CuratorVaultMaxMintBandTest is CuratorVaultBase {
    uint256 internal constant SEED = 10_000e6;

    AceVault internal v;
    MockTerms internal mt;

    function setUp() public override {
        super.setUp();
        (v, mt) = _onMockTerms(0); // the product's entry cap is a settable number
        _lpDeposit(v, alice, SEED);
    }

    /// @notice Inside the band the exact answer fits, yet `maxMint` reports `type(uint256).max` and a mint of it refuses.
    function test_MaxMint_InTheAcceptedBandSaturatesThoughTheAnswerFits() public {
        uint256 cap = uint256(1) << 210;
        mt.setEntryCap(MockTerms.Mode.Answer, cap);
        uint256 q = v.totalSupply() + v.pendingFeeShares() + 1e6;
        uint256 a = v.totalAssets();
        (bool ok,) = Math.tryMul(cap, q);
        assertFalse(ok, "PREMISE: cap times the quote supply overflows");
        uint256 exact = Math.mulDiv(cap, q, a + 1);
        assertLt(exact, type(uint256).max, "PREMISE: the exact answer fits");
        assertLe(v.previewMint(exact), cap, "PREMISE: the exact answer's shares fit the cap");
        assertGt(v.previewMint(exact + 1), cap, "PREMISE: one share past it costs past the cap");
        assertEq(v.maxMint(bob), type(uint256).max, "ACCEPTED: maxMint saturates across the whole overflow band");
    }
}
