// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.36;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {FullMath} from "@uniswap/v4-core/src/libraries/FullMath.sol";
import {Ace} from "../../src/ace/hub/Ace.sol";
import {MarketParams, OpenBounds} from "../../src/ace/hub/Types.sol";
import {ProtocolPolicy} from "../../src/config/Defaults.sol";
import {IAceDeleverageCallback} from "../../src/interfaces/IAceDeleverageCallback.sol";
import {MockERC20} from "../mocks/MockERC20.sol";
import {MockPersistenceRecord} from "../mocks/MockPersistenceRecord.sol";
import {AceFixtures} from "../utils/AceFixtures.sol";
import {AceReader} from "../utils/AceReader.sol";
import {WarpClock} from "../utils/WarpClock.sol";

/// @notice A keeper that fills only `keep` units of every crank and hands the rest straight back.
/// @dev It mints each quoted floor and pays whatever the hub pulls, so `paid()` is the hub's real take, measured.
contract DriftKeeper is IAceDeleverageCallback {
    Ace public immutable ACE;
    MockERC20 public immutable QUOTE;
    IERC20 public immutable COLLATERAL;
    uint256 public keep; // collateral units kept per crank
    uint256 public minted; // every quoted floor, summed

    constructor(Ace ace, MockERC20 quote, IERC20 collateral) {
        ACE = ace;
        QUOTE = quote;
        COLLATERAL = collateral;
        quote.approve(address(ace), type(uint256).max);
    }

    function setKeep(uint256 units) external {
        keep = units;
    }

    function crank(uint256 id) external returns (uint256, uint256) {
        return ACE.deleverage(id, 0, "");
    }

    function onAceDeleverage(uint256 unitsSold, uint256 quoteOwed, bytes calldata) external {
        require(msg.sender == address(ACE), "not the hub");
        uint256 kept = keep < unitsSold ? keep : unitsSold;
        if (unitsSold > kept) COLLATERAL.transfer(msg.sender, unitsSold - kept);
        QUOTE.mint(address(this), quoteOwed);
        minted += quoteOwed;
    }

    /// @notice What the hub actually pulled across every crank.
    function paid() external view returns (uint256) {
        return minted - QUOTE.balanceOf(address(this));
    }
}

