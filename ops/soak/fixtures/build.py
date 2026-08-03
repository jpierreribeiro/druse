#!/usr/bin/env python3
"""Regenerate ops/soak/fixtures/.

The fixtures are committed, not generated at check time; this script exists so
they can be regenerated deterministically when schema.md moves, and so the
difference between two fixtures is a diff of this file rather than a diff of
thirty small JSON documents.

    python3 ops/soak/fixtures/build.py

Each fixture is a run directory plus an EXPECT.json saying what
analyze-soak.py must say about it: the verdict, and substrings that must appear
among its reasons. `build/check_soak_controls.sh` asserts both.

Asserting the REASON and not only the verdict is the point. A fixture that only
required FAIL would be satisfied by an analyser that failed everything, and one
of the defects this work package found was precisely an analyser going red for
the wrong reason while a control could not tell the difference.

`criteria_sha256` and `schema_sha256` are written as placeholders. The runs
pin those hashes so a criterion cannot be edited between a run and its grade,
which means a fixture carrying literal hashes would go red every time
CRITERIA.md was touched — a control that fails for an unrelated edit is a
control people learn to ignore. `materialise.sh` substitutes the live values.
"""
import json
import pathlib

HERE = pathlib.Path(__file__).resolve().parent

WORKLOADS = ("health", "tiny", "json-encode", "json-decode", "bytes-64k", "wait-40ms")
EXPECTED_STATUS = dict.fromkeys(WORKLOADS, "200") | {"json-decode": "204"}
SAMPLES = 12
SERVER_SHA = "a" * 64
OPENLOAD_SHA = "b" * 64


def manifest(**overrides):
    values = {
        "schema_version": "soak/1",
        "started_utc": "2026-08-02T00:00:00Z",
        "git_head": "e32930d0000000000000000000000000000000ab",
        "git_tree": "1111111111111111111111111111111111111111",
        "git_dirty": "0",
        "allow_dirty": "0",
        "harness_head": "e32930d0000000000000000000000000000000ab",
        "criteria_sha256": "@CRITERIA_SHA256@",
        "schema_sha256": "@SCHEMA_SHA256@",
        "runner_sha256": "c" * 64,
        "analyzer_sha256": "d" * 64,
        "preflight": "pass",
        "compiler": "odin version dev-2026-07a",
        "kernel": "Linux 6.18.5 x86_64 GNU/Linux",
        "hours": "12",
        "phase_seconds": "120",
        "sample_seconds": "1",
        "lanes": "4",
        "max_cycles": "1",
        "health_rate": "20",
        "tiny_rate": "10000",
        "json_encode_rate": "1500",
        "json_decode_rate": "4000",
        "bytes_64k_rate": "150",
        "wait_40ms_rate": "15",
        "launch_stagger_seconds": "1",
        "final_settle_seconds": "35",
        "server_cpus": "0-3",
        "generator_cpus": "4-7",
        "max_rss_kib": "4194304",
        "nofile": "8192",
        "server_sha256": SERVER_SHA,
        "openload_sha256": OPENLOAD_SHA,
        "nstat": "present",
        "completed_utc": "2026-08-02T00:02:00Z",
        "cycles": "1",
        "expected_samples": str(SAMPLES),
    }
    values.update(overrides)
    return "".join(f"{key}={value}\n" for key, value in values.items())


TELEMETRY_HEADER = (
    "sample,utc,unix_nanos,elapsed_s,rss_kib,hwm_kib,threads,fds,proc_ticks,"
    "host_ticks,stats_http,stats_curl_exit,stats_bytes,listen_overflows,"
    "listen_drops,tcp_abort_on_close,tcp_retrans"
)


def telemetry(rows=SAMPLES, stats_http="200", stats_curl_exit="0",
              stats_bytes="412", listen_drops=lambda index: 0):
    lines = [TELEMETRY_HEADER]
    base_nanos = 1_785_000_000_000_000_000
    for index in range(rows):
        lines.append(
            f"{index},2026-08-02T00:00:{index:02d}Z,{base_nanos + index * 10**9},"
            f"{index},4096,4200,5,14,{index},{index * 4},"
            f"{stats_http},{stats_curl_exit},{stats_bytes},"
            f"0,{listen_drops(index)},0,0"
        )
    return "\n".join(lines) + "\n"


