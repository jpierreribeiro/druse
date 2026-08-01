#!/usr/bin/env bash
# WP24 — the documentation controls, as one executable run.
#
# WP24 SHIPS NO SYMBOL, so its controls cannot be "mutate the code and watch a
# test go red". What it ships is TEACHING, and teaching fails in two ways: it
# can teach something the framework forbids, and it can quietly stop saying
# something that still matters. Both are probed here.
#
#   1  a `user_data` bag in an example      -> the guardrail scan MUST reject it
#   2  `use` AFTER the protected route      -> the example MUST fail loudly
#   3  the ownership table deleted          -> the docs gate MUST reject it
#   4  an ownership COLUMN dropped          -> the docs gate MUST reject it
#   5  the multi-server contract (R-10) gone-> the docs gate MUST reject it
#   5b the multi-server BOUND removed       -> the docs gate MUST reject it
#   6  POSITIVE: all seven examples still build and the docs gate is green
#
# CONTROL 2 IS THE ONE THAT MATTERS MOST. WP12 D-12.5 measured a mis-ordered
# auth program answering `200 OK` with the secret body to an unauthenticated
# caller. Example 06 teaches the correct order; this control re-creates the
# WRONG order and requires the framework to reject the program — so the example
# is teaching a rule the framework actually enforces, not a convention.
#
# CONTROL 6 IS THE POSITIVE HALF. Controls 3-5 are all satisfied by deleting
# the documentation entirely, and control 1 by having no examples at all.
set -euo pipefail

DRUSE_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

fail() {
  echo "WP24-CONTROL-FAIL: $*" >&2
  exit 1
}

DRUSE_W24_ODIN="${DRUSE_ODIN_BIN:-}"
if test -z "$DRUSE_W24_ODIN" && command -v odin >/dev/null 2>&1; then
  DRUSE_W24_ODIN="$(command -v odin)"
fi
if test -z "$DRUSE_W24_ODIN" && test -x /tmp/druse-toolchain/odin; then
  DRUSE_W24_ODIN=/tmp/druse-toolchain/odin
fi
if test -z "$DRUSE_W24_ODIN"; then
  echo "WP24 CONTROLS -> BLOCKED: no Odin toolchain found (set DRUSE_ODIN_BIN). NOTHING RAN." >&2
  exit 2
fi
# RESOLVE THE SYMLINK FIRST. `ODIN_ROOT` must be the directory holding `base/`
# and `core/`, and that is where the compiler LIVES — not where the name that
# reached it lives. A `~/.local/bin/odin` symlinking into an unpacked toolchain
# is the ordinary install, and taking the dirname of the link gave an ODIN_ROOT
# with no `base/`: the probe below died with "Cannot find the library collection
# 'base'" and SIGILL, reported here as "the probe program did not build" — a
# broken-environment message wearing a broken-code message's clothes. Every other
# control script in build/ already resolves the link; this one did not.
DRUSE_W24_ODIN="$(readlink -f "$DRUSE_W24_ODIN")"
DRUSE_W24_ODIN_DIR="$(cd "$(dirname "$DRUSE_W24_ODIN")" && pwd)"

DRUSE_W24_TMP="$(mktemp -d -t druse-wp24-controls-XXXXXXXX)"
trap 'rm -rf "$DRUSE_W24_TMP"' EXIT

assert_mutated() { # label file before-hash
  local after
  after="$(md5sum "$2" | cut -d' ' -f1)"
  test "$3" != "$after" ||
    fail "BROKEN PROBE ($1): the edit left ${2##*/} unchanged; this control would prove nothing"
}

# A full tree copy, because the docs gate and the examples gate both read the
# repository root rather than a package directory.
tree_copy() { # name
  local t="$DRUSE_W24_TMP/$1"
  mkdir -p "$t"
  cp -r "$DRUSE_ROOT/build" "$t/build"
  cp -r "$DRUSE_ROOT/docs" "$t/docs"
  cp -r "$DRUSE_ROOT/examples" "$t/examples"
  cp -r "$DRUSE_ROOT/web" "$t/web"
  cp -r "$DRUSE_ROOT/planning" "$t/planning"
  cp -r "$DRUSE_ROOT/tests" "$t/tests"
  cp -r "$DRUSE_ROOT/vendor" "$t/vendor"
  cp "$DRUSE_ROOT/README.md" "$t/README.md"
  cp "$DRUSE_ROOT/CHANGELOG.md" "$t/CHANGELOG.md"
  printf '%s' "$t"
}

# Every docs control asserts the UNMUTATED copy passes first, or a later
# rejection would prove nothing about the mutation.
assert_docs_green() { # tree label
  bash "$1/build/check_docs.sh" >/dev/null 2>&1 ||
    fail "BROKEN PROBE ($2): the unmutated copy does not pass the docs gate"
}

