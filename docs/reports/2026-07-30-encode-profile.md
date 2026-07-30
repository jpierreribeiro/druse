# The encode path, profiled for the first time — 2026-07-30

## Verdict

The 2.3× nested-JSON gap decomposes into three visible costs, and the largest of
them is a pass Druse chooses to run:

| | Share of self time | What it is |
|---|---:|---|
| **Second validation pass** | **~25.5%** | `encoding_json.is_valid` re-tokenising every marshalled body |
| **Rune-by-rune string writing** | **~25.7%** | the stdlib encoder emitting strings one rune at a time |
| **Builder growth** | **10.7%** | `runtime::_append_elems`, no preallocation |
| Float rendering (float route only) | ~6.8% | `strconv::write_float` and `strconv_decimal` |
| RTTI tag lookup | 4.3% | `reflect::struct_tag_lookup` |

The encode path had never been profiled. The 2026-07-25 study's profile is a
decode profile taken under a POST workload; no marshal symbol appears in it.

## Method

`bench/application_matrix/profile-endpoint.sh`, `perf record -F 499 -g` for 30
seconds against the pinned server, one run per endpoint, **at 10,000 requests
per second — below the knee**. The 2026-07-30 sweep put Druse's knee for this
workload between 20,000 and 25,000 on four lanes, and a profile taken above it
would sample the queue instead of the work. Both runs served 100% of the offered
rate, which the manifest records so the claim can be checked rather than trusted.

Two endpoints differing only in the type of one field: `/json/medium` (64
`f64` scores, 5,398 bytes) and `/json/medium/int` (the same with integer scores,
4,310 bytes). The diff between their symbol tables is float rendering, isolated.

The kernel fell back from `cycles:u` to `task-clock:u` on this host, so this is a
time profile, not a cycles profile — no IPC or cache claims are made from it.

## `/json/medium/int` at 10,000/s — p50 327 µs

```
10.74%  runtime::_append_elems                       builder growth
 9.60%  encoding_json::get_token                     ── validation pass
 8.45%  strings::_builder_stream_proc
 7.98%  io::write_encoded_rune                       ── string writing
 6.21%  io::write_escaped_rune                       ──
 5.79%  io::write_quoted_string                      ──
 5.70%  io::write_rune                               ──
 4.59%  encoding_json::marshal_to_writer
 4.26%  utf8::decode_rune_in_bytes                   ── validation pass
 4.26%  reflect::struct_tag_lookup
 4.05%  encoding_json::next_rune                     ── validation pass
 3.38%  __memmove_evex_unaligned_erms   (libc)
 2.83%  encoding_json::is_valid_string_literal       ── validation pass
 2.18%  encoding_json::marshal_struct_fields
 2.06%  encoding_json::validate_value                ── validation pass
 1.61%  encoding_json::validate_object_body          ── validation pass
 1.12%  encoding_json::parse_comma                   ── validation pass
```

## What each group means

**The validation pass, ~25.5%.** `web/respond.odin:108` re-runs
`encoding_json.is_valid` over every body the marshaller just produced. Its
comment records why: the pinned marshaller emits `NaN` and `Inf` as bare tokens,
RFC 8259 §6 forbids them, and a compile-time type walk that would catch this
without a second pass is not expressible on the pinned toolchain — `base:intrinsics`
offers `type_field_type($T, $name)` but no field-type-by-index. The decision was
audited and kept. **A quarter of encode CPU is the price of that decision**, and
this is the first measurement of it.

**String writing, ~25.7%.** `write_quoted_string` decodes each string into runes
and writes them one at a time through `write_encoded_rune` and
`write_escaped_rune`. Every response here carries 64 copies of
`"item-abcdefghijklmnop"` plus keys and tags, all pure ASCII with nothing to
escape. This is stdlib behaviour, not framework code.

**Builder growth, 10.7%.** `marshal` builds into a `strings.Builder` starting at
zero capacity, so a 4.3 KB body is grown by repeated `_append_elems`. The
response size is knowable from the previous response of the same route, and
nothing uses that.

**Float rendering, ~6.8%** — measured by difference against the float route:
`strconv::write_float` 2.20%, `strconv_decimal::assign` 1.70%,
`shift_right` 0.83%, plus `get_token.skip_digits` 1.22% and `is_valid_number`
0.85% on the validation side, which are the longer numbers costing more to
re-validate. p50 was 327 µs on the integer route against 368 µs on the float
route in these runs. **This corroborates the sweep**, which measured +3% at
5,000/s and +6% at 10,000/s — and it retires the "50×" figure, which came from
comparing a route past its knee against one inside it.

**RTTI, 4.3%.** `struct_tag_lookup` runs per field per request with no per-type
cache, where Go's `encoding/json` memoises an encoder per type. It is real and
it is not the dominant cost — on the decode side the same symbol was 15.20%
before the fused-descriptor work.

## What this does not say

It does not propose a fix. Each of the three costs has a different owner and a
different price: the validation pass is a deliberate correctness decision with a
documented reason, the string and builder costs live in the pinned standard
library, and `planning/vendor-policy.md` is hostile to patching code the project
does not own.

It does not measure what removing any of them would gain. The percentages are of
encode self time, not of end-to-end latency, and 25% of encode is not 25% of a
request.

One box, one document shape, one rate, one lane count.

## Evidence

`PRIORIDADE/entrega/evidencias/2026-07-30-encode-profile/` — both manifests,
both symbol tables, the exact response each profile encoded, and the load report
proving each run stayed below its knee.
