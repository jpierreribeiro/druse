#!/usr/bin/env bash
#
# The supervisor contract: the shipped systemd unit and every document that
# quotes it must agree.
#
# WHY THIS EXISTS, and it is the eighth entry in planning/diagnosability.md's
# table by a different route. `ops/deploy/druse.service` is a SHIPPED artefact —
# the operator copies it verbatim — and until 2026-07-31 nothing in the gate ever
# opened it. Ten documents drifted to `Restart=always` while the unit shipped
# `Restart=on-failure`, and `docs/operations.md` managed to contradict ITSELF,
# saying `on-failure` in its §1 excerpt and `always` in its checklist three
# hundred lines later. `planning/phase-8-wp102-spec.md` even asserted that its
# value "matches docs/operations.md", which was true of the wrong half.
#
# Nobody was careless. Nothing was asserting it. That is rule 4's corollary one
# layer out from CI: an artefact whose correctness no instrument checks will
# drift, and the drift is invisible precisely because every individual document
# reads plausibly.
#
# WHAT IT ASSERTS. The unit is the single source of truth. Every `Restart=` and
# `LimitMEMLOCK=` token in the tree's own prose must agree with it. LimitMEMLOCK
# is compared BY VALUE, not by string, because `64M` and `67108864` are the same
# limit and a string compare would report a false drift (that exact mismatch
# existed when this control was written).
#
# USAGE. Takes the tree root as $1 so the gate can run it twice: once against the
# repository, which must pass, and once against a MUTATED COPY, which must fail.
# Without that second run this control would be a positive case with a typo's
# worth of distance from proving nothing — how 0b1fea8 happened.

set -euo pipefail

ROOT="${1:-$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)}"
UNIT="$ROOT/ops/deploy/druse.service"

fail() {
  echo "ERROR: $*" >&2
  exit 1
}

test -f "$UNIT" ||
  fail "the canonical systemd unit ops/deploy/druse.service is missing; docs/operations.md tells the operator to copy it"

# --- what the unit actually ships -------------------------------------------

unit_value() {
  # Last assignment wins, matching systemd, and comment lines are ignored.
  sed -n "s/^[[:space:]]*$1=[[:space:]]*//p" "$UNIT" | tail -n 1
}

UNIT_RESTART="$(unit_value Restart)"
UNIT_MEMLOCK="$(unit_value LimitMEMLOCK)"

test -n "$UNIT_RESTART" ||
  fail "ops/deploy/druse.service declares no Restart=; a faulting handler aborts the process (ADR-020) and the supervisor restarting it IS the recovery mechanism"

# StartLimit* belong in [Unit]: systemd moved them out of [Service] in v230, and
# a copy left in [Service] is silently ignored — the exact shape of bug this
# whole control exists to catch, so it is asserted rather than trusted.
UNIT_SECTION_OF_STARTLIMIT="$(
  awk '
    /^\[/          { section = $0 }
    /^[[:space:]]*StartLimit(Burst|IntervalSec)=/ { print section }
  ' "$UNIT" | sort -u
)"
if test -n "$UNIT_SECTION_OF_STARTLIMIT"; then
  test "$UNIT_SECTION_OF_STARTLIMIT" = "[Unit]" ||
    fail "ops/deploy/druse.service puts StartLimitBurst/StartLimitIntervalSec in $UNIT_SECTION_OF_STARTLIMIT; systemd v230 moved them to [Unit] and silently IGNORES them anywhere else, so the crash-loop backstop the file documents would not exist"
fi

# --- normalise a byte quantity so 64M and 67108864 compare equal -------------

as_bytes() {
  local v="${1//[[:space:]]/}"
  local n="${v%[KkMmGgTt]}"
  case "$v" in
    *[Kk]) echo $(( n * 1024 )) ;;
    *[Mm]) echo $(( n * 1024 * 1024 )) ;;
    *[Gg]) echo $(( n * 1024 * 1024 * 1024 )) ;;
    *[Tt]) echo $(( n * 1024 * 1024 * 1024 * 1024 )) ;;
    infinity) echo infinity ;;
    *)     echo "$v" ;;
  esac
}

# --- every prose mention must agree ------------------------------------------
#
# Scanned: the tree's own documents and operational artefacts. Excluded:
# .claude/worktrees and bundle/ (copies of this tree, not this tree),
# release-candidate/ (a built artefact), and vendor/ (upstream's words).

mapfile -t SCAN < <(
  find "$ROOT" \
    \( -path "$ROOT/.claude" -o -path "$ROOT/bundle" -o -path "$ROOT/vendor" \
       -o -path "$ROOT/release-candidate" -o -path "$ROOT/.git" \
       -o -path "$ROOT/build" \) -prune -o \
    -type f \( -name "*.md" -o -name "*.service" -o -name "*.timer" \) -print |
  sort
)

