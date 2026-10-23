// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.36;

import {Math} from "@openzeppelin/contracts/utils/math/Math.sol";
import {CuratorVaultHandler} from "./CuratorVaultHandler.sol";
import {InsufficientCash, RollUnbacked} from "../../src/ace/hub/Borrower.sol";
import {BelowMinLot} from "../../src/ace/hub/Lender.sol";
import {AceVaultFlows} from "../../src/curator/AceVaultFlows.sol";

/// @title CuratorVaultRollHandler
/// @notice The vault campaign's handler PLUS the roll: armed door borrows, the vault's own roll, the holder's retune and disarm, and a stranger's roll.
/// @notice Also a stranger's fold at expiry, the crank that prunes closed records, and the curator's cap.
/// @notice Every inherited action is kept, so the walk is the vault campaign's own with a roll hold standing in it.
/// @dev An extension rather than an edit: the base handler's suite is untouched by these actions, and only new actions live here.
/// @dev Latches live HERE and never in the suite, for the base handler's reason: forge reverts what an `invariant_` writes.
contract CuratorVaultRollHandler is CuratorVaultHandler {
    uint256 public armedOpens; // armed door borrows that landed
    uint256 public retunesLanded; // the holder's same-tenor re-arms that landed
    uint256 public disarmsLanded;
    uint256 public armsUnbacked; // the holder's arms refused `RollUnbacked`: nothing rests, so a disarmed loan never re-arms
    uint256 public armsRefusedOther;
    bytes4 public lastArmRefusal;
    uint256 public holdPeak; // the largest roll hold the vault ever recorded between actions

    uint256 public rollTries; // vault rolls tried on a recorded live loan
    uint256 public rollsInWindow; // of those, tried armed inside the loan's window with the promise standing and the hold whole
    uint256 public rollsRuledOut; // of those, refused `RollNotLendable`: a draw past the record is new lending, ruled refusable
    uint256 public rollsLanded;
    uint256 public lateRollsLanded; // landed after expiry
    uint256 public successorsFunded; // successors recorded with a promise
    uint256 public successorsUnfunded; // recorded without one
    uint256 public successorsUnrecorded; // never recorded: the carry left them disarmed
    uint256 public rollsRefused;
    bytes4 public lastRollRefusal;
    bool public rollStarved; // a promised roll inside its window was refused for cash, wherever idle stood against the roll hold
    uint256 public starvedLoan;
    bytes4 public starvedWhy;
    uint256 public starvedIdle; // idle before the starved roll
    uint256 public starvedHold; // and the roll hold it stood against

    uint256 public strangerRollsLanded;
    uint256 public strangerRollsRefused;
    uint256 public forceClosesLanded; // a stranger's fold at expiry that landed, which settles a vault loan
    uint256 public cranksClosed; // `crank(closed)` calls that landed
    uint256 public emptyBookPrunes; // of those, ones that left no live recorded loan
    bool public holdStuck; // a prune of an empty book left a roll hold standing
    uint256 public capCuts;
    uint256 public capRestores;

    /// @notice One armed door borrow, proved live pre-snapshot, and it STAYS, so every run starts with a roll hold standing.
    /// @dev UNGUARDED, as `baselineExits` is: a refusal here must name itself rather than tally as a healthy run.
    function baselineArm() external {
        uint256 principal = Math.min(100e6, vault.lendable() / 2);
        uint256 loanId = _doorBorrow(principal, true);
        require(loanId != 0, "BASELINE: the armed door borrow did not land -- the arm channel is inert");
        armedOpens++;
        require(ace.restingOf(mid) == 0, "BASELINE: the door left cash resting in its market");
        (uint128 need, bool funded) = vault.rollOf(loanId);
        require(need != 0 && funded, "BASELINE: the armed borrow recorded no promised roll");
        require(vault.rollHold() == need, "BASELINE: the hold is not exactly the one record");
        require(read.reservedOf(loanId) <= need, "BASELINE: the record does not cover the hub's reservation");
        _judge();
        _notePeak();
    }

    /// @notice What the campaign checks parity on: the hub's and the lens's `drawableOf` for one market.
    function drawablePair(bytes32 id) external view returns (uint256 hub, uint256 viaLens) {
        return (ace.drawableOf(id), lens.drawableOf(id));
    }

    /// @notice The vault's door market, for the suite.
    function market() external view returns (bytes32) {
        return mid;
    }

    /// @notice The market's resting cash beside its roll reserve: always no cash between calls, the reserve on paper.
    function restingAndReserve() external view returns (uint256 cash, uint256 rr) {
        return (ace.restingOf(mid), read.rollReserve(mid));
    }

    /// @notice The roll reserve against the sum of the live, armed loans' shares, and whether any other loan holds one.
    /// @return sum The shares of every loan in the market.
    /// @return rr The market's roll reserve.
    /// @return stray Whether a closed or disarmed loan still holds a share.
    function reserveLedger() external view returns (uint256 sum, uint256 rr, bool stray) {
        uint256[] memory ids = ace.marketLoans(mid, 0, ace.marketLoansLength(mid));
        for (uint256 k; k < ids.length; k++) {
            uint256 share = read.reservedOf(ids[k]);
            if (share == 0) continue;
            sum += share;
            (uint64 tenor,,) = read.autoPolicyOf(ids[k]);
            if (read.loan(ids[k]).closedAt != 0 || tenor == 0) stray = true;
        }
        rr = read.rollReserve(mid);
    }

    /// @notice The sum of every tracked loan's recorded need, which the vault's hold must equal exactly.
    function recordSum() external view returns (uint256 sum) {
        for (uint256 i; i < _loanIds.length; i++) {
            (uint128 need,) = vault.rollOf(_loanIds[i]);
            sum += need;
        }
    }

    /// @dev The first live loan at or after `seed`, walking the tracked list; zero when none is live.
    function _liveLoan(uint256 seed, bool armedOnly) internal view returns (uint256) {
        uint256 n = _loanIds.length;
        for (uint256 i; i < n; i++) {
            uint256 cand = _loanIds[(seed + i) % n];
            if (read.loan(cand).closedAt != 0) continue;
            (uint64 t,,) = read.autoPolicyOf(cand);
            if (!armedOnly || t != 0) return cand;
        }
        return 0;
    }

    /// @dev The first live loan at or after `seed` the vault holds a record for; zero when none is.
    function _recordedLive(uint256 seed) internal view returns (uint256) {
        uint256 n = _loanIds.length;
        for (uint256 i; i < n; i++) {
            uint256 cand = _loanIds[(seed + i) % n];
            (uint128 need,) = vault.rollOf(cand);
            if (need != 0 && read.loan(cand).closedAt == 0) return cand;
        }
        return 0;
    }

    function _notePeak() internal {
        uint256 h = vault.rollHold();
        if (h > holdPeak) holdPeak = h;
    }

    /// @notice OPEN AND ARM at the door: one fresh armed loan while fewer than three loans live.
    /// @dev The base `openLoan` stops at three TRACKED loans, closed ones included, so after a wind-down or a few rolls it never lands.
    function openAndArm(uint256 drawSeed) external watched {
        _bump("openAndArm");
        uint256 live;
        for (uint256 i; i < _loanIds.length; i++) {
            if (read.loan(_loanIds[i]).closedAt == 0) live++;
        }
        if (live >= MAX_LOANS) return;
        if (_doorBorrow(bound(drawSeed, 20e6, 300e6), true) != 0) armedOpens++;
        _notePeak();
    }

    /// @notice THE HOLDER'S LEVER: retune a live loan at the market's tenor, or disarm it (one draw in four).
    /// @dev Nothing rests, so a holder re-arms only within a reservation still standing; a disarmed loan's arm is refused `RollUnbacked`.
    function retuneOrDisarm(uint256 loanSeed, uint256 modeSeed) external watched {
        _bump("retuneOrDisarm");
        uint256 loanId = _liveLoan(loanSeed, false);
        if (loanId == 0) return;
        bool disarm = modeSeed % 4 == 0;
        uint64 tenor = disarm ? 0 : ace.idToMarketParams(ace.loanMarket(loanId)).minTenor;
        vm.prank(borrower);
        try ace.setAutoRefinance(loanId, tenor, 0, 0) {
            if (disarm) disarmsLanded++;
            else retunesLanded++;
        } catch (bytes memory err) {
            if (err.length >= 4 && bytes4(err) == RollUnbacked.selector) {
                armsUnbacked++;
            } else {
                armsRefusedOther++;
                lastArmRefusal = err.length >= 4 ? bytes4(err) : bytes4(0);
            }
        }
        _notePeak();
    }

    /// @notice THE VAULT'S ROLL of a recorded live loan: inside its window, or late (one draw in four), by anyone.
    /// @notice Latches a PROMISED roll inside its window refused for cash, whatever idle read: the hub's cash legs, or the dust gap's `BelowMinLot`.
    /// @dev `RollNotLendable` is not latched: a draw past the record is new lending, and its refusal is ruled.
    function rollArmed(uint256 loanSeed, uint256 lateSeed) external watched {
        _bump("rollArmed");
        uint256 loanId = _recordedLive(loanSeed);
        if (loanId == 0) return;
        uint256 exp = read.loan(loanId).expiry;
        bool late = lateSeed % 4 == 0;
        _warpAtLeastTo(late ? exp + 30 minutes : exp - 1 hours);
        rollTries++;
        (, bool funded) = vault.rollOf(loanId);
        (uint64 armedTenor,,) = read.autoPolicyOf(loanId); // a holder's disarm keeps the record but ends the roll
        uint256 nowTs = vm.getBlockTimestamp();
        (uint256 preIdle, uint256 preHold) = (vault.idle(), vault.rollHoldNow());
        bool owed = funded && armedTenor != 0 && nowTs >= exp - 2 hours && nowTs < exp; // the latch reads no idle
        bool counted = owed && preIdle >= preHold; // the coverage guard's count keeps the hold whole
        if (counted) rollsInWindow++;
        vm.prank(stranger);
        try vault.roll(loanId, "") returns (uint256 newId) {
            rollsLanded++;
            if (nowTs >= exp) lateRollsLanded++;
            _track(newId);
            (uint128 need, bool promised) = vault.rollOf(newId);
            if (need == 0) successorsUnrecorded++;
            else if (promised) successorsFunded++;
            else successorsUnfunded++;
        } catch (bytes memory err) {
            _notePanic(err);
            rollsRefused++;
            bytes4 why = err.length >= 4 ? bytes4(err) : bytes4(0);
            lastRollRefusal = why;
            if (counted && why == AceVaultFlows.RollNotLendable.selector) rollsRuledOut++;
            bool cashy = why == InsufficientCash.selector || why == RollUnbacked.selector || why == BelowMinLot.selector;
            if (owed && cashy && !rollStarved) (rollStarved, starvedLoan, starvedWhy, starvedIdle, starvedHold) = (true, loanId, why, preIdle, preHold);
        }
        _notePeak();
    }

    /// @notice A STRANGER'S POLICY ROLL of an armed loan, inside its window: nothing rests, so only a zero-fresh roll can land.
    function strangerRoll(uint256 loanSeed) external watched {
        _bump("strangerRoll");
        uint256 loanId = _liveLoan(loanSeed, true);
        if (loanId == 0) return;
        _warpAtLeastTo(read.loan(loanId).expiry - 1 hours);
        vm.prank(stranger);
        try ace.refinanceByPolicy(loanId) returns (uint256 newId) {
            strangerRollsLanded++;
            _track(newId);
        } catch (bytes memory err) {
            _notePanic(err);
            strangerRollsRefused++;
        }
    }

    /// @notice A STRANGER'S FOLD AT EXPIRY: the hub's paid close settles a vault loan, whose market rests no cash to continue it.
    function forceCloseAtExpiry(uint256 loanSeed) external watched {
        _bump("forceCloseAtExpiry");
        uint256 loanId = _liveLoan(loanSeed, false);
        if (loanId == 0) return;
        _warpAtLeastTo(read.loan(loanId).expiry);
        uint256 g = vault.grossNav();
        vm.prank(stranger);
        try ace.forceClose(loanId) {
            forceClosesLanded++;
            _settled[loanId] = true;
            _dipPending = true;
        } catch (bytes memory err) {
            _notePanic(err);
        }
        _actionLoss += Math.saturatingSub(g, vault.grossNav()); // a settlement's write-off
    }

    /// @notice THE PRUNING CRANK over every tracked loan: closed loans' records leave the hold, live ones stay.
    /// @notice Latches a prune that left no live recorded loan yet a hold standing: an empty book holds nothing.
    function crankClosed() external watched {
        _bump("crankClosed");
        try vault.crank(_loanIds) {
            cranksClosed++;
        } catch (bytes memory err) {
            _notePanic(err);
            return;
        }
        if (_recordedLive(0) != 0) return;
        emptyBookPrunes++;
        if (vault.rollHold() != 0) holdStuck = true;
    }

    /// @notice THE CURATOR'S BRAKE: a cap cut, to zero on one draw in four, by the curator or the guardian; it lands at once.
    function capCut(uint256 modeSeed) external watched {
        _bump("capCut");
        address by = modeSeed % 2 == 0 ? curator : guardian;
        uint192 cap = modeSeed % 4 == 0 ? 0 : uint192(vault.lendable() / 2);
        uint192 standing = vault.rowOf(address(collateral)).cap;
        if (cap >= standing) return;
        vm.prank(by);
        try vault.submitCap(address(collateral), cap) {
            capCuts++;
        } catch (bytes memory err) {
            _notePanic(err);
        }
    }

    /// @notice The cap raised back to unbounded: the curator submits, the timelock passes, and anyone accepts.
    function capRestore() external watched {
        _bump("capRestore");
        if (vault.rowOf(address(collateral)).cap == type(uint192).max) return;
        vm.prank(curator);
        try vault.submitCap(address(collateral), type(uint192).max) {}
        catch (bytes memory err) {
            _notePanic(err);
            return;
        }
        _advance(RIG_TIMELOCK);
        try vault.accept(address(collateral)) {
            capRestores++;
        } catch (bytes memory err) {
            _notePanic(err);
        }
    }
}
