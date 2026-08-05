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
# AND BY PHYSICAL CORE, NOT BY CPU NUMBER (R2-WP02). The first edition of this
# script compared the two CPU sets as STRINGS and called them distinct when they
# differed. Two defects lived in that one line.
#
#   1. `0-3` against `0,1,2,3` is the same set written twice, and it passed.
#   2. On an SMT host, `0-3` against `4-7` is disjoint by NUMBER and identical by
#      CORE. A c5.2xlarge is 4 physical cores x 2 hyperthreads and the Nitro
#      layout pairs (0,4) (1,5) (2,6) (3,7) — so the campaign's server set and
#      its generator set are the two sibling threads of the SAME four cores. The
#      reason this script demands disjoint sets is written four lines below the
#      check itself: "the load generator would compete with the process under
#      measurement". Via SMT they compete exactly like that, and the check that
#      exists to prevent it reported nothing.
#
# A check that stays green while the property it protects is false is a defect of
# the INSTRUMENT, and this repository has already paid for that class twice
# (INS-003, INS-013). So the sets are expanded to CPU numbers, each CPU is mapped
# to its physical core through
# /sys/devices/system/cpu/cpu*/topology/thread_siblings_list, and the comparison
# is made between CORE sets.
#
# A host whose topology cannot be READ is refused rather than assumed flat. That
# is INS-013's rule applied here: a missing measurement is not a clean result.
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
# 12 h of per-request CSV at the pre-registered rates is the dominant artefact,
# and its size is a FUNCTION OF THE OFFERED RATE. The first edition of this
# script wrote that function out in a comment — "~15.6k req/s across the
# profiles, ~120 bytes a row, is ~80 GiB" — and then pinned the RESULT as the
# constant 100.
#
# That constant went stale the moment the campaign changed rates. §4.1 and §4.5
# of the pre-registration took the aggregate from 15,685/s to 1,586/s, a factor
# of ten, and this number kept demanding disk for a load nobody offers any more.
# It refused a host with 91 GiB free for a run whose artefact the rehearsal
# MEASURED at ~10.2 GiB (§4.4).
#
# So it is derived, not pinned. The arithmetic is the comment's own, and it
# agrees with the measurement: at the rehearsal's 2,352/s it predicts 11.4 GiB
# against ~10.2 GiB observed, which is 12% — close enough to trust the shape and
# not close enough to pretend it is exact, which is why the margin below exists.
#
# The margin is 1.5x (the original was 80 GiB estimated against a 100 GiB floor,
# i.e. 1.25x). At the historic rates this derivation yields 113 GiB, MORE than
# the constant it replaces: it is not a threshold lowered to admit a host, it is
# a threshold that now moves with the thing it estimates.
DRUSE_RATE_TOTAL=$(( ${DRUSE_SOAK_HEALTH_RATE:-20} + ${DRUSE_SOAK_TINY_RATE:-10000} \
  + ${DRUSE_SOAK_JSON_ENCODE_RATE:-1500} + ${DRUSE_SOAK_JSON_DECODE_RATE:-4000} \
  + ${DRUSE_SOAK_BYTES_64K_RATE:-150} + ${DRUSE_SOAK_WAIT_40MS_RATE:-15} ))
DRUSE_CSV_ROW_BYTES="${DRUSE_SOAK_CSV_ROW_BYTES:-120}"
DRUSE_EST_GIB=$(( DRUSE_RATE_TOTAL * 3600 * HOURS * DRUSE_CSV_ROW_BYTES * 3 / 2 / 1073741824 ))
# THE LADDER FLOOR, DERIVED — and the first edition of it was a pinned 25 GiB,
# which is the same defect this block exists to fix, left half-done.
#
# The disk holds THE WHOLE LADDER and not one run: smoke (10 min), burn-in
# (30 min), rehearsal (2 h) and both finals (12 h each) are preserved side by
# side — red runs are never deleted, they are evidence about the instrument.
# That is 96,000 s of running, and its size is a function of the offered rate
# exactly like the single-run estimate above.
#
# The pinned 25 GiB was not merely imprecise, it was WRONG IN BOTH DIRECTIONS:
# at 960 req/s the ladder needs 15 GiB and 25 refused hosts that fit; at
# 2,369 req/s it needs 38 GiB and 25 would have admitted a host that runs out
# of disk somewhere in the second final. A constant cannot be conservative for
# a quantity that moves by 4x.
DRUSE_LADDER_SECONDS="${DRUSE_SOAK_LADDER_SECONDS:-96000}"
DRUSE_LADDER_FLOOR_GIB="${DRUSE_SOAK_LADDER_FLOOR_GIB:-$(( DRUSE_RATE_TOTAL * DRUSE_LADDER_SECONDS * DRUSE_CSV_ROW_BYTES * 3 / 2 / 1073741824 ))}"
# A small absolute floor underneath, for the toolchain, the repository and the
# proxy smoke's container images, which no rate makes smaller.
if (( DRUSE_LADDER_FLOOR_GIB < 5 )); then
  DRUSE_LADDER_FLOOR_GIB=5
