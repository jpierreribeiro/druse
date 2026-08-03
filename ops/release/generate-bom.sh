#!/usr/bin/env bash
# R2-WP06 — the bill of materials for a Druse candidate.
#
#   usage: generate-bom.sh [OUTPUT_PATH]
#
# WHY IT IS NOT CALLED AN SBOM. R2-WP06 asks for "inventário SPDX/CycloneDX se a
# ferramenta suportar Odin; caso contrário, produzir BOM versionada com hashes
# sem chamar o resultado de SBOM compatível". No SPDX or CycloneDX generator
# understands Odin packages, so emitting a file with their schema name on it
# would claim a compatibility that does not exist — a consumer's scanner would
# read it, find no known ecosystem, and report a clean bill for a project it
# never examined. That is worse than no document.
#
# So this is a plain, versioned, hashed inventory with its own schema name. It
# says what is in the tree and what it was built with, and nothing about
# vulnerability databases.
#
# WHAT IT DELIBERATELY DOES NOT CLAIM. The binary is not reproducible from this
# inventory: `ops/release/verify-rebuild.sh` measured two builds of one commit
# producing different bytes at identical size. Provenance here means "these
# sources, this compiler", not "these bytes".
set -uo pipefail

OUT="${1:-/dev/stdout}"
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
cd "$ROOT"

if   [[ -n "${DRUSE_COMPILER:-}" ]];     then ODIN="$DRUSE_COMPILER"
elif [[ -n "${DRUSE_ODIN_BIN:-}" ]];     then ODIN="$DRUSE_ODIN_BIN"
elif command -v odin >/dev/null 2>&1;    then ODIN="$(command -v odin)"
elif [[ -x /tmp/druse-toolchain/odin ]]; then ODIN=/tmp/druse-toolchain/odin
else ODIN=""
fi

{
  echo "druse_bom 1"
  echo "# NOT an SPDX or CycloneDX document. See the header of $0."
  echo "generated_utc=$(date -u +%Y-%m-%dT%H:%M:%SZ)"
  echo "commit=$(git rev-parse HEAD 2>/dev/null || echo unknown)"
  echo "tree=$(git rev-parse 'HEAD^{tree}' 2>/dev/null || echo unknown)"
  echo "working_tree_dirty_files=$(git status --porcelain 2>/dev/null | wc -l)"
  echo

  echo "## toolchain"
  echo "pin_release=$(sed -n 's/^release=//p' odin-version.txt)"
  echo "pin_commit=$(sed -n 's/^commit=//p' odin-version.txt)"
  echo "pin_asset=$(sed -n 's/^linux_amd64_asset=//p' odin-version.txt)"
  echo "pin_asset_sha256=$(sed -n 's/^linux_amd64_sha256=//p' odin-version.txt)"
  if [[ -n "$ODIN" ]]; then
    echo "resolved_odin=$(readlink -f "$ODIN")"
    echo "resolved_odin_sha256=$(sha256sum "$(readlink -f "$ODIN")" | awk '{print $1}')"
    echo "resolved_odin_version=$("$ODIN" version 2>&1 | head -n 1)"
  else
    echo "resolved_odin=absent"
  fi
  echo

  # The vendored dependency, and the size of the divergence. A BOM that named
  # the upstream project without saying how far the copy has drifted would
  # describe something nobody is running.
  echo "## vendored"
  echo "vendor_project=laytan/odin-http"
  echo "vendor_upstream_commit=$(sed -n 's/^| Commit | `\([0-9a-f]\+\)` |$/\1/p' vendor/odin-http/VENDOR.md 2>/dev/null | head -n 1)"
  # Counted the way build/check_vendor_policy.sh counts, deliberately. A BOM
  # that produced its own number would be a second source of truth, and the
  # first draft of this file did exactly that -- it read 45 against the gate's
  # 44 and the disagreement turned out to be a real defect in BOTH: a duplicated
  # ID, and a `DELETED` disposition the gate's pattern could not see.
  echo "vendor_patch_dispositions=$(grep -oE '^\| [0-9]+ \| .* \| .* \| \*\*(OFFER UPSTREAM|CARRY|APPEARS FIXED UPSTREAM|DELETED)' planning/vendor-policy.md | wc -l)"
  echo "vendor_in_source_markers=$(grep -rc 'DRUSE PATCH' vendor/odin-http/*.odin 2>/dev/null | awk -F: '{s+=$2} END {print s+0}')"
  echo

  # Content hashes, per file, over what a consumer would actually compile.
  # `git ls-files` rather than `find`: an untracked file is not part of the
  # candidate and must not silently enter its inventory.
  echo "## sources"
  for dir in web vendor ops/soak/soak-server; do
    n=$(git ls-files "$dir" | wc -l)
    h=$(git ls-files "$dir" | sort | xargs sha256sum 2>/dev/null | sha256sum | awk '{print $1}')
    echo "tree_${dir//\//_}_files=$n"
    echo "tree_${dir//\//_}_sha256=$h"
  done
  echo

  echo "## reproducibility"
  echo "byte_identical_rebuild=no"
  echo "note=measured by ops/release/verify-rebuild.sh: two builds of one commit"
  echo "note=with the pinned compiler differ in content at identical size."
  echo "note=Provenance here is 'these sources, this compiler', not 'these bytes'."
} >"$OUT"
