#!/usr/bin/env bash
# R1-WP06 — clean-candidate deploy, crash/restart, drain and atomic rollback.
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
TODAY="$(date -u +%F)"
OUTPUT="$ROOT/evidence/${TODAY}-r1-pilot-exercise"
RUN_FULL_GATE=1
ALLOW_DIRTY=0

usage() {
  echo "usage: $0 [--output DIR] [--skip-full-gate] [--dev-allow-dirty]" >&2
  exit 2
}
while test "$#" -gt 0; do
  case "$1" in
    --output) test "$#" -ge 2 || usage; OUTPUT=$2; shift 2 ;;
    --skip-full-gate) RUN_FULL_GATE=0; shift ;;
    --dev-allow-dirty) ALLOW_DIRTY=1; shift ;;
    *) usage ;;
  esac
done

fail() { echo "R1-PILOT-FAIL: $*" >&2; exit 1; }
test "$ALLOW_DIRTY" -eq 1 || test -z "$(git -C "$ROOT" status --porcelain)" ||
  fail "candidate working tree is dirty; commit before generating evidence"
test ! -e "$OUTPUT" || fail "output already exists: $OUTPUT"

for cmd in odin git docker openssl curl python3 systemctl systemd-run coredumpctl sha256sum; do
  command -v "$cmd" >/dev/null || fail "required command missing: $cmd"
done
systemctl --user is-system-running >/dev/null 2>&1 || fail "user systemd is unavailable"

# shellcheck disable=SC1091
. "$ROOT/ops/proxy/caddy/image.env"
docker image inspect "$DRUSE_CADDY_IMAGE" >/dev/null 2>&1 ||
  fail "pinned Caddy image is absent: $DRUSE_CADDY_IMAGE"

CANDIDATE_COMMIT="$(git -C "$ROOT" rev-parse HEAD)"
CANDIDATE_TREE="$(git -C "$ROOT" rev-parse HEAD^{tree})"
PREVIOUS_COMMIT="$(git -C "$ROOT" rev-parse HEAD^)"
PREVIOUS_TREE="$(git -C "$ROOT" rev-parse HEAD^^{tree})"
ODIN_BIN="${DRUSE_ODIN_BIN:-$(command -v odin)}"
ORIGIN_PORT=22141
PROXY_PORT=22453
UNIT="druse-r1-pilot-$BASHPID"
CONTAINER="druse-r1-pilot-proxy-$BASHPID"
WORK="$(mktemp -d -t druse-r1-pilot-XXXXXXXX)"
RELEASES="$WORK/releases"
CURRENT="$RELEASES/current"
STATE="$WORK/state"
CERTS="$WORK/certs"
PROXY_LOGS="$WORK/proxy-logs"
CADDY_RUNNING=0
UNIT_CREATED=0
CAMPAIGN_COMPLETE=0

cleanup() {
  if test "$CAMPAIGN_COMPLETE" -eq 0 && test -d "$OUTPUT/raw" && test "$UNIT_CREATED" -eq 1; then
    journalctl --user -u "$UNIT.service" --utc --output=short-iso-precise --no-pager \
      > "$OUTPUT/raw/systemd-journal.failure.txt" 2>&1 || true
    systemctl --user show "$UNIT.service" -p LoadState -p ActiveState -p SubState \
      -p Result -p NRestarts -p MainPID -p ExecMainCode -p ExecMainStatus \
      > "$OUTPUT/raw/systemd-failure.txt" 2>&1 || true
  fi
  if test "$CADDY_RUNNING" -eq 1; then
    docker rm -f "$CONTAINER" >/dev/null 2>&1 || true
  fi
  if test "$UNIT_CREATED" -eq 1; then
    systemctl --user stop "$UNIT.service" >/dev/null 2>&1 || true
    systemctl --user reset-failed "$UNIT.service" >/dev/null 2>&1 || true
  fi
  if test -d "$WORK/previous-source/.git" || test -f "$WORK/previous-source/.git"; then
    git -C "$ROOT" worktree remove --force "$WORK/previous-source" >/dev/null 2>&1 || true
  fi
  if test "${DRUSE_KEEP_TMP:-0}" = 1; then
    echo "R1 pilot work retained: $WORK" >&2
  else
    rm -rf "$WORK"
  fi
}
trap cleanup EXIT INT TERM
mkdir -p "$RELEASES" "$STATE" "$CERTS" "$PROXY_LOGS"

