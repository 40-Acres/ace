#!/usr/bin/env bash
# certora-munge-vault.sh -- build the AceVault copy the prover can load: the fourteen forwarded verbs as typed internal calls.
#
#   scripts/certora-munge-vault.sh [out]   regenerate verify/certora/munged-vault/ (or `out`, another verify/certora/munged-vault*
#                                          dir) from src; scripts/certora-run.sh calls this itself whenever a conf
#                                          names the munged vault tree
#   scripts/certora-munge-vault.sh verify/certora/munged-vault-pin-drawMoreFor
#                                          the same copy with the forward pinned to one verb (item 5 below)
#
# WHY. AceVault forwards fourteen verbs' calldata verbatim into AceVaultCaps, AceVaultInKind and AceVaultFlows by
# DELEGATECALL, with a fixed five-word suffix of its own figures appended (AceVaultTail). The prover cannot load that: its
# inliner needs a delegatecall into a static-argument library function to carry exactly the ABI-sized calldata, and the
# suffix makes it longer. So IN A COPY the forward becomes a typed internal call, as scripts/certora-munge.sh does for the
# hub's libraries. The user ruled this the fallback on 2026-11-06 (the design record
#); S3 added the door-mode verbs and `extendFor`, S6 `refinanceFor` and the fifth word;
# the top-up door added `drawMoreFor`.
#
# WHAT THE COPY CHANGES, AND NOTHING ELSE:
#   1. the fourteen forwarded library functions go `external` -> `internal`, and the array parameters `calldata` ->
#      `memory` (the in-kind collect's, the door collect's and the claim's: three); `extendFor`'s two `bytes calldata`
#      and `refinanceFor`'s and `drawMoreFor`'s one each stay calldata, and the dispatch hands them slices of msg.data,
#      since `Permits.pull` and the product's `beforeLend`/`afterLend` legs take calldata;
#   2. the vault's one DELEGATECALL line becomes AceVaultMunged.forward (verify/certora/munge-vault/AceVaultMunged.sol, copied
#      into the tree), which decodes this call's arguments by selector and calls the named internal function;
#   3. the vault's five suffix words go to a transient slot first, and AceVaultTail's one read reads them there, its readers
#      turning `pure` -> `view` as a transient read requires;
#   4. the vault's raw-read view `extsload(bytes32[])` is deleted. Its sload of an arbitrary slot turned the prover's storage
#      splitting off for the whole vault (and with it the heap a run needs); it writes nothing, and no vault scene calls it;
#   5. ONLY in a pinned copy (munged-vault-pin-<verb>), the forward refuses every selector but that verb's and routes on it
#      as a constant: exact for a rule that calls only that verb, which the full copy's msg.sig dispatch runs out of heap on.
#
# WHY THE COPY MEANS THE SAME THING AS THE DEPLOYED VAULT:
#   - EXTERNAL -> INTERNAL keeps the state the body touches: an internal library call runs on the CALLER's storage, with the
#     same msg.sender, msg.value and address(this), and a revert unwinds the same state, exactly as the vault's DELEGATECALL
#     does. The forward keeps its place inside `_fwd`/`_collect`/`_proceeds`/`_lendingVerb`, so it still runs under the lock.
#   - CALLDATA -> MEMORY for `ids` (both collects) and `tokens` (claim) is safe because no body writes its array, and a memory
#     argument the callee only reads means what the calldata one did. A body that starts WRITING its array voids this
#     point, as does a caller that reads one back: re-check it.
#   - THE TYPED DISPATCH decodes the same selector and the same argument types the library's own ABI decoder would, from the
#     same bytes: msg.data, which the vault's external decoder has already validated whole, every calldata array and
#     `bytes` included, before its body runs (AceVaultForwardTail's T3 rows pin it). It routes by the pair (selector,
#     library), because the collect goes to AceVaultInKind in kind and to AceVaultFlows in door mode, and a routing slip
#     refuses rather than running the wrong body.
#   - THE TLOAD WORDS EQUAL THE CALLDATA TAIL because both are the same five TAIL immutables, packed once at deploy: the
#     deployed vault appends them after the caller's bytes, the copy stores them before every dispatch. The slot is ERC-7201
#     namespaced (erc7201:ace.certora.munged.tail), so it cannot meet the reentrancy guard's, the context word's or the
#     lending doors' words. It is NEVER CLEARED, deliberately: the words are this vault's constants, the same on every
#     dispatch, so a stale read equals a fresh one, and the lock stops forwarded verbs from nesting.
#   - gas differs, and the prover already treats gasleft() as arbitrary, so that only adds behaviours.
# THE ONE THING THE COPY CANNOT MODEL is a caller's own forged trailing bytes: they never reach a library here, so the claim
# that a library reads only the vault's suffix belongs to the deployed code, and its forge tests carry it (AceVaultForwardTail
# T1, with T2 and T3 beside it), not the prover. A fifteenth forwarded verb voids the dispatch's coverage: add it here.
#
# THE TRANSFORM REFUSES TO PASS A MISS. Every rewrite is a whole-line literal swap that must match its line EXACTLY ONCE,
# the copy must differ from src by exactly the expected number of lines, and its AceVault must make no DELEGATECALL.
# Like the hub's munged tree, the copy is GENERATED and git-ignored, never committed, and rebuilt whole on every call, so it
# cannot drift from src; scripts/certora-run.sh rebuilds it for any conf that names verify/certora/munged-vault/.
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
OUT="$(realpath -m "${1:-$ROOT/verify/certora/munged-vault}")"
case "$OUT" in
  "$ROOT"/verify/certora/munged-vault | "$ROOT"/verify/certora/munged-vault-*) ;;
  *) echo "certora-munge-vault: refusing to regenerate $OUT -- it is removed first, so it must be verify/certora/munged-vault*" >&2; exit 1 ;;
