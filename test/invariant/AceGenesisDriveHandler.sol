// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.36;

import {Ace} from "../../src/ace/hub/Ace.sol";
import {AceLens} from "../../src/ace/lens/AceLens.sol";
import {Constants} from "../../src/ace/hub/Constants.sol";
import {Loan, MarketParams, OpenBounds} from "../../src/ace/hub/Types.sol";
import {PositionManager} from "../../src/ace/positions/PositionManager.sol";
import {MockERC20} from "../mocks/MockERC20.sol";
import {MockPersistenceRecord} from "../mocks/MockPersistenceRecord.sol";
import {AceFixtures} from "../utils/AceFixtures.sol";
import {ProtocolPolicy} from "../../src/config/Defaults.sol";
import {AceReader} from "../utils/AceReader.sol";
import {PriceFrame} from "../utils/PriceFrame.sol";
import {WarpClock} from "../utils/WarpClock.sol";

/// @title AceGenesisDriveHandler
/// @notice Every market here is CREATED BY THE FUZZER and then DRIVEN, on params nobody wrote by hand.
/// @notice `AceHandler` builds four markets in its constructor, so its campaign only ever drives our own config.
/// @dev The registry is DYNAMIC, which is the whole reason this is a second handler rather than a fifth slot.
/// @dev Its sibling is fixed-size throughout, and a rarely-picked fifth market makes its drive guard flaky.
/// @dev The hub is deployed with NO market: a sequence that never creates one drives nothing, by construction.
/// @dev THE TOKEN POOLS ARE SHARED across markets so the per-token solvency identity keeps its teeth.
/// @dev A fresh token per market would make every identity single-market and blind to a denomination mix.
/// @dev Decimals span 2/6/18 quote against 0/8/18 collateral: the regimes the fixture-pinned suite cannot reach.
/// @dev THE FUZZED PRICE IS THE SUCCESSOR TO THE FUZZED SPACING: a market names one price, so a spread of
/// @dev prices is a spread of MARKETS, and `PRICE_OFFSETS` is the menu genesis stands them up at.
/// @dev SOLE TENANCY: each market names ONE of the three lenders, round-robin, so a lender runs several.
/// @dev That pairing is the point -- `LenderPools` is keyed (lender, quote), so one lender's two markets pool.
/// @dev Every action is bounded and try/catch-guarded (fail_on_revert = false), like its siblings.
contract AceGenesisDriveHandler is WarpClock {
    uint256 internal constant MAX_MARKETS = 6; // the O(markets x loans) invariants bound on it
    uint256 internal constant MAX_LOANS = 8;
    uint256 internal constant SEED_UNITS = 15_000; // whole quote tokens rested at genesis, in the market's own scale
    uint256 internal constant BAND_BPS = 3000; // the deleverage channel's margin, fixed so the dials that vary are visible
    uint256 internal constant REF_PRICE_WAD = 2e18; // a HUMAN price, framed per pair: above every price on the menu

    /// @dev The prices genesis may stand a market up at, as offsets from the pair's par.
    /// @dev BOUNDED WELL UNDER `REF_PRICE_WAD`: the record's windowed min is the draw cap, and a market
    /// @dev priced above its own cap takes no deposit at all, so the whole menu would refuse rather than vary.
    int24[6] internal PRICE_OFFSETS = [int24(-1080), -540, 0, 480, 960, 1380];

    /// @dev The per-market handles a driven verb needs; the lender is held because every lender-gated door asks.
    struct Mkt {
        bytes32 id;
        uint8 qi;
        uint8 ci;
        uint8 li;
        MockPersistenceRecord record;
    }

    Ace public ace;
    PositionManager public positionManager;
    AceReader public read;
    AceLens public lens;

    MockERC20[3] public quoteTokens;
    MockERC20[3] public collTokens;
    /// @notice The decimals of each pool, HELD rather than read back through `decimals()`.
    /// @dev This handler deploys the tokens, so their scale is a fact it already has.
    /// @dev `decimals()` is untrusted metadata, mutable after genesis, and nothing here needs to ask.
    /// @dev It is also the single source the tokens are CONSTRUCTED from, so the two cannot drift.
    uint8[3] internal QDEC = [6, 18, 2];
    uint8[3] internal CDEC = [18, 8, 0];

    /// @dev Each created market names ONE of these; markets round-robin, so every lender runs two of six.
    address[3] public lenders = [AceFixtures.LENDER, address(0xA11CF), address(0xA11D0)];
    address[2] public borrowers = [address(0xB0B), address(0xB0C)];
    address public keeper = address(0xC0FFEE);
    address public canaryLender = address(0xCA9A47); // distinct from every fuzzed actor, so no verb can reach its lots

    bytes32 public canaryId; // a market OUTSIDE `_mkts`: no action here ever names it
    address public canaryQuote; // its quote pool, which the per-token identity must still account for
    uint256 public canarySeededCash; // what it was seeded with, so a leak OUT of it is visible too

    Mkt[] internal _mkts;
    uint256[] internal _loanIds;
    mapping(uint256 => bool) internal _knownLoan;
    mapping(bytes32 => uint256) public calls;

    uint256 public genesisAttempted; // createMarket actions that reached the hub
    uint256 public genesisCreated; // ones the rails admitted
    uint256 public genesisRefused; // ones a rail turned away: the frontier, and a counted result
    uint256 public genesisCappedOut; // ones skipped because the registry was full, so the tally cannot read as a refusal
    bool public genesisIdNotItsParams; // an id stopped re-hashing to the params it resolves to
    uint256 public loansOpened;
    uint256 public settlements;
    uint256 public depositsLanded;
    uint256 public depositsRefused;
    bytes4 public depositRefusalSelector; // the FIRST refusal, seeding or driven, so no refused deposit is anonymous
    uint256 public opensRefused;
    uint256 public opensSkippedAtCap; // draws never attempted because the loan registry was full, so the tally is not a refusal
    bytes4 public openRefusalSelector; // the FIRST refusal; a suite that never draws must say what stopped it
    uint256 public repaysLanded;
    uint256 public creditsPulled; // claimOwed calls that actually delivered units or quote, never the bare hit count
    uint256 public quoteClaimed; // quote pulled through collect: the one verb HERE that debits a lender's pooled credit
    uint256 public unitsRedeemed; // units taken in kind: the ONLY driver of `netSyntheticOutflow` this suite reaches
    uint256 public strangerDepositsRefused; // deposits by a non-tenant the sole-tenancy gate turned away
    bool public strangerRested; // a non-tenant's cash landed in a market it does not own: sole tenancy, falsified
    mapping(uint256 => bool) internal _drewInMarket; // per registry index: the params reached a DRAW, not just genesis
    uint256 public marketsThatDrew;

    constructor() {
        _warpTo(1_000_000);
        for (uint256 i; i < 3; i++) {
            quoteTokens[i] = new MockERC20("Quote", "Q", QDEC[i]);
            collTokens[i] = new MockERC20("Collateral", "C", CDEC[i]);
        }
        (ace, positionManager) = AceFixtures.newAceWithEscrow(AceFixtures.TREASURY);
        read = new AceReader(address(ace));
        lens = new AceLens(address(ace));
        _buildCanary();
    }

    /// @notice The passive isolation witness: a market no action here ever addresses.
    /// @notice It sits OUTSIDE `_mkts`, so `marketCount()` is still zero and every verb still bootstraps its own.
    /// @dev SEEDED on purpose: an empty canary only witnesses a leak INTO it, and cash makes an outbound one visible.
    /// @dev Its lender is outside the fuzzed actor set, so no driven verb can address its lots either.
    /// @dev Its params are the fixture baseline, and a fuzzed set can never collide: the record is fresh per call.
    function _buildCanary() internal {
        MockERC20 q = quoteTokens[0];
        MockERC20 c = collTokens[0];
        MockPersistenceRecord rec = new MockPersistenceRecord(address(q), address(c));
        MarketParams memory p = AceFixtures.marketParams(address(q), address(c));
        p.record = address(rec);
        p.lender = canaryLender; // ITS OWN TENANT: no driven verb can rest or withdraw here, whatever it seeds
        canaryId = ace.createMarket(p);
        canaryQuote = address(q);
        rec.setAbove(true);
        rec.setMinPrice(AceFixtures.px(REF_PRICE_WAD, address(q), address(c)));
        uint256 amt = 9_000 * quoteUnit(0);
        q.mint(canaryLender, amt);
        vm.startPrank(canaryLender);
        q.approve(address(ace), amt);
        ace.deposit(canaryId, amt);
        vm.stopPrank();
        canarySeededCash = read.restingOf(canaryId);
        require(canarySeededCash == amt, "CANARY: the seed did not land, so the witness is empty");
    }

    // ---- reads the invariant suite needs ----

    function marketCount() external view returns (uint256) {
        return _mkts.length;
    }

    /// @notice The registry cap, so a caller states the real search bound instead of hardcoding it.
    function maxMarkets() external pure returns (uint256) {
        return MAX_MARKETS;
    }

    function marketAt(uint256 i) external view returns (bytes32) {
        return _mkts[i].id;
    }

    /// @notice The quote token of the i-th created market; the per-token identity partitions on exactly this.
    function quoteOf(uint256 i) external view returns (address) {
        return address(quoteTokens[_mkts[i].qi]);
    }

    function collOf(uint256 i) external view returns (address) {
        return address(collTokens[_mkts[i].ci]);
    }

    /// @notice The named lender of the i-th created market: the only party that may rest or withdraw there.
    /// @dev THE SUCCESSOR TO `tickAt`/`tickCount`, which named a rung of a ladder that no longer exists.
    /// @dev A caller that walked the rungs of one market now walks the MARKETS, and each names its own tenant.
    function lenderAt(uint256 i) external view returns (address) {
        return lenders[_mkts[i].li];
    }

    /// @notice The price the i-th market was created at, in the hub's frame.
    function priceAt(uint256 i) external view returns (uint256) {
        return ace.idToMarketParams(_mkts[i].id).price;
    }

    function loanIds() external view returns (uint256[] memory) {
        return _loanIds;
    }

    function callCount(string memory tag) external view returns (uint256) {
        return calls[keccak256(bytes(tag))];
    }

    /// @notice One whole token of the i-th quote pool, from the held scale rather than a `decimals()` read.
    function quoteUnit(uint256 i) public view returns (uint256) {
        return 10 ** uint256(QDEC[i]);
    }

    /// @notice One whole token of the i-th collateral pool.
    function collUnit(uint256 i) public view returns (uint256) {
        return 10 ** uint256(CDEC[i]);
    }

    /// @notice The held scale of a created market's quote and collateral; for reporting, never for sizing.
    function scalesAt(uint256 i) external view returns (uint256 qdec, uint256 cdec) {
        return (uint256(QDEC[_mkts[i].qi]), uint256(CDEC[_mkts[i].ci]));
    }

    function _bump(string memory tag) internal {
        calls[keccak256(bytes(tag))]++;
    }

    /// @dev End-of-action tail: the per-market draw witness, which no per-step invariant can recompute.
    function _tail() internal {
        for (uint256 i; i < _mkts.length; i++) {
            if (_drewInMarket[i]) continue;
            if (ace.marketLoansLength(_mkts[i].id) == 0) continue;
            _drewInMarket[i] = true;
            marketsThatDrew++;
        }
    }

    // ---- genesis: the only source of markets in this campaign ----

    /// @notice Create a market on FUZZED params, then seed it so the same sequence can draw against them.
    /// @notice Seeding is part of genesis on purpose: an unfunded market is a config that never reaches a draw.
    /// @dev A refusal is a RESULT, not a failure -- the rails are a frontier and finding it is half the point.
    /// @dev The dials left fixed are the ones whose variation only produces refusals: the tenor grid and the band.
    /// @dev `minCoverageWad`, `baseBps`, `minDebt`, the price, the bounty and the deleverage cut all vary.
    /// @dev `minDebt` reaches ONE ATOM and the price reaches both ends of the menu: the degenerate NEIGHBOURHOODS.
    function createMarket(uint256 seed) external {
        _bump("createMarket");
        _createFrom(seed);
        _tail();
    }

    /// @dev THE BOOTSTRAP, called by every action: until a market exists, every other verb is a no-op.
    /// @dev Without it the campaign spends its depth on inert calls and the walk never reaches a draw.
    /// @dev The market is still the FUZZER'S -- the seed is the caller's own, so no params here are ours.
    function _ensureMarket(uint256 seed) internal {
        if (_mkts.length == 0) _createFrom(seed);
    }

    function _createFrom(uint256 seed) internal {
        if (_mkts.length >= MAX_MARKETS) {
            genesisCappedOut++;
            return;
        }
        uint8 qi = uint8(seed % 3);
        uint8 ci = uint8((seed >> 8) % 3);
        uint8 li = uint8(_mkts.length % 3); // ROUND-ROBIN, not seeded: a fuzzed index can starve a lender to nothing
        MockERC20 q = quoteTokens[qi];
        MockERC20 c = collTokens[ci];
        MockPersistenceRecord rec = new MockPersistenceRecord(address(q), address(c));
        MarketParams memory p = _fuzzParams(seed, qi, ci, li, rec);
        genesisAttempted++;
        try ace.createMarket(p) returns (bytes32 id) {
            genesisCreated++;
            if (keccak256(abi.encode(p)) != id) genesisIdNotItsParams = true;
            if (keccak256(abi.encode(ace.idToMarketParams(id))) != id) genesisIdNotItsParams = true;
            rec.setAbove(true);
            rec.setMinPrice(AceFixtures.px(REF_PRICE_WAD, address(q), address(c)));
            _mkts.push(Mkt(id, qi, ci, li, rec));
            _seedMarket(_mkts.length - 1);
        } catch {
            genesisRefused++;
        }
    }

    /// @dev The fixture baseline with the dials the issue named swept across their rails and past them.
    /// @dev `minDebt` sweeps from ONE ATOM so the sweep reaches the fee-ceiling floor and is refused there.
    /// @dev Scale comes from the HELD decimals, so a 2-dec market is not a thousandth of an 18-dec one.
    /// @dev THE PRICE IS A DIAL NOW, taking the place of the spacing the grid used to fuzz.
    /// @dev The lender is a dial too, and it is in the id preimage, so two markets differing only by it fork.
    /// @dev `baseBps` sweeps to the REPRESENTATIONAL ceiling, past the rail that actually decides: the fixture is a
    /// @dev flat 7d/7d market, where `feeFundable` binds at 2272, so the top tenth of the sweep is refused by name.
    function _fuzzParams(uint256 seed, uint8 qi, uint8 ci, uint8 li, MockPersistenceRecord rec) internal view returns (MarketParams memory p) {
        p = AceFixtures.marketParams(address(quoteTokens[qi]), address(collTokens[ci]));
        p.record = address(rec);
        p.lender = lenders[li];
        p.price = PriceFrame.priceAt(address(quoteTokens[qi]), address(collTokens[ci]), PRICE_OFFSETS[(seed >> 16) % 6]);
        p.minCoverageWad = bound(seed >> 24, 1.05e18, 20e18);
        p.baseBps = bound(seed >> 32, 1, Constants.MAX_FEE_SHARE_BPS);
        p.minDebt = bound(seed >> 40, 1, 50 * quoteUnit(qi));
        p.settleBountyBps = bound(seed >> 72, 0, 200);
        p.deleverageFloorEpsBps = ProtocolPolicy.DELEVERAGE_FLOOR_EPS_BPS;
        p.deleverageBandBps = BAND_BPS;
        p.deleverageTargetBps = 4000;
        p.deleverageStopBps = 1;
        p.deleverageProtocolBps = bound(seed >> 80, 0, 2000);
    }

    /// @dev Resting cash from the market's OWN named lender, in its OWN quote, at its OWN scale.
    /// @dev Without it a fuzz-created market is admitted and then never funds anything, which proves nothing.
    /// @dev THE THREE-LENDER LADDER WALK IS DELETED RATHER THAN RE-POINTED: a market takes cash from one
    /// @dev party only, so two of its three legs would now be refused and the depth would land a third short.
    function _seedMarket(uint256 mi) internal {
        Mkt memory k = _mkts[mi];
        MockERC20 q = quoteTokens[k.qi];
        uint256 amt = SEED_UNITS * quoteUnit(k.qi);
        address who = lenders[k.li];
        q.mint(who, amt);
        vm.startPrank(who);
        q.approve(address(ace), amt);
        try ace.deposit(k.id, amt) {
            depositsLanded++;
        } catch (bytes memory err) {
            depositsRefused++;
            if (depositRefusalSelector == bytes4(0)) depositRefusalSelector = _sel(err);
        }
        vm.stopPrank();
    }

    // ---- lender actions ----

    /// @notice Rest cash. Mostly the market's own tenant, and on a quarter of the seeds a stranger it must refuse.
    /// @dev The stranger draw is what keeps `GateRefused` lit: with the tenant alone the door is never asked.
    function deposit(uint256 mSeed, uint256 aSeed, uint256 amtSeed) external {
        _bump("deposit");
        _ensureMarket(mSeed);
        if (_mkts.length == 0) return;
        Mkt memory k = _mkts[mSeed % _mkts.length];
        MockERC20 q = quoteTokens[k.qi];
        address tenant = lenders[k.li];
        address who = aSeed % 4 == 0 ? lenders[(k.li + 1) % lenders.length] : tenant;
        uint256 amt = bound(amtSeed, 1, 20_000) * quoteUnit(k.qi);
        q.mint(who, amt);
        vm.startPrank(who);
        q.approve(address(ace), amt);
        uint256 had = read.restingOf(k.id);
        try ace.deposit(k.id, amt) {
            depositsLanded++;
            if (who != tenant && read.restingOf(k.id) > had) strangerRested = true;
        } catch (bytes memory err) {
            /// @dev A STRANGER'S REFUSAL IS ITS OWN TALLY, deliberately: it is the expected outcome, and
            /// @dev folding it in would latch `GateRefused` into the selector that exists to name the
            /// @dev genesis frontier -- the one refusal a campaign that never funds anything has to report.
            if (who != tenant) {
                strangerDepositsRefused++;
            } else {
                depositsRefused++;
                if (depositRefusalSelector == bytes4(0)) depositRefusalSelector = _sel(err);
            }
        }
        vm.stopPrank();
        _tail();
    }

    /// @notice Take a market's resting cash back out; the caller is its tenant, who is the only party that may.
    /// @dev THE LOT WALK IS DELETED RATHER THAN RE-POINTED: a market holds one number, so there is no lot
    /// @dev index to pick and no per-tick count to gate on. Resting-or-nothing is the whole precondition.
    function withdraw(uint256 mSeed, uint256 amtSeed) external {
        _bump("withdraw");
        _ensureMarket(mSeed);
        if (_mkts.length == 0) return;
        Mkt memory k = _mkts[mSeed % _mkts.length];
        if (read.restingOf(k.id) == 0) return;
        uint256 amt = amtSeed % 2 == 0 ? type(uint256).max : bound(amtSeed, 1, read.restingOf(k.id));
        vm.prank(lenders[k.li]);
        try ace.withdraw(k.id, amt, lenders[k.li], 0) {} catch {}
        _tail();
    }

    // ---- borrower actions ----

    /// @dev Collateral and principal both scale by their token's decimals, so the LTV a draw asks for is
    /// @dev the same economic ratio in every market and a refusal means the params, never the units.
    function open(uint256 mSeed, uint256 bSeed, uint256 drawSeed) external {
        _bump("open");
        _ensureMarket(mSeed);
        if (_mkts.length == 0) return;
        /// @dev COUNTED, so a campaign that saturated the book is distinguishable from one whose draws were refused.
        if (_loanIds.length >= MAX_LOANS) {
            opensSkippedAtCap++;
            return;
        }
        Mkt memory k = _mkts[mSeed % _mkts.length];
        MockERC20 q = quoteTokens[k.qi];
        MockERC20 c = collTokens[k.ci];
        address who = borrowers[bSeed % borrowers.length];
        uint256 coll = 40_000 * collUnit(k.ci);
        uint256 principal = bound(drawSeed, 50, 12_000) * quoteUnit(k.qi);
        c.mint(who, coll);
        q.mint(who, principal);
        vm.startPrank(who);
        c.approve(address(positionManager), coll);
        q.approve(address(ace), principal);
        try ace.open(k.id, coll, principal, 0, who, OpenBounds(0, 0, 0)) returns (uint256 loanId) {
            if (!_knownLoan[loanId]) {
                _knownLoan[loanId] = true;
                _loanIds.push(loanId);
                loansOpened++;
            }
        } catch (bytes memory err) {
            opensRefused++;
            if (openRefusalSelector == bytes4(0)) openRefusalSelector = _sel(err);
        }
        vm.stopPrank();
        _tail();
    }

    function repay(uint256 loanSeed, uint256 amtSeed) external {
        _bump("repay");
        _ensureMarket(loanSeed);
        if (_loanIds.length == 0) return;
        uint256 loanId = _loanIds[loanSeed % _loanIds.length];
        Loan memory l = read.loan(loanId);
        if (l.debt == 0) return;
        uint256 amt = bound(amtSeed, 1, l.debt);
        MockERC20 q = MockERC20(_quoteOfLoan(loanId));
        q.mint(l.borrower, amt);
        vm.startPrank(l.borrower);
        q.approve(address(ace), amt);
        try ace.repay(loanId, amt) {
            repaysLanded++;
        } catch {}
        vm.stopPrank();
        _tail();
    }

    function withdrawCollateral(uint256 loanSeed, uint256 unitSeed) external {
        _bump("withdrawCollateral");
        _ensureMarket(loanSeed);
        if (_loanIds.length == 0) return;
        uint256 loanId = _loanIds[loanSeed % _loanIds.length];
        Loan memory l = read.loan(loanId);
        if (l.collateralUnits == 0) return;
        vm.prank(l.borrower);
        try ace.withdrawCollateral(loanId, bound(unitSeed, 1, l.collateralUnits), l.borrower) {} catch {}
        _tail();
    }

    function claimOwed(uint256 loanSeed) external {
        _bump("claimOwed");
        _ensureMarket(loanSeed);
        if (_loanIds.length == 0) return;
        uint256 loanId = _loanIds[loanSeed % _loanIds.length];
        address who = read.loan(loanId).borrower;
        if (who == address(0)) return;
        vm.prank(who);
        /// @dev Counted on DELIVERY, not on the call: an empty entry pays zero without reverting.
        try ace.claimOwed(loanId, who) returns (uint256 u, uint256 a) {
            if (u != 0 || a != 0) creditsPulled++;
        } catch {}
        _tail();
    }

    /// @notice The pull payout: a lender's whole accumulated credit in one quote, across every market of theirs.
    /// @notice THE ONLY VERB HERE THAT DEBITS a lender's pooled credit, so without it that figure only ever rises.
    /// @dev IT IS POOLED, NOT PER-MARKET, and that is the point of driving it in the suite with several markets
    /// @dev per lender: a market-keyed debit would show up here as a payout that left the pool short.
    /// @dev LENDER-ONLY by its ledger key, so the caller collects ITS OWN pool and pays itself.
    /// @dev Half the calls are this market's tenant; the rest a fuzzed lender, whose own pool is just as legitimate.
    function collect(uint256 mSeed, uint256 aSeed) external {
        _bump("collect");
        _ensureMarket(mSeed);
        if (_mkts.length == 0) return;
        Mkt memory k = _mkts[mSeed % _mkts.length];
        address who = aSeed % 2 == 0 ? lenders[k.li] : lenders[aSeed % lenders.length];
        vm.prank(who);
        /// @dev Counted on DELIVERY: an empty pool pays zero without reverting, and a hit count would hide that.
        try ace.collect(address(quoteTokens[k.qi]), who) returns (uint256 paid) {
            quoteClaimed += paid;
        } catch {}
        _tail();
    }

    /// @notice The in-kind exit: the lender takes a settled loan's whole pot in collateral rather than in quote.
    /// @notice The ONE driver of `netSyntheticOutflow` a lender reaches, so LR-9's subtrahend can leave zero.
    /// @dev NO AMOUNT AND NO TICK: sole tenancy makes one party the outright owner of the pot, so there is no
    /// @dev slice to size and no class to name. The stranger draw stays -- the door is lender-gated.
    function redeemInKind(uint256 loanSeed, uint256 aSeed) external {
        _bump("redeemInKind");
        _ensureMarket(loanSeed);
        if (_loanIds.length == 0) return;
        uint256 loanId = _loanIds[loanSeed % _loanIds.length];
        (bool ok, uint256 mi) = _marketIndexOfLoan(loanId);
        if (!ok) return;
        address who = aSeed % 4 == 0 ? lenders[aSeed % lenders.length] : lenders[_mkts[mi].li];
        vm.prank(who);
        try ace.redeemInKind(loanId, who) returns (uint256 out) {
            unitsRedeemed += out;
        } catch {}
        _tail();
    }

    // ---- price and keeper actions ----

    /// @notice Arm distress: park the loan's OWN record just under its trigger, as a real record would print it.
    function crashBelow(uint256 loanSeed) external {
        _bump("crashBelow");
        _ensureMarket(loanSeed);
        if (_loanIds.length == 0) return;
        uint256 loanId = _loanIds[loanSeed % _loanIds.length];
        uint256 trig = read.triggerPrice(loanId);
        if (trig == 0) return;
        MockPersistenceRecord rec = _recordOfLoan(loanId);
        if (address(rec) == address(0)) return;
        rec.setBelowBand(trig);
        rec.setAbove(false);
        _tail();
    }

    /// @notice The recovery print. Every market, because a heal scoped to one strands the rest armed.
    function heal() external {
        _bump("heal");
        for (uint256 i; i < _mkts.length; i++) {
            _mkts[i].record.setBelowBand(0);
            _mkts[i].record.setBelow(false);
            _mkts[i].record.setAbove(true);
        }
        _tail();
    }

    function finalize(uint256 loanSeed) external {
        _bump("finalize");
        _ensureMarket(loanSeed);
        if (_loanIds.length == 0) return;
        uint256 loanId = _loanIds[loanSeed % _loanIds.length];
        vm.prank(keeper);
        try ace.finalize(loanId) {
            settlements++;
        } catch {}
        _tail();
    }

    function forceClose(uint256 loanSeed) external {
        _bump("forceClose");
        _ensureMarket(loanSeed);
        if (_loanIds.length == 0) return;
        uint256 loanId = _loanIds[loanSeed % _loanIds.length];
        uint64 exp = read.loan(loanId).expiry;
        if (exp != 0 && _now() < exp) _warpTo(uint256(exp) + 1);
        vm.prank(keeper);
        try ace.forceClose(loanId) {
            settlements++;
        } catch {}
        _tail();
    }

    function warp(uint256 dtSeed) external {
        _bump("warp");
        _ensureMarket(dtSeed);
        _warpBy(bound(dtSeed, 1 minutes, 45 days));
        _tail();
    }

    function sweepRevenue(uint256 mSeed) external {
        _bump("sweepRevenue");
        _ensureMarket(mSeed);
        if (_mkts.length == 0) return;
        vm.prank(keeper);
        try ace.sweepRevenue(_mkts[mSeed % _mkts.length].id) {} catch {}
        _tail();
    }

    // ---- lookups a loan-keyed action needs ----

    /// @dev A refusal's selector, so a verb that never lands can say WHICH rail turned it away.
    function _sel(bytes memory ret) internal pure returns (bytes4 s) {
        if (ret.length < 4) return bytes4(0);
        assembly ("memory-safe") {
            s := mload(add(ret, 0x20))
        }
    }

    function _marketIndexOfLoan(uint256 loanId) internal view returns (bool ok, uint256 mi) {
        bytes32 m = ace.loanMarket(loanId);
        for (uint256 i; i < _mkts.length; i++) {
            if (_mkts[i].id == m) return (true, i);
        }
        return (false, 0);
    }

    function _quoteOfLoan(uint256 loanId) internal view returns (address) {
        (bool ok, uint256 mi) = _marketIndexOfLoan(loanId);
        return ok ? address(quoteTokens[_mkts[mi].qi]) : address(quoteTokens[0]);
    }

    function _recordOfLoan(uint256 loanId) internal view returns (MockPersistenceRecord) {
        (bool ok, uint256 mi) = _marketIndexOfLoan(loanId);
        return ok ? _mkts[mi].record : MockPersistenceRecord(address(0));
    }
}
