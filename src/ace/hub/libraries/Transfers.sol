// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.36;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {Permits} from "./Permits.sol";
import {Cfg} from "../Types.sol";

error FeeOnTransferUnsupported(); // the pull delivered less than it moved

/// @title Transfers
/// @notice Every token the hub pulls IN, balance-checked so a fee-on-transfer token is refused not absorbed.
/// @dev The hub only ever pulls TO ITSELF against an allowance the owner granted.
library Transfers {
    using SafeERC20 for IERC20;

    /// @dev Pulls exactly `amount` of `token`; a fee-on-transfer token is refused rather than under-credited.
    /// @dev Named for the TOKEN rather than a `Cfg`: the permit path pulls COLLATERAL, which no quote names.
    function pullToken(address token, address from, uint256 amount) internal {
        IERC20 t = IERC20(token);
        uint256 pre = t.balanceOf(address(this));
        t.safeTransferFrom(from, address(this), amount);
        if (t.balanceOf(address(this)) - pre != amount) revert FeeOnTransferUnsupported();
    }

    /// @dev Pulls exactly `amount` of quote; every pull credits books, so a fee-on-transfer quote is unsupported.
    function pullQuote(Cfg memory c, address from, uint256 amount) internal {
        pullToken(c.p.quote, from, amount);
    }

    /// @dev `pullToken` funded by a Permit2 SignatureTransfer; an empty blob is the plain path, verbatim.
    function pullTokenPermit(address token, address from, uint256 amount, bytes calldata permit2) internal {
        if (permit2.length == 0) return pullToken(token, from, amount);
        IERC20 t = IERC20(token);
        uint256 pre = t.balanceOf(address(this));
        Permits.pull(token, from, amount, permit2);
        if (t.balanceOf(address(this)) - pre != amount) revert FeeOnTransferUnsupported();
    }

    /// @dev `pullQuote` funded by a Permit2 SignatureTransfer; same delta guard, same books.
    function pullQuotePermit(Cfg memory c, address from, uint256 amount, bytes calldata permit2) internal {
        pullTokenPermit(c.p.quote, from, amount, permit2);
    }
}
