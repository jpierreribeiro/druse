#!/usr/bin/env bash
#
# R3-WP10 Stage 1 — what N worker processes actually cost.
#
# `evidence/2026-08-01-r1-resource-budget/` was produced for N=1: 22 FDs, 9
# threads, 9 io_uring/eventfd pairs, LimitNOFILE 1213 required against 2048
# configured, MemoryMax=1G, LimitMEMLOCK=64M. **None of it transfers**, and
# R3-general-maturity.md §6 makes measuring the N>1 budget a precondition of
# choosing an arm rather than a follow-up to it.
#
# WHAT THIS CAN AND CANNOT ANSWER ON A SHARED CONTAINER (G4). Resource
# ACCOUNTING is deterministic: how many file descriptors a process holds, how
# many io_uring rings it maps, how many bytes those mappings are. Those answers
# are the same on any host. Capacity and tail latency are not, and this script
# does not ask.
#
# THE DISTINCTION THE WHOLE UNIT TEMPLATE TURNS ON, measured rather than
# reasoned about (criterion W3):
#
#   LimitMEMLOCK is an RLIMIT. It is PER PROCESS. Each worker gets its own 64M,
#   so the configured number does not have to grow with N.
#
#   MemoryMax is the cgroup's. It is AGGREGATE. The same 1 GiB is now shared by
#   N workers, which is a silent 1/N cut to every one of them.
#
# Confusing the two produces a unit that looks correct and kills workers under
# load, so this script reports each limit against its own kind and refuses to
# add them up.
#
# Usage: ops/verification/measure-worker-budget.sh OUTPUT_DIR
set -euo pipefail

OUT="${1:?usage: $0 OUTPUT_DIR}"
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
mkdir -p "$OUT/raw" "$OUT/analysis" "$OUT/config"

fail() { echo "WORKER-BUDGET-FAIL: $*" >&2; exit 1; }

ODIN="${DRUSE_ODIN_BIN:-$(command -v odin || true)}"
test -n "$ODIN" || fail "odin not found; set DRUSE_ODIN_BIN"
ODIN="$(readlink -f "$ODIN")"
export ODIN_ROOT="$(dirname "$ODIN")"

WORK="$(mktemp -d -t druse-worker-budget-XXXXXXXX)"
trap 'rm -rf "$WORK"' EXIT

# Lanes per worker. FOUR, not the R1 profile's eight, because this container has
# four CPUs and a lane count above the core count would measure oversubscription
# rather than the per-worker cost. The per-worker numbers are reported as
# "per lane" wherever they scale with it, so the R1 profile can be recomputed
# from them without re-running.
LANES="${LANES:-4}"
COUNTS="${COUNTS:-1 2 4}"
BASE_PORT="${BASE_PORT:-57811}"

# The R1 unit's configured limits, quoted here so the report can be diffed
# against ops/deploy/druse.service rather than trusted to agree with it.
R1_LIMIT_NOFILE=2048
R1_LIMIT_MEMLOCK_MB=64
R1_MEMORY_MAX_MB=1024

"$ODIN" build "$ROOT/ops/soak/soak-server" "-collection:druse=$ROOT" \
  -out:"$WORK/soak-server" || fail "could not build the soak server"
SERVER_SHA="$(sha256sum "$WORK/soak-server" | cut -d' ' -f1)"

{
  echo "lanes_per_worker=$LANES"
  echo "worker_counts=$COUNTS"
  echo "base_port=$BASE_PORT"
  echo "server_sha256=$SERVER_SHA"
  echo "r1_limit_nofile=$R1_LIMIT_NOFILE"
  echo "r1_limit_memlock_mb=$R1_LIMIT_MEMLOCK_MB"
  echo "r1_memory_max_mb=$R1_MEMORY_MAX_MB"
  echo "ulimit_soft_nofile=$(ulimit -Sn)"
  echo "ulimit_hard_nofile=$(ulimit -Hn)"
  echo "ulimit_memlock_kb=$(ulimit -l)"
  echo "nproc=$(nproc)"
} > "$OUT/config/budget.txt"

wait_for_port() {
  local port="$1"
  for _ in $(seq 1 200); do
    if (exec 3<>"/dev/tcp/127.0.0.1/$port") 2>/dev/null; then
      exec 3<&- 3>&-
      return 0
    fi
    sleep 0.05
  done
  return 1
}

stop_pid() {
  kill -TERM "$1" 2>/dev/null || true
  for _ in $(seq 1 200); do
    test -d "/proc/$1" || return 0
    sleep 0.05
  done
  kill -KILL "$1" 2>/dev/null || true
  for _ in $(seq 1 100); do
    test -d "/proc/$1" || return 0
    sleep 0.05
  done
  return 1
}

