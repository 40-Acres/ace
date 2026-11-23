// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.36;

import {MarketParams} from "../../../src/ace/hub/Types.sol";
import {Extension} from "../../../src/interfaces/IRollPolicy.sol";
import {IVaultTerms, Lend, RefinanceRequest} from "../../../src/interfaces/IVaultTerms.sol";
import {BorrowRequest, Terms} from "../../../src/vault/libraries/AceVaultFlows.sol";

/// @notice The hostile shapes `MockTerms` has no mode for: a revert carrying a whole word, an empty success, write calls that revert, and a bad `VAULT()`.
/// @dev Its borrow answer is honest and a row sets it, so a door can reach the leg under test; `word` is what every hostile view answers or reverts with.
contract HostileTerms is IVaultTerms {
    enum View {
        Answer,
        RevertWord,
        Empty
    }

    enum Bind {
        Honest,
        Wrong,
        Reverts,
        Empty
    }

    address internal immutable _vault;
    Bind internal immutable _bind;

    MarketParams internal _mp;
    Terms internal _t;
    View public mode;
    uint256 public word;
    bool public revertBefore;
    bool public revertAfter;

    error WriteRefused();

    constructor(address vault, Bind bind) {
        (_vault, _bind) = (vault, bind);
    }

    function setTerms(MarketParams calldata mp, Terms calldata t) external {
        (_mp, _t) = (mp, t);
    }

    function setView(View m, uint256 w) external {
        (mode, word) = (m, w);
    }

    function setWrites(bool before_, bool after_) external {
        (revertBefore, revertAfter) = (before_, after_);
    }

    function VAULT() external view returns (address) {
        if (_bind == Bind.Wrong) return address(uint160(_vault) ^ 1);
        if (_bind == Bind.Reverts) revert WriteRefused();
        if (_bind == Bind.Empty) {
            assembly ("memory-safe") {
                return(0, 0)
            }
        }
        return _vault;
    }

    function borrowTerms(address, BorrowRequest calldata, bytes calldata) external view returns (MarketParams memory, Terms memory) {
        return (_mp, _t);
    }

    function refinanceTerms(address, uint256, RefinanceRequest calldata, bytes calldata) external view returns (MarketParams memory, Terms memory) {
        return (_mp, _t);
    }

    function admitsExtension(Extension calldata, bytes calldata) external view returns (bool) {
        return _view() == 1;
    }

    function room(MarketParams calldata) external view returns (uint256) {
        return _view();
    }

    function entryCap(address, uint256) external view returns (uint256) {
        return _view();
    }

    function beforeLend(Lend, MarketParams calldata, uint256, bytes calldata) external view {
        if (revertBefore) revert WriteRefused();
    }

    function afterLend(Lend, MarketParams calldata, uint256, address, bytes calldata) external view {
        if (revertAfter) revert WriteRefused();
    }

    /// @dev The row's word, or the same word as a 32-byte revert payload, or a success returning nothing; the last two leave by assembly.
    function _view() private view returns (uint256) {
        uint256 w = word;
        if (mode == View.RevertWord) {
            assembly ("memory-safe") {
                mstore(0, w)
                revert(0, 32)
            }
        }
        if (mode == View.Empty) {
            assembly ("memory-safe") {
                return(0, 0)
            }
        }
        return w;
    }
}

/// @notice Runtime code that burns every unit of gas it is handed, whatever is called: etched over a product to prove a path never calls it.
contract GasBurner {
    fallback() external {
        assembly ("memory-safe") {
            invalid()
        }
    }
}
