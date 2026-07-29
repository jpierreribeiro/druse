# JSON and application-path performance study — 2026-07-25

## Verdict

The transport is not the limiting component for ordinary small application
work. On the same four server cores, Uruquim is faster than Go `net/http`, Gin
and Fastify for fixed text, small JSON, small strict decode+encode, and a routed
request with middleware. Its p99 is also lower than those peers in those
workloads.

The material deficiency was a different and narrower one: strict decoding of a
nested document. Uruquim's preflight built a `json.Value` tree, walked it with
RTTI to classify shape/unknown/range failures, and then tokenized the same bytes
again in the typed stdlib unmarshaller.

Two measured internal changes are adopted. Removing the redundant syntax
validator improved the medium round trip by **9.06%**. Reusing the already
strict, shape-checked tree for the ordinary DTO subset then improved decode-only
throughput by **48.03%** and the medium round trip by **25.44%** against its
immediate control. Wider types retain the stdlib fallback. The public API and
strict error taxonomy do not change.

Uruquim still does **not** lead large-document JSON: Axum remains about 4x
faster in decode-only goodput. These are loopback CPU/application-path numbers,
not real-NIC throughput claims for the project README.

## Rig and method

- AWS `c5.2xlarge`, 8 vCPU, Linux `6.17.0-1017-aws`
- one-box loopback: server pinned to CPUs `0-3`, `wrk` pinned to CPUs `4-7`
- `wrk 4.1.0`, four threads, five 10-second repetitions unless stated
- Uruquim built with Odin `dev-2026-07-nightly:819fdc7`, `-o:speed`
- Uruquim `max_handlers=4`, matching the four allocated server CPUs
- Go `1.26.1`; `GOMAXPROCS=4`
- Axum Tokio worker count `4`
- Fastify run as four cluster workers
- c100 result is the median of five runs; Uruquim's adoption A/B uses ten runs

The peers are pinned in the benchmark lockfiles:

- Go `net/http`
- Gin `1.12.0`
- Fiber `3.4.0` / fasthttp `1.72.0`
- Axum `0.8.9` / Hyper `1.11.0`
- Fastify `5.8.5` / Node `25.1.0`

The comparison is semantic, not a claim that every invalid-input contract is
identical. Uruquim rejects malformed JSON, trailing values, duplicate keys,
unknown fields, wrong shapes and out-of-range integers with its stable
taxonomy. Axum uses Serde with `deny_unknown_fields` and also rejects duplicate
fields. The Go peers use the stdlib decoder with unknown-field and trailing
value rejection, but Go accepts duplicate object keys. Fastify uses a strict
body schema but JSON.parse accepts the last duplicate key. These differences
are features and costs, so they must accompany any result table.

## Workloads

| endpoint | measured work |
|---|---|
| `GET /health` | fixed text control |
| `GET /json/small` | route plus small JSON encode |
| `POST /json/echo` | strict small JSON decode plus encode |
| `POST /json/medium` | 4.6 KiB, 64 nested items, strict decode plus encode |
| `GET /api/users/42?verbose=1` | param/query, request ID, three middleware frames, request state, JSON |
| `POST /json/medium/decode` | same medium strict decode, then 204; isolates response encoding |

All bodies and statuses were checked before load. The medium response is
compared semantically because Odin's pinned encoder renders `f64` with more
digits than the peer encoders. The decode-only endpoint removes that wire-size
confound.

## c100 cross-framework result

Values are median req/s and median p99. Non-2xx is zero unless shown.

| runtime/framework | health | small JSON | small echo | medium round trip | routed |
|---|---:|---:|---:|---:|---:|
| **Uruquim / Odin** | **245,465 / 0.661 ms** | 210,678 / 0.850 ms | 149,189 / 1.35 ms | 9,623 / 18.78 ms¹ | **180,193 / 0.596 ms** |
| Go `net/http` | 150,727 / 2.55 ms | 144,632 / 2.65 ms | 111,221 / 3.38 ms | 15,848 / 50.71 ms | 130,754 / 2.95 ms |
| Gin | 145,946 / 2.67 ms | 141,793 / 2.78 ms | 107,613 / 3.59 ms | 16,321 / 40.25 ms | 128,076 / 3.03 ms |
| Fiber / fasthttp | 256,732 / 1.37 ms | 243,710 / 1.54 ms | 170,399 / 3.99 ms | 22,309 / 16.95 ms | 222,878 / 1.61 ms |
| Axum / Hyper | 257,405 / 0.684 ms | **245,284 / 0.723 ms** | **207,608 / 0.940 ms** | **54,496 / 3.74 ms** | 167,746 / 1.08 ms |
| Fastify / Node | 114,846 / 1.85 ms | 112,722 / 1.93 ms | 64,473 / 3.22 ms | 32,486 / 6.20 ms | 98,596 / 2.18 ms |

