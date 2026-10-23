// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.36;

import {Test} from "forge-std/Test.sol";
import {Ace} from "../../src/ace/hub/Ace.sol";
import {MarketParams, OpenBounds} from "../../src/ace/hub/Types.sol";
import {PositionManager} from "../../src/ace/positions/PositionManager.sol";
import {MockERC20} from "../mocks/MockERC20.sol";
import {MockPersistenceRecord} from "../mocks/MockPersistenceRecord.sol";
import {ReadProbeVault} from "../mocks/ReadProbeVault.sol";
import {AceFixtures} from "../utils/AceFixtures.sol";
import {AceReader} from "../utils/AceReader.sol";

/// @title AceUnitReadOnlyReentrancy
/// @notice lending-review mitigation 4, second half: the pot is debited BEFORE any token moves, so an
/// @notice observer reading the hub from inside the payout transfer sees the FINAL state, never a torn one.
/// @dev The reentrancy guard stops a re-entrant write; it does not stop a view, which is the whole
/// @dev read-only reentrancy surface. This suite is the only proof the views are safe to price off.
/// @dev Hardening pass over the loan-unit receipts rebuild; the design record.
contract AceUnitReadOnlyReentrancyTest is Test {
    Ace internal ace;
    AceReader internal read;
    PositionManager internal positionManager;
    MockERC20 internal usdc;
    ReadProbeVault internal probe;
    MockPersistenceRecord internal record;
    bytes32 internal mid;

    address internal alice = address(0xA11CE);
    address internal bob = address(0xB0B);
    address internal buyer = address(0xB04E5);
    address internal borrower = address(0xB0BA);
    address internal keeper = address(0xCAFE);

    uint256 internal T4; // ticks above this pair's par; assigned in setUp, since par is not a compile-time value
    uint256 internal constant COLL = 10_000e18;
    uint256 internal constant PRINCIPAL = 4_500e6;

    /// @dev This suite's pair, so a tick reads as its distance from par rather than as a grid coordinate.
    /// @param offset Ticks above par.
    /// @return The absolute grid tick.
    function _price(int24 offset) internal view returns (uint256) {
        return AceFixtures.priceAt(address(usdc), address(probe), offset);
    }

    function setUp() public {
        vm.warp(1_000_000);
        usdc = new MockERC20("USD Coin", "USDC", 6);
        probe = new ReadProbeVault();
        T4 = _price(960);
        record = new MockPersistenceRecord(address(usdc), address(probe));
        record.setObserved(AceFixtures.px(1e18, address(usdc), address(probe)));
        record.setMinPrice(AceFixtures.px(2e18, address(usdc), address(probe)));
        MarketParams memory p = AceFixtures.marketParams(address(usdc), address(probe));
        p.record = address(record);
        AceFixtures.Deployment memory d = AceFixtures.deploy(p);
        (ace, positionManager, read, mid) = (d.ace, d.positionManager, d.read, d.id);
    }

    /// @dev WAS TWO LENDERS, so a partial burn left live units to read a balance off. Sole tenancy admits
    /// @dev one, and there are no units to burn: the probe reads the hub's own state mid-payout instead.
    function _settledLoan() internal returns (uint256 id) {
        usdc.mint(alice, 5_000e6);
        vm.startPrank(alice);
        usdc.approve(address(ace), 5_000e6);
        ace.deposit(mid, 5_000e6);
        vm.stopPrank();

        probe.mint(borrower, COLL);
        vm.startPrank(borrower);
        probe.approve(address(positionManager), COLL);
        id = ace.open(mid, COLL, PRINCIPAL, 0, borrower, OpenBounds(0, 0, 0));
        vm.stopPrank();

        record.setBelow(true);
        vm.prank(keeper);
        ace.finalize(id);
        record.setBelow(false);
        vm.warp(read.inventoryAskOpensAt(id)); // the ask rests after settlement; the redeem legs never do
    }

    /// @dev redeemInKind: the pot, the claim and the owed pot must all be final at transfer time.
    /// @dev WAS a HALF redemption against a receipt balance. The ledger is gone and the pot is the lender's
    /// @dev outright, so a redemption takes all of it; what the observer must not see stale is unchanged.
    function test_RedeemInKindIsFullyWrittenBeforeThePayout() public {
        uint256 id = _settledLoan();
        probe.arm(address(ace), address(read), mid, id, alice);
        probe.armPayer(address(positionManager)); // the pot is delivered out of the one custodian

        vm.prank(alice);
        uint256 out = ace.redeemInKind(id, alice);
        assertGt(out, 0, "the redeem really did pay, so the probe really did fire");
        assertEq(probe.snaps(), 1, "the payout transfer fired the observer exactly once");

        assertEq(probe.potSeen(), read.invPotOf(mid, id), "the observer saw the DEBITED pot, not the stale one");
        assertEq(probe.owedSeen(), read.poolOwed(mid), "and the final owed mirror");
        assertEq(probe.unitsSeen(), read.claimOf(mid, id), "and the RETIRED claim, not the old one");
        assertEq(probe.restingSeen(), ace.restingOf(mid), "and a settled resting read");
    }

    /// @dev The per-loan ask: same rule on the other side, where the proceeds also raise the payout index.
    function test_BuyInventoryIsFullyWrittenBeforeThePayout() public {
        uint256 id = _settledLoan();
        probe.arm(address(ace), address(read), mid, id, alice);
        probe.armPayer(address(positionManager)); // the pot is delivered out of the one custodian
        uint256 owedBefore = read.poolOwed(mid);
        uint256 aliceHad = usdc.balanceOf(alice);

        usdc.mint(buyer, 1_000e6);
        vm.startPrank(buyer);
        usdc.approve(address(ace), 1_000e6);
        (uint256 unitsOut, uint256 filled) = ace.buyInventory(id, 1_000e6, 1, buyer);
        vm.stopPrank();
        assertGt(unitsOut, 0, "the ask really did fill, so the probe really did fire");
        assertEq(probe.snaps(), 1, "the collateral release fired the observer exactly once");

        assertEq(probe.potSeen(), read.invPotOf(mid, id), "the observer saw the DEBITED pot");
        assertEq(probe.owedSeen(), owedBefore + filled, "and the owed mirror already carrying the proceeds");
        assertEq(read.poolOwed(mid), probe.owedSeen(), "which is the final owed mirror: the sale writes nothing after the release");
        assertEq(usdc.balanceOf(alice), aliceHad, "and pays the lender nothing in the buyer's call");
    }

    /// @dev The reads a pricing integrator would make must also be stable across a redeem that reverts.
    /// @dev The REFUSAL is a stranger's now: it used to be an oversized burn against the caller's receipt
    /// @dev balance, and with no balance to oversize, what the door still refuses is a caller who is not the lender.
    function test_RefusedRedeemLeavesNoObservableTrace() public {
        uint256 id = _settledLoan();
        uint256 pot0 = read.invPotOf(mid, id);
        uint256 owed0 = read.poolOwed(mid);
        probe.arm(address(ace), address(read), mid, id, alice);

        vm.prank(buyer); // not the market's named lender, so the pot is not theirs to take
        vm.expectRevert();
        ace.redeemInKind(id, buyer);

        assertEq(probe.snaps(), 0, "a refused redeem never reached a transfer");
        assertEq(read.invPotOf(mid, id), pot0, "and left the pot exactly as it was");
        assertEq(read.poolOwed(mid), owed0, "and the owed mirror with it");
    }
}
