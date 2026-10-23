// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.36;

import {Test} from "forge-std/Test.sol";
import {Ace} from "../../src/ace/hub/Ace.sol";
import {MarketParams} from "../../src/ace/hub/Types.sol";
import {BelowMinLot, WouldLeaveDust} from "../../src/ace/hub/Lender.sol";
import {PositionManager} from "../../src/ace/positions/PositionManager.sol";
import {MockERC20} from "../mocks/MockERC20.sol";
import {MockPersistenceRecord} from "../mocks/MockPersistenceRecord.sol";
import {MockStakeVault} from "../mocks/MockStakeVault.sol";
import {AceFixtures} from "../utils/AceFixtures.sol";

/// @title AceMinDebtFloorsBothDoors
/// @notice `minDebt` is ONE number and BOTH doors read it: what a draw may issue, and what a deposit may rest.
/// @notice Entry (`Lender.depositCash`) and exit (`Lender.withdraw`) must gate on that same one number.
/// @dev IT WAS `AceLotFloorDerivation`, and the claim it pins is the half that survived the tick deletion.
/// @dev The old law derived the lender's ticket as `ceil(minDebt / maxClaimTicks)` so a maximally FRAGMENTED
/// @dev ladder could still fund one minimum loan. With one price there is nothing to fragment, so the
/// @dev derivation, its ceil-vs-floor inversion and the arithmetic suite beside it are all gone.
/// @dev WHAT SURVIVES IS WHY THE FLOOR EXISTS AT ALL: cash under `minDebt` is depth no draw can consume, and
/// @dev a reader would otherwise count it as available liquidity. That argument needs both doors, so both are here.
/// @dev BOTH MEANS THE TWO LENDER DOORS, AND THE FLOOR DOES NOT MAKE THAT BAND UNREACHABLE. There is a THIRD
/// @dev door: a draw lowers resting cash and carries no remainder test, so `minDebt` 10 on a rest of 15 drawn
/// @dev at 10 leaves 5, in one ordinary call. Accepted deliberately -- flooring the draw would refuse an
/// @dev otherwise-good one, and nothing is trapped in the band, since emptying the market still works.
/// @dev Every row drives the HUB, so a refusal here proves the gate is live and not just the arithmetic.
contract AceMinDebtFloorsBothDoorsTest is Test {
    Ace internal ace;
    PositionManager internal positionManager;
    MockERC20 internal usdc;
    MockStakeVault internal vault;
    MockPersistenceRecord internal record;

    address internal alice = address(0xA11CE);

    uint256 internal constant FLOOR = 10e6; // the market's `minDebt`, and therefore its deposit floor

    function setUp() public {
        vm.warp(1_000_000);
        usdc = new MockERC20("USD Coin", "USDC", 6);
        vault = new MockStakeVault(42);
        record = new MockPersistenceRecord(address(usdc), address(vault));
        ace = AceFixtures.newAce();
        positionManager = PositionManager(ace.POSITION_MANAGER());
    }

    // ---- fixture ----

    /// @dev Sets only `minDebt`: the deposit floor has no field of its own, and no cap to divide by any more.
    function _params(uint256 minDebt) internal view returns (MarketParams memory p) {
        p = AceFixtures.marketParams(address(usdc), address(vault));
        p.record = address(record);
        p.minDebt = minDebt;
        p.baseBps = 1;
        p.settleBountyBps = 0;
    }

    function _market(uint256 minDebt) internal returns (bytes32) {
        return ace.createMarket(_params(minDebt));
    }

    function _lend(bytes32 mid, uint256 amt) internal {
        usdc.mint(alice, amt);
        vm.startPrank(alice);
        usdc.approve(address(ace), amt);
        ace.deposit(mid, amt);
        vm.stopPrank();
    }

    // ============ entry: `depositCash` gates on `minDebt` ============

    /// @notice A deposit one wei under the floor is refused.
    function testRevert_MinDebt_EntryRefusesASubFloorDeposit() public {
        bytes32 mid = _market(FLOOR);
        usdc.mint(alice, FLOOR);
        vm.startPrank(alice);
        usdc.approve(address(ace), FLOOR);
        vm.expectRevert(BelowMinLot.selector);
        ace.deposit(mid, FLOOR - 1);
        vm.stopPrank();
    }

    /// @notice And the floor itself is admitted, so the refusal above is a boundary and not a ban.
    /// @dev Here so the row above cannot pass by refusing everything.
    function test_MinDebt_EntryAdmitsTheFloorExactly() public {
        bytes32 mid = _market(FLOOR);
        _lend(mid, FLOOR);
        assertEq(ace.restingOf(mid), FLOOR, "a deposit AT the floor books");
    }

    /// @notice A zero deposit is refused by the SAME error, which is a separate clause from the floor test.
    /// @dev They share a selector deliberately: both mean "this deposit rests nothing a draw could take".
    function testRevert_MinDebt_EntryRefusesAZeroDeposit() public {
        bytes32 mid = _market(FLOOR);
        vm.prank(alice);
        vm.expectRevert(BelowMinLot.selector);
        ace.deposit(mid, 0);
    }

    // ============ exit: `withdraw` gates on the SAME number ============

    /// @notice Floor-or-zero on the way out, measured against the same `minDebt` the entry door read.
    /// @dev THE ONE-NUMBER CLAIM, and it is what this file is for: a second constant here would let a
    /// @dev lender be admitted at one figure and stranded at another.
    function testRevert_MinDebt_ExitRefusesASubFloorRemainder() public {
        bytes32 mid = _market(FLOOR);
        _lend(mid, 2 * FLOOR);
        vm.prank(alice);
        vm.expectRevert(WouldLeaveDust.selector);
        ace.withdraw(mid, FLOOR + 1, alice, 0); // would leave FLOOR - 1: nonzero and under the floor
    }

    /// @notice The zero half of floor-or-zero: fully emptying your own market is always available.
    /// @dev The floor must not strand a lender it just admitted.
    function test_MinDebt_ExitAlwaysAllowsAFullEmptying() public {
        bytes32 mid = _market(FLOOR);
        _lend(mid, 2 * FLOOR);
        vm.prank(alice);
        ace.withdraw(mid, type(uint256).max, alice, 0);
        assertEq(ace.restingOf(mid), 0, "the resting cash is gone, whatever the floor was");
    }

    /// @notice A remainder exactly AT the floor is admitted, which is the boundary the refusal above sits on.
    function test_MinDebt_ExitAdmitsARemainderAtTheFloor() public {
        bytes32 mid = _market(FLOOR);
        _lend(mid, 2 * FLOOR);
        vm.prank(alice);
        ace.withdraw(mid, FLOOR, alice, 0);
        assertEq(ace.restingOf(mid), FLOOR, "a remainder AT the floor is legal depth, so it stays");
    }

    // ============ the genesis rails that keep the floor meaningful ============

    /// @notice A zero-`minDebt` market is uncreatable, so neither door ever gates on a floor of zero.
    /// @dev A zero floor admits dust at BOTH doors, which is exactly the state the floor exists to prevent.
    /// @dev Built OUTSIDE the expectRevert: `_params` reads the pair's decimals and would eat the expectation.
    function testRevert_MinDebt_AZeroMinDebtMarketIsUncreatable() public {
        MarketParams memory zero = _params(0);
        vm.expectRevert(bytes("min debt zero"));
        ace.createMarket(zero);
    }

    /// @notice An absurd `minDebt` is refused at GENESIS, so the creator learns rather than the first lender.
    /// @notice Over the market's `uint128` cash cap the floor could never be deposited, so nobody could lend at all.
    /// @dev THE SUCCESSOR to `min lot over tick cap`, which asked the same question of the DERIVED ticket.
    /// @dev With no derivation the question is asked of `minDebt` directly, and the answer is the same one.
    /// @dev Deleting the rail outright would have left a creatable market whose every deposit reverts.
    function testRevert_MinDebt_AnAbsurdMinDebtIsRefusedAtGenesis() public {
        MarketParams memory p = _params(uint256(type(uint128).max) + 1);
        vm.expectRevert(bytes("min debt over cash cap"));
        ace.createMarket(p);
    }

    /// @notice The largest legal `minDebt` still creates, so the rail above is a boundary and not a ban.
    function test_MinDebt_TheCashCapItselfIsCreatable() public {
        bytes32 mid = _market(type(uint128).max);
        assertEq(ace.idToMarketParams(mid).minDebt, type(uint128).max, "the cap itself is a legal floor");
    }
}
