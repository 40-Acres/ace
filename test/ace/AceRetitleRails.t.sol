// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.36;

import {Vm} from "forge-std/Vm.sol";
import {WarpClock} from "../utils/WarpClock.sol";
import {Ace} from "../../src/ace/hub/Ace.sol";
import {GateRefused} from "../../src/ace/hub/Borrower.sol";
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
/// @notice Leg A: in a market that names its borrower, any title move disarms a live armed loan; an open market keeps the policy.
/// @dev A disarm releases the share and logs `AutoPolicySet(id, 0, 0, 0)`; a closed loan's stale policy entry is left alone.
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
    bytes32 internal constant AUTO_POLICY_SET = keccak256("AutoPolicySet(uint256,uint64,uint16,uint16)");

    event AutoPolicySet(uint256 indexed id, uint64 tenor, uint16 minBufferBps, uint16 maxFeeBps);

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

    function _openArmed(bytes32 m) internal returns (uint256 loanId) {
        coll.mint(holder, UNITS);
        vm.startPrank(holder);
        coll.approve(address(pm), UNITS);
        loanId = ace.open(m, UNITS, P, TEN7, holder, OpenBounds(0, 0, 0));
        ace.setAutoRefinance(loanId, TEN7, 500, 0);
        vm.stopPrank();
    }

    function _move(address from, address to, uint256 loanId) internal {
        vm.prank(from);
        title.transferFrom(from, to, loanId);
    }

    function _tenor(uint256 loanId) internal view returns (uint64 t) {
        (t,,) = read.autoPolicyOf(loanId);
    }

    /// @notice Leg B: a title sent to the hub is refused, `ExitToHub`, as every exit refuses it.
    function test_ATitleCannotBeSentToTheHub() public {
        uint256 loanId = _openArmed(open);
        vm.prank(holder);
        vm.expectRevert(ExitToHub.selector);
        title.transferFrom(holder, address(ace), loanId);
    }

    /// @notice Leg B: a title sent to the positionManager is refused, `ExitToCustodian`.
    function test_ATitleCannotBeSentToThePositionManager() public {
        uint256 loanId = _openArmed(open);
        vm.prank(holder);
        vm.expectRevert(ExitToCustodian.selector);
        title.transferFrom(holder, address(pm), loanId);
    }

    /// @notice Leg B: a title sent to the title collection itself is refused: it could neither move the token nor claim for it.
    function test_ATitleCannotBeSentToTheTitleCollection() public {
        uint256 loanId = _openArmed(open);
        vm.prank(holder);
        vm.expectRevert(RETITLE_TO_COLLECTION);
        title.transferFrom(holder, address(title), loanId);
    }

    /// @notice Leg A's scope: an OPEN market's armed loan keeps its policy and its share across a sale.
    function test_AnOpenMarketKeepsThePolicyAcrossATitleMove() public {
        uint256 loanId = _openArmed(open);
        uint256 held = read.rollReserve(open);
        _move(holder, buyer, loanId);
        assertEq(_tenor(loanId), TEN7, "the policy travels with the position");
        assertEq(read.rollReserve(open), held, "and so does its reservation");
    }

    /// @notice Leg A: in a named market ANY title move disarms, a sale into an escrowing marketplace included.
    function test_ANamedMarketDisarmsOnAnyTitleMove() public {
        uint256 loanId = _openArmed(named);
        assertGt(read.rollReserve(named), 0, "PREMISE: armed and reserved");
        vm.expectEmit(true, false, false, true, address(ace));
        emit AutoPolicySet(loanId, 0, 0, 0);
        _move(holder, market, loanId);
        assertEq(_tenor(loanId), 0, "the move into the marketplace disarmed the loan");
        assertEq(read.rollReserve(named), 0, "and released its reservation");
        assertEq(ace.borrowerOf(loanId), market, "while the title moved as asked");
    }

    /// @notice Leg A: the named borrower may re-arm once the title is back in its hands.
    function test_TheNamedBorrowerReArmsWhenTheTitleComesBack() public {
        uint256 loanId = _openArmed(named);
        _move(holder, buyer, loanId);
        _move(buyer, holder, loanId);
        assertEq(_tenor(loanId), 0, "still disarmed: the round trip restored nothing");
        vm.prank(holder);
        ace.setAutoRefinance(loanId, TEN7, 500, 0);
        assertEq(_tenor(loanId), TEN7, "the named holder arms again");
    }

    /// @notice An UNARMED loan's title move in a named market logs no disarm and keeps what its entry stored.
    /// @dev A tenor-zero arm still stores its buffer; a disarm that skipped the tenor test would delete it and log zeros.
    function test_AnUnarmedLoansTitleMoveLogsNoDisarmAndKeepsItsEntry() public {
        uint256 loanId = _openArmed(named);
        vm.prank(holder);
        ace.setAutoRefinance(loanId, 0, 500, 0); // a disarm that keeps a buffer on file
        (uint64 t0, uint16 b0,) = read.autoPolicyOf(loanId);
        assertEq(uint256(t0), 0, "PREMISE: disarmed");
        assertEq(uint256(b0), 500, "PREMISE: with its buffer stored");
        vm.recordLogs();
        _move(holder, buyer, loanId);
        Vm.Log[] memory logs = vm.getRecordedLogs();
        for (uint256 i; i < logs.length; i++) {
            if (logs[i].emitter == address(ace) && logs[i].topics.length > 0) {
                assertTrue(logs[i].topics[0] != AUTO_POLICY_SET, "an unarmed loan's title move logged a disarm");
            }
        }
        (uint64 t1, uint16 b1,) = read.autoPolicyOf(loanId);
        assertEq(uint256(t1), 0, "still disarmed");
        assertEq(uint256(b1), 500, "and its stored buffer is untouched");
    }

    /// @notice A title-move disarm releases THAT loan's share and no other: the market keeps every other armed loan's hold.
    function test_ADisarmReleasesOnlyTheMovedLoansShare() public {
        uint256 a = _openArmed(named);
        uint256 b = _openArmed(named);
        uint256 shareB = read.reservedOf(b);
        assertGt(read.reservedOf(a), 0, "PREMISE: a is reserved");
        assertEq(read.rollReserve(named), read.reservedOf(a) + shareB, "PREMISE: the reserve is the two shares");
        _move(holder, buyer, a);
        assertEq(read.reservedOf(a), 0, "the moved loan's share is released");
        assertEq(read.rollReserve(named), shareB, "and the reserve is exactly the other loan's share");
        assertEq(_tenor(b), TEN7, "the loan that stayed with the named holder keeps its policy");
    }

    /// @notice A gate refusal is PERMANENT for that holder, so `arm` reports it ahead of every policy rail the holder could fix.
    /// @dev Each attempt below breaks one policy rail too: routing with no buffer, a full buffer, and a tenor past the grid.
    function test_AGateRefusalOutranksEveryPolicyRail() public {
        uint256 loanId = _openArmed(named);
        _move(holder, buyer, loanId);
        vm.startPrank(buyer);
        vm.expectRevert(GateRefused.selector);
        ace.setAutoRefinance(loanId, TEN7, 0, 100); // also RoutingNeedsBuffer
        vm.expectRevert(GateRefused.selector);
        ace.setAutoRefinance(loanId, TEN7, 10_000, 0); // also BufferOutOfRange
        vm.expectRevert(GateRefused.selector);
        ace.setAutoRefinance(loanId, 2 * TEN7, 500, 0); // also TenorOutOfRange
        vm.stopPrank();
    }

    /// @notice A closed loan's stale policy entry is left alone: moving its title logs no disarm and writes nothing to it.
    function test_AClosedLoansPolicyEntryIsNotTouchedByATitleMove() public {
        uint256 loanId = _openArmed(named);
        _warpTo(read.loan(loanId).expiry);
        vm.prank(keeper);
        ace.forceClose(loanId);
        assertTrue(ace.isClosed(loanId), "PREMISE: the fold rolled the loan, closing it");
        assertEq(_tenor(loanId), TEN7, "PREMISE: the closed loan's entry stays behind its close stamp");
        vm.recordLogs();
        _move(holder, buyer, loanId);
        Vm.Log[] memory logs = vm.getRecordedLogs();
        for (uint256 i; i < logs.length; i++) {
            if (logs[i].emitter == address(ace) && logs[i].topics.length > 0) {
                assertTrue(logs[i].topics[0] != AUTO_POLICY_SET, "a closed loan's title move logged a disarm");
            }
        }
        assertEq(_tenor(loanId), TEN7, "and wrote nothing to its entry");
    }
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
