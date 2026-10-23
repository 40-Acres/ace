// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.36;

import {CuratorVaultBase} from "./CuratorVaultBase.sol";
import {CuratorVault, Listing} from "../../src/curator/CuratorVault.sol";
import {AceVault, VaultConfig} from "../../src/curator/AceVault.sol";
import {BorrowRequest} from "../../src/curator/AceVaultFlows.sol";
import {GUARD_TRIP} from "../utils/GuardTrip.sol";
import {MarketParams} from "../../src/ace/hub/Types.sol";
import {PocDeployConfig} from "../../src/config/Defaults.sol";
import {AceFixtures} from "../utils/AceFixtures.sol";
import {MockPersistenceRecord} from "../mocks/MockPersistenceRecord.sol";

/// @notice A quote token that re-enters one armed call on every move, so the vault's mutex can be exercised.
/// @dev Every other ERC20 mock in this tree is hook-free, and without a hook the guard is untestable.
/// @dev The callback's revert is BUBBLED, or the mutex's own error never reaches the assertion.
contract ReenteringERC20 {
    string public name = "Reenter";
    string public symbol = "RNT";
    uint8 public constant decimals = 6;

    mapping(address => uint256) public balanceOf;
    mapping(address => mapping(address => uint256)) public allowance;
    uint256 public totalSupply;
    address public target; // zero disarms the hook entirely
    bytes public payload;

    function arm(address who, bytes calldata data) external {
        target = who;
        payload = data;
    }

    function mint(address to, uint256 a) external {
        balanceOf[to] += a;
        totalSupply += a;
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
        uint256 al = allowance[f][msg.sender];
        if (al != type(uint256).max) allowance[f][msg.sender] = al - a;
        _move(f, to, a);
        return true;
    }

    function _move(address f, address t, uint256 a) private {
        balanceOf[f] -= a;
        balanceOf[t] += a;
        if (target == address(0)) return;
        (bool ok, bytes memory err) = target.call(payload);
        if (ok) return;
        assembly ("memory-safe") {
            revert(add(err, 32), mload(err))
        }
    }
}

