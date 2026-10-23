// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.36;

import {Test} from "forge-std/Test.sol";
import {WarpClock} from "../utils/WarpClock.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {Ace} from "../../src/ace/hub/Ace.sol";
import {PositionTitleNFT} from "../../src/ace/positions/PositionTitleNFT.sol";
import {MarketParams, OpenBounds} from "../../src/ace/hub/Types.sol";
import {PositionManager} from "../../src/ace/positions/PositionManager.sol";
import {MockERC20} from "../mocks/MockERC20.sol";
import {MockStakeVault} from "../mocks/MockStakeVault.sol";
import {MockPersistenceRecord} from "../mocks/MockPersistenceRecord.sol";
import {ProtocolPolicy} from "../../src/config/Defaults.sol";
import {AceFixtures} from "../utils/AceFixtures.sol";
import {AceReader} from "../utils/AceReader.sol";

/// @notice A borrower with NO onERC721Received, the canary against mint ever becoming _safeMint.
/// @notice If it does, this contract's open reverts and the delegated-credit path is DoS'd for every vault-shaped borrower.
contract PlainContractBorrower {
    function doOpen(Ace ace, PositionManager positionManager, IERC20 coll, IERC20 quote, bytes32 market, uint256 units, uint256 principal)
        external
        returns (uint256)
    {
        coll.approve(address(positionManager), units);
        quote.approve(address(ace), type(uint256).max);
        return ace.open(market, units, principal, 0, address(this), OpenBounds(0, 0, 0));
    }
}