/// @title AceDeleverageFragmentDrift
/// @notice Bunni-class confirmation: a ceil that is safe per crank must stay safe across MANY tiny cranks on one armed loan.
/// @notice Each crank's `_owed` ceils against the keeper, so the keeper's aggregate overpay sits in `[0, cranks)` atoms, never below zero.
/// @notice Along the whole sequence the trigger never rises, every net equals the debt it melted, and the armed reservation stays in lockstep.
/// @notice A second regime drives the loan to its `minDebt` head first, then cranks into it: no third party ever takes it under the floor.
/// @dev MUTANT: `Deleverage._owed` `mulDivRoundingUp` -> `mulDiv`; the per-crank floor bound and the aggregate bound both kill it.
/// @dev Every row asserts its own premise: the loan is armed, the cranks sold, a crank was inexact, the cap bound.
abstract contract AceDeleverageFragmentDriftBase is WarpClock {
    Ace internal ace;
    AceReader internal read;
    bytes32 internal id;
    MockERC20 internal q;
    MockERC20 internal c;
    MockPersistenceRecord internal record;
    DriftKeeper internal keeper;
    uint256 internal loanId;
    uint256 internal ps; // the market's price and the record's windowed minimum: one whole quote per whole collateral
    uint256 internal minDebt;

    address internal borrower = address(0xB0B);

    uint256 internal constant S = 1 << 96;
    uint256 internal constant K = 1.4e18;
    uint256 internal constant EPS_C = 10000 - ProtocolPolicy.DELEVERAGE_FLOOR_EPS_BPS;
    uint256 internal constant BAND = 3000;
    uint256 internal constant TARGET = 5000;
    uint256 internal constant STOP = 1000;
    uint256 internal constant CUT = 500;
    uint256 internal constant THETA = 7100; // trigger at 71% of the price: in band, above target, and the cut-charging restore fits

    /// @dev The running sums one crank sequence leaves behind.
    struct Tally {
        uint256 sold;
        uint256 out;
        uint256 net;
        uint256 cranks; // cranks that sold at least one unit
        uint256 inexact; // cranks whose floor division left a remainder
        uint256 shrinks; // cranks that shrank the armed reservation
    }

    function _qd() internal pure virtual returns (uint8);

    function _debt() internal pure returns (uint256) {
        return 10_000 * 10 ** _qd();
    }

    /// @dev Builds the market and one ARMED loan at THETA, in band and out of distress, with the keeper standing by.
    function _build(uint256 minDebt_) internal {
        _warpTo(1_000_000);
        minDebt = minDebt_;
        q = new MockERC20("Q", "Q", _qd());
        c = new MockERC20("C18", "C18", 18);
        ps = AceFixtures.px(1e18, address(q), address(c));
        record = new MockPersistenceRecord(address(q), address(c));
        record.setMinPrice(ps);

        MarketParams memory p = AceFixtures.marketParams(address(q), address(c));
        p.price = ps;
        p.record = address(record);
        p.minDebt = minDebt_;
        p.deleverageFloorEpsBps = ProtocolPolicy.DELEVERAGE_FLOOR_EPS_BPS;
        p.deleverageBandBps = BAND;
        p.deleverageTargetBps = TARGET;
        p.deleverageStopBps = STOP;
        p.deleverageProtocolBps = CUT;
        AceFixtures.Deployment memory d = AceFixtures.deployWithTreasury(p, address(0)); // inert sweep: protocolRevenue counts the cut alone
        (ace, read, id) = (d.ace, d.read, d.id);

        uint256 lend = 100 * _debt();
        q.mint(AceFixtures.LENDER, lend);
        vm.startPrank(AceFixtures.LENDER);
        q.approve(address(ace), type(uint256).max);
        ace.deposit(id, lend);
        vm.stopPrank();

        uint256 units = FullMath.mulDiv(K * _debt(), S * 10000, THETA * ps * 1e18);
        c.mint(borrower, units);
        vm.startPrank(borrower);
        c.approve(address(d.positionManager), units);
        loanId = ace.open(id, units, _debt(), ProtocolPolicy.MIN_TENOR, borrower, OpenBounds(0, 0, 0));
        ace.setAutoRefinance(loanId, ProtocolPolicy.MIN_TENOR, 0, 0);
        vm.stopPrank();

        _warpBy(1 days);
        record.setBandPrice(read.triggerPrice(loanId)); // persisted below the band level and not below the trigger
        keeper = new DriftKeeper(ace, q, IERC20(address(c)));
        assertGt(read.reservedOf(loanId), 0, "PREMISE: the loan is armed, so it holds a roll reservation");
        assertEq(read.rollReserve(id), read.reservedOf(loanId), "PREMISE: it is the market's only armed loan");
    }

    /// @dev The most units whose owed floor is `proceeds` quote atoms.
    function _unitsFor(uint256 proceeds) internal view returns (uint256) {
        return FullMath.mulDiv(proceeds, 10000 * S, ps * EPS_C);
    }

    /// @dev The keeper's floor for `units`, rounded against the keeper; used for premises and the one-shot reference.
    function _owedRef(uint256 units) internal view returns (uint256) {
        return FullMath.mulDivRoundingUp(ps, units * EPS_C, 10000 * S);
    }

    /// @dev The state one crank is judged against, read before it runs.
    struct Snap {
        uint256 debt;
        uint256 rev;
        uint256 claim;
        uint256 owed;
        uint256 units;
        uint256 trig;
        uint256 res;
        uint256 hub;
        uint256 keeperUnits;
    }

    function _snap() internal view returns (Snap memory s) {
        s.debt = read.debtOf(loanId);
        s.rev = read.protocolRevenue(id);
        s.claim = read.claimOf(id, loanId);
        s.owed = read.poolOwed(id);
        s.units = read.loan(loanId).collateralUnits;
        s.trig = read.triggerPrice(loanId);
        s.res = read.reservedOf(loanId);
        s.hub = q.balanceOf(address(ace));
        s.keeperUnits = c.balanceOf(address(keeper));
    }

    /// @dev One crank, with every per-crank law checked against independently read state.
    function _crankOnce(Tally memory t) internal {
        Snap memory b = _snap();
        (uint256 sold, uint256 out) = keeper.crank(loanId);
        uint256 melted = b.debt - read.debtOf(loanId);
        _checkMoney(b, sold, out, melted);
        _checkPrice(t, sold, out);
        _checkLoan(t, b);
        t.sold += sold;
        t.out += out;
        t.net += melted;
        if (sold != 0) t.cranks++;
    }

    /// @dev Conservation: proceeds split into melt and cut, and every ledger moved by exactly its leg.
    function _checkMoney(Snap memory b, uint256 sold, uint256 out, uint256 melted) internal view {
        uint256 cut = read.protocolRevenue(id) - b.rev;
        assertEq(out, melted + cut, "every atom of proceeds is either melted debt or the protocol cut");
        assertTrue(cut == 0 || cut == (out * CUT) / 10000, "the cut is zero or the floored share of this crank");
        assertEq(q.balanceOf(address(ace)) - b.hub, out, "the hub received exactly the proceeds it reported");
        assertEq(b.claim - read.claimOf(id, loanId), melted, "the claim melted by exactly the net");
        assertEq(read.poolOwed(id) - b.owed, melted, "and the lender was credited exactly the net");
        assertEq(b.units - read.loan(loanId).collateralUnits, sold, "the position lost exactly the units sold");
        assertEq(c.balanceOf(address(keeper)) - b.keeperUnits, sold, "and the keeper holds exactly those units");
    }

    /// @dev The crank's price: never under the floor value of its units, and over it by under one atom.
    function _checkPrice(Tally memory t, uint256 sold, uint256 out) internal view {
        uint256 num = ps * sold * EPS_C;
        uint256 den = 10000 * S;
        assertGe(out * den, num, "a crank never pays under the floor value of what it took");
        assertLt(out * den, num + den, "and overpays by under one quote atom");
        if (sold != 0 && num % den != 0) t.inexact++;
    }

    /// @dev The loan after the crank: trigger, reservation lockstep, and the minDebt floor.
    function _checkLoan(Tally memory t, Snap memory b) internal view {
        assertLe(read.triggerPrice(loanId), b.trig, "a crank never raises the trigger");
        uint256 res = read.reservedOf(loanId);
        assertEq(read.rollReserve(id), res, "the market's roll reserve is this loan's share, after every crank");
        assertLe(res, b.res, "a crank only ever shrinks the reservation");
        if (res < b.res) t.shrinks++;
        assertGe(read.debtOf(loanId), minDebt, "a third party's crank never takes the debt under minDebt");
    }

    /// @dev Runs `n` cranks and checks the sequence-level laws.
    function _run(uint256 n, uint256 keep) internal returns (Tally memory t) {
        keeper.setKeep(keep);
        uint256 debt0 = read.debtOf(loanId);
        uint256 trig0 = read.triggerPrice(loanId);
        for (uint256 i; i < n; ++i) {
            _crankOnce(t);
        }
        assertEq(t.net, debt0 - read.debtOf(loanId), "the nets sum to the debt melted, exactly");
        assertEq(keeper.paid(), t.out, "the keeper paid exactly the proceeds the cranks reported");
        assertLe(read.triggerPrice(loanId), trig0, "the trigger ends no higher than it started");
        if (t.cranks == 0) return t;
        uint256 oneShot = _owedRef(t.sold);
        assertGe(t.out, oneShot, "the keeper never pays less than one crank of the same units would");
        assertLt(t.out - oneShot, t.cranks, "and overpays by fewer atoms than it cranked");
        assertGe(t.out * 10000 * S, ps * t.sold * EPS_C, "the aggregate is never under the exact floor value");
        emit log_named_uint("cranks that sold", t.cranks);
        emit log_named_uint("keeper overpay vs one shot, atoms", t.out - oneShot);
        emit log_named_uint("inexact cranks", t.inexact);
        emit log_named_uint("reservation shrinks", t.shrinks);
    }

    /// @notice N tiny cranks on one armed loan far above minDebt: every crank sells, and the drift stays in the band the ceil allows.
    function testFuzz_ManyTinyCranks_NoDrift(uint256 nSeed, uint256 keepSeed) public {
        _build(10 ** _qd() * 10);
        uint256 n = bound(nSeed, 2, 50);
        uint256 keep = bound(keepSeed, 1, _unitsFor(50));
        Tally memory t = _run(n, keep);
        assertEq(t.cranks, n, "PREMISE: every crank sold, so the sequence is n cranks long");
        assertGt(t.inexact, 0, "PREMISE: a crank left a remainder, so a floor would have under-charged it");
    }

    /// @notice Fifty fixed cranks of an odd lot: the reservation demonstrably shrinks, and stays the market's whole reserve throughout.
    function test_FiftyOddLots_ReservationShrinksInLockstep() public {
        _build(10 ** _qd() * 10);
        Tally memory t = _run(50, _unitsFor(37) + 12_345);
        assertEq(t.cranks, 50, "PREMISE: all fifty cranks sold");
        assertGt(t.inexact, 0, "PREMISE: a crank left a remainder");
        assertGt(t.shrinks, 0, "PREMISE: the melt shrank the reservation, so the lockstep row is not a pair of zeros");
    }

    /// @notice The dust-first regime: minDebt sits a fuzzed head under the debt, and N tiny cranks drive into it.
    /// @dev The head is at most half what the cranks could realize, so the `room` cap MUST bind before the run ends.
    function testFuzz_CranksIntoTheMinDebtHead_NeverCrossIt(uint256 nSeed, uint256 keepSeed, uint256 headSeed) public {
        uint256 n = bound(nSeed, 2, 50);
        ps = FullMath.mulDiv(1e18, S, 1e18 * 10 ** (18 - _qd())); // the frame's par, so the sizing is known before the build
        uint256 keep = bound(keepSeed, 1, _unitsFor(20));
        uint256 perCrank = _owedRef(keep);
        uint256 head = bound(headSeed, 1, (n * perCrank) / 2 == 0 ? 1 : (n * perCrank) / 2);
        uint256 psFrame = ps;
        _build(_debt() - head);
        assertEq(ps, psFrame, "PREMISE: the build priced the market at the frame's par the sizing assumed");
        Tally memory t = _run(n, keep);
        assertGt(t.cranks, 0, "PREMISE: at least one crank sold");
        assertLt(read.debtOf(loanId) - minDebt, perCrank, "PREMISE: the head ran out, so the minDebt cap bound");
    }
}

/// @notice A 0-decimal quote: one atom is one whole quote, so a one-unit crank's ceil is the largest relative overpay the frame admits.
contract AceDeleverageFragmentDriftQ0Test is AceDeleverageFragmentDriftBase {
    function _qd() internal pure override returns (uint8) {
        return 0;
    }
}

/// @notice A 6-decimal quote against 18-decimal collateral: the shipped USDC shape, at sub-cent crank sizes.
contract AceDeleverageFragmentDriftQ6Test is AceDeleverageFragmentDriftBase {
    function _qd() internal pure override returns (uint8) {
        return 6;
    }
}
