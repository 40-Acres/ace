// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.36;

import {CuratorVaultBase} from "./CuratorVaultBase.sol";
import {CuratorVault} from "../../src/curator/CuratorVault.sol";
import {BorrowRequest} from "../../src/curator/AceVaultFlows.sol";
import {Ace} from "../../src/ace/hub/Ace.sol";
import {GateRefused} from "../../src/ace/hub/Lender.sol";
import {IAceLenderOps} from "../../src/interfaces/IAceLenderOps.sol";
import {ProtocolPolicy} from "../../src/config/Defaults.sol";

/// @title CuratorVaultSurfacePin
/// @notice THE HARD INVARIANT, pinned against the COMPILED ARTIFACT rather than against a reading of the source.
/// @notice The vault must never call `Ace.transfer`, `approve`, `setOperator`, `redeemInKind` or `multicall`,
/// @notice and must never pass a `to` other than itself. Each would put value it counts outside its own hands.
/// @dev A source review is not a rail: a later editor adds the call and the review does not re-run.
/// @dev The interface the vault holds the hub as makes the forbidden verbs a compile error; the `to` half is pinned on calldata.
contract CuratorVaultSurfacePinTest is CuratorVaultBase {
    uint256 internal constant SEED = 10_000e6;
    uint256 internal constant DRAW = 6_000e6;

    function setUp() public override {
        super.setUp();
        record.setMinPrice(T2);
    }

    // ---- the `to` half, pinned on the calldata the vault actually emits ----

    /// @dev The other half of the invariant: every hub call the vault makes names ITSELF as owner and payee.
    /// @dev `expectCall` matches the calldata as a prefix, so this pins the arguments up to the payee and not merely the selector.
    /// @dev The door opens the loan to the vault and withdraws every resting unit to the vault; the roll withdraws to the vault;
    /// @dev the crank's `collect` spends the vault's own pool and pays it to the vault.
    function test_Surface_EveryHubCallNamesTheVaultItselfAsOwnerAndPayee() public {
        CuratorVault v = _newVault(0);
        _lpDeposit(v, alice, SEED);

        uint64 tenor = ProtocolPolicy.MIN_TENOR;
        collateral.mint(borrower, COLL);
        vm.startPrank(borrower);
        collateral.approve(address(v), COLL);
        BorrowRequest memory r = _request(address(collateral), COLL, DRAW);
        r.arm = true;
        vm.expectCall(address(ace), abi.encodeWithSelector(IAceLenderOps.open.selector, mid, COLL, DRAW, tenor, address(v)));
        vm.expectCall(address(ace), abi.encodeCall(IAceLenderOps.withdraw, (mid, type(uint256).max, address(v), 0)));
        uint256 loanId = v.borrow(r, "", "");
        vm.stopPrank();

        _warpAtLeastTo(uint256(read.loan(loanId).expiry) - 1 hours);
        vm.expectCall(address(ace), abi.encodeCall(IAceLenderOps.withdraw, (mid, type(uint256).max, address(v), 0)));
        v.roll(loanId, "");

        vm.expectCall(address(ace), abi.encodeCall(Ace.collect, (v.asset(), address(v))));
        v.crank();
    }

    /// @dev THE RAIL'S MEMBER LIST, pinned: the interface id is the XOR of its selectors, so adding any member is red here.
    /// @dev A new exit on `IAceLenderOps` would compile in every vault; this is what makes the addition a decision.
    /// @dev Spelled from signature STRINGS, not `.selector`, so a member re-signed to new TYPES is red too.
    /// @dev BLIND TO A SAME-TYPE ARGUMENT SWAP: `collect(lender, quote)` became `collect(quote, to)` under one unchanged string.
    /// @dev The vault is the transient BORROWER of its door's loans, so the borrower verbs its door and roll run are members.
    /// @dev Still NOT members: `redeemInKind` and `multicall`, and `drawableOf`, whose only reader was the deleted recall.
    function test_Surface_TheLenderOpsRailHasExactlyItsNineteenMembers() public pure {
        bytes4 reads = bytes4(keccak256("POSITION_MANAGER()")) ^ bytes4(keccak256("POSITION_TITLE()")) ^ bytes4(keccak256("idToMarketParams(bytes32)"))
            ^ bytes4(keccak256("lenderAssets(address,address)")) ^ bytes4(keccak256("lenderOwed(address,address)"))
            ^ bytes4(keccak256("lenderUnresolved(address,address)")) ^ bytes4(keccak256("lenderByCollateral(address,address,address)"))
            ^ bytes4(keccak256("loanMarket(uint256)")) ^ bytes4(keccak256("restingOf(bytes32)")) ^ bytes4(keccak256("debtOf(uint256)"))
            ^ bytes4(keccak256("isClosed(uint256)")) ^ bytes4(keccak256("tryContinue(uint256)"));
        string memory params = string.concat(
            "(address,address,address,address,uint256,uint256,uint256,uint256,",
            "uint64,uint64,uint256,uint256,uint256,uint256,uint256,uint256,uint256,address,bool)"
        );
        bytes4 verbs = bytes4(keccak256(bytes(string.concat("createMarket(", params, ")")))) ^ bytes4(keccak256("deposit(bytes32,uint256)"))
            ^ bytes4(keccak256("withdraw(bytes32,uint256,address,uint256)")) ^ bytes4(keccak256("collect(address,address)"))
            ^ bytes4(keccak256("open(bytes32,uint256,uint256,uint64,address,(uint256,uint256,uint64))"))
            ^ bytes4(keccak256("setAutoRefinance(uint256,uint64,uint16,uint16)")) ^ bytes4(keccak256("refinanceByPolicy(uint256)"));
        assertEq(type(IAceLenderOps).interfaceId, reads ^ verbs, "IAceLenderOps gained, lost or re-signed a member");
    }

    /// @dev A crank and an exit in one block address TWO DIFFERENT PARTIES, and neither may borrow the other's.
    /// @dev The claim names the VAULT; only the exit names a receiver, and it pays out of the vault's own cash alone.
    /// @dev A claim addressed to the exiter would pay them twice: once at the hub and once out of the vault.
    function test_Surface_AClaimAndAnExitAddressTwoDifferentParties() public {
        CuratorVault v = _newVault(0);
        _lpDeposit(v, alice, SEED);
        _lpDeposit(v, bob, 1_000e6);
        uint256 loanId = _open(DRAW);
        _crank(v, loanId, T2, 0);
        _warpBy(30 days);
        _repay(loanId, DRAW / 2);

        /// @dev The instant exit's own bound is exitable cash; the ask only has to clear.
        uint256 sh = v.maxRedeem(bob); // hoisted: the read is a call, and it would eat the prank
        assertGt(sh, 0, "PREMISE: the rail admits him for something, or the exit leg never runs");
        uint256 keeperBefore = usdc.balanceOf(keeper);
        uint256 potBefore = read.invPotOf(mid, loanId);

        vm.expectCall(address(ace), abi.encodeCall(Ace.collect, (v.asset(), address(v))));
        v.crank(); // the claim leg: the vault's own pool, paid to the vault
        vm.prank(bob);
        uint256 got = v.redeem(sh, keeper, bob); // the exit leg: the ONLY one that names a receiver

        assertEq(usdc.balanceOf(keeper) - keeperBefore, got, "the exit paid its receiver, out of the vault's cash alone");
        assertEq(read.invPotOf(mid, loanId), potBefore, "and the claim gave that receiver no title");
        assertEq(usdc.balanceOf(address(v)), v.idle(), "the vault's balance and its idle agree after both legs");
    }

    // ---- single tenancy in the market's own params: the foundation the whole identity rests on ----

    /// @dev The market NAMES its one lender, and the name is in the id preimage, so it cannot move.
    /// @dev REPLACES the gate-predicate row: there is no contract left to interview, only a field to read.
    function test_Tenancy_TheMarketNamesTheVaultAsItsOneLender() public {
        CuratorVault v = _newVault(0);
        assertEq(ace.idToMarketParams(mid).lender, address(v), "the rig really did bind this market to this vault");
    }

    /// @dev Tenancy is a claim about the HUB's behaviour, so pin it there and not only on the params.
    /// @dev TOTAL over the address space, not merely over the addresses a test picked: one admitted
    /// @dev foreign deposit would make that market's aggregates permanently wrong for the vault.
    function testFuzz_Tenancy_TheHubRefusesAForeignDepositInAHeldMarket(address who, uint96 amt) public {
        vm.assume(who != address(0) && who.code.length == 0);
        CuratorVault v = _newVault(0);
        vm.assume(who != address(v));
        uint256 a = bound(uint256(amt), 10e6, 1_000_000e6);

        usdc.mint(who, a);
        vm.startPrank(who);
        usdc.approve(address(ace), a);
        vm.expectRevert(GateRefused.selector);
        ace.deposit(mid, a);
        vm.stopPrank();

        assertEq(ace.restingOf(mid), 0, "nothing rested, so no foreign cash can ever enter the aggregate");
        assertEq(v.grossNav(), _hubTruthNav(v), "and the aggregate the vault reads is still wholly its own");
    }
}
