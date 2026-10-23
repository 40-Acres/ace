// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.36;

import {FullMath} from "@uniswap/v4-core/src/libraries/FullMath.sol";
import {Ace} from "../../src/ace/hub/Ace.sol";
import {Borrower} from "../../src/ace/hub/Borrower.sol";
import {AceLens} from "../../src/ace/lens/AceLens.sol";
import {Loan, MarketParams, Order} from "../../src/ace/hub/Types.sol";
import {PositionManager} from "../../src/ace/positions/PositionManager.sol";
import {ProtocolPolicy} from "../../src/config/Defaults.sol";
import {MockERC20} from "../mocks/MockERC20.sol";
import {MockPersistenceRecord} from "../mocks/MockPersistenceRecord.sol";
import {AceFixtures} from "../utils/AceFixtures.sol";
import {AceReader} from "../utils/AceReader.sol";
import {DeleverageCrank} from "../utils/DeleverageCrank.sol";
import {WarpClock} from "../utils/WarpClock.sol";

/// @title AceSplitOrderHandler
/// @notice The fuzzing surface for SPLITTABLE credit orders: posts that can fill in pieces, and fills taken at the band's pro-rata cap.
/// @notice `AceHandler` posts only all-or-nothing orders, so the split branch of the escrow's slack had no long random campaign.
/// @notice Loan verbs ride beside the fills (repay, withdraw, deleverage, warp) so a fill never meets only a pristine market.
/// @dev THE PROPERTY IS LATCHED HERE, not asserted: a legal fill at its cap that refuses sets `capFillRefused` and names itself.
/// @dev The market's own gates are made to admit before each fill: cash is topped up and the record is healed over the price.
/// @dev So the only refusals left are the order's and the coverage line's, which are exactly what the slack has to pay for.
/// @dev The band's HIGH end is always the market price, so any take between the coverage line and the cap is admissible.
/// @dev Every action is bounded and try/catch-guarded (fail_on_revert = false), like its siblings.
contract AceSplitOrderHandler is WarpClock, DeleverageCrank {
    function _deleverageQuote() internal view override returns (address) {
        return address(usdc);
    }

    uint256 internal constant K = 1.4e18;
    uint256 internal constant S = 1 << 96;
    uint256 internal constant MIN_DEBT = 1_000e6; // the quote is 6-decimal: one thousand per minimum ticket
    uint256 internal constant MAX_ORDERS = 8; // the O(orders) invariants bound on it
    uint256 internal constant MAX_LOANS = 24; // the loan picker's bound
    uint256 internal constant BAND_BPS = 3000; // the PoC deleverage dials
    uint256 internal constant TARGET_BPS = 5000;
    uint256 internal constant STOP_BPS = 1000;
    uint256 internal constant CUT_BPS = 500;

    address public constant MAKER = address(0x4A6E);
    address public constant FILLER = address(0xF111);

    Ace public ace;
    AceLens public lens;
    PositionManager public positionManager;
    AceReader public read;
    MockERC20 public usdc;
    MockERC20 public coll;
    MockPersistenceRecord public record;
    bytes32 public id;
    uint256 public price; // the market's one price, and the high end of every band posted here

    uint256[] internal _orderIds;
    uint256[] internal _loanIds;
    mapping(uint256 => uint256) public postedUnits; // order -> escrow pulled at post
    mapping(uint256 => uint256) public postedPrincipal; // order -> principal stated at post
    mapping(uint256 => uint256) public carriedUnits; // order -> units carried into the loans its fills opened
    mapping(uint256 => uint256) public returnedUnits; // order -> units the maker's close handed back

    uint256 public ordersPosted;
    uint256 public splittablePosted; // posted with principal at least two minimum fills
    uint256 public wholeOnlyPosted; // posted with principal under two minimum fills
    uint256 public sentinelPosted; // posted with a zero minFill, which resolves to minDebt and buys the largest slack
    uint256 public capFills; // fills that landed at the pro-rata cap
    uint256 public partialCapFills; // of those, ones that left principal behind: the split branch itself
    uint256 public minFillCapFills; // of those, ones of exactly the maker's floor: where the per-fill slack is thinnest
    uint256 public bandFills; // fills that landed strictly between the coverage line and the cap
    uint256 public closes;
    uint256 public repays;
    uint256 public withdrawals;
    uint256 public deleveragesSold;

    bool public capFillRefused; // THE LATCH: a legal fill inside [line, cap] was refused
    string public refusal; // what refused it, and the numbers that decide it

    mapping(bytes32 => uint256) public calls;

    /// @param collDec The collateral's decimals; the quote is always 6-decimal.
    /// @param humanPriceWad One whole collateral's price in whole quote, as a WAD.
    constructor(uint8 collDec, uint256 humanPriceWad) {
        _warpTo(1_000_000);
        usdc = new MockERC20("Quote", "Q", 6);
        coll = new MockERC20("Collateral", "C", collDec);
        record = new MockPersistenceRecord(address(usdc), address(coll));
        price = AceFixtures.px(humanPriceWad, address(usdc), address(coll));
        record.setMinPrice(2 * price);

        MarketParams memory p = AceFixtures.marketParams(address(usdc), address(coll));
        p.price = price;
        p.record = address(record);
        p.minCoverageWad = K;
        p.minDebt = MIN_DEBT;
        p.deleverageFloorEpsBps = ProtocolPolicy.DELEVERAGE_FLOOR_EPS_BPS;
        p.deleverageBandBps = BAND_BPS;
        p.deleverageTargetBps = TARGET_BPS;
        p.deleverageStopBps = STOP_BPS;
        p.deleverageProtocolBps = CUT_BPS;
        AceFixtures.Deployment memory d = AceFixtures.deploy(p);
        (ace, positionManager, read, id) = (d.ace, d.positionManager, d.read, d.id);
        lens = new AceLens(address(ace));

        coll.mint(MAKER, type(uint128).max);
        vm.prank(MAKER);
        coll.approve(address(positionManager), type(uint256).max);
        _deposit(100 * MIN_DEBT);

        _baseline();
    }

    /// @notice ONE split, pre-snapshot: a four-way order at the price, a minimum fill at its cap, then the rest whole.
    /// @dev UNGUARDED: if the split branch is dead the campaign must fail to build rather than tally a healthy zero.
    function _baseline() internal {
        vm.prank(MAKER);
        uint256 orderId = ace.postOrder(id, 10 * MIN_DEBT, price, price, 5 * MIN_DEBT / 2, 0, 0);
        _trackOrder(orderId);
        Order memory o = ace.orderOf(orderId);
        uint256 cap = FullMath.mulDiv(o.collateralUnits, o.minFillPrincipal, o.principal);
        vm.prank(FILLER);
        _trackLoan(ace.fillOrder(orderId, o.minFillPrincipal, cap));
        carriedUnits[orderId] += cap;
        o = ace.orderOf(orderId);
        vm.prank(FILLER);
        _trackLoan(ace.fillOrder(orderId, o.principal, o.collateralUnits));
        carriedUnits[orderId] += o.collateralUnits;
    }

    /// @notice The decline channel exercised once, pre-snapshot, so it cannot be silently inert.
    /// @dev Called by the suite's setUp: the crank calls `onAceDeleverage` back on this address, which has no code in its own constructor.
    function baselineDeleverage() external {
        uint256 loanId = _loanIds[0];
        uint256 held = read.loan(loanId).collateralUnits;
        _enterBand(loanId);
        ace.deleverage(loanId, 0, "");
        require(read.loan(loanId).collateralUnits < held, "BASELINE: the deleverage sold nothing -- the channel is inert");
        deleveragesSold++;
        _heal();
    }

    /* ============================ views for the suite ============================ */

    function orderIds() external view returns (uint256[] memory) {
        return _orderIds;
    }

    function loanIds() external view returns (uint256[] memory) {
        return _loanIds;
    }

    function callCount(string memory tag) external view returns (uint256) {
        return calls[keccak256(bytes(tag))];
    }

    /* ============================ helpers ============================ */

    function _bump(string memory tag) internal {
        calls[keccak256(bytes(tag))]++;
    }

    function _deposit(uint256 amt) internal {
        usdc.mint(AceFixtures.LENDER, amt);
        vm.startPrank(AceFixtures.LENDER);
        usdc.approve(address(ace), amt);
        ace.deposit(id, amt);
        vm.stopPrank();
    }

    function _trackOrder(uint256 orderId) internal {
        Order memory o = ace.orderOf(orderId);
        _orderIds.push(orderId);
        postedUnits[orderId] = o.collateralUnits;
        postedPrincipal[orderId] = o.principal;
        ordersPosted++;
        if (o.principal >= 2 * o.minFillPrincipal) splittablePosted++;
        else wholeOnlyPosted++;
    }

    function _trackLoan(uint256 loanId) internal {
        if (_loanIds.length < MAX_LOANS) _loanIds.push(loanId);
    }

    /// @dev The first order at or after the seed's pick that still has principal to fill, wrapping once round.
    function _liveOrder(uint256 seed) internal view returns (bool found, uint256 orderId) {
        uint256 n = _orderIds.length;
        for (uint256 k; k < n; k++) {
            orderId = _orderIds[(seed % n + k) % n];
            Order memory o = ace.orderOf(orderId);
            if (!o.closed && o.principal != 0) return (true, orderId);
        }
    }

    /// @dev A legal principal: the maker's floor on half the draws, else anywhere legal; a sub-floor remainder folds into the fill.
    function _legalX(Order memory o, uint256 seed) internal pure returns (uint256 x) {
        uint256 m = o.minFillPrincipal;
        x = seed % 2 == 0 ? m : m + ((seed >> 1) % (o.principal - m + 1));
        if (o.principal - x < m) x = o.principal;
    }

    /// @dev The band's low leg admits at most `floor(U * x / D)`; a whole fill takes the rest of the escrow.
    function _cap(Order memory o, uint256 x) internal pure returns (uint256) {
        return x == o.principal ? o.collateralUnits : FullMath.mulDiv(o.collateralUnits, x, o.principal);
    }

    /// @dev The market's own gates, opened: the record over the price, out of band, and cash for the draw.
    function _admitTheMarket(uint256 x) internal {
        _heal();
        if (read.restingOf(id) < x) _deposit(2 * x);
    }

    /// @dev Fill and either book it or LATCH the refusal; a refusal here is a violation, never a fuzz outcome.
    function _fillOrLatch(uint256 orderId, Order memory o, uint256 x, uint256 u, uint256 line) internal returns (bool landed) {
        _admitTheMarket(x);
        vm.prank(FILLER);
        try ace.fillOrder(orderId, x, u) returns (uint256 loanId) {
            carriedUnits[orderId] += u;
            _trackLoan(loanId);
            return true;
        } catch (bytes memory err) {
            if (capFillRefused) return false;
            capFillRefused = true;
            refusal = string.concat(
                "a legal fill refused: order ",
                vm.toString(orderId),
                " D ",
                vm.toString(o.principal),
                " U ",
                vm.toString(o.collateralUnits),
                " m ",
                vm.toString(o.minFillPrincipal),
                " x ",
                vm.toString(x),
                " u ",
                vm.toString(u),
                " line ",
                vm.toString(line),
                " err ",
                vm.toString(err)
            );
        }
    }

    function _enterBand(uint256 loanId) internal {
        uint256 trig = read.triggerPrice(loanId);
        if (trig == 0) return;
        record.setBelowBand(FullMath.mulDivRoundingUp(trig, 1e18, 1e18 - BAND_BPS * 1e14));
        record.setMinPrice(trig + trig / 4); // inside the 30% band, clear of the 10% stop
    }

    function _heal() internal {
        record.setBelowBand(0);
        record.setBelow(false);
        record.setMinPrice(2 * price);
    }

    /// @dev The first live, unexpired tracked loan at or after the seed's own pick, wrapping once round.
    function _liveLoan(uint256 seed) internal view returns (bool found, uint256 loanId) {
        uint256 n = _loanIds.length;
        for (uint256 k; k < n; k++) {
            loanId = _loanIds[(seed % n + k) % n];
            Loan memory l = read.loan(loanId);
            if (l.closedAt == 0 && _now() < l.expiry) return (true, loanId);
        }
    }

    /* ============================ the actions ============================ */

    /// @notice A maker's post: mostly splittable, sometimes whole-only or all-or-nothing, sometimes the zero-minFill sentinel.
    /// @notice The low end sits AT the price on half the posts (maximum leverage, where the slack is all there is) and within 10% under it otherwise.
    function postOrder(uint256 principalSeed, uint256 minFillSeed, uint256 lowSeed, uint256 shapeSeed) external {
        _bump("postOrder");
        if (_orderIds.length >= MAX_ORDERS) return;
        uint256 d = bound(principalSeed, 2 * MIN_DEBT, 100 * MIN_DEBT);
        uint256 shape = shapeSeed % 8;
        uint256 m;
        if (shape == 0) m = 0;
        else if (shape == 1) m = d;
        else if (shape == 2) m = bound(minFillSeed, d / 2 + 1, d);
        else m = bound(minFillSeed, MIN_DEBT, d / 2);
        uint256 low = lowSeed % 2 == 0 ? price : bound(lowSeed >> 1, (price * 9) / 10, price);
        vm.prank(MAKER);
        try ace.postOrder(id, d, low, price, m, 0, 0) returns (uint256 orderId) {
            _trackOrder(orderId);
            if (m == 0) sentinelPosted++;
        } catch {}
    }

    /// @notice THE PROPERTY'S ACTION: a legal fill taken at the band's pro-rata cap must open.
    function fillAtCap(uint256 orderSeed, uint256 xSeed) external {
        _bump("fillAtCap");
        (bool found, uint256 orderId) = _liveOrder(orderSeed);
        if (!found) return;
        Order memory o = ace.orderOf(orderId);
        uint256 x = _legalX(o, xSeed);
        uint256 u = _cap(o, x);
        if (_fillOrLatch(orderId, o, x, u, Borrower.coverageLine(K, S, x, price))) {
            capFills++;
            if (x < o.principal) partialCapFills++;
            if (x == o.minFillPrincipal && x < o.principal) minFillCapFills++;
        }
    }

    /// @notice The rest of the admissible interval: any take between the coverage line and the cap must open too.
    /// @dev A take under the cap leaves the remainder RICHER, so it also drives later cap fills through states a cap-only walk never sees.
    function fillInBand(uint256 orderSeed, uint256 xSeed, uint256 uSeed) external {
        _bump("fillInBand");
        (bool found, uint256 orderId) = _liveOrder(orderSeed);
        if (!found) return;
        Order memory o = ace.orderOf(orderId);
        uint256 x = _legalX(o, xSeed);
        uint256 cap = _cap(o, x);
        uint256 line = Borrower.coverageLine(K, S, x, price);
        if (cap < line) {
            if (!capFillRefused) {
                capFillRefused = true;
                refusal = string.concat("the admissible interval is empty: cap ", vm.toString(cap), " under line ", vm.toString(line));
            }
            return;
        }
        uint256 u = bound(uSeed, line, cap);
        if (_fillOrLatch(orderId, o, x, u, line) && u < cap) bandFills++;
    }

    function closeOrder(uint256 orderSeed) external {
        _bump("closeOrder");
        (bool found, uint256 orderId) = _liveOrder(orderSeed);
        if (!found) return;
        vm.prank(MAKER);
        try ace.closeOrder(orderId, MAKER) returns (uint256 units) {
            returnedUnits[orderId] += units;
            closes++;
        } catch {}
    }

    function repay(uint256 loanSeed, uint256 amtSeed) external {
        _bump("repay");
        (bool found, uint256 loanId) = _liveLoan(loanSeed);
        if (!found) return;
        uint256 debt = read.loan(loanId).debt;
        if (debt == 0) return;
        uint256 amt = bound(amtSeed, 1, debt);
        usdc.mint(MAKER, amt);
        vm.startPrank(MAKER);
        usdc.approve(address(ace), amt);
        try ace.repay(loanId, amt) {
            repays++;
        } catch {}
        vm.stopPrank();
    }

    /// @notice The maker takes what the shipped view says is spare: the excess a cap fill carried above its line.
    function withdrawCollateral(uint256 loanSeed) external {
        _bump("withdrawCollateral");
        (bool found, uint256 loanId) = _liveLoan(loanSeed);
        if (!found) return;
        uint256 w = lens.withdrawableUnits(id, loanId);
        if (w == 0 || w >= read.loan(loanId).collateralUnits) return;
        vm.prank(MAKER);
        try ace.withdrawCollateral(loanId, w, MAKER) {
            withdrawals++;
        } catch {}
    }

    /// @notice A crank on a fill-opened loan, then the record healed so the market is left as it was found.
    function deleverage(uint256 loanSeed) external {
        _bump("deleverage");
        (bool found, uint256 loanId) = _liveLoan(loanSeed);
        if (!found) return;
        uint256 held = read.loan(loanId).collateralUnits;
        _enterBand(loanId);
        try ace.deleverage(loanId, 0, "") {
            if (read.loan(loanId).collateralUnits < held) deleveragesSold++;
        } catch {}
        _heal();
    }

    function warp(uint256 dtSeed) external {
        _bump("warp");
        _warpBy(bound(dtSeed, 1 minutes, 2 days));
    }
}
