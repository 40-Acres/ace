// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.36;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {Ownable} from "@openzeppelin/contracts/access/Ownable.sol";
import {Ownable2Step} from "@openzeppelin/contracts/access/Ownable2Step.sol";
import {ReentrancyGuardTransient} from "@openzeppelin/contracts/utils/ReentrancyGuardTransient.sol";

/// @title RevenueRouter
/// @notice The hub's fixed revenue destination: an owned pointer to a sink, and a permissionless sweep to it.
/// @notice The owner can redirect all future protocol revenue until it renounces; renouncing makes the sink final.
/// @dev The hub pays in with a plain ERC-20 transfer, so nothing here runs on the way in and there is no ledger.
/// @dev ERC-20 only: no receive or fallback, so ETH is refused rather than stranded.
/// @dev The inherited ownership verbs carry no guard: each only writes owner storage and calls nothing out.
contract RevenueRouter is Ownable2Step, ReentrancyGuardTransient {
    using SafeERC20 for IERC20;

    error InvalidSink(); // zero or this contract

    address public sink;

    /// @notice The sink moved.
    event SinkSet(address indexed previous, address indexed sink);
    /// @notice A token's whole balance was sent to the sink.
    event Swept(address indexed token, address indexed sink, uint256 amount);
    /// @notice The transfer did not report success; whatever balance it left here waits for the next sweep.
    event SweepFailed(address indexed token, address indexed sink, uint256 amount);

    constructor(address owner_, address sink_) Ownable(owner_) {
        _setSink(sink_);
    }

    /// @notice Repoint the sink; every later sweep pays the new one.
    /// @param s The new sink.
    function setSink(address s) external onlyOwner nonReentrant {
        _setSink(s);
    }

    /// @notice Send each listed token's whole balance to the sink.
    /// @dev A refusing token is reported and skipped; one whose balanceOf reverts, or that burns the gas, can fail the call.
    /// @dev The caller picks the list, so a token that fails the call is simply left off it.
    /// @param tokens The tokens to sweep; a zero balance or a repeat is skipped.
    function sweep(address[] calldata tokens) external nonReentrant {
        address to = sink;
        for (uint256 i; i < tokens.length; ++i) {
            IERC20 t = IERC20(tokens[i]);
            uint256 bal = t.balanceOf(address(this));
            if (bal == 0) continue;
            if (t.trySafeTransfer(to, bal)) emit Swept(address(t), to, bal);
            else emit SweepFailed(address(t), to, bal);
        }
    }

    function _setSink(address s) private {
        if (s == address(0) || s == address(this)) revert InvalidSink();
        emit SinkSet(sink, s);
        sink = s;
    }
}