CYCLES_HEADER = (
    "cycle,started_utc,ended_utc,health_status,health_transport_errors,"
    "health_p99_us,stats_http,stats_curl_exit"
)


def cycles(rows=1, health_errors=0, health_p99=1500):
    lines = [CYCLES_HEADER]
    for index in range(1, rows + 1):
        lines.append(
            f"{index},2026-08-02T00:00:00Z,2026-08-02T00:02:00Z,2400,"
            f"{health_errors},{health_p99},200,0"
        )
    return "\n".join(lines) + "\n"


def workload(name, planned=1000, completed=None, succeeded=None,
             transport_errors=0, failures=None, status=None):
    completed = planned if completed is None else completed
    succeeded = completed - transport_errors if succeeded is None else succeeded
    if status is None:
        status = {EXPECTED_STATUS[name]: succeeded}
        if transport_errors:
            status["0"] = transport_errors
    return {
        "planned": planned,
        "completed": completed,
        "succeeded": succeeded,
        "transport_errors": transport_errors,
        "status": status,
        "latency_p99_us": 1800,
        "failures": failures or [],
        "unclassified": sum(
            entry["count"] for entry in (failures or [])
            if entry["class"] in ("unclassified", "unnamed")
        ),
    }


def write(fixture, files, expect):
    root = HERE / fixture
    for path in sorted(root.rglob("*"), reverse=True):
        path.unlink() if path.is_file() else path.rmdir()
    for name, content in files.items():
        target = root / name
        target.parent.mkdir(parents=True, exist_ok=True)
        target.write_text(
            content if isinstance(content, str)
            else json.dumps(content, indent=2, sort_keys=True) + "\n"
        )
    (root / "EXPECT.json").write_text(json.dumps(expect, indent=2, sort_keys=True) + "\n")
    print(f"wrote {fixture}: expect {expect['result']}")


def base_files():
    files = {
        "manifest.txt": manifest(),
        "telemetry/process.csv": telemetry(),
        "cycles.csv": cycles(),
        "control/final-state.txt": "forced_kill=0\nserver_exit=0\nsampler_exit=0\n",
        # The server's own saturation counter. R2-WP04 excuses
        # `eof_on_fresh_conn` as a documented refusal, and the excuse is only
        # honest if the acceptor agrees it refused that many — so every fixture
        # carries the counter the analyser checks the exemption against.
        "control/final-stats.json": json.dumps({
            "refused_connections": 0,
            "saturation_refusals": 8,
            "responses_sent": 1000,
            "send_errors": 0,
        }) + "\n",
        "control/final-binaries.txt":
            f"server_sha256={SERVER_SHA}\nopenload_sha256={OPENLOAD_SHA}\n",
        "COMPLETE": "",
    }
    for name in WORKLOADS:
        files[f"cycles/c0001-{name}.json"] = workload(name)
    return files


# --- 1. PASS ----------------------------------------------------------------
# The positive control. Without it every negative fixture below is satisfied by
# an analyser that fails everything it is shown.
write("pass", base_files(), {
    "result": "PASS",
    "reasons_must_include": [],
    "note": "A clean run. The positive control: without it, an analyser that "
            "returned FAIL unconditionally would satisfy every other fixture.",
})

