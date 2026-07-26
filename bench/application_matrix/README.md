# Application performance matrix

This harness separates costs that `/ping` cannot:

| endpoint | work |
|---|---|
| `GET /health` | fixed text control |
| `GET /json/small` | route + small JSON encode |
| `GET /json/medium` | fixed nested JSON encode control |
| `POST /json/echo` | strict small JSON decode + encode |
| `POST /json/medium` | strict nested JSON decode + encode |
| `POST /json/medium/decode` | same strict nested decode, 204 response |
| `GET /api/users/42?verbose=1` | param/query extraction, request ID, three middleware frames, typed request state, JSON encode |

The optional Uruquim argument fixes `web.Limits.max_handlers`. The four-core
reference build and run are:

    odin build bench/application_matrix/uruquim \
      -collection:uruquim=. \
      -o:speed \
      -out:/tmp/uruquim-application-matrix

    taskset -c 0-3 /tmp/uruquim-application-matrix 4

Examples:

    taskset -c 4-7 wrk -t4 -c100 -d10s --latency \
      http://127.0.0.1:8080/json/small

    taskset -c 4-7 wrk -t4 -c100 -d10s --latency \
      -s bench/application_matrix/wrk/post_small.lua \
      http://127.0.0.1:8080

    taskset -c 4-7 wrk -t4 -c100 -d10s --latency \
      -s bench/application_matrix/wrk/post_medium.lua \
      http://127.0.0.1:8080

Before recording performance, verify every endpoint's status, media type and
body. Performance runs use `-o:speed`; debug builds are correctness controls,
not product measurements.

Uruquim's efficient strict JSON paths are native defaults; applications do not
need runtime configuration. For framework-maintainer rollback/A-B only:

    odin build bench/application_matrix/uruquim \
      -collection:uruquim=. \
      -o:speed \
      -define:URUQUIM_JSON_DIRECT_PREFLIGHT_PARSE=false \
      -out:/tmp/uruquim-json-validator-control

    odin build bench/application_matrix/uruquim \
      -collection:uruquim=. \
      -o:speed \
      -define:URUQUIM_JSON_FUSED_TREE_DECODE=false \
      -out:/tmp/uruquim-json-stdlib-control

Do not restart an io_uring server between every short `wrk` repetition. On the
reference VPS, rapid process churn temporarily caused bind/start failures and
contaminated an early A/B. Keep each binary alive for all repetitions, stop it,
wait for teardown, then start the other block. Report medians, p99 and non-2xx
for both blocks.

To isolate decode from response serialization:

    URUQUIM_BENCH_PATH=/json/medium/decode \
      taskset -c 4-7 wrk -t4 -c100 -d10s --latency \
      -s bench/application_matrix/wrk/post_medium.lua \
      http://127.0.0.1:8080

## Pinned peers

The peer implementations live under `peers/` and expose the same endpoints.
Their lockfiles are part of the instrument:

| peer | pinned version |
|---|---|
| Go standard library | Go 1.26.1 |
| Gin | 1.12.0 |
| Fiber / fasthttp | 3.4.0 / 1.72.0 |
| Axum / Hyper | 0.8.9 / 1.11.0 |
| Fastify / Node | 5.8.5 / 25.1.0 |

Build the Go peers:

    cd bench/application_matrix/peers/go
    go build -buildvcs=false -trimpath -o /tmp/uruquim-peer-nethttp ./cmd/nethttp
    go build -buildvcs=false -trimpath -o /tmp/uruquim-peer-gin ./cmd/gin
    go build -buildvcs=false -trimpath -o /tmp/uruquim-peer-fiber ./cmd/fiber

Build Axum:

    cd bench/application_matrix/peers/axum
    cargo build --release --locked

Install Fastify:

    cd bench/application_matrix/peers/fastify
    npm install --ignore-scripts

The Go harness rejects unknown fields and trailing JSON values but, like the Go
stdlib, accepts duplicate object keys. Axum uses Serde
`deny_unknown_fields` and rejects duplicate fields. Fastify uses a strict body
schema but JSON.parse accepts the last duplicate. Uruquim's stable contract is
stricter than the Go/Fastify cases, so benchmark tables must carry this note.

The measured 2026-07-25 one-box study, including medians, error rates, profile,
soak and the two-box publication caveat, is in
`docs/reports/2026-07-25-json-application-performance.md`.
