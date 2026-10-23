// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.36;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {IERC20Errors} from "@openzeppelin/contracts/interfaces/draft-IERC6093.sol";
import {IHooks} from "@uniswap/v4-core/src/interfaces/IHooks.sol";
import {IPoolManager} from "@uniswap/v4-core/src/interfaces/IPoolManager.sol";
import {StateLibrary} from "@uniswap/v4-core/src/libraries/StateLibrary.sol";
import {Currency} from "@uniswap/v4-core/src/types/Currency.sol";
import {PoolId, PoolIdLibrary} from "@uniswap/v4-core/src/types/PoolId.sol";
import {PoolKey} from "@uniswap/v4-core/src/types/PoolKey.sol";
import {LaunchOpsBudget} from "../../src/entities/launch/LaunchOpsBudget.sol";
import {LaunchTokenFactory} from "../../src/entities/launch/LaunchTokenFactory.sol";
import {MockLaunchAuction} from "./MockLaunchAuction.sol";
import {RunwayFixture} from "./RunwayFixture.sol";
import {RunwaySalt} from "./RunwayMocks.sol";

/// @title RunwayHardening
/// @notice The factory and token rows a mutation pass found unpinned; each row names the mutant it kills.
/// @notice A token sorting above its quote, and DEAD never sending.
contract RunwayHardeningTest is RunwayFixture {
    using PoolIdLibrary for PoolKey;
    using StateLibrary for IPoolManager;

    uint160 internal constant PRICE = 1 << 96;
    address internal constant LOW_QUOTE = address(0x10000); // a quote every launch token sorts above

    /// @notice A launch token that sorts ABOVE its quote records, and opens, the sorted key: the quote is currency0.
    /// @notice Every other launch, unit and fork, mints a token that sorts below its quote, so only this row reads the other arm.
    /// @notice Kills a key that always puts the token first: the recorded key would never be the one the strategy opens.
    function test_ATokenAboveItsQuoteRecordsTheSortedKey() public {
        vm.etch(LOW_QUOTE, address(usdc).code);
        address at = vm.computeCreateAddress(address(this), vm.getNonce(address(this)));
        bytes32 salt = RunwaySalt.mine(at, address(manager), address(strat));
        LaunchTokenFactory f = new LaunchTokenFactory(address(ace), address(strat), LOW_QUOTE, BLOCK_SECONDS, FEE, SPACING, salt, cutSink, 0);
        strat.setNext(address(new MockLaunchAuction()));
        LaunchTokenFactory.LaunchInput memory p = _input();
        uint256 launchBy = _launchBy(p);
        vm.prank(team);
        address t = f.launch(p);
        assertGt(uint160(t), uint160(LOW_QUOTE), "fixture: the token sorts above its quote");

        PoolKey memory k = PoolKey(Currency.wrap(LOW_QUOTE), Currency.wrap(t), FEE, SPACING, IHooks(address(f.HOOK())));
        (,, address budget) = f.launchOf(t);
        assertEq(f.launchByOf(k.toId()), launchBy, "the sorted key is not the recorded one");
        assertEq(PoolId.unwrap(LaunchOpsBudget(budget).terms().pool), PoolId.unwrap(k.toId()), "the budget names another pool");
        strat.openPool(k, PRICE);
        (uint160 sqrtP,,,) = IPoolManager(address(manager)).getSlot0(k.toId());
        assertEq(sqrtP, PRICE, "the strategy could not open the sorted key");
    }

    /// @notice DEAD never holds a launch token, so it never sends one: a transfer from DEAD reverts on its empty balance, and the supply stands.
    /// @notice Kills an override that also rewrote a send FROM DEAD, which would turn it into a mint out of nothing.
    function test_DeadCannotSendWhatItNeverHolds() public {
        Made memory m = _launch();
        uint256 supply = IERC20(m.token).totalSupply();
        vm.prank(DEAD);
        vm.expectRevert(abi.encodeWithSelector(IERC20Errors.ERC20InsufficientBalance.selector, DEAD, 0, 1));
        IERC20(m.token).transfer(alice, 1);
        assertEq(IERC20(m.token).totalSupply(), supply, "a send from DEAD moved the supply");
        assertEq(IERC20(m.token).balanceOf(alice), 0, "a send from DEAD paid someone");
    }
}
