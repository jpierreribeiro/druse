# The application matrix under an equal offered rate — 2026-07-30

## Why this run exists

Every performance number this project has published came from `wrk`, which is
closed-loop: it offers exactly as much load as each server absorbs, so each
server is measured at its own attained throughput and the latency it reports
mixes service time with queueing. The README says so about the peer table —
"`--latency` prints a histogram, it does not correct for coordinated omission" —
and the caveat applies to the application matrix for the same reason.

This run drives every server at **the same fixed rate**, open loop, with a
generator whose latency clock starts at the request's intended schedule time. A
server that falls behind shows it as latency and as goodput below the offered
rate, instead of quietly being asked for less.

## Rig

AWS `c5.2xlarge`, Linux `6.17.0-1017-aws`. Server pinned to CPUs 0-3, generator
to 4-7. **20,000 requests per second offered**, 10 seconds per measurement, five
repeats, servers alternated between repeats. Druse ran with four handler lanes.
Odin `dev-2026-07-nightly:819fdc7`.

The Go peers were built with Go 1.26.1 — the version their `go.mod` pins — on a
different machine, because the benchmark host carries 1.22.2 and cannot fetch a
toolchain. The manifest records that and the sha256 of each peer binary. **Axum
and Fastify are absent**: the host has neither cargo nor node, and the manifest
records `axum_included=0` / `fastify_included=0` so a partial matrix cannot be
misread as a complete one.

## Result

Median across five repeats.

| Endpoint | Server | Goodput/s | % offered | p50 | p99 | Failures |
|---|---|---:|---:|---:|---:|---:|
| `/health` | **druse** | 20,000 | 100% | **101 µs** | **1,075 µs** | 0 |
| | fiber | 20,000 | 100% | 95 µs | 1,186 µs | 0 |
| | gin | 20,000 | 100% | 119 µs | 1,127 µs | 0 |
| | nethttp | 20,000 | 100% | 118 µs | 1,128 µs | 0 |
| `/json/small` | **druse** | 20,000 | 100% | **105 µs** | **1,077 µs** | 0 |
| | fiber | 20,000 | 100% | 96 µs | 1,170 µs | 0 |
| | gin | 20,000 | 100% | 120 µs | 1,125 µs | 0 |
| | nethttp | 20,000 | 100% | 120 µs | 1,128 µs | 0 |
| `/api/users/42?verbose=1` | **druse** | 20,000 | 100% | **109 µs** | **1,097 µs** | 0 |
| | fiber | 20,000 | 100% | 98 µs | 1,131 µs | 0 |
| | gin | 20,000 | 100% | 124 µs | 1,127 µs | 0 |
| | nethttp | 20,000 | 100% | 124 µs | 1,118 µs | 0 |
| `/json/medium` | **druse** | **19,542** | **97.7%** | **113,136 µs** | **232,601 µs** | **64** |
| | fiber | 20,000 | 100% | 145 µs | 754 µs | 0 |
| | gin | 20,000 | 100% | 164 µs | 498 µs | 0 |
| | nethttp | 20,000 | 100% | 164 µs | 494 µs | 0 |
| `/json/medium/decode` | **druse** | **17,512** | **87.6%** | **734,767 µs** | 1,405,238 µs | **145** |
| | fiber | 19,998 | 100% | 408 µs | 6,741 µs | 0 |
| | gin | 16,413 | 82.1% | 1,085,796 µs | 2,161,636 µs | 0 |
| | nethttp | 16,163 | 80.8% | 1,183,419 µs | 2,352,868 µs | 0 |

## What it says

**On simple and small-JSON work, Druse leads on latency.** Fixed text, small
JSON, and the route that does parameter and query extraction with three
middleware frames, a request ID and typed request state: it serves the full
offered rate with the lowest or second-lowest p50 and the lowest p99 of the four.
The `extract` row matters most of those three — it is the one that exercises the
framework rather than the socket, and Druse is at 109 µs against 124 µs for Gin
and `net/http`.

**On nested JSON it is the only server that does not serve the rate.** At
`/json/medium` the three Go peers deliver 20,000/s at 145–164 µs while Druse
delivers 19,542/s at a p50 of 113 **milliseconds** — three orders of magnitude,
and the shortfall in goodput says the latency figure describes a queue, not a
service time.

**`/json/medium/decode` saturates the box for three of the four.** Gin and
`net/http` also fall behind, at 82.1% and 80.8%, with p50s over a second. Druse
is between them and Fiber at 87.6%. Only Fiber serves it whole. So this endpoint
is not a Druse-specific finding; the medium *encode* row above is.

**Druse's failures are its own saturation refusals.** The classes are
`peer_reset`, `request_write_failed` and `eof_on_fresh_conn` — the same
signature attributed in `2026-07-30-soak-failure-attribution.md`. The peers show
zero failures because they answer every request from a goroutine, however long
the queue gets; Druse has exactly four lanes and refuses at the acceptor when all
four are busy. On the same four CPUs, the two architectures spend a queue in
different places: the peers in latency, Druse in refusals plus latency.

## What it does not say

It does not rank the frameworks. One rate, one box, four endpoints, no TLS, no
database, no keep-alive churn, and two peers missing entirely.

It does not measure capacity. 20,000/s was chosen because all four can nominally
serve it; the endpoints where they cannot are the finding, not the ceiling.

It does not explain the medium-JSON gap. `2026-07-25-json-application-performance.md`
established that strict decoding of a nested document was the material
deficiency and that two changes improved it by 48% and 25%; this run says the gap
is still there on the *encode* side under an equal offered rate, and does not say
why.

## Reproduce

```
bench/application_matrix/run-openload-matrix.sh OUT_DIR 20000 10 5
```

Requires a dedicated idle host — on a shared machine this produces numbers about
the machine. `DRUSE_BENCH_PEER_BIN` accepts prebuilt Go peers, and
`DRUSE_BENCH_COMMIT` supplies the revision when the tree arrives without `.git`.
