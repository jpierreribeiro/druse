# Nested JSON: the knee, and what a request actually costs — 2026-07-30

## Verdict

On a nested JSON document that all four servers answer **byte for byte
identically**, Druse's per-request cost is about **2.3× the Go peers'** below
saturation, and its ceiling on four handler lanes is about **20,800 responses
per second** where the three peers exceed 30,000 without reaching theirs.

Two numbers published earlier the same day were wrong, and both are corrected
here. This report supersedes the `/json/medium` row of
`2026-07-30-open-loop-application-matrix.md`, which was withdrawn.

## What was wrong, and why

The first run measured `GET /json/medium`, whose document contains 64 floats.
Odin's pinned `core:encoding/json` renders `f64` in fixed point with sixteen
decimals — `1.5000000000000000` where Go writes `1.5` — so Druse put 960 more
bytes on the wire than the peers for the same items, and the row compared two
payloads as well as two servers. It reported a p50 of 113 ms against 145 µs.

`/json/medium/int` is the same document with an integer score. Every server
answers **4,310 bytes**, verified character for character. Measuring it changed
the picture twice over:

| At 20,000/s | float route | integer route |
|---|---:|---:|
| Druse goodput | 19,527/s (97.6%) | **19,991/s (100%)** |
| Druse p50 | 119,512 µs | **2,378 µs** |

**Removing the float rendering cut the p50 by fifty times and let Druse serve
the full rate.** That is far more than a 21.6% payload difference explains:
sixteen decimals is not merely more bytes, it is substantially more CPU per
response. No previous measurement could see this, because no previous
measurement had the two documents side by side — the 2026-07-25 study avoided
the confound by measuring decode only, which removed the question along with it.

## The sweep

`/json/medium/int`, three repeats per point, ten seconds each, servers
alternated between repeats and rates ascending within a server visit. AWS
`c5.2xlarge`, server on CPUs 0-3, generator on 4-7, four Druse lanes, open loop
with the latency clock starting at the intended schedule time.

| Offered | Druse | Fiber | Gin | net/http |
|---:|---|---|---|---|
| 5,000/s | **338 µs** · 100% | 607 µs · 100% | 601 µs · 100% | 602 µs · 100% |
| 10,000/s | 333 µs · 100% | **138 µs** · 100% | 154 µs · 100% | 154 µs · 100% |
| 15,000/s | 391 µs · 100% | **129 µs** · 100% | 156 µs · 100% | 156 µs · 100% |
| 20,000/s | 2,375 µs · 100% | **134 µs** · 100% | 156 µs · 100% | 156 µs · 100% |
| 25,000/s | 1,014,637 µs · **82.8%** | 136 µs · 100% | 151 µs · 100% | 150 µs · 100% |
| 30,000/s | 2,204,796 µs · **69.4%** | 136 µs · 100% | 147 µs · 100% | 148 µs · 100% |

| | last rate served | first rate missed | p50 there | p99 there |
|---|---:|---:|---:|---:|
| **druse** | **20,000/s** | 25,000/s | 2,375 µs | 8,146 µs |
| fiber | 30,000/s | not reached | 136 µs | 1,044 µs |
| gin | 30,000/s | not reached | 147 µs | 929 µs |
| nethttp | 30,000/s | not reached | 148 µs | 972 µs |

## Reading it

**Below the knee, the gap is about 2.3×.** At 10,000 and 15,000 requests per
second — comfortably inside every server's capacity — Druse answers in 333 and
391 µs against 129–156 µs. That is the comparable number, and it is the one this
investigation existed to find. The 700× figure from the morning was a queue
depth reported as a service time.

**At 5,000/s Druse is the fastest of the four**, 338 µs against 601–607. Why the
three Go peers are three to four times slower at that rate than at 10,000 is
**not explained here**. It reproduces across all three of them and across
repeats, so it is a property of the peers or of the generator at low rates, not
noise. It is recorded rather than smoothed over.

**Druse's ceiling is about 20,800 responses per second** on this workload with
four lanes. It serves 20,000 fully; at 25,000 it delivers 20,703 and at 30,000
it delivers 20,809 — the same ceiling, with the excess shed. The peers do not
reach theirs inside this sweep.

**The failures are the acceptor's saturation refusals**, the same classes
attributed in `2026-07-30-soak-failure-attribution.md`. They begin at 10,000/s
(9 of 100,000), grow to 30 at 15,000 and 67 at 20,000, and the peers show zero
throughout. This is the bounded-lane design doing what `docs/operations.md`
describes: Druse refuses at the acceptor, the peers queue on an unbounded
goroutine pool. On four CPUs the same pressure lands in different places.

## What this does not settle

It does not explain the 2.3×. Two candidates are visible in the code and neither
is measured here: Druse runs a **second full validation pass** over every
marshalled body (`encoding_json.is_valid`, `web/respond.odin:108`) that no peer
runs, and the pinned encoder walks RTTI with a `struct_tag_lookup` per field per
request where Go's `encoding/json` caches a per-type encoder. **The encode path
has never been profiled** — the profile in the 2026-07-25 study is a decode
profile, and no marshal symbol appears in it.

It does not measure the float cost in isolation. The 50× is at one rate, on the
socket, and mixes rendering cost with the queue it caused.

It is one box, one document shape, no TLS, no database, and Axum and Fastify are
absent because the host has neither toolchain.

## Reproduce

```
bench/application_matrix/run-rate-sweep.sh OUT /json/medium/int 10 3 \
  5000 10000 15000 20000 25000 30000
```

Requires a dedicated idle host. Evidence:
`PRIORIDADE/entrega/evidencias/2026-07-30-json-knee/`.
