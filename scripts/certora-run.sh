#!/usr/bin/env bash
# certora-run.sh -- run a Certora spec against src on THIS MACHINE, never the cloud.
#
#   scripts/certora-run.sh verify/certora/confs/VaultArithmetic.conf             every rule in the conf
#   scripts/certora-run.sh verify/certora/confs/VaultArithmetic.conf --rule feeHighWaterNeverFallsAtACollection
#   CERTORA_CPUS=0-7 scripts/certora-run.sh ...      also capped to cores 0-7 (every run is already nice 19)
#   CERTORA_MEM=24G scripts/certora-run.sh ...       memory cap for the whole run, solvers included (default 40G; off = none)
#
# The conf path may be relative to the caller or absolute. Extra arguments pass through to certoraRun.py,
# except the ones refused below. Install once with scripts/certora-setup.sh.
#
# THE COMPILER SETTINGS ARE THE SHIPPED ONES, DERIVED, NEVER COPIED. The solc version, optimizer runs and EVM
# version are read from foundry.toml, and every run compiles via-IR because [profile.deploy] does:
# a proof over legacy-pipeline bytecode is a proof about a contract nobody deploys. So a conf may not set any
# solc_* key, and neither may the command line -- this script refuses both rather than let one drift.
#
# LOCAL ONLY, ENFORCED HERE, three ways over:
#   1. certoraRun uploads the sources unless it runs a local jar, and `server` can come from a conf as well as
#      the command line. So this script passes --jar itself -- is_local() checks it FIRST -- and refuses
#      server, jar and override_base_config from either place, in any JSON5 spelling of the key.
#   2. It refuses to run without the jar, and unsets CERTORAKEY.
#   3. The prover's EVENT REPORTING, on by default, posts run events to an AWS SQS queue using whatever AWS
#      credentials the machine holds. Every conf must turn it off in its OWN prover_args -- a command-line
#      --prover_args silently REPLACES the conf's list, so it is refused unless it carries the switch too (the
#      split-depth knobs for a heavy verb go that way) -- and this script blanks the
#      AWS credential chain besides, so a regression in that flag still finds nothing to send with.
#
# NEVER A GATE, and no CI job may call it -- the same reasoning that keeps make halmos, make verify and
# make kani out of CI: a timeout is a fact about a solver's budget, not a defect in the tree.
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
TOOLS="${ACE_CERTORA_HOME:-$HOME/.local/share/certora-toolchain}"
CERTORA="$TOOLS/out"
TOML="$ROOT/foundry.toml"

die() {
  echo "$*" >&2
  exit 2
}

