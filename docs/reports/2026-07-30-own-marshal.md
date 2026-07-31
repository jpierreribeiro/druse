# A Druse-owned marshal walk, measured

**2026-07-30. Commit `528ae6a`. Not adopted: `DRUSE_JSON_OWN_MARSHAL` defaults
to `false`.**

The encode profile of this morning put 25.7% of encode self time in writing
quoted strings and named the fix — an ASCII fast path — while noting that
reaching it required Druse to own the marshal walk, because
`core:encoding/json` calls `io.write_quoted_string` directly and offers no hook.
The walk now exists behind a build flag. This is what it measures.

## The headline, and its bounds

`bench/application_matrix/run-variant-ab.sh`, `/json/medium/int` (4,310 bytes,
**verified byte-identical across both variants by the harness before any
measurement**), 4 lanes, server on CPUs 0-3 and the generator on 4-7, AWS
`c5.2xlarge`, kernel `6.17.0-1017-aws`, one commit with two binaries differing
only by the define and each recorded by sha256.

| | p50 below the knee | ceiling past the knee | failures |
|---|---:|---:|---:|
| control | 265 µs | 26,716/s | 1 |
| own marshal | **154 µs (−41.9%)** | **65,336/s (+144.6%)** | 0 |

Below-knee figures are the median over 8 runs (5 repeats at 30,000 and 3 at
70,000 both include a 10,000/s arm); the ceiling is the median of 3 runs at
70,000/s offered.

**The single failure in one control run is recorded, not explained.** One event
across three runs supports no conclusion, and inventing one would be worse than
leaving it open.

## Two ceilings were measured and thrown away, and that is the part worth reading

The first campaign used the recorded above-knee rate of 30,000/s. It reported
`ceiling at 30000: +12.3%`. That number is wrong, and the instrument had no way
to say so.

At 30,000/s the own-marshal build served **29,999.6/s — 100% of the offered
rate — with a p50 of 156 µs**. A p50 of 156 µs is a service time. The build was
never saturated: 30,000/s is still *below* its knee, so the goodput column was
reporting the load generator's setting, not the server's capacity. The second
campaign raised the rate to 45,000/s and got the same shape: 44,999/s served,
p50 188 µs, `+68.5%` — censored again.

Only at 70,000/s are both arms past the knee, and the raw runs are what show it:

| run | goodput | share of offered | p50 |
|---|---:|---:|---:|
| control ×3 | 26,684–26,745/s | 38.1–38.2% | 8.08–8.11 **s** |
| own marshal ×3 | 64,416–65,530/s | 92.0–93.6% | 336–478 **ms** |

Both are queueing, so both p50s are queue depths and both goodputs are
ceilings. That is the only rate at which the comparison is legitimate.

**The lesson generalises past this report.** The standing rule from the previous
handoff is *trust the instrument's flags over your own reading of a latency
column*. This adds a case the flags do not cover: **a column heading is also a
claim**. `summarise` labels its output "ceiling at N" because the harness was
told N is above the knee — and when the change under test *moves* the knee, that
label becomes false while every flag stays green and nothing turns red. The
discriminator is cheap and should be habitual: read goodput and p50 together. A
p50 in the low hundreds of microseconds with ~100% of the offered rate served is
a service time and the run is below the knee, whatever the heading says.

All three campaigns are preserved, the two censored ones included, in
`evidence/2026-07-30-own-marshal/`.

## Where the time went: a like-for-like profile pair

`profile-endpoint.sh`, both at 10,000/s for 30 s on 4 lanes, `served_share =
100.0` in both manifests — the check that the profile stayed below the knee.

**The first comparison drawn was wrong and is recorded here so it is not drawn
again.** The obvious baseline is this morning's `2026-07-30-encode-profile/int`,
and it is the wrong one: it was taken while `DRUSE_JSON_TYPE_GATE` still
defaulted to `false`. Comparing against it credits the own marshal with the
validation pass that the *type gate* removed — a gain already banked and
reported separately. The control below was therefore re-profiled today, with
the gate on and the own marshal off.

`profile-endpoint.sh` could not do this at all until today: it always built the
default configuration, so it could profile no variant. It now takes
`DRUSE_BENCH_DEFINES` and records the value in the manifest, so a profile can
never be mistaken for another variant's.

**Sample counts are the cleanest number in this report.** Both runs sampled the
server process at 499 Hz for 30 s at the same offered rate with 100% served, so
samples are proportional to CPU time consumed:

| | perf samples | |
|---|---:|---|
| control | 18,198 | |
| own marshal | 6,089 | |

**The control spends 2.99× the CPU to serve the same 10,000 requests per
second.** That is the finding, and it is consistent with the 2.45× ceiling
(26,716 → 65,336/s) measured independently.

Per-symbol, with the own-marshal shares rescaled by the 0.3346 CPU-time ratio so
both columns are shares of the *control's* CPU:

