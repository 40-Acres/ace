// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.36;

/// @title IPositionManager
/// @notice The one collateral custodian: it records CUSTODY only, title is the hub's.
/// @dev That is why `pull` names a payer and no owner: there is no title argument to disagree with.
/// @dev A refinance carry is two ledger writes and no transfer, which is why it takes two verbs and no payer.
interface IPositionManager {
    function pull(uint256 loanId, address from, uint256 units) external;
    function release(uint256 loanId, address to, uint256 units) external;
    function retireCustody(uint256 loanId, uint256 units) external;
    function releaseRetired(uint256 loanId, address to, uint256 units) external;
    function carryOut(uint256 fromLoanId, uint256 units) external;
    function carryIn(uint256 fromLoanId, uint256 toLoanId, uint256 units) external;
    function collateralOf(uint256 loanId) external view returns (uint256);
    function custodiedOf(address collateral) external view returns (uint256);
    function LOAN_MANAGER() external view returns (address);
}
