// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.36;

import {Test, console2} from "forge-std/Test.sol";
import {StdInvariant} from "forge-std/StdInvariant.sol";
import {Ace} from "../../src/ace/hub/Ace.sol";
import {Loan, MarketParams, MigrateArgs, OpenBounds} from "../../src/ace/hub/Types.sol";
import {PositionManager} from "../../src/ace/positions/PositionManager.sol";
import {MockERC20} from "../mocks/MockERC20.sol";
import {MockPersistenceRecord} from "../mocks/MockPersistenceRecord.sol";
import {MockStakeVault} from "../mocks/MockStakeVault.sol";
import {AceFixtures} from "../utils/AceFixtures.sol";
import {AceReader} from "../utils/AceReader.sol";
import {AllInFeeSpec} from "../utils/AllInFeeSpec.sol";
import {BookedQuote} from "../utils/BookedQuote.sol";
import {WarpClock} from "../utils/WarpClock.sol";

/// @title AceShareHandler
/// @notice Drives the fee doors, the closes and the treasury's share setter on one hub of two markets that share a lender pool.
/// @notice Every fee door that lands is held, mid-call, to the spec at the share live at that moment; a miss latches.
/// @dev The share moves between any two steps, so a door priced at a stale, zero or ceiling share is a sequence the fuzzer can reach.
/// @dev Every action is bounded and try/catch-guarded (fail_on_revert = false); a refusal is a tally, never a failure.
contract AceShareHandler is WarpClock {
    uint256 internal constant MAX = 1000; // re-spelled ceiling
    uint64 internal constant TEN7 = 7 days;
    uint64 internal constant TEN30 = 30 days;
    uint256 internal constant COLL = 100_000e18;
    uint256 internal constant CASH = 50_000_000e6;
    uint256 internal constant FLOOR = 5e6; // the live debt floor, half the fixture's `minPrincipal`

    Ace public ace;
    PositionManager public pm;
    AceReader public read;
    MockERC20 public usdc;
    MockStakeVault public vault;
    bytes32[2] public mids;
    uint256[2] public rates;
    MockPersistenceRecord[2] public records;

    address public constant TREASURY = AceFixtures.TREASURY;
    address public constant LENDER = AceFixtures.LENDER;
    address public keeper = address(0xCAFE);
    address public stranger = address(0xBAD);
    address[3] internal actors = [address(0xB0B1), address(0xB0B2), address(0xB0B3)];

    uint256[] internal _loanIds;

    uint256 public lastShare = MAX; // the share the treasury last set, mirrored
    uint256 public expectedRevenue; // every landed fee's protocol slice at its own live share, from the spec

    bool public priceSlip; // a landed fee, its payout or its booked slice disagreed with the spec at the live share
    string public priceSlipTag;
    bool public illegalShareLanded; // a stranger's set, or one over the ceiling, landed
    bool public revenueFell; // revenue plus the treasury's take fell, or the treasury's balance did
    uint256 internal _lastRevPlusTreasury;
    uint256 internal _lastTreasury;

    mapping(string => uint256) public calls;
    mapping(string => uint256) public landed;
    mapping(string => bytes4) public lastRefusal;

    constructor() {
        _warpTo(1_000_000);
        usdc = new MockERC20("USD Coin", "USDC", 6);
        vault = new MockStakeVault(42);
        rates = [uint256(2190), uint256(2555)];
        for (uint256 i; i < 2; ++i) {
            records[i] = new MockPersistenceRecord(address(usdc), address(vault));
            records[i].setAbove(true);
        }
        AceFixtures.Deployment memory d = AceFixtures.deploy(_params(0));
        (ace, pm, read, mids[0]) = (d.ace, d.positionManager, d.read, d.id);
        mids[1] = ace.createMarket(_params(1));
        for (uint256 i; i < 2; ++i) {
            usdc.mint(LENDER, CASH);
            vm.startPrank(LENDER);
            usdc.approve(address(ace), CASH);
            ace.deposit(mids[i], CASH);
            vm.stopPrank();
        }
        AceFixtures.installYesPolicy(ace, LENDER); // extensions land, and an own-market refinance reuses the claim
    }

    function _params(uint256 i) internal view returns (MarketParams memory p) {
        p = AceFixtures.marketParams(address(usdc), address(vault));
        p.record = address(records[i]);
        p.lenderAprBps = rates[i];
        p.minTenor = TEN7;
        p.maxTenor = TEN30;
    }

    /* ============================== the fee doors ============================== */

    function open(uint256 marketSeed, uint256 actorSeed, uint256 principalSeed, uint256 tenorSeed) external {
        _bump("open");
        _open(marketSeed % 2, actors[actorSeed % 3], bound(principalSeed, 1_000e6, 30_000e6), uint64(bound(tenorSeed, TEN7, TEN30)));
        _tail();
    }

    /// @dev The one open body: the fuzzed `open`, and the fresh loan a door opens when no tracked loan fits it.
    function _open(uint256 mi, address who, uint256 principal, uint64 tenor) internal returns (bool ok, uint256 loanId) {
        uint256 s = ace.protocolShareBps();
        uint256 fee = AllInFeeSpec.feeAllIn(principal, tenor, rates[mi], s);
        vault.mint(who, COLL);
        vm.prank(who);
        vault.approve(address(pm), COLL);
        uint256 rev = _revenue();
        uint256 bal = usdc.balanceOf(who);
        vm.prank(who);
        try ace.open(mids[mi], COLL, principal, tenor, who, OpenBounds(0, 0, 0)) returns (uint256 id) {
            (ok, loanId) = (true, id);
            _land("open");
            _loanIds.push(id);
            _judge("open", read.loan(id).lastFee, fee, s, rev);
            _judgePaid("open", usdc.balanceOf(who) - bal, principal - fee);
        } catch {}
    }

    /// @dev A live loan with at least `minLeft` of its term to run, else a fresh 30-day loan opened for it.
    function _pickOrOpen(uint256 seed, uint256 minLeft) internal returns (bool ok, uint256 loanId) {
        (ok, loanId) = _pickLive(seed, minLeft);
        if (!ok) (ok, loanId) = _open(seed % 2, actors[(seed >> 8) % 3], bound(seed >> 16, 1_000e6, 30_000e6), TEN30);
    }

    function drawMore(uint256 loanSeed, uint256 amtSeed) external {
        _bump("drawMore");
        (bool found, uint256 loanId) = _pickOrOpen(loanSeed, TEN7 + 1); // a top-up needs `minTenor` left
        if (!found) return _tail();
        Loan memory l = read.loan(loanId);
        uint256 amount = bound(amtSeed, 10e6, 10_000e6);
        uint256 s = ace.protocolShareBps();
        uint256 fee = l.expiry > _now() ? AllInFeeSpec.feeAllIn(amount, uint64(l.expiry - _now()), _rateOf(l.market), s) : 0;
        uint256 rev = _revenue();
        uint256 bal = usdc.balanceOf(l.borrower);
        vm.prank(l.borrower);
        try ace.drawMore(loanId, amount, OpenBounds(0, 0, 0)) returns (uint256 charged) {
            _land("drawMore");
            _judge("drawMore", charged, fee, s, rev);
            _judgePaid("drawMore", usdc.balanceOf(l.borrower) - bal, amount - fee);
        } catch (bytes memory err) {
            _refused("drawMore", err);
        }
        _tail();
    }

    /// @dev Steps a little into the term first, so an extension opened this second still adds time.
    function extend(uint256 loanSeed, uint256 stepSeed) external {
        _bump("extend");
        (bool found, uint256 loanId) = _pickOrOpen(loanSeed, 2);
        if (!found) return _tail();
        Loan memory l = read.loan(loanId);
        uint256 step = bound(stepSeed, 1, 2 days);
        if (_now() + step < l.expiry) _warpBy(step);
        uint256 s = ace.protocolShareBps();
        uint256 fee = AllInFeeSpec.feeAllIn(l.debt, uint64(_now() + l.tenor - l.expiry), _rateOf(l.market), s);
        usdc.mint(l.borrower, fee);
        vm.prank(l.borrower);
        usdc.approve(address(ace), fee);
        uint256 rev = _revenue();
        vm.prank(l.borrower);
        try ace.extend(loanId, 0, "") returns (uint256 charged) {
            _land("extend");
            _judge("extend", charged, fee, s, rev);
        } catch (bytes memory err) {
            _refused("extend", err);
        }
        _tail();
    }

    /// @dev Into either market, so an own-market re-term that reuses the claim and a cross-market draw both run.
    function refinance(uint256 loanSeed, uint256 dstSeed, uint256 principalSeed) external {
        _bump("refinance");
        (bool found, uint256 loanId) = _pickOrOpen(loanSeed, 1);
        if (!found) return _tail();
        Loan memory l = read.loan(loanId);
        uint256 di = dstSeed % 2;
        uint256 lo = l.debt + l.debt / 4; // enough over the debt that the net out is positive
        uint256 hi = l.debt * 3 / 2 < 60_000e6 ? l.debt * 3 / 2 : 60_000e6; // under what the lot covers, mostly
        uint256 newP = bound(principalSeed, lo, hi < lo ? lo : hi);
        if (newP < 1_000e6) newP = 1_000e6;
        uint256 s = ace.protocolShareBps();
        uint256 fee = AllInFeeSpec.feeAllIn(newP, TEN30, rates[di], s);
        uint256 refund = read.earlyExitRefund(loanId);
        uint256 rev = _revenue();
        uint256 bal = usdc.balanceOf(l.borrower);
        vm.prank(l.borrower);
        try ace.refinanceTo(MigrateArgs(loanId, mids[di], newP, TEN30, OpenBounds(0, 0, 0), 0, address(0))) returns (uint256 newId) {
            _land(di == _indexOf(l.market) ? "refinanceHome" : "refinanceAway");
            _loanIds.push(newId);
            _judge("refinance", read.loan(newId).lastFee, fee, s, rev);
            _judgePaid("refinance", usdc.balanceOf(l.borrower) - bal, newP - fee + refund - l.debt);
        } catch (bytes memory err) {
            _refused("refinance", err);
        }
        _tail();
    }

    /* ============================== the closes ============================== */

    /// @dev One seed in four pays the debt whole; a payment that would leave it under the floor does too.
    function repay(uint256 loanSeed, uint256 amtSeed) external {
        _bump("repay");
        (bool found, uint256 loanId) = _pickLive(loanSeed, 0);
        if (!found) return _tail();
        Loan memory l = read.loan(loanId);
        uint256 amount = amtSeed % 4 == 0 ? l.debt : bound(amtSeed, 1, l.debt);
        if (l.debt - amount < FLOOR) amount = l.debt;
        usdc.mint(l.borrower, amount);
        vm.prank(l.borrower);
        usdc.approve(address(ace), amount);
        vm.prank(l.borrower);
        try ace.repay(loanId, amount) {
            _land(amount == l.debt ? "repayClose" : "repayPart");
        } catch {}
        _tail();
    }

    /// @dev Arms the loan's own record just under its trigger, finalizes, and heals the record in the same step.
    /// @dev Skipped on a book of one, so the closes never leave the fee doors nothing to act on.
    function settle(uint256 loanSeed) external {
        _bump("settle");
        if (_liveCount() < 2) return _tail();
        (bool found, uint256 loanId) = _pickLive(loanSeed, 0);
        if (!found) return _tail();
        MockPersistenceRecord r = records[_indexOf(read.loan(loanId).market)];
        r.setBelowBand(read.triggerPrice(loanId));
        r.setAbove(false);
        vm.prank(keeper);
        try ace.finalize(loanId) {
            _land("settle");
        } catch {}
        r.setBelowBand(0);
        r.setBelow(false);
        r.setAbove(true);
        _tail();
    }

    function forceClose(uint256 loanSeed) external {
        _bump("forceClose");
        if (_liveCount() < 2) return _tail();
        (bool found, uint256 loanId) = _pickLive(loanSeed, 0);
        if (!found) return _tail();
        _warpAtLeastTo(uint256(read.loan(loanId).expiry) + 1);
        vm.prank(keeper);
        try ace.forceClose(loanId) {
            _land("forceClose");
        } catch {}
        _tail();
    }

    /* ============================== the share, time and the sweep ============================== */

    /// @dev One call in four asks over the ceiling and one in eight comes from a stranger; either landing latches.
    function setShare(uint256 seed) external {
        _bump("setShare");
        if (seed % 8 == 0) {
            vm.prank(stranger);
            try ace.setProtocolShareBps(bound(seed >> 8, 0, MAX)) {
                illegalShareLanded = true;
            } catch {}
        } else if (seed % 4 == 1) {
            vm.prank(TREASURY);
            try ace.setProtocolShareBps(bound(seed >> 8, MAX + 1, type(uint256).max)) {
                illegalShareLanded = true;
            } catch {}
        } else {
            uint256 s = bound(seed >> 8, 0, MAX);
            vm.prank(TREASURY);
            try ace.setProtocolShareBps(s) {
                _land("setShare");
                lastShare = s;
            } catch {}
        }
        _tail();
    }

    function warp(uint256 dtSeed) external {
        _bump("warp");
        _warpBy(bound(dtSeed, 1 hours, 10 days));
        _land("warp");
        _tail();
    }

    /// @dev Both markets quote usdc, so the one per-quote sweep drains both their cuts; the seed picks nothing.
    function sweep(uint256) external {
        _bump("sweep");
        uint256 before = usdc.balanceOf(TREASURY);
        vm.prank(keeper);
        try ace.sweepRevenue(address(usdc)) {
            if (usdc.balanceOf(TREASURY) > before) _land("sweep");
        } catch {}
        _tail();
    }

    /* ============================== judgement and bookkeeping ============================== */

    /// @dev A landed fee must be the spec's at the live share, and the hub's revenue must rise by exactly that fee's slice.
    function _judge(string memory tag, uint256 charged, uint256 fee, uint256 s, uint256 revBefore) internal {
        uint256 slice = AllInFeeSpec.protocolFee(fee, s);
        expectedRevenue += slice;
        if (charged != fee) _slip(string.concat(tag, ": fee is not the spec at the live share"));
        if (_revenue() != revBefore + slice) _slip(string.concat(tag, ": booked slice is not the live share's"));
    }

    function _judgePaid(string memory tag, uint256 got, uint256 want) internal {
        if (got != want) _slip(string.concat(tag, ": the payee was not paid net of the live share's fee"));
    }

    function _slip(string memory tag) internal {
        if (priceSlip) return;
        priceSlip = true;
        priceSlipTag = tag;
    }

    /// @dev The revenue latch: what the pot holds plus what the treasury was swept never falls, and the treasury never does.
    function _tail() internal {
        uint256 tre = usdc.balanceOf(TREASURY);
        uint256 sum = _revenue() + tre;
        if (tre < _lastTreasury || sum < _lastRevPlusTreasury) revenueFell = true;
        (_lastTreasury, _lastRevPlusTreasury) = (tre, sum);
    }

    /// @dev The usdc pot, read ONCE: both markets book into it, so a per-market sum would count it twice.
    function _revenue() internal view returns (uint256) {
        return read.revenuePot(address(usdc));
    }

    function _bump(string memory tag) internal {
        calls[tag]++;
    }

    function _land(string memory tag) internal {
        landed[tag]++;
    }

    /// @dev The last refusal's selector per door, so a tally that never lands names why.
    function _refused(string memory tag, bytes memory err) internal {
        bytes4 sel;
        if (err.length >= 4) sel = bytes4(err);
        lastRefusal[tag] = sel;
    }

    function _indexOf(bytes32 m) internal view returns (uint256) {
        return m == mids[0] ? 0 : 1;
    }

    function _rateOf(bytes32 m) internal view returns (uint256) {
        return rates[_indexOf(m)];
    }

    /// @dev The first live loan at or after the seed's index, wrapping, with at least `minLeft` seconds of its term to run.
    function _pickLive(uint256 seed, uint256 minLeft) internal view returns (bool, uint256) {
        uint256 n = _loanIds.length;
        if (n == 0) return (false, 0);
        uint256 start = seed % n;
        for (uint256 k; k < n; ++k) {
            uint256 loanId = _loanIds[(start + k) % n];
            if (ace.isLiveLoan(loanId) && read.loan(loanId).expiry >= _now() + minLeft) return (true, loanId);
        }
        return (false, 0);
    }

    function _liveCount() internal view returns (uint256 c) {
        for (uint256 k; k < _loanIds.length; ++k) {
            if (ace.isLiveLoan(_loanIds[k])) c++;
        }
    }

    function loanCount() external view returns (uint256) {
        return _loanIds.length;
    }
}

