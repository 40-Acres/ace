#!/usr/bin/env bash
# certora-munge-receipt.sh -- build the SAeroStakeReceipt copy the prover can load: its clone args read from storage.
#
#   scripts/certora-munge-receipt.sh [out]   regenerate verify/certora/munged-receipt/ (or `out`, another
#                                            verify/certora/munged-receipt* dir) from src; scripts/certora-run.sh
#                                            calls this itself whenever a conf names the munged receipt tree
#
# WHY. A receipt is a clone, and its three args (PORTFOLIO, STAKE_ID, UNITS) are bytes appended to its own code, read by
# `_args()` through OZ `Clones.fetchCloneArgs(address(this))`, an EXTCODECOPY of itself. The prover cannot model that
# read: its ExtcodecopyInstructionHandler gives every EXTCODECOPY site a fresh havoc, so two reads of PORTFOLIO() in one
# rule disagree. Measured on the unmunged receipt: `PORTFOLIO() == PORTFOLIO()` and `UNITS() == totalSupply()` both
# FAIL. A CVL summary cannot replace it either: the prover reports `Clones.fetchCloneArgs` "detected but not matching"
# under via-IR, so a summary would not bind. So IN A COPY the read becomes a virtual hook a harness answers.
#
# WHAT THE COPY CHANGES, AND NOTHING ELSE: `_args()` goes `private view` -> `internal view virtual`. Its body, and every
# other line of src, is unchanged. The harness verify/certora/munge-receipt/SAeroStakeReceiptHarness.sol
# (copied into the tree) overrides it to answer three storage words of its own that no function writes.
#
# WHY THE COPY MEANS THE SAME THING AS A DEPLOYED CLONE:
#   - a clone's code never changes, so on a real clone `_args()` answers the same (P, S, U) on every call, and never
#     reverts (its code is the proxy plus three ABI words, so the length check and the address's clean word always hold);
#   - the harness answers the same three words on every call and never reverts, and since nothing writes them they are
#     free at a rule's start: every (P, S, U) a factory could write is one of them, so a rule holds of every clone;
#   - the words sit after every slot the receipt and its bases declare, so no receipt slot moves;
#   - the constructor leaves them zero, so an invariant's base case meets one args triple; that loses nothing while no
#     invariant's base clause reads the args (the units invariant reads UNITS only past None), and every preservation
#     step and rule starts from free storage, so from any args. An invariant whose base clause reads them needs a re-think.
# The copy cannot model a clone whose args are not a clean (address, uint256, uint256) triple: the factory never writes one.
#
# THE TRANSFORM REFUSES TO PASS A MISS. The swap must match its line EXACTLY ONCE, and the copy must differ from
# src by exactly one line. Like the other munged trees, the copy is GENERATED and git-ignored, rebuilt whole on
# every call, so it cannot drift from src; a mutant applied to src flows into it.
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
OUT="$(realpath -m "${1:-$ROOT/verify/certora/munged-receipt}")"
case "$OUT" in
  "$ROOT"/verify/certora/munged-receipt | "$ROOT"/verify/certora/munged-receipt-*) ;;
  *) echo "certora-munge-receipt: refusing to regenerate $OUT -- it is removed first, so it must be verify/certora/munged-receipt*" >&2; exit 1 ;;
esac
case "${OUT#"$ROOT"/verify/certora/}" in
  */*) echo "certora-munge-receipt: refusing $OUT -- it must sit directly in verify/certora" >&2; exit 1 ;;
esac

TEMPLATE="$ROOT/verify/certora/munge-receipt/SAeroStakeReceiptHarness.sol"
[ -f "$TEMPLATE" ] || { echo "certora-munge-receipt: no harness template at $TEMPLATE -- refusing." >&2; exit 1; }

STAGE="$OUT.stage.$$"
trap 'rm -rf "$STAGE"' EXIT
rm -rf "$STAGE"
mkdir -p "$STAGE/contracts" "$STAGE/harness"
cp -R "$ROOT/src" "$STAGE/src"
F="$STAGE/src/entities/saero/SAeroStakeReceipt.sol"

OLD='    function _args() private view returns (address, uint256, uint256) {'
NEW='    function _args() internal view virtual returns (address, uint256, uint256) {'
n="$(grep -cxF -- "$OLD" "$F" || true)"
if [ "$n" -ne 1 ]; then
  echo "certora-munge-receipt: expected exactly one line in SAeroStakeReceipt.sol, found $n -- refusing:" >&2
  echo "  $OLD" >&2
  exit 1
fi
body="$(cat "$F")"
body="${body/$'\n'"$OLD"$'\n'/$'\n'"$NEW"$'\n'}"
printf '%s\n' "$body" >"$F"

changed="$(diff "$ROOT/src/entities/saero/SAeroStakeReceipt.sol" "$F" | grep -c '^>' || true)"
if [ "$changed" -ne 1 ]; then
  echo "certora-munge-receipt: $changed lines changed but 1 was expected -- refusing." >&2
  exit 1
fi
if ! diff -rq -x SAeroStakeReceipt.sol "$ROOT/src" "$STAGE/src" >/dev/null; then
  echo "certora-munge-receipt: the copy differs from src outside SAeroStakeReceipt.sol -- refusing." >&2
  exit 1
fi

# every harness, re-pointed at the munged tree, so the harness, the mocks and the receipt share ONE set of types
for h in "$ROOT"/verify/certora/harness/*.sol; do
  sed -e 's#\.\./\.\./\.\./src/#../src/#' "$h" >"$STAGE/harness/$(basename "$h")"
done
cp "$TEMPLATE" "$STAGE/harness/SAeroStakeReceiptHarness.sol"

exec 9>"$OUT.lock"
flock 9
if [ -d "$OUT" ] && diff -rq "$STAGE" "$OUT" >/dev/null 2>&1; then
  echo "certora-munge-receipt: $OUT is already current; left untouched"
  exit 0
fi
rm -rf "$OUT"
mv -T "$STAGE" "$OUT"
echo "certora-munge-receipt: clone args made a virtual hook in $OUT (1 line munged)"
