# Experiment 12 — the two concurrency arms, measured (WP42 / ADR-030)

**Question.** Should `web.serve` stay single-threaded by construction, or adopt
the vendored server's multi-threaded mode?

**Why it is an experiment and not an opinion.** The Phase-4 plan pre-registered
the procedure before any prototype existed, precisely so the answer could not be
chosen and then justified: *prototype both arms, measure under real workloads,
and decide by ADR-030 with the losing arm's numbers recorded.* It also
pre-registered the stopping rule — **the burden of proof is on threading, and an
inconclusive prototype means single-threaded.**

## What the arms actually are

The vendored server already supports both. `Server_Opts.thread_count` defaults
to the core count, and **Druse's adapter forces it to 1** today
(`web/internal/transport/odin_http_adapter.odin`). So this is not a build; it is
a one-line change, which is exactly why it needed measuring rather than
guessing — a cheap change is the kind that gets made without evidence.

* **Arm A — single-threaded.** `opts.thread_count = 1`. The status quo.
* **Arm B — threaded.** `opts.thread_count = N`, N = core count.

## How to run

```
bash experiments/12-concurrency-arms/run.sh
```

It builds a consumer against a copy of the tree with each arm patched in,
drives both with the same client load, and prints both results. It changes
nothing in the repository.

## What it measures, and what it deliberately does not

**Measures:** wall-clock to complete a fixed number of requests across a fixed
number of concurrent clients, plus whether every request was answered
correctly.

**Does not measure:** latency percentiles. FINDING-A's noise floor on this
machine is **13,821 basis points — 138%** — so a percentile comparison here
would be theatre. Completion of a whole workload is a coarser number and a
survivable one.

## The result, and it is not the one the numbers decide

Recorded in `planning/phase-4-concurrency.md`. In short: **the timing did not
decide, and it did not need to.** Threading is not blocked by performance; it is
blocked by three documented single-writer guarantees that the framework
currently states as true, and which `thread_count > 1` silently makes false.
That is a correctness finding, and it outranks a stopwatch.
