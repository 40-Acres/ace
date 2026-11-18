// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.36;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {IInKindVault} from "./InKindSurface.sol";

bytes4 constant ERC1271_MAGIC = 0x1626ba7e; // spelled here so no mock inherits a verifier's own answer

/// @notice A Safe-shaped proxy: slot 0 holds the singleton, and every call delegates to it.
contract SafeLikeProxy {
    address internal singleton; // slot 0, as a Safe proxy's

    constructor(address s) {
        singleton = s;
    }

    fallback() external payable {
        assembly ("memory-safe") {
            let s := sload(0)
            calldatacopy(0, 0, calldatasize())
            let ok := delegatecall(gas(), s, 0, calldatasize(), 0, 0)
            returndatacopy(0, 0, returndatasize())
            if iszero(ok) { revert(0, returndatasize()) }
            return(0, returndatasize())
        }
    }
}

/// @notice A Safe-shaped singleton: owners, a threshold, a message hash and a fallback that CALLs a handler with the sender appended.
/// @dev It walks the same hops a Safe's ERC-1271 answer walks: proxy, singleton fallback, handler, then a call back into the Safe.
contract SafeLikeSingleton {
    bytes32 internal constant SAFE_MSG_TYPEHASH = keccak256("SafeMessage(bytes message)");
    bytes32 internal constant DOMAIN_TYPEHASH = keccak256("EIP712Domain(uint256 chainId,address verifyingContract)");

    address internal singleton; // slot 0, shared with the proxy
    address internal handler;
    mapping(address => bool) internal isOwner;
    uint256 internal threshold;

    /// @notice Wire the handler, the owners and the threshold, once, through the proxy.
    function setup(address h, address[] calldata owners, uint256 t) external {
        require(handler == address(0), "set");
        handler = h;
        for (uint256 i; i < owners.length; i++) {
            isOwner[owners[i]] = true;
        }
        threshold = t;
    }

    /// @notice The hash owners sign for a message, under this Safe's own domain.
    function getMessageHash(bytes memory message) public view returns (bytes32) {
        bytes32 domain = keccak256(abi.encode(DOMAIN_TYPEHASH, block.chainid, address(this)));
        bytes32 m = keccak256(abi.encode(SAFE_MSG_TYPEHASH, keccak256(message)));
        return keccak256(abi.encodePacked(bytes1(0x19), bytes1(0x01), domain, m));
    }

    /// @notice Threshold ECDSA over `h`, owners strictly ascending, as a Safe's `checkSignatures` requires.
    function checkSignatures(bytes32 h, bytes memory sigs) public view {
        uint256 t = threshold;
        require(sigs.length >= t * 65, "short");
        address last;
        for (uint256 i; i < t; i++) {
            bytes32 r;
            bytes32 s;
            uint8 v;
            assembly ("memory-safe") {
                let p := add(add(sigs, 0x20), mul(i, 65))
                r := mload(p)
                s := mload(add(p, 0x20))
                v := byte(0, mload(add(p, 0x40)))
            }
            address o = ecrecover(h, v, r, s);
            require(o > last && isOwner[o], "owner");
            last = o;
        }
    }

    fallback() external {
        address h = handler;
        assembly ("memory-safe") {
            calldatacopy(0, 0, calldatasize())
            mstore(calldatasize(), shl(96, caller()))
            let ok := call(gas(), h, 0, 0, add(calldatasize(), 20), 0, 0)
            returndatacopy(0, 0, returndatasize())
            if iszero(ok) { revert(0, returndatasize()) }
            return(0, returndatasize())
        }
    }
}

/// @notice The Safe's compatibility handler: it hashes the digest as a Safe message and asks the Safe to check the owners.
contract SafeLikeHandler {
    function isValidSignature(bytes32 digest, bytes calldata sigs) external view returns (bytes4) {
        SafeLikeSingleton safe = SafeLikeSingleton(payable(msg.sender));
        safe.checkSignatures(safe.getMessageHash(abi.encode(digest)), sigs);
        return ERC1271_MAGIC;
    }
}

/// @notice An ERC-1271 wallet that burns every unit of gas it is handed, so a check that reaches it first cannot finish cheaply.
contract GasBurner1271 {
    function isValidSignature(bytes32, bytes calldata) external pure returns (bytes4) {
        assembly ("memory-safe") {
            for {} 1 {} {}
        }
        return ERC1271_MAGIC;
    }
}

/// @notice The callback a share flash loan makes into its borrower.
interface IShareFlashBorrower {
    function onShareFlash(uint256 amount) external;
}

/// @notice A venue holding vault shares that lends any of them for the length of one call, as a flash-loan venue lends whatever it holds.
contract ShareFlashLender {
    IERC20 public immutable SHARE;

    constructor(IERC20 share) {
        SHARE = share;
    }

    /// @notice Lend `amount` shares to `to` for the callback; it must hand them all back before this returns.
    function flash(uint256 amount, IShareFlashBorrower to) external {
        uint256 before = SHARE.balanceOf(address(this));
        require(SHARE.transfer(address(to), amount), "flash: send");
        to.onShareFlash(amount);
        require(SHARE.balanceOf(address(this)) >= before, "flash: not repaid");
    }
}

/// @notice The attacker: borrows a venue's shares, collects a seized pot while holding them, claims, and repays in one call.
contract FlashCollector is IShareFlashBorrower {
    IInKindVault internal immutable VAULT;
    ShareFlashLender internal immutable LENDER;
    uint256[] internal _ids;
    address[] internal _toks;
    uint256 public paidInFlash; // what the in-flash claim paid of the first token

    constructor(IInKindVault v, ShareFlashLender l) {
        (VAULT, LENDER) = (v, l);
    }

    /// @notice Run the whole attack in one transaction.
    function attack(uint256[] calldata ids, address[] calldata toks, uint256 amount) external {
        _ids = ids;
        _toks = toks;
        LENDER.flash(amount, this);
    }

    function onShareFlash(uint256 amount) external {
        require(msg.sender == address(LENDER), "lender only");
        VAULT.collectForfeited(_ids);
        uint256[] memory paid = VAULT.claim(_toks, address(this));
        paidInFlash = paid.length == 0 ? 0 : paid[0];
        require(VAULT.transfer(address(LENDER), amount), "repay");
    }
}