/// @title AceShareInvariant
/// @notice The settable origination share under a random walk of fee doors, closes, sweeps and share changes.
/// @notice Solvency per token; the share inside [0, 1000] and set only by the treasury; revenue leaves only through the sweep.
/// @dev Config (foundry.toml [invariant]): fail_on_revert = false, so every per-call claim is latched into a handler ghost.
contract AceShareInvariantTest is StdInvariant, Test {
    AceShareHandler internal handler;
    Ace internal ace;
    AceReader internal read;
    MockERC20 internal usdc;

    function setUp() public {
        handler = new AceShareHandler();
        ace = handler.ace();
        read = handler.read();
        usdc = handler.usdc();
        bytes4[] memory sel = new bytes4[](10);
        sel[0] = AceShareHandler.open.selector;
        sel[1] = AceShareHandler.drawMore.selector;
        sel[2] = AceShareHandler.extend.selector;
        sel[3] = AceShareHandler.refinance.selector;
        sel[4] = AceShareHandler.repay.selector;
        sel[5] = AceShareHandler.settle.selector;
        sel[6] = AceShareHandler.forceClose.selector;
        sel[7] = AceShareHandler.setShare.selector;
        sel[8] = AceShareHandler.warp.selector;
        sel[9] = AceShareHandler.sweep.selector;
        targetSelector(FuzzSelector({addr: address(handler), selectors: sel}));
        targetContract(address(handler));
    }

    /// @notice The hub's usdc is its books, exactly: both markets' pots, every loan's escrow, and the one lender's pool credit.
    function invariant_solvency() public view {
        bytes32[] memory markets = new bytes32[](2);
        (markets[0], markets[1]) = (handler.mids(0), handler.mids(1));
        address[] memory lenders = new address[](1);
        lenders[0] = handler.LENDER();
        assertEq(usdc.balanceOf(address(ace)), BookedQuote.total(ace, read, markets, lenders, address(usdc)), "solvency identity");
    }

    /// @notice The share never passes the ceiling, and it is always the last value the treasury set.
    function invariant_theShareStaysInsideTheCeiling() public view {
        assertLe(ace.protocolShareBps(), 1000, "the share passed the ceiling");
        assertEq(ace.protocolShareBps(), handler.lastShare(), "the share is not the treasury's last set");
        assertFalse(handler.illegalShareLanded(), "a stranger's set, or one over the ceiling, landed");
    }

    /// @notice Revenue is every fee's slice at its own share, wherever it now sits; it leaves the markets only for the treasury.
    function invariant_revenueLeavesOnlyThroughTheSweep() public view {
        uint256 held = read.revenuePot(address(usdc)); // ONE read: both markets book into the usdc pot
        assertEq(held + usdc.balanceOf(handler.TREASURY()), handler.expectedRevenue(), "revenue is not the sum of each fee's live-share slice");
        assertFalse(handler.revenueFell(), "revenue fell other than into the treasury");
    }

    /// @notice Every fee door that landed charged, paid and booked at the share live at its moment.
    function invariant_everyFeeIsPricedAtTheLiveShare() public view {
        assertFalse(handler.priceSlip(), handler.priceSlipTag());
    }

    /// @notice Each verb's calls and landings for the LAST sequence, printed for `scripts/invariant-tallies.sh`.
    function afterInvariant() public view {
        string[14] memory tags = [
            "open",
            "drawMore",
            "extend",
            "refinance",
            "refinanceHome",
            "refinanceAway",
            "repay",
            "repayPart",
            "repayClose",
            "settle",
            "forceClose",
            "setShare",
            "warp",
            "sweep"
        ];
        console2.log("=== AceShareHandler verb hits (LAST sequence only): calls / landed ===");
        for (uint256 i; i < tags.length; ++i) {
            console2.log(string.concat(tags[i], ": ", vm.toString(handler.calls(tags[i])), " / ", vm.toString(handler.landed(tags[i]))));
        }
        console2.log(string.concat("loans tracked: ", vm.toString(handler.loanCount()), ", share now: ", vm.toString(ace.protocolShareBps())));
        string[3] memory doors = ["drawMore", "extend", "refinance"];
        for (uint256 i; i < doors.length; ++i) {
            console2.log(string.concat(doors[i], " last refusal: ", vm.toString(abi.encodePacked(handler.lastRefusal(doors[i])))));
        }
    }

    /// @notice Every verb lands at least once on a fixed walk at a non-ceiling share, so a green campaign is not an unexercised one.
    function test_Coverage_EveryVerbLandsAndTheInvariantsHold() public {
        handler.setShare(500 << 8 | 2); // seed % 8 == 2: the treasury sets 500
        assertEq(ace.protocolShareBps(), 500, "fixture: the walk runs at half the ceiling");
        handler.open(0, 0, 10_000e6, TEN30_SEED);
        handler.open(1, 1, 10_000e6, TEN30_SEED);
        handler.open(0, 2, 10_000e6, TEN30_SEED);
        handler.warp(0);
        handler.drawMore(0, 2_000e6);
        handler.extend(0, 3600);
        handler.setShare(250 << 8 | 2);
        handler.refinance(0, 0, 0);
        handler.refinance(1, 0, 0);
        handler.repay(2, 1);
        handler.repay(2, type(uint256).max);
        handler.settle(3);
        handler.open(1, 0, 10_000e6, TEN30_SEED); // a close is skipped on a book of one
        handler.forceClose(4); // no sweep rides it, so the bare sweep below takes the usdc pot whole
        handler.sweep(1);
        string[12] memory must =
            ["open", "drawMore", "extend", "refinanceHome", "refinanceAway", "repayPart", "repayClose", "settle", "forceClose", "setShare", "warp", "sweep"];
        for (uint256 i; i < must.length; ++i) {
            assertGt(handler.landed(must[i]), 0, string.concat("the walk never landed ", must[i]));
        }
        invariant_solvency();
        invariant_theShareStaysInsideTheCeiling();
        invariant_revenueLeavesOnlyThroughTheSweep();
        invariant_everyFeeIsPricedAtTheLiveShare();
    }

    uint256 internal constant TEN30_SEED = 30 days; // bound() keeps an in-range seed as it stands
}
