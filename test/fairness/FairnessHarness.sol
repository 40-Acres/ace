// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.36;

import {FullMath} from "@uniswap/v4-core/src/libraries/FullMath.sol";
import {ExtendRig} from "../utils/ExtendRig.sol";
import {MarketParams, OpenBounds} from "../../src/ace/hub/Types.sol";

/// @title FairnessHarness
/// @notice The differential rig of the fairness table: two runs that differ by ONE action, walked down one price path, settled, compared per party.
/// @notice A run opens one loan from one direct lender, prints the record step by step while a keeper cranks and settles, then force-closes at expiry.
/// @notice Three classes share the rig's pair and lender: a recorded market with the band off, one with the band on, and a recordless one.
/// @dev The record is the rig's mock in band mode: a print at `v` makes every level above `v` persistently below at once, so persistence is not timed.
/// @dev The lender's protective measure is its SHORTFALL: the debt at settlement less the seized units at the mark, floored at zero.
/// @dev The borrower's measure is its WEALTH: wallet and owed quote, plus wallet and owed units at the path's last price.
/// @dev A known violation's property row reads its `FIXED_<issue>` flag; flip the flag when the fix lands and delete the known row it turns red.
/// @dev A new verb joins by adding an `Act` member and its branch in `_act`.
abstract contract FairnessHarness is ExtendRig {
    enum Kind {
        BandOff,
        BandOn,
        Recordless,
        BandOnNoCut // the band-on market with no protocol cut on a restore, the case most markets run
    }

    enum Act {
        None,
        Repay,
        StrangerRepay,
        LenderRepay,
        Deposit,
        AddCollateral, // the holder adds units from its own wallet, minted to it in this run alone
        StrangerAdd // a stranger adds units it was minted, and is owed nothing for them
    }

    enum Mark {
        Settle,
        End
    }

    struct Run {
        Kind kind;
        uint256 principal;
        uint256 thetaBps; // the trigger at open, in bps of par
        uint256 pledgeBps; // the lot, in bps of the lot `thetaBps` implies
        uint256[] path; // the record's print at each step, in bps of par
        Act act;
        uint256 actAt; // the step whose print the action follows, before any keeper moves
        uint256 actAmount; // quote for a repay or a deposit; units for an add
        bool noCranks; // the counterfactual where no keeper deleverages
        bool idle; // the counterfactual where no keeper acts before expiry
    }

    struct Outcome {
        bytes32 mid;
        uint256 loanId;
        uint256 lot; // units pledged at the open, plus any added before the close
        uint256 added; // units the holder added from its own wallet
        uint256 debtAtClose;
        uint256 pot; // units the market took
        uint256 settlePx; // the price when the loan closed
        uint256 endPx; // the path's last price
        uint256 lenderQuote; // wallet plus resting, lent and owed
        uint256 lenderMinted; // quote minted to the lender for its own act, netted out of its measure
        uint256 borrowerQuote; // wallet plus owed
        uint256 borrowerUnits; // wallet plus owed
        uint256 keeperUnits; // the keeper's sliver
        uint256 spent; // quote the borrower paid on its own loan after the open
        uint256 sold; // units the cranks sold
        bool finalized;
    }

    bool internal constant FIXED_933 = true; // the recorded take follows the trigger inside the term, capped at the coverage line
    bool internal constant FIXED_884 = true; // a granted lender can no longer keep an in-band loan crankable past its expiry

    uint256 internal constant D = 70_000e6; // the debt every row opens
    uint256 internal constant STEP = 30 minutes; // one print per step
    uint256 internal constant GRID = 25; // the declining path's step, in bps of par
    uint256 internal constant QUOTE_BUDGET = 100_000e6; // the borrower's spare quote before the open, equal in both runs

    bytes32 internal bandOff;
    bytes32 internal recordless;
    bytes32 internal bandOnNoCut;

    function setUp() public virtual override {
        super.setUp();
        bandOff = ace.createMarket(_classParams(Kind.BandOff));
        recordless = ace.createMarket(_classParams(Kind.Recordless));
        bandOnNoCut = ace.createMarket(_classParams(Kind.BandOnNoCut));
    }

    /// @notice The rig's params for one class: the band-on market is the rig's own, the others zero the band and, recordless, the record.
    function _classParams(Kind k) internal view returns (MarketParams memory p) {
        p = _params(alice);
        if (k == Kind.BandOn) return p;
        if (k == Kind.BandOnNoCut) {
            p.deleverageProtocolBps = 0;
            return p;
        }
        (p.deleverageFloorEpsBps, p.deleverageBandBps, p.deleverageTargetBps) = (0, 0, 0);
        (p.deleverageStopBps, p.deleverageProtocolBps) = (0, 0);
        if (k == Kind.Recordless) p.record = address(0);
    }

    function _mid(Kind k) internal view returns (bytes32) {
        if (k == Kind.BandOn) return id;
        if (k == Kind.BandOnNoCut) return bandOnNoCut;
        return k == Kind.BandOff ? bandOff : recordless;
    }

    /// @notice A run at the fixture debt with a lot at `thetaBps`, no action and every keeper awake.
    function _baseRun(Kind k, uint256 thetaBps, uint256[] memory path) internal pure returns (Run memory r) {
        (r.kind, r.principal, r.thetaBps, r.pledgeBps, r.path) = (k, D, thetaBps, 10000, path);
    }

    /// @notice Run `a`, rewind, run `b`, rewind: the outcomes share every state but the one difference, and the chain is left as found.
    function _pairOf(Run memory a, Run memory b) internal returns (Outcome memory oa, Outcome memory ob) {
        uint256 snap = vm.snapshotState();
        oa = _runFor(a);
        vm.revertToState(snap);
        ob = _runFor(b);
        vm.revertToState(snap);
    }

    /// @notice One run: fund, open, walk the path with the keeper after each print, force-close at expiry if still live, and tally.
    function _runFor(Run memory r) internal returns (Outcome memory o) {
        require(r.path.length != 0 && r.path.length * STEP < TEN7, "fairness: the path must fit inside the term");
        o.mid = _mid(r.kind);
        _deposit(o.mid, alice, 2 * r.principal);
        _budget();
        o.loanId = _openRun(o.mid, r);
        o.lot = read.loan(o.loanId).collateralUnits;
        for (uint256 i; i < r.path.length; ++i) {
            _warpBy(STEP);
            _printBps(r.path[i]);
            if (r.act != Act.None && i == r.actAt && !_closed(o.loanId)) _act(r, o);
            if (!r.idle) _keepStep(r, o, _pxOf(r.path[i]));
        }
        o.endPx = _pxOf(r.path[r.path.length - 1]);
        if (!_closed(o.loanId)) _closeAtTerm(o);
        _tallyOf(o);
    }

    /// @notice The borrower's quote budget, minted and approved before the open, so a run that repays less keeps the rest.
    function _budget() internal {
        usdc.mint(borrower, QUOTE_BUDGET);
        vm.startPrank(borrower);
        coll.approve(address(pm), type(uint256).max);
        usdc.approve(address(ace), type(uint256).max);
        vm.stopPrank();
    }

    /// @notice The borrower is minted exactly its lot, so its wealth counts no collateral the loan never touched.
    function _openRun(bytes32 mid, Run memory r) internal returns (uint256 loanId) {
        uint256 units = FullMath.mulDiv(_units(r.principal, r.thetaBps), r.pledgeBps, 10000);
        coll.mint(borrower, units);
        vm.prank(borrower);
        loanId = ace.open(mid, units, r.principal, 0, borrower, OpenBounds(0, 0, 0));
    }

    /// @notice The borrower opens `principal` in `mid` for the market's longest term, its trigger at `thetaBps`, so a top-up has term left to draw on.
    /// @dev Call after `_budget`, which approves custody and the hub.
    function _openLong(bytes32 mid, uint256 principal, uint256 thetaBps) internal returns (uint256 loanId) {
        uint256 units = _units(principal, thetaBps);
        coll.mint(borrower, units);
        vm.prank(borrower);
        loanId = ace.open(mid, units, principal, MAX_T, borrower, OpenBounds(0, 0, 0));
    }

    /// @notice The one action a pair differs by; a future verb is one more member and one more branch here.
    function _act(Run memory r, Outcome memory o) internal virtual {
        if (r.act == Act.Repay) {
            vm.prank(borrower);
            ace.repay(o.loanId, r.actAmount);
            o.spent += r.actAmount;
        } else if (r.act == Act.StrangerRepay) {
            _repayFrom(stranger, o.loanId, r.actAmount);
        } else if (r.act == Act.LenderRepay) {
            _repayFrom(alice, o.loanId, r.actAmount);
            o.lenderMinted += r.actAmount;
        } else if (r.act == Act.Deposit) {
            _deposit(o.mid, alice, r.actAmount);
            o.lenderMinted += r.actAmount;
        } else if (r.act == Act.AddCollateral) {
            _addFrom(borrower, o.loanId, r.actAmount);
            (o.lot, o.added) = (o.lot + r.actAmount, o.added + r.actAmount);
        } else if (r.act == Act.StrangerAdd) {
            _addFrom(stranger, o.loanId, r.actAmount);
            o.lot += r.actAmount;
        }
    }

    /// @dev `payer` is minted `units`, approves custody for them, and adds them to `loanId`.
    function _addFrom(address payer, uint256 loanId, uint256 units) internal {
        coll.mint(payer, units);
        vm.startPrank(payer);
        coll.approve(address(pm), units);
        ace.addCollateral(loanId, units, "");
        vm.stopPrank();
    }

    function _repayFrom(address who, uint256 loanId, uint256 amount) internal {
        usdc.mint(who, amount);
        vm.startPrank(who);
        usdc.approve(address(ace), amount);
        ace.repay(loanId, amount);
        vm.stopPrank();
    }

    /// @notice The keeper after one print: a deleverage crank where the band is on, then a settlement attempt.
    function _keepStep(Run memory r, Outcome memory o, uint256 px) internal {
        if (_closed(o.loanId)) return;
        if ((r.kind == Kind.BandOn || r.kind == Kind.BandOnNoCut) && !r.noCranks) _crank(o);
        if (_closed(o.loanId)) {
            o.settlePx = px;
            return;
        }
        vm.prank(keeper);
        try ace.finalize(o.loanId) {
            (o.finalized, o.settlePx) = (true, px);
        } catch {}
    }

    function _crank(Outcome memory o) internal {
        try ace.deleverage(o.loanId, 0, "") returns (uint256 u, uint256) {
            o.sold += u;
        } catch {}
    }

    function _closeAtTerm(Outcome memory o) internal {
        _warpAtLeastTo(read.loan(o.loanId).expiry);
        vm.prank(keeper);
        ace.forceClose(o.loanId);
        o.settlePx = o.endPx;
    }

    function _tallyOf(Outcome memory o) internal view {
        o.debtAtClose = read.loan(o.loanId).debt;
        o.pot = read.invPotOf(o.mid, o.loanId);
        (uint256 resting, uint256 lent, uint256 owed) = read.lenderPools(alice, address(usdc));
        o.lenderQuote = usdc.balanceOf(alice) + resting + lent + owed;
        o.borrowerQuote = usdc.balanceOf(borrower) + read.quoteOwedOf(o.loanId, borrower);
        o.borrowerUnits = coll.balanceOf(borrower) + read.unitsOwedOf(o.loanId, borrower);
        o.keeperUnits = read.unitsOwedOf(o.loanId, keeper);
    }

    function _closed(uint256 loanId) internal view returns (bool) {
        return read.loan(loanId).closedAt != 0;
    }

    /// @notice Print `bps` of par on the record: the windowed minimum and the persisted level move together.
    function _printBps(uint256 bps) internal {
        uint256 v = _pxOf(bps);
        rec.setBandPrice(v);
        rec.setMinPrice(v);
    }

    function _pxOf(uint256 bps) internal view returns (uint256) {
        return FullMath.mulDiv(par, bps, 10000);
    }

    function _valueAt(uint256 units, uint256 px) internal pure returns (uint256) {
        return FullMath.mulDiv(units, px, S);
    }

    /// @notice The lender's shortfall: the debt left at settlement less what the seized units fetch at the mark, floored at zero.
    function _shortfall(Outcome memory o, Mark m) internal pure returns (uint256) {
        uint256 seized = _valueAt(o.pot, m == Mark.Settle ? o.settlePx : o.endPx);
        return o.debtAtClose > seized ? o.debtAtClose - seized : 0;
    }

    /// @notice The seizure-marked shortfall with the trigger clamped to `max(trigger, price / k)`: the settle print lifted by the clamp's gap.
    /// @dev Inside `k` coverage lines the trigger is at or over `price / k`, the gap is zero, and this is `_shortfall(o, Mark.Settle)` exactly.
    /// @dev Past them a seizure inside the term takes the coverage line, whole only down to `price / k`: the ruled cap, and the residual this nets.
    /// @dev A close at expiry takes the need, which has no cap to clamp; the market's price is `par` in this rig.
    /// @dev The trigger is `k * debt / lot` on the lot pledged at the open, which no crank moves in a band-off run.
    function _clampedShortfall(Outcome memory o) internal view returns (uint256) {
        if (!o.finalized) return _shortfall(o, Mark.Settle);
        uint256 trigger = FullMath.mulDivRoundingUp(K * o.debtAtClose, S, o.lot * 1e18);
        uint256 clamp = FullMath.mulDiv(par, 1e18, K);
        uint256 seized = _valueAt(o.pot, o.settlePx + (clamp > trigger ? clamp - trigger : 0));
        return o.debtAtClose > seized ? o.debtAtClose - seized : 0;
    }

    /// @notice The ruled in-term take: `ceil(lot * 1e18 / k)` capped at the coverage line, never under the need, never past the lot less the sliver.
    /// @dev Spelled from the ruling, not the hub: the need ceiled at the price, the line `requiredAt` plus one atom, the sliver the debt's bounty floored.
    function _cappedTake(uint256 lot, uint256 debt) internal view returns (uint256) {
        uint256 need = FullMath.mulDivRoundingUp(debt, S, par);
        uint256 atTrigger = FullMath.mulDivRoundingUp(lot, 1e18, K);
        uint256 line = FullMath.mulDivRoundingUp(K * debt, S, par * 1e18) + 1;
        uint256 take = atTrigger < line ? atTrigger : line;
        if (take < need) take = need;
        uint256 sliver = FullMath.mulDiv(debt * BOUNTY, S, 10000 * par);
        if (sliver > lot) sliver = lot;
        return take < lot - sliver ? take : lot - sliver;
    }

    /// @notice F2.3b's ruled bound on what a crank melting `melt` of `debt` may cost the borrower: the eps-and-cut haircut, plus `debt / 1e4` of dust.
    /// @dev The rig's eps is 100 bps; its cut is 500 bps, or none on the no-cut market.
    function _feeBound(uint256 melt, uint256 debt, Kind k) internal pure returns (uint256) {
        uint256 cutBps = k == Kind.BandOnNoCut ? 0 : 500;
        return melt * 1e8 / ((10000 - 100) * (10000 - cutBps)) - melt + debt / 1e4;
    }

    /// @notice The borrower's wealth at the path's last price.
    function _wealth(Outcome memory o) internal pure returns (uint256) {
        return o.borrowerQuote + _valueAt(o.borrowerUnits, o.endPx);
    }

    /// @notice The borrower's wealth less what its own added units are worth at the path's last price: what the loan left it.
    function _wealthNetOfAdds(Outcome memory o) internal pure returns (uint256) {
        return _wealth(o) - _valueAt(o.added, o.endPx);
    }

    /// @notice The lender's wealth at the path's last price, net of the quote minted for its own act.
    function _lenderWealth(Outcome memory o) internal pure returns (uint256) {
        return o.lenderQuote + _valueAt(o.pot, o.endPx) - o.lenderMinted;
    }

    /// @notice What a seizure-marked comparison may differ by on a grid path: the debt times two steps over the lower trigger.
    function _gridTol(uint256 debt, uint256 stepBps, uint256 thetaBps) internal pure returns (uint256) {
        return FullMath.mulDiv(debt, 2 * stepBps, thetaBps) + 2;
    }

    function _glide(uint256 fromBps, uint256 toBps, uint256 stepBps) internal pure returns (uint256[] memory p) {
        uint256 n = (fromBps - toBps) / stepBps + 1;
        p = new uint256[](n);
        for (uint256 i; i < n; ++i) {
            p[i] = fromBps - i * stepBps;
        }
    }

    function _flatAt(uint256 bps, uint256 n) internal pure returns (uint256[] memory p) {
        p = new uint256[](n);
        for (uint256 i; i < n; ++i) {
            p[i] = bps;
        }
    }

    function _shifted(uint256[] memory a, uint256 upBps) internal pure returns (uint256[] memory p) {
        p = new uint256[](a.length);
        for (uint256 i; i < a.length; ++i) {
            p[i] = a[i] + upBps;
        }
    }

    /// @notice Par for one print, then `bps` for `n` more: the loan meets the level in the step after its open.
    function _dropTo(uint256 bps, uint256 n) internal pure returns (uint256[] memory p) {
        p = new uint256[](n + 1);
        p[0] = 10000;
        for (uint256 i = 1; i <= n; ++i) {
            p[i] = bps;
        }
    }
}
