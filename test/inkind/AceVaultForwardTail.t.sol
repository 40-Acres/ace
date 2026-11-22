// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.36;

import {AceVaultCaps} from "../../src/curator/libraries/AceVaultCaps.sol";
import {AceVaultFlows} from "../../src/curator/libraries/AceVaultFlows.sol";
import {AceVaultInKind} from "../../src/curator/libraries/AceVaultInKind.sol";
import {AceVaultTail} from "../../src/curator/libraries/AceVaultTail.sol";
import {AceVaultBaseRig} from "../curator/vault/AceVaultBaseRig.sol";
import {IInKindVault} from "./InKindSurface.sol";
import {InKindRig} from "./InKindRig.sol";

/// @dev Answers every call with its own calldata, so a vault forwarding into it returns exactly what it sent.
contract CalldataEcho {
    fallback() external payable {
        assembly ("memory-safe") {
            calldatacopy(0, 0, calldatasize())
            return(0, calldatasize())
        }
    }
}

/// @dev The production readers over whatever suffix ends the call.
contract TailReader {
    function read() external pure returns (address hub, address cur, address guard, uint64 lock, bool kind, address cash) {
        (hub, cur, guard, lock) = (AceVaultTail.ace(), AceVaultTail.curator(), AceVaultTail.guardian(), AceVaultTail.capTimelock());
        (kind, cash) = (AceVaultTail.inKind(), AceVaultTail.asset());
    }
}

/// @dev The production terms and mode readers over whatever suffix ends the call.
contract TermsReader {
    function read() external pure returns (address t, bool kind, bool doorMode) {
        return (AceVaultTail.terms(), AceVaultTail.inKind(), AceVaultTail.door());
    }
}

/// @dev Capture what `vault` forwards into AceVaultInKind on a `claim`, then decode its suffix with the production readers and check each field.
abstract contract TailLayoutCheck {
    function _forwarded(address vault, address who) internal returns (bytes memory cd, bytes memory sent) {
        cd = abi.encodeCall(IInKindVault.claim, (new address[](0), who));
        bool ok;
        (ok, sent) = vault.call(cd);
        require(ok, "the forward into the echo failed");
    }

    function _tailOf(bytes memory sent, uint256 at) internal pure returns (bytes memory t) {
        t = new bytes(sent.length - at);
        for (uint256 i; i < t.length; i++) {
            t[i] = sent[at + i];
        }
    }

    function _decode(bytes memory tail) internal returns (address, address, address, uint64, bool, address) {
        (bool ok, bytes memory got) = address(new TailReader()).staticcall(abi.encodePacked(TailReader.read.selector, tail));
        require(ok, "the readers refused the suffix");
        return abi.decode(got, (address, address, address, uint64, bool, address));
    }

    /// @dev The bits no field holds: word 0 above the mode byte, and word 1 above the curator.
    function _freedBits(bytes memory tail) internal pure returns (uint256 w0High, uint256 w1High) {
        (bytes32 w0, bytes32 w1,,) = abi.decode(tail, (bytes32, bytes32, bytes32, bytes32));
        return (uint256(w0) >> 232, uint256(w1) >> 160);
    }

    function _decodeTerms(bytes memory tail) internal returns (address t, bool kind, bool doorMode) {
        (bool ok, bytes memory got) = address(new TermsReader()).staticcall(abi.encodePacked(TermsReader.read.selector, tail));
        require(ok, "the readers refused the suffix");
        return abi.decode(got, (address, bool, bool));
    }
}

