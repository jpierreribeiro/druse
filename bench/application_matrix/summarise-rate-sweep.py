#!/usr/bin/env python3
"""Summarise a rate sweep and locate each server's knee.

The knee is the offered rate at which goodput stops tracking the offer. It is
the number a capacity claim needs, and it is the boundary that decides whether a
latency figure means anything: below it p50 is a service time, above it p50 is a
queue depth and comparing it across servers compares queues.

Reports, per server and rate: goodput, share of the offered rate, p50, p99, and
failures by class. Then, per server, the knee and the p50 measured at the
highest rate that still served the offer — which is the closest thing to a
service time this instrument can produce.
"""
import json
import pathlib
import re
import statistics
import sys

root = pathlib.Path(sys.argv[1])
manifest = {}
manifest_path = root / "manifest.txt"
if manifest_path.exists():
    for line in manifest_path.read_text().splitlines():
        if "=" in line:
            key, value = line.split("=", 1)
            manifest[key] = value

# A server is treated as serving the offered rate while goodput is within this
# fraction of it. 2% is comfortably outside run-to-run noise on a dedicated host
# and well inside the collapse that follows a knee.
SERVED = 0.98

runs = {}
for path in sorted((root / "runs").glob("*.json")):
    match = re.match(r"(.+?)-(\d+)-r(\d+)\.json$", path.name)
    if not match:
        continue
    server, rate = match.group(1), int(match.group(2))
    try:
        report = json.loads(path.read_text())
    except Exception:
        continue
    runs.setdefault((server, rate), []).append(report)

servers = sorted({key[0] for key in runs})
rates = sorted({key[1] for key in runs})

print(f"rate sweep — {manifest.get('endpoint', '?')}, "
      f"{manifest.get('repeats', '?')} repeats, "
      f"{manifest.get('seconds_per_run', '?')}s each, "
      f"{manifest.get('druse_lanes', '?')} Druse lanes")
print(f"commit {manifest.get('git_head', 'unknown')[:12]}  "
      f"kernel {manifest.get('kernel', '?')}")
print()

sizes_seen = {}
knees = {}
service = {}

for server in servers:
    print(f"### {server}")
    print(f"  {'offered/s':>10} {'goodput/s':>10} {'% served':>9} {'B/resp':>8} "
          f"{'p50 us':>10} {'p99 us':>10} {'failures':>9}  classes")
    knee = None
    last_served_rate = None
    for rate in rates:
        reports = runs.get((server, rate))
        if not reports:
            continue
        goodput = statistics.median(r.get("goodput_per_second", 0) for r in reports)
        p50 = statistics.median(r.get("latency_p50_us", 0) for r in reports)
        p99 = statistics.median(r.get("latency_p99_us", 0) for r in reports)
        failures = sum(r.get("transport_errors", 0) for r in reports)
        classes = {}
        for report in reports:
            for entry in report.get("failures", []):
                classes[entry["class"]] = classes.get(entry["class"], 0) + entry["count"]
        per_response = [
            r.get("response_bytes", 0) / r["succeeded"] for r in reports if r.get("succeeded")
        ]
        size = statistics.median(per_response) if per_response else 0
        sizes_seen.setdefault(server, size)

        share = goodput / rate if rate else 0
        served = share >= SERVED
        if served:
            last_served_rate = rate
            service[server] = (rate, p50, p99)
        elif knee is None:
            knee = rate
        mark = "" if served else "  <- past the knee; p50 is a queue depth"
        print(f"  {rate:10,} {goodput:10,.0f} {share*100:8.1f}% {size:8,.0f} "
              f"{p50:10,.0f} {p99:10,.0f} {failures:9,}  "
              f"{classes if classes else ''}{mark}")
    knees[server] = (knee, last_served_rate)
    print()

print("### knees")
print(f"  {'server':10} {'last rate served':>18} {'first rate missed':>19} "
      f"{'p50 at last served':>20} {'p99 there':>12}")
for server in servers:
    knee, last = knees.get(server, (None, None))
    if server in service:
        rate, p50, p99 = service[server]
        print(f"  {server:10} {last:>18,} {str(knee) if knee else 'not reached':>19} "
              f"{p50:>17,.0f} us {p99:>9,.0f} us")
    else:
        print(f"  {server:10} {'none — missed every rate':>18} "
              f"{str(knee):>19}")
print()

if len(set(round(v) for v in sizes_seen.values())) > 1:
    print("  !! RESPONSE SIZES DIFFER between servers on this endpoint:")
    for server, size in sorted(sizes_seen.items(), key=lambda kv: kv[1]):
        print(f"       {server:10} {size:8,.0f} B/resp")
    print("     The knees below are not comparable across servers: they are "
          "knees for different payloads.")
else:
    size = next(iter(sizes_seen.values()), 0)
    print(f"  All servers answered {size:,.0f} bytes per response, so these "
          f"knees are comparable.")
