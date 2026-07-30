#!/usr/bin/env python3
import csv
import json
import pathlib
import statistics
import sys


def slope_per_hour(rows, field):
    points = [
        (float(row["elapsed_s"]), float(row[field]))
        for row in rows[len(rows) // 2 :]
        if float(row[field]) > 0
    ]
    x_mean = statistics.mean(point[0] for point in points)
    y_mean = statistics.mean(point[1] for point in points)
    denominator = sum((point[0] - x_mean) ** 2 for point in points)
    if denominator == 0:
        return 0.0
    per_second = sum(
        (point[0] - x_mean) * (point[1] - y_mean) for point in points
    ) / denominator
    return per_second * 3600


root = pathlib.Path(sys.argv[1])
with (root / "telemetry/process.csv").open() as handle:
    telemetry = list(csv.DictReader(handle))
with (root / "cycles.csv").open() as handle:
    cycles = list(csv.DictReader(handle))

health_p99 = [int(row["health_p99_us"]) for row in cycles]
health_errors = [int(row["health_transport_errors"]) for row in cycles]
rss = [int(row["rss_kib"]) for row in telemetry if int(row["rss_kib"]) > 0]
hwm = [int(row["hwm_kib"]) for row in telemetry if int(row["hwm_kib"]) > 0]
threads = [int(row["threads"]) for row in telemetry if int(row["threads"]) > 0]
fds = [int(row["fds"]) for row in telemetry]
stats_missing = [row for row in telemetry if row["stats_http"] != "200"]

workloads = {}
for name in ("health", "tiny", "json-encode", "json-decode", "bytes-64k", "wait-40ms"):
    files = sorted((root / "cycles").glob(f"c*-{name}.json"))
    reports = [json.loads(path.read_text()) for path in files]
    statuses = {}
    # Failure classes are aggregated here for the same reason the statuses are:
    # a key that is not carried forward is a key that is discarded, and this
    # analyser's own first run proved the point — it counted 212 failures and
    # reported zero classified, because this loop built a workload dict with no
    # `failures` in it while the reports had them all along.
    failure_counts = {}
    failure_examples = {}
    for report in reports:
        for status, count in report["status"].items():
            statuses[status] = statuses.get(status, 0) + count
        for entry in report.get("failures", []):
            klass = entry.get("class") or "unnamed"
            failure_counts[klass] = failure_counts.get(klass, 0) + entry.get("count", 0)
            if entry.get("example_error") and klass not in failure_examples:
                failure_examples[klass] = entry["example_error"]
    workloads[name] = {
        "runs": len(reports),
        "planned": sum(report["planned"] for report in reports),
        "completed": sum(report["completed"] for report in reports),
        "transport_errors": sum(report["transport_errors"] for report in reports),
        "status": statuses,
        "failures": [
            {
                "class": klass,
                "count": count,
                "example_error": failure_examples.get(klass, ""),
            }
            for klass, count in sorted(
                failure_counts.items(), key=lambda item: -item[1]
            )
        ],
        "median_p99_us": statistics.median(
            report["latency_p99_us"] for report in reports
        ) if reports else None,
        "max_p99_us": max(
            (report["latency_p99_us"] for report in reports), default=None
        ),
    }

summary = {
    "result": "PASS",
    "cycles": len(cycles),
    "telemetry_samples": len(telemetry),
    "rss_kib": {
        "first": rss[0],
        "last": rss[-1],
        "min": min(rss),
        "max": max(rss),
        "tail_slope_kib_per_hour": slope_per_hour(telemetry, "rss_kib"),
    },
    "hwm_kib": {"max": max(hwm)},
    "threads": {"min": min(threads), "max": max(threads)},
    "fds": {"first": fds[0], "last": fds[-1], "max": max(fds)},
    "stats_missing_samples": len(stats_missing),
    "health": {
        "transport_errors": sum(health_errors),
        "median_p99_us": statistics.median(health_p99),
        "max_p99_us": max(health_p99),
        "cycles_over_250ms": sum(value > 250_000 for value in health_p99),
    },
    "workloads": workloads,
}

reasons = []
if summary["health"]["transport_errors"]:
    reasons.append("health transport errors")
if summary["health"]["cycles_over_250ms"]:
    reasons.append("health p99 exceeded 250 ms")
if min(threads) != max(threads):
    reasons.append("thread count changed")
if fds[-1] > fds[0] + 4:
    reasons.append("file descriptors did not settle")
if len(telemetry) >= 720 and summary["rss_kib"]["tail_slope_kib_per_hour"] > 1024:
    reasons.append("RSS tail slope exceeded 1 MiB/hour")
if (root / "control/safety-stop.txt").exists():
    reasons.append("RSS safety stop")
if (root / "control/server-died.txt").exists():
    reasons.append("server died")
if (root / "control/load-errors.txt").exists():
    reasons.append("load generator process failed")
final_state = {}
for line in (root / "control/final-state.txt").read_text().splitlines():
    key, value = line.split("=", 1)
    final_state[key] = int(value)
if final_state.get("forced_kill", 1):
    reasons.append("server required SIGKILL")
if final_state.get("server_exit", -1) != 0:
    reasons.append(f"server exit was {final_state.get('server_exit')}")
expected_status = {
    "health": "200",
    "tiny": "200",
    "json-encode": "200",
    "json-decode": "204",
    "bytes-64k": "200",
    "wait-40ms": "200",
}
# A profile can be absent because the run deliberately excluded it — the
# saturation experiment removes the blocking handler by setting its rate to
# zero, and the orchestrator records that in control/skipped.txt. Without this,
# a profile with no runs divides by a planned count of zero, is charged a
# transport error ratio of 1.0, and fails the run for never having happened.
#
# Absence WITH a recorded reason is fine. Absence WITHOUT one is red: a profile
# that vanished and nobody wrote down why is exactly the shape of defect this
# analyser exists to refuse.
skipped = {}
skipped_path = root / "control/skipped.txt"
if skipped_path.exists():
    for line in skipped_path.read_text().splitlines():
        fields = dict(
            part.split("=", 1) for part in line.split() if "=" in part
        )
        if "skipped" in fields:
            skipped[fields["skipped"]] = fields.get("reason", "unstated")
summary["skipped_workloads"] = skipped

for name, workload in list(workloads.items()):
    if workload["runs"] == 0:
        if name in skipped:
            workload["skipped_reason"] = skipped[name]
            workload["transport_error_ratio"] = None
            workload["unexpected_http_status"] = {}
            continue
        reasons.append(
            f"{name} produced no runs and control/skipped.txt gives no reason: "
            "a profile disappeared from the run unexplained"
        )
        workload["transport_error_ratio"] = None
        workload["unexpected_http_status"] = {}
        continue
    error_ratio = (
        workload["transport_errors"] / workload["planned"]
        if workload["planned"]
        else 1.0
    )
    workload["transport_error_ratio"] = error_ratio
    unexpected = {
        status: count
        for status, count in workload["status"].items()
        if status not in ("0", expected_status[name])
    }
    workload["unexpected_http_status"] = unexpected
    if name == "health" and workload["transport_errors"]:
        reasons.append("health workload transport errors")
    elif name != "health" and error_ratio > 0.0001:
        reasons.append(f"{name} transport error ratio exceeded 0.01%")
    if unexpected:
        reasons.append(f"{name} returned unexpected HTTP status")

# ---------------------------------------------------------------------------
# ACCOUNTING, NOT TOLERANCE (planning/diagnosability.md rule 3).
#
# The rule above — "at most 0.01% transport error" — is satisfied by 674
# unexplained failures exactly as well as by zero, which is how a 12-hour run
# passed while nobody could say what a single one of those failures was. It is
# kept, because a rate ceiling is still worth having, and this second rule is
# added on top of it:
#
#   every failure must carry a named class, and no class may be "unclassified".
#
# The generator classifies each failure into a closed taxonomy and preserves the
# error text. A cause the taxonomy does not recognise arrives here as
# "unclassified", and an unclassified failure FAILS the run regardless of how
# small the rate is. A new failure mode is then a red run with a verbatim
# example attached, instead of a number inside an allowance.
# ---------------------------------------------------------------------------
failure_classes = {}
unclassified_total = 0
examples = {}
for name, workload in workloads.items():
    for entry in workload.get("failures", []):
        klass = entry.get("class") or "unnamed"
        failure_classes[klass] = failure_classes.get(klass, 0) + entry.get("count", 0)
        examples.setdefault(klass, entry.get("example_error", ""))
        if klass in ("unclassified", "unnamed"):
            unclassified_total += entry.get("count", 0)

counted = sum(workload["transport_errors"] for workload in workloads.values())
classified = sum(failure_classes.values())

summary["failure_classes"] = failure_classes
summary["failure_examples"] = examples
summary["failures_counted"] = counted
summary["failures_classified"] = classified
summary["failures_unclassified"] = unclassified_total

if unclassified_total:
    reasons.append(
        f"{unclassified_total} failure(s) of an unrecognised class — the run is "
        "red because the cause is unknown, not because the rate is high"
    )
if counted != classified:
    reasons.append(
        f"{counted - classified} failure(s) counted but not classified: the "
        "instrument lost a cause it observed, which is the defect this analyser "
        "exists to refuse"
    )

summary["reasons"] = reasons
if reasons:
    summary["result"] = "FAIL"
print(json.dumps(summary, indent=2, sort_keys=True))
