// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.36;

import {WarpClock} from "../utils/WarpClock.sol";
import {FullMath} from "@uniswap/v4-core/src/libraries/FullMath.sol";

import {Ace} from "../../src/ace/hub/Ace.sol";
import {AceLens} from "../../src/ace/lens/AceLens.sol";
import {Borrower} from "../../src/ace/hub/Borrower.sol";
import {MarketInit} from "../../src/ace/hub/MarketInit.sol";
import {Cfg, Loan, MarketParams, OpenBounds, Storage} from "../../src/ace/hub/Types.sol";
import {PositionManager} from "../../src/ace/positions/PositionManager.sol";
import {ProtocolPolicy} from "../../src/config/Defaults.sol";
import {MockERC20} from "../mocks/MockERC20.sol";
import {MockStakeVault} from "../mocks/MockStakeVault.sol";
import {MockPersistenceRecord} from "../mocks/MockPersistenceRecord.sol";
import {AceFixtures} from "../utils/AceFixtures.sol";
import {AceReader} from "../utils/AceReader.sol";

/// @title AceStagedSettlementHandler
/// @notice QUARANTINED. The settlement branches the main campaign cannot reach, driven on their own hub.
/// @notice One market with a record, one without; real verbs plus ONE staging action, `stageShortEscrow`.
/// @dev The short branch is unreachable by verbs: the premium is fixed and the coverage line holds at both doors.
/// @dev So a loan whose units cannot pay its claim at book can only be STAGED, and this handler is the one place that may.
/// @dev THE STAGING IS `Ace.withdrawCollateral` WITH ITS COVERAGE-LINE REFUSAL REMOVED, AND NOTHING ELSE.
/// @dev It releases through `PositionManager.release` as the hub, so the token and both custody ledgers move as that verb moves them.
/// @dev It then writes `Loan.collateralUnits`, the one hub word that verb writes, and keeps every other refusal it makes.
/// @dev Closed, matured and zero-left loans are skipped, so the ONLY property it can break is `units >= coverage line`.
/// @dev The suite asserts the custody identity, so a staging that moved one ledger without the other reddens it first.
/// @dev The recordless market needs no staging: its coverage forfeit is reachable by real verbs and is driven as such.
/// @dev The MAIN campaign (`AceHandler`) must never gain this action: it drives real verbs only, and that is its strength.
contract AceStagedSettlementHandler is WarpClock {
    uint256 internal constant MAX_LOANS = 16; // tracked-loan cap; settlement verbs need live loans to act on

    Ace public ace;
    AceLens public lens;
    AceReader public read;
    PositionManager public pm;
    MockERC20 public usdc;
    MockStakeVault public vault;
    MockPersistenceRecord public record; // the recorded market's own; crash and heal reach nothing else

    bytes32 public recId; // the market with a record: finalize, the expiry fold and settleExpired all settle here
    bytes32 public norecId; // the recordless market: its settlement takes the whole coverage line, the forfeit branch

    address public recLender = address(0xA11CE);
    address public norecLender = address(0xA11CF);
    address[2] public borrowers = [address(0xB0B), address(0xB0C)];
    address public keeper = address(0xCAFE); // the paid settlement doors' caller, so the sliver has one named payee
    address public stranger = address(0x57A2A6E2); // the unpaid backstop's caller: `settleExpired` pays nobody
    address public trader = address(0x74AD34);
    address public sink = address(0x5111C); // where staged units go: out of the system, as a withdrawal sends them

    uint256[] internal _loanIds;
    mapping(bytes32 => uint256) public calls;

    uint256 public stagedShort; // stagings that landed: the action's own success count
    uint256 public stagedOneAtom; // of those, staged exactly one atom short, the quantization edge
    bool public stagingMisaimed; // a staging whose hub word did not read back as written
    uint256 public lastStaged; // the most recent staged loan, which half the settle draws aim at

    /// @dev The settlement latch: the first settle whose ledgers disagree with the settle it was, and why.
    /// @dev 1 units not conserved, 2 claim survived, 3 lent did not fall by the claim, 4 shortfall record wrong,
    /// @dev 5 the market's loss total did not move with the record, 6 a short settle paid the defaulted borrower,
    /// @dev 7 the unpaid backstop credited its caller, 8 the unpaid backstop landed inside the loan's roll window,
    /// @dev 9 a loan in the recordless market was armed, which no record can judge.
    uint8 public settleCode;
    uint256 public settleLoanId;
    uint256 public settleExpected;
    uint256 public settleActual;

    uint256[3] public settlesShort; // per path (0 finalize, 1 expiry fold, 2 settleExpired): settles that came up short
    uint256[3] public settlesCovered; // per path: settles the units covered
    uint256 public forfeits; // recordless settles whose market took more than the claim's need
    uint256 public foldRolls; // expiry folds that rolled an armed loan instead of settling it
    uint256 public earlyRefused; // settleExpired calls inside the roll window that refused, as they must
    uint256 public recordlessArmRefused; // arm attempts on the recordless market that refused, as they must
    uint256 public baselineShort; // short settles the baseline landed, so a report can tell the fuzzer's own from them

    /// @dev What one settle is checked against, taken before it runs.
    struct Pre {
        bytes32 m;
        address borrower;
        address caller;
        uint256 claim;
        uint256 units;
        uint256 pot;
        uint256 borrowerOwed;
        uint256 callerOwed;
        uint256 lent;
        uint256 loss;
        uint256 price;
    }

    constructor() {
        _warpTo(1_000_000);
        usdc = new MockERC20("USD Coin", "USDC", 6);
        vault = new MockStakeVault(42);
        record = new MockPersistenceRecord(address(usdc), address(vault));
        record.setAbove(true);
        record.setMinPrice(AceFixtures.px(2e18, address(usdc), address(vault)));

        MarketParams memory p = AceFixtures.marketParams(address(usdc), address(vault));
        p.record = address(record);
        p.lender = recLender;
        AceFixtures.Deployment memory d = AceFixtures.deploy(p);
        (ace, pm, read, recId) = (d.ace, d.positionManager, d.read, d.id);
        lens = new AceLens(address(ace));

        MarketParams memory q = AceFixtures.marketParams(address(usdc), address(vault));
        q.lender = norecLender; // no record: the forfeit branch, and a market no loan can arm in
        norecId = ace.createMarket(q);
        require(norecId != recId, "TOPOLOGY: the two markets collided");

        _seed(recLender, recId, 60_000e6);
        _seed(norecLender, norecId, 60_000e6);
        _baseline();
    }

    /// @notice Every settlement branch this campaign exists for, landed once before the fuzzer runs.
    /// @dev A branch the fuzzer can miss is asserted over nothing on a cold run; the requires make each one structural.
    function _baseline() internal {
        uint256 a = _mustOpen(recId, borrowers[0]);
        _stage(a, 2); // deep: two atoms, which the paid sliver eats whole
        _crash(a);
        _finalize(a);
        _requireLatchClean();
        require(settlesShort[0] > 0, "BASELINE: the staged short finalize did not land short");
        _heal();

        uint256 b = _mustOpen(recId, borrowers[1]);
        _stage(b, 0); // one atom short after the paid door's sliver: the quantization edge
        _forceClose(b);
        _requireLatchClean();
        require(settlesShort[1] > 0, "BASELINE: the staged short expiry fold did not land short");

        uint256 c = _mustOpen(recId, borrowers[0]);
        _stage(c, 1); // one atom short on the unpaid door, which takes no sliver
        _settleExpired(c, true); // at expiry, inside the roll window: must refuse
        _requireLatchClean();
        require(earlyRefused > 0, "BASELINE: settleExpired inside the roll window did not refuse");
        _settleExpired(c, false);
        _requireLatchClean();
        require(settlesShort[2] > 0, "BASELINE: the staged short settleExpired did not land short");

        uint256 e = _mustOpen(norecId, borrowers[1]);
        _arm(e); // a recordless market cannot arm: must refuse
        _requireLatchClean();
        require(recordlessArmRefused > 0, "BASELINE: arming a loan in the recordless market did not refuse");
        _forceClose(e);
        _requireLatchClean();
        require(forfeits > 0, "BASELINE: the recordless settle forfeited nothing past the claim's need");
        require(stagedShort == 3 && !stagingMisaimed, "BASELINE: a staging did not land as written");
        require(settleCode == 0, "BASELINE: a baseline settle already broke the settlement latch");

        uint256 f = _mustOpen(recId, borrowers[0]);
        _repayWhole(f); // a clean close refunds the unearned escrow AS A CREDIT, so the quote ledger has an entry to hold
        require(read.marketState(recId).quoteOwedTotal > 0, "BASELINE: the clean close credited no quote refund");
        baselineShort = settlesShort[0] + settlesShort[1] + settlesShort[2];
    }

    function _repayWhole(uint256 id) internal {
        Loan memory l = read.loan(id);
        usdc.mint(l.borrower, l.debt);
        vm.startPrank(l.borrower);
        usdc.approve(address(ace), l.debt);
        ace.repay(id, l.debt);
        vm.stopPrank();
    }

    /// @dev Checked BEFORE each branch's own require: a broken settle latches and skips its tally, so the code is the real reason.
    function _requireLatchClean() internal view {
        require(settleCode == 0, string.concat("BASELINE: a settle broke the settlement latch, code ", vm.toString(uint256(settleCode))));
    }

    function _mustOpen(bytes32 m, address who) internal returns (uint256 id) {
        id = _openIn(m, who, 2_000e6, 20_000);
        require(id != 0, "BASELINE: a baseline open did not land");
    }

    // ---- views the suite walks ----

    function loanIds() external view returns (uint256[] memory) {
        return _loanIds;
    }

    function callCount(string memory tag) external view returns (uint256) {
        return calls[keccak256(bytes(tag))];
    }

    function claimants() external view returns (address[5] memory) {
        return [borrowers[0], borrowers[1], keeper, stranger, address(this)];
    }

    // ---- shared helpers ----

    function _bump(string memory tag) internal {
        calls[keccak256(bytes(tag))]++;
    }

    function _seed(address who, bytes32 m, uint256 amt) internal {
        usdc.mint(who, amt);
        vm.startPrank(who);
        usdc.approve(address(ace), amt);
        ace.deposit(m, amt);
        vm.stopPrank();
    }

    function _cfg(bytes32 m) internal view returns (Cfg memory c) {
        c.p = ace.idToMarketParams(m);
        c.unitScale = read.marketState(m).unitScale;
    }

    /// @dev The claim's need at book: one ceil on the whole claim, as settlement takes it.
    function _need(bytes32 m, uint256 claim) internal view returns (uint256) {
        if (claim == 0) return 0;
        return FullMath.mulDivRoundingUp(claim, read.marketState(m).unitScale, ace.idToMarketParams(m).price);
    }

    /// @dev The settle doors' pick: on an even seed the last staged loan while it is still live, else any live loan.
    /// @dev Without the bias a staged loan is rarely the one a later settle lands on, and the short branch is a lottery again.
    function _pickSettle(uint256 seed) internal view returns (bool found, uint256 id) {
        if (seed % 2 == 0 && lastStaged != 0 && read.loan(lastStaged).closedAt == 0) return (true, lastStaged);
        return _pickBy(seed, true);
    }

    /// @dev The first tracked loan at or after the seed's pick that is `live` (or settled, when false), wrapping once.
    /// @dev Without it a short sequence spends its settle and stage draws on loans the baseline already closed.
    function _pickBy(uint256 seed, bool live) internal view returns (bool found, uint256 id) {
        uint256 n = _loanIds.length;
        for (uint256 k; k < n; k++) {
            id = _loanIds[(seed % n + k) % n];
            if ((read.loan(id).closedAt == 0) == live) return (true, id);
        }
    }

    function _pickMarket(uint256 seed) internal view returns (bytes32) {
        return seed % 3 == 0 ? norecId : recId; // two in three draws land where the record makes every branch live
    }

    function _lenderOf(bytes32 m) internal view returns (address) {
        return ace.idToMarketParams(m).lender;
    }

    // ---- lender and borrower verbs ----

    function deposit(uint256 mSeed, uint256 amtSeed) external {
        _bump("deposit");
        bytes32 m = _pickMarket(mSeed);
        address who = _lenderOf(m);
        uint256 amt = bound(amtSeed, ace.idToMarketParams(m).minDebt, 50_000e6);
        usdc.mint(who, amt);
        vm.startPrank(who);
        usdc.approve(address(ace), amt);
        try ace.deposit(m, amt) {} catch {}
        vm.stopPrank();
    }

    function withdraw(uint256 mSeed, uint256 amtSeed) external {
        _bump("withdraw");
        bytes32 m = _pickMarket(mSeed);
        address who = _lenderOf(m);
        vm.prank(who);
        try ace.withdraw(m, bound(amtSeed, 1, 80_000e6), who, 0) {} catch {}
    }

    function collect(uint256 mSeed) external {
        _bump("collect");
        address who = _lenderOf(_pickMarket(mSeed));
        vm.prank(who);
        try ace.collect(address(usdc), who) {} catch {}
    }

    /// @notice A draw sized to clear the coverage line by `factor` bps of it, so health varies by the seed.
    function open(uint256 mSeed, uint256 bSeed, uint256 drawSeed, uint256 factorSeed) external {
        _bump("open");
        if (_loanIds.length >= MAX_LOANS) return;
        bytes32 m = _pickMarket(mSeed);
        _openIn(m, borrowers[bSeed % 2], bound(drawSeed, 50e6, 8_000e6), bound(factorSeed, 10_000, 30_000));
    }

    function _openIn(bytes32 m, address who, uint256 principal, uint256 factorBps) internal returns (uint256 id) {
        Cfg memory c = _cfg(m);
        uint256 line = Borrower.coverageLine(c, principal, c.p.price);
        uint256 units = (line * factorBps) / 10_000 + 1;
        vault.mint(who, units);
        vm.startPrank(who);
        vault.approve(address(pm), units);
        try ace.open(m, units, principal, 0, who, OpenBounds(0, 0, 0)) returns (uint256 got) {
            id = got;
            _loanIds.push(got);
        } catch {}
        vm.stopPrank();
    }

    function repay(uint256 loanSeed, uint256 amtSeed) external {
        _bump("repay");
        (bool found, uint256 id) = _pickBy(loanSeed, true);
        if (!found) return;
        Loan memory l = read.loan(id);
        if (l.closedAt != 0 || l.debt == 0) return;
        uint256 amt = bound(amtSeed, 1, l.debt);
        usdc.mint(l.borrower, amt);
        vm.startPrank(l.borrower);
        usdc.approve(address(ace), amt);
        try ace.repay(id, amt) {} catch {}
        vm.stopPrank();
    }

    /// @notice Arm the loan's roll, so the expiry fold has to judge a staged loan before it settles one.
    /// @dev Drawn on BOTH markets: on the recordless one it must refuse, and a landing there is latched as code 9.
    function armPolicy(uint256 loanSeed) external {
        _bump("armPolicy");
        (bool found, uint256 id) = _pickBy(loanSeed, true);
        if (found) _arm(id);
    }

    function _arm(uint256 id) internal {
        bool recordless = read.loan(id).market == norecId;
        vm.prank(read.loan(id).borrower);
        try ace.setAutoRefinance(id, ProtocolPolicy.MIN_TENOR, 0, 0) {
            if (recordless) _latch(9, id, 0, 1);
        } catch {
            if (recordless) recordlessArmRefused++;
        }
    }

    function claimOwed(uint256 loanSeed, uint256 whoSeed) external {
        _bump("claimOwed");
        (bool found, uint256 id) = _pickBy(loanSeed, false);
        if (!found) return;
        address who = whoSeed % 2 == 0 ? read.loan(id).borrower : keeper;
        vm.prank(who);
        try ace.claimOwed(id, who) {} catch {}
    }

    function redeemInKind(uint256 loanSeed) external {
        _bump("redeemInKind");
        (bool found, uint256 id) = _pickBy(loanSeed, false);
        if (!found) return;
        address who = _lenderOf(read.loan(id).market);
        vm.prank(who);
        try ace.redeemInKind(id, who) {} catch {}
    }

    /// @notice A stranger buys out of a settled pot once its hold has passed.
    function buyInventory(uint256 loanSeed, uint256 quoteSeed) external {
        _bump("buyInventory");
        (bool found, uint256 id) = _pickBy(loanSeed, false);
        if (!found) return;
        _warpAtLeastTo(read.inventoryAskOpensAt(id));
        uint256 amt = bound(quoteSeed, 1e6, 20_000e6);
        usdc.mint(trader, amt);
        vm.startPrank(trader);
        usdc.approve(address(ace), amt);
        try ace.buyInventory(id, amt, 0, trader) {} catch {}
        vm.stopPrank();
    }

    function warp(uint256 dtSeed) external {
        _bump("warp");
        _warpBy(bound(dtSeed, 1 minutes, 20 days));
    }

    // ---- THE STAGING, and the record levers ----

    /// @notice QUARANTINED: take a live loan's units under what its claim needs, as an ungated withdrawal would.
    /// @dev Half the stagings land on the quantization edge: one atom short after a paid door's sliver, or before it.
    /// @dev The rest land anywhere from one unit up, where the sliver alone can eat the whole lot.
    function stageShortEscrow(uint256 loanSeed, uint256 depthSeed) external {
        _bump("stageShortEscrow");
        (bool found, uint256 id) = _pickBy(loanSeed, true);
        if (found) _stage(id, depthSeed);
    }

    /// @notice QUARANTINED: stage a live loan short, then settle it at once through the door the seed names.
    /// @dev Without it the fuzzer's own short settles are a lottery: a settle door warps past every loan's expiry, which
    /// @dev shuts `_stage` on all of them, and only an even seed aims a settle at the staged loan. Measured: three seeds'
    /// @dev last sequences staged three loans between them and settled none short; the baseline carried the whole branch.
    /// @dev A pick past its expiry is replaced by a fresh draw: after any settle door's warp, every live loan is one.
    function stageThenSettle(uint256 loanSeed, uint256 depthSeed, uint256 doorSeed) external {
        _bump("stageThenSettle");
        (bool found, uint256 id) = _pickBy(loanSeed, true);
        if (!found || _now() >= read.loan(id).expiry) {
            if (_loanIds.length >= MAX_LOANS) return;
            id = _openIn(_pickMarket(loanSeed), borrowers[doorSeed % 2], bound(loanSeed, 50e6, 8_000e6), 15_000);
            if (id == 0) return;
        }
        uint256 staged = stagedShort;
        _stage(id, depthSeed);
        if (stagedShort == staged) return; // nothing staged: an expired loan, or one already under the target
        uint256 door = read.loan(id).market == norecId ? 1 : doorSeed % 3; // the recordless market settles only by the fold
        if (door == 0) {
            _crash(id);
            _finalize(id);
            _heal();
        } else if (door == 1) {
            _forceClose(id);
        } else {
            _settleExpired(id, false);
        }
    }

    /// @dev `depthSeed % 4`: 0 is one atom short after the paid sliver, 1 one atom short before it, else a free depth.
    function _stage(uint256 id, uint256 depthSeed) internal {
        Loan memory l = read.loan(id);
        if (l.closedAt != 0 || _now() >= l.expiry) return; // the refusals `withdrawCollateral` keeps
        uint256 need = _need(l.market, read.claimOf(l.market, id));
        if (need < 2) return;
        uint256 target = bound(depthSeed, 1, need - 1);
        if (depthSeed % 4 == 0) target = need - 1 + _sliver(l);
        else if (depthSeed % 4 == 1) target = need - 1;
        if (l.collateralUnits <= target) return;
        vm.prank(address(ace));
        pm.release(id, sink, l.collateralUnits - target);
        uint256 slot = uint256(keccak256(abi.encode(id, uint256(Storage.BOOK) + 1))) + 2; // `loans` is LoanBook member 1, units field 2
        vm.store(address(ace), bytes32(slot), bytes32(target));
        if (read.loan(id).collateralUnits != target || pm.collateralOf(id) != target) stagingMisaimed = true;
        stagedShort++;
        lastStaged = id;
        if (depthSeed % 4 < 2) stagedOneAtom++;
    }

    /// @dev The paid doors' keeper sliver, used ONLY to aim a staging; no assertion reads it, so a drift here mis-aims and never blesses.
    function _sliver(Loan memory l) internal view returns (uint256) {
        MarketParams memory p = ace.idToMarketParams(l.market);
        return FullMath.mulDiv(l.debt * p.settleBountyBps, read.marketState(l.market).unitScale, 10000 * p.price);
    }

    function crash(uint256 loanSeed) external {
        _bump("crash");
        (bool found, uint256 id) = _pickSettle(loanSeed);
        if (found) _crash(id);
    }

    function _crash(uint256 id) internal {
        if (read.loan(id).market != recId) return; // the recordless market has no record to crash
        uint256 trig = read.triggerPrice(id);
        if (trig == 0) return;
        record.setBelowBand(trig);
        record.setAbove(false);
    }

    function heal() external {
        _bump("heal");
        _heal();
    }

    function _heal() internal {
        record.setBelowBand(0);
        record.setBelow(false);
        record.setAbove(true);
    }

    // ---- the three settlement doors, each checked against the settle it was ----

    function finalize(uint256 loanSeed) external {
        _bump("finalize");
        (bool found, uint256 id) = _pickSettle(loanSeed);
        if (found) _finalize(id);
    }

    function _finalize(uint256 id) internal {
        Pre memory p = _pre(id, keeper);
        vm.prank(keeper);
        try ace.finalize(id) {
            _post(p, id, 0);
        } catch {}
    }

    function forceClose(uint256 loanSeed) external {
        _bump("forceClose");
        (bool found, uint256 id) = _pickSettle(loanSeed);
        if (found) _forceClose(id);
    }

    function _forceClose(uint256 id) internal {
        Loan memory l = read.loan(id);
        if (l.closedAt != 0) return;
        _warpAtLeastTo(l.expiry);
        _heal(); // the fold judges an armed loan under a healthy print, so only the staging can settle it
        Pre memory p = _pre(id, keeper);
        uint256 n = read.loanCount();
        vm.prank(keeper);
        try ace.forceClose(id) {
            if (read.loanCount() != n) {
                foldRolls++;
                if (_loanIds.length < MAX_LOANS) _loanIds.push(read.loanCount());
                return;
            }
            _post(p, id, 1);
        } catch {}
    }

    /// @notice The unpaid backstop. One call in four is made EARLY, at expiry but inside the loan's roll window.
    /// @dev The early call must refuse: the window is the borrower's roll, and a landing there is latched as code 8.
    function settleExpired(uint256 loanSeed, uint256 timingSeed) external {
        _bump("settleExpired");
        (bool found, uint256 id) = _pickSettle(loanSeed);
        if (found) _settleExpired(id, timingSeed % 4 == 0);
    }

    function _settleExpired(uint256 id, bool early) internal {
        Loan memory l = read.loan(id);
        if (l.closedAt != 0) return;
        uint256 opens = uint256(l.expiry) + MarketInit.autoRefinanceWindow(l.tenor);
        if (early) _warpAtLeastTo(l.expiry);
        else _warpAtLeastTo(opens);
        bool inWindow = _now() < opens;
        Pre memory p = _pre(id, stranger);
        vm.prank(stranger);
        try ace.settleExpired(id) {
            if (inWindow) {
                _latch(8, id, opens, _now());
                return;
            }
            _post(p, id, 2);
        } catch {
            if (inWindow) earlyRefused++;
        }
    }

    function _pre(uint256 id, address caller) internal view returns (Pre memory p) {
        Loan memory l = read.loan(id);
        p.m = l.market;
        p.borrower = l.borrower;
        p.caller = caller;
        p.claim = read.claimOf(l.market, id);
        p.units = l.collateralUnits;
        p.pot = read.invPotOf(l.market, id);
        p.borrowerOwed = read.unitsOwedOf(id, l.borrower);
        p.callerOwed = read.unitsOwedOf(id, caller);
        (, p.lent,) = read.lenderPools(_lenderOf(l.market), address(usdc));
        p.loss = read.marketState(l.market).realizedLossAtBook;
        p.price = ace.idToMarketParams(l.market).price;
    }

    /// @dev Every check reads a MEASURED delta; only the shortfall record's own definition is restated, once.
    function _post(Pre memory p, uint256 id, uint8 path) internal {
        (bool ok, uint256 potIn, uint256 toBorrower) = _postLedgers(p, id);
        if (!ok) return;
        uint256 toCaller = read.unitsOwedOf(id, p.caller) - p.callerOwed;
        if (path == 2 && toCaller != 0) {
            _latch(7, id, 0, toCaller);
            return;
        }
        uint256 need = _need(p.m, p.claim);
        uint256 give = potIn < need ? potIn : need;
        (uint256 su, uint256 sq) = read.shortfallOf(id);
        if (!_postShortfall(p, id, need, give, su, sq)) return;
        if (su != 0 && toBorrower != 0) {
            _latch(6, id, 0, toBorrower);
            return;
        }
        if (su != 0) settlesShort[path]++;
        else settlesCovered[path]++;
        if (potIn > need) forfeits++;
    }

    /// @dev Codes 1-3: the lot is conserved across the three places it can land, the claim retires, `lent` falls by it.
    function _postLedgers(Pre memory p, uint256 id) internal returns (bool ok, uint256 potIn, uint256 toBorrower) {
        potIn = read.invPotOf(p.m, id) - p.pot;
        toBorrower = read.unitsOwedOf(id, p.borrower) - p.borrowerOwed;
        uint256 landed = potIn + toBorrower + (read.unitsOwedOf(id, p.caller) - p.callerOwed);
        if (landed != p.units) {
            _latch(1, id, p.units, landed);
            return (false, potIn, toBorrower);
        }
        if (read.claimOf(p.m, id) != 0) {
            _latch(2, id, 0, read.claimOf(p.m, id));
            return (false, potIn, toBorrower);
        }
        (, uint256 lentNow,) = read.lenderPools(_lenderOf(p.m), address(usdc));
        if (p.lent - lentNow != p.claim) {
            _latch(3, id, p.claim, p.lent - lentNow);
            return (false, potIn, toBorrower);
        }
        ok = true;
    }

    /// @dev Codes 4-5: the record is the atoms the claim did not get and their value at book, and the market total moves with it.
    function _postShortfall(Pre memory p, uint256 id, uint256 need, uint256 give, uint256 su, uint256 sq) internal returns (bool) {
        uint256 covered = (give * p.price) / read.marketState(p.m).unitScale;
        uint256 wantQ = give < need ? p.claim - (covered < p.claim ? covered : p.claim) : 0;
        if (su != need - give) {
            _latch(4, id, need - give, su);
            return false;
        }
        if (sq != wantQ) {
            _latch(4, id, wantQ, sq);
            return false;
        }
        uint256 moved = read.marketState(p.m).realizedLossAtBook - p.loss;
        if (moved != sq) {
            _latch(5, id, sq, moved);
            return false;
        }
        return true;
    }

    function _latch(uint8 code, uint256 id, uint256 expected, uint256 actual) internal {
        if (settleCode != 0) return;
        (settleCode, settleLoanId, settleExpected, settleActual) = (code, id, expected, actual);
    }
}
