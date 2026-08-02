#!/usr/bin/env python3
"""Grade a soak run directory against ops/soak/CRITERIA.md.

Contract: this program ALWAYS prints one JSON object and ALWAYS exits 0. The
verdict is `result`, and every reason it is not PASS is in `reasons`. Exit 0
means "a verdict was produced", not "the run was good".

That contract is the first thing R2-WP01 fixed. The previous edition raised
FileNotFoundError from pathlib when a run died before writing
control/final-state.txt — the single most likely artefact a bad night produces.
A crashing analyser has no verdict at all, so the run gets graded by whoever is
awake, which is the failure mode this whole instrument exists to remove.

The rule throughout: a missing, short, or malformed artefact is a NAMED FAILURE,
never a traceback and never a silently skipped criterion. Skipping is the worse
of the two. A traceback at least stops; a criterion that quietly does not apply
lets a run pass for a reason nobody chose. Both were present here, and the
second one — telemetry/process.csv holding two rows of a twelve-hour run, which
made the RSS-slope rule (`len(telemetry) >= 720`) not run at all — passed.
"""
import csv
import hashlib
import json
import pathlib
import statistics
import sys

SCHEMA_VERSION = "soak/1"
HERE = pathlib.Path(__file__).resolve().parent

WORKLOADS = ("health", "tiny", "json-encode", "json-decode", "bytes-64k", "wait-40ms")
EXPECTED_STATUS = {
    "health": "200",
    "tiny": "200",
    "json-encode": "200",
    "json-decode": "204",
    "bytes-64k": "200",
    "wait-40ms": "200",
}
TELEMETRY_COLUMNS = (
    "sample", "utc", "unix_nanos", "elapsed_s", "rss_kib", "hwm_kib", "threads",
    "fds", "proc_ticks", "host_ticks", "stats_http", "stats_curl_exit",
    "stats_bytes", "listen_overflows", "listen_drops", "tcp_abort_on_close",
    "tcp_retrans",
)
KERNEL_COLUMNS = ("listen_overflows", "listen_drops", "tcp_abort_on_close", "tcp_retrans")

# curl's exit codes, so a /stats failure arrives as a cause rather than a count.
CURL_EXIT_MEANING = {
    "0": "no error",
    "6": "could not resolve host",
    "7": "connection refused",
    "18": "partial transfer",
    "28": "operation timed out",
    "52": "empty reply from server",
    "55": "send failure",
    "56": "receive failure",
}

# A sampler is allowed to miss a few ticks under load; it is not allowed to
# stop. 2% of the expected samples is the tolerance, and it is stated here
# rather than discovered from a result.
SAMPLE_SHORTFALL_TOLERANCE = 0.02


def sha256_of(path):
    try:
        return hashlib.sha256(path.read_bytes()).hexdigest()
    except OSError:
        return None


def read_key_values(path):
    """Parse a key=value control file. Returns (dict, error-or-None).

    Later keys win: manifest.txt is appended to after the run, and a completion
    key must be able to overwrite a provisional one.
    """
    try:
        text = path.read_text()
    except FileNotFoundError:
        return {}, "missing"
    except (OSError, UnicodeDecodeError) as error:
        # UnicodeDecodeError is caught here, not left to the top-level net: a
        # corrupt manifest must not stop the analyser reading the telemetry and
        # the cycles. One damaged file should cost one reason, not the grade.
        return {}, f"unreadable: {error}"
    values = {}
    for number, line in enumerate(text.splitlines(), start=1):
        line = line.strip()
        if not line or line.startswith("#"):
            continue
        if "=" not in line:
            # Not fatal, and not ignored either. A line the producer wrote and
            # the consumer cannot parse is a disagreement about the schema.
            values.setdefault("__malformed__", []).append(f"line {number}: {line!r}")
            continue
        key, value = line.split("=", 1)
        values[key.strip()] = value.strip()
    return values, None


def as_int(values, key, default=None):
    try:
        return int(str(values.get(key, "")).strip())
    except (TypeError, ValueError):
        return default


