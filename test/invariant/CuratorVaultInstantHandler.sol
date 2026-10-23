// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.36;

import {Math} from "@openzeppelin/contracts/utils/math/Math.sol";
import {CuratorVaultBase} from "../curator/CuratorVaultBase.sol";
import {AceVault, VaultConfig} from "../../src/curator/AceVault.sol";
import {CuratorVault} from "../../src/curator/CuratorVault.sol";
import {Loan} from "../../src/ace/hub/Types.sol";

/// @title CuratorVaultInstantHandler
/// @notice The fuzzing surface for ONE production curator vault's instant exit, beside its exit request and its drain.
/// @notice Four LPs exit at once, request, claim, and enter; loans draw at the door, repay and settle; the curator and the guardian move the drain.
/// @dev Every action is bounded and try/catch-guarded, since `fail_on_revert = false` discards a revert.
/// @dev Properties that cannot be views LATCH here: forge reverts the state an `invariant_` function writes.
contract CuratorVaultInstantHandler is CuratorVaultBase {
    uint16 internal constant FEE_BPS = 1000; // a live fee, so the exit's own collection moves the supply it prices over
    uint256 internal constant MAX_LOANS = 3;
    uint256 internal constant SEED_DEPOSIT = 500e6;
    uint256 internal constant VIRT = 1e6;

    CuratorVault public vault;
    address public guardian = address(0x6A2D);
    address[4] public actors = [address(0xA01), address(0xA02), address(0xA03), address(0xA04)];
    uint256[] internal _loanIds;

    uint256 public exitsPaid;
    uint256 public drainedExitsPaid; // of those, paid under the drain
    uint256 public maxExitsPaid;
    uint256 public lastOutRefused; // exits of the exiter's last free shares refused over a vesting gain: the refusal J5 guards, firing
    uint256 public drainTries; // drain switch-ons tried by a key that holds one
    uint256 public drainsOn;
    uint256 public drainsOff;
    uint256 public requestsStood;
    uint256 public claimTries; // claims of exactly a nonzero `maxClaim`
    uint256 public claimsPaid;

    bool public quoteMissed; // an exit paid other than the preview taken just before it
    bool public priceFell; // an exit left the stayers' price more than one asset-wei under the price before it
    bool public overpaid; // an exit took more than its shares' part of the NAV, plus a wei
    bool public holdTouched; // an exit while lending paid into the exitable cash the requests hold
    bool public maxAskReverted; // `redeem(maxRedeem)`, `withdraw(maxWithdraw)` or `claimExit(maxClaim)` reverted on the view's own figure
    bytes public maxAskErr;
    bool public pileTaken; // an exit took its exiter's last free shares while a gain still vested; an LP's leave the curator's out
    bool public claimPastExitable; // a claim of `maxClaim` paid past the exitable cash it read

    struct Pre {
        bool draining;
        uint256 free; // the free supply the verb's last-out test reads for this exiter, as `_free(holder, supply)` counts it
        uint256 quote; // the preview: assets for a redeem, shares for a withdraw
        uint256 a;
        uint256 q;
        uint256 exitable; // idle past the roll hold, before the exit
    }

    constructor() {
        setUp();
        VaultConfig memory c = _cfg(FEE_BPS);
        c.guardian = guardian;
        vault = _deploy(c, "Instant", "cINST");
        for (uint256 i; i < actors.length; i++) {
            _lpDeposit(vault, actors[i], SEED_DEPOSIT);
        }
        _openLoan(800e6);
    }

    function _actor(uint256 seed) internal view returns (address) {
        return actors[seed % actors.length];
    }

    /// @dev An exiting party: one of the four LPs, or the curator, so its fee shares can leave and the last free holder can be anyone.
    function _exiter(uint256 seed) internal view returns (address) {
        return seed % 5 == 4 ? curator : actors[seed % actors.length];
    }

    /// @dev The state `who`'s exit is judged against; `amount` is the shares a redeem asks, or the cash a withdraw asks.
    /// @dev Its free figure counts the fee the verb mints first, and an LP's leaves out the curator's shares, minted and pending.
    function _pre(address who, uint256 amount, bool isWithdraw) internal view returns (Pre memory p) {
        p.draining = vault.draining();
        p.quote = isWithdraw ? vault.previewWithdraw(amount) : vault.previewRedeem(amount);
        p.a = vault.totalAssets();
        uint256 pending = vault.pendingFeeShares();
        p.q = vault.totalSupply() + pending + VIRT;
        p.free = p.q - VIRT - vault.balanceOf(address(vault));
        if (who != curator) p.free -= vault.balanceOf(curator) + pending;
        (p.exitable,) = vault.holds();
    }

    /// @dev Weigh one exit that paid: the quote, the stayers' price, the cash's share, the requests' hold while lending, and the pile.
    /// @dev The hold after is the requests' worth then, capped by the exitable cash before: an exit inside its bound leaves at least that, a wei or two aside.
    /// @param burned The shares the exit burned.
    /// @param got What the preview predicted: the cash a redeem paid, or the shares a withdraw burned.
    /// @param paid The cash the exit paid.
    function _judgeExit(Pre memory p, uint256 burned, uint256 got, uint256 paid) internal {
        exitsPaid++;
        if (p.draining) drainedExitsPaid++;
        if (burned == p.free && vault.unvested() != 0) pileTaken = true; // the exit leaves the pile whole, so the read after it holds
        if (got != p.quote) quoteMissed = true;
        uint256 q1 = vault.totalSupply() + vault.pendingFeeShares() + VIRT;
        if ((vault.totalAssets() + 2) * p.q < (p.a + 1) * q1) priceFell = true; // one asset-wei of rounding
        if (paid * (p.q - VIRT) > p.a * burned + (p.q - VIRT)) overpaid = true; // past the burned shares' part of NAV, plus a wei
        if (!p.draining) {
            (uint256 exitable,) = vault.holds();
            if (exitable + 2 < Math.min(p.exitable, vault.convertToAssets(vault.requestedShares()))) holdTouched = true;
        }
    }

    /* ============================ the LPs ============================ */

    function deposit(uint256 actorSeed, uint256 amtSeed) external {
        address a = _actor(actorSeed);
        uint256 amt = bound(amtSeed, 1e6, 2_000e6);
        usdc.mint(a, amt);
        vm.startPrank(a);
        usdc.approve(address(vault), amt);
        try vault.deposit(amt, a) {} catch {}
        vm.stopPrank();
    }

    /// @notice An instant redeem of part or all of a holding.
    function redeem(uint256 actorSeed, uint256 shareSeed) external {
        address a = _actor(actorSeed);
        uint256 bal = vault.balanceOf(a);
        if (bal == 0) return;
        _redeem(a, bound(shareSeed, 1, bal));
    }

    /// @notice A whole holding at once, the curator's fee shares included, which is how the last free holder is ever reached.
    function redeemAll(uint256 whoSeed) external {
        address a = _exiter(whoSeed);
        uint256 bal = vault.balanceOf(a);
        if (bal == 0) return;
        _redeem(a, bal);
    }

    function _redeem(address a, uint256 sh) internal {
        Pre memory p = _pre(a, sh, false);
        vm.prank(a);
        try vault.redeem(sh, a, a) returns (uint256 paid) {
            _judgeExit(p, sh, paid, paid);
        } catch (bytes memory err) {
            if (err.length >= 4 && bytes4(err) == AceVault.LastOutVesting.selector && sh == p.free) lastOutRefused++;
        }
    }

    /// @notice Exactly `maxRedeem`, which must land whenever it is not zero.
    function redeemMax(uint256 actorSeed) external {
        address a = _exiter(actorSeed);
        uint256 r = vault.maxRedeem(a);
        if (r == 0) return;
        Pre memory p = _pre(a, r, false);
        vm.prank(a);
        try vault.redeem(r, a, a) returns (uint256 paid) {
            maxExitsPaid++;
            _judgeExit(p, r, paid, paid);
        } catch (bytes memory err) {
            (maxAskReverted, maxAskErr) = (true, err);
        }
    }

    /// @notice Exactly `maxWithdraw`, which must land whenever it is not zero; judged as a redeem is, its burn against its preview.
    function withdrawMax(uint256 actorSeed) external {
        address a = _exiter(actorSeed);
        uint256 w = vault.maxWithdraw(a);
        if (w == 0) return;
        Pre memory p = _pre(a, w, true);
        vm.prank(a);
        try vault.withdraw(w, a, a) returns (uint256 burned) {
            maxExitsPaid++;
            _judgeExit(p, burned, burned, w);
        } catch (bytes memory err) {
            (maxAskReverted, maxAskErr) = (true, err);
        }
    }

    /// @notice A holder requests part of its shares, which holds exitable cash for it at once.
    function requestExit(uint256 actorSeed, uint256 shareSeed) external {
        address a = _actor(actorSeed);
        uint256 bal = vault.balanceOf(a);
        if (bal == 0) return;
        uint256 shares = bound(shareSeed, 1, bal);
        vm.prank(a);
        try vault.requestExit(shares) {
            requestsStood++;
        } catch {}
    }

    /// @notice A requester claims exactly `maxClaim`, which must land whenever it is not zero, and never pays past exitable cash.
    function claimMax(uint256 actorSeed) external {
        address a = _exiter(actorSeed);
        uint256 m = vault.maxClaim(a);
        if (m == 0) return;
        claimTries++;
        (uint256 exitable,) = vault.holds();
        vm.prank(a);
        try vault.claimExit(m, a, 0) returns (uint256 got) {
            claimsPaid++;
            if (got > exitable) claimPastExitable = true;
        } catch (bytes memory err) {
            (maxAskReverted, maxAskErr) = (true, err);
        }
    }

    /* ============================ the drain ============================ */

    function drainOn(bool byGuardian) external {
        drainTries++;
        vm.prank(byGuardian ? guardian : curator);
        try vault.setDrain(true) {
            drainsOn++;
        } catch {}
    }

    function drainOff() external {
        vm.prank(curator);
        try vault.setDrain(false) {
            drainsOff++;
        } catch {}
    }

    /* ============================ the book and the clock ============================ */

    function crank() external {
        try vault.crank() {} catch {}
    }

    function warp(uint256 dtSeed) external {
        _warpBy(bound(dtSeed, 1, 2 days));
    }

    function openLoan(uint256 drawSeed) external {
        if (_loanIds.length >= MAX_LOANS) return;
        _openLoan(bound(drawSeed, 20e6, 300e6));
    }

    /// @notice The whole debt repaid by the rig borrower, who holds every door loan's title; the close pays the vault home.
    function repayLoan(uint256 loanSeed) external {
        if (_loanIds.length == 0) return;
        uint256 loanId = _loanIds[loanSeed % _loanIds.length];
        Loan memory l = read.loan(loanId);
        if (l.closedAt != 0 || l.debt == 0) return;
        usdc.mint(borrower, l.debt);
        vm.startPrank(borrower);
        usdc.approve(address(ace), l.debt);
        try ace.repay(loanId, l.debt) {} catch {}
        vm.stopPrank();
    }

    /// @notice A FALL: one open loan settles, stepping NAV down by its claim.
    function settleLoan(uint256 loanSeed) external {
        _settle(loanSeed);
    }

    function _settle(uint256 loanSeed) internal {
        if (_loanIds.length == 0) return;
        uint256 loanId = _loanIds[loanSeed % _loanIds.length];
        Loan memory l = read.loan(loanId);
        if (l.closedAt != 0 || l.debt == 0) return;
        record.setBelow(true);
        vm.prank(keeper);
        try ace.finalize(loanId) {} catch {}
        record.setBelow(false);
    }

    /// @notice A RISE: a counted donation, which vests, so a last holder has a pile to be refused over.
    function gain(uint256 amtSeed) external {
        _gift(vault, bound(amtSeed, 1e6, 200e6));
    }

    /// @dev One unarmed door borrow of `principal` against `COLL`; a refusal is swallowed.
    function _openLoan(uint256 principal) internal {
        collateral.mint(borrower, COLL);
        vm.startPrank(borrower);
        collateral.approve(address(vault), COLL);
        try vault.borrow(_request(address(collateral), COLL, principal), "", "") returns (uint256 loanId) {
            _loanIds.push(loanId);
        } catch {}
        collateral.approve(address(vault), 0);
        vm.stopPrank();
    }
}