¹ Uruquim returned 87 load-shed 503s across 481,506 medium requests
(`0.01807%`) in the fused A/B block. The table reports total completed req/s,
so the corresponding successful goodput is slightly lower. Reporting req/s
without this error rate would be misleading.

The realistic reading is mixed:

- Uruquim comfortably beats `net/http`, Gin and Fastify on small common paths.
- Fiber is modestly faster, while Uruquim keeps substantially lower p99 for
  small JSON and routed work.
- Axum leads this matrix. Uruquim is not the universal latency leader once the
  payload becomes CPU-heavy.
- Uruquim's medium decoder is the clear outlier and deserves a dedicated future
  work package.

## Decode-only control

This endpoint returns 204 after a successful medium decode, removing response
serialization and Uruquim's longer float rendering.

| runtime/framework | req/s | p99 |
|---|---:|---:|
| Uruquim, direct-parse control | 11,268 | 18.70 ms |
| Uruquim, fused tree decode | 16,679 | 12.70 ms |
| Go `net/http` | 18,895 | 42.11 ms |
| Gin | 19,155 | 34.72 ms |
| Fiber | 27,062 | 13.43 ms |
| Axum | 67,294 | 3.02 ms |
| Fastify | 41,763 | 4.71 ms |

The original gap therefore belonged to decode/validation, not merely to
response size. Fusing the two Uruquim passes closes a material portion of it,
but Axum is still the decisive architecture reference: Serde performs typed,
monomorphized decoding and field lookup without building a general
`json.Value` tree.

## Profile

`perf record -e cpu-clock -F 499 -p SERVER_PID -g` under the medium workload
collected 29k samples with zero loss before the fused decoder. The largest flat
symbols were:

| symbol | self CPU |
|---|---:|
| `encoding_json::get_token` | 16.22% |
| `utf8::decode_rune_in_bytes` | 8.05% |
| `encoding_json::next_rune` | 7.31% |
| `reflect::struct_tag_lookup` | 6.86% |
| `encoding_json::is_valid_string_literal` | 6.62% |
| `encoding_json::parse_value` | 3.48% |
| `encoding_json::unquote_string` | 2.96% |
| `web::body_json_preflight` | 1.57% self |

Hardware PMU counters were unavailable on this VPS, so cycles/instructions and
cache-miss claims are deliberately absent. Software counters showed all four
server CPUs occupied.

The same profile after fusion collected 59k samples with zero loss:

| symbol | self CPU |
|---|---:|
| `reflect::struct_tag_lookup` | 10.16% |
| `encoding_json::get_token` | 7.78% |
| `runtime::_append_elems` | 4.51% |
| `utf8::decode_rune_in_bytes` | 4.26% |
| `encoding_json::next_rune` | 4.24% |
| `encoding_json::parse_value` | 3.12% |
| `web::body_json_preflight` | 2.77% |

The ranking changed as expected: the removed typed token pass is gone, while
field-target resolution inside the fused tree walk is now the largest bounded
cost. This does not retroactively validate the rejected standalone cache; an
integrated fused-target descriptor is a distinct future experiment.

## Adopted change: direct strict preflight parse

Before this change, every valid request ran:

1. allocation-free depth scan;
2. full `json.is_valid` tokenization;
3. full strict parse into a disposable dynamic arena;
4. RTTI shape/unknown/range walk;
5. typed unmarshal into the request arena.

The parser is already the syntax authority. The adopted default removes step 2.
The depth bound remains. The strict parser still rejects malformed input,
duplicate keys and trailing tokens. The shape walk and typed unmarshal remain.
`context.allocator` is bound to the disposable arena for the whole parse, so
partial-tree cleanup uses the same allocator.

