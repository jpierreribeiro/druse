# Six frameworks, one open-loop matrix — 2026-07-30

Druse, Axum, Fiber, Gin, net/http and Fastify, on one dedicated host, at one
offered rate. This is the comparison the earlier matrix could not make: the two
frameworks the 2026-07-25 study named as the ones to beat — Axum for encode,
Fastify as the scripting baseline — were absent from it because the host had
neither toolchain.

## Verdict in one paragraph

**On small responses Druse is third of six**, within 10–13 µs of Axum and Fiber
and ahead of Gin, net/http and Fastify. **On nested JSON encode it is last of
the four that serve the offered rate**, which is the gap
`2026-07-30-nested-json-knee.md` measured at about 2.3× below saturation.
**On the decode path it delivers more than Gin, net/http and Fastify** — only
Axum and Fiber serve that endpoint fully, and Druse leads the remaining three.
Axum wins or ties every endpoint.

## Method

Open loop, offered 20,000 requests per second, five repeats of ten seconds per
server per endpoint, servers alternated between repeats so no server holds a warm
cache for a whole block. AWS `c5.2xlarge`, server pinned to CPUs 0–3, generator
to CPUs 4–7, four Druse handler lanes, commit `9b473c2` with the JSON type gate
**off** (this is the shipped configuration, not the prototype). The latency clock
starts at each request's *scheduled* time, so a server that falls behind cannot
hide it by slowing the client down.

**Where goodput is below 100%, the p50 in that row is a queue depth, not a
service time, and the summariser marks it.** Those rows say what a server
*failed to serve*; they do not say what a request costs.

## Small responses — all six serve the rate

| | `/health` (2 B) | `/json/small` (62 B) | `/api/users/42` (39 B) |
|---|---:|---:|---:|
| **axum** | **91 µs** | **92 µs** | 103 µs |
| **fiber** | 95 µs | 95 µs | **98 µs** |
| **druse** | **101 µs** | **105 µs** | **108 µs** |
| gin | 118 µs | 119 µs | 123 µs |
| nethttp | 117 µs | 120 µs | 123 µs |
| fastify | 141 µs | 138 µs | *(different payload — see below)* |

Every server delivered 20,000/s with zero failures on the first two. Druse is
third of six, 10 µs behind Axum and 6 behind Fiber, and 12–15 µs ahead of both Go
standard-library-family servers.

**Fastify's `/api/users/42` answers 106 bytes against everyone else's 39** — a
+171.8% payload difference, so its row on that endpoint is not a comparison. The
size check added this morning flagged it automatically; the previous matrix had
no such check and I had to find the equivalent defect by hand.

## Nested JSON encode — the known gap, at scale

`/json/medium/int`, 4,310 bytes byte-identical across all six:

| server | goodput | p50 |
|---|---:|---:|
| axum | 20,000/s (100%) | **121 µs** |
| fiber | 20,000/s (100%) | 134 µs |
| gin | 20,000/s (100%) | 156 µs |
| nethttp | 20,000/s (100%) | 156 µs |
| **druse** | **19,994/s (100%)** | **2,343 µs** |
| fastify | 16,183/s (80.9%) | *queue* |

Druse serves the rate, but 20,000/s **is its knee on this workload** — the p50
there is the queue beginning to form, not the cost of a request. The comparable
figure is from the rate sweep: **333–391 µs at 10,000–15,000/s against
129–156 µs**, about 2.3×, with a ceiling near 20,800/s.

The measured, not-yet-adopted per-type validation gate
(`2026-07-30-encode-type-gate.md`) takes that to about **1.8× and ~26,100/s**.
Even with it, Axum and Fiber remain ahead on this endpoint.

The float variant `/json/medium` is **withdrawn** for the reason published in
the knee report: Odin renders `f64` with sixteen decimals, so Druse puts 5,398
bytes on the wire against the peers' 4,438 and the row compares two payloads as
well as two servers. The summariser flags it rather than printing it as a result.

## Decode — Druse leads three of the five peers

`/decode/medium`, a POST that parses the same document. At 20,000/s offered,
**four of six servers cannot serve it**:

| server | goodput | reading |
|---|---:|---|
| axum | 20,000/s (100%) | serves it, 159 µs |
| fiber | 19,999/s (100%) | serves it, 392 µs |
| **druse** | **18,053/s (90.3%)** | **most delivered of the rest** |
| gin | 16,424/s (82.1%) | past its knee |
| nethttp | 16,141/s (80.7%) | past its knee |
| fastify | 9,975/s (49.9%) | serves half |

This is the one endpoint where Druse beats the Go standard-library family
outright, and it is where the project spent its optimisation effort — the
2026-07-25 study cut `reflect::struct_tag_lookup` from 15.20% to 0.26% on this
path. The result is that decode holds up while encode does not, which is exactly
what the profile predicts.

## Failures

**Only Druse reports failures, and every one of them is classified.** 104 on
decode-medium, 119 on the float route, 66 on the integer route; the classes are
`eof_on_fresh_conn`, `peer_reset`, `request_write_failed`, `broken_pipe`. These
are the acceptor's saturation refusals attributed in
`2026-07-30-soak-failure-attribution.md`: with four bounded lanes on four CPUs,
Druse refuses at the acceptor while the Go and Rust peers queue on an unbounded
task pool and Node queues in its event loop. The pressure is the same; the
design chooses a different place to put it, and `docs/operations.md` §6 says so.

Zero of them are unclassified — the accounting rule the analyzer now enforces.

## What this does not settle

One box, four handler lanes, no TLS, no database, six documents. Fastify's
numbers are a single-process Node server against compiled peers on four CPUs,
which is a floor rather than a fair fight, and its `/api/users/42` payload
differs. Axum leading nearly everything is consistent with the 2026-07-25 study
and is not re-derived here.

## Reproduce

```
DRUSE_BENCH_PEER_BIN=... bench/application_matrix/run-openload-matrix.sh OUT 20000 5 10
python3 bench/application_matrix/summarise-openload-matrix.py OUT
```

Evidence: `evidence/2026-07-30-six-framework-matrix/`.
