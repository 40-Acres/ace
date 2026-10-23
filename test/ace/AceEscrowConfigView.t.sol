// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.36;

import {Test} from "forge-std/Test.sol";
import {Ace} from "../../src/ace/hub/Ace.sol";
import {MarketParams, OpenBounds} from "../../src/ace/hub/Types.sol";
import {NoMarket} from "../../src/ace/hub/Ace.sol";
import {PositionManager} from "../../src/ace/positions/PositionManager.sol";
import {ProtocolPolicy} from "../../src/config/Defaults.sol";
import {MockERC20} from "../mocks/MockERC20.sol";
import {MockStakeVault} from "../mocks/MockStakeVault.sol";
import {AceFixtures} from "../utils/AceFixtures.sol";
import {AceReader} from "../utils/AceReader.sol";

/// @title AceEscrowConfigView
/// @notice `escrowConfigOf` is the ONE source of truth the positionManager reads for a loan's custody facts.
/// @dev It exists so `pull` and `release` cannot disagree about which token a loan's units are.
/// @dev Disagreement would credit one pot and pay out of another, draining every loan on the token it named.
/// @dev It is LOAD-BEARING on every verb: a pot holding many tokens cannot self-assert which is this loan's.
contract AceEscrowConfigViewTest is Test {
    Ace internal ace;
    AceReader internal read;
    PositionManager internal positionManager;
    MockERC20 internal usdc;
    MockStakeVault internal vault;
    bytes32 internal id;

    address internal alice = address(0xA11CE);
    address internal borrower = address(0xB0B);

    uint256 internal T; // par for this pair; assigned in setUp, since par is not a compile-time value
    uint256 internal constant COLL = 10_000e18;
    uint256 internal constant DRAW = 1_000e6;

    /// @dev This suite's pair, so a tick reads as its distance from par rather than as a grid coordinate.
    /// @param offset Ticks above par.
    /// @return The absolute grid tick.
    function _price(int24 offset) internal view returns (uint256) {
        return AceFixtures.priceAt(address(usdc), address(vault), offset);
    }

    function setUp() public {
        vm.warp(1_000_000);
        usdc = new MockERC20("USD Coin", "USDC", 6);
        vault = new MockStakeVault(42);
        T = _price(0);

        MarketParams memory p = AceFixtures.marketParams(address(usdc), address(vault));
        AceFixtures.Deployment memory d = AceFixtures.deploy(p);
        (ace, positionManager, read, id) = (d.ace, d.positionManager, d.read, d.id);

        usdc.mint(alice, 5_000e6);
        vm.startPrank(alice);
        usdc.approve(address(ace), 5_000e6);
        ace.deposit(id, 5_000e6);
        vm.stopPrank();
    }

    function _open() internal returns (uint256 loanId) {
        vault.mint(borrower, COLL);
        vm.startPrank(borrower);
        vault.approve(address(positionManager), COLL);
        loanId = ace.open(id, COLL, DRAW, 0, borrower, OpenBounds(0, 0, 0));
        vm.stopPrank();
    }

    /// @notice The view answers with the loan's own market params, verbatim.
    function test_EscrowConfig_MatchesTheLoansMarketParams() public {
        uint256 loanId = _open();
        MarketParams memory p = ace.idToMarketParams(id);

        (address collateral, address quote) = ace.escrowConfigOf(loanId);

        assertEq(collateral, p.collateral, "collateral is the market's own");
        assertEq(quote, p.quote, "quote is the market's own");
    }

    /// @notice An id that never opened has no market, so the view FAILS CLOSED rather than answering zero.
    /// @dev A zero collateral would resolve to a template that does not exist and a bogus vault address.
    /// @dev Silently-wrong custody addressing is the whole class the handshake exists to close.
    function testRevert_EscrowConfig_UnknownLoan() public {
        vm.expectRevert(NoMarket.selector);
        ace.escrowConfigOf(999_999);
    }

    /// @notice THE ORDERING THIS NOW DEPENDS ON: `open` records the loan's market BEFORE it pulls.
    /// @dev Otherwise the positionManager could not resolve a config mid-`open` and the first pull would revert.
    /// @dev The ordering predates this change; what is new is that custody addressing now relies on it.
    /// @dev Pinned here so a future reorder of `open` fails loudly instead of at the first deposit.
    function test_OpenRecordsTheMarket_BeforeItPulls() public {
        uint256 loanId = _open();

        (address collateral,) = ace.escrowConfigOf(loanId);
        assertEq(collateral, address(vault), "the loan resolved its market during open");
        assertEq(read.loan(loanId).market, id, "and the market was recorded, not inferred");
        assertGt(positionManager.collateralOf(loanId), 0, "the pull landed inside the same call");
    }
}
