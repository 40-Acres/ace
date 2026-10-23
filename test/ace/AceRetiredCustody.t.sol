// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.36;

import {Test} from "forge-std/Test.sol";
import {Ace} from "../../src/ace/hub/Ace.sol";
import {MarketParams, OpenBounds} from "../../src/ace/hub/Types.sol";
import {PriceFrame} from "../utils/PriceFrame.sol";
import {PositionManager} from "../../src/ace/positions/PositionManager.sol";
import {MockERC20} from "../mocks/MockERC20.sol";
import {MockPersistenceRecord} from "../mocks/MockPersistenceRecord.sol";
import {MockStakeVault} from "../mocks/MockStakeVault.sol";
import {AceFixtures} from "../utils/AceFixtures.sol";
import {AceReader} from "../utils/AceReader.sol";

/// @title AceRetiredCustody
/// @notice Settled inventory never moves at settlement: it stays in the pot, on the loan's RETIRED ledger.
/// @notice Delivery happens at sale or burn time, to an address the buyer or burner names.
/// @dev So the hub holds no collateral at rest, and two settled loans cannot reach each other's credit.
/// @dev Pooled, the ledger is the whole of that isolation: there is no second address to hide behind.
contract AceRetiredCustodyTest is Test {
    Ace internal ace;
    AceReader internal read;
    PositionManager internal positionManager;
    MockERC20 internal usdc;
    MockStakeVault internal vault;
    MockPersistenceRecord internal record;
    bytes32 internal id;

    address internal alice = address(0xA11CE);
    address internal bob = address(0xB0BB);
    address internal borrowerA = address(0xB0B);
    address internal borrowerB = address(0xB0B2);
    address internal keeper = address(0xCAFE);
    address internal buyer = address(0xBEEF);

    uint256 internal constant COLL = 10_000e18;
    uint256 internal constant PRINCIPAL = 4_500e6;
    uint256 internal constant UNIT_SCALE = 1e30;
    uint256 internal T4; // ticks above this pair's par; assigned in setUp, since par is not a compile-time value

    /// @dev This suite's pair, so a tick reads as its distance from par rather than as a grid coordinate.
    /// @param offset Ticks above par.
    /// @return The absolute grid tick.
    function _price(int24 offset) internal view returns (uint256) {
        return AceFixtures.priceAt(address(usdc), address(vault), offset);
    }

    function setUp() public {
        vm.warp(1_000_000);
        usdc = new MockERC20("USD Coin", "USDC", 6);
        vault = new MockStakeVault(1e18);
        T4 = _price(960);
        record = new MockPersistenceRecord(address(usdc), address(vault));

        MarketParams memory p = AceFixtures.marketParams(address(usdc), address(vault));
        p.record = address(record);
        AceFixtures.Deployment memory d = AceFixtures.deploy(p);
        (ace, positionManager, read, id) = (d.ace, d.positionManager, d.read, d.id);

        /// @dev ALICE ALONE: the market names one lender, so bob is refused at the door. He stays in the
        /// @dev suite as a DESTINATION, which is the only role he ever mattered in here.
        _deposit(alice, T4, 20_000e6);
    }

    // ---- helpers ----

    function _deposit(address who, uint256 price, uint256 amt) internal {
        usdc.mint(who, amt);
        vm.startPrank(who);
        usdc.approve(address(ace), amt);
        ace.deposit(id, amt);
        vm.stopPrank();
    }

    function _open(address who) internal returns (uint256 loanId) {
        vault.mint(who, COLL);
        vm.startPrank(who);
        vault.approve(address(positionManager), COLL);
        loanId = ace.open(id, COLL, PRINCIPAL, 0, who, OpenBounds(0, 0, 0));
        vm.stopPrank();
    }

    /// @dev Settle `who`'s loan, leaving its collateral in the pot on the loan's own retired ledger.
    /// @dev Then rest past the ask hold, read off the market rather than assumed, so a buy leg can run.
    function _settled(address who) internal returns (uint256 loanId) {
        loanId = _open(who);
        record.setBelow(true);
        vm.prank(keeper);
        ace.finalize(loanId);
        record.setBelow(false);
        vm.warp(read.inventoryAskOpensAt(loanId));
    }

    // ============ delivery comes out of the pot, debited to the loan's own retired ledger ============

    /// @notice `buyInventory` delivers out of the pot, debiting the settled loan's retired ledger alone.
    /// @dev A second settled loan is standing by, so a delivery that took the pot at large is visible here.
    function test_BuyInventory_DebitsOnlyTheSellingLoansRetiredLedger() public {
        uint256 loanId = _settled(borrowerA);
        uint256 otherId = _settled(borrowerB);
        uint256 potPre = vault.balanceOf(address(positionManager));
        uint256 retiredPre = positionManager.retiredOf(loanId);
        uint256 otherPre = positionManager.retiredOf(otherId);

        usdc.mint(buyer, 1_000e6);
        vm.startPrank(buyer);
        usdc.approve(address(ace), 1_000e6);
        (uint256 unitsOut,) = ace.buyInventory(loanId, 1_000e6, 1, buyer);
        vm.stopPrank();

        assertGt(unitsOut, 0, "the ask filled");
        assertEq(vault.balanceOf(buyer), unitsOut, "the buyer took delivery");
        assertEq(potPre - vault.balanceOf(address(positionManager)), unitsOut, "out of the pot, unit for unit");
        assertEq(retiredPre - positionManager.retiredOf(loanId), unitsOut, "and only the SELLING loan is debited");
        assertEq(positionManager.retiredOf(otherId), otherPre, "the other settled loan's credit is untouched");
        assertEq(vault.balanceOf(address(ace)), 0, "the hub custodied nothing at any point");
    }

    /// @notice `redeemInKind` delivers from the same place, to the lender's own named address.
    function test_RedeemInKind_DebitsOnlyTheBurningLoansRetiredLedger() public {
        uint256 loanId = _settled(borrowerA);
        uint256 otherId = _settled(borrowerB);
        uint256 potPre = vault.balanceOf(address(positionManager));
        uint256 otherPre = positionManager.retiredOf(otherId);

        vm.prank(alice);
        uint256 out = ace.redeemInKind(loanId, bob); // a destination the lender names

        assertGt(out, 0, "the redeem paid");
        assertEq(vault.balanceOf(bob), out, "to the address the lender named, not to the lender");
        assertEq(potPre - vault.balanceOf(address(positionManager)), out, "out of the pot");
        assertEq(positionManager.retiredOf(otherId), otherPre, "the other settled loan's credit is untouched");
        assertEq(vault.balanceOf(address(ace)), 0, "and never through the hub");
    }

    /// @notice The isolation C2 relies on: draining one settled loan's pot leaves the other's credit intact.
    /// @dev Under one shared pot the LEDGER is the whole of that guarantee, which is what this now asserts.
    function test_TwoSettledLoansNeverDeliverFromEachOthersCredit() public {
        uint256 idA = _settled(borrowerA);
        uint256 idB = _settled(borrowerB);
        uint256 potPre = vault.balanceOf(address(positionManager));
        uint256 bRetiredPre = positionManager.retiredOf(idB);

        usdc.mint(buyer, 100_000e6);
        vm.startPrank(buyer);
        usdc.approve(address(ace), 100_000e6);
        (uint256 unitsOut,) = ace.buyInventory(idA, 100_000e6, 1, buyer); // drain A's pot as far as it goes
        vm.stopPrank();

        assertGt(unitsOut, 0, "A's pot really did sell");
        assertEq(positionManager.retiredOf(idB), bRetiredPre, "B's retired ledger is bit-unchanged");
        assertEq(potPre - vault.balanceOf(address(positionManager)), unitsOut, "and only A's units left the pot");
        assertGe(vault.balanceOf(address(positionManager)), bRetiredPre, "B's credit is still fully covered");
    }

    /// @notice THE GUARD, restated pooled: no route exists to take settled collateral out except a claim.
    /// @dev The sweeps are deleted, so the custodian dispatches no such selector at all.
    /// @dev That is a stronger claim than the old carve-out, which refused COLLATERAL and allowed the rest.
    function test_SettledUnitsHaveNoExtractionRouteAtAll() public {
        uint256 loanId = _settled(borrowerA);
        uint256 retired = positionManager.retiredOf(loanId);
        assertGt(retired, 0, "fixture: the pot really holds settled inventory for this loan");

        vm.prank(borrowerA); // the title holder is the only caller a sweep ever answered to
        (bool ok,) = address(positionManager).call(abi.encodeWithSignature("sweepERC20(uint256,address)", loanId, address(vault)));

        assertFalse(ok, "the custodian exposes no sweep surface, so the selector cannot be dispatched");
        assertEq(positionManager.retiredOf(loanId), retired, "and the settled credit is untouched");
    }

    /// @notice The invariant C2 buys: the hub is a pure router for collateral, at rest and in flight.
    /// @dev I-A is the pot-level sum now, so a single loan's ledgers bound it rather than equalling it.
    function test_HubHoldsNoCollateralAtRestAfterSettlement() public {
        uint256 loanId = _settled(borrowerA);
        assertEq(vault.balanceOf(address(ace)), 0, "no collateral rests on the hub after a settlement");
        assertEq(
            positionManager.custodiedOf(address(vault)),
            positionManager.collateralOf(loanId) + positionManager.retiredOf(loanId),
            "the one loan on this token accounts for the whole aggregate"
        );
        assertEq(
            positionManager.custodiedOf(address(vault)),
            vault.balanceOf(address(positionManager)),
            "I-A: the aggregate is exactly funded, with no donation in this fixture"
        );
    }

    /// @notice The retired ledger covers every class pot it is meant to, with the dust wedge on top.
    /// @dev `collateralNeeded` ceils per tick while `_convertClaim` floors, so it is >= not ==.
    function test_RetiredLedgerCoversTheClassPots() public {
        uint256 loanId = _settled(borrowerA);
        uint256 pot = read.invPotOf(id, loanId);
        (uint256 owedKeeper,) = ace.owedOf(loanId, keeper);
        (uint256 owedHolder,) = ace.owedOf(loanId, borrowerA);

        assertGt(pot, 0, "the class took title to something");
        assertGe(positionManager.retiredOf(loanId), pot + owedKeeper + owedHolder, "the ledger covers every entitlement");
        assertLe(positionManager.retiredOf(loanId) - pot - owedKeeper - owedHolder, 1, "and overshoots by at most the rounding wedge");
    }
}
