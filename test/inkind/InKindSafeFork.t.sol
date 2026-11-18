// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.36;

import {Loan} from "../../src/ace/hub/Types.sol";
import {Extension, IRollPolicy} from "../../src/interfaces/IRollPolicy.sol";
import {IInKindTerms, Quote, RollQuote} from "./InKindSurface.sol";
import {InKindRig} from "./InKindRig.sol";

/// @notice The two Safe v1.4.1 factory and setup calls the fork row makes.
interface ISafeProxyFactory141 {
    function createProxyWithNonce(address singleton, bytes memory initializer, uint256 saltNonce) external returns (address proxy);
}

/// @notice A Safe v1.4.1 proxy, with the compatibility fallback handler's message hash reached through its fallback.
interface ISafe141 {
    function setup(
        address[] calldata owners,
        uint256 threshold,
        address to,
        bytes calldata data,
        address fallbackHandler,
        address paymentToken,
        uint256 payment,
        address payable paymentReceiver
    ) external;
    function getThreshold() external view returns (uint256);
    function getMessageHash(bytes memory message) external view returns (bytes32);
}

/// @title InKindSafeFork
/// @notice The production appraiser on a Base fork: a canonical Safe v1.4.1 L2 proxy with the compatibility fallback handler, M-of-N owners.
/// @notice The owners sign the Safe's OWN message hash, which wraps the vault's digest in a SafeMessage, so no mock stands in for the real path.
/// @notice An extension's signature check must fit the hub's policy budget, read off the hub as deployed, or a cold Safe's answer is a silent no.
/// @dev Skipped without `BASE_RPC_URL` or `ALCHEMY_API_KEY`; every Safe address is checked for code first, so a wrong address fails loudly.
contract InKindSafeForkTest is InKindRig {
    address internal constant SAFE_FACTORY = 0x4e1DCf7AD4e460CfD30791CCC4F9c8a4f820ec67; // SafeProxyFactory v1.4.1
    address internal constant SAFE_L2 = 0x29fcB43b46531BcA003ddC8FCB67FFE91900C762; // SafeL2 v1.4.1 singleton
    address internal constant FALLBACK_HANDLER = 0xfd0732Dc9E303f09fCEf3a7388Ad10A83459Ec99; // CompatibilityFallbackHandler v1.4.1
    uint256 internal constant FORK_BLOCK = 53_118_834; // a Base block the repo's other fork rows already pin
    bool internal live;

    function setUp() public override {
        string memory url = vm.envOr("BASE_RPC_URL", string(""));
        if (bytes(url).length == 0 && bytes(vm.envOr("ALCHEMY_API_KEY", string(""))).length != 0) url = vm.rpcUrl("base");
        if (bytes(url).length == 0) return; // every row skips on !live
        live = true;
        vm.createSelectFork(url, FORK_BLOCK);
        super.setUp();
        _lp(alice, LP_CASH);
    }

    /// @dev A canonical `m`-of-`n` Safe with the compatibility handler and no modules, and its owners' keys ascending by address.
    function _realSafe(uint256 m, uint256 n) internal returns (address safe, uint256[] memory keys) {
        keys = new uint256[](n);
        for (uint256 i; i < n; i++) {
            keys[i] = 0x5AFE5AFE00 + i;
        }
        for (uint256 i = 1; i < n; i++) {
            for (uint256 j = i; j > 0 && vm.addr(keys[j - 1]) > vm.addr(keys[j]); j--) {
                (keys[j - 1], keys[j]) = (keys[j], keys[j - 1]);
            }
        }
        address[] memory owners = new address[](n);
        for (uint256 i; i < n; i++) {
            owners[i] = vm.addr(keys[i]);
        }
        bytes memory init = abi.encodeCall(ISafe141.setup, (owners, m, address(0), "", FALLBACK_HANDLER, address(0), 0, payable(address(0))));
        safe = ISafeProxyFactory141(SAFE_FACTORY).createProxyWithNonce(SAFE_L2, init, uint256(keccak256("inkind appraiser safe")));
        assertEq(ISafe141(safe).getThreshold(), m, "premise: the Safe is M-of-N as built");
    }

    /// @dev The first `m` owners' ECDSA signatures over the Safe's own message hash of the vault's `digest`, ascending by owner.
    function _signedBy(address safe, uint256[] memory keys, uint256 m, bytes32 digest) internal view returns (bytes memory sigs) {
        bytes32 h = ISafe141(safe).getMessageHash(abi.encode(digest));
        for (uint256 i; i < m; i++) {
            sigs = abi.encodePacked(sigs, _sig(keys[i], h));
        }
    }

    /// @dev The extension the hub hands the vault when the holder extends `id` now: its own tenor from now, `dst` a copy of `src`.
    function _ext(uint256 id) internal view returns (Extension memory e) {
        Loan memory l = read.loan(id);
        (e.caller, e.loanId, e.borrower, e.units, e.debt, e.newDebt) = (l.borrower, id, l.borrower, l.collateralUnits, l.debt, l.debt);
        (e.expiry, e.newExpiry, e.src, e.dst) = (l.expiry, uint64(_now()) + l.tenor, _mp(id), _mp(id));
    }

    /// @notice A canonical 3-of-5 Safe appraiser prices a borrow, and cold, its roll consent fits the hub's policy budget and the hub's ask lands.
    function test_fork_aCanonicalSafeAppraiserPricesAndFitsThePolicyBudget() public {
        if (!live) vm.skip(true);
        assertGt(SAFE_FACTORY.code.length, 0, "premise: the v1.4.1 factory is deployed on this fork");
        assertGt(SAFE_L2.code.length, 0, "premise: and the L2 singleton");
        assertGt(FALLBACK_HANDLER.code.length, 0, "premise: and the compatibility fallback handler");
        uint256 loanId = _open(address(tokA));
        (address safe, uint256[] memory keys) = _realSafe(3, 5);
        _appoint(safe);
        assertEq(terms.APPRAISER(), safe, "the Safe holds the seat");

        Quote memory q = _quote(address(tokA), PRICE);
        bytes memory two = abi.encode(q, _signedBy(safe, keys, 2, terms.hashQuote(q)));
        _fund(address(tokA), borrower, UNITS);
        vm.prank(borrower);
        vm.expectRevert(IInKindTerms.BadSignature.selector);
        vault.borrow(_req(address(tokA), UNITS, PRINCIPAL, MIN_TENOR), two, "");
        bytes memory three = abi.encode(q, _signedBy(safe, keys, 3, terms.hashQuote(q)));
        assertGt(_borrowWith(q, three, UNITS, PRINCIPAL, MIN_TENOR), 0, "three of five owners price a loan");

        _warpAtLeastTo(_expiry(loanId) - 1 hours);
        RollQuote memory rq = RollQuote({loanId: loanId, expiry: uint64(_expiry(loanId)), price: _mp(loanId).price, issuedAt: uint64(_now())});
        bytes memory data = abi.encode(rq, _signedBy(safe, keys, 3, terms.hashRollQuote(rq)));
        Extension memory e = _ext(loanId);
        vm.cool(address(vault));
        vm.cool(address(terms));
        vm.cool(safe);
        vm.cool(SAFE_L2);
        vm.cool(FALLBACK_HANDLER);
        uint256 g = gasleft();
        bytes4 answer = vault.admitsExtension(e, data);
        uint256 used = g - gasleft();
        emit log_named_uint("INKIND admitsExtension gas, canonical 3-of-5 Safe v1.4.1 appraiser, cold", used);
        assertEq(answer, IRollPolicy.admitsExtension.selector, "the Safe's roll consent admits it");
        assertLt(used, ace.POLICY_GAS(), "under the hub's policy budget as deployed");
        _armFee(loanId, MIN_TENOR);
        vm.prank(borrower);
        ace.extend(loanId, 0, data);
        assertEq(_expiry(loanId), _now() + MIN_TENOR, "and the hub's capped ask landed the extension");
    }
}