[ "$#" -ge 1 ] || die "usage: scripts/certora-run.sh <conf> [certoraRun args ...]"
CONF="$1"
shift
case "$CONF" in
  /*) ;;
  *) CONF="$PWD/$CONF" ;;
esac
[ -f "$CONF" ] || die "no conf at $CONF"

# --legacy: DIAGNOSTIC ONLY -- compile the legacy pipeline instead of via-IR, to tell a prover limitation from a
# property. A result under it is about bytecode nobody deploys and must never be recorded as a proof.
LEGACY=""
args=()
for a in "$@"; do
  if [ "$a" = "--legacy" ]; then
    LEGACY=1
  else
    args+=("$a")
  fi
done
set -- "${args[@]+"${args[@]}"}"

for a in "$@"; do
  case "$a" in
    --server | --server=* | --jar | --jar=* | --override_base_config | --override_base_config=*)
      die "refusing $a: this script pins the local jar itself, and never sends src to the cloud." ;;
    --prover_args=*"-enableEventReporting false"*) ;; # it replaces the conf's list, so it must carry the switch itself
    --prover_args | --prover_args=*)
      die "refusing $a: it replaces the conf's prover_args; pass --prover_args='-enableEventReporting false ...' or edit the conf." ;;
    --solc | --solc=* | --solc_*)
      die "refusing $a: compiler settings are derived from foundry.toml so they cannot drift from the deploy." ;;
  esac
done

# a JSON5 key may be bare, single-quoted or double-quoted
if grep -qE "(^|[{,[:space:]])[\"']?(server|jar|override_base_config|solc[a-z_]*)[\"']?[[:space:]]*:" "$CONF"; then
  die "refusing $CONF: a conf may not set server, jar, override_base_config or any solc_* key."
fi
grep -qF -- '-enableEventReporting false' "$CONF" ||
  die "refusing $CONF: it must carry \"prover_args\": [\"-enableEventReporting false\"]."

if [ ! -f "$CERTORA/emv.jar" ]; then
  echo "no local prover at $CERTORA/emv.jar -- run scripts/certora-setup.sh first." >&2
  echo "Refusing to run: without the jar certoraRun would upload the sources to the cloud." >&2
  exit 1
fi

# THE JAR MUST BE THE PINNED PROVER. A home built before the pin moved still runs, and on the hub 8.19.2 returns
# spurious FAILs (unlocated internals, raw storage addresses), so a stale build is refused, never quietly used.
PIN="$(grep -m 1 -E '^PROVER_COMMIT=' "$ROOT/scripts/certora-setup.sh" | cut -d'"' -f2)"
BUILT="$(cat "$CERTORA/.built-commit" 2>/dev/null || true)"
[ -n "$PIN" ] || die "could not read PROVER_COMMIT from scripts/certora-setup.sh."
[ "$BUILT" = "$PIN" ] ||
  die "the prover at $CERTORA is built at '${BUILT:-unknown}', not the pinned $PIN -- run scripts/certora-setup.sh to rebuild it."

JDK="$(find "$TOOLS" -maxdepth 1 -type d -name 'jdk-21*' | sort | tail -n 1)"
[ -n "$JDK" ] || die "no JDK under $TOOLS -- run scripts/certora-setup.sh (or set ACE_CERTORA_HOME to where it installed)."

# first match is [profile.default]; [profile.deploy] inherits these and adds via_ir
SOLC_VERSION="$(grep -m 1 -E '^solc[[:space:]]*=' "$TOML" | cut -d'"' -f2 || true)"
RUNS="$(grep -m 1 -E '^optimizer_runs[[:space:]]*=' "$TOML" | tr -dc '0-9' || true)"
EVM="$(grep -m 1 -E '^evm_version[[:space:]]*=' "$TOML" | cut -d'"' -f2 || true)"
[ -n "$SOLC_VERSION" ] && [ -n "$RUNS" ] && [ -n "$EVM" ] ||
  die "could not read solc / optimizer_runs / evm_version from $TOML (got '$SOLC_VERSION' '$RUNS' '$EVM')."
SOLC="$HOME/.local/share/svm/$SOLC_VERSION/solc-$SOLC_VERSION"
[ -x "$SOLC" ] || die "solc $SOLC_VERSION not found at $SOLC (forge installs it on first build)."
[ -d "$ROOT/lib/openzeppelin-contracts/contracts" ] ||
  die "lib is empty in this tree -- run `git submodule update --init --recursive` first."

unset CERTORAKEY AWS_ACCESS_KEY_ID AWS_SECRET_ACCESS_KEY AWS_SESSION_TOKEN AWS_PROFILE AWS_DEFAULT_PROFILE \
  AWS_ROLE_ARN AWS_WEB_IDENTITY_TOKEN_FILE AWS_CONTAINER_CREDENTIALS_RELATIVE_URI AWS_CONTAINER_CREDENTIALS_FULL_URI
export AWS_SHARED_CREDENTIALS_FILE=/dev/null AWS_CONFIG_FILE=/dev/null AWS_EC2_METADATA_DISABLED=true
export CERTORA JAVA_HOME="$JDK"
export PATH="$TOOLS/venv/bin:$JDK/bin:$CERTORA:$TOOLS/bin:$PATH"
# no browser pop-up of FinalResults.html and no desktop notification at a run's end (the prover reads both switches);
# a verdict is read from emv-*/Reports/output.json anyway, never from a page
export CERTORA_DISABLE_POPUP=1 CERTORA_DISABLE_NOTIFICATION=1

# a conf over the munged hub (libraries inlined) gets that tree rebuilt from src first, so it never goes stale;
# a conf over the munged vault (forwarded verbs inlined), the munged receipt (clone args from storage), the munged
# factory (its clone call a recorded hook) or the munged pure harness gets its own the same way
if grep -q "verify/certora/munged-vault/" "$CONF"; then
  "$ROOT/scripts/certora-munge-vault.sh"