def slope_per_hour(rows, field):
    """Least-squares slope over the second half. None when it cannot be computed.

    Returning None rather than 0.0 matters: 0.0 is a measurement ("flat") and
    None is the absence of one. The caller turns absence into a reason.
    """
    points = []
    for row in rows[len(rows) // 2:]:
        try:
            x, y = float(row["elapsed_s"]), float(row[field])
        except (KeyError, TypeError, ValueError):
            continue
        if y > 0:
            points.append((x, y))
    if len(points) < 2:
        return None
    x_mean = statistics.mean(point[0] for point in points)
    y_mean = statistics.mean(point[1] for point in points)
    denominator = sum((point[0] - x_mean) ** 2 for point in points)
    if denominator == 0:
        return 0.0
    per_second = sum(
        (point[0] - x_mean) * (point[1] - y_mean) for point in points
    ) / denominator
    return per_second * 3600


def column_ints(rows, field, positive_only=False):
    values = []
    for row in rows:
        try:
            value = int(row[field])
        except (KeyError, TypeError, ValueError):
            continue
        if positive_only and value <= 0:
            continue
        values.append(value)
    return values


def analyse(root):
    summary = {"result": "PASS", "schema_version_expected": SCHEMA_VERSION}
    reasons = []

    # ------------------------------------------------------------------
    # Identity. Before any measurement is read, establish that the artefact
    # says which candidate it is about and which criteria it was judged by.
    # ------------------------------------------------------------------
    manifest, manifest_error = read_key_values(root / "manifest.txt")
    summary["manifest"] = {k: v for k, v in manifest.items() if k != "__malformed__"}
    if manifest_error:
        reasons.append(
            f"manifest.txt is {manifest_error}: the run recorded no identity, so "
            "there is no candidate to attribute this result to"
        )
    for malformed in manifest.get("__malformed__", []):
        reasons.append(f"manifest.txt has a line the schema does not define ({malformed})")

    schema_version = manifest.get("schema_version")
    summary["schema_version"] = schema_version
    if manifest and schema_version != SCHEMA_VERSION:
        reasons.append(
            f"artefact schema is {schema_version!r} and this analyser implements "
            f"{SCHEMA_VERSION!r}: an artefact from an unknown producer cannot be graded"
        )

    # A criteria file edited between the run and its grading is the "moved the
    # goalposts" failure, and it is invisible unless the run pinned the hash.
    for label, filename in (("criteria", "CRITERIA.md"), ("schema", "schema.md")):
        recorded = manifest.get(f"{label}_sha256")
        if not recorded:
            if manifest:
                reasons.append(
                    f"the run pinned no {label}_sha256, so nothing proves it was "
                    f"judged by the {filename} in the tree today"
                )
            continue
        actual = sha256_of(HERE / filename)
        summary.setdefault("pins", {})[label] = {"run": recorded, "tree": actual}
        if actual is None:
            reasons.append(f"ops/soak/{filename} is unreadable; the {label} pin cannot be checked")
        elif actual != recorded:
            reasons.append(
                f"{filename} changed after the run: manifest pinned {recorded[:12]}, "
                f"the tree holds {actual[:12]}. The criteria a run is graded by "
                "cannot be edited between the run and the grade"
            )

    if manifest.get("git_dirty") == "1" and manifest.get("allow_dirty") != "1":
        reasons.append(
            "the working tree was dirty and DRUSE_SOAK_ALLOW_DIRTY was not set: "
            "the measured artefact is not identified by any commit"
        )
    if manifest.get("allow_dirty") == "1":
        reasons.append(
            "the run was taken with DRUSE_SOAK_ALLOW_DIRTY=1: it is a diagnostic, "
            "not evidence for a promotion decision"
        )

    # The binaries that finished must be the binaries that started.
    final_binaries, binaries_error = read_key_values(root / "control/final-binaries.txt")
    if binaries_error:
        if manifest:
            reasons.append(
                f"control/final-binaries.txt is {binaries_error}: nothing proves the "
                "binary that finished the run is the one whose hash the manifest carries"
            )
    else:
        for key in ("server_sha256", "openload_sha256"):
            before, after = manifest.get(key), final_binaries.get(key)
            if before and after and before != after:
                reasons.append(
                    f"{key} changed during the run ({before[:12]} -> {after[:12]}): "
                    "the artefact measured more than one candidate"
                )

    # ------------------------------------------------------------------
    # Did the run finish at all?
    # ------------------------------------------------------------------
    summary["complete_marker"] = (root / "COMPLETE").exists()
    if not summary["complete_marker"]:
        reasons.append(
            "COMPLETE is absent: the orchestrator did not reach the end of the run, "
            "so this artefact is a partial run being graded as if it were whole"
        )

    final_state, final_state_error = read_key_values(root / "control/final-state.txt")
    summary["final_state"] = {
        k: v for k, v in final_state.items() if k != "__malformed__"
    }
    if final_state_error:
        reasons.append(
            f"control/final-state.txt is {final_state_error}: the run did not record "
            "how it ended. It is written on every exit path including aborts, so its "
            "absence means the orchestrator was killed outright"
        )
    else:
        for malformed in final_state.get("__malformed__", []):
            reasons.append(f"control/final-state.txt has an unparseable line ({malformed})")
        if final_state.get("abort_reason"):
            reasons.append(f"the run aborted: {final_state['abort_reason']}")
        forced_kill = as_int(final_state, "forced_kill", default=None)
        if forced_kill is None:
            reasons.append("control/final-state.txt records no forced_kill")
        elif forced_kill:
            reasons.append("server required SIGKILL")
        server_exit = as_int(final_state, "server_exit", default=None)
        if server_exit is None:
            reasons.append("control/final-state.txt records no server_exit")
        elif server_exit != 0:
            reasons.append(f"server exit was {server_exit}")
        sampler_exit = as_int(final_state, "sampler_exit", default=None)
        if sampler_exit not in (None, 0, 143):  # 143 = SIGTERM, how the run stops it
            reasons.append(f"the telemetry sampler exited {sampler_exit}")

    for marker, reason in (
        ("control/safety-stop.txt", "RSS safety stop"),
        ("control/server-died.txt", "server died"),
        ("control/load-errors.txt", "load generator process failed"),
        ("control/sampler-died.txt", "the telemetry sampler stopped before the run ended"),
        ("control/artefact-missing.txt", "an artefact the run expected to write is missing"),
    ):
        path = root / marker
        if path.exists():
            try:
                detail = path.read_text().strip().replace("\n", "; ")[:400]
            except OSError:
                detail = "unreadable"
            reasons.append(f"{reason} ({marker}: {detail})")

    # ------------------------------------------------------------------
    # Telemetry.
    # ------------------------------------------------------------------
    telemetry = []
    telemetry_path = root / "telemetry/process.csv"
    telemetry_readable = False
    try:
        with telemetry_path.open(newline="") as handle:
            telemetry = list(csv.DictReader(handle))
        telemetry_readable = True
    except FileNotFoundError:
        reasons.append("telemetry/process.csv is missing: the run measured no process state")
    except OSError as error:
        reasons.append(f"telemetry/process.csv is unreadable: {error}")

    summary["telemetry_samples"] = len(telemetry)
    if telemetry_readable:
        present = set(telemetry[0].keys()) if telemetry else set()
        absent = [column for column in TELEMETRY_COLUMNS if column not in present]
        if not telemetry:
            reasons.append(
                "telemetry/process.csv holds no sample: the sampler wrote a header "
                "and died, and every criterion computed from it would otherwise "
                "silently not apply"
            )
        elif absent:
            reasons.append(
                "telemetry/process.csv is missing column(s) "
                f"{', '.join(absent)}: the producer and this analyser disagree "
                f"about schema {SCHEMA_VERSION}"
            )

    # This is the check whose absence let a two-row twelve-hour run pass.
    expected_samples = as_int(manifest, "expected_samples")
    summary["expected_samples"] = expected_samples
    if expected_samples and expected_samples > 0:
        shortfall = expected_samples - len(telemetry)
        summary["sample_shortfall"] = shortfall
        if shortfall > max(2, expected_samples * SAMPLE_SHORTFALL_TOLERANCE):
            reasons.append(
                f"telemetry stopped early: {len(telemetry)} samples of "
                f"{expected_samples} expected. A short sampler does not merely lose "
                "data, it disables every rule computed from the tail"
            )
    elif telemetry_readable and manifest:
        reasons.append(
            "the manifest records no expected_samples, so a sampler that died "
            "mid-run cannot be distinguished from a run that was short"
        )

    rss = column_ints(telemetry, "rss_kib", positive_only=True)
    hwm = column_ints(telemetry, "hwm_kib", positive_only=True)
    threads = column_ints(telemetry, "threads", positive_only=True)
    fds = column_ints(telemetry, "fds")

    summary["rss_kib"] = (
        {
            "first": rss[0],
            "last": rss[-1],
            "min": min(rss),
            "max": max(rss),
            "tail_slope_kib_per_hour": slope_per_hour(telemetry, "rss_kib"),
        }
        if rss
        else None
    )
    summary["hwm_kib"] = {"max": max(hwm)} if hwm else None
    summary["threads"] = {"min": min(threads), "max": max(threads)} if threads else None
    summary["fds"] = {"first": fds[0], "last": fds[-1], "max": max(fds)} if fds else None

    if telemetry and not rss:
        reasons.append("no sample carried a usable rss_kib")
    if telemetry and not threads:
        reasons.append("no sample carried a usable threads count")
    if telemetry and not fds:
        reasons.append("no sample carried a usable fd count")

    if threads and min(threads) != max(threads):
        reasons.append(f"thread count changed ({min(threads)} -> {max(threads)})")
    if fds and fds[-1] > fds[0] + 4:
        reasons.append(f"file descriptors did not settle ({fds[0]} -> {fds[-1]})")

    slope = summary["rss_kib"]["tail_slope_kib_per_hour"] if summary["rss_kib"] else None
    if len(telemetry) >= 720:
        if slope is None:
            reasons.append("RSS tail slope could not be computed from a long run")
        elif slope > 1024:
            reasons.append(f"RSS tail slope exceeded 1 MiB/hour ({slope:.1f} KiB/h)")

    # ------------------------------------------------------------------
    # Kernel counters. Recorded since 2026-07-30 and never once read: a run in
    # which the kernel dropped every connection at the listen queue graded
    # identically to a run in which it dropped none. They are absolute totals
    # since boot, so only the delta from sample 0 — taken before load — is
    # attributable to this run.
    # ------------------------------------------------------------------
    kernel = {}
    if telemetry:
        for column in KERNEL_COLUMNS:
            values = column_ints(telemetry, column)
            if len(values) >= 2:
                kernel[column] = values[-1] - values[0]
    summary["kernel_deltas"] = kernel
    summary["nstat"] = manifest.get("nstat")
    if manifest.get("nstat") == "absent":
        # Zeros in these columns read as "no drops", which is the one thing they
        # exist to distinguish. A host without nstat did not observe a clean
        # kernel; it observed nothing.
        reasons.append(
            "nstat was not installed on the host, so the kernel drop counters "
            "were never collected: the zeros in those columns are absence of "
            "measurement, not absence of drops"
        )
    elif telemetry and len(telemetry) >= 2 and not kernel:
        reasons.append(
            "no kernel counter could be differenced: a request dropped at the "
            "listen queue is indistinguishable from one the server refused"
        )
    for column in ("listen_overflows", "listen_drops"):
        if kernel.get(column, 0) > 0:
            reasons.append(
                f"{column} rose by {kernel[column]} during the run: the kernel "
                "discarded connections before the server saw them, and no rule "
                "elsewhere in this file would have noticed"
            )

    # ------------------------------------------------------------------
    # Cycles.
    # ------------------------------------------------------------------
    cycles = []
    cycles_path = root / "cycles.csv"
    try:
        with cycles_path.open(newline="") as handle:
            cycles = list(csv.DictReader(handle))
    except FileNotFoundError:
        reasons.append("cycles.csv is missing: the run recorded no cycle")
    except OSError as error:
        reasons.append(f"cycles.csv is unreadable: {error}")

    summary["cycles"] = len(cycles)
    if not cycles:
        reasons.append("no cycle completed")

    health_p99 = column_ints(cycles, "health_p99_us")
    health_errors = column_ints(cycles, "health_transport_errors")
    if cycles and (len(health_p99) != len(cycles) or len(health_errors) != len(cycles)):
        reasons.append(
            f"cycles.csv has {len(cycles)} rows but "
            f"{len(health_p99)} usable health_p99_us and {len(health_errors)} usable "
            "health_transport_errors: rows the schema requires did not parse"
        )
    summary["health"] = {
        "transport_errors": sum(health_errors),
        "median_p99_us": statistics.median(health_p99) if health_p99 else None,
        "max_p99_us": max(health_p99) if health_p99 else None,
        "cycles_over_250ms": sum(value > 250_000 for value in health_p99),
    }
    if summary["health"]["transport_errors"]:
        reasons.append("health transport errors")
    if summary["health"]["cycles_over_250ms"]:
        reasons.append("health p99 exceeded 250 ms")

    recorded_cycles = as_int(manifest, "cycles")
    if recorded_cycles is not None and cycles and recorded_cycles != len(cycles):
        reasons.append(
            f"the manifest says {recorded_cycles} cycles and cycles.csv holds "
            f"{len(cycles)}: a cycle started and left no row"
        )

    # ------------------------------------------------------------------
    # Deliberate faults, counted apart and never netted off. A fault we caused
    # is evidence about the instrument; a fault the framework produced is
    # evidence about the product. Summing them makes both unreadable and
    # subtracting them hides a real failure behind an injection.
    # ------------------------------------------------------------------
    injected = {"campaigns": 0, "attempted": 0, "errors": 0, "by_phase": {}, "unreadable": []}
    for path in sorted((root / "cycles").glob("c*-rst.json")) if (root / "cycles").is_dir() else []:
        try:
            report = json.loads(path.read_text())
        except (OSError, json.JSONDecodeError) as error:
            injected["unreadable"].append(f"{path.name}: {error}")
            continue
        if not report.get("deliberate"):
            reasons.append(
                f"{path.name} is an injection report that does not declare itself "
                "deliberate: an injected fault that is not labelled becomes a "
                "product failure the next time somebody reads this directory"
            )
        injected["campaigns"] += 1
        injected["attempted"] += int(report.get("attempted", 0) or 0)
        injected["errors"] += int(report.get("errors", 0) or 0)
        for phase, count in (report.get("errors_by_phase") or {}).items():
            injected["by_phase"][phase] = injected["by_phase"].get(phase, 0) + count
    summary["injected_faults"] = injected
    for problem in injected["unreadable"]:
        reasons.append(f"an injection report could not be read ({problem})")

    # Declared injections, by kind. Only the RST campaign writes a c*-rst.json,
    # so only `kind=rst` declarations are matched against those reports; the
    # slow-reader injection is declared and counted, not reported in JSON.
    declared = {}
    injected_path = root / "control/injected.txt"
    if injected_path.exists():
        try:
            for line in injected_path.read_text().splitlines():
                fields = dict(part.split("=", 1) for part in line.split() if "=" in part)
                kind = fields.get("kind")
                if kind:
                    declared[kind] = declared.get(kind, 0) + 1
        except (OSError, ValueError) as error:
            reasons.append(f"control/injected.txt is unreadable or malformed: {error}")
    summary["injected_faults"]["declared"] = declared
    if declared.get("rst", 0) != injected["campaigns"]:
        reasons.append(
            f"{declared.get('rst', 0)} RST injection(s) declared in "
            f"control/injected.txt and {injected['campaigns']} report(s) on disk: an "
            "injected fault is only separable from a spontaneous one while both "
            "records agree"
        )

    # ------------------------------------------------------------------
    # Workloads, with the arithmetic actually closed.
    # ------------------------------------------------------------------
    skipped = {}
    skipped_path = root / "control/skipped.txt"
    if skipped_path.exists():
        try:
            for line in skipped_path.read_text().splitlines():
                fields = dict(part.split("=", 1) for part in line.split() if "=" in part)
                if "skipped" in fields:
                    skipped[fields["skipped"]] = fields.get("reason", "unstated")
        except OSError:
            reasons.append("control/skipped.txt is unreadable")
    summary["skipped_workloads"] = skipped

    short_allowed = {}
    short_path = root / "control/short.txt"
    if short_path.exists():
        try:
            for line in short_path.read_text().splitlines():
                fields = dict(part.split("=", 1) for part in line.split() if "=" in part)
                if "short" in fields:
                    short_allowed[fields["short"]] = fields.get("reason", "unstated")
        except OSError:
            reasons.append("control/short.txt is unreadable")
    summary["short_workloads"] = short_allowed

    workloads = {}
    for name in WORKLOADS:
        files = sorted((root / "cycles").glob(f"c*-{name}.json")) if (root / "cycles").is_dir() else []
        reports, unreadable = [], []
        for path in files:
            try:
                reports.append(json.loads(path.read_text()))
            except (OSError, json.JSONDecodeError) as error:
                unreadable.append(f"{path.name}: {error}")
        for problem in unreadable:
            reasons.append(f"a {name} cycle report could not be read ({problem})")

        statuses, failure_counts, failure_examples = {}, {}, {}
        planned = completed = succeeded = transport_errors = 0
        status_total = 0
        missing_keys = set()
        for report in reports:
            for key in ("planned", "completed", "succeeded", "transport_errors", "status"):
                if key not in report:
                    missing_keys.add(key)
            planned += int(report.get("planned", 0) or 0)
            completed += int(report.get("completed", 0) or 0)
            succeeded += int(report.get("succeeded", 0) or 0)
            transport_errors += int(report.get("transport_errors", 0) or 0)
            for status, count in (report.get("status") or {}).items():
                statuses[status] = statuses.get(status, 0) + count
                status_total += count
            for entry in report.get("failures") or []:
                klass = entry.get("class") or "unnamed"
                failure_counts[klass] = failure_counts.get(klass, 0) + entry.get("count", 0)
                if entry.get("example_error") and klass not in failure_examples:
                    failure_examples[klass] = entry["example_error"]

        p99s = [
            report["latency_p99_us"] for report in reports if "latency_p99_us" in report
        ]
        workloads[name] = {
            "runs": len(reports),
            "planned": planned,
            "completed": completed,
            "succeeded": succeeded,
            "transport_errors": transport_errors,
            "status": statuses,
            "status_total": status_total,
            "failures": [
                {
                    "class": klass,
                    "count": count,
                    "example_error": failure_examples.get(klass, ""),
                }
                for klass, count in sorted(failure_counts.items(), key=lambda item: -item[1])
            ],
            "median_p99_us": statistics.median(p99s) if p99s else None,
            "max_p99_us": max(p99s) if p99s else None,
        }
        if missing_keys:
            reasons.append(
                f"{name} cycle reports omit required key(s) "
                f"{', '.join(sorted(missing_keys))} of schema {SCHEMA_VERSION}"
            )

    for name, workload in workloads.items():
        if workload["runs"] == 0:
            workload["transport_error_ratio"] = None
            workload["unexpected_http_status"] = {}
            if name in skipped:
                workload["skipped_reason"] = skipped[name]
            else:
                reasons.append(
                    f"{name} produced no runs and control/skipped.txt gives no reason: "
                    "a profile disappeared from the run unexplained"
                )
            continue

        planned = workload["planned"]
        completed = workload["completed"]

        # ACCOUNTING, three ways. Each of these passed before soak/1.
        if completed > planned:
            reasons.append(
                f"{name} completed {completed} of {planned} planned: more requests "
                "finished than were scheduled"
            )
        elif completed < planned:
            if name in short_allowed:
                workload["short_reason"] = short_allowed[name]
            else:
                reasons.append(
                    f"{name} completed {completed} of {planned} planned and "
                    f"control/short.txt gives no reason: {planned - completed} "
                    "request(s) left no record of any kind"
                )
        if workload["status_total"] != completed:
            reasons.append(
                f"{name} completed {completed} request(s) and its status map accounts "
                f"for {workload['status_total']}: the outcome of "
                f"{abs(completed - workload['status_total'])} of them is unrecorded"
            )
        if workload["succeeded"] + workload["transport_errors"] != completed:
            reasons.append(
                f"{name} does not close: succeeded {workload['succeeded']} + errors "
                f"{workload['transport_errors']} != completed {completed}"
            )

        workload["transport_error_ratio"] = (
            workload["transport_errors"] / planned if planned else 1.0
        )
        unexpected = {
            status: count
            for status, count in workload["status"].items()
            if status not in ("0", EXPECTED_STATUS[name])
        }
        workload["unexpected_http_status"] = unexpected
        if name == "health" and workload["transport_errors"]:
            reasons.append("health workload transport errors")
        elif name != "health" and workload["transport_error_ratio"] > 0.0001:
            reasons.append(f"{name} transport error ratio exceeded 0.01%")
        if unexpected:
            reasons.append(f"{name} returned unexpected HTTP status")

    summary["workloads"] = workloads

    # ------------------------------------------------------------------
    # Accounting, not tolerance. Every failure carries a class; a class the
    # taxonomy does not recognise fails the run whatever the rate.
    # ------------------------------------------------------------------
    failure_classes, examples = {}, {}
    unclassified_total = 0
    for workload in workloads.values():
        for entry in workload["failures"]:
            klass = entry["class"]
            failure_classes[klass] = failure_classes.get(klass, 0) + entry["count"]
            examples.setdefault(klass, entry.get("example_error", ""))
            if klass in ("unclassified", "unnamed"):
                unclassified_total += entry["count"]

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
    for klass, count in failure_classes.items():
        if count and not (examples.get(klass) or "").strip():
            reasons.append(
                f"failure class {klass!r} carries {count} failure(s) and no example "
                "text: a named bucket with nothing in it is not an explanation"
            )

    # ------------------------------------------------------------------
    # /stats: measured, and now enforced with a cause.
    # ------------------------------------------------------------------
    stats_missing = [row for row in telemetry if row.get("stats_http") != "200"]
    stats_causes, stats_uncaptured = {}, 0
    for row in stats_missing:
        code = row.get("stats_curl_exit")
        if code in (None, "", "0"):
            stats_uncaptured += 1
        else:
            label = f"{code} ({CURL_EXIT_MEANING.get(code, 'unmapped curl exit')})"
            stats_causes[label] = stats_causes.get(label, 0) + 1
    summary["stats_missing_samples"] = len(stats_missing)
    summary["stats_failure_causes"] = stats_causes
    summary["stats_failures_uncaptured"] = stats_uncaptured

    # A scrape that answered 200 and wrote nothing is not a scrape. curl -o
    # truncates its output file before it knows whether it can fill it, so a
    # zero-byte stats-NNNNNN.json is what a failure leaves behind.
    empty_scrapes = 0
    for row in telemetry:
        if row.get("stats_http") == "200":
            try:
                if int(row.get("stats_bytes", "1")) <= 0:
                    empty_scrapes += 1
            except (TypeError, ValueError):
                empty_scrapes += 1
    summary["stats_empty_bodies"] = empty_scrapes
    if empty_scrapes:
        reasons.append(
            f"{empty_scrapes} sample(s) recorded HTTP 200 from /stats with an empty "
            "body: the scrape file on disk cannot be told from a failed one"
        )

    if stats_missing:
        # The causes go in the REASON, not only in a field beside it. The whole
        # defect this rule replaced was a number that sat in an artefact where
        # nobody looked: 111 failed scrapes of 8,611, recorded, passed, unread.
        detail = ", ".join(
            f"{count}x exit {label}" for label, count in sorted(stats_causes.items())
        )
        reasons.append(
            f"/stats did not answer 200 on {len(stats_missing)} of "
            f"{len(telemetry)} samples"
            + (f" ({detail})" if detail else "")
        )
    if stats_uncaptured:
        reasons.append(
            f"{stats_uncaptured} of those samples captured no cause: the observability "
            "endpoint failed and the instrument did not record why"
        )

    summary["reasons"] = reasons
    if reasons:
        summary["result"] = "FAIL"
    return summary


def main(argv):
    if len(argv) < 2:
        print(
            json.dumps(
                {
                    "result": "FAIL",
                    "reasons": ["usage: analyze-soak.py RUN_DIRECTORY"],
                },
                indent=2,
                sort_keys=True,
            )
        )
        return 0
    root = pathlib.Path(argv[1])
    try:
        summary = analyse(root)
    except Exception as error:  # noqa: BLE001 — see the module docstring.
        # The analyser must produce a verdict even about an artefact that
        # defeats it. A traceback is not a verdict, and the run it could not
        # read is exactly the run somebody will be tempted to grade by eye.
        summary = {
            "result": "FAIL",
            "run_directory": str(root),
            "reasons": [
                f"the analyser could not grade this artefact: "
                f"{type(error).__name__}: {error}"
            ],
        }
    summary.setdefault("run_directory", str(root))
    print(json.dumps(summary, indent=2, sort_keys=True))
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv))
