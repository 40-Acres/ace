// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.36;

import {ERC4626} from "@openzeppelin/contracts/token/ERC20/extensions/ERC4626.sol";
import {CuratorVaultBase} from "./CuratorVaultBase.sol";
import {CuratorVault, Listing} from "../../src/curator/CuratorVault.sol";
import {AceVault, VaultConfig} from "../../src/curator/AceVault.sol";
import {AceLens} from "../../src/ace/lens/AceLens.sol";
import {PocDeployConfig} from "../../src/config/Defaults.sol";

/// @notice A receiver whose every callback reverts: the ERC-6909 leg must never hand it control.
contract HostileReceiver {
    fallback() external payable {
        revert("REENTERED");
    }
}

/// @notice A vault pinned at zero NAV, for the end-of-life guards the counters make unreachable.
contract ZeroNavVault is CuratorVault {
    constructor(VaultConfig memory cfg, Listing[] memory l) CuratorVault(cfg, 10e6, 1.4e18, 1 days, l, "Zero", "cZERO") {}

    function totalAssets() public pure override returns (uint256) {
        return 0;
    }
}

/// @notice A hook token that reads a target during EVERY move and counts each refusal, so a later answering move cannot hide one.
/// @dev The asset is a hook token only to open the seam; production requires a hookless asset.
contract ReadEveryMoveAsset {
    uint8 public constant decimals = 6;

    mapping(address => uint256) public balanceOf;
    mapping(address => mapping(address => uint256)) public allowance;
    address public target; // zero disarms the hook
    bytes public payload;
    uint256 public reads; // armed reads fired since the last arm
    uint256 public refusals; // of them, how many reverted
    bytes4 public firstRefusal; // the selector the first refusal carried
    bytes public lastAnswer; // the return data of the latest read that answered

    function arm(address who, bytes calldata data) external {
        (target, payload, reads, refusals, firstRefusal, lastAnswer) = (who, data, 0, 0, bytes4(0), "");
    }

    function mint(address to, uint256 a) external {
        balanceOf[to] += a;
    }

    function approve(address s, uint256 a) external returns (bool) {
        allowance[msg.sender][s] = a;
        return true;
    }

    function transfer(address to, uint256 a) external returns (bool) {
        _move(msg.sender, to, a);
        return true;
    }

    function transferFrom(address f, address to, uint256 a) external returns (bool) {
        allowance[f][msg.sender] -= a;
        _move(f, to, a);
        return true;
    }

    function _move(address f, address t, uint256 a) private {
        balanceOf[f] -= a;
        balanceOf[t] += a;
        if (target == address(0)) return;
        (bool ok, bytes memory ret) = target.staticcall(payload);
        reads++;
        if (!ok) {
            if (refusals == 0) firstRefusal = bytes4(ret);
            refusals++;
        } else {
            lastAnswer = ret;
        }
    }
}

