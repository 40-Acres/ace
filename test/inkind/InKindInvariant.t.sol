// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.36;

import {ERC4626} from "@openzeppelin/contracts/token/ERC20/extensions/ERC4626.sol";
import {Vm} from "forge-std/Vm.sol";
import {MockERC20} from "../mocks/MockERC20.sol";
import {AceReader} from "../utils/AceReader.sol";
import {VaultLens} from "../utils/VaultLens.sol";
import {Ace} from "../../src/ace/hub/Ace.sol";
import {NoRecord} from "../../src/ace/hub/Settlement.sol";
import {AceVault} from "../../src/vault/AceVault.sol";
import {AceVaultCaps} from "../../src/vault/libraries/AceVaultCaps.sol";
import {BorrowRequest} from "../../src/vault/libraries/AceVaultFlows.sol";
import {IAceVaultLens, IInKindTerms, IInKindVault, Quote} from "./InKindSurface.sol";
import {InKindRig} from "./InKindRig.sol";

/// @notice Drives the vault through deposits, gifts, exits, transfers, requests, loans, settles, collects and claims.
/// @dev Every verb is bounded and wrapped, so a refusal is a skipped step; any collect revert but an early one is a FINDING.
/// @dev So is an entry refused `InventoryUnsold` with no uncollected pot at the hub and no batch the gate could read as open from this block.
/// @dev An open the total refuses is counted, and a refusal while the total still had room for it is a finding too.
contract InKindHandler {
    Vm private constant vm = Vm(address(uint160(uint256(keccak256("hevm cheat code")))));
    bytes32 private constant INKIND_ROOT = 0xd7a5145a3d83b645b4f9f0f6fce92a69c8eed8dbba6d917e62a7d17852ce5100; // erc7201:ace.inkind

    IInKindVault public immutable VAULT;
    Ace public immutable ACE;
    MockERC20 public immutable USDC;
    uint256 private immutable KEY;
    address private constant BORROWER = address(0xB0BA);
    address private constant STRANGER = address(0x5EE);
    uint256 private immutable PRICE;

    address[3] public actors = [address(0xA11CE), address(0xB0B), address(0xCA201)];
    address[2] public toks;
    uint256[] public loans;
    uint256 private _nonce = 1_000_000;

    uint256 public unsoldRefusals; // coverage ghost: entries the unsold-pot gate refused
    uint256 public unsoldUnruled; // entries refused `InventoryUnsold` with nothing for the gate to read: the property
    mapping(address token => uint256) public redeemed; // units the vault's collects measured coming home
    mapping(address token => uint256) public claimed; // units claims paid out
    uint256 public opened; // coverage ghost
    uint256 public redeemedTotal; // coverage ghost
    uint256 public claimedTotal; // coverage ghost
    uint256 public collectUnexpected; // collects that reverted on a closed or expired id, or by any name but NoRecord: the property
    uint256 public collectEarly; // coverage ghost: collects of a live unexpired id, which revert NoRecord by design
    uint256 public feeMinted; // coverage ghost: fee shares the curator's own deposits measured
    uint256 public curatorClaimedTotal; // coverage ghost
    uint256 public overTotal; // coverage ghost: opens the vault-wide total refused, as repeated defaults step it down
    uint256 public overTotalWithRoom; // opens the total refused while it still had room for them: the property
    uint256 public gifted; // shares holders sent straight to the vault, which no holder's tracker counts
    uint256 public claimMispaid; // claims that paid a token other than the lens figure read just before: the property
    uint256 public exitUnruled; // exits and share moves that reverted by anything but a ruled refusal: the property
    bytes4 public lastUnruled; // the selector of the last such revert, to name it when the guard fails
    AceReader private _reader; // built on first use, so the constructor the base campaign calls stays as it was
    IAceVaultLens private _lens; // built on first use, as the reader is

    constructor(IInKindVault v, Ace a, MockERC20 usdc, address t0, address t1, uint256 key, uint256 price) {
        (VAULT, ACE, USDC, KEY, PRICE) = (v, a, usdc, key, price);
        toks = [t0, t1];
    }

    function _bound(uint256 x, uint256 lo, uint256 hi) private pure returns (uint256) {
        if (hi <= lo) return lo;
        return lo + (x % (hi - lo + 1));
    }

    function _actor(uint256 i) private view returns (address) {
        return actors[i % 3];
    }

    function actorCount() external pure returns (uint256) {
        return 3;
    }

    function loanCount() external view returns (uint256) {
        return loans.length;
    }

    function _enter(address payer, address receiver, uint256 amt) private {
        USDC.mint(payer, amt);
        vm.prank(payer);
        USDC.approve(address(VAULT), amt);
        bool gated = _gated();
        vm.prank(payer);
        try VAULT.deposit(amt, receiver) {}
        catch (bytes memory err) {
            _gateRefused(err, gated);
        }
    }

    /// @dev Whether the unsold-pot gate may refuse entry now: the hub counts an uncollected pot, or a batch is open from this block.
    function _gated() private returns (bool) {
        (uint256 unsold,) = ACE.lenderUnresolved(address(VAULT), address(USDC));
        bytes32[] memory s = new bytes32[](1);
        s[0] = bytes32(uint256(INKIND_ROOT) + 6);
        uint256 fb = uint48(uint256(VAULT.extsload(s)[0]) >> 48);
        return unsold != 0 || fb == vm.getBlockNumber();
    }

    /// @dev Count an entry's `InventoryUnsold`, and as a finding when `gated` read nothing the gate could refuse on.
    function _gateRefused(bytes memory err, bool gated) private {
        if (err.length < 4 || bytes4(err) != AceVault.InventoryUnsold.selector) return;
        unsoldRefusals++;
        if (!gated) unsoldUnruled++;
    }

    /// @dev The tracker's views and the vault's stored figures, through one lens built on first use.
    function _view() private returns (IAceVaultLens) {
        if (address(_lens) == address(0)) _lens = VaultLens.deploy();
        return _lens;
    }

    /// @dev The room the vault-wide total leaves now: the total less what is lent and the drawdown.
    function _totalRoom() private returns (uint256) {
        (uint192 cap,) = _view().capOf(address(VAULT), address(VAULT));
        uint256 used = ACE.lenderAssets(address(VAULT), address(USDC)) - ACE.lenderOwed(address(VAULT), address(USDC)) + _view().drawdown(address(VAULT));
        return used >= cap ? 0 : cap - used;
    }

    function deposit(uint256 who, uint256 amt) public {
        address a = _actor(who);
        _enter(a, a, _bound(amt, 1e6, 50_000e6));
    }

    function depositFor(uint256 who, uint256 to, uint256 amt) public {
        _enter(_actor(who), _actor(to), _bound(amt, 1e6, 50_000e6));
    }

    /// @dev Whether `err` is a refusal an exit or a share move is ruled to make: a priced-to-nothing, last-out, over-max or over-request one.
    function _ruledExitRefusal(bytes memory err) private pure returns (bool) {
        if (err.length < 4) return false;
        bytes4 s = bytes4(err);
        return s == AceVault.ZeroAssets.selector || s == AceVault.LastOutVesting.selector || s == AceVault.OverRequest.selector
            || s == AceVault.ClaimUnderMin.selector || s == ERC4626.ERC4626ExceededMaxRedeem.selector || s == ERC4626.ERC4626ExceededMaxWithdraw.selector;
    }

    /// @dev Count a share move's revert that is not a ruled refusal: a regression that reverts an exit leaves state untouched, so only this sees it.
    function _exitRefused(bytes memory err) private {
        if (_ruledExitRefusal(err)) return;
        exitUnruled++;
        lastUnruled = err.length >= 4 ? bytes4(err) : bytes4(0);
    }

    function redeem(uint256 who, uint256 amt) public {
        address a = _actor(who);
        uint256 cap = VAULT.maxRedeem(a);
        if (cap == 0) return;
        vm.prank(a);
        try VAULT.redeem(_bound(amt, 1, cap), a, a) {}
        catch (bytes memory err) {
            _exitRefused(err);
        }
    }

    function transfer(uint256 from, uint256 to, uint256 amt) public {
        (address f, address t) = (_actor(from), _actor(to));
        uint256 bal = VAULT.balanceOf(f);
        if (bal == 0 || f == t) return;
        vm.prank(f);
        try VAULT.transfer(t, _bound(amt, 1, bal)) {}
        catch (bytes memory err) {
            _exitRefused(err);
        }
    }

    /// @dev A holder sends shares straight to the vault, which the tracker books as a burn of the donor's.
    function gift(uint256 who, uint256 amt) public {
        address a = _actor(who);
        uint256 bal = VAULT.balanceOf(a);
        if (bal == 0) return;
        amt = _bound(amt, 1, bal);
        vm.prank(a);
        try VAULT.transfer(address(VAULT), amt) {
            gifted += amt;
        } catch (bytes memory err) {
            _exitRefused(err);
        }
    }

    function request(uint256 who, uint256 amt) public {
        address a = _actor(who);
        uint256 bal = VAULT.balanceOf(a);
        if (bal == 0) return;
        vm.prank(a);
        try VAULT.requestExit(_bound(amt, 1, bal)) {}
        catch (bytes memory err) {
            _exitRefused(err);
        }
    }

    function cancel(uint256 who, uint256 amt) public {
        address a = _actor(who);
        (uint256 r,) = _view().requestOf(address(VAULT), a);
        if (r == 0) return;
        vm.prank(a);
        try VAULT.cancelExit(_bound(amt, 1, r)) {}
        catch (bytes memory err) {
            _exitRefused(err);
        }
    }

    function claimExit(uint256 who, uint256 amt) public {
        address a = _actor(who);
        uint256 cap = VAULT.maxClaim(a);
        if (cap == 0) return;
        vm.prank(a);
        try VAULT.claimExit(_bound(amt, 1, cap), a, 0) {}
        catch (bytes memory err) {
            _exitRefused(err);
        }
    }

    function open(uint256 tok, uint256 principal) public {
        uint256 free = VAULT.lendable();
        if (free < 10e6) return;
        principal = _bound(principal, 10e6, free < 5_000e6 ? free : 5_000e6);
        address c = toks[tok % 2];
        uint64 t = uint64(block.timestamp);
        Quote memory q = Quote({collateral: c, borrower: BORROWER, price: PRICE, maxPrincipal: principal, maxTenor: 14 days, nonce: ++_nonce, issuedAt: t});
        (uint8 v, bytes32 r, bytes32 s) = vm.sign(KEY, IInKindTerms(VAULT.TERMS()).hashQuote(q));
        uint256 units = (principal * 4e12);
        MockERC20(c).mint(BORROWER, units);
        vm.prank(BORROWER);
        MockERC20(c).approve(address(VAULT), units);
        BorrowRequest memory br = BorrowRequest({collateral: c, units: units, principal: principal, tenor: 7 days, minPayout: 0, minBufferWad: 0, deadline: 0});
        uint256 room = _totalRoom();
        vm.prank(BORROWER);
        try VAULT.borrow(br, abi.encode(q, abi.encodePacked(r, s, v)), "") returns (uint256 id) {
            loans.push(id);
            opened++;
        } catch (bytes memory err) {
            if (err.length >= 4 && bytes4(err) == AceVaultCaps.OverTotal.selector) {
                overTotal++;
                if (principal <= room) overTotalWithRoom++;
            }
        }
    }

    function repay(uint256 i) public {
        if (loans.length == 0) return;
        uint256 id = loans[i % loans.length];
        if (ACE.isClosed(id)) return;
        uint256 debt = ACE.debtOf(id);
        USDC.mint(BORROWER, debt);
        vm.prank(BORROWER);
        USDC.approve(address(ACE), debt);
        vm.prank(BORROWER);
        try ACE.repay(id, debt) {} catch {}
    }

    function warp(uint256 secs) public {
        vm.warp(block.timestamp + _bound(secs, 1 hours, 4 days));
        vm.roll(block.number + 1);
    }

    function roll() public {
        vm.roll(block.number + 1);
    }

    function settleByStranger(uint256 i) public {
        if (loans.length == 0) return;
        vm.prank(STRANGER);
        try ACE.forceClose(loans[i % loans.length]) {} catch {}
    }

    function collect(uint256 i) public {
        if (loans.length == 0) return;
        uint256 id = loans[i % loans.length];
        address c = ACE.idToMarketParams(ACE.loanMarket(id)).collateral;
        uint256 b0 = MockERC20(c).balanceOf(address(VAULT));
        uint256[] memory ids = new uint256[](1);
        ids[0] = id;
        if (address(_reader) == address(0)) _reader = new AceReader(address(ACE));
        bool early = !ACE.isClosed(id) && block.timestamp < _reader.loan(id).expiry;
        try VAULT.collectForfeited(ids) {
            uint256 d = MockERC20(c).balanceOf(address(VAULT)) - b0;
            redeemed[c] += d;
            redeemedTotal += d;
        } catch (bytes memory err) {
            if (early && err.length == 4 && bytes4(err) == NoRecord.selector) collectEarly++;
            else collectUnexpected++;
        }
    }

    function claim(uint256 who) public {
        _claimBoth(_actor(who));
    }

    /// @dev `a` claims both tokens, calling again while the lens still shows either owed, at most three calls.
    /// @dev Over those calls each token must pay exactly the lens figure read before the first, or the claim is counted as mispaid (L2's R8).
    function _claimBoth(address a) private returns (uint256 paid) {
        address[] memory t = new address[](2);
        (t[0], t[1]) = (toks[0], toks[1]);
        uint256[2] memory want;
        uint256[2] memory held;
        for (uint256 k; k < 2; k++) {
            (want[k], held[k]) = (_view().claimable(address(VAULT), a, t[k]), MockERC20(t[k]).balanceOf(a));
        }
        for (uint256 n; n < 3; n++) {
            vm.prank(a);
            VAULT.claim(t, a);
            if (_view().claimable(address(VAULT), a, t[0]) + _view().claimable(address(VAULT), a, t[1]) == 0) break;
        }
        for (uint256 k; k < 2; k++) {
            uint256 d = MockERC20(t[k]).balanceOf(a) - held[k];
            if (d != want[k]) claimMispaid++;
            (claimed[t[k]], paid) = (claimed[t[k]] + d, paid + d);
        }
        claimedTotal += paid;
    }

    // ---- the curator's verbs: only the fee campaign targets them, the base campaign's selector list never names them ----

    /// @dev The curator deposits for itself; the fee its entry mints first is measured, and a refusal by the gate is judged as any entry's is.
    function curatorDeposit(uint256 amt) public {
        address cur = VAULT.CURATOR();
        amt = _bound(amt, 1e6, 20_000e6);
        USDC.mint(cur, amt);
        vm.prank(cur);
        USDC.approve(address(VAULT), amt);
        uint256 b0 = VAULT.balanceOf(cur);
        bool gated = _gated();
        vm.prank(cur);
        try VAULT.deposit(amt, cur) returns (uint256 sh) {
            feeMinted += VAULT.balanceOf(cur) - b0 - sh;
        } catch (bytes memory err) {
            _gateRefused(err, gated);
        }
    }

    /// @dev The curator exits some of its own shares, which mints any due fee to it first.
    function curatorRedeem(uint256 amt) public {
        address cur = VAULT.CURATOR();
        uint256 cap = VAULT.maxRedeem(cur);
        if (cap == 0) return;
        vm.prank(cur);
        try VAULT.redeem(_bound(amt, 1, cap), cur, cur) {}
        catch (bytes memory err) {
            _exitRefused(err);
        }
    }

    function curatorClaim() public {
        curatorClaimedTotal += _claimBoth(VAULT.CURATOR());
    }

    /// @dev Cash lands on the vault and is cranked into NAV, so a fee falls due once the rise has vested.
    function gain(uint256 amt) public {
        USDC.mint(address(VAULT), _bound(amt, 1e6, 20_000e6));
        VAULT.crank();
    }

    function collectFee() public {
        vm.prank(STRANGER);
        VAULT.collectFee();
    }

    /// @dev THE FEE CAMPAIGN'S WALK, deterministic: the curator stakes, a gain falls due, its own deposit splits the fee, it is credited and claims.
    function seedFee() external {
        curatorDeposit(10_000e6);
        deposit(0, 40_000e6);
        deposit(1, 30_000e6);
        depositFor(1, 2, 20_000e6);
        gain(5_000e6);
        vm.warp(vm.getBlockTimestamp() + 7 days);
        vm.roll(vm.getBlockNumber() + 1);
        curatorDeposit(5_000e6);
        require(feeMinted > 0, "SEED: the curator's own deposit split a due fee");
        open(0, 2_000e6);
        open(1, 3_000e6);
        require(opened == 2, "SEED: both loans opened");
        vm.warp(vm.getBlockTimestamp() + 7 days);
        vm.roll(vm.getBlockNumber() + 1);
        settleByStranger(0);
        deposit(2, 1_000e6);
        require(unsoldRefusals > 0, "SEED: entry met the gate over an uncollected pot");
        collect(0);
        collect(1);
        require(redeemedTotal > 0, "SEED: a pot came home");
        vm.roll(vm.getBlockNumber() + 1);
        claim(0);
        curatorClaim();
        require(curatorClaimedTotal > 0, "SEED: the curator was credited and claimed");
        open(1, 4_990e6); // the handler's bound maps this to its largest ask, 5,000e6
        require(overTotal == 1 && overTotalWithRoom == 0, "SEED: the total refused an open past its room");
        request(1, 1e15);
        transfer(0, 2, 1e15);
        gift(0, 1e15);
        require(gifted > 0, "SEED: a holder gifted shares to the vault");
    }

    /// @dev WALKS EVERY RAIL ONCE before the campaign, deterministically: forge resets to the post-setUp state each run.
    /// @dev It leaves holders, a gift, a standing request, a gate refusal, credited pots and a claim behind, so no property faces an empty state.
    function seed() external {
        deposit(0, 40_000e6);
        deposit(1, 30_000e6);
        depositFor(1, 2, 20_000e6);
        vm.warp(vm.getBlockTimestamp() + 7 days);
        vm.roll(vm.getBlockNumber() + 1);
        open(0, 2_000e6);
        open(1, 3_000e6);
        require(opened == 2, "SEED: both loans opened");
        deposit(2, 10_000e6);
        vm.warp(vm.getBlockTimestamp() + 7 days);
        vm.roll(vm.getBlockNumber() + 1);
        settleByStranger(0);
        deposit(2, 1_000e6);
        require(unsoldRefusals > 0, "SEED: entry met the gate over an uncollected pot");
        collect(0);
        collect(1);
        require(redeemedTotal > 0, "SEED: a pot came home");
        vm.roll(vm.getBlockNumber() + 1);
        claim(0);
        require(claimedTotal > 0, "SEED: a claim paid");
        open(1, 4_990e6); // the handler's bound maps this to its largest ask, 5,000e6
        require(overTotal == 1 && overTotalWithRoom == 0, "SEED: the total refused an open past its room");
        request(1, 1e15);
        transfer(0, 2, 1e15);
        gift(0, 1e15);
        require(gifted > 0, "SEED: a holder gifted shares to the vault");
    }
}

