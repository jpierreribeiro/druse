#!/usr/bin/env bash
# Host qualification, run BEFORE a soak campaign and recorded with it.
#
#   usage: preflight.sh [REPORT_PATH]
#
# WHY. `run-soak.sh` pins the server to CPUs 0-3 and the generators to 4-7. On a
# four-CPU host `taskset -c 4-7` fails, and the failure surfaces as "load
# generator process failed" or "release-candidate server exited before
# readiness" — two messages about the product, produced by a host that was never
# capable of running the measurement. R2 rule G2 is that an instrument failure
# must fail the CAMPAIGN, visibly, and not be reported as a fact about the
# framework.
#
# So the topology is checked against the affinity the run will actually use,
# by name, before anything is built.
#
# This script REFUSES; it does not adapt. R2-WP02: "Se o host não satisfizer a
# topologia, alterar o plano e commitá-lo antes do run; não adaptar affinity
# silenciosamente durante a campanha." A preflight that quietly narrowed the CPU
# set would produce a run whose manifest disagreed with its plan, and the
# disagreement would be invisible in the artefact.
#
# Exit 0 qualifies the host. Exit 1 does not. Everything it learned is written
# to REPORT_PATH (default: stdout) either way, because the reasons a host was
# rejected are part of the campaign record.
set -uo pipefail

REPORT="${1:-/dev/stdout}"
SERVER_CPUS="${DRUSE_SOAK_SERVER_CPUS:-0-3}"
GENERATOR_CPUS="${DRUSE_SOAK_GENERATOR_CPUS:-4-7}"
PORT="${DRUSE_SOAK_PORT:-8080}"
HOURS="${DRUSE_SOAK_PREFLIGHT_HOURS:-12}"
SAMPLE_SECONDS="${DRUSE_SOAK_SAMPLE_SECONDS:-1}"
# 12 h of per-request CSV at the pre-registered rates is the dominant artefact.
# ~15.6k req/s across the profiles, ~120 bytes a row, is ~80 GiB — the number is
# an estimate and it is recorded as one, but a host with 20 GiB free is not
# going to survive the night and should learn that now rather than at hour nine.
MIN_FREE_GIB="${DRUSE_SOAK_MIN_FREE_GIB:-100}"

problems=()
notes=()

note() { notes+=("$1"); }
problem() { problems+=("$1"); }

# cpu_count_of 0-3      -> 4
# cpu_count_of 0,2,4    -> 3
cpu_count_of() {
  local spec="$1" total=0 part low high
  local IFS=,
  for part in $spec; do
    case "$part" in
      *-*)
        low="${part%%-*}"; high="${part##*-}"
        if ! [[ "$low" =~ ^[0-9]+$ && "$high" =~ ^[0-9]+$ ]] || (( high < low )); then
          echo "invalid"; return 1
        fi
        total=$(( total + high - low + 1 )) ;;
      *)
        [[ "$part" =~ ^[0-9]+$ ]] || { echo "invalid"; return 1; }
        total=$(( total + 1 )) ;;
    esac
  done
  echo "$total"
}

# highest_cpu_of 4-7 -> 7
highest_cpu_of() {
  local spec="$1" highest=-1 part value
  local IFS=,
  for part in $spec; do
    value="${part##*-}"
    [[ "$value" =~ ^[0-9]+$ ]] || { echo "-1"; return 1; }
    (( value > highest )) && highest="$value"
  done
  echo "$highest"
}

# --- 1. topology vs the affinity this campaign will use ----------------------
online_cpus="$(nproc --all 2>/dev/null || echo 0)"
server_n="$(cpu_count_of "$SERVER_CPUS")"
generator_n="$(cpu_count_of "$GENERATOR_CPUS")"
highest_server="$(highest_cpu_of "$SERVER_CPUS")"
highest_generator="$(highest_cpu_of "$GENERATOR_CPUS")"
highest=$(( highest_server > highest_generator ? highest_server : highest_generator ))

note "online_cpus=$online_cpus"
note "server_cpus=$SERVER_CPUS ($server_n)"
note "generator_cpus=$GENERATOR_CPUS ($generator_n)"

