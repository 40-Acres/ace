// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.36;

import {Test} from "forge-std/Test.sol";
import {Ace, NotAuthorized} from "../../src/ace/hub/Ace.sol";
import {AceLens} from "../../src/ace/lens/AceLens.sol";
import {Borrower} from "../../src/ace/hub/Borrower.sol";
import {GateRefused} from "../../src/ace/hub/Borrower.sol";
import {MarketParams, OpenBounds} from "../../src/ace/hub/Types.sol";
import {PositionManager} from "../../src/ace/positions/PositionManager.sol";
import {MockERC20} from "../mocks/MockERC20.sol";
import {MockPersistenceRecord} from "../mocks/MockPersistenceRecord.sol";
import {MockStakeVault} from "../mocks/MockStakeVault.sol";
import {AceFixtures} from "../utils/AceFixtures.sol";
import {AceReader} from "../utils/AceReader.sol";

/// @title AceQuoteOpenBorrowerIdentity
/// @notice Both doors read the market's named borrower: `previewOpen` and `open` each take `borrower`.
/// @notice So a quote taken by a lens, a router or a credit operator is judged on the party that would hold the loan.
/// @notice Admissibility is not authorization: the quote never asks whether the CALLER may open, only whether the draw is legal.
/// @dev Third instance of the class `preview-open-diverges-from-open.md` owns: F1 was the tenor sentinel, F2 the Rate leg.
/// @dev Both directions are pinned: a market naming this borrower must not refuse a legal open, and one naming
/// @dev somebody else must not admit it. The gate contracts these rows used are gone; the field says the same thing.
contract AceQuoteOpenBorrowerIdentityTest is Test {
    Ace internal ace;
    AceReader internal read;
    PositionManager internal pm;
    AceLens internal lens;
    MockERC20 internal usdc;
    MockStakeVault internal vault;
    MockPersistenceRecord internal record;

    address internal alice = address(0xA11CE);
    address internal borrower = address(0xB0B);
    address internal op = address(0x0123);

    uint64 internal constant TEN7 = 7 days;
    uint256 internal constant P = 70_000e6;
    uint256 internal constant COLL = 100_000e18;
    uint256 internal constant TOP = 400_000e6;
    uint256 internal T; // ticks above this pair's par; assigned in setUp, since par is not a compile-time value

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
        T = _price(0);
        record = new MockPersistenceRecord(address(usdc), address(vault));
        AceFixtures.Deployment memory d = AceFixtures.deploy(_params(address(0)));
        (ace, pm, read) = (d.ace, d.positionManager, d.read);
        lens = new AceLens(address(ace));
    }

    function _params(address borrower_) internal view returns (MarketParams memory p) {
        p = AceFixtures.marketParams(address(usdc), address(vault));
        p.record = address(record);
        p.borrower = borrower_; // the id differentiator, and the whole admission rule
        p.baseBps = 40;
    }

    function _market(address borrower_) internal returns (bytes32 mid) {
        mid = ace.createMarket(_params(borrower_));
        usdc.mint(alice, TOP);
        vm.startPrank(alice);
        usdc.approve(address(ace), TOP);
        ace.deposit(mid, TOP);
        vm.stopPrank();
    }

    function _armBorrower() internal {
        vault.mint(borrower, COLL);
        vm.startPrank(borrower);
        vault.approve(address(pm), COLL);
        usdc.approve(address(ace), type(uint256).max);
        vm.stopPrank();
    }

    /// @notice CONTROL: on a market naming this borrower, their own quote and open agree.
    function test_Control_NamedBorrower_QuotesAndOpensAlike() public {
        bytes32 mid = _market(borrower);
        _armBorrower();
        vm.prank(borrower);
        Borrower.Quote memory q = ace.previewOpen(mid, COLL, P, TEN7, borrower, OpenBounds(0, 0, 0));
        vm.prank(borrower);
        uint256 loanId = ace.open(mid, COLL, P, TEN7, borrower, OpenBounds(0, 0, 0));
        assertEq(read.fundingFloor(mid, loanId), q.postDrawFloor, "the borrower's own quote is the borrower's own open");
    }

    /// @notice ADMITTED: the lens admits what the named borrower can open, because both doors read the borrower.
    function test_Lens_OnAMarketNamingThem_AdmitsTheDrawTheBorrowerCanOpen() public {
        bytes32 mid = _market(borrower);
        _armBorrower();

        (bool ok, bytes4 reason,) = lens.tryQuoteOpen(mid, COLL, P, TEN7, borrower, OpenBounds(0, 0, 0));
        emit log_named_bytes32("lens reason", bytes32(reason));

        vm.prank(borrower);
        uint256 loanId = ace.open(mid, COLL, P, TEN7, borrower, OpenBounds(0, 0, 0));
        assertGt(loanId, 0, "the borrower's open succeeds");
        assertTrue(ok, "so the lens must quote it admissible, on the BORROWER's identity");
    }

    /// @notice REFUSED: the lens refuses a draw the market refuses this borrower, because both doors read the field.
    function test_Lens_OnAMarketNamingAnother_RefusesTheDrawTheBorrowerCannotOpen() public {
        bytes32 mid = _market(address(0xB10CED)); // names somebody else, so this borrower is refused
        _armBorrower();

        (bool ok,,) = lens.tryQuoteOpen(mid, COLL, P, TEN7, borrower, OpenBounds(0, 0, 0));

        vm.prank(borrower);
        vm.expectRevert(GateRefused.selector);
        ace.open(mid, COLL, P, TEN7, borrower, OpenBounds(0, 0, 0));
        assertFalse(ok, "the market refuses this borrower, so the lens must not have quoted it admissible");
    }

    /// @notice OPERATOR: a credit operator's quote is gated on the borrower it opens for, not on itself.
    /// @dev Both doors now take `borrower` in the same position, so neither can ask about a different party.
    function test_Operator_QuotesOnTheBorrowersIdentity_AsItOpensOnIt() public {
        bytes32 mid = _market(borrower);
        vault.mint(op, COLL);
        vm.startPrank(op);
        vault.approve(address(pm), COLL);
        usdc.approve(address(ace), type(uint256).max);
        vm.stopPrank();
        vm.prank(borrower);
        ace.setCreditOperator(op, true);

        vm.prank(op);
        (bool ok, bytes memory ret) = address(ace).staticcall(abi.encodeCall(Ace.previewOpen, (mid, COLL, P, TEN7, borrower, OpenBounds(0, 0, 0))));
        bytes4 sel = ret.length >= 4 ? bytes4(ret) : bytes4(0);
        emit log_named_bytes32("operator quote reason", bytes32(sel));

        vm.prank(op);
        uint256 loanId = ace.open(mid, COLL, P, TEN7, borrower, OpenBounds(0, 0, 0));
        assertGt(loanId, 0, "the operator opens in the listed borrower's name");
        assertTrue(ok, "so its quote for that open must be admissible: it names the same borrower");
    }

    /// @notice A stranger holding no grant still gets a real quote for a listed borrower.
    /// @notice ADMISSIBILITY IS NOT AUTHORIZATION, and mirroring `open`'s operator gate here would reopen this bug.
    /// @dev `AceLens` is exactly such a stranger: it is a contract nobody grants, so a gated quote door refuses everyone.
    function test_Preview_DoesNotGateOnCreditOperatorAuthorization() public {
        bytes32 mid = _market(borrower);
        _armBorrower();

        address stranger = address(0x57A);
        vm.prank(stranger);
        Borrower.Quote memory q = ace.previewOpen(mid, COLL, P, TEN7, borrower, OpenBounds(0, 0, 0));
        assertGt(q.postDrawFloor, 0, "a caller with no grant still quotes the listed borrower's draw");

        vm.prank(stranger);
        vm.expectRevert();
        ace.open(mid, COLL, P, TEN7, borrower, OpenBounds(0, 0, 0));
    }

    /// @notice The stranger's `open` is refused BY NAME, so the row above pins authorization and not a fixture slip.
    /// @dev A bare `vm.expectRevert()` there is satisfied by a missing approval just as well as by the grant check.
    /// @dev `NotAuthorized` is the ONE selector that says the quote/open split is authorization and nothing else.
    function test_Preview_TheStrangersOpen_IsRefusedByTheGrantCheckItself() public {
        bytes32 mid = _market(borrower);
        _armBorrower();

        address stranger = address(0x57B);
        vault.mint(stranger, COLL); // funded, so only the grant can be what is missing
        vm.startPrank(stranger);
        vault.approve(address(pm), COLL);
        usdc.approve(address(ace), type(uint256).max);
        vm.stopPrank();

        vm.prank(stranger);
        ace.previewOpen(mid, COLL, P, TEN7, borrower, OpenBounds(0, 0, 0)); // must not revert: a quote asks no grant

        vm.prank(stranger);
        vm.expectRevert(NotAuthorized.selector);
        ace.open(mid, COLL, P, TEN7, borrower, OpenBounds(0, 0, 0));

        vm.prank(borrower);
        ace.setCreditOperator(stranger, true);
        vm.prank(stranger);
        uint256 loanId = ace.open(mid, COLL, P, TEN7, borrower, OpenBounds(0, 0, 0));
        assertGt(loanId, 0, "and the grant is the ONLY thing that was missing");
        assertEq(read.loan(loanId).borrower, borrower, "titled to the party the quote named");
    }
}
