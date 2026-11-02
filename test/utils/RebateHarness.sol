// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.36;

import {Vm} from "forge-std/Vm.sol";
import {Storage, OpenBounds, MigrateArgs} from "../../src/ace/hub/Types.sol";

/// @notice The `refinanceTo` verb, declared test-side; `Ace` ships it but no test-visible interface does.
/// @dev Cast onto `address(ace)`; the signature below is the one `Ace.refinanceTo` ships with.
/// @dev THE SIGNATURE IS THE CONTRACT: a shipped mismatch shows up as every refinance test reverting.
/// @dev `MigrateArgs` is RE-EXPORTED from the hub's own `Types.sol`, never redeclared here.
/// @dev A test-side copy of an ABI tuple drifts silently on any field append; one definition cannot.
interface IAceRefinance {
    /// @notice C41: close a loan and open its successor, in its own market or one sharing the source's collateral AND quote.
    function refinanceTo(MigrateArgs calldata m) external returns (uint256 newId);
}

Vm constant REFI_VM = Vm(address(uint160(uint256(keccak256("hevm cheat code"))))); // forge-std's cheatcode address: a free function cannot see `vm`

/// @notice A re-term in the loan's OWN market: `refinanceTo` naming the market the loan's record holds, the old `refinance` arity.
/// @notice The market is read with `vm.load`, a cheatcode, so a pending prank or `expectRevert` still lands on the verb.
/// @param hub The hub.
/// @param id The loan.
/// @param newPrincipal The successor's principal.
/// @param newTenor The successor's term, or zero for the market's `minTenor`.
/// @param bnd The open bounds.
/// @return The successor's id.
function refinanceHome(address hub, uint256 id, uint256 newPrincipal, uint64 newTenor, OpenBounds memory bnd) returns (uint256) {
    return IAceRefinance(hub).refinanceTo(homeArgs(hub, id, newPrincipal, newTenor, bnd));
}

/// @notice The `MigrateArgs` of a re-term in the loan's own market, for a site that encodes the call itself.
function homeArgs(address hub, uint256 id, uint256 newPrincipal, uint64 newTenor, OpenBounds memory bnd) view returns (MigrateArgs memory) {
    bytes32 mid = REFI_VM.load(hub, keccak256(abi.encode(id, uint256(Storage.BOOK) + 1))); // `LoanBook.loans`, member 1; `market` is word 0
    return MigrateArgs(id, mid, newPrincipal, newTenor, bnd, 0, address(0));
}

/// @notice The rebate views the plan puts on `AceLens`, declared test-side for the same reason.
interface IAceLensRebate {
    function feeEscrowOf(uint256 loanId) external view returns (uint256);
    function earlyExitRefund(uint256 loanId) external view returns (uint256);
}

/// @notice The hub's raw storage door; `AceReader` reads through the same one.
interface IExtsload {
    function extsload(bytes32 slot) external view returns (bytes32);
}

/// @title RebateReader
/// @notice Reads `LoanBook.feeEscrowOf` out of hub storage, so no lens deploy and no new hub view.
/// @dev SLOT ASSUMPTION: count/loans/principal/creditOperator/nonce puts `feeEscrowOf` at 5.
/// @dev Every member after it may change without moving it, so this holds across appends and deletions behind it.
/// @dev It reads the raw slot, so the value is the hub's own and never a test-side re-derivation.
/// @dev A different shipped member order needs THIS constant fixed and nothing else.
contract RebateReader {
    IExtsload public immutable ACE;

    uint256 private constant B_BASE = uint256(Storage.BOOK);
    uint256 private constant B_FEE_ESCROW = B_BASE + 5;

    constructor(address ace) {
        ACE = IExtsload(ace);
    }

    /// @notice The withheld early-exit escrow still held against `loanId`.
    function feeEscrowOf(uint256 loanId) external view returns (uint256) {
        return uint256(ACE.extsload(bytes32(uint256(keccak256(abi.encode(loanId, B_FEE_ESCROW))))));
    }
}

/// @title RebateMath
/// @notice The rebate spec as integer arithmetic, written from the decision record, not the source.
/// @dev The headline cases assert LITERAL bps figures instead of calling these, deliberately.
/// @dev A shared helper is a single point a mutation could move; these serve the fuzz cases only.
library RebateMath {
    /// @notice The shipped rebate share of the lender cut; the binding constraint is phi < 1.
    uint256 internal constant REBATE_PHI_BPS = 5000;

    /// @notice The borrower's ALL-IN one-shot fee, rounded UP: the payer never rounds in their own favour.
    /// @dev `baseBps` prices the LENDER; the protocol's share rides on top, under a single ceil.
    function fee(uint256 principal, uint64 tenor, uint256 baseBps, uint64 minTenor, uint256 protocolShareBps) internal pure returns (uint256) {
        uint256 num = principal * baseBps * uint256(tenor) * (10000 + protocolShareBps);
        uint256 den = 10000 * 10000 * uint256(minTenor);
        return (num + den - 1) / den;
    }

    /// @notice ACE's cut, recovered from the ALL-IN fee by the INVERSE ratio; never rebated (C14).
    /// @dev Floors, so the residue lands on the lender and the protocol can never out-take its share.
    function protocolCut(uint256 f, uint256 protocolShareBps) internal pure returns (uint256) {
        return (f * protocolShareBps) / (10000 + protocolShareBps);
    }

    /// @notice What `open` withholds from the tick credit: phi of the LENDER share, never of the fee.
    function escrow(uint256 f, uint256 protocolShareBps) internal pure returns (uint256) {
        return ((f - protocolCut(f, protocolShareBps)) * REBATE_PHI_BPS) / 10000;
    }

    /// @notice What a clean close at `remaining` seconds to expiry returns; rounds DOWN, market-favoured.
    function refund(uint256 esc, uint256 remaining, uint64 tenor) internal pure returns (uint256) {
        if (remaining > tenor) remaining = tenor;
        return (esc * remaining) / uint256(tenor);
    }
}