DRIFT=""
for f in "${SCAN[@]}"; do
  test "$f" = "$UNIT" && continue

  # `Restart=` and not `RestartSec=`: the character after "Restart" decides.
  while IFS= read -r hit; do
    line="${hit%%:*}"
    value="$(printf '%s' "${hit#*:}" | sed -n 's/.*Restart=\([A-Za-z-]*\).*/\1/p')"
    test -n "$value" || continue
    test "$value" = "$UNIT_RESTART" && continue
    DRIFT="$DRIFT
  ${f#$ROOT/}:$line says Restart=$value"
  done < <(grep -n "Restart=" "$f" 2>/dev/null | grep -v "RestartSec=" || true)

  # LimitMEMLOCK, compared by value.
  while IFS= read -r hit; do
    line="${hit%%:*}"
    value="$(printf '%s' "${hit#*:}" | sed -n 's/.*LimitMEMLOCK=\([0-9]*[KkMmGgTt]\?\).*/\1/p')"
    test -n "$value" || continue
    test "$(as_bytes "$value")" = "$(as_bytes "$UNIT_MEMLOCK")" && continue
    DRIFT="$DRIFT
  ${f#$ROOT/}:$line says LimitMEMLOCK=$value ($(as_bytes "$value") bytes)"
  done < <(grep -n "LimitMEMLOCK=" "$f" 2>/dev/null || true)
done

if test -n "$DRIFT"; then
  fail "the shipped unit and the documents disagree about the supervisor contract.
ops/deploy/druse.service ships Restart=$UNIT_RESTART and LimitMEMLOCK=$UNIT_MEMLOCK ($(as_bytes "$UNIT_MEMLOCK") bytes).
These disagree:$DRIFT

The unit is the source of truth — the operator copies it verbatim. Change the
documents, or change the unit deliberately and let this control tell you every
document that has to move with it."
fi

echo "PASS: ops/deploy/druse.service ships Restart=$UNIT_RESTART, LimitMEMLOCK=$UNIT_MEMLOCK, and every document in the tree agrees"

# --- the OTHER shipped operational artefacts ---------------------------------
#
# `ops/ci/` is the self-hosted verifier: a systemd timer that runs this same gate
# every five minutes on a VPS. It is shipped, it is operational, and it was in
# exactly the position `ops/deploy/druse.service` was in before this file
# existed -- checked by nothing that runs.
#
# It was not unchecked by oversight, which is the interesting part. The checks
# below existed, in build/check_test.sh, which build/check.sh only parses
# because check_test.sh recurses into the gate. Same shape as the orphan
# detector: a real check, in a file nobody executes. Moved here, where the gate
# reaches it.

CI_DIR="$ROOT/ops/ci"
test -d "$CI_DIR" || fail "ops/ci is missing; the self-hosted verifier is part of the shipped topology"

for f in run.sh status.sh install-odin.sh; do
  test -f "$CI_DIR/$f" || fail "missing self-hosted verifier file: ops/ci/$f"
  bash -n "$CI_DIR/$f" || fail "ops/ci/$f does not parse; the VPS would run a broken verifier on its next tick"
done

# The verifier must build from a CLEAN WRITABLE COPY, not from the checkout it
# is watching -- otherwise a gate that mutates sources (every mutation control
# does) would race the working tree it is meant to be verifying.
grep -Fq 'cd "$DRUSE_CI_WORK"' "$CI_DIR/run.sh" ||
  fail "ops/ci/run.sh no longer builds from its clean writable archive; a verifier that runs in the watched tree races the mutations it is running"

# A oneshot must NOT carry Restart=: systemd would relaunch a verifier that has
# already reported, and the timer is what schedules it.
if test -f "$CI_DIR/druse-ci.service"; then
  grep -q '^Type=oneshot' "$CI_DIR/druse-ci.service" ||
    fail "ops/ci/druse-ci.service is no longer Type=oneshot; the timer schedules it, and a long-running verifier would overlap its own next tick"
  grep -q '^Restart=' "$CI_DIR/druse-ci.service" &&
    fail "ops/ci/druse-ci.service declares Restart=; it is a oneshot driven by druse-ci.timer, and restarting it would run the gate in a loop outside the schedule"
fi
test -f "$CI_DIR/druse-ci.timer" ||
  fail "ops/ci/druse-ci.timer is missing; without it druse-ci.service never runs and the self-hosted verifier is decoration"

echo "PASS: ops/ci ships a parseable verifier, building from a clean copy, driven by a timer rather than a restart"
