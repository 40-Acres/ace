// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.36;

import {AceAskDecimalsHandler} from "./AceAskDecimalsHandler.sol";
import {Loan} from "../../src/ace/hub/Types.sol";
import {MarketInit} from "../../src/ace/hub/MarketInit.sol";
import {AceInventoryLens} from "../../src/ace/lens/AceInventoryLens.sol";

/// @title AceUnsoldPotsHandler
/// @notice The ask-decimals walk with every settle door and every emptying verb, each action measured against the unsold-pot count.
/// @notice THE GHOST IS INDEPENDENT: it walks every loan id the hub has issued and reads each pot raw, never the count or a key derived from it.
/// @dev Every action runs inside `tracked`, which checks the STEP LAW: the count moves by the pots that filled minus the pots that emptied.
/// @dev The transition counters start AFTER the parent's baseline and this constructor, so a nonzero one is the fuzzer's own work.
/// @dev All three markets name one lender and one quote, so every pot here lands in the ONE pair the count keys.
contract AceUnsoldPotsHandler is AceAskDecimalsHandler {
    AceInventoryLens public inv; // the clearing-budget quote, wired once by the suite

    uint256 public potsFilled; // pots taken from empty to nonempty inside a fuzzed action: the count's +1 events
    uint256 public potsEmptied; // pots taken from nonempty to empty inside a fuzzed action: the count's -1 events
    uint256 public pairOpened; // actions that took the pair's count from zero to nonzero
    uint256 public pairCleared; // actions that took it from nonzero back to zero
    uint256 public emptyPotBuys; // buys of a closed loan whose pot was empty, made while another pot was counted
    uint256 public clearingBuys; // buys sized at the lens's clearing budget, or over it
    uint256 public rollsLanded; // armed loans that rolled at expiry rather than settling, found as an untracked successor id
    uint256 public armsLanded;
    uint256 public finalizesLanded;
    uint256 public settleExpiredsLanded;
    uint256 public isolatedMoves; // actions that moved one collateral's split while another's stood nonzero and unchanged

    bool public stepLawBroken; // an action moved the count by other than (pots filled - pots emptied)
    bool public clearingBudgetMissed; // a buy at or over `clearingBudget` left the pot nonempty
    string public stepBreachVerb; // the first breach's verb and its four numbers, for the report
    uint256 public stepBreachBefore;
    uint256 public stepBreachAfter;
    uint256 public stepBreachFilled;
    uint256 public stepBreachEmptied;
    uint256 public missLoan; // the first clearing miss's loan and budget
    uint256 public missBudget;

    mapping(uint256 => bool) internal _listed; // ids already in the parent's loan list

    /// @dev What an action found before it ran: the hub's id counter, the count, the list length and which pots held units.
    struct Snap {
        uint256 n;
        uint256 count;
        uint256 listLen;
        bool[] full;
        uint256[N] lent; // each collateral's split before the action, read through the hub's view
        uint256[N] units;
    }

    /// @notice Subjects for every verb, pre-snapshot: three live loans per market for the settle doors, one clean close for the empty buy.
    constructor() {
        for (uint256 k; k < _loanIds.length; k++) {
            _listed[_loanIds[k]] = true;
        }
        for (uint256 i; i < N; i++) {
            _deposit(i, i == 2 ? 30_000_000e6 : 200_000e6);
            uint256 principal = (_minPrincipal[i] + _maxPrincipal[i]) / 2; // M0's minimum is one unit short of its coverage line's dust atom
            for (uint256 j; j < 3; j++) {
                require(_open(i, principal) != 0, "FIXTURE: a live subject did not open");
            }
            uint256 clean = _open(i, principal);
            require(clean != 0, "FIXTURE: the clean-close subject did not open");
            _repayWhole(clean);
        }
        for (uint256 k; k < _loanIds.length; k++) {
            _listed[_loanIds[k]] = true;
        }
        require(nonEmptyPots() == N, "FIXTURE: the parent's baseline did not leave one unsold pot per market"); // pots only: g owns the count
    }

    /// @notice Wire the clearing-budget lens; once, from the suite's setUp, and never a fuzzed selector.
    function setInventoryLens(AceInventoryLens lens_) external {
        require(address(inv) == address(0), "FIXTURE: the lens is wired once");
        inv = lens_;
    }

    // ---- the ghost ----

    /// @notice The independent count: loans the hub has ever issued whose pot holds units, read raw off storage.
    function nonEmptyPots() public view returns (uint256 c) {
        uint256 n = read.loanCount();
        for (uint256 id = 1; id <= n; id++) {
            if (_potOf(id) != 0) c++;
        }
    }

    /// @dev One id's pot, raw; an order id or a market outside this pair reads zero.
    function _potOf(uint256 id) internal view returns (uint256) {
        bytes32 m = read.loan(id).market;
        if (m == bytes32(0) || _indexOf(m) == N) return 0;
        return read.invPotOf(m, id);
    }

    function _indexOf(bytes32 m) internal view returns (uint256 i) {
        for (; i < N; i++) {
            if (ids[i] == m) return i;
        }
    }

    function _count() internal view returns (uint256 n) {
        (n,) = ace.lenderUnresolved(lender, address(usdc));
    }

    // ---- the per-collateral split's ghosts: each market here is the one market of its collateral ----

    /// @notice Market `i`'s live claims, summed raw over every loan the hub has issued in it.
    function rawLentOf(uint256 i) public view returns (uint256 s) {
        uint256 n = read.loanCount();
        for (uint256 id = 1; id <= n; id++) {
            if (read.loan(id).market == ids[i]) s += read.claimOf(ids[i], id);
        }
    }

    /// @notice Market `i`'s settled pots, summed raw: the collateral atoms its lender holds unsold.
    function rawUnitsOf(uint256 i) public view returns (uint256 s) {
        uint256 n = read.loanCount();
        for (uint256 id = 1; id <= n; id++) {
            if (read.loan(id).market == ids[i]) s += read.invPotOf(ids[i], id);
        }
    }

    /// @notice Collateral `i`'s split, through the hub's guarded view: the subject the ghosts above check.
    function splitOf(uint256 i) public view returns (uint256 lent_, uint256 units) {
        return ace.lenderByCollateral(lender, address(usdc), address(colls[i]));
    }

    // ---- the settled count's ghost: the hub's second word ----

    /// @notice The pair's settled count, read through the hub's guarded two-word view.
    function settledNow() public view returns (uint256 s) {
        (, s) = ace.lenderUnresolved(lender, address(usdc));
    }

    /// @notice The loans this pair has SETTLED, read raw: closed with debt still booked, since a clean close and a roll both zero it.
    /// @dev It counts settlements and reads no pot, so it matches the pots ever filled only while every settlement leaves one.
    function settledLoans() public view returns (uint256 c) {
        uint256 n = read.loanCount();
        for (uint256 id = 1; id <= n; id++) {
            Loan memory l = read.loan(id);
            if (l.market == bytes32(0) || _indexOf(l.market) == N) continue;
            if (l.closedAt != 0 && l.debt != 0) c++;
        }
    }

    // ---- the step law ----

    modifier tracked(string memory verb) {
        Snap memory s = _snap();
        _;
        _step(s, verb);
    }

    function _snap() internal view returns (Snap memory s) {
        s.n = read.loanCount();
        s.count = _count();
        s.listLen = _loanIds.length;
        s.full = new bool[](s.n + 1);
        for (uint256 id = 1; id <= s.n; id++) {
            s.full[id] = _potOf(id) != 0;
        }
        for (uint256 i; i < N; i++) {
            (s.lent[i], s.units[i]) = splitOf(i);
        }
    }

    /// @dev Count an action that moved one collateral's split while another's stood nonzero and unchanged.
    function _latchIsolation(Snap memory s) internal {
        bool moved;
        bool stood;
        for (uint256 i; i < N; i++) {
            (uint256 a, uint256 u) = splitOf(i);
            if (a != s.lent[i] || u != s.units[i]) moved = true;
            else if (a + u != 0) stood = true;
        }
        if (moved && stood) isolatedMoves++;
    }

    /// @dev ADDITION FORM: `after + emptied == before + filled`, so an under-count that saturated at zero still reads as a breach.
    function _step(Snap memory s, string memory verb) internal {
        for (uint256 k = s.listLen; k < _loanIds.length; k++) {
            _listed[_loanIds[k]] = true;
        }
        uint256 n = read.loanCount();
        uint256 filled;
        uint256 emptied;
        for (uint256 id = 1; id <= n; id++) {
            bool was = id <= s.n && s.full[id];
            bool isFull = _potOf(id) != 0;
            if (!was && isFull) filled++;
            if (was && !isFull) emptied++;
            if (id > s.n && !_listed[id]) _adopt(id);
        }
        uint256 c = _count();
        if (c + emptied != s.count + filled && !stepLawBroken) {
            stepLawBroken = true;
            (stepBreachVerb, stepBreachBefore, stepBreachAfter, stepBreachFilled, stepBreachEmptied) = (verb, s.count, c, filled, emptied);
        }
        potsFilled += filled;
        potsEmptied += emptied;
        if (s.count == 0 && c != 0) pairOpened++;
        if (s.count != 0 && c == 0) pairCleared++;
        _latchIsolation(s);
    }

    /// @dev An id the hub issued that no handler verb opened is a roll's successor: track it so the walk can settle it later.
    function _adopt(uint256 id) internal {
        _listed[id] = true;
        Loan memory l = read.loan(id);
        uint256 i = _indexOf(l.market);
        if (i == N) return;
        _loanIds.push(id);
        marketIndexOf[id] = i;
        rollsLanded++;
    }

    // ---- the parent's verbs, tracked ----

    function tOpen(uint256 marketSeed, uint256 principalSeed) external tracked("open") {
        this.open(marketSeed, principalSeed);
    }

    function tWarp(uint256 dtSeed) external tracked("warp") {
        this.warp(dtSeed);
    }

    function tForceClose(uint256 loanSeed) external tracked("forceClose") {
        this.forceClose(loanSeed);
    }

    function tRepay(uint256 loanSeed) external tracked("repay") {
        this.repay(loanSeed);
    }

    function tCollect() external tracked("collect") {
        this.collect();
    }

    function tRedeemInKind(uint256 loanSeed) external tracked("redeemInKind") {
        this.redeemInKind(loanSeed);
    }

    function tBuy(uint256 loanSeed, uint256 atomsSeed, uint256 slackSeed) external tracked("buy") {
        this.buy(loanSeed, atomsSeed, slackSeed);
    }

    // ---- the verbs the parent does not drive ----

    /// @notice A keeper settles a live loan by distress: the record proves the band for this one call, then recovers.
    function tFinalize(uint256 loanSeed) external tracked("finalize") {
        _bump("finalize");
        uint256 loanId = _pick(loanSeed, true);
        if (loanId == 0) return;
        uint256 i = marketIndexOf[loanId];
        records[i].setBelow(true);
        vm.prank(keeper);
        try ace.finalize(loanId) {
            settlesLanded++;
            finalizesLanded++;
        } catch {}
        records[i].setBelow(false);
    }

    /// @notice The unpaid backstop: past expiry and the loan's roll window, anyone settles it, armed or not.
    function tSettleExpired(uint256 loanSeed) external tracked("settleExpired") {
        _bump("settleExpired");
        uint256 loanId = _pick(loanSeed, true);
        if (loanId == 0) return;
        Loan memory l = read.loan(loanId);
        _warpAtLeastTo(uint256(l.expiry) + MarketInit.autoRefinanceWindow(l.tenor));
        vm.prank(keeper);
        try ace.settleExpired(loanId) {
            settlesLanded++;
            settleExpiredsLanded++;
        } catch {}
    }

    /// @notice A stranger clears a pot at the lens's clearing budget, or over it; either must empty the pot.
    function tEmptyWhole(uint256 loanSeed, uint256 modeSeed) external tracked("emptyWhole") {
        _bump("emptyWhole");
        uint256 loanId = _pickPot(loanSeed);
        if (loanId == 0) return;
        bytes32 m = ids[marketIndexOf[loanId]];
        _warpAtLeastTo(read.inventoryAskOpensAt(loanId));
        uint256 budget = inv.clearingBudget(m, loanId);
        if (budget == 0) {
            if (!clearingBudgetMissed) (clearingBudgetMissed, missLoan, missBudget) = (true, loanId, 0); // a priced, ask-on pot must quote
            return;
        }
        if (modeSeed % 2 == 1) budget += bound(modeSeed, 1, budget); // over the quote: the same whole-pot charge, the surplus unspent
        (bool ok,,) = _buyAndCheck(loanId, budget);
        clearingBuys++;
        if ((!ok || read.invPotOf(m, loanId) != 0) && !clearingBudgetMissed) (clearingBudgetMissed, missLoan, missBudget) = (true, loanId, budget);
    }

    /// @notice A buy on a closed loan whose pot is already empty (emptied, clean-closed or rolled): it must take no other pot's count.
    function tBuyEmpty(uint256 loanSeed, uint256 budgetSeed) external tracked("buyEmpty") {
        _bump("buyEmpty");
        uint256 loanId = _pickEmpty(loanSeed);
        if (loanId == 0) return;
        bool counted = _count() != 0;
        (bool ok,,) = _buyAndCheck(loanId, bound(budgetSeed, 1, 1e13));
        if (ok && counted) emptyPotBuys++;
    }

    /// @notice The borrower arms a live loan to roll at expiry, so a later `forceClose` may continue it rather than settle it.
    function tArmRoll(uint256 loanSeed) external tracked("armRoll") {
        _bump("armRoll");
        uint256 loanId = _pick(loanSeed, true);
        if (loanId == 0) return;
        vm.prank(borrower);
        try ace.setAutoRefinance(loanId, read.loan(loanId).tenor, 0, 0) {
            armsLanded++;
        } catch {}
    }

    /// @notice Arm a live loan and crank it at expiry in one step, so the roll branch, which writes no pot, lands in the walk.
    /// @dev `tArmRoll` alone rarely meets a `forceClose` on the same loan at expiry inside one depth-32 sequence.
    function tRollAtExpiry(uint256 loanSeed) external tracked("rollAtExpiry") {
        _bump("rollAtExpiry");
        uint256 loanId = _pick(loanSeed, true);
        if (loanId == 0) return;
        Loan memory l = read.loan(loanId);
        vm.prank(borrower);
        try ace.setAutoRefinance(loanId, l.tenor, 0, 0) {
            armsLanded++;
        } catch {
            return;
        }
        _warpAtLeastTo(l.expiry);
        vm.prank(keeper);
        try ace.forceClose(loanId) {
            settlesLanded++;
        } catch {}
    }

    // ---- shared ----

    /// @dev The first tracked closed loan at or after `seed` whose pot is empty; zero when none is.
    function _pickEmpty(uint256 seed) internal view returns (uint256) {
        uint256 n = _loanIds.length;
        for (uint256 k; k < n; k++) {
            uint256 cand = _loanIds[(seed + k) % n];
            if (read.loan(cand).closedAt != 0 && read.invPotOf(ids[marketIndexOf[cand]], cand) == 0) return cand;
        }
        return 0;
    }

    /// @dev A full repay before expiry: the clean close, which leaves no pot.
    function _repayWhole(uint256 loanId) internal {
        uint256 debt = read.loan(loanId).debt;
        usdc.mint(borrower, debt);
        vm.startPrank(borrower);
        usdc.approve(address(ace), debt);
        ace.repay(loanId, debt);
        vm.stopPrank();
        require(read.loan(loanId).closedAt != 0 && read.invPotOf(ids[marketIndexOf[loanId]], loanId) == 0, "FIXTURE: the clean close left a pot");
    }
}
