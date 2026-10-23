// PositionTitleNFT, alone: the title collection never moves a position without telling the hub.
//
// THE NFT IS THE TRANSFER INTERFACE over title; `Ace.Loan.borrower` is the storage of record. The hub's own specs
// summarize the collection's `mint` as moving nothing of the hub's; what makes the pair one ledger is proven here:
//   - ONLY THE HUB MINTS: no other caller grows the supply.
//   - NOTHING BURNS: the supply never falls (a burn would desync `Loan.borrower` and strand a closed loan's claims).
//   - EVERY MOVE IS A RETITLE: each change of a token's owner between two real holders calls `retitle` exactly once,
//     with that token's old and new holder; a mint calls it never.
// The hub's `retitle` is summarized as a recorder: its own refusals (its guard, its sender check) are the hub specs'.
//
// THE REACHABLE-STATE FACTS are stated over REAL reads (`isApprovedForAll`, and the harness's two OZ views), never
// over load hooks: under via-IR the collection's storage analysis fails in the constructor, and a mirror ghost was
// observed disagreeing with the slot it mirrored. Their constructor base case is the prover's UNKNOWN for the same
// reason; it holds by inspection, since the constructor writes only the name, the symbol and an immutable.

methods {
    function _.retitle(uint256 id, address from, address to) external => recordRetitle(id, from, to) expect void;

    function HUB() external returns (address) envfree;
    function totalSupply() external returns (uint256) envfree;
    function isApprovedForAll(address, address) external returns (bool) envfree;
    function ownerOrZero(uint256) external returns (address) envfree;
    function approvalOf(uint256) external returns (address) envfree;
}

persistent ghost mapping(uint256 => mathint) retitles;
persistent ghost mapping(uint256 => address) retitledFrom;
persistent ghost mapping(uint256 => address) retitledTo;

function recordRetitle(uint256 id, address from, address to) {
    retitles[id] = retitles[id] + 1;
    retitledFrom[id] = from;
    retitledTo[id] = to;
}

persistent ghost mapping(uint256 => mathint) moves;
persistent ghost mapping(uint256 => address) movedFrom;
persistent ghost mapping(uint256 => address) movedTo;

// a move is an owner write between two real holders; a mint writes over zero
hook Sstore _owners[KEY uint256 id] address newV (address oldV) {
    if (oldV != 0 && newV != 0) {
        moves[id] = moves[id] + 1;
        movedFrom[id] = oldV;
        movedTo[id] = newV;
    }
}

// ---- two reachable-state facts of OZ's ERC721, proven so the rules below may lean on them ----
// Without them the prover starts a transfer from a state where an UNMINTED token is approved, and the transfer mints.

definition transferVerb(method f) returns bool =
    f.selector == sig:transferFrom(address,address,uint256).selector
    || f.selector == sig:safeTransferFrom(address,address,uint256).selector
    || f.selector == sig:safeTransferFrom(address,address,uint256,bytes).selector;

// nobody can call setApprovalForAll as the zero address: OZ writes `_operatorApprovals[msg.sender]` with no owner
// check, so this rests on the same stated fact as the transfer rule -- no transaction comes from the zero address
invariant theZeroAddressHasNoOperator(address op)
    !isApprovedForAll(0, op)
    { preserved with (env e) { require e.msg.sender != 0; } }

// approve reads the owner first and refuses an unminted token; a transfer clears the approval it moves past
invariant anUnmintedTokenHasNoApproval(uint256 id)
    ownerOrZero(id) == 0 => approvalOf(id) == 0;

// ---- ONLY THE HUB MINTS ----

rule onlyTheHubMints(env e, method f, calldataarg args) filtered { f -> !f.isView && !transferVerb(f) } {
    require e.msg.sender != HUB();
    uint256 supply0 = totalSupply();
    f@withrevert(e, args);
    assert lastReverted || totalSupply() <= supply0, "a caller other than the hub minted title";
}

// the transfers take the token id as a parameter, so each can lean on the reachable-state facts for THAT id
rule aTransferNeverMints(env e, method f, address from, address to, uint256 id, bytes data) filtered { f -> transferVerb(f) } {
    // no transaction comes from the zero address; OZ's `_update` skips authorization for a zero `auth`, as `_mint` does
    require e.msg.sender != 0;
    requireInvariant theZeroAddressHasNoOperator(e.msg.sender);
    requireInvariant anUnmintedTokenHasNoApproval(id);
    uint256 supply0 = totalSupply();
    if (f.selector == sig:transferFrom(address,address,uint256).selector) {
        transferFrom@withrevert(e, from, to, id);
    } else if (f.selector == sig:safeTransferFrom(address,address,uint256).selector) {
        safeTransferFrom@withrevert(e, from, to, id);
    } else {
        safeTransferFrom@withrevert(e, from, to, id, data);
    }
    assert lastReverted || totalSupply() <= supply0, "a transfer minted title";
}

// ---- NOTHING BURNS ----

rule nothingBurns(env e, method f, calldataarg args) filtered { f -> !f.isView } {
    uint256 supply0 = totalSupply();
    f(e, args);
    assert totalSupply() >= supply0, "title was burned";
}

// ---- EVERY MOVE IS A RETITLE ----

rule everyMoveIsARetitle(env e, method f, calldataarg args, uint256 id) filtered { f -> !f.isView } {
    mathint moves0 = moves[id];
    mathint retitles0 = retitles[id];
    f(e, args);
    assert moves[id] - moves0 == retitles[id] - retitles0, "a title moved without exactly one retitle";
    assert moves[id] > moves0 => retitledFrom[id] == movedFrom[id] && retitledTo[id] == movedTo[id],
        "the hub was told a different move than the one made";
}

// ANTI-HOLLOW: a transfer between holders really happens, so the rule above is not true by nothing moving
rule aTransferCanMoveTitle(env e, address from, address to, uint256 id) {
    mathint moves0 = moves[id];
    transferFrom(e, from, to, id);
    satisfy moves[id] > moves0 && from != to;
}