/// @notice The vault-wide total's properties both campaigns check, on a total sized so repeated defaults step it down and it binds.
abstract contract InKindTotalBounds is InKindRig {
    uint192 internal constant CAMPAIGN_TOTAL = 8_000e6; // the seed's two loans fit, and their defaults leave less room than its third ask

    /// @dev Rule IK's bound: what is lent plus the drawdown never passes the total, which nothing in the campaign raises.
    function _assertLentPlusDrawdownWithinTheTotal() internal view {
        (uint192 cap,) = lens.capOf(address(vault), address(vault));
        uint256 lent = ace.lenderAssets(address(vault), address(usdc)) - ace.lenderOwed(address(vault), address(usdc));
        assertLe(lent + lens.drawdown(address(vault)), cap, "what is lent plus the drawdown passed the vault-wide total");
    }

    // ---- the payout tracker, read raw at its fixed offsets from the root, so these checks need no lens ----

    uint256 internal constant TRACKED_AT = 5; // every holder's tracked balance summed
    uint256 internal constant CLOCK_AT = 6; // uint48 batchCount, uint48 foldBlock
    uint256 internal constant BATCHES_AT = 7; // batch => at | supply << 48
    uint256 internal constant HOLDERS_AT = 8; // holder => tracked-balance checkpoints

    /// @dev Every address the campaign can make a holder of.
    function _holders() internal view virtual returns (address[] memory);

    function _rootAt(uint256 k) internal pure returns (bytes32) {
        return bytes32(uint256(INKIND_ROOT) + k);
    }

    function _trackerClock() internal view returns (uint64 count, uint64 foldBlock) {
        uint256 w = uint256(vm.load(address(vault), _rootAt(CLOCK_AT)));
        (count, foldBlock) = (uint48(w), uint48(w >> 48));
    }

    function _batch(uint256 k) internal view returns (uint256 at, uint256 supply) {
        uint256 w = uint256(vm.load(address(vault), keccak256(abi.encode(k, _rootAt(BATCHES_AT)))));
        (at, supply) = (uint48(w), w >> 48);
    }

    /// @dev The holder's tracked checkpoint at block `blk`, by the same upper lookup a claim makes, read raw.
    function _checkpointAt(address h, uint256 blk) internal view returns (uint256 value) {
        bytes32 base = keccak256(abi.encode(h, _rootAt(HOLDERS_AT)));
        uint256 n = uint256(vm.load(address(vault), base));
        uint256 first = uint256(keccak256(abi.encode(base)));
        (uint256 lo, uint256 hi) = (0, n);
        while (lo < hi) {
            uint256 mid = (lo + hi) / 2;
            if (uint48(uint256(vm.load(address(vault), bytes32(first + mid)))) > blk) hi = mid;
            else lo = mid + 1;
        }
        if (lo != 0) value = uint256(vm.load(address(vault), bytes32(first + lo - 1))) >> 48;
    }

    function _checkpointCount(address h) internal view returns (uint256) {
        return uint256(vm.load(address(vault), keccak256(abi.encode(h, _rootAt(HOLDERS_AT)))));
    }

    /// @dev The tracked supply read raw, and every holder's latest tracked checkpoint summed: the two the tracker must keep equal.
    function _trackedRaw() internal view returns (uint256 supply, uint256 sum) {
        supply = uint256(vm.load(address(vault), _rootAt(TRACKED_AT)));
        address[] memory hs = _holders();
        for (uint256 i; i < hs.length; i++) {
            sum += _checkpointAt(hs[i], block.number);
        }
    }

    /// @dev R10: with no batch waiting, every unit that came home and was not claimed is owed to a holder, to per-payout floor dust.
    /// @dev A payout pays each holder `floor(units * balance / supply)`, under one unit short each, and a token takes at most one payout a batch.
    function _assertEveryUnitThatCameHomeIsOwed(InKindHandler h) internal view {
        (uint64 count, uint64 foldBlock) = _trackerClock();
        if (foldBlock != 0) return;
        address[] memory hs = _holders();
        uint256 dust = hs.length * count; // holders x the most payouts a token can have x one unit of floor dust each
        address[2] memory t = [address(tokA), address(tokB)];
        for (uint256 k; k < 2; k++) {
            uint256 owed;
            for (uint256 i; i < hs.length; i++) {
                owed += _claimable(hs[i], t[k]);
            }
            assertLe(h.redeemed(t[k]) - h.claimed(t[k]) - owed, dust, "R10: a unit that came home is owed to nobody");
        }
    }

    /// @dev V1, LENS-FREE AND EXACT: each closed batch's supply is the sum of the holders' tracked checkpoints at its block, with no touch first.
    function _assertCheckpointsSumToEachClosedBatch() internal view {
        address[] memory hs = _holders();
        (uint64 count, uint64 foldBlock) = _trackerClock();
        for (uint256 k = 1; k <= count; k++) {
            if (k == count && foldBlock != 0) break;
            (uint256 at, uint256 supply) = _batch(k);
            uint256 sum;
            for (uint256 i; i < hs.length; i++) {
                sum += _checkpointAt(hs[i], at);
            }
            assertEq(sum, supply, "V1: a closed batch's supply parted from the holders' checkpoints at its block");
        }
        assertEq(_checkpointCount(address(vault)), 0, "V1: the vault's own address holds no checkpoint");
    }
}