# --- 2. classified FAIL -----------------------------------------------------
# The failures are explained, and the run is still red because the RATE is over
# budget. Rate and explanation are separate criteria and this fixture is what
# keeps them separate.
#
# `planned` is 20,000 and not the 1,000 it was until R2-WP04. The ratio ceiling
# is 0.01%, so it cannot be expressed below 10,000 requests — at 1,000 this
# fixture had stopped exercising the rate branch at all and would have proved
# the volume rule instead, silently. The class is `peer_reset` rather than
# `eof_on_fresh_conn` for the same reason: the latter is now excused as a
# documented saturation refusal, and a fixture for the RATE rule must not be
# built out of the one class the rate rule no longer counts.
files = base_files()
files["cycles/c0001-tiny.json"] = workload(
    "tiny", planned=20000, transport_errors=40,
    failures=[{
        "class": "peer_reset", "count": 40,
        "example_error": "read tcp 127.0.0.1:44002->127.0.0.1:8080: connection reset by peer",
    }],
)
write("fail-classified", files, {
    "result": "FAIL",
    "reasons_must_include": ["tiny spontaneous transport error ratio exceeded 0.01%"],
    "reasons_must_not_include": ["not classified", "unrecognised class"],
    "note": "Every failure carries a class and its text; the run is red for the "
            "RATE alone. Proves the rate rule and the accounting rule are "
            "independent. Volume is above 1/ceiling so the rate branch is the "
            "one under test.",
})

# --- 2b. low-volume attribution --------------------------------------------
# The branch R2-WP04 added, and the reason it exists: `wait-40ms` offers 9,000
# requests, a 0.01% ceiling permits 0.9 errors, so ONE error — the smallest
# non-zero rate the workload can produce — failed the run. That was a demand for
# perfection wearing a tolerance's clothes.
#
# Below 1/ceiling the rule is accounting, not rate: every error must be
# attributable. One unattributable error is red here, at a rate far under the
# ceiling, which is the opposite of the fixture above.
files = base_files()
files["cycles/c0001-wait-40ms.json"] = workload(
    "wait-40ms", planned=9000, transport_errors=1,
    failures=[{
        "class": "peer_reset", "count": 1,
        "example_error": "read tcp 127.0.0.1:44010->127.0.0.1:8080: connection reset by peer",
    }],
)
write("fail-low-volume", files, {
    "result": "FAIL",
    "reasons_must_include": ["below the 10000 needed to measure a 0.01% ceiling"],
    "reasons_must_not_include": ["ratio exceeded"],
    "note": "One error in 9,000 — 0.011%, over the ceiling arithmetically but "
            "below the volume the ceiling needs. Red for ATTRIBUTION, not rate. "
            "The paired positive is `saturation-refused`, where the same volume "
            "and the same count pass because the class is explained.",
})

# --- 2c. saturation refusals are excused, and the excuse is checked ---------
# The acceptor is documented to close fresh sockets without a response when every
# lane is busy (`docs/supported-profile.md`), incrementing `saturation_refusals`.
# From the generator that is `eof_on_fresh_conn`. Counting it as a spontaneous
# transport error made the server fail a criterion for keeping its own promise.
#
# The POSITIVE case: same volume and same count as the fixture above, and it
# passes, because the class is attributable and the server's counter agrees.
files = base_files()
files["cycles/c0001-wait-40ms.json"] = workload(
    "wait-40ms", planned=9000, transport_errors=1,
    failures=[{
        "class": "eof_on_fresh_conn", "count": 1,
        "example_error": "EOF on a fresh connection before any response byte",
    }],
)
write("saturation-refused", files, {
    "result": "PASS",
    "reasons_must_include": [],
    "note": "A documented saturation refusal, corroborated by the server's own "
            "saturation_refusals counter, is reported beside the spontaneous "
            "failures and never netted against them (criterion 14's principle). "
            "Without this positive, the separation could be an analyser that "
            "excuses everything.",
})

# --- 3. unclassified FAIL ---------------------------------------------------
# One failure, far under any rate ceiling, and the run is red because nobody can
# say what it was. This is the criterion the whole instrument exists for.
files = base_files()
files["cycles/c0001-bytes-64k.json"] = workload(
    "bytes-64k", planned=100000, transport_errors=1,
    failures=[{
        "class": "unclassified", "count": 1,
        "example_error": "Get \"http://127.0.0.1:8080/bytes/64k\": something new",
    }],
)
write("fail-unclassified", files, {
    "result": "FAIL",
    "reasons_must_include": ["unrecognised class"],
    "note": "One failure in 100,000 — comfortably inside the 0.01% ceiling — and "
            "red anyway because its cause has no name. Accounting, not tolerance.",
})