| symbol / cluster | control | own marshal | |
|---|---:|---:|---|
| the four `core:io` string writers | 35.52% | — | gone |
| `strings::_builder_stream_proc` | 11.09% | — | gone: the `io.Writer` vtable adapter |
| `web::json_write_quoted` | — | 4.32% | replaces both rows above |
| `encoding_json::marshal_to_writer` | 6.36% | — | gone |
| `runtime::_append_elems` | 14.26% | 1.94% | |
| `reflect::struct_tag_lookup` | 6.25% | **5.45%** | |
| `__memmove` | 4.54% | 1.42% | |

The writing cluster — the four `io` symbols plus the vtable adapter they drive,
46.6% of the control's CPU — falls **10.8×** in absolute terms, which is the
8.7×–9.5× measured on the writer's own corpus, plus the per-token indirection
the stdlib pays writing every brace, comma and integer through the same
`io.Writer`.

## Against six peers, at an equal offered rate

The A/B compares Druse with itself. It cannot say whether 154 µs is fast. This
does: the same build, in the application matrix, against every peer the host can
run — and with **fasthttp added as a seventh server**, because the README's
headline claim is a fasthttp comparison and Fiber, though it runs on fasthttp,
is not fasthttp.

`/json/medium/int`, 20,000/s offered, 5 alternating repeats. All seven answer
the same **4,310 bytes**; the summariser flags the row otherwise. Zero failures
of any class across the row, and zero `unclassified` — the run before this one
was discarded for a single unclassified failure, per
`planning/diagnosability.md` rule 3.

| server | p50 | p99 | failures |
|---|---:|---:|---:|
| axum | 120 µs | 1,066 µs | 0 |
| fasthttp | 133 µs | 993 µs | 0 |
| fiber | 133 µs | 964 µs | 0 |
| **druse** | **150 µs** | **384 µs** | **0** |
| gin | 156 µs | 492 µs | 0 |
| net/http | 156 µs | 504 µs | 0 |
| fastify | past its knee | — | 0 |

**Fourth of seven on the median, first on the tail.** The p99 is 2.5× shorter
than fasthttp's and 2.8× shorter than Axum's, which is the lane architecture
showing: no internal queue, no scheduler arbitrating, so the worst case is
bounded rather than long.

**The same build measured 360 µs and last place before this change**, with 22
admission failures the other six did not have. Those went to zero, and the
mechanism is one sentence: a lane freed 2.4× sooner stops pushing a four-lane
pool into refusal. The `eof_on_fresh_conn` failures were a symptom of the
encoder, not of the acceptor — which also means the `max_handlers` auto-sizing
question (ADR-048's open item) is now being asked of a much cheaper handler.

**fasthttp and Fiber both measured 133 µs.** They coincide on this workload,
which validates treating them as separate rows and simultaneously shows why the
separation was necessary: coincidence is a measurement, not an assumption.

## The next lever is this project's own code, and it is not what it looks like

`reflect::struct_tag_lookup` is now the largest single symbol in the own-marshal
profile at 16.29% **of that build's** CPU. It is tempting to read that as a
regression introduced by the new walk. It is not: rescaled, it is **5.45% of the
control's CPU against 6.25% before** — essentially unchanged in absolute terms.
It became dominant by attrition, because everything around it shrank by 3×.

That is what makes it the right next target rather than a defect. The lookup
resolves a `json:"…"` tag per field **per request**, and the answer is constant
per type. `web/json_decode.odin` already solved exactly this on the way in with
a per-type descriptor table; the same shape applies here.

## What this does not say

- **It is not adopted.** The flag defaults to `false`. Flipping it changes the
  default cost of every JSON response and is an owner's decision.
- **The subset matters.** The walk covers structs, slices, arrays, dynamic
  arrays, strings, booleans, integers, floats, enums, bit sets, runes and
  unions, and **falls back to the stdlib** for maps, enumerated arrays,
  fixed-capacity arrays, non-platform endianness, non-UTF-8 strings and any
  struct whose `json:"…"` tag carries flags. `/json/medium/int` is entirely
  inside the fast path — verified: its types carry no flagged tags — so this
  measurement is of the fast path, not of a fallback. A payload outside the
  subset pays nothing and gains nothing.
- **One endpoint, one shape.** A document of 64 small records with string,
  integer and boolean fields. A payload dominated by floats, or by maps, would
  measure differently, and floats are still rendered by the stdlib's sixteen-
  decimal path either way.
- **Equivalence is proven separately** and is the precondition for any of this
  meaning anything: `tests/enc1-quoted-string` over every rune and byte in both
  escape spellings, `tests/enc3-own-marshal` over whole documents with the
  coverage claim pinned, `experiments/25-marshal-parity` over 36 documents plus
  the rejection set, and the A/B harness's own byte-identity check on the wire.

## Evidence

`evidence/2026-07-30-own-marshal/`

| directory | what it is |
|---|---|
| `ab-30k-censored/` | the first campaign; its ceiling column is not a ceiling |
| `ab-45k-censored/` | the second; same defect at a higher rate |
| `ab-70k/` | the campaign both arms are past the knee in |
| `profile-control/` | today's control, gate on, own marshal off |
| `profile-ownmarshal/` | the same, with the walk enabled |
