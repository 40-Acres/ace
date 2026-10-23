// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.36;

import {WarpClock} from "../utils/WarpClock.sol";
import {Ace} from "../../src/ace/hub/Ace.sol";
import {MarketParams, OpenBounds} from "../../src/ace/hub/Types.sol";
import {PositionManager} from "../../src/ace/positions/PositionManager.sol";
import {MockERC20} from "../mocks/MockERC20.sol";
import {MockBlockableERC20} from "../mocks/MockBlockableERC20.sol";
import {MockPersistenceRecord} from "../mocks/MockPersistenceRecord.sol";
import {AceFixtures} from "../utils/AceFixtures.sol";
import {AceReader} from "../utils/AceReader.sol";

/// @title AceP11WithdrawDestination
/// @notice Phase-11 variant PoC (M13, #381): `withdraw` was the one lender exit with no destination.
/// @notice FIXED: `withdraw` and the now lender-only `collect` both pay a `to` the lender names.
/// @notice The ported rows, on the pooled surface with a refusing quote, are `AceP2CollectDestinationTest`'s `test_381_*`.
/// @dev Variant of #179/#196's fixed-destination shape, on the quote side the #196 sweep did not reach.
/// @dev Findings: docs/ai/audit/runs/2026-08-31-fab1e1/phase11-variants.md
contract AceP11WithdrawDestinationTest is WarpClock {
    Ace internal ace;
    AceReader internal read;
    PositionManager internal pm;

    MockBlockableERC20 internal usdc; // the QUOTE, with the USDC per-address refusal shape
    MockERC20 internal coll;
    MockPersistenceRecord internal record;
    bytes32 internal mid;

    address internal alice = address(0xA11CE); // the lender the quote comes to refuse
    address internal borrower = address(0xB0B);

    uint256 internal TICK; // ticks above this pair's par; assigned in setUp, since par is not a compile-time value
    uint256 internal CAP; // the draw cap in the hub's frame; assigned in setUp
    uint256 internal constant DEPOSIT = 20_000e6;
    uint256 internal constant PRINCIPAL = 4_500e6;
    uint256 internal constant COLL = 10_000e18;

    OpenBounds internal OFF = OpenBounds(0, 0, 0);

    /// @dev This suite's pair, so a tick reads as its distance from par rather than as a grid coordinate.
    /// @param offset Ticks above par.
    /// @return The absolute grid tick.
    function _price(int24 offset) internal view returns (uint256) {
        return AceFixtures.priceAt(address(usdc), address(coll), offset);
    }

    function setUp() public {
        _warpTo(1_000_000);
        usdc = new MockBlockableERC20("USD Coin", "USDC", 6);
        coll = new MockERC20("Collateral", "COLL", 18);
        TICK = _price(960);
        CAP = AceFixtures.px(2e18, address(usdc), address(coll));
        record = new MockPersistenceRecord(address(usdc), address(coll));
        record.setObserved(AceFixtures.px(1e18, address(usdc), address(coll)));
        record.setMinPrice(CAP);

        MarketParams memory p = AceFixtures.marketParams(address(usdc), address(coll));
        p.record = address(record);
        AceFixtures.Deployment memory d = AceFixtures.deploy(p);
        (ace, pm, read, mid) = (d.ace, d.positionManager, d.read, d.id);
    }

    /// @notice CONTROL: an unblocked lender withdraws the whole deposit to their own address, with no floor.
    /// @dev It proves this file's rig and nothing more; the refused-lender rows run on their own fixture.
    function test_P11_Control_UnblockedLender_WithdrawsTheSameLot() public {
        _lend(DEPOSIT);
        vm.prank(alice);
        uint256 got = ace.withdraw(mid, type(uint256).max, alice, 0);
        assertEq(got, DEPOSIT, "control: an unrefused lender takes the whole lot back");
    }

    /* ================================= fixture ================================= */

    function _lend(uint256 amt) internal {
        usdc.mint(alice, amt);
        vm.startPrank(alice);
        usdc.approve(address(ace), amt);
        ace.deposit(mid, amt);
        vm.stopPrank();
    }

    function _draw() internal returns (uint256 loanId) {
        coll.mint(borrower, COLL);
        vm.startPrank(borrower);
        coll.approve(address(pm), COLL);
        loanId = ace.open(mid, COLL, PRINCIPAL, 0, borrower, OFF);
        vm.stopPrank();
    }
}