A private build-time rollback remains for one release:

    -define:URUQUIM_JSON_DIRECT_PREFLIGHT_PARSE=false

Applications do not set this flag in normal use. The faster path is native and
the public 82-symbol API is unchanged.

### Ten-run A/B, medium round trip

| variant | median req/s | median p99 | non-2xx |
|---|---:|---:|---:|
| validate + parse control | 6,847 | 27.99 ms | 0.15322% |
| direct parse | 7,468 | 26.69 ms | 0.11352% |

Throughput gain: **9.06%**. p99 change: **-4.63%**. The gain exceeds the 5%
adoption floor and the observed throughput spread.

For the small echo the gain is 3.33% (134,799 to 139,290 req/s), below the
standalone adoption floor but in the expected direction. The medium result is
the adoption case.

## Rejected experiment: request-local RTTI metadata cache

The profile made `reflect.struct_tag_lookup` a reasonable bounded experiment.
A request-local descriptor cache resolved field names once for repeated object
types, owned all descriptor storage by the disposable preflight arena, and
introduced no global state, App back-pointer or synchronization.

The first implementation showed a small-path cost, so a second version cached
only struct types repeated by arrays. The final stable block result was:

| workload | control req/s / p99 | cache req/s / p99 | throughput |
|---|---:|---:|---:|
| medium decode-only | 11,267 / 18.66 ms | 11,722 / 17.74 ms | +4.04% |
| medium round trip | 7,580 / 25.99 ms | 7,734 / 30.62 ms | +2.04% |
| small echo | 139,252 / 1.55 ms | 139,759 / 1.40 ms | noise-level |

This fails the adoption rule: the application gain is marginal and the medium
round-trip p99 regressed 17.8%. The cache code is not shipped. This result also
shows why a flat 6.86% profile symbol is not automatically a 6.86% application
win: some tag resolution belongs to the remaining stdlib pass.

## Adopted change: fused strict tree decode

For the ordinary request-DTO subset — structs containing UTF-8 strings,
platform-endian integers/floats, booleans, slices and fixed arrays — the
strictly parsed and shape-checked `json.Value` tree now populates the
destination directly in the request arena. This removes the second
tokenization pass.

Compatibility is fail-safe:

- maps, unions, enums, recursive schemas and registered custom unmarshalers are
  rejected by the fast-path eligibility check and use the pinned stdlib;
- a value-level miss, such as the stdlib's accepted numeric string for an
  integer destination, falls back without changing the public result;
- all cloned strings and slice storage use `request_arena_allocator(ctx)`;
- malformed, duplicate, trailing, unknown, wrong-shape and out-of-range inputs
  still pass through the same strict parse and stable classification first.

A private rollback remains:

    -define:URUQUIM_JSON_FUSED_TREE_DECODE=false

### Five-run block A/B, c100

Each binary stayed alive for all five repetitions; the 15-second pause between
blocks avoids making rapid io_uring teardown/restart part of the experiment.

| workload | direct-parse control | fused tree decode | throughput | p99 |
|---|---:|---:|---:|---:|
| medium decode-only | 11,268 / 18.70 ms | 16,679 / 12.70 ms | **+48.03%** | **-32.09%** |
| medium round trip | 7,671 / 25.09 ms | 9,623 / 18.78 ms | **+25.44%** | **-25.15%** |
| small echo | 140,183 / 1.55 ms | 149,189 / 1.35 ms | **+6.42%** | **-12.90%** |

The result is material on all three measured decode paths and improves, rather
than trades away, tail latency.

## Lane saturation is a separate limit

Four synchronous lanes on four cores maximize CPU efficiency but can return a
bounded 503 when a connection is assigned to an already-busy lane. With the
medium workload:

| lanes on four CPUs | median req/s | median p99 | non-2xx |
|---|---:|---:|---:|
| 4 | 7,468 | 26.69 ms | 0.11352% |
| 8 | 7,334 | 33.90 ms | 0.01655% |

Eight lanes reduce refusal probability, but cost throughput and tail latency
through oversubscription. This is not a free tuning recommendation. The native
automatic policy remains CPU-derived; operators should use
`web.stats().handler_dwell_ns` to derive lane utilization. The old
`lane_collisions` field was retired after dedicated accept proved it counted
acceptor refusals under the wrong name.

