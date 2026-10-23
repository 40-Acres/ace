#!/usr/bin/env bash
# certora-setup.sh -- build the open-source Certora Prover LOCALLY, under one user-owned directory.
#
#   scripts/certora-setup.sh            fetch what is missing, build if the pinned commit is not built, install the CLI's deps
#
# Everything lands in $ACE_CERTORA_HOME (default ~/.local/share/certora-toolchain). No sudo, nothing
# system-wide: a JDK tarball, a static cvc5, yices and cvc4, the prover source, its build output ($CERTORA = out/),
# and a uv venv for certoraRun.py. Delete the directory to uninstall. Idempotent: a present piece is not refetched,
# and the prover is rebuilt only when out/ does not already hold a build of PROVER_COMMIT.
#
# PINNED AND CHECKED. The prover, the JDK, cvc5, yices and cvc4 are each pinned to one release, and every binary is
# verified against a sha256 before anything unpacks or runs it -- these are the binaries that read src.
# Bump a pin and its hash together. The JDK, cvc5 and yices hashes are their publishers' (Adoptium's .sha256.txt,
# GitHub's asset digest); cvc4's is OURS, taken on first download, because its release publishes none.
#
# WHY LOCAL AND NOT THE CLOUD. The prover is GPL-3.0 and runs on this machine once emv.jar exists. The
# cloud path uploads the sources to Certora, so this lane never
# takes it -- scripts/certora-run.sh pins the local jar rather than falling through.
#
# WHY THE GRAPHCORE CLONE IS BY HAND. The prover's .gitmodules pins scripts/graphcore to an SSH URL, which
# hangs on a passphrase no agent can answer, and `git submodule update` is blocked by this repo's hooks.
# So the one submodule is cloned over HTTPS and checked out at the commit the superproject records.
#
# z3 is NOT fetched: the one halmos installs is reused (uv tool install halmos), else z3 on PATH.
set -euo pipefail

TOOLS="${ACE_CERTORA_HOME:-$HOME/.local/share/certora-toolchain}"
SRC="$TOOLS/CertoraProver"
CERTORA="$TOOLS/out"

PROVER_COMMIT="63fdea80a35b36ebfe0cff5dff9009b90e91966c" # upstream pin: a Certora prover release
JDK_RELEASE="jdk-21.0.12.1+1"
JDK_ASSET="OpenJDK21U-jdk_x64_linux_hotspot_21.0.12.1_1.tar.gz"
JDK_SHA256="ce79869e1307ed8ee1e2baa86a412b1eb5b75d10a01006d788a6f968bcfaee94"
CVC5_TAG="cvc5-1.4.1"
CVC5_ASSET="cvc5-Linux-x86_64-static.zip"
CVC5_SHA256="2f8efe58fe27ba7bccbb504533f690b9312d69da14192712460e4a19231f02a1"
YICES_TAG="yices-2.7.0"
YICES_ASSET="yices-2.7.0-x86_64-pc-linux-gnu-static-gmp.tar.gz"
YICES_SHA256="49566b6f817692820538df78fe406878400d79810631c9372b2495bc81d3e00a"
CVC4_TAG="1.8"
CVC4_ASSET="cvc4-1.8-x86_64-linux-opt"
CVC4_SHA256="d38a79cf984592785eda41ec888d94ca107ac1f13058740238041e28c8472e51" # trust on first use, 2026-10-16

# download to a .part file, refuse it unless the hash matches, and only then move it into place
fetch() {
  local url="$1" dest="$2" sha="$3"
  curl -fsSL -o "$dest.part" "$url"
  if ! echo "$sha  $dest.part" | sha256sum -c --quiet -; then
    rm -f "$dest.part"
    echo "CHECKSUM MISMATCH for $url -- refusing it." >&2
    exit 1
  fi
  mv "$dest.part" "$dest"
}

# whether a git checkout already holds a commit, so a fetch is only spent when it does not
has_commit() {
  git -C "$1" cat-file -e "$2^{commit}" 2>/dev/null
}

mkdir -p "$TOOLS/bin" "$CERTORA"

# ---- JDK (19+ required; 21 LTS) ----
JDK="$TOOLS/$JDK_RELEASE"
if [ ! -x "$JDK/bin/java" ]; then
  echo "=== fetching $JDK_RELEASE ==="
  fetch "https://github.com/adoptium/temurin21-binaries/releases/download/${JDK_RELEASE/+/%2B}/$JDK_ASSET" \
    "$TOOLS/$JDK_ASSET" "$JDK_SHA256"
  tar -xzf "$TOOLS/$JDK_ASSET" -C "$TOOLS"
fi
echo "JDK:   $JDK"

# ---- cvc5 (required) ----
if [ ! -x "$TOOLS/cvc5-Linux-x86_64-static/bin/cvc5" ]; then
  echo "=== fetching $CVC5_TAG ==="
  fetch "https://github.com/cvc5/cvc5/releases/download/$CVC5_TAG/$CVC5_ASSET" "$TOOLS/$CVC5_ASSET" "$CVC5_SHA256"
  unzip -q -o "$TOOLS/$CVC5_ASSET" -d "$TOOLS"
fi
ln -sf "$TOOLS/cvc5-Linux-x86_64-static/bin/cvc5" "$TOOLS/bin/cvc5"
echo "cvc5:  $("$TOOLS/bin/cvc5" --version | head -n 1)"