fi
if (( DRUSE_EST_GIB < DRUSE_LADDER_FLOOR_GIB )); then
  DRUSE_EST_GIB="$DRUSE_LADDER_FLOOR_GIB"
fi
MIN_FREE_GIB="${DRUSE_SOAK_MIN_FREE_GIB:-$DRUSE_EST_GIB}"
# Where the CPU topology is read from. Overridable for ONE reason: the physical
# core check is itself a control, and a control that can only be exercised on the
# machine it happens to run on cannot have a positive case. build/check_soak_
# controls.sh points this at synthetic sysfs trees with known sibling maps. The
# override is recorded in the report, so a real campaign cannot use it unnoticed.
TOPOLOGY_DIR="${DRUSE_SOAK_TOPOLOGY_DIR:-/sys/devices/system/cpu}"

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

# expand_cpu_spec 0-3    -> "0 1 2 3"
# expand_cpu_spec 0,2-3  -> "0 2 3"
# The members, not the count. Disjointness is a question about members, and the
# string comparison this replaces could not ask it: `0-3` and `0,1,2,3` differ as
# strings and are the same four CPUs.
expand_cpu_spec() {
  local spec="$1" out="" part low high i
  local IFS=,
  for part in $spec; do
    case "$part" in
      *-*)
        low="${part%%-*}"; high="${part##*-}"
        if ! [[ "$low" =~ ^[0-9]+$ && "$high" =~ ^[0-9]+$ ]] || (( high < low )); then
          echo "invalid"; return 1
        fi
        for (( i = low; i <= high; i++ )); do out="$out $i"; done ;;
      *)
        [[ "$part" =~ ^[0-9]+$ ]] || { echo "invalid"; return 1; }
        out="$out $part" ;;
    esac
  done
  echo "${out# }"
}