timeline() {
  printf '%s\t%s\n' "$(date -u +%FT%T.%3NZ)" "$1" >> "$WORK/timeline.tsv"
}
timeline "campaign-start candidate=$CANDIDATE_COMMIT previous=$PREVIOUS_COMMIT"

if test "$RUN_FULL_GATE" -eq 1; then
  timeline "full-gate-start"
  if ! bash "$ROOT/build/check.sh" >"$WORK/full-gate.log" 2>&1; then
    tail -n 80 "$WORK/full-gate.log" >&2
    fail "full gate failed for candidate $CANDIDATE_COMMIT"
  fi
  grep -Fq 'PASS: the gate left no test-runner binary in the working tree' "$WORK/full-gate.log" ||
    fail "full gate log lacks its terminal success marker"
  timeline "full-gate-pass"
else
  echo "SKIPPED by --skip-full-gate" > "$WORK/full-gate.log"
  timeline "full-gate-skipped"
fi

# Check out the actual parent commit; the rollback target is not a second build
# of HEAD and not a fabricated copy of the candidate. `git archive` is
# deliberately unusable here because this repository export-ignores tests/ and
# ops/ from release tarballs.
PREVIOUS_SOURCE="$WORK/previous-source"
git -C "$ROOT" worktree add --detach "$PREVIOUS_SOURCE" "$PREVIOUS_COMMIT" >/dev/null

mkdir -p "$RELEASES/previous" "$RELEASES/candidate"
"$ODIN_BIN" build "$PREVIOUS_SOURCE/tests/r1-pilot-deployment/server" \
  "-collection:druse=$PREVIOUS_SOURCE" -o:speed \
  -define:R1_PILOT_RELEASE=previous -out:"$RELEASES/previous/app"
"$ODIN_BIN" build "$ROOT/tests/r1-pilot-deployment/server" \
  "-collection:druse=$ROOT" -o:speed \
  -define:R1_PILOT_RELEASE=candidate -out:"$RELEASES/candidate/app"

make_bundle() {
  local id=$1 source=$2 commit=$3 tree=$4
  local bundle="$RELEASES/$id"
  cp "$source/ops/deploy/runtime-limits.example" "$bundle/runtime-limits"
  cp "$source/ops/deploy/pilot-profile.env" "$bundle/pilot-profile"
  cp "$source/ops/deploy/check-runtime-limits.sh" "$bundle/check-runtime-limits.sh"
  cp "$source/ops/proxy/caddy/pilot.Caddyfile" "$bundle/Caddyfile"
  sed -i "s|DRUSE_SPOOL_DIR=/var/lib/druse|DRUSE_SPOOL_DIR=$STATE|" "$bundle/runtime-limits"
  sed -i "s|DRUSE_READ_WRITE_PATHS=/var/lib/druse|DRUSE_READ_WRITE_PATHS=$STATE|" "$bundle/runtime-limits"
  sed -i "s/DRUSE_BUNDLE_ID:unconfigured/DRUSE_BUNDLE_ID:$id/" "$bundle/Caddyfile"
  printf 'release=%s\ncommit=%s\ntree=%s\n' "$id" "$commit" "$tree" > "$bundle/IDENTITY"
  chmod 0555 "$bundle/app" "$bundle/check-runtime-limits.sh"
  (
    cd "$bundle"
    sha256sum app runtime-limits pilot-profile check-runtime-limits.sh Caddyfile IDENTITY > SHA256SUMS
    sha256sum -c SHA256SUMS >/dev/null
  )
  chmod 0444 "$bundle/runtime-limits" "$bundle/pilot-profile" "$bundle/Caddyfile" \
    "$bundle/IDENTITY" "$bundle/SHA256SUMS"
}
make_bundle previous "$PREVIOUS_SOURCE" "$PREVIOUS_COMMIT" "$PREVIOUS_TREE"
make_bundle candidate "$ROOT" "$CANDIDATE_COMMIT" "$CANDIDATE_TREE"