if [[ "$server_n" == invalid || "$generator_n" == invalid ]]; then
  problem "cpu set is not parseable: server='$SERVER_CPUS' generator='$GENERATOR_CPUS'"
elif (( highest >= online_cpus )); then
  problem "the campaign pins CPU $highest and this host has $online_cpus online: run-soak.sh would fail inside taskset and report it as a product failure"
fi

# Distinct sets, or the generator competes with the server for the thing being
# measured. This is a criterion of the campaign, not a preference.
if [[ "$SERVER_CPUS" == "$GENERATOR_CPUS" ]]; then
  problem "server and generator share the CPU set $SERVER_CPUS: the load generator would compete with the process under measurement"
fi

if command -v taskset >/dev/null 2>&1; then
  taskset -c "$SERVER_CPUS" true 2>/dev/null ||
    problem "taskset -c $SERVER_CPUS is rejected by this host"
  taskset -c "$GENERATOR_CPUS" true 2>/dev/null ||
    problem "taskset -c $GENERATOR_CPUS is rejected by this host"
else
  problem "taskset is not installed; the campaign cannot pin anything"
fi

# --- 2. tools the run and the analysis need ----------------------------------
# nstat is what separates a request the kernel dropped from a request the server
# refused. Without it the sampler records zeros, which read as "no drops".
for tool in curl jq python3 go awk sed find sha256sum; do
  command -v "$tool" >/dev/null 2>&1 ||
    problem "$tool is not installed and the campaign depends on it"
done
if command -v nstat >/dev/null 2>&1; then
  note "nstat=$(command -v nstat)"
else
  problem "nstat is not installed: kernel drop counters would record as zero, which is indistinguishable from no drops"
fi

odin_bin="${DRUSE_ODIN_BIN:-}"
if [[ -z "$odin_bin" ]] && command -v odin >/dev/null 2>&1; then
  odin_bin="$(command -v odin)"
fi
if [[ -n "$odin_bin" && -x "$odin_bin" ]]; then
  note "odin=$odin_bin"
  note "odin_version=$("$odin_bin" version 2>&1 | head -n 1)"
else
  problem "no Odin compiler: set DRUSE_ODIN_BIN or put odin on PATH"
fi
command -v go >/dev/null 2>&1 && note "go_version=$(go version 2>&1)"

# --- 3. CPU frequency policy -------------------------------------------------
# Recorded, not enforced. A campaign on a boosting host is still a valid
# campaign as long as the artefact says so; a campaign whose governor nobody
# wrote down cannot be compared with anything later.
governors="$(cat /sys/devices/system/cpu/cpu*/cpufreq/scaling_governor 2>/dev/null |
  sort -u | tr '\n' ' ')"
note "cpu_governors=${governors:-unavailable}"
if [[ -r /sys/devices/system/cpu/intel_pstate/no_turbo ]]; then
  note "intel_pstate_no_turbo=$(cat /sys/devices/system/cpu/intel_pstate/no_turbo)"
elif [[ -r /sys/devices/system/cpu/cpufreq/boost ]]; then
  note "cpufreq_boost=$(cat /sys/devices/system/cpu/cpufreq/boost)"
else
  note "turbo_policy=unavailable"
fi
if command -v lscpu >/dev/null 2>&1; then
  note "numa_nodes=$(lscpu 2>/dev/null | awk -F: '/NUMA node\(s\)/ {gsub(/ /,"",$2); print $2}')"
  note "cpu_model=$(lscpu 2>/dev/null | awk -F: '/Model name/ {sub(/^[ \t]+/,"",$2); print $2; exit}')"
fi

# --- 4. memory, swap, limits -------------------------------------------------
mem_total_kib="$(awk '/^MemTotal:/ {print $2}' /proc/meminfo 2>/dev/null || echo 0)"
swap_total_kib="$(awk '/^SwapTotal:/ {print $2}' /proc/meminfo 2>/dev/null || echo 0)"
note "mem_total_kib=$mem_total_kib"
note "swap_total_kib=$swap_total_kib"
note "swappiness=$(cat /proc/sys/vm/swappiness 2>/dev/null || echo unavailable)"

