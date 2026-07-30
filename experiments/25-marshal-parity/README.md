# ENC2 — marshal parity

**Pinned toolchain:** `dev-2026-07-nightly:819fdc7`.

Run:

```sh
odin run experiments/25-marshal-parity -collection:druse=.
```

## What this ratifies

`docs/reports/2026-07-30-encode-profile.md` put **25.7% of encode self time** in
writing quoted strings. `web/json_encode_string.odin` makes that primitive
8.7×–9.5× faster and `tests/enc1-quoted-string` proves it byte-for-byte over
every rune, every byte and every two-byte sequence. **Nothing calls it**, because
`core:encoding/json` invokes `io.write_quoted_string` directly and offers no
hook — reaching it requires Druse to own the marshal walk.

Owning the walk is a large change to the response path, so it does not go into
`web/` on an argument. *Specification text proposes; compiling prototypes
ratify.* This is the prototype, and this is its evidence.

## The contract

Byte-for-byte equality with `json.marshal(v, Marshal_Options{}, allocator)` —
the zero-value options the response path uses — over whole documents, plus
error-for-error equality on the types core refuses.

ENC1 proved one primitive. A document is also field ordering, `omitempty`,
`using _` flattening, map iteration order, integer widths, enum rendering and a
rejection set, none of which a string test can reach.

## Observed matrix

**36 cases, 0 disagreements.**

| group | what it covers |
|---|---|
| scalars | `int`, negative `int`, `f64`, `string`, `bool` as whole payloads |
| structs | `json:"name"`, `json:"-"`, `,omitempty` empty and populated, `using _: T` flattening, nesting, empty slice |
| numeric widths | every signed and unsigned width including `i128`/`u128`, `f16`/`f32`/`f64`, `complex64`, `bool`/`b8`/`b64`, `cstring` |
| collections | fixed array, dynamic array, `map[string]int` with one and with four keys, `map[int]string`, empty map, every empty container |
| exotic but reachable | `enum`, `bit_set`, `rune`, `union` nil and held, `json.Null` |
| strings | quotes, backslash, control bytes, Latin-1, above U+00FF, astral, invalid UTF-8 |
| rejection set | pointer, procedure, `any`, `typeid`, quaternion, matrix, multi-pointer — both must refuse |

Two cases exist because the obvious version of them tests nothing:

- **`any` and `typeid` are reached as struct FIELDS.** Passing `var_any: any =
  small` to a procedure taking `any` unwraps it; both marshallers would see a
  `Small`, serialise it happily, and the case would report "ok" while proving
  nothing about `any` at all. The first draft of this file had exactly that bug.
- **The four-key map** is the only case that can test comma placement between
  map entries. Hash order is unspecified, but both marshallers walk the same
  `Raw_Map` buckets in the same order, so the comparison stays exact.

## What parity costs, and the one item that deserves a decision

Equivalence means reproducing core's choices, including the ones that are wrong
on their merits:

- every rune above U+00FF is escaped as `\uXXXX`, though raw UTF-8 is legal JSON;
- `1.5` renders as `1.5000000000000000` — sixteen decimals is a formatting
  choice of `io.write_f64`, not a precision requirement, and it is why a Druse
  `/json/medium` document is 960 bytes larger than its peers';
- maps iterate in hash order and enums render as their underlying integer.

And one that is a **defect, measured here rather than inferred**:

> `opt_write_key` writes object keys with `for_json = false` while string values
> use `for_json = true`. The same U+0007 comes out `\a` in a key and `` in
> a value — and `\a` is not a JSON escape (RFC 8259 §7 admits only
> `" \ / b f n r t uXXXX`).
>
> `json.is_valid`, which the response path trusts as its last line of defence,
> **does not apply escape rules inside keys**. It answers `false` for `\a` in a
> value and `true` for `\a` in a key.

Composed, those two mean a payload whose object key carries a control byte — a
`map[string]T` with a key derived from user input, or a `json:"…"` tag holding
one — puts **invalid JSON on the wire while the NUM-001 guard reports success**.
The prototype reproduces it, so the corpus records it as an executable fact.

This predates the encode work and is unaffected by the per-type validation gate:
for `map[string]string` the walk answers "cannot hold a float" and skips the
pass, but the pass never caught this anyway. **Whether Druse should diverge from
core here is an owner's decision and belongs in an ADR**, not in a commit whose
subject line is about speed.

## Why no pointer type-info symbol appears in the prototype

`build/check_public_api.sh` bans the substrings `Type_Info_Pointer`,
`dereference` and `deref` from `web/` code — by substring, including inside an
identifier — until ADR-003's value-only baseline is amended (R-13). Core's
marshaller names the first of those explicitly, so a transcription of it could
never move into `web/`.

The prototype therefore **enumerates what it serialises and rejects everything
else by falling through** to `Unsupported_Type`. That is byte-for-byte and
error-for-error what core does for pointers, multi-pointers, SOA pointers,
procedures, `any`, `typeid`, parameter lists, SIMD vectors, matrices, bit fields
and quaternions — the rejection rows above are the proof. `json.Null` is the one
pointer-shaped type core *does* serialise, and it is recognised by comparing
typeids, which inspects nothing.

## What is deliberately NOT here

- **The second marshal site.** `web/errors.odin:725` marshals the two-string
  `Error_Envelope` and has no validation pass. It is the path that must not
  fail and its cost is irrelevant; it stays on core.
- **An end-to-end number.** This experiment proves equivalence, not speed. The
  gain, if any, is an A/B against the same commit below the knee — and the
  recorded lesson is that a symbol's share of a profile is not the gain
  available from removing it: builder pre-sizing held 10.7% and measured +0.9%
  p50 / −2.6% ceiling.
- **Float rendering.** Owning the walk makes it addressable; changing it moves
  the bytes on the wire, so it is its own package with its own evidence.
