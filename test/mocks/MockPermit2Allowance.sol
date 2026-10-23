// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.36;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";

/// @title MockPermit2Allowance
/// @notice Permit2's AllowanceTransfer half, as the canonical contract runs it, for etching at the canonical address in unit rows.
/// @notice An allowance of expiration zero is stored as the current second; a pull past the stored expiration reverts.
/// @notice A max allowance never decrements; any other one decrements by each pull and refuses a pull over it.
/// @dev It counts every pull that reaches the token, so a row can pin how many Permit2 calls a verb made.
contract MockPermit2Allowance {
    struct PackedAllowance {
        uint160 amount;
        uint48 expiration;
        uint48 nonce;
    }

    error AllowanceExpired(uint256 deadline);
    error InsufficientAllowance(uint256 amount);
    error InvalidNonce();

    mapping(address owner => mapping(address token => mapping(address spender => PackedAllowance))) public allowance;
    uint256 public pulls; // transferFrom calls that reached the token

    /// @notice Permit2's own `approve`: the caller sets its allowance for `spender`, keeping the nonce.
    function approve(address token, address spender, uint160 amount, uint48 expiration) external {
        PackedAllowance storage a = allowance[msg.sender][token][spender];
        (a.amount, a.expiration) = (amount, expiration == 0 ? uint48(block.timestamp) : expiration);
    }

    /// @notice A signed permit's effect without the signature: the nonce must match, and it moves on by one.
    function permitAs(address owner, address token, address spender, uint160 amount, uint48 expiration, uint48 nonce) external {
        PackedAllowance storage a = allowance[owner][token][spender];
        if (a.nonce != nonce) revert InvalidNonce();
        (a.amount, a.expiration, a.nonce) = (amount, expiration == 0 ? uint48(block.timestamp) : expiration, nonce + 1);
    }

    /// @notice Permit2's `transferFrom`: the caller spends `from`'s allowance for it, and the token moves on `from`'s approval of Permit2.
    function transferFrom(address from, address to, uint160 amount, address token) external {
        PackedAllowance storage a = allowance[from][token][msg.sender];
        if (block.timestamp > a.expiration) revert AllowanceExpired(a.expiration);
        if (a.amount != type(uint160).max) {
            if (amount > a.amount) revert InsufficientAllowance(a.amount);
            a.amount -= amount;
        }
        ++pulls;
        require(IERC20(token).transferFrom(from, to, amount), "mock: the token refused");
    }
}