must_reject_docs() { # tree label expected-pattern
  local out
  if out="$(bash "$1/build/check_docs.sh" 2>&1)"; then
    echo "$out" >&2
    fail "control '$2' PASSED the docs gate; the documentation is unenforced"
  fi
  grep -qiE "$3" <<<"$out" ||
    { echo "$out" >&2; fail "control '$2' failed for the WRONG reason; expected /$3/"; }
  echo "CONTROL $2 -> REJECTED by the gate as required"
}

# --- 1. a `user_data` bag in an example --------------------------------------
# G-03: the request context is not an extension bag. An EXAMPLE teaching one
# would be the most effective way to spread the pattern the guardrail forbids.
T="$(tree_copy userdata)"
bash "$T/build/check_public_api.sh" >/dev/null 2>&1 ||
  fail "BROKEN PROBE (1: user_data): the unmutated copy does not pass the public-API checker"
H="$(md5sum "$T/web/context.odin" | cut -d' ' -f1)"
python3 - "$T/web/context.odin" <<'PYEOF'
import sys
p = sys.argv[1]
s = open(p).read()
old = "\toverlay:     Header_Pair,"
assert old in s, "pattern not found"
open(p, 'w').write(s.replace(old, "\tuser_data: rawptr,\n" + old, 1))
PYEOF
assert_mutated "user_data bag" "$T/web/context.odin" "$H"
if OUT="$(bash "$T/build/check_public_api.sh" 2>&1)"; then
  echo "$OUT" >&2
  fail "control '1: a user_data bag' PASSED the checker; G-03 is unenforced"
fi
grep -qiE 'untyped request-local storage|user_data' <<<"$OUT" ||
  { echo "$OUT" >&2; fail "control 1 failed for the wrong reason; expected the G-03 assertion"; }
echo "CONTROL 1: a user_data bag -> REJECTED by the gate as required"

# --- 2. `use` AFTER the protected route (the D-12.5 hazard) ------------------
# Example 06 teaches "the gate comes first". This control writes the WRONG
# order and requires the framework to REJECT the program at runtime — proving
# the example teaches an enforced rule rather than a convention.
#
# It is a BEHAVIOURAL probe: the mis-ordered program must answer 500 to the
# protected route rather than serving it.
mkdir -p "$DRUSE_W24_TMP/misordered/app" "$DRUSE_W24_TMP/misordered/vendor"
cp -r "$DRUSE_ROOT/web" "$DRUSE_W24_TMP/misordered/web"
cp -r "$DRUSE_ROOT/vendor/odin-http" "$DRUSE_W24_TMP/misordered/vendor/odin-http"
cat >"$DRUSE_W24_TMP/misordered/app/main.odin" <<'ODIN'
package main

import "core:os"
import web "druse:web"

// The D-12.5 shape: a protected route registered BEFORE its guard.
deny :: proc(ctx: ^web.Context) {
	web.unauthorized(ctx, "authentication required")
}

secret :: proc(ctx: ^web.Context) {
	web.text(ctx, .OK, "THE SECRET BODY")
}

main :: proc() {
	app := web.app()

	web.get(&app, "/admin", secret) // registered FIRST — the hazard
	web.use(&app, deny)             // too late to protect it

	res := web.test_request(&app, .GET, "/admin")

	// The framework must reject the whole application fail-closed. Serving the
	// route — with the secret body — is the measured Phase-1 defect this rule
	// exists to prevent.
	code := 0
	if res.status == .OK || res.body == "THE SECRET BODY" {
		code = 1
	} else if res.status != .Internal_Server_Error {
		code = 2
	}

	// Torn down explicitly rather than with `defer`: `os.exit` diverges, which
	// makes a trailing defer unreachable and is a COMPILE error in Odin.
	web.destroy(&app)
	os.exit(code)
}
ODIN
( cd "$DRUSE_W24_TMP/misordered" && env ODIN_ROOT="$DRUSE_W24_ODIN_DIR" \
    PATH="$DRUSE_W24_ODIN_DIR:/usr/bin:/bin" \
    "$DRUSE_W24_ODIN" build app "-collection:druse=$DRUSE_W24_TMP/misordered" \
    -out:misordered.bin >/dev/null 2>&1 ) ||
  fail "BROKEN PROBE (2: mis-ordered use): the probe program did not build"

# The diagnostic it prints is EXPECTED, so stderr is captured rather than shown.
if ! "$DRUSE_W24_TMP/misordered/misordered.bin" >/dev/null 2>&1; then
  case $? in
    1) fail "control '2: use after the protected route' SERVED the route; the D-12.5 authentication bypass is back" ;;
    2) fail "control '2: use after the protected route' answered something other than 500" ;;
    *) fail "control '2: use after the protected route' failed unexpectedly" ;;
  esac
fi
echo "CONTROL 2: use after the protected route -> the application is rejected fail-closed, as example 06 teaches"