/// forge-config: default.invariant.runs = 64
/// @title InKindInvariant
/// @notice The plan's invariants, each a one-sided bound or a partition read off public views.
contract InKindInvariantTest is InKindTotalBounds {
    InKindHandler internal handler;

    function setUp() public override {
        super.setUp();
        total = CAMPAIGN_TOTAL;
        vault = _deploy(_cfg(0), _ik(), _listings());
        handler = new InKindHandler(vault, ace, usdc, address(tokA), address(tokB), APPRAISER_KEY, PRICE);
        handler.seed();
        bytes4[] memory verbs = new bytes4[](15);
        verbs[0] = InKindHandler.deposit.selector;
        verbs[1] = InKindHandler.depositFor.selector;
        verbs[2] = InKindHandler.redeem.selector;
        verbs[3] = InKindHandler.transfer.selector;
        verbs[4] = InKindHandler.request.selector;
        verbs[5] = InKindHandler.cancel.selector;
        verbs[6] = InKindHandler.claimExit.selector;
        verbs[7] = InKindHandler.open.selector;
        verbs[8] = InKindHandler.repay.selector;
        verbs[9] = InKindHandler.warp.selector;
        verbs[10] = InKindHandler.roll.selector;
        verbs[11] = InKindHandler.settleByStranger.selector;
        verbs[12] = InKindHandler.collect.selector;
        verbs[13] = InKindHandler.claim.selector;
        verbs[14] = InKindHandler.gift.selector;
        targetSelector(FuzzSelector({addr: address(handler), selectors: verbs}));
        targetContract(address(handler));
    }

    /// @dev Every holder's tracked shares cover what it holds plus what it has escrowed in a request: the `>=` half, so a shortfall fails by its own name.
    /// @dev The curator is a holder too: its fee shares and any deposit of its own are tracked like anyone's.
    function invariant_trackedCoversBalanceAndRequest() public view {
        for (uint256 i; i <= handler.actorCount(); i++) {
            address a = i < handler.actorCount() ? handler.actors(i) : curator;
            (uint256 r,) = lens.requestOf(address(vault), a);
            assertGe(_tracked(a), vault.balanceOf(a) + r, "a holder's tracker fell under its balance plus its request");
        }
        assertEq(_tracked(address(vault)), 0, "the vault's own address is never tracked");
    }

    /// @dev EXACT: a gift to the vault leaves its donor's tracker, so a tracker over its balance plus its request is a phantom, as a misfiled burn leaves.
    /// @dev The tracked shares of every holder then sum to the supply less the gifted and seed shares, the escrow counted once, with its requester.
    function invariant_trackedIsExactlyBalancePlusRequest() public view {
        uint256 sum;
        for (uint256 i; i <= handler.actorCount(); i++) {
            address a = i < handler.actorCount() ? handler.actors(i) : curator;
            (uint256 r,) = lens.requestOf(address(vault), a);
            assertEq(_tracked(a), vault.balanceOf(a) + r, "a holder's tracker parted from its balance plus its request");
            sum += _tracked(a);
        }
        assertEq(sum, vault.totalSupply() - handler.gifted() - vault.SEED_SHARES(), "the tracked shares parted from the supply less the gifts and the seed");
    }

    /// @dev A collect reverts only on an id still live and unexpired, and then by `NoRecord`: a closed or expired id yields its pot or zero.
    function invariant_collectRevertsOnlyOnALiveUnexpiredLoan() public view {
        assertEq(handler.collectUnexpected(), 0, "a collect reverted on a closed or expired id, or by another name");
    }

    function invariant_lentPlusDrawdownWithinTheTotal() public view {
        _assertLentPlusDrawdownWithinTheTotal();
    }

    /// @dev The total refuses an open only when the open would pass its room, so the step-down never stops lending it should admit.
    function invariant_theTotalRefusesOnlyPastItsRoom() public view {
        assertEq(handler.overTotalWithRoom(), 0, "the total refused an open it had room for");
    }

    /// @dev The tracked supply is exactly the holders' latest tracked checkpoints, both read raw.
    function invariant_trackedSupplyIsTheSumOfTracked() public view {
        (uint256 supply, uint256 sum) = _trackedRaw();
        assertEq(supply, sum, "the tracked supply and the tracked balances parted");
    }

    /// @dev R8: every claim, over the calls it took, paid each token exactly the lens figure read before its first.
    function invariant_aClaimPaysTheLensFigure() public view {
        assertEq(handler.claimMispaid(), 0, "a claim paid other than the lens figure");
    }

    /// @dev Per token, what is owed never exceeds what came home less what was paid, and the vault holds it all; the curator's dues count too.
    function invariant_owedWithinCreditedLessClaimed() public view {
        address[2] memory t = [address(tokA), address(tokB)];
        for (uint256 k; k < 2; k++) {
            uint256 owed = _claimable(curator, t[k]);
            for (uint256 i; i < handler.actorCount(); i++) {
                owed += _claimable(handler.actors(i), t[k]);
            }
            assertLe(owed, handler.redeemed(t[k]) - handler.claimed(t[k]), "owed past credited less claimed");
            assertGe(MockERC20(t[k]).balanceOf(address(vault)), owed, "the vault cannot pay what it owes");
        }
    }

    /// @dev Entry refuses `InventoryUnsold` only while the hub counts an uncollected pot or a batch is open from this block.
    function invariant_entryRefusesInventoryUnsoldOnlyOnAPotOrAnOpenBatch() public view {
        assertEq(handler.unsoldUnruled(), 0, "a deposit refused InventoryUnsold with no pot uncollected and no batch open from its block");
    }

    function _holders() internal view override returns (address[] memory hs) {
        hs = new address[](handler.actorCount() + 1);
        for (uint256 i; i < handler.actorCount(); i++) {
            hs[i] = handler.actors(i);
        }
        hs[handler.actorCount()] = curator;
    }

    function invariant_everyUnitThatCameHomeIsOwed() public view {
        _assertEveryUnitThatCameHomeIsOwed(handler);
    }

    function invariant_checkpointsSumToEachClosedBatch() public view {
        _assertCheckpointsSumToEachClosedBatch();
    }

    /// @dev THE COVERAGE GUARD: the seed must have reached a loan, a collect, a claim, a refusal by the total and one by the gate, or a property is vacuous.
    /// @dev D1: and no exit or share move reverted by anything but a ruled refusal, which `fail_on_revert = false` would otherwise discard.
    function afterInvariant() public view {
        assertGt(handler.opened(), 0, "GHOST: no loan opened");
        assertGt(handler.redeemedTotal(), 0, "GHOST: no pot came home");
        assertGt(handler.claimedTotal(), 0, "GHOST: no claim paid");
        assertGt(handler.overTotal(), 0, "GHOST: the total never refused an open");
        assertGt(handler.unsoldRefusals(), 0, "GHOST: entry never met the unsold-pot gate");
        assertEq(
            handler.exitUnruled(), 0, string.concat("D1: an exit reverted outside the ruled refusals: ", vm.toString(abi.encodePacked(handler.lastUnruled())))
        );
    }
}

