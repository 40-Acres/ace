// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.36;

import {Test, stdError} from "forge-std/Test.sol";
import {FullMath} from "@uniswap/v4-core/src/libraries/FullMath.sol";
import {Ace} from "../../src/ace/hub/Ace.sol";
import {AceLens} from "../../src/ace/lens/AceLens.sol";
import {Borrower, CollateralOutOfRange} from "../../src/ace/hub/Borrower.sol";
import {Constants} from "../../src/ace/hub/Constants.sol";
import {LoanMath} from "../../src/ace/hub/libraries/LoanMath.sol";
import {MarketParams, OpenBounds} from "../../src/ace/hub/Types.sol";
import {PositionManager} from "../../src/ace/positions/PositionManager.sol";
import {MockERC20} from "../mocks/MockERC20.sol";
import {MockPersistenceRecord} from "../mocks/MockPersistenceRecord.sol";
import {MockStakeVault} from "../mocks/MockStakeVault.sol";
import {AceFixtures} from "../utils/AceFixtures.sol";
import {AceReader} from "../utils/AceReader.sol";
import {WarpClock} from "../utils/WarpClock.sol";

/// @title AceCollateralWidthRail
/// @notice `LoanMath.triggerPrice` divides by `collateralUnits * 1e18`, a PLAIN product inside a FullMath call.
/// @notice FullMath protects the DIVISION; it never sees the two operands, which are multiplied before the call.
/// @dev So a site that reads as safe because it names FullMath is not, and this is the reachable half of that.
/// @dev `previewOpen` takes `collateralUnits` from the CALLER and passes it straight in, so a pure view panics.
/// @dev No unusual state is needed: no wide decimal gap, no large debt, no market configuration at all.
contract AceCollateralWidthRailTest is WarpClock {
    Ace internal ace;
    AceLens internal lens;
    PositionManager internal pm;
    AceReader internal read;
    bytes32 internal id;

    MockERC20 internal usdc;
    MockStakeVault internal vault;
    MockPersistenceRecord internal record;

    address internal alice = address(0xA11CE);
    address internal borrower = address(0xB0B);

    uint64 internal constant TEN7 = 7 days;
    uint64 internal constant TEN30 = 30 days;
    uint256 internal constant BASE_BPS = 40;
    uint256 internal TOP; // ticks from this pair's par; assigned in setUp, since par is not a compile-time value
    uint256 internal constant COLL = 100_000e18;
    uint256 internal constant TOP_CASH = 900_000e6;
    uint256 internal constant P = 10_000e6;

    /// @dev The widest collateral the trigger's own denominator can carry: above it `units * 1e18` wraps.
    uint256 internal constant RAIL = type(uint256).max / 1e18;

    OpenBounds internal OFF = OpenBounds(0, 0, 0);

    /// @dev This suite's pair, so a tick reads as its distance from par rather than as a grid coordinate.
    /// @param offset Ticks above par.
    /// @return The absolute grid tick.
    function _price(int24 offset) internal view returns (uint256) {
        return AceFixtures.priceAt(address(usdc), address(vault), offset);
    }

    function setUp() public {
        _warpTo(1_000_000);
        usdc = new MockERC20("USD Coin", "USDC", 6);
        vault = new MockStakeVault(42);
        TOP = _price(0);
        record = new MockPersistenceRecord(address(usdc), address(vault));

        MarketParams memory p = AceFixtures.marketParams(address(usdc), address(vault));
        p.record = address(record);
        p.baseBps = BASE_BPS;
        p.minTenor = TEN7;
        p.maxTenor = TEN30;

        AceFixtures.Deployment memory d = AceFixtures.deploy(p);
        (ace, pm, read, id) = (d.ace, d.positionManager, d.read, d.id);
        lens = new AceLens(address(ace));

        usdc.mint(alice, TOP_CASH);
        vm.startPrank(alice);
        usdc.approve(address(ace), TOP_CASH);
        ace.deposit(id, TOP_CASH);
        vm.stopPrank();
    }

    /// @notice THE DEFECT, in its purest form: the formula itself panics, with no hub and no state.
    /// @dev RED before the rail. `collateralUnits * 1e18` is evaluated before `FullMath` is entered.
    function test_TheTriggerFormulaPanicsOnCollateralItsOwnDenominatorCannotCarry() public {
        vm.expectRevert(stdError.arithmeticError);
        this.triggerAt(RAIL + 1);
    }

    /// @dev External so `expectRevert` observes the call frame rather than the test body.
    /// @param units The collateral to price the trigger against.
    /// @return The triggerable price.
    function triggerAt(uint256 units) external pure returns (uint256) {
        return LoanMath.triggerPrice(1e6, units, 1.05e18, 1e18);
    }

    /// @notice The formula is total at the rail itself, so the bound admits everything it should.
    function test_TheTriggerFormulaIsTotalAtTheRail() public view {
        assertGt(this.triggerAt(RAIL), 0, "the widest admissible collateral must still price a trigger");
    }

    /// @notice THE REACHABLE HALF: a pure view, caller-supplied units, any market. RED before the rail.
    /// @notice After the rail this refuses by NAME, which is what a quoting surface can act on.
    /// @dev `_preChecks` runs before the trigger read on the preview path, so one bound closes this door.
    function test_PreviewOpenRefusesCollateralAboveTheRailByName() public {
        vm.expectRevert(CollateralOutOfRange.selector);
        ace.previewOpen(id, RAIL + 1, P, TEN30, borrower, OFF);
    }

    /// @notice The WRITE door refuses identically, so the two never disagree about what is admissible.
    function test_OpenRefusesCollateralAboveTheRailByName() public {
        vm.prank(borrower);
        vm.expectRevert(CollateralOutOfRange.selector);
        ace.open(id, RAIL + 1, P, TEN30, borrower, OFF);
    }

    /// @notice CONTROL: an ordinary open is untouched, so the rail refuses nothing a real borrower wants.
    /// @dev The bound is 1.1579e59 atoms, which is 1.1579e23 whole tokens even at `MAX_DECIMALS`.
    function test_Control_AnOrdinaryOpenIsUnaffected() public {
        vault.mint(borrower, COLL);
        vm.startPrank(borrower);
        vault.approve(address(pm), COLL);
        uint256 loanId = ace.open(id, COLL, P, TEN30, borrower, OFF);
        vm.stopPrank();
        assertGt(loanId, 0, "the rail must not touch an ordinary draw");
    }

    /// @notice THE ORDER DOOR HOLDS THE SAME BOUND, so a post cannot escrow what a fill could not carry.
    /// @notice Without it a maker escrows against an order whose full size no single fill can ever take.
    /// @dev `post` sizes the escrow at the band's LOW end, so a small enough `liqLow` reaches the bound.
    /// @dev The maker always recovers by closing the order, so this is a door that fails early, not a stranding.
    /// @dev The rail sits BEFORE the escrow is pulled, so this never reaches a token and needs no balance.
    function test_PostOrderRefusesAnEscrowWiderThanTheFillDoorAdmits() public {
        /// @dev `post` escrows `ceil(k * principal * unitScale / (liqLow * 1e18))`, so at a band low of ONE
        /// @dev the rail binds a little over 1e30 of principal; twice that is comfortably past it.
        uint256 wide = 2e30;
        uint256 k = ace.idToMarketParams(id).minCoverageWad;
        assertGt(FullMath.mulDivRoundingUp(k * wide, read.marketState(id).unitScale, 1e18), RAIL, "fixture: the implied escrow must really clear the rail");

        vm.prank(borrower);
        vm.expectRevert(CollateralOutOfRange.selector);
        ace.postOrder(id, wide, 1, type(uint256).max, wide, TEN30, uint64(_now() + 1 days));
    }

    /// @notice CONTROL: an ordinary band posts, so the order rail refuses nothing a real maker wants.
    function test_Control_AnOrdinaryOrderStillPosts() public {
        uint256 escrow = 1e24; // the band below implies ~1.05e23 units, so the maker must hold more
        vault.mint(borrower, escrow);
        vm.startPrank(borrower);
        vault.approve(address(pm), escrow);
        uint256 orderId = ace.postOrder(id, P, 1e17, 1e18, P, TEN30, uint64(_now() + 1 days));
        vm.stopPrank();
        assertGt(orderId, 0, "the rail must not touch an ordinary post");
    }

    /// @notice `tryQuoteOpen` hands back an ACE selector rather than the bare panic selector.
    /// @dev This is the issue's own first complaint, discharged on the quoting surface by the rail.
    /// @dev Before it, `_selOf` returned `0x4e487b71` -- the Panic selector -- where an ACE one belongs.
    function test_TryQuoteOpenNamesTheRefusalRatherThanThePanic() public view {
        (bool ok, bytes4 reason,) = lens.tryQuoteOpen(id, RAIL + 1, P, TEN30, borrower, OFF);
        assertFalse(ok, "the quote must refuse");
        assertEq(reason, CollateralOutOfRange.selector, "and it must name an ACE refusal, not a panic");
    }
}
