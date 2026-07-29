# Numeric contract (IEEE 754-2019)

**Status: PROPOSED, 2026-07-23.** A normative numeric contract for the parts of
Druse that decode and serialize numbers — the JSON boundary today, PostgreSQL
decoding in the data Crystals later. Informed by IEEE 754-2019 (floating-point
formats, operations, exceptions) and RFC 8259 §6 (JSON numbers exclude `NaN` and
`Infinity`). This is **behaviour, tests and documentation**; it adds **no public
symbols**.

The project already requires a stable taxonomy for malformed JSON, wrong type,
missing field and internal error. The numeric contract extends that taxonomy to
the one class it did not yet name: numbers that are representable in IEEE 754 but
not in JSON, and numbers that do not survive a boundary.

## Requirements

| ID | Requirement | Status |
|---|---|---|
| **NUM-001** | JSON responses **MUST NOT** contain non-finite numbers (`NaN`, `+Infinity`, `-Infinity`). | **GAP — see below.** |
| **NUM-002** | An out-of-range integer during decoding **MUST NOT** succeed silently; it is `invalid_field`. | **SATISFIED** (F11 fix, `web/json_decode.odin` `json_int_fits`). |
| **NUM-003** | A finite `f64` value **MUST** survive an encode/decode round-trip: `parse(serialize(x)) == x`. | To verify (corpus). |
| **NUM-004** | A finite `f32` value's precision loss when a JSON number is narrowed to `f32` **MUST** be documented; a value outside `f32` range is `invalid_field`. | To document/verify. |
| **NUM-005** | Money/currency Crystals **MUST NOT** use binary floating point by default (use integer minor units or a decimal type). | Crystal-tier rule (see `standards-registry.md`). |

Edge cases the corpus must exercise (NUM-003/004): `-0.0`, subnormals, `f32`/`f64`
max and min, a value just past `f32` max, and a `f64` with full 17-significant-digit
precision.

## NUM-001 is a live gap (routed to a fix)

**Verified 2026-07-23 by reading the pinned toolchain and `web/`:** the encoder
path `web.json` → `core:encoding/json` `marshal` (`web/respond.odin:76`) writes
floats via `io.write_f16/f32/f64` (`core/encoding/json/marshal.odin:209-215`)
with **no `NaN`/`Infinity` guard**, and `web/` rejects non-finite numbers
**nowhere**. So a Handler that returns a struct with a non-finite float field
(e.g. `f64` = `0.0/0.0` or an overflow to `+Inf`) makes the encoder emit the
token `NaN`/`+Inf`/`-Inf` into the response body — **invalid JSON** by RFC 8259,
which a strict client parser then fails to read. The framework advertises strict
JSON and can currently emit non-strict JSON.

**Impact:** correctness/contract bug (a malformed response body), not a crash.
Reachable whenever application arithmetic can produce a non-finite float that
reaches a responder. Low-to-medium severity; a real interop failure for any
client with a conforming JSON parser.

**Required fix (code — routed to the Phase-6.5 corrective / the correcting
agent, NOT done in this doc PR):** the responder must not emit a non-finite
number. Preferred: detect a non-finite float in the value before/at marshal and
refuse — the framework already has a clean "encode failed → static 500 + log,
no partial bytes" path (`web/respond.odin:77-90`); route non-finite through it
(a `500 internal_error`, logged server-side), because a non-finite value in a
response is a server-side programming error, not a client error. A reflection
pre-scan for non-finite floats, or a marshal-output guard, are the two
implementation shapes; the pre-scan is cleaner and keeps the "never emit partial
bytes" invariant. Add a corpus/contract test: a Handler returning a non-finite
float answers 500 and never writes `NaN`/`Inf` to the wire.

## Where this fits

- **`web` (now):** NUM-001 (fix + test), NUM-002 (done), NUM-003/004 (corpus).
  Zero public symbols; it is the JSON boundary's numeric half of the existing
  honest-decoding work.
- **Data Crystals (later):** NUM-005 and the PostgreSQL numeric decode contract
  (NUMERIC/DECIMAL → integer/decimal, never silent float) inherit these IDs.

## Deviations (documented, per the project's honesty rule)

- Druse does **not** implement IEEE 754 arithmetic or exception flags — it is
  not a numerics library. It adopts only the **boundary** obligations: what may
  cross the JSON/DB wire, and what a narrowing conversion must refuse. The rest
  of 754 is `NAO_APLICAVEL`.
