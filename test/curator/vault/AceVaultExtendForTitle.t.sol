// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.36;

import {IERC721} from "@openzeppelin/contracts/token/ERC721/IERC721.sol";
import {WarpClock} from "../../utils/WarpClock.sol";
import {AceFixtures} from "../../utils/AceFixtures.sol";
import {AceReader} from "../../utils/AceReader.sol";
import {VaultSeed} from "../../utils/VaultSeed.sol";
import {MockERC20} from "../../mocks/MockERC20.sol";
import {MockStakeVault} from "../../mocks/MockStakeVault.sol";
import {MockPersistenceRecord} from "../../mocks/MockPersistenceRecord.sol";
import {Ace} from "../../../src/ace/hub/Ace.sol";
import {ExtensionAddsNoTime, ExtensionTooEarly, UnderPrice} from "../../../src/ace/hub/Borrower.sol";
import {LoanMath} from "../../../src/ace/hub/libraries/LoanMath.sol";
import {Loan, MarketParams} from "../../../src/ace/hub/Types.sol";
import {AceVault} from "../../../src/curator/AceVault.sol";
import {CapListing, ProductConfig} from "../../../src/curator/AceVaultCaps.sol";
import {BorrowRequest, Terms, VaultConfig} from "../../../src/curator/AceVaultFlows.sol";
import {IAceVaultDoor} from "../../../src/interfaces/IAceVaultDoor.sol";
import {RecordingTerms} from "./AceVaultExtendFor.t.sol";

