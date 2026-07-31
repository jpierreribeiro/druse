#!/usr/bin/env bash
# Campaign host preparation. Run as root, once per boot.
#
# Every value here is set because a documented failure in this project traces to
# its default: the CI VPS's ulimit -n 1024 makes the C-03 flood ungeneratable,
# and its 8 MiB RLIMIT_MEMLOCK is the recorded cause of F-C03-2 (io_uring rings
# pin against it, and the vendored server asserted on the failure).
set -euo pipefail

URUQUIM_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
URUQUIM_ARTIFACTS="${URUQUIM_ARTIFACTS:-$URUQUIM_ROOT/artifacts}"
mkdir -p "$URUQUIM_ARTIFACTS"
URUQUIM_STAMP="$(date -u +%Y%m%dT%H%M%SZ)"
URUQUIM_OUT="$URUQUIM_ARTIFACTS/host-state-$URUQUIM_STAMP.txt"

test "$(id -u)" -eq 0 || { echo "must run as root (sysctl + limits)" >&2; exit 1; }

# --- limits ---------------------------------------------------------------
# Session limits, and persistently, because a 24h soak started from a shell that
# inherited the AMI default fails at hour three for a reason nobody traces back
# to descriptors.
ulimit -n 1048576 || echo "WARN: could not raise NOFILE in this shell" >&2
ulimit -l unlimited || echo "WARN: could not raise MEMLOCK in this shell" >&2

if ! grep -q "uruquim-campaign" /etc/security/limits.conf 2>/dev/null; then
  cat >> /etc/security/limits.conf <<'LIM'
# uruquim-campaign
*  soft  nofile   1048576
*  hard  nofile   1048576
*  soft  memlock  unlimited
*  hard  memlock  unlimited
LIM
fi

# --- kernel ---------------------------------------------------------------
# Ephemeral ports and TIME_WAIT reuse, or the flood exhausts the port range long
# before it stresses the acceptor.
sysctl -w net.ipv4.ip_local_port_range="1024 65535"
sysctl -w net.ipv4.tcp_tw_reuse=1
sysctl -w net.ipv4.tcp_fin_timeout=15
# The acceptor's own listen backlog is 1000; do not let the kernel drop SYNs
# before the framework's admission logic is reached.
sysctl -w net.core.somaxconn=65535
sysctl -w net.ipv4.tcp_max_syn_backlog=65535

if lsmod | grep -q nf_conntrack; then
  sysctl -w net.netfilter.nf_conntrack_max=1048576 || true
  echo "NOTE: nf_conntrack is loaded; a full table looks like the server refusing connections" >&2
fi

# --- record ---------------------------------------------------------------
{
  echo "timestamp=$URUQUIM_STAMP"
  echo "commit=$(git -C "$URUQUIM_ROOT" rev-parse HEAD 2>/dev/null || echo unknown)"
  echo
  echo "=== uname ==="; uname -a
  echo; echo "=== lscpu -e (READ THE CORE COLUMN: siblings share a core id) ==="; lscpu -e || true
  echo; echo "=== free -m ==="; free -m
  echo; echo "=== ulimit -a ==="; bash -c 'ulimit -a'
  echo; echo "=== sysctl (relevant) ==="
  sysctl net.ipv4.ip_local_port_range net.ipv4.tcp_tw_reuse net.ipv4.tcp_fin_timeout \
         net.core.somaxconn net.ipv4.tcp_max_syn_backlog 2>/dev/null || true
  echo; echo "=== nf_conntrack loaded? ==="; lsmod | grep -c nf_conntrack || true
  echo; echo "=== io_uring reachable? ==="
  if [ -r /proc/sys/kernel/io_uring_disabled ]; then
    echo "io_uring_disabled=$(cat /proc/sys/kernel/io_uring_disabled)"
  else
    echo "io_uring_disabled=<not present, assume enabled>"
  fi
} | tee "$URUQUIM_OUT"

echo
echo "host state recorded: $URUQUIM_OUT"
echo "COMMIT THIS FILE with every campaign result."
echo
echo "NEXT: confirm the SMT topology above. A c5.2xlarge is 4 physical cores x 2"
echo "threads; if 0-3 and 4-7 are sibling pairs, pin server and client to"
echo "DIFFERENT PHYSICAL CORES (e.g. 0,1,4,5 vs 2,3,6,7), not merely different"
echo "logical CPUs. The existing benchmark pinning may not be the disjoint split"
echo "it claims."
