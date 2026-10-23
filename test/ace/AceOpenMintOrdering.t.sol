// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.36;

import {Test} from "forge-std/Test.sol";
import {Ace} from "../../src/ace/hub/Ace.sol";
import {MarketParams} from "../../src/ace/hub/Types.sol";
import {PositionManager} from "../../src/ace/positions/PositionManager.sol";
import {MockERC20} from "../mocks/MockERC20.sol";
import {MockSendHookERC20} from "../mocks/MockSendHookERC20.sol";
import {MockPersistenceRecord} from "../mocks/MockPersistenceRecord.sol";
import {AceFixtures} from "../utils/AceFixtures.sol";
import {WindowProbe} from "./AceLoansInMarketWindow.t.sol";

/// @title AceOpenMintOrderingTest
/// @notice I8 at the EARLIEST observable point in `Borrower.open`, not the latest.
/// @dev `AceLoansInMarketWindow` hooks the principal payout, the last external call in the function.
/// @dev It therefore proves only "minted before the payout".
/// @dev The ruling is stronger: both secondary ledgers land before ANY external call.
/// @dev Demonstrated gap -- moving the mint to just before the payout leaves that suite green.
/// @dev `IPositionManager.pull` is the first external call after `_record`, and a sender hook reaches it.
/// @dev Collateral is the hooking token here; the quote stays plain, so only the pull is observed.
contract AceOpenMintOrderingTest is Test {
    Ace internal ace;
    PositionManager internal positionManager;
    MockPersistenceRecord internal record;
    MockERC20 internal usdc;
    MockSendHookERC20 internal coll;
    WindowProbe internal probe;
    bytes32 internal id_;

    address internal alice = address(0xA11CE);

    uint256 constant COLL = 10_000e18;
    uint256 constant PRINCIPAL = 4_500e6;

    uint256 internal T3; // ticks above this pair's par; assigned in setUp, since par is not a compile-time value
    uint256 internal T4;

    /// @dev This suite's pair, so a tick reads as its distance from par rather than as a grid coordinate.
    /// @param offset Ticks above par.
    /// @return The absolute grid tick.
    function _price(int24 offset) internal view returns (uint256) {
        return AceFixtures.priceAt(address(usdc), address(coll), offset);
    }

    function setUp() public {
        vm.warp(1_000_000);
        usdc = new MockERC20("USD Coin", "USDC", 6);
        coll = new MockSendHookERC20("Collateral", "COLL", 18);
        (T3, T4) = (_price(480), _price(960));
        record = new MockPersistenceRecord(address(usdc), address(coll));
        record.setObserved(AceFixtures.px(1e18, address(usdc), address(coll)));
        record.setMinPrice(AceFixtures.px(2e18, address(usdc), address(coll)));

        MarketParams memory p = AceFixtures.marketParams(address(usdc), address(coll));
        p.record = address(record);

        AceFixtures.Deployment memory d = AceFixtures.deploy(p);
        (ace, positionManager, id_) = (d.ace, d.positionManager, d.id);

        probe = new WindowProbe(ace);
        probe.arm(id_, address(usdc), address(coll), address(positionManager));
        coll.setHookTarget(address(probe)); // fires when the probe PAYS collateral, i.e. at IPositionManager.pull

        usdc.mint(alice, 40_000e6);
        vm.startPrank(alice);
        usdc.approve(address(ace), 40_000e6);
        ace.deposit(id_, 20_000e6);
        ace.deposit(id_, 20_000e6);
        vm.stopPrank();

        coll.mint(address(probe), 10 * COLL);
        usdc.mint(address(probe), 10_000e6);
    }

    /// @notice The collateral pull is the FIRST external call `open` makes after writing the loan.
    /// @dev So the NFT must already exist by then, not merely by the payout at the end.
    /// @dev This is the assertion that fails if the mint drifts back down the function.
    function test_I8_AtTheEscrowPull_TheNftAlreadyExists() public {
        uint256 id = probe.doOpen(COLL, PRINCIPAL, 1);

        uint256 n = probe.snapCount();
        assertGt(n, 0, "the collateral pull must have fired the sender hook mid-open");

        uint256 checked;
        for (uint256 i; i < n; i++) {
            WindowProbe.Snap memory s = probe.snapAt(i);
            assertEq(s.titled, address(probe), "the hub is already titled at the pull");
            assertTrue(s.ownerAnswered, "I8: so ownerOf must already answer, this early");
            assertEq(s.owner, s.titled, "and the two ledgers must name the same holder");
            assertEq(s.listLength, 1, "the market list entry is already in place too");
            checked++;
        }
        assertGt(checked, 0, "VACUOUS: no snapshot was inspected");

        assertEq(ace.borrowerOf(id), address(probe), "settled state agrees once the call returns");
    }
}
