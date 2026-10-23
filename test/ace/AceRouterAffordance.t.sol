// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.36;

import {WarpClock} from "../utils/WarpClock.sol";
import {Ace, NotAuthorized} from "../../src/ace/hub/Ace.sol";
import {MarketParams, OpenBounds} from "../../src/ace/hub/Types.sol";
import {PositionManager} from "../../src/ace/positions/PositionManager.sol";
import {MockERC20} from "../mocks/MockERC20.sol";
import {MockStakeVault} from "../mocks/MockStakeVault.sol";
import {MockPersistenceRecord} from "../mocks/MockPersistenceRecord.sol";
import {AceFixtures} from "../utils/AceFixtures.sol";
import {AceReader} from "../utils/AceReader.sol";

/// @title AceRouterAffordanceTest
/// @notice WHAT A BORROW ROUTER CAN AND CANNOT DO WITH THE HUB AS SHIPPED.
/// @notice Every market is sole-tenant, so reaching two curators' depth means two loans in two markets.
/// @notice Something must partition that borrow, and this pins which shapes the hub already admits.
/// @dev CHARACTERIZATION, not a defect hunt: it asserts what IS, so a D0 ruling rests on a run rather than a read.
/// @dev The D0 it serves is narrow: does a router need a payer/payee-parameterised `open` door before the freeze.
/// @dev R1 and R2 say the borrower-driven shape needs NOTHING. R3 says the contract-driven shape is CUSTODIAL.
contract AceRouterAffordanceTest is WarpClock {
    Ace internal ace;
    AceReader internal read;
    PositionManager internal positionManager;
    MockERC20 internal usdc;
    MockStakeVault internal collA;
    MockStakeVault internal collB;
    bytes32 internal idA;
    bytes32 internal idB;

    address internal curatorA = address(0xA11CE); // the sole lender of market A
    address internal curatorB = address(0xB0B0B); // the sole lender of market B -- a DIFFERENT curator
    address internal borrower = address(0xB0B);

    uint256 constant COLL = 10_000e18;
    uint256 constant PRINCIPAL = 4_000e6;
    uint256 constant FEE_FLOAT = 500e6;

    function setUp() public {
        _warpTo(1_000_000);
        usdc = new MockERC20("USD Coin", "USDC", 6);
        collA = new MockStakeVault(42);
        collB = new MockStakeVault(43);

        MockPersistenceRecord recA = new MockPersistenceRecord(address(usdc), address(collA));
        recA.setObserved(AceFixtures.px(1e18, address(usdc), address(collA)));
        recA.setMinPrice(AceFixtures.px(2e18, address(usdc), address(collA)));
        MarketParams memory pA = AceFixtures.marketParams(address(usdc), address(collA));
        pA.record = address(recA);
        pA.lender = curatorA;
        AceFixtures.Deployment memory d = AceFixtures.deploy(pA);
        (ace, positionManager, read, idA) = (d.ace, d.positionManager, d.read, d.id);

        MockPersistenceRecord recB = new MockPersistenceRecord(address(usdc), address(collB));
        recB.setObserved(AceFixtures.px(1e18, address(usdc), address(collB)));
        recB.setMinPrice(AceFixtures.px(2e18, address(usdc), address(collB)));
        MarketParams memory pB = AceFixtures.marketParams(address(usdc), address(collB));
        pB.record = address(recB);
        pB.lender = curatorB;
        idB = ace.createMarket(pB);

        _fund(curatorA, idA);
        _fund(curatorB, idB);
    }

    /// @dev Sole tenancy: only the market's named lender may book its cash, so each market is funded by its own.
    function _fund(address curator, bytes32 id) internal {
        usdc.mint(curator, 40_000e6);
        vm.startPrank(curator);
        usdc.approve(address(ace), 40_000e6);
        ace.deposit(id, 40_000e6);
        vm.stopPrank();
    }

    /// @dev Gives `who` collateral in BOTH pairs plus the fee float, approved to the right spender for each.
    function _arm(address who) internal {
        collA.mint(who, COLL);
        collB.mint(who, COLL);
        usdc.mint(who, FEE_FLOAT);
        vm.startPrank(who);
        collA.approve(address(positionManager), COLL);
        collB.approve(address(positionManager), COLL);
        usdc.approve(address(ace), FEE_FLOAT);
        vm.stopPrank();
    }

    /* ============ R1: the borrower-driven shape needs NO hub change ============ */

    /// @notice ONE transaction, TWO curators, and the borrower is payer, payee and title holder on both legs.
    /// @notice `multicall` is `address(this).delegatecall`, so every leg sees the BORROWER as `msg.sender`.
    /// @notice That is what makes an off-chain router sufficient: it routes, the borrower settles, nobody custodies.
    function test_R1_MulticallOpensAcrossTwoCuratorsNonCustodially() public {
        _arm(borrower);
        uint256 usdcBefore = usdc.balanceOf(borrower);

        bytes[] memory calls = new bytes[](2);
        calls[0] = abi.encodeCall(Ace.open, (idA, COLL, PRINCIPAL, 0, borrower, OpenBounds(0, 0, 0)));
        calls[1] = abi.encodeCall(Ace.open, (idB, COLL, PRINCIPAL, 0, borrower, OpenBounds(0, 0, 0)));

        vm.prank(borrower);
        bytes[] memory out = ace.multicall(calls);

        uint256 loanA = abi.decode(out[0], (uint256));
        uint256 loanB = abi.decode(out[1], (uint256));

        assertEq(read.loan(loanA).borrower, borrower, "leg A is titled to the borrower");
        assertEq(read.loan(loanB).borrower, borrower, "leg B is titled to the borrower");
        assertEq(read.loan(loanA).debt, PRINCIPAL, "leg A's debt is the principal drawn");
        assertEq(read.loan(loanB).debt, PRINCIPAL, "leg B's debt is the principal drawn");

        /// @dev PAYER: both legs took the collateral from the borrower, not from any intermediary.
        assertEq(collA.balanceOf(borrower), 0, "market A's collateral left the borrower");
        assertEq(collB.balanceOf(borrower), 0, "market B's collateral left the borrower");

        /// @dev PAYEE: both principals landed on the borrower. Net of the two origination fees, so a
        /// @dev GT against the float is the honest assertion -- the exact fee is LoanMath's, not this test's.
        assertGt(usdc.balanceOf(borrower), usdcBefore, "the borrower received both principals");
        assertGt(usdc.balanceOf(borrower), 2 * PRINCIPAL - FEE_FLOAT, "and they are the full draws, less fees only");
    }

    /// @notice ALL-OR-NOTHING: a batch whose second leg cannot fund reverts the first with it.
    /// @notice A router that quotes wrong strands nothing, which is what lets it be optimistic off-chain.
    function test_R2_ABatchWhoseSecondLegFailsOpensNeitherLoan() public {
        _arm(borrower);

        bytes[] memory calls = new bytes[](2);
        calls[0] = abi.encodeCall(Ace.open, (idA, COLL, PRINCIPAL, 0, borrower, OpenBounds(0, 0, 0)));
        /// @dev Market B cannot serve 10x its resting cash, so this leg must refuse.
        calls[1] = abi.encodeCall(Ace.open, (idB, COLL, 400_000e6, 0, borrower, OpenBounds(0, 0, 0)));

        vm.prank(borrower);
        vm.expectRevert();
        ace.multicall(calls);

        assertEq(ace.marketLoansLength(idA), 0, "the first leg was rolled back with the second");
        assertEq(ace.marketLoansLength(idB), 0, "and the failing leg opened nothing");
        assertEq(collA.balanceOf(borrower), COLL, "no collateral moved");
    }

    /* ============ R3: the contract-driven shape IS CUSTODIAL, and that is the D0 ============ */

    /// @notice An operator router opens loans TITLED to the borrower, but pays and is paid ITSELF.
    /// @notice `Ace.open` builds `OpenArgs(id, borrower, msg.sender, msg.sender, ...)`: payer and payee are the caller.
    /// @notice So a router contract necessarily touches both legs of the borrower's money, however briefly.
    /// @dev THIS IS THE THING THAT IS NOT EXPRESSIBLE: a router that orchestrates and never custodies.
    /// @dev Making it expressible means a payer/payee-parameterised door, which is immutable hub bytecode.
    function test_R3_AnOperatorRouterIsPayerAndPayeeNotTheBorrower() public {
        RouterProbe router = new RouterProbe(ace);
        _arm(address(router)); // the ROUTER holds the collateral and the fee float, not the borrower

        vm.prank(borrower);
        ace.setCreditOperator(address(router), true);

        uint256 routerUsdcBefore = usdc.balanceOf(address(router));
        uint256 borrowerUsdcBefore = usdc.balanceOf(borrower);

        uint256 loanA = router.openFor(idA, COLL, PRINCIPAL, borrower);

        assertEq(read.loan(loanA).borrower, borrower, "title and debt sit with the borrower");
        assertEq(collA.balanceOf(address(router)), 0, "PAYER: the ROUTER posted the collateral");
        assertGt(usdc.balanceOf(address(router)), routerUsdcBefore, "PAYEE: the ROUTER received the principal");
        assertEq(usdc.balanceOf(borrower), borrowerUsdcBefore, "and the borrower received NOTHING directly");
    }

    /// @notice Without the grant the same call is refused, so the custody above is not an access-control gap.
    function test_R3b_AnUngrantedRouterCannotOpenInAnothersName() public {
        RouterProbe router = new RouterProbe(ace);
        _arm(address(router));

        vm.expectRevert(NotAuthorized.selector);
        router.openFor(idA, COLL, PRINCIPAL, borrower);
    }
}

/// @notice The minimal on-chain router: it holds nothing of its own and opens in the borrower's name.
/// @dev Exists to show WHERE the money goes, not to propose a design.
contract RouterProbe {
    Ace internal immutable ACE;

    constructor(Ace ace) {
        ACE = ace;
    }

    /// @notice Opens one leg titled to `borrower`, funded by this contract's own collateral.
    /// @param id The market to draw from.
    /// @param collateralUnits Collateral to escrow.
    /// @param principal Quote to draw.
    /// @param borrower Who holds title and the debt.
    /// @return The new loan id.
    function openFor(bytes32 id, uint256 collateralUnits, uint256 principal, address borrower) external returns (uint256) {
        return ACE.open(id, collateralUnits, principal, 0, borrower, OpenBounds(0, 0, 0));
    }
}
