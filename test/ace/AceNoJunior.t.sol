// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.36;

import {Test} from "forge-std/Test.sol";
import {Ace} from "../../src/ace/hub/Ace.sol";
import {MarketParams} from "../../src/ace/hub/Types.sol";
import {PositionManager} from "../../src/ace/positions/PositionManager.sol";
import {MockERC20} from "../mocks/MockERC20.sol";
import {MockPersistenceRecord} from "../mocks/MockPersistenceRecord.sol";
import {AceFixtures} from "../utils/AceFixtures.sol";

/// @title AceNoJunior
/// @notice The deletion tripwire: the junior/coverage surface must not dispatch, ever again.
/// @dev v1 has no junior tranche, and the sell-walk skip died with it (bids-only).
/// @dev Every selector is called by RAW `abi.encodeWithSignature`, so this compiles with the functions gone.
/// @dev That pins the ruling against silent re-accretion, which a compile error cannot do.
contract AceNoJuniorTest is Test {
    Ace internal ace;
    PositionManager internal positionManager;
    MockERC20 internal usdc;
    MockERC20 internal vmon;
    bytes32 internal id;

    uint256 internal T2; // par for this pair; assigned in setUp, since par is not a compile-time value

    /// @dev This suite's pair, so a tick reads as its distance from par rather than as a grid coordinate.
    /// @param offset Ticks above par.
    /// @return The absolute grid tick.
    function _price(int24 offset) internal view returns (uint256) {
        return AceFixtures.priceAt(address(usdc), address(vmon), offset);
    }

    function setUp() public {
        usdc = new MockERC20("USD Coin", "USDC", 6);
        vmon = new MockERC20("Staked MON", "vMON", 18);
        T2 = _price(0);

        MarketParams memory p = AceFixtures.marketParams(address(usdc), address(vmon));
        p.record = address(new MockPersistenceRecord(address(usdc), address(vmon)));
        p.lender = address(this); // the live-door row below deposits as the test contract, and only the lender may
        AceFixtures.Deployment memory d = AceFixtures.deploy(p);
        (ace, positionManager, id) = (d.ace, d.positionManager, d.id);
    }

    /// @dev THE DISCRIMINATOR: `Ace` has no fallback or receive, so an unimplemented selector reverts EMPTY.
    /// @dev A live function that merely rejects reverts with its own error or string, which is non-empty.
    /// @dev Asserting `!ok` alone would pass on any revert and make this suite vacuous.
    function _assertNoDispatch(bytes memory call, string memory what) internal {
        (bool ok, bytes memory ret) = address(ace).call(call);
        assertFalse(ok, what);
        assertEq(ret.length, 0, string.concat(what, ": reverted with data, so the selector still dispatches"));
    }

    function test_JuniorSeedSurface_DoesNotDispatch() public {
        _assertNoDispatch(abi.encodeWithSignature("depositSeed(bytes32,int24,uint256)", id, T2, 1e6), "depositSeed/3");
        _assertNoDispatch(abi.encodeWithSignature("depositSeed(bytes32,int24,uint256,int24)", id, T2, 1e6, T2), "depositSeed/4");
        _assertNoDispatch(abi.encodeWithSignature("depositSeed(bytes32,int24,uint256,int24,uint32,uint40)", id, T2, 1e6, T2, 0, 0), "depositSeed/6");
        _assertNoDispatch(abi.encodeWithSignature("withdrawSeed(bytes32,int24,uint256)", id, T2, 1), "withdrawSeed");
    }

    function test_CoverageSurface_DoesNotDispatch() public {
        _assertNoDispatch(abi.encodeWithSignature("deposit(bytes32,int24,uint256,int24)", id, T2, 1e6, T2), "deposit with coverTick");
        _assertNoDispatch(abi.encodeWithSignature("releaseExpired(bytes32,int24)", id, T2), "releaseExpired");
    }

    /// @dev `depositAtHorizon` is GONE, and so is the full-form deposit that briefly replaced it: a market's
    /// @dev `maxTenor` is its whole maturity consent, fixed at genesis, so a deposit names no term at all.
    /// @dev BOTH tick-carrying shapes are pinned as undispatchable, and the surviving two-argument door works.
    function test_DepositAtHorizon_AndTheTickCarryingFormAreBothGone() public {
        _assertNoDispatch(abi.encodeWithSignature("depositAtHorizon(bytes32,int24,uint256,uint64)", id, T2, 1e6, uint64(7 days)), "depositAtHorizon is gone");
        _assertNoDispatch(abi.encodeWithSignature("deposit(bytes32,int24,uint256,uint64)", id, T2, 1e6, uint64(7 days)), "so is the tick-and-horizon deposit");

        usdc.mint(address(this), 1_000e6);
        usdc.approve(address(ace), 1_000e6);
        (bool ok,) = address(ace).call(abi.encodeWithSignature("deposit(bytes32,uint256)", id, uint256(1_000e6)));
        assertTrue(ok, "and the door a lender actually has takes the market and the amount, nothing else");
    }

    /// @dev The universal envelope no longer reads a junior bound, so `IRiskBounds` must not ask for it.
    function test_RiskBounds_DoNotReadAJuniorSpread() public {
        _assertNoDispatch(abi.encodeWithSignature("JUNIOR_SPREAD_BPS()"), "the hub exposes no junior surface");
    }
}
