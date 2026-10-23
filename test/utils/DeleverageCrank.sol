// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.36;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {IAceDeleverageCallback} from "../../src/interfaces/IAceDeleverageCallback.sol";

interface IMintable {
    function mint(address to, uint256 amount) external;
}

/// @notice Makes a test contract its own deleverage keeper: inherit it and name the quote token.
/// @dev Solver routing means an EOA cannot crank, so every suite that cranks needs a callback somewhere.
/// @dev On the test contract it keeps the existing call sites in their original shape.
/// @dev Only suites asserting on a SEPARATE keeper's balance need `MockDeleverageKeeper`.
/// @dev Pays exactly what ACE asks and keeps nothing, so it never perturbs a waterfall assertion.
abstract contract DeleverageCrank is IAceDeleverageCallback {
    uint256 public lastQuoteOwed; // what ACE quoted on the last crank; assert against it, never a restated floor
    uint256 public lastUnitsSold;

    /// @dev The quote token to mint and approve; a suite returns its own `address(usdc)`.
    function _deleverageQuote() internal view virtual returns (address);

    function onAceDeleverage(uint256 unitsSold, uint256 quoteOwed, bytes calldata data) external virtual {
        _deleverageCallback(unitsSold, quoteOwed, data);
    }

    /// @dev The body, reachable from a subclass: `super` cannot reach an EXTERNAL override.
    function _deleverageCallback(uint256 unitsSold, uint256 quoteOwed, bytes calldata) internal virtual {
        lastUnitsSold = unitsSold;
        lastQuoteOwed = quoteOwed;
        address q = _deleverageQuote();
        IMintable(q).mint(address(this), quoteOwed); // stands in for the route's proceeds
        IERC20(q).approve(msg.sender, quoteOwed);
    }
}
