// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.36;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {Ace} from "../../src/ace/hub/Ace.sol";
import {IAceDeleverageCallback} from "../../src/interfaces/IAceDeleverageCallback.sol";

interface IMintable {
    function mint(address to, uint256 amount) external;
}

/// @notice The solver-route stand-in: ACE releases units, this keeper "routes" them and returns the floor.
/// @notice Default behaviour pays exactly what ACE asks, which is what most twins want.
/// @dev `routePrice` models a router that CANNOT hand over more than it realized, so the keeper pays `min(owed, realized)`.
/// @dev An unreachable floor then surfaces as a failed pull rather than a mock that always complies; every other misbehaviour is its own knob.
contract MockDeleverageKeeper is IAceDeleverageCallback {
    Ace public immutable ACE;
    address public immutable QUOTE;
    IERC20 public immutable COLLATERAL;
    uint256 public immutable UNIT_SCALE;

    /// @dev Quote per collateral unit this keeper can actually route at; 0 means "always pay the floor".
    uint256 public routePrice;
    /// @dev Collateral units handed back unsold: the partial fill `_recreditRefund` exists for.
    uint256 public refundUnits;
    /// @dev The same refusal as a SHARE of what was released, preferred because a test cannot know the sized units before the crank.
    /// @dev An absolute figure would need a control loan, which is no control: a second loan funds a thinner ladder and sizes differently.
    uint256 public refundBps;
    /// @dev Quote withheld from the approval; one wei is enough to prove the floor binds.
    uint256 public shortfall;
    /// @dev Keep the units, approve nothing: the whole crank must revert.
    bool public payNothing;

    uint256 public lastUnitsSold;
    uint256 public lastQuoteOwed;

    constructor(Ace ace, address quote, address collateral, uint256 unitScale) {
        ACE = ace;
        QUOTE = quote;
        COLLATERAL = IERC20(collateral);
        UNIT_SCALE = unitScale;
    }

    function setRoutePrice(uint256 v) external {
        routePrice = v;
    }

    function setRefundUnits(uint256 v) external {
        refundUnits = v;
    }

    function setRefundBps(uint256 v) external {
        refundBps = v;
    }

    function setShortfall(uint256 v) external {
        shortfall = v;
    }

    function setPayNothing(bool v) external {
        payNothing = v;
    }

    function crankDeleverage(uint256 id) external returns (uint256, uint256) {
        return ACE.deleverage(id, 0, "");
    }

    function crankWithFloor(uint256 id, uint256 minStableOut) external returns (uint256, uint256) {
        return ACE.deleverage(id, minStableOut, "");
    }

    function onAceDeleverage(uint256 unitsSold, uint256 quoteOwed, bytes calldata) external virtual {
        lastUnitsSold = unitsSold;
        lastQuoteOwed = quoteOwed;
        uint256 refund = refundBps > 0 ? (unitsSold * refundBps) / 10000 : refundUnits;
        if (refund > 0) COLLATERAL.transfer(msg.sender, refund); // the tail the route refused
        if (payNothing) return;
        uint256 pay = quoteOwed;
        if (routePrice > 0) {
            uint256 realized = ((unitsSold - refund) * routePrice) / UNIT_SCALE;
            IMintable(QUOTE).mint(address(this), realized); // the route's whole proceeds
            if (realized < pay) pay = realized; // a router cannot hand over what it did not earn
        } else {
            IMintable(QUOTE).mint(address(this), pay);
        }
        IERC20(QUOTE).approve(msg.sender, pay - shortfall);
    }
}