PREVIOUS_BINARY_SHA="$(sha256sum "$RELEASES/previous/app" | awk '{print $1}')"
CANDIDATE_BINARY_SHA="$(sha256sum "$RELEASES/candidate/app" | awk '{print $1}')"
test "$PREVIOUS_BINARY_SHA" != "$CANDIDATE_BINARY_SHA" || fail "previous and candidate binaries are identical"
PREVIOUS_CONFIG_SHA="$(sha256sum "$RELEASES/previous/Caddyfile" | awk '{print $1}')"
CANDIDATE_CONFIG_SHA="$(sha256sum "$RELEASES/candidate/Caddyfile" | awk '{print $1}')"
test "$PREVIOUS_CONFIG_SHA" != "$CANDIDATE_CONFIG_SHA" || fail "previous and candidate proxy configs are identical"

switch_bundle() {
  local id=$1
  test -d "$RELEASES/$id" || fail "unknown release bundle: $id"
  (cd "$RELEASES" && ln -s "$id" .next && mv -Tf .next current)
  test "$(readlink "$CURRENT")" = "$id" || fail "atomic switch did not select $id"
  (cd "$CURRENT" && sha256sum -c SHA256SUMS >/dev/null) || fail "$id bundle manifest failed after switch"
  timeline "bundle-switch target=$id"
}
switch_bundle previous
timeline "previous-bundle-baseline-verified"
switch_bundle candidate

# Ephemeral campaign PKI. Private keys never leave WORK.
openssl req -x509 -newkey rsa:2048 -nodes -days 1 \
  -subj '/CN=Druse R1 Pilot CA' -keyout "$CERTS/ca-key.pem" -out "$CERTS/ca.pem" >/dev/null 2>&1
openssl req -newkey rsa:2048 -nodes -subj '/CN=proxy.test' \
  -addext 'subjectAltName=DNS:proxy.test' \
  -keyout "$CERTS/server-key.pem" -out "$CERTS/server.csr" >/dev/null 2>&1
printf 'subjectAltName=DNS:proxy.test\nextendedKeyUsage=serverAuth\n' > "$CERTS/server.ext"
openssl x509 -req -days 1 -in "$CERTS/server.csr" -CA "$CERTS/ca.pem" \
  -CAkey "$CERTS/ca-key.pem" -CAcreateserial -extfile "$CERTS/server.ext" \
  -out "$CERTS/server.pem" >/dev/null 2>&1

validate_caddy() {
  docker run --rm --platform "$DRUSE_CADDY_PLATFORM" \
    --user "$(id -u):$(id -g)" \
    -e XDG_DATA_HOME=/tmp/caddy-data -e XDG_CONFIG_HOME=/tmp/caddy-config \
    -e DRUSE_PROXY_PORT="$PROXY_PORT" -e DRUSE_UPSTREAM="127.0.0.1:$ORIGIN_PORT" \
    -v "$CURRENT/Caddyfile:/etc/caddy/Caddyfile:ro" -v "$CERTS:/certs:ro" \
    -v "$PROXY_LOGS:/logs" \
    "$DRUSE_CADDY_IMAGE" caddy validate --config /etc/caddy/Caddyfile --adapter caddyfile
}
validate_caddy > "$WORK/caddy-validate.log" 2>&1 || fail "candidate Caddy configuration did not validate"

start_service() {
  load_state="$(systemctl --user show "$UNIT.service" -p LoadState --value 2>/dev/null || true)"
  if test "$UNIT_CREATED" -eq 0 || test "$load_state" = not-found || test -z "$load_state"; then
    systemd-run --user --unit="$UNIT" \
      --property=Type=simple --property=Restart=on-failure --property=RestartSec=200ms \
      --property=StartLimitBurst=5 --property=StartLimitIntervalSec=10s \
      --property=TimeoutStopSec=30s --property=MemoryMax=1G \
      --property=LimitNOFILE=2048 --property=LimitMEMLOCK=64M \
      --setenv=DRUSE_PORT="$ORIGIN_PORT" \
      /bin/bash -c 'set -a; . "$1/runtime-limits"; set +a; "$1/check-runtime-limits.sh"; exec "$1/app"' \
      _ "$CURRENT" >> "$WORK/systemd-run.log" 2>&1
    UNIT_CREATED=1
  else
    systemctl --user start "$UNIT.service"
  fi
  for _ in $(seq 1 300); do
    curl --noproxy '*' -fsS --max-time 0.2 "http://127.0.0.1:$ORIGIN_PORT/health" >/dev/null 2>&1 && {
      timeline "service-ready bundle=$(readlink "$CURRENT") pid=$(systemctl --user show "$UNIT.service" -p MainPID --value)"
      return
    }
    sleep 0.02
  done
  fail "service did not become healthy for bundle $(readlink "$CURRENT")"
}

