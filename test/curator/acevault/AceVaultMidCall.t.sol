// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.36;

import {MockPersistenceRecord} from "../../mocks/MockPersistenceRecord.sol";
import {AceVault} from "../../../src/curator/AceVault.sol";
import {BorrowRequest} from "../../../src/curator/AceVaultFlows.sol";
import {CuratorVault, Listing} from "../../../src/curator/CuratorVault.sol";
import {AceVaultRig} from "./AceVaultRig.sol";

/// @notice A collateral whose pull into custody reads the vault's views, from inside the hub's open.
contract PeekingCollateral {
    uint8 public constant decimals = 18;
    mapping(address => uint256) public balanceOf;
    mapping(address => mapping(address => uint256)) public allowance;
    uint256 public totalSupply;

    address public peekAt; // the vault to read
    address public custody; // the puller whose transfer triggers the read
    address public lp; // the holder whose exit the read prices
    bool public lendOk;
    uint256 public lendSeen;
    bool public navOk;
    uint256 public navSeen;
    bool public exitOk;
    uint256 public exitSeen;

    function arm(address vault, address manager, address holder) external {
        (peekAt, custody, lp) = (vault, manager, holder);
    }

    function mint(address to, uint256 amount) external {
        balanceOf[to] += amount;
        totalSupply += amount;
    }

    function approve(address spender, uint256 amount) external returns (bool) {
        allowance[msg.sender][spender] = amount;
        return true;
    }

    function transfer(address to, uint256 amount) external returns (bool) {
        balanceOf[msg.sender] -= amount;
        balanceOf[to] += amount;
        return true;
    }

    function transferFrom(address from, address to, uint256 amount) external returns (bool) {
        if (msg.sender == custody && peekAt != address(0)) _peek();
        allowance[from][msg.sender] -= amount;
        balanceOf[from] -= amount;
        balanceOf[to] += amount;
        return true;
    }

    uint256 public peeks; // how many custody pulls read the views

    function _peek() internal {
        peeks++;
        bytes memory r;
        (lendOk, r) = peekAt.staticcall(abi.encodeCall(AceVault.lendable, ()));
        if (lendOk) lendSeen = abi.decode(r, (uint256));
        (navOk, r) = peekAt.staticcall(abi.encodeWithSignature("totalAssets()"));
        if (navOk) navSeen = abi.decode(r, (uint256));
        (exitOk, r) = peekAt.staticcall(abi.encodeWithSignature("maxWithdraw(address)", lp));
        if (exitOk) exitSeen = abi.decode(r, (uint256));
    }
}

/// @notice Read from inside the door's hub call, the vault's views refuse or answer the pre-door figure: never the bracket's rested zero.
contract AceVaultMidCallTest is AceVaultRig {
    PeekingCollateral internal peek;
    CuratorVault internal pv;

    function setUp() public override {
        super.setUp();
        peek = new PeekingCollateral();
        MockPersistenceRecord r = _record(address(peek), 2e18);
        Listing[] memory l = new Listing[](1);
        l[0] = Listing({collateral: address(peek), row: _row(address(r), type(uint192).max)});
        pv = new CuratorVault(_cfg(), MIN_DEBT, COVERAGE, TIMELOCK, l, "Peek", "PEEK");
        usdc.mint(alice, LP_CASH);
        vm.startPrank(alice);
        usdc.approve(address(pv), LP_CASH);
        pv.deposit(LP_CASH, alice);
        vm.stopPrank();
        peek.arm(address(pv), address(pm), alice);
    }

    function test_MidDoorViewsNeverReadTheRestedZero() public {
        uint256 lend0 = pv.lendable();
        uint256 nav0 = pv.totalAssets();
        uint256 exit0 = pv.maxWithdraw(alice);
        assertGt(lend0, 0, "premise: the vault can lend");
        peek.mint(borrower, UNITS);
        BorrowRequest memory q = _req(UNITS, PRINCIPAL, MIN_TENOR, false);
        q.collateral = address(peek);
        vm.startPrank(borrower);
        peek.approve(address(pv), UNITS);
        pv.borrow(q, "", "");
        vm.stopPrank();
        assertEq(peek.peeks(), 1, "premise: custody's pull inside the hub's open read the views");
        assertFalse(peek.lendOk(), "lendable refused mid-hub: its holds price requests off the hub's guarded pool");
        assertTrue(!peek.lendOk() || peek.lendSeen() == lend0, "lendable refused or read the pre-door figure");
        assertTrue(!peek.navOk() || peek.navSeen() == nav0, "totalAssets refused or read the pre-door figure");
        assertTrue(!peek.exitOk() || peek.exitSeen() == exit0, "maxWithdraw refused or read the pre-door figure");
    }
}
