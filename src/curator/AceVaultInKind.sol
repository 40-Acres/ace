// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.36;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {LowLevelCall} from "@openzeppelin/contracts/utils/LowLevelCall.sol";
import {Math} from "@openzeppelin/contracts/utils/math/Math.sol";
import {SafeCast} from "@openzeppelin/contracts/utils/math/SafeCast.sol";
import {Checkpoints} from "@openzeppelin/contracts/utils/structs/Checkpoints.sol";
import {TransientSlot} from "@openzeppelin/contracts/utils/TransientSlot.sol";
import {EmptyPot} from "../ace/hub/Lender.sol";
import {MarketParams} from "../ace/hub/Types.sol";
import {IAceLenderOps} from "../interfaces/IAceLenderOps.sol";
import {IAceVaultOps} from "../interfaces/IAceVaultOps.sol";
import {AceVaultFlows} from "./AceVaultFlows.sol";
import {AceVaultTail} from "./AceVaultTail.sol";

/// @title AceVaultInKind
/// @notice AceVault's in-kind mode: the collect that brings a default's pot home in kind, and the payouts that pay it to the shares that carried its loss.
/// @notice A COLLECT opens a payout batch, each token it brings home one payout, credited pro rata over every tracked share when the batch closes.
/// @notice A BATCH CLOSES at a later block's first tracker step, on the tracked supply its own block ended with; a share borrowed inside it earns nothing.
/// @notice Tracked shares are CHECKPOINTED by block, and a claim credits each payout at the holder's checkpoint for its batch's block.
/// @dev DELEGATECALL-linked: it runs as the vault, from its guarded verbs or its share hook only; the library's call protection refuses a direct call.
library AceVaultInKind {
    using SafeERC20 for IERC20;
    using Checkpoints for Checkpoints.Trace208;

    error ClaimToVault(); // tokens landing on the vault are credited to nobody
    error NotOurLoan(); // the loan's market does not name this vault as lender in its asset
    error ModeUnbuilt(); // a claim on a vault outside in-kind mode

    /// @notice A seized pot came home in kind; it is credited to the tracked shares once its batch closes.
    event Forfeited(uint256 indexed loanId, address indexed collateral, uint256 units);
    /// @notice A holder took credited units of one token.
    event Claimed(address indexed holder, address indexed token, address to, uint256 amount);

    /// @notice One collect's batch: the block its supply is read at, and that supply; zero supply while it is open.
    struct Batch {
        uint48 at;
        uint208 supply;
    }

    /// @notice One token's share of one batch.
    struct Payout {
        uint48 batch;
        uint208 units;
    }

    /// @notice One token's walk in a claim: the next payout, the checkpoint index it reads, the holder's checkpoint count, steps left, credit so far.
    struct Walk {
        uint256 nextPayout;
        uint256 checkpoint;
        uint256 checkpoints;
        uint256 left;
        uint256 credited;
    }

    /// @custom:storage-location erc7201:ace.inkind
    struct Layout {
        uint256[4] reserved; // unused, so every member below keeps its fixed offset from the root
        address[] paidTokens; // every token a payout ever carried, in the order of its first
        uint256 trackedSupply; // every holder's tracked balance summed: escrow counts, shares gifted to the vault do not
        uint48 batchCount; // batches so far; the latest is open while `foldBlock` is nonzero
        uint48 foldBlock; // the open batch's block, as opened or last re-stamped; zero is none
        mapping(uint256 batch => Batch) batches;
        mapping(address holder => Checkpoints.Trace208) bal; // each holder's tracked balance, checkpointed at each block it moved in
        mapping(address holder => mapping(address token => uint256)) cursor; // next payout, then at bit 128 the checkpoint index its walk reads
        mapping(address token => Payout[]) payouts; // each token's payouts, in batch order
    }

    uint64 internal constant MAX_TENOR_RAIL = 30 days; // the in-kind rail ceiling: nothing settles before expiry, so NAV counts a dead loan whole that long
    uint256 internal constant MAX_SUPPLY = 1 << 160; // in-kind entry mints no share past this, far under the tracker's 208-bit counts
    uint256 internal constant CLAIM_BUDGET = 400; // steps one claim takes across its tokens; its worst call stays under about 3.9M gas, a quarter of 2^24
    uint256 internal constant TOKEN_CHARGE = 16; // steps a named token with payouts left costs before its walk: its searches and its transfer
    bytes32 internal constant ROOT = 0xd7a5145a3d83b645b4f9f0f6fce92a69c8eed8dbba6d917e62a7d17852ce5100; // erc7201:ace.inkind
    bytes32 internal constant CONTEXT = 0xbacc57cdbed839b845ee25e51e0ed6cdd2a7a2a19d2e15c45d890c30be236300; // erc7201:ace.inkind.context, transient

    /// @notice The library's state, at its ERC-7201 root.
    function layout() internal pure returns (Layout storage $) {
        bytes32 slot = ROOT;
        assembly ("memory-safe") {
            $.slot := slot
        }
    }

    /// @dev The shares in-kind entry may still mint against `quoteSupply`, which carries the fee the entry collects first.
    function headroom(uint256 quoteSupply) internal pure returns (uint256) {
        return Math.saturatingSub(MAX_SUPPLY + AceVaultFlows.VIRTUAL_SHARES, quoteSupply);
    }

    /* ============================== THE COLLECT ============================== */

    /// @notice End each named loan of this vault's and bring its pot home in kind, as payouts of a batch that closes from a later block.
    /// @notice A repaid or already-collected id yields zero and the batch goes on; one neither expired nor settleable on distress reverts the whole batch.
    /// @return out The units each id brought home.
    function collectForfeited(uint256[] calldata ids) external returns (uint256[] memory out) {
        (address ace, address asset) = (AceVaultTail.ace(), AceVaultTail.asset());
        Layout storage $ = layout();
        _fold($);
        IAceLenderOps hub = IAceLenderOps(ace);
        out = new uint256[](ids.length);
        for (uint256 i; i < ids.length; ++i) {
            MarketParams memory mp = hub.idToMarketParams(hub.loanMarket(ids[i]));
            if (mp.lender != address(this) || mp.quote != asset) revert NotOurLoan();
            AceVaultFlows.endLoan(ace, ids[i]);
            out[i] = _redeem($, ace, ids[i], mp.collateral);
        }
    }

    /// @dev Take one settled loan's pot home, measured, and add it to the open batch as a payout of its token; an empty pot is nothing to take.
    function _redeem(Layout storage $, address ace, uint256 loanId, address token) private returns (uint256 units) {
        uint256 held = IERC20(token).balanceOf(address(this));
        (bool ok, bytes memory err) = ace.call(abi.encodeCall(IAceVaultOps.redeemInKind, (loanId, address(this))));
        if (!ok) {
            if (err.length != 4 || bytes4(err) != EmptyPot.selector) LowLevelCall.bubbleRevert(err);
            return 0;
        }
        units = IERC20(token).balanceOf(address(this)) - held;
        if (units == 0) return 0;
        uint256 batch = $.batchCount;
        if ($.foldBlock == 0) {
            ($.batchCount, $.foldBlock) = (uint48(++batch), uint48(block.number));
            $.batches[batch].at = uint48(block.number);
        }
        Payout[] storage list = $.payouts[token];
        uint256 count = list.length;
        if (count != 0 && list[count - 1].batch == batch) {
            list[count - 1].units = SafeCast.toUint208(list[count - 1].units + units);
        } else {
            if (count == 0) $.paidTokens.push(token);
            list.push(Payout(uint48(batch), SafeCast.toUint208(units)));
        }
        emit Forfeited(loanId, token, units);
    }

    /* ============================== THE TRACKER ============================== */

    /// @notice Account one share move the vault's `_update` reports, after the balances moved; it reads no token and calls no other contract.
    /// @notice Escrows, vault mints and self-transfers move no tracked share; an escrow burn is the context holder's; a gift to the vault leaves as a burn.
    function moved(address from, address to, uint256 value) external {
        if (value == 0 || from == to) return;
        address ctx = TransientSlot.tload(TransientSlot.asAddress(CONTEXT));
        if (from == address(this)) {
            if (to != address(0) || ctx == address(0)) return;
            from = ctx;
        } else if (to == address(this)) {
            if (from == address(0) || from == ctx) return;
            to = address(0);
        }
        Layout storage $ = layout();
        _fold($);
        if (from == address(0)) $.trackedSupply += value;
        else _push($.bal[from], $.bal[from].latest() - value);
        if (to == address(0)) $.trackedSupply -= value;
        else _push($.bal[to], $.bal[to].latest() + value);
    }

    /// @dev Checkpoint a holder's tracked balance at this block.
    function _push(Checkpoints.Trace208 storage history, uint256 tracked) private {
        history.push(uint48(block.number), SafeCast.toUint208(tracked));
    }

    /// @notice Pay the caller the named tokens' credit to `to` in order, within `CLAIM_BUDGET` steps; one the budget misses pays zero and resumes next call.
    /// @dev Each payout credits `floor(units * balance / supply)`, so a small holder's share of a low-decimal token's payout can floor to zero.
    function claim(address[] calldata tokens, address to) external returns (uint256[] memory paid) {
        if (!AceVaultTail.inKind()) revert ModeUnbuilt();
        if (to == address(this)) revert ClaimToVault();
        address holder = msg.sender;
        Layout storage $ = layout();
        _fold($);
        Checkpoints.Trace208 storage history = $.bal[holder];
        paid = new uint256[](tokens.length);
        uint256 budget = CLAIM_BUDGET;
        for (uint256 i; i < tokens.length && budget != 0; ++i) {
            (paid[i], budget) = _claimToken($, history, holder, tokens[i], to, budget);
        }
    }

    /// @dev Settle one token from `budget`, answering the rest: one step if owed nothing; else the call stops at or under `TOKEN_CHARGE`, or pays it and walks.
    function _claimToken(Layout storage $, Checkpoints.Trace208 storage history, address holder, address token, address to, uint256 budget)
        private
        returns (uint256 amount, uint256)
    {
        mapping(address => uint256) storage cursors = $.cursor[holder];
        Payout[] storage list = $.payouts[token];
        uint256 cursor = cursors[token];
        uint256 count = list.length;
        if (count == 0 || (cursor != 0 && uint128(cursor) == count)) return (0, budget - 1);
        if (budget <= TOKEN_CHARGE) return (0, 0);
        Walk memory walk = _settle($, history, list, cursor, budget - TOKEN_CHARGE);
        (cursors[token], amount) = (walk.nextPayout | (walk.checkpoint << 128), walk.credited);
        if (amount != 0) {
            IERC20(token).safeTransfer(to, amount);
            emit Claimed(holder, token, to, amount);
        }
        return (amount, walk.left);
    }

    /// @dev Close the open batch on the tracked supply from a later block, O(1), before any balance moves; untracked, it waits re-stamped to this block.
    function _fold(Layout storage $) private {
        uint256 foldBlock = $.foldBlock;
        if (foldBlock == 0 || foldBlock >= block.number) return;
        uint256 supply = $.trackedSupply;
        Batch storage batch = $.batches[$.batchCount];
        if (supply == 0) (batch.at, $.foldBlock) = (uint48(block.number), uint48(block.number));
        else (batch.supply, $.foldBlock) = (SafeCast.toUint208(supply), 0);
    }

    /// @dev Walk a token's payouts from `cursor` within `left` steps, one a read or probe, stopping at the open batch or the budget's end, both places kept.
    function _settle(Layout storage $, Checkpoints.Trace208 storage history, Payout[] storage list, uint256 cursor, uint256 left)
        private
        view
        returns (Walk memory walk)
    {
        uint256 count = list.length;
        (walk.nextPayout, walk.checkpoint) = cursor == 0 ? _start($, history, list, count) : (uint128(cursor), cursor >> 128);
        (walk.checkpoints, walk.left) = (history.length(), left);
        while (walk.nextPayout < count && walk.left != 0 && _step($, history, list[walk.nextPayout], walk)) ++walk.nextPayout;
    }

    /// @dev Credit one payout at the holder's checkpoint for its batch, `walk.checkpoint` moved up to it; false at the open batch or out of steps.
    function _step(Layout storage $, Checkpoints.Trace208 storage history, Payout memory payout, Walk memory walk) private view returns (bool) {
        --walk.left;
        Batch memory batch = $.batches[payout.batch];
        if (batch.supply == 0) return false;
        if (walk.checkpoint + 1 < walk.checkpoints && !_seek(history, walk, batch.at)) return false;
        if (walk.checkpoints != 0) {
            Checkpoints.Checkpoint208 memory entry = history.pos(uint32(walk.checkpoint));
            if (entry._key <= batch.at) walk.credited += credit(payout.units, entry._value, batch.supply);
        }
        return true;
    }

    /// @dev Move `walk.checkpoint` to the last at or before block `at`, a probe a step (two of one, doubling, bisection); out of steps it keeps a lower bound.
    /// @dev Not OZ's `upperLookupRecent`, which has no step budget and keeps no index to resume from.
    function _seek(Checkpoints.Trace208 storage history, Walk memory walk, uint256 at) private view returns (bool) {
        (uint256 index, uint256 hi, uint256 left) = (walk.checkpoint, walk.checkpoints, walk.left);
        uint256 probes;
        for (uint256 probe = index + 1; probe < hi; probe = probeAfter(index, probes)) {
            if (left == 0) return _park(walk, index);
            --left;
            if (history.pos(uint32(probe))._key > at) {
                hi = probe;
                break;
            }
            (index, probes) = (probe, probes + 1);
        }
        while (index + 1 < hi) {
            if (left == 0) return _park(walk, index);
            --left;
            uint256 mid = (index + hi) / 2;
            if (history.pos(uint32(mid))._key > at) hi = mid;
            else index = mid;
        }
        (walk.checkpoint, walk.left) = (index, left);
        return true;
    }

    /// @dev Out of steps mid-search: keep `index`, a lower bound for this payout's checkpoint, and spend the rest.
    function _park(Walk memory walk, uint256 index) private pure returns (bool) {
        (walk.checkpoint, walk.left) = (index, 0);
        return false;
    }

    /// @dev A first claim's places, each by search: the first payout it can be owed, never past the open batch, and the last checkpoint at or before it.
    function _start(Layout storage $, Checkpoints.Trace208 storage history, Payout[] storage list, uint256 count)
        private
        view
        returns (uint256 lo, uint256 index)
    {
        uint256 len = history.length();
        uint256 key = len == 0 ? type(uint256).max : history.pos(0)._key;
        uint256 hi = count;
        while (lo < hi) {
            uint256 mid = (lo + hi) / 2;
            Batch memory batch = $.batches[list[mid].batch];
            if (readBefore(batch.at, batch.supply, key)) lo = mid + 1;
            else hi = mid;
        }
        if (len == 0) return (lo, 0);
        if (lo == count) return (lo, len - 1);
        uint256 at = $.batches[list[lo].batch].at;
        (uint256 low, uint256 high) = (0, len);
        while (low < high) {
            uint256 mid = (low + high) / 2;
            if (history.pos(uint32(mid))._key > at) high = mid;
            else low = mid + 1;
        }
        index = low == 0 ? 0 : low - 1;
    }

    /// @notice The checkpoint index a seek probes next from `index`, after `probes` probes keyed at or before the batch. The lens shares it.
    function probeAfter(uint256 index, uint256 probes) internal pure returns (uint256) {
        return index + (probes < 2 ? 1 : 1 << (probes - 1));
    }

    /// @notice What one payout of `units` over a batch of `supply` tracked shares credits a holder of `balance` of them, rounded down.
    function credit(uint256 units, uint256 balance, uint256 supply) internal pure returns (uint256) {
        return Math.mulDiv(units, balance, supply);
    }

    /// @notice Whether a batch credits a holder whose first checkpoint is at `key` nothing: it is closed and read before that key. The lens shares it.
    function readBefore(uint256 at, uint256 supply, uint256 key) internal pure returns (bool) {
        return supply != 0 && at < key;
    }
}
