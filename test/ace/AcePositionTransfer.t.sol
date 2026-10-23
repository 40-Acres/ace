// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.36;

import {Test, Vm} from "forge-std/Test.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {Ace} from "../../src/ace/hub/Ace.sol";
import {PositionTitleNFT} from "../../src/ace/positions/PositionTitleNFT.sol";
import {Loan, MarketParams, OpenBounds} from "../../src/ace/hub/Types.sol";
import {NotBorrower, NotPositionTitle, RetitleToZero} from "../../src/ace/hub/Ace.sol";
import {PositionManager} from "../../src/ace/positions/PositionManager.sol";
import {MockERC20} from "../mocks/MockERC20.sol";
import {MockStakeVault} from "../mocks/MockStakeVault.sol";
import {MockPersistenceRecord} from "../mocks/MockPersistenceRecord.sol";
import {AceFixtures} from "../utils/AceFixtures.sol";
import {AceReader} from "../utils/AceReader.sol";

/// @notice A hostile ERC-721 receiver that re-enters the hub from `onERC721Received` and records what it saw.
/// @dev By the time the hook fires retitle has completed and released the guard, so hub state must read CONSISTENT.
contract ReenteringReceiver {
    Ace public ace;
    uint256 public sawHolder0; // 1 if borrowerOf already reported this contract inside the hook
    bool public guardReleased; // the hub's ACTUAL guard state as the hook observed it

    function arm(Ace a) external {
        ace = a;
    }

    function onERC721Received(address, address, uint256 tokenId, bytes calldata) external returns (bytes4) {
        /// @dev `sawHolder0` stays 0 if the read reverts, so it carries the read AND its success in one.
        try ace.borrowerOf(tokenId) returns (address holder) {
            if (holder == address(this)) sawHolder0 = 1;
        } catch {}
        guardReleased = ace.notEntered();
        return this.onERC721Received.selector;
    }
}

interface ITokenReceiveHook {
    function onTokenReceived(address from, uint256 value) external;
}

/// @notice ERC-20 that notifies a designated receiver on transfer.
/// @dev The vehicle for landing a token callback INSIDE a hub call, where an NFT transfer must hit the hub's guard (M8).
contract HookedERC20 {
    string public name = "Hooked";
    string public symbol = "HOOK";
    uint8 public immutable decimals = 18;

    mapping(address => uint256) public balanceOf;
    mapping(address => mapping(address => uint256)) public allowance;
    address public hookTarget;

    function setHookTarget(address t) external {
        hookTarget = t;
    }

    function mint(address to, uint256 amount) external {
        balanceOf[to] += amount;
    }

    function approve(address spender, uint256 amount) external returns (bool) {
        allowance[msg.sender][spender] = amount;
        return true;
    }

    function _move(address from, address to, uint256 amount) private {
        balanceOf[from] -= amount;
        balanceOf[to] += amount;
        if (to == hookTarget && to.code.length > 0) ITokenReceiveHook(to).onTokenReceived(from, amount);
    }

    function transfer(address to, uint256 amount) external returns (bool) {
        _move(msg.sender, to, amount);
        return true;
    }

    function transferFrom(address from, address to, uint256 amount) external returns (bool) {
        uint256 a = allowance[from][msg.sender];
        if (a != type(uint256).max) allowance[from][msg.sender] = a - amount;
        _move(from, to, amount);
        return true;
    }
}

/// @notice Contract borrower that, on receiving collateral mid-withdraw, tries to sell its own position NFT inside the hub call.
/// @dev The attempt must die on the hub's guard (M8): title never moves while any hub entry point is live.
contract NestedTransferBorrower {
    Ace public ace;
    PositionTitleNFT public positions;
    uint256 public loanId;
    address public to;
    bool public armed;
    bool public transferReverted;

    function open(Ace a, PositionManager positionManager, IERC20 coll, IERC20 quote, bytes32 market, uint256 units, uint256 principal)
        external
        returns (uint256 id)
    {
        ace = a;
        positions = PositionTitleNFT(a.POSITION_TITLE());
        coll.approve(address(positionManager), units);
        quote.approve(address(a), type(uint256).max);
        id = a.open(market, units, principal, 0, address(this), OpenBounds(0, 0, 0));
        loanId = id;
    }

    function armAndWithdraw(address dest, uint256 units) external {
        to = dest;
        armed = true;
        ace.withdrawCollateral(loanId, units, address(this));
        armed = false;
    }

    function onTokenReceived(address, uint256) external {
        if (!armed) return;
        try positions.transferFrom(address(this), to, loanId) {
            transferReverted = false;
        } catch {
            transferReverted = true;
        }
    }
}

