// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.36;

import {ERC721} from "@openzeppelin/contracts/token/ERC721/ERC721.sol";
import {ERC721Enumerable} from "@openzeppelin/contracts/token/ERC721/extensions/ERC721Enumerable.sol";

/// @notice The one hub call this collection makes: title moves on the hub the instant it moves here.
interface IRetitle {
    function retitle(uint256 loanId, address from, address to) external;
}

/// @title PositionTitleNFT
/// @notice ONE ERC-721 over every borrower position the hub opens: tokenId == loanId, ids global.
/// @notice The NFT is the TRANSFER INTERFACE over title; `Ace.Loan.borrower` is the storage of record.
/// @dev Every hub authorization predicate reads `Loan.borrower`, never this contract.
/// @dev `_update` pushes each real transfer into `Ace.retitle`: both ledgers move in one tx or neither.
/// @dev No burn exists, ever -- it would desync `Loan.borrower` from the token; a closed loan's credits key to its holder at the close, not to the title.
/// @dev `totalSupply()` is NOT a live-loan count: nothing burns, and it spans EVERY market's loans.
/// @dev Use `Ace.marketLoans` for one market's loans, `Ace.isClosed` for liveness.
contract PositionTitleNFT is ERC721Enumerable {
    error NotHubTitle(); // only the hub mints title; its own selector, never confusable with a hub-side guard

    address public immutable HUB; // the Ace singleton; sole minter, and the storage of record this collection mirrors

    constructor(address hub) ERC721("ACE Position", "ACE-POS") {
        HUB = hub;
    }

    /// @notice Mints loan `loanId`'s position to its borrower. Hub-only, called once per loan at open.
    /// @dev Plain `_mint`, NEVER `_safeMint`: its hook would revert `open` for a contract borrower, a live DoS on delegated credit.
    /// @dev Unguarded: hub-only, and plain `_mint` runs no receiver hook; a fresh id never reaches `retitle`, a reused one trips the hub's guard.
    /// @dev The inherited transfer surface needs no guard either: `_update` routes every real move into `retitle`.
    function mint(uint256 loanId, address to) external {
        if (msg.sender != HUB) revert NotHubTitle();
        _mint(to, loanId);
    }

    /// @dev `super._update` runs FIRST and its RETURNED `from` is used: `_checkAuthorized` is inside it.
    /// @dev Composing the hub write before it would retitle on an unauthorized call.
    /// @dev `ERC721Enumerable._update` returns `previousOwner` verbatim, so the gate below is unchanged.
    /// @dev Mint (`from == 0`) skips the hub call: the hub wrote `Loan.borrower` in the same tx.
    /// @dev There is no burn path, so the `to == 0` leg is unreachable.
    /// @dev `retitle` is nonReentrant: a transfer nested inside a hub call reverts, which is intended.
    function _update(address to, uint256 tokenId, address auth) internal override returns (address from) {
        from = super._update(to, tokenId, auth);
        if (from != address(0) && to != address(0)) IRetitle(HUB).retitle(tokenId, from, to);
    }

    /// @notice No metadata endpoint; deliberately empty rather than a broken URI.
    function tokenURI(uint256) public pure override returns (string memory) {
        return "";
    }
}
