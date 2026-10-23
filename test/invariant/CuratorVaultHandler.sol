// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.36;

import {Math} from "@openzeppelin/contracts/utils/math/Math.sol";
import {ERC4626} from "@openzeppelin/contracts/token/ERC20/extensions/ERC4626.sol";
import {CuratorVaultBase} from "../curator/CuratorVaultBase.sol";
import {AceVault, VaultConfig} from "../../src/curator/AceVault.sol";
import {BorrowRequest} from "../../src/curator/AceVaultFlows.sol";
import {CuratorVault} from "../../src/curator/CuratorVault.sol";
import {Loan} from "../../src/ace/hub/Types.sol";

/// @title CuratorVaultHandler
/// @notice The fuzzing surface for ONE production curator vault, holding its cash, and the one market its door lends into.
/// @notice THE EXIT REQUEST IS THE SUBJECT: escrowed shares whose worth the vault holds out of its exitable cash, claimed first come, cancelled, lapsed.
/// @notice FIVE ACTORS and the curator exit at once, request, claim, cancel and lapse; the curator and the guardian move the drain.
/// @dev Every action is bounded and try/catch-guarded, since `fail_on_revert = false` discards a revert.
/// @dev A property that cannot be a view therefore LATCHES here and is asserted by the suite.
/// @dev EVERY LATCH IS THE HANDLER'S, NEVER THE SUITE'S: forge REVERTS the state an `invariant_` function writes.
/// @dev `ghostEscrow` is each holder's request as this handler's own verbs moved it, so the suite checks the vault's book against it.
contract CuratorVaultHandler is CuratorVaultBase {
    uint16 internal constant FEE_BPS = 1000; // a live performance fee, so collections move the supply and the curator requests too
    uint256 internal constant MAX_LOANS = 3; // the O(loans) walks bound on it
    uint256 internal constant SEED_DEPOSIT = 200e6; // per actor, at the rig's 6-dec quote
    uint256 internal constant SEED_DRAW = 850e6; // most of the deposits lent, so a claim is cash-bound and the hold binds
    uint256 internal constant VIRT = 1e6; // the vault's virtual-share offset, which is `10 ** _decimalsOffset()`
    uint64 internal constant LEASE = 30 days; // the vault's REQUEST_LEASE
    uint256 internal constant WHOLE_SALE = 1_000_000e6; // offered to empty a pot; the hub pulls only what the fill takes
    uint256 internal constant RECOVERY_ENTRY = 100e6; // the entry a whole recovery is judged by

    CuratorVault public vault;
    address public guardian = address(0x6A2D);
    address public stranger = address(0x57A1);

    address[5] public actors = [address(0xA01), address(0xA02), address(0xA03), address(0xA04), address(0xA05)];

    uint256[] internal _loanIds;
    mapping(uint256 => bool) internal _knownLoan;
    mapping(uint256 => bool) internal _settled;
    mapping(address => uint256) public ghostEscrow; // each holder's request, as the handler's verbs moved it

    uint256 public requestsStood; // nonzero requests that landed
    uint256 public topUps; // of those, the ones that added to a standing request
    uint256 public renewals; // zero requests that landed, which only renew the lease
    uint256 public cancels; // nonzero cancels that landed
    uint256 public lapseTries; // lapses tried past the lease of a standing request
    uint256 public lapses; // of those, the ones that landed
    uint256 public earlyLapsesRefused; // lapses refused inside the lease
    uint256 public emptyLapsesRefused; // lapses of an empty record refused
    uint256 public claimTries; // claims of exactly a nonzero `maxClaim`
    uint256 public claimsPaid; // claims that landed
    uint256 public claimsRefused; // whole-request claims refused, exitable cash short of them
    uint256 public dipClaims; // claims landing after a settlement and before any other claim, so priced in a trough
    uint256 public exitsPaid; // instant exits that landed
    uint256 public drainedExits; // of those, landed under the drain
    uint256 public drainedClaims; // claims landed under the drain
    uint256 public drainTries; // drain switch-ons tried by a key that holds one
    uint256 public drainsOn;
    uint256 public drainsOff;
    uint256 public heldReads; // actions that ended with standing requests holding exitable cash
    uint256 public loanTries; // door borrows tried with the principal inside `lendable`
    uint256 public loansOpened; // of those, the ones that landed
    uint256 public loanSettles; // loans the fuzzer settled, which is the only fall it drives
    uint256 public salesLanded;
    uint256 public recoveryEntriesJudged; // entries judged at a whole sale's own second, its recovery still vesting
    uint256 public cleanRecoveries; // whole sales leaving no pot unsold, no drain, no water, NAV and shares out: entry must reopen
    uint256 public cleanRecoveriesEntered; // of those, the ones whose own entry a vest window on landed and was judged
    uint256 public lastOuts; // pays that left every exit-capable share gone
    uint256 public shareDonations;
    uint256 public donatedShares; // shares sent TO the vault, which no verb burns: a claim burns its own escrow only
    uint256 public assetDonations;
    uint256 public shuttles; // share balances moved between two actors with no request touched
    uint256 public zeroCalls; // zero-valued verb calls driven
    uint256 public quotesServed; // max asks, instant or claimed, that paid their figure
    uint256 public vaultDoorsRefused;

    bool public quoteReverted; // a max ask reverted on its own view's figure: `withdraw(maxWithdraw)`, `redeem(maxRedeem)`, `claimExit(maxClaim)`
    bytes public quoteRevertData; // and the reason, so a report names the break instead of asserting one happened
    bool public quoteShort; // `withdraw(maxWithdraw)` paid, but not what the view quoted
    address public quoteWho;
    uint256 public quoteAsked;
    uint256 public quotePaid;
    bool public claimPastExitable; // a claim paid more than the exitable cash before it
    bool public claimUnderMin; // a claim landed paying under its own minimum
    bool public heldTakenByAnExit; // an instant exit while lending paid past exitable less what the requests hold
    bool public payUnderRollHold; // an exit or a claim left idle under the roll hold
    bool public drainLeftLendable; // a drain switched on and left anything lendable
    bool public keyBroke; // the drain answered a key wrong: a stranger or the guardian's off landed, or the curator was refused
    bool public lapsedEarly; // a lapse landed inside the lease
    bool public emptyLapseLanded; // a lapse of an empty record landed
    bool public dueLapseRefused; // a lapse past the lease of a standing request was refused
    bool public renewMissed; // a request left the lease other than a full lease from now
    bool public strandBroken; // the last holders out left more behind than the virtual-share offset and the donations
    uint256 public lastOutStrand; // what was left when every exit-capable share last left
    uint256 public lastOutCeiling; // and what those exits could never have paid out
    int256 public worstStrandMargin; // the closest any last pay came to leaving more than it could not take
    bool internal _marginSeen;
    bool public zeroMovedAnOrder; // a zero-valued verb moved a request, a balance or the vault's cash
    bool public vaultDoorOpened; // a door that must refuse the vault's own balance did not
    bool public vaultMovedEscrow; // the escrow moved across one of those calls
    bool public holdsBroke; // after an action the holds did not nest: heldReq <= worth + 1, lendable == exitable - heldReq, 0 draining
    string public holdsTag; // the action that broke them
    bool public entryUnderAPile; // an entry landed while the pile it read sat over the entry line: GATE_BPS of NAV and one asset unit
    uint256 public entryPile; // and the pile and NAV it read, so a report names the break
    uint256 public entryNav;
    bool public entrySeamSplit; // maxDeposit or maxMint disagreed with the verb's outcome
    bool public gapGrew; // the fee-free gap in assets rose past the action's real loss and its rounding allowance
    uint256 public gapRise; // and by how much, against what was allowed, so a report names the break
    uint256 public gapAllowed;
    string public gapTag; // the action that raised it
    bool public verbPanicked; // a vault verb reverted with a panic
    bytes public panicData; // and the panic, so a report names it

    string public lastTag; // the action that just ran

    bool internal _dipPending; // a settlement landed and no claim has paid since
    uint256 internal _preGap; // the fee-free gap in assets before the action
    uint256 internal _pays; // exits and claims the action landed
    uint256 internal _actionLoss; // the real loss the action's settlements wrote off
    uint256 internal _clampForgiven; // the cash the action's pays took past the high-water standing before them
    bool internal _crossedZero; // the action started, passed through or ended at zero supply

    mapping(bytes32 => uint256) public calls;

    /// @dev The state a pay is judged against, read before it.
    struct Pay {
        uint256 exitable; // idle past the roll hold: what a claim may take
        uint256 gross;
        uint256 supply;
        uint256 h; // the fee high-water the pay sees, after its own collection
        bool draining;
    }

    /// @dev Snapshot before the action, weigh every watermark after it.
    modifier watched() {
        (_preGap, _pays, _actionLoss, _clampForgiven) = (_gap(), 0, 0, 0);
        _crossedZero = vault.totalSupply() == 0;
        _;
        _judge();
        _judgeGap();
    }

    constructor() {
        setUp();
        VaultConfig memory c = _cfg(FEE_BPS);
        c.guardian = guardian;
        vault = _deploy(c, "Curator", "cVLT");
        for (uint256 i; i < actors.length; i++) {
            _lpDeposit(vault, actors[i], SEED_DEPOSIT);
        }
        _track(_open(SEED_DRAW));
    }

    /// @notice The exit channels, exercised once pre-snapshot so none of them can be silently inert.
    /// @notice UNGUARDED on purpose: a refusal here must name itself rather than tally as a healthy run.
    /// @dev The request, its hold and its claim stay; the drain and the lapse are proved and rolled back.
    function baselineExits() external {
        address a = actors[0];
        require(_doRequest(a, vault.balanceOf(a) / 2), "BASELINE: the request did not stand");
        (uint256 exitable, uint256 held) = vault.holds();
        require(held != 0, "BASELINE: the request held none of the exitable cash it found -- the hold is inert");
        require(vault.lendable() == exitable - held, "BASELINE: lending reaches the cash the request holds");
        uint256 id = _loanIds[0];
        _repayBy(id, read.loan(id).debt / 4);
        _crankJudged();
        uint256 m = vault.maxClaim(a);
        require(m != 0, "BASELINE: the request can claim nothing");
        vm.prank(a);
        require(vault.claimExit(m, a, 0) != 0, "BASELINE: the claim paid nothing -- the claim channel is inert");
        ghostEscrow[a] -= m; // a direct call, untallied, so the coverage guards count only a run's own claims
        uint256 root = vm.snapshotState();
        vm.prank(curator);
        vault.setDrain(true);
        require(vault.lendable() == 0, "BASELINE: the drain left cash lendable");
        vm.prank(curator);
        vault.setDrain(false);
        uint256 quarter = vault.balanceOf(a) / 4;
        vm.prank(a);
        vault.requestExit(quarter);
        _warpBy(LEASE);
        vm.prank(stranger);
        vault.lapseExit(a);
        (uint256 left,) = vault.requestOf(a);
        require(left == 0, "BASELINE: the lapse did not send the request home");
        vm.revertToState(root);
        _judge();
    }

    /* ============================ the watermarks ============================ */

    /// @dev Every per-step measurement, taken once the action has finished and its state has settled: the holds nest.
    /// @dev The requests hold at most their worth, a wei of rounding over; lending takes exitable less that hold, and nothing while draining.
    function _judge() internal {
        (uint256 exitable, uint256 held) = vault.holds();
        if (held != 0) heldReads++;
        uint256 worth = vault.convertToAssets(vault.requestedShares());
        bool draining = vault.draining();
        bool nested = held <= exitable && exitable <= vault.idle() && held <= worth + 1;
        nested = nested && vault.lendable() == (draining ? 0 : exitable - held) && (!draining || held == 0);
        if (!nested && !holdsBroke) (holdsBroke, holdsTag) = (true, lastTag);
    }

    /// @dev The fee-free gap in assets, `feeHighWater - totalAssets()`, floored at zero: what the curator must earn back first.
    function _gap() internal view returns (uint256) {
        return Math.saturatingSub(vault.feeHighWater(), vault.totalAssets());
    }

    /// @dev THE BOUND THE FEE MARK'S SAFETY RESTS ON: across an action the gap rises by at most the real loss it wrote off.
    /// @dev Plus two atoms a pay for its rounding, and the cash a clamp forgave the curator.
    /// @dev And a CONSTANT two atoms an action, not booked as loss: the hub's position reads round, so an open or a sale moves NAV by a wei.
    /// @dev EXEMPT across zero supply: an empty vault restamps the high-water at NAV, which no flow of cash describes.
    function _judgeGap() internal {
        if (_crossedZero || vault.totalSupply() == 0) return;
        uint256 allowed = _actionLoss + 2 * (_pays + 1) + _clampForgiven;
        uint256 gap = _gap();
        if (gap > _preGap + allowed && !gapGrew) {
            gapGrew = true;
            (gapRise, gapAllowed, gapTag) = (gap - _preGap, allowed, lastTag);
        }
    }

    /// @dev Latch a PANIC out of a verb that must never panic; a custom error is a refusal and stays unlatched.
    function _notePanic(bytes memory err) internal {
        if (err.length < 4 || bytes4(err) != bytes4(0x4e487b71) || verbPanicked) return;
        verbPanicked = true;
        panicData = err;
    }

    /* ============================ the recorded verbs ============================ */

    /// @dev One request; zero only renews. It must renew the whole lease.
    function _doRequest(address who, uint256 shares) internal returns (bool) {
        (uint256 had,) = vault.requestOf(who);
        vm.prank(who);
        try vault.requestExit(shares) {
            ghostEscrow[who] += shares;
            if (shares == 0) {
                renewals++;
            } else {
                requestsStood++;
                if (had != 0) topUps++;
            }
            (, uint64 exp) = vault.requestOf(who);
            if (exp != uint64(vm.getBlockTimestamp()) + LEASE) renewMissed = true;
            return true;
        } catch (bytes memory err) {
            _notePanic(err);
            return false;
        }
    }

    /// @dev The state a pay is judged against: exitable cash, the gross and supply it prices from, and the high-water its own collection leaves.
    function _prePay() internal view returns (Pay memory p) {
        (p.exitable,) = vault.holds();
        (p.gross, p.supply) = (vault.grossNav(), vault.totalSupply());
        p.draining = vault.draining();
        uint256 nav = vault.totalAssets();
        p.h = vault.feeHighWater();
        if (p.supply != 0 && nav > p.h) p.h = nav; // the verb's collection lifts it first
    }

    /// @dev Book a pay: the gap allowance, a clamp the high-water forgave, zero supply, the roll hold, and the last holders out.
    function _notePay(Pay memory p, uint256 paid, uint256 burned) internal {
        _pays++;
        if (paid > p.h) _clampForgiven += paid - p.h;
        if (vault.totalSupply() == 0) _crossedZero = true;
        if (vault.idle() < vault.rollHoldNow()) payUnderRollHold = true;
        if (_allExitCapableSharesGone() && burned != 0) _noteLastOut(p.gross, p.supply);
    }

    /// @dev One claim, recorded: it may never pay past exitable cash or under its minimum.
    function _doClaim(address who, uint256 shares, uint256 minAssets) internal returns (bool ok, uint256 got) {
        Pay memory p = _prePay();
        vm.prank(who);
        try vault.claimExit(shares, who, minAssets) returns (uint256 a) {
            (ok, got) = (true, a);
            ghostEscrow[who] -= shares;
            claimsPaid++;
            if (p.draining) drainedClaims++;
            if (_dipPending) dipClaims++;
            _dipPending = false;
            if (a > p.exitable) claimPastExitable = true;
            if (a < minAssets) claimUnderMin = true;
            _notePay(p, a, shares);
        } catch (bytes memory err) {
            _notePanic(err);
            if (err.length >= 4 && bytes4(err) == ERC4626.ERC4626ExceededMaxRedeem.selector) claimsRefused++;
        }
    }

    /// @dev Judge an instant exit that landed: while lending it leaves the requests' hold standing in exitable cash.
    /// @dev The hold after is the requests' worth then, which the exit's own fee collection may have trimmed, capped by the exitable cash before.
    function _afterExit(Pay memory p, uint256 burned, uint256 paid) internal {
        exitsPaid++;
        if (p.draining) {
            drainedExits++;
        } else {
            (uint256 exitable,) = vault.holds();
            uint256 owed = Math.min(p.exitable, vault.convertToAssets(vault.requestedShares()));
            if (exitable + 2 < owed) heldTakenByAnExit = true;
        }
        _notePay(p, paid, burned);
    }

    /// @dev An instant redeem; `atQuote` makes a revert or a short pay a quote break.
    function _exitByRedeem(address who, uint256 shares, bool atQuote) internal {
        Pay memory p = _prePay();
        vm.prank(who);
        try vault.redeem(shares, who, who) returns (uint256 paid) {
            if (atQuote) quotesServed++;
            _afterExit(p, shares, paid);
        } catch (bytes memory err) {
            if (atQuote) _latchQuoteRevert(who, shares, err);
            _notePanic(err);
        }
    }

    /// @dev Take exactly what `maxWithdraw` promises, and latch a revert or a short payment against it.
    function _exitAtQuote(address who) internal {
        uint256 q = vault.maxWithdraw(who);
        if (q == 0) return;
        uint256 had = usdc.balanceOf(who);
        Pay memory p = _prePay();
        vm.prank(who);
        try vault.withdraw(q, who, who) returns (uint256 shares) {
            quotesServed++;
            uint256 got = usdc.balanceOf(who) - had;
            if (got != q) {
                quoteShort = true;
                (quoteWho, quoteAsked, quotePaid) = (who, q, got);
            }
            _afterExit(p, shares, got);
        } catch (bytes memory err) {
            _latchQuoteRevert(who, q, err);
            _notePanic(err);
        }
    }

    function _latchQuoteRevert(address who, uint256 asked, bytes memory err) internal {
        if (quoteReverted) return;
        quoteReverted = true;
        (quoteWho, quoteAsked, quotePaid) = (who, asked, 0);
        quoteRevertData = err;
    }

    /// @dev Claim exactly `maxClaim`, which must land whenever it is not zero.
    function _claimMax(address who) internal {
        uint256 m = vault.maxClaim(who);
        if (m == 0) return;
        claimTries++;
        Pay memory p = _prePay();
        vm.prank(who);
        try vault.claimExit(m, who, 0) returns (uint256 a) {
            quotesServed++;
            ghostEscrow[who] -= m;
            claimsPaid++;
            if (p.draining) drainedClaims++;
            if (_dipPending) dipClaims++;
            _dipPending = false;
            if (a > p.exitable) claimPastExitable = true;
            _notePay(p, a, m);
        } catch (bytes memory err) {
            _latchQuoteRevert(who, m, err);
            _notePanic(err);
        }
    }

    /* ============================ helpers ============================ */

    /// @dev Advance time by `d`; `WarpClock` re-anchors against the runner's own clock first.
    function _advance(uint256 d) internal {
        _warpBy(d);
    }

    function _bump(string memory tag) internal {
        calls[keccak256(bytes(tag))]++;
        lastTag = tag;
    }

    /// @notice Per-action call count, for the run report.
    function callCount(string memory tag) external view returns (uint256) {
        return calls[keccak256(bytes(tag))];
    }

    function actorCount() external view returns (uint256) {
        return actors.length;
    }

    /// @notice The quote's underlying, so the suite can read the vault's own cash.
    function cash() external view returns (address) {
        return address(usdc);
    }

    /// @notice Every address that can hold a request here: the five actors, the curator, and the vault itself.
    /// @dev THE CURATOR IS NOT OPTIONAL: a live fee mints it shares and the wind-down requests them.
    /// @dev The vault is in the walk to PIN a zero: no request ever stands for it.
    function participantCount() external view returns (uint256) {
        return actors.length + 2;
    }

    function participantAt(uint256 i) public view returns (address) {
        if (i < actors.length) return actors[i];
        return i == actors.length ? curator : address(vault);
    }

    /// @notice Every loan id the fixture and the fuzzer have opened.
    function loanIds() external view returns (uint256[] memory) {
        return _loanIds;
    }

    /// @notice Cash resting in the vault's markets now: its door market, and every market a tracked loan sits in.
    function restingNow() external view returns (uint256 sum) {
        sum = ace.restingOf(mid);
        for (uint256 i; i < _loanIds.length; i++) {
            bytes32 m = ace.loanMarket(_loanIds[i]);
            if (m != mid) sum += ace.restingOf(m);
        }
    }

    function _track(uint256 loanId) internal {
        if (_knownLoan[loanId]) return;
        _knownLoan[loanId] = true;
        _loanIds.push(loanId);
    }

    /// @dev A holder: one of the five actors, or the curator, so its fee shares can be requested and claimed.
    function _holder(uint256 seed) internal view returns (address) {
        return participantAt(seed % (actors.length + 1));
    }

    /// @dev Has every share that CAN leave left? That is the last-holders-out state, and it is NOT a zero supply.
    /// @dev A donated share is unburnable, and a holding too small to price cannot be paid at all.
    function _allExitCapableSharesGone() internal view returns (bool) {
        if (vault.requestedShares() != 0) return false;
        for (uint256 i; i < actors.length + 1; i++) {
            if (vault.convertToAssets(vault.balanceOf(participantAt(i))) != 0) return false;
        }
        return true;
    }

    /// @dev Weigh what the last pay left behind against what no exit could ever have paid.
    /// @dev Dead capital by construction: the virtual offset's slice and the donated shares' slice of the NAV it priced at.
    /// @param preGross The vault's gross NAV before the pay.
    /// @param preSupply The share supply before it.
    function _noteLastOut(uint256 preGross, uint256 preSupply) internal {
        lastOuts++;
        uint256 left = vault.grossNav(); // GROSS, never `totalAssets`: a deferral left standing is stranded too
        uint256 ceiling = Math.mulDiv(preGross, VIRT + donatedShares, preSupply + VIRT, Math.Rounding.Ceil) + actors.length + 3;
        int256 margin = int256(left) - int256(ceiling);
        if (margin > 0) strandBroken = true;
        if (_marginSeen && margin <= worstStrandMargin) return;
        _marginSeen = true;
        worstStrandMargin = margin;
        (lastOutStrand, lastOutCeiling) = (left, ceiling);
    }

    /// @dev Repay `amt` of `loanId` as the rig borrower, who holds every door loan's title; the hub pulls the asset.
    function _repayBy(uint256 loanId, uint256 amt) internal {
        if (amt == 0) return;
        usdc.mint(borrower, amt);
        vm.startPrank(borrower);
        usdc.approve(address(ace), amt);
        try ace.repay(loanId, amt) {} catch {}
        vm.stopPrank();
    }

    /// @dev A crank, a panic out of it latched.
    function _crankJudged() internal {
        try vault.crank() {}
        catch (bytes memory err) {
            _notePanic(err);
        }
    }

    /* ============================ the entry actions ============================ */

    /// @notice An LP joins pro-rata against NAV.
    function depositLp(uint256 actorSeed, uint256 amtSeed) external watched {
        _bump("depositLp");
        address a = actors[actorSeed % actors.length];
        uint256 amt = bound(amtSeed, MIN_DEP, 400e6);
        usdc.mint(a, amt);
        vm.startPrank(a);
        usdc.approve(address(vault), amt);
        (bool open, bool virgin) = (vault.maxDeposit(a) != 0, vault.totalSupply() == 0);
        try vault.deposit(amt, a) {
            _judgeEntry(open, virgin, true, "", amt);
        } catch (bytes memory err) {
            _notePanic(err);
            _judgeEntry(open, virgin, false, err, 0);
        }
        vm.stopPrank();
    }

    /// @notice The other entry door, which rounds the assets UP against the depositor.
    function mintLp(uint256 actorSeed, uint256 shareSeed) external watched {
        _bump("mintLp");
        address a = actors[actorSeed % actors.length];
        uint256 shares = bound(shareSeed, 1, 200e12);
        uint256 cost;
        try vault.previewMint(shares) returns (uint256 c) {
            cost = c;
        } catch {
            return;
        }
        if (cost == 0 || cost > 500e6) return;
        usdc.mint(a, cost);
        vm.startPrank(a);
        usdc.approve(address(vault), cost);
        (bool open, bool virgin) = (vault.maxMint(a) != 0, vault.totalSupply() == 0);
        try vault.mint(shares, a) returns (uint256 paid) {
            _judgeEntry(open, virgin, true, "", paid);
        } catch (bytes memory err) {
            _notePanic(err);
            _judgeEntry(open, virgin, false, err, 0);
        }
        vm.stopPrank();
    }

    /// @dev One entry judged: the max view against the verb's outcome, and the pile the verb read against the entry line.
    /// @dev The verb's NAV is read back as NAV after it less its own cash; the entry stamps no pile, so the pile after is the one it read.
    /// @dev An empty vault admits whatever stands, by rule: a new life takes what nobody holds, so its entry is not judged against the pile.
    function _judgeEntry(bool open, bool virgin, bool ok, bytes memory err, uint256 assets) internal {
        bytes4 sel = err.length >= 4 ? bytes4(err) : bytes4(0);
        bool refused = sel == AceVault.GainVesting.selector || sel == AceVault.EndOfLife.selector || sel == AceVault.InventoryUnsold.selector;
        if ((ok && !open) || (refused && open)) entrySeamSplit = true;
        if (!ok || virgin) return;
        uint256 u = vault.unvested();
        uint256 a = Math.saturatingSub(vault.totalAssets(), assets);
        if (u > vault.VEST_FLOOR() && u * 10_000 > (a + 2) * vault.GATE_BPS() && !entryUnderAPile) {
            entryUnderAPile = true;
            (entryPile, entryNav) = (u, a);
        }
    }

    /* ============================ the exit actions ============================ */

    /// @notice Stand a request, or add to one, as its holder.
    function request(uint256 holderSeed, uint256 shareSeed) external watched {
        _bump("request");
        _request(_holder(holderSeed), shareSeed);
    }

    function _request(address who, uint256 shareSeed) internal returns (bool) {
        uint256 bal = vault.balanceOf(who);
        if (bal == 0) return false;
        return _doRequest(who, bound(shareSeed, 1, bal));
    }

    /// @notice The curator requests every free fee share, which is the wind-down's recurring move.
    function requestFee() external watched {
        _bump("requestFee");
        uint256 free = vault.balanceOf(curator);
        if (free == 0) return;
        _doRequest(curator, free);
    }

    /// @notice A zero request, which renews the lease and moves no escrow.
    function requestZero(uint256 holderSeed) external watched {
        _bump("requestZero");
        address c = _holder(holderSeed);
        zeroCalls++;
        (uint256 s0,) = vault.requestOf(c);
        (uint256 bal, uint256 req) = (vault.balanceOf(c), vault.requestedShares());
        _doRequest(c, 0);
        (uint256 s1,) = vault.requestOf(c);
        if (s1 != s0 || vault.balanceOf(c) != bal || vault.requestedShares() != req) zeroMovedAnOrder = true;
    }

    /// @notice Claim the whole request, which exitable cash may not cover: a shortfall is the vault's refusal, counted.
    function claimAll(uint256 holderSeed) external watched {
        _bump("claimAll");
        address c = _holder(holderSeed);
        uint256 s = ghostEscrow[c];
        if (s == 0) return;
        _doClaim(c, s, 0);
    }

    /// @notice THE CLAIM QUOTE: claim exactly what `maxClaim` just offered.
    function claimMax(uint256 holderSeed) external watched {
        _bump("claimMax");
        _claimMax(_holder(holderSeed));
    }

    /// @notice A claim under a minimum the fuzzer picks, up to twice the offer's worth: it lands at or over it, or refuses.
    function claimWithMin(uint256 holderSeed, uint256 minSeed) external watched {
        _bump("claimWithMin");
        address c = _holder(holderSeed);
        uint256 m = vault.maxClaim(c);
        if (m == 0) return;
        _doClaim(c, m, bound(minSeed, 0, 2 * vault.previewRedeem(m) + 1));
    }

    /// @notice THE WHOLE EXIT IN ONE ACTION: stand a request, then claim what exitable cash covers now.
    function requestAndClaim(uint256 holderSeed, uint256 shareSeed) external watched {
        _bump("requestAndClaim");
        address c = _holder(holderSeed);
        if (!_request(c, shareSeed)) return;
        _claimMax(c);
    }

    /// @notice Cancel part or all of a standing request.
    function cancel(uint256 holderSeed, uint256 shareSeed) external watched {
        _bump("cancel");
        address c = _holder(holderSeed);
        uint256 s = ghostEscrow[c];
        if (s == 0) return;
        uint256 amt = bound(shareSeed, 1, s);
        vm.prank(c);
        try vault.cancelExit(amt) {
            ghostEscrow[c] -= amt;
            cancels++;
        } catch (bytes memory err) {
            _notePanic(err);
        }
    }

    /// @notice A STRANGER LAPSES a standing request at the first second its lease allows: it must land.
    function lapseDue(uint256 holderSeed) external watched {
        _bump("lapseDue");
        address c = _holder(holderSeed);
        (uint256 s, uint64 exp) = vault.requestOf(c);
        if (s == 0) return;
        _warpAtLeastTo(exp);
        lapseTries++;
        vm.prank(stranger);
        try vault.lapseExit(c) {
            ghostEscrow[c] = 0;
            lapses++;
        } catch (bytes memory err) {
            dueLapseRefused = true;
            _notePanic(err);
        }
    }

    /// @notice A stranger tries to lapse early: inside a lease, or on a holder with no request. Both must refuse.
    function lapseEarly(uint256 holderSeed) external watched {
        _bump("lapseEarly");
        address c = _holder(holderSeed);
        (uint256 s, uint64 exp) = vault.requestOf(c);
        if (s != 0 && vm.getBlockTimestamp() >= exp) return;
        vm.prank(stranger);
        try vault.lapseExit(c) {
            if (s == 0) emptyLapseLanded = true;
            else lapsedEarly = true;
        } catch (bytes memory err) {
            _notePanic(err);
            if (s == 0) emptyLapsesRefused++;
            else earlyLapsesRefused++;
        }
    }

    /// @notice An instant redeem of part of a holding.
    function redeemPart(uint256 holderSeed, uint256 shareSeed) external watched {
        _bump("redeemPart");
        address c = _holder(holderSeed);
        uint256 bal = vault.balanceOf(c);
        if (bal == 0) return;
        _exitByRedeem(c, bound(shareSeed, 1, bal), false);
    }

    /// @notice THE INSTANT QUOTE: take exactly what `maxWithdraw` just promised.
    function exitAtQuote(uint256 holderSeed) external watched {
        _bump("exitAtQuote");
        _exitAtQuote(_holder(holderSeed));
    }

    /// @notice The same door measured in shares: spend exactly what `maxRedeem` just promised.
    function redeemAtQuote(uint256 holderSeed) external watched {
        _bump("redeemAtQuote");
        address c = _holder(holderSeed);
        uint256 s = vault.maxRedeem(c);
        if (s == 0) return;
        _exitByRedeem(c, s, true);
    }

    /// @notice The zero-valued doors, which ERC-4626 makes no-ops; a zero claim refuses `ZeroAssets` and moves nothing.
    function claimZero(uint256 holderSeed) external watched {
        _bump("claimZero");
        address c = _holder(holderSeed);
        zeroCalls++;
        (uint256 s0,) = vault.requestOf(c);
        (uint256 bal, uint256 req, uint256 pot) = (vault.balanceOf(c), vault.requestedShares(), vault.idle());
        vm.startPrank(c);
        try vault.redeem(0, c, c) {}
        catch (bytes memory err) {
            _notePanic(err);
        }
        try vault.withdraw(0, c, c) {}
        catch (bytes memory err) {
            _notePanic(err);
        }
        try vault.cancelExit(0) {}
        catch (bytes memory err) {
            _notePanic(err);
        }
        try vault.claimExit(0, c, 0) {}
        catch (bytes memory err) {
            _notePanic(err);
        }
        vm.stopPrank();
        (uint256 s1,) = vault.requestOf(c);
        if (s1 != s0 || vault.balanceOf(c) != bal || vault.requestedShares() != req || vault.idle() != pot) zeroMovedAnOrder = true;
    }

    /// @notice THE WIND-DOWN: every borrower repays, every holder requests, and the claims alone empty the vault.
    /// @dev The loans are repaid FIRST: cash still lent out cannot be paid to anyone until it returns.
    /// @dev The deferral matures first too, so no claim's fee collection mints the curator a share it then has to request.
    /// @dev A request left worth nothing cannot be claimed, so it is cancelled: its shares then price to nothing as a balance.
    function windDown() external watched {
        _bump("windDown");
        for (uint256 i; i < _loanIds.length; i++) {
            Loan memory l = read.loan(_loanIds[i]);
            if (l.closedAt == 0 && l.debt != 0) _repayBy(_loanIds[i], l.debt);
        }
        _crankJudged();
        _advance(VEST_W);
        for (uint256 round; round < 8 && !_allExitCapableSharesGone(); round++) {
            for (uint256 i; i < 6; i++) {
                address a = _drainer(i);
                uint256 bal = vault.balanceOf(a);
                if (bal != 0 && vault.convertToAssets(bal) != 0) _doRequest(a, bal);
            }
            for (uint256 i; i < 6; i++) {
                address a = _drainer(i);
                _claimMax(a);
                _dropDust(a);
            }
        }
    }

    /// @dev The drain walk's actors: the five holders, then the curator its fee shares accrue to.
    function _drainer(uint256 i) internal view returns (address) {
        return i < actors.length ? actors[i] : curator;
    }

    /// @dev Cancel a request that prices to nothing, so the wind-down never waits on a claim that cannot pay.
    function _dropDust(address a) internal {
        uint256 s = ghostEscrow[a];
        if (s == 0 || vault.convertToAssets(s) != 0) return;
        vm.prank(a);
        try vault.cancelExit(s) {
            ghostEscrow[a] = 0;
            cancels++;
        } catch (bytes memory err) {
            _notePanic(err);
        }
    }

    /* ============================ the drain ============================ */

    /// @notice Switch the drain on: the curator on half the seeds, the guardian on a quarter, a stranger on the rest, whom it must refuse.
    function drainOn(uint256 whoSeed) external watched {
        _bump("drainOn");
        uint256 k = whoSeed % 4;
        address by = k < 2 ? curator : (k == 2 ? guardian : stranger);
        if (by != stranger) drainTries++;
        vm.prank(by);
        try vault.setDrain(true) {
            if (by == stranger) {
                keyBroke = true;
                return;
            }
            drainsOn++;
            if (vault.lendable() != 0) drainLeftLendable = true; // exits take all of exitable, first come, and nothing lends
        } catch (bytes memory err) {
            _notePanic(err);
            if (by != stranger) keyBroke = true;
        }
    }

    /// @notice Switch the drain off: the curator on half the seeds, else the guardian or a stranger, whom it must refuse.
    function drainOff(uint256 whoSeed) external watched {
        _bump("drainOff");
        uint256 k = whoSeed % 4;
        address by = k < 2 ? curator : (k == 2 ? guardian : stranger);
        vm.prank(by);
        try vault.setDrain(false) {
            if (by != curator) {
                keyBroke = true;
                return;
            }
            drainsOff++;
        } catch (bytes memory err) {
            _notePanic(err);
            if (by == curator) keyBroke = true;
        }
    }

    /* ============================ the share actions ============================ */

    /// @notice Move FREE shares between two actors in one block, touching nobody's request.
    function shuttleShares(uint256 fromSeed, uint256 toSeed, uint256 amtSeed) external watched {
        _bump("shuttleShares");
        address from = actors[fromSeed % actors.length];
        address to = actors[toSeed % actors.length];
        uint256 bal = vault.balanceOf(from);
        if (bal == 0 || from == to) return;
        vm.prank(from);
        try vault.transfer(to, bound(amtSeed, 1, bal)) {
            shuttles++;
        } catch (bytes memory err) {
            _notePanic(err);
        }
    }

    /// @notice Donate SHARES to the vault, where they are neither escrow nor redeemable by anyone.
    function donateShares(uint256 fromSeed, uint256 amtSeed) external watched {
        _bump("donateShares");
        address from = actors[fromSeed % actors.length];
        uint256 bal = vault.balanceOf(from);
        if (bal == 0) return;
        uint256 amt = bound(amtSeed, 1, bal);
        vm.prank(from);
        try vault.transfer(address(vault), amt) {
            shareDonations++;
            donatedShares += amt;
        } catch (bytes memory err) {
            _notePanic(err);
        }
    }

    /// @notice THE ONE-WEI SHARE DONATION, kept apart from the sized one: a uniform bound lands on one wei with probability ~0.
    function donateOneShare(uint256 fromSeed) external watched {
        _bump("donateOneShare");
        address from = actors[fromSeed % actors.length];
        if (vault.balanceOf(from) == 0) return;
        vm.prank(from);
        try vault.transfer(address(vault), 1) {
            shareDonations++;
            donatedShares += 1;
        } catch (bytes memory err) {
            _notePanic(err);
        }
    }

    /// @notice Donate ASSETS to the vault: a COUNTED donation, which NAV reads and the vest defers like any other rise.
    function donateAssets(uint256 amtSeed) external watched {
        _bump("donateAssets");
        usdc.mint(address(vault), bound(amtSeed, 1, 100e6));
        assetDonations++;
    }

    /* ============================ the door and the market ============================ */

    /// @notice A borrower draws through the vault's door, which is what takes exitable cash out of the vault.
    function openLoan(uint256 drawSeed) external watched {
        _bump("openLoan");
        if (_loanIds.length >= MAX_LOANS) return;
        uint256 principal = bound(drawSeed, 20e6, 300e6);
        if (principal <= vault.lendable()) loanTries++;
        _doorBorrow(principal, false);
    }

    /// @dev One door borrow of `principal` against `COLL`, armed when `arm`; tracked and tallied when it lands, else the refusal is swallowed.
    function _doorBorrow(uint256 principal, bool arm) internal returns (uint256 loanId) {
        collateral.mint(borrower, COLL);
        vm.startPrank(borrower);
        collateral.approve(address(vault), COLL);
        BorrowRequest memory r = _request(address(collateral), COLL, principal);
        r.arm = arm;
        try vault.borrow(r, "", "") returns (uint256 id) {
            loanId = id;
            _track(id);
            loansOpened++;
        } catch (bytes memory err) {
            _notePanic(err);
        }
        collateral.approve(address(vault), 0);
        vm.stopPrank();
    }

    /// @notice A repayment lands: credit the vault collects at a crank, or pays home at the loan's close.
    function repayLoan(uint256 loanSeed, uint256 amtSeed) external watched {
        _bump("repayLoan");
        if (_loanIds.length == 0) return;
        uint256 loanId = _loanIds[loanSeed % _loanIds.length];
        Loan memory l = read.loan(loanId);
        if (l.closedAt != 0 || l.debt == 0) return;
        _repayBy(loanId, bound(amtSeed, 1, l.debt));
    }

    /// @notice A repayment lands, and a holder claims against it on the same draw: first come at the held cash.
    function repayAndClaim(uint256 loanSeed, uint256 amtSeed, uint256 holderSeed) external watched {
        _bump("repayAndClaim");
        if (_loanIds.length == 0) return;
        uint256 loanId = _loanIds[loanSeed % _loanIds.length];
        Loan memory l = read.loan(loanId);
        if (l.closedAt != 0 || l.debt == 0) return;
        _repayBy(loanId, bound(amtSeed, 1, l.debt));
        _claimMax(_holder(holderSeed));
    }

    /// @notice A FALL: one open loan settles, so the requests' worth drops while they stand, and the next claim prices in the trough.
    function settleLoan(uint256 loanSeed) external watched {
        _bump("settleLoan");
        _settle(loanSeed);
    }

    function _settle(uint256 loanSeed) internal {
        if (_loanIds.length == 0) return;
        uint256 loanId = _loanIds[loanSeed % _loanIds.length];
        Loan memory l = read.loan(loanId);
        if (l.closedAt != 0 || l.debt == 0) return;
        uint256 g = vault.grossNav();
        record.setBelow(true);
        vm.prank(keeper);
        try ace.finalize(loanId) {
            _settled[loanId] = true;
            loanSettles++;
            _dipPending = true;
        } catch {}
        record.setBelow(false);
        _actionLoss += Math.saturatingSub(g, vault.grossNav()); // the write-off: the one real loss an action makes
    }

    /// @notice A RECOVERY: some of a settled loan's inventory sells, a vesting rise that goes to whoever holds as it vests.
    function sellInventory(uint256 loanSeed, uint256 amtSeed) external watched {
        _bump("sellInventory");
        if (_loanIds.length == 0) return;
        uint256 loanId = _loanIds[loanSeed % _loanIds.length];
        if (!_settled[loanId]) return;
        uint256 amt = bound(amtSeed, 1e6, 400e6);
        _warpAtLeastTo(read.inventoryAskOpensAt(loanId));
        usdc.mint(keeper, amt);
        vm.startPrank(keeper);
        _approveCash(ace.loanMarket(loanId), amt);
        try ace.buyInventory(loanId, amt, 0, keeper) {
            salesLanded++;
        } catch {}
        vm.stopPrank();
        _crankJudged();
    }

    /// @notice A WHOLE RECOVERY: a settled pot sold out, an entry judged at the sale's own second, then a vest window and one that must land.
    /// @dev The first entry judges the vest gate while the recovery vests; on a clean run the second shows the gates reopen behind it.
    /// @dev Clean: no pot left unsold, no drain, NAV and shares out; the walk's own levers keep it otherwise.
    function sellOutAndEnter(uint256 loanSeed, uint256 actorSeed) external watched {
        _bump("sellOutAndEnter");
        if (_loanIds.length == 0) return;
        uint256 loanId = _loanIds[loanSeed % _loanIds.length];
        if (!_settled[loanId] || read.invPotOf(mid, loanId) == 0) return;
        _warpAtLeastTo(read.inventoryAskOpensAt(loanId));
        usdc.mint(keeper, WHOLE_SALE);
        vm.startPrank(keeper);
        _approveCash(ace.loanMarket(loanId), WHOLE_SALE);
        try ace.buyInventory(loanId, WHOLE_SALE, 0, keeper) {
            salesLanded++;
        } catch {}
        vm.stopPrank();
        _crankJudged();
        if (read.invPotOf(mid, loanId) != 0 || vault.totalSupply() == 0) return;
        address a = actors[actorSeed % actors.length];
        _enterJudged(a);
        recoveryEntriesJudged++;
        (uint256 unsold,) = ace.lenderUnresolved(address(vault), address(usdc));
        if (unsold != 0 || vault.draining() || vault.grossNav() == 0) return;
        cleanRecoveries++;
        _warpBy(vault.VEST_WINDOW());
        if (_enterJudged(a)) cleanRecoveriesEntered++;
    }

    /// @dev One deposit of `RECOVERY_ENTRY` by `a`, judged as `depositLp` judges one; true when it landed on shares already out.
    function _enterJudged(address a) internal returns (bool landed) {
        usdc.mint(a, RECOVERY_ENTRY);
        vm.startPrank(a);
        usdc.approve(address(vault), RECOVERY_ENTRY);
        (bool open, bool virgin) = (vault.maxDeposit(a) != 0, vault.totalSupply() == 0);
        try vault.deposit(RECOVERY_ENTRY, a) {
            _judgeEntry(open, virgin, true, "", RECOVERY_ENTRY);
            landed = !virgin;
        } catch (bytes memory err) {
            _notePanic(err);
            _judgeEntry(open, virgin, false, err, 0);
        }
        vm.stopPrank();
    }

    /// @notice The permissionless sweep, which moves credited quote into the vault's own balance.
    function crank() external watched {
        _bump("crank");
        _crankJudged();
    }

    function collectFee() external watched {
        _bump("collectFee");
        try vault.collectFee() {}
        catch (bytes memory err) {
            _notePanic(err);
        }
    }

    /// @notice A warp of up to a day.
    function warpShort(uint256 dtSeed) external watched {
        _bump("warpShort");
        _advance(bound(dtSeed, 1, 1 days));
    }

    /// @notice A warp of a day up to a lease and a day, so requests lapse inside a run.
    function warpLong(uint256 dtSeed) external watched {
        _bump("warpLong");
        _advance(bound(dtSeed, 1 days, uint256(LEASE) + 1 days));
    }

    /* ============================ the vault's own balance ============================ */

    /// @notice A stranger tries to exit the vault's own balance, which is escrow and donations, and to lapse a request of the vault's.
    /// @dev The exits refuse for want of an allowance the vault never grants; the lapse refuses an empty record.
    function vaultDoors() external watched {
        _bump("vaultDoors");
        address v = address(vault);
        (uint256 held, uint256 req) = (vault.balanceOf(v), vault.requestedShares());
        vm.startPrank(stranger);
        try vault.redeem(1, stranger, v) {
            vaultDoorOpened = true;
        } catch (bytes memory err) {
            vaultDoorsRefused++;
            _notePanic(err);
        }
        try vault.withdraw(1, stranger, v) {
            vaultDoorOpened = true;
        } catch (bytes memory err) {
            vaultDoorsRefused++;
            _notePanic(err);
        }
        try vault.lapseExit(v) {
            vaultDoorOpened = true;
        } catch (bytes memory err) {
            vaultDoorsRefused++;
            _notePanic(err);
        }
        vm.stopPrank();
        if (vault.balanceOf(v) != held || vault.requestedShares() != req) vaultMovedEscrow = true;
    }
}
