// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.36;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {Extension, IRollPolicy} from "../../src/interfaces/IRollPolicy.sol";

/// @notice The guarded hub views and the unguarded ones a policy mock reads, by signature.
interface IPolicyReadsHub {
    function lenderAssets(address lender, address quote) external view returns (uint256);
    function isLiveLoan(uint256 id) external view returns (bool);
}

/// @dev THE ONE YES: `admitsExtension.selector`, the magic value every consenting policy returns.
bytes4 constant POLICY_YES = IRollPolicy.admitsExtension.selector;

/// @notice Always consents.
contract YesPolicy is IRollPolicy {
    function admitsExtension(Extension calldata, bytes calldata) external pure returns (bytes4) {
        return POLICY_YES;
    }
}

/// @notice Always refuses with a clean zero answer.
contract NoPolicy is IRollPolicy {
    function admitsExtension(Extension calldata, bytes calldata) external pure returns (bytes4) {
        return bytes4(0);
    }
}

/// @notice Reverts on every ask.
contract RevertingPolicy is IRollPolicy {
    function admitsExtension(Extension calldata, bytes calldata) external pure returns (bytes4) {
        revert("policy says no by reverting");
    }
}

/// @notice Succeeds and returns no bytes at all.
contract EmptyReturnPolicy {
    function admitsExtension(Extension calldata, bytes calldata) external pure returns (bytes4) {
        assembly ("memory-safe") {
            return(0, 0)
        }
    }
}

/// @notice Returns TWO words, each holding the selector: a hub reading only the first word would take it for a yes.
contract TwoWordPolicy {
    function admitsExtension(Extension calldata, bytes calldata) external pure returns (bytes4) {
        bytes4 yes = POLICY_YES;
        assembly ("memory-safe") {
            mstore(0, yes)
            mstore(0x20, yes)
            return(0, 0x40)
        }
    }
}

/// @notice Returns one well-formed word that is not the selector.
contract WrongWordPolicy is IRollPolicy {
    function admitsExtension(Extension calldata, bytes calldata) external pure returns (bytes4) {
        return bytes4(0xdeadbeef);
    }
}

/// @notice Returns `uint256(1)`, the old bool `true`: the answer a fallback or a bool-shaped policy gives by accident.
contract BoolOnePolicy {
    function admitsExtension(Extension calldata, bytes calldata) external pure returns (bytes4) {
        assembly ("memory-safe") {
            mstore(0, 1)
            return(0, 0x20)
        }
    }
}

/// @notice Returns a large buffer whose first word IS the selector: only a size check refuses it, and only a bounded copy survives it.
contract ReturnBombPolicy {
    uint256 internal constant BOMB = 60_000; // bytes returned; memory expansion inside the cap, a copy of it outside

    function admitsExtension(Extension calldata, bytes calldata) external pure returns (bytes4) {
        bytes4 yes = POLICY_YES;
        assembly ("memory-safe") {
            mstore(0, yes)
            return(0, BOMB)
        }
    }
}

/// @notice Burns every unit of gas it is handed, so its call fails out of gas inside the cap.
contract GasBurnerPolicy {
    function admitsExtension(Extension calldata, bytes calldata) external pure returns (bytes4) {
        assembly ("memory-safe") {
            for {} 1 {} {}
        }
        return POLICY_YES;
    }
}

/// @notice Answers EVERY call by echoing its first calldata word: the selector, then the first 28 bytes of word 0.
/// @dev With `Extension` static and `caller` at word 0, that echo is the selector only for a caller whose top 16 bytes are zero.
/// @dev A dynamic member would put an offset at word 0, and the echo would then read as the selector for any caller.
contract EchoFallbackPolicy {
    fallback() external {
        assembly ("memory-safe") {
            mstore(0, calldataload(0))
            return(0, 0x20)
        }
    }
}

/// @notice Consents only to the exact extension and payload it was told to expect, field for field.
/// @dev The hub asks with a STATICCALL, so a policy cannot write what it saw; matching is how it records.
contract MatchingPolicy is IRollPolicy {
    bytes32 public expected; // keccak of the abi-encoded (extension, payload) pair the next ask must carry

    function expect(Extension calldata e, bytes calldata data) external {
        expected = keccak256(abi.encode(e, data));
    }

    function admitsExtension(Extension calldata e, bytes calldata data) external view returns (bytes4) {
        return keccak256(abi.encode(e, data)) == expected ? POLICY_YES : bytes4(0);
    }
}

/// @notice Consents only if a GUARDED hub view answers: a no inside any hub verb, a yes from an unlocked preview.
contract GuardedViewPolicy is IRollPolicy {
    IPolicyReadsHub internal immutable HUB;
    address internal immutable LENDER;
    address internal immutable QUOTE;

    constructor(address hub, address lender, address quote) {
        (HUB, LENDER, QUOTE) = (IPolicyReadsHub(hub), lender, quote);
    }

    function admitsExtension(Extension calldata, bytes calldata) external view returns (bytes4) {
        HUB.lenderAssets(LENDER, QUOTE); // reverts while the hub's lock is held
        return POLICY_YES;
    }
}

/// @notice Consents only if it was handed at least `THRESHOLD` gas: the cap less its own entry cost.
contract GasFloorPolicy is IRollPolicy {
    uint256 public immutable THRESHOLD; // the least `gasleft()` at entry that reads as having received the whole cap

    constructor(uint256 threshold) {
        THRESHOLD = threshold;
    }

    function admitsExtension(Extension calldata, bytes calldata) external view returns (bytes4) {
        return gasleft() >= THRESHOLD ? POLICY_YES : bytes4(0);
    }
}

/// @notice Consents only while the loan it is asked about is still live: a hub that closed it first gets a no.
contract LiveLoanPolicy is IRollPolicy {
    IPolicyReadsHub internal immutable HUB;

    constructor(address hub) {
        HUB = IPolicyReadsHub(hub);
    }

    function admitsExtension(Extension calldata e, bytes calldata) external view returns (bytes4) {
        return HUB.isLiveLoan(e.loanId) ? POLICY_YES : bytes4(0);
    }
}

/// @notice Consents only while two quote balances still read what it was told: a hub that pulled the fee first gets a no.
contract BalancePolicy is IRollPolicy {
    IERC20 public token;
    address public payer;
    uint256 public payerBalance;
    address public hub;
    uint256 public hubBalance;

    function expect(IERC20 t, address p, address h) external {
        (token, payer, hub) = (t, p, h);
        (payerBalance, hubBalance) = (t.balanceOf(p), t.balanceOf(h));
    }

    function admitsExtension(Extension calldata, bytes calldata) external view returns (bytes4) {
        bool same = token.balanceOf(payer) == payerBalance && token.balanceOf(hub) == hubBalance;
        return same ? POLICY_YES : bytes4(0);
    }
}

/// @notice Forwards the question carried in the caller's payload to another policy and returns its answer: how a test asks a vault under the hub's lock.
/// @dev The hub's lock is held for the whole ask, so the forwarded answer is the one the vault gives inside a hub verb.
/// @dev Stateless, the payload being `abi.encode(target, question)`, so the ask costs no storage reads against the cap.
contract ForwardingPolicy is IRollPolicy {
    function admitsExtension(Extension calldata, bytes calldata data) external view returns (bytes4) {
        (IRollPolicy target, Extension memory question) = abi.decode(data, (IRollPolicy, Extension));
        return target.admitsExtension(question, "");
    }
}