stop_service_clean() {
  local label=$1
  timeline "$label-sigterm"
  systemctl --user kill --kill-whom=main --signal=SIGTERM "$UNIT.service"
  for _ in $(seq 1 400); do
    state="$(systemctl --user show "$UNIT.service" -p ActiveState --value)"
    test "$state" = inactive && { timeline "$label-inactive"; return; }
    sleep 0.025
  done
  fail "$label did not stop inside the supervisor bound"
}

start_caddy() {
  docker run -d --name "$CONTAINER" --network host \
    --platform "$DRUSE_CADDY_PLATFORM" --user "$(id -u):$(id -g)" \
    -e XDG_DATA_HOME=/tmp/caddy-data -e XDG_CONFIG_HOME=/tmp/caddy-config \
    -e DRUSE_PROXY_PORT="$PROXY_PORT" -e DRUSE_UPSTREAM="127.0.0.1:$ORIGIN_PORT" \
    -v "$CURRENT/Caddyfile:/etc/caddy/Caddyfile:ro" -v "$CERTS:/certs:ro" \
    -v "$PROXY_LOGS:/logs" "$DRUSE_CADDY_IMAGE" \
    caddy run --config /etc/caddy/Caddyfile --adapter caddyfile >/dev/null
  CADDY_RUNNING=1
  for _ in $(seq 1 200); do
    proxy_curl -fsS "$(proxy_url /health)" >/dev/null 2>&1 && {
      timeline "proxy-ready bundle=$(readlink "$CURRENT")"
      return
    }
    sleep 0.03
  done
  fail "Caddy did not become healthy"
}

stop_caddy() {
  test "$CADDY_RUNNING" -eq 1 || return
  docker logs "$CONTAINER" > "$WORK/caddy-container-$(readlink "$CURRENT").log" 2>&1 || true
  docker rm -f "$CONTAINER" >/dev/null
  CADDY_RUNNING=0
  timeline "proxy-stopped bundle=$(readlink "$CURRENT")"
}

proxy_url() { printf 'https://proxy.test:%s%s' "$PROXY_PORT" "$1"; }
proxy_curl() {
  curl --noproxy '*' --silent --show-error --max-time 10 \
    --cacert "$CERTS/ca.pem" --resolve "proxy.test:$PROXY_PORT:127.0.0.1" "$@"
}

smoke_bundle() {
  local expected=$1 prefix="$WORK/smoke-$1"
  proxy_curl -D "$prefix.headers" "$(proxy_url /pilot/sentinel)" > "$prefix.body"
  grep -iq "^x-r1-bundle: $expected" "$prefix.headers" || fail "$expected proxy config marker missing"
  grep -Fq "release=$expected sentinel=r1-integrity-v1" "$prefix.body" || fail "$expected binary/sentinel mismatch"
  proxy_curl -D "$prefix.request-id.headers" -H 'X-Request-Id: r1-wp06' \
    "$(proxy_url /pilot/whoami)" > "$prefix.whoami"
  grep -iq '^X-Request-Id: r1-wp06' "$prefix.request-id.headers" || fail "$expected request ID was not correlated"
  grep -Fxq '127.0.0.1' "$prefix.whoami" || fail "$expected client identity crossed the trusted boundary incorrectly"
  code="$(proxy_curl -o "$prefix.rejected.body" -w '%{http_code}' "$(proxy_url /outside)")"
  test "$code" = 404 || fail "$expected proxy allowlist returned $code for /outside"
  grep -Fq 'outside R1 pilot allowlist' "$prefix.rejected.body" || fail "$expected allowlist rejection came from the wrong layer"
  proxy_curl --http2 -o /dev/null -w '%{http_version}\n' "$(proxy_url /health)" > "$prefix.http-version"
  grep -Fxq '2' "$prefix.http-version" || fail "$expected client-to-proxy HTTP/2 was not negotiated"
  python3 "$ROOT/tests/r1-real-proxy/client.py" stream 127.0.0.1 "$PROXY_PORT" \
    "$CERTS/ca.pem" proxy.test /pilot/stream > "$prefix.stream.json"
  timeline "smoke-pass bundle=$expected"
}

start_service
start_caddy