/// @title AceVaultForwardTail
/// @notice The forwarded verbs trust only the vault's own figures: a caller's trailing words are ignored, a library refuses a direct call,
/// @notice and the vault refuses a truncated array encoding before any library runs; the suffix decodes to the vault's named getters.
/// @dev The forged words are a well-formed suffix naming the stranger, so a library reading the wrong end would take them.
contract AceVaultForwardTailTest is InKindRig, TailLayoutCheck {
    function setUp() public override {
        super.setUp();
        _lp(alice, LP_CASH);
    }

    /// @dev A suffix a caller appends, naming the stranger as curator and guardian, no timelock, hub-ask mode, a one-second tenor.
    /// @dev The tenor is ORed into word 1's old rail-floor bits by hand: no field reads them now.
    function _forged() internal view returns (bytes memory) {
        (bytes32 w0, bytes32 w1, bytes32 w2, bytes32 w3) = AceVaultTail.pack(address(ace), stranger, stranger, address(tokA), 0, false);
        return abi.encodePacked(w0, w1 | bytes32(uint256(1) << 160), w2, w3);
    }

    // ---- the layout ----

    /// @notice The forward is the call unchanged plus a `SIZE`-byte suffix, and each field of it decodes to the vault's own named getter.
    function test_tail_eachFieldDecodesToItsNamedGetter() public {
        vm.etch(address(AceVaultInKind), address(new CalldataEcho()).code);
        (bytes memory cd, bytes memory sent) = _forwarded(address(vault), alice);
        assertEq(sent.length, cd.length + AceVaultTail.SIZE, "the call plus one fixed suffix");
        assertEq(keccak256(_head(sent, cd.length)), keccak256(cd), "the caller's bytes go first, unchanged");
        bytes memory tail = _tailOf(sent, cd.length);
        (address hub, address cur, address guard, uint64 lock, bool kind, address cash) = _decode(tail);
        assertEq(hub, vault.ACE(), "ACE");
        assertEq(cur, vault.CURATOR(), "CURATOR");
        assertEq(guard, vault.GUARDIAN(), "GUARDIAN");
        assertEq(lock, vault.CAP_TIMELOCK(), "CAP_TIMELOCK");
        assertTrue(kind == vault.IN_KIND() && kind, "IN_KIND");
        assertEq(cash, vault.asset(), "asset");
        (uint256 w0High, uint256 w1High) = _freedBits(tail);
        assertEq(w0High, 0, "word 0 holds nothing above the mode byte");
        assertEq(w1High, 0, "word 1 holds nothing above the curator");
    }

    function _head(bytes memory b, uint256 n) internal pure returns (bytes memory h) {
        h = new bytes(n);
        for (uint256 i; i < n; i++) {
            h[i] = b[i];
        }
    }

    /// @dev `who` calls the vault with `cd` and the forged words after it.
    function _withForged(address who, bytes memory cd) internal returns (bool ok, bytes memory ret) {
        vm.prank(who);
        (ok, ret) = address(vault).call(abi.encodePacked(cd, _forged()));
    }

    function _assertRefused(bool ok, bytes memory ret, bytes4 err, string memory why) internal pure {
        assertFalse(ok, why);
        assertEq(bytes4(ret), err, why);
    }

    // ---- T1: forged trailing words ----

    /// @notice A stranger whose trailing words name it curator and guardian can neither raise, cut nor delist a row, nor revoke a pending change.
    function test_T1_aForgedCuratorIsRefusedEveryCapVerb() public {
        (bool ok, bytes memory ret) = _withForged(stranger, abi.encodeCall(IInKindVault.submitCap, (address(tokA), CAP + 1)));
        _assertRefused(ok, ret, IInKindVault.NotCurator.selector, "a forged curator's raise");
        (ok, ret) = _withForged(stranger, abi.encodeCall(IInKindVault.submitCap, (address(tokA), 0)));
        _assertRefused(ok, ret, IInKindVault.NotCurator.selector, "a forged guardian's cut");
        (ok, ret) = _withForged(stranger, abi.encodeCall(IInKindVault.submitDelist, (address(tokA))));
        _assertRefused(ok, ret, IInKindVault.NotCurator.selector, "a forged curator's delisting");
        vm.prank(curator);
        vault.submitCap(address(tokB), CAP + 1);
        (ok, ret) = _withForged(stranger, abi.encodeCall(IInKindVault.revokePendingCap, (address(tokB))));
        _assertRefused(ok, ret, IInKindVault.NotCurator.selector, "a forged guardian's revoke");
        assertEq(_capOf(address(tokA)), CAP, "the cap never moved");
    }

    /// @notice The curator's raise carrying a forged zero timelock still waits the vault's own `CAP_TIMELOCK`.
    function test_T1_aForgedTimelockDoesNotShortenTheWait() public {
        (bool ok,) = _withForged(curator, abi.encodeCall(IInKindVault.submitCap, (address(tokA), CAP + 1)));
        assertTrue(ok, "premise: the curator's raise is accepted");
        (,, uint64 validAt) = lens.pendingCapOf(address(vault), address(tokA));
        assertEq(validAt, _now() + TIMELOCK, "it waits the vault's timelock, not the forged one");
    }

    /// @notice Forged words naming hub-ask mode leave the in-kind rules on: a nonzero wildcard and the asset as a key still refuse.
    function test_T1_aForgedModeLeavesTheInKindRulesOn() public {
        (bool ok, bytes memory ret) = _withForged(curator, abi.encodeCall(IInKindVault.submitCap, (address(0), 1)));
        _assertRefused(ok, ret, IInKindVault.WildcardInKind.selector, "the wildcard");
        (ok, ret) = _withForged(curator, abi.encodeCall(IInKindVault.submitCap, (address(usdc), CAP)));
        _assertRefused(ok, ret, IInKindVault.CashIsNotCollateral.selector, "the asset");
    }

    // ---- T2: a direct call to a library verb ----

    /// @notice Each of the six forwarded library functions refuses a direct call by the library's own guard, with or without trailing words.
    /// @dev The stranger the in-kind forged words name, over seeded library storage, would land every one of them without that guard.
    function test_T2_aDirectCallToEachForwardedLibraryFunctionReverts() public {
        address caps = address(AceVaultCaps);
        address inKind = address(AceVaultInKind);
        assertGt(caps.code.length, 0, "premise: the caps library is deployed");
        assertGt(inKind.code.length, 0, "premise: the in-kind library is deployed");
        _seedTheCapsLibrary(caps);
        (bytes32 w0, bytes32 w1, bytes32 w2, bytes32 w3) = AceVaultTail.pack(address(ace), stranger, stranger, address(usdc), 0, true);
        bytes memory forged = abi.encodePacked(w0, w1 | bytes32(uint256(1) << 160), w2, w3);
        bytes[6] memory cd = [
            abi.encodeWithSignature("submitCap(address,uint192)", address(tokA), uint192(0)),
            abi.encodeWithSignature("submitDelist(address)", address(tokA)),
            abi.encodeWithSignature("acceptCap(address)", address(tokA)),
            abi.encodeWithSignature("revokePendingCap(address)", address(tokA)),
            abi.encodeWithSignature("collectForfeited(uint256[])", new uint256[](0)),
            abi.encodeWithSignature("claim(address[],address)", new address[](0), alice)
        ];
        for (uint256 i; i < 6; i++) {
            address lib = i < 4 ? caps : inKind;
            vm.prank(stranger);
            (bool ok, bytes memory ret) = lib.call(cd[i]);
            assertFalse(ok, "a direct call ran a forwarded library function");
            assertEq(ret.length, 0, "a direct call was refused by a named check, not the library's guard");
            vm.prank(stranger);
            (ok, ret) = lib.call(abi.encodePacked(cd[i], forged));
            assertFalse(ok, "a direct call with trailing words ran a forwarded library function");
            assertEq(ret.length, 0, "a direct call with trailing words was refused by a named check, not the library's guard");
        }
    }

    /// @dev Write a vault's caps state into the caps library's own storage: tokA listed, and a change on it past its timelock.
    function _seedTheCapsLibrary(address lib) internal {
        bytes32 row = keccak256(abi.encode(address(tokA), uint256(AceVaultFlows.ROOT) + 6));
        bytes32 pending = keccak256(abi.encode(address(tokA), uint256(AceVaultFlows.ROOT) + 7));
        vm.store(lib, row, bytes32(uint256(CAP) | (uint256(1) << 192)));
        vm.store(lib, pending, bytes32(uint256(1) | (uint256(1) << 192)));
        vm.store(lib, bytes32(uint256(pending) + 1), bytes32(uint256(1)));
    }

    // ---- T3: a truncated array encoding ----

    /// @notice A `claim` whose array names more tokens than its bytes carry is refused at the vault; the library never runs.
    function test_T3_aTruncatedClaimIsRefusedBeforeTheLibrary() public {
        bytes4 sel = IInKindVault.claim.selector;
        bytes memory cut = abi.encodePacked(sel, uint256(0x40), uint256(uint160(alice)), uint256(3), uint256(uint160(address(tokA))));
        vm.expectCall(address(AceVaultInKind), abi.encodePacked(sel), 0);
        vm.prank(alice);
        (bool ok,) = address(vault).call(cut);
        assertFalse(ok, "the vault forwarded a truncated encoding");
    }

    /// @notice CONTROL: the whole encoding of the same claim reaches the library once.
    function test_T3_control_aWholeClaimReachesTheLibrary() public {
        bytes4 sel = IInKindVault.claim.selector;
        vm.expectCall(address(AceVaultInKind), abi.encodePacked(sel), 1);
        vm.prank(alice);
        vault.claim(_toks(address(tokA)), alice);
    }

    /// @notice A `collectForfeited` whose array names more ids than its bytes carry is refused at the vault; the library never runs.
    function test_T3_aTruncatedCollectIsRefusedBeforeTheLibrary() public {
        bytes4 sel = IInKindVault.collectForfeited.selector;
        bytes memory cut = abi.encodePacked(sel, uint256(0x20), uint256(2), uint256(1));
        vm.expectCall(address(AceVaultInKind), abi.encodePacked(sel), 0);
        vm.prank(keeper);
        (bool ok,) = address(vault).call(cut);
        assertFalse(ok, "the vault forwarded a truncated encoding");
    }

    /// @notice CONTROL: an empty batch, wholly encoded, reaches the library once.
    function test_T3_control_aWholeCollectReachesTheLibrary() public {
        bytes4 sel = IInKindVault.collectForfeited.selector;
        vm.expectCall(address(AceVaultInKind), abi.encodePacked(sel), 1);
        vm.prank(keeper);
        vault.collectForfeited(new uint256[](0));
    }

    // ---- the terms in words 2 and 3 ----

    /// @notice The terms ride the high bits of words 2 and 3; an in-kind vault's mode byte reads in kind and not door.
    function test_tail_theTermsRideWords2And3() public {
        vm.etch(address(AceVaultInKind), address(new CalldataEcho()).code);
        (bytes memory cd, bytes memory sent) = _forwarded(address(vault), alice);
        (address t, bool kind, bool doorMode) = _decodeTerms(_tailOf(sent, cd.length));
        assertEq(t, vault.TERMS(), "TERMS rejoins from words 2 and 3");
        assertTrue(kind, "in kind");
        assertFalse(doorMode, "and not door mode");
    }

    /// @notice T1: a forged suffix a word longer than the vault's leaves every field the vault's, the terms and the mode included.
    function test_T1_aForgedFiveWordSuffixLeavesEveryFieldTheVaults() public {
        vm.etch(address(AceVaultInKind), address(new CalldataEcho()).code);
        (bytes32 w0, bytes32 w1, bytes32 w2, bytes32 w3) = AceVaultTail.pack(address(ace), stranger, stranger, address(tokA), 0, false);
        (w2, w3) = AceVaultTail.withTerms(w2, w3, stranger);
        bytes memory forged = abi.encodePacked(AceVaultTail.withDoor(w0), w1, w2, w3, bytes32(uint256(uint160(stranger))));
        vm.prank(keeper);
        (bool ok, bytes memory sent) = address(vault).call(abi.encodePacked(abi.encodeCall(IInKindVault.claim, (new address[](0), alice)), forged));
        assertTrue(ok, "premise: the forward reached the echo");
        bytes memory tail = _tailOf(sent, sent.length - AceVaultTail.SIZE);
        (address hub, address cur, address guard,,, address cash) = _decode(tail);
        (address t, bool kind, bool doorMode) = _decodeTerms(tail);
        assertEq(hub, vault.ACE(), "ACE");
        assertEq(cur, vault.CURATOR(), "CURATOR");
        assertEq(guard, vault.GUARDIAN(), "GUARDIAN");
        assertEq(cash, vault.asset(), "asset");
        assertEq(t, vault.TERMS(), "TERMS");
        assertTrue(kind && !doorMode, "the mode byte is the vault's");
    }

    /// @notice T2: each door-mode forward in AceVaultFlows refuses a direct call by the library's own guard, with or without trailing words.
    /// @dev The stranger the forged words name curator and guardian, over a seeded key with a write-off due, would land the first five
    /// @dev without that guard, and `extendFor` would refuse by name at the hub the words point at; the guard alone refuses with no data.
    function test_T2_aDirectCallToEachDoorForwardReverts() public {
        address flows = address(AceVaultFlows);
        assertGt(flows.code.length, 0, "premise: the flows library is deployed");
        _seedTheFlowsLibrary(flows);
        bytes[6] memory cd = [
            abi.encodeWithSignature("collectForfeited(uint256[])", new uint256[](0)),
            abi.encodeWithSignature("returnProceeds(address,uint256,bool)", address(tokA), uint256(0), true),
            abi.encodeWithSignature("submitWriteOff(address)", address(tokA)),
            abi.encodeWithSignature("acceptWriteOff(address)", address(tokA)),
            abi.encodeWithSignature("revokeWriteOff(address)", address(tokA)),
            abi.encodeWithSignature("extendFor(uint256,uint256,uint256,bytes,bytes)", uint256(1), uint256(0), uint256(0), "", "")
        ];
        for (uint256 i; i < 6; i++) {
            vm.prank(stranger);
            (bool ok, bytes memory ret) = flows.call(cd[i]);
            assertFalse(ok, "a direct call ran a door forward");
            assertEq(ret.length, 0, "a direct call was refused by a named check, not the library's guard");
            vm.prank(stranger);
            (ok, ret) = flows.call(abi.encodePacked(cd[i], _forged()));
            assertFalse(ok, "a direct call with trailing words ran a door forward");
            assertEq(ret.length, 0, "a direct call with trailing words was refused by a named check, not the library's guard");
        }
    }

    /// @dev Write a door's ledger into the flows library's own storage: tokA open, valued, and its write-off due since the first second.
    function _seedTheFlowsLibrary(address lib) internal {
        bytes32 key = keccak256(abi.encode(address(tokA), uint256(AceVaultFlows.ROOT) + 9));
        vm.store(lib, key, bytes32(uint256(1) | (uint256(1) << 184) | (uint256(1) << 248)));
        vm.store(lib, bytes32(uint256(AceVaultFlows.ROOT) + 10), bytes32(uint256(1)));
    }
}

