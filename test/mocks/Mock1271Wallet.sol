// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.36;

bytes4 constant MAGIC_VALUE = 0x1626ba7e; // ERC-1271, spelled here so a mock cannot inherit the hub's own answer

/// @notice A smart-contract wallet that answers for exactly one digest, the way a real one signs one message.
contract Signing1271Wallet {
    mapping(bytes32 => bool) public signed;

    function sign(bytes32 digest) external {
        signed[digest] = true;
    }

    function isValidSignature(bytes32 digest, bytes calldata) external view returns (bytes4) {
        return signed[digest] ? MAGIC_VALUE : bytes4(0xffffffff);
    }
}

/// @notice Answers the magic value for ANYTHING: the 7702 shape the standing rejection names as item 3.
contract Permissive1271Wallet {
    function isValidSignature(bytes32, bytes calldata) external pure returns (bytes4) {
        return MAGIC_VALUE;
    }
}

/// @notice Reverts rather than answering: the callee that must not roll back the nonce the door already spent.
contract Reverting1271Wallet {
    error WalletSaysNo();

    function isValidSignature(bytes32, bytes calldata) external pure returns (bytes4) {
        revert WalletSaysNo();
    }
}

/// @notice Returns a well-formed but WRONG selector: a wallet that answers must answer the magic value.
contract WrongAnswer1271Wallet {
    function isValidSignature(bytes32, bytes calldata) external pure returns (bytes4) {
        return 0xdeadbeef;
    }
}

/// @notice Reads its own nonce while being asked, and answers only if the door already spent it.
/// @notice Turns the CEI ordering into the thing the call's success depends on, which a revert cannot observe.
contract NonceObserving1271Wallet {
    INonceReader public immutable READER;
    uint256 public immutable EXPECT;

    constructor(INonceReader reader, uint256 expect) {
        READER = reader;
        EXPECT = expect;
    }

    function isValidSignature(bytes32, bytes calldata) external view returns (bytes4) {
        return READER.creditOperatorNonce(address(this)) == EXPECT ? MAGIC_VALUE : bytes4(0xffffffff);
    }
}

interface INonceReader {
    function creditOperatorNonce(address borrower) external view returns (uint256);
}

/// @notice Returns fewer than 32 bytes, so a verifier that skips the length check reads adjacent memory.
contract ShortReturn1271Wallet {
    fallback(bytes calldata) external returns (bytes memory) {
        return hex"1626";
    }
}

/// @notice Returns the magic value in FOUR bytes: correct in content, short in the ABI's frame.
/// @notice The truncated answer a verifier reading one word without a length check would ADMIT.
contract ShortMagic1271Wallet {
    fallback(bytes calldata) external returns (bytes memory) {
        return hex"1626ba7e";
    }
}

/// @notice Tries to write hub state while being asked, then answers the magic value.
/// @notice The ask is a STATICCALL, so the write reverts and the wallet never gets to answer at all.
contract Reentering1271Wallet {
    IGrantDoor public immutable DOOR;

    constructor(IGrantDoor door) {
        DOOR = door;
    }

    function isValidSignature(bytes32, bytes calldata) external returns (bytes4) {
        DOOR.setCreditOperator(msg.sender, true);
        return MAGIC_VALUE;
    }
}

interface IGrantDoor {
    function setCreditOperator(address operator, bool allowed) external;
}
