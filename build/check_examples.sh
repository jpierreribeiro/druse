#!/usr/bin/env bash
# WP10 — the example compile gate.
#
# The three Phase-1 examples are part of the compatibility contract
# (`knowledge-base/01-architecture-spec.md` §AI-Friendly API Rules: "Public
# examples ... compile in the mandatory verification gate"). If an example
# stops compiling, the documentation that teaches it is wrong, and this fails.
#
# Examples are COMPILED, never RUN: `web.serve` blocks forever by design.
#
# Every binary goes into one `mktemp -d`, removed on exit even when a build
# fails, so a red gate can never leave an ELF inside `examples/` or the
# repository root.
set -euo pipefail

URUQUIM_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
URUQUIM_EXAMPLES="$URUQUIM_ROOT/examples"

fail() {
  echo "EXAMPLES-FAIL: $*" >&2
  exit 1
}

test -n "${URUQUIM_COMPILER:-}" ||
  fail "URUQUIM_COMPILER is not set; run this through build/check.sh"
test -x "$URUQUIM_COMPILER" || fail "compiler is not executable: $URUQUIM_COMPILER"
URUQUIM_COMPILER_DIR="$(cd "$(dirname "$URUQUIM_COMPILER")" && pwd)"

# ---------------------------------------------------------------------------
# 1. The example set is EXACT.
#
# `examples/` also holds the throwaway prototypes from WP0 (`01-api-shape` and
# friends) that `experiments/run_checks.sh` owns. The Phase-1 application
# examples are exactly these three directories, and the gate names them so a
# deleted or renamed example is a failure rather than a silent gap.
# ---------------------------------------------------------------------------
URUQUIM_EXPECTED_EXAMPLES="01-hello-world
02-json-api
03-route-params
04-middleware
05-route-groups
06-authentication
07-app-state
08-table-stakes
09-graceful-shutdown
10-config-and-health
11-clean-layers"

test -d "$URUQUIM_EXAMPLES" || fail "examples/ does not exist"

for URUQUIM_NAME in $URUQUIM_EXPECTED_EXAMPLES; do
  test -d "$URUQUIM_EXAMPLES/$URUQUIM_NAME" ||
    fail "examples/$URUQUIM_NAME/ is missing; the examples are a contract (WP10 D3, extended by WP24 and WP37)"
  test -f "$URUQUIM_EXAMPLES/$URUQUIM_NAME/main.odin" ||
    fail "examples/$URUQUIM_NAME/main.odin is missing; each example is a self-contained program"
done

