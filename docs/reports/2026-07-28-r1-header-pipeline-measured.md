# R1 — the response header pipeline, measured

Date: 2026-07-28. Host: 4 vCPU KVM, loopback, `tsc` clocksource.
Toolchain: the pinned `dev-2026-07-nightly:819fdc7`.

## What R1 claims

The July audit's backlog records R1 as the largest single hot-path cost:

> Every header is copied three times and rebuilt once … For a typical routed
> response that is ~10–15 small allocations, two full header copies, one
> lowercase re-render, a hash map built and iterated — per request … This is the
> audit's pick for the routing-benchmark gap.

Two separate claims live in that paragraph: a **magnitude** (~10–15 allocations
per request) and a **ranking** (the biggest single cost). The audit marked R1
"verified as code cost, but not benchmarked" — that is, both claims come from
reading. This project's own standard says a claim without a measurement is a
hypothesis, and this audit has been confidently wrong often enough that the
number should exist before anyone rewrites the pipeline for it.

## Method

A temporary counting allocator was interposed on the **per-request arena** —
`conn_handle_reqs` in `vendor/odin-http/server.odin`, the allocator passed to
`request_init`/`response_init` and therefore the one backing the headers map,
`sanitize_key`, `response_headers_neutral_transport` and `copy_response`. Every
`Alloc`/`Resize` was counted and forwarded unchanged.

Three routes differing only in how many response headers the handler sets, 200
requests each, `Connection: close`, after a 20-request warmup so first-touch
arena growth is not charged to the measurement. The shim was reverted before
commit; it is a measurement instrument, not a shipped counter.

## Result

| route | extra response headers | allocations / request | arena bytes / request |
|---|---|---|---|
| `/plain` | 0 | **7.00** | 1223 |
| `/few` | 2 | **8.00** | 1084 |
| `/many` | 6 | **13.00** | 1960 |

Identical to two decimal places across two independent runs — this is a
deterministic count, not a sample.

## Verdict

**The magnitude claim is corroborated.** A minimal routed response costs 7
arena allocations before the handler adds a single header of its own, and each
additional response header costs about one more. A response carrying six
application headers lands at 13, inside the "~10–15" the audit estimated. The
per-header slope is real and it is roughly linear.

**The ranking claim is still unproven, and nothing here tests it.** "The biggest
single hot-path cost" is a comparison against the other candidates — R2's body
copies and heap round-trip, R3's ~7 KB of `Context` zeroed per request, R4's
double request-header conversion, R5's routing walk. An allocation count ranks
none of them. It would take a profile (`perf record` on the routing benchmark)
to say which dominates, and that has not been run. R1 should be described as
"a measured 7–13 allocations per request" and NOT as "the biggest cost" until
that profile exists.

**Scope of the number.** It counts the request arena only. Response bodies
allocated from the lane's heap allocator (R2) are outside it, so 7–13 is a floor
on total allocations per request, not the whole figure.

## What would move this

- A `perf record` on the routing benchmark, to settle the ranking honestly.
- An allocs-per-request figure for the same three routes after any pipeline
  rewrite, which is now cheap to produce: the instrument is four lines around
  `virtual.arena_allocator` and the probe drives ordinary sockets.
- The Campaign C dispatch-bracket delta on the same benchmark, still owed
  (freeze Amendment 33).
