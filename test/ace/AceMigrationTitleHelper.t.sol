// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.36;

import {Test} from "forge-std/Test.sol";
import {WarpClock} from "../utils/WarpClock.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {Ace} from "../../src/ace/hub/Ace.sol";
import {MarketParams, OpenBounds} from "../../src/ace/hub/Types.sol";
import {LoanMath} from "../../src/ace/hub/libraries/LoanMath.sol";
import {PositionManager} from "../../src/ace/positions/PositionManager.sol";
import {PositionTitleNFT} from "../../src/ace/positions/PositionTitleNFT.sol";
import {MockERC20} from "../mocks/MockERC20.sol";
import {MockPersistenceRecord} from "../mocks/MockPersistenceRecord.sol";
import {MockStakeVault} from "../mocks/MockStakeVault.sol";
import {AceFixtures} from "../utils/AceFixtures.sol";
import {AceReader} from "../utils/AceReader.sol";
import {IAceRefinance, MigrateArgs} from "../utils/RebateHarness.sol";

/// @notice The reference migration helper: it takes title, migrates, and hands the NEW title back.
/// @dev The three hub entries are SEQUENTIAL, never nested, which is the only reason this works.
/// @dev The new id is a DIFFERENT token than the one taken in: the open mints to `msg.sender`.
/// @dev While it holds title it IS the borrower, so it funds the top-up out of its own balance.
contract TitleHelper {
    Ace internal immutable ACE;

    bool public keepTitle;

    constructor(Ace ace) {
        ACE = ace;
    }

    function setKeepTitle(bool v) external {
        keepTitle = v;
    }

    /// @notice Fund and approve the top-up the repay leg will pull from this contract as borrower.
    function armTopUp(address token, uint256 amount) external {
        MockERC20(token).mint(address(this), amount);
        IERC20(token).approve(address(ACE), amount);
    }

    /// @notice While it holds title it IS the borrower, so it repays the shortfall out of its own balance.
    /// @dev The verb refuses a draw short of the old debt, so the helper brackets a composition, not one call.
    function migrateForHolder(MigrateArgs calldata m, uint256 gap) external returns (uint256 newId) {
        PositionTitleNFT title = PositionTitleNFT(ACE.POSITION_TITLE());
        title.transferFrom(msg.sender, address(this), m.id);
        if (gap == 0) {
            newId = IAceRefinance(address(ACE)).refinanceTo(m);
        } else {
            bytes[] memory calls = new bytes[](2);
            calls[0] = abi.encodeCall(Ace.repay, (m.id, gap));
            calls[1] = abi.encodeWithSelector(IAceRefinance.refinanceTo.selector, m);
            newId = abi.decode(ACE.multicall(calls)[1], (uint256));
        }
        if (!keepTitle) title.transferFrom(address(this), msg.sender, newId);
    }
}

