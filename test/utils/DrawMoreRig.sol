// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.36;

import {IERC721} from "@openzeppelin/contracts/token/ERC721/IERC721.sol";
import {Loan, OpenBounds} from "../../src/ace/hub/Types.sol";
import {ExtendRig} from "./ExtendRig.sol";
import {YesPolicy} from "./RollPolicyMocks.sol";

/// @notice The top-up surface by signature, so a suite reaches it through one typed handle.
interface IAceDrawMore {
    function drawMore(uint256 id, uint256 amount, OpenBounds calldata bnd) external returns (uint256 fee);
    function addCollateral(uint256 id, uint256 units, bytes calldata permit2) external;
    function tryDrawMore(uint256 id, uint256 amount, OpenBounds calldata bnd, address caller)
        external
        view
        returns (bool ok, bytes4 reason, uint256 fee, uint64 term);
}

/// @title DrawMoreRig
/// @notice `ExtendRig` with the top-up surface: a yes policy for `alice`, a long term with room past its open, and the draw's helpers.
/// @dev A top-up is floored at `minTenor` of term left, so the suites open at `LONG` and top up while at least `TEN7` remains.
abstract contract DrawMoreRig is ExtendRig {
    uint64 internal constant LONG = 28 days; // the rig's maxTenor: room for a top-up after the open
    IAceDrawMore internal hub;
    YesPolicy internal yes;
    IERC721 internal titles;

    event Funded(uint256 indexed loanId, uint256 amount, address indexed to);
    event DrewMore(uint256 indexed id, uint256 amount, uint256 fee, uint64 term, uint256 debt, address indexed executor);
    event CollateralAdded(uint256 indexed id, address indexed payer, uint256 units, uint256 unitsAfter, uint256 trigger);
    event Extended(uint256 indexed id, uint64 added, uint64 newExpiry, uint256 fee, address indexed executor);

    function setUp() public virtual override {
        super.setUp();
        hub = IAceDrawMore(address(ace));
        titles = IERC721(ace.POSITION_TITLE());
        yes = new YesPolicy();
        _setPolicy(alice, address(yes));
    }

    function _none() internal pure returns (OpenBounds memory) {
        return OpenBounds(0, 0, 0);
    }

    /// @dev The term a top-up of `loanId` is charged on now: its expiry less the clock.
    function _termLeft(uint256 loanId) internal view returns (uint64) {
        return uint64(read.loan(loanId).expiry - _now());
    }

    /// @dev The fee a top-up of `amount` on `loanId` charges now: the origination fee on the term left.
    function _topFee(uint256 loanId, uint256 amount) internal view returns (uint256) {
        return _fee(amount, _termLeft(loanId));
    }

    /// @dev `who` tops `loanId` up by `amount` with no bounds.
    function _top(address who, uint256 loanId, uint256 amount) internal returns (uint256 fee) {
        vm.prank(who);
        fee = hub.drawMore(loanId, amount, _none());
    }

    /// @dev `payer` is minted `units` of collateral, approves custody, and adds them to `loanId`.
    function _add(address payer, uint256 loanId, uint256 units) internal {
        coll.mint(payer, units);
        vm.startPrank(payer);
        coll.approve(address(pm), units);
        hub.addCollateral(loanId, units, "");
        vm.stopPrank();
    }

    /// @dev The preview refuses `who`'s top-up with `err`, at no fee and no term, and the verb then reverts with exactly that selector.
    function _refusedTop(address who, uint256 loanId, uint256 amount, OpenBounds memory bnd, bytes4 err) internal {
        (bool ok, bytes4 why, uint256 fee, uint64 term) = hub.tryDrawMore(loanId, amount, bnd, who);
        assertFalse(ok, "the preview admitted a top-up the verb refuses");
        assertEq(why, err, "the preview named another leg");
        assertEq(fee, 0, "a refused preview quotes no fee");
        assertEq(term, 0, "a refused preview quotes no term");
        vm.prank(who);
        vm.expectRevert(err);
        hub.drawMore(loanId, amount, bnd);
    }

    /// @dev The term identity a top-up keeps: the schedule opens no earlier than one tenor before expiry, and never after it.
    function _assertTermBounds(uint256 loanId) internal view {
        Loan memory l = read.loan(loanId);
        assertLe(uint256(l.expiry) - l.tenor, l.openTime, "I1: the schedule opens more than a tenor before expiry");
        assertLe(l.openTime, l.expiry, "I1: the schedule opens after expiry");
    }
}
