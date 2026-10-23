// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.36;

import {Math} from "@openzeppelin/contracts/utils/math/Math.sol";
import {Market, MarketParams} from "./Types.sol";
import {Constants} from "./Constants.sol";
import {LoanMath} from "./libraries/LoanMath.sol";
import {Borrower} from "./Borrower.sol";
import {IERC20Decimals} from "../../interfaces/IERC20Decimals.sol";
import {IPriceFrame} from "../../interfaces/IPriceFrame.sol";
import {IPersistenceRecord} from "../../interfaces/IPersistenceRecord.sol";

error MarketExists(); // a live quote at this id: genesis runs once per market, ever

/// @title MarketInit
/// @notice Market genesis: every bound a new market must clear, enforced once and never re-checked.
/// @dev NOT part of the by-flow partition; linked out only because a singleton makes these RUNTIME code.
/// @dev The rails this enforces are declared in `Constants`, which holds the whole immutable surface.
library MarketInit {
    uint256 private constant UNIT_SCALE = 1 << 96; // the price frame, one in every market: the ticket rail, the record check and the state write

    /// @notice A keeper-latency budget: `min(2 hours, tenor / 5)`, used on BOTH sides of expiry.
    /// @notice Before expiry it is how early an armed policy may be executed; after it, how long the roll keeps priority.
    /// @dev DERIVED so a minute-scale market is creatable at all; a fixed 2h made one uncreatable.
    /// @dev Under the tenor by construction, so its ceiling needs no rail; its floor is genesis's `MIN_TENOR_FLOOR`, which keeps it off zero.
    /// @dev The caller chooses the argument: the market floor for admission, the LOAN'S own tenor for its roll window.
    function autoRefinanceWindow(uint64 minTenor) internal pure returns (uint64) {
        uint64 w = minTenor / Constants.AUTO_REFINANCE_WINDOW_DIVISOR;
        return uint64(Math.min(w, Constants.AUTO_REFINANCE_WINDOW));
    }

    /// @notice The roll window's TRAILING share, counted back from expiry, in which a stranger's market may also fund the roll.
    /// @notice The `window - hold` before it is the incumbent lender's alone: their span to keep the loan before a stranger routes it.
    /// @dev DERIVED, never independent: at a divisor of 2 the incumbent's span is never the shorter; a whole-window hold leaves them none.
    /// @dev At or above genesis's `MIN_TENOR_FLOOR` the hold is at least a second, so a stranger may still route before expiry.
    function homeRollHold(uint64 minTenor) internal pure returns (uint64) {
        return autoRefinanceWindow(minTenor) / Constants.AUTO_ROLL_HOME_SHARE_DIVISOR;
    }

    /// @notice How long settled inventory rests before its ask opens: `min(1 hours, minTenor / 2)`.
    /// @notice It is the lender's window to take their own goods in kind before a stranger may buy them.
    /// @notice ITS SECOND JOB, where a record floors the ask: the read that settles a loan is never the read that prices its pot.
    /// @notice READ ONLY WHERE THE MARKET HAS THE ASK: without one no stranger ever buys, so there is nothing to hold back.
    /// @dev Without the hold a wrong-low read would settle a loan and sell its pot at the market's price in one transaction, the gap to the buyer.
    /// @dev DERIVED so a minute-scale market opens its ask inside its own term rather than after it.
    /// @dev Under minTenor by construction, so its ceiling needs no rail; its floor is genesis's `MIN_TENOR_FLOOR`, which keeps it off zero.
    function inventoryHold(uint64 minTenor) internal pure returns (uint64) {
        uint64 w = minTenor / Constants.INVENTORY_HOLD_DIVISOR;
        return uint64(Math.min(w, Constants.INVENTORY_HOLD));
    }

    /// @dev A price source must AFFIRM this market's ordered pair; refusing to answer is not an exemption.
    /// @dev A source that reverts here bricks only the market naming it -- do not soften this with try/catch.
    function _requireFrame(address src, address quote, address collateral, string memory err) private view {
        require(IPriceFrame(src).supportsPair(quote, collateral), err);
    }

    /// @dev The four `IPersistenceRecord` reads beyond orientation, each CALLED once at a fixed probe and DISCARDED.
    /// @dev What is proved is that each read ANSWERS: stronger than an ERC-165 declaration, weaker than a behavioural proof.
    /// @dev `supportsPair` alone admits a contract implementing nothing else, and settlement would then revert forever.
    /// @dev A zero or a false is the legitimate cold answer, so answering IS the test: creation never depends on feed uptime.
    /// @dev Unscoped by the band: the interface IS these four reads, and `AceLens.inDistress` decodes distress raw on any recorded market.
    /// @dev Its own frame, so the four return decodes do not sit on the genesis function's stack.
    function _requireAnswers(address record, address quote, address collateral) private view {
        IPersistenceRecord(record).minPrice(quote, collateral);
        IPersistenceRecord(record).persistedBelowDistress(quote, collateral, 0);
        IPersistenceRecord(record).persistedBelowSettle(quote, collateral, 0);
        IPersistenceRecord(record).lastObserved(quote, collateral);
    }

    /// @notice Validate one market's config and write it. Reverts MarketExists on a duplicate id.
    /// @notice `unitScale` is the SAME constant in every market, so no price site ever branches on decimals.
    /// @notice It also INTERVIEWS creator-chosen contracts: both tokens and the record.
    /// @dev Every write is a pure function of `p`, so a reentrant `createMarket` on this id is idempotent.
    /// @dev That is what makes the creator-chosen staticcalls below safe without a guard.
    function init(Market storage M, MarketParams calldata p) public {
        if (M.p.quote != address(0)) revert MarketExists();

        require(p.quote != address(0) && p.collateral != address(0), "tokens required");
        /// @dev Sole tenancy is LEGISLATED, not offered: a market with no named lender has no owner for its cash.
        /// @dev Every per-market ledger assumes this one owner: an optional lender would need a pooling path this tree does not have.
        require(p.lender != address(0), "lender required");
        require(p.collateral != p.quote, "collateral is quote");
        /// @dev ZERO IS REFUSED: every price consumer divides by it and it is write-once, so the market could never draw, settle or price a pot.
        require(p.price > 0, "price zero");
        /// @dev The CEILING is what every overflow argument in this tree was written against; see `Constants.MAX_PRICE`.
        require(p.price <= Constants.MAX_PRICE, "price over ceiling");
        require(p.fillFeeBps <= Constants.MAX_FILL_FEE_BPS, "fill fee too high");
        /// @dev a declared-but-unread field on an immutable preimage is a lie: with the ask off no buyer exists to pay a fill fee
        require(p.inventoryAsk || p.fillFeeBps == 0, "ask off but fill fee set");
        require(p.minCoverageWad >= Constants.MIN_COVERAGE_WAD && p.minCoverageWad <= Constants.MAX_COVERAGE_WAD, "min coverage out of band");
        /// @dev THE CEILING IS REPRESENTATIONAL, NOT POLICY: `feeFundable` below binds at 2272, under this 2500 at every shape.
        /// @dev Without it an unbounded `baseBps` reaches `feeFundable`'s multiply first and reverts Panic instead of by name.
        require(p.baseBps >= Constants.MIN_BASE_BPS && p.baseBps <= Constants.MAX_FEE_SHARE_BPS, "base bps out of band");
        /// @dev The floor is DERIVED from the window divisors: at it no tenor-derived window or hold is zero.
        /// @dev MUST precede the two fee rails below: at `minTenor == 0` one misnames the refusal and the other divides by it.
        require(p.minTenor >= Constants.MIN_TENOR_FLOOR, "min tenor under floor");
        require(p.maxTenor >= p.minTenor, "max tenor below min");
        require(p.maxTenor <= type(uint40).max, "max tenor too long"); // a sanity bound on a write-once term
        /// @dev the all-in fee stays inside `MAX_FEE_SHARE_BPS` of the draw at every term the market offers
        require(LoanMath.feeFundable(p.baseBps, p.maxTenor, p.minTenor), "fee bps too high");
        /// @dev A TERM IS ADMISSIBLE IFF IT LIES IN `[minTenor, maxTenor]`: nothing quantises a tenor, so a borrower picks any in that range.
        require(p.minDebt > 0, "min debt zero"); // it floors BOTH doors, and a zero floor admits dust at each
        /// @dev The SHARE rail above bounds a fraction and cannot bound one wei, because the fee CEILS; so this checks the hardest ends.
        /// @dev Those are maxTenor and minDebt: the fee is monotone in tenor, and `ceil(P r) < P` binds at the smallest P.
        /// @dev MUST stay below `min debt zero`: at zero the fee is zero too, so `0 < 0` would fail here and shadow it
        require(LoanMath.originationFee(p.minDebt, p.maxTenor, p.baseBps, p.minTenor) < p.minDebt, "min debt under fee");
        /// @dev THE DEPOSIT FLOOR IS `minDebt` ITSELF, so its smallest legal deposit must fit the cash cap or no deposit could ever book.
        require(p.minDebt <= type(uint128).max, "min debt over cash cap");
        /// @dev THE MINIMUM TICKET MUST OPEN: its coverage line at the price must fit the widest lot an open admits, `max / 1e18`.
        /// @dev EXACT, on the open door's own arithmetic: at the line the trigger sits at or under the price, so that lot opens.
        /// @dev MUST follow the coverage band and `min debt over cash cap`: they bound `minCoverageWad * minDebt`, which otherwise panics.
        require(Borrower.coverageLine(p.minCoverageWad, UNIT_SCALE, p.minDebt, p.price) <= type(uint256).max / 1e18, "min ticket unopenable");
        require(p.settleBountyBps <= Constants.MAX_SETTLE_BOUNTY_BPS, "settle bps too high");
        /// @dev eps is immutable, so a mis-set value is permanent: a sold unit melts (1-eps) of the record floor, less the cut on a restoring crank
        /// @dev unconditional, above both band arms, though band-off eps must be zero: an over-ceiling eps is refused by this name either way
        require(p.deleverageFloorEpsBps <= Constants.MAX_DELEVERAGE_FLOOR_EPS_BPS, "deleverage eps too high");
        /// @dev these rails are the DECLINE channel's, and its sizing must divide
        if (p.deleverageBandBps != 0) {
            /// @dev the band is a MARGIN over the trigger, so the floor bounds how late the channel may open
            /// @dev too narrow and a fast decline crosses the whole corridor between prints, into the dead zone below the stop
            /// @dev the ceiling is arithmetic: at 10000 `bandLevel`'s divisor is zero and every crank reverts
            require(p.deleverageBandBps >= Constants.MIN_DELEVERAGE_BAND_BPS && p.deleverageBandBps < 10000, "deleverage band out of band");
            require(p.deleverageTargetBps > p.deleverageBandBps, "deleverage target below band"); // hysteresis
            require(p.deleverageTargetBps < 10000, "deleverage target too high");
            /// @dev the stop floor: a real positive margin strictly below the fire band
            /// @dev below it settlement owns the loan -- a trade must not do liquidation's job
            uint256 stop = p.deleverageStopBps;
            require(stop > 0 && stop < p.deleverageBandBps, "deleverage stop out of band");
            require(p.deleverageProtocolBps <= Constants.MAX_DELEVERAGE_PROTOCOL_BPS, "deleverage cut too high");
            /// @dev the closed form's real-arithmetic feasibility: `k m (1-cut) + t > 1e18`, k = minCoverageWad
            /// @dev REDUNDANT given the sell-max rail below and `target > band > stop`, and kept for the sharper message it puts first
            /// @dev the truncating divisions err LOW, rejecting marginal configs -- the safe direction
            require(
                (p.minCoverageWad * (10000 - p.deleverageFloorEpsBps) / 10000) * (10000 - p.deleverageProtocolBps) / 10000 + p.deleverageTargetBps * 1e14
                    > 1e18,
                "deleverage denominator"
            );
            /// @dev sell-max bound: `k m (1-cut) + stop > 1e18`, one of the four facts holding the runtime sizing denominator positive
            /// @dev it buys `u <= C`, NOT `u < C`: at one wei of rail slack the lowest admitted price SIZES u == C
            /// @dev benign: that crank re-sizes to the cut-free restore under its caps, takes no cut, and every wei of proceeds melts debt
            /// @dev trivial at k=1.4; the `u == C` window widens as this rail's slack narrows, and at generic slack it is dust prices
            /// @dev SECOND JOB: every admitted crank melts debt faster than it spends collateral, so cranking cannot walk a loan into the stop.
            /// @dev LOOSENING the stop reopens that band.
            require(
                p.deleverageStopBps * 1e14 + (p.minCoverageWad * (10000 - p.deleverageFloorEpsBps) / 10000) * (10000 - p.deleverageProtocolBps) / 10000 > 1e18,
                "stop below sellmax onset"
            );
            require(p.record != address(0), "record required");
            require(p.deleverageFloorEpsBps > 0, "deleverage eps zero"); // the decline keeper is paid in eps
            /// @dev NO fill-fee rail here: a settled pot's buyer pays `fillFeeBps` where the market has the ask, and no deleverage crank reads it.
        } else {
            /// @dev declared-but-unread fields on an immutable preimage are a lie: with the band off no verb acts on the other four
            require(
                p.deleverageStopBps == 0 && p.deleverageProtocolBps == 0 && p.deleverageTargetBps == 0 && p.deleverageFloorEpsBps == 0,
                "deleverage off but dials set"
            );
        }
        uint8 cd = IERC20Decimals(p.collateral).decimals();
        uint8 qd = IERC20Decimals(p.quote).decimals();
        /// @dev absolute rather than relative, so a garbage decimals() is refused by name on either side
        /// @dev ONE bound covers BOTH directions: with each end at or under 18 the widest gap either way IS 18.
        /// @dev IT BOUNDS WHERE PAR SITS IN THE Q96 FRAME: par is `2^96 * 10^qd / 10^cd`, and an 18-decimal gap either way stays inside the price rails.
        /// @dev The reads have a SECOND job: they are the only proof either token has code, since the checks above take addresses alone.
        require(cd <= Constants.MAX_DECIMALS && qd <= Constants.MAX_DECIMALS, "decimals out of band");
        /// @dev every rail the record answers for, under one guard: a recordless market is a supported shape and skips them all
        if (p.record != address(0)) {
            /// @dev Every price source is DIRECTIONAL (quote-per-collateral), so bind each to this market's own pair.
            /// @dev Without this an inverse market can name a record whose frame reads every value upside down.
            /// @dev `cd >= qd` catches only the decimal-mismatched half, and only as a representability side effect.
            _requireFrame(p.record, p.quote, p.collateral, "record orientation");
            /// @dev NO WINDOW RAILS HERE: the record owns both windows, so it checks them in its own constructor.
            /// @dev NO AGE RAIL EITHER, deliberately: the record refuses a window it has not printed inside.
            /// @dev So a cold record admits creation and then refuses every draw until it genuinely prints.
            _requireAnswers(p.record, p.quote, p.collateral);
            /// @dev A record that DECLARES a unit scale must declare THIS market's; absent is not a refusal.
            /// @dev Probed, never an interface member: the ORACLE classes carry no unit scale and would brick.
            /// @dev What it CATCHES is a record built against a different frame constant: a stale one, or a third party's.
            /// @dev The in-repo record declares the same constant, so it passes by construction and this door is for the others.
            /// @dev `||` short-circuits, so a short return is never decoded.
            (bool okScale, bytes memory scaleRet) = p.record.staticcall(abi.encodeWithSignature("UNIT_SCALE()"));
            require(!okScale || scaleRet.length < 32 || abi.decode(scaleRet, (uint256)) == UNIT_SCALE, "record unit scale");
        }

        M.p = p;
        M.s.unitScale = UNIT_SCALE;
        M.s.lastSweptAt = uint64(block.timestamp); // a fresh market's first keeper crank cannot piggyback a sweep
    }
}
