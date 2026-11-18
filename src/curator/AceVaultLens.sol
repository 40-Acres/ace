// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.36;

import {Math} from "@openzeppelin/contracts/utils/math/Math.sol";
import {MarketParams} from "../ace/hub/Types.sol";
import {IAceLenderOps} from "../interfaces/IAceLenderOps.sol";
import {IVaultTerms} from "../interfaces/IVaultTerms.sol";
import {AceVault} from "./AceVault.sol";
import {AceVaultCaps} from "./AceVaultCaps.sol";
import {AceVaultFlows, BorrowRequest, Terms} from "./AceVaultFlows.sol";
import {AceVaultInKind} from "./AceVaultInKind.sol";

/// @title AceVaultLens
/// @notice Read-only views over any AceVault, the vault first in each: the door's preview, the entry gate, the in-kind tracker and its stored figures.
/// @notice It holds no state and no authority, so a new lens can replace this one at any time.
/// @dev `previewTerms` and `roomOf` run the door's own library helpers on the vault's figures, so neither can drift from the door.
/// @dev The tracker views and stored figures read the `ace.inkind` and `ace.curatorvault` words by `extsload`, at offsets that must match their layouts.
contract AceVaultLens {
    bytes32 private constant TRACKER = AceVaultInKind.ROOT; // the in-kind tracker's namespace
    bytes32 private constant STORE = AceVaultFlows.ROOT; // the vault's own namespace
    uint256 private constant TOKENS = 4; // every token a payout carried
    uint256 private constant TRACKED_SUPPLY = 5;
    uint256 private constant CLOCK = 6; // uint48 batchCount, uint48 foldBlock
    uint256 private constant BATCHES = 7; // batch => (block | supply << 48)
    uint256 private constant HOLDERS = 8; // holder => its tracked balance's checkpoints, their count at the base slot
    uint256 private constant CURSOR = 9; // holder => token => next payout, then at bit 128 the checkpoint index its walk reads
    uint256 private constant PAYOUTS = 10; // token => [(batch | units << 48)]
    uint256 private constant CHUNK = 64; // payout words `claimable` reads in one `extsload`, their batch words in a second
    uint256 private constant WINDOW = 4; // checkpoint words one `extsload` reads from the index a walk needs

    /// @dev One holder's standing as a claim would read it.
    struct View {
        bytes32 trace; // the checkpoints' first element slot
        uint256 count; // checkpoints
        uint256 supplyNow; // the tracked supply a waiting batch would close on, zero if it cannot close now
    }

    /// @dev One `claimable` walk: its payout list, the next payout and checkpoint, the credit so far, and the checkpoint words last read.
    struct Walk {
        bytes32 base; // the payout list's first element slot
        uint256 n; // payouts
        uint256 i;
        uint256 j;
        uint256 amt;
        bool open; // stopped at a batch that cannot close now
        uint256 from; // the checkpoint index `words` starts at
        bytes32[] words;
    }

    /// @notice The market a `borrow` by `borrower` on `vault` with this request and payload would land in, and the draw.
    /// @notice It refuses as the door's checks on the product's answer and on its market would; `borrow` may still refuse on the drain, room, cash or the hub.
    /// @return id The market id, which the door creates if missing.
    /// @return mp The market's parameters.
    /// @return t The draw the product admits, its buffer the larger of the ask's and the product's.
    function previewTerms(AceVault vault, address borrower, BorrowRequest calldata r, bytes calldata data)
        external
        view
        returns (bytes32 id, MarketParams memory mp, Terms memory t)
    {
        (mp, t) = IVaultTerms(vault.TERMS()).borrowTerms(borrower, r, data);
        t = AceVaultCaps.admit(r, mp, t, AceVaultCaps.hubAsk(vault.IN_KIND(), vault.DOOR()), vault.MIN_TENOR(), vault.MAX_TENOR());
        AceVaultFlows.checkMarket(mp, vault.asset(), address(vault));
        id = keccak256(abi.encode(mp));
    }

    /// @notice Everything `holder` is owed of `token` on `vault` now: every payout from its cursor, a batch that would close now included.
    /// @notice A claim may pay only part of it within its budget; the exact one-call preview is an `eth_call` of `claim(tokens, holder)` from the holder.
    function claimable(AceVault vault, address holder, address token) external view returns (uint256 amt) {
        View memory v = _view(vault, holder);
        bytes32 p = _slot(uint160(token), TRACKER, PAYOUTS);
        bytes32[] memory s = new bytes32[](2);
        (s[0], s[1]) = (keccak256(abi.encode(token, _slot(uint160(holder), TRACKER, CURSOR))), p);
        bytes32[] memory w = vault.extsload(s);
        uint256 c = uint256(w[0]);
        Walk memory k;
        (k.base, k.n, k.i, k.j) = (keccak256(abi.encode(p)), uint256(w[1]), uint128(c), c >> 128);
        if (c == 0) k.i = _firstEligible(vault, v, k.base, k.n);
        while (k.i < k.n && !k.open) {
            _chunk(vault, v, k);
        }
        amt = k.amt;
    }

    /// @dev Credit the next `CHUNK` payouts of the walk, their words and their batches each read in one call; stop at a batch that cannot close.
    function _chunk(AceVault vault, View memory v, Walk memory k) private view {
        uint256 m = k.n - k.i < CHUNK ? k.n - k.i : CHUNK;
        bytes32[] memory s = new bytes32[](m);
        for (uint256 x; x < m; ++x) {
            s[x] = _plus(k.base, k.i + x);
        }
        bytes32[] memory pw = vault.extsload(s);
        for (uint256 x; x < m; ++x) {
            s[x] = _slot(uint48(uint256(pw[x])), TRACKER, BATCHES);
        }
        bytes32[] memory bw = vault.extsload(s);
        for (uint256 x; x < m; ++x) {
            uint256 supply = uint256(bw[x]) >> 48;
            if (supply == 0) supply = v.supplyNow;
            if (supply == 0) {
                k.open = true;
                return;
            }
            uint256 e = _eligible(vault, v, k, uint48(uint256(bw[x])));
            if (e != 0) k.amt += AceVaultInKind.credit(uint256(pw[x]) >> 48, e, supply);
            ++k.i;
        }
    }

    /// @notice How many of `token`'s payouts `holder` has not yet walked on `vault`, at most: a claim's list should name only tokens with some.
    function unclaimedPayouts(AceVault vault, address holder, address token) external view returns (uint256) {
        bytes32[] memory s = new bytes32[](2);
        (s[0], s[1]) = (keccak256(abi.encode(token, _slot(uint160(holder), TRACKER, CURSOR))), _slot(uint160(token), TRACKER, PAYOUTS));
        bytes32[] memory w = vault.extsload(s);
        return uint256(w[1]) - uint128(uint256(w[0]));
    }

    /// @dev The batch a payout word names, its block and supply; an open batch reads the supply it would close on now, zero if it cannot.
    function _batchOf(AceVault vault, View memory v, uint256 pw) private view returns (uint256 at, uint256 supply) {
        uint256 bw = _word(vault, _slot(uint48(pw), TRACKER, BATCHES));
        (at, supply) = (uint48(bw), bw >> 48);
        if (supply == 0) supply = v.supplyNow;
    }

    /// @dev The library's search for a claim from cursor zero, over the stored words.
    function _firstEligible(AceVault vault, View memory v, bytes32 base, uint256 n) private view returns (uint256 lo) {
        uint256 key = v.count != 0 ? uint48(_word(vault, v.trace)) : type(uint256).max;
        uint256 hi = n;
        while (lo < hi) {
            uint256 mid = (lo + hi) / 2;
            (uint256 at, uint256 supply) = _batchOf(vault, v, _word(vault, bytes32(uint256(base) + mid)));
            if (AceVaultInKind.readBefore(at, supply, key)) lo = mid + 1;
            else hi = mid;
        }
    }

    /// @notice `holder`'s tracked shares on `vault`: its shares plus its escrow, as stored.
    function trackedOf(AceVault vault, address holder) external view returns (uint256) {
        bytes32 h = _slot(uint160(holder), TRACKER, HOLDERS);
        uint256 count = _word(vault, h);
        return count == 0 ? 0 : _word(vault, _plus(keccak256(abi.encode(h)), count - 1)) >> 48;
    }

    /// @notice The shares a batch closing now would count on `vault`: every holder's balance and escrow, never shares gifted to the vault.
    function trackedSupply(AceVault vault) external view returns (uint256) {
        return _word(vault, _at(TRACKER, TRACKED_SUPPLY));
    }

    /// @notice Every token a payout on `vault` has carried, in the order of its first.
    function rewardTokens(AceVault vault) external view returns (address[] memory tokens) {
        uint256 n = _word(vault, _at(TRACKER, TOKENS));
        bytes32[] memory s = new bytes32[](n);
        bytes32 base = keccak256(abi.encode(_at(TRACKER, TOKENS)));
        for (uint256 i; i < n; ++i) {
            s[i] = _plus(base, i);
        }
        bytes32[] memory w = vault.extsload(s);
        tokens = new address[](n);
        for (uint256 i; i < n; ++i) {
            tokens[i] = address(uint160(uint256(w[i])));
        }
    }

    /// @dev The holder's checkpoints, and the supply a waiting batch would close on.
    function _view(AceVault vault, address holder) private view returns (View memory v) {
        bytes32 h = _slot(uint160(holder), TRACKER, HOLDERS);
        bytes32[] memory s = new bytes32[](3);
        (s[0], s[1], s[2]) = (h, _at(TRACKER, CLOCK), _at(TRACKER, TRACKED_SUPPLY));
        bytes32[] memory w = vault.extsload(s);
        (v.trace, v.count) = (keccak256(abi.encode(h)), uint256(w[0]));
        uint256 fb = uint48(uint256(w[1]) >> 48);
        uint256 ts = uint256(w[2]);
        if (fb != 0 && fb < block.number && ts != 0) v.supplyNow = ts;
    }

    /// @dev The holder's tracked balance at block `t`, `k.j` moved to its checkpoint in the claim's own probe order, so the walk costs what the claim's does.
    function _eligible(AceVault vault, View memory v, Walk memory k, uint256 t) private view returns (uint256 e) {
        if (v.count == 0) return 0;
        (uint256 j, uint256 hi, uint256 probes) = (k.j, v.count, 0);
        uint256 cur = _checkpoint(vault, v, k, j);
        for (uint256 x = j + 1; x < hi; x = AceVaultInKind.probeAfter(j, probes)) {
            uint256 cw = _checkpoint(vault, v, k, x);
            if (uint48(cw) > t) {
                hi = x;
                break;
            }
            (j, cur, probes) = (x, cw, probes + 1);
        }
        while (j + 1 < hi) {
            uint256 mid = (j + hi) / 2;
            uint256 cw = _checkpoint(vault, v, k, mid);
            if (uint48(cw) > t) hi = mid;
            else (j, cur) = (mid, cw);
        }
        if (uint48(cur) <= t) e = cur >> 48;
        k.j = j;
    }

    /// @dev The holder's stored checkpoint word `idx`: from the words last read, else read with the next `WINDOW` past it in one call.
    function _checkpoint(AceVault vault, View memory v, Walk memory k, uint256 idx) private view returns (uint256) {
        if (idx >= k.from && idx < k.from + k.words.length) return uint256(k.words[idx - k.from]);
        uint256 m = v.count - idx < WINDOW ? v.count - idx : WINDOW;
        bytes32[] memory s = new bytes32[](m);
        for (uint256 x; x < m; ++x) {
            s[x] = _plus(v.trace, idx + x);
        }
        (k.from, k.words) = (idx, vault.extsload(s));
        return uint256(k.words[0]);
    }

    /// @dev One raw word of `vault`.
    function _word(AceVault vault, bytes32 slot) private view returns (uint256) {
        bytes32[] memory s = new bytes32[](1);
        s[0] = slot;
        return uint256(vault.extsload(s)[0]);
    }

    /// @dev The member at offset `k` from a namespace `root`: the tracker's or the vault's.
    function _at(bytes32 root, uint256 k) private pure returns (bytes32) {
        return bytes32(uint256(root) + k);
    }

    /// @dev The word `key` maps to in the mapping at offset `k` from `root`; an address key is passed as its 160-bit number, which encodes alike.
    function _slot(uint256 key, bytes32 root, uint256 k) private pure returns (bytes32) {
        return keccak256(abi.encode(key, _at(root, k)));
    }

    /// @dev The word `i` slots past `s`.
    function _plus(bytes32 s, uint256 i) private pure returns (bytes32) {
        return bytes32(uint256(s) + i);
    }

    // ---- the vault's stored figures, at fixed offsets from `ace.curatorvault` ----

    uint256 private constant NAV_MARK = 1; // gross NAV at the last sync
    uint256 private constant VEST = 2; // basis | maturity << 128 | draining << 192 | troughHold << 200
    uint256 private constant REQUESTED = 3; // escrowed shares of every standing request
    uint256 private constant EXEMPT_SETTLED = 5;
    uint256 private constant REQUESTS = 4; // holder => (shares, expiresAt)
    uint256 private constant CAPS = 6; // key => cap | listed << 192
    uint256 private constant PENDING_CAPS = 7; // key => (cap | listed << 192, validAt)
    uint256 private constant NAV_HIGH = 8;
    uint256 private constant SEIZED = 9; // collateral => value | writeOffAt << 184 | open << 248
    uint256 private constant OPEN_SEIZED = 10;

    /// @notice Escrowed shares of every standing request on `vault`.
    function requestedShares(AceVault vault) external view returns (uint256) {
        return _word(vault, _at(STORE, REQUESTED));
    }

    /// @notice `holder`'s standing request on `vault`: its escrowed shares, and when anyone may lapse it.
    function requestOf(AceVault vault, address holder) external view returns (uint256 shares, uint64 expiresAt) {
        bytes32 r = _slot(uint160(holder), STORE, REQUESTS);
        bytes32[] memory w = vault.extsload(_two(r, _plus(r, 1)));
        return (uint256(w[0]), uint64(uint256(w[1])));
    }

    /// @notice A key's cap on `vault` as stored: a collateral's row and whether it is listed; the wildcard at `address(0)`, the total at the vault.
    function capOf(AceVault vault, address key) external view returns (uint192 cap, bool listed) {
        return _cap(_word(vault, _slot(uint160(key), STORE, CAPS)));
    }

    /// @notice A key's pending change on `vault` and when anyone may accept it; a zero `validAt` is none.
    function pendingCapOf(AceVault vault, address key) external view returns (uint192 cap, bool listed, uint64 validAt) {
        bytes32 p = _slot(uint160(key), STORE, PENDING_CAPS);
        bytes32[] memory w = vault.extsload(_two(p, _plus(p, 1)));
        (cap, listed) = _cap(uint256(w[0]));
        validAt = uint64(uint256(w[1]));
    }

    /// @notice Gross NAV's high-water on `vault` as a sync now would leave it: lifted by a new high, raised by entries, lowered by exits and claims.
    function navHigh(AceVault vault) external view returns (uint256) {
        return Math.max(_word(vault, _at(STORE, NAV_HIGH)), vault.grossNav());
    }

    /// @notice How far `vault`'s gross NAV sits below its high-water: losses not yet earned back, which hold room under the total.
    function drawdown(AceVault vault) public view returns (uint256) {
        return Math.saturatingSub(_word(vault, _at(STORE, NAV_HIGH)), vault.grossNav());
    }

    /// @notice `vault`'s idle, and the part of it the standing requests hold at their worth now; they hold nothing while it drains.
    /// @return exitable What a claim may take.
    /// @return heldReq What instant exits and placements leave for the requests.
    function holds(AceVault vault) external view returns (uint256 exitable, uint256 heldReq) {
        exitable = vault.idle();
        if (vault.draining()) return (exitable, 0);
        heldReq = Math.min(exitable, vault.previewRedeem(_word(vault, _at(STORE, REQUESTED))));
    }

    /// @notice The room a new placement against `collateral` has on `vault` now, under its row and the total; a product's own room may only lower it.
    function roomOf(AceVault vault, address collateral) external view returns (uint256) {
        IAceLenderOps hub = IAceLenderOps(vault.ACE());
        bytes32[] memory w = vault.extsload(_two(_slot(uint160(collateral), STORE, SEIZED), _slot(uint160(address(vault)), STORE, CAPS)));
        (uint256 lent,) = hub.lenderByCollateral(address(vault), vault.asset(), collateral);
        uint256 row = AceVaultCaps.rowRoom(vault.effectiveCap(collateral), lent, uint184(uint256(w[0])));
        return Math.min(row, _totalRoom(vault, hub, uint192(uint256(w[1]))));
    }

    /// @notice A door-mode `vault`'s ledger for `collateral`: the value its goods still hold, whether it shuts entry, and a pending write-off.
    /// @return value The booked value less cash returned; it holds the collateral's row room, never NAV.
    /// @return open Whether the key shuts entry.
    /// @return writeOffAt A pending write-off's due time; zero is none.
    function seizedOf(AceVault vault, address collateral) external view returns (uint256 value, bool open, uint64 writeOffAt) {
        uint256 w = _word(vault, _slot(uint160(collateral), STORE, SEIZED));
        return (uint184(w), (w >> 248) & 1 != 0, uint64(w >> 184));
    }

    /// @notice The keys still open on a door-mode `vault`, each shutting entry.
    function openSeized(AceVault vault) external view returns (uint256) {
        return _word(vault, _at(STORE, OPEN_SEIZED));
    }

    /// @notice `vault`'s trough hold as stored: zero none, all ones marked over an unsold pot, else the second it lifts by at the latest.
    function troughHoldOf(AceVault vault) public view returns (uint48) {
        return uint48(_word(vault, _at(STORE, VEST)) >> 200);
    }

    /// @notice Why entry on `vault` is shut, zero when open: the vault's own gate in its order, then `Draining` and in kind `OverSupply`, the lens's names.
    /// @notice `until` is the second a gain's vest or a hold lifts by, as the next sync leaves it, zero where unknowable; a product's own cap is not read.
    function entryGate(AceVault vault) external view returns (bytes4 reason, uint256 until) {
        uint256 g = vault.grossNav();
        uint256 a = vault.totalAssets();
        uint256 u = g - a; // the pile the next sync would leave
        bool live = vault.totalSupply() > vault.SEED_SHARES();
        uint256 w = _word(vault, _at(STORE, VEST));
        if (live && a == 0) return (AceVault.EndOfLife.selector, 0);
        if (live && AceVaultFlows.gainVesting(u, a, vault.VEST_FLOOR())) return (AceVault.GainVesting.selector, _nextMaturity(vault, g, w));
        if (_unsold(vault)) return (AceVault.InventoryUnsold.selector, 0);
        uint48 t = uint48(w >> 200);
        if (AceVaultFlows.material(u, g) && block.timestamp < t) {
            return (AceVault.RecoveryVesting.selector, t == type(uint48).max ? _nextMaturity(vault, g, w) : t);
        }
        if (vault.draining()) return (AceVault.Draining.selector, 0);
        if (vault.IN_KIND() && _supplyFull(vault, a)) return (AceVault.OverSupply.selector, 0);
    }

    /// @dev The vest maturity the next sync leaves at gross `g`, vest word `w`: a pending rise blended in as the vault's stamp blends it, else the stored one.
    function _nextMaturity(AceVault vault, uint256 g, uint256 w) private view returns (uint64) {
        uint256 mark = _word(vault, _at(STORE, NAV_MARK));
        uint64 m = uint64(w >> 128);
        return g > mark ? AceVaultFlows.blended(vault.unvested(), g - mark, m, vault.VEST_WINDOW()) : m;
    }

    /// @dev The vault's unsold-pot gate by its stored words: a batch open this block over tracked shares, or a pot or open key no exemption covers.
    function _unsold(AceVault vault) private view returns (bool) {
        if (vault.IN_KIND()) {
            bytes32[] memory s = _two(_at(TRACKER, CLOCK), _at(TRACKER, TRACKED_SUPPLY));
            bytes32[] memory w = vault.extsload(s);
            if (uint48(uint256(w[0]) >> 48) == block.number && uint256(w[1]) != 0) return true;
        }
        (uint256 u, uint256 settled) = IAceLenderOps(vault.ACE()).lenderUnresolved(address(vault), vault.asset());
        bytes32[] memory x = vault.extsload(_two(_at(STORE, OPEN_SEIZED), _at(STORE, EXEMPT_SETTLED)));
        return AceVaultFlows.unsold(u, uint256(x[0]), settled, uint256(x[1]));
    }

    /// @dev Whether in-kind entry has no share left to mint under the supply bound at NAV `a`, as `maxDeposit` prices it.
    function _supplyFull(AceVault vault, uint256 a) private view returns (bool) {
        uint256 q = vault.totalSupply() + vault.pendingFeeShares() + AceVaultFlows.VIRTUAL_SHARES;
        (bool ok, uint256 n) = Math.tryMul(AceVaultInKind.headroom(q), a + 1);
        return ok && n / q == 0;
    }

    /// @dev The total's room on `vault` under its total cap `cap`, by the door's own helper.
    function _totalRoom(AceVault vault, IAceLenderOps hub, uint256 cap) private view returns (uint256) {
        address asset = vault.asset();
        return AceVaultCaps.totalRoom(cap, hub.lenderAssets(address(vault), asset), hub.lenderOwed(address(vault), asset), drawdown(vault));
    }

    /// @dev A stored cap word, split.
    function _cap(uint256 w) private pure returns (uint192, bool) {
        return (uint192(w), (w >> 192) & 1 != 0);
    }

    /// @dev Two slots, as one `extsload` batch.
    function _two(bytes32 a, bytes32 b) private pure returns (bytes32[] memory q) {
        q = new bytes32[](2);
        (q[0], q[1]) = (a, b);
    }
}
