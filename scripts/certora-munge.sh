#!/usr/bin/env bash
# certora-munge.sh -- build the hub copy the prover can actually execute: the six external libraries inlined, and
# the two raw-read `extsload` views cut (the prover's copy only; see THE RAW READS GO below).
#
#   scripts/certora-munge.sh [out]      regenerate verify/certora/munged/ (or `out`, which must be another
#                                       verify/certora/munged* dir) from src; scripts/certora-run.sh calls
#                                       this itself whenever a conf names the munged tree, and
#                                       scripts/certora-munged-suite.sh builds its own copy so the two never collide
#
# WHY. The hub's logic lives in six external libraries (Borrower, Lender, Settlement, Orders, Deleverage, MarketInit)
# reached by delegatecall. Under via-IR the prover cannot resolve those calls -- not by itself, and not with an
# explicit DISPATCH list -- and the legacy pipeline cannot compile the hub at all. So every library function the hub
# calls externally is made `internal` IN A COPY, and inlines into Ace. Certora calls this "munging".
#
# WHY THE COPY MEANS THE SAME THING AS THE DEPLOYED HUB:
#   - a storage-pointer library call reads and writes the CALLER's storage either way, with the same msg.sender,
#     msg.value and address(this), and a revert unwinds the same state;
#   - the one real difference is MEMORY: an external call copies a memory argument, an internal one passes a
#     reference, so a callee's write to a memory argument would leak back. One library entry point writes one:
#     Orders.post sets `a.tenor`, and its caller never reads the argument again: Ace's `postOrder` builds its own
#     `PostArgs` and returns at once. `Borrower.refinance` reads its `MigrateArgs` and writes none of it;
#   - gas differs, and the prover already treats gasleft() as arbitrary, so that only adds behaviours;
#   - the prover's copy has no `extsload`: a caller of those two views sees no function, and no rule is such a caller.
# A NEW memory-argument write in a library, or a caller that reads one back, voids that argument: re-check it.
#
# THE TRANSFORM REFUSES TO PASS A MISS. It rewrites the visibility keyword in all three layouts the tree uses (on the
# `function` line, alone on a continuation line, after a wrapped signature's `)`), then fails unless the six files
# carry no public/external function left AND exactly as many lines changed as there were visibility keywords.
# The tree is rebuilt whole on every call, so it cannot drift from src.
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
# CANONICAL before the guard: a case glob's `*` matches `/` and `..`, so munged-x/../../../contracts would pass it
OUT="$(realpath -m "${1:-$ROOT/verify/certora/munged}")"
case "$OUT" in
  "$ROOT"/verify/certora/munged | "$ROOT"/verify/certora/munged-*) ;;
  *) echo "certora-munge: refusing to regenerate $OUT -- it is removed first, so it must be verify/certora/munged*" >&2; exit 1 ;;
