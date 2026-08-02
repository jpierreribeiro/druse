# Soak artefact schema — `soak/1`

The on-disk contract between `run-soak.sh` (producer) and `analyze-soak.py`
(consumer). It is versioned because R2-WP01 found the two disagreeing in
silence: the runner recorded kernel counters and a `/stats` curl exit that the
analyser never read, and the analyser read a `control/final-state.txt` the
runner did not always write. Neither side was wrong about its own job. There
was no document either could be wrong about.

`schema_version` appears in `manifest.txt`. A run whose version the analyser
does not implement is FAIL, not best-effort: an artefact from an unknown
producer is exactly the thing this instrument must refuse to grade.

## Rules that apply to every file here

1. **Absent is not empty.** A file the runner may legitimately not create is
   listed below as optional, with the meaning of its absence. Any other missing
   file is FAIL with a named reason — never a traceback and never a skipped
   criterion.
2. **Truncated is not complete.** Every stream artefact (`process.csv`,
   `cycles.csv`) carries an expected length in the manifest. Short means the
   producer died; short does not mean the criterion does not apply.
3. **Absolute time, everywhere.** Every row carries UTC and unix nanoseconds so
   a client-side failure can be joined to a server sample and a kernel counter
   from the same instant.
4. **Counters are absolute; deltas are the consumer's job.** Kernel counters
   come from `nstat -az`, which reports totals since boot. Sample 0 is taken
   *before* the first load cycle and is therefore the run's baseline. The
   attributable movement is `last - first`, never the raw value.

## `manifest.txt`

`key=value`, one per line, no quoting. Written in two parts: identity and
configuration before the first cycle, completion keys after the last.

### Identity — required, written before load starts

| Key | Meaning |
|---|---|
| `schema_version` | `soak/1`. The analyser refuses anything else. |
| `started_utc` | RFC3339 UTC, before the first cycle |
| `git_head` | commit of `BASE/repo` |
| `git_tree` | `git rev-parse HEAD^{tree}` of `BASE/repo` |
| `git_dirty` | `0` or `1`. `1` requires `allow_dirty=1` |
| `allow_dirty` | `1` only when `DRUSE_SOAK_ALLOW_DIRTY=1` was set |
| `harness_head` | commit of the checkout the harness itself came from, or `unknown` |
| `criteria_sha256` | sha256 of `ops/soak/CRITERIA.md` as used by this run |
| `schema_sha256` | sha256 of this file as used by this run |
| `runner_sha256` | sha256 of `run-soak.sh` |
| `analyzer_sha256` | sha256 of `analyze-soak.py` |
| `compiler` | first line of `odin version` |
| `kernel` | `uname -srmo` |
| `server_sha256`, `openload_sha256` | binaries actually launched |
| `preflight` | `pass`, `skipped`, or `absent` |
| `nstat` | `present` or `absent` on the host |

`nstat=absent` fails the run. The kernel-counter columns are still written, as
zeros, and a zero there reads as "no drops" — which is the single thing those
columns exist to distinguish. A host that could not collect them did not observe
a clean kernel; it observed nothing, and the artefact has to say which.

`criteria_sha256` and `schema_sha256` are the answer to "a criterion was
changed after the result". They are recorded by the run, and the analyser
recomputes them from the working tree: a mismatch is FAIL. A criteria file
edited between the run and its grading can no longer be presented as the
criteria the run was judged by.

`server_sha256` and `openload_sha256` are recorded from the binaries that were
*launched*, and re-hashed after the run into `control/final-binaries.txt`. A
binary swapped mid-run is a different candidate and is FAIL.

### Configuration — required

`hours`, `phase_seconds`, `sample_seconds`, `lanes`, `max_cycles`,
`launch_stagger_seconds`, `final_settle_seconds`, `max_rss_kib`, `nofile`,
`server_cpus`, `generator_cpus`, and one `<name>_rate` per workload.

### Completion — written after the last cycle

| Key | Meaning |
|---|---|
| `completed_utc` | RFC3339 UTC |
| `cycles` | cycles actually started |
| `expected_samples` | wall-clock seconds ÷ `sample_seconds` |

`expected_samples` is what makes a dead sampler visible. Without it a
`process.csv` holding two rows of a twelve-hour run is a short file that no
rule mentions, and the RSS-slope criterion — which only applies at ≥720 samples
— silently does not run.

## `telemetry/process.csv`

One row per `sample_seconds`. Sample 0 precedes the first cycle.

