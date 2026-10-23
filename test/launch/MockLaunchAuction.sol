// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.36;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {Bid, Checkpoint, Tick} from "../../src/interfaces/ILaunchAuction.sol";

/// @notice A settable stand-in for the auction's persistent state, for the UNIT rows, where no real auction runs.
/// @dev The fork suite runs the ops budget against the deployed auction; this exists so the arithmetic has rows of its own.
/// @dev Its sweep acts as the deployed one does: only the tokens recipient, once, sending the unsold amount it was set up with.
contract MockLaunchAuction {
    address public token;
    address public currency;
    address public validationHook;
    address public tokensRecipient;
    address public fundsRecipient;
    uint128 public totalSupply;
    uint64 public endBlock;
    uint64 public claimBlock;
    uint64 public lastCheckpointedBlock;
    bool public isGraduated;
    uint256 public currencyRaisedQ96X7;
    uint256 public clearingPrice;
    uint256 public unsold; // what a sweep sends, from this mock's own balance
    bool public swept;

    mapping(uint256 => Bid) internal _bids;
    mapping(uint64 => Checkpoint) internal _checkpoints;
    mapping(uint256 => Tick) internal _ticks;

    function set(address t, address c, address hook, uint64 end) external {
        (token, currency, validationHook, endBlock, claimBlock) = (t, c, hook, end, end);
    }

    function setUnsold(address recipient, uint256 amount) external {
        (tokensRecipient, unsold) = (recipient, amount);
    }

    function sweepUnsoldTokens() external {
        require(msg.sender == tokensRecipient, "mock: not the tokens recipient");
        require(!swept, "mock: swept already");
        swept = true;
        if (unsold != 0) IERC20(token).transfer(tokensRecipient, unsold);
    }

    function setState(uint64 last, bool graduated, uint256 raisedQ96X7) external {
        (lastCheckpointedBlock, isGraduated, currencyRaisedQ96X7) = (last, graduated, raisedQ96X7);
    }

    function setBid(uint256 id, Bid calldata b) external {
        _bids[id] = b;
    }

    function setCheckpoint(uint64 blockNumber, Checkpoint calldata c) external {
        _checkpoints[blockNumber] = c;
    }

    function setTick(uint256 price, uint256 demandQ96) external {
        _ticks[price].currencyDemandQ96 = demandQ96;
    }

    function bids(uint256 id) external view returns (Bid memory) {
        return _bids[id];
    }

    function checkpoints(uint64 blockNumber) external view returns (Checkpoint memory) {
        return _checkpoints[blockNumber];
    }

    function ticks(uint256 price) external view returns (Tick memory) {
        return _ticks[price];
    }
}
