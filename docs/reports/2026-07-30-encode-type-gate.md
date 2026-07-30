# A per-type gate on the response validation pass — 2026-07-30

## Verdict

Skipping the second validation pass for response types that **cannot hold a
float** is worth **−21.2% on p50 and +27.7% on ceiling throughput** for nested
JSON, and it keeps the check that pass exists for.

| | control | type gate | change |
|---|---:|---:|---:|
| p50 below the knee (10,000/s) | 339 µs | **267 µs** | **−21.2%** |
| Ceiling (offered 30,000/s) | 20,431/s | **26,097/s** | **+27.7%** |

The upper bound — removing the pass entirely, which is not shippable — is
−23.0% and +31.9%. **The gate captures 92% of the latency gain and 87% of the
throughput gain while remaining correct.**

Against the Go peers on the same byte-identical document, this moves Druse's
per-request cost from about 2.3× theirs to about 1.8×, and its ceiling from
~20,400/s to ~26,100/s where they exceed 30,000/s.

## What the pass is, and why it exists

`web/respond.odin` re-runs `encoding_json.is_valid` over every body the
marshaller just produced. The reason is recorded at the call site: the pinned
marshaller writes a non-finite float — `NaN`, `+Inf`, `-Inf` — as a **bare
token**, which is not valid JSON, and the framework promises strict JSON on the
wire. `tests/wp6-public-surface` pins the behaviour: a handler returning
`math.inf_f64(1)` must produce a complete 500, and the token must never reach
the client.

The 2026-07-30 encode profile measured its price for the first time: **about a
quarter of encode self time.**

## Why a gate is possible now

The call site's own note says a compile-time walk cannot express this on the
pinned toolchain, and that is correct — `base:intrinsics` resolves a field type
only by name (`type_field_type($T, $name: string)`), so a recursion over a
struct's fields cannot be written.

What the note does not consider is a **runtime walk done once per type**.
`@(static)` inside a parametric procedure gives each instantiation its own
slot — verified on the pinned toolchain, where three calls with `Alpha` and two
with `Beta` counted 1,2,3 and 1,2 rather than sharing a counter. So the answer
is computed once per response type for the life of the process, and every later
response pays one integer comparison.

That is a different object from the RTTI cache the 2026-07-25 study measured and
**rejected**: that one cached field metadata per request on the decode path and
cost p99 +17.8%. This caches one integer per type, for ever.

## The walk is conservative by construction

`json_type_may_hold_float` answers `true` for anything it does not recognise —
`any`, procedures, raw pointers, and any variant not enumerated — and for a
self-referential type that exceeds its depth bound. A wrong `false` is the one
outcome the mechanism exists to prevent, so every uncertain case pays the pass.

Floats, complex and quaternion answer `true`. Integers, booleans, strings,
runes, enums and bit sets answer `false`. Structs, arrays, slices, dynamic
arrays, maps, pointers and unions recurse into their members.

Two lanes racing on the first write compute the **same** value, so the race is
benign: neither can install a wrong answer.

## The safety property is proven in both directions

**With the gate on**, all 15 `wp6-public-surface` contract tests pass, including
`wp6_num001_non_finite_float_yields_a_complete_500`.

**With the walk mutated to stop recognising floats**, that test goes red on five
assertions at once, and the decisive two are:

```
a non-finite float token must never escape onto the wire
the error response body must itself be valid JSON
```

So the existing test does catch a broken gate, and it catches it by observing
the exact failure the pass prevents — invalid JSON reaching the client.

## A candidate measured and rejected

Pre-sizing the marshal builder was the other obvious lever: the profile put
`runtime::_append_elems` at 10.7% of encode self time, growing a 4.3 KB body
from zero capacity. Building into a `strings.Builder` reserved from the previous
response's size, via the public `marshal_to_builder`, measured:

| | control | pre-sized | change |
|---|---:|---:|---:|
| p50 below the knee | 343 µs | 346 µs | +0.9% |
| Ceiling | 20,279/s | 19,755/s | **−2.6%** |

**It does not help, and it costs throughput.** Combined with the skipped pass it
was also worse than the skipped pass alone (+23.6% ceiling against +31.9%).

Recorded because the ritual requires it, and because the lesson generalises: a
symbol's share of a profile is not the gain available from removing it. 10.7% of
self time yielded nothing.

**Do not revive builder pre-sizing unchanged.**

## Method

Paired control and candidate built from one commit differing only by
`-define:DRUSE_JSON_TYPE_GATE`, sha256 of each in the manifest. Five repeats,
variants alternating between repeats, on AWS `c5.2xlarge` with the server pinned
to CPUs 0-3 and the generator to 4-7, four handler lanes, open loop.

Two rates, answering different questions: **10,000/s is below the knee**, so p50
there is a service time; **30,000/s is above it**, where goodput *is* the ceiling
and is the one number a saturated run reports honestly. The harness verifies
before measuring that every variant answers byte-identical responses — 4,310
bytes — because a prototype that changes the response is a different endpoint,
not a faster one.

## Status

**Not adopted.** The flag defaults to off. This is a measured proposal with its
correctness control, and adopting it is a work package: the freeze ritual, the
full gate, and a decision on whether the conservative walk's coverage is wide
enough to keep the promise in `docs/errors.md`.

Evidence: `PRIORIDADE/entrega/evidencias/2026-07-30-encode-prototype/`.
