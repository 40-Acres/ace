// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.36;

import {WarpClock} from "../utils/WarpClock.sol";
import {Ace, InventoryHeld, NoRecordPrice} from "../../src/ace/hub/Ace.sol";
import {RecordUnreadable} from "../../src/ace/hub/Borrower.sol";
import {UnitsBelowCallerFloor} from "../../src/ace/hub/Lender.sol";
import {Loan, MarketParams, OpenBounds} from "../../src/ace/hub/Types.sol";
import {PositionManager} from "../../src/ace/positions/PositionManager.sol";
import {MockERC20} from "../mocks/MockERC20.sol";
import {MockPersistenceRecord} from "../mocks/MockPersistenceRecord.sol";
import {AceFixtures} from "../utils/AceFixtures.sol";
import {AceReader} from "../utils/AceReader.sol";

/// @title AceAskDecimalsHandler
/// @notice The ask's firing regimes under a stateful walk, which `AceHandler`'s 18-decimal, fee-free market never reaches.
/// @notice M0: 0-decimal collateral at an ETH-shaped price and a 25 bps fee, so one atom is ~2001 quote atoms and not a whole number of them.
/// @notice M1: 6-decimal collateral at the same price and no fee, so the zero-deliver window is shown to follow price, not decimals alone.
/// @notice M2: 18-decimal collateral at a cheap Q96 price and a 25 bps fee, the regime where the sizing price's fee ceiling carries weight.
/// @dev Every buy is checked inside the action and LATCHED here, because forge reverts what an `invariant_` writes.
/// @dev The ask price is derived as the hub derives it: `max(price, askFloor)`, the floor read off the record at the buy.
contract AceAskDecimalsHandler is WarpClock {
    uint256 internal constant N = 3; // markets: M0, M1, M2
    uint256 internal constant UNIT_SCALE = 1 << 96;
    uint256 internal constant CHEAP_PRICE = 792_281_625_199; // == 399 mod 400, so `price * 25 mod 1e4` is 9975, the widest remainder

    Ace public ace;
    PositionManager public positionManager;
    AceReader public read;
    MockERC20 public usdc;
    address public lender = AceFixtures.LENDER;
    address public borrower = address(0xB0B);
    address public keeper = address(0xCAFE);
    address public buyer = address(0xB0FF);

    bytes32[N] public ids;
    MockERC20[N] public colls;
    MockPersistenceRecord[N] public records;
    uint256[N] public prices;
    uint256[N] public fees;
    uint256[N] internal _minPrincipal;
    uint256[N] internal _maxPrincipal;

    uint256[] internal _loanIds;
    mapping(uint256 => uint256) public marketIndexOf;
    mapping(bytes32 => uint256) public calls;

    bool public bookedWithoutDelivery; // a buy charged quote for a leg that delivered no units
    bool public chargedPastBudget; // a buy charged more than the caller's `stableIn`
    bool public hubDeltaMismatch; // the hub's quote balance moved by other than the charge
    bool public poolDeltaMismatch; // the lender's pool credit moved by other than the charge
    bool public potDeltaMismatch; // the pot fell by other than the units delivered
    bool public deliveryMismatch; // the buyer received other than the units reported
    bool public chargeLawBroken; // the charge was not `g + ceil(g * fee / 1e4)` on the ask value `g` of what left
    bool public unexpectedBuyRefusal; // a buy reverted outside `_expectedRefusal`, e.g. an overcharge the buyer cannot fund failing the pull
    bytes4 public unexpectedRefusalSelector; // the first such revert's selector; zero for a bare revert
    uint256 public breachLoan; // the first breach's loan, budget, units and charge, for the report
    uint256 public breachBudget;
    uint256 public breachUnits;
    uint256 public breachCharge;

    uint256 public buysLanded;
    uint256 public buysRefused; // expected refusals only; an unexpected one latches instead
    bytes4 public lastBuyRefusal;
    uint256 public buysRefusedUnexpected;
    uint256 public zeroDeliverInWindow; // buys whose budget afforded an atom and that delivered none, charged nothing
    uint256 public fillsLanded; // buys that delivered at least one unit
    uint256 public fillsWithFeeRemainder; // of those, fills whose fee left a remainder, so a floor and a ceiling differ
    uint256[N] public fillsPerMarket;
    uint256 public opensLanded;
    uint256 public opensRefused;
    uint256 public settlesLanded;
    uint256 public repaysLanded;
    uint256 public repaysRefused;
    bytes4 public lastRepayRefusal;
    uint256 public redeemsLanded;
    uint256 public collectsLanded;

    constructor() {
        _warpTo(1_000_000);
        usdc = new MockERC20("USD Coin", "USDC", 6);
        colls[0] = new MockERC20("Zero", "C0", 0);
        colls[1] = new MockERC20("Six", "C6", 6);
        colls[2] = new MockERC20("Cheap", "C18", 18);
        prices[0] = AceFixtures.priceAt(address(usdc), address(colls[0]), 76020);
        prices[1] = AceFixtures.priceAt(address(usdc), address(colls[1]), 76020);
        prices[2] = CHEAP_PRICE;
        (fees[0], fees[1], fees[2]) = (25, 0, 25);
        (_minPrincipal[0], _maxPrincipal[0]) = (100e6, 5_000e6);
        (_minPrincipal[1], _maxPrincipal[1]) = (100e6, 5_000e6);
        (_minPrincipal[2], _maxPrincipal[2]) = (1_000_000e6, 5_000_000e6);

        AceFixtures.Deployment memory d = AceFixtures.deploy(_params(0));
        (ace, positionManager, read, ids[0]) = (d.ace, d.positionManager, d.read, d.id);
        ids[1] = ace.createMarket(_params(1));
        ids[2] = ace.createMarket(_params(2));
        for (uint256 i; i < N; i++) {
            require(read.marketState(ids[i]).unitScale == UNIT_SCALE, "FIXTURE: a market is not at the atom frame's scale");
            require(ace.idToMarketParams(ids[i]).fillFeeBps == fees[i], "FIXTURE: genesis did not store the fee");
        }
        require(prices[0] > UNIT_SCALE && prices[0] % UNIT_SCALE != 0, "FIXTURE: M0's atom is not a fractional number of quote atoms");
        require(prices[1] > UNIT_SCALE && prices[1] % UNIT_SCALE != 0, "FIXTURE: M1's atom is not a fractional number of quote atoms");
        require(prices[2] < UNIT_SCALE, "FIXTURE: M2's atom is not worth less than a quote atom");

        _deposit(0, 200_000e6);
        _deposit(1, 200_000e6);
        _deposit(2, 30_000_000e6);
        _baseline();
    }

    /// @dev Recordful for the SETTLEMENT rule; the record answers the max sentinel, which reads as no ask floor.
    function _params(uint256 i) internal returns (MarketParams memory p) {
        records[i] = new MockPersistenceRecord(address(usdc), address(colls[i]));
        records[i].setMinPrice(type(uint256).max);
        p = AceFixtures.marketParams(address(usdc), address(colls[i]));
        p.record = address(records[i]);
        p.baseBps = 1;
        p.settleBountyBps = 0; // no sliver, so every unit reaches the pot
        p.fillFeeBps = fees[i];
        p.price = prices[i];
    }

    /// @notice Pre-snapshot proof that every check can fire: a settled pot per market, then a zero-deliver buy and a filling buy.
    /// @dev UNGUARDED requires: a fixture that cannot reach its regime must fail setUp, never tally as a quiet run.
    function _baseline() internal {
        for (uint256 i; i < N; i++) {
            uint256 loanId = _open(i, _maxPrincipal[i]);
            require(loanId != 0, "BASELINE: the open failed");
            _warpAtLeastTo(read.loan(loanId).expiry);
            vm.prank(keeper);
            ace.forceClose(loanId);
            settlesLanded++;
            uint256 pot = read.invPotOf(ids[i], loanId);
            require(pot > 2, "BASELINE: settlement left fewer than three atoms in the pot");
            uint256 per = _effPrice(i) / UNIT_SCALE;
            if (per >= 2) {
                (bool ok, uint256 units, uint256 charged) = _buyAndCheck(loanId, per + 1);
                require(ok && units == 0 && charged == 0, "BASELINE: the zero-deliver window did not deliver and charge nothing");
            }
            uint256 eff = _effPrice(i);
            uint256 budget = per >= 2 ? (2 * eff + UNIT_SCALE - 1) / UNIT_SCALE : (pot / 2) * eff / UNIT_SCALE; // two atoms, else half the pot
            (bool ok2, uint256 units2, uint256 charged2) = _buyAndCheck(loanId, budget);
            require(ok2 && units2 > 0 && charged2 > 0, "BASELINE: a funded buy did not fill");
        }
        require(!anyBreach(), "BASELINE: a buy broke a check before the campaign began");
        require(zeroDeliverInWindow == 2, "BASELINE: M0 and M1 did not both reach the zero-deliver window");
        require(fillsWithFeeRemainder > 0, "BASELINE: no fill left a fee remainder, so the charge law is untested");
    }

    // ---- views for the suite ----

    /// @notice Whether any buy broke any check.
    function anyBreach() public view returns (bool) {
        return bookedWithoutDelivery || chargedPastBudget || hubDeltaMismatch || poolDeltaMismatch || potDeltaMismatch || deliveryMismatch || chargeLawBroken
            || unexpectedBuyRefusal;
    }

    /// @notice The three markets, every one quoting in `usdc`.
    function markets() external view returns (bytes32[] memory m) {
        m = new bytes32[](N);
        for (uint256 i; i < N; i++) {
            m[i] = ids[i];
        }
    }

    /// @notice Per-action call count, for the run report.
    function callCount(string memory tag) external view returns (uint256) {
        return calls[keccak256(bytes(tag))];
    }

    /// @notice The ask price the hub would quote market `i` now: its price, lifted by the record's floor when one is set.
    function askPriceOf(uint256 i) public view returns (uint256) {
        uint256 cap = records[i].minPrice(address(usdc), address(colls[i]));
        uint256 askFloor = cap == type(uint256).max ? 0 : cap;
        return askFloor > prices[i] ? askFloor : prices[i];
    }

    // ---- actions ----

    /// @notice The lender rests cash in one market.
    function deposit(uint256 marketSeed, uint256 amtSeed) external {
        _bump("deposit");
        uint256 i = marketSeed % N;
        _deposit(i, bound(amtSeed, 1e6, i == 2 ? 10_000_000e6 : 50_000e6));
    }

    /// @notice A borrower opens a loan whose collateral is worth 2.4x its principal.
    function open(uint256 marketSeed, uint256 principalSeed) external {
        _bump("open");
        uint256 i = marketSeed % N;
        _open(i, bound(principalSeed, _minPrincipal[i], _maxPrincipal[i]));
    }

    /// @notice Time passes: loans age toward expiry and settled pots toward their ask.
    function warp(uint256 dtSeed) external {
        _bump("warp");
        _warpBy(bound(dtSeed, 1 hours, 3 days));
    }

    /// @notice A keeper settles a live loan at expiry, warping there first; settlement is what fills a pot.
    function forceClose(uint256 loanSeed) external {
        _bump("forceClose");
        uint256 loanId = _pick(loanSeed, true);
        if (loanId == 0) return;
        _warpAtLeastTo(read.loan(loanId).expiry);
        vm.prank(keeper);
        try ace.forceClose(loanId) {
            settlesLanded++;
        } catch {}
    }

    /// @notice The borrower repays a live loan in full before expiry.
    function repay(uint256 loanSeed) external {
        _bump("repay");
        uint256 loanId = _pick(loanSeed, true);
        if (loanId == 0) return;
        Loan memory l = read.loan(loanId);
        _warpAtLeastTo(0); // re-anchors the clock to the chain, which the invariant run moves between calls, and warps nowhere
        if (_now() >= l.expiry) return;
        usdc.mint(borrower, l.debt);
        vm.startPrank(borrower);
        usdc.approve(address(ace), l.debt);
        try ace.repay(loanId, l.debt) {
            repaysLanded++;
        } catch (bytes memory r) {
            repaysRefused++;
            if (r.length >= 4) lastRepayRefusal = bytes4(r);
        }
        vm.stopPrank();
    }

    /// @notice The lender pulls its uncollected credit.
    function collect() external {
        _bump("collect");
        vm.prank(lender);
        try ace.collect(address(usdc), lender) returns (uint256 paid) {
            if (paid > 0) collectsLanded++;
        } catch {}
    }

    /// @notice The lender takes a settled pot whole, in kind.
    function redeemInKind(uint256 loanSeed) external {
        _bump("redeemInKind");
        uint256 loanId = _pickPot(loanSeed);
        if (loanId == 0) return;
        vm.prank(lender);
        try ace.redeemInKind(loanId, lender) {
            redeemsLanded++;
        } catch {}
    }

    /// @notice A stranger buys from a settled pot on a budget of `atoms` all-in units plus a sub-unit slack.
    /// @dev `atoms` spans [0, pot + 1], so the walk reaches the zero-deliver window, one atom, a partial fill and the whole pot.
    /// @dev One buy in four is sized for the SMALLEST leg the ask prices, which a uniform draw over a large pot never lands.
    /// @dev Where an atom is worth a quote atom or more that is one atom: the zero-deliver window, except on a one-atom pot, which sells whole.
    /// @dev Where it is worth less (M2) it is two quote atoms: one cannot fill, its gross floors to zero at any nonzero fee.
    function buy(uint256 loanSeed, uint256 atomsSeed, uint256 slackSeed) external {
        _bump("buy");
        uint256 loanId = _pickPot(loanSeed);
        if (loanId == 0) return;
        uint256 i = marketIndexOf[loanId];
        uint256 eff = _effPrice(i);
        uint256 per = eff / UNIT_SCALE;
        uint256 budget;
        if (atomsSeed % 4 == 0) {
            budget = per == 0 ? 2 : per + slackSeed % per;
        } else {
            uint256 atoms = bound(atomsSeed, 0, read.invPotOf(ids[i], loanId) + 1);
            budget = (atoms * eff) / UNIT_SCALE + (per == 0 ? 0 : slackSeed % per);
        }
        _buyAndCheck(loanId, budget);
    }

    // ---- shared ----

    function _bump(string memory tag) internal {
        calls[keccak256(bytes(tag))]++;
    }

    /// @dev The all-in unit price the ask sizes off, its fee rounded up; recomputed here rather than read off the hub.
    function _effPrice(uint256 i) internal view returns (uint256) {
        uint256 askPrice = askPriceOf(i);
        return askPrice + (askPrice * fees[i] + 9999) / 10000;
    }

    function _deposit(uint256 i, uint256 amt) internal {
        usdc.mint(lender, amt);
        vm.startPrank(lender);
        usdc.approve(address(ace), amt);
        ace.deposit(ids[i], amt);
        vm.stopPrank();
    }

    /// @dev Collateral sized by VALUE at 2.4x the principal, plus the one atom the coverage line's ceiling may need.
    function _open(uint256 i, uint256 principal) internal returns (uint256 loanId) {
        uint256 units = ((principal * 12) / 5) * UNIT_SCALE / prices[i] + 1;
        colls[i].mint(borrower, units);
        vm.startPrank(borrower);
        colls[i].approve(address(positionManager), units);
        try ace.open(ids[i], units, principal, 0, borrower, OpenBounds(0, 0, 0)) returns (uint256 id_) {
            loanId = id_;
            _loanIds.push(id_);
            marketIndexOf[id_] = i;
            opensLanded++;
        } catch {
            opensRefused++;
        }
        vm.stopPrank();
    }

    /// @dev The first tracked loan at or after `seed` that is live (`live`) or closed (`!live`); zero when none is.
    function _pick(uint256 seed, bool live) internal view returns (uint256) {
        uint256 n = _loanIds.length;
        for (uint256 k; k < n; k++) {
            uint256 cand = _loanIds[(seed + k) % n];
            if ((read.loan(cand).closedAt == 0) == live) return cand;
        }
        return 0;
    }

    /// @dev The first tracked settled loan at or after `seed` whose pot still holds units; zero when none does.
    function _pickPot(uint256 seed) internal view returns (uint256) {
        uint256 n = _loanIds.length;
        for (uint256 k; k < n; k++) {
            uint256 cand = _loanIds[(seed + k) % n];
            if (read.loan(cand).closedAt != 0 && read.invPotOf(ids[marketIndexOf[cand]], cand) > 0) return cand;
        }
        return 0;
    }

    /// @dev One buy, every check measured against state read before and after it, the breach latched on the handler.
    /// @dev The buyer holds twice the budget under an UNLIMITED allowance, so an overcharge up to that lands as a debit.
    /// @dev Past what the buyer holds it fails the pull instead, which is why an unexpected revert latches rather than tallies.
    function _buyAndCheck(uint256 loanId, uint256 budget) internal returns (bool ok, uint256 unitsOut, uint256 charged) {
        uint256 i = marketIndexOf[loanId];
        _warpAtLeastTo(read.inventoryAskOpensAt(loanId));
        usdc.mint(buyer, 2 * budget);
        vm.prank(buyer);
        usdc.approve(address(ace), type(uint256).max);
        Before memory b = Before(
            usdc.balanceOf(address(ace)), ace.lenderOwed(lender, address(usdc)), read.invPotOf(ids[i], loanId), colls[i].balanceOf(buyer), askPriceOf(i)
        );

        vm.prank(buyer);
        try ace.buyInventory(loanId, budget, 0, buyer) returns (uint256 u, uint256 c) {
            (ok, unitsOut, charged) = (true, u, c);
        } catch (bytes memory r) {
            bytes4 sel = r.length >= 4 ? bytes4(r) : bytes4(0);
            if (_expectedRefusal(sel)) {
                buysRefused++;
                lastBuyRefusal = sel;
            } else {
                buysRefusedUnexpected++;
                if (!unexpectedBuyRefusal) (unexpectedBuyRefusal, unexpectedRefusalSelector) = (true, sel);
                if (breachLoan == 0) (breachLoan, breachBudget) = (loanId, budget);
            }
            return (false, 0, 0);
        }
        buysLanded++;
        _judge(loanId, budget, b, unitsOut, charged);
    }

    /// @notice The hub's refusals of `buyInventory` a correct hub may give this handler's buyer: timing, the record, the caller's own bound.
    /// @dev `InventoryHeld`: the pot's hold has not elapsed, or the loan is live.
    /// @dev `NoRecordPrice`, `RecordUnreadable`: the record answered zero, or did not answer.
    /// @dev `UnitsBelowCallerFloor`: the fill fell short of `minUnitsOut`, a zero fill included.
    /// @dev DELIBERATELY OUT: `SyntheticCapExceeded` (a pot holds only settled units, so it fires only on an accounting break).
    /// @dev Also out: the recipient rails, `NoMarket`, the reentrancy guard, and every failure of the pull or the release.
    function _expectedRefusal(bytes4 sel) internal pure returns (bool) {
        return sel == InventoryHeld.selector || sel == NoRecordPrice.selector || sel == RecordUnreadable.selector || sel == UnitsBelowCallerFloor.selector;
    }

    /// @dev What the buy found before it ran, so `_judge` measures every delta against one snapshot.
    struct Before {
        uint256 hub;
        uint256 owed;
        uint256 pot;
        uint256 got;
        uint256 askPrice;
    }

    /// @dev Every check on one landed buy; a breach is latched and its first instance recorded for the report.
    function _judge(uint256 loanId, uint256 budget, Before memory b, uint256 unitsOut, uint256 charged) internal {
        uint256 i = marketIndexOf[loanId];
        uint256 g = (unitsOut * b.askPrice + UNIT_SCALE - 1) / UNIT_SCALE; // the ask value of what left, ceiled as the hub prices it
        bool breach;
        if (charged != 0 && unitsOut == 0) (bookedWithoutDelivery, breach) = (true, true);
        if (charged > budget) (chargedPastBudget, breach) = (true, true);
        /// @dev ADDITION FORM throughout: a subtraction that underflowed would revert the action, and an unfailed revert hides a breach.
        if (usdc.balanceOf(address(ace)) != b.hub + charged) (hubDeltaMismatch, breach) = (true, true);
        if (ace.lenderOwed(lender, address(usdc)) != b.owed + charged) (poolDeltaMismatch, breach) = (true, true);
        if (read.invPotOf(ids[i], loanId) + unitsOut != b.pot) (potDeltaMismatch, breach) = (true, true);
        if (colls[i].balanceOf(buyer) != b.got + unitsOut) (deliveryMismatch, breach) = (true, true);
        if (charged != g + (g * fees[i] + 9999) / 10000) (chargeLawBroken, breach) = (true, true);
        if (breach && breachLoan == 0) (breachLoan, breachBudget, breachUnits, breachCharge) = (loanId, budget, unitsOut, charged);

        if (unitsOut == 0 && budget * UNIT_SCALE >= _effPrice(i)) zeroDeliverInWindow++;
        if (unitsOut > 0) {
            fillsLanded++;
            fillsPerMarket[i]++;
            if ((g * fees[i]) % 10000 != 0) fillsWithFeeRemainder++;
        }
    }
}
