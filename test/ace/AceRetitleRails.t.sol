// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.36;

import {WarpClock} from "../utils/WarpClock.sol";
import {Ace} from "../../src/ace/hub/Ace.sol";
import {ExitToCustodian, ExitToHub} from "../../src/ace/hub/libraries/Recipients.sol";
import {MarketParams, OpenBounds} from "../../src/ace/hub/Types.sol";
import {PositionManager} from "../../src/ace/positions/PositionManager.sol";
import {PositionTitleNFT} from "../../src/ace/positions/PositionTitleNFT.sol";
import {RevenueRouter} from "../../src/ace/treasury/RevenueRouter.sol";
import {MockERC20} from "../mocks/MockERC20.sol";
import {MockPersistenceRecord} from "../mocks/MockPersistenceRecord.sol";
import {AceFixtures} from "../utils/AceFixtures.sol";
import {AceReader} from "../utils/AceReader.sol";

/// @title AceRetitleRails
/// @notice Run 251533 Y-12. Leg B: a title never moves to the hub, the positionManager, the title collection or the treasury.
/// @notice Leg A, a title move disarming an armed loan in a named market, went with arming; AceExtend pins the named market's gate.
contract AceRetitleRailsTest is WarpClock {
    Ace internal ace;
    AceReader internal read;
    PositionManager internal pm;
    PositionTitleNFT internal title;
    MockERC20 internal usdc;
    MockERC20 internal coll;
    bytes32 internal named; // a market naming `holder` as its one borrower
    bytes32 internal open; // the same terms, naming nobody

    address internal alice = AceFixtures.LENDER;
    address internal holder = address(0xB0B);
    address internal buyer = address(0xB0B2);
    address internal market = address(0x3A2E7); // an escrowing marketplace, the sale's natural counterparty
    address internal keeper = address(0xCAFE);

    uint64 internal constant TEN7 = 7 days;
    uint256 internal constant P = 50_000e6;
    uint256 internal constant UNITS = 100_000e18;

    bytes4 internal constant RETITLE_TO_COLLECTION = bytes4(keccak256("RetitleToCollection()"));

    function setUp() public {
        _warpTo(1_000_000);
        usdc = new MockERC20("USD Coin", "USDC", 6);
        coll = new MockERC20("Collateral", "COLL", 18);
        MockPersistenceRecord rec = new MockPersistenceRecord(address(usdc), address(coll));
        rec.setMinPrice(AceFixtures.px(1.1e18, address(usdc), address(coll)));
        MarketParams memory p = AceFixtures.marketParams(address(usdc), address(coll));
        p.record = address(rec);
        p.minTenor = TEN7;
        p.maxTenor = TEN7;
        AceFixtures.Deployment memory d = AceFixtures.deploy(p);
        (ace, pm, read, open) = (d.ace, d.positionManager, d.read, d.id);
        p.borrower = holder;
        named = ace.createMarket(p);
        title = PositionTitleNFT(ace.POSITION_TITLE());
        _deposit(open);
        _deposit(named);
    }

    function _deposit(bytes32 m) internal {
        usdc.mint(alice, 4 * P);
        vm.startPrank(alice);
        usdc.approve(address(ace), 4 * P);
        ace.deposit(m, 4 * P);
        vm.stopPrank();
    }

    function _openIn(bytes32 m) internal returns (uint256 loanId) {
        coll.mint(holder, UNITS);
        vm.startPrank(holder);
        coll.approve(address(pm), UNITS);
        loanId = ace.open(m, UNITS, P, TEN7, holder, OpenBounds(0, 0, 0));
        vm.stopPrank();
    }

    /// @notice Leg B: a title sent to the hub is refused, `ExitToHub`, as every exit refuses it.
    function test_ATitleCannotBeSentToTheHub() public {
        uint256 loanId = _openIn(open);
        vm.prank(holder);
        vm.expectRevert(ExitToHub.selector);
        title.transferFrom(holder, address(ace), loanId);
    }

    /// @notice Leg B: a title sent to the positionManager is refused, `ExitToCustodian`.
    function test_ATitleCannotBeSentToThePositionManager() public {
        uint256 loanId = _openIn(open);
        vm.prank(holder);
        vm.expectRevert(ExitToCustodian.selector);
        title.transferFrom(holder, address(pm), loanId);
    }

    /// @notice Leg B: a title sent to the title collection itself is refused: it could neither move the token nor claim for it.
    function test_ATitleCannotBeSentToTheTitleCollection() public {
        uint256 loanId = _openIn(open);
        vm.prank(holder);
        vm.expectRevert(RETITLE_TO_COLLECTION);
        title.transferFrom(holder, address(title), loanId);
    }

    // Leg A's seven disarm-on-retitle rows went with arming: a title move now writes only the holder
}