esac
case "${OUT#"$ROOT"/verify/certora/}" in
  */*) echo "certora-munge-vault: refusing $OUT -- it must sit directly in verify/certora" >&2; exit 1 ;;
esac

TEMPLATE="$ROOT/verify/certora/munge-vault/AceVaultMunged.sol"
SLOT="0xd1441af45b27613188b5d9a7dc0ea3f4aeef1fb960ef8c3a120619d445c13b00" # erc7201:ace.certora.munged.tail
grep -qF "SLOT = $SLOT;" "$TEMPLATE" || { echo "certora-munge-vault: $TEMPLATE does not name the slot $SLOT -- refusing." >&2; exit 1; }

STAGE="$OUT.stage.$$"
trap 'rm -rf "$STAGE"' EXIT
rm -rf "$STAGE"
mkdir -p "$STAGE/contracts" "$STAGE/harness"
cp -R "$ROOT/src" "$STAGE/src"
CUR="$STAGE/src/vault"

# swap FILE OLD NEW: replace the one whole line OLD with NEW (which may hold a newline), refusing unless OLD occurs exactly once
swap() {
  local f="$1" old="$2" new="$3" n body
  n="$(grep -cxF -- "$old" "$f" || true)"
  if [ "$n" -ne 1 ]; then
    echo "certora-munge-vault: expected exactly one line in $(basename "$f"), found $n -- refusing:" >&2
    echo "  $old" >&2
    exit 1
  fi
  body="$(cat "$f")"
  body="${body/$'\n'"$old"$'\n'/$'\n'"$new"$'\n'}"
  printf '%s\n' "$body" >"$f"
}

I='    '
swap "$CUR/libraries/AceVaultCaps.sol" "${I}function submitCap(address key, uint192 cap) external {" "${I}function submitCap(address key, uint192 cap) internal {"
swap "$CUR/libraries/AceVaultCaps.sol" "${I}function submitDelist(address collateral) external {" "${I}function submitDelist(address collateral) internal {"
swap "$CUR/libraries/AceVaultCaps.sol" "${I}function acceptCap(address key) external {" "${I}function acceptCap(address key) internal {"
swap "$CUR/libraries/AceVaultCaps.sol" "${I}function revokePendingCap(address key) external {" "${I}function revokePendingCap(address key) internal {"
swap "$CUR/libraries/AceVaultInKind.sol" "${I}function collectForfeited(uint256[] calldata ids) external returns (uint256[] memory out) {" \
  "${I}function collectForfeited(uint256[] memory ids) internal returns (uint256[] memory out) {"
swap "$CUR/libraries/AceVaultInKind.sol" "${I}function claim(address[] calldata tokens, address to) external returns (uint256[] memory paid) {" \
  "${I}function claim(address[] memory tokens, address to) internal returns (uint256[] memory paid) {"
swap "$CUR/libraries/AceVaultFlows.sol" "${I}function collectForfeited(uint256[] calldata ids) external returns (uint256[] memory out) {" \
  "${I}function collectForfeited(uint256[] memory ids) internal returns (uint256[] memory out) {"
swap "$CUR/libraries/AceVaultFlows.sol" "${I}function returnProceeds(address collateral, uint256 cash, bool closes) external {" \
  "${I}function returnProceeds(address collateral, uint256 cash, bool closes) internal {"
swap "$CUR/libraries/AceVaultFlows.sol" "${I}function submitWriteOff(address collateral) external {" "${I}function submitWriteOff(address collateral) internal {"
swap "$CUR/libraries/AceVaultFlows.sol" "${I}function acceptWriteOff(address collateral) external {" "${I}function acceptWriteOff(address collateral) internal {"
swap "$CUR/libraries/AceVaultFlows.sol" "${I}function revokeWriteOff(address collateral) external {" "${I}function revokeWriteOff(address collateral) internal {"
swap "$CUR/libraries/AceVaultFlows.sol" \
  "${I}function extendFor(uint256 loanId, uint256 maxFee, uint256 minBufferWad, bytes calldata data, bytes calldata permit2) external returns (uint256 fee) {" \
  "${I}function extendFor(uint256 loanId, uint256 maxFee, uint256 minBufferWad, bytes calldata data, bytes calldata permit2) internal returns (uint256 fee) {"
swap "$CUR/libraries/AceVaultFlows.sol" "${I}) external returns (uint256 newId, uint256 out) {" "${I}) internal returns (uint256 newId, uint256 out) {" # refinanceFor's
swap "$CUR/libraries/AceVaultFlows.sol" "${I}${I}external" "${I}${I}internal" # drawMoreFor's visibility, on its own line under its long signature
swap "$CUR/libraries/AceVaultTail.sol" "${I}${I}${I}w := calldataload(sub(calldatasize(), sub(SIZE, shl(5, i))))" "${I}${I}${I}w := tload(add($SLOT, i))"
# a transient read is `view`, so the word reader and the eleven figure readers lose `pure` with it
for r in 'ace() internal pure returns (address)' 'capTimelock() internal pure returns (uint64)' 'inKind() internal pure returns (bool)' \
  'door() internal pure returns (bool)' 'curator() internal pure returns (address)' 'guardian() internal pure returns (address)' \
  'asset() internal pure returns (address)' 'terms() internal pure returns (address)' 'title() internal pure returns (address)' \
  'minTenor() internal pure returns (uint64)' 'maxTenor() internal pure returns (uint64)' '_word(uint256 i) private pure returns (uint256 w)'; do
  swap "$CUR/libraries/AceVaultTail.sol" "${I}function $r {" "${I}function ${r/ pure / view } {"
done
swap "$CUR/AceVault.sol" "${I}${I}(ok, ret) = lib.delegatecall(abi.encodePacked(msg.data, TAIL0, TAIL1, TAIL2, TAIL3, TAIL4));" \
  "${I}${I}(ok, ret) = (true, AceVaultMunged.forward(lib, TAIL0, TAIL1, TAIL2, TAIL3, TAIL4));"
swap "$CUR/AceVault.sol" 'import {AceVaultTail} from "./libraries/AceVaultTail.sol";' \
  'import {AceVaultTail} from "./libraries/AceVaultTail.sol";'$'\n''import {AceVaultMunged} from "./AceVaultMunged.sol";'
cp "$TEMPLATE" "$CUR/AceVaultMunged.sol"

# 5. A PINNED copy (`out` named verify/certora/munged-vault-pin-<verb>) forwards that one verb and refuses every other
# selector. The dispatch otherwise reads msg.sig, which the prover does not fold, so each forwarded verb's program carries
# all thirteen bodies, and the heavy scenes exhaust the heap on it. For a rule that calls only the pinned verb, msg.sig is
# that verb's selector, so the pinned copy runs exactly the branch the full copy would. Every other forwarded verb reverts
# in it, so a rule over another forwarded verb, or a parametric rule over all of them, must use the full copy.
PIN="$(basename "$OUT")"
case "$PIN" in
  munged-vault-pin-*) PIN="${PIN#munged-vault-pin-}" ;;
  *) PIN="" ;;
esac
if [ -n "$PIN" ]; then
  case "$PIN" in
    drawMoreFor) SEL=DRAW_MORE_FOR ;;
    refinanceFor) SEL=REFINANCE_FOR ;;
    extendFor) SEL=EXTEND_FOR ;;
    submitCap) SEL=SUBMIT_CAP ;;
    submitDelist) SEL=SUBMIT_DELIST ;;
    acceptCap) SEL=ACCEPT_CAP ;;
    revokePendingCap) SEL=REVOKE_PENDING_CAP ;;
    collectForfeited) SEL=COLLECT ;;
    claim) SEL=CLAIM ;;
    returnProceeds) SEL=RETURN_PROCEEDS ;;
    submitWriteOff) SEL=SUBMIT_WRITE_OFF ;;
    acceptWriteOff) SEL=ACCEPT_WRITE_OFF ;;
    revokeWriteOff) SEL=REVOKE_WRITE_OFF ;;
    *) echo "certora-munge-vault: no pin for '$PIN' -- refusing (one of the thirteen forwarded verbs, by name)." >&2; exit 1 ;;
  esac
  swap "$CUR/AceVaultMunged.sol" "${I}${I}bytes4 s = msg.sig;" \
    "${I}${I}if (msg.sig != $SEL) revert NoForward();"$'\n'"${I}${I}bytes4 s = $SEL; // PINNED by scripts/certora-munge-vault.sh"
  if grep -qE '^ *bytes4 s = msg\.sig;' "$CUR/AceVaultMunged.sol"; then
    echo "certora-munge-vault: the pinned forward still reads msg.sig -- refusing." >&2
    exit 1
  fi
fi

# 4. the vault's one raw-read view, extsload(bytes32[]), is cut: its sload of a caller-chosen slot stops the prover splitting
# the vault's storage at all, and no vault conf calls it (a lens reads it on the deployed vault, never in a vault scene)
n="$(grep -c '^    function extsload(' "$CUR/AceVault.sol" || true)"
[ "$n" -eq 1 ] || { echo "certora-munge-vault: expected one extsload view in AceVault, found $n -- refusing." >&2; exit 1; }
sed -E -i -e '/^    \/\/\/ @notice Raw storage words of this vault at `slots`/d' -e '/^    function extsload\(/,/^    }$/d' "$CUR/AceVault.sol"
if grep -qE 'extsload|sload\(' "$CUR/AceVault.sol"; then
  echo "certora-munge-vault: the copy's AceVault still holds an extsload or an sload -- refusing." >&2
  exit 1
fi
CUT=13 # the view's NatSpec line and its eleven-line body, plus the forward line swapped above
cut="$(diff "$ROOT/src/vault/AceVault.sol" "$CUR/AceVault.sol" | grep -c '^<' || true)"
[ "$cut" -eq "$CUT" ] || { echo "certora-munge-vault: $cut AceVault lines removed but $CUT were expected -- refusing." >&2; exit 1; }

# twenty-nine lines differ: fourteen forwarded signatures, the tail read and its twelve readers' mutability, the forward,
# one added import
EXPECTED=29
changed=0
for f in libraries/AceVaultCaps libraries/AceVaultInKind libraries/AceVaultFlows libraries/AceVaultTail AceVault; do
  n="$(diff "$ROOT/src/vault/$f.sol" "$CUR/$f.sol" | grep -c '^>' || true)"
  changed=$((changed + n))
done
if [ "$changed" -ne "$EXPECTED" ]; then
  echo "certora-munge-vault: $changed lines changed but $EXPECTED were expected -- refusing." >&2
  exit 1
fi
if grep -qF "delegatecall" "$CUR/AceVault.sol"; then
  echo "certora-munge-vault: the copy's AceVault still makes a DELEGATECALL -- refusing." >&2
  exit 1
fi

# every harness, re-pointed at the munged tree, so the harness and the vault share ONE set of types
for h in "$ROOT"/verify/certora/harness/*.sol; do
  sed -e 's#\.\./\.\./\.\./src/#../src/#' "$h" >"$STAGE/harness/$(basename "$h")"
done

exec 9>"$OUT.lock"
flock 9
if [ -d "$OUT" ] && diff -rq "$STAGE" "$OUT" >/dev/null 2>&1; then
  echo "certora-munge-vault: $OUT is already current; left untouched"
  exit 0
fi
rm -rf "$OUT"
mv -T "$STAGE" "$OUT"
echo "certora-munge-vault: forwarded verbs inlined into $OUT ($EXPECTED lines munged${PIN:+, forward pinned to $PIN})"