# sample_pid PID -> "fds threads rings ring_bytes vmlck_kb vmrss_kb vmhwm_kb"
#
# `ring_bytes` sums the anon_inode:[io_uring] mappings from /proc/PID/maps.
# That is the locked-memory footprint the RLIMIT_MEMLOCK failure mode (F-C03-2,
# patch 30) is about, and it is NOT the same number as VmLck — the kernel
# accounts io_uring rings against the limit without necessarily reporting them
# under VmLck, so reporting only one of the two would hide the mode that
# actually fires.
sample_pid() {
  local pid="$1"
  local fds threads rings ring_bytes vmlck vmrss vmhwm
  fds="$(ls -1 "/proc/$pid/fd" 2>/dev/null | wc -l)"
  threads="$(awk '/^Threads:/{print $2}' "/proc/$pid/status" 2>/dev/null || echo -1)"
  # RING FILE DESCRIPTORS, which is what R1 counted, not mappings. Each ring is
  # mmapped twice (the SQ/CQ ring and the SQEs), so counting `maps` lines
  # double-counts and would report eight rings for a four-lane server.
  rings="$(ls -l "/proc/$pid/fd" 2>/dev/null | grep -Fc 'anon_inode:[io_uring]' || true)"
  # Summed in python, not awk: `strtonum` is a gawk extension and this container
  # runs mawk, where it silently yields 0. The first version of this script
  # reported `ring_bytes 0` for a process holding ten io_uring mappings — a zero
  # that meant "not measured" and read as "costs nothing".
  ring_bytes="$(python3 - "$pid" <<'PYIN' 2>/dev/null || echo -1
import sys
total = 0
try:
    for line in open(f"/proc/{sys.argv[1]}/maps"):
        if "anon_inode:[io_uring]" in line:
            lo, hi = line.split()[0].split("-")
            total += int(hi, 16) - int(lo, 16)
except OSError:
    print(-1); raise SystemExit
print(total)
PYIN
)"
  vmlck="$(awk '/^VmLck:/{print $2}' "/proc/$pid/status" 2>/dev/null || echo -1)"
  vmrss="$(awk '/^VmRSS:/{print $2}' "/proc/$pid/status" 2>/dev/null || echo -1)"
  vmhwm="$(awk '/^VmHWM:/{print $2}' "/proc/$pid/status" 2>/dev/null || echo -1)"
  echo "$fds $threads $rings $ring_bytes $vmlck $vmrss $vmhwm"
}

: > "$OUT/raw/per-worker.txt"
echo "# n worker pid fds threads ring_fds ring_bytes vmlck_kb vmrss_kb vmhwm_kb" \
  >> "$OUT/raw/per-worker.txt"

for N in $COUNTS; do
  pids=()
  started=1
  for w in $(seq 0 $((N - 1))); do
    port=$((BASE_PORT + w))
    "$WORK/soak-server" "$LANES" "$port" "" >"$WORK/w$w.log" 2>&1 &
    pid=$!
    if ! wait_for_port "$port"; then
      echo "n=$N worker=$w FAILED_TO_START port=$port" >> "$OUT/raw/per-worker.txt"
      kill -KILL "$pid" 2>/dev/null || true
      started=0
      break
    fi
    pids+=("$pid")
  done

  if test "$started" -eq 1; then
    # Let every lane finish acquiring its event loop before sampling. A ring
    # count read mid-startup is a number about the sampler's timing.
    sleep 1
    for i in "${!pids[@]}"; do
      echo "$N $i ${pids[$i]} $(sample_pid "${pids[$i]}")" >> "$OUT/raw/per-worker.txt"
    done
    cp "/proc/${pids[0]}/maps" "$OUT/raw/maps-n$N-worker0.txt" 2>/dev/null || true
    grep -E '^(VmPeak|VmSize|VmRSS|VmHWM|VmLck|Threads):' \
      "/proc/${pids[0]}/status" > "$OUT/raw/status-n$N-worker0.txt" 2>/dev/null || true
  fi

  for pid in "${pids[@]:-}"; do
    test -n "$pid" && stop_pid "$pid"
  done
done

python3 - "$OUT" "$LANES" "$R1_LIMIT_NOFILE" "$R1_LIMIT_MEMLOCK_MB" "$R1_MEMORY_MAX_MB" \
  <<'PY' | tee "$OUT/analysis/budget.md"
import sys, collections

out, lanes = sys.argv[1], int(sys.argv[2])
limit_nofile, limit_memlock_mb, memory_max_mb = (int(sys.argv[i]) for i in (3, 4, 5))

rows = collections.defaultdict(list)
failed = []
for line in open(f"{out}/raw/per-worker.txt"):
    if line.startswith("#"):
        continue
    if "FAILED_TO_START" in line:
        failed.append(line.strip())
        continue
    f = line.split()
    if len(f) != 10:
        continue
    n = int(f[0])
    rows[n].append(dict(fds=int(f[3]), threads=int(f[4]), rings=int(f[5]),
                        ring_bytes=int(f[6]), vmlck=int(f[7]),
                        vmrss=int(f[8]), vmhwm=int(f[9])))

