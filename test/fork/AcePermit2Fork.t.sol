// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.36;

import {Test} from "forge-std/Test.sol";
import {WarpClock} from "../utils/WarpClock.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {Ace} from "../../src/ace/hub/Ace.sol";
import {Loan, MarketParams, OpenBounds} from "../../src/ace/hub/Types.sol";
import {PositionManager} from "../../src/ace/positions/PositionManager.sol";
import {IPermit2} from "../../src/interfaces/IPermit2.sol";
import {MockPersistenceRecord} from "../mocks/MockPersistenceRecord.sol";
import {MockStakeVault} from "../mocks/MockStakeVault.sol";
import {AceFixtures} from "../utils/AceFixtures.sol";
import {AceReader} from "../utils/AceReader.sol";

/// @title AcePermit2Fork
/// @notice The Permit2 flows against CANONICAL Permit2 and real USDC on a mainnet fork.
/// @notice This is the proof the mock cannot give: real domain, real nonce bitmap, real spender binding.
/// @dev Skipped cleanly when ALCHEMY_API_KEY is absent, exactly as the YB lifecycle fork suite is.
contract AcePermit2ForkTest is WarpClock {
    address internal constant PERMIT2 = 0x000000000022D473030F116dDEE9F6B43aC78BA3;
    address internal constant USDC = 0xA0b86991c6218b36c1d19D4a2e9Eb0cE3606eB48;

    bytes32 internal constant TOKEN_PERMISSIONS_TYPEHASH = keccak256("TokenPermissions(address token,uint256 amount)");
    bytes32 internal constant PERMIT_TRANSFER_FROM_TYPEHASH = keccak256(
        "PermitTransferFrom(TokenPermissions permitted,address spender,uint256 nonce,uint256 deadline)" "TokenPermissions(address token,uint256 amount)"
    );

    error InvalidSigner(); // canonical Permit2's selector, declared for expectRevert

    bool internal live;
    Ace internal ace;
    AceReader internal read;
    PositionManager internal positionManager;
    MockStakeVault internal vault;
    bytes32 internal id;

    uint256 internal constant LENDER_PK = 0xA11CE;
    address internal lender;
    // WAS a second lender. Sole tenancy admits ONE per market, and the permit rows must deposit as the SIGNER.
    address internal attacker = address(0xBAD);

    uint256 internal T2; // ticks above this pair's par; assigned in setUp, since par is not a compile-time value
    uint256 internal T4;
    uint256 internal constant COLL = 10_000e18;
    uint256 internal constant PRINCIPAL = 4_500e6;

    /// @dev This suite's pair, so a tick reads as its distance from par rather than as a grid coordinate.
    /// @param offset Ticks above par.
    /// @return The absolute grid tick.
    function _price(int24 offset) internal view returns (uint256) {
        return AceFixtures.priceAt(USDC, address(vault), offset);
    }

    function setUp() public {
        string memory key = vm.envOr("ALCHEMY_API_KEY", string(""));
        if (bytes(key).length == 0) return; // every test vm.skips on !live
        live = true;
        uint256 blockNum = vm.envOr("ACE_FORK_BLOCK", uint256(25_717_936));
        string memory url = string.concat("https://eth-mainnet.g.alchemy.com/v2/", key);
        if (blockNum == 0) vm.createSelectFork(url);
        else vm.createSelectFork(url, blockNum);
        _anchorClock(); // the fork moved block.timestamp; every deadline below is signed off the clock

        lender = vm.addr(LENDER_PK);
        vault = new MockStakeVault(42);
        (T2, T4) = (_price(0), _price(960));
        MarketParams memory p = AceFixtures.marketParams(USDC, address(vault));
        p.lender = lender; // sole tenancy: this suite deposits as the permit SIGNER, so the market names them
        p.record = address(new MockPersistenceRecord(USDC, address(vault)));
        AceFixtures.Deployment memory d = AceFixtures.deploy(p);
        (ace, positionManager, read, id) = (d.ace, d.positionManager, d.read, d.id);
    }

    // ---- helpers ----

    function _domain() internal view returns (bytes32) {
        (bool ok, bytes memory ret) = PERMIT2.staticcall(abi.encodeWithSignature("DOMAIN_SEPARATOR()"));
        require(ok, "no DOMAIN_SEPARATOR at canonical Permit2");
        return abi.decode(ret, (bytes32));
    }

    function _signToken(uint256 pk, address token, uint256 amt, uint256 nonce, uint256 deadline, address spender) internal view returns (bytes memory) {
        bytes32 structHash =
            keccak256(abi.encode(PERMIT_TRANSFER_FROM_TYPEHASH, keccak256(abi.encode(TOKEN_PERMISSIONS_TYPEHASH, token, amt)), spender, nonce, deadline));
        bytes32 digest = keccak256(abi.encodePacked("\x19\x01", _domain(), structHash));
        (uint8 v, bytes32 r, bytes32 s) = vm.sign(pk, digest);
        return abi.encodePacked(r, s, v);
    }

    function _sign(uint256 pk, uint256 amt, uint256 nonce, uint256 deadline, address spender) internal view returns (bytes memory) {
        return _signToken(pk, USDC, amt, nonce, deadline, spender);
    }

    function _permit(uint256 amt, uint256 nonce, uint256 deadline) internal pure returns (IPermit2.PermitTransferFrom memory) {
        return IPermit2.PermitTransferFrom(IPermit2.TokenPermissions(USDC, amt), nonce, deadline);
    }

    function _blob(uint256 pk, uint256 amt, uint256 nonce) internal view returns (bytes memory) {
        uint256 deadline = _now() + 1 hours;
        return abi.encode(_permit(amt, nonce, deadline), _sign(pk, amt, nonce, deadline, address(ace)));
    }

    function _blobToken(uint256 pk, address token, uint256 amt, uint256 nonce) internal view returns (bytes memory) {
        uint256 deadline = _now() + 1 hours;
        IPermit2.PermitTransferFrom memory p = IPermit2.PermitTransferFrom(IPermit2.TokenPermissions(token, amt), nonce, deadline);
        return abi.encode(p, _signToken(pk, token, amt, nonce, deadline, address(ace)));
    }

    function _fundViaPermit2Only(address who, uint256 amt) internal {
        deal(USDC, who, amt);
        vm.prank(who);
        IERC20(USDC).approve(PERMIT2, type(uint256).max);
    }

    function _fundLadder() internal {
        deal(USDC, lender, 10_000e6);
        vm.startPrank(lender);
        IERC20(USDC).approve(address(ace), 10_000e6);
        ace.deposit(id, 5_000e6);
        ace.deposit(id, 5_000e6);
        vm.stopPrank();
    }

    // ---- the four proofs ----

    function test_Fork_DepositWithPermit2_RealPermit2RealUsdc() public {
        if (!live) return vm.skip(true);
        _fundViaPermit2Only(lender, 1000e6);
        bytes memory blob = _blob(LENDER_PK, 1000e6, 0);

        vm.prank(lender);
        ace.depositWithPermit2(id, 1000e6, blob);

        assertEq(ace.restingOf(id), 1000e6, "the signer's lot rests whole");
        assertEq(IERC20(USDC).allowance(lender, address(ace)), 0, "no ERC20 allowance to ACE, on the real rails");
        assertEq(read.marketState(id).cash, 1000e6, "real USDC landed in the market");
    }

    function test_Fork_RepayWithPermit2_FullRoundTrip() public {
        if (!live) return vm.skip(true);
        _fundLadder();
        vault.mint(lender, COLL);
        vm.startPrank(lender);
        vault.approve(address(positionManager), COLL);
        uint256 loanId = ace.open(id, COLL, PRINCIPAL, 0, lender, OpenBounds(0, 0, 0));
        vm.stopPrank();

        _fundViaPermit2Only(lender, PRINCIPAL);
        bytes memory blob = _blob(LENDER_PK, PRINCIPAL, 1);
        vm.prank(lender);
        ace.repayWithPermit2(loanId, PRINCIPAL, blob);

        assertTrue(read.loan(loanId).closedAt != 0, "closed against canonical Permit2");
        vm.prank(lender); // the close CREDITS the collateral; the pull delivers it
        ace.claimOwed(loanId, lender);
        assertEq(vault.balanceOf(lender), COLL, "collateral released");
    }

    /// @dev Spender binding, unmockable: naming ACE makes a third party's DIRECT submission a bad digest.
    function test_Fork_DirectSubmissionByThirdParty_RevertsAndBurnsNoNonce() public {
        if (!live) return vm.skip(true);
        _fundViaPermit2Only(lender, 1000e6);
        uint256 deadline = _now() + 1 hours;
        IPermit2.PermitTransferFrom memory p = _permit(1000e6, 0, deadline);
        bytes memory sig = _sign(LENDER_PK, 1000e6, 0, deadline, address(ace));

        vm.prank(attacker);
        vm.expectRevert(InvalidSigner.selector);
        IPermit2(PERMIT2).permitTransferFrom(p, IPermit2.SignatureTransferDetails({to: attacker, requestedAmount: 1000e6}), lender, sig);

        // the failed relay burned nothing: the signer's own transaction still spends the permit
        bytes memory blob = abi.encode(p, sig);
        vm.prank(lender);
        ace.depositWithPermit2(id, 1000e6, blob);
        assertEq(ace.restingOf(id), 1000e6, "nonce survived the attempted grief");
    }

    /// @dev The collateral leg on real rails: signature to the hub, hand-on to the custodian's pot.
    function test_Fork_OpenWithPermit2_CollateralBySignature() public {
        if (!live) return vm.skip(true);
        _fundLadder();
        vault.mint(lender, COLL);
        vm.prank(lender);
        vault.approve(PERMIT2, type(uint256).max);
        bytes memory blob = _blobToken(LENDER_PK, address(vault), COLL, 5);

        vm.prank(lender);
        uint256 loanId = ace.openWithPermit2(id, COLL, PRINCIPAL, 0, lender, OpenBounds(0, 0, 0), blob);

        assertEq(positionManager.collateralOf(loanId), COLL, "custody via canonical Permit2");
        assertEq(vault.balanceOf(address(ace)), 0, "hub custody was transient on the real contract too");
        assertEq(vault.allowance(address(ace), address(positionManager)), 0, "hand-on approval fully consumed");
        assertGt(IERC20(USDC).balanceOf(lender), 0, "real USDC drawn against permit-posted collateral");
    }

    function test_Fork_OverSignedPermit_PullsOnlyAssets() public {
        if (!live) return vm.skip(true);
        _fundViaPermit2Only(lender, 2000e6);
        bytes memory blob = _blob(LENDER_PK, 2000e6, 0);

        vm.prank(lender);
        ace.depositWithPermit2(id, 800e6, blob);

        assertEq(IERC20(USDC).balanceOf(lender), 1200e6, "requestedAmount pinned on the real contract");
    }
}
