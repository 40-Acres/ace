// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.36;

import {AceFixtures} from "../utils/AceFixtures.sol";
import {PushCostRig} from "../utils/PushCostRig.sol";

/// @title AcePushCostSizingFork
/// @notice Live USDC (FiatTokenProxy over FiatTokenV2_2) and live USDT on a mainnet fork, measured by the push-cost rig.
/// @dev The all-cold copies are the LIVE bytecode etched at fresh addresses, USDC's each over its own etched implementation.
/// @dev Only the balance words are seeded, by `deal`; every other word reads zero, which prices an SLOAD the same as the live value.
/// @dev Skipped cleanly when ALCHEMY_API_KEY is absent, as the other fork suites are; `ACE_FORK_BLOCK` pins the block.
/// @dev Read the table with `scripts/test-trace.sh test/fork/AcePushCostSizingFork.t.sol PUSH-COST 0`, under `FOUNDRY_PROFILE=deploy`.
contract AcePushCostSizingForkTest is PushCostRig {
    address internal constant USDC = 0xA0b86991c6218b36c1d19D4a2e9Eb0cE3606eB48;
    address internal constant USDT = 0xdAC17F958D2ee523a2206206994597C13D831ec7;
    bool internal live;

    /// @dev `POOL` copies of a live token at fresh addresses; a proxy's copies each get their own implementation copy.
    function _etchPool(address token, address impl) internal {
        for (uint256 i; i < POOL; i++) {
            address copy = address(uint160(uint256(keccak256(abi.encode("push-cost copy", token, i)))));
            vm.etch(copy, token.code);
            if (impl != address(0)) {
                address implCopy = address(uint160(uint256(keccak256(abi.encode("push-cost impl copy", token, i)))));
                vm.etch(implCopy, impl.code);
                vm.store(copy, ZOS_IMPLEMENTATION_SLOT, bytes32(uint256(uint160(implCopy))));
            }
            _fund(copy, true, false);
            fresh[token].push(copy);
        }
    }

    function setUp() public {
        string memory key = vm.envOr("ALCHEMY_API_KEY", string(""));
        if (bytes(key).length == 0) return; // every test vm.skips on !live
        live = true;
        uint256 blockNum = vm.envOr("ACE_FORK_BLOCK", uint256(25_717_936));
        string memory url = string.concat("https://eth-mainnet.g.alchemy.com/v2/", key);
        if (blockNum == 0) vm.createSelectFork(url);
        else vm.createSelectFork(url, blockNum);
        ace = AceFixtures.newAce();
        lenderEmpty = makeAddr("push-cost empty lender");
        _fund(USDC, true, true);
        _fund(USDT, true, true);
        _etchPool(USDC, _implOf(USDC));
        _etchPool(USDT, address(0));
    }

    /// @notice Live USDC: the four states and the worst. All cold over warm is two accounts, three proxy/pause words, the hub word.
    function test_Fork_PushCost_LiveUsdc() public {
        if (!live) return vm.skip(true);
        emit log_named_uint("PUSH-COST | fork block", block.number);
        emit log_named_address("PUSH-COST | USDC implementation", _implOf(USDC));
        (Cost[4] memory cs, uint256 worst) = _shape("live USDC        ", USDC, _implOf(USDC), 2);
        emit log_named_uint("PUSH-COST | live USDC worst need", worst);
        assertEq(cs[2].used - cs[0].used, 2 * 2_500 + 3 * 2_000 + 4_800, "RIG: all cold must re-pay every word the warm-up pull read");
    }

    /// @notice Live USDT: the four states and the worst. All cold over warm is the account, the pause, deprecation and fee words, the hub word.
    function test_Fork_PushCost_LiveUsdt() public {
        if (!live) return vm.skip(true);
        emit log_named_uint("PUSH-COST | fork block", block.number);
        (Cost[4] memory cs, uint256 worst) = _shape("live USDT        ", USDT, address(0), 1);
        emit log_named_uint("PUSH-COST | live USDT worst need", worst);
        assertEq(cs[2].used - cs[0].used, 2_500 + 4 * 2_000 + 4_800, "RIG: all cold must re-pay every word the warm-up pull read");
    }
}
