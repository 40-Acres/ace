// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.36;

import {Test} from "forge-std/Test.sol";
import {Ace} from "../../src/ace/hub/Ace.sol";
import {MarketParams, OpenBounds} from "../../src/ace/hub/Types.sol";
import {PositionManager} from "../../src/ace/positions/PositionManager.sol";
import {MockERC20} from "../mocks/MockERC20.sol";
import {MockPersistenceRecord} from "../mocks/MockPersistenceRecord.sol";
import {MockStakeVault} from "../mocks/MockStakeVault.sol";
import {AceFixtures} from "../utils/AceFixtures.sol";
import {AceReader} from "../utils/AceReader.sol";

/// @notice The continuation doors, declared test-side so this file names no hub ABI it does not drive.
interface IAceAuto {
    function tryContinue(uint256 id) external view returns (bool ok, bytes4 reason, uint256 principal);
    function setAutoRefinance(uint256 id, uint64 tenor, uint16 minBufferBps, uint16 maxFeeBps) external;
    function refinanceByPolicy(uint256 id) external returns (uint256 newId);
    function refinanceByPolicies(uint256[] calldata ids) external returns (uint256[] memory newIds);
}

/// @notice What the continuation predicate COSTS, decomposed, with ceilings that fail rather than print.
/// @notice DECOMPOSED on purpose: one figure for the whole path hides which door a regression landed on.
/// @notice A whole test body is ONE EIP-2929 warming context, so each measurement gets a body of its own.
/// @dev The ceilings are headroom over a measured baseline, not targets -- they catch a step change, not drift.
/// @dev They are deliberately loose enough to survive an unrelated storage-layout shuffle and tight enough
/// @dev that adding a ladder walk or a second external read to any of these four paths trips one.
contract AceContinueGasTest is Test {
    Ace internal ace;
    PositionManager internal pm;
    AceReader internal read;
    bytes32 internal id;

    MockERC20 internal usdc;
    MockStakeVault internal vault;
    MockPersistenceRecord internal record;
    IAceAuto internal auto_;

    address internal alice = address(0xA11CE);
    address internal borrower = address(0xB0B);
    address internal keeper = address(0xC0FFEE);

    uint64 internal constant TEN7 = 7 days;
    uint64 internal constant TEN30 = 30 days;
    uint16 internal constant BASE_BPS = 40;

    uint256 internal TOP; // ticks from this pair's par; assigned in setUp, since par is not a compile-time value
    uint256 internal constant COLL = 100_000e18;
    uint256 internal constant P = 20_000e6; // small, so five rolls fit one tick and no walk descends
    uint256 internal constant TOP_CASH = 800_000e6;

    uint256 internal constant CEIL_TRY_CONTINUE = 40_000; // measured 35_773: loan state plus one ladder walk
    uint256 internal constant CEIL_REFINANCE_BY_POLICY = 875_000; // measured 641_720: retire, melt, draw, mint, carry, net
    uint256 internal constant CEIL_FORCE_CLOSE_ROLL = 945_000; // measured 736_738: the paid post-expiry backstop
    uint256 internal constant CEIL_BATCH_OF_FIVE = 4_240_000; // measured 3_098_710, about 620k marginal per id

    OpenBounds internal OFF = OpenBounds(0, 0, 0);

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
        TOP = _price(0);
        record = new MockPersistenceRecord(address(usdc), address(vault));

        AceFixtures.Deployment memory d = AceFixtures.deploy(_params());
        (ace, pm, read, id) = (d.ace, d.positionManager, d.read, d.id);
        auto_ = IAceAuto(address(ace));

        _deposit(TOP_CASH);
    }

    /// @notice The FILTER alone. A keeper pays this per id before it commits to a batch, so it is the hot read.
    function test_Gas_TryContinue() public {
        uint256 loanId = _armedLoan();
        _intoWindow(loanId);

        uint256 before = gasleft();
        (bool ok,,) = auto_.tryContinue(loanId);
        uint256 used = before - gasleft();

        assertTrue(ok, "measured a REFUSAL, which short-circuits: the figure below is not the full path");
        emit log_named_uint("tryContinue           ", used);
        assertLt(used, CEIL_TRY_CONTINUE, "tryContinue got more expensive: the batch filter is the hot read");
    }

    /// @notice The verb end to end, which now pays for the predicate before it does anything else.
    function test_Gas_RefinanceByPolicy() public {
        uint256 loanId = _armedLoan();
        _intoWindow(loanId);

        vm.prank(keeper);
        uint256 before = gasleft();
        uint256 newId = auto_.refinanceByPolicy(loanId);
        uint256 used = before - gasleft();

        assertGt(newId, 0, "no roll happened, so the figure below measures a refusal");
        emit log_named_uint("refinanceByPolicy     ", used);
        assertLt(used, CEIL_REFINANCE_BY_POLICY, "refinanceByPolicy got more expensive");
    }

    /// @notice THE FOLD, which must not regress: `forceClose` on an armed loan rolls instead of settling.
    /// @dev This is the path the predicate was extracted FROM, so a regression here is the unification's own cost.
    function test_Gas_ForceCloseRollsAnArmedLoan() public {
        uint256 loanId = _armedLoan();
        vm.warp(read.loan(loanId).expiry + 1);

        vm.prank(keeper);
        uint256 before = gasleft();
        ace.forceClose(loanId);
        uint256 used = before - gasleft();

        assertTrue(read.loan(loanId).closedAt != 0, "the loan is still open, so nothing was measured");
        assertGt(read.loanCount(), 1, "the fold SETTLED instead of rolling: this is the wrong branch");
        emit log_named_uint("forceClose (roll)     ", used);
        assertLt(used, CEIL_FORCE_CLOSE_ROLL, "the expiry fold got more expensive");
    }

    /// @notice The batch a filtered keeper actually sends. Reported per id as well, which is what scales.
    function test_Gas_RefinanceByPoliciesOverFive() public {
        uint256[] memory ids = new uint256[](5);
        for (uint256 i; i < ids.length; i++) {
            ids[i] = _armedLoan();
        }
        _intoWindow(ids[0]); // opened in one block, so one warp puts every one of them in its window

        vm.prank(keeper);
        uint256 before = gasleft();
        uint256[] memory newIds = auto_.refinanceByPolicies(ids);
        uint256 used = before - gasleft();

        assertEq(newIds.length, 5, "the batch did not land, so the figure below measures a revert");
        emit log_named_uint("refinanceByPolicies x5", used);
        emit log_named_uint("  per id              ", used / 5);
        assertLt(used, CEIL_BATCH_OF_FIVE, "the batch got more expensive");
    }

    /* ========================== helpers ========================== */

    function _params() internal view returns (MarketParams memory p) {
        p = AceFixtures.marketParams(address(usdc), address(vault));
        p.record = address(record);
        p.baseBps = BASE_BPS;
        p.minTenor = TEN7;
        p.maxTenor = TEN30;
    }

    function _deposit(uint256 amt) internal {
        usdc.mint(alice, amt);
        vm.startPrank(alice);
        usdc.approve(address(ace), amt);
        ace.deposit(id, amt);
        vm.stopPrank();
    }

    function _armedLoan() internal returns (uint256 loanId) {
        vault.mint(borrower, COLL);
        usdc.mint(borrower, P);
        vm.startPrank(borrower);
        vault.approve(address(pm), COLL);
        usdc.approve(address(ace), type(uint256).max);
        loanId = ace.open(id, COLL, P, TEN7, borrower, OFF);
        auto_.setAutoRefinance(loanId, TEN7, 0, 0);
        vm.stopPrank();
    }

    function _intoWindow(uint256 loanId) internal {
        vm.warp(read.loan(loanId).expiry - 1);
    }
}