# ---------------------------------------------------------------------------
# 2. Examples use the PUBLIC surface only.
#
# An example that reached into the machinery would teach a path applications
# must never take, and would quietly make the "34 symbols are enough" claim
# false.
# ---------------------------------------------------------------------------
for URUQUIM_NAME in $URUQUIM_EXPECTED_EXAMPLES; do
  URUQUIM_SRC="$URUQUIM_EXAMPLES/$URUQUIM_NAME/main.odin"
  URUQUIM_CODE="$(sed -E 's://.*$::' "$URUQUIM_SRC")"

  if grep -nE '"uruquim:web/testing"|"uruquim:web/internal|"uruquim:vendor' <<<"$URUQUIM_CODE"; then
    fail "examples/$URUQUIM_NAME imports test machinery, an internal package, or the backend"
  fi

  # Future-phase vocabulary must not appear in a Phase-1 example (AMEND-4).
  # WP24: `use`/`next` (WP17), `router`/`mount` (WP18), `header`/`bearer_token`
  # (WP19), `logger` (WP22) and `request_id` (WP23) are RATIFIED application
  # symbols and left this list as they shipped — examples 04-06 exist to teach
  # them. WP37 removed `web.state` and `web.app_with_state` for the same
  # reason, and example 07 exists to teach them. `web.group` stays FOREVER: ADR-024 rejects it in every phase, so it is
  # not deferred API, it is refused API.
  for URUQUIM_FUTURE in 'web\.group' \
    'web\.serve_with' 'web\.serve_transport' 'web\.body_limit' 'web\.bytes' \
    'web\.redirect' 'web\.conflict'; do
    if grep -nE "$URUQUIM_FUTURE" <<<"$URUQUIM_CODE"; then
      fail "examples/$URUQUIM_NAME uses future-phase API matching /$URUQUIM_FUTURE/ (AMEND-4)"
    fi
  done

  # A PROMISE IN A COMMENT IS STILL A PROMISE (G-08).
  #
  # The scan above deliberately reads code with comments stripped, because a
  # comment may legitimately NAME a future symbol to say it does not exist.
  # That blindness had a cost: WP24's auth example told readers that "typed
  # request-local storage" would arrive in Phase 3 and make `current_user` a
  # lookup — a feature no ADR has decided, and one research finding C-6 argues
  # against. It shipped, because the ban list only ever saw the code.
  #
  # An example's comments teach as loudly as its code. So the COMMENTS are
  # scanned too, for the one thing that actually went wrong: a promise that a
  # named future capability WILL arrive. Naming a thing to deny it stays legal;
  # scheduling it does not.
  URUQUIM_COMMENTS="$(grep -oE '//.*$' "$URUQUIM_SRC" || true)"
  if grep -nEi '(phase [3-5]|later phase|a future phase) (will|is going to|adds|brings|makes)' <<<"$URUQUIM_COMMENTS"; then
    fail "examples/$URUQUIM_NAME PROMISES a future capability in a comment (G-08). State a cost as permanent until an ADR decides otherwise; do not schedule features in teaching text."
  fi
  if grep -nEi 'until then|for now,? (this|the) (cost|limitation)' <<<"$URUQUIM_COMMENTS"; then
    fail "examples/$URUQUIM_NAME implies a limitation is temporary ('until then'). If no ADR has decided the fix, say the cost is permanent until one does (G-08)."
  fi

  # The canonical call-site rules the examples exist to teach.
  if grep -nE 'or_else[[:space:]]*\{' <<<"$URUQUIM_CODE"; then
    fail "examples/$URUQUIM_NAME uses an 'or_else { ... }' block, which is not valid Odin"
  fi
  if grep -nE 'web\.(ok|created|json)\([^,]+,[[:space:]]*&' <<<"$URUQUIM_CODE"; then
    fail "examples/$URUQUIM_NAME passes a POINTER payload; Phase-1 payloads are values (ADR-003)"
  fi
  if grep -nE '\.(Get|Post|Put|Patch|Delete)\b' <<<"$URUQUIM_CODE"; then
    fail "examples/$URUQUIM_NAME uses a mixed-case method member; Method members are UPPERCASE"
  fi
  grep -qE '^package main$' <<<"$URUQUIM_CODE" ||
    fail "examples/$URUQUIM_NAME is not 'package main'"
  grep -qE 'web\.destroy\(&app\)' <<<"$URUQUIM_CODE" ||
    fail "examples/$URUQUIM_NAME never destroys its App"
done

# ---------------------------------------------------------------------------
# 3. Compile each example. Binaries live in a temp directory only.
# ---------------------------------------------------------------------------
URUQUIM_BIN_TMP="$(mktemp -d -t uruquim-examples-XXXXXXXX)"
trap 'rm -rf "$URUQUIM_BIN_TMP"' EXIT

for URUQUIM_NAME in $URUQUIM_EXPECTED_EXAMPLES; do
  echo "--- example: $URUQUIM_NAME (odin build) ---"
  env ODIN_ROOT="$URUQUIM_COMPILER_DIR" PATH="$URUQUIM_COMPILER_DIR:/usr/bin:/bin" \
    "$URUQUIM_COMPILER" build "$URUQUIM_EXAMPLES/$URUQUIM_NAME" \
    "-collection:uruquim=$URUQUIM_ROOT" \
    -out:"$URUQUIM_BIN_TMP/$URUQUIM_NAME" ||
    fail "examples/$URUQUIM_NAME did not compile"
done

URUQUIM_TOTAL=0
for URUQUIM_NAME in $URUQUIM_EXPECTED_EXAMPLES; do
  URUQUIM_SIZE="$(stat -c%s "$URUQUIM_BIN_TMP/$URUQUIM_NAME")"
  URUQUIM_TOTAL=$((URUQUIM_TOTAL + URUQUIM_SIZE))
  echo "example $URUQUIM_NAME -> $URUQUIM_SIZE bytes"
done
echo "examples total: $URUQUIM_TOTAL bytes (built in $URUQUIM_BIN_TMP, removed on exit)"

# 4. No example binary may be left in the working tree.
if find "$URUQUIM_EXAMPLES" -type f -perm -u+x ! -name '*.odin' ! -name '*.md' -print -quit | grep -q .; then
  fail "an executable was left inside examples/; example binaries belong in a temp directory"
fi

rm -rf "$URUQUIM_BIN_TMP"
trap - EXIT

echo "PASS: the examples compile and use only the public surface"
