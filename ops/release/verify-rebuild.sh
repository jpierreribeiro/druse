#!/usr/bin/env bash
# R2-WP06 — rebuild the candidate from a CLEAN CLONE and compare the artefacts.
#
#   usage: verify-rebuild.sh [REPORT_PATH]
#
# WHY. The supply-chain half of R2-WP06 asks for "prova de rebuild a partir de
# clone limpo/toolchain pin" and "comparar hashes de dois builds no mesmo
# ambiente; se não reprodutíveis, registrar fontes de nondeterminismo".
#
# The second clause is the one that matters here, because this repository has
# already measured the answer and it is NO: `uruquim-byte-identity-is-not-testable`
# recorded that the toolchain is not reproducible — binary size quantises at
# about 4 KiB and `nm` is blind to inlined procedures. A gate that demanded byte
# identity would be red forever for a reason nobody could fix.
#
# So this script does not assert identity. It MEASURES the difference and
# records it, which is what an honest supply-chain claim looks like: two builds
# of the same commit, same toolchain, same flags, and the delta stated rather
# than hoped for. A release note can then say what it can actually support —
# "built from this commit with this compiler" — instead of "byte-identical",
# which would be false.
#
# Exit 0 means both builds succeeded and the comparison was recorded. It does
# NOT mean the bytes matched.
set -uo pipefail

REPORT="${1:-/dev/stdout}"
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
WORK="$(mktemp -d -t druse-rebuild-XXXXXXXX)"
trap 'rm -rf "$WORK"' EXIT

notes=(); problems=()
note() { notes+=("$1"); }
problem() { problems+=("$1"); }

# The pinned compiler, by the same four-branch chain the gates use.
if   [[ -n "${DRUSE_COMPILER:-}" ]];   then ODIN="$DRUSE_COMPILER"
elif [[ -n "${DRUSE_ODIN_BIN:-}" ]];   then ODIN="$DRUSE_ODIN_BIN"
elif command -v odin >/dev/null 2>&1;  then ODIN="$(command -v odin)"
elif [[ -x /tmp/druse-toolchain/odin ]]; then ODIN=/tmp/druse-toolchain/odin
else
  problem "no Odin compiler: set DRUSE_ODIN_BIN or put odin on PATH"
  printf 'rebuild=fail\nproblem=%s\n' "${problems[0]}" >"$REPORT"
  exit 1
fi
ODIN="$(readlink -f "$ODIN")"
ODIN_ROOT_DIR="$(cd "$(dirname "$ODIN")" && pwd)"

head="$(git -C "$ROOT" rev-parse HEAD 2>/dev/null || echo unknown)"
dirty="$(git -C "$ROOT" status --porcelain 2>/dev/null | wc -l)"
note "commit=$head"
note "working_tree_dirty_files=$dirty"
note "odin=$("$ODIN" version 2>&1 | head -n 1)"
note "odin_sha256=$(sha256sum "$ODIN" | awk '{print $1}')"
note "pin_release=$(sed -n 's/^release=//p' "$ROOT/odin-version.txt")"
note "pin_commit=$(sed -n 's/^commit=//p' "$ROOT/odin-version.txt")"
if (( dirty > 0 )); then
  problem "the working tree has $dirty modified file(s): a rebuild claim is about a COMMIT, and this one would describe something no commit names"
fi

# Two clean clones of the same commit. A clone rather than a copy so nothing
# untracked — a stale binary, an editor swapfile — can differ between them.
build_one() { # dest-label -> prints sha256, or empty on failure
  local label="$1"
  local dir="$WORK/$label"
  git clone -q --depth 1 --no-local "file://$ROOT" "$dir" 2>/dev/null || {
    echo ""; return 1
  }
  ( cd "$dir" && git checkout -q "$head" 2>/dev/null ) || true
  env ODIN_ROOT="$ODIN_ROOT_DIR" "$ODIN" build "$dir/ops/soak/soak-server" \
    -collection:druse="$dir" -o:speed -out:"$WORK/$label.bin" \
    >"$WORK/$label.log" 2>&1 || { echo ""; return 1; }
  sha256sum "$WORK/$label.bin" | awk '{print $1}'
}

a="$(build_one a)"
b="$(build_one b)"
if [[ -z "$a" || -z "$b" ]]; then
  problem "a clean-clone rebuild did not produce a binary; see the build logs"
else
  note "build_a_sha256=$a"
  note "build_b_sha256=$b"
  note "build_a_bytes=$(stat -c %s "$WORK/a.bin")"
  note "build_b_bytes=$(stat -c %s "$WORK/b.bin")"
  if [[ "$a" == "$b" ]]; then
    note "byte_identical=yes"
  else
    # Recorded, not failed. See the header.
    note "byte_identical=no"
    note "size_delta_bytes=$(( $(stat -c %s "$WORK/a.bin") - $(stat -c %s "$WORK/b.bin") ))"
    note "nondeterminism=the pinned toolchain does not produce byte-identical output for identical input; this is measured, not assumed, and the release claim is 'built from this commit with this compiler' rather than 'byte-identical'"
  fi
fi

{
  echo "rebuild_utc=$(date -u +%Y-%m-%dT%H:%M:%SZ)"
  for line in "${notes[@]}"; do echo "$line"; done
  if (( ${#problems[@]} == 0 )); then
    echo "rebuild=pass"
  else
    echo "rebuild=fail"
    for line in "${problems[@]}"; do echo "problem=$line"; done
  fi
} >"$REPORT"

(( ${#problems[@]} == 0 ))
