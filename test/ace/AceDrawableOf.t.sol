// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.36;

import {WarpClock} from "../utils/WarpClock.sol";
import {Ace} from "../../src/ace/hub/Ace.sol";
import {InsufficientCash} from "../../src/ace/hub/Borrower.sol";
import {MarketParams, OpenBounds} from "../../src/ace/hub/Types.sol";
import {PositionManager} from "../../src/ace/positions/PositionManager.sol";
import {MockERC20} from "../mocks/MockERC20.sol";
import {MockPersistenceRecord} from "../mocks/MockPersistenceRecord.sol";
import {AceFixtures} from "../utils/AceFixtures.sol";
import {AceReader} from "../utils/AceReader.sol";

/// @title AceDrawableOf
/// @notice `drawableOf` is DELETED with the roll reservation: what a fresh draw may take is `restingOf`, every atom of it, a live loan beside it or not.
/// @dev The boundary row runs with a Live record whose cap sits over the market's price, so `InsufficientCash` can only mean cash.
contract AceDrawableOfTest is WarpClock {
    Ace internal ace;
    AceReader internal read;
    PositionManager internal pm;
    MockERC20 internal usdc;
    MockERC20 internal coll;
    bytes32 internal id;

    address internal alice = address(0xA11CE); // the market's one lender
    address internal borrower = address(0xB0B);
    address internal drawer = address(0xD4A3); // a second borrower, whose fresh draw the boundary row quotes

    uint64 internal constant TEN7 = 7 days;
    uint256 internal constant UNITS = 1_000_000e18; // worth a million at par: collateral never binds a draw here

    function setUp() public {
        _warpTo(1_000_000);
        usdc = new MockERC20("USD Coin", "USDC", 6);
        coll = new MockERC20("Collateral", "COLL", 18);
        MockPersistenceRecord rec = new MockPersistenceRecord(address(usdc), address(coll));
        rec.setMinPrice(AceFixtures.px(1.1e18, address(usdc), address(coll))); // Live, and over the price: the cap never binds
        MarketParams memory p = AceFixtures.marketParams(address(usdc), address(coll));
        p.record = address(rec);
        p.lender = alice;
        p.baseBps = 40;
        p.minTenor = TEN7;
        p.maxTenor = TEN7;
        AceFixtures.Deployment memory d = AceFixtures.deploy(p);
        (ace, pm, read, id) = (d.ace, d.positionManager, d.read, d.id);
    }

    function _deposit(uint256 amt) internal {
        usdc.mint(alice, amt);
        vm.startPrank(alice);
        usdc.approve(address(ace), amt);
        ace.deposit(id, amt);
        vm.stopPrank();
    }

    function _openLoan(uint256 principal) internal returns (uint256 loanId) {
        coll.mint(borrower, UNITS);
        vm.startPrank(borrower);
        coll.approve(address(pm), UNITS);
        loanId = ace.open(id, UNITS, principal, TEN7, borrower, OpenBounds(0, 0, 0));
        vm.stopPrank();
    }

    /// @notice FUZZ (the draw's own boundary): a fresh draw clears the cash test IFF it is at most `restingOf`, with a live loan beside it.
    /// @notice And one atom past `restingOf` refuses `InsufficientCash`, so the view is the rule and not an estimate of it.
    /// @dev Bounded to `fresh >= minPrincipal` and a Live record capped over the price, so no other rail answers first.
    function testFuzz_TheViewIsTheDrawsOwnCashBoundary(uint256 depositSeed, uint256 principalSeed, uint256 keepSeed, uint256 freshSeed) public {
        uint256 minPrincipal = ace.idToMarketParams(id).minPrincipal;
        uint256 dep = bound(depositSeed, 4 * minPrincipal, 400_000e6);
        _deposit(dep);
        _openLoan(bound(principalSeed, minPrincipal, dep / 2));
        uint256 out = ace.restingOf(id) - bound(keepSeed, 0, ace.restingOf(id)); // hoisted: a call in the argument list eats the prank
        vm.prank(alice);
        try ace.withdraw(id, out, alice, 0) {} catch {} // a dust remainder is refused, and the state stays

        uint256 drawable = ace.restingOf(id);
        uint256 fresh = bound(freshSeed, minPrincipal, drawable + minPrincipal);
        bool admitted = _previews(fresh);
        assertEq(admitted, fresh <= drawable, "the draw clears the cash test exactly when it fits under the resting cash");
        if (drawable + 1 >= minPrincipal) {
            assertFalse(_previews(drawable + 1), "and one atom past it is refused");
        }
    }

    /// @dev Whether a fresh draw of `fresh` previews clean; any refusal must be the cash rail's.
    function _previews(uint256 fresh) internal view returns (bool) {
        try ace.previewOpen(id, UNITS, fresh, 0, drawer, OpenBounds(0, 0, 0)) {
            return true;
        } catch (bytes memory err) {
            assertEq(bytes4(err), InsufficientCash.selector, "the only refusal is the cash rail");
            return false;
        }
    }
}
