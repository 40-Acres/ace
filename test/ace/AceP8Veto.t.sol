// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.36;

import {WarpClock} from "../utils/WarpClock.sol";
import {Ace} from "../../src/ace/hub/Ace.sol";
import {InsufficientCash} from "../../src/ace/hub/Borrower.sol";
import {GateRefused, QuoteMismatch} from "../../src/ace/hub/Borrower.sol";
import {MarketParams, MigrateArgs, OpenBounds} from "../../src/ace/hub/Types.sol";
import {PositionManager} from "../../src/ace/positions/PositionManager.sol";
import {MockERC20} from "../mocks/MockERC20.sol";
import {MockPersistenceRecord} from "../mocks/MockPersistenceRecord.sol";
import {MockStakeVault} from "../mocks/MockStakeVault.sol";
import {PriceFrame} from "../utils/PriceFrame.sol";
import {AceFixtures} from "../utils/AceFixtures.sol";
import {AceReader} from "../utils/AceReader.sol";
import {AceLens} from "../../src/ace/lens/AceLens.sol";
import {Borrower} from "../../src/ace/hub/Borrower.sol";
import {MockDeleverageKeeper} from "../mocks/MockDeleverageKeeper.sol";

/// @title AceP8Veto
/// @notice MEASUREMENT, not refutation: the funding class can veto an armed roll, and the veto pays the vetoer.
/// @notice Every verb is documented and every rail passes; the numbers are the deliverable.
/// @dev A red here means an ECONOMIC change, never a correctness regression.
contract AceP8VetoTest is WarpClock {
    Ace internal ace;
    AceReader internal read;
    PositionManager internal pm;
    MockERC20 internal usdc;
    MockStakeVault internal coll;
    MockPersistenceRecord internal record;
    bytes32 internal id;

    address internal alice = address(0xA11CE); // the funding class: her cash is what the loan drew
    address internal honest = address(0x40E5); // the deep resting bid that would fund the roll
    address internal borrower = address(0xB0B);
    address internal keeper = address(0xCAFE);
    address internal buyer = address(0xB0BB1E); // the stranger who buys settled inventory at the record floor

    uint64 internal constant TEN7 = 7 days;
    uint256 internal constant P = 70_000e6;
    uint256 internal constant COLL = 100_000e18;
    uint256 internal constant DEEP = 400_000e6;
    uint256 internal constant UNIT_SCALE = 1 << 96;
    uint256 internal T; // par

    function _price(int24 offset) internal view returns (uint256) {
        return AceFixtures.priceAt(address(usdc), address(coll), offset);
    }

    function _px(uint256 humanWad) internal view returns (uint256) {
        return AceFixtures.px(humanWad, address(usdc), address(coll));
    }

    function setUp() public {
        _warpTo(1_000_000);
        usdc = new MockERC20("USD Coin", "USDC", 6);
        coll = new MockStakeVault(42);
        T = _price(0);
        record = new MockPersistenceRecord(address(usdc), address(coll));
        record.setMinPrice(_px(1.1e18)); // the windowed minimum sits 10% over the funding tick, and never moves

        AceFixtures.Deployment memory d = AceFixtures.deploy(_params());
        (ace, pm, read, id) = (d.ace, d.positionManager, d.read, d.id);
        usdc.mint(borrower, 1_000_000e6);
    }

    function _params() internal view returns (MarketParams memory p) {
        p = AceFixtures.marketParams(address(usdc), address(coll));
        p.record = address(record);
        p.baseBps = 40;
        p.minTenor = TEN7;
        p.maxTenor = TEN7;
        p.settleBountyBps = 50;
        p.minCoverageWad = 1.4e18;
    }

    function _deposit(address who, uint256 price, uint256 amt) internal {
        usdc.mint(who, amt);
        vm.startPrank(who);
        usdc.approve(address(ace), amt);
        ace.deposit(id, amt);
        vm.stopPrank();
    }

    function _open(address who, uint256 units, uint256 principal) internal returns (uint256 loanId) {
        coll.mint(who, units);
        vm.startPrank(who);
        coll.approve(address(pm), units);
        usdc.approve(address(ace), type(uint256).max);
        loanId = ace.open(id, units, principal, TEN7, who, OpenBounds(0, 0, 0));
        vm.stopPrank();
    }

    function _armedLoan() internal returns (uint256 loanId) {
        loanId = _open(borrower, COLL, P);
        vm.prank(borrower);
        ace.setAutoRefinance(loanId, TEN7, 0, 0);
    }

    /// @dev All-in origination at this market's one tenor, ceiled as the hub ceils.
    function _fee(uint256 principal) internal pure returns (uint256) {
        uint256 d = 10000 * 10000 * uint256(TEN7);
        return (principal * 40 * uint256(TEN7) * 11000 + d - 1) / d;
    }

    function _value(uint256 units, uint256 price) internal pure returns (uint256) {
        return (units * price) / UNIT_SCALE;
    }

    /// @dev The class sells its pot to a stranger at the hub's own ask, at the first second the hold allows.
    function _sellPot(uint256 loanId) internal returns (uint256 filled) {
        _warpAtLeastTo(read.inventoryAskOpensAt(loanId));
        usdc.mint(buyer, 1_000_000e6);
        vm.startPrank(buyer);
        usdc.approve(address(ace), type(uint256).max);
        (, filled) = ace.buyInventory(loanId, 1_000_000e6, 0, buyer);
        vm.stopPrank();
    }

    /// @dev The loan is TRACKED AND IGNORED: `collect` is keyed by (lender, quote) and sweeps the lender's
    /// @dev whole credit, so there is no per-class door left for a caller to name.
    function _claimClass(address who, uint256 loanId) internal returns (uint256 paid) {
        vm.prank(who);
        paid = ace.collect(address(usdc), who);
    }

    /* ================================================================= */
    /*  V1 -- DELETED. It measured an OUTSIDER to the resting cash vetoing */
    /*  an armed roll: alice funded the loan, `honest` rested the deep     */
    /*  cash the roll would draw, and alice BORROWED that cash away for    */
    /*  one call so the crank took the settle branch instead. The whole    */
    /*  form needs TWO lenders in ONE market, which sole tenancy makes     */
    /*  unexpressible -- a market names one lender, and the cash a roll    */
    /*  would draw is always the funding lender's own.                     */
    /*  A STRANGER cannot reach it either: an armed loan RESERVES its      */
    /*  roll's fresh remainder and no fresh draw may take reserved cash,   */
    /*  so only the lender's own withdraw can starve an armed roll.        */
    /*                                                                     */
    /*  THE VETO ITSELF SURVIVES and is the subject of V2 below, where it  */
    /*  costs the resting lender nothing because they simply withdraw. The */
    /*  flash-drain apparatus existed only to reach someone else's cash,   */
    /*  and with it goes the one number V1 added: what the detour cost.    */
    /* ================================================================= */

    /* ================================================================= */
    /*  V2 -- the veto costs the RESTING lender nothing at all, and the   */
    /*        borrower has no continuation that does not pass through it. */
    /* ================================================================= */

    /// @notice When the funding class IS the resting cash, the veto is one withdraw. Every borrower continuation then refuses.
    function test_V2_RestingLenderVeto_IsFree_AndClosesEveryContinuationDoor() public {
        _deposit(alice, T, DEEP);
        uint256 loanId = _armedLoan();
        _warpTo(uint256(read.loan(loanId).expiry) - 1 hours); // inside the roll window, before expiry

        vm.prank(alice);
        ace.withdraw(id, type(uint256).max, alice, 0);

        // the borrower, present and willing, has no door left but cash
        vm.startPrank(borrower);
        vm.expectRevert(InsufficientCash.selector);
        ace.refinance(loanId, P + 1_000e6, TEN7, OpenBounds(0, 0, 0));
        vm.expectRevert(InsufficientCash.selector);
        ace.refinanceByPolicy(loanId);
        vm.stopPrank();

        // and a second market on the same pair takes the borrower away only if ITS ladder has cash
        MarketParams memory p = _params();
        p.record = address(new MockPersistenceRecord(address(usdc), address(coll)));
        bytes32 other = ace.createMarket(p);
        vm.prank(borrower);
        vm.expectRevert(InsufficientCash.selector);
        ace.refinanceTo(MigrateArgs(loanId, other, P + 1_000e6, TEN7, OpenBounds(0, 0, 0), 0, address(0)));

        _warpTo(uint256(read.loan(loanId).expiry));
        uint256 n = read.loanCount();
        vm.prank(alice);
        ace.forceClose(loanId);
        assertEq(read.loanCount(), n, "settled, not rolled");
        uint256 units = read.unitsOwedOf(loanId, alice);
        assertGt(units, 0, "and alice, who cranked it, holds the sliver");
        emit log_named_decimal_uint("alice's cost of the veto (USDC)", 0, 6);
        emit log_named_decimal_uint("sliver to alice (atoms)", units, 18);
    }

    /* ================================================================= */
    /*  V3 -- the SIZE of the prize needs no appreciation: the gap between */
    /*        the funding tick and the windowed minimum at open is enough. */
    /* ================================================================= */

    /// @notice The class buys at the funding tick and sells at the record floor. Both are fixed the day the loan opens.
    function test_V3_TheCaptureIsTheTickToFloorGap_NotAppreciation() public {
        _deposit(alice, T, DEEP);
        uint256 loanId = _armedLoan();
        uint256 floor = read.fundingFloor(id, loanId);
        _warpTo(uint256(read.loan(loanId).expiry));
        vm.prank(alice);
        ace.withdraw(id, type(uint256).max, alice, 0);
        vm.prank(keeper);
        ace.forceClose(loanId);
        uint256 filled = _sellPot(loanId);
        uint256 paid = _claimClass(alice, loanId);
        uint256 debt = read.debtOf(loanId);

        emit log_named_decimal_uint("claim at par              (USDC)", debt, 6);
        emit log_named_decimal_uint("class proceeds            (USDC)", paid, 6);
        emit log_named_uint("floor / windowed-min, bps", (floor * 10000) / _px(1.1e18));
        emit log_named_uint("class gain over par, bps of claim", ((paid - debt) * 10000) / debt);

        // proceeds = the buyer's fill (claim * minPrice / floor) plus the fee share and the escrow the settlement earned
        emit log_named_decimal_uint("of which the buyer's fill (USDC)", filled, 6);
        assertGt(paid, (debt * 108) / 100, "the class clears over 8% above par with the price where it was at open");
        assertGe(paid, filled, "every wei the buyer paid landed in the class's index");
    }

    /* ================================================================= */
    /*  V4 -- a loan can be OPENED inside the deleverage band, and cranked */
    /*        in the block it opens. The quote does not say so.            */
    /* ================================================================= */

    /// @notice The band opens at a margin against the RECORD price, and admission reads only the funding floor.
    /// @notice A max-LTV open on a ladder resting under the windowed minimum is therefore crankable at birth.
    function test_V4_BornInTheBand_CrankedInItsOwnBlock_AndThePreviewSaysNothing() public {
        MarketParams memory p = _params();
        p.deleverageBandBps = 3000;
        p.deleverageTargetBps = 4000;
        p.deleverageStopBps = 1;
        p.deleverageFloorEpsBps = 200; // the ceiling: the keeper's whole pay
        p.record = address(new MockPersistenceRecord(address(usdc), address(coll)));
        MockPersistenceRecord r = MockPersistenceRecord(p.record);
        r.setMinPrice(_px(1.1e18));
        r.setBandPrice(_px(1.1e18)); // the price has sat at the windowed minimum for the whole window
        bytes32 band = ace.createMarket(p);
        AceLens lens = new AceLens(address(ace));

        // a lender rests at par; the record's floor is 10% above it
        usdc.mint(alice, DEEP);
        vm.startPrank(alice);
        usdc.approve(address(ace), DEEP);
        ace.deposit(band, DEEP);
        vm.stopPrank();

        // the borrower opens at the largest draw the floor admits: trigger just under the par tick
        uint256 units = 100_000e18;
        uint256 principal = (units * T * 10) / (14 * UNIT_SCALE) - 1e6;
        Borrower.Quote memory q = ace.previewOpen(band, units, principal, TEN7, borrower, OpenBounds(0, 0, 0));
        coll.mint(borrower, units);
        vm.startPrank(borrower);
        coll.approve(address(pm), units);
        uint256 loanId = ace.open(band, units, principal, TEN7, borrower, OpenBounds(0, 0, 0));
        vm.stopPrank();

        uint256 bandLevel = lens.deleverageBandLevel(loanId);
        assertGt(bandLevel, _px(1.1e18), "PREMISE: the band level sits above the record price the loan was born under");
        assertTrue(lens.deleverageEligible(loanId), "the loan is crankable in the block it opened");

        MockDeleverageKeeper k = new MockDeleverageKeeper(ace, address(usdc), address(coll), UNIT_SCALE);
        (uint256 sold, uint256 stable) = k.crankDeleverage(loanId);
        uint256 keeperMargin = _value(sold, _px(1.1e18)) - stable;

        emit log_named_uint("quote: buffer vs the funding floor, bps", q.bufferWad / 1e14);
        emit log_named_uint("margin vs the record price at open, bps", 10000 - (q.triggerAtOpen * 10000) / _px(1.1e18));
        emit log_named_uint("market band, bps", 3000);
        emit log_named_uint("collateral sold in the opening block, bps of the position", (sold * 10000) / units);
        emit log_named_decimal_uint("the keeper's margin on that sale (USDC)", keeperMargin, 6);
        emit log_named_decimal_uint("as bps of the borrower's debt", (keeperMargin * 10000) / principal, 2);

        assertGt(sold, (units * 25) / 100, "over a quarter of the position is sold before the borrower's next block");
        assertGt(keeperMargin, 0, "and the keeper is paid eps of it");
    }

    /* ================================================================= */
    /*  V5 -- DELETED, and the mechanism it measured is gone with it.      */
    /*  A creator's GATE was a contract the hub interviewed on every       */
    /*  continuation, and it could see `tx.origin`. One admitting only the */
    /*  borrower's own transactions made the borrower's simulation of the  */
    /*  roll say yes and every keeper's say no, turning an armed policy    */
    /*  into a settle branch at no cost to the creator.                    */
    /*                                                                     */
    /*  `MarketParams.gate` IS AN ADDRESS NOW -- `borrower`, the one party */
    /*  that may draw here, zero meaning permissionless. A comparison      */
    /*  cannot read the origin, cannot revert, cannot run out of gas and   */
    /*  cannot answer two callers differently, so the whole class of       */
    /*  caller-dependent refusals the row priced is unreachable.           */
    /*  The `OriginGate` mock went with it: there is nothing to interview. */
    /* ================================================================= */
}