elif PINNED="$(grep -oE 'verify/certora/munged-vault-pin-[A-Za-z]+/' "$CONF" | sort -u)" && [ -n "$PINNED" ]; then
  [ "$(printf '%s\n' "$PINNED" | wc -l)" -eq 1 ] || die "refusing $CONF: it names more than one pinned vault copy."
  "$ROOT/scripts/certora-munge-vault.sh" "$ROOT/${PINNED%/}"
elif grep -q "verify/certora/munged-receipt/" "$CONF"; then
  "$ROOT/scripts/certora-munge-receipt.sh"
elif grep -q "verify/certora/munged-factory/" "$CONF"; then
  "$ROOT/scripts/certora-munge-factory.sh"
elif grep -q "verify/certora/munged-pure/" "$CONF"; then
  "$ROOT/scripts/certora-munge-pure.sh"
elif grep -q "verify/certora/munged/" "$CONF"; then
  "$ROOT/scripts/certora-munge.sh"
fi

PIPELINE=(--solc_via_ir)
if [ -n "$LEGACY" ]; then
  PIPELINE=()
  echo "certora-run: --legacy -- DIAGNOSTIC: NOT the shipped (via-IR) bytecode; never record this run as a proof." >&2
fi

# EVERY RUN IS LOW PRIORITY (nice 19, inherited by every solver it spawns): it takes whatever cores are idle and
# yields them to anything else on the machine. CERTORA_CPUS=<cpu-list> (e.g. 0-7) also caps it to those cores;
# scripts/certora-throttle.sh does either to a run already going
LIMIT=(nice -n 19)
if [ -n "${CERTORA_CPUS:-}" ]; then
  LIMIT=(taskset -c "$CERTORA_CPUS" nice -n 19)
fi

# EVERY RUN IS MEMORY-CAPPED TOO, in its own cgroup scope. Neither -Xmx nor a core cap bounds a run: -Xmx caps only
# the JVM, and one yices query alone has reached 52 GB. Over the cap the kernel OOM-kills the largest process in the
# scope -- a runaway solver, not the JVM -- and the run must SURVIVE that kill rather than be torn down with it.
#
# THE SURVIVAL IS BOUGHT BY Delegate=yes, NOT BY OOMPolicy=continue, and the difference is a systemd version.
# `-p OOMPolicy=continue` is refused outright by systemd 249 on a SCOPE ("Unknown assignment: OOMPolicy=continue"),
# so a machine on 249 could not start a capped run at all. Dropping the property is not the fix either: OOMPolicy
# falls back to DefaultOOMPolicy=, which ships as `stop`, and `stop` tears down the whole scope the moment one
# solver is OOM-killed -- turning the cap into a kill switch for the run it exists to protect. Delegate=yes gets
# `continue` as its own documented default (systemd.service(5): the default is continue for units with Delegate=
# turned on), it is accepted on every version in play, and delegation is what a scope holding a process tree
# wants regardless. Keep both properties: a newer systemd honours the explicit one, 249 needs it absent.
MEM="${CERTORA_MEM:-40G}"
if [ "$MEM" != "off" ]; then
  LIMIT=(systemd-run --user --scope --quiet -p "MemoryMax=$MEM" -p MemorySwapMax=0 -p Delegate=yes -- "${LIMIT[@]}")
fi

# THE JVM'S HEAP IS SET FROM THE CAP, because its default is a QUARTER of the cgroup's memory: CERTORA_MEM=20G left it
# 5 GiB (jcmd read MaxHeapSize=5368709120 on a live prover, 2026-11-12), and that, not the cap, was this tree's "heap"
# wall. A cap given in whole G gets -Xmx at 60% of it, leaving the rest to the solvers; a caller's own --java_args wins.
JAVA_HEAP=()
case " $* " in *" --java_args "*) ;; *)
  if [[ "$MEM" =~ ^([0-9]+)[Gg]$ ]] && [ $((BASH_REMATCH[1] * 6 / 10)) -ge 1 ]; then
    JAVA_HEAP=(--java_args "-Xmx$((BASH_REMATCH[1] * 6 / 10))g")
  fi
  ;;
esac

cd "$ROOT"
"${LIMIT[@]}" python3 "$CERTORA/certoraRun.py" "$CONF" "$@" "${JAVA_HEAP[@]+"${JAVA_HEAP[@]}"}" \
  --solc "$SOLC" "${PIPELINE[@]+"${PIPELINE[@]}"}" --solc_optimize "$RUNS" --solc_evm_version "$EVM" \
  --jar "$CERTORA/emv.jar"