/// @title AceVaultExtendForTitleTest
/// @notice D-3: `extendFor` reaches the hub as the holder's title operator, as `refinanceFor` does, so the vault renews as the holder would.
/// @notice Without the holder's title approval the vault is a non-holder, held to the hub's three legs; a credit grant seats nothing.
contract AceVaultExtendForTitleTest is WarpClock {
    Ace internal ace;
    AceReader internal read;
    MockERC20 internal usdc;
    MockStakeVault internal coll;
    MockPersistenceRecord internal record;
    AceVault internal vault;
    IAceVaultDoor internal door;
    RecordingTerms internal terms;
    IERC721 internal titles;

    address internal curator = address(0xC0A11);
    address internal guardian = address(0x6A2E);
    address internal alice = address(0xA11CE);
    address internal borrower = address(0xB0BA5);

    uint64 internal constant TENOR = 7 days;
    uint256 internal constant UNITS = 2_000e18;
    uint256 internal constant PRINCIPAL = 1_000e6;
    uint192 internal constant UNCAPPED = type(uint192).max;

    function setUp() public {
        _warpTo(1_000_000);
        usdc = new MockERC20("USD Coin", "USDC", 6);
        coll = new MockStakeVault(42);
        (ace,) = AceFixtures.newAceWithEscrow(AceFixtures.TREASURY);
        read = new AceReader(address(ace));
        titles = IERC721(ace.POSITION_TITLE());
        record = new MockPersistenceRecord(address(usdc), address(coll));
        record.setMinPrice(AceFixtures.px(2e18, address(usdc), address(coll)));
        record.setObserved(AceFixtures.px(2e18, address(usdc), address(coll)));
        address predicted = vm.computeCreateAddress(address(this), vm.getNonce(address(this)) + 1);
        terms = new RecordingTerms(predicted, address(ace));
        ProductConfig memory pc =
            ProductConfig({terms: address(terms), door: address(0), inKind: false, drainable: true, capTimelock: 3 days, minTenor: 1 days, maxTenor: 30 days});
        CapListing[] memory caps = new CapListing[](2);
        (caps[0], caps[1]) = (CapListing(address(coll), UNCAPPED), CapListing(predicted, UNCAPPED));
        VaultConfig memory cfg = VaultConfig({
            ace: address(ace), asset: address(usdc), curator: curator, guardian: guardian, perfFeeBps: 0, vestWindow: 1 days, seed: VaultSeed.SEED
        });
        VaultSeed.fund(cfg, predicted);
        vault = new AceVault(cfg, pc, caps, "Ext", "eVLT");
        assertEq(address(vault), predicted, "rig: the vault landed off its predicted address");
        door = IAceVaultDoor(address(vault));
        MarketParams memory p = AceFixtures.marketParams(address(usdc), address(coll));
        (p.record, p.lender, p.settleBountyBps, p.minTenor, p.maxTenor) = (address(record), predicted, 0, TENOR, TENOR);
        terms.setTerms(p, Terms({units: UNITS, principal: PRINCIPAL, tenor: 0, minBufferWad: 0}));
        usdc.mint(alice, 1_000_000e6);
        vm.startPrank(alice);
        usdc.approve(address(vault), type(uint256).max);
        vault.deposit(1_000_000e6, alice);
        vm.stopPrank();
    }

    /// @dev A loan to the borrower through the vault, a day old, with neither a grant nor a title approval to the vault.
    function _loan() internal returns (uint256 loanId) {
        coll.mint(borrower, UNITS);
        vm.startPrank(borrower);
        coll.approve(address(vault), UNITS);
        loanId = vault.borrow(BorrowRequest(address(coll), UNITS, PRINCIPAL, 0, 0, 0, 0), "", "");
        vm.stopPrank();
        _warpBy(1 days);
    }

    function _fee(uint256 loanId) internal view returns (uint256) {
        MarketParams memory mp = ace.idToMarketParams(ace.loanMarket(loanId));
        Loan memory l = read.loan(loanId);
        return LoanMath.originationFee(read.debtOf(loanId), uint64(_now()) + l.tenor - l.expiry, mp.lenderAprBps);
    }

    /// @dev The borrower renews through the door, funded and approved for exactly the fee.
    function _renew(uint256 loanId) internal returns (uint256) {
        uint256 fee = _fee(loanId);
        usdc.mint(borrower, fee);
        vm.prank(borrower);
        usdc.approve(address(vault), fee);
        vm.prank(borrower);
        return door.extendFor(loanId, fee, 0, "", "");
    }

    function _renewRefused(uint256 loanId, bytes4 err) internal {
        uint256 fee = _fee(loanId);
        usdc.mint(borrower, fee);
        vm.prank(borrower);
        usdc.approve(address(vault), fee);
        vm.prank(borrower);
        vm.expectRevert(err);
        door.extendFor(loanId, fee, 0, "", "");
    }

    /// @notice The holder's approval of the vault for all its titles seats the vault: it renews a day in, as the holder would.
    function test_AnAllTitlesApprovalSeatsTheVault() public {
        uint256 loanId = _loan();
        vm.prank(borrower);
        titles.setApprovalForAll(address(vault), true);
        _renew(loanId);
        assertEq(read.loan(loanId).expiry, _now() + TENOR, "the vault renewed early as the holder's operator");
        assertEq(titles.ownerOf(loanId), borrower, "and the title never moved");
    }

    /// @notice An approval for this one title seats the vault too.
    function test_ATokenApprovalSeatsTheVault() public {
        uint256 loanId = _loan();
        vm.prank(borrower);
        titles.approve(address(vault), loanId);
        _renew(loanId);
        assertEq(read.loan(loanId).expiry, _now() + TENOR, "the vault renewed early on the token approval");
    }

    /// @notice Unapproved, the vault is a non-holder: a day in it is refused `ExtensionTooEarly`; in the last quarter, in fair weather, it lands.
    function test_WithoutTheApprovalTheVaultIsANonHolder() public {
        uint256 loanId = _loan();
        _renewRefused(loanId, ExtensionTooEarly.selector);
        _warpTo(uint256(read.loan(loanId).expiry) - TENOR / 4);
        _renew(loanId);
        assertEq(read.loan(loanId).expiry, _now() + TENOR, "in the last quarter anyone may renew, the vault included");
    }

    /// @notice Unapproved and under the price, the vault is refused `UnderPrice` even in the last quarter; approved, it renews.
    function test_UnderThePriceOnlyTheApprovedVaultRenews() public {
        uint256 loanId = _loan();
        record.setMinPrice((ace.idToMarketParams(ace.loanMarket(loanId)).price * 9) / 10);
        _warpTo(uint256(read.loan(loanId).expiry) - TENOR / 4);
        _renewRefused(loanId, UnderPrice.selector);
        vm.prank(borrower);
        titles.setApprovalForAll(address(vault), true);
        _renew(loanId);
        assertEq(read.loan(loanId).expiry, _now() + TENOR, "the approved vault renews under the price, as the holder would");
    }

    /// @notice The holder's credit grant no longer seats the vault: with it alone the vault is still a non-holder, refused a day in.
    function test_ACreditGrantSeatsNothing() public {
        uint256 loanId = _loan();
        vm.prank(borrower);
        ace.setCreditOperator(address(vault), true);
        _renewRefused(loanId, ExtensionTooEarly.selector);
    }

    /// @notice The six-argument door that relayed a grant is gone: a funded call by its selector, the grant standing, finds nothing.
    function test_TheGrantRelayingDoorIsGone() public {
        uint256 loanId = _loan();
        bytes4 old = bytes4(keccak256("extendFor(uint256,uint256,uint256,bytes,bytes,bytes)"));
        uint256 fee = _fee(loanId);
        usdc.mint(borrower, fee);
        vm.startPrank(borrower);
        usdc.approve(address(vault), fee);
        ace.setCreditOperator(address(vault), true);
        vm.stopPrank();
        vm.prank(borrower);
        (bool ok,) = address(vault).call(abi.encodeWithSelector(old, loanId, type(uint256).max, uint256(0), bytes(""), bytes(""), bytes("")));
        assertFalse(ok, "the grant-relaying door still answers");
    }

    /// @notice The disclosed residual: in the last quarter a stranger renews a vault loan straight at the hub, paying, and no product hook runs.
    /// @notice The holder's renewal through the door in that second then refuses `ExtensionAddsNoTime`, and costs the holder no quote.
    function test_AStrangersHubRenewalLandsFirstAndTheHoldersDoorCallRefuses() public {
        uint256 loanId = _loan();
        _warpTo(uint256(read.loan(loanId).expiry) - TENOR / 4);
        uint256 fee = _fee(loanId);
        uint256 hooks = terms.calls().length;
        address stranger = address(0x5EE);
        usdc.mint(stranger, fee);
        vm.prank(stranger);
        usdc.approve(address(ace), fee);
        vm.prank(stranger);
        assertEq(ace.extend(loanId, 0, ""), fee, "the stranger paid the fee on the time added");
        assertEq(read.loan(loanId).expiry, _now() + TENOR, "the stranger's renewal landed at the hub");
        assertEq(terms.calls().length, hooks, "and no product hook ran for it");
        usdc.mint(borrower, fee);
        vm.prank(borrower);
        usdc.approve(address(vault), fee);
        uint256 bal = usdc.balanceOf(borrower);
        vm.prank(borrower);
        vm.expectRevert(ExtensionAddsNoTime.selector);
        door.extendFor(loanId, fee, 0, "", "");
        assertEq(usdc.balanceOf(borrower), bal, "the refused renewal cost the holder no quote");
    }
}