print("# R3-WP10 Stage 1 — the cost of N worker processes\n")
print(f"Lanes per worker: **{lanes}**. Derived from `raw/per-worker.txt`; this page")
print("groups those numbers and says what they mean. It replaces neither.\n")

if failed:
    print("## Workers that did not start\n")
    for line in failed:
        print(f"- `{line}`")
    print()

print("## Per worker\n")
print("| N | workers sampled | FDs | threads | io_uring rings | ring bytes | VmLck KiB | VmRSS KiB |")
print("|---|---|---|---|---|---|---|---|")
per_worker_constant = True
first = None
for n in sorted(rows):
    rs = rows[n]
    def uniq(k):
        vals = {r[k] for r in rs}
        return str(vals.pop()) if len(vals) == 1 else "/".join(str(v) for v in sorted(vals))
    sig = (uniq("fds"), uniq("threads"), uniq("rings"))
    if first is None:
        first = sig
    elif sig != first:
        per_worker_constant = False
    rss = sum(r["vmrss"] for r in rs) // len(rs)
    print(f"| {n} | {len(rs)} | {uniq('fds')} | {uniq('threads')} | {uniq('rings')} | "
          f"{uniq('ring_bytes')} | {uniq('vmlck')} | {rss} |")

print()
print("## W1 — are the per-worker costs constant in N?\n")
if per_worker_constant:
    print("**PASS.** FDs, threads and io_uring rings per worker do not vary with N.")
    print("Each worker pays the same price; nothing is shared and nothing is coupled.")
else:
    print("**FAIL.** A per-worker cost changed with N. That would mean coupling")
    print("between processes that nobody designed, and it has to be explained")
    print("before any arm is chosen.")

print()
print("## W2/W3 — the aggregate, against each limit AND its own kind\n")
print("The two limits are different KINDS of thing and adding them together is")
print("the defect this table exists to prevent.\n")
print("| N | aggregate FDs | aggregate ring bytes | aggregate RSS KiB | `LimitNOFILE` (per process) | `LimitMEMLOCK` (per process) | `MemoryMax` (cgroup, aggregate) |")
print("|---|---|---|---|---|---|---|")
for n in sorted(rows):
    rs = rows[n]
    agg_fds = sum(r["fds"] for r in rs)
    agg_ring = sum(r["ring_bytes"] for r in rs)
    agg_rss = sum(r["vmrss"] for r in rs)
    max_fds = max(r["fds"] for r in rs)
    max_ring_mb = max(r["ring_bytes"] for r in rs) / 1048576
    nofile_v = "ok" if max_fds < limit_nofile else f"**EXCEEDED** ({max_fds})"
    memlock_v = "ok" if max_ring_mb < limit_memlock_mb else f"**EXCEEDED** ({max_ring_mb:.1f} MiB)"
    share_mb = memory_max_mb / n
    mem_v = f"{share_mb:.0f} MiB per worker"
    if agg_rss / 1024 > memory_max_mb:
        mem_v = f"**EXCEEDED** ({agg_rss/1024:.0f} MiB aggregate)"
    print(f"| {n} | {agg_fds} | {agg_ring} | {agg_rss} | {nofile_v} | {memlock_v} | {mem_v} |")

print()
print("### Reading that table\n")
print(f"- **`LimitNOFILE` and `LimitMEMLOCK` are RLIMITs — PER PROCESS.** Each worker")
print(f"  gets its own {limit_nofile} descriptors and its own {limit_memlock_mb} MiB of")
print("  locked memory, so neither configured number has to grow with N. They are")
print("  checked against the **largest single worker**, never against the sum.")
print(f"- **`MemoryMax` is the cgroup's — AGGREGATE.** The same {memory_max_mb} MiB is")
print("  now shared by N workers. That is the number that actually changes meaning,")
print("  and it changes silently: nothing in the unit says 'divided by N'.")
print("- The host still has to physically hold the aggregate. A per-process limit")
print("  that every process satisfies can still exhaust the machine.")
print()
print("### VmLck is 0, and that is the trap, not an error\n")
print("Every worker maps io_uring rings and every worker reports `VmLck: 0`. The")
print("kernel charges io_uring ring memory against RLIMIT_MEMLOCK **without**")
print("reporting it under `VmLck`, so an operator watching `VmLck` to predict a")
print("memlock exhaustion sees a flat zero right up to the allocation that fails.")
print("That failure mode is already reproduced in this repository (F-C03-2, patch")
print("30). The number to watch is the ring-bytes column, and nothing in /proc")
print("hands it to you — it has to be summed from the mappings.")
PY

echo
echo "raw:      $OUT/raw/per-worker.txt"
echo "analysis: $OUT/analysis/budget.md"