/// forge-config: default.invariant.runs = 64
/// @title InKindFeeInvariant
/// @notice The same properties with a performance fee and a curator that deposits, exits and claims, so its fee shares and dues are never vacuous.
/// @dev The base campaign runs at a zero fee with a curator holding nothing; every curator leg of its properties reads zeros there.
contract InKindFeeInvariantTest is InKindTotalBounds {
    InKindHandler internal handler;

    function setUp() public override {
        super.setUp();
        total = CAMPAIGN_TOTAL;
        vault = _deploy(_cfg(1000), _ik(), _listings());
        handler = new InKindHandler(vault, ace, usdc, address(tokA), address(tokB), APPRAISER_KEY, PRICE);
        handler.seedFee();
        bytes4[] memory verbs = new bytes4[](20);
        verbs[0] = InKindHandler.deposit.selector;
        verbs[1] = InKindHandler.depositFor.selector;
        verbs[2] = InKindHandler.redeem.selector;
        verbs[3] = InKindHandler.transfer.selector;
        verbs[4] = InKindHandler.request.selector;
        verbs[5] = InKindHandler.cancel.selector;
        verbs[6] = InKindHandler.claimExit.selector;
        verbs[7] = InKindHandler.open.selector;
        verbs[8] = InKindHandler.repay.selector;
        verbs[9] = InKindHandler.warp.selector;
        verbs[10] = InKindHandler.roll.selector;
        verbs[11] = InKindHandler.settleByStranger.selector;
        verbs[12] = InKindHandler.collect.selector;
        verbs[13] = InKindHandler.claim.selector;
        verbs[14] = InKindHandler.curatorDeposit.selector;
        verbs[15] = InKindHandler.curatorRedeem.selector;
        verbs[16] = InKindHandler.curatorClaim.selector;
        verbs[17] = InKindHandler.gain.selector;
        verbs[18] = InKindHandler.collectFee.selector;
        verbs[19] = InKindHandler.gift.selector;
        targetSelector(FuzzSelector({addr: address(handler), selectors: verbs}));
        targetContract(address(handler));
    }

    function _holder(uint256 i) internal view returns (address) {
        return i < handler.actorCount() ? handler.actors(i) : curator;
    }

    /// @dev EXACT for every holder, the curator included, and the tracked shares sum to the supply less the seed and what holders gifted the vault.
    function invariant_trackedIsExactlyBalancePlusRequest() public view {
        uint256 sum;
        for (uint256 i; i <= handler.actorCount(); i++) {
            address a = _holder(i);
            (uint256 r,) = lens.requestOf(address(vault), a);
            assertEq(_tracked(a), vault.balanceOf(a) + r, "a holder's tracker parted from its balance plus its request");
            sum += _tracked(a);
        }
        assertEq(sum, vault.totalSupply() - handler.gifted() - vault.SEED_SHARES(), "the tracked shares parted from the supply less the gifts and the seed");
        assertEq(_tracked(address(vault)), 0, "the vault's own address is never tracked");
    }

    function invariant_trackedSupplyIsTheSumOfTracked() public view {
        (uint256 supply, uint256 sum) = _trackedRaw();
        assertEq(supply, sum, "the tracked supply and the tracked balances parted");
    }

    /// @dev R8: every claim, the curator's included, over the calls it took, paid each token exactly the lens figure read before its first.
    function invariant_aClaimPaysTheLensFigure() public view {
        assertEq(handler.claimMispaid(), 0, "a claim paid other than the lens figure");
    }

    /// @dev Per token, every holder's dues, the curator's included, stay within what came home less what was paid, and the vault holds them.
    function invariant_owedWithinCreditedLessClaimed() public view {
        address[2] memory t = [address(tokA), address(tokB)];
        for (uint256 k; k < 2; k++) {
            uint256 owed;
            for (uint256 i; i <= handler.actorCount(); i++) {
                owed += _claimable(_holder(i), t[k]);
            }
            assertLe(owed, handler.redeemed(t[k]) - handler.claimed(t[k]), "owed past credited less claimed");
            assertGe(MockERC20(t[k]).balanceOf(address(vault)), owed, "the vault cannot pay what it owes");
        }
    }

    /// @dev Entry, the curator's own included, refuses `InventoryUnsold` only while the hub counts an uncollected pot or a batch is open from this block.
    function invariant_entryRefusesInventoryUnsoldOnlyOnAPotOrAnOpenBatch() public view {
        assertEq(handler.unsoldUnruled(), 0, "a deposit refused InventoryUnsold with no pot uncollected and no batch open from its block");
    }

    function invariant_collectRevertsOnlyOnALiveUnexpiredLoan() public view {
        assertEq(handler.collectUnexpected(), 0, "a collect reverted on a closed or expired id, or by another name");
    }

    function invariant_lentPlusDrawdownWithinTheTotal() public view {
        _assertLentPlusDrawdownWithinTheTotal();
    }

    /// @dev The total refuses an open only when the open would pass its room.
    function invariant_theTotalRefusesOnlyPastItsRoom() public view {
        assertEq(handler.overTotalWithRoom(), 0, "the total refused an open it had room for");
    }

    function _holders() internal view override returns (address[] memory hs) {
        hs = new address[](handler.actorCount() + 1);
        for (uint256 i; i <= handler.actorCount(); i++) {
            hs[i] = _holder(i);
        }
    }

    function invariant_everyUnitThatCameHomeIsOwed() public view {
        _assertEveryUnitThatCameHomeIsOwed(handler);
    }

    function invariant_checkpointsSumToEachClosedBatch() public view {
        _assertCheckpointsSumToEachClosedBatch();
    }

    /// @dev THE COVERAGE GUARD: a loan, a collect, a claim, a fee split by the curator's own deposit, a curator claim, a refusal by the total and by the gate.
    /// @dev D1: and no exit or share move, the curator's included, reverted by anything but a ruled refusal.
    function afterInvariant() public view {
        assertGt(handler.opened(), 0, "GHOST: no loan opened");
        assertGt(handler.redeemedTotal(), 0, "GHOST: no pot came home");
        assertGt(handler.claimedTotal(), 0, "GHOST: no claim paid");
        assertGt(handler.feeMinted(), 0, "GHOST: no curator deposit split a due fee");
        assertGt(handler.curatorClaimedTotal(), 0, "GHOST: the curator never claimed");
        assertGt(handler.overTotal(), 0, "GHOST: the total never refused an open");
        assertGt(handler.unsoldRefusals(), 0, "GHOST: entry never met the unsold-pot gate");
        assertEq(
            handler.exitUnruled(), 0, string.concat("D1: an exit reverted outside the ruled refusals: ", vm.toString(abi.encodePacked(handler.lastUnruled())))
        );
    }
}