/// @title AcePositionTransferTest
/// @notice The security suite over transferable positions: health-invariance (M2), what rides the NFT (M3), the self-transfer guard (M5).
/// @notice Also retitle authorization, the nested-transfer refusal (M8), distress-laundering (M10), and the seams that do NOT move.
contract AcePositionTransferTest is Test {
    Ace internal ace;
    PositionTitleNFT internal positions;
    AceReader internal read;
    PositionManager internal positionManager;
    MockPersistenceRecord internal record;
    MockERC20 internal usdc;
    MockStakeVault internal vault;
    bytes32 internal id_;

    address internal alice = address(0xA11CE);
    address internal seller = address(0xB0B);
    address internal buyer = address(0xB417);
    address internal operator = address(0x09E7);
    address internal keeper = address(0xCAFE);
    address internal stranger = address(0x57A6);

    uint256 constant COLL = 10_000e18;
    uint256 constant PRINCIPAL = 4_500e6;
    uint256 constant FEE_FLOAT = 100e6;

    uint256 internal T2; // ticks above this pair's par; assigned in setUp, since par is not a compile-time value
    uint256 internal T3;
    uint256 internal T4;

    event Retitled(uint256 indexed id, address indexed from, address indexed to, uint256 feeEscrow);

    /// @dev This suite's pair, so a tick reads as its distance from par rather than as a grid coordinate.
    /// @param offset Ticks above par.
    /// @return The absolute grid tick.
    function _price(int24 offset) internal view returns (uint256) {
        return AceFixtures.priceAt(address(usdc), address(vault), offset);
    }

    function setUp() public {
        vm.warp(1_000_000);
        usdc = new MockERC20("USD Coin", "USDC", 6);
        vault = new MockStakeVault(42);
        (T2, T3, T4) = (_price(0), _price(480), _price(960));
        record = new MockPersistenceRecord(address(usdc), address(vault));
        record.setObserved(AceFixtures.px(1e18, address(usdc), address(vault)));
        record.setMinPrice(AceFixtures.px(2e18, address(usdc), address(vault)));

        MarketParams memory p = AceFixtures.marketParams(address(usdc), address(vault));
        p.record = address(record);
        AceFixtures.Deployment memory d = AceFixtures.deploy(p);
        (ace, positionManager, read, id_) = (d.ace, d.positionManager, d.read, d.id);
        positions = PositionTitleNFT(ace.POSITION_TITLE());

        usdc.mint(alice, 15_000e6);
        vm.startPrank(alice);
        usdc.approve(address(ace), 15_000e6);
        ace.deposit(id_, 5_000e6);
        ace.deposit(id_, 5_000e6);
        ace.deposit(id_, 5_000e6);
        vm.stopPrank();
    }

    function _open(address who) internal returns (uint256 id) {
        vault.mint(who, COLL);
        usdc.mint(who, FEE_FLOAT);
        vm.startPrank(who);
        vault.approve(address(positionManager), COLL);
        usdc.approve(address(ace), FEE_FLOAT);
        id = ace.open(id_, COLL, PRINCIPAL, 0, who, OpenBounds(0, 0, 0));
        vm.stopPrank();
    }

    function _transfer(uint256 id, address from, address to) internal {
        vm.prank(from);
        positions.transferFrom(from, to, id);
    }

    // ---- M2: health-invariance, the licence for skipping the solvency re-check ----

    /// @notice Debt, collateral, principal and the computed trigger are BYTE-IDENTICAL across a transfer.
    /// @dev THE LICENCE for having no solvency check on transfer: ACE moves both legs together, so health cannot change.
    function test_M2_HealthInputs_ByteIdenticalAcrossTransfer() public {
        uint256 id = _open(seller);
        Loan memory pre = read.loan(id);
        uint256 trigPre = read.triggerPrice(id);
        uint256 principalPre = read.principalOf(id);

        _transfer(id, seller, buyer);

        Loan memory post = read.loan(id);
        assertEq(post.debt, pre.debt, "debt unchanged");
        assertEq(post.collateralUnits, pre.collateralUnits, "collateral units unchanged");
        assertEq(read.principalOf(id), principalPre, "principal unchanged");
        assertEq(read.triggerPrice(id), trigPre, "trigger price unchanged");
        assertEq(post.openTime, pre.openTime, "no clock resets");
        assertEq(post.expiry, pre.expiry, "no expiry resets");
        assertEq(post.lastFee, pre.lastFee, "no fee-state resets");
    }

    // ---- title moves atomically, both ledgers ----

    function test_Transfer_MovesTitleOnBothLedgers_BothDirections() public {
        uint256 id = _open(seller);

        _transfer(id, seller, buyer);
        assertEq(positions.ownerOf(id), buyer, "NFT ledger moved");
        assertEq(ace.borrowerOf(id), buyer, "hub ledger moved in the same tx");

        _transfer(id, buyer, seller);
        assertEq(positions.ownerOf(id), seller, "NFT ledger moved back");
        assertEq(ace.borrowerOf(id), seller, "hub ledger moved back too");
    }

    // ---- authority follows the position, per entry point ----

    function test_Transfer_MovesEveryBorrowerGate() public {
        uint256 id = _open(seller);
        _transfer(id, seller, buyer);

        vm.startPrank(seller);
        vm.expectRevert(NotBorrower.selector);
        ace.withdrawCollateral(id, 1e18, seller);
        vm.expectRevert(NotBorrower.selector);
        ace.setAutoRefinance(id, 0, 300, 0);
        vm.stopPrank();

        vm.startPrank(buyer);
        ace.setAutoRefinance(id, 0, 300, 0);
        ace.withdrawCollateral(id, 1e18, buyer);
        vm.stopPrank();
        assertEq(read.loan(id).collateralUnits, COLL - 1e18, "the new holder exercised the withdraw right");
    }

    // ---- M3: everything loanId-keyed rides the position, visibly ----

    function test_M3_LoanKeyedStateRidesThePosition_AndTheEventShowsIt() public {
        uint256 id = _open(seller);
        vm.prank(seller);
        ace.setAutoRefinance(id, 0, 300, 0);

        uint256 principal = read.principalOf(id);
        uint256 escrowed = read.feeEscrowOf(id);
        (, uint16 buffer,) = read.autoPolicyOf(id);
        /// @dev A carry assertion on a zero subject is 0 == 0, so pin each one nonzero before the transfer.
        assertGt(escrowed, 0, "fixture: the position carries a live fee escrow to ride along");
        assertGt(principal, 0, "fixture: the principal is a real number to ride");
        assertGt(buffer, 0, "fixture: the armed buffer floor is a real number to ride");

        vm.expectEmit(true, true, true, true, address(ace));
        emit Retitled(id, seller, buyer, escrowed);
        _transfer(id, seller, buyer);

        assertEq(read.principalOf(id), principal, "principal rides");
        assertEq(read.feeEscrowOf(id), escrowed, "the fee escrow rides -- the buyer owns the refund now");
        (, uint16 buffer2,) = read.autoPolicyOf(id);
        assertEq(buffer2, buffer, "the armed continuation's buffer floor rides");
    }

    // ---- M5: self-transfer is inert ----

    function test_M5_SelfTransfer_EmitsNoRetitled() public {
        uint256 id = _open(seller);

        vm.recordLogs();
        _transfer(id, seller, seller);

        Vm.Log[] memory logs = vm.getRecordedLogs();
        /// @dev A no-log run satisfies the loop below without ever testing it, so bound the capture first.
        /// @dev ERC-721 still emits its own Transfer on a self-move: empty means the recorder, not the code.
        assertGt(logs.length, 0, "fixture: the self-transfer did emit its ERC-721 Transfer");
        bytes32 sig = keccak256("Retitled(uint256,address,address,uint256)");
        for (uint256 i; i < logs.length; i++) {
            assertTrue(logs[i].topics[0] != sig, "a self-transfer must not emit a Retitled");
        }
        assertEq(ace.borrowerOf(id), seller, "title unchanged");
    }

    // ---- retitle authorization ----

    function test_retitle_DirectCall_Reverts() public {
        uint256 id = _open(seller);

        vm.prank(stranger);
        vm.expectRevert(NotPositionTitle.selector);
        ace.retitle(id, seller, stranger);

        vm.prank(seller); // even the rightful holder cannot skip the NFT ledger
        vm.expectRevert(NotPositionTitle.selector);
        ace.retitle(id, seller, buyer);
    }

    function test_retitle_WrongFrom_Reverts() public {
        uint256 id = _open(seller);
        vm.prank(ace.POSITION_TITLE());
        vm.expectRevert(NotBorrower.selector);
        ace.retitle(id, stranger, buyer);
    }

    function test_retitle_ToZero_Reverts() public {
        uint256 id = _open(seller);
        vm.prank(ace.POSITION_TITLE());
        vm.expectRevert(RetitleToZero.selector);
        ace.retitle(id, seller, address(0));
    }

    // ---- the hook-timing property: retitle completes before any receiver hook fires ----

    /// @notice A hostile receiver re-entering from `onERC721Received` finds CONSISTENT state: title moved, guard released.
    /// @dev M6's super-first ordering is what makes that so.
    function test_SafeTransfer_HostileReceiver_SeesConsistentState() public {
        uint256 id = _open(seller);
        ReenteringReceiver r = new ReenteringReceiver();
        r.arm(ace);

        vm.prank(seller);
        positions.safeTransferFrom(seller, address(r), id);

        assertEq(r.sawHolder0(), 1, "the hook fired AFTER retitle: title already the receiver's");
        assertTrue(r.guardReleased(), "the guard was already released when the hook ran");
        assertEq(ace.borrowerOf(id), address(r), "final state consistent");
    }

    // ---- M10: a transfer launders nothing ----

    /// @notice Selling a distressed position resets no clock and dodges no settlement (SOL-Defi-Lending-6 shape).
    /// @dev The loan is as settleable in the buyer's hands as it was in the seller's.
    function test_M10_TransferInDistress_ResetsNothing_StillSettleable() public {
        uint256 id = _open(seller);
        record.setBelow(true);
        assertTrue(read.inDistress(id), "precondition: distress");
        assertTrue(read.settleable(id), "precondition: settleable");
        Loan memory pre = read.loan(id);

        _transfer(id, seller, buyer);

        Loan memory post = read.loan(id);
        assertEq(post.openTime, pre.openTime, "openTime untouched");
        assertEq(post.expiry, pre.expiry, "expiry untouched");
        assertEq(post.lastFee, pre.lastFee, "lastFee untouched");
        assertTrue(read.settleable(id), "still immediately settleable");

        vm.prank(keeper);
        ace.finalize(id); // and the settlement executes against the new holder's position
        assertTrue(read.loan(id).closedAt != 0, "settled despite the mid-distress sale");
    }

    /// @notice Transfer during distress is deliberately ALLOWED, and the buyer can cure by repaying.
    function test_TransferInDistress_Allowed_NewHolderCures() public {
        uint256 id = _open(seller);
        record.setBelow(true);
        _transfer(id, seller, buyer);

        uint256 debt = read.loan(id).debt;
        usdc.mint(buyer, debt);
        vm.startPrank(buyer);
        usdc.approve(address(ace), debt);
        ace.repay(id, debt);
        ace.claimOwed(id, buyer);
        vm.stopPrank();

        assertTrue(read.loan(id).closedAt != 0, "the rescue market works: the buyer cured the loan");
        assertEq(vault.balanceOf(buyer), COLL, "and the released collateral goes to the CURRENT holder");
    }

    // ---- repay stays permissionless ----

    /// @notice A blackholed holder cannot block repayment: anyone may repay (SOL-Defi-Lending-12).
    function test_Repay_StaysPermissionless_AfterTransfer() public {
        uint256 id = _open(seller);
        _transfer(id, seller, buyer);

        uint256 debt = read.loan(id).debt;
        usdc.mint(stranger, debt);
        vm.startPrank(stranger);
        usdc.approve(address(ace), debt);
        ace.repay(id, debt);
        vm.stopPrank();

        assertTrue(read.loan(id).closedAt != 0, "a stranger's repay still closes the loan");
        /// @dev The credit names the HOLDER, so only they can pull it -- a stranger's repay funds nobody else
        (uint256 owedStranger,) = ace.owedOf(id, stranger);
        assertEq(owedStranger, 0, "the payer is credited nothing");
        vm.prank(buyer);
        ace.claimOwed(id, buyer);
        assertEq(vault.balanceOf(buyer), COLL, "collateral released to the holder, not the payer");
    }

    // ---- transfer post-close ----

    /// @notice A closed position still transfers, and the residue right moves with title.
    /// @notice NOT the whole name: no sweep runs here, and a credit booked before the sale does not move.
    function test_TransferPostClose_Allowed_AndMovesSweepDestination() public {
        uint256 id = _open(seller);
        uint256 debt = read.loan(id).debt;
        usdc.mint(seller, debt);
        vm.startPrank(seller);
        usdc.approve(address(ace), debt);
        ace.repay(id, debt);
        vm.stopPrank();

        assertTrue(read.loan(id).closedAt != 0, "precondition: the position really is closed before it moves");

        _transfer(id, seller, buyer);
        assertEq(ace.borrowerOf(id), buyer, "a closed position still transfers: the residue right trades");

        /// @dev `unitsOwed` is keyed by (loanId, CLAIMANT) and was booked at the repay, before the sale.
        /// @dev So the CLOSE CREDIT does not ride a later transfer; only the sweep right does.
        (uint256 owedSeller,) = ace.owedOf(id, seller);
        (uint256 owedBuyer,) = ace.owedOf(id, buyer);
        assertEq(owedSeller, COLL, "the close credit stays with whoever held title when it was booked");
        assertEq(owedBuyer, 0, "a buyer of an ALREADY-closed position inherits none of that credit");

        vm.prank(seller);
        ace.claimOwed(id, seller);
        assertEq(vault.balanceOf(seller), COLL, "and the seller can still pull it after selling the NFT");
        assertEq(vault.balanceOf(buyer), 0, "the new holder receives nothing from the pre-booked credit");
    }

    // ---- settlement pays the current holder and never retitles ----

    function test_SettlementResidual_PaysTheCurrentHolder() public {
        uint256 id = _open(seller);
        _transfer(id, seller, buyer);
        record.setBelow(true);

        uint256 sellerPre = vault.balanceOf(seller);
        uint256 buyerPre = vault.balanceOf(buyer);
        vm.prank(keeper);
        ace.finalize(id);

        (uint256 owedSeller,) = ace.owedOf(id, seller);
        assertEq(owedSeller, 0, "the original borrower is credited nothing");
        vm.prank(buyer);
        ace.claimOwed(id, buyer);
        assertEq(vault.balanceOf(seller), sellerPre, "the original borrower receives nothing");
        assertGt(vault.balanceOf(buyer), buyerPre, "the residual leg pays the CURRENT holder");
        assertEq(positions.ownerOf(id), buyer, "settlement never moves the NFT: filling lenders are plural");
    }

    // ---- M8: no NFT transfer inside a live hub call ----

    /// @notice A token callback landing inside `withdrawCollateral` tries to move the position and dies on the hub's guard.
    /// @dev The safe direction, pinned as an intended property.
    function test_M8_NestedTransferInsideHubCall_Reverts() public {
        HookedERC20 hooked = new HookedERC20();
        MarketParams memory p = AceFixtures.marketParams(address(usdc), address(hooked));
        p.deleverageFloorEpsBps = 0;
        AceFixtures.Deployment memory d = AceFixtures.deploy(p);

        usdc.mint(alice, 15_000e6);
        vm.startPrank(alice);
        usdc.approve(address(d.ace), 15_000e6);
        d.ace.deposit(d.id, 5_000e6);
        d.ace.deposit(d.id, 5_000e6);
        vm.stopPrank();

        NestedTransferBorrower nb = new NestedTransferBorrower();
        hooked.mint(address(nb), COLL);
        usdc.mint(address(nb), FEE_FLOAT);
        uint256 id = nb.open(d.ace, d.positionManager, IERC20(address(hooked)), IERC20(address(usdc)), d.id, COLL, PRINCIPAL);

        hooked.setHookTarget(address(nb));
        nb.armAndWithdraw(buyer, 1e18);

        assertTrue(nb.transferReverted(), "the nested NFT transfer must die on the hub's guard");
        assertEq(d.ace.borrowerOf(id), address(nb), "title never moved inside the hub call");
        assertEq(PositionTitleNFT(d.ace.POSITION_TITLE()).ownerOf(id), address(nb), "NFT ledger agrees");
    }

    // ---- what deliberately does NOT follow the position ----

    /// @notice Credit delegation is a grant over an ADDRESS's name, never over a position, so it does not ride the NFT.
    /// @dev The Types rule behind it: the two grants must never share a mapping.
    function test_CreditOperator_DoesNotFollowThePosition() public {
        uint256 id = _open(seller);
        vm.prank(seller);
        ace.setCreditOperator(operator, true);

        _transfer(id, seller, buyer);

        assertTrue(read.creditOperator(seller, operator), "the seller's grant is untouched");
        assertFalse(read.creditOperator(buyer, operator), "and nothing was granted in the buyer's name");
    }

    // ---- the phishing surface, documented ----

    /// @notice `setApprovalForAll` lets an operator move a debt-bearing, equity-holding position.
    /// @dev The standard ERC-721 surface, identical to Uniswap's position NFT; not a defect.
    /// @dev Pinned as a DOCUMENTING test so the surface is a known quantity rather than a discovery.
    function test_Documenting_ApprovalForAll_EnablesOperatorTransfer() public {
        uint256 id = _open(seller);
        vm.prank(seller);
        positions.setApprovalForAll(operator, true);

        vm.prank(operator);
        positions.transferFrom(seller, buyer, id);

        assertEq(ace.borrowerOf(id), buyer, "an approved operator can move the position and its equity");
    }
}
