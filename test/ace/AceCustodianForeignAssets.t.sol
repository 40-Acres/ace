// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.36;

import {WarpClock} from "../utils/WarpClock.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {IERC721Errors, IERC1155Errors} from "@openzeppelin/contracts/interfaces/draft-IERC6093.sol";
import {ERC721} from "@openzeppelin/contracts/token/ERC721/ERC721.sol";
import {IERC721Receiver} from "@openzeppelin/contracts/token/ERC721/IERC721Receiver.sol";
import {ERC1155} from "@openzeppelin/contracts/token/ERC1155/ERC1155.sol";
import {IERC1155Receiver} from "@openzeppelin/contracts/token/ERC1155/IERC1155Receiver.sol";
import {IERC165} from "@openzeppelin/contracts/utils/introspection/IERC165.sol";
import {Ace} from "../../src/ace/hub/Ace.sol";
import {MarketParams, OpenBounds} from "../../src/ace/hub/Types.sol";
import {PositionManager} from "../../src/ace/positions/PositionManager.sol";
import {PositionTitleNFT} from "../../src/ace/positions/PositionTitleNFT.sol";
import {ProtocolPolicy} from "../../src/config/Defaults.sol";
import {MockERC20} from "../mocks/MockERC20.sol";
import {MockPersistenceRecord} from "../mocks/MockPersistenceRecord.sol";
import {AceFixtures} from "../utils/AceFixtures.sol";
import {AceReader} from "../utils/AceReader.sol";

/// @title MockAirdropERC721
/// @notice Retroactive NFT airdrop. `mint` skips the acceptance check; `safeMint` requires it.
contract MockAirdropERC721 is ERC721 {
    constructor() ERC721("Airdrop721", "AIR721") {}

    /// @notice Mints `tokenId` to `to` with NO receiver hook, which is the leg nothing can refuse.
    function mint(address to, uint256 tokenId) external {
        _mint(to, tokenId);
    }

    /// @notice Mints `tokenId` to `to` THROUGH the acceptance check; reverts on a hookless recipient.
    function safeMint(address to, uint256 tokenId) external {
        _safeMint(to, tokenId);
    }
}

/// @title MockAirdropERC1155
/// @notice Retroactive multi-token airdrop. Every mint runs the acceptance check.
contract MockAirdropERC1155 is ERC1155 {
    constructor() ERC1155("ace://airdrop/{id}") {}

    /// @notice Mints `amount` of `id` to `to`; runs onERC1155Received.
    function mint(address to, uint256 id, uint256 amount) external {
        _mint(to, id, amount, "");
    }

    /// @notice Mints a batch to `to`; runs onERC1155BatchReceived.
    function mintBatch(address to, uint256[] memory ids, uint256[] memory amounts) external {
        _mintBatch(to, ids, amounts, "");
    }
}

