// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.36;

import {WarpClock} from "../utils/WarpClock.sol";
import {Ace} from "../../src/ace/hub/Ace.sol";
import {Borrower, BufferBelowMin, InsufficientCash} from "../../src/ace/hub/Borrower.sol";
import {Cfg, MarketParams, OpenBounds, Order} from "../../src/ace/hub/Types.sol";
import {PositionManager} from "../../src/ace/positions/PositionManager.sol";
import {MockERC20} from "../mocks/MockERC20.sol";
import {MockPersistenceRecord} from "../mocks/MockPersistenceRecord.sol";
import {AceFixtures} from "../utils/AceFixtures.sol";
import {AceReader} from "../utils/AceReader.sol";
import {PriceFrame} from "../utils/PriceFrame.sol";

/// @title AceP7OrderFloor
/// @notice THE ATTACK THIS FILE MEASURED IS STRUCTURALLY CLOSED, and the rows below are what closed it.
/// @notice It was a Phase-7 probe on the one open door with no buffer bound: `Orders.fill` passes
/// @notice `OpenBounds(0, 0, expiry)`, and the maker is absent at the draw by construction, so they could not
/// @notice refuse the funding floor their fill landed on. A filler who was also the top resting bid therefore
/// @notice CHOSE that floor, and the lowest legal choice was the maker's own trigger. #346 D0-8 ruled the loss
/// @notice accepted, describing it as a passive thin market; O1 and O2 priced the attacker's side of that ruling.
/// @dev WHAT CHANGED: a market names ONE price, write-once and inside its own id. An order names its market when
/// @dev it is posted, so the price its fill will fund at is fixed at that moment. A filler cannot rest a lower
/// @dev bid in that market -- there is no coordinate to rest at -- and a market at a different price is a
/// @dev DIFFERENT market that the order does not point at. The flash-drain of O2 fares no better: draining the
/// @dev market's cash cannot move its price, so it turns the fill into a refusal rather than a worse floor.
/// @dev The maker's buffer is therefore knowable from the order itself, which is the property the RED row asked
/// @dev for and the ruling declined to adopt. It is now a consequence of the shape rather than a bound to add.
contract AceP7OrderFloorTest is WarpClock {
    Ace internal ace;
    AceReader internal read;
    PositionManager internal pm;
    MockERC20 internal usdc; // quote, 6 decimals
    MockERC20 internal coll; // collateral, 18 decimals
    MockPersistenceRecord internal record;
    bytes32 internal mid;

    address internal honest = address(0xA11CE); // the market's named lender, resting at a fair bid
    address internal maker = address(0x4A6E); // the order's maker, the borrower-to-be
    address internal filler = address(0xF111); // the would-be attacker: filler and keeper in one

    uint64 internal constant TEN = 7 days;
    uint256 internal constant P = 100_000e6; // the order's principal
    uint256 internal FAIR; // the honest bid: ~1.935 quote per collateral, under the 2.0 cap
    uint256 internal LOW; // the price the attacker would have wanted: ~1.4079, just over the maker's band
    uint256 internal LIQ_LOW; // 1.40: the maker's safest trigger
    uint256 internal LIQ_HIGH; // 1.45: the maker's worst trigger

    function _price(int24 offset) internal view returns (uint256) {
        return AceFixtures.priceAt(address(usdc), address(coll), offset);
    }

    function _px(uint256 humanWad) internal view returns (uint256) {
        return AceFixtures.px(humanWad, address(usdc), address(coll));
    }

    function _human(uint256 framePrice) internal view returns (uint256) {
        return PriceFrame.humanWad(framePrice, address(usdc), address(coll));
    }

    function setUp() public {
        _warpTo(1_000_000);
        usdc = new MockERC20("USD Coin", "USDC", 6);
        coll = new MockERC20("Collateral", "COLL", 18);
        FAIR = _price(6600); // 1.0001 ** 6600 ~= 1.935
        LOW = _price(3420); // 1.0001 ** 3420 ~= 1.4079
        LIQ_LOW = _px(1.4e18);
        LIQ_HIGH = _px(1.45e18);

        record = new MockPersistenceRecord(address(usdc), address(coll));
        record.setObserved(_px(2e18));
        record.setMinPrice(_px(2e18)); // the cap: both prices here are admissible

        MarketParams memory p = AceFixtures.marketParams(address(usdc), address(coll));
        p.record = address(record);
        p.price = FAIR;
        p.lender = honest;
        AceFixtures.Deployment memory d = AceFixtures.deploy(p);
        (ace, pm, read, mid) = (d.ace, d.positionManager, d.read, d.id);

        coll.mint(maker, 1e30);
        vm.prank(maker);
        coll.approve(address(pm), type(uint256).max);
    }

    /* ================================ the fixture verbs ================================ */

    function _lend(address who, bytes32 market, uint256 amt) internal {
        usdc.mint(who, amt);
        vm.startPrank(who);
        usdc.approve(address(ace), amt);
        ace.deposit(market, amt);
        vm.stopPrank();
    }

    function _post() internal returns (uint256 orderId) {
        vm.prank(maker);
        orderId = ace.postOrder(mid, P, LIQ_LOW, LIQ_HIGH, P, TEN, uint64(_now() + 30 days));
    }

    function _cfg() internal view returns (Cfg memory c) {
        c.p = ace.idToMarketParams(mid);
        c.unitScale = read.marketState(mid).unitScale;
    }

    /// @dev The maker's realised buffer on a loan: `(floor - trig) / floor`, as `previewOpen` would have reported it.
    function _bufferWad(uint256 loanId) internal view returns (uint256) {
        uint256 floor = read.fundingFloor(mid, loanId);
        uint256 trig = read.triggerPrice(loanId);
        return ((floor - trig) * 1e18) / floor;
    }

    /// @dev A SECOND market on the same pair at the attacker's price, which is the closest they can now get.
    function _lowMarket() internal returns (bytes32) {
        MarketParams memory p = AceFixtures.marketParams(address(usdc), address(coll));
        p.record = address(record);
        p.price = LOW;
        p.lender = filler;
        return ace.createMarket(p);
    }

    /* ================================ O1: the floor is the order's own ================================ */

    /// @notice THE CLOSURE. An order's funding floor is the price of the market it names, known when it is posted.
    /// @notice The filler no longer chooses it, so the buffer the maker gets is the buffer they could see.
    /// @dev WAS `test_O1_ThinLadder_TheFillerFundsTheMakerAtTheMakersOwnTrigger`, which asserted the opposite:
    /// @dev the filler rested one step over the maker's band and the fill landed there, at a sub-1% buffer.
    function test_O1_TheFillFundsAtTheMarketsOwnPrice_NotTheFillersChoice() public {
        uint256 orderId = _post();
        Order memory o = ace.orderOf(orderId);
        _lend(honest, mid, P);

        uint256 quotedBuffer = ((FAIR - LIQ_HIGH) * 1e18) / FAIR; // what the maker could read off the order

        vm.prank(filler);
        uint256 loanId = ace.fillOrder(orderId, P, o.collateralUnits);

        uint256 floor = read.fundingFloor(mid, loanId);
        emit log_named_decimal_uint("funding floor (quote per collateral)", _human(floor), 18);
        emit log_named_decimal_uint("trigger       (quote per collateral)", _human(read.triggerPrice(loanId)), 18);
        emit log_named_decimal_uint("maker's realised buffer (WAD)       ", _bufferWad(loanId), 18);
        assertEq(floor, FAIR, "the MARKET's price is the maker's funding floor, whoever filled");
        assertGe(_bufferWad(loanId), quotedBuffer, "and the buffer is at least what the order itself advertised");
        assertGt(_bufferWad(loanId), 0.2e18, "which on this order is a real margin, not the sub-1% the attack produced");

        // the consequence on the TERM: the maker's excess escrow is free behind the coverage line at THIS floor
        uint256 lineFair = Borrower.coverageLine(_cfg(), P, FAIR);
        uint256 lineLow = Borrower.coverageLine(_cfg(), P, LOW);
        emit log_named_decimal_uint("collateral units held              ", o.collateralUnits, 18);
        emit log_named_decimal_uint("withdrawable at the market's floor ", o.collateralUnits - lineFair, 18);
        assertGt(o.collateralUnits - lineFair, o.collateralUnits / 4, "over a quarter of the escrow is withdrawable for the term");
        assertLt(o.collateralUnits - lineLow, o.collateralUnits / 100, "where the attacked floor would have left under 1%");
    }

    /// @notice The attacker's remaining move is a market of their OWN at the low price -- and the order is not in it.
    /// @dev This is what makes the closure structural rather than a matter of who is faster: the order's market is
    /// @dev in its own preimage, so a market at another price is a different market with no order resting in it.
    function test_O1_ALowPricedMarketCannotReachTheOrder() public {
        uint256 orderId = _post();
        Order memory o = ace.orderOf(orderId);
        bytes32 low = _lowMarket();
        assertTrue(low != mid, "the low-priced market really is a different market");
        _lend(filler, low, P);
        _lend(honest, mid, P);

        vm.prank(filler);
        uint256 loanId = ace.fillOrder(orderId, P, o.collateralUnits);

        assertEq(read.loan(loanId).market, mid, "the fill lands in the market the ORDER named");
        assertEq(read.fundingFloor(mid, loanId), FAIR, "at that market's price, with the attacker's bid untouched");
        assertEq(ace.restingOf(low), P, "and their low bid still rests, having funded nothing");
    }

    /* ================================ O2: draining is a refusal, not a worse floor ================================ */

    /// @notice The flash-drain of O2 now produces a REFUSAL rather than a cheaper funding floor.
    /// @notice Cash is what a draw consumes; price is what it funds at, and nothing a borrower does moves it.
    /// @dev WAS `test_O2_ThickLadder_FlashDrainThenFundTheMakerLow`: borrow the honest bid away inside one
    /// @dev multicall, rest a low bid, fill the order against it, repay. The measured capture on default cleared
    /// @dev the detour's cost, which is what made it an attack rather than a curiosity. The middle step is gone.
    function test_O2_DrainingTheMarketRefusesTheFillRatherThanRepricingIt() public {
        uint256 orderId = _post();
        Order memory o = ace.orderOf(orderId);
        _lend(honest, mid, P);

        // the drain: a borrower takes every resting wei, exactly as the attack's first leg did
        uint256 drainColl = Borrower.coverageLine(_cfg(), P, FAIR) + 1;
        coll.mint(filler, drainColl);
        vm.startPrank(filler);
        coll.approve(address(pm), drainColl);
        ace.open(mid, drainColl, P, TEN, filler, OpenBounds(0, 0, 0));
        vm.stopPrank();
        assertEq(ace.restingOf(mid), 0, "the market really is drained");

        vm.prank(filler);
        vm.expectRevert(InsufficientCash.selector); // BY NAME: the claim is that a drain refuses, not that it fails somehow
        ace.fillOrder(orderId, P, o.collateralUnits);

        // and once cash returns, the fill lands at the SAME price it would have before the drain
        _lend(honest, mid, P);
        vm.prank(filler);
        uint256 loanId = ace.fillOrder(orderId, P, o.collateralUnits);
        assertEq(read.fundingFloor(mid, loanId), FAIR, "the detour bought the filler nothing: the floor never moved");
    }

    /// @dev Expire and settle the maker's loan by the paid door, then read what the lender was handed at book.
    /// @dev WAS a sum over the loan's funded ticks; a loan holds one pot, so the sum is that one read.
    function _settleAndMeasure(uint256 loanId) internal returns (uint256 unitsToLender) {
        _warpTo(read.loan(loanId).expiry);
        vm.prank(filler);
        ace.forceClose(loanId);
        unitsToLender = read.invPotOf(mid, loanId);
    }
}
