// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.36;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {IERC721} from "@openzeppelin/contracts/token/ERC721/IERC721.sol";
import {Ace} from "../../src/ace/hub/Ace.sol";
import {InsufficientCash, NotBorrower} from "../../src/ace/hub/Borrower.sol";
import {OpenBounds} from "../../src/ace/hub/Types.sol";
import {DrawMoreRig, IAceDrawMore} from "../utils/DrawMoreRig.sol";

/// @notice A test-only lender with a vault's shape: it rests cash only inside its own door and drains it before the door returns.
/// @notice So between its calls its market rests nothing, and a direct top-up there finds no cash to draw.
contract RestingDoorLender {
    Ace internal immutable ACE;
    IERC20 internal immutable QUOTE;
    IERC20 internal immutable COLLATERAL;
    bytes32 public market;

    constructor(Ace ace, address quote, address collateral) {
        (ACE, QUOTE, COLLATERAL) = (ace, IERC20(quote), IERC20(collateral));
    }

    function setMarket(bytes32 m) external {
        market = m;
    }

    /// @notice Lend `principal` against the caller's `units`: rest it, open as the transient borrower, drain, and hand title and payout over.
    function borrow(uint256 units, uint256 principal, uint64 tenor) external returns (uint256 loanId) {
        uint256 held = QUOTE.balanceOf(address(this));
        COLLATERAL.transferFrom(msg.sender, address(this), units);
        COLLATERAL.approve(ACE.POSITION_MANAGER(), units);
        QUOTE.approve(address(ACE), principal);
        ACE.deposit(market, principal);
        loanId = ACE.open(market, units, principal, tenor, address(this), OpenBounds(0, 0, 0));
        _drain();
        IERC721(ACE.POSITION_TITLE()).transferFrom(address(this), msg.sender, loanId);
        QUOTE.transfer(msg.sender, QUOTE.balanceOf(address(this)) + principal - held); // the open's payout, never the lender's own float
    }

    /// @notice Top the caller's loan up by `amount` inside the door: rest it, draw as the holder's title operator, drain.
    function topUp(uint256 loanId, uint256 amount) external returns (uint256 fee) {
        require(ACE.borrowerOf(loanId) == msg.sender, "not the holder");
        QUOTE.approve(address(ACE), amount);
        ACE.deposit(market, amount);
        fee = IAceDrawMore(address(ACE)).drawMore(loanId, amount, OpenBounds(0, 0, 0));
        _drain();
    }

    function _drain() internal {
        uint256 r = ACE.restingOf(market);
        if (r != 0) ACE.withdraw(market, r, address(this), 0);
    }
}

/// @title AceDrawMoreRestingCashTest
/// @notice Resting cash is the lender's standing consent to any admissible top-up, so a lender that rests nothing between its doors consents to none.
/// @notice A vault-shaped lender serves a top-up only inside its own door, as the holder's title operator, and the payout still reaches the holder.
contract AceDrawMoreRestingCashTest is DrawMoreRig {
    RestingDoorLender internal door;
    bytes32 internal doorMarket;
    uint256 internal constant A = P / 4;

    function setUp() public override {
        super.setUp();
        door = new RestingDoorLender(ace, address(usdc), address(coll));
        doorMarket = ace.createMarket(_params(address(door)));
        door.setMarket(doorMarket);
        usdc.mint(address(door), 10 * P);
    }

    /// @dev The borrower borrows `P` for `LONG` through the door, a day ago.
    function _doorLoan() internal returns (uint256 loanId) {
        uint256 units = _units(P, 5000);
        coll.mint(borrower, units);
        vm.startPrank(borrower);
        coll.approve(address(door), units);
        loanId = door.borrow(units, P, LONG);
        vm.stopPrank();
        _warpBy(1 days);
    }

    /// @notice Between the door's calls its market rests nothing, so the holder's direct top-up refuses `InsufficientCash`.
    function test_BetweenItsDoorsTheMarketRestsNothingATopUpCanReach() public {
        uint256 loanId = _doorLoan();
        assertEq(ace.borrowerOf(loanId), borrower, "PREMISE: the borrower holds the title");
        assertEq(ace.restingOf(doorMarket), 0, "PREMISE: the door rested nothing past its call");
        _refusedTop(borrower, loanId, MIN_PRINCIPAL, _none(), InsufficientCash.selector);
    }

    /// @notice Inside its door the lender rests, draws as the holder's title operator, drains, and the holder takes the payout.
    function test_InsideItsDoorTheLenderServesATopUpAndTheHolderIsPaid() public {
        uint256 loanId = _doorLoan();
        vm.prank(borrower);
        titles.approve(address(door), loanId);
        uint256 fee = _topFee(loanId, A);
        uint256 holder0 = usdc.balanceOf(borrower);
        vm.prank(borrower);
        uint256 got = door.topUp(loanId, A);
        assertEq(got, fee, "the door's top-up paid the hub's fee");
        assertEq(usdc.balanceOf(borrower), holder0 + A - fee, "the holder took the payout");
        assertEq(read.debtOf(loanId), P + A, "the debt rose by the amount");
        assertEq(ace.restingOf(doorMarket), 0, "and the door left nothing resting");
    }

    /// @notice Without the holder's title approval the door is a stranger to the loan: its top-up refuses `NotBorrower`, and its rest unwinds.
    function test_WithoutTheTitleApprovalTheDoorIsRefused() public {
        uint256 loanId = _doorLoan();
        vm.prank(borrower);
        vm.expectRevert(NotBorrower.selector);
        door.topUp(loanId, A);
        assertEq(ace.restingOf(doorMarket), 0, "the refused top-up rested nothing");
    }
}
