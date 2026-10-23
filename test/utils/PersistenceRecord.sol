// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.36;

import {IPersistenceRecord} from "../../src/interfaces/IPersistenceRecord.sol";
import {Math} from "@openzeppelin/contracts/utils/math/Math.sol";
import {FullMath} from "@uniswap/v4-core/src/libraries/FullMath.sol";

/// @title PersistenceRecord
/// @notice TEST FIXTURE: a windowed venue-style record, so the suite can drive the hub's windowed path.
/// @notice Proves price held past a level for a window; grants no borrowing power. Nothing in src deploys it.
/// @dev Lagging floor, never a live quote: silence persists last state, window reads fail-safe to 0/false.
/// @dev The ring is hand-rolled because a MINIMUM over a window is not derivable from cumulative-tick observations.
contract PersistenceRecord is IPersistenceRecord {
    error NotWriter();
    error BadParams();
    error WrongPair();

    struct Obs {
        uint64 time; // bucket start
        uint256 price; // bucket VWAP, truncated and volume-weighted, in the UNIT_SCALE frame
    }

    struct DepthObs {
        uint64 time; // bucket start
        uint256 depth; // minimum venue depth seen in the bucket, quote units
    }

    address public immutable WRITER; // the one address allowed to observe; the test itself, here
    address public immutable QUOTE; // the ordered pair this record prices; genesis binds a market to it
    address public immutable COLLATERAL;
    uint256 public immutable TRUNC_CAP_BPS; // max move per bucket at full volume, bps of the bucket base
    uint64 public immutable OBS_INTERVAL; // bucket width, seconds; writes inside coalesce into one slot
    uint256 public immutable OBS_CAP; // ring capacity in buckets, price and depth rings each
    uint256 public constant UNIT_SCALE = 1 << 96; // the FIXED price frame: prices are quote atoms per collateral atom
    uint256 public immutable VOL_REF_BPS; // fraction of live depth (in units) that earns the full cap, bps
    uint256 public immutable VOL_REF_FLOOR; // denominator floor, units; the depthless-bootstrap reference
    uint256 public immutable DEPTH_WINDOW; // window (seconds) the truncation denominator reads depth over
    uint256 public immutable PERSISTENCE_WINDOW; // the distress window: how long a price must hold to engage the guards
    uint64 public immutable PENDING_WINDOW; // grace on top, before the verb that moves title may be called
    uint256 public immutable SETTLE_WINDOW; // persistence + pending, summed once so no settle read pays an add
    uint256 public constant MIN_PERSISTENCE_WINDOW = 24; // two mainnet blocks: under it a live pool answers almost nothing

    Obs[] internal _obs; // grows to OBS_CAP, then wraps
    uint256 internal _obsSeq; // price buckets ever opened; head slot = (_obsSeq - 1) % OBS_CAP
    uint256 internal _last; // current head price; persists through silence
    uint256 internal _bucketBase; // prior bucket's final price: the truncation base for the open bucket
    uint256 internal _sumVol; // open price bucket: volume accumulator
    uint256 internal _sumPriceVol; // open price bucket: price*volume accumulator

    DepthObs[] internal _depthObs;
    uint256 internal _depthSeq;
    uint256 internal _minDepthAtRoll; // min depth over DEPTH_WINDOW, cached per roll (units; 0 pre-feed)

    /// @notice Every construction value, as ONE named argument.
    /// @dev A STRUCT, not a positional list, and it is load-bearing twice over.
    /// @dev A list this wide exhausts the constructor's decode stack under the legacy pipeline; a struct arrives as one memory pointer.
    /// @dev And a run of same-typed positional values still compiles when one is dropped or reordered; named fields cannot.
    struct Config {
        address writer; // the one address allowed to observe
        uint256 truncCapBps;
        uint256 initialPrice; // the deploy anchor
        uint64 obsInterval;
        uint256 volRefFloor;
        uint256 obsCap;
        uint256 unitScale;
        uint256 volRefBps;
        uint256 depthWindow;
        address quote;
        address collateral;
        uint256 persistenceWindow; // the distress window this record answers over
        uint64 pendingWindow; // grace on top; the settle window is their sum
    }

    constructor(Config memory c) {
        address _writer = c.writer;
        uint256 _truncCapBps = c.truncCapBps;
        uint256 initialPrice = c.initialPrice;
        uint64 _obsInterval = c.obsInterval;
        uint256 _volRefFloor = c.volRefFloor;
        uint256 _obsCap = c.obsCap;
        uint256 _volRefBps = c.volRefBps;
        uint256 _depthWindow = c.depthWindow;
        address _quote = c.quote;
        address _collateral = c.collateral;
        uint256 _persistenceWindow = c.persistenceWindow;
        uint64 _pendingWindow = c.pendingWindow;
        _requireParams(_obsInterval, _volRefFloor, _obsCap, _quote, _collateral, _depthWindow, _persistenceWindow, _pendingWindow);
        QUOTE = _quote;
        COLLATERAL = _collateral;
        WRITER = _writer;
        TRUNC_CAP_BPS = _truncCapBps;
        OBS_INTERVAL = _obsInterval;
        VOL_REF_FLOOR = _volRefFloor;
        OBS_CAP = _obsCap;
        VOL_REF_BPS = _volRefBps;
        DEPTH_WINDOW = _depthWindow;
        PERSISTENCE_WINDOW = _persistenceWindow;
        PENDING_WINDOW = _pendingWindow;
        SETTLE_WINDOW = _persistenceWindow + _pendingWindow;
        _last = initialPrice;
        _bucketBase = initialPrice;
        _obs.push(Obs(uint64(block.timestamp), initialPrice)); // deploy anchor: the record spans from here
        _obsSeq = 1;
    }

    /// @dev Every genesis rail, in its OWN frame: the constructor's decoder plus this cascade overflow one stack under the legacy pipeline.
    function _requireParams(
        uint64 _obsInterval,
        uint256 _volRefFloor,
        uint256 _obsCap,
        address _quote,
        address _collateral,
        uint256 _depthWindow,
        uint256 _persistenceWindow,
        uint64 _pendingWindow
    ) private pure {
        if (_obsInterval == 0 || _obsInterval > 1 days) revert BadParams(); // 0 re-opens spam eviction
        if (_volRefFloor == 0) revert BadParams(); // full-weight-dust is set via floor = 1
        /// @dev Unreachable under the window rails below, which force a span and so a ring of at least two slots.
        /// @dev Kept for the sharper message: a caller who got the ring wrong is told about the ring.
        if (_obsCap < 2) revert BadParams(); // a 1-slot ring can never span a window
        if (_quote == address(0) || _collateral == address(0) || _quote == _collateral) revert BadParams();
        /// @dev The window floor is absolute, not relative to the bucket: a bucket narrower than a block does not shrink it.
        /// @dev Under it a live pool is refused for most of every bucket, which is a market that admits nothing.
        if (_persistenceWindow < MIN_PERSISTENCE_WINDOW) revert BadParams();
        /// @dev Two bucket widths, so a read still spans a full bucket after the head rolls.
        if (_persistenceWindow < 2 * uint256(_obsInterval)) revert BadParams();
        if (_pendingWindow == 0) revert BadParams(); // grace of zero settles on the distress window itself
        /// @dev The ring must reach the SETTLE window, the sum, because the settle read walks the whole of it.
        /// @dev Both sides are this constructor's own arguments, so the record rails its own reach.
        if (_persistenceWindow + _pendingWindow > (_obsCap - 1) * uint256(_obsInterval)) revert BadParams();
        /// @dev The borrow blackout must cover the depth feed's maturity, which matures on a different clock.
        if (_depthWindow > _persistenceWindow) revert BadParams();
    }

    /// @notice Folds a post-swap price into the open bucket; writer-only. Zero volume never moves the price.
    /// @dev It still ROLLS at a boundary though: a slot is spent and the far end of the ring ages out.
    function observe(uint256 price, uint256 volume) external {
        if (msg.sender != WRITER) revert NotWriter();
        uint256 seq = _obsSeq;
        uint256 idx = (seq - 1) % OBS_CAP;
        if (block.timestamp >= uint256(_obs[idx].time) + OBS_INTERVAL) {
            // roll: the closed head's price becomes the new bucket's truncation base
            _bucketBase = _last;
            _sumVol = 0;
            _sumPriceVol = 0;
            idx = seq % OBS_CAP;
            if (_obs.length < OBS_CAP) _obs.push(Obs(uint64(block.timestamp), _last));
            else _obs[idx] = Obs(uint64(block.timestamp), _last);
            _obsSeq = seq + 1;
            // cache the live depth-over-window once per roll; intra-bucket observes reuse it (no re-scan)
            _minDepthAtRoll = _minDepthOverWindow(DEPTH_WINDOW);
        }
        _sumVol += volume;
        _sumPriceVol += price * volume;
        uint256 capped = _sumVol == 0 ? _bucketBase : _truncate(_bucketBase, _sumPriceVol / _sumVol, _sumVol);
        _last = capped;
        _obs[idx].price = capped;
    }

    /// @dev Caps the step base->target at truncCapBps, pro-rated by volume below the live denominator.
    function _truncate(uint256 base, uint256 target, uint256 vol) internal view returns (uint256) {
        uint256 delta = (base * TRUNC_CAP_BPS) / 10000;
        uint256 denom = _denom();
        if (vol < denom) delta = (delta * vol) / denom;
        if (target > base + delta) return base + delta;
        if (target + delta < base) return base - delta; // target < base - delta
        return target;
    }

    /// @dev Full-cap volume denominator: VOL_REF_BPS of cached min-window depth, floored at VOL_REF_FLOOR.
    /// @dev A deeper pool raises it, so the same walk-down needs more volume; the floor covers bootstrap.
    function _denom() internal view returns (uint256) {
        uint256 last = _last;
        uint256 units = last == 0 ? 0 : FullMath.mulDiv(_minDepthAtRoll, UNIT_SCALE, last);
        uint256 depthDenom = (units * VOL_REF_BPS) / 10000;
        return Math.max(depthDenom, VOL_REF_FLOOR);
    }

    /// @notice Records the venue pool's own measured depth (quote units); writer-only, never self-reported.
    /// @dev INSIDE a live bucket the MINIMUM is kept: a pull marks instantly, a spike above it is dropped.
    /// @dev AT A BUCKET BOUNDARY it is not: the new bucket takes `depth` verbatim, so a JIT spike registers.
    /// @dev It stands until a lower observation lands in that same bucket, and the window min still floors it.
    function observeDepth(uint256 depth) external {
        if (msg.sender != WRITER) revert NotWriter();
        uint256 seq = _depthSeq;
        if (seq == 0 || block.timestamp >= uint256(_depthObs[(seq - 1) % OBS_CAP].time) + OBS_INTERVAL) {
            uint256 idx = seq % OBS_CAP;
            if (_depthObs.length < OBS_CAP) _depthObs.push(DepthObs(uint64(block.timestamp), depth));
            else _depthObs[idx] = DepthObs(uint64(block.timestamp), depth);
            _depthSeq = seq + 1;
        } else {
            DepthObs storage h = _depthObs[(seq - 1) % OBS_CAP];
            if (depth < h.depth) h.depth = depth;
        }
    }

    /// @notice The ordered pair this record prices; genesis refuses any other.
    function supportsPair(address quote, address collateral) external view returns (bool) {
        return quote == QUOTE && collateral == COLLATERAL;
    }

    /// @dev A wrong-pair read is a wiring bug, unreachable from a created market -- revert loudly.
    function _requirePair(address quote, address collateral) internal view {
        if (quote != QUOTE || collateral != COLLATERAL) revert WrongPair();
    }

    /// @dev Where a window of `window` seconds starts: that far back from now, floored at zero. Every ring walk asks this.
    function _windowStart(uint256 window) private view returns (uint64) {
        return uint64(Math.saturatingSub(block.timestamp, window));
    }

    /// @dev How many slots of a ring hold an observation: its sequence, capped at the ring's size.
    function _ringLen(uint256 seq) private view returns (uint256) {
        return Math.min(seq, OBS_CAP);
    }

    /// @notice Minimum venue depth observed over the window; 0 if the record does not span it.
    /// @dev NOT an interface member -- ACE never calls it; public so the depth ring stays readable.
    function minDepthOverWindow(uint256 window) external view returns (uint256) {
        return _minDepthOverWindow(window);
    }

    function _minDepthOverWindow(uint256 window) internal view returns (uint256) {
        uint64 boundary = _windowStart(window);
        uint256 lo = type(uint256).max;
        uint256 seq = _depthSeq;
        uint256 n = _ringLen(seq);
        for (uint256 k; k < n; k++) {
            DepthObs storage o = _depthObs[(seq - 1 - k) % OBS_CAP];
            if (o.depth < lo) lo = o.depth; // a branch, not `Math.min`, as in `_minPriceOverWindow`: only a new low pays
            if (o.time <= boundary) return lo; // window-start state included: the record spans
        }
        return 0; // record does not span the window: nothing proven
    }

    /// @notice Minimum price observed over the DISTRESS window; 0 under silence longer than that window.
    /// @notice The staleness horizon IS the window this record was built with: it tolerates no silence longer.
    function minPrice(address quote, address collateral) external view returns (uint256) {
        _requirePair(quote, collateral);
        return _minPriceOverWindow(PERSISTENCE_WINDOW);
    }

    /// @notice The windowed minimum over an ARBITRARY window; NOT an interface member -- ACE never calls it.
    /// @dev Public so the price ring stays readable, exactly as `minDepthOverWindow` keeps the depth ring readable.
    function minPriceOverWindow(address quote, address collateral, uint256 window) external view returns (uint256) {
        _requirePair(quote, collateral);
        return _minPriceOverWindow(window);
    }

    /// @notice The full ring's REACH: head to oldest is `OBS_CAP - 1` gaps, not `OBS_CAP`.
    /// @dev Writes coalesce inside a bucket, so `OBS_INTERVAL` is the tightest gap and this a floor.
    /// @dev The walk needs an observation at or BEFORE the boundary, which is why the gap count is n-1.
    function minGuaranteedSpan() external view returns (uint256) {
        return (OBS_CAP - 1) * OBS_INTERVAL;
    }

    /// @dev The head must sit STRICTLY inside the window, else the walk returns `_last` on step one -- one unprinted price serving as a windowed minimum.
    /// @dev Equality refuses too: at `head.time == boundary` a never-observed ring answers its ctor anchor.
    /// @dev Checked BEFORE the walk, so a silent record costs one read rather than a full ring scan.
    function _minPriceOverWindow(uint256 window) internal view returns (uint256) {
        uint64 boundary = _windowStart(window);
        uint256 seq = _obsSeq;
        if (_obs[(seq - 1) % OBS_CAP].time <= boundary) return 0; // no print inside the window: refuse
        uint256 lo = type(uint256).max;
        uint256 n = _ringLen(seq);
        for (uint256 k; k < n; k++) {
            Obs storage o = _obs[(seq - 1 - k) % OBS_CAP];
            if (o.price < lo) lo = o.price; // a branch, not `Math.min`: few steps of a walk set a new low, and only those pay
            if (o.time <= boundary) return lo;
        }
        return 0;
    }

    /// @notice The last recorded price; silence leaves it standing.
    function lastObserved(address quote, address collateral) external view returns (uint256) {
        _requirePair(quote, collateral);
        return _last;
    }

    /// @notice Zero-arg twin for a writer's per-swap hot path; NOT an interface member.
    function lastObserved() external view returns (uint256) {
        return _last;
    }

    /// @notice Whether the price held strictly below x for the whole DISTRESS window; else false.
    function persistedBelowDistress(address quote, address collateral, uint256 x) external view returns (bool) {
        _requirePair(quote, collateral);
        return _persistedBelow(x, PERSISTENCE_WINDOW);
    }

    /// @notice Whether the price held strictly below x for the whole SETTLE window; else false.
    /// @dev The longer patience, and a strictly harder question than the distress twin: same walk, wider boundary.
    function persistedBelowSettle(address quote, address collateral, uint256 x) external view returns (bool) {
        _requirePair(quote, collateral);
        return _persistedBelow(x, SETTLE_WINDOW);
    }

    /// @notice Below-ness over an ARBITRARY window; NOT an interface member -- ACE asks only its two named questions.
    /// @dev Public so the ring stays inspectable over any span, exactly as `minPriceOverWindow` keeps it readable.
    function persistedBelow(address quote, address collateral, uint256 x, uint256 window) external view returns (bool) {
        _requirePair(quote, collateral);
        return _persistedBelow(x, window);
    }

    /// @notice Above-ness over an ARBITRARY window; NOT an interface member, for the same reason as the below twin.
    function persistedAbove(address quote, address collateral, uint256 x, uint256 window) external view returns (bool) {
        _requirePair(quote, collateral);
        return _persistedAbove(x, window);
    }

    /// @dev SILENCE PERSISTS BELOW-NESS here, the permissive direction, and it is a choice not an oversight.
    /// @dev A record that stops observing keeps answering true from its last print, so quiet reads as distress.
    /// @dev A VENUE-class question: an oracle-class market names a different record, so a fed price never reaches this.
    /// @dev THE WINDOW MEASURES DURATION, NOT GRADUALNESS: a jump below x starts the clock, never evades it.
    /// @dev The walk reads the window-START observation, so settlement needs no separate jump branch.
    function _persistedBelow(uint256 x, uint256 window) internal view returns (bool) {
        if (_last >= x) return false;
        uint64 boundary = _windowStart(window);
        uint256 seq = _obsSeq;
        uint256 n = _ringLen(seq);
        for (uint256 k; k < n; k++) {
            Obs storage o = _obs[(seq - 1 - k) % OBS_CAP];
            if (o.time <= boundary) return o.price < x; // state at window-start (silence persists)
            if (o.price >= x) return false; // an in-window bucket broke below-ness
        }
        return false; // record does not span the full window
    }

    /// @notice Whether the price held strictly above x for the whole DISTRESS window; mirror of the below twin.
    /// @dev NOT an interface member -- no hub verb asks the recovery question, only a view does.
    function persistedAbove(address quote, address collateral, uint256 x) external view returns (bool) {
        _requirePair(quote, collateral);
        return _persistedAbove(x, PERSISTENCE_WINDOW);
    }

    function _persistedAbove(uint256 x, uint256 window) internal view returns (bool) {
        if (_last <= x) return false;
        uint64 boundary = _windowStart(window);
        uint256 seq = _obsSeq;
        uint256 n = _ringLen(seq);
        for (uint256 k; k < n; k++) {
            Obs storage o = _obs[(seq - 1 - k) % OBS_CAP];
            if (o.time <= boundary) return o.price > x;
            if (o.price <= x) return false;
        }
        return false;
    }
}
