// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.36;

import {Test} from "forge-std/Test.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {PositionManager} from "../../src/ace/positions/PositionManager.sol";
import {AceFixtures} from "../utils/AceFixtures.sol";
import {LoanManagerStub} from "../utils/LoanManagerStub.sol";
import {MockNoReturnERC20} from "../mocks/MockNoReturnERC20.sol";

/// @notice N8 token safety: PositionManager's custody moves are SafeERC20 (`safeTransferFrom` on pull,
/// @notice `safeTransfer` on release), so a no-bool USDT-shaped collateral custodies normally.
/// @notice A raw IERC20 call would ABI-decode the missing return word and revert, bricking the flow;
/// @notice this suite pins that it does not, by asserting real custody deltas across the round trip.
contract EscrowTokenSafetyN8Test is Test, LoanManagerStub {
    PositionManager internal positionManager;
    MockNoReturnERC20 internal coll; // USDT-style collateral: transfer/transferFrom return NOTHING

    address internal alice = address(0xA11CE); // title holder
    address internal bob = address(0xB0B); // release destination
    address internal payer = address(0xBEEF);

    function setUp() public {
        coll = new MockNoReturnERC20("Vote MON", "vMON", 18);
        positionManager = AceFixtures.plainEscrow(IERC20(address(coll)), address(this)); // this == LOAN_MANAGER
        _stubLoanConfig(address(coll), address(0)); // the config the positionManager reads back for every id
        coll.mint(payer, 1_000_000e18);
        vm.prank(payer);
        coll.approve(address(positionManager), type(uint256).max);
    }

    /// @notice Full pull -> partial release -> full release round trip against a no-return token.
    /// @dev Exercises both safe-transfer sites and asserts the real custody deltas at each leg.
    /// @dev A regression to a raw IERC20 call reverts here on the missing return word.
    function test_N8_PullRelease_RoundTrip_NoReturnCollateral() public {
        positionManager.pull(1, payer, 100e18);
        assertEq(coll.balanceOf(address(positionManager)), 100e18, "pull took custody into the pot");
        assertEq(positionManager.collateralOf(1), 100e18, "loan ledger credited");

        positionManager.release(1, bob, 40e18);
        assertEq(coll.balanceOf(bob), 40e18, "partial release delivered collateral (safeTransfer)");
        assertEq(coll.balanceOf(address(positionManager)), 60e18, "remainder still in the pot");

        positionManager.release(1, bob, 60e18);
        assertEq(coll.balanceOf(bob), 100e18, "full collateral delivered across releases");
        assertEq(coll.balanceOf(address(positionManager)), 0, "the pot is fully drained");
        assertEq(positionManager.collateralOf(1), 0, "loan ledger cleared");
        assertEq(positionManager.custodiedOf(address(coll)), 0, "and the aggregate cleared with it");
    }
}
