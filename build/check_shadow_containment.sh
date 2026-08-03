#!/usr/bin/env bash
# R2-WP07 — controls for the shadow's containment claim.
#
# Readiness rule G2: an instrument proves itself before it measures anything, and
# a control that only knows how to refuse is indistinguishable from one that is
# broken. So this drives `ops/canary/containment_check.py` with fixtures: a
# POSITIVE that must stay green, and five MUTANTS that must each go red for the
# reason named.
#
# The claim under test is the only one in the shadow harness that survives being
# moved to another topology — *every request the edge served is one the shadow
# sent*. K1b (peer observation) and K2 (loopback publish) are a fence around one
# host; K3 is evidence about the run.
#
# The mutants are the ways a reconciliation stops reconciling:
#
#   M1 the edge served a route the driver never sent  — the shape of a real user
#   M2 the edge served MORE of a route than was sent  — the same leak, partial
#   M3 the access log is empty while the driver sent  — "no remainder" is true of
#                                                       a file nobody wrote
#   M4 the access log holds an unparsable line        — a request the check
#                                                       cannot read is one it
#                                                       cannot account for
#   M5 the access log is missing entirely             — unproven, never proven
set -euo pipefail

DRUSE_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
CHECK="$DRUSE_ROOT/ops/canary/containment_check.py"
WORK="$(mktemp -d -t druse-shadow-controls-XXXXXXXX)"
trap 'rm -rf "$WORK"' EXIT

fail() { echo "SHADOW-CONTAINMENT-FAIL: $*" >&2; exit 1; }

test -f "$CHECK" || fail "ops/canary/containment_check.py is missing"
test -f "$DRUSE_ROOT/ops/canary/run-shadow.sh" || fail "ops/canary/run-shadow.sh is missing"
test -f "$DRUSE_ROOT/ops/canary/shadow_replay.py" || fail "ops/canary/shadow_replay.py is missing"
test -f "$DRUSE_ROOT/ops/canary/shadow-profile.md" || fail "the shadow profile is missing; a declared shape with no declaration is an invented one"

cat >"$WORK/driver.json" <<'JSON'
{
 "requests_total": 10,
 "requests_by_route": {"GET /ok": 7, "POST /body": 3},
 "responses_delivered_to_a_user": 0
}
JSON

emit_log() { # count route file
  local n="$1" route="$2" file="$3"
  local method="${route%% *}" uri="${route#* }"
  for _ in $(seq 1 "$n"); do
    printf '{"request":{"method":"%s","uri":"%s"},"status":200}\n' "$method" "$uri" >>"$file"
  done
}

# --- POSITIVE ----------------------------------------------------------------
: >"$WORK/access.json"
emit_log 7 "GET /ok" "$WORK/access.json"
emit_log 3 "POST /body" "$WORK/access.json"
emit_log 40 "GET /ready" "$WORK/access.json"   # the declared proxy-internal probes
if ! python3 "$CHECK" "$WORK/driver.json" "$WORK/access.json" >"$WORK/p.txt" 2>&1; then
  cat "$WORK/p.txt" >&2
  fail "POSITIVE went red: a run whose accounting closes must prove containment"
fi
grep -q '^containment=proven$' "$WORK/p.txt" || fail "POSITIVE did not report containment=proven"
grep -q '^proxy_internal_health_probes=40$' "$WORK/p.txt" ||
  fail "POSITIVE did not count the declared /ready probes separately; an exemption that is not counted is one nobody can audit"

expect_red() { # label file needle
  grep -qE '^containment=(broken|unproven)$' "$2" || fail "$1 did not go red"
  grep -q "$3" "$2" || fail "$1 went red for the wrong reason: expected '$3'"
}

# --- M1: a route the driver never sent ---------------------------------------
cp "$WORK/access.json" "$WORK/m1.json"
emit_log 1 "GET /whoami" "$WORK/m1.json"
python3 "$CHECK" "$WORK/driver.json" "$WORK/m1.json" >"$WORK/m1.txt" 2>&1 || true
expect_red "M1 (route never sent)" "$WORK/m1.txt" "UNACCOUNTED GET /whoami delta=1"

# --- M2: more of a route than was sent ---------------------------------------
cp "$WORK/access.json" "$WORK/m2.json"
emit_log 2 "GET /ok" "$WORK/m2.json"
python3 "$CHECK" "$WORK/driver.json" "$WORK/m2.json" >"$WORK/m2.txt" 2>&1 || true
expect_red "M2 (more served than sent)" "$WORK/m2.txt" "UNACCOUNTED GET /ok delta=2"

# --- M3: the driver sent and the log is empty --------------------------------
: >"$WORK/m3.json"
python3 "$CHECK" "$WORK/driver.json" "$WORK/m3.json" >"$WORK/m3.txt" 2>&1 || true
expect_red "M3 (empty access log)" "$WORK/m3.txt" "the proxy logged none"

# --- M4: an unparsable line --------------------------------------------------
cp "$WORK/access.json" "$WORK/m4.json"
echo '{this is not json' >>"$WORK/m4.json"
python3 "$CHECK" "$WORK/driver.json" "$WORK/m4.json" >"$WORK/m4.txt" 2>&1 || true
expect_red "M4 (unparsable log line)" "$WORK/m4.txt" "could not be read"

# --- M5: no access log at all ------------------------------------------------
python3 "$CHECK" "$WORK/driver.json" "$WORK/absent.json" >"$WORK/m5.txt" 2>&1 || true
expect_red "M5 (missing access log)" "$WORK/m5.txt" "proxy_access_log=MISSING"

# --- The harness must not quietly lose its containment assertions -------------
# Each of these is a line whose deletion would leave the script running and the
# claim unmade, which is the failure mode that is hardest to notice.
RUNNER="$DRUSE_ROOT/ops/canary/run-shadow.sh"
grep -q 'p "127.0.0.1:\$PROXY_PORT:\$PROXY_PORT"' "$RUNNER" ||
  fail "K2 is gone: the pinned proxy is no longer published to loopback only, and docker's default publish writes an iptables rule that bypasses a host firewall"
grep -q 'k1b_peer_observation=' "$RUNNER" ||
  fail "K1b is gone: nothing observes who actually connected to the candidate, and the framework cannot bind to loopback to make that unnecessary"
grep -q 'containment_check.py' "$RUNNER" ||
  fail "K3 is gone: the run would produce evidence with no reconciliation in it"

# --- The K1 finding must stay a finding ---------------------------------------
# `web.serve` takes no bind address. If that ever changes, the shadow should stop
# working around it — and this control is where the change gets noticed, because
# nobody re-reads a comment in a harness.
grep -qE '^serve :: proc\(a: \^App, port: int\)' "$DRUSE_ROOT/web/serve.odin" ||
  fail "web.serve's signature changed. R2-WP07 records that a Druse application cannot be told to listen on loopback only, and the shadow's containment is built around that. Re-read ops/canary/shadow-profile.md §3 before changing this line."

echo "SHADOW-CONTAINMENT-OK: positive green, five mutants red for their named reasons, three assertions pinned"