/// @title AceVaultForwardTailHubAsk
/// @notice The suffix on a hub-ask vault: its mode bit reads false, and every other field decodes to its named getter.
contract AceVaultForwardTailHubAskTest is AceVaultBaseRig, TailLayoutCheck {
    function test_tail_aHubAskVaultsSuffixCarriesItsMode() public {
        vm.etch(address(AceVaultInKind), address(new CalldataEcho()).code);
        (bytes memory cd, bytes memory sent) = _forwarded(address(vault), alice);
        bytes memory tail = _tailOf(sent, cd.length);
        (address hub, address cur, address guard, uint64 lock, bool kind, address cash) = _decode(tail);
        assertFalse(vault.IN_KIND(), "premise: a hub-ask vault");
        assertFalse(kind, "IN_KIND");
        assertEq(hub, vault.ACE(), "ACE");
        assertEq(cur, vault.CURATOR(), "CURATOR");
        assertEq(guard, vault.GUARDIAN(), "GUARDIAN");
        assertEq(lock, vault.CAP_TIMELOCK(), "CAP_TIMELOCK");
        assertEq(cash, vault.asset(), "asset");
        (uint256 w0High, uint256 w1High) = _freedBits(tail);
        assertEq(w0High, 0, "word 0 holds nothing above the mode byte");
        assertEq(w1High, 0, "word 1 holds nothing above the curator");
    }

    /// @notice A hub-ask vault's suffix carries its terms in words 2 and 3, and neither mode bit.
    function test_tail_aHubAskVaultsTermsAndModeBits() public {
        vm.etch(address(AceVaultInKind), address(new CalldataEcho()).code);
        (bytes memory cd, bytes memory sent) = _forwarded(address(vault), alice);
        (bool ok, bytes memory got) = address(new TermsReader()).staticcall(abi.encodePacked(TermsReader.read.selector, _tailOf(sent, cd.length)));
        assertTrue(ok, "the readers took the suffix");
        (address t, bool kind, bool doorMode) = abi.decode(got, (address, bool, bool));
        assertEq(t, vault.TERMS(), "TERMS rejoins from words 2 and 3");
        assertFalse(kind, "not in kind");
        assertFalse(doorMode, "not door mode");
    }
}