mkdir -p "$OUTPUT/config" "$OUTPUT/raw" "$OUTPUT/analysis"
cp "$WORK/full-gate.log" "$OUTPUT/raw/full-gate.log"
cp "$WORK/caddy-validate.log" "$OUTPUT/raw/caddy-validate.log"
cp "$WORK/systemd-run.log" "$OUTPUT/raw/systemd-run.log"
cp "$CERTS/ca.pem" "$OUTPUT/config/campaign-ca.pem"
cp "$CERTS/server.pem" "$OUTPUT/config/proxy-public.pem"
cp "$RELEASES/previous/SHA256SUMS" "$OUTPUT/config/previous-bundle.SHA256SUMS"
cp "$RELEASES/candidate/SHA256SUMS" "$OUTPUT/config/candidate-bundle.SHA256SUMS"
cp "$RELEASES/previous/Caddyfile" "$OUTPUT/config/previous.Caddyfile"
cp "$RELEASES/candidate/Caddyfile" "$OUTPUT/config/candidate.Caddyfile"
cp "$RELEASES/candidate/runtime-limits" "$OUTPUT/config/runtime-limits"
cp "$RELEASES/candidate/pilot-profile" "$OUTPUT/config/pilot-profile.env"

smoke_bundle candidate
cp "$WORK"/smoke-candidate.* "$OUTPUT/raw/"

# One >max_body upload exercises the public spool path; request teardown must
# leave no file. The bytes are synthetic zeroes and are never preserved.
head -c 5242880 /dev/zero | proxy_curl -X POST --data-binary @- \
  -o "$OUTPUT/raw/upload.body" -w '%{http_code}\n' "$(proxy_url /pilot/upload)" \
  > "$OUTPUT/raw/upload.status"
grep -Fxq '201' "$OUTPUT/raw/upload.status" || fail "candidate large upload did not return 201"
test -z "$(find "$STATE" -maxdepth 1 -type f -name 'druse-spool-*' -print -quit)" ||
  fail "candidate upload left an owned spool"

python3 "$ROOT/tests/r1-pilot-deployment/client.py" 127.0.0.1 "$PROXY_PORT" \
  "$CERTS/ca.pem" candidate 50 > "$OUTPUT/raw/low-load.json"
grep -Fq '"errors": 0' "$OUTPUT/raw/low-load.json" || fail "low load recorded transport errors"
grep -Fq '"unexpected": 0' "$OUTPUT/raw/low-load.json" || fail "low load recorded unexpected responses"
MAIN_PID="$(systemctl --user show "$UNIT.service" -p MainPID --value)"
{
  echo "pid=$MAIN_PID"
  echo "exe=$(readlink "/proc/$MAIN_PID/exe")"
  rg '^(VmRSS|VmHWM|VmLck|Threads):' "/proc/$MAIN_PID/status"
  echo "fds=$(find "/proc/$MAIN_PID/fd" -mindepth 1 -maxdepth 1 | wc -l)"
} > "$OUTPUT/raw/candidate-process.txt"
systemctl --user show "$UNIT.service" -p ActiveState -p SubState -p Result -p NRestarts -p MainPID \
  > "$OUTPUT/raw/systemd-before-drain.txt"

# Normal drain: SIGTERM is delivered by the supervisor and clean exit must not
# count as a restart.
stop_service_clean normal-drain
systemctl --user show "$UNIT.service" -p ActiveState -p SubState -p Result -p NRestarts \
  > "$OUTPUT/raw/systemd-after-drain.txt"
grep -Fq 'NRestarts=0' "$OUTPUT/raw/systemd-after-drain.txt" || fail "clean drain caused a restart"
start_service

# Active health is attached to /pilot/*, while start_service deliberately probes
# the origin directly.  After a clean drain Caddy may still hold the upstream in
# its failed state for one health interval.  Do not let that propagation window
# turn the fault injection into a 503 that never reaches the Handler.
PROXY_APPLICATION_READY=0
for _ in $(seq 1 100); do
  if proxy_curl -fsS "$(proxy_url /pilot/sentinel)" 2>/dev/null | \
      grep -Fq 'release=candidate sentinel=r1-integrity-v1'; then
    PROXY_APPLICATION_READY=1
    break
  fi
  sleep 0.025
done
test "$PROXY_APPLICATION_READY" -eq 1 || fail "proxy did not restore candidate application traffic after clean drain"
timeline "proxy-application-ready-after-drain"

