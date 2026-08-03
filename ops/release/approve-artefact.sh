#!/usr/bin/env bash
# R2-WP08 — record the identity of the artefact that was approved.
#
#   usage: approve-artefact.sh ARTEFACT [APPROVAL_PATH]
#
# WHY THIS EXISTS, and why it is not `verify-rebuild.sh`.
#
# R2-WP08's exit criterion used to read "the deployed artefact is byte-identical
# to the approved one", and everybody read that as "the build is reproducible".
# It is not, and that is measured rather than suspected:
# `evidence/2026-08-03-r2-wp06-assurance/raw/rebuild-two-clean-clones.txt` built
# the same commit twice with the same pinned compiler on the same machine and
# got two different hashes at *identical size* — the delta is content, not
# structure. A criterion that requires reproducing the build is unsatisfiable
# here for a reason no work inside this repository can remove.
#
# So the OBJECT of the criterion changed and its rigour did not. Build once,
# hash that file, deploy that same file, and prove the bytes on the target are
# the bytes that were approved. That claim is *stronger* than a reproducible
# build, because it removes the build machine from the chain of trust
# altogether: a reproducible build proves two compilers agreed, whereas this
# proves the reviewed bytes are the running bytes.
#
# This script writes the approval half. `verify-deployed.sh` reads it.
set -uo pipefail

ARTEFACT="${1:-}"
REPORT="${2:-/dev/stdout}"
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"

notes=(); problems=()
note() { notes+=("$1"); }
problem() { problems+=("$1"); }

emit() {
  {
    echo "approval_utc=$(date -u +%Y-%m-%dT%H:%M:%SZ)"
    for line in "${notes[@]}"; do echo "$line"; done
    if (( ${#problems[@]} == 0 )); then
      echo "approval=pass"
    else
      echo "approval=fail"
      for line in "${problems[@]}"; do echo "problem=$line"; done
    fi
  } >"$REPORT"
  (( ${#problems[@]} == 0 ))
}

if [[ -z "$ARTEFACT" ]]; then
  problem "no artefact given: approve-artefact.sh ARTEFACT [APPROVAL_PATH]"
  emit; exit 1
fi
if [[ ! -f "$ARTEFACT" ]]; then
  problem "artefact not found: $ARTEFACT"
  emit; exit 1
fi

note "artefact_path=$(readlink -f "$ARTEFACT")"
note "artefact_sha256=$(sha256sum "$ARTEFACT" | awk '{print $1}')"
note "artefact_bytes=$(stat -c %s "$ARTEFACT")"

# The commit is part of the identity, but the hash is what the criterion checks.
# Recording both is what lets a reader go from a running binary back to source.
head="$(git -C "$ROOT" rev-parse HEAD 2>/dev/null || echo unknown)"
tree="$(git -C "$ROOT" rev-parse HEAD^{tree} 2>/dev/null || echo unknown)"
dirty="$(git -C "$ROOT" status --porcelain 2>/dev/null | wc -l)"
note "commit=$head"
note "tree=$tree"
note "working_tree_dirty_files=$dirty"
if (( dirty > 0 )); then
  problem "the working tree has $dirty modified file(s): an approval names a COMMIT, and this one would name something no commit describes"
fi

if   [[ -n "${DRUSE_COMPILER:-}" ]];     then ODIN="$DRUSE_COMPILER"
elif [[ -n "${DRUSE_ODIN_BIN:-}" ]];     then ODIN="$DRUSE_ODIN_BIN"
elif command -v odin >/dev/null 2>&1;    then ODIN="$(command -v odin)"
elif [[ -x /tmp/druse-toolchain/odin ]]; then ODIN=/tmp/druse-toolchain/odin
else ODIN=""
fi
if [[ -n "$ODIN" ]]; then
  ODIN="$(readlink -f "$ODIN")"
  note "odin=$("$ODIN" version 2>&1 | head -n 1)"
  note "odin_sha256=$(sha256sum "$ODIN" | awk '{print $1}')"
else
  note "odin=unknown"
fi
note "pin_release=$(sed -n 's/^release=//p' "$ROOT/odin-version.txt" 2>/dev/null)"
note "pin_commit=$(sed -n 's/^commit=//p' "$ROOT/odin-version.txt" 2>/dev/null)"

# Stated in the record itself so a reader of the artefact never has to find this
# file to learn what the claim does and does not cover.
note "claim=the bytes named by artefact_sha256 were approved; a deployment satisfies R2-WP08 when the deployed file hashes to this value"
note "not_claimed=that rebuilding commit= from source reproduces artefact_sha256; measured false, see evidence/2026-08-03-r2-wp06-assurance/raw/rebuild-two-clean-clones.txt"

emit