/// @title AceMigrationTitleHelper
/// @notice The title-helper composition: a contract brackets a migration with two title transfers.
/// @notice Title IS borrower identity, so no code gate can tell a helper from any other title holder.
/// @dev The destination shares the source's quote and collateral, which is every migration there is.
/// @dev The trust assumption -- a helper that keeps the title keeps the position -- is written as a test.
contract AceMigrationTitleHelperTest is WarpClock {
    Ace internal ace;
    AceReader internal read;
    PositionManager internal pm;
    PositionTitleNFT internal title;
    MockERC20 internal usdc;
    MockStakeVault internal vault;
    TitleHelper internal helper;
    bytes32 internal idA;
    bytes32 internal idA2;

    address internal alice = address(0xA11CE);
    address internal borrower = address(0xB0B);

    uint64 internal constant TEN7 = 7 days;
    uint64 internal constant TEN30 = 30 days;
    uint64 internal constant SPACING = 23 days;

    uint256 internal constant P = 70_000e6;
    uint256 internal constant COLL = 100_000e18;
    uint256 internal constant TOP_CASH = 400_000e6;

    /// @dev fee(P,30d) at 40 bps per 7d is 1,200; the escrow is half of what the protocol cut leaves.
    /// @dev At t+15d of a 30d term exactly half that escrow is unearned, and the netting refunds it.
    uint256 internal constant FEE30 = 1_320e6; // the borrower's ALL-IN at the 30d rung
    uint256 internal constant REFUND30_AT15 = 300e6;
    uint256 internal constant TOP_UP = FEE30 - REFUND30_AT15;

    OpenBounds internal OFF = OpenBounds(0, 0, 0);
    uint256 internal t0;

    function setUp() public {
        _warpTo(1_000_000);
        t0 = _now();
        usdc = new MockERC20("USD Coin", "USDC", 6);
        vault = new MockStakeVault(42);

        AceFixtures.Deployment memory d = AceFixtures.deploy(_params(1.4e18));
        (ace, pm, read, idA) = (d.ace, d.positionManager, d.read, d.id);
        idA2 = ace.createMarket(_params(1.3e18));
        title = PositionTitleNFT(ace.POSITION_TITLE());
        helper = new TitleHelper(ace);

        _deposit(idA, TOP_CASH);
        _deposit(idA2, TOP_CASH);
    }

    // ---- fixture ----

    /// @dev One shape, two instantiations: the markets differ in coverage, each on a record of its own.
    function _params(uint256 k) internal returns (MarketParams memory p) {
        p = AceFixtures.marketParams(address(usdc), address(vault));
        p.record = address(new MockPersistenceRecord(address(usdc), address(vault)));
        p.baseBps = 40;
        p.minCoverageWad = k;
        p.minTenor = TEN7;
        p.maxTenor = TEN30;
    }

    function _deposit(bytes32 mid, uint256 amt) internal {
        usdc.mint(alice, amt);
        vm.startPrank(alice);
        usdc.approve(address(ace), amt);
        ace.deposit(mid, amt);
        vm.stopPrank();
    }

    function _open() internal returns (uint256 loanId) {
        vault.mint(borrower, COLL);
        vm.startPrank(borrower);
        vault.approve(address(pm), COLL);
        loanId = ace.open(idA, COLL, P, TEN30, borrower, OFF);
        vm.stopPrank();
    }

    function _args(uint256 oldId) internal view returns (MigrateArgs memory) {
        return MigrateArgs(oldId, idA2, P, TEN30, OFF, 0, address(0));
    }

    /// @dev The shortfall the helper repays before the migration: the destination's fee less the old refund.
    function _gap(uint256 oldId) internal view returns (uint256) {
        MarketParams memory p = ace.idToMarketParams(idA2);
        uint256 credit = P - LoanMath.originationFee(P, TEN30, p.baseBps, p.minTenor) + read.earlyExitRefund(oldId);
        return credit >= P ? 0 : P - credit;
    }

    // ============ the helper flow ============

    /// @notice THE FULL HELPER FLOW, end to end. The reference a helper author will copy.
    /// @dev The EOA approves the helper, the helper brackets the migration with two title transfers, and
    /// @dev the EOA ends holding a NEW position it never lost custody of for longer than one call.
    function test_TitleHelper_AnEoaEndsHoldingTheNewPosition() public {
        uint256 oldId = _open();
        _warpTo(t0 + 15 days);
        helper.armTopUp(address(usdc), TOP_UP);
        vm.prank(borrower);
        title.setApprovalForAll(address(helper), true);

        // build the args BEFORE the prank: a call in the argument list consumes the one-shot prank
        MigrateArgs memory m = _args(oldId);
        uint256 gap = _gap(oldId);
        vm.prank(borrower);
        uint256 newId = helper.migrateForHolder(m, gap);

        assertEq(title.ownerOf(newId), borrower, "the EOA holds the NEW title");
        assertEq(read.loan(newId).borrower, borrower, "and the hub agrees the EOA is the borrower");
        assertEq(read.loan(newId).market, idA2, "on a loan in the destination market");
        assertTrue(read.loan(oldId).closedAt != 0, "while the old token names a closed loan");
        assertEq(title.ownerOf(oldId), address(helper), "the spent token is left where the flow left it");
        assertEq(usdc.balanceOf(address(helper)), 0, "and the helper funded the top-up out of its own balance");
    }

    /// @notice A helper that KEEPS the title -- the hub stays consistent, the loss is the borrower's alone.
    /// @dev No code gate can tell a helper from any other title holder; the trust assumption is the test.
    function test_TitleHelper_AHelperThatKeepsTheTitle_LeavesTheHubConsistent() public {
        uint256 oldId = _open();
        _warpTo(t0 + 15 days);
        helper.armTopUp(address(usdc), TOP_UP);
        vm.prank(borrower);
        title.setApprovalForAll(address(helper), true);
        helper.setKeepTitle(true);

        // build the args BEFORE the prank: a call in the argument list consumes the one-shot prank
        MigrateArgs memory m = _args(oldId);
        uint256 gap = _gap(oldId);
        vm.prank(borrower);
        uint256 newId = helper.migrateForHolder(m, gap);

        assertEq(title.ownerOf(newId), address(helper), "the helper kept the position outright");
        assertEq(read.loan(newId).borrower, address(helper), "and the hub records exactly that");
        assertEq(read.debtOf(newId), P, "the loan itself is perfectly well formed");
        assertEq(pm.collateralOf(newId), COLL, "with its collateral in its own vault");
    }
}