# Deliberate Handler fault: capture the faulting PID, prove a core record, then
# prove Restart=on-failure restored the same candidate bundle.
CRASH_PID="$(systemctl --user show "$UNIT.service" -p MainPID --value)"
timeline "handler-fault-request pid=$CRASH_PID"
proxy_curl "$(proxy_url /pilot/crash)" > "$OUTPUT/raw/crash-client.txt" 2>&1 || true
RESTARTED=0
for _ in $(seq 1 400); do
  restarts="$(systemctl --user show "$UNIT.service" -p NRestarts --value)"
  new_pid="$(systemctl --user show "$UNIT.service" -p MainPID --value)"
  if test "${restarts:-0}" -ge 1 && test "$new_pid" != "$CRASH_PID" && \
      curl --noproxy '*' -fsS --max-time 0.2 "http://127.0.0.1:$ORIGIN_PORT/health" >/dev/null 2>&1; then
    RESTARTED=1
    timeline "handler-fault-recovered old_pid=$CRASH_PID new_pid=$new_pid restarts=$restarts"
    break
  fi
  sleep 0.025
done
test "$RESTARTED" -eq 1 || fail "supervisor did not restart after the Handler fault"
CORE_FOUND=0
for _ in $(seq 1 200); do
  if coredumpctl --no-pager info "$CRASH_PID" > "$OUTPUT/raw/coredump-info.txt" 2>&1; then
    CORE_FOUND=1
    break
  fi
  sleep 0.05
done
test "$CORE_FOUND" -eq 1 || fail "no coredump metadata was recorded for faulting pid $CRASH_PID"
grep -Fq 'Signal: 6 (ABRT)' "$OUTPUT/raw/coredump-info.txt" || fail "core metadata did not classify SIGABRT"
systemctl --user show "$UNIT.service" -p ActiveState -p SubState -p Result -p NRestarts -p MainPID \
  > "$OUTPUT/raw/systemd-after-crash.txt"
smoke_bundle candidate
cp "$WORK"/smoke-candidate.* "$OUTPUT/raw/"

# Rollback target and configuration change together. Caddy is recreated so its
# bind mount resolves through the newly selected bundle.
ROLLBACK_START="$(date +%s)"
stop_service_clean rollback-stop
stop_caddy
test -z "$(pgrep -f "$RELEASES/candidate/app" || true)" || fail "candidate process survived rollback stop"
switch_bundle previous
validate_caddy > "$OUTPUT/raw/rollback-caddy-validate.log" 2>&1 || fail "previous Caddy configuration did not validate"
start_service
start_caddy
smoke_bundle previous
cp "$WORK"/smoke-previous.* "$OUTPUT/raw/"
ROLLBACK_SECONDS=$(($(date +%s) - ROLLBACK_START))
test "$ROLLBACK_SECONDS" -le 300 || fail "rollback took ${ROLLBACK_SECONDS}s, over five-minute objective"
ROLLBACK_PID="$(systemctl --user show "$UNIT.service" -p MainPID --value)"
{
  echo "pid=$ROLLBACK_PID"
  echo "exe=$(readlink "/proc/$ROLLBACK_PID/exe")"
  echo "bundle=$(readlink "$CURRENT")"
  echo "rollback_seconds=$ROLLBACK_SECONDS"
} > "$OUTPUT/raw/rollback-process.txt"
systemctl --user show "$UNIT.service" -p ActiveState -p SubState -p Result -p NRestarts -p MainPID \
  > "$OUTPUT/raw/systemd-after-rollback.txt"
test -z "$(find "$STATE" -maxdepth 1 -type f -name 'druse-spool-*' -print -quit)" ||
  fail "rollback left an orphan spool"
timeline "rollback-smoke-pass seconds=$ROLLBACK_SECONDS"

# Preserve UTC logs while the unit/container still exist.
journalctl --user -u "$UNIT.service" --utc --output=short-iso-precise --no-pager \
  > "$OUTPUT/raw/systemd-journal.txt"
cp "$PROXY_LOGS/access.json" "$OUTPUT/raw/proxy-access.json"
stop_service_clean final-stop
stop_caddy
systemctl --user show "$UNIT.service" -p ActiveState -p SubState -p Result -p NRestarts \
  > "$OUTPUT/raw/systemd-final.txt"
test -z "$(ss -H -ltn "sport = :$ORIGIN_PORT or sport = :$PROXY_PORT" 2>/dev/null)" ||
  fail "pilot listener remained after final stop"
