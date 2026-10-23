// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.36;

import {WarpClock} from "../utils/WarpClock.sol";
import {Ace} from "../../src/ace/hub/Ace.sol";
import {Constants} from "../../src/ace/hub/Constants.sol";
import {MarketParams, OpenBounds} from "../../src/ace/hub/Types.sol";
import {PositionManager} from "../../src/ace/positions/PositionManager.sol";
import {MockERC20} from "../mocks/MockERC20.sol";
import {AceFixtures} from "../utils/AceFixtures.sol";
import {AceReader} from "../utils/AceReader.sol";

/// @title AcePriceRail
/// @notice GENESIS is the ONE door a price passes before a market can hold cash, and it is passed ONCE.
/// @notice Its two arms are a nonzero price and a price under `Constants.MAX_PRICE`.
/// @notice The first arm is what every division by a price downstream rests on.
/// @dev IT WAS `AceTickRail`, and the tick deletion did not weaken the property -- it moved WHERE it is enforced.
/// @dev `Ladder.checkTick` guarded every deposit, because a lender picked a tick each time and could pick a bad
/// @dev one. A market names ONE price, write-once, inside its id preimage, so the check runs at creation and the
/// @dev deposit door has nothing left to ask. THAT IS THE STRONGER SHAPE: a bad price is now uncreatable rather
/// @dev than merely un-depositable, so no live market can exist that every lender is refused by.
/// @dev The third old arm, grid alignment, has no successor and no meaning: there is no grid to be off.
contract AcePriceRailTest is WarpClock {
    Ace internal ace;
    AceReader internal read;
    PositionManager internal positionManager;
    MockERC20 internal usdc;
    MockERC20 internal coll;
    bytes32 internal id;

    address internal alice = address(0xA11CE);
    address internal borrower = address(0xB0B);
    address internal keeper = address(0xCAFE);

    uint256 internal constant DEPOSIT = 6000e6;
    uint256 internal constant PRINCIPAL = 5000e6;
    /// @dev WAS 6e18, against a deposit parked at absolute tick 76020 -- roughly $2000 per collateral ATOM.
    /// @dev The fixture market bids at PAR now, so the same draw needs collateral worth 1.4x it at one-for-one.
    uint256 internal constant COLL_UNITS = 8000e18;

    function setUp() public {
        _warpTo(1_000_000);
        usdc = new MockERC20("USD Coin", "USDC", 6);
        coll = new MockERC20("Collateral", "COLL", 18);

        AceFixtures.Deployment memory d = AceFixtures.deploy(_params());
        (ace, positionManager, read, id) = (d.ace, d.positionManager, d.read, d.id);
        assertGt(ace.idToMarketParams(id).price, 0, "fixture: the baseline market carries a live price");
    }

    /// @dev Built through a helper so a row can amend one field and re-create without repeating the shape.
    /// @dev A record-less market is the convenience the rail rows want: no draw cap stands between them and the door.
    function _params() internal view returns (MarketParams memory p) {
        p = AceFixtures.marketParams(address(usdc), address(coll));
        p.record = address(0); // convenience for the rail rows, and it puts the settling row on the forfeit arm
        p.baseBps = 1;
        p.settleBountyBps = 0;
    }

    function _fund(address who, uint256 amt) internal {
        usdc.mint(who, amt);
        vm.prank(who);
        usdc.approve(address(ace), amt);
    }

    /// @notice A market whose price is zero is UNCREATABLE, so no door downstream ever divides by one.
    /// @dev Built OUTSIDE the expectRevert: `_params` reads the pair's decimals and would eat the expectation.
    function testRevert_PriceRail_AZeroPriceMarketIsUncreatable() public {
        MarketParams memory p = _params();
        p.price = 0;
        vm.expectRevert(bytes("price zero"));
        ace.createMarket(p);
    }

    /// @notice One atom is admitted, so the refusal above is a boundary and not a ban on small prices.
    /// @dev The floor of the admissible band, asserted so the zero row cannot pass by refusing everything.
    function test_PriceRail_OneAtomIsAdmissible() public {
        MarketParams memory p = _params();
        p.price = 1;
        bytes32 m = ace.createMarket(p);
        assertEq(ace.idToMarketParams(m).price, 1, "one atom is a legal price");
    }

    /// @notice A price over the genesis ceiling is refused, which is what keeps the overflow arguments true.
    /// @dev The ceiling is not a round number picked fresh: it is where this tree's overflow proofs were written to.
    function testRevert_PriceRail_APriceOverTheCeilingIsRefused() public {
        MarketParams memory p = _params();
        p.price = Constants.MAX_PRICE + 1;
        vm.expectRevert(bytes("price over ceiling"));
        ace.createMarket(p);
    }

    /// @notice The ceiling itself is admitted, so that refusal is a boundary too.
    function test_PriceRail_TheCeilingItselfIsAdmissible() public {
        MarketParams memory p = _params();
        p.price = Constants.MAX_PRICE;
        bytes32 m = ace.createMarket(p);
        assertEq(ace.idToMarketParams(m).price, Constants.MAX_PRICE, "the ceiling is a legal price");
    }

    /// @notice THE PROPERTY the whole rail is for: a live market's price cannot be zero, ever.
    /// @notice Write-once and inside the id preimage, so nothing can move it after genesis has admitted it.
    /// @dev Asserted through the ORDINARY doors -- a deposit and a draw -- rather than by re-reading the param.
    function test_PriceRail_ADepositAndADrawBothSeeALivePrice() public {
        _fund(alice, DEPOSIT);
        vm.prank(alice);
        ace.deposit(id, DEPOSIT);
        assertEq(ace.restingOf(id), DEPOSIT, "the deposit rested at the market's own price");

        coll.mint(borrower, COLL_UNITS);
        vm.startPrank(borrower);
        coll.approve(address(positionManager), COLL_UNITS);
        uint256 loanId = ace.open(id, COLL_UNITS, PRINCIPAL, 0, borrower, OpenBounds(0, 0, 0));
        vm.stopPrank();

        assertGt(read.fundingFloor(id, loanId), 0, "the loan funded at a live price");
        assertEq(read.fundingFloor(id, loanId), ace.idToMarketParams(id).price, "and it is the market's own");
    }

    /// @notice The consequence the ask rests on: a settled loan's pot is always priced by a live number.
    /// @dev A zero price there would divide by zero in settlement long before the ask ever saw it.
    /// @dev THE OLD ROW WALKED `claimTicks` asserting each carried a live price; there is one price to assert now.
    function test_PriceRail_AnAskNeverSeesAZeroPrice() public {
        _fund(alice, DEPOSIT);
        vm.prank(alice);
        ace.deposit(id, DEPOSIT);

        coll.mint(borrower, COLL_UNITS);
        vm.startPrank(borrower);
        coll.approve(address(positionManager), COLL_UNITS);
        uint256 loanId = ace.open(id, COLL_UNITS, PRINCIPAL, 0, borrower, OpenBounds(0, 0, 0));
        vm.stopPrank();
        _warpBy(7 days + 1);
        vm.prank(keeper);
        ace.forceClose(loanId);

        assertGt(read.invPotOf(id, loanId), 0, "premise: the settled loan really left a pot behind");
        assertGt(ace.idToMarketParams(id).price, 0, "and the price the ask will value it at is live");
    }
}