/// @title AceRetitleRailsTreasury
/// @notice Leg B's fourth sink, from the scoped re-run (R-1): a title never moves to the hub's own TREASURY.
/// @dev Deployed with a real `RevenueRouter` as `TREASURY`, as production is: it can neither `claimOwed` nor move a title.
contract AceRetitleRailsTreasuryTest is WarpClock {
    Ace internal ace;
    AceReader internal read;
    PositionManager internal pm;
    PositionTitleNFT internal title;
    MockERC20 internal usdc;
    MockERC20 internal coll;
    RevenueRouter internal router;
    bytes32 internal id;

    address internal alice = AceFixtures.LENDER;
    address internal holder = address(0xB0B);
    address internal stranger = address(0x57A2);

    uint64 internal constant TEN7 = 7 days;
    uint256 internal constant P = 50_000e6;
    uint256 internal constant UNITS = 100_000e18;

    bytes4 internal constant RETITLE_TO_TREASURY = bytes4(keccak256("RetitleToTreasury()"));
    address internal constant WALLET = AceFixtures.TREASURY; // a codeless treasury, as the playground binds a plain wallet

    function setUp() public {
        _warpTo(1_000_000);
        usdc = new MockERC20("USD Coin", "USDC", 6);
        coll = new MockERC20("Collateral", "COLL", 18);
        MockPersistenceRecord rec = new MockPersistenceRecord(address(usdc), address(coll));
        rec.setMinPrice(AceFixtures.px(1.1e18, address(usdc), address(coll)));
        router = new RevenueRouter(address(this), address(0x5151));
        MarketParams memory p = AceFixtures.marketParams(address(usdc), address(coll));
        p.record = address(rec);
        p.minTenor = TEN7;
        p.maxTenor = TEN7;
        AceFixtures.Deployment memory d = AceFixtures.deployWithTreasury(p, address(router));
        (ace, pm, read, id) = (d.ace, d.positionManager, d.read, d.id);
        title = PositionTitleNFT(ace.POSITION_TITLE());
        usdc.mint(alice, 4 * P);
        vm.startPrank(alice);
        usdc.approve(address(ace), 4 * P);
        ace.deposit(id, 4 * P);
        vm.stopPrank();
    }

    function _openSwept() internal returns (uint256 loanId) {
        coll.mint(holder, UNITS);
        vm.startPrank(holder);
        coll.approve(address(pm), UNITS);
        loanId = ace.open(id, UNITS, P, TEN7, holder, OpenBounds(0, 0, 0));
        ace.sweepRevenue(id);
        vm.stopPrank();
        assertGt(usdc.balanceOf(address(router)), 0, "PREMISE: the router IS the hub's treasury: the sweep paid it");
    }

    /// @notice A title sent to the treasury is refused by name, `RetitleToTreasury`.
    function test_ATitleCannotBeSentToTheTreasury() public {
        uint256 loanId = _openSwept();
        vm.prank(holder);
        vm.expectRevert(RETITLE_TO_TREASURY);
        title.transferFrom(holder, address(router), loanId);
    }

    /// @notice The refused move leaves the holder titled, so a payoff credits the holder and owes the treasury nothing on either leg.
    function test_ARefusedTreasuryMoveLeavesThePayoffWithTheHolder() public {
        uint256 loanId = _openSwept();
        vm.prank(holder);
        try title.transferFrom(holder, address(router), loanId) {} catch {}
        assertEq(title.ownerOf(loanId), holder, "the title stayed with the holder");
        assertEq(ace.borrowerOf(loanId), holder, "and so did the hub's record of it");
        uint256 debt = read.debtOf(loanId);
        usdc.mint(stranger, debt);
        vm.startPrank(stranger);
        usdc.approve(address(ace), debt);
        ace.repay(loanId, debt);
        vm.stopPrank();
        (uint256 units, uint256 amount) = ace.owedOf(loanId, address(router));
        assertEq(units, 0, "no lot is owed to the treasury, which can neither claim it nor move the title");
        assertEq(amount, 0, "nor any quote");
        (uint256 heldUnits,) = ace.owedOf(loanId, holder);
        assertEq(heldUnits, UNITS, "the whole lot is owed to the holder");
    }

    /// @notice Both `safeTransferFrom` overloads route through `transferFrom` into `retitle`, so the hub refuses them by name too.
    /// @dev Without the hub's rail the router's missing receiver hook still refuses them, but as `ERC721InvalidReceiver`.
    function test_TheSafeTransfersToTheTreasuryAreRefusedByName() public {
        uint256 loanId = _openSwept();
        vm.startPrank(holder);
        vm.expectRevert(RETITLE_TO_TREASURY);
        title.safeTransferFrom(holder, address(router), loanId);
        vm.expectRevert(RETITLE_TO_TREASURY);
        title.safeTransferFrom(holder, address(router), loanId, "");
        vm.stopPrank();
        assertEq(ace.borrowerOf(loanId), holder, "the holder keeps the title");
    }

    /// @notice A second hub on the same terms whose treasury is `WALLET`, funded by `alice`.
    function _walletHub() internal returns (AceFixtures.Deployment memory d) {
        assertEq(WALLET.code.length, 0, "PREMISE: the treasury is a plain wallet");
        MockPersistenceRecord rec = new MockPersistenceRecord(address(usdc), address(coll));
        rec.setMinPrice(AceFixtures.px(1.1e18, address(usdc), address(coll)));
        MarketParams memory p = AceFixtures.marketParams(address(usdc), address(coll));
        p.record = address(rec);
        p.minTenor = TEN7;
        p.maxTenor = TEN7;
        d = AceFixtures.deployWithTreasury(p, WALLET);
        usdc.mint(alice, 4 * P);
        vm.startPrank(alice);
        usdc.approve(address(d.ace), 4 * P);
        d.ace.deposit(d.id, 4 * P);
        vm.stopPrank();
    }

    /// @notice Opens a loan on `d` in `who`'s own name, then proves `WALLET` is that hub's treasury by a sweep that pays it.
    function _openOnWalletHub(AceFixtures.Deployment memory d, address who) internal returns (uint256 loanId) {
        coll.mint(who, UNITS);
        vm.startPrank(who);
        coll.approve(address(d.positionManager), UNITS);
        loanId = d.ace.open(d.id, UNITS, P, TEN7, who, OpenBounds(0, 0, 0));
        vm.stopPrank();
        uint256 before = usdc.balanceOf(WALLET);
        d.ace.sweepRevenue(d.id);
        assertGt(usdc.balanceOf(WALLET), before, "PREMISE: the wallet IS this hub's treasury: the sweep paid it");
    }

    /// @notice A plain-wallet treasury is refused by the same name: the rail keys on the address, never on code at it.
    function test_APlainWalletTreasuryIsRefusedToo() public {
        AceFixtures.Deployment memory d = _walletHub();
        PositionTitleNFT t = PositionTitleNFT(d.ace.POSITION_TITLE());
        uint256 loanId = _openOnWalletHub(d, holder);
        vm.prank(holder);
        vm.expectRevert(RETITLE_TO_TREASURY);
        t.transferFrom(holder, WALLET, loanId);
    }

    /// @notice The rail is one-way: a wallet treasury that opened in its own name may still send its title on.
    function test_ATreasuryHoldingATitleMaySendItOn() public {
        AceFixtures.Deployment memory d = _walletHub();
        PositionTitleNFT t = PositionTitleNFT(d.ace.POSITION_TITLE());
        uint256 loanId = _openOnWalletHub(d, WALLET);
        assertEq(d.ace.borrowerOf(loanId), WALLET, "PREMISE: the treasury holds the title");
        vm.prank(WALLET);
        t.transferFrom(WALLET, holder, loanId);
        assertEq(t.ownerOf(loanId), holder, "the title left the treasury");
        assertEq(d.ace.borrowerOf(loanId), holder, "and the hub's record moved with it");
    }
}
