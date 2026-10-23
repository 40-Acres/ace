// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.36;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {VestingWallet} from "@openzeppelin/contracts/finance/VestingWallet.sol";
import {VestingWalletUpgradeable} from "../../vendor/oz-upgradeable/VestingWalletUpgradeable.sol";
import {LaunchOpsBudget} from "../../src/entities/launch/LaunchOpsBudget.sol";
import {LaunchTokenFactory} from "../../src/entities/launch/LaunchTokenFactory.sol";
import {RunwayFixture} from "./RunwayFixture.sol";

/// @notice An auction whose sweep, the one untrusted call `settle` makes, tries to initialize the budget's fresh wallet to a thief.
contract WalletGrabbingAuction {
    uint64 public endBlock;
    uint64 public lastCheckpointedBlock;
    uint256 public currencyRaisedQ96X7;
    bool public grabbed; // the thief's initialize landed
    address internal immutable THIEF;

    constructor(address thief) {
        THIEF = thief;
    }

    function setEnd(uint64 e) external {
        (endBlock, lastCheckpointedBlock) = (e, e);
    }

    function sweepUnsoldTokens() external {
        address w = LaunchOpsBudget(msg.sender).wallet();
        try VestingWalletUpgradeable(payable(w)).initialize(THIEF, 0, 0) {
            grabbed = true;
        } catch {}
    }
}

/// @title RunwayWalletCloneHardening
/// @notice The clone-then-initialize order `settle` relies on, pinned against the one call it makes outside OpenZeppelin's code.
/// @notice The review's "no external call between the CREATE and `initialize`" is what keeps a hostile sweep from owning the wallet.
contract RunwayWalletCloneHardeningTest is RunwayFixture {
    /// @notice A sweep that tries to initialize the fresh wallet finds it already owned by the operator, so settlement completes.
    /// @notice Kills `initialize` moved after the sweep: the thief would own the wallet first, and every settle would then revert.
    function test_TheSweepFindsTheWalletAlreadyOwned() public {
        WalletGrabbingAuction a = new WalletGrabbingAuction(stranger);
        strat.setNext(address(a));
        LaunchTokenFactory.LaunchInput memory p = _input();
        uint256 launchBy = _launchBy(p);
        vm.prank(team);
        address t = factory.launch(p);
        (,, address b) = factory.launchOf(t);
        a.setEnd(p.endBlock);
        strat.send(t, b, SUPPLY); // a failed migration's recovery returns the whole reserve
        _warpTo(launchBy + 1);
        LaunchOpsBudget(b).settle();
        VestingWallet w = VestingWallet(payable(LaunchOpsBudget(b).wallet()));
        assertFalse(a.grabbed(), "the sweep initialized the wallet before the budget did");
        assertEq(w.owner(), operator, "the wallet vests to another");
        assertEq(IERC20(t).balanceOf(address(w)), OPS, "the wallet does not hold the ops tokens");
    }

    /// @notice The settled wallet is an EIP-1167 minimal proxy delegating to the budget's WALLET_IMPL, byte for byte.
    /// @notice It proves "clones, never deploys" by code shape rather than by gas, so no optimizer setting or gas schedule can move it.
    function test_TheWalletIsAMinimalCloneOfTheImplementation() public {
        Made memory m = _launch();
        m.auction.setState(m.auction.endBlock(), true, 0);
        strat.send(m.token, address(m.budget), SUPPLY);
        _warpTo(m.launchBy + 1);
        m.budget.settle();
        address impl = m.budget.WALLET_IMPL();
        bytes memory want = abi.encodePacked(hex"363d3d373d3d3d363d73", impl, hex"5af43d82803e903d91602b57fd5bf3");
        assertEq(m.budget.wallet().code, want, "the wallet is not a minimal clone of the budget's implementation");
        assertEq(impl, LaunchOpsBudget(factory.BUDGET_IMPL()).WALLET_IMPL(), "the clone's implementation is not the budget implementation's");
        assertGt(impl.code.length, 45, "fixture: the implementation carries the wallet's code");
    }
}
