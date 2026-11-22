// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.36;

import {Math} from "@openzeppelin/contracts/utils/math/Math.sol";
import {MarketParams} from "../ace/hub/Types.sol";
import {IAceLenderOps} from "../interfaces/IAceLenderOps.sol";
import {IVaultTerms} from "../interfaces/IVaultTerms.sol";
import {AceVault} from "./AceVault.sol";
import {AceVaultCaps} from "./libraries/AceVaultCaps.sol";
import {AceVaultFlows, BorrowRequest, Terms} from "./libraries/AceVaultFlows.sol";
import {AceVaultInKind} from "./libraries/AceVaultInKind.sol";
import {AceVaultNav} from "./libraries/AceVaultNav.sol";

/// @title AceVaultLens
/// @notice Read-only views over any AceVault, the vault first in each: `borrow`'s preview, the entry gate, the in-kind tracker and its stored figures.
/// @notice It holds no state and no authority, so a new lens can replace this one at any time.
/// @dev `previewTerms` and `roomOf` run `borrow`'s own library helpers on the vault's figures, so neither can drift from `borrow`.
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
        uint256 count; // payouts
        uint256 nextPayout;
        uint256 checkpoint;
        uint256 credited;
        bool open; // stopped at a batch that cannot close now
        uint256 from; // the checkpoint index `words` starts at
        bytes32[] words;
    }

    /// @notice The market a `borrow` by `borrower` on `vault` with this request and payload would land in, and the draw.
    /// @notice It refuses as `borrow`'s checks on the product's answer and on its market would; `borrow` may still refuse on the drain, room, cash or the hub.
    /// @return id The market id, which `borrow` creates if missing.
    /// @return mp The market's parameters.
    /// @return draw The draw the product admits, its buffer the larger of the ask's and the product's.
    function previewTerms(AceVault vault, address borrower, BorrowRequest calldata request, bytes calldata data)
        external
        view
        returns (bytes32 id, MarketParams memory mp, Terms memory draw)
    {
        (mp, draw) = IVaultTerms(vault.TERMS()).borrowTerms(borrower, request, data);
        draw = AceVaultCaps.admit(request, mp, draw, AceVaultCaps.hubAsk(vault.IN_KIND(), vault.DOOR()), vault.MIN_TENOR(), vault.MAX_TENOR());
        AceVaultFlows.checkMarket(mp, vault.asset(), address(vault));
        id = keccak256(abi.encode(mp));
    }

    /// @notice Everything `holder` is owed of `token` on `vault` now: every payout from its cursor, a batch that would close now included.
    /// @notice A claim may pay only part of it within its budget; the exact one-call preview is an `eth_call` of `claim(tokens, holder)` from the holder.
    function claimable(AceVault vault, address holder, address token) external view returns (uint256 amount) {
        View memory standing = _view(vault, holder);
        bytes32 payouts = _slot(uint160(token), TRACKER, PAYOUTS);
        bytes32[] memory slots = new bytes32[](2);
        (slots[0], slots[1]) = (keccak256(abi.encode(token, _slot(uint160(holder), TRACKER, CURSOR))), payouts);
        bytes32[] memory words = vault.extsload(slots);
        uint256 cursor = uint256(words[0]);
        Walk memory walk;
        (walk.base, walk.count, walk.nextPayout, walk.checkpoint) = (keccak256(abi.encode(payouts)), uint256(words[1]), uint128(cursor), cursor >> 128);
        if (cursor == 0) walk.nextPayout = _firstEligible(vault, standing, walk.base, walk.count);
        while (walk.nextPayout < walk.count && !walk.open) {
            _chunk(vault, standing, walk);
        }
        amount = walk.credited;
    }

    /// @dev Credit the next `CHUNK` payouts of the walk, their words and their batches each read in one call; stop at a batch that cannot close.
    function _chunk(AceVault vault, View memory standing, Walk memory walk) private view {
        uint256 size = walk.count - walk.nextPayout < CHUNK ? walk.count - walk.nextPayout : CHUNK;
        bytes32[] memory slots = new bytes32[](size);
        for (uint256 i; i < size; ++i) {
            slots[i] = _plus(walk.base, walk.nextPayout + i);
        }
        bytes32[] memory payoutWords = vault.extsload(slots);
        for (uint256 i; i < size; ++i) {
            slots[i] = _slot(uint48(uint256(payoutWords[i])), TRACKER, BATCHES);
        }
        bytes32[] memory batchWords = vault.extsload(slots);
        for (uint256 i; i < size; ++i) {
            uint256 supply = uint256(batchWords[i]) >> 48;
            if (supply == 0) supply = standing.supplyNow;
            if (supply == 0) {
                walk.open = true;
                return;
            }
            uint256 held = _eligible(vault, standing, walk, uint48(uint256(batchWords[i])));
            if (held != 0) walk.credited += AceVaultInKind.credit(uint256(payoutWords[i]) >> 48, held, supply);
            ++walk.nextPayout;
        }
    }

    /// @notice How many of `token`'s payouts `holder` has not yet walked on `vault`, at most: a claim's list should name only tokens with some.
    function unclaimedPayouts(AceVault vault, address holder, address token) external view returns (uint256) {
        bytes32[] memory slots = new bytes32[](2);
        (slots[0], slots[1]) = (keccak256(abi.encode(token, _slot(uint160(holder), TRACKER, CURSOR))), _slot(uint160(token), TRACKER, PAYOUTS));
        bytes32[] memory words = vault.extsload(slots);
        return uint256(words[1]) - uint128(uint256(words[0]));
    }

    /// @dev The batch a payout word names, its block and supply; an open batch reads the supply it would close on now, zero if it cannot.
    function _batchOf(AceVault vault, View memory standing, uint256 payoutWord) private view returns (uint256 at, uint256 supply) {
        uint256 batchWord = _word(vault, _slot(uint48(payoutWord), TRACKER, BATCHES));
        (at, supply) = (uint48(batchWord), batchWord >> 48);
        if (supply == 0) supply = standing.supplyNow;
    }

    /// @dev The library's search for a claim from cursor zero, over the stored words.
    function _firstEligible(AceVault vault, View memory standing, bytes32 base, uint256 count) private view returns (uint256 lo) {
        uint256 key = standing.count != 0 ? uint48(_word(vault, standing.trace)) : type(uint256).max;
        uint256 hi = count;
        while (lo < hi) {
            uint256 mid = (lo + hi) / 2;
            (uint256 at, uint256 supply) = _batchOf(vault, standing, _word(vault, bytes32(uint256(base) + mid)));
            if (AceVaultInKind.readBefore(at, supply, key)) lo = mid + 1;
            else hi = mid;
        }
    }

    /// @notice `holder`'s tracked shares on `vault`: its shares plus its escrow, as stored.
    function trackedOf(AceVault vault, address holder) external view returns (uint256) {
        bytes32 holderSlot = _slot(uint160(holder), TRACKER, HOLDERS);
        uint256 count = _word(vault, holderSlot);
        return count == 0 ? 0 : _word(vault, _plus(keccak256(abi.encode(holderSlot)), count - 1)) >> 48;
    }

    /// @notice The shares a batch closing now would count on `vault`: every holder's balance and escrow, never shares gifted to the vault.
    function trackedSupply(AceVault vault) external view returns (uint256) {
        return _word(vault, _at(TRACKER, TRACKED_SUPPLY));
    }

    /// @notice Every token a payout on `vault` has carried, in the order of its first.
    function rewardTokens(AceVault vault) external view returns (address[] memory tokens) {
        uint256 count = _word(vault, _at(TRACKER, TOKENS));
        bytes32[] memory slots = new bytes32[](count);
        bytes32 base = keccak256(abi.encode(_at(TRACKER, TOKENS)));
        for (uint256 i; i < count; ++i) {
            slots[i] = _plus(base, i);
        }
        bytes32[] memory words = vault.extsload(slots);
        tokens = new address[](count);
        for (uint256 i; i < count; ++i) {
            tokens[i] = address(uint160(uint256(words[i])));
        }
    }

    /// @dev The holder's checkpoints, and the supply a waiting batch would close on.
    function _view(AceVault vault, address holder) private view returns (View memory standing) {
        bytes32 holderSlot = _slot(uint160(holder), TRACKER, HOLDERS);
        bytes32[] memory slots = new bytes32[](3);
        (slots[0], slots[1], slots[2]) = (holderSlot, _at(TRACKER, CLOCK), _at(TRACKER, TRACKED_SUPPLY));
        bytes32[] memory words = vault.extsload(slots);
        (standing.trace, standing.count) = (keccak256(abi.encode(holderSlot)), uint256(words[0]));
        uint256 foldBlock = uint48(uint256(words[1]) >> 48);
        uint256 supply = uint256(words[2]);
        if (foldBlock != 0 && foldBlock < block.number && supply != 0) standing.supplyNow = supply;
    }

    /// @dev The holder's tracked balance at `atBlock`, `walk.checkpoint` moved there in the claim's own probe order, so the walk costs what the claim's does.
    function _eligible(AceVault vault, View memory standing, Walk memory walk, uint256 atBlock) private view returns (uint256 held) {
        if (standing.count == 0) return 0;
        (uint256 index, uint256 hi, uint256 probes) = (walk.checkpoint, standing.count, 0);
        uint256 current = _checkpoint(vault, standing, walk, index);
        for (uint256 probe = index + 1; probe < hi; probe = AceVaultInKind.probeAfter(index, probes)) {
            uint256 word = _checkpoint(vault, standing, walk, probe);
            if (uint48(word) > atBlock) {
                hi = probe;
                break;
            }
            (index, current, probes) = (probe, word, probes + 1);
        }
        while (index + 1 < hi) {
            uint256 mid = (index + hi) / 2;
            uint256 word = _checkpoint(vault, standing, walk, mid);
            if (uint48(word) > atBlock) hi = mid;
            else (index, current) = (mid, word);
        }
        if (uint48(current) <= atBlock) held = current >> 48;
        walk.checkpoint = index;
    }

    /// @dev The holder's stored checkpoint word `index`: from the words last read, else read with the next `WINDOW` past it in one call.
    function _checkpoint(AceVault vault, View memory standing, Walk memory walk, uint256 index) private view returns (uint256) {
        if (index >= walk.from && index < walk.from + walk.words.length) return uint256(walk.words[index - walk.from]);
        uint256 size = standing.count - index < WINDOW ? standing.count - index : WINDOW;
        bytes32[] memory slots = new bytes32[](size);
        for (uint256 i; i < size; ++i) {
            slots[i] = _plus(standing.trace, index + i);
        }
        (walk.from, walk.words) = (index, vault.extsload(slots));
        return uint256(walk.words[0]);
    }

    /// @dev One raw word of `vault`.
    function _word(AceVault vault, bytes32 slot) private view returns (uint256) {
        bytes32[] memory slots = new bytes32[](1);
        slots[0] = slot;
        return uint256(vault.extsload(slots)[0]);
    }

    /// @dev The member at `offset` from a namespace `root`: the tracker's or the vault's.
    function _at(bytes32 root, uint256 offset) private pure returns (bytes32) {
        return bytes32(uint256(root) + offset);
    }

    /// @dev The word `key` maps to in the mapping at `offset` from `root`; an address key is passed as its 160-bit number, which encodes alike.
    function _slot(uint256 key, bytes32 root, uint256 offset) private pure returns (bytes32) {
        return keccak256(abi.encode(key, _at(root, offset)));
    }

    /// @dev The word `i` slots past `slot`.
    function _plus(bytes32 slot, uint256 i) private pure returns (bytes32) {
        return bytes32(uint256(slot) + i);
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
        bytes32 slot = _slot(uint160(holder), STORE, REQUESTS);
        bytes32[] memory words = vault.extsload(_two(slot, _plus(slot, 1)));
        return (uint256(words[0]), uint64(uint256(words[1])));
    }

    /// @notice A key's cap on `vault` as stored: a collateral's row and whether it is listed; the wildcard at `address(0)`, the total at the vault.
    function capOf(AceVault vault, address key) external view returns (uint192 cap, bool listed) {
        return _cap(_word(vault, _slot(uint160(key), STORE, CAPS)));
    }

    /// @notice A key's pending change on `vault` and when anyone may accept it; a zero `validAt` is none.
    function pendingCapOf(AceVault vault, address key) external view returns (uint192 cap, bool listed, uint64 validAt) {
        bytes32 slot = _slot(uint160(key), STORE, PENDING_CAPS);
        bytes32[] memory words = vault.extsload(_two(slot, _plus(slot, 1)));
        (cap, listed) = _cap(uint256(words[0]));
        validAt = uint64(uint256(words[1]));
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
        bytes32[] memory words = vault.extsload(_two(_slot(uint160(collateral), STORE, SEIZED), _slot(uint160(address(vault)), STORE, CAPS)));
        (uint256 lent,) = hub.lenderByCollateral(address(vault), vault.asset(), collateral);
        uint256 row = AceVaultCaps.rowRoom(vault.effectiveCap(collateral), lent, uint184(uint256(words[0])));
        return Math.min(row, _totalRoom(vault, hub, uint192(uint256(words[1]))));
    }

    /// @notice A door-mode `vault`'s ledger for `collateral`: the value its goods still hold, whether it shuts entry, and a pending write-off.
    /// @return value The booked value less cash returned; it holds the collateral's row room, never NAV.
    /// @return open Whether the key shuts entry.
    /// @return writeOffAt A pending write-off's due time; zero is none.
    function seizedOf(AceVault vault, address collateral) external view returns (uint256 value, bool open, uint64 writeOffAt) {
        uint256 word = _word(vault, _slot(uint160(collateral), STORE, SEIZED));
        return (uint184(word), (word >> 248) & 1 != 0, uint64(word >> 184));
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
        uint256 gross = vault.grossNav();
        uint256 nav = vault.totalAssets();
        uint256 deferred = gross - nav; // the deferred gain the next sync would leave
        bool live = vault.totalSupply() > vault.SEED_SHARES();
        uint256 vestWord = _word(vault, _at(STORE, VEST));
        if (live && nav == 0) return (AceVault.EndOfLife.selector, 0);
        if (live && AceVaultNav.gainVesting(deferred, nav, vault.VEST_FLOOR())) {
            return (AceVault.GainVesting.selector, _nextMaturity(vault, gross, vestWord));
        }
        if (_unsold(vault)) return (AceVault.InventoryUnsold.selector, 0);
        uint48 holdUntil = uint48(vestWord >> 200);
        if (AceVaultNav.material(deferred, gross) && block.timestamp < holdUntil) {
            return (AceVault.RecoveryVesting.selector, holdUntil == type(uint48).max ? _nextMaturity(vault, gross, vestWord) : holdUntil);
        }
        if (vault.draining()) return (AceVault.Draining.selector, 0);
        if (vault.IN_KIND() && _supplyFull(vault, nav)) return (AceVault.OverSupply.selector, 0);
    }

    /// @dev The vest maturity the next sync leaves at `gross` and `vestWord`: a pending rise blended in as the vault's stamp blends it, else the stored one.
    function _nextMaturity(AceVault vault, uint256 gross, uint256 vestWord) private view returns (uint64) {
        uint256 mark = _word(vault, _at(STORE, NAV_MARK));
        uint64 maturity = uint64(vestWord >> 128);
        return gross > mark ? AceVaultNav.blended(vault.unvested(), gross - mark, maturity, vault.VEST_WINDOW()) : maturity;
    }

    /// @dev The vault's unsold-pot gate by its stored words: a batch open this block over tracked shares, or a pot or open key no exemption covers.
    function _unsold(AceVault vault) private view returns (bool) {
        if (vault.IN_KIND()) {
            bytes32[] memory slots = _two(_at(TRACKER, CLOCK), _at(TRACKER, TRACKED_SUPPLY));
            bytes32[] memory words = vault.extsload(slots);
            if (uint48(uint256(words[0]) >> 48) == block.number && uint256(words[1]) != 0) return true;
        }
        (uint256 unsoldPots, uint256 settledPots) = IAceLenderOps(vault.ACE()).lenderUnresolved(address(vault), vault.asset());
        bytes32[] memory doorWords = vault.extsload(_two(_at(STORE, OPEN_SEIZED), _at(STORE, EXEMPT_SETTLED)));
        return AceVaultNav.unsold(unsoldPots, uint256(doorWords[0]), settledPots, uint256(doorWords[1]));
    }

    /// @dev Whether in-kind entry has no share left to mint under the supply bound at `nav`, as `maxDeposit` prices it.
    function _supplyFull(AceVault vault, uint256 nav) private view returns (bool) {
        uint256 quoteSupply = vault.totalSupply() + vault.pendingFeeShares() + AceVaultFlows.VIRTUAL_SHARES;
        (bool fits, uint256 scaled) = Math.tryMul(AceVaultInKind.headroom(quoteSupply), nav + 1);
        return fits && scaled / quoteSupply == 0;
    }

    /// @dev The total's room on `vault` under its total cap `cap`, by `borrow`'s own helper.
    function _totalRoom(AceVault vault, IAceLenderOps hub, uint256 cap) private view returns (uint256) {
        address asset = vault.asset();
        return AceVaultCaps.totalRoom(cap, hub.lenderAssets(address(vault), asset), hub.lenderOwed(address(vault), asset), drawdown(vault));
    }

    /// @dev A stored cap word, split.
    function _cap(uint256 word) private pure returns (uint192, bool) {
        return (uint192(word), (word >> 192) & 1 != 0);
    }

    /// @dev Two slots, as one `extsload` batch.
    function _two(bytes32 first, bytes32 second) private pure returns (bytes32[] memory slots) {
        slots = new bytes32[](2);
        (slots[0], slots[1]) = (first, second);
    }
}