# The safety stop is 4 GiB of RSS. A host that cannot hold it will OOM-kill the
# server and the run will report "server died" about a host that was too small.
max_rss_kib="${DRUSE_SOAK_MAX_RSS_KIB:-4194304}"
if (( mem_total_kib > 0 && mem_total_kib < max_rss_kib * 2 )); then
  problem "host has ${mem_total_kib} KiB of RAM and the RSS safety stop is ${max_rss_kib} KiB: an OOM kill would be recorded as a server death"
fi

nofile_hard="$(ulimit -Hn 2>/dev/null || echo 0)"
note "nofile_hard=$nofile_hard"
if [[ "$nofile_hard" != unlimited ]] && (( nofile_hard < 8192 )); then
  problem "hard nofile limit is $nofile_hard and the run raises it to 8192"
fi

note "cgroup=$(awk -F: 'NR==1 {print $3}' /proc/self/cgroup 2>/dev/null || echo unavailable)"

# --- 5. the port is free -----------------------------------------------------
if command -v ss >/dev/null 2>&1; then
  if ss -ltn "sport = :$PORT" 2>/dev/null | tail -n +2 | grep -q .; then
    problem "port $PORT already has a listener"
  else
    note "port_$PORT=free"
  fi
elif curl -fsS --max-time 1 "http://127.0.0.1:$PORT/" >/dev/null 2>&1; then
  problem "port $PORT already answers HTTP"
else
  note "port_$PORT=free (probed with curl; ss unavailable)"
fi

# --- 6. clock ----------------------------------------------------------------
# Every artefact joins on absolute unix time. A host whose clock steps mid-run
# produces a per-request CSV that cannot be joined to a /stats sample, and the
# join is the whole diagnosability story.
if command -v timedatectl >/dev/null 2>&1; then
  synced="$(timedatectl show -p NTPSynchronized --value 2>/dev/null || echo unknown)"
  note "ntp_synchronized=$synced"
  [[ "$synced" == "no" ]] &&
    problem "the clock is not NTP-synchronised: absolute timestamps are the join key for every artefact"
else
  note "ntp_synchronized=unknown (timedatectl unavailable)"
fi
note "utc_now=$(date -u +%Y-%m-%dT%H:%M:%SZ)"

# --- 7. disk for the raw evidence -------------------------------------------
target_dir="${DRUSE_SOAK_BASE:-$PWD}"
free_kib="$(df -Pk "$target_dir" 2>/dev/null | awk 'NR==2 {print $4}')"
free_gib=$(( ${free_kib:-0} / 1024 / 1024 ))
note "free_gib_at=$target_dir:$free_gib"
note "estimated_need_gib=$MIN_FREE_GIB (for ${HOURS}h at sample_seconds=$SAMPLE_SECONDS)"
if (( free_gib < MIN_FREE_GIB )); then
  problem "$free_gib GiB free at $target_dir; a ${HOURS}h run is estimated to need $MIN_FREE_GIB GiB of raw CSV"
fi

# --- report ------------------------------------------------------------------
{
  echo "preflight_utc=$(date -u +%Y-%m-%dT%H:%M:%SZ)"
  echo "hostname=$(hostname 2>/dev/null || echo unknown)"
  echo "kernel=$(uname -srmo)"
  for line in "${notes[@]}"; do echo "$line"; done
  if (( ${#problems[@]} == 0 )); then
    echo "preflight=pass"
  else
    echo "preflight=fail"
    for line in "${problems[@]}"; do echo "problem=$line"; done
  fi
} >"$REPORT"

if (( ${#problems[@]} > 0 )); then
  echo "PREFLIGHT FAILED — this host cannot run the campaign as planned:" >&2
  for line in "${problems[@]}"; do echo "  - $line" >&2; done
  echo >&2
  echo "Change the plan and commit it, or use a host that satisfies it." >&2
  echo "Do not adapt the affinity silently during a campaign (R2-WP02)." >&2
  exit 1
fi

echo "preflight: host qualified for server=$SERVER_CPUS generator=$GENERATOR_CPUS" >&2
