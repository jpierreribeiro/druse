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
| `/json/medium` **(not comparable — see correction)** | **druse** | **19,542** | **97.7%** | **113,136 µs** | **232,601 µs** | **64** |
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

**On nested JSON it is the only server that does not serve the rate — and that
row is not a like-for-like comparison.** Read the correction below before using
it. At `/json/medium` the three Go peers deliver 20,000/s at 145–164 µs while
Druse delivers 19,542/s at a p50 of 113 **milliseconds**, and the shortfall in
goodput says the latency figure describes a queue rather than a service time.

> ### Correction, added after publication
>
> **Druse emits 5,398 bytes per response on this endpoint; the three peers emit
> 4,438.** The documents are otherwise identical — same fields, same nesting,
> same values, all four pre-build the 64-item payload once at startup. The
> entire 960-byte difference is float rendering: Odin's pinned
> `core:encoding/json` writes `1.5000000000000000` where Go writes `1.5`,
> fifteen extra bytes times sixty-four items, which reproduces to the byte.
>
> **This confound was already known, and this run reintroduced it.**
> `2026-07-25-json-application-performance.md` says: "the medium response is
> compared semantically because Odin's pinned encoder renders `f64` with more
> digits than the peer encoders. **The decode-only endpoint removes that
> wire-size confound.**" That study measured `POST /json/medium/decode`
> precisely to avoid this. This run measured `GET /json/medium` and did not
> carry the caveat forward. That is an error in this report, not in the earlier
> one.
>
> Two further asymmetries belong beside it. Druse runs a **second full
> validation pass** over every marshalled body (`encoding_json.is_valid`,
> `web/respond.odin:108`) that no peer runs. And Druse answers on **four fixed
> handler lanes** where the peers use unbounded goroutines, so the same
> per-request cost turns into a queue here and into a longer service time there.
>
> **What survives.** A 21.6% payload difference cannot produce a ~780× latency
> difference, and Druse moved **more** bytes per second than the peers while
> showing it — 103.5 MB/s against 88.8. So a real gap is being reported. But its
> size is not the number in this table, and the table cannot be used to size it.
> The five repeats spread from 101 ms to 199 ms, a factor of two, where the peers
> held 144–145 µs with a spread of one microsecond: past the knee, that figure
> measures how far the queue grew, not what a request cost.
>
> **The number is withdrawn pending a re-run** with the float rendering
> normalised and a rate sweep to locate the knee. The other three rows stand:
> they are byte-identical across all four servers.
>
> `summarise-openload-matrix.py` now prints bytes per response and refuses to
> present a row whose servers disagree on it. It did not, which is why this
> correction was found by hand after publication rather than by the instrument
> before it.

**`/json/medium/decode` saturates the box for three of the four.** Gin and
`net/http` also fall behind, at 82.1% and 80.8%, with p50s over a second. Druse
is between them and Fiber at 87.6%. Only Fiber serves it whole. So this endpoint
is not a Druse-specific finding. Neither, on its own, is the medium encode row above — see the correction.

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

It does not size the medium-JSON gap, and after the correction above it does not
claim to. `2026-07-25-json-application-performance.md` established that strict
*decoding* of a nested document was the material deficiency and that two changes
improved it by 48% and 25%. Neither touched encoding, and **the encode path has
never been profiled** — the profile in that study is a decode profile taken under
a POST workload, and no marshal symbol appears in it. What this run establishes
is that an encode-side question exists and that the instrument was not yet good
enough to answer it.

## Reproduce

```
bench/application_matrix/run-openload-matrix.sh OUT_DIR 20000 10 5
```

Requires a dedicated idle host — on a shared machine this produces numbers about
the machine. `DRUSE_BENCH_PEER_BIN` accepts prebuilt Go peers, and
`DRUSE_BENCH_COMMIT` supplies the revision when the tree arrives without `.git`.
