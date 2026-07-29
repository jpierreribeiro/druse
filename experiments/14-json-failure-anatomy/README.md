# WP67 — JSON failure anatomy

**Pinned toolchain:** `dev-2026-07-nightly:819fdc7`.

Run:

```sh
odin run experiments/14-json-failure-anatomy -collection:druse=.
```

## Observed matrix before any patch

| Input | `web.body` | Raw stdlib result |
|---|---|---|
| malformed JSON | `400 invalid_json` | `Invalid_Data` |
| scalar type mismatch | `500 internal_error` | `Unsupported_Type_Error`, token offset 7, no field path |
| nested type mismatch | `500 internal_error` | `Unsupported_Type_Error`, token offset 21, no field path |
| unknown field | success | `nil`; field skipped deliberately |
| `json:"name,required"` absent | success | `nil`; option ignored |
| `validate:"min=0,max=130"` violated | success | outside the decoder's vocabulary |
| unsupported destination field | `500 internal_error` | `Unsupported_Type_Error` |
| allocations forced through `mem.nil_allocator()` | direct decoder returns `nil` with zero/empty destination; `web.body` classifies the same valid input as `400 invalid_json` during validation | no reliable allocation error |

The real-socket negative control in
`tests/wp67-json-boundary/transport-control/` returns the same current 500 and
body as `web.test_request`. The defect is therefore core classification, not a
test-transport shortcut.

## Finding

The stdlib error carries the destination `typeid` and the offending token, but
not the JSON key stack. Field paths and unknown-field refusal require a bounded
structural preflight or a thin decoder owned by the framework; re-labeling
`Unsupported_Type_Error` alone cannot produce an honest path.

Requiredness and domain validation are a separate schema decision. Making
`required` or `validate` tags canonical merely because the experiment used them
as probes would pre-decide WP81 and reproduce the stringly-typed design the
phase exists to avoid. Their RED tests remain separate until WP81 selects the
representation.

The allocation result is the more serious finding: the pinned stdlib can
silently return success with zero values when its allocator refuses. WP68 must
use a path whose allocation failures are observable and covered by the internal
RED test. A decoder that maps this to client `invalid_json` is also wrong; the
client's bytes were valid.