# physical_core_of 4 -> "0 4"   (on a host where cpu4's siblings are 0 and 4)
#
# The sorted sibling list IS the core's identity: two CPUs are on one physical
# core exactly when they list each other. Nothing here needs a core NUMBER, and
# deriving one from `core_id` would need `physical_package_id` too to stay
# correct on a multi-socket host — the sibling list is already unique per core
# and needs no second file to disambiguate.
#
# Prints nothing and returns 1 when the topology is unreadable. The caller must
# treat that as a refusal, not as "no siblings".
physical_core_of() {
  local cpu="$1" file="$TOPOLOGY_DIR/cpu$1/topology/thread_siblings_list" raw expanded
  [[ -r "$file" ]] || return 1
  raw="$(<"$file")"
  raw="${raw//[[:space:]]/}"
  [[ -n "$raw" ]] || return 1
  expanded="$(expand_cpu_spec "$raw")" || return 1
  [[ "$expanded" == invalid ]] && return 1
  # Sorted, so the same core reached from either sibling yields one key.
  tr ' ' '\n' <<<"$expanded" | sort -n | tr '\n' ' ' | sed 's/ $//'
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
if [[ "$TOPOLOGY_DIR" == "/sys/devices/system/cpu" ]]; then
  online_cpus="$(nproc --all 2>/dev/null || echo 0)"
  note "topology_source=$TOPOLOGY_DIR"
else
  # Fixture mode. `nproc` would describe the machine running the control rather
  # than the machine the fixture describes, and the two disagree by design.
  online_cpus="$(find "$TOPOLOGY_DIR" -maxdepth 1 -name 'cpu[0-9]*' -type d 2>/dev/null | wc -l)"
  note "topology_source=$TOPOLOGY_DIR (OVERRIDE — not a real host; DRUSE_SOAK_TOPOLOGY_DIR is set)"
fi
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
#
# Two levels, and the second is the one that was missing. Disjoint LOGICAL CPUs
# is necessary and not sufficient: on an SMT host two disjoint CPU sets can be
# the two thread halves of one set of physical cores, and then the competition
# this check exists to prevent is happening on every core the server runs on.
server_cpu_list="$(expand_cpu_spec "$SERVER_CPUS")"
generator_cpu_list="$(expand_cpu_spec "$GENERATOR_CPUS")"

if [[ "$server_cpu_list" == invalid || "$generator_cpu_list" == invalid ]]; then
  : # already reported by the parse check above
else
  shared_cpus="$(comm -12 \
    <(tr ' ' '\n' <<<"$server_cpu_list" | sort -n -u) \
    <(tr ' ' '\n' <<<"$generator_cpu_list" | sort -n -u) | tr '\n' ' ')"
  shared_cpus="${shared_cpus% }"
  if [[ -n "$shared_cpus" ]]; then
    problem "server ($SERVER_CPUS) and generator ($GENERATOR_CPUS) share logical CPU(s) ${shared_cpus// /,}: the load generator would compete with the process under measurement"
  fi

  # --- physical cores ---------------------------------------------------------
  server_cores=(); generator_cores=(); unreadable=()
  for cpu in $server_cpu_list; do
    if core="$(physical_core_of "$cpu")"; then
      server_cores+=("$core")
    else
      unreadable+=("$cpu")
    fi
  done
  for cpu in $generator_cpu_list; do
    if core="$(physical_core_of "$cpu")"; then
      generator_cores+=("$core")
    else
      unreadable+=("$cpu")
    fi
  done

  if (( ${#unreadable[@]} > 0 )); then
    # Not "assume no SMT". A topology that cannot be read is a property that
    # cannot be verified, and INS-013 is the finding that says an absent
    # measurement must never be rendered as a clean one.
    note "physical_core_disjoint=unknown"
    problem "the physical-core topology is unreadable for CPU(s) $(printf '%s,' "${unreadable[@]}" | sed 's/,$//') under $TOPOLOGY_DIR/cpuN/topology/thread_siblings_list: whether the server and generator sets share a core cannot be verified, and an unverified isolation claim is not an isolated host"
  else
    server_core_set="$(printf '%s\n' "${server_cores[@]}" | sort -u)"
    generator_core_set="$(printf '%s\n' "${generator_cores[@]}" | sort -u)"
    shared_cores="$(comm -12 \
      <(printf '%s\n' "$server_core_set") \
      <(printf '%s\n' "$generator_core_set"))"

    note "server_physical_cores=$(tr '\n' ';' <<<"$server_core_set" | sed 's/;$//')"
    note "generator_physical_cores=$(tr '\n' ';' <<<"$generator_core_set" | sed 's/;$//')"
    note "server_physical_core_count=$(grep -c . <<<"$server_core_set")"
    note "generator_physical_core_count=$(grep -c . <<<"$generator_core_set")"
    threads_per_core="$(awk '{print NF}' <<<"$server_core_set" | sort -rn | head -n 1)"
    note "threads_per_core_max=${threads_per_core:-unknown}"

    if [[ -n "$shared_cores" ]]; then
      note "physical_core_disjoint=no"
      problem "server ($SERVER_CPUS) and generator ($GENERATOR_CPUS) are disjoint by CPU NUMBER and share physical core(s) [$(tr '\n' ';' <<<"$shared_cores" | sed 's/;$//')]: those CPUs are SMT sibling threads of one core, so the load generator would compete with the process under measurement on the very cores being measured — which is the condition the disjoint sets exist to rule out"
    else
      # The affirmative. A preflight that can only say "refused" is
      # indistinguishable from a preflight that is broken, so the verified case
      # is recorded as a fact in the report and not merely as the absence of a
      # complaint (R2 rule G2).
      note "physical_core_disjoint=yes"
    fi
  fi
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

  # A compiler that EXISTS is not a compiler that BUILDS. Odin shells out to a
  # linker — clang on Linux — and a host with the toolchain unpacked but no
  # clang answers `odin version` perfectly and then fails at link time with
  # `sh: 1: clang: not found`. That was found here the expensive way: this
  # preflight passed a host, and the smoke it is supposed to run before failed
  # on the first build.
  #
  # So the check is a real build of a real program, not a version string. It
  # costs about a second and it is the difference between qualifying a host and
  # qualifying a filename.
  odin_probe="$(mktemp -d -t druse-odin-probe-XXXXXX)"
  printf 'package main\nimport "core:fmt"\nmain :: proc() { fmt.println("ok") }\n' \
    >"$odin_probe/main.odin"
  if env ODIN_ROOT="$(cd "$(dirname "$(readlink -f "$odin_bin")")" && pwd)" \
       "$odin_bin" build "$odin_probe" -out:"$odin_probe/probe" \
       >"$odin_probe/build.log" 2>&1 && [[ -x "$odin_probe/probe" ]]; then
    note "odin_can_build=yes"
  else
    problem "the Odin compiler is present and cannot BUILD on this host: $(tr '\n' ' ' <"$odin_probe/build.log" | cut -c1-200). A version string is not a toolchain — Odin links through clang, and a missing linker surfaces at the first build of the campaign rather than here."
  fi
  rm -rf "$odin_probe"
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

# RLIMIT_MEMLOCK. Every io_uring ring the framework allocates pins memory against
# this limit, and a host that cannot hold the rings does not fail at the limit —
# it fails at STARTUP, which this repository has already recorded once as
# F-C03-2 and diagnosed the expensive way. The stock AWS AMI ships 8 MiB.
#
# So it is refused here rather than discovered at hour zero of a twelve-hour run,
# where "the server exited before readiness" is a sentence about the product
# produced by a host that was never configured to run it. R2-WP02, and
# R2-restricted-production.md §3 lists memlock among the preflight's own checks.
memlock_kib="$(ulimit -Hl 2>/dev/null || echo 0)"
note "memlock_hard_kib=$memlock_kib"
memlock_min_kib="${DRUSE_SOAK_MIN_MEMLOCK_KIB:-65536}"
if [[ "$memlock_kib" != unlimited ]]; then
  if [[ "$memlock_kib" =~ ^[0-9]+$ ]] && (( memlock_kib < memlock_min_kib )); then
    problem "RLIMIT_MEMLOCK is ${memlock_kib} KiB and the campaign needs at least ${memlock_min_kib} KiB (unlimited is preferred): io_uring rings pin against it, and a ring allocation that fails surfaces as a server that died before readiness — this project has already paid for that once as F-C03-2. Raise it persistently in /etc/security/limits.conf and LimitMEMLOCK=, not just in this shell."
  fi
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

# --- 6b. the host must not change itself under the measurement ---------------
# FOUND BY LOSING A HOST, 2026-08-04. The qualified campaign host was pinned at
# kernel 7.0.0-1006-aws (pre-registration §3.1) and came back from a reboot
# running 7.0.0-1009-aws. Nothing in this script had an opinion about that,
# because every other check reads the host AT REST and this one is about the
# host's future.
#
# Why it is a refusal and not a note. G1 counts the kernel as part of the
# candidate's identity. A twelve-hour final that begins on one kernel and is
# graded on a host that upgraded itself in hour seven is not a run with a
# caveat — it is a run whose environment changed while it was the thing being
# measured, and no artefact records that. §3 already requires "known
# neighbours: none; the host runs nothing else for the window"; an auto-upgrader
# IS something else running, and it was never enumerated.
#
# The refusal is overridable, because a host that upgrades only user-space
# packages is a different risk from one that reboots into a new kernel, and that
# judgement belongs to whoever commits the amendment — not to this script.
auto_upgrade_units=""
if command -v systemctl >/dev/null 2>&1; then
  for unit in unattended-upgrades.service apt-daily-upgrade.timer apt-daily.timer; do
    if systemctl is-enabled "$unit" >/dev/null 2>&1; then
      auto_upgrade_units="$auto_upgrade_units $unit"
    fi
  done
fi
auto_upgrade_units="${auto_upgrade_units# }"
note "auto_upgrade_units=${auto_upgrade_units:-none}"
note "kernel_running=$(uname -r)"
if [[ -n "$auto_upgrade_units" ]]; then
  if [[ "${DRUSE_SOAK_ALLOW_AUTO_UPGRADE:-}" == "1" ]]; then
    note "auto_upgrade_override=yes"
  else
    problem "the host upgrades itself while the campaign runs: $auto_upgrade_units enabled. A run whose kernel or libc changes mid-flight has no artefact that records it (G1). Disable them for the window — 'systemctl disable --now unattended-upgrades.service apt-daily-upgrade.timer apt-daily.timer' — or set DRUSE_SOAK_ALLOW_AUTO_UPGRADE=1 to accept the risk, which stamps the report"
  fi
fi

# --- 7. disk for the raw evidence -------------------------------------------
target_dir="${DRUSE_SOAK_BASE:-$PWD}"
free_kib="$(df -Pk "$target_dir" 2>/dev/null | awk 'NR==2 {print $4}')"
free_gib=$(( ${free_kib:-0} / 1024 / 1024 ))
note "free_gib_at=$target_dir:$free_gib"
note "estimated_need_gib=$MIN_FREE_GIB (for ${HOURS}h at sample_seconds=$SAMPLE_SECONDS)"
# The inputs to the estimate, so a reader of the artefact can recompute it
# instead of taking the number on faith. An estimate whose derivation is not in
# the report is a constant wearing an estimate's label — which is the defect
# this derivation replaced.
note "estimate_rate_total=$DRUSE_RATE_TOTAL"
note "estimate_row_bytes=$DRUSE_CSV_ROW_BYTES"
note "estimate_ladder_floor_gib=$DRUSE_LADDER_FLOOR_GIB"
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