```text
sample,utc,unix_nanos,elapsed_s,rss_kib,hwm_kib,threads,fds,proc_ticks,
host_ticks,stats_http,stats_curl_exit,stats_bytes,listen_overflows,
listen_drops,tcp_abort_on_close,tcp_retrans
```

| Column | Meaning |
|---|---|
| `sample` | zero-based; also names `telemetry/stats-%06d.json` |
| `stats_http` | HTTP status of the `/stats` scrape, `000` when none arrived |
| `stats_curl_exit` | **curl's exit status**, not its HTTP code |
| `stats_bytes` | size of the scrape body written to `stats-%06d.json` |
| `listen_*`, `tcp_*` | `nstat -az` totals since boot; see rule 4 |

`stats_curl_exit` is the field R2-WP01 was opened for. The shipped sampler
wrote `… )" || true` and read `$?` on the next line, which is the exit status of
`true`. Every failed scrape recorded `0`. The taxonomy the comment above it
promised — 7 refused, 28 timeout, 52 empty reply, 56 receive failure — was
unreachable for the entire life of the field.

`stats_bytes` exists because `curl -o` truncates its output file before it
knows whether it will fill it. A failed scrape leaves a zero-byte
`stats-%06d.json`, which on disk is indistinguishable from a successful scrape
of an empty body. The row now says which it was.

## `cycles.csv`

One row per completed cycle.

```text
cycle,started_utc,ended_utc,health_status,health_transport_errors,
health_p99_us,stats_http,stats_curl_exit
```

## `cycles/c%04d-<workload>.json`

The generator's summary, one per workload per cycle. Required keys:
`planned`, `completed`, `succeeded`, `transport_errors`, `status`,
`latency_p99_us`, `failures`, `unclassified`.

`failures` is a list of `{class, count, example_error}`. The analyser requires
all four of these to close:

```text
completed        == sum(status.values())
completed        == succeeded + transport_errors
transport_errors == sum(f.count for f in failures)
completed        <= planned
```

A generator whose workers hang returns `completed < planned` with nothing else
wrong. Before `soak/1` that was a PASS.

`completed < planned` is permitted only for a workload named in
`control/short.txt` with a reason; otherwise it is FAIL.

## `cycles/c%04d-rst.json` — injected faults

Written by the RST campaign, which is deliberate. Required: `deliberate: true`,
`mode`, `attempted`, `errors`, `errors_by_phase`, `started_unix_nanos`,
`ended_unix_nanos`.

Injected faults are counted **separately and are not subtracted from any
total**. The analyser reports `injected_faults` beside `failures_counted`; it
never nets one against the other. A fault we caused is evidence about the
instrument, and a fault the framework produced is evidence about the product —
adding them makes both unreadable, and subtracting makes a real failure
disappear behind an injection.

## `control/` — the run's own account of itself

| File | Optional? | Meaning of its presence |
|---|---|---|
| `final-state.txt` | **no** | `forced_kill`, `server_exit`, `sampler_exit`, `abort_reason`. Written on **every** exit path, including aborts. |
| `final-binaries.txt` | no | re-hash of the binaries after the run |
| `skipped.txt` | yes | a workload deliberately not run (`skipped=<name> reason=<why>`) |
| `short.txt` | yes | a workload that ran fewer requests than planned, with a reason |
| `injected.txt` | yes | one line per injected campaign |
| `artefact-missing.txt` | yes | a per-cycle artefact the runner expected and did not find |
| `load-errors.txt` | yes | a load-generator child exited non-zero |
| `sampler-died.txt` | yes | the sampler stopped before the run asked it to |
| `server-died.txt` | yes | the server was gone at the top of a cycle |
| `safety-stop.txt` | yes | RSS crossed `max_rss_kib` |
| `health-violations.txt` | yes | a cycle breached the health criterion |

`final-state.txt` is not optional and its absence is not a crash. A run killed
before it could write one is the ordinary shape of a bad night, and the
analyser's job on that artefact is to say *the run did not finish and here is
what it did record* — not to raise `FileNotFoundError` from
`pathlib`, which is what `soak/0` did.

## `COMPLETE`

Written last, after `MANIFEST.sha256`. Its absence means the orchestrator did
not reach the end, and the analyser reports FAIL with that reason. `soak/0`
never looked at this file, so a run killed at hour two graded exactly like a run
that finished.

## Changing this schema

A change here is a change to `schema_version`, a change to
`build/check_soak_controls.sh`, and a new fixture in `ops/soak/fixtures/`. The
version exists so the analyser can refuse an artefact it does not understand; a
version that moves without the analyser moving with it is worse than none.