# ---- yices (optional to the prover, fetched anyway) ----
# The prover's per-theory races list yices FIRST and are not filtered by what is installed, so without it every
# query loses its lead racer to a failed spawn, and the timeout cracker's first strategy runs on z3 alone.
if [ ! -x "$TOOLS/$YICES_TAG/bin/yices-smt2" ]; then
  echo "=== fetching $YICES_TAG ==="
  fetch "https://github.com/SRI-CSL/yices2/releases/download/$YICES_TAG/$YICES_ASSET" "$TOOLS/$YICES_ASSET" "$YICES_SHA256"
  tar -xzf "$TOOLS/$YICES_ASSET" -C "$TOOLS"
fi
ln -sf "$TOOLS/$YICES_TAG/bin/yices-smt2" "$TOOLS/bin/yices-smt2"
echo "yices: $("$TOOLS/bin/yices-smt2" --version | head -n 1)"

# ---- cvc4 (optional to the prover, fetched anyway; raced the same way as yices) ----
# Its last release (1.8, the repo now archived) publishes no hash, so the pin is the one taken on first download:
# it proves every later fetch matches that one, not that that one was the publisher's. A static ELF, no archive.
if [ ! -x "$TOOLS/cvc4-$CVC4_TAG/cvc4" ]; then
  echo "=== fetching cvc4 $CVC4_TAG ==="
  mkdir -p "$TOOLS/cvc4-$CVC4_TAG"
  fetch "https://github.com/CVC4/CVC4-archived/releases/download/$CVC4_TAG/$CVC4_ASSET" "$TOOLS/cvc4-$CVC4_TAG/cvc4" "$CVC4_SHA256"
  chmod +x "$TOOLS/cvc4-$CVC4_TAG/cvc4"
fi
ln -sf "$TOOLS/cvc4-$CVC4_TAG/cvc4" "$TOOLS/bin/cvc4"
echo "cvc4:  $("$TOOLS/bin/cvc4" --version | head -n 1)"

# ---- z3 (required; reused, not fetched) ----
Z3="$HOME/.local/share/uv/tools/halmos/bin/z3"
[ -x "$Z3" ] || Z3="$(command -v z3 || true)"
if [ -z "$Z3" ]; then
  echo "no z3 found. Install halmos (uv tool install halmos), which ships one, or put z3 on PATH." >&2
  exit 1
fi
ln -sf "$Z3" "$TOOLS/bin/z3"
echo "z3:    $("$TOOLS/bin/z3" --version)"

# ---- prover source, pinned; a failed fetch stops here with git's own reason ----
if [ ! -d "$SRC/.git" ]; then
  echo "=== cloning CertoraProver ==="
  git clone https://github.com/Certora/CertoraProver.git "$SRC"
fi
has_commit "$SRC" "$PROVER_COMMIT" || git -C "$SRC" fetch --quiet --depth 1 origin "$PROVER_COMMIT"
git -C "$SRC" checkout --quiet "$PROVER_COMMIT"
GRAPHCORE_COMMIT="$(git -C "$SRC" ls-tree HEAD scripts/graphcore | cut -d' ' -f3 | cut -f1)"
if [ ! -d "$SRC/scripts/graphcore/.git" ]; then
  rm -rf "$SRC/scripts/graphcore"
  git clone --quiet https://github.com/Certora/graphcore.git "$SRC/scripts/graphcore"
fi
has_commit "$SRC/scripts/graphcore" "$GRAPHCORE_COMMIT" || git -C "$SRC/scripts/graphcore" fetch --quiet origin
git -C "$SRC/scripts/graphcore" checkout --quiet "$GRAPHCORE_COMMIT"
echo "prover: $PROVER_COMMIT (graphcore $GRAPHCORE_COMMIT)"

# ---- build, skipped when out/ already holds this commit's build ----
export JAVA_HOME="$JDK"
export CERTORA
export PATH="$JDK/bin:$CERTORA:$TOOLS/bin:$PATH"
BUILT="$CERTORA/.built-commit"
if [ -f "$CERTORA/emv.jar" ] && [ "$(cat "$BUILT" 2>/dev/null || true)" = "$PROVER_COMMIT" ]; then
  echo "=== prover already built at $PROVER_COMMIT -- skipping gradlew ==="
else
  echo "=== gradlew assemble (minutes, first run downloads gradle + deps) ==="
  rm -f "$BUILT"
  "$SRC/gradlew" -p "$SRC" assemble --console=plain
  echo "$PROVER_COMMIT" >"$BUILT"
fi

# ---- certoraRun.py's python deps, in a venv ----
command -v uv >/dev/null 2>&1 || { echo "uv not on PATH; it is needed for the CLI venv." >&2; exit 1; }
[ -x "$TOOLS/venv/bin/python" ] || uv venv --quiet "$TOOLS/venv"
uv pip install --quiet --python "$TOOLS/venv/bin/python" -r "$SRC/scripts/certora_cli_requirements.txt"

if [ ! -f "$CERTORA/emv.jar" ]; then
  echo "BUILD FINISHED BUT $CERTORA/emv.jar IS MISSING -- a local run is impossible." >&2
  exit 1
fi
echo "OK: local prover at $CERTORA (emv.jar present). Run specs with scripts/certora-run.sh."