esac
case "${OUT#"$ROOT"/verify/certora/}" in
  */*) echo "certora-munge: refusing $OUT -- it must sit directly in verify/certora" >&2; exit 1 ;;
esac
LIBS=(Borrower Lender Settlement Orders Deleverage MarketInit)

# the three layouts of an external/public visibility keyword on a library function
SIG='^[[:space:]]+function [^;{]*\) (public|external)( |$)'
ALONE='^[[:space:]]+(public|external)$'
CLOSE='^[[:space:]]+\) (public|external)( |$)'

# BUILT IN A STAGING DIR AND SWAPPED IN ONLY WHEN IT DIFFERS: prover runs launched together each call this, and
# regenerating in place deleted a sibling's sources while it compiled. Same sources, same tree, so nothing moves.
# What no lock can fix: a run still COMPILING when src changes under it (a mutant, an edit) loses its tree.
STAGE="$OUT.stage.$$"
trap 'rm -rf "$STAGE"' EXIT
rm -rf "$STAGE"
mkdir -p "$STAGE/contracts" "$STAGE/harness"
cp -R "$ROOT/src" "$STAGE/src"

expected=0
for lib in "${LIBS[@]}"; do
  f="$STAGE/src/ace/hub/$lib.sol"
  n="$(grep -cE "$SIG|$ALONE|$CLOSE" "$f" || true)"
  expected=$((expected + n))
  sed -E -i \
    -e "/^[[:space:]]+function /s/\\) (public|external)( |\$)/) internal\\2/" \
    -e "s/^([[:space:]]+)(public|external)\$/\\1internal/" \
    -e "s/^([[:space:]]+)\\) (public|external)( |\$)/\\1) internal\\3/" \
    "$f"
  if grep -qE "$SIG|$ALONE|$CLOSE" "$f"; then
    echo "certora-munge: $lib.sol still has an external/public function after the rewrite -- refusing." >&2
    grep -nE "$SIG|$ALONE|$CLOSE" "$f" >&2
    exit 1
  fi
done

# THE RAW READS GO: `Ace.extsload(bytes32)` and `extsload(bytes32,uint256)` sload a caller's slot, which has no storage
# path, and the prover then turns storage splitting off for the WHOLE contract ("no storage path associated with them
# (this prevents storage splitting being applied on this contract)"), so every packed-word proof ran on one flat map.
# Both are views that write nothing, so no rule over another verb loses a behaviour, and no spec calls them.
# ACE_MUNGE_KEEP_RAW_READS=1 keeps them: scripts/certora-munged-suite.sh sets it, since lens and vault tests read through them.
ACE="$STAGE/src/ace/hub/Ace.sol"
if [ "${ACE_MUNGE_KEEP_RAW_READS:-0}" != 1 ]; then
  if [ "$(grep -cE '^    function extsload\(' "$ACE" || true)" -ne 2 ]; then
    echo "certora-munge: expected exactly two extsload functions in Ace.sol -- refusing." >&2
    exit 1
  fi
  sed -E -i \
    -e '/^    \/\/\/ @notice Read (one storage slot raw|`n` contiguous storage slots raw)/d' \
    -e '/^    function extsload\(/,/^    }$/d' \
    "$ACE"
  if grep -qE 'function extsload|sload\(slot\)|^    /// @notice Read (one storage slot raw|`n` contiguous)' "$ACE"; then
    echo "certora-munge: an extsload line survived the cut -- refusing." >&2
    grep -nE 'function extsload|sload\(slot\)' "$ACE" >&2
    exit 1
  fi
fi

changed=0
for lib in "${LIBS[@]}"; do
  n="$(diff "$ROOT/src/ace/hub/$lib.sol" "$STAGE/src/ace/hub/$lib.sol" | grep -c '^>' || true)"
  changed=$((changed + n))
done
if [ "$changed" -ne "$expected" ]; then
  echo "certora-munge: $changed lines changed but $expected visibility keywords were found -- refusing." >&2
  exit 1
fi

# EVERY harness, re-pointed at the munged tree, so a storage-link harness and the hub share ONE set of types
for h in "$ROOT"/verify/certora/harness/*.sol; do
  sed -e 's#\.\./\.\./\.\./src/#../src/#' "$h" >"$STAGE/harness/$(basename "$h")"
done

# THE COMPARE AND THE SWAP ARE ONE STEP, under a lock: two runs launched after a src edit both see a stale tree, and
# unlocked, the second's `rm -rf` lands on the first's freshly swapped sources mid-compile. `mv -T` never nests.
exec 9>"$OUT.lock"
flock 9
if [ -d "$OUT" ] && diff -rq "$STAGE" "$OUT" >/dev/null 2>&1; then
  echo "certora-munge: $OUT is already current ($expected library functions inlined); left untouched"
  exit 0
fi
rm -rf "$OUT"
mv -T "$STAGE" "$OUT"
echo "certora-munge: inlined $expected library functions across ${#LIBS[@]} libraries into $OUT"
