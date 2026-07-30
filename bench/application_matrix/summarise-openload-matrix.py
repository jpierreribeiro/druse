#!/usr/bin/env python3
"""Summarise an open-loop application-matrix run.

Reports the median across repeats, per server and endpoint, of:

  goodput      successful responses per second, against the offered rate
  p50/p99      latency measured FROM THE SCHEDULED TIME, so a server that falls
               behind shows it here instead of being asked for less
  failures     by class, because a comparison that hides failures is comparing
               a server that answered with one that did not

A server whose goodput is materially below the offered rate did not serve the
workload, and its latency numbers describe a queue rather than the server. That
is stated per row rather than left for the reader to notice.
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

offered = int(manifest.get("rate_per_second", 0))

runs = {}
for path in sorted((root / "runs").glob("*.json")):
    match = re.match(r"(.+?)-(.+)-r(\d+)\.json$", path.name)
    if not match:
        continue
    server, endpoint, repeat = match.group(1), match.group(2), int(match.group(3))
    try:
        report = json.loads(path.read_text())
    except Exception:
        continue
    runs.setdefault((server, endpoint), []).append(report)

servers = sorted({key[0] for key in runs})
endpoints = sorted({key[1] for key in runs})

print(f"open-loop application matrix — offered {offered:,}/s, "
      f"{manifest.get('repeats', '?')} repeats, "
      f"{manifest.get('seconds_per_run', '?')}s each")
print(f"commit {manifest.get('git_head', '?')[:12]}  kernel {manifest.get('kernel', '?')}")
print()

for endpoint in endpoints:
    print(f"### {endpoint}")
    print(f"  {'server':10} {'goodput/s':>10} {'% offered':>10} {'p50 us':>9} "
          f"{'p99 us':>9} {'failures':>9}  classes")
    for server in servers:
        reports = runs.get((server, endpoint))
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
        share = (goodput / offered * 100) if offered else 0
        note = ""
        if offered and goodput < offered * 0.95:
            note = "  <- did not serve the offered rate; latency here is a queue"
        print(f"  {server:10} {goodput:10,.0f} {share:9.1f}% {p50:9,.0f} {p99:9,.0f} "
              f"{failures:9,}  {classes if classes else ''}{note}")
    print()

unclassified = 0
for reports in runs.values():
    for report in reports:
        unclassified += report.get("unclassified", 0)
if unclassified:
    print(f"WARNING: {unclassified} failure(s) of an unrecognised class. "
          f"planning/diagnosability.md rule 3: a cause that cannot be named "
          f"invalidates the run, not just the row.")