/// @title CuratorVaultExit
/// @notice Cash plus a uniform fraction of every written-off position, atomic, and never stranding.
contract CuratorVaultExitTest is CuratorVaultBase {
    uint256 internal constant SEED = 10_000e6;
    uint256 internal constant DRAW = 6_000e6;
    uint256 internal constant BIG_COLL = 4_000_000e18;

    function setUp() public override {
        super.setUp();
        record.setMinPrice(T4);
    }

    /// @dev One settled, written-off class, with idle cash left over to redeem against.
    function _impaired(CuratorVault v, uint256 seedA, uint256 seedB) internal returns (uint256 loanId) {
        _lpDeposit(v, alice, seedA);
        _lpDeposit(v, bob, seedB);
        loanId = _open(DRAW);
        _crank(v, loanId, T2, 0);
        _finalize(loanId);
        _crankAll(v);
    }

    /// @dev A door borrow pledging `BIG_COLL`, so the trigger stays far under the floor.
    function _openBig(CuratorVault v, uint256 principal) internal returns (uint256 loanId) {
        collateral.mint(borrower, BIG_COLL);
        vm.startPrank(borrower);
        collateral.approve(address(v), BIG_COLL);
        loanId = v.borrow(_request(address(collateral), BIG_COLL, principal), "", "");
        vm.stopPrank();
    }

    /// @dev T13: the worked example. Cash at book, and NOTHING else: the exit moves no title.
    function test_Exit_CashOnly_TheWorkedExample() public {
        CuratorVault v = _newVault(0);
        uint256 loanId = _impaired(v, 9_000e6, 1_000e6);

        uint256 nav = v.totalAssets();
        uint256 unitsHeld = read.invPotOf(mid, loanId);
        uint256 s0 = v.totalSupply();
        uint256 shares = v.balanceOf(bob);
        assertGt(unitsHeld, 0, "the vault holds real title booked at zero");

        uint256 cashBefore = usdc.balanceOf(bob);
        uint256 got = _redeemAll(v, bob);

        assertEq(got, (shares * (nav + 1)) / (s0 + 1e6), "the cash leg is the plain 4626 conversion");
        assertEq(usdc.balanceOf(bob) - cashBefore, got, "and it really arrived");
        assertEq(read.invPotOf(mid, loanId), unitsHeld, "so the stayers keep every unit, and the recovery");
        assertEq(v.totalAssets(), nav - got, "NAV fell by the cash alone: the title was booked at zero");
    }

    /// @dev T15: the exit performs no valuation. Every price source is armed to revert during it.
    function test_Exit_NoValuationIsPerformed() public {
        CuratorVault v = _newVault(0);
        _impaired(v, 9_000e6, 1_000e6);

        vm.mockCallRevert(address(record), bytes(""), bytes("RECORD_READ"));
        vm.mockCallRevert(address(lens), abi.encodeWithSelector(AceLens.inventoryMark.selector), bytes("MARK"));

        uint256 got = _redeemAll(v, bob);
        assertGt(got, 0, "the exit paid, with no oracle and no mark in the call");
        vm.clearMockedCalls();
    }

    /// @dev T29: EVERY exit always succeeds. With no gate left, `redeem` IS the escape the forfeiting verb was.
    /// @dev Twelve positions and a long gap: nothing about time or count may stand between an LP and cash.
    function test_Exit_RedeemAlwaysSucceeds() public {
        CuratorVault v = _newVault(0);
        _lpDeposit(v, alice, 12 * 500e6);
        _lpDeposit(v, bob, 2_000e6);
        /// @dev WAS twelve LOTS and ONE loan drawing across all of them: a class was a (loan, tick) pair, so
        /// @dev one draw booked twelve. A position is a LOAN now, so twelve positions is twelve loans.
        uint256 loanId;
        for (uint256 i; i < 12; i++) {
            loanId = _open(500e6);
            _crankAllTicks(v, loanId, i);
            _finalize(loanId);
        }
        _crankAll(v);
        assertEq(_carriedClasses(v), 12, "every position impaired, and the vault still holds title in each");

        _warpBy(5 days);
        uint256 unitsBefore = _unitsHeld(v);
        uint256 got = _redeemAll(v, bob); // a request and a claim, in one go

        assertGt(got, 0, "the exit paid cash however long nobody cranked");
        assertEq(_unitsHeld(v), unitsBefore, "and every unit stayed with the stayers");
        assertEq(_unitsHeld(v), unitsBefore, "the exiter took no title at all: the pot is unmoved");
    }

    /// @dev T35: maxRedeem reports the liquidity truth and nothing else.
    /// @dev The open's own gain vests first: a sole holder's whole free supply is refused, and offered nothing, while a gain vests.
    function test_Exit_MaxRedeemIsLiquidityBounded() public {
        CuratorVault v = _newVault(0);
        _lpDeposit(v, alice, SEED);
        uint256 loanId = _open(DRAW);
        _crank(v, loanId, T2, 0);
        _warpBy(VEST_W);
        v.crank();

        uint256 idle0 = v.idle();
        uint256 held = v.balanceOf(alice);
        uint256 cap = v.maxRedeem(alice);
        assertLt(cap, held, "idle cannot clear the whole holding, and maxRedeem says so");
        assertEq(v.maxWithdraw(alice), idle0, "the cash bound is exitable cash, which with no request and no armed loan is all of idle");

        _finalize(loanId);
        _crankAll(v); // the crank brings what the hub owes the vault home into idle
        uint256 unitsBefore = read.invPotOf(mid, loanId);
        uint256 idle1 = v.idle();
        uint256 maxW = v.maxWithdraw(alice);
        assertLe(maxW, idle1, "after the write-off the bound is still exitable cash, at the trough price");
        uint256 r = v.maxRedeem(alice);
        vm.prank(alice);
        uint256 got = v.redeem(r, alice, alice);

        assertLe(got, idle1, "the exit paid what the cash supported");
        assertApproxEqAbs(got, maxW, 1, "and the max views quoted what it paid");
        assertEq(read.invPotOf(mid, loanId), unitsBefore, "and took no title with it");
    }

    /// @dev T34, EXIT HALF ONLY: a burn worth nothing reverts rather than giving the shares away.
    /// @dev The ENTRY half is parked -- `EndOfLife` is deleted, so the door does not shut any more.
    /// @dev The state is unreachable through the hub: the virtual offset always leaves a wei behind.
    /// @dev The double overrides the NAV expression rather than faking it in storage.
    function test_EndOfLife_ZeroNavBurnRevertsRatherThanGivingSharesAway() public {
        ZeroNavVault z = new ZeroNavVault(_cfg(0), _listing());
        _lpDeposit(CuratorVault(address(z)), alice, 1_000e6);
        assertEq(z.totalAssets(), 0, "NAV is zero while shares are live");
        assertGt(z.totalSupply(), 0, "the spent-vault state");

        /// @dev BOTH EXIT DOORS PRICE, and both refuse a burn that prices to nothing.
        uint256 held = z.balanceOf(alice);
        vm.startPrank(alice);
        vm.expectRevert(AceVault.ZeroAssets.selector);
        z.redeem(held, alice, alice);
        z.requestExit(held); // a request prices nothing, so it stands
        vm.expectRevert(AceVault.ZeroAssets.selector);
        z.claimExit(held, alice, 0);
        vm.stopPrank();
    }


    /// @dev The reachable half of the same state: a write-off that nearly empties NAV shuts entry until its settled pot sells.
    /// @dev The trough gate is deleted; what shuts this door is the unsold pot, `InventoryUnsold`, with no share minted.
    function test_Entry_AWriteOffThatEmptiesNavWaitsForTheSale() public {
        CuratorVault v = _newVault(0);
        _lpDeposit(v, alice, DRAW);
        uint256 loanId = _open(DRAW);
        _crank(v, loanId, T2, 0);
        _finalize(loanId);
        _crankAll(v);

        assertLt(v.totalAssets(), DRAW, "the loss fell straight through to NAV, with no memo to hold it");
        assertGt(v.totalAssets(), 0, "PREMISE: the open's lender fee is left, so the vault is not spent");
        _assertEntryWaitsForTheSale(v, bob);
        assertTrue(lens.loan(loanId).closedAt != 0, "the loan that emptied NAV really did settle");
    }

    /// @dev T41: the exit hands a hostile receiver nothing but an ERC20 transfer, which has no hook either.
    function test_Exit_AHostileReceiverCannotReenter() public {
        CuratorVault v = _newVault(0);
        _impaired(v, 9_000e6, 1_000e6);
        HostileReceiver hostile = new HostileReceiver();

        uint256 shares = v.balanceOf(bob); // BEFORE the prank: a read is a call, and a call would eat it
        vm.prank(bob);
        v.requestExit(shares);
        uint256 m = v.maxClaim(bob); // BEFORE the prank: a read is a call, and a call would eat it
        vm.prank(bob);
        uint256 got = v.claimExit(m, address(hostile), 0); // the claim, at the impaired price, paid to the hostile receiver

        assertGt(got, 0, "the exit completed against a receiver whose every callback reverts");
        assertEq(usdc.balanceOf(address(hostile)), got, "the cash landed");
    }

    /// @notice A HOOK READING NAV DURING A CLAIM SEES THE STATE THE CLAIM LEAVES: the claim moves cash once, after every write.
    /// @dev The vault holds its cash, so the payout to the receiver is the claim's only move, and it lands after the burn and the books.
    /// @dev This hook fires after balances move, so its one read answers the post-claim NAV rather than tearing.
    /// @dev The vault lists no collateral: it never lends here, and a row would need a record on this hook asset's pair.
    function test_Exit_AMidClaimReadSeesTheNavTheClaimLeaves() public {
        ReadEveryMoveAsset hook = new ReadEveryMoveAsset();
        VaultConfig memory cfg = _cfg(0);
        cfg.asset = address(hook);
        CuratorVault v = new CuratorVault(cfg, RIG_MIN_DEBT, PocDeployConfig.MIN_COVERAGE_WAD, RIG_TIMELOCK, new Listing[](0), "Curator", "cVLT");
        address[2] memory lps = [alice, bob];
        for (uint256 i; i < 2; i++) {
            hook.mint(lps[i], SEED);
            vm.prank(lps[i]);
            hook.approve(address(v), SEED);
            vm.prank(lps[i]);
            v.deposit(SEED, lps[i]);
        }
        uint256 escrow = v.balanceOf(bob);
        vm.prank(bob);
        v.requestExit(escrow);
        assertGt(v.totalAssets(), 0, "control: the same read answers outside a move");

        hook.arm(address(v), abi.encodeCall(AceVault.totalAssets, ()));
        vm.prank(bob);
        v.claimExit(escrow, bob, 0); // one move: the vault's payment to bob
        assertEq(hook.reads(), 1, "PREMISE: the claim moved cash once, so the armed read fired once");
        assertEq(hook.refusals(), 0, "a NAV read during the claim's payout was refused");
        assertEq(abi.decode(hook.lastAnswer(), (uint256)), v.totalAssets(), "the read during the payout tore: it is not the NAV the claim left");
        assertEq(v.totalSupply(), v.balanceOf(alice), "and the claim itself completed: bob's escrow burned");
    }

    /// @dev A SEPARATE DEFECT ON THE SAME PATH: `withdraw` once fed a ceiled share count to a release test doing `totalSupply() - shares`.
    /// @dev Past NAV that UNDERFLOWED into `Panic(0x11)`; this pins a named refusal for an ask past NAV instead.
    /// @dev The cash bound is checked before the burn, so the name is OZ's over-withdraw, carrying the bound the max view reports.
    function test_Exit_AWithdrawPastNavRefusesByNameRatherThanByPanic() public {
        CuratorVault v = _newVault(0);
        _lpDeposit(v, alice, 9_000e6);
        _lpDeposit(v, bob, 1_000e6);
        _open(9_000e6);
        uint256 nav = v.totalAssets();
        uint256 maxW = v.maxWithdraw(bob);

        vm.prank(bob);
        vm.expectRevert(abi.encodeWithSelector(ERC4626.ERC4626ExceededMaxWithdraw.selector, bob, nav * 2, maxW));
        v.withdraw(nav * 2, bob, bob);
    }

    /// @dev The exit's cost is now FLAT in the written-off set, which is what deleted both caps.
    /// @dev Was `test_Exit_GasByWrittenOffCount`, which measured the deleted `_payUnits` walk against
    /// @dev the deleted `MAX_POSITIONS`. Its final figures are in the decisions record.
    function test_Exit_GasIsFlatInTheWrittenOffCount() public {
        uint256 g1 = _measureExit(1);
        uint256 g32 = _measureExit(32);
        uint256 g128 = _measureExit(128);

        emit log_named_uint("redeem gas at k=1", g1);
        emit log_named_uint("redeem gas at k=32", g32);
        emit log_named_uint("redeem gas at k=128", g128);
        // FLATNESS, not equality: the two differ by warm/cold slots, never by the size of the set
        assertLt(g128, 2 * g1, "the exit walks nothing, so 128 impairments cost about what one does");
        assertLt(g32, 2 * g1, "and the shape does not bend in between either");
        assertLt(g128, 200_000, "and a full exit is an ordinary transaction at any set size");
    }

    /// @dev Build `k` written-off positions, one door borrow each, then time one instant redemption.
    /// @dev Nothing rests between calls, so there is no unconsumed depth to stand beside them.
    function _measureExit(uint256 k) internal returns (uint256 used) {
        CuratorVault v = _newVault(0);
        _lpDeposit(v, alice, k * 100e6 + 5_000e6);
        _lpDeposit(v, bob, 1_000e6);
        for (uint256 i; i < k; i++) {
            uint256 loanId = _openBig(v, 100e6);
            _crank(v, loanId, T2, 0);
            _finalize(loanId);
        }
        _crankAll(v);
        assertEq(_carriedClasses(v), k, "every class settled, and the vault holds title in each");

        uint256 shares = v.maxRedeem(bob); // BEFORE the prank: a read is a call, and a call would eat it
        assertGt(shares, 0, "LIVENESS: there is a real exit to time");
        vm.prank(bob);
        uint256 g = gasleft();
        v.redeem(shares, bob, bob);
        used = g - gasleft();
    }
}