timeline "campaign-complete decision=PROMOTE_TO_R1"
CAMPAIGN_COMPLETE=1
cp "$WORK/timeline.tsv" "$OUTPUT/raw/timeline.tsv"
cp "$WORK"/caddy-container-*.log "$OUTPUT/raw/" 2>/dev/null || true

IMAGE_ID="$(docker image inspect "$DRUSE_CADDY_IMAGE" --format '{{.Id}}')"
START_UTC="$(head -n 1 "$WORK/timeline.tsv" | cut -f1)"
END_UTC="$(tail -n 1 "$WORK/timeline.tsv" | cut -f1)"
{
  echo "campaign=R1-WP06-pilot-exercise"
  echo "start_utc=$START_UTC"
  echo "end_utc=$END_UTC"
  echo "candidate_commit=$CANDIDATE_COMMIT"
  echo "candidate_tree=$CANDIDATE_TREE"
  echo "previous_commit=$PREVIOUS_COMMIT"
  echo "previous_tree=$PREVIOUS_TREE"
  echo "candidate_binary_sha256=$CANDIDATE_BINARY_SHA"
  echo "previous_binary_sha256=$PREVIOUS_BINARY_SHA"
  echo "candidate_proxy_sha256=$CANDIDATE_CONFIG_SHA"
  echo "previous_proxy_sha256=$PREVIOUS_CONFIG_SHA"
  echo "compiler_sha256=$(sha256sum "$ODIN_BIN" | awk '{print $1}')"
  echo "caddy_image=$DRUSE_CADDY_IMAGE"
  echo "caddy_image_id=$IMAGE_ID"
  echo "rollback_seconds=$ROLLBACK_SECONDS"
  echo "decision=PROMOTE_TO_R1"
} > "$OUTPUT/manifest.txt"
{
  uname -a
  "$ODIN_BIN" version
  systemd --version | head -n 1
  docker version --format 'docker={{.Server.Version}}'
  docker run --rm --platform "$DRUSE_CADDY_PLATFORM" "$DRUSE_CADDY_IMAGE" caddy version
  openssl version
} > "$OUTPUT/environment.txt"
cat > "$OUTPUT/commands.txt" <<EOF
full_gate=bash build/check.sh
candidate_build=odin build tests/r1-pilot-deployment/server -collection:druse=. -o:speed -define:R1_PILOT_RELEASE=candidate
previous_build=git worktree add --detach previous-source $PREVIOUS_COMMIT; odin build tests/r1-pilot-deployment/server -o:speed -define:R1_PILOT_RELEASE=previous
supervisor=systemd-run --user with Restart=on-failure TimeoutStopSec=30s MemoryMax=1G LimitNOFILE=2048 LimitMEMLOCK=64M
proxy=docker run --network host --platform $DRUSE_CADDY_PLATFORM $DRUSE_CADDY_IMAGE
private_keys=ephemeral; never copied into evidence
EOF
cat > "$OUTPUT/verdict.md" <<EOF
# R1-WP06 pilot exercise verdict

**Decision: PROMOTE TO R1 — internal, non-critical controlled pilot only.**

- Candidate \
  \`$CANDIDATE_COMMIT\` passed the full gate and was installed as an immutable
  binary + runtime + pilot policy + Caddy bundle.
- TLS/proxy smoke, route allowlist, request-ID correlation, trusted client
  identity, HTTP/2 ingress, HTTP/1.1 upstream policy, detached streaming,
  spooled upload and 10 rps low load passed.
- Normal SIGTERM drained with zero restarts. A deliberate Handler fault
  produced SIGABRT core metadata and \`Restart=on-failure\` recovered the same
  candidate bundle.
- Rollback atomically selected actual parent commit \
  \`$PREVIOUS_COMMIT\`, changed binary and proxy hashes together, completed in
  ${ROLLBACK_SECONDS}s, then passed health/readiness/route/stream/integrity smoke.
- No candidate process, listener or orphan spool remained after final stop.

This verdict does not authorize critical production, direct exposure, a
different proxy, irreversible migration or load above
\`ops/deploy/pilot-profile.env\`.
EOF

(
  cd "$OUTPUT"
  find . -type f ! -name SHA256SUMS -print0 | sort -z | xargs -0 sha256sum > SHA256SUMS
  sha256sum -c SHA256SUMS >/dev/null
)
echo "PASS: R1-WP06 deploy, crash/restart, drain and rollback campaign"
echo "evidence: $OUTPUT"