# --- 3. the ownership table deleted ------------------------------------------
T="$(tree_copy notable)"
assert_docs_green "$T" "3: ownership table deleted"
H="$(md5sum "$T/docs/canonical-patterns.md" | cut -d' ' -f1)"
python3 - "$T/docs/canonical-patterns.md" <<'PYEOF'
import sys
p = sys.argv[1]
s = open(p).read()
old = "## Who owns what (the ownership table)"
assert old in s, "pattern not found"
open(p, 'w').write(s.replace(old, "## Some notes on memory", 1))
PYEOF
assert_mutated "ownership table deleted" "$T/docs/canonical-patterns.md" "$H"
must_reject_docs "$T" "3: the ownership table deleted" "ownership table"

# --- 4. one ownership COLUMN dropped -----------------------------------------
# The subtler regression: the table survives, but a row stops answering one of
# the four questions. "Who cleans up" is the one a reader most needs and the
# one most easily lost in an edit.
T="$(tree_copy nocolumn)"
assert_docs_green "$T" "4: ownership column dropped"
H="$(md5sum "$T/docs/canonical-patterns.md" | cut -d' ' -f1)"
python3 - "$T/docs/canonical-patterns.md" <<'PYEOF'
import sys
p = sys.argv[1]
s = open(p).read()
old = "| Value | Owner | Valid until | May it escape? | Who cleans up |"
new = "| Value | Owner | Valid until | May it escape? |"
assert old in s, "pattern not found"
open(p, 'w').write(s.replace(old, new, 1))
PYEOF
assert_mutated "ownership column dropped" "$T/docs/canonical-patterns.md" "$H"
must_reject_docs "$T" "4: an ownership column dropped" "Who cleans up|four"

# --- 5. the multi-server contract (R-10) deleted ------------------------------
# This control used to delete the SINGLE-server rule and require rejection. WP123
# made two servers in one process supported, so that mutation now weakens
# nothing — and a control that cannot fail is worse than none, because it reads
# as coverage. It is replaced by the successor claim rather than dropped.
#
# A capability that stops being written down is one the reader will not use; a
# capability written down without its LIMIT is one the reader will exceed. So
# there are two mutations here where there was one, and the second is the one
# that would have rotted quietly.
T="$(tree_copy nor10)"
assert_docs_green "$T" "5: R-10 deleted"
H="$(md5sum "$T/docs/canonical-patterns.md" | cut -d' ' -f1)"
python3 - "$T/docs/canonical-patterns.md" <<'PYEOF'
import sys
p = sys.argv[1]
s = open(p).read()
old = "## More than one server in a process"
assert old in s, "pattern not found"
s = s.replace(old, "## Serving", 1)
s = s.replace("two servers in one process", "this", 1)
s = s.replace("multiple servers", "this", 1)
open(p, 'w').write(s)
PYEOF
assert_mutated "R-10 deleted" "$T/docs/canonical-patterns.md" "$H"
must_reject_docs "$T" "5: the multi-server contract deleted" "multi-server|R-10"

# 5b. The contract kept, its BOUND removed. "Supported" with no ceiling stated
# reads as unlimited, and the seventeenth `serve` in a process returns without
# binding — a failure the reader was never told to expect.
T="$(tree_copy nobound)"
assert_docs_green "$T" "5b: the bound removed"
H="$(md5sum "$T/docs/canonical-patterns.md" | cut -d' ' -f1)"
python3 - "$T/docs/canonical-patterns.md" <<'PYEOF'
import sys
p = sys.argv[1]
s = open(p).read()
old = "at most sixteen concurrent servers"
assert old in s, "pattern not found"
open(p, 'w').write(s.replace(old, "as many concurrent servers as it needs", 1))
PYEOF
assert_mutated "the bound removed" "$T/docs/canonical-patterns.md" "$H"
must_reject_docs "$T" "5b: the multi-server bound removed" "BOUND|bound|sixteen"

# --- 6. POSITIVE control -----------------------------------------------------
# Controls 3-5 are all satisfied by deleting the documentation, and control 1
# by having no examples. This is the half that requires the real thing to be
# there and to work.
T="$(tree_copy positive)"
bash "$T/build/check_docs.sh" >/dev/null 2>&1 ||
  fail "POSITIVE control failed: the docs gate does not pass on the real tree"
env DRUSE_COMPILER="$DRUSE_W24_ODIN" bash "$T/build/check_examples.sh" >/dev/null 2>&1 ||
  fail "POSITIVE control failed: the seven examples do not build"

for DRUSE_NAME in 04-middleware 05-route-groups 06-authentication; do
  test -f "$DRUSE_ROOT/examples/$DRUSE_NAME/main.odin" ||
    fail "POSITIVE control failed: examples/$DRUSE_NAME is missing"
done

# The auth example must teach the revalidation COST, not hide it. A future edit
# that quietly drops the warning turns an honest example into a misleading one.
grep -qiE 'REVALIDATES|revalidat' "$DRUSE_ROOT/examples/06-authentication/main.odin" ||
  fail "POSITIVE control failed: example 06 no longer states that current_user revalidates the token"

echo "CONTROL 6: docs gate green, seven examples build, example 06 still states its cost -> GREEN as required [positive control]"

echo "PASS: all six WP24 documentation controls behaved as required"