# --- 4. child death ---------------------------------------------------------
# The server died mid-run and a load generator went with it. The artefact is
# partial by construction: no COMPLETE, and the sampler stopped early.
files = base_files()
del files["COMPLETE"]
files["manifest.txt"] = manifest(expected_samples="43200")
files["control/server-died.txt"] = "server_died_cycle=417\n"
files["control/load-errors.txt"] = "cycle=417 child=90412 exit=143\n"
files["control/final-state.txt"] = (
    "forced_kill=1\nserver_exit=137\nsampler_exit=0\n"
    "abort_reason=orchestrator failed at run-soak.sh:301 with exit 137\n"
)
write("child-death", files, {
    "result": "FAIL",
    "reasons_must_include": [
        "server died",
        "load generator process failed",
        "server required SIGKILL",
        "server exit was 137",
        "COMPLETE is absent",
        "telemetry stopped early",
        "the run aborted",
    ],
    "note": "A twelve-hour run that died at cycle 417. Every one of these "
            "reasons is separately load-bearing; the telemetry shortfall is the "
            "one that used to be invisible.",
})

# --- 5. missing final-state -------------------------------------------------
# The artefact of a killed orchestrator, and the one that used to make the
# analyser raise FileNotFoundError instead of returning a verdict.
files = base_files()
del files["control/final-state.txt"]
del files["control/final-binaries.txt"]
del files["COMPLETE"]
write("missing-final-state", files, {
    "result": "FAIL",
    "reasons_must_include": [
        "control/final-state.txt is missing",
        "control/final-binaries.txt is missing",
        "COMPLETE is absent",
    ],
    "must_not_traceback": True,
    "note": "The exact artefact a killed orchestrator leaves. soak/0 raised "
            "FileNotFoundError from pathlib here, so the run with the most to "
            "say produced no verdict at all.",
})

# --- 6. dead sampler --------------------------------------------------------
# Separated from child-death because it is the subtler half: the run itself
# finished cleanly and only the INSTRUMENT stopped. Nothing about the product
# is wrong in this artefact, and it must still be refused, because the criteria
# computed from the tail did not run.
files = base_files()
files["manifest.txt"] = manifest(expected_samples="43200")
files["telemetry/process.csv"] = telemetry(rows=2)
files["control/sampler-died.txt"] = (
    "the telemetry sampler was not running when the load stopped\n"
)
write("dead-sampler", files, {
    "result": "FAIL",
    "reasons_must_include": [
        "telemetry stopped early",
        "the telemetry sampler stopped before the run ended",
    ],
    "note": "A clean twelve-hour run whose sampler died after two seconds. "
            "soak/0 graded this PASS: the RSS-slope rule only applies at 720 "
            "samples, so a two-row artefact disabled it silently.",
})

# --- 7. kernel drops --------------------------------------------------------
files = base_files()
files["telemetry/process.csv"] = telemetry(
    listen_drops=lambda index: 0 if index < 6 else 9000
)
write("kernel-drops", files, {
    "result": "FAIL",
    "reasons_must_include": ["listen_drops rose by 9000"],
    "note": "The kernel discarded connections before the server saw them. These "
            "counters were recorded from 2026-07-30 and read by nothing until "
            "soak/1.",
})

# --- 8. arithmetic that does not close --------------------------------------
files = base_files()
files["cycles/c0001-json-encode.json"] = {
    "planned": 1000, "completed": 640, "succeeded": 640, "transport_errors": 0,
    "status": {"200": 600}, "latency_p99_us": 1800, "failures": [], "unclassified": 0,
}
write("broken-accounting", files, {
    "result": "FAIL",
    "reasons_must_include": [
        "json-encode completed 640 of 1000 planned",
        "its status map accounts for 600",
    ],
    "note": "360 requests left no record of any kind and 40 more finished with "
            "no outcome recorded. Both passed before soak/1.",
})