/// @notice The custodian REFUSES every foreign asset it can refuse, and strands the rest for ever.
/// @notice There is no sweep, no rescue and no arbitrary call: nothing leaves except a market's own collateral.
/// @dev This file inverts the ruling it used to assert. The old per-loan vault ACCEPTED everything.
/// @dev It could, because a dead vault's foreign assets were sweepable by the loan's title holder.
/// @dev With one shared custodian and no sweep surface, an asset that LANDS is what is stranded.
/// @dev So refusal is the better failure mode, and it is asserted here on all four receiving legs.
/// @dev THE RESIDUE IS IRREDUCIBLE and is tested rather than claimed: a plain ERC-20 `transfer`
/// @dev cannot be refused by any receiver, and a plain ERC-721 `transferFrom` runs no receiver check.
contract AceCustodianForeignAssetsTest is WarpClock {
    Ace internal ace;
    AceReader internal read;
    PositionManager internal positionManager;
    PositionTitleNFT internal positions;
    MockERC20 internal usdc; // quote, 6dec
    MockERC20 internal weth; // collateral, 18dec
    MockERC20 internal drop; // a foreign ERC-20 airdrop, which is every token but COLLATERAL
    MockAirdropERC721 internal nft;
    MockAirdropERC1155 internal multi;
    MockPersistenceRecord internal record;
    bytes32 internal id_;

    address internal borrower = address(0xB0B);
    address internal buyer = address(0xB417); // takes title mid-life, for the title-stability rows
    address internal stranger = address(0x57A6);
    address internal keeper = address(0xCAFE);
    address internal alice = address(0xA11CE); // lender

    uint256 constant COLL = 10_000e18;
    uint256 constant PRINCIPAL = 4_500e6;
    uint256 constant FEE_FLOAT = 100e6;
    uint256 constant AIRDROP = 777e18; // foreign ERC-20 landing on the custodian
    uint256 constant ETH_DROP = 3 ether;
    uint256 constant NFT_ID = 42;
    uint256 constant SFT_ID = 7;
    uint256 constant SFT_QTY = 9;

    uint256 internal T2; // ticks from this pair's par; assigned in setUp, since par is not a compile-time value
    uint256 internal T3; // one rung up
    uint256 internal T4; // two rungs up

    function setUp() public {
        _warpTo(1_000_000);
        usdc = new MockERC20("USD Coin", "USDC", 6);
        weth = new MockERC20("Wrapped Ether", "WETH", 18);
        (T2, T3, T4) = (_price(0), _price(480), _price(960));
        drop = new MockERC20("Airdrop", "DROP", 18);
        nft = new MockAirdropERC721();
        multi = new MockAirdropERC1155();
        record = new MockPersistenceRecord(address(usdc), address(weth));
        record.setObserved(AceFixtures.px(1e18, address(usdc), address(weth)));

        AceFixtures.Deployment memory d = AceFixtures.deploy(_params());
        (ace, positionManager, read, id_) = (d.ace, d.positionManager, d.read, d.id);
        positions = PositionTitleNFT(ace.POSITION_TITLE());
        _seed();

        vm.label(address(ace), "Ace");
        vm.label(address(positionManager), "PositionManager");
        vm.label(borrower, "Borrower");
        vm.label(buyer, "Buyer");
        vm.label(stranger, "Stranger");
    }

    // ---- helpers ----

    /// @dev This suite's pair, so a tick reads as its distance from par rather than as a grid coordinate.
    /// @param offset Ticks above par.
    /// @return The absolute grid tick.
    function _price(int24 offset) internal view returns (uint256) {
        return AceFixtures.priceAt(address(usdc), address(weth), offset);
    }

    function _params() internal returns (MarketParams memory p) {
        p = AceFixtures.marketParams(address(usdc), address(weth));
        p.record = address(record);
    }

    function _seed() internal {
        usdc.mint(alice, 15_000e6);
        vm.startPrank(alice);
        usdc.approve(address(ace), 15_000e6);
        ace.deposit(id_, 5_000e6);
        ace.deposit(id_, 5_000e6);
        ace.deposit(id_, 5_000e6);
        vm.stopPrank();
    }

    function _open(address who) internal returns (uint256 id) {
        weth.mint(who, COLL);
        usdc.mint(who, FEE_FLOAT);
        vm.startPrank(who);
        weth.approve(address(positionManager), COLL);
        usdc.approve(address(ace), FEE_FLOAT);
        id = ace.open(id_, COLL, PRINCIPAL, 0, who, OpenBounds(0, 0, 0));
        vm.stopPrank();
    }

    /// @dev The close CREDITS the collateral, so the claim is what actually empties the loan's ledger.
    /// @dev Payer and claimant are read off TITLE, so this follows a mid-life sale without being told.
    function _repay(uint256 id) internal {
        uint256 owed = read.loan(id).debt;
        address holder = read.loan(id).borrower;
        usdc.mint(holder, owed);
        vm.startPrank(holder);
        usdc.approve(address(ace), owed);
        ace.repay(id, owed);
        ace.claimOwed(id, holder);
        vm.stopPrank();
    }

    /// @dev Full repay -> closeClean, so the loan is genuinely closed before the residue rows run.
    function _openAndRepay() internal returns (uint256 id) {
        id = _open(borrower);
        _repay(id);
        assertTrue(read.loan(id).closedAt != 0, "full repay closes the loan");
    }

    /// @dev Distress -> finalize. The lender takes title to the collateral; the position's holder is unchanged.
    function _openAndFinalize() internal returns (uint256 id) {
        id = _open(borrower);
        record.setBelow(true);
        vm.prank(keeper);
        ace.finalize(id);
        record.setBelow(false); // the record recovers, so later fixtures are not incidentally settleable
        assertTrue(read.loan(id).closedAt != 0, "finalize settles");
    }

    /// @dev Expiry -> forceClose, the must-execute backstop.
    function _openAndForceClose() internal returns (uint256 id) {
        id = _open(borrower);
        _warpBy(ProtocolPolicy.MIN_TENOR + 1);
        vm.prank(keeper);
        ace.forceClose(id);
        assertTrue(read.loan(id).closedAt != 0, "expiry settles unconditionally");
    }

    // ---- A. RECEIVING: refuse everything that CAN be refused ----

    /// @notice A plain value send to the custodian REVERTS, at the sender, on a closed loan or any other.
    /// @dev The contract is not payable and declares no `receive()`, so this is refusal by construction.
    /// @dev Inverted from the vault ruling: with no sweep, the ETH that lands is the ETH that is lost.
    function testRevert_custodian_RefusesPlainEthSend() public {
        _openAndRepay();
        vm.deal(stranger, ETH_DROP);

        vm.prank(stranger);
        (bool ok,) = payable(address(positionManager)).call{value: ETH_DROP}("");

        assertFalse(ok, "the custodian must refuse a plain ETH send");
        assertEq(address(positionManager).balance, 0, "and hold no native balance at all");
    }

    /// @notice The refusal is unconditional, so a LIVE loan does not open a native-value door either.
    function testRevert_custodian_RefusesPlainEthSend_WhileLive() public {
        _open(borrower);
        vm.deal(stranger, ETH_DROP);

        vm.prank(stranger);
        (bool ok,) = payable(address(positionManager)).call{value: ETH_DROP}("");

        assertFalse(ok, "liveness is irrelevant: there is no receive() to reach");
        assertEq(address(positionManager).balance, 0, "no ETH lands");
    }

    /// @notice `safeTransferFrom` of an ERC-721 reverts AT THE SENDER, because there is no receiver hook.
    function testRevert_custodian_RefusesSafeErc721Transfer() public {
        _openAndRepay();
        nft.mint(stranger, NFT_ID);

        vm.prank(stranger);
        vm.expectRevert(abi.encodeWithSelector(IERC721Errors.ERC721InvalidReceiver.selector, address(positionManager)));
        nft.safeTransferFrom(stranger, address(positionManager), NFT_ID);

        assertEq(nft.ownerOf(NFT_ID), stranger, "the NFT never left the sender");
    }

    /// @notice A safe MINT is refused too; most airdrops mint rather than transfer, so it needs its own row.
    function testRevert_custodian_RefusesSafeErc721Mint() public {
        _openAndRepay();

        vm.expectRevert(abi.encodeWithSelector(IERC721Errors.ERC721InvalidReceiver.selector, address(positionManager)));
        nft.safeMint(address(positionManager), NFT_ID);
    }

    /// @notice A single-id ERC-1155 transfer is refused: no `onERC1155Received` to answer with.
    function testRevert_custodian_RefusesErc1155SingleTransfer() public {
        _openAndRepay();

        vm.expectRevert(abi.encodeWithSelector(IERC1155Errors.ERC1155InvalidReceiver.selector, address(positionManager)));
        multi.mint(address(positionManager), SFT_ID, SFT_QTY);

        assertEq(multi.balanceOf(address(positionManager), SFT_ID), 0, "nothing landed");
    }

    /// @notice A batch ERC-1155 transfer is refused on its own separate selector.
    /// @dev The batch hook is a different selector from the single one, so it needs its own row or it gets missed.
    function testRevert_custodian_RefusesErc1155BatchTransfer() public {
        _openAndRepay();
        uint256[] memory ids = new uint256[](2);
        uint256[] memory amounts = new uint256[](2);
        ids[0] = SFT_ID;
        ids[1] = SFT_ID + 1;
        amounts[0] = SFT_QTY;
        amounts[1] = SFT_QTY * 2;

        vm.expectRevert(abi.encodeWithSelector(IERC1155Errors.ERC1155InvalidReceiver.selector, address(positionManager)));
        multi.mintBatch(address(positionManager), ids, amounts);
    }

    /// @notice The custodian advertises NO receiver interface, so a probing distributor skips it.
    /// @dev The old vault advertised all three deliberately, to make sure airdrops could land.
    /// @dev The ruling inverted: a distributor that skips this address is a distributor that lost nothing.
    /// @dev `supportsInterface` is absent entirely, so the probe reverts rather than answering false.
    function test_custodian_AdvertisesNoReceiverInterfaces() public view {
        bytes4[4] memory probes = [type(IERC165).interfaceId, type(IERC721Receiver).interfaceId, type(IERC1155Receiver).interfaceId, bytes4(0xdeadbeef)];
        for (uint256 i; i < probes.length; i++) {
            (bool ok,) = address(positionManager).staticcall(abi.encodeWithSelector(IERC165.supportsInterface.selector, probes[i]));
            assertFalse(ok, "the custodian must answer no ERC-165 probe at all");
        }
    }

    // ---- B. THE RESIDUE: what cannot be refused is stranded, and nothing recovers it ----

    /// @notice A plain ERC-20 `transfer` CANNOT be refused by any receiver, so it lands and is lost.
    /// @dev The header claims exactly this residue, so it is tested rather than asserted in prose.
    /// @dev Nothing credits it, no verb reaches it, and there is no sweep selector to dispatch.
    function test_custodian_PlainErc20TransferIsStrandedForever() public {
        uint256 id = _openAndRepay();
        drop.mint(stranger, AIRDROP);

        vm.prank(stranger);
        drop.transfer(address(positionManager), AIRDROP);

        assertEq(drop.balanceOf(address(positionManager)), AIRDROP, "the transfer landed: nothing could refuse it");
        assertEq(positionManager.custodiedOf(address(drop)), 0, "and credited nobody");
        assertEq(positionManager.uncreditedSurplus(address(drop)), AIRDROP, "it is surplus, in full");

        vm.prank(borrower); // the title holder is the one party a sweep ever answered to
        (bool ok,) = address(positionManager).call(abi.encodeWithSignature("sweepERC20(uint256,address)", id, address(drop)));

        assertFalse(ok, "there is no sweep surface, so the selector cannot be dispatched");
        assertEq(drop.balanceOf(address(positionManager)), AIRDROP, "and the airdrop is stranded for ever");
    }

    /// @notice A plain ERC-721 `transferFrom` runs no receiver check, so an NFT lands and is lost too.
    /// @dev This is the second half of the irreducible residue: refusal needs a hook, and this path has none.
    function test_custodian_UnsafeErc721TransferIsStrandedForever() public {
        uint256 id = _openAndRepay();
        nft.mint(stranger, NFT_ID);

        vm.prank(stranger);
        nft.transferFrom(stranger, address(positionManager), NFT_ID);

        assertEq(nft.ownerOf(NFT_ID), address(positionManager), "the unsafe transfer landed");

        vm.prank(borrower);
        (bool ok,) = address(positionManager).call(abi.encodeWithSignature("sweepERC721(uint256,address,uint256)", id, address(nft), NFT_ID));

        assertFalse(ok, "no sweep exists for it either");
        assertEq(nft.ownerOf(NFT_ID), address(positionManager), "so the NFT is stranded for ever");
    }

    /// @notice Stranding a foreign asset never touches the collateral ledger of any loan.
    /// @dev The pot and its aggregate are collateral-keyed, so a foreign balance is invisible to both.
    function test_strandedForeignAssetsLeaveTheCustodyLedgerUntouched() public {
        uint256 idLive = _open(borrower);
        uint256 potBefore = weth.balanceOf(address(positionManager));

        drop.mint(address(positionManager), AIRDROP);
        nft.mint(address(positionManager), NFT_ID);

        assertEq(positionManager.collateralOf(idLive), COLL, "the live loan's ledger is untouched");
        assertEq(positionManager.custodiedOf(address(weth)), COLL, "and so is the collateral aggregate");
        assertEq(weth.balanceOf(address(positionManager)), potBefore, "the collateral pot did not move");
    }

    // ---- C. Title stays put after settlement, which the residue rules used to depend on ----

    /// @notice Title stays the borrower after settlement even though the lender took the collateral.
    /// @dev The R4 pin: the lender bought the asset at their pre-committed tick, not the address's history.
    /// @dev Title reads off the hub (`borrowerOf`), which is the storage every claim resolves through.
    function test_borrowerOf_StaysBorrower_AfterFinalize() public {
        uint256 id = _openAndFinalize();
        assertEq(ace.borrowerOf(id), borrower, "settlement does not retitle the position");
    }

    /// @notice The same after the must-execute backstop.
    function test_borrowerOf_StaysBorrower_AfterForceClose() public {
        uint256 id = _openAndForceClose();
        assertEq(ace.borrowerOf(id), borrower, "forceClose does not retitle the position either");
    }

    /// @notice Title still moves with the position, and the buyer is the party the close pays.
    /// @dev Kept from the destination suite: the residue right is gone, but the CLAIM right still trades.
    function test_claimPaysTheCurrentHolder_AfterATitleTransfer() public {
        uint256 id = _open(borrower);
        vm.prank(borrower);
        positions.transferFrom(borrower, buyer, id);

        _repay(id);

        assertEq(ace.borrowerOf(id), buyer, "the sale really moved title");
        assertEq(weth.balanceOf(buyer), COLL, "and the close paid the CURRENT holder");
        assertEq(weth.balanceOf(borrower), 0, "the previous holder collects nothing");
    }

    // ---- D. NO actor anywhere names a target ----

    /// @notice There is no holder-driven arbitrary call on the custodian, on a closed loan or any other.
    /// @dev The earlier design carried `forward(uint256,address,bytes)`, which needed a denylist to be safe.
    /// @dev Deleting it deletes the denylist and every question about what the custodian may be pointed at.
    /// @dev The custodian has no fallback, so that selector cannot be dispatched at all.
    function test_hub_ExposesNoArbitraryForward() public {
        uint256 id = _openAndRepay();
        bytes memory data = abi.encodeWithSignature("forward(uint256,address,bytes)", id, address(drop), bytes(""));

        vm.prank(borrower);
        (bool ok,) = address(positionManager).call(data);

        assertFalse(ok, "the custodian must expose no arbitrary-target call");
    }

    /// @notice The whole sweep surface is gone, so every one of the four selectors fails to dispatch.
    /// @dev Asserted on the TITLE HOLDER, who is the one caller the deleted gate would have let through.
    function test_custodian_ExposesNoSweepSurfaceAtAll() public {
        uint256 id = _openAndRepay();
        bytes[4] memory calls = [
            abi.encodeWithSignature("sweepERC20(uint256,address)", id, address(drop)),
            abi.encodeWithSignature("sweepETH(uint256)", id),
            abi.encodeWithSignature("sweepERC721(uint256,address,uint256)", id, address(nft), NFT_ID),
            abi.encodeWithSignature("sweepERC1155(uint256,address,uint256)", id, address(multi), SFT_ID)
        ];

        vm.startPrank(borrower);
        for (uint256 i; i < calls.length; i++) {
            (bool ok,) = address(positionManager).call(calls[i]);
            assertFalse(ok, "no sweep selector may be dispatchable on the custodian");
        }
        vm.stopPrank();
    }
}
