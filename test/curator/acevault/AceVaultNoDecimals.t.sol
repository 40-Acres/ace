// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.36;

import {MockStakeVault} from "../../mocks/MockStakeVault.sol";
import {MockPersistenceRecord} from "../../mocks/MockPersistenceRecord.sol";
import {WarpClock} from "../../utils/WarpClock.sol";
import {AceFixtures} from "../../utils/AceFixtures.sol";
import {Ace} from "../../../src/ace/hub/Ace.sol";
import {VaultConfig} from "../../../src/curator/AceVault.sol";
import {BorrowRequest} from "../../../src/curator/AceVaultFlows.sol";
import {CuratorVault, Listing, Row} from "../../../src/curator/CuratorVault.sol";

/// @notice A cash token that answers no `decimals()`.
contract NoDecimalsCash {
    mapping(address => uint256) public balanceOf;
    mapping(address => mapping(address => uint256)) public allowance;
    uint256 public totalSupply;

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
        allowance[from][msg.sender] -= amount;
        balanceOf[from] -= amount;
        balanceOf[to] += amount;
        return true;
    }
}

/// @notice No construction rail refuses a cash with no `decimals()`: the vault deploys, its first borrow reverts at the hub, and entry and exit still work.
contract AceVaultNoDecimalsTest is WarpClock {
    function test_ACashWithNoDecimalsDeploysLendsNothingAndStillExits() public {
        _warpTo(1_000_000);
        Ace ace = AceFixtures.newAce();
        NoDecimalsCash cash = new NoDecimalsCash();
        MockStakeVault coll = new MockStakeVault(3);
        MockPersistenceRecord rec = new MockPersistenceRecord(address(0), address(0)); // an unframed build reads no decimals
        rec.setFrame(address(cash), address(coll));
        rec.setMinPrice(1 << 96);
        Listing[] memory l = new Listing[](1);
        l[0] = Listing({
            collateral: address(coll),
            row: Row({record: address(rec), bufferBps: 1000, baseBps: 40, minTenor: 7 days, maxTenor: 30 days, cap: type(uint192).max})
        });
        VaultConfig memory cfg =
            VaultConfig({ace: address(ace), asset: address(cash), curator: address(0xC0A11), guardian: address(0), perfFeeBps: 0, vestWindow: 1 days});
        CuratorVault v = new CuratorVault(cfg, 10e6, 1.4e18, 3 days, l, "NoDec", "ND");
        address lp = address(0xA11CE);
        cash.mint(lp, 1_000_000e6);
        vm.startPrank(lp);
        cash.approve(address(v), 1_000_000e6);
        uint256 shares = v.deposit(1_000_000e6, lp);
        vm.stopPrank();
        assertGt(shares, 0, "a deposit works");
        address who = address(0xB0BA);
        coll.mint(who, 2_000e18);
        vm.startPrank(who);
        coll.approve(address(v), 2_000e18);
        vm.expectRevert();
        v.borrow(BorrowRequest(address(coll), 2_000e18, 1_000e6, 7 days, false, 0, 0, 0), "", "");
        vm.stopPrank();
        uint256 half = shares / 2;
        vm.prank(lp);
        uint256 paid = v.redeem(half, lp, lp);
        assertGt(paid, 0, "an instant exit works");
        assertEq(cash.balanceOf(lp), paid, "and pays the holder");
    }
}