/// @title AcePositionsTest
/// @notice The mint half of the title layer: one position NFT per loan, minted by the hub at open, with tokenId == loanId.
/// @notice It is never burned, and answers after every close path.
contract AcePositionsTest is WarpClock {
    Ace internal ace;
    PositionTitleNFT internal positions;
    AceReader internal read;
    PositionManager internal positionManager;
    MockPersistenceRecord internal record;
    MockERC20 internal usdc;
    MockStakeVault internal vault;
    bytes32 internal id_;

    address internal alice = address(0xA11CE);
    address internal borrower = address(0xB0B);
    address internal operator = address(0x09E7);
    address internal keeper = address(0xCAFE);

    uint256 constant COLL = 10_000e18;
    uint256 constant PRINCIPAL = 4_500e6;
    uint256 constant FEE_FLOAT = 100e6;

    uint256 internal T2; // ticks above this pair's par; assigned in setUp, since par is not a compile-time value
    uint256 internal T3;
    uint256 internal T4;

    /// @dev This suite's pair, so a tick reads as its distance from par rather than as a grid coordinate.
    /// @param offset Ticks above par.
    /// @return The absolute grid tick.
    function _price(int24 offset) internal view returns (uint256) {
        return AceFixtures.priceAt(address(usdc), address(vault), offset);
    }

    function setUp() public {
        _warpTo(1_000_000);
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

    function _arm(address who) internal {
        vault.mint(who, COLL);
        usdc.mint(who, FEE_FLOAT);
        vm.startPrank(who);
        vault.approve(address(positionManager), COLL);
        usdc.approve(address(ace), FEE_FLOAT);
        vm.stopPrank();
    }

    // ---- mint at open: every entry point, tokenId == loanId, owner == borrower ----

    function test_open_MintsPositionToBorrower() public {
        _arm(borrower);
        vm.prank(borrower);
        uint256 id = ace.open(id_, COLL, PRINCIPAL, 0, borrower, OpenBounds(0, 0, 0));

        assertEq(positions.ownerOf(id), borrower, "position minted to the borrower");
        assertEq(positions.balanceOf(borrower), 1, "one position for one loan");
        assertEq(ace.borrowerOf(id), borrower, "hub title agrees");
    }

    function test_open_WithTenor_Mints() public {
        _arm(borrower);
        vm.prank(borrower);
        uint256 id = ace.open(id_, COLL, PRINCIPAL, ProtocolPolicy.MIN_TENOR, borrower, OpenBounds(0, 0, 0));

        assertEq(positions.ownerOf(id), borrower, "tenor entry point mints too");
    }

    function test_open_TenorZero_Mints() public {
        _arm(borrower);
        vm.prank(borrower);
        uint256 id = ace.open(id_, COLL, PRINCIPAL, 0, borrower, OpenBounds(0, 0, 0));

        assertEq(positions.ownerOf(id), borrower, "bounds entry point mints too");
    }

    /// @dev Opening in another's name: the OPERATOR is msg.sender, the position lands on the BORROWER.
    function test_open_OnBehalfOf_MintsToTheBorrower_NotTheOperator() public {
        _arm(operator);
        vm.prank(borrower);
        ace.setCreditOperator(operator, true);

        vm.prank(operator);
        uint256 id = ace.open(id_, COLL, PRINCIPAL, 0, borrower, OpenBounds(0, 0, 0));

        assertEq(positions.ownerOf(id), borrower, "the title is the borrower's");
        assertEq(positions.balanceOf(operator), 0, "the operator funds; they do not own");
    }

    function test_open_OnBehalfOf_BothTenorForms_MintToTheBorrower() public {
        vault.mint(operator, 2 * COLL);
        usdc.mint(operator, 2 * FEE_FLOAT);
        vm.startPrank(operator);
        vault.approve(address(positionManager), 2 * COLL);
        usdc.approve(address(ace), 2 * FEE_FLOAT);
        vm.stopPrank();
        vm.prank(borrower);
        ace.setCreditOperator(operator, true);

        vm.prank(operator);
        uint256 idA = ace.open(id_, COLL, PRINCIPAL, ProtocolPolicy.MIN_TENOR, borrower, OpenBounds(0, 0, 0));
        vm.prank(operator);
        uint256 idB = ace.open(id_, COLL, PRINCIPAL, 0, borrower, OpenBounds(0, 0, 0));

        assertEq(positions.ownerOf(idA), borrower, "openFor+tenor mints to the borrower");
        assertEq(positions.ownerOf(idB), borrower, "openForWithBounds mints to the borrower");
        assertEq(positions.balanceOf(borrower), 2, "positions enumerate per owner");
    }

    /// @notice A CONTRACT borrower with no onERC721Received still opens.
    /// @notice The canary for any later _safeMint: the receiver hook would revert this open and DoS the vault-shaped borrower path.
    function test_M1_ContractBorrowerWithoutReceiverHook_StillOpens() public {
        PlainContractBorrower pb = new PlainContractBorrower();
        vault.mint(address(pb), COLL);
        usdc.mint(address(pb), FEE_FLOAT);

        uint256 id = pb.doOpen(ace, positionManager, IERC20(address(vault)), IERC20(address(usdc)), id_, COLL, PRINCIPAL);

        assertEq(positions.ownerOf(id), address(pb), "plain _mint lands on a hook-less contract");
    }

    // ---- mint authority and the missing burn ----

    function test_mint_FromNonHub_Reverts() public {
        vm.expectRevert(PositionTitleNFT.NotHubTitle.selector);
        positions.mint(999, borrower);

        vm.prank(borrower);
        vm.expectRevert(PositionTitleNFT.NotHubTitle.selector);
        positions.mint(999, borrower);
    }

    function test_NoBurnSelectorExists() public {
        _arm(borrower);
        vm.prank(borrower);
        uint256 id = ace.open(id_, COLL, PRINCIPAL, 0, borrower, OpenBounds(0, 0, 0));

        (bool ok, bytes memory ret) = address(positions).call(abi.encodeWithSignature("burn(uint256)", id));
        assertFalse(ok, "no burn function, ever: a burn would strand every post-close sweep");
        assertEq(ret.length, 0, "empty returndata is the discriminator: a live-but-reverting burn returns data");
    }

    // ---- the position survives every close path ----

    function test_ownerOf_AnswersAfterRepay() public {
        _arm(borrower);
        vm.prank(borrower);
        uint256 id = ace.open(id_, COLL, PRINCIPAL, 0, borrower, OpenBounds(0, 0, 0));
        uint256 debt = read.loan(id).debt;
        usdc.mint(borrower, debt);
        vm.startPrank(borrower);
        usdc.approve(address(ace), debt);
        ace.repay(id, debt);
        vm.stopPrank();

        assertEq(positions.ownerOf(id), borrower, "the position outlives a clean close");
    }

    function test_ownerOf_AnswersAfterFinalize() public {
        _arm(borrower);
        vm.prank(borrower);
        uint256 id = ace.open(id_, COLL, PRINCIPAL, 0, borrower, OpenBounds(0, 0, 0));
        record.setBelow(true);
        vm.prank(keeper);
        ace.finalize(id);

        assertEq(positions.ownerOf(id), borrower, "the position outlives a settlement");
    }

    function test_ownerOf_AnswersAfterForceClose() public {
        _arm(borrower);
        vm.prank(borrower);
        uint256 id = ace.open(id_, COLL, PRINCIPAL, 0, borrower, OpenBounds(0, 0, 0));
        _warpBy(30 days + 1);
        vm.prank(keeper);
        ace.forceClose(id);

        assertEq(positions.ownerOf(id), borrower, "the position outlives the backstop close");
    }

    // ---- partial repay leaves title alone ----

    function test_PartialRepay_OwnerStable() public {
        _arm(borrower);
        vm.prank(borrower);
        uint256 id = ace.open(id_, COLL, PRINCIPAL, 0, borrower, OpenBounds(0, 0, 0));
        usdc.mint(borrower, 1_000e6);
        vm.startPrank(borrower);
        usdc.approve(address(ace), 1_000e6);
        ace.repay(id, 1_000e6);
        vm.stopPrank();

        assertEq(positions.ownerOf(id), borrower, "owner stable across a partial repay");
    }

    // ---- conformance ----

    function test_ERC165_Conformance() public view {
        assertTrue(positions.supportsInterface(0x01ffc9a7), "ERC-165");
        assertTrue(positions.supportsInterface(0x80ac58cd), "ERC-721");
        assertTrue(positions.supportsInterface(0x5b5e139f), "ERC-721 metadata");
    }

    function test_Metadata() public view {
        assertEq(positions.name(), "ACE Position");
        assertEq(positions.symbol(), "ACE-POS");
        assertEq(positions.HUB(), address(ace), "hub-scoped by construction");
        assertEq(positions.tokenURI(1), "", "deliberately empty, never a broken URI");
    }
}