Before the fused decoder, Uruquim's c400 median results were:

| workload | req/s | p99 | non-2xx |
|---|---:|---:|---:|
| health | 270,838 | 2.46 ms | 0 |
| small JSON | 235,695 | 2.99 ms | 0 |
| small echo | 143,595 | 4.89 ms | 0.00160% |
| medium round trip | 7,361 | 86.03 ms | 0 |
| routed | 191,521 | 3.39 ms | 0.00488% |

The c100-to-c400 p99 growth is queueing under four times as many concurrent
connections, not a 3.9x throughput claim. Throughput is already near saturation,
so added concurrency mostly increases waiting time.

With the fused decoder, three c400 medium round-trip runs had median
**9,593 req/s** and median **74.69 ms p99**. They returned 358 load-shed 503s
across 291,937 requests (`0.12263%`). Versus the pre-fused c400 result, goodput
rose about 30% and p99 improved about 13%; the bounded refusal rate must still
be reported.

## Soak and gates

The pre-fused five-minute c100 medium soak completed:

- 2,254,567 requests at 7,513.22 req/s;
- p99 26.13 ms;
- 59 load-shed 503s (`0.00262%`);
- RSS 6,056 KiB to 6,264 KiB;
- high-water RSS 8,368 KiB to 8,400 KiB;
- zero page faults during the 280-second warmed perf window.

The fused default then completed its own five-minute c100 medium soak:

- 2,921,752 requests at 9,736.20 req/s;
- p99 18.87 ms;
- 116 load-shed 503s (`0.00397%`);
- RSS 4,124 KiB to 5,804 KiB;
- high-water RSS 8,812 KiB.

The definitive full gate passed on 2026-07-26 outside the filesystem/network
sandbox with the pinned compiler. It included the WP7 allocator/leak tests,
all then-present 16 WP68 JSON cases, in-memory and real-socket conformance, the raw-wire
corpus, mutation controls, C-01 async inventory, C-03 fault campaign, response
retention soak, deadline/drain, WP98 proxy interop and WP99 streaming slice.
The public ledger remains 80 application plus 2 test-support symbols.

Final review added two positive differential contracts for the fused scalar
subset and `null` zeroing. All 18 decoder cases then passed with the default
fast path and with both rollback flags disabled; this test-only addition did
not change the already gate-validated implementation.

That run also included a separate transport correction discovered while
closing the gate: the dedicated acceptor's eight-item handoff bound made the
current baseline fail C-03 at roughly 50k RST connections/s. The final bound of
two passed C-03 three times before the full gate and then served 58/58 healthy
probes inside the gate. Its `/ping` cost versus eight was -1.16% at c100 and
-1.58% at c400, with median p99 0.646 ms and 2.38 ms. The full investigation
and reproduction instructions are in
`docs/reports/2026-07-25-dedicated-accept-throughput.md` and
`bench/framework_ping/README.md`.

## Future work, in evidence order

1. **Do not revisit transport flags for this gap.** The decode-only control
   isolates CPU in JSON/RTTI.
2. **Prototype an integrated fused-target descriptor, not the rejected
   standalone cache.** The post-fusion profile puts field-tag lookup at 10.16%
   self CPU. A descriptor owned by the disposable parse arena could resolve
   effective field targets once per concrete struct, but it needs a new A/B and
   must preserve explicit-tag/default-name/flattened-using precedence.
3. **Do not revive the standalone RTTI cache unchanged.** It was measured and
   failed the application-path adoption rule.
4. **Study a one-pass typed parser.** The fused decoder removes the second token
   pass but still allocates and walks a general tree. Parsing directly into the
   request arena while maintaining the bounded field path, duplicate/unknown
   refusal and exact range taxonomy is the remaining internal route toward
   Axum.
5. **Consider generated/monomorphized codecs only with an explicit ergonomics
   study.** Axum proves the performance ceiling, but mandatory user-visible
   code generation would be a product/API decision, not an internal
   optimization.
6. **Use two physical boxes before public throughput claims.** This report is a
   valid CPU/application-path study because client and server cores are
   disjoint. It is still loopback and does not replace the required real-NIC
   validation for transport or README headline numbers.