/// @title CuratorVaultSoleLender
/// @notice THE IDENTITY THE POOLED NAV RESTS ON: these aggregates are this vault's, and only its.
/// @notice The market's `lender` field is what makes the claim TRUE, and the door writes it from the vault's own address.
/// @notice Also the one thing single tenancy does NOT give away by itself: the foreign-market drain.
/// @dev Successor to `CuratorVaultDerivedRegistration.t.sol`, whose subject (the cost book) is deleted.
contract CuratorVaultSoleLenderTest is CuratorVaultBase {
    uint256 internal constant SEED = 50_000e6;
    uint256 internal constant DRAW = 6_000e6;
    address internal stranger = address(0x57A11);

    function setUp() public override {
        super.setUp();
        record.setMinPrice(T2);
    }

    /// @dev A market naming NOBODY cannot exist at all: genesis refuses a zero lender outright.
    /// @dev REPLACES `testRevert_AdoptMarket_AnUngatedMarketIsRefused`, whose subject -- a market open to
    /// @dev every lender alive -- is unrepresentable rather than merely refused.
    function testRevert_CreateMarket_AZeroLenderIsRefusedAtGenesis() public {
        _newVault(0);
        MarketParams memory p = AceFixtures.marketParams(address(usdc), address(collateral)); // built first: the builder itself makes calls
        p.record = address(record);
        p.lender = address(0);
        vm.expectRevert(bytes("lender required"));
        ace.createMarket(p);
    }

    /// @dev DELETED: `testRevert_AdoptMarket_AMarketThatAlreadyHoldsValueIsRefused`, with `MarketNotEmpty`.
    /// @dev Sole tenancy names ONE lender in the market's own id preimage and the door builds that lender as the vault
    /// @dev itself, so a market holding value the vault does not own is never one it lends in.

    /// @dev DELETED: `testRevert_CreateMarket_TheCapBinds`, with `MAX_MARKETS` and `TooManyMarkets`.
    /// @dev The cap bounded the NAV WALK, which sat on the entry and the exit alike, so an LP paid per market.
    /// @dev `grossNav` is two reads at any count now -- the balance and the aggregates keyed by (lender, quote) across
    /// @dev every market the vault runs -- so there is no walk to bound.
    /// @dev `CuratorVaultMarketGas.t.sol` priced the cap and now pins the FLATNESS that replaced it.

    // ---- the foreign market: the drain single tenancy does NOT close by itself ----

    /// @dev THE DRAIN IS CLOSED BY THE KEY, not by a guard. `collect` pays in the MARKET's quote, so an
    /// @dev unbound call was a drain that needed no shares. The crank takes no market: it sweeps the vault's own pool,
    /// @dev keyed by (lender, quote), and a foreign market's credit is keyed to somebody else and simply unreachable.
    /// @dev The two vault verbs that take a loan id reach no further: `crank(closed)` passed the stranger's loan changes nothing,
    /// @dev and `roll` refuses it by name before any hub call that could move value.
    function test_Crank_AForeignMarketIsOutsideThePool() public {
        CuratorVault v = _newVault(0);
        _lpDeposit(v, alice, SEED);
        bytes32 foreign = _marketLike(12e6, stranger);
        _lendDirectIn(stranger, foreign, 4_000e6);
        uint256 theirs = _openIn(foreign, 2_000e6);

        uint256 navBefore = v.grossNav();
        uint256 idleBefore = v.idle();
        v.crank();
        assertEq(v.grossNav(), navBefore, "a stranger's market is outside the pool the crank sweeps");

        uint256[] memory ids = new uint256[](1);
        ids[0] = theirs;
        v.crank(ids);
        assertEq(v.rollHold(), 0, "the stranger's loan was never on the vault's books");
        assertEq(v.grossNav(), navBefore, "and pruning it moved no NAV");
        assertEq(v.idle(), idleBefore, "and no cash");

        vm.expectRevert(AceVault.NotOurLoan.selector);
        v.roll(theirs, "");
    }

    // ---- multi-market: the pool is one position, never a single market assumed ----

    /// @dev Two door markets on one vault: NAV counts both, and ONE crank sweeps what both earned.
    /// @dev THE CREDIT POOLS PER (lender, quote), so there is nothing finer than the pool for a crank to name.
    /// @dev The second market is the door's at a lower record print, so the two loans sit in two ids.
    function test_MultiMarket_NavCountsBothAndOneCrankSweepsThem() public {
        CuratorVault v = _newVault(0);
        _lpDeposit(v, alice, SEED);
        uint256 here = _open(DRAW);
        MockPersistenceRecord(v.rowOf(address(collateral)).record).setMinPrice(AceFixtures.px(18e17, address(usdc), address(collateral)));
        uint256 there = _borrow(v, DRAW);
        assertTrue(ace.loanMarket(there) != ace.loanMarket(here), "PREMISE: the two loans sit in two markets");

        assertEq(v.grossNav(), _hubTruthNav(v), "both markets are in the aggregate before anybody cranks");
        assertGt(lens.claimable(address(v), v.asset()), 0, "the two draws really left credit waiting to be swept");
        uint256 navBefore = v.grossNav();
        uint256 idleBefore = v.idle();
        uint256 owed = lens.claimable(address(v), v.asset());
        v.crank();

        assertEq(lens.claimable(address(v), v.asset()), 0, "one lap emptied the pool BOTH markets paid into");
        assertEq(v.idle(), idleBefore + owed, "the credit moved from the pool into idle");
        assertEq(v.grossNav(), navBefore, "the lap is NAV-neutral");
        assertEq(v.grossNav(), _hubTruthNav(v), "the two-market read still agrees with the hub");
    }

    // ---- the mutex ----

    /// @dev The hostile asset re-enters mid-`transferFrom`, which is the one window a 4626 deposit opens.
    /// @dev Every state-changing verb syncs, so a re-entrant one would read a half-moved counter.
    /// @dev The vault lists nothing: the rows here are about the mutex, and a row's record would have to price the hostile asset.
    function test_Reentrancy_TheCrankAndRequestVerbsAreBehindTheMutex() public {
        ReenteringERC20 tok = new ReenteringERC20();
        VaultConfig memory cfg = _cfg(0);
        cfg.asset = address(tok);
        CuratorVault v = new CuratorVault(cfg, RIG_MIN_DEBT, PocDeployConfig.MIN_COVERAGE_WAD, RIG_TIMELOCK, new Listing[](0), "Hostile", "cHOST");

        tok.mint(bob, 10_000e6);
        vm.prank(bob);
        tok.approve(address(v), type(uint256).max);
        vm.prank(bob);
        assertGt(v.deposit(1_000e6, bob), 0, "the control: an unarmed token deposits normally");

        tok.arm(address(v), abi.encodeWithSignature("crank()"));
        vm.prank(bob);
        vm.expectRevert(GUARD_TRIP);
        v.deposit(1_000e6, bob);

        tok.arm(address(v), abi.encodeWithSignature("crank(uint256[])", new uint256[](0)));
        vm.prank(bob);
        vm.expectRevert(GUARD_TRIP);
        v.deposit(1_000e6, bob);

        tok.arm(address(v), abi.encodeCall(AceVault.requestExit, (1)));
        vm.prank(bob);
        vm.expectRevert(GUARD_TRIP);
        v.deposit(1_000e6, bob);

        tok.arm(address(v), abi.encodeCall(AceVault.borrow, (_request(address(collateral), COLL, 100e6), "", "")));
        vm.prank(bob);
        vm.expectRevert(GUARD_TRIP);
        v.deposit(1_000e6, bob);

        tok.arm(address(v), abi.encodeCall(AceVault.roll, (1, "")));
        vm.prank(bob);
        vm.expectRevert(GUARD_TRIP);
        v.deposit(1_000e6, bob);

        tok.arm(address(v), abi.encodeCall(AceVault.collectFee, ()));
        vm.prank(bob);
        vm.expectRevert(GUARD_TRIP);
        v.mint(1e12, bob);
    }

    // ---- what a dead lens costs the vault ----

    /// @dev THE TRUST BOUNDARY, pinned positively: the lens is NOT audited, so no vault path may need it.
    /// @dev A DEAD LENS COSTS THIS VAULT NOTHING. Every verb below runs against an address holding no code.
    /// @dev The aggregate NAV reads the hub's own guarded `lenderAssets`, the crank is one `collect`, and the door asks the hub alone.
    /// @dev Assertions are SUCCESSES, not absent reverts: a passing `expectRevert` proves nothing about why.
    function test_Exit_ADeadLensCostsTheVaultNothingOnAnyPath() public {
        CuratorVault v = _newVault(0);
        uint256 shares = _lpDeposit(v, alice, SEED);
        _open(DRAW);
        vm.etch(address(lens), hex""); // the lens address holds no code from here on

        assertEq(v.maxDeposit(alice), type(uint256).max, "the entry ceilings still answer without asking anyone");
        assertEq(v.maxMint(alice), type(uint256).max, "on the mint side too");
        assertGt(v.grossNav(), 0, "NAV answers off the hub alone");
        assertGt(_open(DRAW), 0, "a door borrow lands with the lens dead");
        vm.prank(alice);
        v.requestExit(shares / 4); // the exit's first door, and it runs against the dead lens too
        assertGt(v.maxClaim(alice), 0, "the EXIT ceiling answers with the lens dead");

        v.crank(); // the last path that used the lens; it now asks the hub for one number

        /// @dev THE ASK IS WHAT EXITABLE CASH COVERS; this row is about the dead lens, not the size.
        uint256 fill = v.maxClaim(alice); // BEFORE the prank: a read is a call, and a call would eat it
        assertGt(fill, 0, "the claim ceiling quotes a servable part in share terms, with the lens dead");
        vm.prank(alice);
        assertGt(v.claimExit(fill, alice, 0), 0, "and a real exit settles with the lens dead");
    }
}
